import Foundation

/// 自定义分组 / 规则库的导入导出。
///
/// 文件是带格式标识的 JSON；导入始终以「合并」方式处理：
/// - 保留不冲突的原有 ID，冲突时重新生成并同步改写组引用 / 规则引用
/// - 内置规则不写入导出文件，导入时也不会覆盖内置规则
enum GroupTransfer {

    static let formatIdentifier = "swiftinsight.groups"
    static let currentVersion = 1

    // MARK: - Document

    struct Document: Codable {
        var format: String = GroupTransfer.formatIdentifier
        var version: Int = GroupTransfer.currentVersion
        var exportedAt: String = ""
        var appVersion: String = ""
        var groups: [ProcessFilterGroup] = []
        var savedRules: [SavedGroupRule] = []

        private enum CodingKeys: String, CodingKey {
            case format
            case version
            case exportedAt
            case appVersion
            case groups
            case savedRules
        }

        init(
            groups: [ProcessFilterGroup],
            savedRules: [SavedGroupRule],
            appVersion: String,
            exportedAt: String = GroupTransfer.timestamp()
        ) {
            self.groups = groups
            self.savedRules = savedRules
            self.appVersion = appVersion
            self.exportedAt = exportedAt
        }

        /// 容忍缺字段 / 旧版本文件，避免因为一个可选字段整份导入失败
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
            appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
            groups = try container.decodeIfPresent([ProcessFilterGroup].self, forKey: .groups) ?? []
            savedRules = try container.decodeIfPresent([SavedGroupRule].self, forKey: .savedRules) ?? []
        }
    }

    struct MergeResult {
        var groups: [ProcessFilterGroup] = []
        var rules: [SavedGroupRule] = []
    }

    enum TransferError: LocalizedError {
        case notRecognized
        case empty

        var errorDescription: String? {
            switch self {
            case .notRecognized: return L("settings.groups.transfer.unrecognized")
            case .empty: return L("settings.groups.import.empty")
            }
        }
    }

    // MARK: - Export

    static func exportData(
        groups: [ProcessFilterGroup],
        savedRules: [SavedGroupRule]
    ) throws -> Data {
        let document = Document(
            groups: groups,
            savedRules: savedRules.filter { !$0.isBuiltin },
            appVersion: appVersionString
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    // MARK: - Import

    static func decodeDocument(from data: Data) throws -> Document {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(Document.self, from: data),
           (document.format.isEmpty || document.format == formatIdentifier) {
            guard !document.groups.isEmpty || !document.savedRules.isEmpty else {
                throw TransferError.empty
            }
            return document
        }

        // 兼容只包含分组数组的旧文件
        if let groups = try? decoder.decode([ProcessFilterGroup].self, from: data), !groups.isEmpty {
            return Document(groups: groups, savedRules: [], appVersion: "")
        }

        throw TransferError.notRecognized
    }

    /// 把导入内容合并进现有数据：不覆盖现有分组 / 规则，引用仍保持正确。
    static func merge(
        document: Document,
        existingGroups: [ProcessFilterGroup],
        existingRules: [SavedGroupRule]
    ) -> MergeResult {
        var result = MergeResult()

        var usedRuleIDs = Set(existingRules.map(\.id))
        usedRuleIDs.formUnion(BuiltinRuleCatalog.matchingRulesByID.keys)

        var ruleIDMap: [UUID: UUID] = [:]
        for var rule in document.savedRules where !rule.isBuiltin {
            var newID = rule.id
            if usedRuleIDs.contains(newID) {
                newID = UUID()
            }
            ruleIDMap[rule.id] = newID
            rule.id = newID
            rule.isBuiltin = false
            usedRuleIDs.insert(newID)
            result.rules.append(rule)
        }

        var usedGroupIDs = Set(existingGroups.map(\.id))
        var takenNames = Set(existingGroups.map(\.name))
        var groupIDMap: [UUID: UUID] = [:]

        for var group in document.groups {
            var newID = group.id
            if usedGroupIDs.contains(newID) {
                newID = UUID()
            }
            groupIDMap[group.id] = newID
            group.id = newID
            usedGroupIDs.insert(newID)
            group.name = uniqueName(group.name, taken: &takenNames)
            result.groups.append(group)
        }

        // 分组 / 规则之间可能互相引用，统一按旧 ID → 新 ID 映射改写
        result.groups = result.groups.map {
            remap($0, ruleIDMap: ruleIDMap, groupIDMap: groupIDMap)
        }
        result.rules = result.rules.map {
            var rule = $0
            if let condition = rule.condition {
                rule.condition = remapNode(condition, ruleIDMap: ruleIDMap, groupIDMap: groupIDMap)
            }
            return rule
        }
        return result
    }

    // MARK: - Helpers

    private static var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        if !taken.contains(name) {
            taken.insert(name)
            return name
        }
        var index = 2
        while taken.contains("\(name) \(index)") {
            index += 1
        }
        let unique = "\(name) \(index)"
        taken.insert(unique)
        return unique
    }

    private static func remap(
        _ group: ProcessFilterGroup,
        ruleIDMap: [UUID: UUID],
        groupIDMap: [UUID: UUID]
    ) -> ProcessFilterGroup {
        var group = group
        group.condition = remapNode(group.condition, ruleIDMap: ruleIDMap, groupIDMap: groupIDMap)
        group.rules = group.rules.map {
            var rule = $0
            rule.id = UUID()
            return rule
        }
        return group
    }

    private static func remapNode(
        _ node: GroupConditionNode,
        ruleIDMap: [UUID: UUID],
        groupIDMap: [UUID: UUID]
    ) -> GroupConditionNode {
        var node = node
        node.id = UUID()
        if let ref = node.ruleRef, let newID = ruleIDMap[ref] {
            node.ruleRef = newID
        }
        if let ref = node.groupRef, let newID = groupIDMap[ref] {
            node.groupRef = newID
        }
        if var rule = node.rule {
            rule.id = UUID()
            node.rule = rule
        }
        node.children = node.children.map {
            remapNode($0, ruleIDMap: ruleIDMap, groupIDMap: groupIDMap)
        }
        return node
    }
}
