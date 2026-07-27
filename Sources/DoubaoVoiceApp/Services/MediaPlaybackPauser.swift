import AppKit
import Foundation

/// 语音输入期间暂停系统「正在播放 (Now Playing)」的媒体，会话收尾后恢复。
///
/// 恢复不能在收尾点立刻做：豆包放掉麦克风前，蓝牙耳机停在通话档（HFP，
/// 音量映射与正常播放不同），这时拉起音乐会先偏响、路由切回时再跳一次。
/// 胶囊消失也不是可靠信号（实测路由恢复晚于胶囊消失），所以正常收尾走
/// resumeAfterVoiceSessionWhenRouteSettles()，由 AudioRouteSettler 盯着
/// CoreAudio 信号等路由真正退回，再经静音预热后恢复。
///
/// 汽水音乐、抖音、Music、Spotify、浏览器视频等都注册系统媒体会话，谁在播
/// 就暂停谁；会议通话类音频（Zoom/飞书）不注册该会话，不会被误暂停。
///
/// macOS 15.4 起 MediaRemote 私有框架只对 Apple 平台二进制返回真实数据
/// （普通第三方进程拿到的是 isPlaying=false 的假数据），所以真正的调用
/// 发生在系统自带的 /usr/bin/perl 进程内：spawn perl 执行
/// Resources/mrbridge-host.pl，由它加载 Resources/mrbridge.dylib 完成
/// status / pause / play，详见 Helper/MediaRemoteBridge/。
///
/// 失败安全：helper 缺失（swift build 直跑无 bundle 时）、超时、输出异常
/// 都只记日志，绝不影响语音输入主流程。
///
/// 线程模型：公开方法只在主线程调用（与控制器其余状态一致），helper
/// 进程在内部串行队列执行，结果回主线程。决不能进入事件监听线程。
final class MediaPlaybackPauser {

    // MARK: - 时序常量（单位：秒）

    /// 单次 helper 进程的运行上限。实测 status 约 0.05s、pause/play 约 0.2s，
    /// 超过上限直接杀掉，宁可放弃这次媒体控制也不积压进程。
    private let helperTimeout: TimeInterval = 2.0

    /// 「恢复播放后紧接着又开始新会话」跳过播放状态查询的窗口。
    /// play 命令发出后媒体恢复需要零点几秒，这个窗口内查 status 会误判成
    /// 「没在播放」，导致快速连续说话时第二段的暂停被漏掉。
    private let recentResumeWindow: TimeInterval = 1.0

    /// 会话收尾后等待音频路由退回正常档的上限。超过就直接恢复（可能带一次
    /// 音量跳变）：常见于麦克风被别的 App 长期占用（比如正在开会）。
    private let routeSettleTimeout: TimeInterval = 6.0

    // MARK: - 状态

    private let workQueue = DispatchQueue(label: "MediaPlaybackPauser", qos: .userInitiated)

    /// 音频路由守门人：恢复播放前等蓝牙耳机从通话档退回 A2DP（见其顶部注释）。
    private let routeSettler = AudioRouteSettler()

    // 以下状态只在主线程访问。
    /// 当前这次语音会话是否由本 App 暂停了媒体（true 时结束后必须恢复）。
    private var didPause = false
    /// 被暂停应用的显示名，仅用于日志。
    private var pausedAppName: String?
    /// 代际号：resume 或新 pause 都会 +1，用来作废还在飞行中的 status 回调，
    /// 避免「会话已结束，迟到的查询结果又把媒体暂停掉」。
    private var generation = 0
    /// 最近一次真的发出 play 恢复的时刻（空恢复不记）。
    private var lastResumeAt: Date?
    private var unavailableLogged = false

    // MARK: - 公开接口（主线程）

    /// 语音会话开始：若有媒体正在播放则暂停它。异步执行，不阻塞调用方。
    func pauseForVoiceSession() {
        guard GeneralSettings.pauseMediaDuringVoice else { return }
        guard let helper = availableHelper() else { return }

        generation += 1
        let gen = generation

        // 刚恢复播放又立刻开始新会话：play 还在生效途中，此刻查询会误判
        // 「没在播放」。上个会话确实暂停过媒体，直接按在播处理。
        if let resumeAt = lastResumeAt, Date().timeIntervalSince(resumeAt) < recentResumeWindow {
            markPausedAndSend(helper: helper, appName: pausedAppName)
            return
        }

        run(command: "status", helper: helper) { [weak self] result in
            guard let self = self, gen == self.generation else { return }

            switch result {
            case .failure(let message):
                Logger.shared.warn("查询媒体播放状态失败，跳过本次暂停: \(message)")
            case .success(let json):
                guard json["playing"] as? Bool == true else {
                    Logger.shared.debug("当前没有媒体在播放，无需暂停")
                    return
                }
                let pid = json["pid"] as? Int ?? 0
                self.markPausedAndSend(helper: helper, appName: Self.appName(forPid: pid))
            }
        }
    }

    /// 语音会话结束：立即恢复播放。幂等，可在多个收口重复调用。
    ///
    /// 只用于麦克风从未被占用（启动失败）或等不起（App 退出）的场景；
    /// 正常收尾请走 resumeAfterVoiceSessionWhenRouteSettles()，否则会撞上
    /// 蓝牙通话档窗口，音乐先偏响再跳回正常。
    func resumeAfterVoiceSession() {
        // 作废飞行中的 status 查询：会话已结束，迟到的结果不许再触发暂停。
        // 同时也作废还在等路由沉降的恢复（那份闭包的代际号已过期）。
        generation += 1
        guard didPause else { return }
        performResume()
    }

    /// 语音会话结束：等音频路由退回正常档（豆包放掉麦克风、蓝牙耳机从通话档
    /// 切回 A2DP）后再恢复播放，恢复前先做静音预热。幂等，可重复调用。
    ///
    /// 等待期间若新语音会话开始（pauseForVoiceSession 会推进代际号），本次
    /// 恢复自动作废，待恢复状态（didPause）顺延给新会话，由它的收尾来恢复。
    func resumeAfterVoiceSessionWhenRouteSettles() {
        // 会话已结束：作废飞行中的 status 查询，语义与立即版一致。
        generation += 1
        guard didPause else { return }
        let gen = generation

        routeSettler.waitUntilSettled(timeout: routeSettleTimeout) { [weak self] settled in
            guard let self = self, gen == self.generation, self.didPause else {
                Logger.shared.debug("等待音频路由期间恢复已被接管（新会话或立即恢复），本次不再处理")
                return
            }
            if !settled {
                Logger.shared.warn("音频路由未在时限内退回正常档，直接恢复播放（可能有一次音量跳变）")
            }
            self.routeSettler.primeOutputThenCall { [weak self] in
                guard let self = self, gen == self.generation, self.didPause else { return }
                self.performResume()
            }
        }
    }

    /// 真正发出 play 命令并清理状态。只能由两个 resume 入口调用。
    private func performResume() {
        didPause = false
        lastResumeAt = Date()

        guard let helper = availableHelper() else { return }
        let name = pausedAppName ?? "媒体"
        run(command: "play", helper: helper) { result in
            switch result {
            case .success:
                Logger.shared.info("已恢复 \(name) 的播放")
            case .failure(let message):
                Logger.shared.warn("恢复 \(name) 播放失败: \(message)")
            }
        }
    }

    // MARK: - 暂停动作

    private func markPausedAndSend(helper: HelperFiles, appName: String?) {
        didPause = true
        pausedAppName = appName
        let name = appName ?? "正在播放的媒体"
        run(command: "pause", helper: helper) { result in
            switch result {
            case .success:
                Logger.shared.info("语音输入开始，已暂停 \(name) 的播放")
            case .failure(let message):
                Logger.shared.warn("暂停 \(name) 失败: \(message)")
            }
        }
    }

    private static func appName(forPid pid: Int) -> String? {
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }

    // MARK: - helper 定位

    private struct HelperFiles {
        let script: URL
        let dylib: URL
    }

    private lazy var helperFiles: HelperFiles? = {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let script = resourceURL.appendingPathComponent("mrbridge-host.pl")
        let dylib = resourceURL.appendingPathComponent("mrbridge.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: dylib.path)
        else {
            return nil
        }
        return HelperFiles(script: script, dylib: dylib)
    }()

    private func availableHelper() -> HelperFiles? {
        if let helper = helperFiles { return helper }
        if !unavailableLogged {
            unavailableLogged = true
            Logger.shared.warn("媒体暂停组件缺失（Resources 里没有 mrbridge-host.pl / mrbridge.dylib，swift build 直跑时属正常），「语音时暂停媒体」功能不可用")
        }
        return nil
    }

    // MARK: - helper 进程执行

    private enum HelperResult {
        case success([String: Any])
        case failure(String)
    }

    /// 在工作队列 spawn 一个短命 perl 进程执行命令，结果回主线程。
    /// workQueue 是串行的，保证 pause / play 命令不会乱序。
    private func run(
        command: String,
        helper: HelperFiles,
        completion: @escaping (HelperResult) -> Void
    ) {
        let timeout = helperTimeout
        workQueue.async {
            let started = Date()
            let result = Self.runHelperProcess(command: command, helper: helper, timeout: timeout)
            let elapsed = Date().timeIntervalSince(started)
            Logger.shared.debug(String(format: "媒体控制命令 %@ 完成，耗时 %.2fs", command, elapsed))
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func runHelperProcess(
        command: String,
        helper: HelperFiles,
        timeout: TimeInterval
    ) -> HelperResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [helper.script.path, helper.dylib.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MRB_COMMAND"] = command
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure("启动 perl 失败: \(error.localizedDescription)")
        }

        // 超时兜底：正常情况下 helper 自身 1s 内必然退出。
        let killer = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // 输出只有一行 JSON，读到 EOF 不会有缓冲死锁问题。
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderrText.isEmpty
                ? "退出码 \(process.terminationStatus)，无有效输出（可能已超时被杀）"
                : stderrText
            return .failure(detail)
        }
        guard json["ok"] as? Bool == true else {
            return .failure(json["error"] as? String ?? "helper 返回失败")
        }
        return .success(json)
    }
}
