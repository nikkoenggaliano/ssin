// Renders the app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [CGColor(srgbRed: 0.42, green: 0.35, blue: 0.98, alpha: 1), CGColor(srgbRed: 0.84, green: 0.43, blue: 0.99, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 860), startRadius: 0, endCenter: CGPoint(x: 300, y: 860), endRadius: 700, options: [])
ctx.restoreGState()

// Viewfinder corners.
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let inset: CGFloat = 250, arm: CGFloat = 150
let lo = inset, hi = size - inset
for (x, y, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (hi, lo, -1.0, 1.0), (lo, lo, 1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    ctx.move(to: CGPoint(x: x + arm * dx, y: y))
    ctx.addLine(to: CGPoint(x: x, y: y))
    ctx.addLine(to: CGPoint(x: x, y: y + arm * dy))
}
ctx.strokePath()

// Record dot: screenshots + recordings.
let dot = CGRect(x: size / 2 - 92, y: size / 2 - 92, width: 184, height: 184)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.3))
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fillEllipse(in: dot.insetBy(dx: -22, dy: -22))
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(CGColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1))
ctx.fillEllipse(in: dot)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
