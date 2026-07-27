# 项目约定（给 AI 协作与贡献者）

## 构建与验证

- `./install-app.sh` 是默认编译脚本：编译 → 打包 `.app` → 安装到 `~/Applications` → 启动。
- 只验证编译用 `swift build`；只打包不安装用 `./build.sh`。
- 没有单元测试；行为验证靠日志 `~/Library/Logs/DoubaoVoiceApp/app.log`。
- 发布靠推 `v*` tag 触发 `.github/workflows/release.yml`：universal 编译 → Developer ID 签名 → Apple 公证 → 装订票据 → 建 GitHub Release。CI 凭证用 `./setup-ci-secrets.sh` 配一次。
- universal 包必须逐架构编译再 `lipo` 合并（见 `build.sh`）。别改回一条 `swift build --arch arm64 --arch x86_64`：那会切到 Xcode build system，在 Xcode 26 上必崩在「The Xcode build system has terminated」。
- App 图标是入库产物（`Resources/AppIcon.icns` + `AppIcon.icon` + `Assets.car`），改设计编辑 `tools/GenerateAppIcon.swift` 后执行 `swift tools/GenerateAppIcon.swift` 重新生成（编 `Assets.car` 需要 Xcode 26 的 actool）。icns 走 `CFBundleIconFile` 服务 macOS 13–15，`Assets.car` 走 `CFBundleIconName` 让 macOS 26+ 满版显示——只有 icns 时 Tahoe 会把图标缩小垫在白色底板上。CI（macos-14 runner）没有 Xcode 26，`build.sh` 只拷贝不生成。
- 有真实证书时 `build.sh` 一律带 Hardened Runtime（公证前提）；安全时间戳要联网，只由 `CODE_SIGN_TIMESTAMP=1` 打开，本地默认关着好让断网也能签。

## 架构速览

- `Sources/DoubaoVoiceApp/Controllers/DoubaoVoiceController.swift`：主状态机（说话快捷键 → 切豆包 → 触发语音 → 恢复输入法），所有时序常量集中在文件顶部。快捷键匹配只读 `HotkeySnapshot` 这份加锁快照，主线程算、事件线程读。
- `Sources/DoubaoVoiceApp/Services/Hotkey.swift`：可配置快捷键的值类型。组合键 / 功能键走 keyDown 按下即触发并吞键；单独修饰键走 flagsChanged，抬起时才触发且要求按下期间没配合别的输入，除 Fn 外一律不吞（Fn 不吞系统会额外弹听写 / Emoji 面板）。修饰键不分左右。
- `Sources/DoubaoVoiceApp/Controllers/EventTapController.swift`：CGEventTap 包装，独立线程。
- `Sources/DoubaoVoiceApp/Services/GeneralSettings.swift`：用户配置（UserDefaults），默认值必须与老版本硬编码一致。
- `Sources/DoubaoVoiceApp/Services/DoubaoVoiceHUDDetector.swift`：用豆包语音胶囊窗口作为「是否在录音」的真值源。
- `Sources/DoubaoVoiceApp/Services/KeyboardSimulator.swift`：合成「左 Option 单击」触发豆包语音。合成事件带自识别标记（`isSynthetic`），三个事件回调开头都要先放行它——不然把快捷键设成单独点 Option 会自触发甚至递归。
- `Sources/DoubaoVoiceApp/Services/MediaPlaybackPauser.swift`：语音期间暂停/恢复系统「正在播放」的媒体。macOS 15.4+ 封锁了第三方进程直调 MediaRemote，所以经系统自带 perl 宿主执行 `Helper/MediaRemoteBridge/`（build.sh 编译进 Resources）；helper 失败只记日志，不许影响语音主流程。
- `Sources/DoubaoVoiceApp/Views/`：设置界面（SwiftUI）。`PreferencesWindowController` 只剩 `NSTabViewController`（`.toolbar` 分栏）外壳，每个分栏是 `NSHostingController` 托管的分组 `Form`；`SettingsStore` 只做状态桥接，真值仍在各服务里，写入一律走原有 setter。`HotkeyRecorder` 用 `NSEvent` local monitor 录键位，录制期间必须调 `setHotkeyCaptureActive(true)` 让 event tap 让路，否则已生效的快捷键会先被吞掉。

## 硬约束

1. 事件监听线程的回调（`EventTapDelegate` 各方法）必须立即返回，禁止 TIS、磁盘同步 IO 等可能阻塞的调用——阻塞超过约 1 秒系统会禁用整个 tap。
2. 不要破坏配置默认值的向后兼容：老用户升级后行为不能变。
3. 面向用户的文案（菜单、弹窗、日志）用简体中文。
4. 部署目标是 macOS 13，别用更高版本才有的 API（CI 跑在 macos-14 runner 上，本机 SDK 更新，编不出错不代表用户能跑）。
