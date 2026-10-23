import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: a virtual key code plus modifier flags.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt

    static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantFlags).rawValue
    }

    init(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevantFlags)
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    var modifierSymbols: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    var keyName: String {
        Self.specialKeyNames[Int(keyCode)] ?? Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    var displayString: String { modifierSymbols + keyName }

    /// Key equivalent string for showing the shortcut in an NSMenuItem.
    var menuKeyEquivalent: String {
        if let fn = Self.functionKeyNumbers[Int(keyCode)], let scalar = UnicodeScalar(NSF1FunctionKey + fn - 1) {
            return String(Character(scalar))
        }
        let arrows: [Int: Int] = [kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
                                  kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey]
        if let a = arrows[Int(keyCode)], let scalar = UnicodeScalar(a) {
            return String(Character(scalar))
        }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        default: return Self.character(for: keyCode)?.lowercased() ?? ""
        }
    }

    static func isFunctionKey(_ code: UInt16) -> Bool { functionKeyNumbers[Int(code)] != nil }

    private static let functionKeyNumbers: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
        kVK_F19: 19, kVK_F20: 20,
    ]

    private static let specialKeyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        ]
        for (code, n) in functionKeyNumbers { names[code] = "F\(n)" }
        return names
    }()

    /// The character a key produces on the current keyboard layout (e.g. "2" for kVK_ANSI_2).
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
