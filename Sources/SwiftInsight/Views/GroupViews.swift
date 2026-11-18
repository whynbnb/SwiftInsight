import SwiftUI
import AppKit

// MARK: - 侧栏分组区

/// 自定义分组列表：选择即筛选，右键可编辑 / 删除
struct CustomGroupsSection: View {
    let groups: [ProcessFilterGroup]
    let counts: [UUID: Int]
    let selectedID: UUID?
    var onSelect: (UUID?) -> Void
    var onCreate: (ProcessFilterGroup) -> UUID
    var onUpdate: (ProcessFilterGroup) -> Void
    var onDelete: (ProcessFilterGroup) -> Void

    @State private var editorContext: GroupEditorContext?
    @State private var pendingDelete: ProcessFilterGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L("sidebar.groups"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editorContext = .new
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("group.new"))
            }

            if groups.isEmpty {
                Text(L("group.empty_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            } else if groups.count <= 4 {
                groupRows
            } else {
                // 分组较多时内部滚动，避免把下方资源对比挤出窗口
                ScrollView(.vertical, showsIndicators: true) {
                    groupRows
                }
                .frame(maxHeight: 150)
            }
        }
        .sheet(item: $editorContext) { context in
            GroupEditorSheet(context: context) { saved in
                switch context {
                case .new:
                    onSelect(onCreate(saved))
                case .edit:
                    onUpdate(saved)
                }
            }
        }
        .confirmationDialog(
            L("group.delete.confirm"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("group.delete"), role: .destructive) {
                if let group = pendingDelete {
                    if selectedID == group.id { onSelect(nil) }
                    onDelete(group)
                }
                pendingDelete = nil
            }
            Button(L("alert.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            if let group = pendingDelete {
                Text(group.name)
            }
        }
    }

    private var groupRows: some View {
        VStack(spacing: 4) {
            ForEach(groups) { group in
                groupRow(group)
            }
        }
    }

    private func groupRow(_ group: ProcessFilterGroup) -> some View {
        let selected = selectedID == group.id
        return Button {
            onSelect(selected ? nil : group.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(group.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(counts[group.id] ?? 0)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.isDynamic ? L("group.kind.dynamic.help") : L("group.kind.static.help"))
        .contextMenu {
            Button(L("group.edit")) { editorContext = .edit(group) }
            Button(L("group.delete"), role: .destructive) { pendingDelete = group }
        }
    }
}

// MARK: - 表头筛选中的分组标记

struct GroupFilterChip: View {
    let group: ProcessFilterGroup
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: group.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(group.name)
                .font(.caption)
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("group.clear"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
        )
        .fixedSize()
        .help(String(format: L("group.chip.help"), group.name))
    }
}

// MARK: - 编辑器上下文

enum GroupEditorContext: Identifiable {
    case new
    case edit(ProcessFilterGroup)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let group): return group.id.uuidString
        }
    }
}

struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var onSave: (ProcessFilterGroup) -> Void

    @State private var draft: ProcessFilterGroup

    init(context: GroupEditorContext, onSave: @escaping (ProcessFilterGroup) -> Void) {
        self.onSave = onSave
        switch context {
        case .new:
            _draft = State(initialValue: ProcessFilterGroup(
                name: "",
                symbolName: ProcessFilterGroup.symbolChoices[0],
                isDynamic: true
            ))
        case .edit(let group):
            var group = group
            // 根节点必须是条件组，旧数据或异常数据统一包一层
            if group.condition.isRule {
                group.condition = GroupConditionNode(children: [group.condition])
            }
            _draft = State(initialValue: group)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupEditorView(draft: $draft)
                .padding(16)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button(L("alert.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("group.save")) {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draft.name.isEmpty { draft.name = L("group.untitled") }
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
    }
}

// MARK: - 编辑器主体

struct GroupEditorView: View {
    @Binding var draft: ProcessFilterGroup

    @State private var showAppPicker = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                iconPicker
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("group.name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.weight(.medium))
                        .focused($nameFocused)

                    Picker(L("group.type"), selection: $draft.isDynamic) {
                        Text(L("group.kind.dynamic")).tag(true)
                        Text(L("group.kind.static")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Text(draft.isDynamic ? L("group.kind.dynamic.help") : L("group.kind.static.help"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if draft.isDynamic {
                dynamicEditor
            } else {
                staticEditor
            }
        }
        .onAppear { nameFocused = true }
    }

    // MARK: Icon

    private var iconPicker: some View {
        HStack(spacing: 4) {
            ForEach(ProcessFilterGroup.symbolChoices, id: \.self) { symbol in
                let selected = draft.symbolName == symbol
                Button {
                    draft.symbolName = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                        )
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Dynamic condition tree

    private var dynamicEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("group.logic"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $draft.condition.combinator) {
                    ForEach(GroupCombinator.allCases) { combinator in
                        Text(combinator.title).tag(combinator)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 196)
                .help(L("group.logic.hint"))
            }

            ScrollView {
                GroupConditionEditor(
                    node: $draft.condition,
                    depth: 0,
                    isRoot: true,
                    onRemove: nil
                )
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 300)

            Text(L("group.logic.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("group.rule.wildcard.hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Static members

    private var staticEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("group.members")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAppPicker = true
                } label: {
                    Label(L("group.member.add"), systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if draft.members.isEmpty {
                Text(L("group.member.empty"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(draft.members) { member in
                            memberRow(member)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .sheet(isPresented: $showAppPicker) {
            GroupAppPickerSheet(existing: draft.members) { member in
                if !draft.members.contains(where: { $0.id == member.id }) {
                    draft.members.append(member)
                }
            }
        }
    }

    private func memberRow(_ member: GroupMember) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessClassifier.icon(for: member.path, name: member.name))
                .resizable()
                .frame(width: 16, height: 16)
            Text(member.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let bid = member.bundleID {
                Text(bid)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Button {
                draft.members.removeAll { $0.id == member.id }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("group.remove"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - 条件树编辑器（递归）

/// 一行规则，或一个可嵌套 / 可取反的条件组。
private struct GroupConditionEditor: View {
    @Binding var node: GroupConditionNode
    let depth: Int
    let isRoot: Bool
    let onRemove: (() -> Void)?

    private static let maxDepth = 4

    var body: some View {
        if node.isRule {
            ruleRow
        } else {
            groupBox
        }
    }

    // MARK: Rule leaf

    private var ruleKind: Binding<GroupRuleKind> {
        Binding(
            get: { node.rule?.kind ?? .bundlePattern },
            set: { node.rule?.kind = $0 }
        )
    }

    private var ruleValue: Binding<String> {
        Binding(
            get: { node.rule?.value ?? "" },
            set: { node.rule?.value = $0 }
        )
    }

    private var ruleRow: some View {
        HStack(spacing: 6) {
            negateButton

            Picker("", selection: ruleKind) {
                ForEach(GroupRuleKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 142)

            TextField(node.rule?.kind.placeholder ?? "", text: ruleValue)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

            if !isRoot, let onRemove {
                removeButton(help: L("group.remove"), action: onRemove)
            }
        }
    }

    // MARK: Nested condition group

    private var groupBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isRoot {
                HStack(spacing: 6) {
                    negateButton

                    Picker("", selection: $node.combinator) {
                        ForEach(GroupCombinator.allCases) { combinator in
                            Text(combinator.title).tag(combinator)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 168)

                    Spacer()

                    if let onRemove {
                        removeButton(help: L("group.condition.remove"), action: onRemove)
                    }
                }
            }

            if node.children.isEmpty {
                Text(L("group.condition.empty"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, isRoot ? 0 : 2)
            } else {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                    GroupConditionEditor(
                        node: $node.children[index],
                        depth: depth + 1,
                        isRoot: false,
                        onRemove: { node.children.removeAll { $0.id == child.id } }
                    )
                }
            }

            HStack(spacing: 10) {
                Button {
                    node.children.append(GroupConditionNode(rule: GroupRule()))
                } label: {
                    Label(L("group.rule.add"), systemImage: "plus")
                }

                if depth < Self.maxDepth {
                    Button {
                        node.children.append(GroupConditionNode())
                    } label: {
                        Label(L("group.condition.add_group"), systemImage: "square.stack.3d.down.right")
                    }
                }

                Spacer(minLength: 0)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(isRoot ? 0 : 8)
        .background {
            if !isRoot {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
    }

    // MARK: Shared

    private var negateButton: some View {
        Button {
            node.isNegated.toggle()
        } label: {
            Text(L("group.logic.not.short"))
                .font(.system(size: 9, weight: .bold))
                .frame(width: 26, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(node.isNegated ? Color.red.opacity(0.18) : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(node.isNegated ? Color.red : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("group.logic.not.help"))
    }

    private func removeButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 应用选择器

struct GroupAppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var monitor: ProcessMonitor

    let existing: [GroupMember]
    var onPick: (GroupMember) -> Void

    @State private var query = ""
    @State private var added: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("group.member.add"))
                    .font(.headline)
                Spacer()
                Button(L("group.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            TextField(L("group.search.apps"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            List(filtered, id: \.id) { candidate in
                HStack(spacing: 8) {
                    Image(nsImage: ProcessClassifier.icon(for: candidate.path, name: candidate.name))
                        .resizable()
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.name)
                            .lineLimit(1)
                        Text(subtitle(candidate))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    let isAdded = added.contains(candidate.id)
                        || existing.contains(where: { $0.id == candidate.id })
                    Button(isAdded ? L("group.added") : L("group.add")) {
                        guard !isAdded else { return }
                        let member = GroupMember(
                            id: candidate.id,
                            name: candidate.name,
                            bundleID: candidate.bundleID,
                            path: candidate.path
                        )
                        added.insert(candidate.id)
                        onPick(member)
                    }
                    .disabled(isAdded)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: 480, height: 420)
    }

    private var candidates: [GroupAppCandidate] {
        ProcessGroupMatcher.appCandidates(from: monitor.processes)
    }

    private var filtered: [GroupAppCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.lowercased().contains(q)
                || ($0.bundleID?.lowercased().contains(q) ?? false)
                || $0.path.lowercased().contains(q)
        }
    }

    private func subtitle(_ candidate: GroupAppCandidate) -> String {
        var parts: [String] = []
        if let bid = candidate.bundleID { parts.append(bid) }
        parts.append(String(format: L("group.process_count"), candidate.processCount))
        return parts.joined(separator: " · ")
    }
}
