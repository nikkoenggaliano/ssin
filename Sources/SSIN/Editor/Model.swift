import AppKit
import SwiftUI

// MARK: - Color

struct RGBA: Codable, Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255, a: alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var swiftUI: Color { Color(nsColor) }

    func opacity(_ value: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: value) }

    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Near-black or white, whichever reads better on top of this color.
    var contrasting: RGBA { luminance > 0.6 ? RGBA(hex: 0x1C1C1E) : RGBA(hex: 0xFFFFFF) }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static let palette: [RGBA] = [0xFF3B30, 0xFF9500, 0xFFD60A, 0x30D158, 0x0A84FF, 0x5E5CE6, 0xFF2D78, 0xFFFFFF, 0x1C1C1E]
        .map { RGBA(hex: $0) }
}

// MARK: - Tools & annotations

enum AnnotationKind: String, Codable {
    case arrow, line, rect, ellipse, text, pen, highlight, blur, spotlight, counter

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .pen: "Pen"
        case .highlight: "Highlight"
        case .blur: "Redact"
        case .spotlight: "Spotlight"
        case .counter: "Step"
        }
    }

    var usesColor: Bool { self != .blur && self != .spotlight }
    var usesStroke: Bool { [.arrow, .line, .rect, .ellipse, .pen].contains(self) }
    var usesFill: Bool { self == .rect || self == .ellipse }
    var usesShadow: Bool { [.arrow, .line, .rect, .ellipse, .pen, .text, .counter].contains(self) }
}

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, text, pen, highlight, blur, spotlight, counter, crop

    var id: String { rawValue }

    var kind: AnnotationKind? {
        switch self {
        case .select, .crop: nil
        case .arrow: .arrow
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        case .text: .text
        case .pen: .pen
        case .highlight: .highlight
        case .blur: .blur
        case .spotlight: .spotlight
        case .counter: .counter
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        default: kind?.title ?? ""
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "scribble.variable"
        case .highlight: "highlighter"
        case .blur: "eye.slash"
        case .spotlight: "flashlight.on.fill"
        case .counter: "1.circle"
        case .crop: "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rect: "r"
        case .ellipse: "o"
        case .text: "t"
        case .pen: "p"
        case .highlight: "h"
        case .blur: "b"
        case .spotlight: "s"
        case .counter: "n"
        case .crop: "c"
        }
    }

    static func forShortcut(_ c: Character) -> Tool? { allCases.first { $0.shortcut == c } }
}

enum FillStyle: String, Codable, CaseIterable, Identifiable {
    case outline, tinted, solid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .outline: "square"
        case .tinted: "square.lefthalf.filled"
        case .solid: "square.fill"
        }
    }
}

enum TextStyle: String, Codable, CaseIterable, Identifiable {
    case plain, outlined, pill
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: "Plain"
        case .outlined: "Outline"
        case .pill: "Label"
        }
    }
}

enum BlurStyle: String, Codable, CaseIterable, Identifiable {
    case pixelate, blur
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// One drawn object. Coordinates are image pixels with a top-left origin.
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBA
    var width: CGFloat
    var fill: FillStyle = .outline
    var text = ""
    var fontSize: CGFloat = 40
    var textStyle: TextStyle = .outlined
    var number = 1
    var blurStyle: BlurStyle = .pixelate
    var shadow = true

    var rect: CGRect { CGRect(p1: start, p2: end) }

    mutating func translate(by d: CGPoint) {
        start = start + d
        end = end + d
        if !points.isEmpty { points = points.map { $0 + d } }
    }
}

/// The current drawing defaults (sizes in points), remembered across sessions.
struct ToolStyle: Codable, Equatable {
    var color = RGBA(hex: 0xFF3B30)
    var highlightColor = RGBA(hex: 0xFFD60A)
    var strokeWidth: CGFloat = 4
    var fill: FillStyle = .outline
    var textStyle: TextStyle = .outlined
    var fontSize: CGFloat = 22
    var counterSize: CGFloat = 15
    var blurStyle: BlurStyle = .pixelate
    var shadow = true

    private static let key = "toolStyle"

    static func load() -> ToolStyle {
        guard let data = UserDefaults.standard.data(forKey: key),
              let style = try? JSONDecoder().decode(ToolStyle.self, from: data)
        else { return ToolStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - Background ("beautify")

struct BackgroundPreset: Identifiable {
    let id: Int
    let name: String
    let colors: [RGBA]

    var isTransparent: Bool { colors.isEmpty }

    private init(_ id: Int, _ name: String, _ hexes: [UInt32]) {
        self.id = id
        self.name = name
        colors = hexes.map { RGBA(hex: $0) }
    }

    static let all: [BackgroundPreset] = [
        BackgroundPreset(0, "Transparent", []),
        BackgroundPreset(1, "Iris", [0x6A5AF9, 0xD66EFD]),
        BackgroundPreset(2, "Ocean", [0x2B7FFF, 0x2FD8F2]),
        BackgroundPreset(3, "Sunset", [0xFF6B6B, 0xFFA45B, 0xFFE07F]),
        BackgroundPreset(4, "Peach", [0xFF9A9E, 0xFAD0C4]),
        BackgroundPreset(5, "Mint", [0x11998E, 0x38EF7D]),
        BackgroundPreset(6, "Aurora", [0x7F7FD5, 0x86A8E7, 0x91EAE4]),
        BackgroundPreset(7, "Candy", [0xF857A6, 0xFF5858]),
        BackgroundPreset(8, "Midnight", [0x0F2027, 0x203A43, 0x2C5364]),
        BackgroundPreset(9, "Graphite", [0x232326, 0x4A4A52]),
        BackgroundPreset(10, "Paper", [0xF7F7F9, 0xE2E2E8]),
    ]

    static func with(id: Int) -> BackgroundPreset { all.first { $0.id == id } ?? all[1] }
}

struct BackgroundStyle: Codable, Equatable {
    var enabled = false
    var presetID = 1
    /// Points; multiplied by the image's pixel scale when rendering.
    var padding: CGFloat = 56
    var cornerRadius: CGFloat = 12
    var shadow: CGFloat = 0.6

    var preset: BackgroundPreset { .with(id: presetID) }

    private static let key = "backgroundStyle"

    /// Restores the last used look; the background itself starts switched off.
    static func load() -> BackgroundStyle {
        guard let data = UserDefaults.standard.data(forKey: key),
              var style = try? JSONDecoder().decode(BackgroundStyle.self, from: data)
        else { return BackgroundStyle() }
        style.enabled = false
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - Document state

struct DocState: Equatable {
    var annotations: [Annotation] = []
    /// Image pixels; nil means the full image.
    var crop: CGRect?
    var background = BackgroundStyle()

    func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }
}

/// Fast-changing UI info kept apart from the document so mouse moves don't trigger canvas redraws.
@MainActor
final class EditorStatus: ObservableObject {
    @Published var hoverColor: RGBA?
    @Published var zoomPercent = 100
}
