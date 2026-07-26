import SwiftUI

/// 「输入法」分栏：日常输入源的两端，以及输入源轮换的开关与快捷键。
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
                    Text("语音结束后找不到之前的输入源时会恢复到这里，它们也是轮换快捷键的两端。说话固定使用豆包输入法，不需要配置。")
                    ForEach(store.inputSourceWarnings, id: \.self) { warning in
                        SettingsWarning(text: warning)
                    }
                }
            }

            Section {
                Toggle("用快捷键轮换输入源", isOn: store.ctrlSpaceSwitchEnabled)
                LabeledContent("轮换快捷键") {
                    HotkeyRecorder(store: store, target: .cycle)
                }
                .disabled(!store.cycleSwitchEnabled)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("只在上面两个输入源之间切换，不把豆包放进轮换。关掉后 \(store.cycleHotkey.displayString) 交回系统处理。")
                    if let warning = store.cycleHotkeyWarning {
                        SettingsWarning(text: warning)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsAlert(store)
    }
}
