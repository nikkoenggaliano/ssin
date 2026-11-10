import AppKit
import QuartzCore

enum SelectionPurpose {
    case screenshot, text, record

    var hint: String {
        switch self {
        case .screenshot: "Drag to capture  ·  Click a window  ·  Click empty space for full screen  ·  Esc to cancel"
        case .text: "Drag over the text you want to copy  ·  Esc to cancel"
        case .record: "Drag an area to record  ·  Click a window or empty space for full screen  ·  Esc to cancel"
        }
    }
}

struct SelectionResult {
    let screen: NSScreen
    /// Screen-local points, bottom-left origin.
    let rect: CGRect
    /// Set when the user clicked a window instead of dragging.
    let window: WindowInfo?
}

/// Full-screen overlays (one per display) where the user drags an area or picks a window.
@MainActor
final class SelectionOverlayController {
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((SelectionResult?) -> Void)?

    init(session: CaptureSession, purpose: SelectionPurpose, completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let shot = screen.displayID.flatMap { session.shots[$0] }
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(screen: screen, shot: shot, windows: session.windows, purpose: purpose)
            view.controller = self
            window.contentView = view
            windows.append(window)
            views.append(view)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        if let key = windows.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? windows.first {
            key.makeKeyAndOrderFront(nil)
            key.makeFirstResponder(key.contentView)
        }
        pointerMoved(to: mouse)
        NSCursor.crosshair.set()
    }

    func pointerMoved(to global: CGPoint) {
        for view in views { view.pointerMoved(toGlobal: global) }
    }

    /// An audio toggle changed: every display's overlay shows the same state.
    func optionsChanged() {
        for view in views { view.refreshOptions() }
    }

    func finish(_ result: SelectionResult?) {
        guard let completion else { return }
        self.completion = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        completion(result)
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    weak var controller: SelectionOverlayController?

    private let screen: NSScreen
    private let shot: DisplayShot?
    private let purpose: SelectionPurpose
    private let windowRects: [(info: WindowInfo, rect: CGRect)]
    /// Pixels per point of the frozen image (or the screen when recording).
    private let pixelScale: CGFloat

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let sizeLabel = PillTextLayer()
    private let hintLabel = PillTextLayer()
    private let loupe = LoupeLayer()
    private let optionsBar = RecordOptionsLayer()

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: (info: WindowInfo, rect: CGRect)?
    private var hoveredOption: RecordOptionsLayer.Option?
    /// Set while a click lands on an audio toggle, so it never starts a selection.
    private var hitOption = false

    init(screen: NSScreen, shot: DisplayShot?, windows: [WindowInfo], purpose: SelectionPurpose) {
        self.screen = screen
        self.shot = shot
        self.purpose = purpose
        pixelScale = shot.map { CGFloat($0.image.width) / screen.frame.width } ?? screen.backingScaleFactor
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        windowRects = windows.compactMap { w in
            let local = w.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(bounds)
            return local.isNull || local.width < 20 || local.height < 20 ? nil : (w, local)
        }
        super.init(frame: bounds)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        guard let root = layer else { return }
        let scale = screen.backingScaleFactor
        if let shot {
            imageLayer.contents = shot.image
            imageLayer.contentsGravity = .resize
            imageLayer.frame = bounds
            root.addSublayer(imageLayer)
        }
        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(shot == nil ? 0.25 : 0.4).cgColor
        outlineLayer.fillColor = nil
        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.lineDashPattern = [5, 4]
        crosshairLayer.fillColor = nil
        hintLabel.setText(purpose.hint, font: .systemFont(ofSize: 13, weight: .medium))
        optionsBar.isHidden = true
        if purpose == .record { optionsBar.configure(scale: scale) }
        for sub in [dimLayer, outlineLayer, crosshairLayer, sizeLabel, hintLabel, optionsBar, loupe] as [CALayer] {
            sub.contentsScale = scale
            root.addSublayer(sub)
        }
        loupe.setScale(scale)
        sizeLabel.isHidden = true
        loupe.isHidden = true
        hintLabel.isHidden = true
        refresh()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { pointerCursor.set() }

    private var pointerCursor: NSCursor { hoveredOption == nil ? .crosshair : .arrow }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(to: NSEvent.mouseLocation)
        pointerCursor.set()
    }

    func pointerMoved(toGlobal global: CGPoint) {
        let local = CGPoint(x: global.x - screen.frame.minX, y: global.y - screen.frame.minY)
        mouse = bounds.contains(local) ? local : nil
        if dragStart == nil {
            hoveredOption = mouse.flatMap { option(at: $0) }
            hovered = hoveredOption != nil ? nil : mouse.flatMap { m in windowRects.first { $0.rect.contains(m) } }
        }
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        if let option = option(at: point) {
            hitOption = true
            toggle(option)
            return
        }
        hitOption = false
        dragStart = point
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hitOption, let start = dragStart else { return }
        var p = clamp(convert(event.locationInWindow, from: nil))
        mouse = p
        if selection == nil && p.distance(to: start) < 3 { return }
        if event.modifierFlags.contains(.shift) { p = clamp(Geometry.squareEnd(from: start, to: p)) }
        selection = CGRect(p1: start, p2: p)
        hovered = nil
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if hitOption {
            hitOption = false
            return
        }
        if let sel = selection, sel.width >= 2, sel.height >= 2 {
            controller?.finish(SelectionResult(screen: screen, rect: snapped(sel), window: nil))
        } else if let hovered {
            controller?.finish(SelectionResult(screen: screen, rect: hovered.rect, window: hovered.info))
        } else if dragStart != nil {
            controller?.finish(SelectionResult(screen: screen, rect: bounds, window: nil))
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller?.finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            controller?.finish(nil)
            return
        }
        guard purpose == .record, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m": toggle(.microphone)
        case "d": toggle(.desktopAudio)
        default: break
        }
    }

    /// Flips an audio source for the recording that is about to start (shared by every overlay on screen).
    private func toggle(_ option: RecordOptionsLayer.Option) {
        let settings = AppSettings.shared
        switch option {
        case .microphone: settings.recordMicrophone.toggle()
        case .desktopAudio: settings.recordSystemAudio.toggle()
        }
        refresh()
        controller?.optionsChanged()
    }

    func refreshOptions() { refresh() }

    /// The audio toggle under a point in view coordinates, if any.
    private func option(at point: CGPoint) -> RecordOptionsLayer.Option? {
        guard purpose == .record, dragStart == nil, selection == nil else { return nil }
        let frame = optionsBar.frame
        guard frame.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return optionsBar.option(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
    }

    override func cancelOperation(_ sender: Any?) { controller?.finish(nil) }

    #if DEBUG
    /// Center of an audio toggle in view coordinates (nil when the bar isn't on screen).
    func debugOptionCenter(_ option: RecordOptionsLayer.Option) -> CGPoint? {
        guard purpose == .record, let local = optionsBar.center(of: option) else { return nil }
        return CGPoint(x: optionsBar.frame.minX + local.x, y: optionsBar.frame.minY + local.y)
    }

    var debugSelectionArmed: Bool { dragStart != nil }

    func debugMouseDown(at point: CGPoint) {
        if let option = option(at: point) {
            hitOption = true
            toggle(option)
            return
        }
        hitOption = false
        dragStart = point
    }

    func dragStartForDebug(_ p: CGPoint) { dragStart = p }
    func selectionForDebug(_ r: CGRect) {
        selection = r
        mouse = CGPoint(x: r.maxX, y: r.minY)
        hovered = nil
        refresh()
    }
    #endif

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Aligns a selection to the pixel grid so crops are exact.
    private func snapped(_ r: CGRect) -> CGRect {
        let s = pixelScale
        let x0 = (r.minX * s).rounded() / s, x1 = (r.maxX * s).rounded() / s
        let y0 = (r.minY * s).rounded() / s, y1 = (r.maxY * s).rounded() / s
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let hole = selection ?? hovered?.rect
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addRect(hole) }
        dimLayer.path = dim

        if let sel = selection {
            outlineLayer.path = CGPath(rect: sel.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            outlineLayer.strokeColor = NSColor.white.cgColor
            outlineLayer.lineWidth = 1
        } else if let rect = hovered?.rect {
            outlineLayer.path = CGPath(rect: rect.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            outlineLayer.strokeColor = NSColor.controlAccentColor.cgColor
            outlineLayer.lineWidth = 3
        } else {
            outlineLayer.path = nil
        }

        if selection == nil, let m = mouse {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: m.x.rounded() + 0.5, y: 0))
            path.addLine(to: CGPoint(x: m.x.rounded() + 0.5, y: bounds.height))
            path.move(to: CGPoint(x: 0, y: m.y.rounded() + 0.5))
            path.addLine(to: CGPoint(x: bounds.width, y: m.y.rounded() + 0.5))
            crosshairLayer.path = path
        } else {
            crosshairLayer.path = nil
        }

        updateSizeLabel()
        updateLoupe()

        hintLabel.isHidden = mouse == nil || dragStart != nil
        hintLabel.position = CGPoint(x: bounds.midX, y: bounds.maxY - 64)
        updateOptionsBar()
    }

    private func updateOptionsBar() {
        guard purpose == .record else { return }
        let settings = AppSettings.shared
        optionsBar.update(microphone: settings.recordMicrophone, desktopAudio: settings.recordSystemAudio, hovered: hoveredOption)
        optionsBar.isHidden = mouse == nil || dragStart != nil
        let size = optionsBar.bounds.size
        let top = bounds.maxY - 64 - hintLabel.bounds.height / 2 - 10
        optionsBar.frame = CGRect(x: (bounds.width - size.width) / 2, y: top - size.height, width: size.width, height: size.height)
    }

    private func updateSizeLabel() {
        let target: CGRect
        var text: String
        if let sel = selection {
            target = sel
            text = "\(Int((sel.width * pixelScale).rounded())) × \(Int((sel.height * pixelScale).rounded()))"
        } else if let hovered {
            target = hovered.rect
            text = "\(Int((hovered.rect.width * pixelScale).rounded())) × \(Int((hovered.rect.height * pixelScale).rounded()))"
            if !hovered.info.owner.isEmpty { text = "\(hovered.info.owner)  ·  \(text)" }
        } else {
            sizeLabel.isHidden = true
            return
        }
        sizeLabel.setText(text)
        sizeLabel.isHidden = false
        let size = sizeLabel.bounds.size
        var x = target.maxX - size.width / 2
        var y = target.minY - size.height / 2 - 8
        if y - size.height / 2 < 4 { y = target.minY + size.height / 2 + 8 }
        x = min(max(x, size.width / 2 + 4), bounds.width - size.width / 2 - 4)
        sizeLabel.position = CGPoint(x: x, y: y)
    }

    private func updateLoupe() {
        guard let shot, let m = mouse else {
            loupe.isHidden = true
            return
        }
        let px = Int(m.x * pixelScale)
        let py = Int((bounds.height - m.y) * pixelScale)
        loupe.update(image: shot.image, pixelX: px, pixelY: py)
        loupe.isHidden = false
        let size = loupe.bounds.size
        var origin = CGPoint(x: m.x + 22, y: m.y - 22 - size.height)
        if origin.x + size.width > bounds.width - 4 { origin.x = m.x - 22 - size.width }
        if origin.y < 4 { origin.y = m.y + 22 }
        loupe.frame.origin = origin
    }
}

/// A rounded dark label drawn with Core Animation.
final class PillTextLayer: CALayer {
    private let textLayer = CATextLayer()

    override init() {
        super.init()
        backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        cornerRadius = 7
        borderWidth = 0.5
        borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        textLayer.alignmentMode = .center
        addSublayer(textLayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet { textLayer.contentsScale = contentsScale }
    }

    func setText(_ text: String, font: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = attributed.size()
        let w = ceil(size.width), h = ceil(size.height)
        bounds = CGRect(x: 0, y: 0, width: w + 18, height: h + 9)
        textLayer.string = attributed
        textLayer.frame = CGRect(x: 9, y: 4.5, width: w, height: h)
    }
}

/// The microphone / desktop-audio toggles shown while picking an area to record.
/// Click them, or press M / D; the choice is remembered in Settings → Recording.
final class RecordOptionsLayer: CALayer {
    enum Option: CaseIterable {
        case microphone, desktopAudio

        var onSymbol: String { self == .microphone ? "mic.fill" : "speaker.wave.2.fill" }
        var offSymbol: String { self == .microphone ? "mic.slash.fill" : "speaker.slash.fill" }
        var title: String { self == .microphone ? "Microphone" : "Desktop audio" }
        var key: String { self == .microphone ? "M" : "D" }
    }

    private static let spacing: CGFloat = 8
    private var chips: [(option: Option, chip: OptionChipLayer)] = []

    func configure(scale: CGFloat) {
        contentsScale = scale
        for option in Option.allCases {
            let chip = OptionChipLayer()
            chip.contentsScale = scale
            chip.configure(option: option, scale: scale)
            chips.append((option, chip))
            addSublayer(chip)
        }
        update(microphone: false, desktopAudio: false, hovered: nil)
    }

    func update(microphone: Bool, desktopAudio: Bool, hovered: Option?) {
        for (option, chip) in chips {
            chip.update(on: option == .microphone ? microphone : desktopAudio, hovered: option == hovered)
        }
        var x: CGFloat = 0, height: CGFloat = 0
        for (_, chip) in chips {
            chip.frame = CGRect(origin: CGPoint(x: x, y: 0), size: chip.bounds.size)
            x += chip.bounds.width + Self.spacing
            height = max(height, chip.bounds.height)
        }
        bounds = CGRect(x: 0, y: 0, width: max(0, x - Self.spacing), height: height)
    }

    /// `point` is in this layer's own coordinate space.
    func option(at point: CGPoint) -> Option? {
        chips.first { $0.chip.frame.insetBy(dx: -2, dy: -4).contains(point) }?.option
    }

    /// Middle of a chip, in this layer's own coordinate space.
    func center(of option: Option) -> CGPoint? {
        chips.first { $0.option == option }?.chip.frame.center
    }
}

/// One toggle pill: icon, label and its key hint.
private final class OptionChipLayer: CALayer {
    private let iconLayer = CALayer()
    private let textLayer = CATextLayer()
    private var onImage: CGImage?
    private var offImage: CGImage?
    private var iconSize = CGSize(width: 14, height: 14)
    private var title = ""
    private var key = ""

    override init() {
        super.init()
        cornerRadius = 9
        borderWidth = 1
        iconLayer.contentsGravity = .resizeAspect
        textLayer.alignmentMode = .left
        addSublayer(iconLayer)
        addSublayer(textLayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet {
            iconLayer.contentsScale = contentsScale
            textLayer.contentsScale = contentsScale
        }
    }

    func configure(option: RecordOptionsLayer.Option, scale: CGFloat) {
        title = option.title
        key = option.key
        onImage = SymbolImage.white(option.onSymbol, pointSize: 12, scale: scale)
        offImage = SymbolImage.white(option.offSymbol, pointSize: 12, scale: scale)
        if let onImage {
            iconSize = CGSize(width: CGFloat(onImage.width) / scale, height: CGFloat(onImage.height) / scale)
        }
    }

    func update(on: Bool, hovered: Bool) {
        iconLayer.contents = on ? onImage : offImage
        iconLayer.opacity = on ? 1 : 0.6
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: on ? NSColor.white : NSColor.white.withAlphaComponent(0.75),
        ])
        text.append(NSAttributedString(string: "  \(key)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(on ? 0.7 : 0.45),
        ]))
        let size = text.size()
        let tw = ceil(size.width), th = ceil(size.height)
        let height: CGFloat = 30, left: CGFloat = 11, gap: CGFloat = 7, right: CGFloat = 12
        bounds = CGRect(x: 0, y: 0, width: left + iconSize.width + gap + tw + right, height: height)
        iconLayer.frame = CGRect(x: left, y: ((height - iconSize.height) / 2).rounded(),
                                 width: iconSize.width, height: iconSize.height)
        textLayer.string = text
        textLayer.frame = CGRect(x: left + iconSize.width + gap, y: ((height - th) / 2).rounded(), width: tw, height: th)
        backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(hovered ? 1 : 0.88).cgColor
            : NSColor(white: 0.08, alpha: hovered ? 0.95 : 0.82).cgColor
        borderColor = NSColor.white.withAlphaComponent(on ? 0.3 : (hovered ? 0.4 : 0.18)).cgColor
    }
}

/// Magnifier showing the pixels around the cursor plus the color under it.
final class LoupeLayer: CALayer {
    private static let cells = 15
    private static let cellSize: CGFloat = 9

    private let zoom = CALayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let info = PillTextLayer()
    private let swatch = CALayer()

    override init() {
        super.init()
        let side = CGFloat(Self.cells) * Self.cellSize
        bounds = CGRect(x: 0, y: 0, width: side, height: side + 34)

        zoom.frame = CGRect(x: 0, y: 34, width: side, height: side)
        zoom.magnificationFilter = .nearest
        zoom.contentsGravity = .resize
        zoom.cornerRadius = 12
        zoom.masksToBounds = true
        zoom.borderWidth = 2
        zoom.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        zoom.backgroundColor = NSColor.black.cgColor

        let path = CGMutablePath()
        for i in 1..<Self.cells {
            let v = CGFloat(i) * Self.cellSize
            path.move(to: CGPoint(x: v, y: 0)); path.addLine(to: CGPoint(x: v, y: side))
            path.move(to: CGPoint(x: 0, y: v)); path.addLine(to: CGPoint(x: side, y: v))
        }
        grid.path = path
        grid.strokeColor = NSColor.black.withAlphaComponent(0.12).cgColor
        grid.lineWidth = 0.5
        grid.frame = zoom.bounds
        zoom.addSublayer(grid)

        let c = CGFloat(Self.cells / 2) * Self.cellSize
        center.path = CGPath(rect: CGRect(x: c, y: c, width: Self.cellSize, height: Self.cellSize), transform: nil)
        center.fillColor = nil
        center.strokeColor = NSColor.white.cgColor
        center.lineWidth = 1.5
        center.shadowColor = NSColor.black.cgColor
        center.shadowOpacity = 0.8
        center.shadowRadius = 1
        center.shadowOffset = .zero
        center.frame = zoom.bounds
        zoom.addSublayer(center)

        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.45
        shadowRadius = 10
        shadowOffset = CGSize(width: 0, height: -3)

        addSublayer(zoom)
        addSublayer(info)
        swatch.cornerRadius = 4
        swatch.borderWidth = 1
        swatch.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        addSublayer(swatch)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ scale: CGFloat) {
        for l in [self, zoom, grid, center, info, swatch] as [CALayer] { l.contentsScale = scale }
    }

    func update(image: CGImage, pixelX px: Int, pixelY py: Int) {
        let n = Self.cells, half = n / 2
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var color: RGBA?
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            ctx.interpolationQuality = .none
            let wanted = CGRect(x: px - half, y: py - half, width: n, height: n)
            let actual = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !actual.isNull, let region = image.cropping(to: actual) {
                // Bitmap contexts are y-up; image rows are y-down.
                let dx = actual.minX - wanted.minX
                let dyTop = actual.minY - wanted.minY
                ctx.draw(region, in: CGRect(x: dx, y: CGFloat(n) - dyTop - actual.height, width: actual.width, height: actual.height))
            }
            zoom.contents = ctx.makeImage()
            let p = raw.bindMemory(to: UInt8.self)
            let i = (half * n + half) * 4
            color = RGBA(r: CGFloat(p[i]) / 255, g: CGFloat(p[i + 1]) / 255, b: CGFloat(p[i + 2]) / 255)
        }
        guard let color else { return }
        info.setText("\(color.hex)   \(px), \(py)", font: .monospacedSystemFont(ofSize: 11, weight: .medium))
        let infoSize = info.bounds.size
        info.position = CGPoint(x: bounds.midX + 9, y: 14)
        swatch.backgroundColor = color.cgColor
        swatch.frame = CGRect(x: bounds.midX - infoSize.width / 2 - 13, y: 6, width: 16, height: 16)
    }
}

#if DEBUG
extension SelectionOverlayController {
    /// Headless check: clicking each chip flips its setting and never starts a selection drag.
    static func debugToggleCheck() -> String {
        guard let screen = NSScreen.main else { return "no screen" }
        let view = OverlayView(screen: screen, shot: nil, windows: [], purpose: .record)
        let settings = AppSettings.shared
        view.pointerMoved(toGlobal: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        var results: [String] = []
        for option in RecordOptionsLayer.Option.allCases {
            let name = option == .microphone ? "mic" : "desktop"
            func value() -> Bool { option == .microphone ? settings.recordMicrophone : settings.recordSystemAudio }
            let before = value()
            guard view.debugClickOption(option) else {
                results.append("\(name) NOT HITTABLE")
                continue
            }
            results.append("\(name) \(value() != before ? "ok" : "FAILED")")
        }
        results.append(view.debugSelectionArmed ? "drag leak FAILED" : "no drag leak ok")
        return results.joined(separator: ", ")
    }

    /// Renders an overlay offscreen with a simulated pointer/selection (no real screen involved).
    static func debugRender(screen: NSScreen, frozen: CGImage, mouse: CGPoint, dragTo: CGPoint?, windows: [WindowInfo],
                            purpose: SelectionPurpose = .screenshot) -> CGImage? {
        let shot = DisplayShot(displayID: screen.displayID ?? 0, image: frozen, scale: screen.backingScaleFactor)
        let view = OverlayView(screen: screen, shot: shot, windows: windows, purpose: purpose)
        let global = CGPoint(x: mouse.x + screen.frame.minX, y: mouse.y + screen.frame.minY)
        view.pointerMoved(toGlobal: global)
        if let dragTo { view.debugDrag(from: mouse, to: dragTo) }
        guard let layer = view.layer else { return nil }
        let scale = screen.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBColorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}

extension OverlayView {
    /// Clicks an audio toggle on the recording overlay, as the real mouse would.
    @discardableResult
    func debugClickOption(_ option: RecordOptionsLayer.Option) -> Bool {
        let point = debugOptionCenter(option)
        guard let point else { return false }
        debugMouseDown(at: point)
        return true
    }

    func debugDrag(from start: CGPoint, to end: CGPoint) {
        dragStartForDebug(start)
        selectionForDebug(CGRect(p1: start, p2: end))
    }
}
#endif
