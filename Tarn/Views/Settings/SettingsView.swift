import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "slider.horizontal.3") { GeneralPane() }
            Tab("AI Model", systemImage: "cpu") { ModelPane() }
            Tab("Connectors", systemImage: "puzzlepiece.extension") { ConnectorsPane() }
            Tab("Skills", systemImage: "sparkles") { SkillsPane() }
            Tab("Chats & Backup", systemImage: "archivebox") { DataPane() }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath") { UpdatesPane() }
            Tab("About", systemImage: "info.circle") { AboutPane() }
        }
        .frame(width: 640, height: 560)
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var about = ""

    var body: some View {
        Form {
            Section {
                TextField("What should Tarn know about you?", text: $about,
                          prompt: Text("My name is Sam. I teach high-school biology. Keep answers short and use simple words."), axis: .vertical)
                    .lineLimit(3...6)
                    .onAppear { about = model.settings.aboutYou }
                    .onChange(of: about) { _, v in model.update { $0.aboutYou = String(v.prefix(4000)) } }
            } header: {
                Text("About you")
            } footer: {
                Text("Your name, what you do, how you like answers. Tarn reads this before every chat.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Appearance", selection: Binding(get: { model.settings.theme }, set: { v in model.update { $0.theme = v } })) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(get: { model.settings.webSearch }, set: { v in model.update { $0.webSearch = v } })) {
                    Text("Search the web when needed")
                    Text("For news, prices and anything recent. Searches go to DuckDuckGo; nothing else leaves your Mac.")
                }
                Toggle(isOn: Binding(get: { model.settings.thinking }, set: { v in model.update { $0.thinking = v } })) {
                    Text("Think before answering")
                    Text("Slower, but better at tricky questions, maths and planning.")
                }
                Toggle(isOn: Binding(get: { model.settings.memoryGuard }, set: { v in model.update { $0.memoryGuard = v } })) {
                    Text("Warn me when my Mac is low on memory")
                    Text("Suggests the lighter model or freeing Tarn’s memory when you run heavy apps.")
                }
                Picker(selection: Binding(get: { model.settings.idleUnloadMinutes }, set: { v in model.update { $0.idleUnloadMinutes = v } })) {
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                    Text("Never").tag(0)
                } label: {
                    Text("Free memory when Tarn isn’t in use")
                    Text("Tarn unloads its AI when idle and reloads it in seconds when you return.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelPane: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false

    var body: some View {
        Form {
            if let hw = model.hardware {
                Section {
                    ForEach(Tier.allCases) { t in
                        if let p = model.picks.pick(t) { TierCard(tier: t, pick: p) }
                    }
                } header: {
                    Text("Picked for your \(hw.machineName) (\(hw.chipShort), \(hw.ramGB) GB)")
                } footer: {
                    Text("Both run entirely on your Mac and leave room for your other apps.").foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button(checking ? "Checking…" : "Check now") {
                        checking = true
                        Task {
                            await model.checkModelUpdates()
                            checking = false
                            model.showToast(model.updates.isEmpty ? "Your AI is up to date." : "An update is available. See the banner in your chat.")
                        }
                    }
                    .disabled(checking)
                } label: {
                    Text("Check for model updates")
                    Text("Tarn checks every time it opens. Space used by models: \(Fmt.bytes(model.installed.reduce(0) { $0 + $1.size })).")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TierCard: View {
    @Environment(AppModel.self) private var model
    let tier: Tier
    let pick: ModelPick
    @State private var confirmDelete = false

    var body: some View {
        let m = pick.model
        let installed = model.isInstalled(m.id)
        let active = model.activeModelId == m.id
        let mine = model.download.modelId == m.id ? model.download : .idle
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Fmt.tierLabel(tier, pick)).font(.headline)
                if active { Text("In use").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: .capsule) }
                Spacer()
                switch mine {
                case .downloading(let p):
                    Button("Pause · \(Int(p.fraction * 100))%") { model.pauseDownload() }
                case .paused, .failed:
                    Button("Resume") { model.startDownload(m.id) }
                    Button("Cancel") { model.cancelDownload() }
                case .verifying:
                    Text("Checking…").foregroundStyle(.secondary)
                case .idle:
                    if installed && !active { Button("Use this model") { model.setTier(tier) } }
                    if !installed { Button("Download · \(Fmt.bytes(m.file.size))") { model.startDownload(m.id) } }
                    if installed {
                        Button("Delete…") { confirmDelete = true }
                    }
                }
            }
            Text(tier.blurb).foregroundStyle(.secondary)
            Text("\(Fmt.bytes(m.file.size)) on disk · uses about \(Fmt.bytes(pick.footprintBytes)) of memory while loaded")
                .font(.callout).foregroundStyle(.secondary)
            if case .downloading(let p) = mine { ProgressView(value: p.fraction).tint(Color.water) }
            if case .failed(_, let msg) = mine { Text(msg).font(.callout).foregroundStyle(.red) }
            DisclosureGroup("Details") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Model").foregroundStyle(.secondary); Text(m.name) }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(m.totalParamsB == m.activeParamsB ? "\(m.params) parameters" : "\(m.params) parameters, \(Int(m.activeParamsB))B active per word")
                    }
                    GridRow { Text("Conversation memory").foregroundStyle(.secondary); Text("about \((pick.contextTokens * 3 / 4).formatted()) words") }
                    GridRow { Text("License").foregroundStyle(.secondary); Link(m.license, destination: URL(string: m.licenseUrl)!) }
                    GridRow { Text("Source").foregroundStyle(.secondary); Link("huggingface.co/\(m.file.repo)", destination: m.pageURL) }
                }
                .font(.callout)
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .padding(.vertical, 6)
        .confirmationDialog("Delete \(Fmt.tierLabel(tier, pick)) from this Mac?", isPresented: $confirmDelete) {
            Button("Delete \(Fmt.bytes(m.file.size))", role: .destructive) { model.removeModel(m.id) }
        } message: {
            Text("You can download it again any time.")
        }
    }
}

private struct ConnectorsPane: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ForEach(model.connectors) { c in ConnectorRow(config: c) }
                if model.connectors.isEmpty { Text("No connectors yet.").foregroundStyle(.secondary) }
            } header: {
                Text("Connectors")
            } footer: {
                Text("Connectors let Tarn use other apps and services through the Model Context Protocol (MCP): notes, calendars, GitHub and more. Tarn asks before every action a connector takes.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Add connector…") { adding = true }
                    Button("Import from Claude Desktop") { model.importClaudeConnectors() }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { ConnectorForm() }
    }
}

private struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    let config: ConnectorConfig
    @State private var confirm = false

    var body: some View {
        let status = model.connectorStatus[config.id] ?? ConnectorStatus(state: config.enabled ? .connecting : .off)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(config.name).font(.headline)
                Text(config.kind == .stdio ? ([config.command] + config.args).joined(separator: " ") : config.url)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                switch status.state {
                case .connected: Label("Connected · \(status.tools.count) tool\(status.tools.count == 1 ? "" : "s")", systemImage: "circle.fill").foregroundStyle(.green)
                case .connecting: Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
                case .failed(let msg): Label(msg, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                case .off: Label("Off", systemImage: "circle").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Spacer()
            if case .failed = status.state { Button("Reconnect") { model.connect(config) } }
            Button(role: .destructive) { confirm = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(config.name)")
            Toggle("", isOn: Binding(get: { config.enabled }, set: { v in var c = config; c.enabled = v; model.upsertConnector(c) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .confirmationDialog("Remove \(config.name)?", isPresented: $confirm) {
            Button("Remove", role: .destructive) { model.removeConnector(config.id) }
        }
    }
}

private struct ConnectorForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ConnectorConfig.Kind = .http
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var command = ""
    @State private var env = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a connector").font(.title2.weight(.semibold))
            Picker("Type", selection: $kind) {
                Text("Web address").tag(ConnectorConfig.Kind.http)
                Text("Program on this Mac").tag(ConnectorConfig.Kind.stdio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                TextField("Name", text: $name, prompt: Text("Notion"))
                if kind == .http {
                    TextField("Address", text: $url, prompt: Text("https://mcp.example.com/mcp"))
                    SecureField("Access key (optional)", text: $token)
                } else {
                    TextField("Command", text: $command, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                    TextField("Settings (optional, one per line: KEY=value)", text: $env, axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add connector") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return error = "Give the connector a name." }
        if kind == .http {
            let u = url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: u), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                return error = "Enter the connector’s address, starting with https://"
            }
            let headers = token.isEmpty ? [:] : ["Authorization": "Bearer \(token.trimmingCharacters(in: .whitespaces))"]
            model.upsertConnector(ConnectorConfig(id: newId(), name: n, kind: .http, url: u, headers: headers, enabled: true))
        } else {
            let parts = splitArgs(command)
            guard let first = parts.first else { return error = "Enter the command that starts the connector." }
            var envMap: [String: String] = [:]
            for line in env.split(separator: "\n") {
                if let m = line.firstMatch(of: /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/) { envMap[String(m.1)] = String(m.2) }
            }
            model.upsertConnector(ConnectorConfig(id: newId(), name: n, kind: .stdio, command: first, args: Array(parts.dropFirst()), env: envMap, enabled: true))
        }
        dismiss()
    }
}

/// Splits a command line, honouring simple single and double quotes.
func splitArgs(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var quote: Character?
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch.isWhitespace {
            if !cur.isEmpty { out.append(cur); cur = "" }
        } else {
            cur.append(ch)
        }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

private struct SkillsPane: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false

    var body: some View {
        Form {
            Section {
                ForEach(model.skills) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(s.name).font(.headline)
                                if s.builtIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(s.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if !s.builtIn {
                            Button(role: .destructive) {
                                try? Skills.remove(s.name)
                                model.refreshSkills()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(s.name)")
                        }
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { v in Skills.setEnabled(s.name, v); model.refreshSkills() }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            } header: {
                Text("Skills")
            } footer: {
                Text("Skills are saved instructions Tarn follows for particular jobs. Tarn picks the right one on its own. Skills made for Claude (folders with a SKILL.md) work here too.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Create skill…") { creating = true }
                    Button("Add from folder or zip…") { importSkill() }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $creating) { SkillForm() }
    }

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.title = "Add a skill"
        panel.message = "Choose a skill folder (with a SKILL.md inside) or a skill .zip file."
        panel.prompt = "Add skill"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "zip" { try Skills.importZip(url) } else {
                try Skills.importFolder(url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent() : url)
            }
            model.refreshSkills()
            model.showToast("Skill added.")
        } catch {
            model.showToast(error.localizedDescription, error: true)
        }
    }
}

private struct SkillForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a skill").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Meeting notes"))
                TextField("When should Tarn use it?", text: $description, prompt: Text("When I paste a meeting transcript or ask for meeting notes"))
                TextField("Instructions", text: $instructions, prompt: Text("Start with decisions made, then action items with owners and dates, then open questions."), axis: .vertical)
                    .lineLimit(5...10)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save skill") {
                    do {
                        try Skills.create(name: name, description: description, instructions: instructions)
                        model.refreshSkills()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

private struct DataPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Back up…") { model.exportBackup() }
                } label: {
                    Text("Back up everything")
                    Text("Saves \(model.summaries.count) chat\(model.summaries.count == 1 ? "" : "s"), your skills, connectors and preferences in one .zip file. AI models aren’t included; Tarn downloads the right one on each Mac. Connector settings can include access keys, so keep the file private.")
                }
                LabeledContent {
                    Button("Restore…") { model.importBackup(replace: false) }
                } label: {
                    Text("Restore from a backup")
                    Text("Adds the chats from a Tarn backup. Chats you already have stay. Connectors from the backup arrive switched off.")
                }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.data) }
                } label: {
                    Text("Show Tarn’s files")
                    Text("The folder where Tarn keeps chats and models.")
                }
            } footer: {
                Text("Your chats are stored only on this Mac.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Delete all…", role: .destructive) { confirm = true }.disabled(model.summaries.isEmpty)
                } label: {
                    Text("Delete all chats")
                    Text("Removes every chat from this Mac. Back up first if you might want them.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all \(model.summaries.count) chats?", isPresented: $confirm) {
            Button("Delete all chats", role: .destructive) {
                model.deleteAllChats()
                model.showToast("All chats deleted.")
            }
        } message: {
            Text("This can’t be undone.")
        }
    }
}

private struct UpdatesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.settings.autoUpdate }, set: { v in model.update { $0.autoUpdate = v } })) {
                    Text("Update Tarn automatically")
                    Text("Downloads new versions in the background and installs them the next time Tarn restarts.")
                }
                LabeledContent {
                    Button("Check now") { model.updater.checkNow() }.disabled(!model.updater.isConfigured)
                } label: {
                    Text("Version \(version)")
                    Text(model.updater.isConfigured ? "Tarn checks for a new version each time it opens." : "This is a test build. Released versions check for updates each time they open.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        Form {
            Section {
                HStack(spacing: 12) {
                    Mark(size: 34)
                    VStack(alignment: .leading) {
                        Text("Tarn \(version)").font(.title2.weight(.semibold))
                        Text("A private AI that runs on your Mac. Made by Rishab Kumar Jha, an independent developer in India.").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Privacy") {
                Text("Tarn has no account and sends no analytics. Your chats, files and settings stay on this Mac. Tarn connects to the internet only to download AI models from Hugging Face, to check for app updates, and to search the web through DuckDuckGo when that’s switched on.")
                    .foregroundStyle(.secondary)
            }
            Section("Built with") {
                Text("llama.cpp (MIT license) runs the AI. Models are made by their authors and used under their licenses; see AI Model → Details. Sparkle handles updates.")
                    .foregroundStyle(.secondary)
                Link("llama.cpp on GitHub", destination: URL(string: "https://github.com/ggml-org/llama.cpp")!)
            }
            Section("Contact") {
                Link("kumarjharishab@gmail.com", destination: URL(string: "mailto:kumarjharishab@gmail.com?subject=Tarn")!)
            }
        }
        .formStyle(.grouped)
    }
}
