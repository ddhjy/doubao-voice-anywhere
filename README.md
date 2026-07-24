# 豆包随时说

[![CI](https://github.com/ddhjy/doubao-voice-anywhere/actions/workflows/ci.yml/badge.svg)](https://github.com/ddhjy/doubao-voice-anywhere/actions/workflows/ci.yml)

把豆包输入法留给它最有价值的部分：免费、好用的语音输入。
把你真正顺手的输入法，继续留作主输入法。

一个常驻菜单栏的 macOS 原生 App。**轻按一次 `Fn` 开始说话，再按一次结束**，它自动处理中间所有的事：

![按一下 Fn，直接用豆包语音输入](./assets/doubao-fn-voice-message.png)

- 切换到豆包输入法
- 唤起豆包语音输入
- 说完后切回你原来的输入法
- （可选）让 `Ctrl+Space` 只在你的日常中文输入法和英文键盘之间轮换，不把豆包放进轮换

## 为什么做这个项目

豆包输入法的 macOS 版本目前有一个很明显的矛盾：

- 它的常规输入法能力偏弱，不太适合当主输入法。
- 它的语音识别能力却不错，而且免费，单独拿来做语音输入很有价值。
- 但官方的产品形态更偏向"占住输入法入口"，日常使用必须反复手动切换，体验并不顺。

这个项目的目标很直接：**不把豆包当主输入法用，但把它当成主力语音输入工具来用。**

## 前置要求

- macOS 12 或更高版本
- 已安装[豆包输入法](https://www.doubao.com/product/input-method)，并已在「系统设置 → 键盘 → 输入法」中添加
- 豆包输入法的语音快捷键保持默认的「单击左 Option」（本 App 靠它触发语音）
- 编译需要 Xcode Command Line Tools（含 Swift 5.9+）：`xcode-select --install`

## 安装

```bash
git clone https://github.com/ddhjy/doubao-voice-anywhere.git
cd doubao-voice-anywhere
./install-app.sh
```

脚本会编译打包出 `dist/豆包随时说.app`，安装到 `~/Applications/` 并启动。启动后菜单栏会出现一个麦克风图标。

**第一次运行只需要做一件事**：在弹出的系统提示中打开「系统设置 → 隐私与安全性 → 辅助功能」，勾选「豆包随时说」。授权后 App 会在几秒内自动开始监听（如果没生效，点菜单栏图标 →「重新连接键盘监听」）。

然后就可以用了：**轻按一次 `Fn`，开始说话；再按一次，结束**。

其它安装选项：

```bash
./build.sh                       # 只编译打包，不安装（默认当前架构）
./build.sh --universal           # 编译 arm64 + x86_64 通用包
./build.sh --clean               # 编译前先 swift package clean
./install-app.sh --skip-build    # 不重新编译，复用 dist 中现有产物
./install-app.sh --system        # 安装到 /Applications（需要管理员权限）
```

### 关于代码签名

macOS 的辅助功能授权跟随 App 的签名身份。`build.sh` 按以下顺序选择签名方式，通常你什么都不用做：

1. 环境变量 `CODE_SIGN_IDENTITY`（如 `CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./install-app.sh`）
2. 仓库根目录的 `.codesign-identity` 文件（写一行证书名，不会被提交到 git）
3. 自动探测本机第一个可用的开发者证书
4. 都没有时用 ad-hoc 签名——**能正常安装运行**，但每次重新编译安装后需要重新授权一次辅助功能（先移除再勾选）

不想每次重装都重新授权、又没有付费开发者证书？见[常见问题](#常见问题)里的自签证书方法。

## 怎么用

1. 轻按一次 `Fn`：自动切到豆包输入法并启动语音输入，开始说话。
2. 说完再轻按一次 `Fn`：结束语音，自动切回你之前的输入法。
3. 录音过程中敲任意键或点击鼠标，也会自动结束语音并恢复输入法。
4. （可选）按 `Ctrl+Space`：只在你配置的中文输入法 / 英文键盘之间轮换，不会切到豆包。

## 配置

打开菜单栏图标 →「设置…」：

**输入法与快捷键**
- **日常中文输入法 / 日常英文键盘**：从系统已启用的输入源里直接选。它们是 `Ctrl+Space` 轮换的两端，也是语音结束后找不到「之前输入源」时的兜底恢复目标。
- **Ctrl+Space 轮换开关**：不想让本 App 接管 `Ctrl+Space` 就关掉它，按键会交回系统处理。配置的输入法在系统里不可用时，App 也会自动暂停拦截，不会吞掉你的按键。

**应用兼容性**
部分 Electron 应用（如 Notion、VS Code）会出现「菜单栏输入法已切换，但应用内输入框没有真正切换」的问题。把这类 App 加进列表后，切换输入法时会做一次极短的输入上下文刷新：用一个不激活本 App 的小面板短暂接管 key window 再还回去，前台 App 全程保持激活，输入框焦点不会丢。默认已包含 Notion。

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
| 开始 / 结束豆包语音 | 等同于按 `Fn`，没法按键时手动触发 |
| 切到豆包输入法 | 仅切输入源、不触发语音 |
| 切回上一个输入法 | 恢复被切到豆包之前的输入源 |
| 设置… | 日常输入法、Ctrl+Space 开关、应用兼容性 |
| 登录时自动启动 | 写入当前用户的 LaunchAgent |
| 在 Finder 中显示日志 | 打开 `~/Library/Logs/DoubaoVoiceApp/app.log` |

## 常见问题

**菜单栏没出现图标？**
看日志 `~/Library/Logs/DoubaoVoiceApp/app.log` 里有没有 `DoubaoVoiceApp 启动`。没有的话，确认 `./install-app.sh` 输出中的签名步骤是否成功。

**按 Fn 没反应？**
点开菜单栏图标：如果显示「去开启辅助功能权限…」，点它去系统设置授权；授权后几秒内自动生效，仍无效就点「重新连接键盘监听」。

**按 Fn 弹出了系统听写 / Emoji 选择器？**
系统设置 → 键盘 → 「按下 🌐 键执行以下操作」改成「不执行任何操作」；如果触发的是听写，把「听写」也关掉。

**豆包语音没启动？**
确认豆包输入法的「语音输入」快捷键仍是默认的「单击左 Option」（在豆包输入法自己的设置里改回来）。日志里能看到每一步切换是否成功。

**Ctrl+Space 没反应？**
打开「设置…」检查两个日常输入源是否有效。如果配置的输入法未启用，界面会有 ⚠️ 提示，此时 App 自动暂停拦截、按键交回系统。

**我不用鼠须管 / 我的输入法不在默认配置里？**
打开「设置…」，在下拉框里直接选你的输入法即可，不需要改代码。

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

## 它是怎么工作的

- 用 `CGEventTap` 监听全局 `flagsChanged` 和 `keyDown`，识别「轻按 Fn」和 `Ctrl+Space`。监听跑在独立线程上，回调内不做任何可能阻塞的调用；tap 被系统禁用时立即自动重启，另有周期看门狗兜底。
- 进程通过 `NSProcessInfo.beginActivity` 退出 App Nap，避免闲置后第一次按 Fn 因进程被降频而无响应（不阻止系统正常休眠）。
- 用 Carbon `TextInputSources` (TIS) 切换输入法 / 键盘布局。
- 触发豆包语音时，用 combined-session 事件源发送左 Option `flagsChanged` 单击；事件序列为 down/up。
- 左 Option 单击对豆包来说既是「开始」也是「结束」，为了不让内部状态和豆包真实状态反转（豆包会因静音超时自行结束录音；Electron 应用的输入上下文滞后还会让单击落空），App 用 `CGWindowList` 探测豆包输入法进程的语音胶囊窗口作为真值源：启动后确认胶囊出现（没出现则强制焦点刷新并重发一次）、录音中周期巡检胶囊是否还在、停止前发现胶囊已消失就跳过单击。探测不可用时（比如豆包改版）自动退回旧的盲切换行为。
- 全程不依赖 Hammerspoon 或任何脚本运行时，纯 Swift + AppKit + Carbon。

## 技术栈

- Swift 5.9 + SwiftPM 可执行包，单文件 `Package.swift`，不依赖 Xcode 工程
- 输入源切换：Carbon `TextInputSources` (TIS)
- 全局键盘事件：`CGEventTap`（独立线程 + 禁用自动恢复 + 看门狗巡检）
- 模拟左 Option：combined-session `flagsChanged` 事件，在 HID / combined session 两层状态里确认释放
- 菜单栏宿主：`NSStatusItem` + `LSUIElement = true`
- 编译产物用 shell 脚本组装成 `.app` bundle，签名方式自动探测（见[关于代码签名](#关于代码签名)）

## 目录结构

按 Apple / SwiftPM 惯例分层：`App/` 装应用生命周期，`Controllers/` 装顶层控制器，`Models/` 放纯数据类型，`Services/` 是对系统 API 的封装，`Utilities/` 是与业务无关的工具类。

```text
.
├── Package.swift
├── LICENSE                             # MIT
├── build.sh                            # 编译 + 组装 .app（含签名探测）
├── install-app.sh                      # 安装到 ~/Applications 并启动
├── .github/workflows/ci.yml            # CI：编译 + 打包验证
├── assets/                             # README 图片
├── Resources/Info.plist                # bundle Info.plist 模板（含 ${...} 占位符）
├── tools/check_switch.swift            # 输入源诊断脚本
└── Sources/DoubaoVoiceApp/
    ├── App/
    │   ├── DoubaoVoiceApp.swift        # @main 入口
    │   └── AppDelegate.swift           # 菜单栏 / 权限 / 重试逻辑
    ├── Controllers/
    │   ├── DoubaoVoiceController.swift # 主状态机
    │   ├── EventTapController.swift    # CGEventTap 包装
    │   └── PreferencesWindowController.swift  # 设置窗口
    ├── Models/
    │   └── InputSource.swift           # 输入源描述
    ├── Services/
    │   ├── GeneralSettings.swift       # 用户配置（UserDefaults）
    │   ├── InputSourceManager.swift    # Carbon TIS 包装
    │   ├── KeyboardSimulator.swift     # 左 Option 单击
    │   ├── DoubaoVoiceHUDDetector.swift # 语音胶囊探测
    │   ├── InputSourceActivationNudge.swift          # 输入上下文刷新
    │   ├── InputSourceActivationNudgeSettings.swift  # 应用兼容性白名单
    │   ├── LoginItemManager.swift      # 登录时自动启动
    │   └── PermissionManager.swift     # 辅助功能权限
    └── Utilities/
        └── Logger.swift                # stderr + 文件日志
```

## 贡献

欢迎 Issue 和 PR。改动请保持：

- `./install-app.sh` 一条命令能跑通（这也是默认的开发验证方式）
- 事件监听线程的回调里不引入阻塞调用（见 `EventTapController` 的注释）
- 面向用户的文案用简体中文

## 卸载

```bash
pkill -x DoubaoVoiceApp
rm -rf ~/Applications/豆包随时说.app
rm -rf ~/Applications/豆包语音输入助手.app   # 从旧版本升级过的话，顺带清掉旧名残留
rm -f ~/Library/LaunchAgents/com.doubaovoiceapp.menubar.autostart.plist
rm -rf ~/Library/Logs/DoubaoVoiceApp
defaults delete com.doubaovoiceapp.menubar 2>/dev/null || true
# 系统设置 → 隐私与安全性 → 辅助功能：把"豆包随时说"那一项移除
```

## 许可证

[MIT](./LICENSE)
