import MarkdownUI
import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    @State private var pinnedToBottom = true

    var body: some View {
        let last = chat.messages.last
        let lastSize = last.map { m in m.blocks.reduce(0) { n, b in
            switch b {
            case .text(let t): n + t.count
            case .thinking(let t, _): n + t.count
            case .tool(let t): n + 1 + (t.result?.count ?? 0) + t.status.rawValue.count
            }
        } } ?? 0
        ScrollViewReader { proxy in
            ScrollView {
                // Short chats fill the visible height with the messages at the bottom. Leaving the
                // space empty instead lets macOS paint a lighter band above them in dark mode.
                ZStack(alignment: .bottom) {
                Color.clear.containerRelativeFrame(.vertical)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chat.messages) { m in
                        if m.role == .user {
                            UserMessageView(chat: chat, message: m)
                        } else {
                            AssistantMessageView(chat: chat, message: m, isLast: m.id == last?.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .frame(maxWidth: .infinity)
                }
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, atBottom in
                pinnedToBottom = atBottom
            }
            .onChange(of: lastSize) {
                if pinnedToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.messages.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.id) {
                pinnedToBottom = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

private struct UserMessageView: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let message: Message
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let files = message.attachments, !files.isEmpty {
                let images = files.filter { $0.kind == .image }
                if !images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(images) { img in
                            if let url = Attachments.imageURL(img), let ns = NSImage(contentsOf: url) {
                                Image(nsImage: ns)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: images.count == 1 ? 260 : 150, height: images.count == 1 ? 180 : 110)
                                    .clipShape(.rect(cornerRadius: 14))
                                    .accessibilityLabel(img.name)
                            }
                        }
                    }
                }
                let others = files.filter { $0.kind != .image }
                if !others.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(others) { f in FileChip(attachment: f) }
                    }
                }
            }
            if editing {
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("Edit message", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...12)
                        .padding(12)
                        .background(Color.bubble, in: .rect(cornerRadius: 16))
                    HStack {
                        Button("Cancel") { editing = false }.buttonStyle(.borderless)
                        Button("Send") {
                            editing = false
                            model.editAndResend(chat.id, messageId: message.id, text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .primaryButton()
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .frame(maxWidth: 600)
            } else {
                Text(message.text)
                    .font(.system(size: 14.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Color.bubble, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18))
                    .frame(maxWidth: 600, alignment: .trailing)
                HStack(spacing: 2) {
                    CopyButton(text: message.text)
                    if !chat.isAnswering {
                        IconButton(symbol: "pencil", help: "Edit") { draft = message.text; editing = true }
                    }
                }
                .opacity(hover ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 22)
        .padding(.bottom, 4)
        .onHover { hover = $0 }
    }
}

private struct AssistantMessageView: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let message: Message
    let isLast: Bool
    @State private var hover = false

    var body: some View {
        let streaming = message.status == .streaming
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { i, block in
                BlockView(block: block, live: streaming && i == message.blocks.count - 1)
            }
            if streaming, waiting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(waitingText).foregroundStyle(.secondary).font(.callout)
                }
                .padding(.vertical, 4)
            }
            if message.status == .error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                    Text(message.error ?? "Something went wrong.").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if isLast { Button("Try again") { model.retry(chat.id) }.buttonStyle(.glass) }
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(12)
                .background(.red.opacity(0.08), in: .rect(cornerRadius: 12))
            }
            if message.status == .stopped {
                Text("Stopped").font(.callout.italic()).foregroundStyle(.tertiary)
            }
            if let saved = message.memorySaved, !saved.isEmpty {
                Button {
                    model.settingsTab = "memory"
                    model.openSettingsRequest += 1
                } label: {
                    Label("Memory updated", systemImage: "brain.head.profile").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(saved.joined(separator: "\n"))
            }
            if !streaming, message.status != .error {
                HStack(spacing: 2) {
                    let text = message.visibleText
                    if !text.isEmpty { CopyButton(text: text) }
                    if isLast { IconButton(symbol: "arrow.counterclockwise", help: "Try again") { model.retry(chat.id) } }
                    if let ms = message.ms, ms > 400, !text.isEmpty {
                        Text("\(wordsPerSecond(text, ms)) words a second, on your Mac").font(.caption).foregroundStyle(.tertiary).padding(.leading, 6)
                    }
                }
                .opacity(hover || isLast ? 1 : 0)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hover = $0 }
    }

    private var waiting: Bool {
        guard let last = message.blocks.last else { return true }
        if case .tool(let t) = last { return t.status == .done || t.status == .error || t.status == .denied }
        return false
    }

    private var waitingText: String {
        if case .starting = model.engineState { return "Waking up the AI…" }
        return message.blocks.isEmpty ? "Thinking…" : "Working…"
    }

    private func wordsPerSecond(_ text: String, _ ms: Int) -> Int {
        max(1, Int((Double(text.split(whereSeparator: \.isWhitespace).count) / (Double(ms) / 1000)).rounded()))
    }
}

private struct BlockView: View {
    let block: Block
    let live: Bool

    var body: some View {
        switch block {
        case .text(let t):
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Markdown(t).markdownTheme(.tarn).textSelection(.enabled)
            }
        case .thinking(let t, let ms):
            ThinkingView(text: t, ms: ms, live: live)
        case .tool(let tool):
            if tool.status == .awaitingApproval, let request = tool.approval {
                ApprovalCard(blockId: tool.id, request: request)
            } else {
                ToolStepView(tool: tool)
            }
        }
    }
}

private struct ThinkingView: View {
    let text: String
    let ms: Int
    let live: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                .padding(.top, 4)
        } label: {
            let secs = max(1, ms / 1000)
            Text(live ? "Thinking…" : "Thought for \(secs) second\(secs == 1 ? "" : "s")").foregroundStyle(.secondary).font(.callout)
        }
    }
}

private struct ToolStepView: View {
    let tool: ToolBlock
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                Text(prettyArgs).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let r = tool.result {
                    Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(r.count > 6000 ? String(r.prefix(6000)) + "\n…" : r).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 7) {
                statusIcon.frame(width: 16)
                Text(tool.status == .denied ? "\(tool.label) (not allowed)" : tool.label).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(tool.status == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch tool.status {
        case .running: ProgressView().controlSize(.mini)
        case .error: Image(systemName: "exclamationmark.circle")
        case .denied: Image(systemName: "nosign")
        default: Image(systemName: symbol)
        }
    }

    private var symbol: String {
        switch tool.name {
        case "web_search", "fetch_page": "globe"
        case "run_command": "terminal"
        case "write_file", "edit_file": "square.and.pencil"
        case "list_files", "search_files": "folder"
        case "read_file": "doc.text"
        case "use_skill": "sparkles"
        default: "puzzlepiece.extension"
        }
    }

    private var prettyArgs: String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(tool.args.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return tool.args.isEmpty ? "{}" : tool.args }
        return String(decoding: d, as: UTF8.self)
    }
}

private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let blockId: String
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            ScrollView {
                Group {
                    if request.rendered == true {
                        // A document preview, formatted the way the saved file will look.
                        Markdown(request.detail).markdownTheme(.tarn).textSelection(.enabled)
                    } else {
                        Text(request.detail)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(request.rendered == true ? 14 : 10)
            }
            .frame(maxHeight: request.rendered == true ? 240 : 200)
            .background(request.rendered == true ? Color(nsColor: .textBackgroundColor) : Color.codeBackground, in: .rect(cornerRadius: 10))
            .overlay {
                if request.rendered == true { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
            }
            HStack {
                Spacer()
                Button("Don’t allow") { model.approve(blockId, .deny) }.buttonStyle(.borderless)
                Button("Allow for this chat") { model.approve(blockId, .chat) }.buttonStyle(.glass)
                Button("Allow once") { model.approve(blockId, .once) }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tarn needs your permission")
    }
}

struct FileChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let url = Attachments.imageURL(attachment), let ns = NSImage(contentsOf: url) {
                Image(nsImage: ns).resizable().scaledToFill().frame(width: 22, height: 22).clipShape(.rect(cornerRadius: 5))
            } else {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text").font(.caption)
            }
            Text(attachment.name).lineLimit(1).truncationMode(.middle).font(.callout)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .frame(maxWidth: 240)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 22) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(help)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        }
    }
}

extension Theme {
    /// Assistant answers read like a well-set book page: Iowan Old Style, generous leading.
    @MainActor static let tarn = Theme()
        .text {
            FontFamily(.custom("Iowan Old Style"))
            FontSize(16.5)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.84))
            BackgroundColor(Color.codeBackground)
        }
        .link { ForegroundColor(.primary); UnderlineStyle(.single) }
        .strong { FontWeight(.semibold) }
        .heading1 { c in c.label.markdownMargin(top: 20, bottom: 8).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.45)) } }
        .heading2 { c in c.label.markdownMargin(top: 18, bottom: 6).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.25)) } }
        .heading3 { c in c.label.markdownMargin(top: 14, bottom: 4).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.1)) } }
        .paragraph { c in c.label.relativeLineSpacing(.em(0.32)).markdownMargin(top: 0, bottom: 12) }
        .listItem { c in c.label.markdownMargin(top: .em(0.2)) }
        .blockquote { c in
            c.label
                .markdownTextStyle { ForegroundColor(.secondary) }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                .markdownMargin(top: 0, bottom: 12)
        }
        .codeBlock { c in CodeBlockView(configuration: c).markdownMargin(top: 0, bottom: 14) }
        .table { c in
            c.label
                .markdownTableBorderStyle(.init(.horizontalBorders, color: .secondary.opacity(0.25)))
                .markdownTextStyle { FontFamilyVariant(.normal); FontSize(14) }
                .markdownMargin(top: 0, bottom: 14)
        }
        .tableCell { c in
            c.label
                .markdownTextStyle { if c.row == 0 { FontWeight(.semibold) } }
                .padding(.vertical, 6)
                .padding(.trailing, 14)
        }
}

private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language ?? "text").font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: configuration.content)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            Divider().opacity(0.5)
            ScrollView(.horizontal) {
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.82)) }
                    .padding(12)
            }
        }
        .background(Color.codeBackground, in: .rect(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
    }
}
