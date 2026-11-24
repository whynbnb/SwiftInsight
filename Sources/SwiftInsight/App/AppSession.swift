import SwiftUI
import AppKit
import Combine

/// 进程级会话：不依赖 SwiftUI Window 存活，菜单栏-only 启动也能跑
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    let monitor = ProcessMonitor()
    let controlKeyMonitor = ControlKeyMonitor()
    let menuBar = MenuBarController()
    let prefs = AppPreferences.shared
    let groupStore = ProcessGroupStore.shared

    private var didBootstrap = false
    private var languageCancellable: AnyCancellable?

    private init() {}

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        MainWindowCoordinator.bindProcessMonitor(monitor)
        controlKeyMonitor.start(processMonitor: monitor)
        monitor.onMainWindowVisibilityChange = { [weak self] visible in
            self?.controlKeyMonitor.setEnabled(visible)
        }
        monitor.start()
        controlKeyMonitor.setEnabled(monitor.mainWindowVisible)

        menuBar.onOpenMain = {
            MainWindowCoordinator.showMainWindow()
        }
        menuBar.install(monitor: monitor)
        prefs.applyTheme()

        // 启动后统一本地化一次：SwiftUI 生成的「设置…」等系统项不跟随运行时语言
        DispatchQueue.main.async {
            AppMenuLocalizer.refresh()
        }

        languageCancellable = prefs.$language
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.menuBar.refreshLocalizedUI()
                MainWindowCoordinator.reloadMainWindowContentIfNeeded()
                AboutWindowHolder.refreshLocalizedUI()
                // SwiftUI 只更新自定义菜单的标题，子项标题不会跟随；下一轮补一次
                DispatchQueue.main.async {
                    AppMenuLocalizer.refresh()
                }
            }
    }
}

/// SwiftUI `.commands` 在运行时切换语言时只刷新菜单标题，子项标题会保持旧语言。
/// 这里按命令 key 反查菜单项（匹配任一语言的标题），统一改成当前语言。
@MainActor
enum AppMenuLocalizer {
    private static let commandKeys = [
        "cmd.about",
        "cmd.settings",
        "cmd.process",
        "cmd.refresh",
        "cmd.show_all",
        "cmd.only_system",
        "cmd.only_app",
        "cmd.only_third",
        "cmd.menubar",
        "mb.open_main",
        "icon.cpu",
        "icon.memory",
        "icon.combined",
    ]

    static func refresh() {
        guard let mainMenu = NSApp.mainMenu else { return }

        var keyByTitle: [String: String] = [:]
        for key in commandKeys {
            for language in [ResolvedLanguage.zh, .en] {
                keyByTitle[L10n.string(key, language: language)] = key
            }
        }
        retitle(items: mainMenu.items, keyByTitle: keyByTitle)

        // 「设置…」由 SwiftUI 生成，标题不跟随运行时语言；用 action 识别
        for item in mainMenu.items {
            retitleSettingsItem(in: item.submenu)
        }
    }

    private static func retitle(items: [NSMenuItem], keyByTitle: [String: String]) {
        for item in items {
            if let key = keyByTitle[item.title] {
                item.title = L(key)
            }
            if let submenu = item.submenu {
                retitle(items: submenu.items, keyByTitle: keyByTitle)
            }
        }
    }

    private static func retitleSettingsItem(in menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if let action = item.action {
                let name = NSStringFromSelector(action)
                if name == "showSettingsWindow:" || name == "showPreferencesWindow:" {
                    item.title = L("cmd.settings")
                }
            }
            retitleSettingsItem(in: item.submenu)
        }
    }
}
