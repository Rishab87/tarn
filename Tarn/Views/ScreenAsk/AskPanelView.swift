import AppKit
import MarkdownUI
import SwiftUI

/// The floating prompt box beside the circled region. Non-activating like Spotlight: typing in
/// it doesn't bring Tarn's main window forward.
final class AskPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct AskPanelView: View {
    @Environment(ScreenAskController.self) private var ctl
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ctl = ctl
        VStack(alignment: .leading, spacing: 10) {
            header
            if ctl.showPermissions {
                permissions
            } else {
                conversation
            }
        }
        .padding(14)
        .frame(width: ScreenAskController.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Glow.water.opacity(0.35), lineWidth: 1))
        .onAppear { focused = true }
        .onChange(of: ctl.focusRequest) { focused = true }
    }

    /// First run, or permission switched off later: say what's needed and why, in plain words.
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold ⌥⌘ in any app, circle what you see, and ask Tarn about it. To see your screen, Tarn needs your OK in macOS first:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ScreenAskPermissionsView()
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { ctl.close() }.controlSize(.small)
            }
        }
        .onAppear { ctl.refreshPermissions() }
    }

    @ViewBuilder private var conversation: some View {
        @Bindable var ctl = ctl
        Group {
            if !ctl.session.captures.isEmpty { thumbnails }
            if ctl.session.messages.isEmpty {
                Spacer(minLength: 0)
            } else {
                transcript
            }
            if let note = ctl.notice {
                Text(note).font(.callout).foregroundStyle(Color.warning).fixedSize(horizontal: false, vertical: true)
            }
            input
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Mark(size: 18)
            Text("Ask about your screen").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { ctl.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
        }
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ctl.session.captures) { a in
                    CaptureThumb(attachment: a, pending: ctl.session.pending.contains(a))
                }
            }
        }
        .frame(height: 64)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ctl.session.messages) { m in
                        if m.role == .user {
                            Text(m.text)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.bubble, in: .rect(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            AnswerView(message: m)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 2)
            }
            .onChange(of: ctl.session.messages.last?.visibleText) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
        .clipShape(.rect) // earlier lines must not scroll up under the thumbnails
    }

    private var input: some View {
        @Bindable var ctl = ctl
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(ctl.session.messages.isEmpty ? "Ask about this… (Return: “What is this?”)" : "Ask a follow-up…", text: $ctl.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { ctl.draft += "\n"; return .handled }
                    ctl.submit()
                    return .handled
                }
                .onKeyPress(.escape) { ctl.close(); return .handled }
            if ctl.answering {
                Button { ctl.stopAnswer() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(SendButtonStyle())
                    .accessibilityLabel("Stop answering")
            } else {
                Button { ctl.submit() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(SendButtonStyle())
                    .accessibilityLabel("Ask")
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 18))
    }

    private var footer: some View {
        HStack {
            Text("⇧⌥⌘ add another part · ⌥⌘ start over")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Continue in chat") { ctl.continueInChat() }
                .controlSize(.small)
                .disabled(!ctl.canContinue)
        }
    }
}

private struct CaptureThumb: View {
    let attachment: Attachment
    let pending: Bool

    var body: some View {
        Group {
            if let url = Attachments.imageURL(attachment), let img = NSImage(contentsOf: url) {
                // Fit, not fill: a thin strip (a table row, a toolbar) must stay recognisable.
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 88, height: 60)
        .background(Color.primary.opacity(0.05))
        .clipShape(.rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pending ? Glow.water : Color.primary.opacity(0.12), lineWidth: pending ? 2 : 1))
        .help(pending ? "Goes with your next question" : attachment.name)
    }
}

private struct AnswerView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let text = message.visibleText
            if text.isEmpty, message.status == .streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Markdown(text).markdownTheme(.tarn)
                    .markdownTextStyle(\.text) { FontSize(14) } // the chat's 16.5 pt is too big for a 400 pt panel
                    .textSelection(.enabled)
            }
            if message.status == .error, let e = message.error {
                Text(e).font(.callout).foregroundStyle(Color.warning)
            }
            if message.status == .stopped { Text("Stopped").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explains the two macOS permissions in plain words, with live status. Shown in Settings and
/// in the panel when something is missing.
struct ScreenAskPermissionsView: View {
    @Environment(ScreenAskController.self) private var ctl

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(ok: ctl.screenRecording, title: "Screen Recording",
                detail: "Lets Tarn take a picture of the screen when you hold ⌥⌘. Only the part you circle is kept, and it goes to Tarn’s AI on this Mac, nowhere else.",
                open: ScreenAskController.screenRecordingSettings) { ScreenCapture.requestPermission() }
            if !ctl.screenRecording {
                Text("After you switch Tarn on in System Settings, macOS may ask you to quit and reopen Tarn.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(ok: Bool, title: String, detail: String, open: URL, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.water : .secondary)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !ok {
                Button("Allow…") {
                    request()
                    NSWorkspace.shared.open(open)
                }
                .controlSize(.small)
            }
        }
    }
}
