# 项目约定（给 AI 协作与贡献者）

## 构建与验证

- `./install-app.sh` 是默认编译脚本：编译 → 打包 `.app` → 安装到 `~/Applications` → 启动。
- 本机日常用的是 GitHub Release 正式版（`/Applications`），开发验证一律 `./install-app.sh --dev`：装成「豆包随时说 Dev.app」（bundle ID `com.doubaovoiceapp.menubar.dev`），TCC 授权 / UserDefaults / 登录项 / 日志与正式版按 bundle ID 隔离；两个版本会抢同一个快捷键，所以安装脚本会先退出另一版本的运行实例，别绕过这个逻辑。
- 只验证编译用 `swift build`；只打包不安装用 `./build.sh`（加 `--dev` 同上）。
- 没有单元测试；行为验证靠日志 `~/Library/Logs/DoubaoVoiceApp/app.log`（开发版写 `app-dev.log`）。
- 发布靠推 `main` 上的应用代码触发 `.github/workflows/release.yml`（相对最新 `v*` tag 自动 patch +1）；手动推 `v*` tag 或 `workflow_dispatch` 仍可指定版本。流程：universal 编译 → Developer ID 签名 → Apple 公证 → 装订票据 → 建 GitHub Release（DMG 给新用户 + zip 给自动更新）→ 给 zip 签 EdDSA、往 `appcast.xml` 追条目并推回 `main`。appcast 回推靠提交说明跳过，不会循环出包。CI 凭证用 `./setup-ci-secrets.sh` 配一次。
- `appcast.xml` 在仓库根、跟着 `main` 走，App 里的 `SUFeedURL` 写死指向它的 raw 地址：换路径 / 换分支 = 老版本永久失联。它由 `tools/update-appcast.sh` 生成，别手改。`CFBundleVersion` 必须随版本号单调递增（CI 里就取 tag 的版本号），Sparkle 靠它比新旧。
- universal 包必须逐架构编译再 `lipo` 合并（见 `build.sh`）。别改回一条 `swift build --arch arm64 --arch x86_64`：那会切到 Xcode build system，在 Xcode 26 上必崩在「The Xcode build system has terminated」。
- App 图标是入库产物（`Resources/AppIcon.icns` + `AppIcon.icon` + `Assets.car`），改设计编辑 `tools/GenerateAppIcon.swift` 后执行 `swift tools/GenerateAppIcon.swift` 重新生成（编 `Assets.car` 需要 Xcode 26 的 actool）。icns 走 `CFBundleIconFile` 服务 macOS 13–15，`Assets.car` 走 `CFBundleIconName` 让 macOS 26+ 满版显示——只有 icns 时 Tahoe 会把图标缩小垫在白色底板上。CI（macos-14 runner）没有 Xcode 26，`build.sh` 只拷贝不生成。
- 有真实证书时 `build.sh` 一律带 Hardened Runtime（公证前提）；安全时间戳要联网，只由 `CODE_SIGN_TIMESTAMP=1` 打开，本地默认关着好让断网也能签。

## 架构速览

- `Sources/DoubaoVoiceApp/Controllers/DoubaoVoiceController.swift`：主状态机（说话快捷键 → 切豆包 → 触发语音 → 恢复输入法），所有时序常量集中在文件顶部。快捷键匹配只读 `HotkeySnapshot` 这份加锁快照，主线程算、事件线程读。
- `Sources/DoubaoVoiceApp/Services/Hotkey.swift`：可配置快捷键的值类型。组合键 / 功能键走 keyDown 按下即触发并吞键；单独修饰键走 flagsChanged，抬起时才触发且要求按下期间没配合别的输入，除 Fn 外一律不吞（Fn 不吞系统会额外弹听写 / Emoji 面板）。修饰键不分左右。
- `Sources/DoubaoVoiceApp/Controllers/EventTapController.swift`：CGEventTap 包装，独立线程。
- `Sources/DoubaoVoiceApp/Services/GeneralSettings.swift`：用户配置（UserDefaults），默认值必须与老版本硬编码一致。
- `Sources/DoubaoVoiceApp/Services/DoubaoVoiceHUDDetector.swift`：语音胶囊覆盖录音和识别优化整个会话，可见不等于正在录音。启动前要排除旧胶囊，重试和键盘队列实际发键前都要复查，避免多发 Option 把启动变成停止。首次使用 / 唤醒 / 闲置一分钟后，先刷新输入上下文再发键，不能只看进程是否存活。
- `Sources/DoubaoVoiceApp/Services/DoubaoIMEReadiness.swift`：启动 / 唤醒 / 进程退出时静默拉起豆包输入法进程（不切 TIS），避免闲置后第一次按快捷键再冷启动。TIS 切过去再切回只作为静默拉起失败的退路。
- `Sources/DoubaoVoiceApp/Services/DoubaoIMEReadiness.swift`：启动 / 唤醒 / 进程退出时静默拉起豆包输入法进程（不切 TIS），避免闲置后第一次按快捷键再冷启动。TIS 切过去再切回只作为静默拉起失败的退路。
- `Sources/DoubaoVoiceApp/Services/KeyboardSimulator.swift`：合成「左 Option 单击」触发豆包语音。合成事件带自识别标记（`isSynthetic`），三个事件回调开头都要先放行它——不然把快捷键设成单独点 Option 会自触发甚至递归。
- `Sources/DoubaoVoiceApp/Services/MediaPlaybackPauser.swift`：语音期间暂停/恢复系统「正在播放」的媒体。macOS 15.4+ 封锁了第三方进程直调 MediaRemote，所以经系统自带 perl 宿主执行 `Helper/MediaRemoteBridge/`（build.sh 编译进 Resources）；helper 失败只记日志，不许影响语音主流程。会话收尾的恢复要经 `AudioRouteSettler` 守门：等 CoreAudio 信号确认麦克风已释放、蓝牙耳机从通话档（HFP）退回 A2DP，再做静音预热后才发 play——提前恢复会让音乐先以通话档的偏大音量播出再跳回正常。会话收尾的恢复要经 `AudioRouteSettler` 守门：等 CoreAudio 信号确认麦克风已释放、蓝牙耳机从通话档（HFP）退回 A2DP，再做静音预热后才发 play——提前恢复会让音乐先以通话档的偏大音量播出再跳回正常。
- `Sources/DoubaoVoiceApp/Services/UpdateController.swift`：自动更新（Sparkle 2.9.4）。读不到 Info.plist 里的 `SUFeedURL` 就整个不实例化 updater——开发版正是靠这一条不参与更新。设置里「自动更新到最新版」同时打开定时检查和后台下载；下载完若没在说话就立刻安装重启，否则等语音结束。菜单栏「检查更新…」直接把 target/action 指向 `SPUStandardUpdaterController`，灰显由它自己管。本 App 是 `LSUIElement`，必须实现 `supportsGentleScheduledUpdateReminders` 并在更新会话期间临时切 `.regular`，否则提示窗会压在别的窗口后面，用户根本看不见。
- `Sources/DoubaoVoiceApp/Views/`：设置界面（SwiftUI）。`PreferencesWindowController` 只剩 `NSTabViewController`（`.toolbar` 分栏）外壳，每个分栏是 `NSHostingController` 托管的分组 `Form`；`SettingsStore` 只做状态桥接，真值仍在各服务里，写入一律走原有 setter。`HotkeyRecorder` 用 `NSEvent` local monitor 录键位，录制期间必须调 `setHotkeyCaptureActive(true)` 让 event tap 让路，否则已生效的快捷键会先被吞掉。

## 硬约束

1. 事件监听线程的回调（`EventTapDelegate` 各方法）必须立即返回，禁止 TIS、磁盘同步 IO 等可能阻塞的调用——阻塞超过约 1 秒系统会禁用整个 tap。
2. 不要破坏配置默认值的向后兼容：老用户升级后行为不能变。
3. 面向用户的文案（菜单、弹窗、日志）用简体中文。
4. 部署目标是 macOS 13，别用更高版本才有的 API（CI 跑在 macos-14 runner 上，本机 SDK 更新，编不出错不代表用户能跑）。
5. `build.sh` 里「只有拿到真证书才加 `--options runtime`」这个分支不能动。Hardened Runtime 含 Library Validation，要求 `Sparkle.framework` 和主程序 Team ID 一致，而 ad-hoc 签名没有 Team ID——给 ad-hoc 包加上 runtime，dyld 会拒绝加载框架，App 直接起不来。
6. Sparkle 相关的打包细节：拷框架只能用 `ditto`（`cp -RL` 跟随符号链接会毁掉签名）；签名严格自内向外 `Autoupdate` → `Updater.app` → 框架 → 外层 app，不用 `--deep`；更新 zip 只能用 `ditto -c -k`，`zip -r` 同样会毁签名。`Info.plist` 里的 `CFBundleAllowMixedLocalizations` 也别删——bundle 里没有任何 `.lproj`，去掉它 Sparkle 自带的中文本地化不生效，更新窗口会变英文。
