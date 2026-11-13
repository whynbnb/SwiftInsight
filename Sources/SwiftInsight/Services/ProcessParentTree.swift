import Foundation

/// 按 PPID 构建真正的父子启动关系树
/// 特殊处理：去掉 launchd 这一层，其子进程直接作为根展示
enum ProcessParentTree {

    struct Node {
        var process: MonitoredProcess
        var children: [Node]

        var memberCount: Int {
            1 + children.reduce(0) { $0 + $1.memberCount }
        }

        var totalCPU: Double {
            (process.cpuAvailable ? process.cpuPercent : 0) + children.reduce(0) { $0 + $1.totalCPU }
        }

        var totalMemory: UInt64 {
            (process.memoryAvailable ? process.memoryBytes : 0) + children.reduce(0) { $0 + $1.totalMemory }
        }

        var totalThreads: Int {
            process.threadCount + children.reduce(0) { $0 + $1.totalThreads }
        }

        var key: String { "ppid:\(process.pid)" }
    }

    static func buildForest(from processes: [MonitoredProcess]) -> [Node] {
        guard !processes.isEmpty else { return [] }

        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let bootstrapPIDs = Set(processes.filter(isBootstrapProcess).map(\.pid))

        var childrenMap: [Int32: [MonitoredProcess]] = [:]
        var roots: [MonitoredProcess] = []

        for p in processes {
            // launchd 自身稍后单独处理：不作为挂载所有进程的根
            if bootstrapPIDs.contains(p.pid) {
                continue
            }

            let parentIsBootstrap = bootstrapPIDs.contains(p.ppid)
            let parentInSet = p.ppid > 0 && p.ppid != p.pid && byPID[p.ppid] != nil

            // 父进程是 launchd → 提升为根；父进程不在集合中 → 也是根
            if parentInSet && !parentIsBootstrap {
                childrenMap[p.ppid, default: []].append(p)
            } else {
                roots.append(p)
            }
        }

        // launchd 本身若在列表中：作为无子节点的独立根（不吞并整棵树）
        for p in processes where bootstrapPIDs.contains(p.pid) {
            roots.append(p)
        }

        // 父链断裂（如 crashpad_handler 被 launchd 接管）但同属一个应用的根，
        // 合并到应用主进程下，避免同一 App 在父子视图里散成多个顶层节点。
        roots = mergeDetachedAppRoots(roots, all: byPID, childrenMap: &childrenMap)

        func build(_ p: MonitoredProcess, ancestry: Set<Int32>) -> Node {
            var nextAncestry = ancestry
            nextAncestry.insert(p.pid)
            // bootstrap 节点不挂子进程
            if bootstrapPIDs.contains(p.pid) {
                return Node(process: p, children: [])
            }
            let kids = (childrenMap[p.pid] ?? [])
                .filter { !nextAncestry.contains($0.pid) && !bootstrapPIDs.contains($0.pid) }
                .map { build($0, ancestry: nextAncestry) }
            return Node(process: p, children: kids)
        }

        return roots.map { build($0, ancestry: []) }
    }

    /// 将父链已断裂、但与应用同属 `app:` / `bid:` 组的根进程挂到主进程下。
    /// 典型：`msedge_crashpad_handler` 的 PPID 被 launchd 接管。
    private static func mergeDetachedAppRoots(
        _ roots: [MonitoredProcess],
        all: [Int32: MonitoredProcess],
        childrenMap: inout [Int32: [MonitoredProcess]]
    ) -> [MonitoredProcess] {
        guard roots.count > 1 else { return roots }

        // 只合并有明确应用身份的根，避免把同名 daemon 误并到一起
        var buckets: [String: [MonitoredProcess]] = [:]
        for root in roots {
            let key = ProcessAggregator.groupKey(for: root, all: all)
            guard key.hasPrefix("app:") || key.hasPrefix("bid:") else { continue }
            buckets[key, default: []].append(root)
        }

        var absorbed: Set<Int32> = []
        for group in buckets.values where group.count > 1 {
            let primary = ProcessAggregator.pickPrimary(group)
            for p in group where p.pid != primary.pid {
                childrenMap[primary.pid, default: []].append(p)
                absorbed.insert(p.pid)
            }
        }

        guard !absorbed.isEmpty else { return roots }
        return roots.filter { !absorbed.contains($0.pid) }
    }

    /// 系统/用户 launchd：几乎所有进程的公共祖先，展示时跳过这一层
    private static func isBootstrapProcess(_ p: MonitoredProcess) -> Bool {
        if p.pid == 1 { return true }
        let name = p.name.lowercased()
        if name == "launchd" || name.hasSuffix("/launchd") { return true }
        if p.path == "/sbin/launchd" || p.path.hasSuffix("/sbin/launchd") { return true }
        return false
    }

    static func flatten(
        _ forest: [Node],
        expanded: Set<String>,
        sortColumn: SortColumn,
        sortAscending: Bool,
        rollupWhenCollapsed: Bool = false
    ) -> [ProcessDisplayRow] {
        let sorted = sortNodes(forest, column: sortColumn, ascending: sortAscending)
        var rows: [ProcessDisplayRow] = []
        for root in sorted {
            append(root, depth: 0, expanded: expanded, sortColumn: sortColumn, sortAscending: sortAscending, rollup: rollupWhenCollapsed, into: &rows)
        }
        return rows
    }

    private static func append(
        _ node: Node,
        depth: Int,
        expanded: Set<String>,
        sortColumn: SortColumn,
        sortAscending: Bool,
        rollup: Bool,
        into rows: inout [ProcessDisplayRow]
    ) {
        let hasChildren = !node.children.isEmpty
        let key = node.key
        let isExpanded = hasChildren && expanded.contains(key)

        var display = node.process
        if hasChildren && !isExpanded && rollup {
            display.cpuPercent = node.totalCPU
            display.memoryBytes = node.totalMemory
            display.threadCount = node.totalThreads
            display.cpuAvailable = true
            display.memoryAvailable = true
            display.metricsFromHelper = false
        }

        rows.append(ProcessDisplayRow(
            id: key,
            process: display,
            depth: depth,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            memberCount: node.memberCount,
            isGroupRoot: hasChildren,
            groupKey: key
        ))

        if isExpanded {
            for child in sortNodes(node.children, column: sortColumn, ascending: sortAscending) {
                append(child, depth: depth + 1, expanded: expanded, sortColumn: sortColumn, sortAscending: sortAscending, rollup: rollup, into: &rows)
            }
        }
    }

    private static func sortNodes(_ nodes: [Node], column: SortColumn, ascending: Bool) -> [Node] {
        nodes.sorted { a, b in
            let result: Bool
            switch column {
            case .cpu:     result = a.process.cpuPercent < b.process.cpuPercent
            case .memory:  result = a.process.memoryBytes < b.process.memoryBytes
            case .name:    result = a.process.name.localizedCaseInsensitiveCompare(b.process.name) == .orderedAscending
            case .pid:     result = a.process.pid < b.process.pid
            case .threads: result = a.process.threadCount < b.process.threadCount
            }
            return ascending ? result : !result
        }
    }
}
