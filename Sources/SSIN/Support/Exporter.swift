import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes, saves and copies images. Retina scale is stored as DPI so files open at their real point size.
enum Exporter {
    static func encode(_ image: CGImage, scale: CGFloat, format: ImageFormat, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        var output = image
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = quality
            if image.hasAlpha, let flat = image.flattened() { output = flat }
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func fileName(prefix: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: date))"
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    @MainActor
    static func saveToFolder(_ image: CGImage, scale: CGFloat, prefix: String = "Screenshot") throws -> URL {
        let settings = AppSettings.shared
        let folder = settings.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, base: fileName(prefix: prefix), ext: settings.imageFormat.fileExtension)
        guard let data = encode(image, scale: scale, format: settings.imageFormat, quality: settings.jpegQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    static func saveInBackground(_ image: CGImage, scale: CGFloat, announce: Bool) {
        let settings = AppSettings.shared
        let folder = settings.saveFolder
        let format = settings.imageFormat
        let quality = settings.jpegQuality
        let url = uniqueURL(in: folder, base: fileName(prefix: "Screenshot"), ext: format.fileExtension)
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let data = encode(image, scale: scale, format: format, quality: quality) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                if announce {
                    await Toast.show("Saved", symbol: "checkmark.circle.fill", detail: url.lastPathComponent)
                }
            } catch {
                await Toast.show("Couldn't save", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
            }
        }
    }

    /// Puts the image on the clipboard. PNG and TIFF are produced lazily, so copying is instant even for 6K captures.
    @MainActor
    static func copyToClipboard(_ image: CGImage, scale: CGFloat, to pb: NSPasteboard = .general) {
        let provider = ImagePasteboardProvider(image: image, scale: scale)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pb.clearContents()
        pb.writeObjects([item])
        ImagePasteboardProvider.current = provider
        provider.warmUp()
    }

    @MainActor
    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }
}

final class ImagePasteboardProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    /// The pasteboard only keeps a weak reference to its provider.
    @MainActor static var current: ImagePasteboardProvider?

    private let image: CGImage
    private let scale: CGFloat
    private let lock = NSLock()
    private var png: Data?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.pngData() }
    }

    private func pngData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if png == nil { png = Exporter.encode(image, scale: scale, format: .png) }
        return png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            if let data = pngData() { item.setData(data, forType: .png) }
        case .tiff:
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            if let data = rep.tiffRepresentation(using: .lzw, factor: 0) { item.setData(data, forType: .tiff) }
        default:
            break
        }
    }
}
