import Foundation
import Combine

/// 自定义分组的持久化存储（动态规则 / 静态应用成员）
@MainActor
final class ProcessGroupStore: ObservableObject {
    static let shared = ProcessGroupStore()

    private static let storageKey = "customProcessGroups"

    @Published private(set) var groups: [ProcessFilterGroup] = []

    private init() {
        load()
    }

    // MARK: - Query

    func group(with id: UUID?) -> ProcessFilterGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    // MARK: - Mutation

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
            let exists = group.rules.contains {
                $0.kind == rule.kind
                    && $0.value.caseInsensitiveCompare(rule.value) == .orderedSame
            }
            guard !exists else { return }
            group.rules.append(rule)
        } else {
            let member = ProcessGroupMatcher.member(for: process)
            guard !group.members.contains(where: { $0.id == member.id }) else { return }
            group.members.append(member)
        }
        groups[index] = group
        persist()
    }

    // MARK: - Persistence

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("group.untitled") : trimmed
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ProcessFilterGroup].self, from: data) else {
            groups = []
            return
        }
        groups = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
