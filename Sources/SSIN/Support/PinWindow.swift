import AppKit

/// A screenshot pinned above all windows. Drag to move, scroll to resize, double-click or Esc to close.
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []

    private let image: CGImage
    private let scale: CGFloat
    private let aspect: CGFloat

    static func show(image: CGImage, scale: CGFloat) {
        let pin = PinWindow(image: image, scale: scale)
        open.append(pin)
        pin.orderFrontRegardless()
        pin.makeKey()
    }

    private init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let screen = NSScreen.withMouse ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = CGSize(width: vf.width * 0.5, height: vf.height * 0.5)
        if size.width > maxSize.width || size.height > maxSize.height {
            let f = min(maxSize.width / size.width, maxSize.height / size.height)
            size = CGSize(width: size.width * f, height: size.height * f)
        }
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)

        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = false

        let view = PinContentView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        view.autoresizingMask = [.width, .height]
        view.menu = makeMenu()
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
        var f = frame
        let newWidth = min(max(f.width * (1 + delta), 80), 4000)
        let newHeight = newWidth / aspect
        f.origin.x += (f.width - newWidth) / 2
        f.origin.y += (f.height - newHeight) / 2
        f.size = CGSize(width: newWidth, height: newHeight)
        setFrame(f, display: true)
    }

    override func close() {
        super.close()
        PinWindow.open.removeAll { $0 === self }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Save to Folder", action: #selector(saveImage), keyEquivalent: "s").target = self
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [100, 80, 60, 40] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = value
            item.target = self
            sub.addItem(item)
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "w").target = self
        return menu
    }

    @objc private func copyImage() {
        Exporter.copyToClipboard(image, scale: scale)
        Toast.show("Copied to clipboard")
    }

    @objc private func saveImage() {
        do {
            let url = try Exporter.saveToFolder(image, scale: scale)
            Toast.show("Saved", detail: url.lastPathComponent)
        } catch {
            Toast.show("Couldn't save", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
        }
    }

    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func closePin() { close() }
}

private final class PinContentView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
        } else {
            window?.performDrag(with: event)
        }
    }
}
