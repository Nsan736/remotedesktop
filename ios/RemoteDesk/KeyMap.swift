import UIKit

enum VK {
    static let back: UInt16 = 0x08
    static let tab: UInt16 = 0x09
    static let enter: UInt16 = 0x0D
    static let shift: UInt16 = 0x10
    static let control: UInt16 = 0x11
    static let menu: UInt16 = 0x12
    static let escape: UInt16 = 0x1B
    static let space: UInt16 = 0x20
    static let pageUp: UInt16 = 0x21
    static let pageDown: UInt16 = 0x22
    static let end: UInt16 = 0x23
    static let home: UInt16 = 0x24
    static let left: UInt16 = 0x25
    static let up: UInt16 = 0x26
    static let right: UInt16 = 0x27
    static let down: UInt16 = 0x28
    static let insert: UInt16 = 0x2D
    static let delete: UInt16 = 0x2E
    static let lwin: UInt16 = 0x5B
    static let f1: UInt16 = 0x70
}

enum KeyMap {
    static func vk(for usage: UIKeyboardHIDUsage) -> UInt16? {
        let raw = usage.rawValue
        if raw >= UIKeyboardHIDUsage.keyboardA.rawValue && raw <= UIKeyboardHIDUsage.keyboardZ.rawValue {
            return UInt16(0x41 + (raw - UIKeyboardHIDUsage.keyboardA.rawValue))
        }
        if raw >= UIKeyboardHIDUsage.keyboard1.rawValue && raw <= UIKeyboardHIDUsage.keyboard9.rawValue {
            return UInt16(0x31 + (raw - UIKeyboardHIDUsage.keyboard1.rawValue))
        }
        if raw >= UIKeyboardHIDUsage.keyboardF1.rawValue && raw <= UIKeyboardHIDUsage.keyboardF12.rawValue {
            return UInt16(0x70 + (raw - UIKeyboardHIDUsage.keyboardF1.rawValue))
        }
        switch usage {
        case .keyboard0: return 0x30
        case .keyboardReturnOrEnter, .keypadEnter: return VK.enter
        case .keyboardEscape: return VK.escape
        case .keyboardDeleteOrBackspace: return VK.back
        case .keyboardTab: return VK.tab
        case .keyboardSpacebar: return VK.space
        case .keyboardHyphen: return 0xBD
        case .keyboardEqualSign: return 0xBB
        case .keyboardOpenBracket: return 0xDB
        case .keyboardCloseBracket: return 0xDD
        case .keyboardBackslash: return 0xDC
        case .keyboardSemicolon: return 0xBA
        case .keyboardQuote: return 0xDE
        case .keyboardGraveAccentAndTilde: return 0xC0
        case .keyboardComma: return 0xBC
        case .keyboardPeriod: return 0xBE
        case .keyboardSlash: return 0xBF
        case .keyboardCapsLock: return 0x14
        case .keyboardPrintScreen: return 0x2C
        case .keyboardScrollLock: return 0x91
        case .keyboardPause: return 0x13
        case .keyboardInsert: return VK.insert
        case .keyboardHome: return VK.home
        case .keyboardPageUp: return VK.pageUp
        case .keyboardDeleteForward: return VK.delete
        case .keyboardEnd: return VK.end
        case .keyboardPageDown: return VK.pageDown
        case .keyboardRightArrow: return VK.right
        case .keyboardLeftArrow: return VK.left
        case .keyboardDownArrow: return VK.down
        case .keyboardUpArrow: return VK.up
        case .keyboardLeftControl: return 0xA2
        case .keyboardLeftShift: return 0xA0
        case .keyboardLeftAlt: return 0xA4
        case .keyboardLeftGUI: return 0x5B
        case .keyboardRightControl: return 0xA3
        case .keyboardRightShift: return 0xA1
        case .keyboardRightAlt: return 0xA5
        case .keyboardRightGUI: return 0x5C
        case .keyboardApplication: return 0x5D
        case .keyboardInternational1: return 0xE2
        case .keyboardInternational3: return 0xDC
        case .keyboardInternational4: return 0x1C
        case .keyboardInternational5: return 0x1D
        case .keyboardLANG1: return 0x15
        case .keyboardLANG2: return 0x1D
        case .keypadNumLock: return 0x90
        case .keypadSlash: return 0x6F
        case .keypadAsterisk: return 0x6A
        case .keypadHyphen: return 0x6D
        case .keypadPlus: return 0x6B
        case .keypadPeriod: return 0x6E
        case .keypad0: return 0x60
        case .keypad1: return 0x61
        case .keypad2: return 0x62
        case .keypad3: return 0x63
        case .keypad4: return 0x64
        case .keypad5: return 0x65
        case .keypad6: return 0x66
        case .keypad7: return 0x67
        case .keypad8: return 0x68
        case .keypad9: return 0x69
        default: return nil
        }
    }

    /// Maps a single typed character to a virtual key that produces it with
    /// modifiers held (used for shortcuts like Ctrl+C typed on the soft keyboard).
    static func vk(forShortcutCharacter c: Character) -> UInt16? {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        if v >= 0x61 && v <= 0x7A { return UInt16(v - 0x20) }
        if v >= 0x41 && v <= 0x5A { return UInt16(v) }
        if v >= 0x30 && v <= 0x39 { return UInt16(v) }
        switch c {
        case " ": return VK.space
        case "\n", "\r": return VK.enter
        case "\t": return VK.tab
        case "-": return 0xBD
        case "=": return 0xBB
        case "[": return 0xDB
        case "]": return 0xDD
        case ";": return 0xBA
        case "'": return 0xDE
        case ",": return 0xBC
        case ".": return 0xBE
        case "/": return 0xBF
        default: return nil
        }
    }
}
