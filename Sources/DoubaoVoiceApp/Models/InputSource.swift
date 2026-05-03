import Foundation

/// 输入源描述：用 `kind` 区分输入法 / 键盘布局，`sourceID` 是稳定身份，`value` 是可显示的 localized name。
struct InputSource: Equatable, CustomStringConvertible {
    enum Kind: String { case method, layout }

    let kind: Kind
    let value: String
    let sourceID: String?

    var description: String {
        "InputSource(kind=\(kind.rawValue), value=\(value), sourceID=\(sourceID ?? "nil"))"
    }
}
