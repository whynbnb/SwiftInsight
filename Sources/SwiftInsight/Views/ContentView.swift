import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var prefs: AppPreferences
    @EnvironmentObject private var groupStore: ProcessGroupStore
    @State private var selectedPID: Int32?
    @State private var showTerminateConfirm = false
    @State private var terminateForce = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                categoryFilter: monitor.categoryFilter,
                groupFilterID: monitor.groupFilterID,
                groups: groupStore.groups,
                groupCounts: monitor.groupCounts,
                summary: monitor.summary,
                physicalMemory: monitor.systemMetrics.physicalMemory,
                rankings: monitor.rankings,
                rankingTab: prefs.rankingTab,
                onCategory: { category in
                    monitor.selectCategory(category)
                    if category == nil { monitor.selectGroup(nil) }
                },
                onRankingTab: { prefs.rankingTab = $0 },
                onSelectRank: { pid in
                    selectedPID = pid
                    monitor.inspectedPID = pid
                },
                onGroupSelect: { monitor.selectGroup($0) },
                onGroupCreate: { group in
                    groupStore.add(group)
                },
                onGroupUpdate: { groupStore.update($0) },
                onGroupDelete: { groupStore.remove(id: $0.id) }
            )
            .equatable()
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detailContent
        }
        .searchable(text: $monitor.filterText, prompt: L("search.prompt"))
        .onChange(of: selectedPID) { _, pid in
            monitor.inspectedPID = pid
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker(L("settings.refresh"), selection: $monitor.refreshInterval) {
                    Text(L("settings.1s")).tag(1.0)
                    Text(L("settings.2s")).tag(2.0)
                    Text(L("settings.5s")).tag(5.0)
                    Text(L("settings.10s")).tag(10.0)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .disabled(monitor.isRefreshPaused)
                .help(L("settings.refresh.main.caption"))

                Button {
                    monitor.toggleManualLock()
                } label: {
                    Label(
                        monitor.isManualLock ? L("toolbar.unlock") : L("toolbar.lock"),
                        systemImage: monitor.isManualLock ? "lock.fill" : "lock.open"
                    )
                }
                .help(L("toolbar.lock.help"))
                .tint(monitor.isManualLock ? Color.orange : nil)

                Button {
                    monitor.refresh()
                } label: {
                    Label(L("toolbar.refresh"), systemImage: "arrow.clockwise")
                }
                .help(L("toolbar.refresh.help"))
                .disabled(monitor.isRefreshPaused)
            }
        }
        .alert(
            terminateForce ? L("alert.force_quit") : L("alert.quit"),
            isPresented: $showTerminateConfirm
        ) {
            Button(L("alert.cancel"), role: .cancel) {}
            Button(terminateForce ? L("alert.force_quit_btn") : L("alert.quit_btn"), role: .destructive) {
                if let pid = selectedPID {
                    monitor.terminate(pid: pid, force: terminateForce)
                    selectedPID = nil
                }
            }
        } message: {
            if let pid = selectedPID,
               let p = monitor.processes.first(where: { $0.pid == pid }) {
                Text("\(p.name) (PID \(p.pid))")
            }
        }
    }

    // MARK: - Detail layout

    /// 主内容列（系统条 / 图表 / 汇总 / 进程表）
    private var mainColumn: some View {
        VStack(spacing: 0) {
            SystemOverviewBar()
            Divider()
            SystemHistoryCharts()
            Divider()
            SummaryBarView()
            Divider()
            ProcessTableView(selectedPID: $selectedPID)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if prefs.detailPanelPosition == .right {
            HSplitView {
                mainColumn
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                if let process = selectedProcess {
                    ProcessDetailPanel(
                        process: process,
                        layout: .vertical,
                        onTerminate: requestTerminate,
                        onForceQuit: requestForceQuit,
                        onClose: closeDetail
                    )
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        } else {
            VStack(spacing: 0) {
                mainColumn
                if let process = selectedProcess {
                    Divider()
                    ProcessDetailPanel(
                        process: process,
                        layout: .horizontal,
                        onTerminate: requestTerminate,
                        onForceQuit: requestForceQuit,
                        onClose: closeDetail
                    )
                }
            }
        }
    }

    private var selectedProcess: MonitoredProcess? {
        guard let pid = selectedPID else { return nil }
        return monitor.processes.first { $0.pid == pid }
    }

    private func requestTerminate() {
        terminateForce = false
        showTerminateConfirm = true
    }

    private func requestForceQuit() {
        terminateForce = true
        showTerminateConfirm = true
    }

    private func closeDetail() {
        selectedPID = nil
    }
}

// MARK: - Sidebar

struct SidebarView: View, Equatable {
    let categoryFilter: ProcessCategory?
    let groupFilterID: UUID?
    let groups: [ProcessFilterGroup]
    let groupCounts: [UUID: Int]
    let summary: ResourceSummary
    let physicalMemory: UInt64
    let rankings: CategoryRankings
    let rankingTab: RankingTab
    var onCategory: (ProcessCategory?) -> Void
    var onRankingTab: (RankingTab) -> Void
    var onSelectRank: (Int32) -> Void
    var onGroupSelect: (UUID?) -> Void
    var onGroupCreate: (ProcessFilterGroup) -> UUID
    var onGroupUpdate: (ProcessFilterGroup) -> Void
    var onGroupDelete: (ProcessFilterGroup) -> Void

    /// 只比较展示数据，忽略闭包；无关状态变化时跳过重建，避免侧栏闪烁
    nonisolated static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.categoryFilter == rhs.categoryFilter
            && lhs.groupFilterID == rhs.groupFilterID
            && lhs.groups == rhs.groups
            && lhs.groupCounts == rhs.groupCounts
            && lhs.summary == rhs.summary
            && lhs.physicalMemory == rhs.physicalMemory
            && lhs.rankings == rhs.rankings
            && lhs.rankingTab == rhs.rankingTab
    }

    var body: some View {
        VStack(spacing: 0) {
            // 固定区域：分类 / 自定义分组 / 资源对比
            VStack(alignment: .leading, spacing: 14) {
                categorySection
                CustomGroupsSection(
                    groups: groups,
                    counts: groupCounts,
                    selectedID: groupFilterID,
                    onSelect: onGroupSelect,
                    onCreate: onGroupCreate,
                    onUpdate: onGroupUpdate,
                    onDelete: onGroupDelete
                )
                resourceSection
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Divider()

            // 仅排行区域滚动，占据剩余高度
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L("sidebar.who"))
                CategoryRankingsView(
                    rankingTab: rankingTab,
                    rankings: rankings,
                    onSelectTab: onRankingTab,
                    onSelect: onSelectRank
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("SwiftInsight")
    }

    // MARK: Fixed sections

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(L("sidebar.category"))
            ForEach(CategoryFilterItem.allCases) { item in
                categoryRow(item)
            }
        }
    }

    private var resourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("sidebar.resource"))
            ResourceBreakdownView(summary: summary, physicalMemory: physicalMemory)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func categoryRow(_ item: CategoryFilterItem) -> some View {
        let selected = groupFilterID == nil && CategoryFilterItem.from(category: categoryFilter) == item
        return Button {
            onCategory(item.category)
        } label: {
            HStack {
                Label(item.title, systemImage: item.symbolName)
                Spacer()
                Text("\(count(for: item))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func count(for item: CategoryFilterItem) -> Int {
        let s = summary
        switch item {
        case .all: return s.totalCount
        case .appleSystem: return s.appleSystemCount
        case .appleApp: return s.appleAppCount
        case .thirdParty: return s.thirdPartyCount
        }
    }
}

// MARK: - Resource breakdown

struct ResourceBreakdownView: View {
    let summary: ResourceSummary
    let physicalMemory: UInt64

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 10) {
            Text("CPU")
                .font(.caption)
                .foregroundStyle(.secondary)
            stackedBar(
                segments: [
                    (.blue, s.appleSystemCPU),
                    (.cyan, s.appleAppCPU),
                    (.orange, s.thirdPartyCPU),
                ],
                total: 100
            )
            legendRow(color: .blue, title: L("cat.short.system"), value: String(format: "%.1f%%", s.appleSystemCPU))
            legendRow(color: .cyan, title: L("cat.appleApp"), value: String(format: "%.1f%%", s.appleAppCPU))
            legendRow(color: .orange, title: L("cat.thirdParty"), value: String(format: "%.1f%%", s.thirdPartyCPU))

            Divider().padding(.vertical, 4)

            Text(L("metric.memory"))
                .font(.caption)
                .foregroundStyle(.secondary)
            let phys = Double(physicalMemory)
            stackedBar(
                segments: [
                    (.blue, Double(s.appleSystemMemory)),
                    (.cyan, Double(s.appleAppMemory)),
                    (.orange, Double(s.thirdPartyMemory)),
                ],
                total: max(phys, 1)
            )
            legendRow(color: .blue, title: L("cat.short.system"), value: byteString(s.appleSystemMemory))
            legendRow(color: .cyan, title: L("cat.appleApp"), value: byteString(s.appleAppMemory))
            legendRow(color: .orange, title: L("cat.thirdParty"), value: byteString(s.thirdPartyMemory))

            Divider().padding(.vertical, 4)

            HStack {
                Text(L("sidebar.apple_total"))
                    .font(.caption.weight(.semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "CPU %.1f%%", s.appleCPU))
                        .font(.caption2)
                        .monospacedDigit()
                    Text(byteString(s.appleMemory))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stackedBar(segments: [(Color, Double)], total: Double) -> some View {
        let values = segments.map { max(0, $0.1) }
        // total 为 100（CPU）或物理内存字节；按绝对比例铺色，剩余为空闲底轨
        let denom = max(total, 0.0001)

        return Canvas { context, size in
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(bg, with: .color(Color.secondary.opacity(0.15)))

            var x: CGFloat = 0
            let h = size.height
            let w = size.width
            for (index, seg) in segments.enumerated() {
                let fraction = CGFloat(min(1, values[index] / denom))
                guard fraction > 0 else { continue }
                var segmentWidth = w * fraction
                if x + segmentWidth > w {
                    segmentWidth = max(0, w - x)
                }
                if segmentWidth > 0, segmentWidth < 1 { segmentWidth = 1 }
                guard segmentWidth > 0 else { continue }
                let rect = CGRect(x: x, y: 0, width: segmentWidth, height: h)
                context.fill(Path(rect), with: .color(seg.0))
                x += segmentWidth
                if x >= w { break }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func legendRow(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2)
            Spacer()
            Text(value).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

// MARK: - Summary bar

/// 刷新状态指示（汇总栏右侧）
struct RefreshStatusView: View {
    @EnvironmentObject private var monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: monitor.isRefreshPaused ? "pause.circle.fill" : "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(monitor.isRefreshPaused ? Color.orange : Color.green)
                .symbolRenderingMode(.hierarchical)
            Text(monitor.statusText)
                .font(.caption)
                .foregroundStyle(monitor.isRefreshPaused ? Color.primary : Color.secondary)
                .monospacedDigit()
        }
        .help(monitor.isRefreshPaused ? L("summary.pause_on") : L("summary.pause_off"))
        .animation(.easeInOut(duration: 0.15), value: monitor.isRefreshPaused)
        .accessibilityLabel(monitor.statusText)
    }
}

struct SummaryBarView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var groupStore: ProcessGroupStore

    var body: some View {
        let s = monitor.summary
        HStack(spacing: 16) {
            summaryChip(
                title: L("cat.appleSystem"),
                cpu: s.appleSystemCPU,
                memory: s.appleSystemMemory,
                count: s.appleSystemCount,
                color: .blue
            )
            summaryChip(
                title: L("cat.appleApp"),
                cpu: s.appleAppCPU,
                memory: s.appleAppMemory,
                count: s.appleAppCount,
                color: .cyan
            )
            summaryChip(
                title: L("cat.thirdParty"),
                cpu: s.thirdPartyCPU,
                memory: s.thirdPartyMemory,
                count: s.thirdPartyCount,
                color: .orange
            )
            // 自定义分组卡放在分类卡之后
            if let usage = selectedGroupUsage {
                groupUsageChip(usage)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                RefreshStatusView()
                HStack(spacing: 8) {
                    Text(String(format: L("summary.process_count"), s.totalCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if monitor.lastUpdate != .distantPast {
                        Text("\(L("summary.updated")) \(monitor.lastUpdate, style: .time)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.15), value: monitor.isRefreshPaused)
    }

    private struct GroupUsage {
        let group: ProcessFilterGroup
        let cpu: Double
        let memory: UInt64
        let count: Int
    }

    /// 当前选中的自定义分组占用（按分组全量成员统计，不受表格搜索影响）
    private var selectedGroupUsage: GroupUsage? {
        guard let group = groupStore.group(with: monitor.groupFilterID) else { return nil }
        let savedRules = groupStore.savedRulesByID
        let pids = ProcessGroupMatcher.matchedProcessIDs(
            group: group,
            groups: groupStore.groups,
            processes: monitor.processes,
            savedRules: savedRules
        )
        var cpu = 0.0
        var memory: UInt64 = 0
        var count = 0
        for process in monitor.processes where pids.contains(process.pid) {
            count += 1
            if process.cpuAvailable { cpu += process.cpuPercent }
            if process.memoryAvailable { memory += process.memoryBytes }
        }
        return GroupUsage(group: group, cpu: cpu, memory: memory, count: count)
    }

    private func groupUsageChip(_ usage: GroupUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: usage.group.symbolName)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text(shortGroupName(usage.group.name))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("· \(usage.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Text(String(format: "%.1f%%", usage.cpu))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(ByteCountFormatter.string(fromByteCount: Int64(usage.memory), countStyle: .memory))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        }
        .help("\(usage.group.name)\n\(L("summary.group.help"))")
    }

    /// 分组卡保持紧凑：名称过长时直接截断，完整名称放在 tooltip 里
    private func shortGroupName(_ name: String) -> String {
        name.count <= 16 ? name : String(name.prefix(15)) + "…"
    }

    private func summaryChip(title: String, cpu: Double, memory: UInt64, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color.gradient).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("· \(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Text(String(format: "%.1f%%", cpu))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        }
    }
}

// MARK: - Detail bar

enum DetailPanelLayout {
    case horizontal
    case vertical
}

struct ProcessDetailBar: View {
    let process: MonitoredProcess
    var layout: DetailPanelLayout = .horizontal
    var onTerminate: () -> Void
    var onForceQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        Group {
            if layout == .vertical {
                verticalContent
            } else {
                horizontalContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Horizontal（底部面板）

    private var horizontalContent: some View {
        HStack(spacing: 16) {
            iconAndTitle

            Spacer()

            detailStat("PID", "\(process.pid)")
            detailStat(L("detail.user"), process.username)
            detailStat(L("detail.threads"), "\(process.threadCount)")
            detailStat("CPU", process.cpuFormatted)
            detailStat(L("detail.memory"), process.memoryFormatted)
            if process.metricsFromHelper {
                detailStat(L("detail.source"), "root Helper")
            }

            if let bid = process.bundleIdentifier {
                detailStat("Bundle", bid)
            }

            actionsMenu
                .frame(width: 70)

            closeButton
        }
    }

    // MARK: Vertical（右侧面板）

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                iconAndTitle
                Spacer(minLength: 4)
                actionsMenu
                closeButton
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                detailStat("PID", "\(process.pid)")
                detailStat(L("detail.threads"), "\(process.threadCount)")
                detailStat(L("detail.user"), process.username)
                detailStat("CPU", process.cpuFormatted)
                detailStat(L("detail.memory"), process.memoryFormatted)
                if process.metricsFromHelper {
                    detailStat(L("detail.source"), "root Helper")
                }
                if let bid = process.bundleIdentifier {
                    detailStat("Bundle", bid)
                }
            }
        }
    }

    private var iconAndTitle: some View {
        HStack(spacing: 10) {
            ProcessIconView(path: process.path, name: process.name)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(process.name)
                        .font(.headline)
                        .lineLimit(1)
                    CategoryBadge(category: process.category)
                }
                Text(process.path.isEmpty ? L("detail.path_unavailable") : process.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(layout == .vertical ? 2 : 1)
                    .truncationMode(.middle)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(L("alert.quit_btn"), action: onTerminate)
            Button(L("alert.force_quit_btn"), role: .destructive, action: onForceQuit)
            Divider()
            if !process.path.isEmpty {
                Button(L("menu.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.path)])
                }
                Button(L("menu.copy_path")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(process.path, forType: .string)
                }
            }
        } label: {
            Label(L("detail.actions"), systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("detail.close"))
        .accessibilityLabel(L("detail.close"))
    }

    private func detailStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

struct CategoryBadge: View {
    let category: ProcessCategory

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tagColor)
                .frame(width: 5, height: 5)
            Text(category.shortName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(category.displayName)
    }

    private var tagColor: Color {
        switch category {
        case .appleSystem: return Color(red: 0.35, green: 0.55, blue: 0.95)
        case .appleApp:    return Color(red: 0.25, green: 0.72, blue: 0.78)
        case .thirdParty:  return Color(red: 0.92, green: 0.55, blue: 0.28)
        case .unknown:     return Color.secondary
        }
    }
}

struct ProcessIconView: View {
    let path: String
    let name: String

    var body: some View {
        Image(nsImage: ProcessClassifier.icon(for: path, name: name))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}
