import AppKit
import Observation

/// The screens of NX Hub
enum Page: Hashable { case home, library, game(String), catalog, saves, mods(String?), cheats(String?), controllers, nxnative, settings }

/// What the controller moves through on the start screen
enum HomeRow { case games, dock }
enum DockItem: Int, CaseIterable { case library, catalog, mods, cheats, saves, controllers, nxnative, settings }

@Observable
@MainActor
final class AppModel {
    let config: Config
    var games: [Game] = []
    var scanning = false
    var repo: NXNativeRepo
    let builds = BuildService()
    let pads = ControllerMonitor()
    let cheats = CheatSession()
    /// The game started from NX Hub that runs now: its pictures, and its pause behind NX Hub when Home is pressed in it
    var session: GameSession?
    /// "Close <game>?" over the start screen (X on a running game)
    var closePrompt: Game?
    /// Another game asked for while one is suspended at its instant: go back to it, or close it and open the other
    var switchPrompt: SwitchPlan?
    struct SwitchPlan: Identifiable, Equatable {
        let from: Game
        let to: Game
        var closing = false            // the suspended game is closing (the prompt stays, with a spinner, until the other one opens)
        var id: String { from.titleID + "→" + to.titleID }
    }
    /// A game suspended here was saved on another device meanwhile: close it (its next start brings in that save) or go back to this instant anyway
    var cloudPrompt: CloudConflict?
    @ObservationIgnored private var cloudPromptAt = Date.distantPast   // presses right after it appears are not taken (a second A from the resume that raised it)
    /// Asks about a game another device saved while it was suspended here
    func askCloud(_ c: CloudConflict) {
        if cloudPrompt == nil { cloudPromptAt = Date() }
        cloudPrompt = c
    }
    struct CloudConflict: Identifiable, Equatable {
        let game: Game
        let cloud: Date                // when the cloud's file changed
        var id: String { game.titleID }
    }
    /// Goes up when a new picture of where a game is lands (views read the pictures again)
    var shotStamp = 0
    @ObservationIgnored private let nightGuard = SleepGuard()
    @ObservationIgnored private var nightTimer: Timer?
    var running: Set<String> = []                  // bundle IDs of the nxnative apps running now (lower case)
    var changes: [String: GameChanges] = [:]       // title ID → what changed upstream since its build
    var notice: String?                            // a message shown at the bottom of the window
    var page: Page = .home
    var homeIndex = 0                              // the selected game on the start screen
    var homeRow: HomeRow = .games
    var dockIndex = 0
    var catalog: [CatalogEntry] = []
    /// Asks the Settings window to open (the start screen's Settings button)
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startDone = false            // the first library load is over: a game found running after it was just opened
    @ObservationIgnored private var adopting = false             // stopped hosts are being looked at: no session for them yet (adoptStopped)
    @ObservationIgnored private var opening: Set<String> = []    // games play() is opening now
    @ObservationIgnored private var pendingShots: [String: URL] = [:]       // title ID → the picture taken at the first commit of a burst
    @ObservationIgnored private var lastGameSave: [String: String] = [:]    // title ID → the signature of its last "when the game saved" backup
    /// NX Hub keeps running out of sight (no window, no Dock icon) to hold a suspended game at its instant after Quit
    var hiddenInBackground = false
    @ObservationIgnored private var hiddenAt = Date.distantPast
    /// Opens the main window again (RootView sets it): after Quit closed it, hiding left none to bring back
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init() {
        let c = Config()
        config = c
        repo = NXNativeRepo(url: c.nxnativeURL)
        builds.onFinished = { [weak self] job in
            guard let self else { return }
            switch job.state {
            case .succeeded: self.notice = LF("%@ is built.", job.name)
            case .failed(let m): self.notice = LF("%@: the build failed: %@", job.name, m)
            default: break
            }
            Task { await self.reloadLibrary(); await self.computeChanges() }
        }
        pads.onButton = { [weak self] b in Task { @MainActor in if self?.config.padNavigation ?? true { self?.handle(b) } } }
        pads.onHome = { [weak self] in Task { @MainActor in await self?.homePressed() } }
        cheats.pads = pads
        let wc = NSWorkspace.shared.notificationCenter
        // Logging out, restarting or shutting down: a suspended game goes on, so it can quit with the Mac (a stopped one cannot answer and would hold it up)
        wc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.session, s.paused else { return }
                if self.cloudConflict(s) != nil { DevLog.write("power off: \(s.game.titleID) closes without sending (another device saved it meanwhile)"); s.killWithoutSending() }
                else { DevLog.write("power off: \(s.game.titleID) goes on"); s.cont() }
            }
        }
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            wc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateRunning() } }
        }
        wc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.appActivated(app) }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        pads.start()
        let stopped = await GameSession.stoppedHosts()   // a game a previous NX Hub left suspended: kept at its instant once the library says which it is
        adopting = !stopped.isEmpty
        DevSnapshot.start(model: self)
        await Shell.loadUserPath()
        builds.restore(config: config)   // after the login shell's PATH: a queued build may start right away
        if config.keysPath.isEmpty, let k = config.findKeys(in: config.libraryURLs) { config.keysPath = k }
        DevLog.write("start: library \(config.libraryFolders), nxnative \(config.nxnativePath), python \(config.pythonPath), keys \(config.keysPath), PATH \(Shell.userPath ?? "(login shell PATH not read)")")
        await reloadLibrary()
        await adoptStopped(stopped)
        adopting = false
        startDone = true
        updateRunning()
        await repo.refresh()
        loadCatalog()
        if config.checkAtLaunch { await repo.fetch() }
        await computeChanges()
        nightTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.nightTick() } }
        nightTick()
    }

    func loadCatalog() {
        let root = repo.url
        Task {
            let entries = await Task.detached(priority: .utility) { Catalog.load(repo: root) }.value
            self.catalog = entries
            DevLog.write("catalog: \(entries.count) games, \(entries.filter { $0.image != nil }.count) with a picture")
        }
    }

    // MARK: navigation

    var selectedGame: Game? { games.indices.contains(homeIndex) ? games[homeIndex] : games.first }
    func goHome() { page = .home }
    func open(_ p: Page) { page = p }
    func openDock(_ item: DockItem) {
        switch item {
        case .library: page = .library
        case .catalog: page = .catalog
        case .mods: page = .mods(selectedGame?.titleID)
        case .cheats: page = .cheats(selectedGame?.titleID)
        case .saves: page = .saves
        case .controllers: page = .controllers
        case .nxnative: page = .nxnative
        case .settings: page = .settings
        }
    }

    /// A controller press: the start screen moves through its games and buttons; every other screen goes back with B
    func handle(_ b: PadButton) {
        guard !hiddenInBackground else { return }   // no window to act in
        if let c = cloudPrompt {
            guard Date().timeIntervalSince(cloudPromptAt) > 0.6 else { return }
            switch b {
            case .x: cloudPrompt = nil; Task { await closeKeepingCloud(c) }   // X closes, as on the start screen: the A that resumed never closes
            case .a: resumeNow()
            case .b: cloudPrompt = nil
            default: break
            }
            return
        }
        if let plan = switchPrompt {
            if plan.closing { return }
            switch b {
            case .a: switchPrompt = nil; resumeGame()
            case .x: switchPrompt = nil; Task { await closeAndPlay(plan) }
            case .b: switchPrompt = nil
            default: break
            }
            return
        }
        if let g = closePrompt {
            if b == .a { Task { await closeGame(g) } } else if b == .b { closePrompt = nil }
            return
        }
        guard page == .home else {
            if b == .b { goHome() }
            if b == .a, case .game(let id) = page, let g = games.first(where: { $0.titleID == id }), g.app != nil { Task { await play(g) } }
            return
        }
        switch (homeRow, b) {
        case (.games, .left): homeIndex = max(0, homeIndex - 1)
        case (.games, .right): homeIndex = min(max(0, games.count - 1), homeIndex + 1)
        case (.games, .down): homeRow = .dock
        case (.dock, .up): homeRow = .games
        case (.dock, .left): dockIndex = max(0, dockIndex - 1)
        case (.dock, .right): dockIndex = min(DockItem.allCases.count - 1, dockIndex + 1)
        case (.games, .a): if let g = selectedGame { if g.app != nil { Task { await play(g) } } else { page = .game(g.titleID) } }
        case (.games, .x): if let g = selectedGame { if isRunning(g) { closePrompt = g } else { page = .game(g.titleID) } }
        case (.games, .plus): if let g = selectedGame { page = .game(g.titleID) }
        case (.games, .y): if let g = selectedGame, g.canBuild { build(g) }
        case (.dock, .a): if let item = DockItem(rawValue: dockIndex) { openDock(item) }
        case (_, .minus): page = .settings
        case (.dock, .b): homeRow = .games
        default: break
        }
    }

    func reloadLibrary() async {
        scanning = true
        let folders = config.libraryURLs
        games = await Task.detached(priority: .userInitiated) { LibraryScanner.scan(folders: folders) }.value
        scanning = false
        DevLog.write("library: \(games.count) games")
        for g in games {
            DevLog.write("  \(g.titleID) \(g.name) | \(g.version ?? "-") | app \(g.app.map { Paths.pretty($0.url) } ?? "-") chain \(g.app?.chain ?? "-") commit \(g.app?.commit ?? "-") | build \(g.buildDir.map(Paths.pretty) ?? "-") | \(g.packages.count) packages | icon \(g.extractIcon != nil)")
        }
        updateRunning()
        if !config.cloudSavesFolder.isEmpty { applyCloudSaves() }   // a new or rebuilt app gets the folder too
        resetSyncBases()
    }

    func computeChanges() async {
        guard repo.valid else { changes = [:]; return }
        var out: [String: GameChanges] = [:]
        for g in games where g.app != nil { out[g.id] = await repo.changes(for: g, record: config.buildRecords[g.titleID]) }
        changes = out
        DevLog.write("repo: valid \(repo.valid) head \(repo.shortHead) branch \(repo.branch ?? "detached") dirty \(repo.dirty) upstream \(repo.upstream.prefix(8)) incoming \(repo.incoming.count) chain \(repo.chain) upstream chain \(repo.upstreamChain) error \(repo.error ?? "-")")
        DevLog.write("repo: edited \(repo.editedFiles) own \(repo.localCommits.map { "\($0.short) \($0.subject)" })")
        for (id, c) in out { DevLog.write("  changes \(id): known \(c.known) approx \(c.approximate) profile \(c.profile.count) engine \(c.engine) chainOutdated \(c.chainOutdated)") }
    }

    func nxnativePathChanged() async {
        repo = NXNativeRepo(url: config.nxnativeURL)
        await repo.refresh()
        await computeChanges()
    }

    func updateRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        if let s = session, !isRunning(s.game), !s.alive { endSession() }
        // A game opened another way (its app, the Dock) gets a session too: Home works in it (no pictures: it has no control file)
        if session == nil, !adopting, let g = games.first(where: { $0.app != nil && isRunning($0) }) {
            let s = GameSession(game: g, ctl: nil)
            s.syncFolder = syncFolder(g)
            beginSession(s, alreadyRunning: !startDone)
        }
        resetSyncBases()
    }

    /// The cloud folder a game started now syncs through ("" for none): what its launcher reads, for a build whose launcher reads it
    func syncFolder(_ g: Game, launchEnv: [String: String]? = nil) -> String {
        guard let app = g.app, CloudSaves.supported(app) else { return "" }
        return CloudSaves.effectiveFolder(of: app, launchEnv: launchEnv ?? config.launchEnvironment(g.titleID))
    }

    /// nxnative's record of a game's last sync (<save>.sync) goes once the game has ended when its cloud folder changed while it ran
    /// (applyCloudSaves): the first sync with the new folder then goes by date
    private func resetSyncBases() {
        guard startDone, !config.cloudSyncResetPending.isEmpty else { return }   // the library is read: a game not in it now stays pending
        var left: [String] = []
        for tid in config.cloudSyncResetPending {
            guard let g = games.first(where: { $0.titleID == tid }) else { left.append(tid); continue }
            if isRunning(g) || (session?.game.titleID == tid && session?.alive == true) { left.append(tid); continue }
            try? FileManager.default.removeItem(at: saveSlot(for: g).syncBase)
            DevLog.write("cloud saves: \(tid): record of the last sync removed (its folder changed while it ran)")
        }
        if left != config.cloudSyncResetPending { config.cloudSyncResetPending = left }
    }
    func isRunning(_ g: Game) -> Bool { running.contains(g.bundleID.lowercased()) }

    /// Starts the game's app without its own settings window: the choices saved here apply (nxnative docs/frontends.md, Starting a game).
    /// A running game comes back to the front (and goes on, when Home paused it)
    @discardableResult
    func play(_ g: Game, extraEnv: [String: String] = [:]) async -> Bool {
        guard let app = g.app, !opening.contains(g.titleID) else { return false }
        opening.insert(g.titleID)
        defer { opening.remove(g.titleID) }
        if isRunning(g) {
            if let s = session, s.game.titleID == g.titleID { resumeGame() } else { activate(g) }
            return true
        }
        // A game kept at its instant is not let go on behind another one: go back to it, or close it first (SwitchPrompt)
        if let s = session, s.game.titleID != g.titleID, s.paused || s.pausing, s.alive {
            switchPrompt = SwitchPlan(from: s.game, to: g)
            return false
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--no-launcher"]
        cfg.activates = true
        var extra = config.launchEnvironment(g.titleID).merging(extraEnv) { _, new in new }
        if extra["DM_ROMFS_OVERLAY"] == nil, let ov = ModStore.overlay(enabled: config.enabledMods[g.titleID] ?? [], mods: ModStore.list(g.titleID)) {
            extra["DM_ROMFS_OVERLAY"] = ov
        }
        // The control file the host reads (pictures of where you are); a DM_CTL of the launch options wins
        var ctl: URL?
        if extra["DM_CTL"] == nil, let c = GameSession.freshCtl(g.titleID) { extra["DM_CTL"] = c.path; ctl = c }
        if !extra.isEmpty { cfg.environment = extra }
        DevLog.write("play \(g.titleID): \(extra)")
        if config.backupBeforePlay {
            let slot = saveSlot(for: g)
            if slot.exists { _ = try? await SaveStore.backup(slot, label: "auto") }
        }
        let folder = syncFolder(g, launchEnv: extra)   // what its launcher reads as it starts
        let opened: NSRunningApplication
        do { opened = try await NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) }
        catch { notice = LF("Could not open %@: %@", g.name, error.localizedDescription); return false }
        let s = GameSession(game: g, ctl: ctl)
        s.launcherPID = opened.processIdentifier
        s.syncFolder = folder
        beginSession(s)
        if !(config.enabledCheats[g.titleID] ?? []).isEmpty { Task { await startCheatsWhenReady(g) } }
        return true
    }

    /// Cheats turned on for a game start once its host has logged where its memory is (a few seconds after it opens)
    func startCheatsWhenReady(_ g: Game) async {
        let opened = Date()
        for _ in 0..<40 {
            try? await Task.sleep(for: .seconds(1.5))
            guard let mod = Paths.modified(Paths.gameLog(g.titleID)), mod > opened, CheatSession.bases(g.titleID) != nil,
                  await CheatSession.hostPID(g) != nil else { continue }
            let all = CheatStore.cheats(g.titleID).flatMap { $0.cheats }
            await cheats.start(game: g, cheats: all, enabled: config.enabledCheats[g.titleID] ?? [])
            if case .failed(let m) = cheats.status { notice = LF("Cheats for %@: %@", g.name, m) }
            return
        }
    }

    // MARK: the game in play

    private func beginSession(_ s: GameSession, alreadyRunning: Bool = false) {
        if let old = session, old !== s, old.savePending { Task { await gameSaved(old, flush: true) } }   // its last commits: whole by now
        session?.end()
        session = s
        s.onShot = { [weak self] in self?.shotStamp += 1 }
        s.startShots(every: config.shotMinutes)
        s.watchEnd { [weak self, weak s] in if let self, let s, self.session === s { self.endSession() } }
        let slot = saveSlot(for: s.game)
        s.watchSaves([slot.folder, slot.device], alreadyRunning: alreadyRunning,
                     first: { [weak self, weak s] in if let self, let s { Task { await self.gameSaving(s) } } },
                     saved: { [weak self, weak s] in if let self, let s { Task { await self.gameSaved(s) } } })
        pads.monitorInBackground("game", config.homeButton)
        DevLog.write("session \(s.game.titleID): launcher \(s.launcherPID), control file \(s.ctl?.path ?? "none")")
        Task {
            for _ in 0..<30 {
                if await s.findProcesses() { DevLog.write("session \(s.game.titleID): host \(s.hostPID), launcher \(s.launcherPID)"); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func endSession() {
        guard let s = session else { return }
        let pending = s.savePending
        s.end()
        session = nil
        if closePrompt?.titleID == s.game.titleID { closePrompt = nil }
        if switchPrompt?.from.titleID == s.game.titleID, switchPrompt?.closing != true { switchPrompt = nil }
        if cloudPrompt?.game.titleID == s.game.titleID { cloudPrompt = nil }
        resetSyncBases()
        pads.monitorInBackground("game", false)
        shotStamp += 1
        DevLog.write("session \(s.game.titleID): ended")
        let quit = hiddenInBackground   // NX Hub stayed out of sight only to hold this game: the Quit the player chose finishes now
        Task {
            if pending { await gameSaved(s, flush: true) }   // the last commits before it closed: the save is whole now
            if quit, hiddenInBackground, session == nil { DevLog.write("hidden: the game it held has ended, NX Hub quits"); NSApp.terminate(nil) }
        }
    }

    /// The controller's Home button. In a game started from NX Hub: a picture of where you are, NX Hub in front on its start screen with the game
    /// selected, the game paused. In NX Hub: back to the paused game, as the Switch's HOME menu does, else back to the start screen
    func homePressed() async {
        guard config.homeButton else { return }
        if hiddenInBackground {
            // The game NX Hub held out of sight went on (its window was clicked): Home in it does what it does in any game, below. Otherwise NX Hub comes back
            if let s = session, !s.paused, s.isFrontmost { leaveBackground() } else { showFromBackground(); return }
        }
        if NSApp.isActive {
            guard closePrompt == nil, cloudPrompt == nil, switchPrompt?.closing != true else { return }
            if let s = session, s.suspended { resumeGame() } else { page = .home; homeRow = .games }
            return
        }
        guard let s = session else { return }
        await s.findProcesses()
        guard s.isFrontmost else { return }
        DevLog.write("home: \(s.game.titleID) in front (host \(s.hostPID))")
        await s.shoot(timeout: 1.2)
        page = .home; homeRow = .games
        if let i = games.firstIndex(where: { $0.titleID == s.game.titleID }) { homeIndex = i }
        s.suspended = true
        s.pausing = config.pauseOnHome
        defer { s.pausing = false }
        let front = await bringForward()
        DevLog.write("home: NX Hub in front: \(front)")
        guard front else {
            s.suspended = false
            notice = L("macOS did not let NX Hub come to the front: switch to it with ⌘-Tab.")
            return
        }
        if config.pauseOnHome {
            try? await Task.sleep(for: .milliseconds(250))   // the game hears first that it lost focus (front_mac.m: focus state 2), then it stops
            // While its save went to the cloud the game ran on behind NX Hub: the picture again, of the instant it stops at (a covered window draws about once
            // a second), and a look again for a commit made meanwhile; all within one 15 s budget
            let started = Date()
            while s.suspended && !s.isFrontmost, await waitForCloudSend(s, budgetFrom: started) {
                await s.shoot(timeout: 1.5)
                if Date().timeIntervalSince(started) >= 15 { break }
            }
            if s.suspended && !s.isFrontmost { s.stop() }
        }
    }

    /// NX Hub to the front from behind a game. macOS 14 activates apps cooperatively (the app in front yields), so NX Hub asks in more than one way
    private func bringForward() async -> Bool {
        func came() async -> Bool {
            for _ in 0..<6 { if NSApp.isActive { return true }; try? await Task.sleep(for: .milliseconds(60)) }
            return NSApp.isActive
        }
        NSApp.unhide(nil)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain || $0.isMiniaturized }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()   // Quit closed it and was then cancelled
        }
        NSApp.activate()
        if await came() { return true }
        NSApp.activate(ignoringOtherApps: true)
        if await came() { DevLog.write("home: in front with activate(ignoringOtherApps:)"); return true }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg)
        if await came() { DevLog.write("home: in front through LaunchServices"); return true }
        return false
    }

    /// Back to the suspended game, unless another device saved it meanwhile: then CloudPrompt asks first
    func resumeGame() {
        closePrompt = nil
        switchPrompt = nil
        guard let s = session else { return }
        if let c = cloudConflict(s) {
            askCloud(c)
            DevLog.write("resume \(s.game.titleID): the cloud's save changed \(c.cloud) while it was paused (since \(s.pausedSince.map { "\($0)" } ?? "-")): asking")
            return
        }
        resumeNow()
    }

    /// Back to the suspended game as it is
    func resumeNow() {
        cloudPrompt = nil
        session?.resume()
    }

    /// Another device changed the cloud's file of a game paused here, after the pause began (this Mac's own send ends before it: waitForCloudSend).
    /// Going on would send this older instant over that save at the game's next commit (save_sync.c send_save replaces a changed cloud save, keeping a copy)
    func cloudConflict(_ s: GameSession) -> CloudConflict? {
        guard s.paused, s.syncs, let since = s.pausedSince,
              let cloud = CloudSaves.lastSync(s.game.titleID, in: s.syncFolder), cloud > since.addingTimeInterval(5) else { return nil }
        return CloudConflict(game: s.game, cloud: cloud)
    }

    /// Closes a game: the one NX Hub follows by default. A paused one whose cloud save another device changed meanwhile closes without running again
    /// (nothing of this instant is sent). Another running game (opened elsewhere) is asked to quit as its own Quit does
    func closeGame(_ g: Game? = nil) async {
        closePrompt = nil
        if let g, session?.game.titleID != g.titleID {
            for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier?.lowercased() == g.bundleID.lowercased() { a.terminate() }
            return
        }
        guard let s = session else { return }
        if cloudConflict(s) != nil { await s.closeWithoutSending() } else { await s.close() }
    }

    /// CloudPrompt's Close: the game closes as it is stopped, and its next start brings in the other device's save
    func closeKeepingCloud(_ c: CloudConflict) async {
        cloudPrompt = nil
        guard let s = session, s.game.titleID == c.game.titleID else { return }
        if s.paused { await s.closeWithoutSending() } else { await s.close() }   // it went on meanwhile: an ordinary Quit
        notice = LF("%@ is closed: its next start brings in the save from your other device.", c.game.name)
    }

    /// Closes the suspended game (what it saved stays; the rest of that instant is lost, as when the Switch closes software), then opens the other one.
    /// The prompt stays, with a spinner, until then
    func closeAndPlay(_ plan: SwitchPlan) async {
        guard let s = session, s.game.titleID == plan.from.titleID else { switchPrompt = nil; await play(plan.to); return }
        var busy = plan; busy.closing = true
        switchPrompt = busy
        if cloudConflict(s) != nil { await s.closeWithoutSending() } else { await s.close() }
        for _ in 0..<50 where s.alive { try? await Task.sleep(for: .milliseconds(200)) }   // its launcher syncs the save once the host has quit
        if s.alive { switchPrompt = nil; notice = LF("%@ is still closing: try again in a moment.", plan.from.name); return }
        if session === s { endSession() }
        await play(plan.to)
        switchPrompt = nil
    }

    /// A game a previous NX Hub left paused (it crashed, or was quit some other way, during a pause) stays at its instant: it is this session again, suspended.
    /// The game is known by its host's own path (the library may not list it). Any other stopped host goes on, as before (NX Hub follows one game at a time)
    private func adoptStopped(_ pids: [pid_t]) async {
        var adopted = false
        for pid in pids {
            var game: Game?
            if !adopted, let exe = await Shell.run("/bin/ps", ["-o", "command=", "-p", "\(pid)"]).out.split(separator: "\n").first,
               let r = exe.range(of: ".app/Contents/MacOS/") {
                let appURL = URL(fileURLWithPath: String(exe[..<r.lowerBound]) + ".app").resolvingSymlinksInPath()
                game = games.first { $0.app?.url.resolvingSymlinksInPath().path == appURL.path }
                if game == nil, let a = AppBundle(url: appURL) { game = Game(titleID: a.titleID, name: a.name, app: a) }
            }
            guard let g = game else { kill(pid, SIGCONT); DevLog.write("stray stopped host \(pid): SIGCONT"); continue }
            let ctl = GameSession.ctlFile(g.titleID)
            let s = GameSession(game: g, ctl: Paths.exists(ctl) ? ctl : nil)
            s.syncFolder = syncFolder(g)
            s.hostPID = pid
            if let p = Proc.parent(pid), p > 1 { s.launcherPID = p }
            let still = Proc.stopped(pid)   // something may have let it go on meanwhile
            s.suspended = still; s.paused = still
            s.pausedSince = still ? (GameSession.keptPause(g.titleID, host: pid) ?? Paths.modified(saveSlot(for: g).syncBase)) : nil   // unknown: no cloud check
            beginSession(s, alreadyRunning: true)
            if let i = games.firstIndex(where: { $0.titleID == g.titleID }) { homeIndex = i }
            adopted = true
            DevLog.write("session \(g.titleID): host \(pid) found \(still ? "paused: kept suspended at its instant" : "running")")
        }
    }

    /// NX Hub out of sight after Quit with a game kept suspended: no window and no Dock icon, still holding the game (and letting it go on if the Mac shuts down)
    func hideInBackground() {
        hiddenInBackground = true
        hiddenAt = Date()
        // Activation goes to the Finder, not to the stopped game behind NX Hub (appActivated would let it go on); hide() also leaves a full-screen Space
        if let f = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first { NSApp.yieldActivation(to: f); f.activate() }
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
        DevLog.write("hidden in the background with \(session?.game.titleID ?? "-") suspended")
    }

    /// Back from hiding: opening NX Hub again, or the controller's Home button. Returns whether it brought back a window it had hidden (else it opens the window anew)
    @discardableResult
    func showFromBackground() -> Bool {
        guard hiddenInBackground else { return true }
        let had = leaveBackground()
        page = .home; homeRow = .games
        if let s = session, let i = games.firstIndex(where: { $0.titleID == s.game.titleID }) { homeIndex = i }
        Task { _ = await bringForward() }   // macOS 14 activates cooperatively: the same ways as Home
        return had
    }

    /// NX Hub's window again after a Quit that closed it was cancelled
    func reopenIfClosed() {
        if !NSApp.windows.contains(where: { $0.canBecomeMain || $0.isMiniaturized }) { openMainWindow?() }
    }

    /// Out of hiding without coming to the front, for Home in the game it held (that takes its picture, then brings NX Hub forward). Returns whether
    /// NX Hub's window was still there (else it opens anew: Quit had closed it)
    @discardableResult
    private func leaveBackground() -> Bool {
        hiddenInBackground = false
        NSApp.setActivationPolicy(.regular)
        NSApp.unhideWithoutActivation()
        let had = NSApp.windows.contains { $0.canBecomeMain || $0.isMiniaturized }
        if !had { openMainWindow?() }
        return had
    }

    /// With cloud saves on, nxnative sends a committed save from a thread of the game itself once the game has not committed for 3 s (dm/host/save_sync.c
    /// QUIET_MS): a game stopped before that keeps an unsent save. So the game, already out of focus, stops only once no send can be pending: 4 s after its
    /// last commit (the sender's quiet time and NX Hub's polling), and not while a send runs (send_save works in <save>.sync-tmp/out and removes it however it
    /// ends: sent, already in step, or failed). At most 15 s (a fetch of the cloud's copy may take 10 s, FETCH_MS). Returns whether it waited
    @discardableResult
    private func waitForCloudSend(_ s: GameSession, budgetFrom started: Date) async -> Bool {
        guard s.syncs else { return false }
        let began = Date()
        var waited = false
        var busyFrom: Date?             // the sync work seen running (a send, the first mount's fetch), since when
        var busyEnded: Date?            // when the last one seen ended
        var commitDuringBusy = false    // a commit came after that work began: the sender sends again once quiet, counted from its end
        while s.suspended && !s.isFrontmost {
            s.pollSaves()   // a commit just before Home: the timer may not have seen it yet
            let now = Date()
            if let b = s.syncBusySince {
                busyFrom = b; busyEnded = nil
                commitDuringBusy = s.lastCommitAt.map { $0 > b.addingTimeInterval(-1) } ?? false   // seen up to a second late
            } else if busyFrom != nil {
                busyFrom = nil; busyEnded = now
            }
            let quietAfterCommit = s.lastCommitAt.map { now.timeIntervalSince($0) < 4 } ?? false
            let quietAfterSend = commitDuringBusy && (busyEnded.map { now.timeIntervalSince($0) < 4 } ?? false)
            guard busyFrom != nil || quietAfterCommit || quietAfterSend else { break }
            if now.timeIntervalSince(started) >= 15 { DevLog.write("home: \(s.game.titleID): its save was still on its way to the cloud after 15 s; paused anyway"); break }
            if !waited { waited = true; s.sendingSave = true; DevLog.write("home: \(s.game.titleID): waiting for its save to reach the cloud") }
            try? await Task.sleep(for: .milliseconds(250))
        }
        s.sendingSave = false
        if waited { DevLog.write("home: \(s.game.titleID): waited \(String(format: "%.1f", Date().timeIntervalSince(began))) s for its save to reach the cloud") }
        return waited
    }

    // MARK: saves

    /// The game started saving (the first commit of a burst): the picture closest to that moment, kept for the backup made once the burst ends
    func gameSaving(_ s: GameSession) async {
        guard config.backupOnGameSave, session === s, s.ctl != nil else { return }
        let tid = s.game.titleID
        guard await s.shoot(timeout: 1.5) else { return }
        let p = ShotStore.folder(tid).appendingPathComponent("saving.png")
        try? FileManager.default.removeItem(at: p)
        if (try? FileManager.default.copyItem(at: ShotStore.last(tid), to: p)) != nil { pendingShots[tid] = p }
    }

    /// The game saved (its commits ended): a backup of that save with the picture taken as it began, so the backup shows where restoring it lands. None when the
    /// save is the same as the last one; the newest config.gameSaveBackups of those stay (Settings › Saves). `flush`: the session has ended meanwhile
    func gameSaved(_ s: GameSession, flush: Bool = false) async {
        guard config.backupOnGameSave, flush || session === s else { return }
        let tid = s.game.titleID
        let shot = pendingShots.removeValue(forKey: tid)
        defer { if let shot { try? FileManager.default.removeItem(at: shot) } }
        let slot = saveSlot(for: s.game)
        guard slot.exists else { return }
        do {
            let r = try await SaveStore.gameBackup(slot, picture: shot, previous: lastGameSave[tid])
            lastGameSave[tid] = r.signature
            guard let z = r.zip else { DevLog.write("game save \(tid): the same as the last backup"); return }
            SaveStore.prune(tid, label: "game", keep: config.gameSaveBackups)
            DevLog.write("game save \(tid): backup \(z.lastPathComponent)\(shot == nil ? " (no picture)" : "")")
        } catch {
            DevLog.write("game save \(tid): backup failed: \(error.localizedDescription)")
        }
        shotStamp += 1
    }

    /// What applyCloudSaves found: games whose apps are too old for cloud saves, games whose own window chose otherwise, and whether iCloud Drive is off
    struct CloudReport { var tooOld: [Game] = []; var ownChoice: [Game] = []; var iCloudOff = false }

    /// Writes the cloud saves folder (config.cloudSavesFolder) into every game's app that reads it, or takes NX Hub's folder out of them when it is "".
    /// Only apps with no folder yet, or with the one NX Hub wrote last, are changed: a folder the player chose (or turned off) in a game's own window stays.
    /// When an app's folder changes, nxnative's record of its last sync (<save>.sync, which does not say which folder) is removed, so the first sync with the
    /// new folder goes by date instead of taking that folder's save as newer (dm/host/save_sync.c ss_decide)
    @discardableResult
    func applyCloudSaves() -> CloudReport {
        var r = CloudReport()
        var want = config.cloudSavesFolder
        if !want.isEmpty, CloudSaves.unreachable(want) { r.iCloudOff = true; want = "" }   // iCloud Drive off: none, until it is back
        var written = config.cloudSavesWritten
        for g in games {
            guard let app = g.app else { continue }
            let raw = CloudSaves.rawFolder(of: app), mine = written[app.bundleID]
            if want.isEmpty {
                if let mine, raw == mine { CloudSaves.set(nil, for: app) }
                written[app.bundleID] = nil
                continue
            }
            guard CloudSaves.supported(app) else { r.tooOld.append(g); continue }
            guard raw == nil || raw == mine else { r.ownChoice.append(g); continue }
            if raw != want {
                CloudSaves.set(want, for: app)
                if isRunning(g) { if !config.cloudSyncResetPending.contains(g.titleID) { config.cloudSyncResetPending.append(g.titleID) } }
                else { try? FileManager.default.removeItem(at: saveSlot(for: g).syncBase) }
            }
            written[app.bundleID] = want
        }
        if written != config.cloudSavesWritten { config.cloudSavesWritten = written }
        DevLog.write("cloud saves: \(want.isEmpty ? "off" : want); too old \(r.tooOld.map(\.titleID)); own choice \(r.ownChoice.map(\.titleID)); iCloud off \(r.iCloudOff)")
        return r
    }

    /// Back to the game some other way (⌘-Tab, its window, the Dock): it goes on. Unless another device saved it meanwhile: then it stays stopped, and NX Hub
    /// comes forward to ask (CloudPrompt)
    private func appActivated(_ app: NSRunningApplication?) {
        guard let app, let s = session, s.owns(app) else { return }
        if switchPrompt?.from.titleID == s.game.titleID, switchPrompt?.closing != true { switchPrompt = nil }
        guard s.suspended || s.paused else { return }
        if hiddenInBackground && Date().timeIntervalSince(hiddenAt) < 2 { DevLog.write("activated \(s.game.titleID) right after hiding: kept as it is"); return }
        if let c = cloudConflict(s) {
            askCloud(c)
            if hiddenInBackground { showFromBackground() } else { Task { _ = await bringForward() } }
            DevLog.write("activated \(s.game.titleID) while paused, its cloud save changed meanwhile: kept stopped, asking")
            return
        }
        s.cont()
        s.suspended = false
    }

    // MARK: builds for the night

    func nightTick() {
        let waiting = !config.nightQueue.isEmpty
        nightGuard.set(waiting && config.awakeWhileBuilding && MacBattery.onAC, reason: "NX Hub: builds waiting for the night")
        guard waiting else { return }
        let h = Calendar.current.component(.hour, from: Date())
        guard (h - config.nightHour + 24) % 24 < 3 else { return }
        let ids = config.nightQueue
        config.nightQueue = []
        nightGuard.set(false, reason: "")
        var n = 0
        for id in ids { if let g = games.first(where: { $0.titleID == id }), g.canBuild, !isRunning(g) { build(g); n += 1 } }
        DevLog.write("night builds: \(ids) started \(n)")
        if n > 0 { notice = LF("Night builds started: %lld games.", n) }
    }

    func toggleNight(_ g: Game) {
        if config.nightQueue.contains(g.titleID) { config.nightQueue.removeAll { $0 == g.titleID } } else { config.nightQueue.append(g.titleID) }
        nightTick()
    }

    func toggleKept(_ g: Game) {
        if config.keptBuilds.contains(g.titleID) { config.keptBuilds.removeAll { $0 == g.titleID } } else { config.keptBuilds.append(g.titleID) }
    }

    func activate(_ g: Game) {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.lowercased() == g.bundleID.lowercased() }?.activate()
    }

    func build(_ g: Game) {
        guard let folder = g.folder, !g.packages.isEmpty else { notice = LF("%@ has no NSP files in its folder to build from.", g.name); return }
        if isRunning(g) { notice = LF("Quit %@ before rebuilding it.", g.name); return }
        builds.enqueue(BuildJob(titleID: g.titleID, name: g.name, folder: folder, appOut: g.app?.url, source: config.source(for: g.titleID)), config: config)
    }

    func saveSlot(for g: Game) -> SaveSlot {
        let folder = g.app != nil || g.buildDir == nil ? Paths.gameSaves(g.titleID) : g.buildDir!.appendingPathComponent("run/save")
        return SaveStore.slot(g.titleID, g.name, folder)
    }

    /// A game from the catalog: its files go into a new folder of the first library folder (an APFS clone when on the same volume), then it is built
    func addGame(_ e: CatalogEntry, files: [URL]) async throws {
        guard let root = config.libraryURLs.first else { throw NSError(domain: "NXHub", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Add a library folder in Settings first.")]) }
        let name = e.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files {
                let dest = dir.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: f, to: dest) }
            }
        }.value
        await reloadLibrary()
        if let g = games.first(where: { $0.titleID == e.id }) {
            build(g)
            notice = LF("%@ is in %@ and building.", e.name, Paths.pretty(dir))
            page = .game(g.titleID)
        } else {
            notice = LF("The files are in %@, but NX Hub does not see %@ there: check that they are this game's.", Paths.pretty(dir), e.name)
        }
    }

    // MARK: settings for every game

    /// One row per setting any game has (the first game's description), for Settings › All games
    var allGameSettings: [Setting] {
        var seen = Set<String>(), out: [Setting] = []
        for g in games {
            guard let app = g.app, let s = GameSettings(app: app) else { continue }
            for row in s.list.settings where row.kind != .unknown && seen.insert(row.env).inserted { out.append(row) }
        }
        return out
    }

    /// The choices a setting has across the games (a language one game lacks is offered anyway; games without it keep theirs)
    func choices(for env: String) -> [Setting.Choice] {
        var seen = Set<String>(), out: [Setting.Choice] = []
        for g in games {
            guard let app = g.app, let s = GameSettings(app: app), let row = s.list.settings.first(where: { $0.env == env }) else { continue }
            for c in row.choices where seen.insert(c.value).inserted { out.append(c) }
        }
        return out
    }

    /// Writes a value into every game that has the setting and accepts the value (as its own saved choice); returns how many took it
    @discardableResult
    func applyToAllGames(_ env: String, _ value: String?) -> Int {
        var n = 0
        for g in games {
            guard let app = g.app, let s = GameSettings(app: app), let row = s.list.settings.first(where: { $0.env == env }) else { continue }
            if let value {
                guard row.accepts(value) else { continue }
                s.set(row, value)
            } else {
                s.saved.set(env, nil)
            }
            n += 1
        }
        config.globalSettings[env] = value
        return n
    }

    /// nxnative changed something for the game since its build that a rebuild would bring: its profile, or (unless turned off) its shaders. Not for a build kept as it is
    func worthRebuilding(_ g: Game) -> Bool {
        guard g.canBuild, !config.keptBuilds.contains(g.titleID), let c = changes[g.id] else { return false }
        return !c.profile.isEmpty || (config.rebuildForShaders && c.chainOutdated)
    }

    var gamesWorthRebuilding: [Game] { games.filter { worthRebuilding($0) } }
}
