import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu = NSMenu()
    private var recordingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let capture = CaptureCoordinator.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        setupStatusItem()

        HotKeyCenter.shared.install()
        applyHotKeys(AppSettings.shared.hotKeys)
        AppSettings.shared.$hotKeys
            .dropFirst()
            .sink { [weak self] keys in self?.applyHotKeys(keys) }
            .store(in: &cancellables)

        ScreenRecorder.shared.onStateChange = { [weak self] in self?.updateStatusItem() }
        try? FileManager.default.createDirectory(at: AppSettings.shared.saveFolder, withIntermediateDirectories: true)

        if !UserDefaults.standard.bool(forKey: "didLaunchBefore") {
            UserDefaults.standard.set(true, forKey: "didLaunchBefore")
            // A screenshot tool is only useful if it's always there; the user can turn this off in Settings.
            try? SMAppService.mainApp.register()
            Permissions.requestOnFirstLaunch()
            SettingsWindowController.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.show() }
        return true
    }

    /// Finalizes an in-progress recording before quitting so the file isn't lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecorder.shared.isRecording else { return .terminateNow }
        Task {
            await ScreenRecorder.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Hotkeys

    private func applyHotKeys(_ keys: [HotKeyAction: KeyCombo]) {
        var bindings: [HotKeyAction: (combo: KeyCombo, handler: () -> Void)] = [:]
        for (action, combo) in keys {
            bindings[action] = (combo, { [weak self] in self?.perform(action) })
        }
        HotKeyCenter.shared.setBindings(bindings)
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: capture.captureArea()
        case .captureFullscreen: capture.captureFullscreen()
        case .captureText: capture.captureText()
        case .recordScreen: capture.toggleRecording()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        if ScreenRecorder.shared.isRecording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.imagePosition = .imageLeading
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecording(_:))
            updateRecordingTitle()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRecordingTitle() }
            }
        } else {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SSIN")
            button.image?.isTemplate = true
            button.title = ""
            button.action = nil
            statusItem.menu = statusMenu
        }
    }

    private func updateRecordingTitle() {
        guard let start = ScreenRecorder.shared.startedAt else { return }
        let s = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let keys = AppSettings.shared.hotKeys
        for action in HotKeyAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if let combo = keys[action] {
                item.keyEquivalent = combo.menuKeyEquivalent
                item.keyEquivalentModifierMask = combo.flags
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder(_:)), keyEquivalent: "")
        folder.target = self
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(folder)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SSIN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.perform(action) }
    }

    @objc private func stopRecording(_ sender: Any?) {
        Task { await ScreenRecorder.shared.stop() }
    }

    @objc private func openFolder(_ sender: Any?) {
        let folder = AppSettings.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }
}
