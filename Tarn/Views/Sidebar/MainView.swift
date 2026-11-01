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

    private var groups: [(String, [ChatSummary])] {
        let list = search.isEmpty ? model.summaries : model.store.search(search)
        if !search.isEmpty { return list.isEmpty ? [] : [("Results", list)] }
        var out: [(String, [ChatSummary])] = []
        let pinned = list.filter(\.pinned)
        if !pinned.isEmpty { out.append(("Pinned", pinned)) }
        for c in list where !c.pinned {
            let label = Fmt.dayGroup(c.updatedAt)
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(c) } else { out.append((label, [c])) }
        }
        return out
    }

    var body: some View {
        let selection = Binding<String?>(get: { model.currentId }, set: { model.openChat($0) })
        List(selection: selection) {
            Button { model.newChat() } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .help("New chat (⌘N)")
            if groups.isEmpty {
                Text(search.isEmpty ? "Your chats will appear here. They’re saved on this Mac only." : "No chats match that.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            ForEach(groups, id: \.0) { label, chats in
                Section(label) {
                    ForEach(chats) { c in ChatRow(chat: c).tag(c.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

private struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: ChatSummary
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
            }
        }
        .contextMenu {
            Button("Rename") { title = chat.title; renaming = true }
            Button(chat.pinned ? "Unpin" : "Pin") { model.togglePin(chat.id) }
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
