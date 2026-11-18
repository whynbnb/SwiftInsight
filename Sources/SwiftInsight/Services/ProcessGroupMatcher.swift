import Foundation

/// 自定义分组匹配：动态规则（Bundle / 名称 / 路径 / 用户）或静态应用成员
enum ProcessGroupMatcher {

    // MARK: - Match

    static func matches(_ process: MonitoredProcess, group: ProcessFilterGroup) -> Bool {
        if group.isDynamic {
            let rules = group.rules.filter {
                !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !rules.isEmpty else { return false }
            return rules.contains { ruleMatches(process, rule: $0) }
        }
        guard !group.members.isEmpty else { return false }
        let keys = identityKeys(for: process)
        return group.members.contains { keys.contains($0.id) }
    }

    private static func ruleMatches(_ process: MonitoredProcess, rule: GroupRule) -> Bool {
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        switch rule.kind {
        case .bundlePattern:
            var ids: [String] = []
            if let bid = process.bundleIdentifier, !bid.isEmpty {
                ids.append(bid.lowercased())
                ids.append(ProcessAggregator.familyBundleID(bid).lowercased())
            }
            return ids.contains { wildcardMatch(pattern: value, text: $0) }
        case .namePattern:
            let names = [
                process.name.lowercased(),
                ProcessAggregator.familyName(process.name).lowercased(),
            ]
            return names.contains { wildcardMatch(pattern: value, text: $0) }
        case .bundlePrefix:
            let ids = [
                process.bundleIdentifier,
                process.bundleIdentifier.map(ProcessAggregator.familyBundleID),
            ].compactMap { $0?.lowercased() }
            return ids.contains { $0.hasPrefix(value) }
        case .nameContains:
            return process.name.lowercased().contains(value)
        case .pathContains:
            if process.path.lowercased().contains(value) { return true }
            if let app = ProcessAggregator.appBundlePath(from: process.path, outermost: true) {
                return app.lowercased().contains(value)
            }
            return false
        case .user:
            return process.username.lowercased() == value
        }
    }

    // MARK: - Wildcard

    /// 通配符匹配：`*` 任意多个字符，`?` 单个字符。
    /// 不含通配符时按完整名称匹配（忽略大小写）。
    static func wildcardMatch(pattern: String, text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let s = Array(text.lowercased())
        if p.isEmpty { return s.isEmpty }

        var pi = 0
        var si = 0
        var star = -1
        var resume = 0

        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                resume = si
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                resume += 1
                si = resume
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Identity

    /// 进程可能命中的稳定标识（与 GroupMember.id 对应）
    static func identityKeys(for process: MonitoredProcess) -> Set<String> {
        var keys: Set<String> = []
        if let app = ProcessAggregator.appBundlePath(from: process.path, outermost: true) {
            keys.insert("app:" + app)
        }
        if let bid = process.bundleIdentifier, !bid.isEmpty {
            keys.insert("bid:" + ProcessAggregator.familyBundleID(bid))
        }
        if !process.path.isEmpty {
            keys.insert("path:" + process.path)
        }
        keys.insert("name:" + ProcessAggregator.familyName(process.name))
        return keys
    }

    /// 从进程生成静态成员条目（优先最外层 .app）
    static func member(for process: MonitoredProcess) -> GroupMember {
        if let app = ProcessAggregator.appBundlePath(from: process.path, outermost: true) {
            let name = (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let bid = process.bundleIdentifier.map(ProcessAggregator.familyBundleID)
            return GroupMember(id: "app:" + app, name: name, bundleID: bid, path: app)
        }
        if let bid = process.bundleIdentifier, !bid.isEmpty {
            let family = ProcessAggregator.familyBundleID(bid)
            return GroupMember(id: "bid:" + family, name: process.name, bundleID: family, path: process.path)
        }
        if !process.path.isEmpty {
            return GroupMember(id: "path:" + process.path, name: process.name, bundleID: nil, path: process.path)
        }
        return GroupMember(
            id: "name:" + ProcessAggregator.familyName(process.name),
            name: process.name,
            bundleID: nil,
            path: ""
        )
    }

    /// 动态规则：为进程生成「加入此组」所需的最小规则
    static func rule(for process: MonitoredProcess) -> GroupRule {
        if let bid = process.bundleIdentifier, !bid.isEmpty {
            return GroupRule(kind: .bundlePrefix, value: ProcessAggregator.familyBundleID(bid))
        }
        if !process.path.isEmpty,
           let app = ProcessAggregator.appBundlePath(from: process.path, outermost: true) {
            return GroupRule(kind: .pathContains, value: app)
        }
        return GroupRule(kind: .nameContains, value: ProcessAggregator.familyName(process.name))
    }

    // MARK: - Candidates

    /// 编辑器里的应用候选：按最外层 .app / Bundle 族聚合
    static func appCandidates(from processes: [MonitoredProcess]) -> [GroupAppCandidate] {
        var counts: [String: (name: String, path: String, bid: String?, count: Int, isApp: Bool)] = [:]

        for p in processes {
            let member = member(for: p)
            let key = member.id
            // 静态分组按「应用」管理：只列 .app 包内的成员，避免 zsh / 守护进程刷屏
            let isApp = key.hasPrefix("app:")
            if var existing = counts[key] {
                existing.count += 1
                if existing.path.isEmpty, !member.path.isEmpty {
                    existing.path = member.path
                }
                if existing.bid == nil, let bid = member.bundleID {
                    existing.bid = bid
                } else if let bid = member.bundleID, let old = existing.bid, bid.count < old.count {
                    // 同组混入 helper 时，保留更短的主 Bundle ID
                    existing.bid = bid
                }
                counts[key] = existing
            } else {
                counts[key] = (member.name, member.path, member.bundleID, 1, isApp)
            }
        }

        let entries = counts.map { key, value in
            (candidate: GroupAppCandidate(
                id: key,
                name: value.name,
                path: value.path,
                bundleID: value.bid,
                processCount: value.count
            ), isApp: value.isApp)
        }
        // 应用优先，其次进程数、名称；非 .app 成员仍保留（后台服务/自定义启动的进程）
        return entries.sorted { lhs, rhs in
            if lhs.isApp != rhs.isApp { return lhs.isApp }
            if lhs.candidate.processCount != rhs.candidate.processCount {
                return lhs.candidate.processCount > rhs.candidate.processCount
            }
            return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name) == .orderedAscending
        }
        .map(\.candidate)
    }
}
