import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The drawing surface: renders the document and turns mouse/keyboard input into edits.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let doc: EditorDocument

    /// View points per document unit (image pixel).
    private(set) var scale: CGFloat = 1
    private var fitMode = true
    private var pan = CGPoint.zero
    var insets = NSEdgeInsets(top: 22, left: 28, bottom: 86, right: 28)

    private enum Handle: Equatable {
        case start, end
        case corner(Int)      // 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
        case cropHandle(Int)  // 0...7 clockwise from top-left
    }

    private enum Drag {
        case none
        case create(UUID)
        case move(UUID, last: CGPoint)
        case handle(UUID, Handle)
        case cropNew(start: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(Int)
    }

    private var drag: Drag = .none
    /// While dragging an annotation we invalidate only the area it touches instead of the whole canvas.
    private var partialRedraw = false
    private var mouseDownPoint = CGPoint.zero
    private var didDrag = false

    private var textField: InlineTextField?
    private var editingID: UUID?
    private var editingIsNew = false

    private var cancellables = Set<AnyCancellable>()
    private lazy var checkerColor: NSColor = Self.makeCheckerColor()

    init(doc: EditorDocument) {
        self.doc = doc
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        doc.objectWillChange
            .sink { [weak self] _ in
                guard let self, !self.partialRedraw else { return }
                self.needsDisplay = true
                DispatchQueue.main.async { self.documentDidChange() }
            }
            .store(in: &cancellables)
        doc.willChangeTool = { [weak self] in self?.endTextEditing() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func documentDidChange() {
        if fitMode { needsLayout = true }
        if editingID != nil { styleTextField() }
        needsDisplay = true
    }

    // MARK: Geometry

    private var currentLayout: DocLayout { doc.layout(cropEditing: doc.tool == .crop) }

    private var availableRect: CGRect {
        CGRect(x: insets.left, y: insets.top,
               width: max(1, bounds.width - insets.left - insets.right),
               height: max(1, bounds.height - insets.top - insets.bottom))
    }

    private func fitScale(for size: CGSize) -> CGFloat {
        let a = availableRect
        // Never upscale past the capture's real size (100%).
        return max(0.01, min(a.width / size.width, a.height / size.height, 1 / doc.pixelScale))
    }

    /// The document's rectangle in view coordinates (updates the scale when fitting).
    private func docRect(for layout: DocLayout) -> CGRect {
        if fitMode {
            scale = fitScale(for: layout.size)
            pan = .zero
        }
        let w = layout.size.width * scale, h = layout.size.height * scale
        let a = availableRect
        return CGRect(x: (a.midX - w / 2 + pan.x).rounded(), y: (a.midY - h / 2 + pan.y).rounded(), width: w, height: h)
    }

    private func viewToImage(_ p: CGPoint) -> CGPoint {
        let layout = currentLayout
        let r = docRect(for: layout)
        return layout.docToImage(CGPoint(x: (p.x - r.minX) / scale, y: (p.y - r.minY) / scale))
    }

    private func imageToView(_ p: CGPoint) -> CGPoint {
        let layout = currentLayout
        let r = docRect(for: layout)
        let d = layout.imageToDoc(p)
        return CGPoint(x: r.minX + d.x * scale, y: r.minY + d.y * scale)
    }

    private func imageRectToView(_ rect: CGRect) -> CGRect {
        CGRect(p1: imageToView(CGPoint(x: rect.minX, y: rect.minY)), p2: imageToView(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    /// Hit tolerance in image pixels for ~6 view points.
    private var tolerance: CGFloat { 6 / scale }

    override func layout() {
        super.layout()
        _ = docRect(for: currentLayout)
        clampPan()
        reportZoom()
        if editingID != nil { positionTextField() }
    }

    private func reportZoom() {
        let percent = Int((scale * doc.pixelScale * 100).rounded())
        if doc.status.zoomPercent != percent { doc.status.zoomPercent = percent }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let layout = currentLayout
        let r = docRect(for: layout)

        ctx.setFillColor(NSColor(white: 0.085, alpha: 1).cgColor)
        ctx.fill(bounds)

        // Soft drop shadow behind the document.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: CGColor(gray: 0, alpha: 0.55))
        ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
        ctx.fill(r)
        ctx.restoreGState()

        // Checkerboard shows through transparent areas.
        ctx.saveGState()
        ctx.clip(to: r)
        checkerColor.setFill()
        NSGraphicsContext.current?.patternPhase = r.origin
        r.fill()
        ctx.restoreGState()

        let backing = window?.backingScaleFactor ?? 2
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = scale * backing >= 2 ? .none : .high
        Renderer.drawDocument(in: ctx, state: doc.state, layout: layout,
                              sources: doc.sources(deviceScale: scale * backing), hiddenID: editingID)
        ctx.restoreGState()

        if doc.tool == .crop {
            drawCropOverlay(ctx, docRect: r)
        } else {
            drawSelection(ctx)
        }
    }

    private static func makeCheckerColor() -> NSColor {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(white: 0.24, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.19, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: size / 2, height: size / 2).fill()
            NSRect(x: size / 2, y: size / 2, width: size / 2, height: size / 2).fill()
            return true
        }
        return NSColor(patternImage: image)
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let a = doc.selected, a.id != editingID else { return }
        let accent = NSColor.controlAccentColor.cgColor
        let handles = handlePoints(for: a)
        if handles.isEmpty || a.kind == .text || a.kind == .pen || a.kind == .counter {
            let box = imageRectToView(Renderer.bounds(of: a)).insetBy(dx: -5, dy: -5)
            ctx.saveGState()
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        } else if a.kind != .arrow && a.kind != .line {
            ctx.saveGState()
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1)
            ctx.stroke(imageRectToView(a.rect).insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
        }
        for (_, p) in handles { drawHandle(ctx, at: imageToView(p)) }
    }

    private func drawHandle(_ ctx: CGContext, at p: CGPoint, radius: CGFloat = 5) {
        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
    }

    private func drawCropOverlay(_ ctx: CGContext, docRect: CGRect) {
        guard let draft = doc.cropDraft else { return }
        let v = imageRectToView(draft)
        ctx.saveGState()
        let dim = CGMutablePath()
        dim.addRect(docRect)
        dim.addRect(v)
        ctx.addPath(dim)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(1)
        for i in 1...2 {
            let x = v.minX + v.width * CGFloat(i) / 3, y = v.minY + v.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: v.minY)); ctx.addLine(to: CGPoint(x: x, y: v.maxY))
            ctx.move(to: CGPoint(x: v.minX, y: y)); ctx.addLine(to: CGPoint(x: v.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.stroke(v)

        // Thick L-shaped corners and edge bars.
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        let l = min(18, v.width / 3, v.height / 3)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: v.minX, y: v.minY), 1, 1), (CGPoint(x: v.maxX, y: v.minY), -1, 1),
            (CGPoint(x: v.maxX, y: v.maxY), -1, -1), (CGPoint(x: v.minX, y: v.maxY), 1, -1),
        ]
        for (p, sx, sy) in corners {
            ctx.move(to: CGPoint(x: p.x + l * sx, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y + l * sy))
        }
        ctx.move(to: CGPoint(x: v.midX - l / 2, y: v.minY)); ctx.addLine(to: CGPoint(x: v.midX + l / 2, y: v.minY))
        ctx.move(to: CGPoint(x: v.midX - l / 2, y: v.maxY)); ctx.addLine(to: CGPoint(x: v.midX + l / 2, y: v.maxY))
        ctx.move(to: CGPoint(x: v.minX, y: v.midY - l / 2)); ctx.addLine(to: CGPoint(x: v.minX, y: v.midY + l / 2))
        ctx.move(to: CGPoint(x: v.maxX, y: v.midY - l / 2)); ctx.addLine(to: CGPoint(x: v.maxX, y: v.midY + l / 2))
        ctx.strokePath()
        ctx.restoreGState()

        let label = "\(Int(draft.width.rounded())) × \(Int(draft.height.rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        var box = CGRect(x: v.midX - size.width / 2 - 8, y: v.minY - size.height - 14, width: size.width + 16, height: size.height + 6)
        if box.minY < 4 { box.origin.y = v.minY + 8 }
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        label.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attrs)
    }

    // MARK: Handles

    private func handlePoints(for a: Annotation) -> [(Handle, CGPoint)] {
        switch a.kind {
        case .arrow, .line:
            return [(.start, a.start), (.end, a.end)]
        case .rect, .ellipse, .highlight, .blur, .spotlight:
            let r = a.rect
            return [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                    (.corner(2), CGPoint(x: r.maxX, y: r.maxY)), (.corner(3), CGPoint(x: r.minX, y: r.maxY))]
        default:
            return []
        }
    }

    private func handle(at viewPoint: CGPoint, of a: Annotation) -> Handle? {
        handlePoints(for: a).first { imageToView($0.1).distance(to: viewPoint) <= 9 }?.0
    }

    private func cropHandlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func cropHandle(at viewPoint: CGPoint) -> Int? {
        guard let draft = doc.cropDraft else { return nil }
        return cropHandlePoints(draft).firstIndex { imageToView($0).distance(to: viewPoint) <= 12 }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        let ip = viewToImage(vp)
        mouseDownPoint = vp
        didDrag = false
        drag = .none

        if doc.tool == .crop {
            cropMouseDown(vp, ip, clickCount: event.clickCount)
            return
        }

        if let sel = doc.selected, let h = handle(at: vp, of: sel) {
            doc.beginGesture()
            drag = .handle(sel.id, h)
            return
        }

        if let hit = doc.hitTest(ip, tolerance: tolerance, generous: doc.tool == .select) {
            if event.clickCount >= 2 && hit.kind == .text {
                beginTextEditing(hit.id, isNew: false)
                return
            }
            doc.selectedID = hit.id
            doc.beginGesture()
            drag = .move(hit.id, last: ip)
            return
        }

        doc.selectedID = nil
        guard let kind = doc.tool.kind else { return }
        let a = doc.makeAnnotation(kind, at: ip)
        doc.beginGesture()
        doc.live { $0.annotations.append(a) }
        switch kind {
        case .text:
            beginTextEditing(a.id, isNew: true)
        case .counter:
            drag = .move(a.id, last: ip)
        default:
            drag = .create(a.id)
        }
    }

    /// View-space area an annotation covers, including shadow and selection handles.
    private func dirtyRect(for id: UUID) -> CGRect {
        guard let a = doc.annotation(id) else { return .null }
        let margin = 16 * doc.pixelScale * scale + a.width * scale + 14
        return imageRectToView(Renderer.bounds(of: a)).insetBy(dx: -margin, dy: -margin)
    }

    private var draggedID: UUID? {
        switch drag {
        case .create(let id), .move(let id, _), .handle(let id, _): id
        default: nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let draggedBefore = draggedID.map(dirtyRect(for:))
        partialRedraw = draggedBefore != nil
        defer {
            if let before = draggedBefore, let id = draggedID {
                setNeedsDisplay(before.union(dirtyRect(for: id)))
            }
            partialRedraw = false
        }
        let vp = convert(event.locationInWindow, from: nil)
        if vp.distance(to: mouseDownPoint) > 2 { didDrag = true }
        let ip = viewToImage(vp)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .none:
            break
        case .create(let id):
            doc.live { s in
                guard let i = s.index(of: id) else { return }
                switch s.annotations[i].kind {
                case .pen:
                    if let last = s.annotations[i].points.last, last.distance(to: ip) * self.scale >= 1.5 {
                        s.annotations[i].points.append(ip)
                    }
                case .arrow, .line:
                    s.annotations[i].end = shift ? Geometry.snapAngle(from: s.annotations[i].start, to: ip) : ip
                default:
                    s.annotations[i].end = shift ? Geometry.squareEnd(from: s.annotations[i].start, to: ip) : ip
                }
            }
        case .move(let id, let last):
            let d = ip - last
            doc.live { s in
                if let i = s.index(of: id) { s.annotations[i].translate(by: d) }
            }
            drag = .move(id, last: ip)
        case .handle(let id, let h):
            doc.live { s in
                guard let i = s.index(of: id) else { return }
                var a = s.annotations[i]
                switch h {
                case .start:
                    a.start = shift ? Geometry.snapAngle(from: a.end, to: ip) : ip
                case .end:
                    a.end = shift ? Geometry.snapAngle(from: a.start, to: ip) : ip
                case .corner(let c):
                    let r = a.rect
                    let opposite = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                                    CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][c]
                    a.start = opposite
                    a.end = shift ? Geometry.squareEnd(from: opposite, to: ip) : ip
                    // Keep the handle index stable while dragging through the opposite corner.
                    let nr = a.rect
                    let corners = [CGPoint(x: nr.minX, y: nr.minY), CGPoint(x: nr.maxX, y: nr.minY),
                                   CGPoint(x: nr.maxX, y: nr.maxY), CGPoint(x: nr.minX, y: nr.maxY)]
                    if let nc = corners.firstIndex(where: { $0.distance(to: a.end) < 0.001 }), nc != c {
                        self.drag = .handle(id, .corner(nc))
                    }
                case .cropHandle:
                    break
                }
                s.annotations[i] = a
            }
        case .cropNew(let start):
            doc.cropDraft = CGRect(p1: clampToImage(start), p2: clampToImage(shift ? Geometry.squareEnd(from: start, to: ip) : ip))
        case .cropMove(let last):
            guard var r = doc.cropDraft else { return }
            r.origin = r.origin + (ip - last)
            r.origin.x = min(max(r.origin.x, 0), doc.imageSize.width - r.width)
            r.origin.y = min(max(r.origin.y, 0), doc.imageSize.height - r.height)
            doc.cropDraft = r
            drag = .cropMove(last: ip)
        case .cropResize(let index):
            guard let r = doc.cropDraft else { return }
            let p = clampToImage(ip)
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            if [0, 6, 7].contains(index) { minX = p.x }
            if [2, 3, 4].contains(index) { maxX = p.x }
            if [0, 1, 2].contains(index) { minY = p.y }
            if [4, 5, 6].contains(index) { maxY = p.y }
            doc.cropDraft = CGRect(p1: CGPoint(x: minX, y: minY), p2: CGPoint(x: maxX, y: maxY))
        }
        updateCursor(at: vp)
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .create(let id):
            if !didDrag {
                doc.cancelGesture()
            } else {
                let kind = doc.annotation(id)?.kind
                doc.endGesture("Add \(kind?.title ?? "Annotation")")
                doc.selectedID = id
            }
        case .move(let id, _):
            let kind = doc.annotation(id)?.kind
            doc.endGesture(kind == .counter && !didDrag ? "Add Step" : "Move")
        case .handle:
            doc.endGesture("Resize")
        case .cropNew:
            if let r = doc.cropDraft, r.width < 4 || r.height < 4 { doc.resetCropDraft() }
        case .none, .cropMove, .cropResize:
            break
        }
        drag = .none
    }

    private func cropMouseDown(_ vp: CGPoint, _ ip: CGPoint, clickCount: Int) {
        guard let draft = doc.cropDraft else { return }
        if clickCount >= 2 && draft.contains(ip) {
            doc.applyCrop()
            return
        }
        // While the draft still covers the whole image, dragging anywhere draws a new crop.
        let coversImage = draft.width >= doc.imageSize.width - 1 && draft.height >= doc.imageSize.height - 1
        if let index = cropHandle(at: vp) {
            drag = .cropResize(index)
        } else if draft.contains(ip) && !coversImage {
            drag = .cropMove(last: ip)
        } else {
            drag = .cropNew(start: ip)
        }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), doc.imageSize.width), y: min(max(p.y, 0), doc.imageSize.height))
    }

    // MARK: Hover, cursor, pixel color

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        let ip = viewToImage(vp)
        let visible = doc.tool == .crop ? doc.fullRect : doc.effectiveCrop
        doc.status.hoverColor = visible.contains(ip) ? doc.color(at: ip) : nil
        updateCursor(at: vp)
    }

    override func mouseExited(with event: NSEvent) {
        doc.status.hoverColor = nil
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at vp: CGPoint) {
        let cursor: NSCursor
        if doc.tool == .crop {
            if let index = cropHandle(at: vp) {
                cursor = [1, 5].contains(index) ? .resizeUpDown : [3, 7].contains(index) ? .resizeLeftRight : .crosshair
            } else if let d = doc.cropDraft, d.contains(viewToImage(vp)) {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        } else if case .move = drag {
            cursor = .closedHand
        } else if let sel = doc.selected, handle(at: vp, of: sel) != nil {
            cursor = .crosshair
        } else if doc.hitTest(viewToImage(vp), tolerance: tolerance, generous: doc.tool == .select) != nil {
            cursor = .openHand
        } else if doc.tool == .select {
            cursor = .arrow
        } else if doc.tool == .text {
            cursor = .iBeam
        } else {
            cursor = .crosshair
        }
        cursor.set()
    }

    func copyHoverColor() {
        guard let color = doc.status.hoverColor else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(color.hex, forType: .string)
        Toast.show("Copied \(color.hex)", symbol: "eyedropper", tint: Color(nsColor: color.nsColor))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = (shift ? 10 : 1) * doc.pixelScale
        switch Int(event.keyCode) {
        case kVK_Escape:
            if doc.tool == .crop { doc.cancelCrop() }
            else if doc.beautifyPanel { doc.beautifyPanel = false }
            else if doc.selectedID != nil { doc.selectedID = nil }
            else { window?.performClose(nil) }
            return
        case kVK_Delete, kVK_ForwardDelete:
            if doc.selectedID != nil { doc.deleteSelected(); return }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if doc.tool == .crop { doc.applyCrop(); return }
            if let s = doc.selected, s.kind == .text { beginTextEditing(s.id, isNew: false); return }
        case kVK_Tab:
            copyHoverColor()
            return
        case kVK_LeftArrow where doc.selectedID != nil: doc.nudgeSelected(by: CGPoint(x: -step, y: 0)); return
        case kVK_RightArrow where doc.selectedID != nil: doc.nudgeSelected(by: CGPoint(x: step, y: 0)); return
        case kVK_UpArrow where doc.selectedID != nil: doc.nudgeSelected(by: CGPoint(x: 0, y: -step)); return
        case kVK_DownArrow where doc.selectedID != nil: doc.nudgeSelected(by: CGPoint(x: 0, y: step)); return
        default:
            break
        }
        if flags.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased(), let c = chars.first {
            if let tool = Tool.forShortcut(c) {
                doc.selectTool(tool)
                return
            }
            if let n = c.wholeNumberValue, (1...RGBA.palette.count).contains(n) {
                doc.setColor(RGBA.palette[n - 1])
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Zoom & pan

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if fitMode { zoomTo(percent: 200, around: convert(event.locationInWindow, from: nil)) } else { zoomToFit() }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: 1 + delta, around: convert(event.locationInWindow, from: nil))
            return
        }
        guard !fitMode else { return }
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        clampPan()
        refreshAfterViewportChange()
    }

    func zoom(by factor: CGFloat, around p: CGPoint) {
        let layout = currentLayout
        let r = docRect(for: layout)
        let docPoint = CGPoint(x: (p.x - r.minX) / scale, y: (p.y - r.minY) / scale)
        let minScale = min(fitScale(for: layout.size), 0.05)
        let maxScale = 16 / doc.pixelScale
        scale = min(max(scale * factor, minScale), maxScale)
        fitMode = false
        let a = availableRect
        let w = layout.size.width * scale, h = layout.size.height * scale
        pan = CGPoint(x: p.x - docPoint.x * scale - (a.midX - w / 2), y: p.y - docPoint.y * scale - (a.midY - h / 2))
        clampPan()
        refreshAfterViewportChange()
    }

    func zoomTo(percent: CGFloat, around p: CGPoint? = nil) {
        let target = percent / 100 / doc.pixelScale
        zoom(by: target / scale, around: p ?? CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomToFit() {
        fitMode = true
        pan = .zero
        refreshAfterViewportChange()
    }

    private func clampPan() {
        let layout = currentLayout
        let a = availableRect
        let w = layout.size.width * scale, h = layout.size.height * scale
        let limitX = max(0, (w - a.width) / 2 + 40), limitY = max(0, (h - a.height) / 2 + 40)
        pan.x = w <= a.width ? 0 : min(max(pan.x, -limitX), limitX)
        pan.y = h <= a.height ? 0 : min(max(pan.y, -limitY), limitY)
    }

    private func refreshAfterViewportChange() {
        reportZoom()
        if editingID != nil { positionTextField() }
        needsDisplay = true
    }

    // MARK: Inline text editing

    func beginTextEditing(_ id: UUID, isNew: Bool) {
        guard let a = doc.annotation(id) else { return }
        if !isNew { doc.beginGesture() }
        editingID = id
        editingIsNew = isNew
        doc.selectedID = nil
        let field = InlineTextField(string: a.text)
        field.delegate = self
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.placeholderString = "Type…"
        textField = field
        addSubview(field)
        styleTextField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (a.text as NSString).length, length: 0)
        needsDisplay = true
    }

    private func styleTextField() {
        guard let field = textField, let id = editingID, let a = doc.annotation(id) else { return }
        field.font = TextLayout.font(size: max(6, a.fontSize * scale))
        field.textColor = (a.textStyle == .pill ? a.color.contrasting : a.color).nsColor
        field.drawsBackground = a.textStyle == .pill
        field.backgroundColor = a.color.nsColor
        if a.textStyle == .outlined {
            let shadow = NSShadow()
            shadow.shadowColor = a.color.contrasting.nsColor.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 2
            field.shadow = shadow
        } else {
            field.shadow = nil
        }
        positionTextField()
    }

    private func positionTextField() {
        guard let field = textField, let id = editingID, let a = doc.annotation(id) else { return }
        field.sizeToFit()
        var size = field.frame.size
        size.width = max(size.width + 12, 40)
        let origin = imageToView(Renderer.textFrame(a).glyphOrigin)
        field.frame = CGRect(x: origin.x - 2, y: origin.y - 1, width: size.width, height: size.height)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField, let id = editingID else { return }
        let text = field.stringValue
        doc.live { s in
            if let i = s.index(of: id) { s.annotations[i].text = text }
        }
        positionTextField()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    func endTextEditing() {
        guard let field = textField, let id = editingID else { return }
        let text = field.stringValue
        textField = nil
        editingID = nil
        field.delegate = nil
        field.removeFromSuperview()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.live { $0.annotations.removeAll { $0.id == id } }
            if editingIsNew { doc.cancelGesture() } else { doc.endGesture("Delete Text") }
        } else {
            doc.live { s in
                if let i = s.index(of: id) { s.annotations[i].text = text }
            }
            doc.endGesture(editingIsNew ? "Add Text" : "Edit Text")
            doc.selectedID = id
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

/// The text field used for typing annotations; it gets its own field editor (see EditorWindowController).
final class InlineTextField: NSTextField {}
