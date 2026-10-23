import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class EditorWindow: AppWindow {}

/// One editor window per capture.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []
    private static let topBarHeight: CGFloat = 52

    let doc: EditorDocument
    let canvas: CanvasView
    private let fieldEditor = PrivateUndoFieldEditor.make()
    private var dragFileURL: URL?
    /// Tests swap in a private pasteboard so they don't clobber the user's clipboard.
    var pasteboard = NSPasteboard.general

    static func open(image: CGImage, scale: CGFloat) {
        let controller = EditorWindowController(image: image, scale: scale)
        openEditors.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        ActivationPolicy.refresh()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    init(image: CGImage, scale: CGFloat) {
        doc = EditorDocument(image: image, pixelScale: scale)
        canvas = CanvasView(doc: doc)
        let window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        super.init(window: window)

        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar 52pt tall and centers the traffic lights in our top bar.
        window.toolbar = NSToolbar(identifier: "EditorToolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(white: 0.085, alpha: 1)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 980, height: 480)
        window.title = Exporter.fileName(prefix: "Screenshot", date: doc.createdAt)

        let actions = EditorActions(
            copy: { [weak self] in self?.copyImage() },
            save: { [weak self] in self?.saveImage() },
            copyText: { [weak self] in self?.copyText() },
            pin: { [weak self] in self?.pin() },
            zoom: { [weak self] in self?.zoom($0) },
            dragFile: { [weak self] in self?.prepareDragFile() }
        )
        // The top bar lives under the transparent title bar, so it must not inset itself for it.
        let topBar = NSHostingView(rootView: EditorTopBar(doc: doc, actions: actions))
        topBar.safeAreaRegions = []
        let inspector = NSHostingView(rootView: InspectorBar(doc: doc))
        inspector.safeAreaRegions = []
        window.contentView = EditorContentView(canvas: canvas, topBar: topBar, inspector: inspector, topBarHeight: Self.topBarHeight)
        window.setFrame(initialFrame(for: image, scale: scale), display: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func initialFrame(for image: CGImage, scale: CGFloat) -> CGRect {
        let screen = NSScreen.withMouse ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let logical = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let chrome = CGSize(width: 56 + 40, height: Self.topBarHeight + 108 + 40)
        let w = min(max(980, logical.width + chrome.width), vf.width * 0.92)
        let h = min(max(520, logical.height + chrome.height), vf.height * 0.92)
        return CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h).integral
    }

    // MARK: Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { doc.undoManager }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is InlineTextField ? fieldEditor : nil
    }

    func windowWillClose(_ notification: Notification) {
        canvas.endTextEditing()
        if let url = dragFileURL { try? FileManager.default.removeItem(at: url) }
        Self.openEditors.removeAll { $0 === self }
        ActivationPolicy.refreshSoon()
    }

    // MARK: Actions (also reachable through the menu / responder chain)

    @objc func copy(_ sender: Any?) { copyImage() }
    @objc func saveImage(_ sender: Any?) { saveImage() }
    @objc func saveImageAs(_ sender: Any?) { saveAs() }
    @objc func copyAndClose(_ sender: Any?) {
        copyImage()
        if window?.isVisible == true { window?.close() }
    }

    /// Copying or saving finishes the job, so the preview gets out of the way. Holding ⌥ keeps it open.
    private func closeAfterExport() {
        guard !NSEvent.modifierFlags.contains(.option) else { return }
        window?.close()
    }
    @objc func copyRecognizedText(_ sender: Any?) { copyText() }
    @objc func pinImage(_ sender: Any?) { pin() }
    @objc func toggleBeautify(_ sender: Any?) { doc.toggleBeautify() }
    @objc func zoomIn(_ sender: Any?) { canvas.zoom(by: 1.25, around: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    @objc func zoomOut(_ sender: Any?) { canvas.zoom(by: 0.8, around: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    @objc func zoomActualSize(_ sender: Any?) { canvas.zoomTo(percent: 100) }
    @objc func delete(_ sender: Any?) { doc.deleteSelected() }

    private func render() -> CGImage? {
        canvas.endTextEditing()
        return doc.renderFinal()
    }

    func copyImage() {
        guard let image = render() else { return }
        Exporter.copyToClipboard(image, scale: doc.pixelScale, to: pasteboard)
        Toast.show("Copied to clipboard", detail: "\(image.width) × \(image.height) px")
        closeAfterExport()
    }

    func saveImage() {
        guard let image = render() else { return }
        do {
            let url = try Exporter.saveToFolder(image, scale: doc.pixelScale)
            Toast.show("Saved", symbol: "checkmark.circle.fill", detail: url.lastPathComponent)
            closeAfterExport()
        } catch {
            Toast.show("Couldn't save", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
        }
    }

    func saveAs() {
        guard let window, let image = render() else { return }
        let panel = NSSavePanel()
        let format = AppSettings.shared.imageFormat
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "\(Exporter.fileName(prefix: "Screenshot", date: doc.createdAt)).\(format.fileExtension)"
        panel.directoryURL = AppSettings.shared.saveFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let chosen: ImageFormat = url.pathExtension.lowercased() == "png" ? .png : .jpeg
            guard let data = Exporter.encode(image, scale: self.doc.pixelScale, format: chosen, quality: AppSettings.shared.jpegQuality) else { return }
            do {
                try data.write(to: url, options: .atomic)
                Toast.show("Saved", detail: url.lastPathComponent)
                self.closeAfterExport()
            } catch {
                Toast.show("Couldn't save", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
            }
        }
    }

    func copyText() {
        let image = doc.croppedOriginal()
        Task { await OCR.copyText(from: image) }
    }

    func pin() {
        guard let image = render() else { return }
        PinWindow.show(image: image, scale: doc.pixelScale)
    }

    private func zoom(_ command: ZoomCommand) {
        switch command {
        case .fit: canvas.zoomToFit()
        case .percent(let p): canvas.zoomTo(percent: p)
        }
    }

    /// Writes the current render to a temp PNG for drag-and-drop into other apps.
    private func prepareDragFile() -> URL? {
        guard let image = render(),
              let data = Exporter.encode(image, scale: doc.pixelScale, format: .png) else { return nil }
        if let old = dragFileURL { try? FileManager.default.removeItem(at: old) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SSIN", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(Exporter.fileName(prefix: "Screenshot", date: doc.createdAt)).png")
        do {
            try data.write(to: url, options: .atomic)
            dragFileURL = url
            return url
        } catch {
            return nil
        }
    }
}

/// Lays out the top bar, the canvas and the floating inspector.
private final class EditorContentView: NSView {
    init(canvas: CanvasView, topBar: NSView, inspector: NSView, topBarHeight: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        for view in [canvas, topBar, inspector] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: topBarHeight),
            canvas.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            inspector.centerXAnchor.constraint(equalTo: centerXAnchor),
            inspector.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Keeps typing undo separate from the document's undo stack.
private final class PrivateUndoFieldEditor: NSTextView {
    private let privateUndoManager = UndoManager()

    override var undoManager: UndoManager? { privateUndoManager }

    static func make() -> PrivateUndoFieldEditor {
        let editor = PrivateUndoFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.allowsUndo = true
        return editor
    }
}
