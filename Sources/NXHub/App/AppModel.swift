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
        await GameSession.continueStrays()
        DevSnapshot.start(model: self)
        await Shell.loadUserPath()
        builds.restore(config: config)   // after the login shell's PATH: a queued build may start right away
        if config.keysPath.isEmpty, let k = config.findKeys(in: config.libraryURLs) { config.keysPath = k }
        DevLog.write("start: library \(config.libraryFolders), nxnative \(config.nxnativePath), python \(config.pythonPath), keys \(config.keysPath), PATH \(Shell.userPath ?? "(login shell PATH not read)")")
        await reloadLibrary()
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
        if closePrompt != nil {
            if b == .a { Task { await closeGame() } } else if b == .b { closePrompt = nil }
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
    }

    func computeChanges() async {
        guard repo.valid else { changes = [:]; return }
        var out: [String: GameChanges] = [:]
        for g in games where g.app != nil { out[g.id] = await repo.changes(for: g, record: config.buildRecords[g.titleID]) }
        changes = out
        DevLog.write("repo: valid \(repo.valid) head \(repo.shortHead) branch \(repo.branch ?? "detached") dirty \(repo.dirty) upstream \(repo.upstream.prefix(8)) incoming \(repo.incoming.count) chain \(repo.chain) upstream chain \(repo.upstreamChain) error \(repo.error ?? "-")")
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
        if session == nil, let g = games.first(where: { $0.app != nil && isRunning($0) }) { beginSession(GameSession(game: g, ctl: nil)) }
    }
    func isRunning(_ g: Game) -> Bool { running.contains(g.bundleID.lowercased()) }

    /// Starts the game's app without its own settings window: the choices saved here apply (nxnative docs/frontends.md, Starting a game).
    /// A running game comes back to the front (and goes on, when Home paused it)
    func play(_ g: Game) async {
        guard let app = g.app else { return }
        if isRunning(g) {
            if let s = session, s.game.titleID == g.titleID { resumeGame() } else { activate(g) }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--no-launcher"]
        cfg.activates = true
        var extra = config.launchEnvironment(g.titleID)
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
        let opened: NSRunningApplication
        do { opened = try await NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) }
        catch { notice = LF("Could not open %@: %@", g.name, error.localizedDescription); return }
        let s = GameSession(game: g, ctl: ctl)
        s.launcherPID = opened.processIdentifier
        beginSession(s)
        if !(config.enabledCheats[g.titleID] ?? []).isEmpty { Task { await startCheatsWhenReady(g) } }
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

    private func beginSession(_ s: GameSession) {
        session?.end()
        session = s
        s.onShot = { [weak self] in self?.shotStamp += 1 }
        s.startShots(every: config.shotMinutes)
        s.watchEnd { [weak self, weak s] in if let self, let s, self.session === s { self.endSession() } }
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
        s.end()
        session = nil
        if closePrompt?.titleID == s.game.titleID { closePrompt = nil }
        pads.monitorInBackground("game", false)
        shotStamp += 1
        DevLog.write("session \(s.game.titleID): ended")
    }

    /// The controller's Home button. In a game started from NX Hub: a picture of where you are, NX Hub in front on its start screen with the game
    /// selected, the game paused. In NX Hub: back to the paused game, as the Switch's HOME menu does, else back to the start screen
    func homePressed() async {
        guard config.homeButton else { return }
        if NSApp.isActive {
            guard closePrompt == nil else { return }
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
        let front = await bringForward()
        DevLog.write("home: NX Hub in front: \(front)")
        guard front else {
            s.suspended = false
            notice = L("macOS did not let NX Hub come to the front: switch to it with ⌘-Tab.")
            return
        }
        if config.pauseOnHome {
            try? await Task.sleep(for: .milliseconds(250))   // the game hears first that it lost focus (front_mac.m: focus state 2), then it stops
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
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
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

    func resumeGame() {
        guard let s = session else { return }
        closePrompt = nil
        s.resume()
    }

    func closeGame() async {
        guard let s = session else { return }
        closePrompt = nil
        await s.close()
    }

    /// Back to the game some other way (⌘-Tab, its window, the Dock): it goes on
    private func appActivated(_ app: NSRunningApplication?) {
        guard let app, let s = session, s.owns(app), s.suspended || s.paused else { return }
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
