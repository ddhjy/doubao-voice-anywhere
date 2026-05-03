import AppKit
import Foundation
import UniformTypeIdentifiers

final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "移除", target: nil, action: nil)
    private let emptyLabel = NSTextField(
        labelWithString: "还没有添加任何应用\n遇到切换不生效时，从下方加进来。"
    )

    private var bundleIDs: [String] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "应用兼容性设置"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        buildContentView()
        reloadFromSettings()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: InputSourceActivationNudgeSettings.changedNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        reloadFromSettings()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContentView() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "需要修复输入法切换的应用")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let helpLabel = NSTextField(
            labelWithString: "有些应用（多见于 Electron 类，比如 Mira、VS Code）切完输入法后，文本框里其实没切过去。把它们加进来，助手会做一次极短的窗口聚焦，让切换立刻生效。"
        )
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 3

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "应用"
        appColumn.width = 180

        let bundleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        bundleColumn.title = "Bundle ID"
        bundleColumn.width = 320

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

        [titleLabel, helpLabel, scrollView, emptyLabel, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            helpLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            helpLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            helpLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 190),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 14),
            buttonStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
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

    @objc private func settingsDidChange(_ notification: Notification) {
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
        input.placeholderString = "例如：net.byteintl.mira"

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
                informativeText: "格式类似 net.byteintl.mira。"
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
