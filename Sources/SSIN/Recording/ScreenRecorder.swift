import AppKit
import AVFoundation
import ScreenCaptureKit

/// Which audio sources the current recording captures. Fixed when the recording starts: ScreenCaptureKit closes
/// the file's audio tracks on a mid-stream configuration change, so the sources are chosen before the first frame.
struct RecordingAudio {
    var microphone = false
    var system = false
}

/// Records an area of one display straight to MP4 with ScreenCaptureKit (hardware encoder, native resolution).
@MainActor
final class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var audio = RecordingAudio()
    var onStateChange: (() -> Void)?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var fileURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var failure: Error?
    private let sink = StreamSink()
    private let hud = RecordingHUD()

    func start(screen: NSScreen, rect: CGRect) async {
        guard !isRecording, stream == nil else { return }
        let settings = AppSettings.shared
        var microphone = settings.recordMicrophone
        if microphone {
            microphone = await Permissions.ensureMicrophone()
            if !microphone {
                Toast.show("Microphone access is off", symbol: "mic.slash.fill", detail: "Recording without microphone", tint: .orange)
            }
        }

        let systemAudio = settings.recordSystemAudio
        audio = RecordingAudio(microphone: microphone, system: systemAudio)

        let globalRect = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let isFullScreen = rect.width >= screen.frame.width - 1 && rect.height >= screen.frame.height - 1
        // Show the HUD first: the app must own a window to be excluded from the capture below.
        hud.show(around: globalRect, on: screen, showBorder: !isFullScreen, audio: audio,
                 onStop: { [weak self] in Task { await self?.stop() } },
                 onDiscard: { [weak self] in Task { await self?.stop(discard: true) } })

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { throw CocoaError(.featureUnsupported) }
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : screen.backingScaleFactor

            let config = SCStreamConfiguration()
            if !isFullScreen {
                // sourceRect uses display points with a top-left origin.
                config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
            }
            var width = rect.width * scale, height = rect.height * scale
            // The H.264 hardware encoder tops out at 4096 px; HEVC goes to 8K.
            let limit: CGFloat = settings.videoCodec == .h264 ? 4096 : 8192
            if max(width, height) > limit {
                let f = limit / max(width, height)
                width *= f
                height *= f
            }
            config.width = max(64, Int(width) & ~1)
            config.height = max(64, Int(height) & ~1)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.recordFPS))
            config.queueDepth = 8
            config.showsCursor = settings.recordCursor
            config.showMouseClicks = settings.recordClicks
            config.capturesAudio = systemAudio
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = microphone
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            config.pixelFormat = kCVPixelFormatType_32BGRA

            try FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
            let url = Exporter.uniqueURL(in: settings.saveFolder, base: Exporter.fileName(prefix: "Recording"), ext: "mp4")
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = url
            recordingConfig.outputFileType = .mp4
            let codec: AVVideoCodecType = settings.videoCodec == .hevc ? .hevc : .h264
            recordingConfig.videoCodecType = recordingConfig.availableVideoCodecTypes.contains(codec) ? codec : .h264

            let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if config.capturesAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            if microphone { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
            try stream.addRecordingOutput(output)
            try await stream.startCapture()

            self.stream = stream
            self.output = output
            fileURL = url
            failure = nil
            isRecording = true
            startedAt = Date()
            hud.startTimer(from: startedAt!)
            Sound.recordStart()
            onStateChange?()
        } catch {
            hud.hide()
            self.stream = nil
            self.output = nil
            audio = RecordingAudio()
            Permissions.report(error)
        }
    }


    func stop(discard: Bool = false) async {
        guard isRecording, let stream, let output else { return }
        isRecording = false
        hud.hide()
        onStateChange?()

        // Removing the recording output finalizes the file; wait for the delegate (with a safety timeout).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            do {
                try stream.removeRecordingOutput(output)
            } catch {
                resumeFinish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.resumeFinish() }
        }
        try? await stream.stopCapture()
        self.stream = nil
        self.output = nil
        startedAt = nil
        audio = RecordingAudio()
        onStateChange?()

        guard let url = fileURL else { return }
        fileURL = nil
        if discard {
            try? FileManager.default.removeItem(at: url)
            Toast.show("Recording discarded", symbol: "trash.fill", tint: .secondary)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Toast.show("Recording failed", symbol: "exclamationmark.triangle.fill",
                       detail: failure?.localizedDescription ?? "No video was written", tint: .orange)
            return
        }
        Sound.recordStop()
        if AppSettings.shared.showRecordingPreview {
            RecordingPreviewController.show(url: url)
        } else {
            Toast.show("Recording saved", symbol: "film.fill", detail: url.lastPathComponent)
        }
    }

    private func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    /// Stream stopped by the system (display unplugged, permission revoked, "Stop sharing" in the menu bar...).
    private func streamEnded(error: Error) {
        guard isRecording else { return }
        failure = error
        Task { await stop() }
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.streamEnded(error: error) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.failure = error
            self.resumeFinish()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish() }
    }
}

/// ScreenCaptureKit wants an output per enabled sample type; the recording output does the real work.
private final class StreamSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "ssin.stream-sink")

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
