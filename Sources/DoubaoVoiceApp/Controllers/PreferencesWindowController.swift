import AppKit
import Foundation
import UniformTypeIdentifiers

/// 「设置」窗口：
/// - 「输入法与快捷键」：配置日常中文输入法 / 英文键盘布局与 Ctrl+Space 轮换开关
/// - 「应用兼容性」：维护需要输入上下文刷新的 App 白名单
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - 输入法与快捷键 tab 控件

    private let chinesePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let englishPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ctrlSpaceCheckbox = NSButton(
        checkboxWithTitle: "用 Ctrl+Space 在上面两个输入源之间轮换（不把豆包放进轮换）",
        target: nil,
        action: nil
    )
    private let pauseMediaCheckbox = NSButton(
        checkboxWithTitle: "按 Fn 说话时自动暂停正在播放的媒体，说完自动恢复",
        target: nil,
        action: nil
    )
    private let generalStatusLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - 应用兼容性 tab 控件

    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "移除", target: nil, action: nil)
    private let emptyLabel = NSTextField(
        labelWithString: "还没有添加任何应用\n遇到切换不生效时，从下方加进来。"
    )

    private var bundleIDs: [String] = []
    private var enabledSourcesObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        buildContentView()
        reloadGeneralTab()
        reloadFromSettings()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nudgeSettingsDidChange(_:)),
            name: InputSourceActivationNudgeSettings.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(generalSettingsDidChange(_:)),
            name: GeneralSettings.changedNotification,
            object: nil
        )
        enabledSourcesObserver = InputSourceManager.observeEnabledInputSourcesChanged { [weak self] in
            self?.reloadGeneralTab()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let observer = enabledSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    override func showWindow(_ sender: Any?) {
        reloadGeneralTab()
        reloadFromSettings()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 布局

    private func buildContentView() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "输入法与快捷键"
        generalItem.view = buildGeneralTabView()
        tabView.addTabViewItem(generalItem)

        let compatibilityItem = NSTabViewItem(identifier: "compatibility")
        compatibilityItem.label = "应用兼容性"
        compatibilityItem.view = buildCompatibilityTabView()
        tabView.addTabViewItem(compatibilityItem)
    }

    // MARK: 输入法与快捷键 tab

    private func buildGeneralTabView() -> NSView {
        let container = NSView()

        let helpLabel = NSTextField(wrappingLabelWithString:
            "「按 Fn 说话」固定使用豆包输入法，不需要配置。这里配置的是你日常使用的输入源：语音结束后找不到之前输入源时的恢复目标，以及 Ctrl+Space 轮换的两端。"
        )
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor

        let chineseLabel = NSTextField(labelWithString: "日常中文输入法：")
        let englishLabel = NSTextField(labelWithString: "日常英文键盘：")

        chinesePopup.target = self
        chinesePopup.action = #selector(chinesePopupChanged(_:))
        englishPopup.target = self
        englishPopup.action = #selector(englishPopupChanged(_:))
        ctrlSpaceCheckbox.target = self
        ctrlSpaceCheckbox.action = #selector(ctrlSpaceToggled(_:))
        pauseMediaCheckbox.target = self
        pauseMediaCheckbox.action = #selector(pauseMediaToggled(_:))

        let grid = NSGridView(views: [
            [chineseLabel, chinesePopup],
            [englishLabel, englishPopup],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300

        generalStatusLabel.font = .systemFont(ofSize: 12)
        generalStatusLabel.textColor = .secondaryLabelColor

        [helpLabel, grid, ctrlSpaceCheckbox, pauseMediaCheckbox, generalStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            helpLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            helpLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            ctrlSpaceCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            ctrlSpaceCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            ctrlSpaceCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            pauseMediaCheckbox.topAnchor.constraint(equalTo: ctrlSpaceCheckbox.bottomAnchor, constant: 10),
            pauseMediaCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            pauseMediaCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            generalStatusLabel.topAnchor.constraint(equalTo: pauseMediaCheckbox.bottomAnchor, constant: 14),
            generalStatusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            generalStatusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            generalStatusLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])

        return container
    }

    /// 重新填充两个下拉框、复选框和状态提示。
    private func reloadGeneralTab() {
        populate(
            popup: chinesePopup,
            sources: InputSourceManager.enabledSelectableMethods()
                .filter { !($0.sourceID ?? "").hasPrefix(DoubaoVoiceHUDDetector.imeBundleID) },
            configuredID: GeneralSettings.normalChineseInputSourceID,
            configuredName: GeneralSettings.normalChineseInputMethodName,
            missingKind: .method
        )
        populate(
            popup: englishPopup,
            sources: InputSourceManager.enabledSelectableLayouts(),
            configuredID: GeneralSettings.normalEnglishKeyboardLayoutID,
            configuredName: GeneralSettings.normalEnglishKeyboardLayoutName,
            missingKind: .layout
        )
        ctrlSpaceCheckbox.state = GeneralSettings.ctrlSpaceSwitchEnabled ? .on : .off
        pauseMediaCheckbox.state = GeneralSettings.pauseMediaDuringVoice ? .on : .off
        refreshGeneralStatus()
    }

    /// 下拉框列出系统里已启用的输入源；配置的输入源当前未启用时，
    /// 追加一个「（未启用）」项保住用户的选择，不静默改配置。
    private func populate(
        popup: NSPopUpButton,
        sources: [InputSource],
        configuredID: String,
        configuredName: String,
        missingKind: InputSource.Kind
    ) {
        popup.removeAllItems()

        let usable = sources.filter { $0.sourceID != nil }
        for source in usable {
            popup.addItem(withTitle: source.value)
            popup.lastItem?.representedObject = source
        }

        if usable.isEmpty {
            popup.addItem(withTitle: "（系统里没有可用项）")
            popup.lastItem?.isEnabled = false
            return
        }

        if let index = usable.firstIndex(where: { $0.sourceID == configuredID }) {
            popup.selectItem(at: index)
        } else {
            popup.menu?.addItem(.separator())
            let missing = InputSource(kind: missingKind, value: configuredName, sourceID: configuredID)
            popup.addItem(withTitle: "\(configuredName)（未启用）")
            popup.lastItem?.representedObject = missing
            popup.select(popup.lastItem)
        }
    }

    private func refreshGeneralStatus() {
        var lines: [String] = []

        let chineseConfiguredEnabled = InputSourceManager.isSourceEnabled(
            id: GeneralSettings.normalChineseInputSourceID
        )
        let englishConfiguredEnabled = InputSourceManager.isSourceEnabled(
            id: GeneralSettings.normalEnglishKeyboardLayoutID
        )
        let resolvedChinese = DoubaoVoiceController.resolvedNormalChineseInputSource()
        let resolvedEnglish = DoubaoVoiceController.resolvedNormalEnglishLayout()

        if !chineseConfiguredEnabled {
            if let fallback = resolvedChinese {
                lines.append("⚠️ 配置的中文输入法未启用，暂时改用「\(fallback.value)」。")
            } else {
                lines.append("⚠️ 系统里没有已启用的中文输入法，Ctrl+Space 轮换已自动暂停（按键交回系统）。")
            }
        }
        if !englishConfiguredEnabled {
            if let fallback = resolvedEnglish {
                lines.append("⚠️ 配置的英文键盘未启用，暂时改用「\(fallback.value)」。")
            } else {
                lines.append("⚠️ 系统里没有已启用的键盘布局，Ctrl+Space 轮换已自动暂停（按键交回系统）。")
            }
        }
        if !GeneralSettings.ctrlSpaceSwitchEnabled {
            lines.append("Ctrl+Space 轮换已关闭，该快捷键交回系统处理。")
        }

        generalStatusLabel.stringValue = lines.joined(separator: "\n")
        generalStatusLabel.textColor = lines.contains(where: { $0.hasPrefix("⚠️") })
            ? .systemOrange
            : .secondaryLabelColor
    }

    @objc private func chinesePopupChanged(_ sender: NSPopUpButton) {
        guard let source = sender.selectedItem?.representedObject as? InputSource,
              let id = source.sourceID
        else { return }
        GeneralSettings.setNormalChineseInputSource(id: id, name: source.value)
    }

    @objc private func englishPopupChanged(_ sender: NSPopUpButton) {
        guard let source = sender.selectedItem?.representedObject as? InputSource,
              let id = source.sourceID
        else { return }
        GeneralSettings.setNormalEnglishKeyboardLayout(id: id, name: source.value)
    }

    @objc private func ctrlSpaceToggled(_ sender: NSButton) {
        GeneralSettings.ctrlSpaceSwitchEnabled = sender.state == .on
    }

    @objc private func pauseMediaToggled(_ sender: NSButton) {
        GeneralSettings.pauseMediaDuringVoice = sender.state == .on
    }

    @objc private func generalSettingsDidChange(_ notification: Notification) {
        // 通知可能在 popup 的 action 里同步发出，异步刷新避免在回调中重建菜单。
        DispatchQueue.main.async { [weak self] in
            self?.reloadGeneralTab()
        }
    }

    // MARK: 应用兼容性 tab

    private func buildCompatibilityTabView() -> NSView {
        let container = NSView()

        let helpLabel = NSTextField(wrappingLabelWithString:
            "有些应用（多见于 Electron 类，比如 Notion、VS Code）切完输入法后，文本框里其实没切过去。把它们加进来，助手会做一次极短的窗口聚焦，让切换立刻生效。"
        )
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "应用"
        appColumn.width = 180

        let bundleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        bundleColumn.title = "Bundle ID"
        bundleColumn.width = 300

        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(bundleColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        scrollView.documentView = tableView

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.usesSingleLineMode = false
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0

        let addAppButton = NSButton(title: "添加应用…", target: self, action: #selector(addApplication(_:)))
        let addBundleIDButton = NSButton(title: "用 Bundle ID 添加…", target: self, action: #selector(addBundleID(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))

        let buttonStack = NSStackView(views: [addAppButton, addBundleIDButton, removeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        [helpLabel, scrollView, emptyLabel, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            helpLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            helpLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: helpLabel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: helpLabel.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 190),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 14),
            buttonStack.leadingAnchor.constraint(equalTo: helpLabel.leadingAnchor),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])

        return container
    }

    private func reloadFromSettings() {
        bundleIDs = InputSourceActivationNudgeSettings.bundleIDs.sorted()
        tableView.reloadData()
        updateControls()
    }

    private func updateControls() {
        removeButton.isEnabled = tableView.selectedRow >= 0 && tableView.selectedRow < bundleIDs.count
        emptyLabel.isHidden = !bundleIDs.isEmpty
    }

    @objc private func nudgeSettingsDidChange(_ notification: Notification) {
        reloadFromSettings()
    }

    @objc private func addApplication(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "选择需要修复的应用"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }

            var added = 0
            for url in panel.urls {
                guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                    self?.showMessage(
                        "读不到这个应用的 Bundle ID",
                        informativeText: "\(url.lastPathComponent) 看起来不是一个有效的 .app。"
                    )
                    continue
                }
                if InputSourceActivationNudgeSettings.add(bundleID: bundleID) {
                    added += 1
                }
            }

            self?.reloadFromSettings()
            if added == 0, !panel.urls.isEmpty {
                self?.showMessage(
                    "已经添加过了",
                    informativeText: "选中的应用早已在列表里。"
                )
            }
        }
    }

    @objc private func addBundleID(_ sender: Any?) {
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "例如：notion.id"

        let alert = NSAlert()
        alert.messageText = "用 Bundle ID 添加应用"
        alert.informativeText = "找不到 .app 时，可以直接填它的 Bundle ID。"
        alert.accessoryView = input
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let bundleID = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            showMessage(
                "请先填写一个 Bundle ID",
                informativeText: "格式类似 com.example.app。"
            )
            return
        }

        _ = InputSourceActivationNudgeSettings.add(bundleID: bundleID)
        reloadFromSettings()
    }

    @objc private func removeSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < bundleIDs.count else { return }

        InputSourceActivationNudgeSettings.remove(bundleID: bundleIDs[row])
        reloadFromSettings()
    }

    private func showMessage(_ messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window!)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        bundleIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < bundleIDs.count, let tableColumn = tableColumn else { return nil }

        let bundleID = bundleIDs[row]
        let value: String
        if tableColumn.identifier.rawValue == "app" {
            value = InputSourceActivationNudgeSettings.applicationName(for: bundleID)
        } else {
            value = bundleID
        }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }
}
