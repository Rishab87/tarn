import SwiftUI

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var files: [Attachment] = []
    @FocusState private var focused: Bool

    private var draftKey: String { chat?.id ?? "new" }

    var body: some View {
        Group {
            if model.activeModelId == nil {
                LockedComposer()
            } else {
                editor
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tarnAttach)) { note in
            if let f = note.object as? [Attachment] { files = Array((files + f).prefix(10)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tarnSeed)) { note in
            guard chat == nil, let (prompt, attach) = note.object as? (String, Bool) else { return }
            model.drafts[draftKey] = prompt
            focused = true
            if attach { files = Array((files + model.pickAttachments()).prefix(10)) }
        }
    }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.drafts[draftKey] = $0 })
    }

    private var answering: Bool { chat.map { model.isAnswering($0.id) } ?? false }

    private var canSend: Bool {
        !answering && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !files.isEmpty || chat?.folder != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let folder = chat?.folder {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").font(.caption)
                                Text((folder as NSString).lastPathComponent).font(.callout)
                                Button { model.stopSharingFolder() } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Stop sharing this folder")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.water.opacity(0.14), in: .capsule)
                            .help(folder)
                        }
                        ForEach(files) { f in FileChip(attachment: f) { files.removeAll { $0.id == f.id } } }
                    }
                }
            }
            TextField(chat?.folder != nil ? "Ask Tarn to work with your folder…" : "Ask Tarn anything…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...10)
                .focused($focused)
                .onKeyPress(keys: ["v"], phases: .down) { press in
                    // ⌘V with an image or file on the clipboard attaches it instead of pasting text.
                    guard press.modifiers.contains(.command) else { return .ignored }
                    let pb = NSPasteboard.general
                    let hasText = pb.string(forType: .string) != nil
                    let hasFiles = (pb.types ?? []).contains(.fileURL)
                    guard hasFiles || !hasText else { return .ignored }
                    let pasted = Attachments.fromPasteboard(pb)
                    guard !pasted.isEmpty else { return .ignored }
                    files = Array((files + pasted).prefix(10))
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        draft.wrappedValue += "\n"
                        return .handled
                    }
                    send()
                    return .handled
                }
                .padding(.top, 2)
            HStack(spacing: 2) {
                ToolbarIcon(symbol: "paperclip", help: "Attach images, PDFs or text files") {
                    files = Array((files + model.pickAttachments()).prefix(10))
                }
                ToolbarIcon(symbol: "folder", help: "Let Tarn work in a folder", on: chat?.folder != nil) { model.shareFolder() }
                ToolbarIcon(symbol: "globe", help: model.settings.webSearch ? "Web search is on" : "Web search is off", on: model.settings.webSearch) {
                    model.update { $0.webSearch.toggle() }
                }
                if Catalog.model(model.activeModelId)?.thinking == .optional {
                    ToolbarIcon(symbol: "brain", help: model.settings.thinking ? "Thinks before answering (slower, better for hard questions)" : "Answers right away",
                                on: model.settings.thinking) {
                        model.update { $0.thinking.toggle() }
                    }
                }
                Spacer()
                ModelPicker()
                if answering, let chat {
                    Button { model.stop(chat.id) } label: { Image(systemName: "stop.fill").font(.system(size: 11)) }
                        .buttonStyle(SendButtonStyle())
                        .help("Stop")
                        .keyboardShortcut(".", modifiers: .command)
                        .accessibilityLabel("Stop answering")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up") }
                        .buttonStyle(SendButtonStyle())
                        .disabled(!canSend)
                        .help("Send (Return)")
                        .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onAppear { focused = true }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.wrappedValue
        let sent = files
        model.drafts[draftKey] = ""
        files = []
        if !model.send(text, attachments: sent) {
            model.drafts[draftKey] = text
            files = sent
        } else if draftKey == "new" {
            model.drafts["new"] = ""
        }
    }
}

private struct ToolbarIcon: View {
    let symbol: String
    let help: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .foregroundStyle(on ? Color.water : .secondary)
                .background(on ? Color.water.opacity(0.13) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Shown instead of the text box until a model is downloaded and checked.
private struct LockedComposer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rec = model.picks.recommended
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                switch model.download {
                case .downloading(let p):
                    let tier = model.picks.tier(of: p.modelId) ?? .recommended
                    let eta = p.bytesPerSec > 0 ? Fmt.eta(Double(p.total - p.received) / p.bytesPerSec) : ""
                    Text("Getting your AI ready · \(Int(p.fraction * 100))%").font(.headline)
                    Text("\(Fmt.tierLabel(tier, model.picks.pick(tier))): \(Fmt.bytes(p.received)) of \(Fmt.bytes(p.total))\(eta.isEmpty ? "" : ", \(eta) left"). Chat unlocks when it’s done.")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    ProgressView(value: p.fraction).tint(Color.water).padding(.top, 4)
                case .verifying:
                    Text("Checking the download…").font(.headline)
                    Text("Almost there.").font(.callout).foregroundStyle(.secondary)
                case .paused(let p):
                    Text("Download paused").font(.headline)
                    Text("\(Fmt.bytes(p.received)) of \(Fmt.bytes(p.total))").font(.callout).foregroundStyle(.secondary)
                case .failed(_, let message, _):
                    Text("The download stopped").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                case .idle:
                    Text("Tarn needs its AI to chat").font(.headline)
                    Text(rec.map { "Download \(Fmt.tierLabel(.recommended, $0)), \(Fmt.bytes($0.model.file.size))." } ?? "No AI fits this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch model.download {
            case .downloading: Button("Pause") { model.pauseDownload() }.buttonStyle(.glass)
            case .paused(let p): Button("Resume") { model.startDownload(p.modelId, vision: p.isVision) }.primaryButton()
            case .failed(let id, _, let vision): Button("Try again") { model.startDownload(id, vision: vision) }.primaryButton()
            case .idle:
                if let rec { Button("Download") { model.startDownload(rec.model.id) }.primaryButton() }
            case .verifying: EmptyView()
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }
}

struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(Tier.allCases) { t in
                if let p = model.picks.pick(t) {
                    let installed = model.isInstalled(p.model.id)
                    let downloading = model.download.modelId == p.model.id && model.download.progress != nil
                    Button {
                        model.setTier(t)
                    } label: {
                        Text(Fmt.tierLabel(t, p) + (model.activeTier == t && installed ? "  ✓" : ""))
                        Text(installed ? (t == .bigger ? "⚠︎ Asks a lot of this Mac. Best with nothing else open." : t.blurb)
                             : downloading ? "Downloading… \(Int((model.download.progress?.fraction ?? 0) * 100))%"
                             : t == .bigger ? "⚠︎ Download · \(Fmt.bytes(p.model.file.size)) · may slow your Mac" : "Download · \(Fmt.bytes(p.model.file.size))")
                    }
                }
            }
            Divider()
            Button("Model settings…") { openSettings() }
        } label: {
            Text(Fmt.tierLabel(model.activeTier, model.picks.pick(model.activeTier))).font(.callout.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Choose your AI")
    }
}
