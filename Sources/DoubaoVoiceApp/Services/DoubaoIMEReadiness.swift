import AppKit
import Foundation

/// 把豆包输入法进程养在后台，避免闲置后第一次按快捷键再付一遍冷启动代价。
///
/// 切回其他输入源后，豆包进程可能退出。下次按说话快捷键时，
/// 即使 TIS 已报成功，进程和 IMK 仍可能没准备好。
///
/// 保活不走 TIS：豆包输入法是 `LSBackgroundOnly`，直接静默打开
/// `/Library/Input Methods/DoubaoIme.app` 就能把进程拉起来，当前输入法不变，
/// 菜单栏也不会闪。TIS 切过去再切回来只作为静默拉起失败时的退路。
///
/// 启动 / 唤醒先拉一次；之后靠定时器 + 进程退出通知续命。
/// 不在打字中途切输入法。
final class DoubaoIMEReadiness {

    /// 等豆包进程出现的上限。开机时系统在忙，进程可能晚几秒。
    private let processWaitTimeout: TimeInterval = 5.0
    private let processPollInterval: TimeInterval = 0.05
    /// 进程起来后再坐一会儿，让 IMK 真正完成挂载（仅 TIS 退路需要）。
    private let settleDuration: TimeInterval = 0.8
    /// 退出通知可能漏掉，短轮询补上；只查进程，不唤起窗口或触发录音。
    private let keepAliveInterval: TimeInterval = 5
    private let maximumRetryDelay: TimeInterval = 30
    private let stableProcessDuration: TimeInterval = 30

    /// 已确认进程在跑；不代表当前前台 App 的输入上下文已经挂载。
    private(set) var hasWarmedUp = false

    private var isRunning = false
    private var isLaunching = false
    private var restoreSource: InputSource?
    private var generation = 0
    private var pendingWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var nextLaunchAllowedAt = Date.distantPast
    private var lastLaunchAt: Date?
    private var retryDelay: TimeInterval = 1
    private var isCancelled = false
    private var keepAliveTimer: Timer?
    private var terminateObserver: NSObjectProtocol?
    private var canRunKeepAlive: () -> Bool = { true }

    var isWarmupInProgress: Bool { isRunning || isLaunching }

    /// 语音启动打断预热：取消「切回去」，把原本要恢复的输入源交给调用方。
    /// 没在预热时返回 nil。
    @discardableResult
    func claimForVoiceStart() -> InputSource? {
        let wasWarming = isRunning || isLaunching
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
        retryWork?.cancel()
        retryWork = nil
        isRunning = false
        isLaunching = false
        let saved = restoreSource
        restoreSource = nil
        // 进程刚被拉起、settle 可能还没走完，不把这次算作成热，
        // 让随后的 Option 单击走冷启动的更长等待。
        if wasWarming {
            Logger.shared.info("豆包输入法预热交给语音启动接管，取消后台切回及失败回退")
        }
        return saved
    }

    func cancel() {
        isCancelled = true
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
        retryWork?.cancel()
        retryWork = nil
        isRunning = false
        isLaunching = false
        restoreSource = nil
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    /// 语音胶囊已经确认出现：输入法进程和挂载都是活的。
    func markReady() {
        hasWarmedUp = true
    }

    /// 启动定时保活。进程被系统收掉后会静默再拉起来，不切当前输入法。
    func startKeepAlive(canRun: @escaping () -> Bool) {
        isCancelled = false
        canRunKeepAlive = canRun
        guard keepAliveTimer == nil else { return }

        let timer = Timer(timeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            self?.ensureProcessRunning(reason: "保活", allowTISFallback: false)
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == DoubaoVoiceHUDDetector.imeBundleID
            else { return }
            self?.hasWarmedUp = false
            Logger.shared.info("豆包输入法进程已退出，稍后静默拉起")
            self?.scheduleEnsureProcess(after: 0.2, reason: "进程退出")
        }
    }

    /// 预热豆包输入法。进程已经在跑就直接记成已预热，避免无谓地闪菜单栏图标。
    func warmup(reason: String) {
        ensureProcessRunning(reason: reason, allowTISFallback: true)
    }

    /// 进程不在就静默拉起；只有静默拉起失败才走 TIS 切过去再切回来。
    func ensureProcessRunning(reason: String, allowTISFallback: Bool) {
        guard !isCancelled else { return }
        if DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            hasWarmedUp = true
            // 连续稳定运行后才清空退避；刚拉起就崩溃的进程不能反复高速重启。
            if lastLaunchAt.map({ Date().timeIntervalSince($0) >= stableProcessDuration }) ?? true {
                retryDelay = 1
                nextLaunchAllowedAt = .distantPast
            }
            if reason != "保活" {
                Logger.shared.info("豆包输入法进程已在运行，跳过拉起（\(reason)）")
            }
            return
        }

        guard canRunKeepAlive() else {
            Logger.shared.debug("语音进行中，跳过豆包输入法保活（\(reason)）")
            return
        }
        guard !isLaunching, !isRunning else {
            Logger.shared.debug("豆包输入法预热已在进行，忽略（\(reason)）")
            return
        }
        hasWarmedUp = false
        let remainingDelay = nextLaunchAllowedAt.timeIntervalSinceNow
        guard remainingDelay <= 0 else {
            scheduleEnsureProcess(after: remainingDelay, reason: "拉起重试")
            return
        }

        retryWork?.cancel()
        retryWork = nil
        generation += 1
        let gen = generation
        lastLaunchAt = Date()
        nextLaunchAllowedAt = Date(timeIntervalSinceNow: retryDelay)
        retryDelay = min(retryDelay * 2, maximumRetryDelay)
        isLaunching = true
        Logger.shared.info("豆包输入法进程不在，静默拉起（\(reason)）")
        let finish: (Bool) -> Void = { [weak self] launched in
            self?.finishSilentLaunch(
                generation: gen, launched: launched, reason: reason, allowTISFallback: allowTISFallback
            )
        }
        // openApplication 本身也可能迟迟不回调，不能让 isLaunching 永久卡住。
        let timeout = DispatchWorkItem { finish(false) }
        pendingWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + processWaitTimeout, execute: timeout)
        launchIMEProcess(generation: gen, then: finish)
    }

    // MARK: - 静默拉起

    private func scheduleEnsureProcess(after delay: TimeInterval, reason: String) {
        guard !isCancelled else { return }
        retryWork?.cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == gen, !self.isCancelled else { return }
            self.retryWork = nil
            self.ensureProcessRunning(reason: reason, allowTISFallback: false)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finishSilentLaunch(generation gen: Int, launched: Bool, reason: String, allowTISFallback: Bool) {
        guard generation == gen, isLaunching, !isCancelled else { return }
        pendingWork?.cancel()
        pendingWork = nil
        isLaunching = false
        if launched || DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            hasWarmedUp = true
            Logger.shared.info("豆包输入法进程已在运行（\(reason)）")
            return
        }
        // 用户可能已经开始录音。旧的启动失败回调不能抢输入法或启动 TIS 退路。
        if allowTISFallback, canRunKeepAlive() {
            warmupBySelectingIME(reason: reason)
        } else {
            Logger.shared.warn("静默拉起豆包输入法失败，稍后重试（\(reason)）")
            scheduleEnsureProcess(after: max(0.2, nextLaunchAllowedAt.timeIntervalSinceNow), reason: "拉起失败")
        }
    }

    private func launchIMEProcess(generation gen: Int, then completion: @escaping (Bool) -> Void) {
        if DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            completion(true)
            return
        }
        guard let url = DoubaoVoiceHUDDetector.imeAppURL() else {
            Logger.shared.warn("找不到豆包输入法 App，无法静默拉起进程")
            completion(false)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen, self.isLaunching, !self.isCancelled else { return }
                if let error {
                    Logger.shared.warn("静默拉起豆包输入法失败: \(error.localizedDescription)")
                    completion(false)
                    return
                }
                self.waitForProcess(generation: gen, deadline: Date(timeIntervalSinceNow: self.processWaitTimeout)) { ok in
                    completion(ok)
                }
            }
        }
    }

    // MARK: - TIS 退路

    /// 静默拉起失败时：切到豆包把进程唤起来，再切回原来的输入源。
    private func warmupBySelectingIME(reason: String) {
        if DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            hasWarmedUp = true
            Logger.shared.info("豆包输入法进程已在运行，跳过预热（\(reason)）")
            return
        }

        guard !isRunning, !isCancelled, canRunKeepAlive() else {
            Logger.shared.debug("豆包输入法预热已在进行，忽略（\(reason)）")
            return
        }

        let original = InputSourceManager.nowSource()
        guard selectDoubao() else {
            Logger.shared.warn("豆包输入法预热失败：切不到豆包（\(reason)）")
            scheduleEnsureProcess(after: max(0.2, nextLaunchAllowedAt.timeIntervalSinceNow), reason: "预热失败")
            return
        }

        generation += 1
        let gen = generation
        isRunning = true
        restoreSource = original
        Logger.shared.info("开始预热豆包输入法（\(reason)）")

        waitForProcess(generation: gen, deadline: Date(timeIntervalSinceNow: processWaitTimeout)) { [weak self] ok in
            guard let self = self, self.generation == gen, self.isRunning else { return }
            guard ok else {
                Logger.shared.warn("豆包输入法预热超时：进程没起来（\(reason)）")
                self.finishWarmup(generation: gen, warmedUp: false)
                return
            }

            Logger.shared.debug("豆包输入法进程已起来，再等 \(self.settleDuration)s 让输入法挂稳")
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.generation == gen, self.isRunning else { return }
                self.pendingWork = nil
                self.finishWarmup(generation: gen, warmedUp: true)
            }
            self.pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDuration, execute: work)
        }
    }

    private func waitForProcess(generation gen: Int, deadline: Date, then completion: @escaping (Bool) -> Void) {
        guard generation == gen, (isLaunching || isRunning), !isCancelled else { return }
        if DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            completion(true)
            return
        }
        if Date() >= deadline {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + processPollInterval) { [weak self] in
            self?.waitForProcess(generation: gen, deadline: deadline, then: completion)
        }
    }

    private func finishWarmup(generation: Int, warmedUp: Bool) {
        guard self.generation == generation, isRunning else { return }

        let target = restoreSource
        isRunning = false
        restoreSource = nil
        hasWarmedUp = warmedUp

        restoreIfNeeded(target)
        if warmedUp {
            Logger.shared.info("豆包输入法预热完成，进程已在运行")
        } else {
            scheduleEnsureProcess(after: max(0.2, nextLaunchAllowedAt.timeIntervalSinceNow), reason: "预热失败")
        }
    }

    private func restoreIfNeeded(_ target: InputSource?) {
        guard isDoubaoActive() else {
            Logger.shared.debug("预热结束时已不是豆包输入法，跳过切回")
            return
        }
        guard let target = target, !isDoubaoSource(target) else {
            Logger.shared.debug("预热没有可切回的输入源，保持豆包输入法")
            return
        }

        let ok: Bool
        switch target.kind {
        case .method:
            ok = (target.sourceID.flatMap { InputSourceManager.selectSource(byID: $0) } ?? false)
                || InputSourceManager.selectMethod(byName: target.value)
        case .layout:
            ok = (target.sourceID.flatMap { InputSourceManager.selectSource(byID: $0) } ?? false)
                || InputSourceManager.selectLayout(byName: target.value)
        }
        Logger.shared.debug(
            "预热结束，切回 \(target.kind.rawValue): \(target.value)(\(target.sourceID ?? "nil")), 结果: \(ok)"
        )
    }

    private func selectDoubao() -> Bool {
        if InputSourceManager.selectSource(byID: DoubaoVoiceController.targetInputSourceID) {
            return true
        }
        return InputSourceManager.selectMethod(byName: DoubaoVoiceController.targetInputMethod)
    }

    private func isDoubaoActive() -> Bool {
        InputSourceManager.currentSourceID() == DoubaoVoiceController.targetInputSourceID
            || InputSourceManager.currentMethod() == DoubaoVoiceController.targetInputMethod
    }

    private func isDoubaoSource(_ source: InputSource) -> Bool {
        source.sourceID == DoubaoVoiceController.targetInputSourceID
            || (source.kind == .method && source.value == DoubaoVoiceController.targetInputMethod)
    }
}
