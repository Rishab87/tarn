import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.sidebarVisible) {
            SidebarView(search: search)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .searchable(text: $search, placement: .sidebar, prompt: "Search chats")
                .searchFocused($searchFocused)
        } detail: {
            ChatView()
        }
        .onChange(of: model.searchOpen) { _, open in
            if open {
                model.sidebarVisible = .all
                searchFocused = true
                model.searchOpen = false
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var prompt: FolderPrompt?
    @State private var folderName = ""

    /// A chat in a folder shows only inside it, pinned first, then newest. The rest fill the
    /// date sections.
    static func split(_ summaries: [ChatSummary], groups: [ChatGroup]) -> (inFolder: [String: [ChatSummary]], rest: [ChatSummary]) {
        let ids = Set(groups.map(\.id))
        var inFolder: [String: [ChatSummary]] = [:]
        var rest: [ChatSummary] = []
        for c in summaries {
            if let g = c.groupId, ids.contains(g) { inFolder[g, default: []].append(c) } else { rest.append(c) }
        }
        for (g, chats) in inFolder { inFolder[g] = chats.filter(\.pinned) + chats.filter { !$0.pinned } }
        return (inFolder, rest)
    }

    /// Date sections, or one "Results" section while searching (results include chats in folders).
    private func sections(_ rest: [ChatSummary]) -> [(String, [ChatSummary])] {
        if !search.isEmpty {
            let list = model.store.search(search)
            return list.isEmpty ? [] : [("Results", list)]
        }
        var out: [(String, [ChatSummary])] = []
        let pinned = rest.filter(\.pinned)
        if !pinned.isEmpty { out.append(("Pinned", pinned)) }
        for c in rest where !c.pinned {
            let label = Fmt.dayGroup(c.updatedAt)
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(c) } else { out.append((label, [c])) }
        }
        return out
    }

    var body: some View {
        // nil is ignored: a row can vanish (its folder collapses) without the user picking another
        // chat. "New chat" is what closes the open one.
        let selection = Binding<String?>(get: { model.currentId }, set: { if let id = $0 { model.openChat(id) } })
        let split = Self.split(model.summaries, groups: model.groups)
        let sections = sections(split.rest)
        List(selection: selection) {
            Button { model.newChat() } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .help("New chat (⌘N)")
            Button { ask(.create(moving: nil)) } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            if search.isEmpty, !model.groups.isEmpty {
                Section("Folders") {
                    // Flat rows (folder header, then its chats indented), not a DisclosureGroup: the
                    // outline view behind a disclosure group left ghost rows when the last chat of a
                    // date section moved into an open folder.
                    ForEach(model.groups) { g in
                        FolderHeader(group: g, rename: { ask(.rename(g)) })
                        if !g.collapsed {
                            ForEach(split.inFolder[g.id] ?? [], id: \.inFolderRowID) { c in
                                ChatRow(chat: c, folders: model.groups, newFolder: { ask(.create(moving: c.id)) })
                                    .padding(.leading, 18)
                                    .tag(c.id)
                            }
                        }
                    }
                }
            }
            if search.isEmpty ? model.summaries.isEmpty : sections.isEmpty {
                Text(search.isEmpty ? "Your chats will appear here. They’re saved on this Mac only." : "No chats match that.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            ForEach(sections, id: \.0) { label, chats in
                Section(label) {
                    ForEach(chats) { c in
                        ChatRow(chat: c, folders: model.groups, newFolder: { ask(.create(moving: c.id)) }).tag(c.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            TextField("Name", text: $folderName)
            Button(p.button) { commit(p) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func ask(_ p: FolderPrompt) {
        if case .rename(let g) = p { folderName = g.name } else { folderName = "" }
        prompt = p
    }

    private func commit(_ p: FolderPrompt) {
        switch p {
        case .create(let chatId): model.createGroup(folderName, moving: chatId)
        case .rename(let g): model.renameGroup(g.id, folderName)
        }
    }
}

/// The name prompt for a new or renamed folder.
private enum FolderPrompt {
    /// `moving`: the chat to file in the new folder, when started from that chat's menu.
    case create(moving: String?)
    case rename(ChatGroup)

    var title: String {
        switch self {
        case .create: "New folder"
        case .rename: "Rename folder"
        }
    }

    var button: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }
}

/// A folder in the sidebar: click to open or close it, drop chats on it, right-click to rename
/// or delete.
private struct FolderHeader: View {
    @Environment(AppModel.self) private var model
    let group: ChatGroup
    let rename: () -> Void
    @State private var confirmDelete = false
    @State private var dropTargeted = false

    var body: some View {
        Button { model.setGroupCollapsed(group.id, !group.collapsed) } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .frame(width: 12)
                Label(group.name, systemImage: "folder")
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(group.name)
        .accessibilityLabel("\(group.name) folder, \(group.collapsed ? "closed" : "open")")
        .background(dropTargeted ? Color.water.opacity(0.14) : .clear, in: .rect(cornerRadius: 6))
        .dropDestination(for: String.self) { ids, _ in
            model.moveChats(ids, to: group.id)
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Rename") { rename() }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(group.name)”?", isPresented: $confirmDelete) {
            Button("Delete folder", role: .destructive) { model.deleteGroup(group.id) }
        } message: {
            Text("Its chats move back to your chat list.")
        }
        .selectionDisabled()
    }
}

private struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: ChatSummary
    /// Every folder, for "Move to folder".
    let folders: [ChatGroup]
    /// Opens the new-folder prompt for this chat.
    let newFolder: () -> Void
    @State private var renaming = false
    @State private var title = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if renaming {
                TextField("Chat name", text: $title)
                    .textFieldStyle(.plain)
                    .onSubmit { commit() }
                    .onExitCommand { renaming = false }
            } else {
                Text(chat.title).lineLimit(1).help(chat.preview.isEmpty ? chat.title : chat.preview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .draggable(chat.id)
            }
        }
        .contextMenu {
            Button("Rename") { title = chat.title; renaming = true }
            Button(chat.pinned ? "Unpin" : "Pin") { model.togglePin(chat.id) }
            Menu("Move to folder") {
                ForEach(folders) { g in
                    Button(g.name) { model.moveChat(chat.id, to: g.id) }.disabled(g.id == chat.groupId)
                }
                if !folders.isEmpty { Divider() }
                Button("New folder…") { newFolder() }
            }
            if folders.contains(where: { $0.id == chat.groupId }) {
                Button("Remove from folder") { model.moveChat(chat.id, to: nil) }
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(chat.title)”?", isPresented: $confirmDelete) {
            Button("Delete chat", role: .destructive) { model.deleteChat(chat.id) }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func commit() {
        renaming = false
        model.renameChat(chat.id, title)
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.activeModelId == nil ? "Tarn’s AI isn’t installed yet" : "\(tierLabel) runs on this Mac")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings (⌘,)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tierLabel: String {
        Fmt.tierLabel(model.activeTier, model.picks.pick(model.activeTier))
    }

    /// Short enough for a narrow sidebar; the full model name is in the tooltip and the composer.
    private var statusText: String {
        if model.activeModelId == nil {
            if case .downloading(let p) = model.download { return "Downloading · \(Int(p.fraction * 100))%" }
            return "No AI yet"
        }
        switch model.engineState {
        case .ready: return model.engine.likelyAsleep ? "Resting" : "Ready"
        case .starting: return "Waking up"
        case .failed: return "Stopped"
        case .stopped: return "Resting"
        }
    }

    private var dotColor: Color {
        switch model.engineState {
        case .ready: .green
        case .starting: .water
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let t = model.toast {
            Text(t.text)
                .foregroundStyle(t.isError ? Color.red : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

private extension ChatSummary {
    var inFolderRowID: String { "in-folder/" + id }
}
