import Foundation

// MARK: - 自定义分组

/// 动态分组的规则类型
enum GroupRuleKind: String, Codable, CaseIterable, Identifiable {
    case bundlePattern  // Bundle ID 通配符（含同族 helper）
    case namePattern    // 名称通配符
    case bundlePrefix   // Bundle ID 前缀（含同族 helper）
    case nameContains   // 名称包含
    case nameExact      // 名称精确匹配
    case pathContains   // 路径包含
    case pathPrefix     // 路径前缀
    case processKind    // 进程类型
    case pathEmpty      // 路径为空
    case appleBundleID  // Apple Bundle ID（内置集合）
    case systemPath     // 系统路径（内置集合）
    case appleAppPath   // Apple 应用路径（内置集合）
    case knownSystemProcess // 已知系统进程名（内置集合）
    case user           // 用户名

    var id: String { rawValue }

    /// 是否需要用户填写匹配值（内置集合类规则不需要）
    var requiresValue: Bool {
        switch self {
        case .pathEmpty, .appleBundleID, .systemPath, .appleAppPath, .knownSystemProcess:
            return false
        default:
            return true
        }
    }

    var title: String {
        switch self {
        case .bundlePattern: return L("group.rule.bundle_pattern")
        case .namePattern: return L("group.rule.name_pattern")
        case .bundlePrefix: return L("group.rule.bundle")
        case .nameContains: return L("group.rule.name")
        case .nameExact: return L("group.rule.name_exact")
        case .pathContains: return L("group.rule.path")
        case .pathPrefix: return L("group.rule.path_prefix")
        case .processKind: return L("group.rule.process_kind")
        case .pathEmpty: return L("group.rule.path_empty")
        case .appleBundleID: return L("group.rule.apple_bundle")
        case .systemPath: return L("group.rule.system_path")
        case .appleAppPath: return L("group.rule.apple_app_path")
        case .knownSystemProcess: return L("group.rule.known_system_process")
        case .user: return L("group.rule.user")
        }
    }

    var placeholder: String {
        switch self {
        case .bundlePattern: return "com.microsoft.*"
        case .namePattern: return "*Edge*"
        case .bundlePrefix: return "com.microsoft.edgemac"
        case .nameContains: return "Chrome"
        case .nameExact: return "WindowServer"
        case .pathContains: return "/Applications/"
        case .pathPrefix: return "/usr/libexec/"
        case .processKind: return "app"
        case .pathEmpty: return ""
        case .appleBundleID: return ""
        case .systemPath: return ""
        case .appleAppPath: return ""
        case .knownSystemProcess: return ""
        case .user: return NSUserName()
        }
    }
}

struct GroupRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: GroupRuleKind = .bundlePattern
    var value: String = ""
}

/// 规则库条目的内容类型
enum SavedRuleContent: String, Codable {
    case rule       // 单条匹配规则
    case appSet     // 固定应用集合（来自静态分组）
    case condition  // 可组合的条件树（内置分类规则等）
}

/// 规则库里的命名规则 / 规则集，可被任意分组的条件树引用；修改后所有引用同步生效
struct SavedGroupRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var content: SavedRuleContent = .rule
    var kind: GroupRuleKind = .bundlePattern
    var value: String = ""
    /// 应用集合的固定成员（content == .appSet 时使用）
    var members: [GroupMember] = []
    /// 组合条件（content == .condition 时使用）
    var condition: GroupConditionNode?
    /// 说明文字（内置规则用）
    var detail: String = ""
    /// 内置规则不可编辑 / 删除
    var isBuiltin: Bool = false

    var rule: GroupRule {
        GroupRule(kind: kind, value: value)
    }

    var isAppSet: Bool { content == .appSet }
    var isCondition: Bool { content == .condition }

    init(
        id: UUID = UUID(),
        name: String = "",
        content: SavedRuleContent = .rule,
        kind: GroupRuleKind = .bundlePattern,
        value: String = "",
        members: [GroupMember] = [],
        condition: GroupConditionNode? = nil,
        detail: String = "",
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.kind = kind
        self.value = value
        self.members = members
        self.condition = condition
        self.detail = detail
        self.isBuiltin = isBuiltin
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case content
        case kind
        case value
        case members
        case condition
        case detail
        case isBuiltin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        content = try container.decodeIfPresent(SavedRuleContent.self, forKey: .content) ?? .rule
        kind = try container.decodeIfPresent(GroupRuleKind.self, forKey: .kind) ?? .bundlePattern
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        members = try container.decodeIfPresent([GroupMember].self, forKey: .members) ?? []
        condition = try container.decodeIfPresent(GroupConditionNode.self, forKey: .condition)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        isBuiltin = try container.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
    }
}

/// 条件组合方式：任一（或）/ 全部（且）
enum GroupCombinator: String, Codable, CaseIterable, Identifiable {
    case any
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return L("group.logic.any")
        case .all: return L("group.logic.all")
        }
    }
}

/// 分组条件树的节点：规则叶子，或可嵌套、可取反的条件组
struct GroupConditionNode: Identifiable, Codable, Hashable {
    var id = UUID()
    /// 有值时为直接填写的规则叶子；nil 时表示条件组或规则库引用
    var rule: GroupRule?
    /// 引用规则库中的命名规则（与 rule 互斥）
    var ruleRef: UUID?
    /// 条件组内子条件的组合方式
    var combinator: GroupCombinator = .any
    /// 是否对自身结果取反
    var isNegated: Bool = false
    /// 子条件（仅条件组使用）
    var children: [GroupConditionNode] = []

    var isRule: Bool { rule != nil || ruleRef != nil }
    var isReference: Bool { ruleRef != nil }

    init(id: UUID = UUID(), rule: GroupRule) {
        self.id = id
        self.rule = rule
        self.ruleRef = nil
    }

    init(id: UUID = UUID(), ruleRef: UUID) {
        self.id = id
        self.rule = nil
        self.ruleRef = ruleRef
    }

    init(
        id: UUID = UUID(),
        combinator: GroupCombinator = .any,
        isNegated: Bool = false,
        children: [GroupConditionNode] = []
    ) {
        self.id = id
        self.rule = nil
        self.ruleRef = nil
        self.combinator = combinator
        self.isNegated = isNegated
        self.children = children
    }

    /// 树中所有直接填写的规则叶子（用于去重等，不含规则库引用）
    var leafRules: [GroupRule] {
        if let rule { return [rule] }
        return children.flatMap(\.leafRules)
    }

    /// 树中所有引用的规则库 ID
    var referencedRuleIDs: Set<UUID> {
        var ids: Set<UUID> = []
        if let ruleRef { ids.insert(ruleRef) }
        for child in children {
            ids.formUnion(child.referencedRuleIDs)
        }
        return ids
    }

    /// 旧版扁平规则 → 条件树
    static func legacy(rules: [GroupRule]) -> GroupConditionNode {
        GroupConditionNode(children: rules.map { GroupConditionNode(rule: $0) })
    }
}

/// 静态分组里的一个应用成员
struct GroupMember: Identifiable, Codable, Hashable {
    /// 稳定键：app:/bid:/path:/name:
    var id: String
    var name: String
    var bundleID: String?
    var path: String
}

/// 用户自定义的进程分组（动态条件树或静态成员）
struct ProcessFilterGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbolName: String
    /// true = 动态条件树；false = 静态成员
    var isDynamic: Bool
    /// 旧版扁平规则，仅用于兼容已保存的数据
    var rules: [GroupRule] = []
    var members: [GroupMember] = []
    /// 动态分组的条件树（根节点为条件组）
    var condition: GroupConditionNode = GroupConditionNode()

    static let symbolChoices = [
        "app.badge",
        "globe",
        "square.stack.3d.up",
        "bolt",
        "leaf",
        "terminal",
        "shippingbox",
        "star",
    ]

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String,
        isDynamic: Bool,
        rules: [GroupRule] = [],
        members: [GroupMember] = [],
        condition: GroupConditionNode? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isDynamic = isDynamic
        self.rules = rules
        self.members = members
        self.condition = condition ?? .legacy(rules: rules)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName
        case isDynamic
        case rules
        case members
        case condition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        isDynamic = try container.decode(Bool.self, forKey: .isDynamic)
        rules = try container.decodeIfPresent([GroupRule].self, forKey: .rules) ?? []
        members = try container.decodeIfPresent([GroupMember].self, forKey: .members) ?? []
        if let saved = try container.decodeIfPresent(GroupConditionNode.self, forKey: .condition) {
            condition = saved
        } else {
            condition = .legacy(rules: rules)
        }
    }
}

/// 分组编辑器中的全局应用候选条目
struct GroupAppCandidate: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let bundleID: String?
    let processCount: Int
}
