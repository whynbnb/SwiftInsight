import Foundation
import Combine

/// 自定义分组与规则库的持久化存储
@MainActor
final class ProcessGroupStore: ObservableObject {
    static let shared = ProcessGroupStore()

    private static let storageKey = "customProcessGroups"
    private static let savedRulesKey = "savedGroupRules"

    @Published private(set) var groups: [ProcessFilterGroup] = []
    /// 全局规则库：命名规则可被任意分组引用
    @Published private(set) var savedRules: [SavedGroupRule] = []

    private init() {
        load()
        loadSavedRules()
    }

    // MARK: - Group query

    func group(with id: UUID?) -> ProcessFilterGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    // MARK: - Group mutation

    @discardableResult
    func add(_ group: ProcessFilterGroup) -> UUID {
        var copy = group
        copy.name = normalizedName(copy.name)
        groups.append(copy)
        persist()
        return copy.id
    }

    func update(_ group: ProcessFilterGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var copy = group
        copy.name = normalizedName(copy.name)
        groups[index] = copy
        persist()
    }

    func remove(id: UUID) {
        groups.removeAll { $0.id == id }
        persist()
    }

    /// 在侧栏顺序中上移 / 下移一个分组
    func moveGroup(id: UUID, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard groups.indices.contains(target), target != index else { return }
        var copy = groups
        copy.swapAt(index, target)
        groups = copy
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        groups.remove(atOffsets: offsets)
        persist()
    }

    /// 把进程加入：动态组补一条规则，静态组加一个成员
    func addProcess(_ process: MonitoredProcess, to id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var group = groups[index]
        if group.isDynamic {
            let rule = ProcessGroupMatcher.rule(for: process)
            if group.condition.isRule {
                group.condition = GroupConditionNode(children: [group.condition])
            }
            let exists = group.condition.leafRules.contains {
                $0.kind == rule.kind
                    && $0.value.caseInsensitiveCompare(rule.value) == .orderedSame
            }
            guard !exists else { return }
            if group.condition.combinator == .all || group.condition.isNegated {
                // 「全部」/ 取反的组再追加同级规则会收紧条件，导致刚加入的进程反而不匹配；
                // 改为「原有条件 或 新规则」，保证该进程一定在组内。
                let previous = group.condition
                group.condition = GroupConditionNode(
                    combinator: .any,
                    children: [previous, GroupConditionNode(rule: rule)]
                )
            } else {
                group.condition.children.append(GroupConditionNode(rule: rule))
            }
        } else {
            let member = ProcessGroupMatcher.member(for: process)
            guard !group.members.contains(where: { $0.id == member.id }) else { return }
            group.members.append(member)
        }
        groups[index] = group
        persist()
    }

    // MARK: - Rule library query

    func savedRule(with id: UUID?) -> SavedGroupRule? {
        guard let id else { return nil }
        return allRules.first { $0.id == id }
    }

    /// 内置规则 + 用户规则（内置规则只读，不能编辑或删除）
    var allRules: [SavedGroupRule] {
        BuiltinRuleCatalog.rules + savedRules
    }

    var savedRulesByID: [UUID: SavedGroupRule] {
        Dictionary(uniqueKeysWithValues: allRules.map { ($0.id, $0) })
    }

    /// 有多少个分组引用了这条规则
    func referenceCount(forSavedRule id: UUID) -> Int {
        groups.filter { $0.condition.referencedRuleIDs.contains(id) }.count
    }

    // MARK: - Rule library mutation

    @discardableResult
    func addSavedRule(_ rule: SavedGroupRule) -> UUID {
        let copy = normalizedSavedRule(rule)
        savedRules.append(copy)
        persistSavedRules()
        return copy.id
    }

    func updateSavedRule(_ rule: SavedGroupRule) {
        guard !rule.isBuiltin,
              let index = savedRules.firstIndex(where: { $0.id == rule.id }) else { return }
        savedRules[index] = normalizedSavedRule(rule)
        persistSavedRules()
    }

    func removeSavedRule(id: UUID) {
        guard !BuiltinRuleCatalog.matchingRulesByID.keys.contains(id) else { return }
        savedRules.removeAll { $0.id == id }
        persistSavedRules()
    }

    // MARK: - Persistence

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("group.untitled") : trimmed
    }

    private func normalizedSavedRule(_ rule: SavedGroupRule) -> SavedGroupRule {
        var copy = rule
        copy.isBuiltin = false
        let trimmedName = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.isAppSet {
            copy.value = ""
            copy.name = trimmedName.isEmpty ? L("group.rule.untitled_set") : trimmedName
        } else {
            copy.value = copy.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
                copy.name = copy.value.isEmpty ? L("group.rule.untitled") : copy.value
            } else {
                copy.name = trimmedName
            }
        }
        return copy
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ProcessFilterGroup].self, from: data) else {
            groups = []
            return
        }
        groups = decoded
    }

    private func loadSavedRules() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedRulesKey),
              let decoded = try? JSONDecoder().decode([SavedGroupRule].self, from: data) else {
            savedRules = []
            return
        }
        savedRules = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func persistSavedRules() {
        guard let data = try? JSONEncoder().encode(savedRules) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedRulesKey)
    }
}
