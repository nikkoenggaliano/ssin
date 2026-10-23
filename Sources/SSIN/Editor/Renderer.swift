import AppKit

/// Images the renderer draws from. The canvas passes downscaled proxies; export passes full resolution.
struct RenderSources {
    let base: CGImage
    let blurred: () -> CGImage?
    let pixelated: () -> CGImage?
    let luma: LumaMap?
}

/// Maps between image pixels and "document" space (the image plus any background padding). Both are y-down.
struct DocLayout {
    let imageSize: CGSize
    let crop: CGRect
    let background: BackgroundStyle?
    let pixelScale: CGFloat

    var padding: CGFloat {
        guard let background else { return 0 }
        return (background.padding * pixelScale).rounded()
    }

    var size: CGSize { CGSize(width: crop.width + padding * 2, height: crop.height + padding * 2) }
    var contentRect: CGRect { CGRect(x: padding, y: padding, width: crop.width, height: crop.height) }

    func imageToDoc(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - crop.minX + padding, y: p.y - crop.minY + padding) }
    func docToImage(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + crop.minX - padding, y: p.y + crop.minY - padding) }
}

/// Draws documents into any y-down CGContext. Used for both the live canvas and the full-resolution export,
/// so what you see is exactly what you get.
enum Renderer {
    // MARK: Document

    static func drawDocument(in ctx: CGContext, state: DocState, layout: DocLayout, sources: RenderSources, hiddenID: UUID? = nil) {
        let content = layout.contentRect
        let ps = layout.pixelScale
        ctx.saveGState()
        if let bg = layout.background {
            drawBackground(bg, in: ctx, size: layout.size)
            let radius = max(0, min(bg.cornerRadius * ps, content.width / 2, content.height / 2))
            let shape = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if bg.shadow > 0.01 {
                ctx.saveGState()
                // Clip to the outside of the shape so only the shadow shows (works for transparent windows too).
                ctx.addRect(CGRect(origin: .zero, size: layout.size).insetBy(dx: -2, dy: -2))
                ctx.addPath(shape)
                ctx.clip(using: .evenOdd)
                let k = deviceScale(ctx)
                ctx.setShadow(offset: CGSize(width: 0, height: -16 * ps * bg.shadow * k),
                              blur: 40 * ps * bg.shadow * k,
                              color: CGColor(gray: 0, alpha: 0.25 + 0.3 * bg.shadow))
                ctx.addPath(shape)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.addPath(shape)
            ctx.clip()
        } else {
            ctx.clip(to: content)
        }
        ctx.translateBy(x: content.minX - layout.crop.minX, y: content.minY - layout.crop.minY)
        drawContent(in: ctx, state: state, imageSize: layout.imageSize, pixelScale: ps, sources: sources, hiddenID: hiddenID)
        ctx.restoreGState()
    }

    static func drawBackground(_ bg: BackgroundStyle, in ctx: CGContext, size: CGSize) {
        let colors = bg.preset.colors
        guard !colors.isEmpty else { return }
        let rect = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        ctx.clip(to: rect)
        if colors.count == 1 {
            ctx.setFillColor(colors[0].cgColor)
            ctx.fill(rect)
        } else if let gradient = CGGradient(colorsSpace: sRGBColorSpace, colors: colors.map(\.cgColor) as CFArray, locations: nil) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // A soft light from the top-left adds depth.
        if let glow = CGGradient(colorsSpace: sRGBColorSpace,
                                 colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
                                 locations: [0, 1]) {
            let center = CGPoint(x: size.width * 0.18, y: size.height * 0.05)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: max(size.width, size.height) * 0.8, options: [])
        }
        ctx.restoreGState()
    }

    /// Draws the image and annotations in image coordinates.
    static func drawContent(in ctx: CGContext, state: DocState, imageSize: CGSize, pixelScale ps: CGFloat,
                            sources: RenderSources, hiddenID: UUID?) {
        let imageRect = CGRect(origin: .zero, size: imageSize)
        drawImage(sources.base, in: imageRect, ctx: ctx)
        let items = state.annotations.filter { $0.id != hiddenID }

        // Redactions sit directly on the pixels, then the spotlight dim, then highlights, then strokes on top.
        for a in items where a.kind == .blur { drawBlur(a, in: ctx, imageRect: imageRect, sources: sources, ps: ps) }
        let spots = items.filter { $0.kind == .spotlight }
        if !spots.isEmpty { drawSpotlights(spots, in: ctx, imageRect: imageRect, ps: ps) }
        for a in items where a.kind == .highlight { drawHighlight(a, in: ctx, sources: sources, ps: ps) }
        for a in items where ![.blur, .spotlight, .highlight].contains(a.kind) { drawAnnotation(a, in: ctx, ps: ps) }
    }

    /// Draws a CGImage right side up in a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Device pixels per user-space unit, used to keep blur radii resolution independent.
    static func deviceScale(_ ctx: CGContext) -> CGFloat {
        let m = ctx.ctm
        return max(0.0001, hypot(m.a, m.b))
    }

    // MARK: Annotations

    /// Shadows go on one primitive per annotation (no transparency layers), which keeps redraws cheap.
    static func drawAnnotation(_ a: Annotation, in ctx: CGContext, ps: CGFloat) {
        let shadow = a.shadow && a.kind.usesShadow
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .arrow:
            if shadow { applyShadow(ctx, ps: ps) }
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: a.width))
            ctx.setFillColor(a.color.cgColor)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width * 0.35)
            ctx.drawPath(using: .fillStroke)
        case .line:
            if shadow { applyShadow(ctx, ps: ps) }
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.strokePath()
        case .rect:
            let r = a.rect
            let radius = max(0, min(4 * ps, r.width / 2, r.height / 2))
            drawShape(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil), a, ctx, shadow: shadow, ps: ps)
        case .ellipse:
            drawShape(CGPath(ellipseIn: a.rect, transform: nil), a, ctx, shadow: shadow, ps: ps)
        case .pen:
            if shadow { applyShadow(ctx, ps: ps) }
            ctx.addPath(smoothPath(a.points))
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.strokePath()
        case .text:
            drawText(a, in: ctx, shadow: shadow, ps: ps)
        case .counter:
            drawCounter(a, in: ctx, shadow: shadow, ps: ps)
        case .highlight, .blur, .spotlight:
            break
        }
        ctx.restoreGState()
    }

    private static func applyShadow(_ ctx: CGContext, ps: CGFloat) {
        let k = deviceScale(ctx)
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * ps * k), blur: 6 * ps * k, color: CGColor(gray: 0, alpha: 0.38))
    }

    private static func clearShadow(_ ctx: CGContext) {
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private static func drawShape(_ path: CGPath, _ a: Annotation, _ ctx: CGContext, shadow: Bool, ps: CGFloat) {
        switch a.fill {
        case .outline:
            if shadow { applyShadow(ctx, ps: ps) }
            ctx.addPath(path)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.strokePath()
        case .tinted:
            ctx.addPath(path)
            ctx.setFillColor(a.color.opacity(0.22).cgColor)
            ctx.fillPath()
            if shadow { applyShadow(ctx, ps: ps) }
            ctx.addPath(path)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.strokePath()
        case .solid:
            if shadow { applyShadow(ctx, ps: ps) }
            ctx.addPath(path)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        }
    }

    /// A tapered arrow with swept-back barbs.
    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath {
        let dx = e.x - s.x, dy = e.y - s.y
        let length = max(hypot(dx, dy), 0.01)
        let headLength = min(max(w * 4.2, 10), length * 0.65)
        let headHalf = headLength * 0.56
        let neck = length - headLength * 0.78
        let tailHalf = w * 0.24
        let neckHalf = w * 0.62
        let points = [
            CGPoint(x: 0, y: -tailHalf),
            CGPoint(x: neck, y: -neckHalf),
            CGPoint(x: length - headLength, y: -headHalf),
            CGPoint(x: length, y: 0),
            CGPoint(x: length - headLength, y: headHalf),
            CGPoint(x: neck, y: neckHalf),
            CGPoint(x: 0, y: tailHalf),
        ]
        let transform = CGAffineTransform(translationX: s.x, y: s.y).rotated(by: atan2(dy, dx))
        let path = CGMutablePath()
        path.addLines(between: points, transform: transform)
        path.closeSubpath()
        return path
    }

    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first + CGPoint(x: 0.01, y: 0))
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func drawBlur(_ a: Annotation, in ctx: CGContext, imageRect: CGRect, sources: RenderSources, ps: CGFloat) {
        let r = a.rect.intersection(imageRect)
        guard !r.isNull, r.width > 0.5, r.height > 0.5,
              let source = a.blurStyle == .blur ? sources.blurred() : sources.pixelated()
        else { return }
        // Only touch the pixels under the region (the source may be a downscaled proxy).
        let sx = CGFloat(source.width) / imageRect.width, sy = CGFloat(source.height) / imageRect.height
        let sourceRect = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !sourceRect.isNull, let piece = source.cropping(to: sourceRect) else { return }
        ctx.saveGState()
        let radius = max(0, min(3 * ps, r.width / 2, r.height / 2))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        drawImage(piece, in: CGRect(x: sourceRect.minX / sx, y: sourceRect.minY / sy,
                                    width: sourceRect.width / sx, height: sourceRect.height / sy), ctx: ctx)
        ctx.restoreGState()
    }

    private static func drawSpotlights(_ spots: [Annotation], in ctx: CGContext, imageRect: CGRect, ps: CGFloat) {
        var holes: CGPath?
        for spot in spots {
            let r = spot.rect
            guard r.width > 0.5, r.height > 0.5 else { continue }
            let radius = max(0, min(8 * ps, r.width / 2, r.height / 2))
            let hole = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            holes = holes.map { $0.union(hole) } ?? hole
        }
        var dim = CGPath(rect: imageRect, transform: nil)
        if let holes { dim = dim.subtracting(holes) }
        ctx.saveGState()
        ctx.addPath(dim)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.58))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawHighlight(_ a: Annotation, in ctx: CGContext, sources: RenderSources, ps: CGFloat) {
        let r = a.rect
        guard r.width > 0.5, r.height > 0.5 else { return }
        ctx.saveGState()
        // Marker-style multiply on light content, translucent wash on dark content where multiply would vanish.
        if (sources.luma?.average(in: r) ?? 1) > 0.45 {
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.opacity(0.85).cgColor)
        } else {
            ctx.setFillColor(a.color.opacity(0.35).cgColor)
        }
        let radius = max(0, min(3 * ps, r.width / 2, r.height / 2))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Text & counters

    struct TextFrame {
        let layout: TextLayout
        /// Full box (including label padding / outline), image coordinates.
        let box: CGRect
        /// Top-left of the glyphs.
        let glyphOrigin: CGPoint
    }

    static func textFrame(_ a: Annotation) -> TextFrame {
        let layout = TextLayout.make(text: a.text.isEmpty ? " " : a.text, fontSize: a.fontSize)
        let fs = a.fontSize
        switch a.textStyle {
        case .pill:
            let padX = fs * 0.45, padY = fs * 0.2
            let box = CGRect(x: a.start.x, y: a.start.y, width: layout.size.width + padX * 2, height: layout.size.height + padY * 2)
            return TextFrame(layout: layout, box: box, glyphOrigin: CGPoint(x: a.start.x + padX, y: a.start.y + padY))
        case .outlined:
            let m = fs * 0.1
            let box = CGRect(x: a.start.x - m, y: a.start.y - m, width: layout.size.width + m * 2, height: layout.size.height + m * 2)
            return TextFrame(layout: layout, box: box, glyphOrigin: a.start)
        case .plain:
            return TextFrame(layout: layout, box: CGRect(origin: a.start, size: layout.size), glyphOrigin: a.start)
        }
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext, shadow: Bool, ps: CGFloat) {
        let frame = textFrame(a)
        let glyphs = frame.layout.path(at: frame.glyphOrigin)
        if shadow { applyShadow(ctx, ps: ps) }
        switch a.textStyle {
        case .pill:
            let radius = min(frame.box.height * 0.3, frame.box.width / 2)
            ctx.addPath(CGPath(roundedRect: frame.box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
            clearShadow(ctx)
            ctx.addPath(glyphs)
            ctx.setFillColor(a.color.contrasting.cgColor)
            ctx.fillPath()
        case .outlined:
            ctx.addPath(glyphs)
            ctx.setStrokeColor(a.color.contrasting.cgColor)
            ctx.setLineWidth(a.fontSize * 0.16)
            ctx.strokePath()
            clearShadow(ctx)
            ctx.addPath(glyphs)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        case .plain:
            ctx.addPath(glyphs)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        }
        clearShadow(ctx)
        frame.layout.drawBitmapRuns(in: ctx, at: frame.glyphOrigin)
    }

    static func counterRadius(_ a: Annotation) -> CGFloat { a.fontSize * 0.95 }

    private static func drawCounter(_ a: Annotation, in ctx: CGContext, shadow: Bool, ps: CGFloat) {
        let r = counterRadius(a)
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        if shadow { applyShadow(ctx, ps: ps) }
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: circle)
        clearShadow(ctx)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(r * 0.13)
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.065, dy: r * 0.065))
        let label = TextLayout.make(text: "\(a.number)", fontSize: a.fontSize * (a.number >= 10 ? 0.82 : 1))
        let bb = label.path.boundingBoxOfPath
        ctx.addPath(label.path(at: CGPoint(x: a.start.x - bb.midX, y: a.start.y - bb.midY)))
        ctx.setFillColor(a.color.contrasting.cgColor)
        ctx.fillPath()
    }

    // MARK: Geometry & hit testing

    static func bounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .arrow, .line:
            return CGRect(p1: a.start, p2: a.end).insetBy(dx: -a.width * 2.5, dy: -a.width * 2.5)
        case .pen:
            guard let first = a.points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in a.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -a.width, dy: -a.width)
        case .text:
            return textFrame(a).box
        case .counter:
            let r = counterRadius(a)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        case .rect, .ellipse, .highlight, .blur, .spotlight:
            return a.rect
        }
    }

    /// `generous` (select tool) lets the inside of area shapes grab them; drawing tools only grab their edges.
    static func hitTest(_ a: Annotation, at p: CGPoint, tolerance t: CGFloat, generous: Bool) -> Bool {
        switch a.kind {
        case .arrow, .line:
            return Geometry.distance(p, toSegmentFrom: a.start, to: a.end) <= max(t, a.width * (a.kind == .arrow ? 1.6 : 0.8))
        case .pen:
            guard a.points.count > 1 else { return a.points.first.map { $0.distance(to: p) <= t + a.width } ?? false }
            for i in 1..<a.points.count where Geometry.distance(p, toSegmentFrom: a.points[i - 1], to: a.points[i]) <= t + a.width / 2 {
                return true
            }
            return false
        case .text, .counter:
            return bounds(of: a).insetBy(dx: -t / 2, dy: -t / 2).contains(p)
        case .rect, .ellipse:
            let r = a.rect
            if generous || a.fill != .outline { return r.insetBy(dx: -t, dy: -t).contains(p) }
            let edge = t + a.width / 2
            if a.kind == .ellipse {
                let rx = r.width / 2, ry = r.height / 2
                guard rx > 0, ry > 0 else { return r.insetBy(dx: -edge, dy: -edge).contains(p) }
                let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
                return abs(sqrt(nx * nx + ny * ny) - 1) * min(rx, ry) <= edge
            }
            return r.insetBy(dx: -edge, dy: -edge).contains(p) && !r.insetBy(dx: edge, dy: edge).contains(p)
        case .highlight, .blur, .spotlight:
            let r = a.rect
            if generous { return r.insetBy(dx: -t, dy: -t).contains(p) }
            return r.insetBy(dx: -t, dy: -t).contains(p) && !r.insetBy(dx: t, dy: t).contains(p)
        }
    }
}

/// A tiny grayscale thumbnail used to pick the highlight blend mode per region.
final class LumaMap {
    private let width: Int
    private let height: Int
    private let sx: CGFloat
    private let sy: CGFloat
    private let pixels: [UInt8]

    init?(image: CGImage, maxDimension: Int = 192) {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        sx = CGFloat(w) / CGFloat(image.width)
        sy = CGFloat(h) / CGFloat(image.height)
        pixels = buffer
    }

    /// Average brightness (0...1) of a rect given in image pixels (y-down).
    func average(in rect: CGRect) -> CGFloat {
        let x0 = max(0, Int(rect.minX * sx)), x1 = min(width - 1, Int(rect.maxX * sx))
        let y0 = max(0, Int(rect.minY * sy)), y1 = min(height - 1, Int(rect.maxY * sy))
        guard x1 >= x0, y1 >= y0 else { return 1 }
        var sum = 0
        for y in y0...y1 {
            for x in x0...x1 { sum += Int(pixels[y * width + x]) }
        }
        return CGFloat(sum) / CGFloat((x1 - x0 + 1) * (y1 - y0 + 1)) / 255
    }
}
