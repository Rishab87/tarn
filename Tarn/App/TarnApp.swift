import SwiftUI

@main
struct TarnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Tarn", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 540)
                .task {
                    delegate.model = model
                    await model.boot()
                }
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.newChat() }.keyboardShortcut("n")
                Button("Search Chats") { model.searchOpen = true }.keyboardShortcut("k")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Back Up Chats…") { model.exportBackup() }.disabled(!model.booted)
            }
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: Binding(get: { model.settings.theme }, set: { v in model.update { $0.theme = v } })) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(!model.booted)
            }
            CommandGroup(replacing: .help) {
                Link("Tarn on GitHub", destination: URL(string: "https://github.com/Rishab87/tarn")!)
                Link("Report a Problem", destination: URL(string: "https://github.com/Rishab87/tarn/issues")!)
                Button("Show Tarn’s Data Folder") { NSWorkspace.shared.open(Paths.data) }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if !model.booted {
                Color.clear
            } else if !model.settings.onboarded {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .onChange(of: model.openSettingsRequest) { openSettings() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Closing Tarn frees the model's memory immediately.
        model?.shutdown()
    }
}
