import AppKit
import AVKit
import SwiftUI

final class RecordingPreviewWindow: AppWindow {}

/// Plays a finished recording with quick actions: trim, copy, reveal, delete.
@MainActor
final class RecordingPreviewController: NSWindowController, NSWindowDelegate {
    private static var open: [RecordingPreviewController] = []

    private var url: URL
    private let playerView = AVPlayerView()
    private let model = RecordingPreviewModel()

    static func show(url: URL) {
        let controller = RecordingPreviewController(url: url)
        open.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        ActivationPolicy.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL) {
        self.url = url
        let window = RecordingPreviewWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 600),
                                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        window.tabbingMode = .disallowed

        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.player = AVPlayer(url: url)

        model.trim = { [weak self] in self?.trim() }
        model.copy = { [weak self] in self?.copyFile() }
        model.reveal = { [weak self] in self?.reveal() }
        model.delete = { [weak self] in self?.deleteFile() }

        let bar = NSHostingView(rootView: RecordingPreviewBar(model: model))
        let container = NSView()
        for view in [playerView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 56),
        ])
        window.contentView = container
        window.center()
        Task { await loadInfo() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func loadInfo() async {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var pixelSize = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            pixelSize = natural
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        model.info = "\(Int(pixelSize.width))×\(Int(pixelSize.height)) · \(RecordingPreviewBar.format(duration)) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        if pixelSize.width > 0, let window, let screen = window.screen ?? NSScreen.main {
            let scale = screen.backingScaleFactor
            let vf = screen.visibleFrame
            var size = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale + 56 + 28)
            let f = min(1, vf.width * 0.85 / size.width, vf.height * 0.85 / size.height)
            size = CGSize(width: max(560, size.width * f), height: max(380, size.height * f))
            window.setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        playerView.player?.play()
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.removeAll { $0 === self }
        ActivationPolicy.refreshSoon()
    }

    private func trim() {
        guard playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                guard result == .okButton, let self, let item = self.playerView.player?.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                Task { await self.exportTrim(start: start, end: end) }
            }
        }
    }

    private func exportTrim(start: CMTime, end: CMTime) async {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        session.timeRange = CMTimeRange(start: start, end: end)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".trim-\(UUID().uuidString).mp4")
        model.busy = true
        defer { model.busy = false }
        do {
            try await session.export(to: temp, as: .mp4)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            playerView.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
            await loadInfo()
            Toast.show("Trimmed", symbol: "scissors")
        } catch {
            try? FileManager.default.removeItem(at: temp)
            Toast.show("Trim failed", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
        }
    }

    private func copyFile() {
        Exporter.copyFile(url)
        Toast.show("Video copied", symbol: "film.fill", detail: "Paste it into Slack, Finder, Mail…")
    }

    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func deleteFile() {
        playerView.player?.pause()
        NSWorkspace.shared.recycle([url]) { _, _ in }
        Toast.show("Moved to Trash", symbol: "trash.fill", tint: .secondary)
        window?.close()
    }
}

@MainActor
final class RecordingPreviewModel: ObservableObject {
    @Published var info = ""
    @Published var busy = false
    var trim: () -> Void = {}
    var copy: () -> Void = {}
    var reveal: () -> Void = {}
    var delete: () -> Void = {}
}

private struct RecordingPreviewBar: View {
    @ObservedObject var model: RecordingPreviewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(.secondary)
            Text(model.info).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            BarButton(symbol: "scissors", help: "Trim", action: model.trim)
            BarButton(symbol: "folder", help: "Show in Finder", action: model.reveal)
            BarButton(symbol: "trash", help: "Move to Trash", action: model.delete)
            Button(action: model.copy) {
                Label("Copy Video", systemImage: "doc.on.doc.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.accentColor.gradient))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
