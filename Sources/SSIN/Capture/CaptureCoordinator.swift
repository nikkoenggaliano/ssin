import AppKit

/// Entry point for every capture action (hotkeys and menu).
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlayController?
    private var busy = false
    private var previousApp: NSRunningApplication?

    func captureArea() { beginSelection(.screenshot) }
    func captureText() { beginSelection(.text) }

    func toggleRecording() {
        if ScreenRecorder.shared.isRecording {
            Task { await ScreenRecorder.shared.stop() }
        } else {
            beginSelection(.record)
        }
    }

    func captureFullscreen() {
        guard overlay == nil, !busy, Permissions.ensureScreenCapture() else { return }
        busy = true
        let screen = NSScreen.withMouse ?? NSScreen.main
        Task {
            defer { busy = false }
            do {
                let session = try await CaptureSession.make(frozen: true, onlyDisplay: screen?.displayID)
                guard let id = screen?.displayID, let shot = session.shots[id] else { return }
                deliver(image: shot.image, scale: shot.scale)
            } catch {
                Permissions.report(error)
            }
        }
    }

    private func beginSelection(_ purpose: SelectionPurpose) {
        if let overlay {
            overlay.finish(nil)
            return
        }
        guard !busy, Permissions.ensureScreenCapture() else { return }
        busy = true
        previousApp = NSWorkspace.shared.frontmostApplication
        Task {
            do {
                let session = try await CaptureSession.make(frozen: purpose != .record)
                let controller = SelectionOverlayController(session: session, purpose: purpose) { [weak self] result in
                    self?.overlay = nil
                    self?.handle(result, purpose: purpose, session: session)
                }
                overlay = controller
                busy = false
                controller.show()
            } catch {
                busy = false
                Permissions.report(error)
            }
        }
    }

    private func handle(_ result: SelectionResult?, purpose: SelectionPurpose, session: CaptureSession) {
        guard let result else {
            restoreFocus()
            return
        }
        switch purpose {
        case .record:
            restoreFocus()
            Task { await ScreenRecorder.shared.start(screen: result.screen, rect: result.rect) }
        case .text:
            restoreFocus()
            guard let (image, _) = crop(result, from: session) else { return }
            Task { await OCR.copyText(from: image) }
        case .screenshot:
            Task {
                if let info = result.window,
                   let window = session.content.windows.first(where: { $0.windowID == info.id }),
                   let (image, scale) = try? await ScreenGrabber.captureWindow(window) {
                    deliver(image: image, scale: scale)
                } else if let (image, scale) = crop(result, from: session) {
                    deliver(image: image, scale: scale)
                } else {
                    restoreFocus()
                }
            }
        }
    }

    private func crop(_ result: SelectionResult, from session: CaptureSession) -> (CGImage, CGFloat)? {
        guard let id = result.screen.displayID, let shot = session.shots[id] else { return nil }
        let s = CGFloat(shot.image.width) / result.screen.frame.width
        let h = result.screen.frame.height
        let r = result.rect
        let x0 = (r.minX * s).rounded(), x1 = (r.maxX * s).rounded()
        let y0 = ((h - r.maxY) * s).rounded(), y1 = ((h - r.minY) * s).rounded()
        guard x1 - x0 >= 1, y1 - y0 >= 1,
              let image = shot.image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { return nil }
        return (image, shot.scale)
    }

    /// Applies the "after capture" preferences.
    func deliver(image: CGImage, scale: CGFloat) {
        let settings = AppSettings.shared
        Sound.shutter()
        if settings.copyAfterCapture { Exporter.copyToClipboard(image, scale: scale) }
        if settings.saveAfterCapture { Exporter.saveInBackground(image, scale: scale, announce: !settings.openEditor) }
        if settings.openEditor {
            previousApp = nil
            EditorWindowController.open(image: image, scale: scale)
        } else {
            restoreFocus()
            if settings.copyAfterCapture && !settings.saveAfterCapture { Toast.show("Copied to clipboard") }
        }
    }

    private func restoreFocus() {
        if let app = previousApp, app != NSRunningApplication.current {
            app.activate()
        }
        previousApp = nil
    }
}
