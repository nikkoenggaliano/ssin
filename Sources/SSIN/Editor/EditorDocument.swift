import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins

/// The editable screenshot: original pixels + annotations + crop + background, with undo.
@MainActor
final class EditorDocument: ObservableObject {
    let image: CGImage
    /// Pixels per point of the capture (2 on Retina). Sizes in the UI are in points.
    let pixelScale: CGFloat
    let imageSize: CGSize
    let createdAt = Date()
    let undoManager = UndoManager()
    let status = EditorStatus()

    @Published private(set) var state: DocState
    @Published private(set) var tool: Tool = .arrow
    @Published var selectedID: UUID?
    @Published var style: ToolStyle { didSet { style.save() } }
    @Published var beautifyPanel = false
    @Published var cropDraft: CGRect?

    /// Called before the tool changes so the canvas can finish inline text editing.
    var willChangeTool: (() -> Void)?

    private var gestureStart: DocState?
    private var lastCoalesce: (key: String, time: Date)?
    private var toolBeforeCrop: Tool = .arrow

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private lazy var luma = LumaMap(image: image)
    private var blurredFull: CGImage?
    private var pixelatedFull: CGImage?
    private var proxies: [Int: Proxy] = [:]

    private struct Proxy {
        let base: CGImage
        var blurred: CGImage?
        var pixelated: CGImage?
    }

    init(image: CGImage, pixelScale: CGFloat) {
        self.image = image
        self.pixelScale = max(1, pixelScale)
        imageSize = image.size
        var initial = DocState()
        initial.background = BackgroundStyle.load()
        state = initial
        style = ToolStyle.load()
        undoManager.groupsByEvent = true
    }

    // MARK: Lookup

    var fullRect: CGRect { CGRect(origin: .zero, size: imageSize) }
    var effectiveCrop: CGRect { state.crop ?? fullRect }
    var selected: Annotation? { selectedID.flatMap { id in state.annotations.first { $0.id == id } } }
    func annotation(_ id: UUID) -> Annotation? { state.annotations.first { $0.id == id } }

    /// The kind whose properties the inspector shows: the selection, else the active tool.
    var inspectorKind: AnnotationKind? { selected?.kind ?? tool.kind }

    var isPristine: Bool { state.annotations.isEmpty && state.crop == nil && !state.background.enabled }

    func layout(cropEditing: Bool) -> DocLayout {
        if cropEditing {
            return DocLayout(imageSize: imageSize, crop: fullRect, background: nil, pixelScale: pixelScale)
        }
        return DocLayout(imageSize: imageSize, crop: effectiveCrop,
                         background: state.background.enabled ? state.background : nil, pixelScale: pixelScale)
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat, generous: Bool) -> Annotation? {
        state.annotations.reversed().first { Renderer.hitTest($0, at: p, tolerance: tolerance, generous: generous) }
    }

    // MARK: Undo-aware mutations

    /// Starts a drag; live changes made until `endGesture` become one undo step.
    func beginGesture() { gestureStart = state }

    func live(_ change: (inout DocState) -> Void) { change(&state) }

    func endGesture(_ name: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        guard start != state else { return }
        registerUndo(restoring: start, name: name)
    }

    func cancelGesture() {
        if let start = gestureStart { state = start }
        gestureStart = nil
    }

    /// A single change. Changes sharing a coalesce key within a second merge into one undo step (slider drags).
    func perform(_ name: String, coalesce key: String? = nil, _ change: (inout DocState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        let now = Date()
        let merge = key != nil && lastCoalesce?.key == key && now.timeIntervalSince(lastCoalesce!.time) < 1
        if !merge { registerUndo(restoring: state, name: name) }
        lastCoalesce = key.map { ($0, now) }
        state = next
    }

    private func registerUndo(restoring old: DocState, name: String) {
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.restore(old, name: name) }
        }
        undoManager.setActionName(name)
        lastCoalesce = nil
    }

    private func restore(_ old: DocState, name: String) {
        registerUndo(restoring: state, name: name)
        state = old
        if let id = selectedID, old.index(of: id) == nil { selectedID = nil }
    }

    // MARK: Tools

    func selectTool(_ t: Tool) {
        guard t != tool else { return }
        willChangeTool?()
        if t == .crop {
            toolBeforeCrop = tool
            cropDraft = effectiveCrop
            selectedID = nil
        } else {
            cropDraft = nil
        }
        if t != .select { selectedID = nil }
        beautifyPanel = false
        tool = t
    }

    func makeAnnotation(_ kind: AnnotationKind, at p: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, start: p, end: p,
                           color: kind == .highlight ? style.highlightColor : style.color,
                           width: style.strokeWidth * pixelScale)
        a.fill = style.fill
        a.textStyle = style.textStyle
        a.fontSize = (kind == .counter ? style.counterSize : style.fontSize) * pixelScale
        a.blurStyle = style.blurStyle
        a.shadow = style.shadow
        if kind == .counter {
            a.number = (state.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
        }
        if kind == .pen { a.points = [p] }
        return a
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        perform("Delete") { $0.annotations.removeAll { $0.id == id } }
        selectedID = nil
    }

    func nudgeSelected(by d: CGPoint) {
        guard let id = selectedID else { return }
        perform("Move", coalesce: "nudge-\(id)") { s in
            if let i = s.index(of: id) { s.annotations[i].translate(by: d) }
        }
    }

    func bringSelectedToFront() {
        guard let id = selectedID else { return }
        perform("Bring to Front") { s in
            if let i = s.index(of: id) { s.annotations.append(s.annotations.remove(at: i)) }
        }
    }

    private func updateSelected(_ key: String, _ change: (inout Annotation) -> Void) {
        guard let id = selectedID else { return }
        perform("Change Style", coalesce: "\(key)-\(id)") { s in
            if let i = s.index(of: id) { change(&s.annotations[i]) }
        }
    }

    // MARK: Style (applies to the selection and to new annotations)

    var currentColor: RGBA {
        if let s = selected { return s.color }
        return tool == .highlight ? style.highlightColor : style.color
    }

    func setColor(_ c: RGBA) {
        if (selected?.kind ?? tool.kind) == .highlight { style.highlightColor = c } else { style.color = c }
        updateSelected("color") { $0.color = c }
    }

    var currentStrokeWidth: CGFloat { selected.map { $0.width / pixelScale } ?? style.strokeWidth }

    func setStrokeWidth(_ w: CGFloat) {
        style.strokeWidth = w
        updateSelected("width") { $0.width = w * self.pixelScale }
    }

    var currentFill: FillStyle { selected?.fill ?? style.fill }

    func setFill(_ f: FillStyle) {
        style.fill = f
        updateSelected("fill") { $0.fill = f }
    }

    var currentTextStyle: TextStyle { selected?.textStyle ?? style.textStyle }

    func setTextStyle(_ t: TextStyle) {
        style.textStyle = t
        updateSelected("textStyle") { $0.textStyle = t }
    }

    var currentFontSize: CGFloat {
        if let s = selected { return s.fontSize / pixelScale }
        return tool == .counter ? style.counterSize : style.fontSize
    }

    func setFontSize(_ size: CGFloat) {
        if (selected?.kind ?? tool.kind) == .counter { style.counterSize = size } else { style.fontSize = size }
        updateSelected("fontSize") { $0.fontSize = size * self.pixelScale }
    }

    var currentBlurStyle: BlurStyle { selected?.blurStyle ?? style.blurStyle }

    func setBlurStyle(_ b: BlurStyle) {
        style.blurStyle = b
        updateSelected("blurStyle") { $0.blurStyle = b }
    }

    var currentShadow: Bool { selected?.shadow ?? style.shadow }

    func setShadow(_ on: Bool) {
        style.shadow = on
        updateSelected("shadow") { $0.shadow = on }
    }

    // MARK: Crop

    func applyCrop() {
        guard let draft = cropDraft else { return }
        let r = CGRect(x: draft.minX.rounded(), y: draft.minY.rounded(),
                       width: draft.width.rounded(), height: draft.height.rounded()).intersection(fullRect)
        perform("Crop") { s in
            s.crop = (r.isNull || r.width < 2 || r.height < 2 || r == fullRect) ? nil : r
        }
        cropDraft = nil
        selectTool(toolBeforeCrop == .crop ? .arrow : toolBeforeCrop)
    }

    func cancelCrop() {
        cropDraft = nil
        selectTool(toolBeforeCrop == .crop ? .arrow : toolBeforeCrop)
    }

    func resetCropDraft() { cropDraft = fullRect }

    // MARK: Background

    func toggleBeautify() {
        if !state.background.enabled {
            perform("Background") { $0.background.enabled = true }
            beautifyPanel = true
        } else if !beautifyPanel {
            beautifyPanel = true
        } else {
            perform("Background") { $0.background.enabled = false }
            beautifyPanel = false
        }
    }

    func updateBackground(_ key: String, _ change: (inout BackgroundStyle) -> Void) {
        perform("Background", coalesce: "bg-\(key)") { s in
            change(&s.background)
            s.background.enabled = true
        }
        state.background.save()
    }

    // MARK: Pixels

    func color(at p: CGPoint) -> RGBA? {
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        let a = CGFloat(bytes[3]) / 255
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        return RGBA(r: min(1, CGFloat(bytes[0]) / 255 / a), g: min(1, CGFloat(bytes[1]) / 255 / a),
                    b: min(1, CGFloat(bytes[2]) / 255 / a), a: a)
    }

    // MARK: Render sources

    var fullSources: RenderSources {
        RenderSources(base: image,
                      blurred: { [unowned self] in self.blurredImage() },
                      pixelated: { [unowned self] in self.pixelatedImage() },
                      luma: luma)
    }

    /// Sources sized for the given device-pixels-per-image-pixel factor, so huge captures stay fast on screen.
    func sources(deviceScale f: CGFloat) -> RenderSources {
        guard f > 0, f < 0.7 else { return fullSources }
        let level = min(4, Int(floor(log2(1 / f))))
        guard level >= 1 else { return fullSources }
        let factor = pow(0.5, CGFloat(level))
        if proxies[level] == nil, let base = image.downscaled(by: factor) {
            proxies[level] = Proxy(base: base)
        }
        guard let proxy = proxies[level] else { return fullSources }
        return RenderSources(base: proxy.base,
                             blurred: { [unowned self] in self.proxyVariant(level: level, factor: factor, blurred: true) },
                             pixelated: { [unowned self] in self.proxyVariant(level: level, factor: factor, blurred: false) },
                             luma: luma)
    }

    private func proxyVariant(level: Int, factor: CGFloat, blurred: Bool) -> CGImage? {
        if let cached = blurred ? proxies[level]?.blurred : proxies[level]?.pixelated { return cached }
        guard let full = blurred ? blurredImage() : pixelatedImage(), let scaled = full.downscaled(by: factor) else { return nil }
        if blurred { proxies[level]?.blurred = scaled } else { proxies[level]?.pixelated = scaled }
        return scaled
    }

    private func blurredImage() -> CGImage? {
        if let blurredFull { return blurredFull }
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: Double(8 * pixelScale)).cropped(to: input.extent)
        blurredFull = Self.ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: sRGBColorSpace)
        return blurredFull
    }

    private func pixelatedImage() -> CGImage? {
        if let pixelatedFull { return pixelatedFull }
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(8, 10 * pixelScale))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        pixelatedFull = Self.ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: sRGBColorSpace)
        return pixelatedFull
    }

    // MARK: Export

    /// The final image at full native resolution.
    func renderFinal() -> CGImage? {
        if isPristine { return image }
        let layout = self.layout(cropEditing: false)
        let w = Int(layout.size.width.rounded()), h = Int(layout.size.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        Renderer.drawDocument(in: ctx, state: state, layout: layout, sources: fullSources)
        return ctx.makeImage()
    }

    /// Cropped original pixels (no annotations), used for OCR.
    func croppedOriginal() -> CGImage {
        image.cropping(to: effectiveCrop) ?? image
    }

    var outputPixelSize: CGSize { layout(cropEditing: false).size }
}
