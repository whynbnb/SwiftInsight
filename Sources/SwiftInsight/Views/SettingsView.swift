import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var menuBar: MenuBarController
    @EnvironmentObject private var prefs: AppPreferences
    @EnvironmentObject private var groupStore: ProcessGroupStore

    @State private var editingGroup: ProcessFilterGroup?
    @State private var helperBusy = false
    @State private var helperMessage: String?
    @State private var helperMessageIsError = false
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var launchAtLoginMessageIsError = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(L("settings.tab.general"), systemImage: "gearshape")
                }

            refreshTab
                .tabItem {
                    Label(L("settings.tab.refresh"), systemImage: "arrow.clockwise")
                }

            groupsTab
                .tabItem {
                    Label(L("settings.tab.groups"), systemImage: "square.stack.3d.up")
                }

            menuBarTab
                .tabItem {
                    Label(L("settings.tab.menubar"), systemImage: "menubar.rectangle")
                }

            helperTab
                .tabItem {
                    Label(L("settings.tab.helper"), systemImage: "lock.shield")
                }

            aboutTab
                .tabItem {
                    Label(L("settings.tab.about"), systemImage: "info.circle")
                }
        }
        .frame(width: 560, height: 460)
        .id(prefs.language)
        .onAppear {
            monitor.refreshHelperStatus()
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section(L("settings.appearance")) {
                Picker(L("settings.language"), selection: $prefs.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text(L("settings.language.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.theme"), selection: $prefs.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                Text(L("settings.theme.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.detail_position"), selection: $prefs.detailPanelPosition) {
                    ForEach(DetailPanelPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                Text(L("settings.detail_position.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.view_state")) {
                Toggle(L("settings.remember_view_state"), isOn: $prefs.rememberViewState)
                Text(L("settings.remember_view_state.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.launch_at_login")) {
                Toggle(L("settings.launch_at_login"), isOn: launchAtLoginBinding)
                    .disabled(!LaunchAtLogin.isAvailable)
                Text(L("settings.launch_at_login.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !LaunchAtLogin.isAvailable {
                    Text(L("settings.launch_at_login.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(launchAtLoginMessageIsError ? Color.red : Color.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var refreshTab: some View {
        Form {
            Section(L("settings.refresh")) {
                Picker(L("settings.refresh_interval"), selection: $monitor.refreshInterval) {
                    Text(L("settings.1s")).tag(1.0)
                    Text(L("settings.2s")).tag(2.0)
                    Text(L("settings.5s")).tag(5.0)
                    Text(L("settings.10s")).tag(10.0)
                }
                Text(L("settings.refresh.main.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.pause_refresh")) {
                LabeledContent(L("settings.pause_refresh")) {
                    Text(L("settings.hold_control"))
                        .foregroundStyle(.secondary)
                }
                Text(L("settings.pause.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var groupsTab: some View {
        List {
            Section {
                ForEach([CategoryFilterItem.appleSystem, .appleApp, .thirdParty], id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(item.title)
                        Spacer()
                        Toggle("", isOn: categoryVisibilityBinding(item))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            } header: {
                Text(L("settings.groups.builtin"))
            } footer: {
                Text(L("settings.groups.builtin.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if groupStore.groups.isEmpty {
                    Text(L("settings.groups.custom.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(groupStore.groups.enumerated()), id: \.element.id) { index, group in
                        customGroupRow(group, index: index)
                    }
                }
            } header: {
                Text(L("settings.groups.custom"))
            } footer: {
                Text(L("settings.groups.custom.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .sheet(item: $editingGroup) { group in
            GroupEditorSheet(context: .edit(group)) { saved in
                groupStore.update(saved)
            }
        }
    }

    private func customGroupRow(_ group: ProcessFilterGroup, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .lineLimit(1)
                Text(group.isDynamic ? L("group.kind.dynamic") : L("group.kind.static"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                groupStore.moveGroup(id: group.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L("settings.groups.move_up"))

            Button {
                groupStore.moveGroup(id: group.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= groupStore.groups.count - 1)
            .help(L("settings.groups.move_down"))

            Button {
                editingGroup = group
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L("group.edit"))

            Toggle("", isOn: groupVisibilityBinding(group))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(L("settings.groups.visibility"))
        }
        .opacity(group.isHidden ? 0.55 : 1)
    }

    private func categoryVisibilityBinding(_ item: CategoryFilterItem) -> Binding<Bool> {
        Binding(
            get: { !prefs.isCategoryHidden(item) },
            set: { visible in
                prefs.setCategoryHidden(item, hidden: !visible)
                if !visible, CategoryFilterItem.from(category: monitor.categoryFilter) == item {
                    monitor.selectCategory(nil)
                }
            }
        )
    }

    private func groupVisibilityBinding(_ group: ProcessFilterGroup) -> Binding<Bool> {
        Binding(
            get: {
                groupStore.groups.first(where: { $0.id == group.id })?.isHidden == false
            },
            set: { visible in
                guard var current = groupStore.groups.first(where: { $0.id == group.id }) else { return }
                current.isHidden = !visible
                groupStore.update(current)
                if !visible, monitor.groupFilterID == group.id {
                    monitor.selectGroup(nil)
                }
                if !visible, editingGroup?.id == group.id {
                    editingGroup = nil
                }
            }
        )
    }

    private var menuBarTab: some View {
        Form {
            Section(L("settings.icon_mode")) {
                Picker(L("settings.icon_mode"), selection: $menuBar.iconMode) {
                    ForEach(MenuBarIconMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(L("settings.menubar.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.menubar.icon_interval")) {
                Picker(L("settings.menubar.icon_interval"), selection: $monitor.menuBarIconInterval) {
                    Text(L("settings.2s")).tag(2.0)
                    Text(L("settings.3s")).tag(3.0)
                    Text(L("settings.5s")).tag(5.0)
                    Text(L("settings.10s")).tag(10.0)
                }
                Text(L("settings.menubar.icon.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.menubar.panel_interval")) {
                Picker(L("settings.menubar.panel_interval"), selection: $monitor.menuBarPanelInterval) {
                    Text(L("settings.1s")).tag(1.0)
                    Text(L("settings.2s")).tag(2.0)
                    Text(L("settings.3s")).tag(3.0)
                    Text(L("settings.5s")).tag(5.0)
                }
                Text(L("settings.menubar.panel.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.menubar.top_mode"), selection: $prefs.menuBarDisplayMode) {
                    ForEach(ListDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(L("settings.menubar.top_mode.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.menubar.top_count"), selection: $prefs.menuBarTopCount) {
                    ForEach(Array(AppPreferences.menuBarTopCountRange), id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                Text(L("settings.menubar.top_count.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var helperTab: some View {
        Form {
            Section(L("settings.helper")) {
                LabeledContent("Helper") {
                    Text(helperStatusText)
                        .foregroundStyle(helperStatusColor)
                }
                Text(L("settings.helper.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !HelperInstaller.hasBundledHelper {
                    Text(L("settings.helper.no_bundle"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 12) {
                    Button(L("settings.helper.install_btn")) {
                        runHelperAction(.install)
                    }
                    .disabled(helperBusy || !HelperInstaller.hasBundledHelper || monitor.privilegedHelperRoot)

                    Button(L("settings.helper.uninstall_btn"), role: .destructive) {
                        runHelperAction(.uninstall)
                    }
                    .disabled(helperBusy || !monitor.privilegedHelperInstalled)

                    Button(L("settings.helper.recheck")) {
                        monitor.refreshHelperStatus()
                        helperMessage = nil
                    }
                    .disabled(helperBusy)
                }

                if let helperMessage {
                    Text(helperMessage)
                        .font(.caption)
                        .foregroundStyle(helperMessageIsError ? Color.red : Color.secondary)
                }

                Text(L("settings.helper.path_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            Section(L("settings.classification")) {
                Text(L("settings.classification.intro"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label(L("settings.classification.system"), systemImage: "gearshape.2.fill")
                    .font(.callout)
                Label(L("settings.classification.app"), systemImage: "apple.logo")
                    .font(.callout)
                Label(L("settings.classification.third"), systemImage: "app.badge")
                    .font(.callout)
            }

            Section(L("settings.app")) {
                LabeledContent(L("settings.purpose")) {
                    Text(L("settings.purpose.value"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let version = AppInfo.version {
                    LabeledContent(L("settings.version")) {
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L("settings.bundle_id")) {
                    Text(Bundle.main.bundleIdentifier ?? "me.whynbnb.SwiftInsight")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(L("settings.license")) {
                    Text("MIT")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings / Helper

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                launchAtLoginMessage = nil
                let ok = LaunchAtLogin.setEnabled(newValue)
                launchAtLoginEnabled = LaunchAtLogin.isEnabled
                if !ok {
                    launchAtLoginMessageIsError = true
                    launchAtLoginMessage = L("settings.launch_at_login.failed")
                }
            }
        )
    }

    private var helperStatusText: String {
        if monitor.privilegedHelperRoot {
            return L("settings.helper.ok")
        }
        if monitor.privilegedHelperInstalled {
            return L("settings.helper.not_root")
        }
        if HelperInstaller.hasBundledHelper {
            return L("settings.helper.bundled")
        }
        return L("settings.helper.missing")
    }

    private var helperStatusColor: Color {
        if monitor.privilegedHelperRoot { return .green }
        if HelperInstaller.hasBundledHelper { return .orange }
        return .secondary
    }

    private enum HelperAction {
        case install
        case uninstall
    }

    private func runHelperAction(_ action: HelperAction) {
        helperBusy = true
        helperMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: HelperInstaller.Outcome
            switch action {
            case .install: outcome = HelperInstaller.install()
            case .uninstall: outcome = HelperInstaller.uninstall()
            }
            DispatchQueue.main.async {
                helperBusy = false
                monitor.refreshHelperStatus()
                switch outcome {
                case .success:
                    helperMessageIsError = false
                    helperMessage = action == .install
                        ? L("settings.helper.install_ok")
                        : L("settings.helper.uninstall_ok")
                case .cancelled:
                    helperMessageIsError = false
                    helperMessage = L("settings.helper.cancelled")
                case .missingBundle:
                    helperMessageIsError = true
                    helperMessage = L("settings.helper.no_bundle")
                case .failed(let msg):
                    helperMessageIsError = true
                    helperMessage = String(format: L("settings.helper.failed"), msg)
                }
            }
        }
    }
}
