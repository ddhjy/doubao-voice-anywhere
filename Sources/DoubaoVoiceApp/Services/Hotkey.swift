import CoreGraphics
import Foundation

/// 一个用户可配置的快捷键。
///
/// 三种形态，判定路径不同：
///   - 组合键（`⌃Space`）：修饰键 + 普通键，走 keyDown，按下即触发并吞掉按键。
///   - 裸普通键（`F13`）：走 keyDown，按下即触发并吞掉按键。
///   - 裸修饰键（单独点一下 `⌥`）：走 flagsChanged，抬起时才触发，且要求按下
///     期间没配合别的键或鼠标。除 Fn 外一律不吞——吞了 `⌥C` 这类组合就废了。
///
/// 修饰键不分左右：左右 Option 归一到同一个键码，用户随手点哪边都算。
struct Hotkey: Equatable, CustomStringConvertible {

    /// 左右归一后的修饰键。
    enum ModifierKey: CaseIterable {
        case fn, control, option, shift, command

        /// 系统里左右两侧的虚拟键码，第一个是归一后的代表值。
        var keyCodes: [Int64] {
            switch self {
            case .fn: return [63]
            case .control: return [59, 62]
            case .option: return [58, 61]
            case .shift: return [56, 60]
            case .command: return [55, 54]
            }
        }

        var canonicalKeyCode: Int64 { keyCodes[0] }

        var flag: CGEventFlags {
            switch self {
            case .fn: return .maskSecondaryFn
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .shift: return .maskShift
            case .command: return .maskCommand
            }
        }

        /// 菜单里的惯例写法。`allCases` 的顺序就是拼接顺序。
        var symbol: String {
            switch self {
            case .fn: return "Fn"
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }

        static func forKeyCode(_ keyCode: Int64) -> ModifierKey? {
            allCases.first { $0.keyCodes.contains(keyCode) }
        }
    }

    /// 参与匹配的修饰键位。CapsLock（`maskAlphaShift`）和小键盘位
    /// （`maskNumericPad`，方向键也会带上）一律忽略，与改造前的判定保持一致。
    static let significantModifierMask: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    let keyCode: Int64
    let modifiers: CGEventFlags

    init(keyCode: Int64, modifiers: CGEventFlags = []) {
        let cleaned = modifiers.intersection(Self.significantModifierMask)
        // 裸修饰键左右归一：左右两边录出来是同一个值，比较才不会漏。
        if cleaned.isEmpty, let modifier = ModifierKey.forKeyCode(keyCode) {
            self.keyCode = modifier.canonicalKeyCode
        } else {
            self.keyCode = keyCode
        }
        self.modifiers = cleaned
    }

    // MARK: - 形态

    /// 非 nil 表示这是「裸修饰键轻按」形态。
    var bareModifier: ModifierKey? {
        guard modifiers.isEmpty else { return nil }
        return ModifierKey.forKeyCode(keyCode)
    }

    var isBareModifier: Bool { bareModifier != nil }

    /// 触发后要不要把按键吞掉。
    ///
    /// 裸修饰键一律透传，否则它就没法再当修饰键用了。Fn 是唯一例外：单独按 Fn
    /// 系统会弹 Emoji 面板 / 听写，不吞掉就会和语音一起冒出来。
    var swallowsEvent: Bool {
        guard let modifier = bareModifier else { return true }
        return modifier == .fn
    }

    /// 无修饰的普通键会被全局吞掉，设成字母数字这类就打不出字了，需要提醒用户。
    var swallowsCommonTypingKey: Bool {
        guard !isBareModifier, modifiers.isEmpty else { return false }
        return !Self.safeBareKeyCodes.contains(keyCode)
    }

    // MARK: - 匹配

    /// keyDown 形态的匹配。裸修饰键走 flagsChanged，这里恒为 false。
    func matchesKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard !isBareModifier, keyCode == self.keyCode else { return false }
        return flags.intersection(Self.significantModifierMask) == modifiers
    }

    /// 这条 flagsChanged 是不是本快捷键那个修饰键发出来的（左右都算）。
    func matchesModifierKeyCode(_ keyCode: Int64) -> Bool {
        bareModifier?.keyCodes.contains(keyCode) ?? false
    }

    /// 配合 `matchesModifierKeyCode` 用：该修饰键此刻是按下还是抬起。
    func modifierIsPressed(in flags: CGEventFlags) -> Bool {
        guard let modifier = bareModifier else { return false }
        return flags.contains(modifier.flag)
    }

    // MARK: - 显示

    /// 面向用户的写法：`⌃Space`、`⌥`、`⌘⇧A`、`Fn F13`。
    var displayString: String {
        if let modifier = bareModifier { return modifier.symbol }

        let symbols = ModifierKey.allCases
            .filter { modifiers.contains($0.flag) }
            .map(\.symbol)
            .joined()
        let name = Self.keyName(for: keyCode)
        guard let last = symbols.last else { return name }
        // "Fn" 是字母写法，直接贴上去会糊成 "FnF13"。
        return last.isLetter ? "\(symbols) \(name)" : symbols + name
    }

    var description: String { displayString }

    static func keyName(for keyCode: Int64) -> String {
        keyNames[keyCode] ?? "键码 \(keyCode)"
    }

    /// US 布局的键码表。只用于显示，匹配始终按键码走，换布局不影响功能。
    private static let keyNames: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        64: "F17", 65: "小键盘 .", 67: "小键盘 *", 69: "小键盘 +", 71: "Clear",
        75: "小键盘 /", 76: "⌤", 78: "小键盘 -", 79: "F18", 80: "F19", 81: "小键盘 =",
        82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2", 85: "小键盘 3", 86: "小键盘 4",
        87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7", 90: "F20", 91: "小键盘 8",
        92: "小键盘 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 110: "菜单键", 111: "F12",
        113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘",
        120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// 这些键单独吞掉不影响正常输入（功能键、Help），其余裸键都会打断打字。
    private static let safeBareKeyCodes: Set<Int64> = [
        64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113,
        114, 118, 120, 122,
    ]
}
