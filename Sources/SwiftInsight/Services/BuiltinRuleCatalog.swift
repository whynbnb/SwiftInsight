import Foundation

/// 内置规则的稳定 ID（写入分组引用，不能随意改动）
enum BuiltinRuleID {
    static let appleSystem = UUID(uuidString: "EAA23234-0CD9-4B1D-8CD8-C33FE7929D43")!
    static let appleApp = UUID(uuidString: "609160A9-1EB1-44FD-8233-B9C574631E1A")!
    static let thirdParty = UUID(uuidString: "781AE54A-924D-4280-BF2B-00B772B52CF5")!
    static let appleAll = UUID(uuidString: "F8B10835-0257-4DB9-B804-CC308EA8C0D4")!
    static let appleBundle = UUID(uuidString: "67E29A1E-EC29-4570-A9FE-4450F6F12E7A")!
    static let systemPath = UUID(uuidString: "F8487E63-7BC3-4A28-856C-C8F7CA769194")!
    static let appleAppPath = UUID(uuidString: "E8752794-E072-47AF-BC0E-181ED6550D55")!
    static let knownSystemProcess = UUID(uuidString: "8D3C8A9B-EC62-42C8-8EF6-9118E48541F0")!
    static let kernelBootstrap = UUID(uuidString: "A8C5ACE6-CAAB-4420-8C75-B43C9D66AA23")!
    static let foregroundApp = UUID(uuidString: "05914CEC-0AF5-44C1-9E90-7D16738FD2E8")!
    static let backgroundProcess = UUID(uuidString: "B2455F99-A011-4A44-AD51-E2BCE8B10843")!
    static let pathEmpty = UUID(uuidString: "05951971-00B3-4AA9-BAAF-F01DF5538136")!
}

/// 内置规则库：把「Apple 系统 / Apple 应用 / 第三方」拆成一组可组合的小规则。
/// 分类器与自定义分组引用共用同一套定义，保证侧栏分类与分组引用结果一致。
enum BuiltinRuleCatalog {

    // MARK: - Public

    /// 全部内置规则（名称按当前语言本地化）
    static var rules: [SavedGroupRule] {
        definitions.map { definition in
            SavedGroupRule(
                id: definition.id,
                name: L(definition.nameKey),
                content: definition.content,
                kind: definition.kind,
                value: definition.value,
                condition: definition.condition,
                detail: L(definition.detailKey),
                isBuiltin: true
            )
        }
    }

    /// 供匹配器解析引用的快照（名称不参与匹配）
    static let matchingRulesByID: [UUID: SavedGroupRule] = {
        var map: [UUID: SavedGroupRule] = [:]
        for definition in definitions {
            map[definition.id] = SavedGroupRule(
                id: definition.id,
                name: "",
                content: definition.content,
                kind: definition.kind,
                value: definition.value,
                condition: definition.condition,
                isBuiltin: true
            )
        }
        return map
    }()

    /// 组合条件入口（分类器用）
    static let conditionsByID: [UUID: GroupConditionNode] = {
        var map: [UUID: GroupConditionNode] = [:]
        for definition in definitions {
            if let condition = definition.condition {
                map[definition.id] = condition
            }
        }
        return map
    }()

    /// 分类判定顺序：Apple 系统 → Apple 应用 → 第三方
    static let categoryRules: [(id: UUID, category: ProcessCategory)] = [
        (BuiltinRuleID.appleSystem, .appleSystem),
        (BuiltinRuleID.appleApp, .appleApp),
        (BuiltinRuleID.thirdParty, .thirdParty),
    ]

    // MARK: - Definitions

    private struct Definition {
        let id: UUID
        let nameKey: String
        let detailKey: String
        let content: SavedRuleContent
        var kind: GroupRuleKind = .bundlePattern
        var value: String = ""
        var condition: GroupConditionNode?
    }

    private static let definitions: [Definition] = [
        Definition(
            id: BuiltinRuleID.appleSystem,
            nameKey: "group.builtin.apple_system",
            detailKey: "group.builtin.apple_system.detail",
            content: .condition,
            condition: appleSystemCondition
        ),
        Definition(
            id: BuiltinRuleID.appleApp,
            nameKey: "group.builtin.apple_app",
            detailKey: "group.builtin.apple_app.detail",
            content: .condition,
            condition: appleAppCondition
        ),
        Definition(
            id: BuiltinRuleID.thirdParty,
            nameKey: "group.builtin.third_party",
            detailKey: "group.builtin.third_party.detail",
            content: .condition,
            condition: thirdPartyCondition
        ),
        Definition(
            id: BuiltinRuleID.appleAll,
            nameKey: "group.builtin.apple_all",
            detailKey: "group.builtin.apple_all.detail",
            content: .condition,
            condition: appleAllCondition
        ),
        Definition(
            id: BuiltinRuleID.appleBundle,
            nameKey: "group.builtin.apple_bundle",
            detailKey: "group.builtin.apple_bundle.detail",
            content: .condition,
            condition: appleBundleCondition
        ),
        Definition(
            id: BuiltinRuleID.systemPath,
            nameKey: "group.builtin.system_path",
            detailKey: "group.builtin.system_path.detail",
            content: .rule,
            kind: .systemPath
        ),
        Definition(
            id: BuiltinRuleID.appleAppPath,
            nameKey: "group.builtin.apple_app_path",
            detailKey: "group.builtin.apple_app_path.detail",
            content: .rule,
            kind: .appleAppPath
        ),
        Definition(
            id: BuiltinRuleID.knownSystemProcess,
            nameKey: "group.builtin.known_system_process",
            detailKey: "group.builtin.known_system_process.detail",
            content: .rule,
            kind: .knownSystemProcess
        ),
        Definition(
            id: BuiltinRuleID.kernelBootstrap,
            nameKey: "group.builtin.kernel_bootstrap",
            detailKey: "group.builtin.kernel_bootstrap.detail",
            content: .condition,
            condition: any([
                rule(.nameExact, "kernel_task"),
                rule(.nameExact, "launchd"),
            ])
        ),
        Definition(
            id: BuiltinRuleID.foregroundApp,
            nameKey: "group.builtin.foreground_app",
            detailKey: "group.builtin.foreground_app.detail",
            content: .rule,
            kind: .processKind,
            value: ProcessKind.app.rawValue
        ),
        Definition(
            id: BuiltinRuleID.backgroundProcess,
            nameKey: "group.builtin.background_process",
            detailKey: "group.builtin.background_process.detail",
            content: .condition,
            condition: not(rule(.processKind, ProcessKind.app.rawValue))
        ),
        Definition(
            id: BuiltinRuleID.pathEmpty,
            nameKey: "group.builtin.path_empty",
            detailKey: "group.builtin.path_empty.detail",
            content: .rule,
            kind: .pathEmpty
        ),
    ]

    // MARK: - Composed conditions

    private static var appleBundleCondition: GroupConditionNode {
        any([
            rule(.bundlePrefix, "com.apple."),
            rule(.bundlePrefix, "com.apple"),
            rule(.bundlePrefix, "edu.mit.kerberos"),
        ])
    }

    private static var daemonOrHelperCondition: GroupConditionNode {
        any([
            rule(.processKind, ProcessKind.daemon.rawValue),
            rule(.processKind, ProcessKind.helper.rawValue),
        ])
    }

    private static var appleSystemCondition: GroupConditionNode {
        any([
            rule(.knownSystemProcess),
            all([ref(BuiltinRuleID.appleBundle), rule(.systemPath)]),
            all([ref(BuiltinRuleID.appleBundle), daemonOrHelperCondition]),
            rule(.systemPath),
            rule(.namePattern, "com.apple.*"),
            all([rule(.pathEmpty), rule(.namePattern, "kernel*")]),
            all([rule(.pathEmpty), rule(.namePattern, "com.apple*")]),
        ])
    }

    private static var appleAppCondition: GroupConditionNode {
        // 与「Apple 系统」互斥：分类器按 系统 → 应用 顺序判定，
        // 内置「Apple 应用」也要排除系统进程，保证引用结果与侧栏计数一致。
        all([
            not(ref(BuiltinRuleID.appleSystem)),
            any([
                all([
                    ref(BuiltinRuleID.appleBundle),
                    not(rule(.systemPath)),
                    not(daemonOrHelperCondition),
                ]),
                rule(.appleAppPath),
            ]),
        ])
    }

    private static var thirdPartyCondition: GroupConditionNode {
        all([
            not(ref(BuiltinRuleID.appleSystem)),
            not(ref(BuiltinRuleID.appleApp)),
            not(rule(.pathEmpty)),
        ])
    }

    private static var appleAllCondition: GroupConditionNode {
        any([
            ref(BuiltinRuleID.appleSystem),
            ref(BuiltinRuleID.appleApp),
        ])
    }

    // MARK: - Node helpers

    private static func rule(_ kind: GroupRuleKind, _ value: String = "") -> GroupConditionNode {
        GroupConditionNode(rule: GroupRule(kind: kind, value: value))
    }

    private static func ref(_ id: UUID) -> GroupConditionNode {
        GroupConditionNode(ruleRef: id)
    }

    private static func any(_ children: [GroupConditionNode]) -> GroupConditionNode {
        GroupConditionNode(combinator: .any, children: children)
    }

    private static func all(_ children: [GroupConditionNode]) -> GroupConditionNode {
        GroupConditionNode(combinator: .all, children: children)
    }

    private static func not(_ node: GroupConditionNode) -> GroupConditionNode {
        var copy = node
        copy.isNegated.toggle()
        return copy
    }
}
