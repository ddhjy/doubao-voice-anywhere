import SwiftUI

/// 「通用」分栏：说话快捷键、启动方式、说话时的媒体行为、辅助功能权限、自动更新。
struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("交给豆包输入法的全局语音处理", isOn: store.voiceHandledByDoubao)
                LabeledContent("说话快捷键") {
                    HotkeyRecorder(store: store, target: .voice)
                }
                .disabled(store.voiceHandledByDoubao.wrappedValue)
                if !store.voiceHandledByDoubao.wrappedValue {
                    Picker("豆包免按模式快捷键", selection: store.voiceOptionKey) {
                        Text(VoiceOptionKey.left.label).tag(VoiceOptionKey.left)
                        Text(VoiceOptionKey.right.label).tag(VoiceOptionKey.right)
                    }
                    if store.voiceHotkey.bareModifier == .fn {
                        Toggle("用 Fn 触发豆包原生识别优化", isOn: store.nativeFnStop)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if store.voiceHandledByDoubao.wrappedValue {
                        Text("由豆包的「全局唤起语音」处理说话快捷键。它可能先经过上一个输入法，再切到豆包。说完后会恢复打字时的输入法。")
                    } else if store.voiceHotkey.bareModifier == .fn && store.nativeFnStop.wrappedValue {
                        Text("在豆包「语音输入」里把「长按模式」设为 Fn，「免按模式」设为这里选的 Option 键。轻按 Fn 开始，再按 Fn 由豆包整理文字。Option 也能照常单击。")
                    } else {
                        Text("按说话快捷键直接切到豆包。请把豆包的「免按模式」设为这里选的 Option 键，并让豆包的长按和免按快捷键都与说话快捷键错开。")
                    }
                    if let warning = store.voiceHotkeyWarning {
                        SettingsWarning(text: warning)
                    }
                }
            }

            Section {
                Toggle("登录时自动启动", isOn: store.launchAtLogin)
                Toggle("说话时暂停正在播放的媒体", isOn: store.pauseMediaDuringVoice)
            } footer: {
                Text("说完自动恢复播放。只恢复由本 App 暂停的那一个，不会拉起你自己暂停的音乐。")
            }

            Section {
                LabeledContent("辅助功能") {
                    if store.accessibilityTrusted {
                        Label {
                            Text("已授权")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Label {
                            Text("未授权")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack {
                    if !store.accessibilityTrusted {
                        Button("打开系统设置…") {
                            store.openAccessibilitySettings()
                        }
                    }
                    Button("重新连接键盘监听") {
                        store.restartKeyboardMonitoring()
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("没有辅助功能权限就监听不到快捷键。授权后通常几秒内自动生效，没生效时点「重新连接键盘监听」。")
            }

            if store.updatesEnabled {
                Section {
                    LabeledContent("当前版本") {
                        Text(store.appVersion)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("自动更新到最新版", isOn: store.automaticUpdates)
                    Button("现在检查…") {
                        store.checkForUpdates()
                    }
                } header: {
                    Text("更新")
                } footer: {
                    Text("每天在后台查一次，发现新版本会自动下载并安装，装完自动重启。正在说话时会等说完再装。关掉后仍可点「现在检查…」手动更新。")
                }
            }
        }
        .formStyle(.grouped)
        .settingsAlert(store)
    }
}
