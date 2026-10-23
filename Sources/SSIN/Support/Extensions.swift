import AppKit

let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The screen that owns the menu bar; its origin is (0, 0) in Cocoa global space.
    static var primary: NSScreen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }

    static var withMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }

    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

enum Geometry {
    /// Converts a rect in CoreGraphics global space (top-left origin) into Cocoa global space.
    static func cocoaRect(fromCG r: CGRect) -> CGRect {
        let h = NSScreen.primary?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func distance(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
        return p.distance(to: a + ab * t)
    }

    /// Snaps the end point so the segment lies on a multiple of 45°.
    static func snapAngle(from s: CGPoint, to e: CGPoint) -> CGPoint {
        let d = e - s
        let len = hypot(d.x, d.y)
        let step = CGFloat.pi / 4
        let angle = (atan2(d.y, d.x) / step).rounded() * step
        return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
    }

    /// Makes the rect spanned by s and e a square, keeping the drag direction.
    static func squareEnd(from s: CGPoint, to e: CGPoint) -> CGPoint {
        let d = e - s
        let side = max(abs(d.x), abs(d.y))
        return CGPoint(x: s.x + (d.x < 0 ? -side : side), y: s.y + (d.y < 0 ? -side : side))
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }

    func downscaled(by factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(width) * factor).rounded()))
        let h = max(1, Int((CGFloat(height) * factor).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Composites the image onto an opaque color (used for formats without alpha).
    func flattened(onto color: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.draw(self, in: rect)
        return ctx.makeImage()
    }

    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func load(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

extension NSImage {
    convenience init(cgImage: CGImage, scale: CGFloat) {
        self.init(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }
}

/// Windows that should give the app a Dock icon and a place in ⌘-Tab while they are open.
class AppWindow: NSWindow {}

@MainActor
enum ActivationPolicy {
    static func refresh() {
        let hasWindows = NSApp.windows.contains { $0 is AppWindow && $0.isVisible }
        let target: NSApplication.ActivationPolicy = hasWindows ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }

    static func refreshSoon() {
        DispatchQueue.main.async { refresh() }
    }
}
