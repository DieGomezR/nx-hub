import SwiftUI
import AppKit

@main
struct NXHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("NX Hub", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1024, minHeight: 680)
                .task {
                    AppDelegate.model = model
                    await model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.page = .settings }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Reload Library") { Task { await model.reloadLibrary(); await model.computeChanges() } }
                    .keyboardShortcut("r")
                Button("Check for nxnative Updates") { Task { await model.repo.fetch(); await model.computeChanges() } }
                    .keyboardShortcut("u")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A running build goes on after NX Hub quits (it writes to its own log, and the next start finds it again); queued ones wait for the next start.
    /// A game paused behind NX Hub goes on
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.model?.builds.prepareToQuit()
        AppDelegate.model?.session?.end()
        return .terminateNow
    }
}
