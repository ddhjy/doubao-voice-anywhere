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
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if store.voiceHandledByDoubao.wrappedValue {
                        Text("本 App 不再接管说话快捷键，由豆包自己识别、自己切换和切回输入法，最稳定。请在豆包输入法设置里打开「全局语音」，并把语音快捷键设成你想用的键（比如 Fn）。说完后本 App 会把输入法切回你原来用的那个，说话时暂停媒体也仍然有效。")
                    } else {
                        Text("按一下开始说话，再按一下结束。可以是组合键，也可以单独点一个修饰键（比如只点一下 ⌥）——单独点修饰键时，按住它配合别的键不会触发语音。")
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
