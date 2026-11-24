import SwiftUI
import AppKit

@main
struct SwiftInsightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 观察语言 / 主题等偏好：切换语言后重建 App 菜单命令
    @StateObject private var prefs = AppPreferences.shared

    var body: some Scene {
        // 无 WindowGroup：仅菜单栏启动时不创建主窗口，从根上消除闪屏
        // 主窗口由 MainWindowCoordinator 按需以 AppKit 创建
        // 注意：不要在属性初始化里碰 AppSession（NSApp 可能尚未就绪）
        Settings {
            SettingsRootView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("cmd.about")) {
                    openAboutWindow()
                }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu(L("cmd.process")) {
                Button(L("cmd.refresh")) {
                    AppSession.shared.monitor.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(L("cmd.show_all")) {
                    let monitor = AppSession.shared.monitor
                    monitor.selectGroup(nil)
                    monitor.selectCategory(nil)
                    monitor.processScope = .all
                }
                Button(L("cmd.only_system")) {
                    AppSession.shared.monitor.selectCategory(.appleSystem)
                }
                Button(L("cmd.only_app")) {
                    AppSession.shared.monitor.selectCategory(.appleApp)
                }
                Button(L("cmd.only_third")) {
                    AppSession.shared.monitor.selectCategory(.thirdParty)
                }
            }
            CommandMenu(L("cmd.menubar")) {
                ForEach(MenuBarIconMode.allCases) { mode in
                    Button(mode.displayName) {
                        AppSession.shared.menuBar.iconMode = mode
                    }
                }
            }
            CommandGroup(after: .windowList) {
                Button(L("mb.open_main")) {
                    MainWindowCoordinator.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    private func openAboutWindow() {
        let session = AppSession.shared
        session.bootstrapIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 显式持有，避免关闭后无主窗口对象无法回收 / 重复创建
        if let existing = AboutWindowHolder.window {
            existing.makeKeyAndOrderFront(nil)
            MainWindowCoordinator.updateDockVisibility()
            return
        }

        let view = AboutView()
            .environmentObject(session.prefs)
            .id(session.prefs.language)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("about-swiftinsight")
        window.title = L("cmd.about")
        window.styleMask = NSWindow.StyleMask([.titled, .closable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 400, height: 360))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        AboutWindowHolder.window = window
        MainWindowCoordinator.updateDockVisibility()
    }
}

/// 关于窗口单例持有：关闭后复用，避免每次打开都新建并泄漏
@MainActor
enum AboutWindowHolder {
    static var window: NSWindow?

    /// 语言切换后更新窗口标题；内容由 AboutView 自己观察偏好刷新
    static func refreshLocalizedUI() {
        window?.title = L("cmd.about")
    }
}

/// Settings 在真正打开时再取 session，避免启动期过早初始化
private struct SettingsRootView: View {
    var body: some View {
        let session = AppSession.shared
        SettingsView()
            .environmentObject(session.monitor)
            .environmentObject(session.menuBar)
            .environmentObject(session.prefs)
            .environmentObject(session.groupStore)
            .background(SettingsWindowAccessor())
            .onAppear {
                session.bootstrapIfNeeded()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                MainWindowCoordinator.updateDockVisibility()
            }
    }
}

/// 给 SwiftUI 设置窗口打上稳定标识：标题会跟着标签页变化，不能靠标题识别
private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(MainWindowCoordinator.settingsWindowID)
            MainWindowCoordinator.updateDockVisibility()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.identifier?.rawValue != MainWindowCoordinator.settingsWindowID {
                window.identifier = NSUserInterfaceItemIdentifier(MainWindowCoordinator.settingsWindowID)
            }
        }
    }
}
