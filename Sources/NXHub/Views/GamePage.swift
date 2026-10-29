import SwiftUI

/// One game: its art and actions, then its settings, what nxnative changed for it, its mods, saves, launch options and files
struct GamePage: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var body: some View {
        ZStack {
            ArtBackground(image: GameArt.image(game), dim: 0.74)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Button { model.goHome() } label: { HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Home") } }
                            .buttonStyle(GlassPill())
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Menu { GameMenuItems(game: game) } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)) }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                    }
                    hero
                    if let job = model.builds.job(for: game.titleID) {
                        BuildProgressCard(job: job, compact: true)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 18) {
                            GroupBox("Game settings") {
                                if let app = game.app {
                                    SettingsFormView(app: app, running: model.isRunning(game))
                                } else {
                                    Text("Build the Mac app to get its settings: graphics, controls and performance.").foregroundStyle(Theme.secondary)
                                }
                            }
                            LaunchOptionsBox(game: game)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        VStack(alignment: .leading, spacing: 18) {
                            NXNativeStatus(game: game)
                            SaveMini(game: game)
                            ExtrasMini(game: game)
                            FilesBox(game: game)
                        }
                        .frame(width: 400, alignment: .top)
                    }
                }
                .padding(.horizontal, 48).padding(.vertical, 28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 30) {
            GameTileArt(game: game, size: 210)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            VStack(alignment: .leading, spacing: 12) {
                Text(game.name).font(.system(size: 40, weight: .heavy)).lineLimit(2)
                Text([game.version.map { LF("Version %@", $0) }, game.titleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                StatusChips(game: game)
                HStack(spacing: 12) {
                    if game.app != nil {
                        let suspended = model.session?.game.titleID == game.titleID && model.session?.suspended == true
                        Button { Task { await model.play(game) } } label: {
                            Label(LocalizedStringKey(suspended ? "Resume" : model.isRunning(game) ? "Show Game" : "Play"), systemImage: "play.fill").frame(minWidth: 110)
                        }
                        .buttonStyle(PrimaryPill())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.builds.job(for: game.titleID) != nil)
                        if model.isRunning(game) {
                            Button { model.closePrompt = game } label: { Label("Close Game", systemImage: "xmark") }.buttonStyle(GlassPill(tint: Theme.bad))
                        }
                    }
                    if game.canBuild {
                        Button { model.build(game) } label: { Label(LocalizedStringKey(game.app == nil ? "Build App" : "Rebuild"), systemImage: "hammer.fill") }
                            .buttonStyle(GlassPill())
                            .disabled(model.builds.job(for: game.titleID) != nil)
                            .help("Builds the game again with the nxnative checkout: the newest profile, host and shaders")
                    }
                    Button { model.open(.mods(game.titleID)) } label: { Label("Mods", systemImage: "puzzlepiece.extension.fill") }.buttonStyle(GlassPill())
                    Button { model.open(.cheats(game.titleID)) } label: { Label("Cheats", systemImage: "wand.and.stars") }.buttonStyle(GlassPill())
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

/// How the game's build stands against nxnative
private struct NXNativeStatus: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var showAll = false

    var body: some View {
        GroupBox("nxnative") {
            VStack(alignment: .leading, spacing: 10) {
                if let app = game.app {
                    let record = model.config.buildRecords[game.titleID]
                    InfoRow(L("Built"), app.builtAt.map { $0.relative } ?? "—")
                    InfoRow(L("nxnative commit"), app.commit ?? record?.first.flatMap { $0.isEmpty ? nil : $0 + " " + L("(recorded by NX Hub)") } ?? L("unknown (an app built before nxnative stamped it)"))
                    InfoRow(L("Shaders"), app.chain.map { c in c == model.repo.upstreamChain || model.repo.upstreamChain.isEmpty ? c : LF("%@ · nxnative is at %@", c, model.repo.upstreamChain) } ?? "—")
                } else {
                    Text(LocalizedStringKey(game.kind == .devBuild
                        ? "This game has an nxnative build folder but no Mac app: Build App makes one from it, reusing the extraction."
                        : "This game is not built yet. Build App extracts it and builds it with nxnative (it takes a while the first time)."))
                        .foregroundStyle(Theme.secondary)
                }
                SourcePicker(game: game)
                if game.canBuild {
                    Toggle("Keep this build (NX Hub does not suggest rebuilding it)", isOn: Binding(get: { model.config.keptBuilds.contains(game.titleID) }, set: { _ in model.toggleKept(game) }))
                        .font(.callout)
                    if model.config.nightQueue.contains(game.titleID) {
                        HStack {
                            Label(LF("Builds tonight at %@", NightHour.text(model.config.nightHour)), systemImage: "moon.stars.fill").foregroundStyle(Theme.accent)
                            Spacer()
                            Button("Cancel") { model.toggleNight(game) }.buttonStyle(.link)
                        }
                        .font(.callout)
                    }
                }
                if let last = BuildStats.load()[game.titleID] { LastBuildTimes(entry: last) }
                if let c = model.changes[game.id] {
                    Divider().overlay(Theme.stroke)
                    if !c.known {
                        Text("NX Hub cannot tell which nxnative this app was built with. Rebuilding it starts tracking it.").foregroundStyle(Theme.secondary)
                    } else if c.profile.isEmpty && !c.chainOutdated && c.engine == 0 {
                        Label("Up to date with nxnative", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    } else {
                        if c.chainOutdated {
                            Label("nxnative translates shaders differently now: a rebuild gives this game the new shaders.", systemImage: "sparkles").foregroundStyle(Theme.warn)
                        }
                        if !c.profile.isEmpty {
                            Label(LF("%lld changes to this game's profile since your build%@", c.profile.count, c.approximate ? " " + L("(by date)") : ""), systemImage: "wrench.and.screwdriver.fill")
                                .font(.headline)
                            ForEach(showAll ? c.profile : Array(c.profile.prefix(5))) { commit in
                                CommitRow(commit: commit, showTags: false)
                            }
                            if c.profile.count > 5 {
                                Button(LocalizedStringKey(showAll ? "Show Fewer" : "Show All")) { showAll.toggle() }.buttonStyle(.link)
                            }
                        }
                        if c.engine > 0 {
                            Text(LF("%lld changes to the host and graphics since your build%@", c.engine, c.approximate ? " " + L("(by date)") : ""))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Which checkout builds this game: the main one, or another (a game whose profile is still in a pull request)
private struct SourcePicker: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let override = model.config.sourceOverrides[game.titleID]
        HStack {
            Text("Builds with").foregroundStyle(Theme.secondary)
            Text(Paths.pretty(model.config.source(for: game.titleID))).font(.callout.monospaced())
            Spacer()
            Menu("Change") {
                Button("Main nxnative checkout") { model.config.sourceOverrides[game.titleID] = nil }
                    .disabled(override == nil)
                Button("Another Folder…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    p.message = L("Choose an nxnative checkout (a clone or worktree with scripts/build_ipa_from_nsp.py)")
                    if p.runModal() == .OK, let u = p.url {
                        if NXNativeRepo.isCheckout(u) { model.config.sourceOverrides[game.titleID] = u.path }
                        else { model.notice = L("This folder is not an nxnative checkout.") }
                    }
                }
            }
            .fixedSize()
        }
        .font(.callout)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.secondary).frame(width: 160, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct FilesBox: View {
    let game: Game

    var body: some View {
        GroupBox("Files") {
            VStack(alignment: .leading, spacing: 8) {
                if let f = game.folder { PathRow(L("Game folder"), f) }
                if let a = game.app { PathRow(L("App"), a.url) }
                PathRow(L("Saves"), Paths.gameSaves(game.titleID))
                PathRow(L("Log"), Paths.gameLog(game.titleID))
                PathRow(L("Your env.txt"), Paths.playerEnv(game.titleID))
                PathRow(L("Mods"), ModStore.folder(game.titleID))
                if !game.packages.isEmpty {
                    Text(LF("%lld packages: %@", game.packages.count, game.packages.map { $0.lastPathComponent }.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(Theme.tertiary).lineLimit(3)
                }
            }
        }
    }
}

private struct PathRow: View {
    let label: String
    let url: URL
    init(_ label: String, _ url: URL) { self.label = label; self.url = url }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.secondary).frame(width: 160, alignment: .leading)
            Text(Paths.pretty(url)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 8)
            if Paths.exists(url) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            } else {
                Text("not there yet").font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

/// Switches for the game's starts from NX Hub (diagnostics, settings a game has no row for)
private struct LaunchOptionsBox: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        @Bindable var config = model.config
        GroupBox("Launch options") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(get: { config.launchEnv[game.titleID] ?? "" },
                                         set: { config.launchEnv[game.titleID] = $0.isEmpty ? nil : $0 }))
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                Text("One KEY=VALUE per line (for example DM_METAL_HUD=1). NX Hub adds them when it starts this game; they win over the settings above, only for starts from NX Hub.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                let n = config.launchEnvironment(game.titleID).count
                if n > 0 { Chip(text: LF("%lld active", n), color: Theme.warn) }
            }
        }
    }
}

/// The game's save at a glance
private struct SaveMini: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let slot = model.saveSlot(for: game)
        let _ = model.shotStamp
        GroupBox("Saves") {
            VStack(alignment: .leading, spacing: 10) {
                if let img = ShotStore.lastImage(game.titleID) {
                    ShotThumb(image: img, game: game, width: 364)
                    if let d = Paths.modified(ShotStore.last(game.titleID)) {
                        Label(LF("Where you left it, %@", d.relative), systemImage: "camera.fill").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                Text(slot.exists ? LF(slot.files == 1 ? "%lld file · %@ · saved %@" : "%lld files · %@ · saved %@", slot.files, slot.size.bytes, slot.modified?.relative ?? "—") : L("No save yet"))
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                HStack {
                    Button { Task { if let z = try? await SaveStore.backup(slot) { model.notice = LF("Saved a backup: %@", z.lastPathComponent) } } } label: { Label("Back Up", systemImage: "arrow.down.doc.fill") }
                        .buttonStyle(GlassPill()).disabled(!slot.exists)
                    Button { model.open(.saves) } label: { Label("Import or Restore…", systemImage: "clock.arrow.circlepath") }.buttonStyle(GlassPill())
                }
            }
        }
    }
}

/// Mods and cheats turned on for the game
private struct ExtrasMini: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let mods = model.config.enabledMods[game.titleID] ?? []
        let cheats = model.config.enabledCheats[game.titleID] ?? []
        GroupBox("Mods and cheats") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Color(red: 0.75, green: 0.55, blue: 1))
                    Text(mods.isEmpty ? L("No mods turned on") : LF("%lld mods on: %@", mods.count, mods.joined(separator: ", "))).lineLimit(2)
                    Spacer()
                    Button("Manage") { model.open(.mods(game.titleID)) }.buttonStyle(.link)
                }
                HStack {
                    Image(systemName: "wand.and.stars").foregroundStyle(Theme.warn)
                    Text(cheats.isEmpty ? L("No cheats turned on") : LF("%lld cheats on: %@", cheats.count, cheats.joined(separator: ", "))).lineLimit(2)
                    Spacer()
                    Button("Manage") { model.open(.cheats(game.titleID)) }.buttonStyle(.link)
                }
            }
            .font(.system(size: 13))
        }
    }
}

/// The last build of a game, step by step: how long each took and how many of the Mac's cores it kept busy
struct LastBuildTimes: View {
    let entry: BuildStats.Entry
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack {
                    Image(systemName: "stopwatch")
                    Text(LF("Last build: %@ (%@)", BuildStats.duration(entry.total), entry.date.relative))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption)
                }
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(Theme.secondary)
            if open { StageTimesTable(stages: entry.stages, total: entry.total) }
        }
    }
}

/// Steps of a build with their time, a bar of their share, and the cores in use while they ran
struct StageTimesTable: View {
    let stages: [StageTime]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(stages.enumerated()), id: \.offset) { _, st in
                HStack(spacing: 8) {
                    Text(st.name).lineLimit(1).frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Theme.accent.opacity(0.75))
                            .frame(width: max(3, g.size.width * CGFloat(total > 0 ? st.seconds / total : 0)))
                    }
                    .frame(height: 6)
                    Text(BuildStats.duration(st.seconds)).monospacedDigit().frame(width: 62, alignment: .trailing)
                    Text(st.cores.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 34, alignment: .trailing)
                        .help("Cores busy on average while the step ran")
                }
                .font(.system(size: 11))
            }
            if let k = CPULoad.kinds {
                Text(LF("Last column: cores busy on average, of %lld (%lld performance, %lld efficiency). A step far below that waits on one core.", CPULoad.count, k.p, k.e))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(LF("Last column: cores busy on average, of %lld. A step far below that waits on one core.", CPULoad.count))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum NightHour {
    static func text(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h; c.minute = 0
        return (Calendar.current.date(from: c) ?? Date()).formatted(date: .omitted, time: .shortened)
    }
}
