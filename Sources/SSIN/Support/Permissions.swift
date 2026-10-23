import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
enum Permissions {
    private static let askedKey = "askedScreenCapture"

    static var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true when capture is allowed. Otherwise triggers the system prompt (first time) or explains how to enable it.
    static func ensureScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let askedBefore = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)
        if CGRequestScreenCaptureAccess() { return true }
        if askedBefore { showScreenCaptureAlert() }
        return false
    }

    static func requestOnFirstLaunch() {
        guard !CGPreflightScreenCaptureAccess(), !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        _ = CGRequestScreenCaptureAccess()
    }

    static func showScreenCaptureAlert() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording"
        alert.informativeText = "SSIN needs Screen & System Audio Recording permission to capture your screen.\n\nTurn it on in System Settings → Privacy & Security, then quit and reopen SSIN."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    static func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
            showScreenCaptureAlert()
            return
        }
        Toast.show("Capture failed", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
    }
}
