import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chat = model.current
        Group {
            if let chat, !chat.messages.isEmpty {
                TranscriptView(chat: chat)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 8) {
                            ModelUpdateBanner()
                            ComposerView(chat: chat)
                            Text("Tarn runs on your Mac and can make mistakes. Check anything important.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: 780)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity)
                    }
            } else {
                EmptyChatView()
            }
        }
        .navigationTitle(chat.map { $0.messages.isEmpty ? "" : $0.title } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { WaterCounter() }
        }
        .overlay(alignment: .topTrailing) { MemoryAlertView().padding(16) }
        .dropDestination(for: URL.self) { urls, _ in
            let files = model.readAttachments(urls)
            guard !files.isEmpty else { return false }
            NotificationCenter.default.post(name: .tarnAttach, object: files)
            return true
        }
    }
}

extension Notification.Name {
    static let tarnAttach = Notification.Name("tarnAttach")
    static let tarnSeed = Notification.Name("tarnSeed")
}

private struct EmptyChatView: View {
    @Environment(AppModel.self) private var model

    private let suggestions: [(symbol: String, label: String, prompt: String, attach: Bool)] = [
        ("doc.text", "Summarize a document", "Summarize this document. Start with the three most important points.", true),
        ("calendar", "Plan my week", "Help me plan my week. Here’s what I need to get done:\n", false),
        ("envelope", "Write an email", "Write a short, friendly email to ", false),
        ("lightbulb", "Explain something simply", "Explain this to me like I’m new to it: ", false),
    ]

    var body: some View {
        let name = model.settings.aboutYou.firstMatch(of: /(?i)(?:my name is|i'm|i am|call me)\s+([A-Z][a-z]+)/).map { String($0.1) }
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            HStack(spacing: 16) {
                PixelScene()
                Text(Fmt.greeting(name: name)).font(.display(42))
            }
            .padding(.bottom, 26)
            ModelUpdateBanner().padding(.bottom, 10)
            // An empty chat can already exist (a folder was shared before the first message);
            // pass it so its folder chip and draft show.
            ComposerView(chat: model.current)
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.label) { s in
                    Button {
                        NotificationCenter.default.post(name: .tarnSeed, object: (s.prompt, s.attach))
                    } label: {
                        Label(s.label, systemImage: s.symbol)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WaterCounter: View {
    @Environment(AppModel.self) private var model
    @State private var sparkle = 0

    var body: some View {
        Button { model.waterOpen.toggle() } label: {
            Label {
                Text("\(Water.format(model.settings.water.ml)) saved").monospacedDigit()
            } icon: {
                PixelDrop(sparkle: sparkle)
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Water saved by answering on your Mac")
        .onChange(of: model.settings.water.ml) { old, new in
            guard let milestone = Water.milestone(from: old, to: new) else { return }
            model.showToast("Level up: \(Water.format(milestone)) of water saved by answering on your Mac.")
            Task { @MainActor in
                for _ in 0..<2 {
                    for f in 1...9 { sparkle = f; try? await Task.sleep(for: .milliseconds(80)) }
                }
                sparkle = 0
            }
        }
        .popover(isPresented: Binding(get: { model.waterOpen }, set: { model.waterOpen = $0 }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Water.format(model.settings.water.ml)).font(.display(30))
                let level = Water.level(model.settings.water.ml)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Level \(level.level)").font(.callout.weight(.semibold))
                        if let next = level.next { Text("· next at \(Water.format(next))").font(.callout).foregroundStyle(.secondary) }
                    }
                    PixelBar(progress: level.progress)
                }
                Text("saved across \(model.settings.water.answers.formatted()) answer\(model.settings.water.answers == 1 ? "" : "s") written on your Mac")
                    .foregroundStyle(.secondary)
                Text(Water.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Water.sources, id: \.url) { s in Link(s.title, destination: s.url).font(.caption) }
                }
            }
            .padding(18)
            .frame(width: 340)
        }
    }
}

struct MemoryAlertView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let alert = model.memoryAlert {
            let lighter = model.picks.lighter
            VStack(alignment: .leading, spacing: 10) {
                Label("Your Mac is running low on memory", systemImage: "memorychip").font(.headline)
                    .foregroundStyle(Color.warning, .primary)
                let size = alert.engineGB.map { "about \($0.formatted()) GB" } ?? "a lot of memory"
                Text(alert.onLighter
                     ? "Looks like you’re doing something heavy. Tarn’s AI is holding \(size). Free it up while you work; Tarn reloads it in a few seconds when you send your next message. You can also quit Tarn."
                     : "Looks like you’re doing something heavy. Tarn’s AI is using \(size). Switch to \(Fmt.tierLabel(.lighter, lighter)) to give memory back to your other apps, or free it up for now.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if !alert.onLighter, lighter != nil {
                        Button("Use \(Fmt.tierLabel(.lighter, lighter))") {
                            model.dismissMemoryAlert()
                            model.setTier(.lighter)
                        }
                        .primaryButton()
                    }
                    Button("Free up memory") { model.freeMemory() }.buttonStyle(.glass)
                    Button("Not now") { model.dismissMemoryAlert() }.buttonStyle(.borderless)
                }
            }
            .padding(16)
            .frame(width: 370)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ModelUpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let u = model.updates.first(where: { !model.dismissedUpdates.contains($0.id) }) {
            let targetId = u.kind == .file ? u.modelId : u.replacementId
            let busy = model.download.modelId == targetId && model.download.progress != nil
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 1) {
                    if u.kind == .file {
                        Text("An improved version of your AI is available.").fontWeight(.semibold)
                        Text("\(Fmt.bytes(u.sizeBytes)) download.").foregroundStyle(.secondary)
                    } else {
                        Text("There’s a smarter AI for your Mac: \(Fmt.tierLabel(.recommended, model.picks.recommended)).").fontWeight(.semibold)
                        Text("It replaces your current one when it’s ready.").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Spacer()
                if busy, let p = model.download.progress {
                    Text("Downloading… \(Int(p.fraction * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Button("Later") { model.dismissedUpdates.insert(u.id) }.buttonStyle(.borderless)
                    Button(u.kind == .file ? "Update" : "Download") { model.applyUpdate(u) }.primaryButton()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}
