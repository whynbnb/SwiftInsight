import Foundation
import AppKit
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("lang.system")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    /// 解析后的实际语言（system 跟随系统）
    var resolved: ResolvedLanguage {
        switch self {
        case .chinese: return .zh
        case .english: return .en
        case .system:
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zh : .en
        }
    }
}

enum ResolvedLanguage {
    case zh
    case en
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("theme.system")
        case .light: return L("theme.light")
        case .dark: return L("theme.dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 进程详情面板位置（右侧 / 底部）
enum DetailPanelPosition: String, CaseIterable, Identifiable {
    case right
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .right: return L("detail.position.right")
        case .bottom: return L("detail.position.bottom")
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private static let languageKey = "appLanguage"
    private static let themeKey = "appTheme"
    private static let detailPanelPositionKey = "detailPanelPosition"
    private static let rememberViewStateKey = "rememberViewState"
    private static let rankingTabKey = "rankingTab"
    private static let menuBarTopCountKey = "menuBarTopCount"
    private static let menuBarDisplayModeKey = "menuBarDisplayMode"
    nonisolated static let menuBarTopCountRange = 3...15
    nonisolated static let menuBarTopCountDefault = 8


    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            L10nRuntime.language = language.resolved
            objectWillChange.send()
        }
    }

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
            applyTheme()
        }
    }

    /// 进程详情面板位置：右侧（默认）/ 底部
    @Published var detailPanelPosition: DetailPanelPosition {
        didSet {
            UserDefaults.standard.set(detailPanelPosition.rawValue, forKey: Self.detailPanelPositionKey)
        }
    }

    /// 是否记住界面状态（分类 / 前后台筛选 / 视图 / 排序）
    @Published var rememberViewState: Bool {
        didSet {
            UserDefaults.standard.set(rememberViewState, forKey: Self.rememberViewStateKey)
        }
    }

    /// 「谁在吃资源」当前标签页
    @Published var rankingTab: RankingTab {
        didSet {
            guard rememberViewState else { return }
            UserDefaults.standard.set(rankingTab.rawValue, forKey: Self.rankingTabKey)
        }
    }

    /// 菜单栏高占用条数（CPU / 内存各一列），3–15，默认 8
    @Published var menuBarTopCount: Int {
        didSet {
            let clamped = Self.clampedTopCount(menuBarTopCount)
            if clamped != menuBarTopCount {
                menuBarTopCount = clamped
                return
            }
            UserDefaults.standard.set(menuBarTopCount, forKey: Self.menuBarTopCountKey)
        }
    }

    /// 菜单栏 Top 列表模式（列表 / 聚合 / 父子），与主窗口 displayMode 独立
    @Published var menuBarDisplayMode: ListDisplayMode {
        didSet {
            UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: Self.menuBarDisplayModeKey)
        }
    }

    var resolvedLanguage: ResolvedLanguage { language.resolved }

    nonisolated static func clampedTopCount(_ value: Int) -> Int {
        min(menuBarTopCountRange.upperBound, max(menuBarTopCountRange.lowerBound, value))
    }


    private init() {
        let lang: AppLanguage
        if let raw = UserDefaults.standard.string(forKey: Self.languageKey),
           let parsed = AppLanguage(rawValue: raw) {
            lang = parsed
        } else {
            lang = .system
        }
        language = lang

        let th: AppTheme
        if let raw = UserDefaults.standard.string(forKey: Self.themeKey),
           let parsed = AppTheme(rawValue: raw) {
            th = parsed
        } else {
            th = .system
        }
        theme = th

        if let raw = UserDefaults.standard.string(forKey: Self.detailPanelPositionKey),
           let pos = DetailPanelPosition(rawValue: raw) {
            detailPanelPosition = pos
        } else {
            detailPanelPosition = .right
        }

        let remember = UserDefaults.standard.object(forKey: Self.rememberViewStateKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.rememberViewStateKey)
        rememberViewState = remember

        if remember,
           let raw = UserDefaults.standard.string(forKey: Self.rankingTabKey),
           let tab = RankingTab(rawValue: raw) {
            rankingTab = tab
        } else {
            rankingTab = .thirdCPU
        }

        let storedTop = UserDefaults.standard.object(forKey: Self.menuBarTopCountKey) as? Int
            ?? Self.menuBarTopCountDefault
        menuBarTopCount = Self.clampedTopCount(storedTop)

        if let raw = UserDefaults.standard.string(forKey: Self.menuBarDisplayModeKey),
           let mode = ListDisplayMode(rawValue: raw) {
            menuBarDisplayMode = mode
        } else {
            menuBarDisplayMode = .flat
        }

        L10nRuntime.language = lang.resolved
        applyTheme()
    }

    func applyTheme() {
        // 静态初始化过早时 NSApp 仍为 nil
        guard NSApp != nil else { return }
        NSApp.appearance = theme.nsAppearance
    }
}

/// 线程安全当前语言
enum L10nRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _language: ResolvedLanguage = .zh

    static var language: ResolvedLanguage {
        get { lock.lock(); defer { lock.unlock() }; return _language }
        set { lock.lock(); _language = newValue; lock.unlock() }
    }
}

/// 全局本地化（任意线程可调）
func L(_ key: String) -> String {
    L10n.string(key, language: L10nRuntime.language)
}

enum L10n {
    static func string(_ key: String, language: ResolvedLanguage) -> String {
        let table = language == .zh ? zh : en
        if let v = table[key] { return v }
        // 回退：英文表 → 中文表 → key 本身
        if let v = en[key] { return v }
        if let v = zh[key] { return v }
        return key
    }

    // MARK: - Chinese (default product language)

    private static let zh: [String: String] = [
        // Language / Theme
        "lang.system": "跟随系统",
        "theme.system": "跟随系统",
        "theme.light": "浅色",
        "theme.dark": "深色",
        "settings.appearance": "外观",
        "settings.language": "语言",
        "settings.theme": "主题",
        "settings.language.caption": "切换后界面立即更新；菜单栏面板同步刷新。",
        "settings.theme.caption": "浅色 / 深色，或跟随系统外观。",
        "settings.detail_position": "详情面板位置",
        "settings.detail_position.caption": "点击进程后，详情显示在右侧或底部（默认右侧）。",
        "settings.view_state": "界面状态",
        "settings.remember_view_state": "记住界面状态",
        "settings.remember_view_state.caption": "记住分类、前后台筛选、视图模式、排序方式和资源排行标签页；关闭后每次启动恢复默认值。",

        // Categories
        "cat.appleSystem": "Apple 系统",
        "cat.appleApp": "Apple 应用",
        "cat.thirdParty": "第三方",
        "cat.unknown": "未知",
        "cat.short.system": "系统",
        "cat.short.apple": "官方",
        "cat.short.third": "三方",
        "cat.all": "全部进程",

        // Display / sort
        "mode.flat": "列表",
        "mode.tree": "聚合",
        "mode.application": "按应用",
        "mode.parentTree": "父子",
        "sort.cpu": "CPU",
        "sort.memory": "内存",
        "sort.name": "名称",
        "sort.pid": "PID",
        "sort.threads": "线程",
        "history.30s": "30 秒",
        "history.2m": "2 分钟",
        "history.5m": "5 分钟",
        "icon.cpu": "CPU 状态条",
        "icon.memory": "内存状态条",
        "icon.combined": "CPU + 内存",
        "icon.short.memory": "内存",
        "icon.short.combined": "叠加",

        // Status
        "status.stopped": "已停止",
        "status.paused": "已暂停 · 松开 ⌃ 继续",
        "status.locked": "已暂停 · 点击锁定按钮继续",
        "status.live": "实时 · 每 %d 秒",
        "status.menubar_live": "菜单栏 · 每 %d 秒",
        "status.icon_live": "图标 · 每 %d 秒",
        "status.panel_live": "面板 · 每 %d 秒",
        "status.helper.hint": "来自 root Helper 补全（本地无法直接读取该进程 taskinfo）",
        "status.helper.unavailable": "无法读取该进程资源：系统保护/其他用户进程。可安装 root Helper 补全。",
        "status.cpu_mem": "CPU %.0f%% · 内存 %.0f%%",

        // Metrics labels
        "metric.cpu": "CPU",
        "metric.memory": "内存",
        "metric.swap": "交换",
        "metric.network": "网络",
        "metric.disk": "磁盘",
        "metric.load": "负载",
        "metric.throughput": "吞吐",
        "metric.page_io": "页换入出",
        "metric.user": "用户",
        "metric.system": "系统",
        "metric.app": "应用",
        "metric.wired": "联动",
        "metric.compressed": "压缩",
        "metric.available": "可用",
        "metric.pressure": "压力",
        "metric.efficiency": "能效",
        "metric.performance": "性能",
        "metric.cores": "%d 核",
        "metric.logical_cores": "%d 逻辑核",
        "metric.ep_cores": "能效 %.0f%% · 性能 %.0f%% · %d 核",
        "metric.user_system": "用户 %.0f%%  系统 %.0f%%",
        "metric.pressure_fmt": "压力 %.0f%% · %@",
        "metric.swap_total": "共 %@",
        "metric.swap_none": "未使用",
        "metric.mem_detail": "应用 %@ · 联动 %@ · 压缩 %@",
        "metric.core_summary": "E %.0f%%  P %.0f%%",
        "pressure.normal": "正常",
        "pressure.warning": "警告",
        "pressure.critical": "危急",
        "thermal.nominal": "正常",
        "thermal.fair": "热·中",
        "thermal.serious": "热·高",
        "thermal.critical": "热·危",

        // Settings
        "settings.tab.general": "通用",
        "settings.tab.refresh": "刷新",
        "settings.tab.menubar": "菜单栏",
        "settings.tab.helper": "特权",
        "settings.tab.about": "关于",
        "settings.refresh": "刷新",
        "settings.refresh_interval": "主窗口间隔",
        "settings.refresh.main.caption": "仅主窗口打开时生效：完整进程列表、图表与详情。关闭主窗口后自动停用。",
        "settings.1s": "1 秒",
        "settings.2s": "2 秒",
        "settings.3s": "3 秒",
        "settings.5s": "5 秒",
        "settings.10s": "10 秒",
        "settings.pause_refresh": "暂停刷新",
        "settings.hold_control": "按住 ⌃ Control",
        "settings.pause.caption": "按住 Control 仅暂停主窗口自动刷新；菜单栏常驻采样不受影响。松开后主窗口立即刷新一次。",
        "settings.menubar": "菜单栏",
        "settings.icon_mode": "图标模式",
        "settings.menubar.icon_interval": "图标间隔",
        "settings.menubar.icon.caption": "仅状态栏迷你条：只采整机 CPU/内存，不枚举进程。主窗口打开或面板展开时自动停用。",
        "settings.menubar.panel_interval": "面板间隔",
        "settings.menubar.panel.caption": "点击图标弹出的面板：采进程排名与精简指标。仅面板打开时运行；关闭后立刻退回图标轨。",
        "settings.menubar.top_count": "高占用条数",
        "settings.menubar.top_count.caption": "菜单栏面板中 CPU / 内存高占用列表各显示的条数（3–15）。",
        "settings.menubar.top_mode": "Top 展示方式",
        "settings.menubar.top_mode.caption": "列表 / 聚合 / 父子，与主窗口视图模式一致，但单独配置、互不同步。",
        "settings.menubar.caption": "状态栏显示 CPU / 内存迷你条；点击弹出精简面板。关闭主窗口后仍保留菜单栏。",
        "settings.launch_at_login": "开机自启",
        "settings.launch_at_login.caption": "登录后自动启动（需使用 .app 运行；首次可能弹出系统授权）。",
        "settings.launch_at_login.unavailable": "当前不是完整 .app，无法注册开机自启。请用 Xcode / 打包脚本运行。",
        "settings.launch_at_login.failed": "设置失败，请在「系统设置 → 通用 → 登录项」中检查。",
        "settings.helper": "特权采样（自用）",
        "settings.helper.body": "部分系统保护进程对普通用户不可读。本 App 可将内嵌 Helper 安装为 setuid root（需管理员密码），用于补全 CPU/内存，并采样频率/温度。无需源码。",
        "settings.helper.install": "安装（需管理员密码，仅本机自用）：",
        "settings.helper.uninstall": "卸载：sudo rm -f /usr/local/libexec/SwiftInsightHelper",
        "settings.helper.install_btn": "安装 Helper…",
        "settings.helper.uninstall_btn": "卸载 Helper…",
        "settings.helper.recheck": "重新检测",
        "settings.helper.ok": "已安装 · root 生效",
        "settings.helper.not_root": "已找到但非 root（请重新安装）",
        "settings.helper.missing": "未安装",
        "settings.helper.bundled": "包内已带 · 尚未安装为 root",
        "settings.helper.no_bundle": "当前 App 未内嵌 Helper。请用 Xcode / package-app 完整构建后再安装。",
        "settings.helper.install_ok": "安装成功，已生效。",
        "settings.helper.uninstall_ok": "已卸载。",
        "settings.helper.cancelled": "已取消。",
        "settings.helper.failed": "失败：%@",
        "settings.helper.path_hint": "安装路径：/usr/local/libexec/SwiftInsightHelper",
        "settings.classification": "关于分类",
        "settings.classification.intro": "SwiftInsight 根据进程路径、Bundle Identifier 与已知系统进程名，区分：",
        "settings.classification.system": "Apple 系统 — 内核、launchd、系统守护进程与 /System、/usr 等路径",
        "settings.classification.app": "Apple 应用 — 带 com.apple.* Bundle ID 或系统自带应用",
        "settings.classification.third": "第三方 — 其余用户安装的应用与进程",
        "settings.about": "关于",
        "settings.app": "应用",
        "settings.purpose": "用途",
        "settings.purpose.value": "活动监视器替代 · 侧重 Apple / 第三方资源对比",
        "settings.version": "版本",
        "settings.bundle_id": "包名",
        "settings.repository": "仓库",
        "settings.license": "开源协议",

        // Main window
        "search.prompt": "搜索名称、PID、路径、Bundle ID…",
        "toolbar.view": "视图",
        "toolbar.refresh": "刷新",
        "toolbar.refresh.help": "立即刷新",
        "toolbar.lock": "锁定数据",
        "toolbar.unlock": "恢复刷新",
        "toolbar.lock.help": "暂停自动刷新并保留当前数据（等同于按住 ⌃）",
        "alert.quit": "退出进程？",
        "alert.force_quit": "强制退出进程？",
        "alert.cancel": "取消",
        "alert.quit_btn": "退出",
        "alert.force_quit_btn": "强制退出",
        "sidebar.category": "分类",
        "sidebar.filter": "筛选",
        "sidebar.filter.help": "范围筛选；「按应用」聚合时会忽略此筛选。",
        "scope.all": "全部",
        "scope.foreground": "前台 App",
        "scope.background": "后台进程",
        "sidebar.resource": "资源占用对比",
        "sidebar.who": "谁在吃资源",
        "sidebar.apple_total": "Apple 合计",
        "summary.process_count": "共 %d 个进程",
        "summary.updated": "更新于",
        "summary.pause_on": "按住 Control 暂停刷新中",
        "summary.pause_off": "按住 Control 可暂停自动刷新",
        "detail.path_unavailable": "路径不可用",
        "detail.source": "来源",
        "detail.actions": "操作",
        "detail.close": "关闭详情",
        "detail.position.right": "右侧",
        "detail.position.bottom": "底部",
        "detail.user": "用户",
        "detail.threads": "线程",
        "detail.memory": "内存",
        "menu.reveal": "在 Finder 中显示",
        "menu.copy_path": "复制路径",
        "menu.copy_bid": "复制 Bundle ID",
        "menu.filter_category": "筛选此分类",
        "menu.groups": "加入分组",
        "menu.create_group": "新建分组并加入…",
        "sidebar.groups": "自定义分组",
        "group.new": "新建分组",
        "group.edit": "编辑分组…",
        "group.delete": "删除分组",
        "group.delete.confirm": "删除这个分组？",
        "group.save": "保存",
        "group.done": "完成",
        "group.untitled": "未命名分组",
        "group.name": "分组名称",
        "group.type": "类型",
        "group.kind.dynamic": "动态",
        "group.kind.static": "静态",
        "group.kind.dynamic.help": "动态：按条件组自动匹配，支持「且 / 或 / 非」、嵌套与引用规则库，成员随进程自动增减。",
        "group.kind.static.help": "静态：只包含手动加入的应用，成员固定。",
        "group.rules": "匹配规则",
        "group.rule.add": "添加规则",
        "group.rule.empty": "还没有规则，添加后才会匹配进程。",
        "group.rule.bundle": "Bundle ID 前缀",
        "group.rule.name": "名称包含",
        "group.rule.bundle_pattern": "Bundle ID 通配符",
        "group.rule.name_pattern": "名称通配符",
        "group.rule.path": "路径包含",
        "group.rule.user": "用户",
        "group.rule.wildcard.hint": "通配符：* 匹配任意多个字符，? 匹配单个字符；不含通配符时按完整名称匹配。",
        "group.logic": "匹配逻辑",
        "group.logic.any": "任一（或）",
        "group.logic.all": "全部（且）",
        "group.logic.not.short": "非",
        "group.logic.not.help": "取反：命中该规则或条件组时，不归入此分组。",
        "group.logic.hint": "条件组可嵌套：子条件按所选的「或 / 且」组合，点「非」可排除单条规则或整个条件组。",
        "group.condition.add_group": "添加条件组",
        "group.condition.remove": "移除条件组",
        "group.condition.empty": "空条件组不会匹配任何进程。",
        "group.rule.untitled": "未命名规则",
        "group.rule.untitled_set": "未命名规则集",
        "group.rule.library.save_set": "保存为规则集…",
        "group.rule.library.save_set.empty": "静态分组还没有应用，无法保存为规则集",
        "group.rule.library.set.summary": "%d 个应用",
        "group.rule.library.set.members": "应用成员",
        "group.rule.library.set.help": "规则集保存静态分组的固定应用列表，引用后匹配其中任一应用；成员可在规则库中调整。",
        "group.rule.kind": "规则类型",
        "group.rule.value": "匹配值",
        "group.rule.reference": "引用规则",
        "group.rule.manage_library": "管理规则库…",
        "group.rule.library": "规则库",
        "group.rule.library.help": "规则库中的命名规则可在多个分组中复用；修改后所有引用自动生效。",
        "group.rule.library.empty": "规则库为空",
        "group.rule.library.empty_hint": "还没有保存的规则。可以在规则行点书签保存，或新建一条。",
        "group.rule.library.new": "新建规则",
        "group.rule.library.edit": "编辑规则",
        "group.rule.library.delete": "删除规则",
        "group.rule.library.delete.confirm": "删除这条规则？",
        "group.rule.library.delete.usage": "%d 个分组正在引用它，删除后这些引用将失效。",
        "group.rule.library.usage": "%d 个引用",
        "group.rule.save_to_library": "保存到规则库…",
        "group.rule.saved_to_library": "已在规则库中",
        "group.rule.missing": "引用的规则已删除",
        "group.rule.missing.help": "请重新选择或移除引用",
        "group.members": "应用成员",
        "group.member.add": "添加应用",
        "group.member.empty": "还没有应用，添加后会固定包含这些应用。",
        "group.add": "添加",
        "group.added": "已添加",
        "group.remove": "移除",
        "group.clear": "清除分组筛选",
        "group.chip.help": "当前按分组「%@」筛选",
        "group.empty_hint": "点击 + 新建分组，例如「浏览器」",
        "group.process_count": "%d 个进程",
        "group.search.apps": "搜索应用、Bundle ID 或路径…",
        "menu.collapse": "折叠",
        "menu.expand": "展开",
        "table.sort": "排序:",
        "table.groups": "%d 组 · %d 行",
        "table.items": "%d 项",
        "table.name": "名称",
        "table.user": "用户",
        "rank.third_cpu": "第三方 · CPU",
        "rank.third_mem": "第三方 · 内存",
        "rank.sys_cpu": "Apple 系统 · CPU",
        "rank.app_cpu": "Apple 应用 · CPU",
        "rank.tab.third_cpu": "三方 CPU",
        "rank.tab.third_mem": "三方 内存",
        "rank.tab.third": "三方",
        "rank.tab.sys_cpu": "系统",
        "rank.tab.app_cpu": "应用",
        "rank.empty": "暂无数据",
        "detail.parent": "父进程",
        "detail.open_files": "打开文件",
        "detail.started": "启动",
        "chart.cpu": "CPU 趋势",
        "chart.memory": "内存 趋势",
        "chart.category": "分类 CPU",
        "chart.series.third": "第三方",
        "chart.series.apple": "Apple",
        "chart.history": "历史",
        "chart.collecting": "采集中…",
        "chart.points": "%d 点",
        "chart.need_samples": "历史曲线采集中（需 %@ 内多个采样点）",
        "menubar.icon": "菜单栏图标",
        "menubar.mode": "模式",

        // Commands
        "cmd.process": "进程",
        "cmd.refresh": "刷新",
        "cmd.show_all": "显示全部",
        "cmd.only_system": "仅 Apple 系统",
        "cmd.only_app": "仅 Apple 应用",
        "cmd.only_third": "仅第三方",
        "cmd.menubar": "菜单栏",
        "cmd.about": "关于 SwiftInsight",

        // Menu bar panel
        "mb.open_main": "打开主窗口",
        "mb.quit_app": "退出 SwiftInsight",
        "mb.github": "GitHub…",
        "mb.launch_at_login": "开机自启",
        "mb.composition": "构成",
        "mb.tops": "高占用",
        "mb.full_window": "完整窗口",
        "mb.quit": "退出",
        "mb.activity_monitor": "活动监视器",
        "mb.system_info": "系统信息",
        "mb.none": "暂无",
        "mb.pressure_tip": "内核档位 %d · memorystatus_level 推算 %.0f%%",
        "mb.cores_tip": "%d 核 · E %.0f%% · P %.0f%%",
        "mb.cores_avg": "%d 核 · 均值 %.0f%%",
        "file.kind.file": "文件",
        "file.kind.socket": "套接字",
        "file.kind.pipe": "管道",
        "file.note.fail": "无法读取打开文件（权限不足或进程已退出）",
        "file.note.count": "共 %d 个打开的文件/套接字",
    ]

    // MARK: - English

    private static let en: [String: String] = [
        "lang.system": "System",
        "theme.system": "System",
        "theme.light": "Light",
        "theme.dark": "Dark",
        "settings.appearance": "Appearance",
        "settings.language": "Language",
        "settings.theme": "Theme",
        "settings.language.caption": "UI updates immediately; menu bar panel refreshes too.",
        "settings.theme.caption": "Light, Dark, or follow system appearance.",
        "settings.detail_position": "Detail panel position",
        "settings.detail_position.caption": "Show process details on the right or at the bottom (right by default).",
        "settings.view_state": "View state",
        "settings.remember_view_state": "Remember view state",
        "settings.remember_view_state.caption": "Remember category, scope, view mode, sorting, and the ranking tab. When off, defaults are used on every launch.",

        "cat.appleSystem": "Apple System",
        "cat.appleApp": "Apple Apps",
        "cat.thirdParty": "Third-Party",
        "cat.unknown": "Unknown",
        "cat.short.system": "System",
        "cat.short.apple": "Apple",
        "cat.short.third": "3rd",
        "cat.all": "All Processes",

        "mode.flat": "List",
        "mode.tree": "Grouped",
        "mode.application": "By App",
        "mode.parentTree": "Parent",
        "sort.cpu": "CPU",
        "sort.memory": "Memory",
        "sort.name": "Name",
        "sort.pid": "PID",
        "sort.threads": "Threads",
        "history.30s": "30 sec",
        "history.2m": "2 min",
        "history.5m": "5 min",
        "icon.cpu": "CPU bar",
        "icon.memory": "Memory bar",
        "icon.combined": "CPU + Memory",
        "icon.short.memory": "Memory",
        "icon.short.combined": "Both",

        "status.stopped": "Stopped",
        "status.paused": "Paused · release ⌃ to resume",
        "status.locked": "Paused · click lock to resume",
        "status.live": "Live · every %d s",
        "status.menubar_live": "Menu bar · every %d s",
        "status.icon_live": "Icon · every %d s",
        "status.panel_live": "Panel · every %d s",
        "status.helper.hint": "Filled by root Helper (taskinfo not readable locally)",
        "status.helper.unavailable": "Cannot read process resources (protected/other user). Install root Helper to fill.",
        "status.cpu_mem": "CPU %.0f%% · Mem %.0f%%",

        "metric.cpu": "CPU",
        "metric.memory": "Memory",
        "metric.swap": "Swap",
        "metric.network": "Network",
        "metric.disk": "Disk",
        "metric.load": "Load",
        "metric.throughput": "I/O",
        "metric.page_io": "Page in/out",
        "metric.user": "User",
        "metric.system": "System",
        "metric.app": "App",
        "metric.wired": "Wired",
        "metric.compressed": "Compressed",
        "metric.available": "Free",
        "metric.pressure": "Pressure",
        "metric.efficiency": "Efficiency",
        "metric.performance": "Performance",
        "metric.cores": "%d cores",
        "metric.logical_cores": "%d logical cores",
        "metric.ep_cores": "E %.0f%% · P %.0f%% · %d cores",
        "metric.user_system": "User %.0f%%  Sys %.0f%%",
        "metric.pressure_fmt": "Pressure %.0f%% · %@",
        "metric.swap_total": "Total %@",
        "metric.swap_none": "Unused",
        "metric.mem_detail": "App %@ · Wired %@ · Compressed %@",
        "metric.core_summary": "E %.0f%%  P %.0f%%",
        "pressure.normal": "Normal",
        "pressure.warning": "Warning",
        "pressure.critical": "Critical",
        "thermal.nominal": "Normal",
        "thermal.fair": "Warm",
        "thermal.serious": "Hot",
        "thermal.critical": "Critical",

        "settings.tab.general": "General",
        "settings.tab.refresh": "Refresh",
        "settings.tab.menubar": "Menu Bar",
        "settings.tab.helper": "Helper",
        "settings.tab.about": "About",
        "settings.refresh": "Refresh",
        "settings.refresh_interval": "Main window interval",
        "settings.refresh.main.caption": "Applies only while the main window is open: full process list, charts, and details. Stops when the window is closed.",
        "settings.1s": "1 sec",
        "settings.2s": "2 sec",
        "settings.3s": "3 sec",
        "settings.5s": "5 sec",
        "settings.10s": "10 sec",
        "settings.pause_refresh": "Pause refresh",
        "settings.hold_control": "Hold ⌃ Control",
        "settings.pause.caption": "Hold Control to pause main-window auto-refresh only; menu-bar sampling keeps running. Release to refresh the main window once.",
        "settings.menubar": "Menu Bar",
        "settings.icon_mode": "Icon mode",
        "settings.menubar.icon_interval": "Icon interval",
        "settings.menubar.icon.caption": "Status-item bars only: system CPU/memory, no process enumeration. Pauses while the main window or panel is open.",
        "settings.menubar.panel_interval": "Panel interval",
        "settings.menubar.panel.caption": "Click-to-open panel: process rankings and compact metrics. Runs only while the panel is open; closes back to the icon track.",
        "settings.menubar.top_count": "Top processes",
        "settings.menubar.top_count.caption": "How many CPU / memory top entries to show in the menu bar panel (3–15).",
        "settings.menubar.top_mode": "Top list mode",
        "settings.menubar.top_mode.caption": "List / Grouped / Parent — same options as the main window, stored separately.",
        "settings.menubar.caption": "Status item shows CPU/memory mini bars; click for a compact panel. Menu bar stays when the main window is closed.",
        "settings.launch_at_login": "Launch at Login",
        "settings.launch_at_login.caption": "Start automatically after login (requires a real .app; macOS may prompt for permission).",
        "settings.launch_at_login.unavailable": "Not running as a full .app, so login items cannot be registered. Use Xcode or the package script.",
        "settings.launch_at_login.failed": "Could not update login item. Check System Settings → General → Login Items.",
        "settings.helper": "Privileged sampling",
        "settings.helper.body": "Some protected processes are unreadable as a normal user. This app can install its bundled Helper as setuid root (admin password) to fill CPU/memory and sample frequency/temperature. No source code needed on the target Mac.",
        "settings.helper.install": "Install (admin password, local use only):",
        "settings.helper.uninstall": "Uninstall: sudo rm -f /usr/local/libexec/SwiftInsightHelper",
        "settings.helper.install_btn": "Install Helper…",
        "settings.helper.uninstall_btn": "Uninstall Helper…",
        "settings.helper.recheck": "Recheck",
        "settings.helper.ok": "Installed · root active",
        "settings.helper.not_root": "Found but not root (re-install)",
        "settings.helper.missing": "Not installed",
        "settings.helper.bundled": "Bundled · not installed as root",
        "settings.helper.no_bundle": "This build has no bundled Helper. Build with Xcode or package-app first.",
        "settings.helper.install_ok": "Installed successfully.",
        "settings.helper.uninstall_ok": "Uninstalled.",
        "settings.helper.cancelled": "Cancelled.",
        "settings.helper.failed": "Failed: %@",
        "settings.helper.path_hint": "Install path: /usr/local/libexec/SwiftInsightHelper",
        "settings.classification": "About categories",
        "settings.classification.intro": "SwiftInsight classifies processes by path, Bundle ID, and known system names:",
        "settings.classification.system": "Apple System — kernel, launchd, daemons under /System, /usr, etc.",
        "settings.classification.app": "Apple Apps — com.apple.* Bundle IDs or built-in apps",
        "settings.classification.third": "Third-Party — everything else you installed",
        "settings.about": "About",
        "settings.app": "App",
        "settings.purpose": "Purpose",
        "settings.purpose.value": "Activity Monitor alternative · Apple vs third-party focus",
        "settings.version": "Version",
        "settings.bundle_id": "Bundle ID",
        "settings.repository": "Repository",
        "settings.license": "License",

        "search.prompt": "Search name, PID, path, Bundle ID…",
        "toolbar.view": "View",
        "toolbar.refresh": "Refresh",
        "toolbar.refresh.help": "Refresh now",
        "toolbar.lock": "Lock Data",
        "toolbar.unlock": "Resume",
        "toolbar.lock.help": "Pause auto-refresh and keep current data (same as holding ⌃)",
        "alert.quit": "Quit process?",
        "alert.force_quit": "Force quit process?",
        "alert.cancel": "Cancel",
        "alert.quit_btn": "Quit",
        "alert.force_quit_btn": "Force Quit",
        "sidebar.category": "Category",
        "sidebar.filter": "Filter",
        "sidebar.filter.help": "Process scope; ignored when aggregating by app.",
        "scope.all": "All",
        "scope.foreground": "Foreground Apps",
        "scope.background": "Background",
        "sidebar.resource": "Resource breakdown",
        "sidebar.who": "Top consumers",
        "sidebar.apple_total": "Apple total",
        "summary.process_count": "%d processes",
        "summary.updated": "Updated",
        "summary.pause_on": "Hold Control — refresh paused",
        "summary.pause_off": "Hold Control to pause auto-refresh",
        "detail.path_unavailable": "Path unavailable",
        "detail.source": "Source",
        "detail.actions": "Actions",
        "detail.close": "Close details",
        "detail.position.right": "Right",
        "detail.position.bottom": "Bottom",
        "detail.user": "User",
        "detail.threads": "Threads",
        "detail.memory": "Memory",
        "menu.reveal": "Show in Finder",
        "menu.copy_path": "Copy Path",
        "menu.copy_bid": "Copy Bundle ID",
        "menu.filter_category": "Filter this category",
        "menu.groups": "Add to Group",
        "menu.create_group": "New Group with This Process…",
        "sidebar.groups": "Custom Groups",
        "group.new": "New Group",
        "group.edit": "Edit Group…",
        "group.delete": "Delete Group",
        "group.delete.confirm": "Delete this group?",
        "group.save": "Save",
        "group.done": "Done",
        "group.untitled": "Untitled Group",
        "group.name": "Group name",
        "group.type": "Type",
        "group.kind.dynamic": "Dynamic",
        "group.kind.static": "Static",
        "group.kind.dynamic.help": "Dynamic: matches a condition tree with AND / OR / NOT, nesting, and reusable library rules; members follow the process list.",
        "group.kind.static.help": "Static: contains only the apps you add manually.",
        "group.rules": "Match rules",
        "group.rule.add": "Add Rule",
        "group.rule.empty": "No rules yet. Add one to start matching processes.",
        "group.rule.bundle": "Bundle ID prefix",
        "group.rule.name": "Name contains",
        "group.rule.bundle_pattern": "Bundle ID wildcard",
        "group.rule.name_pattern": "Name wildcard",
        "group.rule.path": "Path contains",
        "group.rule.user": "User",
        "group.rule.wildcard.hint": "Wildcards: * matches any characters, ? matches one character. Without wildcards the value must match exactly.",
        "group.logic": "Logic",
        "group.logic.any": "Any (OR)",
        "group.logic.all": "All (AND)",
        "group.logic.not.short": "NOT",
        "group.logic.not.help": "Negate: processes matching this rule or group are excluded.",
        "group.logic.hint": "Condition groups can nest: children combine with OR / AND, and NOT excludes a single rule or an entire group.",
        "group.condition.add_group": "Add Group",
        "group.condition.remove": "Remove condition group",
        "group.condition.empty": "An empty condition group matches nothing.",
        "group.rule.untitled": "Untitled Rule",
        "group.rule.untitled_set": "Untitled Rule Set",
        "group.rule.library.save_set": "Save as Rule Set…",
        "group.rule.library.save_set.empty": "This static group has no apps yet",
        "group.rule.library.set.summary": "%d apps",
        "group.rule.library.set.members": "Apps",
        "group.rule.library.set.help": "A rule set stores a static group's fixed app list; referencing it matches any of those apps. Members can be adjusted in the library.",
        "group.rule.kind": "Rule type",
        "group.rule.value": "Match value",
        "group.rule.reference": "Reference Rule",
        "group.rule.manage_library": "Manage Rule Library…",
        "group.rule.library": "Rule Library",
        "group.rule.library.help": "Named library rules can be reused by any group; edits apply to every reference immediately.",
        "group.rule.library.empty": "Rule library is empty",
        "group.rule.library.empty_hint": "No saved rules yet. Use the bookmark on a rule row, or create one.",
        "group.rule.library.new": "New Rule",
        "group.rule.library.edit": "Edit Rule",
        "group.rule.library.delete": "Delete Rule",
        "group.rule.library.delete.confirm": "Delete this rule?",
        "group.rule.library.delete.usage": "%d groups reference it. Those references will stop matching.",
        "group.rule.library.usage": "%d refs",
        "group.rule.save_to_library": "Save to Rule Library…",
        "group.rule.saved_to_library": "Already in rule library",
        "group.rule.missing": "Referenced rule deleted",
        "group.rule.missing.help": "Choose another rule or remove the reference",
        "group.members": "Apps",
        "group.member.add": "Add App",
        "group.member.empty": "No apps yet. Added apps stay in this group.",
        "group.add": "Add",
        "group.added": "Added",
        "group.remove": "Remove",
        "group.clear": "Clear group filter",
        "group.chip.help": "Filtered by group \"%@\"",
        "group.empty_hint": "Click + to create a group, e.g. “Browsers”",
        "group.process_count": "%d processes",
        "group.search.apps": "Search apps, Bundle IDs, or paths…",
        "menu.collapse": "Collapse",
        "menu.expand": "Expand",
        "table.sort": "Sort:",
        "table.groups": "%d groups · %d rows",
        "table.items": "%d items",
        "table.name": "Name",
        "table.user": "User",
        "rank.third_cpu": "Third-Party · CPU",
        "rank.third_mem": "Third-Party · Memory",
        "rank.sys_cpu": "Apple System · CPU",
        "rank.app_cpu": "Apple Apps · CPU",
        "rank.tab.third_cpu": "3rd CPU",
        "rank.tab.third_mem": "3rd Mem",
        "rank.tab.third": "3rd",
        "rank.tab.sys_cpu": "System",
        "rank.tab.app_cpu": "Apps",
        "rank.empty": "No data",
        "detail.parent": "Parent",
        "detail.open_files": "Open files",
        "detail.started": "Started",
        "chart.cpu": "CPU trend",
        "chart.memory": "Memory trend",
        "chart.category": "Category CPU",
        "chart.series.third": "Third-Party",
        "chart.series.apple": "Apple",
        "chart.history": "History",
        "chart.collecting": "Collecting…",
        "chart.points": "%d pts",
        "chart.need_samples": "Collecting history (need samples within %@)",
        "menubar.icon": "Menu bar icon",
        "menubar.mode": "Mode",

        "cmd.process": "Process",
        "cmd.refresh": "Refresh",
        "cmd.show_all": "Show All",
        "cmd.only_system": "Apple System only",
        "cmd.only_app": "Apple Apps only",
        "cmd.only_third": "Third-Party only",
        "cmd.menubar": "Menu Bar",
        "cmd.about": "About SwiftInsight",

        "mb.open_main": "Open Main Window",
        "mb.quit_app": "Quit SwiftInsight",
        "mb.github": "GitHub…",
        "mb.launch_at_login": "Launch at Login",
        "mb.composition": "Breakdown",
        "mb.tops": "Top usage",
        "mb.full_window": "Full Window",
        "mb.quit": "Quit",
        "mb.activity_monitor": "Activity Monitor",
        "mb.system_info": "System Information",
        "mb.none": "None",
        "mb.pressure_tip": "Kernel level %d · est. %.0f%% from memorystatus_level",
        "mb.cores_tip": "%d cores · E %.0f%% · P %.0f%%",
        "mb.cores_avg": "%d cores · avg %.0f%%",
        "file.kind.file": "File",
        "file.kind.socket": "Socket",
        "file.kind.pipe": "Pipe",
        "file.note.fail": "Cannot read open files (permission or process exited)",
        "file.note.count": "%d open files/sockets",
    ]
}
