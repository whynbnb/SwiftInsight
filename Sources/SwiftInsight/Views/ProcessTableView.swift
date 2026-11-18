import SwiftUI
import AppKit

/// AppKit NSTableView 封装：系统级条纹、流畅滚动；支持聚合树缩进与展开
struct ProcessTableView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var groupStore: ProcessGroupStore
    @Binding var selectedPID: Int32?

    var body: some View {
        VStack(spacing: 0) {
            sortHeader
            ProcessNSTable(
                rows: monitor.displayRows,
                selectedPID: $selectedPID,
                sortColumn: monitor.sortColumn,
                sortAscending: monitor.sortAscending,
                groups: groupStore.groups,
                onSort: { monitor.toggleSort($0) },
                onTerminate: { pid, force in
                    monitor.terminate(pid: pid, force: force)
                },
                onFilterCategory: { category in
                    monitor.selectCategory(category)
                },
                onAddToGroup: { pid, groupID in
                    guard let process = monitor.processes.first(where: { $0.pid == pid }) else { return }
                    groupStore.addProcess(process, to: groupID)
                    monitor.selectGroup(groupID)
                },
                onCreateGroupWithProcess: { pid in
                    guard let process = monitor.processes.first(where: { $0.pid == pid }) else { return }
                    var group = ProcessFilterGroup(
                        name: ProcessAggregator.familyName(process.name),
                        symbolName: ProcessFilterGroup.symbolChoices[0],
                        isDynamic: true
                    )
                    group.rules = [ProcessGroupMatcher.rule(for: process)]
                    let id = groupStore.add(group)
                    monitor.selectGroup(id)
                },
                onToggleExpand: { key in
                    monitor.toggleExpanded(key)
                }
            )
        }
    }

    private var sortHeader: some View {
        HStack(spacing: 12) {
            Text(L("toolbar.view"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            Picker(L("toolbar.view"), selection: $monitor.displayMode) {
                ForEach(ListDisplayMode.allCases) { mode in
                    Text(mode.displayName)
                        .lineLimit(1)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 固定为内容宽度：窗口变窄时不再压缩导致文字竖排
            .fixedSize()

            Divider().frame(height: 16)

            Text(L("sidebar.filter"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            ScopeFilterControl()

            if let group = groupStore.groups.first(where: { $0.id == monitor.groupFilterID }) {
                GroupFilterChip(group: group) {
                    monitor.selectGroup(nil)
                }
            }

            Spacer(minLength: 8)

            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 96, alignment: .trailing)
        }
        // 固定高度，避免每次刷新时表头高度抖动导致整体闪烁
        .frame(height: 34)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var countLabel: String {
        if monitor.displayMode == .tree || monitor.displayMode == .application {
            let groups = monitor.displayRows.filter { $0.depth == 0 }.count
            return String(format: L("table.groups"), groups, monitor.displayRows.count)
        }
        return String(format: L("table.items"), monitor.displayRows.count)
    }
}

// MARK: - NSTableView bridge

/// 前后台范围选择：独立观察 monitor，切换时只重建这个小控件
private struct ScopeFilterControl: View {
    @EnvironmentObject private var monitor: ProcessMonitor

    var body: some View {
        Picker(L("sidebar.filter"), selection: $monitor.processScope) {
            ForEach(ProcessScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        // 按应用聚合时忽略范围筛选
        .disabled(monitor.displayMode == .application)
        .help(L("sidebar.filter.help"))
    }
}

private struct ProcessNSTable: NSViewRepresentable {
    let rows: [ProcessDisplayRow]
    @Binding var selectedPID: Int32?
    let sortColumn: SortColumn
    let sortAscending: Bool
    let groups: [ProcessFilterGroup]
    var onSort: (SortColumn) -> Void
    var onTerminate: (Int32, Bool) -> Void
    var onFilterCategory: (ProcessCategory) -> Void
    var onAddToGroup: (Int32, UUID) -> Void
    var onCreateGroupWithProcess: (Int32) -> Void
    var onToggleExpand: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.gridStyleMask = []
        table.headerView = NSTableHeaderView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = context.coordinator.makeContextMenu()

        for col in Coordinator.columns {
            let column = NSTableColumn(identifier: col.id)
            column.title = col.title
            column.width = col.width
            column.minWidth = col.minWidth
            column.resizingMask = .userResizingMask
            if col.numeric {
                column.headerCell.alignment = .right
            }
            table.addTableColumn(column)
        }

        scrollView.documentView = table
        context.coordinator.tableView = table
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(rows: rows, selectedPID: selectedPID)
        context.coordinator.syncSortIndicator()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        struct ColumnDef {
            let id: NSUserInterfaceItemIdentifier
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
            let numeric: Bool
        }

        static let columns: [ColumnDef] = [
            .init(id: .init("name"), title: L("table.name"), width: 360, minWidth: 200, numeric: false),
            .init(id: .init("cpu"), title: "CPU %", width: 72, minWidth: 56, numeric: true),
            .init(id: .init("memory"), title: L("metric.memory"), width: 90, minWidth: 70, numeric: true),
            .init(id: .init("threads"), title: L("sort.threads"), width: 56, minWidth: 44, numeric: true),
            .init(id: .init("pid"), title: "PID", width: 64, minWidth: 48, numeric: true),
            .init(id: .init("user"), title: L("table.user"), width: 88, minWidth: 60, numeric: false),
        ]

        var parent: ProcessNSTable
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        private var rows: [ProcessDisplayRow] = []
        private var isApplying = false
        private var lastSortIndicatorState = ""
        private var iconCache: [String: NSImage] = [:]

        init(_ parent: ProcessNSTable) {
            self.parent = parent
        }

        func apply(rows: [ProcessDisplayRow], selectedPID: Int32?) {
            // 始终采用最新快照，避免 isApplying 期间丢弃有数据的更新
            let dataChanged = !Self.sameDisplayData(self.rows, rows)
            let selectionChanged = selectedPID != currentSelectedPID()
            guard dataChanged || selectionChanged else { return }

            self.rows = rows

            let applyBlock = { [weak self] in
                guard let self, let table = self.tableView else { return }

                let savedSelection = selectedPID
                let clip = self.scrollView?.contentView
                let savedOrigin = clip?.bounds.origin

                if dataChanged {
                    table.reloadData()
                }

                if let pid = savedSelection,
                   let index = self.rows.firstIndex(where: { $0.pid == pid }) {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                } else if savedSelection == nil {
                    table.deselectAll(nil)
                }

                if let clip, let savedOrigin {
                    clip.scroll(to: savedOrigin)
                    self.scrollView?.reflectScrolledClipView(clip)
                }

                self.isApplying = false
            }

            if Thread.isMainThread {
                isApplying = true
                applyBlock()
            } else {
                isApplying = true
                Task { @MainActor in applyBlock() }
            }
        }

        private func currentSelectedPID() -> Int32? {
            guard let table = tableView, table.selectedRow >= 0, table.selectedRow < rows.count else {
                return nil
            }
            return rows[table.selectedRow].pid
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rows.count, let tableColumn else { return nil }
            let item = rows[row]
            let process = item.process
            let id = tableColumn.identifier

            switch id.rawValue {
            case "name":
                return nameCell(tableView: tableView, row: item)
            case "cpu":
                return textCell(
                    tableView: tableView,
                    id: id,
                    text: process.cpuFormatted,
                    alignment: .right,
                    color: process.cpuAvailable
                        ? (process.metricsFromHelper ? NSColor.systemPurple : cpuColor(process.cpuPercent))
                        : .tertiaryLabelColor,
                    toolTip: process.metricsSourceHint
                )
            case "memory":
                return textCell(
                    tableView: tableView,
                    id: id,
                    text: process.memoryFormatted,
                    alignment: .right,
                    color: process.memoryAvailable
                        ? (process.metricsFromHelper ? NSColor.systemPurple : .labelColor)
                        : .tertiaryLabelColor,
                    toolTip: process.metricsSourceHint
                )
            case "threads":
                return textCell(
                    tableView: tableView,
                    id: id,
                    text: "\(process.threadCount)",
                    alignment: .right,
                    color: .secondaryLabelColor
                )
            case "pid":
                return textCell(
                    tableView: tableView,
                    id: id,
                    text: "\(process.pid)",
                    alignment: .right,
                    color: .secondaryLabelColor
                )
            case "user":
                return textCell(
                    tableView: tableView,
                    id: id,
                    text: process.username,
                    alignment: .left,
                    color: .secondaryLabelColor
                )
            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table = tableView else { return }
            let pid: Int32?
            if table.selectedRow >= 0, table.selectedRow < rows.count {
                pid = rows[table.selectedRow].pid
            } else {
                pid = nil
            }
            if parent.selectedPID != pid {
                parent.selectedPID = pid
            }
        }

        /// 表头排序指示器与 monitor 的排序状态保持同步
        func syncSortIndicator() {
            guard let table = tableView else { return }
            let key = parent.sortColumn.rawValue
            let ascending = parent.sortAscending
            let state = "\(key):\(ascending)"
            guard state != lastSortIndicatorState else { return }
            lastSortIndicatorState = state

            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            // 明确设置列头指示箭头，确保排序状态可见
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            let arrow = NSImage(
                systemSymbolName: ascending ? "chevron.up" : "chevron.down",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config)
            for column in table.tableColumns {
                table.setIndicatorImage(nil, in: column)
            }
            if let column = table.tableColumns.first(where: { $0.identifier.rawValue == key }) {
                table.setIndicatorImage(arrow, in: column)
            }
            table.headerView?.needsDisplay = true
        }

        /// 点击列头排序
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let column = SortColumn(rawValue: tableColumn.identifier.rawValue) else { return }
            parent.onSort(column)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table = tableView else { return }
            let row = table.clickedRow
            guard row >= 0, row < rows.count else { return }
            let item = rows[row]
            if item.hasChildren {
                parent.onToggleExpand(item.groupKey)
            }
        }

        // MARK: Cells

        private func nameCell(tableView: NSTableView, row item: ProcessDisplayRow) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("nameTreeCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? TreeNameCell
                ?? TreeNameCell(identifier: cellID)

            let process = item.process
            cell.configure(
                icon: icon(for: process),
                title: process.name,
                tag: process.category.shortName,
                memberCount: item.hasChildren ? item.memberCount : nil,
                depth: item.depth,
                hasChildren: item.hasChildren,
                isExpanded: item.isExpanded,
                toolTip: process.path.isEmpty ? process.name : process.path
            )
            cell.onToggle = { [weak self] in
                self?.parent.onToggleExpand(item.groupKey)
            }
            return cell
        }

        private func textCell(
            tableView: NSTableView,
            id: NSUserInterfaceItemIdentifier,
            text: String,
            alignment: NSTextAlignment,
            color: NSColor,
            toolTip: String? = nil
        ) -> NSView {
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? makeTextCell(identifier: id)
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.textColor = color
            cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.textField?.toolTip = toolTip
            cell.toolTip = toolTip
            return cell
        }

        private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.isEditable = false
            textField.isBordered = false
            textField.drawsBackground = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for process: MonitoredProcess) -> NSImage {
            let key = process.path.isEmpty ? process.name : process.path
            if let cached = iconCache[key] { return cached }
            // ProcessClassifier 已有全局 NSCache；此处只做本表视图热缓存
            let image = ProcessClassifier.icon(for: process.path, name: process.name)
            image.size = NSSize(width: 16, height: 16)
            iconCache[key] = image
            if iconCache.count > 256 {
                // 淘汰约一半，避免一次性清空导致图标 thrash
                let drop = iconCache.keys.prefix(iconCache.count / 2)
                for k in drop { iconCache.removeValue(forKey: k) }
            }
            return image
        }

        private func cpuColor(_ cpu: Double) -> NSColor {
            if cpu >= 50 { return .systemRed }
            if cpu >= 20 { return .systemOrange }
            if cpu >= 5 { return .labelColor }
            return .secondaryLabelColor
        }

        private static func sameDisplayData(_ a: [ProcessDisplayRow], _ b: [ProcessDisplayRow]) -> Bool {
            guard a.count == b.count else { return false }
            for i in a.indices {
                let x = a[i]
                let y = b[i]
                if x.id != y.id
                    || x.depth != y.depth
                    || x.hasChildren != y.hasChildren
                    || x.isExpanded != y.isExpanded
                    || x.memberCount != y.memberCount
                    || x.process.pid != y.process.pid
                    || x.process.name != y.process.name
                    || abs(x.process.cpuPercent - y.process.cpuPercent) > 0.05
                    || x.process.memoryBytes != y.process.memoryBytes
                    || x.process.cpuAvailable != y.process.cpuAvailable
                    || x.process.memoryAvailable != y.process.memoryAvailable
                    || x.process.metricsFromHelper != y.process.metricsFromHelper
                    || x.process.threadCount != y.process.threadCount
                    || x.process.username != y.process.username
                    || x.process.category != y.process.category {
                    return false
                }
            }
            return true
        }

        // MARK: Context menu

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            return menu
        }

        private func processAtClickedRow() -> ProcessDisplayRow? {
            guard let table = tableView else { return nil }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard row >= 0, row < rows.count else { return nil }
            return rows[row]
        }
    }
}

// MARK: - Tree name cell

private final class TreeNameCell: NSTableCellView {
    private let disclosure = NSButton()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint?
    var onToggle: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.setButtonType(.momentaryChange)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(disclosure)
        addSubview(iconView)
        addSubview(titleField)
        imageView = iconView
        textField = titleField

        let lead = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        leadingConstraint = lead

        NSLayoutConstraint.activate([
            lead,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 14),
            disclosure.heightAnchor.constraint(equalToConstant: 14),

            iconView.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        icon: NSImage,
        title: String,
        tag: String,
        memberCount: Int?,
        depth: Int,
        hasChildren: Bool,
        isExpanded: Bool,
        toolTip: String
    ) {
        leadingConstraint?.constant = 2 + CGFloat(depth) * 16
        iconView.image = icon

        if hasChildren {
            disclosure.isHidden = false
            disclosure.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: isExpanded ? L("menu.collapse") : L("menu.expand")
            )
            disclosure.contentTintColor = .secondaryLabelColor
            disclosure.isEnabled = true
        } else {
            disclosure.isHidden = false
            disclosure.image = nil
            disclosure.isEnabled = false
        }

        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let memberCount, memberCount > 1 {
            attributed.append(NSAttributedString(
                string: "  ·\(memberCount)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        attributed.append(NSAttributedString(
            string: "  \(tag)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        titleField.attributedStringValue = attributed
        titleField.toolTip = toolTip
    }

    @objc private func toggle() {
        onToggle?()
    }
}

extension ProcessNSTable.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = processAtClickedRow() else { return }
        let process = item.process

        if item.hasChildren {
            let title = item.isExpanded ? L("menu.collapse") : L("menu.expand")
            let expand = NSMenuItem(title: title, action: #selector(toggleExpand(_:)), keyEquivalent: "")
            expand.target = self
            expand.representedObject = item.groupKey
            menu.addItem(expand)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: L("alert.quit_btn"), action: #selector(quitProcess(_:)), keyEquivalent: "")
        quit.target = self
        quit.representedObject = process.pid
        menu.addItem(quit)

        let force = NSMenuItem(title: L("alert.force_quit_btn"), action: #selector(forceQuitProcess(_:)), keyEquivalent: "")
        force.target = self
        force.representedObject = process.pid
        menu.addItem(force)

        menu.addItem(.separator())

        if !process.path.isEmpty {
            let reveal = NSMenuItem(title: L("menu.reveal"), action: #selector(revealInFinder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = process.path
            menu.addItem(reveal)

            let copyPath = NSMenuItem(title: L("menu.copy_path"), action: #selector(copyString(_:)), keyEquivalent: "")
            copyPath.target = self
            copyPath.representedObject = process.path
            menu.addItem(copyPath)
        }

        if let bid = process.bundleIdentifier {
            let copyBID = NSMenuItem(title: L("menu.copy_bid"), action: #selector(copyString(_:)), keyEquivalent: "")
            copyBID.target = self
            copyBID.representedObject = bid
            menu.addItem(copyBID)
        }

        menu.addItem(.separator())

        let filter = NSMenuItem(title: L("menu.filter_category"), action: #selector(filterCategory(_:)), keyEquivalent: "")
        filter.target = self
        filter.representedObject = process.category.rawValue
        menu.addItem(filter)

        let groupsItem = NSMenuItem(title: L("menu.groups"), action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        if parent.groups.isEmpty {
            let empty = NSMenuItem(title: L("group.empty_hint"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            groupMenu.addItem(empty)
        } else {
            for group in parent.groups {
                let add = NSMenuItem(title: group.name, action: #selector(addToGroup(_:)), keyEquivalent: "")
                add.target = self
                add.representedObject = AddToGroupPayload(pid: process.pid, groupID: group.id)
                groupMenu.addItem(add)
            }
        }
        groupMenu.addItem(.separator())
        let create = NSMenuItem(title: L("menu.create_group"), action: #selector(createGroupWithProcess(_:)), keyEquivalent: "")
        create.target = self
        create.representedObject = process.pid
        groupMenu.addItem(create)
        groupsItem.submenu = groupMenu
        menu.addItem(groupsItem)
    }

    private final class AddToGroupPayload: NSObject {
        let pid: Int32
        let groupID: UUID

        init(pid: Int32, groupID: UUID) {
            self.pid = pid
            self.groupID = groupID
        }
    }

    @objc private func addToGroup(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? AddToGroupPayload else { return }
        parent.onAddToGroup(payload.pid, payload.groupID)
    }

    @objc private func createGroupWithProcess(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32 else { return }
        parent.onCreateGroupWithProcess(pid)
    }

    @objc private func toggleExpand(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        parent.onToggleExpand(key)
    }

    @objc private func quitProcess(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32 else { return }
        parent.onTerminate(pid, false)
    }

    @objc private func forceQuitProcess(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32 else { return }
        parent.onTerminate(pid, true)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyString(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func filterCategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let category = ProcessCategory(rawValue: raw) else { return }
        parent.onFilterCategory(category)
    }
}
