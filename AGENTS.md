# 项目约定（给 AI 协作与贡献者）

## 构建与验证

- `./install-app.sh` 是默认编译脚本：编译 → 打包 `.app` → 安装到 `~/Applications` → 启动。
- 只验证编译用 `swift build`；只打包不安装用 `./build.sh`。
- 没有单元测试；行为验证靠日志 `~/Library/Logs/DoubaoVoiceApp/app.log`。

## 架构速览

- `Sources/DoubaoVoiceApp/Controllers/DoubaoVoiceController.swift`：主状态机（Fn 轻按 → 切豆包 → 触发语音 → 恢复输入法），所有时序常量集中在文件顶部。
- `Sources/DoubaoVoiceApp/Controllers/EventTapController.swift`：CGEventTap 包装，独立线程。
- `Sources/DoubaoVoiceApp/Services/GeneralSettings.swift`：用户配置（UserDefaults），默认值必须与老版本硬编码一致。
- `Sources/DoubaoVoiceApp/Services/DoubaoVoiceHUDDetector.swift`：用豆包语音胶囊窗口作为「是否在录音」的真值源。
- `Sources/DoubaoVoiceApp/Services/MediaPlaybackPauser.swift`：语音期间暂停/恢复系统「正在播放」的媒体。macOS 15.4+ 封锁了第三方进程直调 MediaRemote，所以经系统自带 perl 宿主执行 `Helper/MediaRemoteBridge/`（build.sh 编译进 Resources）；helper 失败只记日志，不许影响语音主流程。

## 硬约束

1. 事件监听线程的回调（`EventTapDelegate` 各方法）必须立即返回，禁止 TIS、磁盘同步 IO 等可能阻塞的调用——阻塞超过约 1 秒系统会禁用整个 tap。
2. 不要破坏配置默认值的向后兼容：老用户升级后行为不能变。
3. 面向用户的文案（菜单、弹窗、日志）用简体中文。
