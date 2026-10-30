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
    /// One another device saved meanwhile is not let go on (it would send this older instant over that save): it can be closed instead.
    /// Logging out, restarting or shutting down asks nothing: the game goes on, so it can quit with the Mac
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.model else { return .terminateNow }
        let byTheSystem = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(0x7768_793F)) != nil   // kAEQuitReason, 'why?'
        var closeFirst = false
        if let s = model.session, s.pausing, !byTheSystem {   // Home is still pausing it (its save is on its way to the cloud): ask once it is paused
            model.notice = LF("%@ is still pausing while its save goes to the cloud: quit again in a moment.", s.game.name)
            return .terminateCancel
        }
        if byTheSystem, let s = model.session, s.paused, model.cloudConflict(s) != nil { s.killWithoutSending() }   // not let go on over the other device's save
        if let s = model.session, s.paused, s.alive, !byTheSystem {
            let conflict = model.cloudConflict(s)
            let a = NSAlert()
            a.messageText = LF("Keep %@ suspended?", s.game.name)
            if let c = conflict {
                a.informativeText = LF("It was saved on another device %@, while it was suspended here, so it does not go on without NX Hub. Keep it suspended to decide later, or close it: its next start brings in that save.", c.cloud.relative)
                a.addButton(withTitle: L("Keep Suspended"))
                a.addButton(withTitle: L("Close It and Quit"))
            } else {
                a.informativeText = L("NX Hub then stays open out of sight, holding the game at this instant: open NX Hub again, or press Home on the controller, to find it there. If you let it go on, the game keeps running without NX Hub. If you close the game or restart the Mac, that instant is lost.")
                a.addButton(withTitle: L("Keep Suspended"))
                a.addButton(withTitle: L("Let It Go On and Quit"))
            }
            a.addButton(withTitle: L("Cancel"))
            let answer = a.runModal()
            let conflictNow = model.cloudConflict(s)   // another device may have saved it while the question was up
            switch answer {
            case .alertFirstButtonReturn:
                guard s.paused, s.alive else { model.reopenIfClosed(); return .terminateCancel }   // it went on, or ended, while the question was up
                model.hideInBackground(); return .terminateCancel
            case .alertSecondButtonReturn:
                if conflict == nil, let c = conflictNow { model.reopenIfClosed(); model.askCloud(c); return .terminateCancel }   // "go on" no longer fits: ask as on resume
                closeFirst = conflict != nil
            default: model.reopenIfClosed(); return .terminateCancel
            }
        }
        let s = model.session
        guard closeFirst || (s?.savePending == true && !byTheSystem) else {
            model.builds.prepareToQuit()
            s?.end()
            return .terminateNow
        }
        // NX Hub quits once the game is closed without sending, or once the backup of a save the game just made is written
        Task { @MainActor in
            if let s {
                if closeFirst { await s.closeWithoutSending() } else { await model.gameSaved(s, flush: true) }
            }
            model.builds.prepareToQuit()
            s?.end()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// NX Hub opened again while it holds a suspended game out of sight: its window comes back (SwiftUI opens it anew when Quit had closed it)
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model = AppDelegate.model, model.hiddenInBackground else { return true }
        return !model.showFromBackground()
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        if AppDelegate.model?.hiddenInBackground == true { AppDelegate.model?.showFromBackground() }
    }
}
