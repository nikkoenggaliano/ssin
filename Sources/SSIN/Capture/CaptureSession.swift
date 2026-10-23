import AppKit
import ScreenCaptureKit

struct DisplayShot {
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Pixels per point (2 on Retina).
    let scale: CGFloat
}

struct WindowInfo {
    let id: CGWindowID
    /// Cocoa global coordinates.
    let frame: CGRect
    let owner: String
}

/// Everything gathered at the moment a hotkey fires: frozen display images and the window layout.
@MainActor
final class CaptureSession {
    let shots: [CGDirectDisplayID: DisplayShot]
    let windows: [WindowInfo]
    let content: SCShareableContent

    private init(shots: [CGDirectDisplayID: DisplayShot], windows: [WindowInfo], content: SCShareableContent) {
        self.shots = shots
        self.windows = windows
        self.content = content
    }

    /// - Parameters:
    ///   - frozen: capture display images (screenshots). Recording selection uses the live screen instead.
    ///   - onlyDisplay: limit the capture to one display.
    static func make(frozen: Bool, onlyDisplay: CGDirectDisplayID? = nil) async throws -> CaptureSession {
        let windows = WindowList.onScreenWindows()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [CGDirectDisplayID: DisplayShot] = [:]
        if frozen {
            let cursor = AppSettings.shared.captureCursor
            let targets: [(SCDisplay, CGFloat)] = NSScreen.screens.compactMap { screen in
                guard let id = screen.displayID, onlyDisplay == nil || onlyDisplay == id,
                      let display = content.displays.first(where: { $0.displayID == id })
                else { return nil }
                return (display, screen.backingScaleFactor)
            }
            try await withThrowingTaskGroup(of: DisplayShot.self) { group in
                for (display, scale) in targets {
                    group.addTask { try await ScreenGrabber.capture(display: display, fallbackScale: scale, cursor: cursor) }
                }
                for try await shot in group { shots[shot.displayID] = shot }
            }
        }
        return CaptureSession(shots: shots, windows: windows, content: content)
    }
}

enum ScreenGrabber {
    /// Captures a whole display at its native pixel resolution.
    static func capture(display: SCDisplay, fallbackScale: CGFloat, cursor: Bool) async throws -> DisplayShot {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : fallbackScale
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = cursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return DisplayShot(displayID: display.displayID, image: image, scale: scale)
    }

    /// Captures a single window on its own (even if partly covered), with transparent rounded corners.
    static func captureWindow(_ window: SCWindow) async throws -> (CGImage, CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }
}

enum WindowList {
    /// Normal app windows on screen, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int).map({ $0 != Int(me) }) ?? false,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return WindowInfo(id: CGWindowID(number), frame: Geometry.cocoaRect(fromCG: bounds),
                              owner: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}
