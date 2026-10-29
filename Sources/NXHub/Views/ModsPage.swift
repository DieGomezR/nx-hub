import SwiftUI

/// Mods per game: pick the game, then its installed mods (turn on, order, remove) or GameBanana's to download
struct ModsPage: View {
    @Environment(AppModel.self) private var model
    let initial: String?
    @State private var selected: String?
    @State private var tab = 0

    var body: some View {
        PageShell(title: L("Mods"), systemImage: "puzzlepiece.extension.fill") {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(model.games) { g in
                            VStack(spacing: 6) {
                                GameTileArt(game: g, size: 76)
                                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(selected == g.titleID ? Theme.accent : .clear, lineWidth: 4).padding(-5))
                                Text(g.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 84)
                                    .foregroundStyle(selected == g.titleID ? Theme.text : Theme.secondary)
                            }
                            .onTapGesture { selected = g.titleID }
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 8)
                }
                HStack {
                    Picker("", selection: $tab) {
                        Text("Installed").tag(0)
                        Text("Explore GameBanana").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Button { importAtmosphere() } label: { Label("Import from an Atmosphère folder…", systemImage: "sdcard") }.buttonStyle(GlassPill())
                }
                .padding(.horizontal, 32)
                if let id = selected, let g = model.games.first(where: { $0.titleID == id }) {
                    if tab == 0 {
                        ScrollView {
                            ModsList(titleID: id)
                                .padding(.horizontal, 32).padding(.bottom, 32)
                                .frame(maxWidth: 1100, alignment: .leading)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        ModBrowser(game: g).id(id)
                    }
                }
            }
        }
        .onAppear {
            selected = initial ?? model.selectedGame?.titleID ?? model.games.first?.titleID
            if DevSnapshot.tab == "explore" { tab = 1; DevSnapshot.tab = nil }
        }
    }

    private func importAtmosphere() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = L("Choose your SD card or a copy of its atmosphere folder")
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            let done = try ModStore.importAtmosphere(u, titleIDs: Set(model.games.map(\.titleID)))
            model.notice = done.isEmpty ? L("No mods for your games in that folder (atmosphere/contents/<title ID>/romfs).")
                : LF("Imported %lld mods, turned off: turn on the ones you want.", done.count)
        } catch { model.notice = error.localizedDescription }
    }
}

/// GameBanana's mods for a game: all of them unselected; the ones you tick are downloaded, installed and turned on
struct ModBrowser: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var gbID: Int?
    @State private var mods: [GBMod] = []
    @State private var total = 0
    @State private var page = 1
    @State private var sort: GameBanana.Sort = .liked
    @State private var picked: Set<Int> = []
    @State private var loading = false
    @State private var problem: String?
    @State private var status: [Int: String] = [:]
    @State private var installing = false
    @State private var installed: Set<String> = []
    @State private var choosingGame = false

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if gbID != nil {
                    Text(LF("%lld mods on GameBanana", total)).font(.system(size: 15, weight: .semibold))
                    Button { choosingGame = true } label: { Label(model.config.gbGameNames[game.titleID] ?? L("Change game"), systemImage: "arrow.left.arrow.right") }
                        .buttonStyle(.link).font(.callout).help("Not this game? Choose the right one")
                    Picker("", selection: $sort) { ForEach(GameBanana.Sort.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().fixedSize()
                        .onChange(of: sort) { Task { await reload() } }
                }
                if loading { ProgressView().controlSize(.small) }
                if gbID == nil && !loading { Button("Choose the Game on GameBanana…") { choosingGame = true }.buttonStyle(GlassPill()) }
                Spacer()
                if let id = gbID, let u = URL(string: "https://gamebanana.com/games/\(id)") { Link("Open on GameBanana", destination: u).font(.callout) }
            }
            .padding(.horizontal, 32)
            Text("Only RomFS mods work with nxnative (models, textures, text, music). Code mods (exefs, cheats or 60 fps patches) and Smash mods that need ARCropolis do not: NX Hub installs them but marks them.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 32).fixedSize(horizontal: false, vertical: true)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).padding(.horizontal, 32) }
            ScrollView {
                if mods.isEmpty && !loading && problem == nil && gbID != nil {
                    Text("GameBanana has no mods for this game yet.").foregroundStyle(Theme.secondary).padding(.top, 30)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(mods) { m in card(m) }
                }
                .padding(.horizontal, 32)
                if mods.count < total {
                    Button { Task { await more() } } label: { Label("Load More", systemImage: "arrow.down.circle") }
                        .buttonStyle(GlassPill()).disabled(loading).padding(.vertical, 12)
                }
                Spacer(minLength: 80)
            }
        }
        .overlay(alignment: .bottom) {
            if !picked.isEmpty {
                HStack(spacing: 14) {
                    Text(LF("%lld selected", picked.count)).font(.system(size: 14, weight: .semibold))
                    Button("Clear") { picked = [] }.buttonStyle(.link)
                    Spacer()
                    if installing { ProgressView().controlSize(.small) }
                    Button { Task { await installPicked() } } label: { Label("Download and Install", systemImage: "arrow.down.to.line") }
                        .buttonStyle(PrimaryPill()).disabled(installing)
                }
                .padding(14)
                .frame(maxWidth: 760)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
                .padding(16)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $choosingGame) {
            GBGamePicker(start: game.name) { g in
                model.config.gbGameIDs[game.titleID] = g.id
                model.config.gbGameNames[game.titleID] = g.name
                gbID = g.id
                Task { await reload() }
            }
        }
    }

    private func card(_ m: GBMod) -> some View {
        let on = picked.contains(m.id)
        let have = installed.contains(ModBrowser.folderName(m.name))
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: m.thumb) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.white.opacity(0.05) }
                    .frame(height: 130).frame(maxWidth: .infinity).clipped()
                Image(systemName: have ? "checkmark.seal.fill" : on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(have ? Theme.good : on ? Theme.accent : .white.opacity(0.85))
                    .shadow(radius: 4).padding(10)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(m.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Label(String(m.likes), systemImage: "heart.fill").foregroundStyle(Theme.bad)
                    if let c = m.category { Text(c).foregroundStyle(Theme.secondary).lineLimit(1) }
                    Spacer()
                    if let s = status[m.id] { Text(s).foregroundStyle(Theme.accent).lineLimit(1) }
                    else if have { Text("Already installed").foregroundStyle(Theme.good) }
                }
                .font(.system(size: 11, weight: .medium))
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Theme.accent : Theme.stroke, lineWidth: on ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if !have { if on { picked.remove(m.id) } else { picked.insert(m.id) } } }
        .contextMenu { Link("Open on GameBanana", destination: m.page) }
    }

    static func folderName(_ name: String) -> String { name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-") }

    private func reload() async {
        installed = Set(ModStore.list(game.titleID).map(\.name))
        loading = true; defer { loading = false }
        problem = nil
        do {
            if gbID == nil {
                if let cached = model.config.gbGameIDs[game.titleID] {
                    gbID = cached
                    if model.config.gbGameNames[game.titleID] == nil, let g = try? await GameBanana.searchGames(game.name).first(where: { $0.id == cached }) {
                        model.config.gbGameNames[game.titleID] = g.name
                    }
                }
                else if let g = try await GameBanana.game(named: game.name) {
                    gbID = g.id
                    model.config.gbGameIDs[game.titleID] = g.id
                    model.config.gbGameNames[game.titleID] = g.name
                }
            }
            guard let id = gbID else { problem = LF("GameBanana has no page for %@.", game.name); return }
            page = 1
            let r = try await GameBanana.mods(game: id, page: 1, sort: sort)
            mods = r.mods; total = r.total
        } catch { problem = LF("Could not reach GameBanana: %@", error.localizedDescription) }
    }

    private func more() async {
        guard let id = gbID else { return }
        loading = true; defer { loading = false }
        do {
            let r = try await GameBanana.mods(game: id, page: page + 1, sort: sort)
            page += 1
            let have = Set(mods.map(\.id))
            mods += r.mods.filter { !have.contains($0.id) }
        } catch { problem = LF("Could not reach GameBanana: %@", error.localizedDescription) }
    }

    /// Each picked mod: its newest archive file (zip, 7z or rar) is downloaded, unpacked into the mods folder under the mod's name, and turned on when it has RomFS files
    private func installPicked() async {
        installing = true; defer { installing = false }
        for id in picked.sorted() {
            guard let m = mods.first(where: { $0.id == id }) else { continue }
            status[id] = L("Downloading…")
            do {
                let (files, _) = try await GameBanana.files(mod: id)
                guard let f = files.first(where: { ["zip", "7z", "rar"].contains(($0.name as NSString).pathExtension.lowercased()) }) ?? files.first else {
                    status[id] = L("No file"); continue
                }
                let local = try await GameBanana.download(f)
                status[id] = L("Installing…")
                let name = try await ModStore.install(local, titleID: game.titleID, name: ModBrowser.folderName(m.name))
                try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
                if let installedMod = ModStore.list(game.titleID).first(where: { $0.name == name }), installedMod.usable {
                    var e = model.config.enabledMods[game.titleID] ?? []
                    if !e.contains(name) { e.append(name) }
                    model.config.enabledMods[game.titleID] = e
                    status[id] = L("Installed and on")
                } else {
                    status[id] = L("Installed: code only, off")
                }
                picked.remove(id)
            } catch {
                status[id] = L("Failed")
                problem = LF("%@: %@", m.name, error.localizedDescription)
            }
        }
        installed = Set(ModStore.list(game.titleID).map(\.name))
    }
}

/// One game's mods
struct ModsList: View {
    @Environment(AppModel.self) private var model
    let titleID: String
    @State private var mods: [GameMod] = []
    @State private var busy = false

    private var enabled: [String] { model.config.enabledMods[titleID] ?? [] }
    private var name: String { model.games.first { $0.titleID == titleID }?.name ?? titleID }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LF("Mods for %@", name)).font(.system(size: 20, weight: .bold))
                    Text("RomFS mods (textures, models, text, music) replace the game's files when it starts from NX Hub. Code mods (exefs, .ips) do not apply: nxnative recompiles the game's code. A mod higher in the list wins where two change one file.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if busy { ProgressView().controlSize(.small) }
                Button { add() } label: { Label("Add Mod…", systemImage: "plus") }.buttonStyle(PrimaryPill())
                Button { try? FileManager.default.createDirectory(at: ModStore.folder(titleID), withIntermediateDirectories: true); NSWorkspace.shared.open(ModStore.folder(titleID)) } label: { Image(systemName: "folder") }
                    .buttonStyle(GlassPill()).help("Open the mods folder")
            }
            if mods.isEmpty {
                Text("No mods yet. Add a folder or a zip / 7z / rar: NX Hub finds its romfs folder (also in Atmosphère's atmosphere/contents/<title ID>/romfs layout).")
                    .foregroundStyle(Theme.secondary).card()
            }
            ForEach(ordered) { m in row(m) }
        }
        .onAppear(perform: reload)
        .onChange(of: titleID) { reload() }
    }

    /// Mods turned on first, in their order; the rest by name
    private var ordered: [GameMod] {
        let on = enabled.compactMap { n in mods.first { $0.name == n } }
        return on + mods.filter { !enabled.contains($0.name) }
    }

    private func row(_ m: GameMod) -> some View {
        let on = enabled.contains(m.name)
        return HStack(spacing: 14) {
            Toggle("", isOn: Binding(get: { on }, set: { set(m, $0) })).labelsHidden().toggleStyle(.switch).disabled(!m.usable)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.name).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    Text(m.size.bytes).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if m.usable { Chip(text: "RomFS", color: Theme.good) } else { Chip(text: L("Code only: does not apply"), color: Theme.bad) }
                    if m.hasCode && m.usable { Chip(text: L("its code part is skipped"), color: Theme.warn) }
                }
            }
            Spacer()
            if on, let i = enabled.firstIndex(of: m.name) {
                Button { move(m, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                Button { move(m, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == enabled.count - 1)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([m.romfs ?? m.folder]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            Button(role: .destructive) { remove(m) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .card(padding: 14)
    }

    private func reload() { mods = ModStore.list(titleID) }

    private func set(_ m: GameMod, _ on: Bool) {
        var e = enabled.filter { $0 != m.name }
        if on { e.append(m.name) }
        model.config.enabledMods[titleID] = e.isEmpty ? nil : e
    }

    private func move(_ m: GameMod, _ by: Int) {
        var e = enabled
        guard let i = e.firstIndex(of: m.name), e.indices.contains(i + by) else { return }
        e.swapAt(i, i + by)
        model.config.enabledMods[titleID] = e
    }

    private func remove(_ m: GameMod) {
        do { try ModStore.remove(m); set(m, false); reload(); model.notice = LF("%@ moved to the Trash.", m.name) }
        catch { model.notice = error.localizedDescription }
    }

    private func add() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = L("Choose mods: folders, or zip / 7z / rar files")
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        Task {
            busy = true; defer { busy = false }
            for u in urls {
                do {
                    let n = try await ModStore.install(u, titleID: titleID)
                    reload()
                    if let m = mods.first(where: { $0.name == n }), m.usable { set(m, true) }
                    model.notice = LF("Added %@.", n)
                } catch { model.notice = error.localizedDescription }
            }
        }
    }
}

/// Which GameBanana game a game's mods come from, when the name did not find the right one
private struct GBGamePicker: View {
    let start: String
    let chosen: (GameBanana.GBGame) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var found: [GameBanana.GBGame] = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The game on GameBanana").font(.title2.bold())
            HStack {
                TextField("Name", text: $text).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
            }
            if let problem { Text(problem).foregroundStyle(Theme.warn) }
            List(found) { g in
                Button { chosen(g); dismiss() } label: {
                    HStack { Text(g.name); Spacer(); Text(verbatim: "#\(g.id)").foregroundStyle(.secondary).font(.caption.monospaced()) }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 260)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(22)
        .frame(width: 480)
        .task { text = start; await search() }
    }

    private func search() async {
        problem = nil
        do { found = try await GameBanana.searchGames(text) } catch { problem = LF("Could not reach GameBanana: %@", error.localizedDescription) }
    }
}
