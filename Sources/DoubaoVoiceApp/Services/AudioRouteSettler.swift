import AVFoundation
import CoreAudio
import Foundation

/// 语音会话结束后，等系统音频路由从「通话档」退回「正常播放档」，再放行媒体恢复。
///
/// 为什么需要：蓝牙耳机在麦克风被占用期间运行在通话档（HFP/SCO），输出采样率
/// 跌到 8-24kHz，音量映射也与正常听歌的 A2DP 档不同；而且麦克风释放后
/// coreaudiod 不会立刻切回，路由还要滞留一小会。豆包的语音胶囊消失只代表
/// 识别结果已上屏，不代表路由已经退回——实测「胶囊消失 + 1s」后恢复播放，
/// 音乐仍会先以偏大的音量播出、路由切回时再跳一次。所以不猜固定延迟，
/// 直接盯系统信号。
///
/// 判定信号（只读 CoreAudio 属性，无需任何权限，单次读取微秒级）：
/// 1. 默认输入设备 isRunningSomewhere == false：系统里已没有进程在采音，
///    豆包真的放掉了麦克风；
/// 2. 默认输出设备 nominalSampleRate ≥ 32kHz：蓝牙耳机已从通话档回到 A2DP
///    （通话档是 8/16/24kHz；扬声器、有线、USB 输出恒 ≥ 44.1kHz，天然满足）。
/// 两个信号需连续 stableTicksRequired 个轮询周期同时成立，防路由切换途中抖动。
/// 读不到的信号一律按「正常」处理：诊断能力缺失时绝不能把媒体恢复卡死。
///
/// 静音预热：路由退回后，蓝牙耳机重建 A2DP 流的瞬间还可能带一次音量同步跳变
/// （耳机先按自己记住的音量出声，AVRCP 稍后才把系统音量同步过去）。恢复命令
/// 发出前先用一条全零输出流把设备拉起来，让这次跳变发生在无声期里。
///
/// 线程模型：只在主线程使用；轮询是 asyncAfter 链，回调回主线程。
final class AudioRouteSettler {

    // MARK: - 时序常量（单位：秒）

    /// 信号轮询周期。CoreAudio 属性读取是本地 IPC，微秒级，频率不构成负担。
    private let pollInterval: TimeInterval = 0.15
    /// 信号需连续成立的周期数（约 0.3s），容忍路由切换过程中的短暂抖动。
    private let stableTicksRequired = 2
    /// 静音预热时长：恢复命令发出前，先让输出设备以无声流跑这么久，
    /// 蓝牙建流的音量同步跳变会落在这段静音里。
    private let primeLeadDuration: TimeInterval = 0.5
    /// play 命令发出后静音流再保持这么久才释放，保证媒体接手前设备不掉线。
    private let primeTailDuration: TimeInterval = 1.0
    /// 通话档 / 正常档的采样率分界：HFP 是 8/16/24kHz，A2DP 是 44.1/48kHz。
    private let normalSampleRateFloor: Double = 32_000

    // MARK: - 状态（主线程访问）

    /// 代际号：新一轮等待会作废还挂着的旧轮询链。
    private var generation = 0
    /// 正在运行的静音预热流；nil 表示没在预热。
    private var primer: SilencePrimer?

    // MARK: - 公开接口（主线程）

    /// 等待路由退回正常档后回调；超时也回调（settled=false），绝不吞掉回调。
    /// 再次调用会作废上一次还没完成的等待（旧 completion 不再被执行）。
    func waitUntilSettled(timeout: TimeInterval, completion: @escaping (_ settled: Bool) -> Void) {
        generation += 1
        let snapshot = Self.probe()
        if snapshot.isNormal(rateFloor: normalSampleRateFloor) {
            // 信号当下就满足（扬声器输出、麦克风早已释放等常见情形），直接放行。
            Logger.shared.debug("音频路由已在正常档（\(snapshot.describe())），无需等待")
            completion(true)
            return
        }
        Logger.shared.debug("等待音频路由退回正常档: \(snapshot.describe())")
        poll(
            gen: generation,
            deadline: Date(timeIntervalSinceNow: timeout),
            stableTicks: 0,
            started: Date(),
            completion: completion
        )
    }

    /// 恢复播放前的静音预热：先以无声流预热输出设备 primeLeadDuration，再执行
    /// body；body 执行后无声流保持 primeTailDuration 才释放。预热启动失败或
    /// 已有预热在跑时不额外等待，直接执行 body——预热只是锦上添花，不许添堵。
    func primeOutputThenCall(_ body: @escaping () -> Void) {
        if primer != nil {
            body()
            return
        }
        let newPrimer = SilencePrimer()
        guard newPrimer.start() else {
            body()
            return
        }
        primer = newPrimer
        let tail = primeTailDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + primeLeadDuration) { [weak self] in
            body()
            DispatchQueue.main.asyncAfter(deadline: .now() + tail) {
                newPrimer.stop()
                if let self = self, self.primer === newPrimer {
                    self.primer = nil
                }
            }
        }
    }

    // MARK: - 轮询

    private func poll(
        gen: Int,
        deadline: Date,
        stableTicks: Int,
        started: Date,
        completion: @escaping (_ settled: Bool) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self = self, gen == self.generation else { return }

            let snapshot = Self.probe()
            let ticks = snapshot.isNormal(rateFloor: self.normalSampleRateFloor) ? stableTicks + 1 : 0
            if ticks >= self.stableTicksRequired {
                Logger.shared.debug(String(
                    format: "音频路由已退回正常档（等待 %.2fs）: %@",
                    Date().timeIntervalSince(started), snapshot.describe()
                ))
                completion(true)
                return
            }
            if Date() >= deadline {
                Logger.shared.warn("等待音频路由退回正常档超时: \(snapshot.describe())")
                completion(false)
                return
            }
            self.poll(gen: gen, deadline: deadline, stableTicks: ticks, started: started, completion: completion)
        }
    }

    // MARK: - CoreAudio 信号读取

    private struct RouteSnapshot {
        var inputRunning: Bool?
        var outputSampleRate: Double?

        func isNormal(rateFloor: Double) -> Bool {
            // 读不到（nil）按正常算：不能因为诊断失败卡住媒体恢复。
            let micIdle = inputRunning != true
            let rateOK = outputSampleRate.map { $0 >= rateFloor } ?? true
            return micIdle && rateOK
        }

        func describe() -> String {
            let running = inputRunning.map { $0 ? "占用中" : "空闲" } ?? "未知"
            let rate = outputSampleRate.map { String(format: "%.0fHz", $0) } ?? "未知"
            return "输入设备\(running)，输出采样率 \(rate)"
        }
    }

    private static func probe() -> RouteSnapshot {
        var snapshot = RouteSnapshot()
        if let device = defaultDeviceID(input: true) {
            snapshot.inputRunning = isRunningSomewhere(device)
        }
        if let device = defaultDeviceID(input: false) {
            snapshot.outputSampleRate = nominalSampleRate(device)
        }
        return snapshot
    }

    private static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: input
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }
}

/// 一条全零的输出流。跑起来时输出设备处于活跃状态（蓝牙 A2DP 流已建立、
/// 音量已同步），但用户听不到任何声音——双保险：源节点写零 + 混音器音量 0。
private final class SilencePrimer {
    private let engine = AVAudioEngine()

    /// 启动静音流；输出设备异常（无设备、格式不可用）时返回 false，不抛错。
    func start() -> Bool {
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: hardwareFormat.sampleRate,
                  channels: hardwareFormat.channelCount
              )
        else {
            Logger.shared.debug("静音预热不可用：输出设备格式异常")
            return false
        }

        let silenceSource = AVAudioSourceNode(format: format) { isSilence, _, _, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            isSilence.pointee = true
            return noErr
        }
        engine.attach(silenceSource)
        engine.connect(silenceSource, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        do {
            try engine.start()
            return true
        } catch {
            Logger.shared.debug("静音预热启动失败（不影响恢复）: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        engine.stop()
    }
}
