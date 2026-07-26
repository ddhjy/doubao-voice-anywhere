import SwiftUI

/// 「通用」分栏：启动方式、说话时的媒体行为、辅助功能权限。
struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
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
                Text("没有辅助功能权限就监听不到 Fn 键。授权后通常几秒内自动生效，没生效时点「重新连接键盘监听」。")
            }
        }
        .formStyle(.grouped)
        .settingsAlert(store)
    }
}
