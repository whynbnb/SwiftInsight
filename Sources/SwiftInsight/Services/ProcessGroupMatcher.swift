import Foundation

/// 规则求值所需的进程信息（分类器在生成 ProcessKind 后也能直接复用）
struct ProcessRuleContext {
    let pid: Int32
    let name: String
    let path: String
    let bundleIdentifier: String?
    let kind: ProcessKind
    let username: String
}

extension MonitoredProcess {
    var ruleContext: ProcessRuleContext {
        ProcessRuleContext(
            pid: pid,
            name: name,
            path: path,
            bundleIdentifier: bundleIdentifier,
            kind: kind,
            username: username
        )
    }
}

/// 自定义分组匹配：动态条件树（或/且/非、嵌套、规则库引用）或静态应用成员
enum ProcessGroupMatcher {

    // MARK: - Match

    static func matches(
        _ process: MonitoredProcess,
        group: ProcessFilterGroup,
        savedRules: [UUID: SavedGroupRule] = [:],
        groupMembership: ((UUID) -> Set<Int32>)? = nil
    ) -> Bool {
        if group.isDynamic {
            return evaluate(
                group.condition,
                context: process.ruleContext,
                savedRules: savedRules,
                groupMembership: groupMembership
            )
        }
        guard !group.members.isEmpty else { return false }
        let keys = identityKeys(for: process.ruleContext)
        return group.members.contains { keys.contains($0.id) }
    }

    /// 计算所有分组的成员 PID（含分组引用与后代展开）。
    /// 分组引用按 ID 实时解析；visiting 用于阻断分组之间的循环引用。
    static func groupMemberships(
        groups: [ProcessFilterGroup],
        processes: [MonitoredProcess],
        savedRules: [UUID: SavedGroupRule] = [:]
    ) -> [UUID: Set<Int32>] {
        let groupsByID = Dictionary(
            groups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var memberships: [UUID: Set<Int32>] = [:]
        var visiting: Set<UUID> = []

        var childrenByParent: [Int32: [Int32]] = [:]
        for process in processes where process.ppid > 0 {
            childrenByParent[process.ppid, default: []].append(process.pid)
        }

        func expand(_ direct: Set<Int32>, includeChildren: Bool) -> Set<Int32> {
            guard includeChildren, !direct.isEmpty else { return direct }
            var matched = direct
            var queue = Array(direct)
            var index = 0
            while index < queue.count {
                let pid = queue[index]
                index += 1
                for child in childrenByParent[pid] ?? [] where matched.insert(child).inserted {
                    queue.append(child)
                }
            }
            return matched
        }

        func membership(_ id: UUID) -> Set<Int32> {
            if let cached = memberships[id] { return cached }
            guard let group = groupsByID[id], visiting.insert(id).inserted else { return [] }

            var direct: Set<Int32> = []
            for process in processes where matches(
                process,
                group: group,
                savedRules: savedRules,
                groupMembership: membership
            ) {
                direct.insert(process.pid)
            }

            // 计算取反排除期间继续保持 visiting，防止自引用 / 循环引用
            // 在 isExplicitlyExcluded 里再次递归到当前分组导致栈溢出。
            var excluded: Set<Int32> = []
            if group.isDynamic {
                for process in processes where isExplicitlyExcluded(
                    group.condition,
                    context: process.ruleContext,
                    savedRules: savedRules,
                    groupMembership: membership
                ) {
                    excluded.insert(process.pid)
                }
            }

            let result = expand(direct, includeChildren: group.includeChildren)
                .subtracting(excluded)
            memberships[id] = result
            visiting.remove(id)
            return result
        }

        for group in groups {
            _ = membership(group.id)
        }
        return memberships
    }

    /// 分组命中的进程 PID（含后代展开与分组引用）
    static func matchedProcessIDs(
        group: ProcessFilterGroup,
        groups: [ProcessFilterGroup],
        processes: [MonitoredProcess],
        savedRules: [UUID: SavedGroupRule] = [:]
    ) -> Set<Int32> {
        groupMemberships(
            groups: groups,
            processes: processes,
            savedRules: savedRules
        )[group.id] ?? []
    }

    static func evaluate(
        _ node: GroupConditionNode,
        process: MonitoredProcess,
        savedRules: [UUID: SavedGroupRule] = [:],
        groupMembership: ((UUID) -> Set<Int32>)? = nil
    ) -> Bool {
        evaluate(
            node,
            context: process.ruleContext,
            savedRules: savedRules,
            groupMembership: groupMembership
        )
    }

    /// 递归求值：规则叶子按取反处理，条件组按 或/且 组合后再取反。
    /// 规则库 / 自定义分组引用均实时求值；引用失效、空白规则、空条件组视为无效条件，
    /// 整棵树没有有效条件时不匹配任何进程。visiting 用于阻断规则集之间的循环引用。
    static func evaluate(
        _ node: GroupConditionNode,
        context: ProcessRuleContext,
        savedRules: [UUID: SavedGroupRule] = [:],
        groupMembership: ((UUID) -> Set<Int32>)? = nil,
        visiting: Set<UUID> = []
    ) -> Bool {
        if let ref = node.groupRef {
            let matched = groupMembership?(ref).contains(context.pid) ?? false
            return node.isNegated ? !matched : matched
        }
        if let ref = node.ruleRef {
            guard let saved = savedRules[ref], !visiting.contains(ref) else { return false }
            let matched: Bool
            switch saved.content {
            case .appSet:
                let keys = identityKeys(for: context)
                matched = saved.members.contains { keys.contains($0.id) }
            case .rule:
                matched = ruleMatches(context, rule: saved.rule)
            case .condition:
                guard let condition = saved.condition else { return false }
                matched = evaluate(
                    condition,
                    context: context,
                    savedRules: savedRules,
                    groupMembership: groupMembership,
                    visiting: visiting.union([ref])
                )
            }
            return node.isNegated ? !matched : matched
        }
        if let rule = node.rule {
            let matched = ruleMatches(context, rule: rule)
            return node.isNegated ? !matched : matched
        }
        let children = node.children.filter { !isVacuous($0, savedRules: savedRules) }
        guard !children.isEmpty else { return false }
        let combined: Bool
        switch node.combinator {
        case .any:
            combined = children.contains {
                evaluate(
                    $0,
                    context: context,
                    savedRules: savedRules,
                    groupMembership: groupMembership,
                    visiting: visiting
                )
            }
        case .all:
            combined = children.allSatisfy {
                evaluate(
                    $0,
                    context: context,
                    savedRules: savedRules,
                    groupMembership: groupMembership,
                    visiting: visiting
                )
            }
        }
        return node.isNegated ? !combined : combined
    }

    /// 命中「非」条件的进程：作为硬排除，优先级高于 includeChildren 的后代展开。
    /// 只收集最外层取反节点，取反节点内部的嵌套条件仍按布尔求值处理。
    private static func isExplicitlyExcluded(
        _ node: GroupConditionNode,
        context: ProcessRuleContext,
        savedRules: [UUID: SavedGroupRule],
        groupMembership: ((UUID) -> Set<Int32>)?
    ) -> Bool {
        if node.isNegated {
            var positive = node
            positive.isNegated = false
            return evaluate(
                positive,
                context: context,
                savedRules: savedRules,
                groupMembership: groupMembership
            )
        }
        // 只有「全部」组合下的取反子条件才代表排除。
        // 「任一」里的取反是正向包含（例如 A OR NOT B），不能全局硬排除。
        guard node.combinator == .all else { return false }
        for child in node.children {
            if isExplicitlyExcluded(
                child,
                context: context,
                savedRules: savedRules,
                groupMembership: groupMembership
            ) {
                return true
            }
        }
        return false
    }

    /// 没有任何有效规则的条件（空白规则 / 失效引用 / 空条件组）
    private static func isVacuous(
        _ node: GroupConditionNode,
        savedRules: [UUID: SavedGroupRule]
    ) -> Bool {
        // 分组引用是明确条件；即使引用失效也保留其位置
        if node.groupRef != nil { return false }
        if let ref = node.ruleRef {
            guard let saved = savedRules[ref] else { return true }
            switch saved.content {
            case .appSet:
                return saved.members.isEmpty
            case .rule:
                return saved.rule.kind.requiresValue
                    && saved.rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .condition:
                return saved.condition == nil
            }
        }
        if let rule = node.rule {
            return rule.kind.requiresValue
                && rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return node.children.allSatisfy { isVacuous($0, savedRules: savedRules) }
    }

    private static func ruleMatches(_ context: ProcessRuleContext, rule: GroupRule) -> Bool {
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rule.kind {
        case .pathEmpty:
            return context.path.isEmpty
        case .appleBundleID:
            guard let bid = context.bundleIdentifier else { return false }
            if isAppleBundleID(bid) { return true }
            let family = ProcessAggregator.familyBundleID(bid)
            return family != bid && isAppleBundleID(family)
        case .systemPath:
            return ProcessClassifier.isSystemPath(context.path)
        case .appleAppPath:
            return ProcessClassifier.isAppleAppPath(context.path)
        case .knownSystemProcess:
            return ProcessClassifier.isKnownSystemProcess(context.name)
        case .processKind:
            return ProcessKind(rawValue: value) == context.kind
        case .nameExact:
            guard !value.isEmpty else { return false }
            return context.name.lowercased() == value
                || ProcessAggregator.familyName(context.name).lowercased() == value
        case .pathPrefix:
            guard !value.isEmpty else { return false }
            return context.path.lowercased().hasPrefix(value)
        case .bundlePattern, .namePattern, .bundlePrefix, .nameContains, .pathContains, .user:
            guard !value.isEmpty else { return false }
            return valueMatches(context, kind: rule.kind, value: value)
        }
    }

    private static func isAppleBundleID(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("com.apple.")
            || lower == "com.apple"
            || lower.hasPrefix("edu.mit.kerberos")
    }

    private static func valueMatches(
        _ context: ProcessRuleContext,
        kind: GroupRuleKind,
        value: String
    ) -> Bool {
        switch kind {
        case .bundlePattern:
            guard let bid = context.bundleIdentifier, !bid.isEmpty else { return false }
            let lower = bid.lowercased()
            if wildcardMatch(pattern: value, text: lower) { return true }
            let family = ProcessAggregator.familyBundleID(bid).lowercased()
            return family != lower && wildcardMatch(pattern: value, text: family)
        case .namePattern:
            let name = context.name.lowercased()
            if wildcardMatch(pattern: value, text: name) { return true }
            let family = ProcessAggregator.familyName(context.name).lowercased()
            return family != name && wildcardMatch(pattern: value, text: family)
        case .bundlePrefix:
            guard let bid = context.bundleIdentifier else { return false }
            if bid.lowercased().hasPrefix(value) { return true }
            return ProcessAggregator.familyBundleID(bid).lowercased().hasPrefix(value)
        case .nameContains:
            return context.name.lowercased().contains(value)
        case .pathContains:
            if context.path.lowercased().contains(value) { return true }
            if let app = ProcessAggregator.appBundlePath(from: context.path, outermost: true) {
                return app.lowercased().contains(value)
            }
            return false
        case .user:
            return context.username.lowercased() == value
        default:
            return false
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
        identityKeys(for: process.ruleContext)
    }

    static func identityKeys(for context: ProcessRuleContext) -> Set<String> {
        var keys: Set<String> = []
        if let app = ProcessAggregator.appBundlePath(from: context.path, outermost: true) {
            keys.insert("app:" + app)
        }
        if let bid = context.bundleIdentifier, !bid.isEmpty {
            keys.insert("bid:" + ProcessAggregator.familyBundleID(bid))
        }
        if !context.path.isEmpty {
            keys.insert("path:" + context.path)
        }
        keys.insert("name:" + ProcessAggregator.familyName(context.name))
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
