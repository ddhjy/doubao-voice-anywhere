# 豆包随时说

[![CI](https://github.com/ddhjy/doubao-voice-anywhere/actions/workflows/ci.yml/badge.svg)](https://github.com/ddhjy/doubao-voice-anywhere/actions/workflows/ci.yml)

把豆包输入法留给它最有价值的部分：免费、好用的语音输入。
把你真正顺手的输入法，继续留作主输入法。

一个常驻菜单栏的 macOS 原生 App。**轻按一次 `Fn` 开始说话，再按一次结束**（快捷键可以改成任何你顺手的键），它自动处理中间所有的事：

![按一下 Fn，直接用豆包语音输入](./assets/doubao-fn-voice-message.png)

- 切换到豆包输入法
- 唤起豆包语音输入
- 暂停正在播放的音乐 / 视频（汽水音乐、抖音、Music、浏览器……），说完自动恢复
- 说完后切回你原来的输入法
- （可选）让 `Ctrl+Space` 只在你的日常中文输入法和英文键盘之间轮换，不把豆包放进轮换
- 两个快捷键都能在设置里重录：组合键、功能键，或者单独点一下 `⌥` 这种都行

## 为什么做这个项目

豆包输入法的 macOS 版本目前有一个很明显的矛盾：

- 它的常规输入法能力偏弱，不太适合当主输入法。
- 它的语音识别能力却不错，而且免费，单独拿来做语音输入很有价值。
- 但官方的产品形态更偏向"占住输入法入口"，日常使用必须反复手动切换，体验并不顺。

这个项目的目标很直接：**不把豆包当主输入法用，但把它当成主力语音输入工具来用。**

## 前置要求

- macOS 13 或更高版本
- 已安装[豆包输入法](https://www.doubao.com/product/input-method)，并已在「系统设置 → 键盘 → 输入法」中添加
- 豆包输入法的语音快捷键保持默认的「单击左 Option」（本 App 靠它触发语音）
- 编译需要 Xcode Command Line Tools（含 Swift 5.9+）：`xcode-select --install`

## 安装

[Releases](https://github.com/ddhjy/doubao-voice-anywhere/releases) 里有签名并经过 Apple 公证的 DMG（Intel / Apple Silicon 通用），下载后打开、把 App 拖进 Applications 就能用。装好之后会自己检查更新，见[自动更新](#自动更新)。

想自己编译：

```bash
git clone https://github.com/ddhjy/doubao-voice-anywhere.git
cd doubao-voice-anywhere
./install-app.sh
```

脚本会编译打包出 `dist/豆包随时说.app`，安装到 `~/Applications/` 并启动。启动后菜单栏会出现一个麦克风图标。

**第一次运行只需要做一件事**：在弹出的系统提示中打开「系统设置 → 隐私与安全性 → 辅助功能」，勾选「豆包随时说」。授权后 App 会在几秒内自动开始监听（如果没生效，点菜单栏图标 →「重新连接键盘监听」）。

然后就可以用了：**轻按一次 `Fn`，开始说话；再按一次，结束**。想换成别的键就去「设置…」→「通用」重录。

其它安装选项：

```bash
./build.sh                       # 只编译打包，不安装（默认当前架构）
./build.sh --universal           # 编译 arm64 + x86_64 通用包
./build.sh --clean               # 编译前先 swift package clean
./install-app.sh --skip-build    # 不重新编译，复用 dist 中现有产物
./install-app.sh --system        # 安装到 /Applications（需要管理员权限）
./install-app.sh --dev           # 安装开发版（与正式版共存，见「贡献」）
```

### 关于代码签名

macOS 的辅助功能授权跟随 App 的签名身份。`build.sh` 按以下顺序选择签名方式，通常你什么都不用做：

1. 环境变量 `CODE_SIGN_IDENTITY`（如 `CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./install-app.sh`）
2. 仓库根目录的 `.codesign-identity` 文件（写一行证书名，不会被提交到 git）
3. 自动探测本机第一个可用的开发者证书
4. 都没有时用 ad-hoc 签名——**能正常安装运行**，但每次重新编译安装后需要重新授权一次辅助功能（先移除再勾选）

前三种情况下会一并启用 Hardened Runtime（Apple 公证的前提条件），ad-hoc 签名不支持它，会自动跳过。

不想每次重装都重新授权、又没有付费开发者证书？见[常见问题](#常见问题)里的自签证书方法。

## 怎么用

1. 轻按一次 `Fn`：自动切到豆包输入法并启动语音输入，开始说话。正在放歌 / 放视频的话会先帮你暂停，不让背景音干扰识别。
2. 说完再轻按一次 `Fn`：结束语音，自动切回你之前的输入法，被暂停的媒体自动恢复播放。
3. 录音过程中敲任意键或点击鼠标，也会自动结束语音并恢复输入法。
4. （可选）按 `Ctrl+Space`：只在你配置的中文输入法 / 英文键盘之间轮换，不会切到豆包。
5. 这两个快捷键都能改，见下面的「配置」。

## 配置

打开菜单栏图标 →「设置…」，分三个分栏：

**通用**
- **说话快捷键**：默认轻按 `Fn`。点一下右边的按钮进入录制，按下的键位就是新快捷键，Esc 取消。可以是组合键（`⌘⇧D`）、功能键（`F13`），也可以单独点一个修饰键（比如只点一下 `⌥`）。单独点修饰键时，按住它配合别的键或点鼠标都不会触发语音，所以 `⌥C` 之类的组合照常可用。
- **登录时自动启动**：写入当前用户的 LaunchAgent。
- **说话时暂停正在播放的媒体**：说话时自动暂停系统「正在播放」的媒体，说完自动恢复（默认开启）。只有真的由本 App 暂停的媒体才会被恢复，不会乱拉起你手动暂停的音乐；会议通话类音频不注册系统媒体会话，不受影响。
- **辅助功能权限**：显示当前授权状态，未授权时可直接跳转系统设置；旁边的「重新连接键盘监听」用于事件监听失效时手动重启。

**输入法**
- **日常中文输入法 / 日常英文键盘**：从系统已启用的输入源里直接选。它们是 `Ctrl+Space` 轮换的两端，也是语音结束后找不到「之前输入源」时的兜底恢复目标。配置的输入源在系统里未启用时，下拉框会把它标成「（未启用）」保留住，不会静默改掉你的配置，同时给出黄色警告说明当前实际改用了哪一个。
- **用快捷键轮换输入源**：不想让本 App 接管这个键就关掉它，按键会交回系统处理。配置的输入法在系统里不可用时，App 也会自动暂停拦截，不会吞掉你的按键。
- **轮换快捷键**：默认 `Ctrl+Space`，录制方式与说话快捷键相同。两个快捷键不能设成同一个键位。

**应用兼容性**
部分 Electron 应用（如 Notion、VS Code）会出现「菜单栏输入法已切换，但应用内输入框没有真正切换」的问题。把这类 App 加进列表后，切换输入法时会做一次极短的输入上下文刷新：用一个不激活本 App 的小面板短暂接管 key window 再还回去，前台 App 全程保持激活，输入框焦点不会丢。默认已包含 Notion。列表下方的 `+` 可以选 `.app` 或直接填 Bundle ID，`−`（或 Delete 键）移除选中项。

想查看系统里所有输入源的 ID，或验证输入法切换是否正常：

```bash
swift tools/check_switch.swift                          # 列出已启用的输入源
swift tools/check_switch.swift com.apple.keylayout.ABC  # 测试切换到指定输入源
```

## 菜单栏功能

| 菜单项 | 用途 |
| --- | --- |
| 当前状态（不可点） | 显示当前输入源 + 豆包语音是否录音中 |
| 去开启辅助功能权限… | 未授权时显示，点击跳转系统设置 |
| 重新连接键盘监听 | 事件监听失效时手动重启 |
| 开始 / 结束豆包语音 | 等同于按说话快捷键，没法按键时手动触发 |
| 切到豆包输入法 | 仅切输入源、不触发语音 |
| 切回上一个输入法 | 恢复被切到豆包之前的输入源 |
| 设置… | 两个快捷键、自启动、语音时暂停媒体、权限状态、日常输入法、应用兼容性、自动更新 |
| 在 Finder 中显示日志 | 打开 `~/Library/Logs/DoubaoVoiceApp/app.log` |
| 检查更新… | 立刻查一次有没有新版本（开发版不显示这一项） |

## 自动更新

用 [Sparkle](https://sparkle-project.org) 做的：启动时和之后每天各在后台查一次，发现新版本会自动下载并安装，装完自动重启。正在说话时会等说完再装，避免打断录音。不想要就去「设置…」→「通用」→「更新」关掉「自动更新到最新版」，需要时再手动点「现在检查…」。

更新包由本项目的 EdDSA 私钥签名，客户端拿内置公钥验签，签不上不会安装；下载下来的仍是经 Apple 公证的同一个包，所以更新后辅助功能授权不会丢，不用重新授权。

> v1.0.3 及更早的版本还没有这个能力，收不到更新提示。从 Releases 手动装一次新版本之后，后续升级就自动了。

## 常见问题

**菜单栏没出现图标？**
看日志 `~/Library/Logs/DoubaoVoiceApp/app.log` 里有没有 `DoubaoVoiceApp 启动`。没有的话，确认 `./install-app.sh` 输出中的签名步骤是否成功。

**按 Fn 没反应？**
点开菜单栏图标：如果显示「去开启辅助功能权限…」，点它去系统设置授权；授权后几秒内自动生效，仍无效就点「重新连接键盘监听」。

**按 Fn 弹出了系统听写 / Emoji 选择器？**
系统设置 → 键盘 → 「按下 🌐 键执行以下操作」改成「不执行任何操作」；如果触发的是听写，把「听写」也关掉。

**豆包语音没启动？**
确认豆包输入法的「语音输入」快捷键仍是默认的「单击左 Option」（在豆包输入法自己的设置里改回来）。日志里能看到每一步切换是否成功。

**轮换快捷键没反应？**
打开「设置…」→「输入法」检查开关是否开着、两个日常输入源是否有效。如果配置的输入法未启用，界面会有黄色警告提示，此时 App 自动暂停拦截、按键交回系统。

**我不用鼠须管 / 我的输入法不在默认配置里？**
打开「设置…」→「输入法」，在下拉框里直接选你的输入法即可，不需要改代码。

**说话时音乐没有自动暂停？**
先确认「设置…」里的开关是开着的，再看日志：正常一次会话会有「已暂停 xx 的播放」和「已恢复 xx 的播放」。如果日志提示「媒体暂停组件缺失」，说明 App 不是用 `./install-app.sh` 打包安装的（`swift build` 直跑没有 Resources）。个别播放器不接入系统「正在播放」会话（按 F8 播放/暂停键对它无效的那种），这类播放器无法被控制。

**每次重新安装都要重新授权辅助功能？**
这是 ad-hoc 签名的特性（没有稳定签名身份）。一次性解决：用「钥匙串访问」创建一个免费的自签代码签名证书——

1. 钥匙串访问 → 菜单「钥匙串访问 → 证书助理 → 创建证书…」
2. 名称随意（比如 `my-codesign`），身份类型「自签名根证书」，证书类型「代码签名」，点「创建」
3. 把证书名写进仓库根目录的 `.codesign-identity` 文件，重新安装：

```bash
echo "my-codesign" > .codesign-identity
./install-app.sh
```

之后签名身份固定，重装不再需要重新授权。

**录屏软件里 Option 键帽一直显示按住？**
CleanShot X 等录屏软件的按键可视化层对模拟修饰键事件的显示问题，不代表系统里 Option 真被按住。以实际输入行为和日志里的释放状态为准；录屏时可关闭「显示按键」。

**连按好几次 Fn 都拉不起语音，手动切一下输入法又好了？**
两种成因。一是系统里残留了幽灵修饰键（Fn 卡在「按下」状态），发出去的就变成「Fn+Option」，豆包不认——App 现在会把无关修饰键从模拟单击里剥掉，并在日志里记一条「合成单击带上了无关修饰键」。二是豆包偶发对模拟单击完全没反应，此时 App 会自动把输入法整条重挂一遍（英文键盘布局 → 日常中文输入法 → 豆包）再试。两级补救都失败才提示「豆包语音没拉起来」，同时把输入法恢复回去，并在日志里留一条「拉起失败现场」记录当时的输入源、前台应用、修饰键状态和豆包在屏窗口。

## 它是怎么工作的

- 用 `CGEventTap` 监听全局 `flagsChanged` 和 `keyDown`，按用户配置的两个快捷键匹配。组合键与功能键走 `keyDown`、按下即触发并吞掉按键；单独修饰键走 `flagsChanged`、抬起时才触发且要求按下期间没配合别的输入，除 Fn 外一律不吞（Fn 不吞会额外弹出系统听写 / Emoji 面板）。监听跑在独立线程上，回调内不做任何可能阻塞的调用；tap 被系统禁用时立即自动重启，另有周期看门狗兜底。
- 进程通过 `NSProcessInfo.beginActivity` 退出 App Nap，避免闲置后第一次按快捷键因进程被降频而无响应（不阻止系统正常休眠）。
- 用 Carbon `TextInputSources` (TIS) 切换输入法 / 键盘布局。
- 触发豆包语音时，用 combined-session 事件源发送左 Option `flagsChanged` 单击；事件序列为 down/up。合成事件带一个自识别标记，绕回自己的 event tap 时直接透传，否则把快捷键设成单独点 `⌥` 就会自触发。事件源会把会话当前的修饰键状态一并写进新事件，所以发送前会剥掉除左 Option 外的所有修饰键位——系统里残留一个幽灵 Fn，豆包收到的就是「Fn+Option」，会直接忽略。
- 左 Option 单击对豆包来说既是「开始」也是「结束」。首次使用、唤醒后或闲置一分钟再启动时，即使豆包进程仍在，也先刷新前台 App 的输入上下文，再发出第一次 Option；连续使用保持原来的热启动路径。
- App 用 `CGWindowList` 探测豆包语音胶囊。胶囊覆盖「录音 → 识别优化」整个会话，启动前若有旧胶囊，要等它完全消失；发键后确认新胶囊出现。没出现就分两级补救：刷新焦点，再重新挂载输入法；补发前及键盘队列真正发键前都会复查，避免迟到的首次启动被第二次 Option 停止。只有光标旁的 `⌥` 角标不算启动成功。录音中周期巡检胶囊，停止前发现胶囊已消失就跳过单击。
- 没有收到停止操作，胶囊却在启动后首轮巡检就消失时，按启动失败记录，下一次激活重新挂载输入上下文。用户主动停止短录音仍按正常结束处理。
- 「语音时暂停媒体」走系统「正在播放 (Now Playing)」媒体会话（MediaRemote 私有框架）：谁在播就暂停谁，恢复也只发给它。macOS 15.4 起该框架只对 Apple 平台二进制返回真实数据，所以实际调用发生在系统自带的 `/usr/bin/perl` 进程内——spawn perl 加载 `Resources/mrbridge.dylib` 完成查询与控制（机制同 [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)，见 `Helper/MediaRemoteBridge/`）。helper 任何失败都只记日志，不影响语音主流程。
- 除系统自带的 perl 外，不依赖 Hammerspoon 或任何需要额外安装的脚本运行时，纯 Swift + AppKit + Carbon。

## 技术栈

- Swift 5.9 + SwiftPM 可执行包，单文件 `Package.swift`，不依赖 Xcode 工程
- 输入源切换：Carbon `TextInputSources` (TIS)
- 全局键盘事件：`CGEventTap`（独立线程 + 禁用自动恢复 + 看门狗巡检）
- 模拟左 Option：combined-session `flagsChanged` 事件，在 HID / combined session 两层状态里确认释放
- 菜单栏宿主：`NSStatusItem` + `LSUIElement = true`
- 设置窗口：`NSTabViewController`（`.toolbar` 分栏）承载 SwiftUI 分组 `Form`，对齐系统设置的观感
- 编译产物用 shell 脚本组装成 `.app` bundle，签名方式自动探测（见[关于代码签名](#关于代码签名)）

## 目录结构

按 Apple / SwiftPM 惯例分层：`App/` 装应用生命周期，`Controllers/` 装顶层控制器，`Models/` 放纯数据类型，`Services/` 是对系统 API 的封装，`Utilities/` 是与业务无关的工具类，`Views/` 是设置界面的 SwiftUI 视图。

```text
.
├── Package.swift
├── LICENSE                             # MIT
├── build.sh                            # 编译 + 组装 .app（含签名探测）
├── install-app.sh                      # 安装到 ~/Applications 并启动
├── package-dmg.sh                      # 把 .app 打成可分发 DMG
├── notarize.sh                         # 提交 Apple 公证并等结果
├── codesign-lib.sh                     # 签名身份解析，被上面几个脚本 source
├── setup-ci-secrets.sh                 # 一次性配好 CI 的签名 / 公证 / 更新签名 secrets
├── appcast.xml                         # Sparkle 更新源，由 CI 维护，别手改
├── .github/workflows/
│   ├── ci.yml                          # push / PR：编译 + 打包验证（ad-hoc 签名）
│   └── release.yml                     # 推 main / 打 tag：签名 + 公证 + 发 Release + 更新 appcast
├── assets/                             # README 图片
├── Resources/Info.plist                # bundle Info.plist 模板（含 ${...} 占位符）
├── tools/check_switch.swift            # 输入源诊断脚本
├── tools/update-appcast.sh             # 给更新包签名并往 appcast.xml 追加条目
├── Helper/MediaRemoteBridge/           # 媒体暂停 helper（perl 宿主 + MediaRemote 桥接 dylib 源码）
│   ├── mrbridge.m                      # status / pause / play，编译进 Resources/mrbridge.dylib
│   └── mrbridge-host.pl                # 在 Apple 签名的 perl 进程内加载 dylib
└── Sources/DoubaoVoiceApp/
    ├── App/
    │   ├── DoubaoVoiceApp.swift        # @main 入口
    │   └── AppDelegate.swift           # 菜单栏 / 权限 / 重试逻辑
    ├── Controllers/
    │   ├── DoubaoVoiceController.swift # 主状态机
    │   ├── EventTapController.swift    # CGEventTap 包装
    │   └── PreferencesWindowController.swift  # 设置窗口外壳（工具栏分栏）
    ├── Models/
    │   └── InputSource.swift           # 输入源描述
    ├── Services/
    │   ├── GeneralSettings.swift       # 用户配置（UserDefaults）
    │   ├── InputSourceManager.swift    # Carbon TIS 包装
    │   ├── KeyboardSimulator.swift     # 左 Option 单击
    │   ├── DoubaoVoiceHUDDetector.swift # 语音胶囊探测
    │   ├── MediaPlaybackPauser.swift   # 语音时暂停/恢复媒体播放
    │   ├── InputSourceActivationNudge.swift          # 输入上下文刷新
    │   ├── InputSourceActivationNudgeSettings.swift  # 应用兼容性白名单
    │   ├── LoginItemManager.swift      # 登录时自动启动
    │   ├── PermissionManager.swift     # 辅助功能权限
    │   └── UpdateController.swift      # 自动更新（Sparkle）
    ├── Utilities/
    │   └── Logger.swift                # stderr + 文件日志
    └── Views/                           # 设置界面（SwiftUI）
        ├── SettingsStore.swift         # 界面与各服务之间的状态桥接
        ├── GeneralSettingsPane.swift   # 通用
        ├── InputSourceSettingsPane.swift # 输入法
        └── AppCompatibilityPane.swift  # 应用兼容性
```

## 发布流程

把应用代码推到 `main` 就会触发 [release workflow](.github/workflows/release.yml)：相对最新的稳定版 tag 自动 patch +1（例如当前是 `v1.0.6` 就会出 `v1.0.7`），然后 universal 编译 → Developer ID 签名 → 送 Apple 公证 → 把票据装订进 `.app` 和 DMG → 建 GitHub Release 并挂上 DMG 和更新用 zip → 给 zip 算 EdDSA 签名、往 `appcast.xml` 追加条目并推回 `main`。只改文档 / `appcast.xml` / 工作流配置不会发版；appcast 回推靠提交说明跳过，不会循环出包。装订过票据的包在离线环境下也能通过 Gatekeeper，用户双击即可打开，不用右键绕过。

需要发 minor / major，或重跑某个版本时，仍可手动推 `v*` tag，或在 Actions 里 `workflow_dispatch` 并填版本号。

DMG 给首次下载的用户，zip 给 Sparkle 自动更新——同一个 `.app`，只是打包格式不同。`appcast.xml` 入库放在 `main` 上，App 里的 `SUFeedURL` 指的就是它的 raw 地址，所以这个文件的路径和分支不能随便挪，挪了老版本就再也收不到更新。

第一次要配一遍凭证，脚本会引导你导出证书、填 App Store Connect API Key、把 Sparkle 签名私钥写进 secret：

```bash
./setup-ci-secrets.sh
```

之后日常发版：把改动推进 `main` 即可。需要指定版本时：

```bash
git tag v1.2.0 && git push origin v1.2.0
gh run watch    # 公证一般 1-5 分钟
```

用到的 7 个 secrets：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application 证书连私钥导出的 .p12，base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 .p12 时设的密码 |
| `MACOS_SIGN_IDENTITY` | 证书全名，形如 `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_API_KEY_P8` | App Store Connect API Key 的 .p8，base64 |
| `APPLE_API_KEY_ID` | Key ID，10 位 |
| `APPLE_API_ISSUER_ID` | Issuer ID，UUID |
| `SPARKLE_PRIVATE_KEY` | Sparkle 更新签名的 EdDSA 私钥，`generate_keys -x` 导出 |

`SPARKLE_PRIVATE_KEY` 和 `Resources/Info.plist` 里的 `SUPublicEDKey` 是一对，换了一个就得同步换另一个，否则用户端验签不过、收不到更新（`./setup-ci-secrets.sh --sparkle-only` 会替你核对这一点）。私钥存在本机钥匙串里，换机器时用 `generate_keys -x` / `-f` 导出导入。

同一套脚本在本地也能手动跑完整流程：

```bash
APP_VERSION=1.2.0 CODE_SIGN_TIMESTAMP=1 ./build.sh --universal
DMG_VERSION=1.2.0 CODE_SIGN_TIMESTAMP=1 ./package-dmg.sh
NOTARY_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8 NOTARY_KEY_ID=XXXXXXXXXX \
  NOTARY_ISSUER_ID=<uuid> ./notarize.sh dist/DoubaoVoiceApp-1.2.0.dmg
```

`CODE_SIGN_TIMESTAMP=1` 打开安全时间戳（公证必需，要联网），本地日常构建默认关着，断网也能签。

出问题看 `gh run view --log-failed`；公证被 Apple 拒绝时，`notarize.sh` 会把对方返回的完整原因打进日志。

## 贡献

欢迎 Issue 和 PR。改动请保持：

- `./install-app.sh` 一条命令能跑通（这也是默认的开发验证方式）
- 事件监听线程的回调里不引入阻塞调用（见 `EventTapController` 的注释）
- 面向用户的文案用简体中文

日常在用 Release 正式版、又要改代码验证？用开发版模式：

```bash
./install-app.sh --dev
```

它会装出一个「豆包随时说 Dev.app」，bundle ID 是独立的
`com.doubaovoiceapp.menubar.dev`——辅助功能授权、配置、登录项、日志
（`app-dev.log`）全部与正式版隔离，开发版首次运行授权一次辅助功能后，
反复重装也不用再授权，正式版不受任何影响。两个版本不要同时运行（都会
响应说话快捷键），安装脚本会自动退出另一个版本；验证完退出 Dev 版，
重新打开正式版即可。

## 卸载

```bash
pkill -x DoubaoVoiceApp
rm -rf ~/Applications/豆包随时说.app
rm -rf ~/Applications/豆包语音输入助手.app   # 从旧版本升级过的话，顺带清掉旧名残留
rm -f ~/Library/LaunchAgents/com.doubaovoiceapp.menubar.autostart.plist
rm -rf ~/Library/Logs/DoubaoVoiceApp
defaults delete com.doubaovoiceapp.menubar 2>/dev/null || true
# 装过开发版（--dev）的话，顺带清理：
rm -rf "$HOME/Applications/豆包随时说 Dev.app"
rm -f ~/Library/LaunchAgents/com.doubaovoiceapp.menubar.dev.autostart.plist
defaults delete com.doubaovoiceapp.menubar.dev 2>/dev/null || true
# 系统设置 → 隐私与安全性 → 辅助功能：把"豆包随时说"那一项移除
```

## 许可证

[MIT](./LICENSE)
