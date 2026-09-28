import SwiftUI

/// 「输入法」分栏：日常输入源，以及输入源轮换的开关、快捷键和参与轮换的输入源。
struct InputSourceSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("日常中文输入法", selection: store.chineseSourceID) {
                    ForEach(store.chineseChoices) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                Picker("日常英文键盘", selection: store.englishSourceID) {
                    ForEach(store.englishChoices) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("语音结束后找不到之前的输入源时会恢复到这里。说话固定使用豆包输入法；平时也只用豆包打中文的话，中文输入法直接选豆包。")
                    ForEach(store.inputSourceWarnings, id: \.self) { warning in
                        SettingsWarning(text: warning)
                    }
                }
            }

            Section {
                Toggle("用快捷键轮换输入源", isOn: store.ctrlSpaceSwitchEnabled)
                Group {
                    LabeledContent("轮换快捷键") {
                        HotkeyRecorder(store: store, target: .cycle)
                    }
                    LabeledContent("参与轮换") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.cycleChoices) { choice in
                                Toggle(choice.name, isOn: store.cycleMember(choice.id))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .disabled(!store.cycleSwitchEnabled)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按系统输入法列表的顺序在勾选的输入源之间依次切换；当前输入源不在其中时，先切到类型不同的那个（比如从豆包切到英文键盘）。切完会对「应用兼容」里的 App 刷新一次输入框，避免菜单栏切了、输入框没跟上。关掉后 \(store.cycleHotkey.displayString) 交回系统处理。")
                    ForEach(store.cycleWarnings, id: \.self) { warning in
                        SettingsWarning(text: warning)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsAlert(store)
    }
}
