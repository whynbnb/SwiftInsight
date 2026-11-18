import Foundation

// MARK: - 自定义分组

/// 动态分组的规则类型
enum GroupRuleKind: String, Codable, CaseIterable, Identifiable {
    case bundlePattern  // Bundle ID 通配符（含同族 helper）
    case namePattern    // 名称通配符
    case bundlePrefix   // Bundle ID 前缀（含同族 helper）
    case nameContains   // 名称包含
    case pathContains   // 路径包含
    case user           // 用户名

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundlePattern: return L("group.rule.bundle_pattern")
        case .namePattern: return L("group.rule.name_pattern")
        case .bundlePrefix: return L("group.rule.bundle")
        case .nameContains: return L("group.rule.name")
        case .pathContains: return L("group.rule.path")
        case .user: return L("group.rule.user")
        }
    }

    var placeholder: String {
        switch self {
        case .bundlePattern: return "com.microsoft.*"
        case .namePattern: return "*Edge*"
        case .bundlePrefix: return "com.microsoft.edgemac"
        case .nameContains: return "Chrome"
        case .pathContains: return "/Applications/"
        case .user: return NSUserName()
        }
    }
}

struct GroupRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: GroupRuleKind = .bundlePattern
    var value: String = ""
}

/// 静态分组里的一个应用成员
struct GroupMember: Identifiable, Codable, Hashable {
    /// 稳定键：app:/bid:/path:/name:
    var id: String
    var name: String
    var bundleID: String?
    var path: String
}

/// 用户自定义的进程分组（动态规则或静态成员）
struct ProcessFilterGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbolName: String
    /// true = 动态规则；false = 静态成员
    var isDynamic: Bool
    var rules: [GroupRule] = []
    var members: [GroupMember] = []

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
}

/// 分组编辑器中的全局应用候选条目
struct GroupAppCandidate: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let bundleID: String?
    let processCount: Int
}
