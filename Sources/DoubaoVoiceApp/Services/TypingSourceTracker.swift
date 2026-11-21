import Foundation

/// 记住「打字用的输入源」：语音结束后切回它。
///
/// 不能直接用「最近一个非豆包输入源」。豆包全局语音唤起自己时不是一步切过去的：
/// 它先发一次系统的「选择上一个输入法」快捷键，约 0.3s 后发现没落在豆包上才再切一次。
/// 中间会闪过系统记的「上一个输入源」——只用两个输入源打字的人，闪过的恰好是另一个：
/// 在鼠须管下说话会闪一下 ABC，说完就被切回 ABC。
///
/// 所以「从别的打字输入源切过来、不到 `transientWindow` 又切到豆包」的那个算中转，
/// 作废，打字输入源退回它顶替掉的那一个。从豆包切回来的不算中转：人已经在豆包里时，
/// 豆包不需要绕这一下。
///
/// 纯值类型，不碰 TIS，时间由调用方传入。只在主线程使用。
struct TypingSourceTracker {

    /// 中转实测固定停留约 0.32s，留三倍余量。
    static let transientWindow: TimeInterval = 1.0

    enum Event: Equatable {
        /// 打字输入源换成了它。
        case adopted(InputSource)
        /// 它只是切到豆包途中的中转，作废；打字输入源退回 `kept`。
        case discarded(InputSource, heldFor: TimeInterval, kept: InputSource)
    }

    /// 当前认定的打字输入源。
    var current: InputSource? { last?.source }

    /// `replaced`：它直接顶替掉的那个打字输入源；从豆包切回来的、本 App 自己切的都是 nil。
    private var last: (source: InputSource, since: TimeInterval, replaced: InputSource?)?
    private(set) var doubaoActive = false

    /// 系统通知输入源变了。`source` 传 nil 表示当前是豆包。
    ///
    /// 同一个输入源会连着通知好几次（切 App、切窗口也会发），重复的不重新计时。
    mutating func observe(_ source: InputSource?, at now: TimeInterval) -> [Event] {
        guard let source = source else {
            doubaoActive = true
            guard let transient = last, let replaced = transient.replaced,
                  now - transient.since < Self.transientWindow
            else { return [] }
            last = (replaced, transient.since, nil)
            return [.discarded(transient.source, heldFor: now - transient.since, kept: replaced)]
        }

        let cameFromDoubao = doubaoActive
        doubaoActive = false
        if let last = last, Self.isSame(last.source, source) { return [] }
        last = (source, now, cameFromDoubao ? nil : last?.source)
        return [.adopted(source)]
    }

    /// 本 App 自己切过去的（轮换、语音后切回）：直接算数，之后不会被当成中转。
    mutating func confirm(_ source: InputSource, at now: TimeInterval) -> [Event] {
        let changed = last.map { !Self.isSame($0.source, source) } ?? true
        last = (source, now, nil)
        return changed ? [.adopted(source)] : []
    }

    /// localized name 在不同 locale 下可能不一致，有 sourceID 就只认 sourceID。
    static func isSame(_ lhs: InputSource, _ rhs: InputSource) -> Bool {
        if let left = lhs.sourceID, let right = rhs.sourceID { return left == right }
        return lhs.kind == rhs.kind && lhs.value == rhs.value
    }
}
