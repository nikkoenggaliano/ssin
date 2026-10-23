import AppKit
import CoreText

/// Lays text out as vector glyph outlines so it can be stroked (outline style) and rendered at any resolution.
struct TextLayout {
    /// Glyph outlines in a y-down space whose origin is the top-left of the text block.
    let path: CGPath
    let size: CGSize
    /// Runs without outlines (color emoji), drawn as bitmaps. The point is the line's baseline origin.
    private let bitmapRuns: [(run: CTRun, origin: CGPoint)]

    private static var cache: [String: TextLayout] = [:]

    /// Cached layout; the canvas redraws on every mouse move, text rarely changes.
    static func make(text: String, fontSize: CGFloat) -> TextLayout {
        let key = "\(fontSize)|\(text)"
        if let hit = cache[key] { return hit }
        let layout = TextLayout(text: text, fontSize: fontSize)
        if cache.count > 256 { cache.removeAll() }
        cache[key] = layout
        return layout
    }

    static func font(size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded
        }
        return base
    }

    init(text: String, fontSize: CGFloat) {
        let font = Self.font(size: fontSize)
        let ascent = font.ascender
        let lineHeight = ceil(font.ascender - font.descender + font.leading) * 1.04
        let path = CGMutablePath()
        var runs: [(CTRun, CGPoint)] = []
        var maxWidth: CGFloat = 0
        let lines = text.components(separatedBy: "\n")

        for (index, string) in lines.enumerated() {
            let baseline = CGFloat(index) * lineHeight + ascent
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
            maxWidth = max(maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in glyphRuns {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? (font as CTFont)
                if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) {
                    runs.append((run, CGPoint(x: 0, y: baseline)))
                    continue
                }
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for i in 0..<count {
                    guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                    // Glyph outlines are y-up around the baseline; flip them into the y-down layout.
                    let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: baseline - positions[i].y)
                    path.addPath(glyphPath, transform: transform)
                }
            }
        }
        self.path = path
        bitmapRuns = runs
        size = CGSize(width: max(ceil(maxWidth), fontSize * 0.3), height: CGFloat(lines.count) * lineHeight)
    }

    /// Glyph outlines moved so the text block's top-left sits at `origin`.
    func path(at origin: CGPoint) -> CGPath {
        var t = CGAffineTransform(translationX: origin.x, y: origin.y)
        return path.copy(using: &t) ?? path
    }

    func drawBitmapRuns(in ctx: CGContext, at origin: CGPoint) {
        for (run, lineOrigin) in bitmapRuns {
            ctx.saveGState()
            ctx.translateBy(x: origin.x + lineOrigin.x, y: origin.y + lineOrigin.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
            ctx.restoreGState()
        }
    }
}
