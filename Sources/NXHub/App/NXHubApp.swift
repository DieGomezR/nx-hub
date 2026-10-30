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
    /// A game paused behind NX Hub: the player keeps it suspended (NX Hub then stays, out of sight, holding it at its instant), lets it go on, or stays.
    /// Logging out, restarting or shutting down asks nothing: the game goes on, so it can quit with the Mac
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.model else { return .terminateNow }
        let byTheSystem = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(0x7768_793F)) != nil   // kAEQuitReason, 'why?'
        if let s = model.session, s.paused, s.alive, !byTheSystem {
            let a = NSAlert()
            a.messageText = LF("Keep %@ suspended?", s.game.name)
            a.informativeText = L("NX Hub then stays open out of sight, holding the game at this instant: open NX Hub again, or press Home on the controller, to go back to it. If it goes on, it runs without NX Hub. Closing the game or restarting the Mac loses that instant.")
            a.addButton(withTitle: L("Keep Suspended"))
            a.addButton(withTitle: L("Let It Go On and Quit"))
            a.addButton(withTitle: L("Cancel"))
            switch a.runModal() {
            case .alertFirstButtonReturn: model.hideInBackground(); return .terminateCancel
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        model.builds.prepareToQuit()
        model.session?.end()
        return .terminateNow
    }

    /// NX Hub opened again while it holds a suspended game out of sight: its window comes back
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppDelegate.model?.hiddenInBackground == true { AppDelegate.model?.showFromBackground(); return false }
        return true
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        if AppDelegate.model?.hiddenInBackground == true { AppDelegate.model?.showFromBackground() }
    }
}
