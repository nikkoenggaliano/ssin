#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Developer-only command line hooks (debug builds): render tests and UI snapshots without clicking around.
@MainActor
enum DebugCommands {
    static func run(_ args: [String]) -> Bool {
        guard args.count >= 2 else { return false }
        switch args[1] {
        case "--render-test" where args.count >= 4:
            renderTest(input: args[2], outDir: args[3])
            return true
        case "--editor-snapshot" where args.count >= 4:
            editorSnapshot(input: args[2], output: args[3], variant: args.count >= 5 ? args[4] : "annotated")
            return true
        case "--capture-test" where args.count >= 3:
            captureTest(output: args[2])
            return true
        case "--overlay-snapshot" where args.count >= 4:
            overlaySnapshot(input: args[2], outDir: args[3])
            return true
        case "--record-test" where args.count >= 3:
            recordTest(outDir: args[2])
            return true
        case "--settings-snapshot" where args.count >= 3:
            settingsSnapshot(output: args[2])
            return true
        case "--interaction-test" where args.count >= 3:
            interactionTest(input: args[2])
            return true
        case "--perf-test" where args.count >= 3:
            perfTest(input: args[2])
            return true
        default:
            return false
        }
    }

    private static func load(_ path: String) -> CGImage {
        guard let image = CGImage.load(from: URL(fileURLWithPath: path)) else {
            print("cannot load \(path)")
            exit(1)
        }
        return image
    }

    private static func write(_ image: CGImage, to path: String) {
        let data = Exporter.encode(image, scale: 2, format: .png)!
        try! data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(image.width)x\(image.height)")
    }

    /// A tidy, realistic edit for the README screenshot (meant for the Settings window snapshot).
    static func hero(_ doc: EditorDocument) {
        let w = doc.imageSize.width, h = doc.imageSize.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        var items: [Annotation] = []
        var a = doc.makeAnnotation(.rect, at: p(0.025, 0.278)); a.end = p(0.975, 0.452); items.append(a)
        a = doc.makeAnnotation(.arrow, at: p(0.62, 0.585)); a.end = p(0.85, 0.385); items.append(a)
        a = doc.makeAnnotation(.text, at: p(0.34, 0.585)); a.text = "Copied on every capture"; a.textStyle = .pill; a.color = RGBA.palette[5]; items.append(a)
        for (i, y) in [0.115, 0.258, 0.5].enumerated() {
            a = doc.makeAnnotation(.counter, at: p(0.93, y)); a.number = i + 1; items.append(a)
        }
        doc.perform("Hero") {
            $0.annotations = items
            $0.background.enabled = true
            $0.background.presetID = 1
            $0.background.padding = 64
        }
        doc.selectTool(.arrow)
        doc.beautifyPanel = true
    }

    /// Adds one of every annotation type, scaled to the image.
    static func populate(_ doc: EditorDocument) {
        let w = doc.imageSize.width, h = doc.imageSize.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        var items: [Annotation] = []
        var a = doc.makeAnnotation(.arrow, at: p(0.08, 0.85)); a.end = p(0.3, 0.6); items.append(a)
        a = doc.makeAnnotation(.rect, at: p(0.36, 0.3)); a.end = p(0.62, 0.48); items.append(a)
        a = doc.makeAnnotation(.ellipse, at: p(0.66, 0.08)); a.end = p(0.9, 0.24); a.color = RGBA.palette[4]; a.fill = .tinted; items.append(a)
        a = doc.makeAnnotation(.line, at: p(0.05, 0.08)); a.end = p(0.3, 0.12); a.color = RGBA.palette[3]; items.append(a)
        a = doc.makeAnnotation(.highlight, at: p(0.35, 0.52)); a.end = p(0.62, 0.57); items.append(a)
        a = doc.makeAnnotation(.blur, at: p(0.66, 0.3)); a.end = p(0.92, 0.45); items.append(a)
        a = doc.makeAnnotation(.blur, at: p(0.66, 0.5)); a.end = p(0.92, 0.6); a.blurStyle = .blur; items.append(a)
        a = doc.makeAnnotation(.text, at: p(0.06, 0.22)); a.text = "Outline text ✨"; items.append(a)
        a = doc.makeAnnotation(.text, at: p(0.06, 0.34)); a.text = "Label style"; a.textStyle = .pill; a.color = RGBA.palette[5]; items.append(a)
        a = doc.makeAnnotation(.text, at: p(0.06, 0.46)); a.text = "Plain\nmultiline"; a.textStyle = .plain; a.color = .init(hex: 0xFFFFFF); items.append(a)
        for (i, x) in [0.7, 0.78, 0.86].enumerated() {
            a = doc.makeAnnotation(.counter, at: p(x, 0.72)); a.number = i + 1; items.append(a)
        }
        a = doc.makeAnnotation(.pen, at: p(0.4, 0.7))
        a.points = (0...40).map { i in let t = CGFloat(i) / 40; return p(0.4 + 0.2 * t, 0.72 + 0.06 * sin(t * .pi * 4)) }
        a.color = RGBA.palette[1]
        items.append(a)
        a = doc.makeAnnotation(.spotlight, at: p(0.34, 0.27)); a.end = p(0.64, 0.6); items.append(a)
        doc.perform("Test") { $0.annotations = items }
    }

    private static func renderTest(input: String, outDir: String) {
        let doc = EditorDocument(image: load(input), pixelScale: 2)
        populate(doc)
        var t = Date()
        write(doc.renderFinal()!, to: "\(outDir)/render-annotated.png")
        print(String(format: "  render %.0f ms", Date().timeIntervalSince(t) * 1000))
        doc.updateBackground("test") { $0.presetID = 1; $0.padding = 56; $0.cornerRadius = 12; $0.shadow = 0.6 }
        t = Date()
        write(doc.renderFinal()!, to: "\(outDir)/render-beautify.png")
        print(String(format: "  render %.0f ms", Date().timeIntervalSince(t) * 1000))
        doc.undoManager.undo()
        doc.undoManager.undo()
        print("after 2 undos: annotations=\(doc.state.annotations.count) background=\(doc.state.background.enabled)")
        doc.undoManager.redo()
        print("after redo: annotations=\(doc.state.annotations.count)")
    }

    private static func overlaySnapshot(input: String, outDir: String) {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { exit(1) }
        // A synthetic "frozen screen": the input image stretched to the display's pixel size.
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBColorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(load(input), in: CGRect(x: 0, y: 0, width: w, height: h))
        let frozen = ctx.makeImage()!
        let size = screen.frame.size
        let fakeWindow = WindowInfo(id: 1, frame: CGRect(x: screen.frame.minX + size.width * 0.3, y: screen.frame.minY + size.height * 0.2,
                                                         width: size.width * 0.5, height: size.height * 0.55), owner: "Terminal")
        if let hover = SelectionOverlayController.debugRender(screen: screen, frozen: frozen, mouse: CGPoint(x: size.width * 0.5, y: size.height * 0.5),
                                                              dragTo: nil, windows: [fakeWindow]) {
            write(hover, to: "\(outDir)/overlay-hover.png")
        }
        if let drag = SelectionOverlayController.debugRender(screen: screen, frozen: frozen, mouse: CGPoint(x: size.width * 0.15, y: size.height * 0.75),
                                                             dragTo: CGPoint(x: size.width * 0.55, y: size.height * 0.35), windows: []) {
            write(drag, to: "\(outDir)/overlay-drag.png")
        }
    }

    /// Records a small area for 2 seconds through the real recorder, then prints the file's video properties.
    private static func recordTest(outDir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let settings = AppSettings.shared
        let savedFolder = settings.saveFolder, savedPreview = settings.showRecordingPreview
        settings.saveFolder = URL(fileURLWithPath: outDir, isDirectory: true)
        settings.showRecordingPreview = false
        func finish(_ code: Int32) -> Never {
            settings.saveFolder = savedFolder
            settings.showRecordingPreview = savedPreview
            exit(code)
        }
        Task { @MainActor in
            guard let screen = NSScreen.main else { finish(1) }
            let rect = CGRect(x: 100, y: 100, width: 401, height: 301)
            await ScreenRecorder.shared.start(screen: screen, rect: rect)
            print("recording:", ScreenRecorder.shared.isRecording)
            try? await Task.sleep(for: .seconds(2))
            await ScreenRecorder.shared.stop()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: outDir).filter { $0.hasSuffix(".mp4") }) ?? []
            guard let name = files.first else { print("no file written"); finish(1) }
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let fps = (try? await track.load(.nominalFrameRate)) ?? 0
                let formats = (try? await track.load(.formatDescriptions)) ?? []
                let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }.map { code in
                    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
                } ?? "?"
                print(String(format: "file: %@  %.0fx%.0f  codec %@  %.1f fps  %.2fs  %lld bytes", name, size.width, size.height, codec, fps, duration,
                             (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0))
            }
            try? FileManager.default.removeItem(at: url)
            finish(0)
        }
        NSApp.run()
    }

    private static func settingsSnapshot(output: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SettingsWindowController.show()
        guard let window = NSApp.windows.first(where: { $0 is SettingsWindow }) else { exit(1) }
        // Prefer a Retina screen so the snapshot comes out at 2x.
        if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.maxY - window.frame.height - 60))
        }
        // Key window, so switches render in the accent color instead of the inactive gray.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let image = await captureOwnWindow(window) else { exit(2) }
            write(image, to: output)
            exit(0)
        }
        NSApp.run()
    }

    /// Drives the editor canvas with synthetic mouse/keyboard events and checks the resulting document.
    private static func interactionTest(input: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()
        let controller = EditorWindowController(image: load(input), scale: 2)
        let doc = controller.doc, canvas = controller.canvas
        guard let window = controller.window else { exit(1) }
        window.alphaValue = 0
        window.setFrame(CGRect(x: 60, y: 60, width: 1200, height: 800), display: true)
        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
            if !ok { failures += 1 }
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        // Each real user action is its own run loop pass, which is where UndoManager closes its groups.
        func tick() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) {
            defer { tick() }
            canvas.mouseDown(with: mouse(.leftMouseDown, a, flags: flags))
            for i in 1...5 {
                let t = CGFloat(i) / 5
                canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags))
            }
            canvas.mouseUp(with: mouse(.leftMouseUp, b, flags: flags))
        }
        func click(_ p: CGPoint, clicks: Int = 1) {
            defer { tick() }
            canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: clicks))
            canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: clicks))
        }
        func key(_ chars: String, _ code: Int) {
            defer { tick() }
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                                  keyCode: UInt16(code))!)
        }
        let c = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY - 30)
        print("canvas \(canvas.bounds.size), scale \(canvas.scale)")

        drag(CGPoint(x: c.x - 120, y: c.y + 40), CGPoint(x: c.x, y: c.y))
        check("drag creates an arrow", doc.state.annotations.count == 1 && doc.state.annotations[0].kind == .arrow)
        check("new arrow is selected", doc.selectedID == doc.state.annotations.first?.id)
        guard !doc.state.annotations.isEmpty else { print("  (aborting: nothing was created)"); exit(1) }
        let before = doc.state.annotations[0].start
        drag(CGPoint(x: c.x - 60, y: c.y + 20), CGPoint(x: c.x - 40, y: c.y + 30))
        let moved = doc.state.annotations[0].start
        check("dragging the arrow moves it", abs(moved.x - before.x - 20 / canvas.scale) < 1 && abs(moved.y - before.y - 10 / canvas.scale) < 1)
        doc.undoManager.undo(); tick()
        check("undo restores position", doc.state.annotations.first?.start == before)
        doc.undoManager.undo(); tick()
        check("second undo removes arrow", doc.state.annotations.isEmpty)
        doc.undoManager.redo(); tick()
        check("redo brings it back", doc.state.annotations.count == 1)

        click(CGPoint(x: c.x + 200, y: c.y - 100))
        check("click on empty canvas deselects without adding", doc.selectedID == nil && doc.state.annotations.count == 1)

        key("r", 15)
        check("R selects rectangle tool", doc.tool == .rect)
        drag(CGPoint(x: c.x + 50, y: c.y - 80), CGPoint(x: c.x + 150, y: c.y - 20), flags: .shift)
        let rect = doc.state.annotations.last!
        check("shift-drag makes a square", rect.kind == .rect && abs(rect.rect.width - rect.rect.height) < 0.5)
        key("\u{7f}", 51)
        check("delete removes selection", doc.state.annotations.count == 1)

        key("t", 17)
        click(CGPoint(x: c.x - 200, y: c.y - 120))
        if let field = canvas.subviews.compactMap({ $0 as? InlineTextField }).first {
            field.stringValue = "Hello 👋"
            canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            canvas.endTextEditing()
        }
        check("text tool types an annotation", doc.state.annotations.last?.text == "Hello 👋")
        check("text field removed after commit", canvas.subviews.allSatisfy { !($0 is InlineTextField) })

        key("n", 45)
        for i in 0..<3 { click(CGPoint(x: c.x - 100 + CGFloat(i) * 50, y: c.y + 120)) }
        check("step counters number 1, 2, 3", doc.state.annotations.filter { $0.kind == .counter }.map(\.number) == [1, 2, 3])

        key("c", 8)
        check("C enters crop", doc.tool == .crop && doc.cropDraft == doc.fullRect)
        drag(CGPoint(x: c.x - 150, y: c.y - 100), CGPoint(x: c.x + 150, y: c.y + 100))
        let draft = doc.cropDraft ?? .zero
        key("\r", 36)
        check("Return applies crop", doc.state.crop != nil && doc.tool == .counter)
        let out = doc.renderFinal()!
        check("export matches crop size", abs(CGFloat(out.width) - draft.width.rounded()) <= 1 && abs(CGFloat(out.height) - draft.height.rounded()) <= 1)
        doc.toggleBeautify()
        let pretty = doc.renderFinal()!
        let pad = (doc.state.background.padding * 2).rounded() * 2
        check("beautify adds padding", pretty.width == out.width + Int(pad))
        key("\u{1b}", 53)
        check("Esc closes the beautify panel first", !doc.beautifyPanel && doc.state.background.enabled)
        key("v", 9)
        click(CGPoint(x: 12, y: 12))
        check("select tool click on nothing changes nothing", doc.selectedID == nil)

        // Hover tips
        func anchors(in view: NSView) -> [TipAnchorView] {
            view.subviews.flatMap { sub -> [TipAnchorView] in
                if let anchor = sub as? TipAnchorView { return [anchor] }
                return anchors(in: sub)
            }
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func hoverEvent(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        let tips = anchors(in: window.contentView!)
        let titles = Set(tips.map(\.tip.title))
        check("top bar buttons have tips", ["Save to folder", "Copy to clipboard", "Pin to screen", "Undo", Tool.arrow.title].allSatisfy(titles.contains))
        let saveTip = tips.first { $0.tip.title == "Save to folder" }!
        let copyTip = tips.first { $0.tip.title == "Copy to clipboard" }!
        check("save tip names the folder", saveTip.tip.detail?.contains(AppSettings.shared.saveFolder.lastPathComponent) == true)
        saveTip.mouseEntered(with: hoverEvent(.mouseEntered))
        wait(0.1)
        check("tip waits a moment before showing", HoverTip.shared.panel?.isVisible != true)
        wait(0.4)
        let saveRect = window.convertToScreen(saveTip.convert(saveTip.bounds, to: nil))
        let tipFrame = HoverTip.shared.panel?.frame ?? .zero
        check("save tip appears just below its button", HoverTip.shared.panel?.isVisible == true && tipFrame.maxY <= saveRect.minY
              && saveRect.minY - tipFrame.maxY < 12 && abs(tipFrame.midX - saveRect.midX) < 2)
        saveTip.mouseExited(with: hoverEvent(.mouseExited))
        tick()
        check("tip hides when the pointer leaves", HoverTip.shared.panel?.isVisible == false)
        copyTip.mouseEntered(with: hoverEvent(.mouseEntered))
        tick()
        check("next button's tip shows right away", HoverTip.shared.panel?.isVisible == true && HoverTip.shared.owner === copyTip)
        copyTip.mouseExited(with: hoverEvent(.mouseExited))
        tick()

        // Copy and Save close the preview
        final class Flag: @unchecked Sendable { var value = false }
        func closeFlag(_ window: NSWindow) -> Flag {
            let flag = Flag()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in flag.value = true }
            return flag
        }
        let saver = EditorWindowController(image: load(input), scale: 2)
        let saverClosed = closeFlag(saver.window!)
        let settings = AppSettings.shared, savedFolder = settings.saveFolder
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ssin-test-\(UUID().uuidString)", isDirectory: true)
        settings.saveFolder = folder
        saver.saveImage()
        settings.saveFolder = savedFolder
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check("save writes the file and closes the preview", saved.count == 1 && saverClosed.value)
        try? FileManager.default.removeItem(at: folder)

        let copyClosed = closeFlag(window)
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.ssin.interaction-test"))
        controller.copyImage()
        check("copy puts a PNG on the pasteboard and closes the preview",
              controller.pasteboard.data(forType: .png) != nil && copyClosed.value)
        controller.pasteboard.releaseGlobally()

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Simulates canvas redraws (what happens on every mouse-drag event) at typical window sizes.
    private static func perfTest(input: String) {
        let doc = EditorDocument(image: load(input), pixelScale: 2)
        let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "full"
        if mode != "empty" { populate(doc) }
        if mode == "noshadow" { doc.perform("x") { s in for i in s.annotations.indices { s.annotations[i].shadow = false } } }
        if mode == "nospot" { doc.perform("x") { s in s.annotations.removeAll { $0.kind == .spotlight } } }
        if mode.hasPrefix("only:") {
            let kind = String(mode.dropFirst(5))
            doc.perform("x") { s in s.annotations.removeAll { $0.kind.rawValue != kind } }
        }
        print("mode:", mode)
        for deviceScale in [1.0, 0.8, 0.5] as [CGFloat] {
            let layout = doc.layout(cropEditing: false)
            let w = Int(layout.size.width * deviceScale), h = Int(layout.size.height * deviceScale)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBColorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: deviceScale, y: -deviceScale)
            ctx.interpolationQuality = .high
            let sources = doc.sources(deviceScale: deviceScale)
            Renderer.drawDocument(in: ctx, state: doc.state, layout: layout, sources: sources) // warm caches
            let t = Date()
            let n = 20
            for _ in 0..<n { Renderer.drawDocument(in: ctx, state: doc.state, layout: layout, sources: sources) }
            print(String(format: "device scale %.1f (%dx%d px): %.1f ms per frame", deviceScale, w, h, Date().timeIntervalSince(t) * 1000 / Double(n)))
        }
    }

    private static func editorSnapshot(input: String, output: String, variant: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()
        let controller = EditorWindowController(image: load(input), scale: 2)
        guard let window = controller.window else { exit(1) }
        switch variant {
        case "annotated":
            populate(controller.doc)
            controller.doc.selectedID = controller.doc.state.annotations[1].id
        case "beautify":
            controller.doc.toggleBeautify()
        case "crop":
            controller.doc.selectTool(.crop)
            controller.doc.cropDraft = CGRect(x: 120, y: 80, width: controller.doc.imageSize.width * 0.6, height: controller.doc.imageSize.height * 0.6)
        case "text":
            controller.doc.selectTool(.text)
        case "hero":
            hero(controller.doc)
        default:
            break
        }
        window.alphaValue = 0.0
        window.setFrame(CGRect(x: 80, y: 80, width: 1240, height: 820), display: true)
        window.orderFrontRegardless()
        controller.doc.status.hoverColor = RGBA(hex: 0xE3E7DC)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            window.displayIfNeeded()
            window.alphaValue = 1
            var tipPanel: NSPanel?
            if variant == "tip", let save = Self.tipAnchor(titled: "Save to folder", in: window.contentView!) {
                HoverTip.shared.show(for: save)
                tipPanel = HoverTip.shared.panel
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard let image = await Self.captureOwnWindow(window) else {
                print("window capture unavailable")
                exit(2)
            }
            if let tipPanel, let tip = await Self.captureOwnWindow(tipPanel) {
                // Lay both windows out as they sit on screen (bottom-left origin, points × backing scale).
                let scale = window.backingScaleFactor
                let bounds = window.frame.union(tipPanel.frame.insetBy(dx: -12, dy: -12))
                let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: sRGBColorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                for (img, frame) in [(image, window.frame), (tip, tipPanel.frame)] {
                    ctx.draw(img, in: CGRect(x: (frame.minX - bounds.minX) * scale, y: (frame.minY - bounds.minY) * scale,
                                             width: frame.width * scale, height: frame.height * scale))
                }
                write(ctx.makeImage()!, to: output)
            } else {
                write(image, to: output)
            }
            exit(0)
        }
        NSApp.run()
    }

    private static func tipAnchor(titled title: String, in view: NSView) -> TipAnchorView? {
        for sub in view.subviews {
            if let anchor = sub as? TipAnchorView, anchor.tip.title == title { return anchor }
            if let found = tipAnchor(titled: title, in: sub) { return found }
        }
        return nil
    }

    private static func captureOwnWindow(_ window: NSWindow) async -> CGImage? {
        let content = try? await SCShareableContent.currentProcess
        guard let scWindow = content?.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func captureTest(output: String) {
        _ = NSApplication.shared
        print("screen capture permission:", CGPreflightScreenCaptureAccess())
        guard CGPreflightScreenCaptureAccess() else { exit(3) }
        Task { @MainActor in
            let t = Date()
            do {
                let session = try await CaptureSession.make(frozen: true)
                print(String(format: "freeze capture of %d display(s): %.0f ms", session.shots.count, Date().timeIntervalSince(t) * 1000))
                for shot in session.shots.values {
                    print("  display \(shot.displayID): \(shot.image.width)x\(shot.image.height) @\(shot.scale)x")
                }
                print("windows found:", session.windows.count)
                if let shot = session.shots.values.first { write(shot.image, to: output) }
                exit(0)
            } catch {
                print("capture failed:", error)
                exit(1)
            }
        }
        NSApp.run()
    }
}
#endif
