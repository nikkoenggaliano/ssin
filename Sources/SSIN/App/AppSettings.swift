import AppKit
import Carbon.HIToolbox
import Combine

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG (lossless)" : "JPEG (smaller)" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc

    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264 — plays everywhere" : "HEVC — sharper, smaller files" }
}

enum HotKeyAction: String, CaseIterable, Identifiable, Codable {
    case captureArea, captureFullscreen, captureText, recordScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureText: "Capture Text (OCR)"
        case .recordScreen: "Record Screen"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "rectangle.dashed"
        case .captureFullscreen: "display"
        case .captureText: "text.viewfinder"
        case .recordScreen: "record.circle"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .captureFullscreen: KeyCombo(kVK_ANSI_1, [.command, .shift])
        case .captureArea: KeyCombo(kVK_ANSI_2, [.command, .shift])
        case .recordScreen: KeyCombo(kVK_ANSI_6, [.command, .shift])
        case .captureText: KeyCombo(kVK_ANSI_7, [.command, .shift])
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let saveFolder = "saveFolder"
        static let openEditor = "openEditor"
        static let copyAfterCapture = "copyAfterCapture"
        static let saveAfterCapture = "saveAfterCapture"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let captureCursor = "captureCursor"
        static let playSounds = "playSounds"
        static let hotKeys = "hotKeys"
        static let recordFPS = "recordFPS"
        static let videoCodec = "videoCodec"
        static let recordCursor = "recordCursor"
        static let recordClicks = "recordClicks"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let showRecordingPreview = "showRecordingPreview"
    }

    private let defaults = UserDefaults.standard

    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    @Published var openEditor: Bool { didSet { defaults.set(openEditor, forKey: Key.openEditor) } }
    @Published var copyAfterCapture: Bool { didSet { defaults.set(copyAfterCapture, forKey: Key.copyAfterCapture) } }
    @Published var saveAfterCapture: Bool { didSet { defaults.set(saveAfterCapture, forKey: Key.saveAfterCapture) } }
    @Published var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: Key.imageFormat) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var captureCursor: Bool { didSet { defaults.set(captureCursor, forKey: Key.captureCursor) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var hotKeys: [HotKeyAction: KeyCombo] { didSet { saveHotKeys() } }

    @Published var recordFPS: Int { didSet { defaults.set(recordFPS, forKey: Key.recordFPS) } }
    @Published var videoCodec: VideoCodec { didSet { defaults.set(videoCodec.rawValue, forKey: Key.videoCodec) } }
    @Published var recordCursor: Bool { didSet { defaults.set(recordCursor, forKey: Key.recordCursor) } }
    @Published var recordClicks: Bool { didSet { defaults.set(recordClicks, forKey: Key.recordClicks) } }
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: Key.recordMicrophone) } }
    @Published var showRecordingPreview: Bool { didSet { defaults.set(showRecordingPreview, forKey: Key.showRecordingPreview) } }

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/SSIN", isDirectory: true)
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.openEditor: true,
            Key.copyAfterCapture: true,
            Key.saveAfterCapture: false,
            Key.imageFormat: ImageFormat.png.rawValue,
            Key.jpegQuality: 0.9,
            Key.captureCursor: false,
            Key.playSounds: true,
            Key.recordFPS: 60,
            Key.videoCodec: VideoCodec.h264.rawValue,
            Key.recordCursor: true,
            Key.recordClicks: true,
            Key.recordSystemAudio: false,
            Key.recordMicrophone: false,
            Key.showRecordingPreview: true,
        ])
        saveFolder = d.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        openEditor = d.bool(forKey: Key.openEditor)
        copyAfterCapture = d.bool(forKey: Key.copyAfterCapture)
        saveAfterCapture = d.bool(forKey: Key.saveAfterCapture)
        imageFormat = ImageFormat(rawValue: d.string(forKey: Key.imageFormat) ?? "") ?? .png
        jpegQuality = d.double(forKey: Key.jpegQuality)
        captureCursor = d.bool(forKey: Key.captureCursor)
        playSounds = d.bool(forKey: Key.playSounds)
        recordFPS = d.integer(forKey: Key.recordFPS)
        videoCodec = VideoCodec(rawValue: d.string(forKey: Key.videoCodec) ?? "") ?? .h264
        recordCursor = d.bool(forKey: Key.recordCursor)
        recordClicks = d.bool(forKey: Key.recordClicks)
        recordSystemAudio = d.bool(forKey: Key.recordSystemAudio)
        recordMicrophone = d.bool(forKey: Key.recordMicrophone)
        showRecordingPreview = d.bool(forKey: Key.showRecordingPreview)
        hotKeys = Self.loadHotKeys(from: d)
    }

    private static func loadHotKeys(from d: UserDefaults) -> [HotKeyAction: KeyCombo] {
        guard let data = d.data(forKey: Key.hotKeys),
              let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data)
        else {
            return Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultCombo) })
        }
        // A missing entry means the user cleared that shortcut.
        var result: [HotKeyAction: KeyCombo] = [:]
        for (key, combo) in stored {
            if let action = HotKeyAction(rawValue: key) { result[action] = combo }
        }
        return result
    }

    private func saveHotKeys() {
        let stored = Dictionary(uniqueKeysWithValues: hotKeys.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.hotKeys)
        }
    }
}
