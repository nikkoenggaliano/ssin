import AppKit

/// The menu bar shown while an editor window is active. Also provides key equivalents (⌘C, ⌘Z, ...).
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SSIN", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SSIN", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit SSIN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "SSIN", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save to Folder", action: #selector(EditorWindowController.saveImage(_:)), keyEquivalent: "s")
        file.addItem(item("Save As…", #selector(EditorWindowController.saveImageAs(_:)), "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let image = NSMenu(title: "Image")
        image.addItem(item("Copy & Close", #selector(EditorWindowController.copyAndClose(_:)), "\r", [.command]))
        image.addItem(item("Copy Text (OCR)", #selector(EditorWindowController.copyRecognizedText(_:)), "c", [.command, .shift]))
        image.addItem(withTitle: "Pin to Screen", action: #selector(EditorWindowController.pinImage(_:)), keyEquivalent: "p")
        image.addItem(withTitle: "Beautify Background", action: #selector(EditorWindowController.toggleBeautify(_:)), keyEquivalent: "b")
        image.addItem(.separator())
        image.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "=")
        image.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        image.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.zoomActualSize(_:)), keyEquivalent: "1")
        image.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindowController.zoomToFit(_:)), keyEquivalent: "0")
        add(image, titled: "Image", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
