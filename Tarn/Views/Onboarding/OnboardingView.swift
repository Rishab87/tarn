import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.onboardingStep {
            case 0: Welcome { withAnimation(.smooth) { model.onboardingStep = 1 } }
            case 1: Origin { withAnimation(.smooth) { model.onboardingStep = 2 } }
            default: Setup()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .transition(.opacity)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

private struct Welcome: View {
    var next: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            PixelLake(level: 1).frame(maxWidth: 420).padding(.bottom, 30)
            Text("An AI that lives on your Mac")
                .font(.display(44))
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
            Text("No account, no subscription, no ads. Tarn runs on this computer, so your conversations never leave it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.bottom, 32)
            Button(action: next) { Text("Get started").frame(minWidth: 120) }
                .primaryButton()
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct Origin: View {
    @Environment(AppModel.self) private var model
    var next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("New here, or coming from another Mac?")
                .font(.display(40))
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
            Text("If you backed up Tarn on another Mac, bring your chats, skills and preferences with you.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.bottom, 30)
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    ChoiceCard(symbol: "sparkles", title: "Start fresh", detail: "Begin with an empty Tarn. You can restore a backup later in Settings.", action: next)
                    ChoiceCard(symbol: "arrow.down.doc", title: "Restore a backup", detail: "Choose the Tarn Backup .zip file you saved before.") {
                        if model.importBackup(replace: true) != nil { next() }
                    }
                }
            }
            .frame(maxWidth: 600)
        }
    }
}

private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.title3.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .padding(20)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

private struct Setup: View {
    @Environment(AppModel.self) private var model
    @State private var tier: Tier = .recommended
    @State private var started = false

    var body: some View {
        let hw = model.hardware
        let chosen = model.picks.pick(tier)
        let ready = model.isInstalled(chosen?.model.id)
        let mine = model.download.modelId == chosen?.model.id && !model.download.isVision ? model.download : .idle
        let level = ready ? 1 : (mine.progress?.fraction ?? 0)

        VStack(spacing: 0) {
            if hw?.appleSilicon == false {
                NoticeView(title: "Tarn needs a newer Mac", text: "Tarn runs its AI on Apple silicon (M1 or later). This Mac has an Intel processor, which is too slow for it.")
            } else if model.picks.recommended == nil {
                NoticeView(title: "Tarn needs more memory", text: "Tarn needs a Mac with at least 8 GB of memory to run its AI without slowing everything else down.")
            } else {
                PixelLake(level: level).frame(maxWidth: 420).padding(.bottom, 24)
                Text(ready ? "Tarn is ready" : "Setting up Tarn for your Mac")
                    .font(.display(40))
                    .padding(.bottom, 10)
                if let hw {
                    Text(machineLine(hw)).font(.title3).foregroundStyle(.secondary).padding(.bottom, 22)
                }
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(Tier.allCases) { t in
                            if let pick = model.picks.pick(t) {
                                TierRow(tier: t, pick: pick, selected: tier == t,
                                        warning: t == .bigger ? ModelFit.biggerWarning(pick, ramBytes: hw?.ramBytes ?? 0, budgetBytes: model.picks.budgetBytes) : nil) { choose(t) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 560)
                .padding(.bottom, 20)
                status(ready: ready, state: mine, total: chosen?.model.file.size ?? 1)
                    .frame(minHeight: 46)
                    .padding(.bottom, 18)
                HStack(spacing: 12) {
                    if case .paused = mine, let id = chosen?.model.id {
                        Button("Resume download") { model.startDownload(id) }.buttonStyle(.glass).controlSize(.extraLarge)
                    }
                    if case .failed = mine, let id = chosen?.model.id {
                        Button("Try again") { model.startDownload(id) }.buttonStyle(.glass).controlSize(.extraLarge)
                    }
                    Button { model.finishOnboarding() } label: { Text(ready ? "Start chatting" : "Continue to Tarn").frame(minWidth: 150) }
                        .primaryButton()
                        .controlSize(.extraLarge)
                        .keyboardShortcut(.defaultAction)
                }
                if !ready {
                    Text("You can look around while it downloads. Chat unlocks as soon as the AI is ready.")
                        .font(.callout).foregroundStyle(.tertiary).padding(.top, 16)
                }
            }
        }
        .task {
            // Start downloading the recommended model as soon as this screen appears.
            guard !started, let rec = model.picks.recommended, !model.isInstalled(rec.model.id) else { return }
            started = true
            model.startDownload(rec.model.id)
        }
    }

    private func machineLine(_ hw: Hardware) -> AttributedString {
        var s = AttributedString("Your ")
        var name = AttributedString(hw.machineName); name.font = .title3.weight(.semibold); name.foregroundColor = .primary
        s += name
        if hw.chipFamily != nil {
            s += AttributedString(" has an ")
            var chip = AttributedString(hw.chipShort); chip.font = .title3.weight(.semibold); chip.foregroundColor = .primary
            s += chip
            s += AttributedString(" chip and ")
        } else {
            s += AttributedString(" has ")
        }
        var ram = AttributedString("\(hw.ramGB) GB"); ram.font = .title3.weight(.semibold); ram.foregroundColor = .primary
        s += ram
        s += AttributedString(" of memory.")
        return s
    }

    private func choose(_ t: Tier) {
        guard t != tier else { return }
        tier = t
        model.setTier(t)
    }

    @ViewBuilder
    private func status(ready: Bool, state: DownloadState, total: Int64) -> some View {
        VStack(spacing: 3) {
            switch state {
            case _ where ready:
                Text("Downloaded and checked.").font(.headline)
                Text("Everything from here on runs on your Mac.").foregroundStyle(.secondary)
            case .failed(_, let message, _):
                Text("The download stopped").font(.headline)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .verifying:
                Text("Checking the download…").font(.headline)
                Text("Making sure the file arrived intact.").foregroundStyle(.secondary)
            case .paused(let p):
                Text("Download paused").font(.headline)
                Text("\(Fmt.bytes(p.received)) of \(Fmt.bytes(p.total))").foregroundStyle(.secondary)
            case .downloading(let p):
                Text("Downloading your AI…").font(.headline)
                let eta = p.bytesPerSec > 0 ? Fmt.eta(Double(p.total - p.received) / p.bytesPerSec) : ""
                Text("\(Fmt.bytes(p.received)) of \(Fmt.bytes(p.total))\(eta.isEmpty ? "" : ", \(eta) left")").foregroundStyle(.secondary).monospacedDigit()
            case .idle:
                Text("Getting ready…").font(.headline)
                Text(Fmt.bytes(total)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TierRow: View {
    let tier: Tier
    let pick: ModelPick
    let selected: Bool
    var warning: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? .primary : .tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.tierLabel(tier, pick)).font(.headline)
                    Text(tier.blurb).foregroundStyle(.secondary)
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer()
                Text(Fmt.bytes(pick.model.file.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(selected ? 0.55 : 0), lineWidth: 1.5))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct NoticeView: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.display(40))
            Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
    }
}
