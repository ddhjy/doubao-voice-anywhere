import SwiftUI

/// 「应用兼容性」分栏：维护需要输入上下文刷新的 App 白名单。
///
/// 布局对齐系统设置里的「登录项」「文本替换」：一张列表 + 底部加减按钮。
struct AppCompatibilityPane: View {
    @ObservedObject var store: SettingsStore

    @State private var isPromptingBundleID = false
    @State private var bundleIDInput = ""

    var body: some View {
        Form {
            Section {
                Table(store.compatibilityApps, selection: $store.compatibilitySelection) {
                    TableColumn("应用", value: \.displayName)
                    TableColumn("Bundle ID", value: \.id)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .frame(minHeight: 200)
                .onDeleteCommand { store.removeSelectedCompatibilityApps() }
                .overlay {
                    if store.compatibilityApps.isEmpty {
                        Text("还没有添加任何应用\n遇到切换不生效时，用下面的按钮加进来。")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Menu {
                        Button("选择应用…") { store.presentApplicationPicker() }
                        Button("输入 Bundle ID…") { isPromptingBundleID = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)

                    Button {
                        store.removeSelectedCompatibilityApps()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.compatibilitySelection.isEmpty)
                    .frame(width: 22)
                }
            } footer: {
                Text("有些应用（多见于 Electron 类，比如 Notion、VS Code）切完输入法后，文本框里其实没切过去。把它们加进来，助手会做一次极短的窗口聚焦，让切换立刻生效。")
            }
        }
        .formStyle(.grouped)
        .alert("用 Bundle ID 添加应用", isPresented: $isPromptingBundleID) {
            TextField("例如：notion.id", text: $bundleIDInput)
            Button("添加") {
                store.addCompatibilityApp(bundleID: bundleIDInput)
                bundleIDInput = ""
            }
            .disabled(bundleIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { bundleIDInput = "" }
        } message: {
            Text("找不到 .app 时，可以直接填它的 Bundle ID。")
        }
        .settingsAlert(store)
    }
}
