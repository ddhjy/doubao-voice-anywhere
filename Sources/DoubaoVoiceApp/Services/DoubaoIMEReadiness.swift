import Foundation

/// 登录 / 唤醒时用 TIS 把豆包输入法进程拉起来，再切回原来的输入源。
///
/// 重启后第一次按说话快捷键时，TIS 会立刻报「已切到豆包」，但 IMK 还没挂上，
/// Option 单击会落空。把这段冷启动代价提前付掉，按键时就不必再等。
/// 只在启动和唤醒时走这条路径，不在打字中途定时切输入法。
final class DoubaoIMEReadiness {

    /// 等豆包进程出现的上限。开机时系统在忙，TIS 虽已返回成功，进程还可能晚几秒。
    private let processWaitTimeout: TimeInterval = 5.0
    private let processPollInterval: TimeInterval = 0.05
    /// 进程起来后再坐一会儿，让 IMK 真正完成挂载。
    private let settleDuration: TimeInterval = 0.8

    /// 本次进程里是否已经成功预热过（或启动时进程已经在跑）。
    /// 语音启动用它判断要不要加长胶囊等待。
    private(set) var hasWarmedUp = false

    private var isRunning = false
    private var restoreSource: InputSource?
    private var generation = 0
    private var pendingWork: DispatchWorkItem?

    var isWarmupInProgress: Bool { isRunning }

    /// 语音启动打断预热：取消「切回去」，把原本要恢复的输入源交给调用方。
    /// 没在预热时返回 nil。
    @discardableResult
    func claimForVoiceStart() -> InputSource? {
        guard isRunning else { return nil }

        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
        isRunning = false
        let saved = restoreSource
        restoreSource = nil
        // 进程刚被拉起、settle 可能还没走完，不把这次算作成热，
        // 让随后的 Option 单击走冷启动的更长等待。
        Logger.shared.info("豆包输入法预热被语音启动打断，保持当前输入法")
        return saved
    }

    func cancel() {
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
        isRunning = false
        restoreSource = nil
    }

    /// 预热豆包输入法。进程已经在跑就直接记成已预热，避免无谓地闪菜单栏图标。
    func warmup(reason: String) {
        if DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            hasWarmedUp = true
            Logger.shared.info("豆包输入法进程已在运行，跳过预热（\(reason)）")
            return
        }

        guard !isRunning else {
            Logger.shared.debug("豆包输入法预热已在进行，忽略（\(reason)）")
            return
        }

        let original = InputSourceManager.nowSource()
        guard selectDoubao() else {
            Logger.shared.warn("豆包输入法预热失败：切不到豆包（\(reason)）")
            return
        }

        generation += 1
        let gen = generation
        isRunning = true
        restoreSource = original
        Logger.shared.info("开始预热豆包输入法（\(reason)）")

        waitForProcess(deadline: Date(timeIntervalSinceNow: processWaitTimeout), generation: gen) { [weak self] ok in
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

    // MARK: - 内部

    private func waitForProcess(
        deadline: Date,
        generation: Int,
        then completion: @escaping (Bool) -> Void
    ) {
        if DoubaoVoiceHUDDetector.isIMEProcessRunning() {
            completion(true)
            return
        }
        if Date() >= deadline {
            completion(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == generation, self.isRunning else { return }
            self.pendingWork = nil
            self.waitForProcess(deadline: deadline, generation: generation, then: completion)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + processPollInterval, execute: work)
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
