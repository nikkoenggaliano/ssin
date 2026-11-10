import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class SettingsWindow: AppWindow {}

@MainActor
enum SettingsWindowController {
    private static var window: SettingsWindow?

    static func show() {
        if window == nil {
            let w = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 640),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "SSIN Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { ActivationPolicy.refreshSoon() }
            }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        ActivationPolicy.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 560, height: 640)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasPermission = Permissions.hasScreenCapture

    var body: some View {
        Form {
            Section("Save location") {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: settings.saveFolder.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                    Button {
                        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(settings.saveFolder)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .help("Open folder")
                }
            }
            Section("After capturing a screenshot") {
                Toggle("Open the editor", isOn: $settings.openEditor)
                Toggle("Copy to clipboard", isOn: $settings.copyAfterCapture)
                Toggle("Save to folder", isOn: $settings.saveAfterCapture)
            }
            Section("Images") {
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                if settings.imageFormat == .jpeg {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $settings.jpegQuality, in: 0.5...1)
                            Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().frame(width: 40)
                        }
                    }
                }
                Toggle("Include the mouse cursor", isOn: $settings.captureCursor)
                LabeledContent("Resolution") {
                    Text("Native pixels (Retina @2x kept)").foregroundStyle(.secondary)
                }
            }
            Section("App") {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                LabeledContent("Screen Recording permission") {
                    if hasPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") { Permissions.openScreenCaptureSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = Permissions.hasScreenCapture
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            Toast.show("Couldn't change login item", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if hotKeys.failed.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("This shortcut is already used by another app")
                            }
                            HotKeyRecorder(combo: Binding(get: { settings.hotKeys[action] },
                                                          set: { settings.hotKeys[action] = $0 }))
                        }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            } footer: {
                Text("Click a shortcut and press new keys. ⌫ clears it, Esc cancels. If a shortcut doesn't fire, quit other screenshot apps (e.g. Shottr) or change their shortcuts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("In the editor") {
                ShortcutRow("Tools", "V A L R O T N P H B S C")
                ShortcutRow("Colors", "1 – 9")
                ShortcutRow("Copy · Copy & close", "⌘C · ⌘↩")
                ShortcutRow("Save · Save as", "⌘S · ⇧⌘S")
                ShortcutRow("Copy text (OCR) · Pin", "⇧⌘C · ⌘P")
                ShortcutRow("Copy pixel color", "Tab")
                ShortcutRow("Zoom fit · 100% · in/out", "⌘0 · ⌘1 · ⌘= / ⌘-")
                ShortcutRow("Close", "Esc")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: String

    init(_ title: String, _ keys: String) {
        self.title = title
        self.keys = keys
    }

    var body: some View {
        LabeledContent(title) {
            Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

private struct RecordingSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $settings.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                Picker("Codec", selection: $settings.videoCodec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Resolution") {
                    Text("Native Retina pixels, MP4").foregroundStyle(.secondary)
                }
            }
            Section("Cursor") {
                Toggle("Show the cursor", isOn: $settings.recordCursor)
                Toggle("Highlight clicks", isOn: $settings.recordClicks)
            }
            Section("Audio") {
                Toggle("Record desktop audio", isOn: $settings.recordSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordMicrophone)
                Text("Both can also be switched right before you record: click them on the recording overlay, or press M and D. They can't change once a recording is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("When finished") {
                Toggle("Open a preview to trim, copy or share", isOn: $settings.showRecordingPreview)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press a key combination.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press keys…" : (combo?.displayString ?? "Record Shortcut"))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? Color.accentColor : (combo == nil ? .secondary : .primary))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            if combo != nil && !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(KeyCombo.relevantFlags)
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            if modifiers.isEmpty && (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete) {
                combo = nil
                stop()
                return nil
            }
            guard !modifiers.intersection([.command, .option, .control]).isEmpty || KeyCombo.isFunctionKey(event.keyCode) else {
                NSSound.beep()
                return nil
            }
            combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotKeyCenter.shared.resume()
        }
    }
}
