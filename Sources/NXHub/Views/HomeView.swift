import SwiftUI

/// The start screen: the selected game's art lights the room, its name and actions above a row of big tiles, round buttons below
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let sel = model.selectedGame
        let _ = model.shotStamp
        let shot = sel.flatMap { ShotStore.lastImage($0.titleID) }
        ZStack {
            Group {
                if let shot {
                    ZStack {
                        ArtBackground(image: shot, dim: 0.5, blur: 16, opacity: 0.95)
                        LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .black.opacity(0.15), location: 0.65)], startPoint: .leading, endPoint: .trailing)
                        LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.18), .init(color: .clear, location: 0.7), .init(color: .black.opacity(0.6), location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                    .ignoresSafeArea()
                }
                else { ArtBackground(image: sel.flatMap { GameArt.image($0) }, dim: 0.5) }
            }
                .id("\(sel?.titleID ?? "none")-\(shot != nil)-\(model.shotStamp)")
                .animation(.easeInOut(duration: 0.45), value: sel?.titleID)
            VStack(spacing: 0) {
                TopBar()
                Spacer(minLength: 12)
                if model.games.isEmpty {
                    EmptyHome()
                } else {
                    if let sel { SelectedHeader(game: sel) }
                    Carousel()
                }
                Spacer(minLength: 12)
                Dock()
                if model.config.showHints { HintsBar().padding(.top, 14).padding(.bottom, 18) } else { Spacer().frame(height: 26) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; model.homeIndex = min(model.homeIndex, max(0, model.games.count - 1)) }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .escape]) { press in
            switch press.key {
            case .leftArrow: model.handle(.left)
            case .rightArrow: model.handle(.right)
            case .upArrow: model.handle(.up)
            case .downArrow: model.handle(.down)
            case .escape: model.handle(.b)
            default: model.handle(.a)
            }
            return .handled
        }
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.accent, Color(red: 0.45, green: 0.35, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(NSFullUserName().prefix(1)).uppercased()).font(.system(size: 18, weight: .bold))
            }
            .frame(width: 40, height: 40)
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
            Text(NSFullUserName().split(separator: " ").first.map(String.init) ?? "").font(.system(size: 15, weight: .semibold))
            Spacer()
            if !model.gamesWorthRebuilding.isEmpty || !model.repo.incoming.isEmpty {
                Button { model.open(.nxnative) } label: {
                    Label(model.repo.incoming.isEmpty ? (model.gamesWorthRebuilding.count == 1 ? L("nxnative has improvements for 1 of your games") : LF("nxnative has improvements for %lld of your games", model.gamesWorthRebuilding.count)) : (model.repo.incoming.count == 1 ? L("1 new change in nxnative") : LF("%lld new in nxnative", model.repo.incoming.count)),
                          systemImage: "sparkles")
                }
                .buttonStyle(GlassPill(tint: Theme.warn))
            }
            if model.builds.current != nil {
                Button { model.open(.nxnative) } label: {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building") }
                }
                .buttonStyle(GlassPill())
            }
            ForEach(model.pads.pads) { p in
                Image(systemName: "gamecontroller.fill").font(.system(size: 16)).foregroundStyle(Theme.secondary).help(p.name)
            }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                HStack(spacing: 14) {
                    if let b = MacBattery.read() {
                        HStack(spacing: 4) {
                            Text(verbatim: "\(b.percent)%").font(.system(size: 14, weight: .medium)).monospacedDigit()
                            Image(systemName: b.charging ? "battery.100percent.bolt" : b.percent > 60 ? "battery.75percent" : b.percent > 25 ? "battery.50percent" : "battery.25percent")
                        }
                    }
                    Text(ctx.date, format: .dateTime.hour().minute()).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                }
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 40).padding(.top, 20)
    }
}

/// The selected game's name, how it stands, and what A and the buttons do
private struct SelectedHeader: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(game.name).font(.system(size: 34, weight: .bold)).lineLimit(1).shadow(radius: 8)
                HStack(spacing: 8) {
                    if let v = game.version { Text(LF("Version %@", v)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary) }
                    StatusChips(game: game)
                }
                HStack(spacing: 12) {
                    if game.app != nil {
                        let s = model.session?.game.titleID == game.titleID ? model.session : nil
                        Button { Task { await model.play(game) } } label: {
                            Label(LocalizedStringKey(s?.suspended == true ? "Resume" : model.isRunning(game) ? "Show Game" : "Play"), systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryPill(focused: model.homeRow == .games))
                        .disabled(model.builds.job(for: game.titleID) != nil)
                        if model.isRunning(game) {
                            Button { model.closePrompt = game } label: { Label("Close Game", systemImage: "xmark") }
                                .buttonStyle(GlassPill(tint: Theme.bad))
                        }
                    } else if game.canBuild {
                        Button { model.build(game) } label: { Label("Build App", systemImage: "hammer.fill") }
                            .buttonStyle(PrimaryPill(focused: model.homeRow == .games))
                            .disabled(model.builds.job(for: game.titleID) != nil)
                    }
                    Button { model.open(.game(game.titleID)) } label: { Label("Options", systemImage: "slider.horizontal.3") }
                        .buttonStyle(GlassPill())
                    if let job = model.builds.job(for: game.titleID) {
                        HStack(spacing: 8) {
                            ProgressView(value: job.fraction ?? 0).frame(width: 120).tint(Theme.accent)
                            Text(job.state == .queued ? L("Waiting to build") : job.stageName).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 18) {
                    if let built = game.app?.builtAt { Label(LF("Built %@", built.relative), systemImage: "hammer") }
                    let save = model.saveSlot(for: game)
                    if save.exists { Label(LF("Save %@ · %@", save.size.bytes, save.modified?.relative ?? "—"), systemImage: "externaldrive") }
                    let mods = (model.config.enabledMods[game.titleID] ?? []).count
                    if mods > 0 { Label(LF("%lld mods", mods), systemImage: "puzzlepiece.extension") }
                    let cheats = (model.config.enabledCheats[game.titleID] ?? []).count
                    if cheats > 0 { Label(LF("%lld cheats", cheats), systemImage: "wand.and.stars") }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 64)
    }
}

struct StatusChips: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        HStack(spacing: 6) {
            if let job = model.builds.job(for: game.titleID) {
                Chip(text: job.state == .queued ? L("Waiting to build") : LF("Building %@", job.fraction.map { "\(Int($0 * 100)) %" } ?? "…"), color: Theme.accent, systemImage: "hammer.fill")
            } else if let s = model.session, s.game.titleID == game.titleID, s.suspended {
                Chip(text: L(s.paused ? "Paused" : "In the background"), color: Theme.warn, systemImage: "pause.fill")
            } else if model.isRunning(game) {
                Chip(text: L("Playing"), color: Theme.good, systemImage: "play.fill")
            } else if game.app == nil {
                Chip(text: L(game.kind == .devBuild ? "No app yet" : "Not built"), color: Theme.secondary)
            } else if model.worthRebuilding(game), let c = model.changes[game.id] {
                Chip(text: L(c.profile.isEmpty ? "New shaders" : "Profile updated"), color: Theme.warn, systemImage: "arrow.down.circle.fill")
            } else {
                Chip(text: L("Ready"), color: Theme.good, systemImage: "checkmark.circle.fill")
            }
            let mods = (model.config.enabledMods[game.titleID] ?? []).count
            if mods > 0 { Chip(text: LF("%lld mods", mods), color: Color(red: 0.75, green: 0.55, blue: 1), systemImage: "puzzlepiece.extension.fill") }
        }
    }
}

private struct Carousel: View {
    @Environment(AppModel.self) private var model
    private let size: CGFloat = 196

    var body: some View {
        let games = model.games
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                        HomeTile(game: g, selected: i == model.homeIndex && model.homeRow == .games, size: size)
                            .id(g.id)
                            .onTapGesture(count: 2) { if g.app != nil { Task { await model.play(g) } } else { model.open(.game(g.titleID)) } }
                            .onTapGesture { model.homeIndex = i; model.homeRow = .games }
                    }
                    AddTile(size: size).onTapGesture { model.open(.catalog) }
                }
                .padding(.horizontal, 64)
                .padding(.vertical, 26)
            }
            .onChange(of: model.homeIndex) {
                guard games.indices.contains(model.homeIndex) else { return }
                withAnimation(.spring(duration: 0.35)) { proxy.scrollTo(games[model.homeIndex].id, anchor: .center) }
            }
        }
        .frame(height: size + 70)
    }
}

private struct HomeTile: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let selected: Bool
    let size: CGFloat
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GameTileArt(game: game, size: size)
                .opacity(game.app == nil ? 0.55 : 1)
            if let job = model.builds.job(for: game.titleID) {
                ZStack {
                    Circle().fill(.black.opacity(0.6))
                    Circle().trim(from: 0, to: CGFloat(job.fraction ?? 0.02)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).padding(5)
                    Image(systemName: "hammer.fill").font(.system(size: 13))
                }
                .frame(width: 42, height: 42).padding(10)
            } else if model.worthRebuilding(game) {
                Circle().fill(Theme.warn).frame(width: 14, height: 14).overlay(Circle().stroke(.black.opacity(0.4))).padding(12)
            }
            if model.isRunning(game) {
                let paused = model.session?.game.titleID == game.titleID && model.session?.paused == true
                Image(systemName: paused ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white, paused ? Theme.warn : Theme.good).padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.09 + 6, style: .continuous)
                .stroke(selected ? Theme.accent : .white.opacity(hover ? 0.35 : 0), lineWidth: selected ? 5 : 2)
                .padding(-7)
        )
        .shadow(color: selected ? Theme.accent.opacity(0.45) : .black.opacity(0.4), radius: selected ? 22 : 10, y: selected ? 0 : 6)
        .scaleEffect(selected ? 1.07 : 1)
        .animation(.spring(duration: 0.28), value: selected)
        .onHover { hover = $0 }
        .contextMenu { GameMenuItems(game: game) }
    }
}

private struct AddTile: View {
    let size: CGFloat
    @State private var hover = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus").font(.system(size: 40, weight: .light))
            Text("Add Game").font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(Theme.secondary)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        .onHover { hover = $0 }
        .help("Find games nxnative supports and add yours")
    }
}

private struct EmptyHome: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller").font(.system(size: 60, weight: .light)).foregroundStyle(Theme.secondary)
            Text("No games yet").font(.system(size: 28, weight: .bold))
            Text("Add a game from the catalog of games nxnative supports, or tell NX Hub where your game folders are.")
                .foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 14) {
                Button { model.open(.catalog) } label: { Label("Catalog", systemImage: "square.grid.3x3.fill") }.buttonStyle(PrimaryPill())
                Button { model.openSettings?() } label: { Label("Settings", systemImage: "gearshape.fill") }.buttonStyle(GlassPill())
            }
        }
    }
}

extension DockItem {
    var title: String {
        switch self {
        case .library: return L("Library")
        case .catalog: return L("Catalog")
        case .mods: return L("Mods")
        case .cheats: return L("Cheats")
        case .saves: return L("Saves")
        case .controllers: return L("Controllers")
        case .nxnative: return "nxnative"
        case .settings: return L("Settings")
        }
    }
    var systemImage: String {
        switch self {
        case .library: return "square.grid.2x2.fill"
        case .catalog: return "square.grid.3x3.fill"
        case .mods: return "puzzlepiece.extension.fill"
        case .cheats: return "wand.and.stars"
        case .saves: return "externaldrive.fill"
        case .controllers: return "gamecontroller.fill"
        case .nxnative: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
    var tint: Color {
        switch self {
        case .library: return Color(red: 0.3, green: 0.86, blue: 0.98)
        case .catalog: return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .mods: return Color(red: 0.75, green: 0.55, blue: 1.0)
        case .cheats: return Color(red: 1.0, green: 0.78, blue: 0.3)
        case .saves: return Color(red: 0.35, green: 0.8, blue: 1.0)
        case .controllers: return Color(red: 0.4, green: 0.9, blue: 0.6)
        case .nxnative: return Color(red: 0.55, green: 0.7, blue: 1.0)
        case .settings: return Color(white: 0.85)
        }
    }
}

private struct Dock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 26) {
            ForEach(DockItem.allCases, id: \.self) { item in
                DockButton(item: item, focused: model.homeRow == .dock && model.dockIndex == item.rawValue, badge: badge(item))
                    .onTapGesture { model.dockIndex = item.rawValue; model.openDock(item) }
            }
        }
    }

    private func badge(_ item: DockItem) -> Int {
        switch item {
        case .nxnative: return model.repo.incoming.count + model.gamesWorthRebuilding.count
        default: return 0
        }
    }
}

private struct DockButton: View {
    let item: DockItem
    let focused: Bool
    let badge: Int
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.white.opacity(focused || hover ? 0.16 : 0.08))
                    .overlay(Circle().stroke(focused ? Theme.accent : Color.white.opacity(0.12), lineWidth: focused ? 4 : 1).padding(focused ? -5 : 0))
                    .overlay(Image(systemName: item.systemImage).font(.system(size: 23, weight: .semibold)).foregroundStyle(item.tint))
                    .frame(width: 62, height: 62)
                if badge > 0 {
                    Text(verbatim: "\(badge)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.bad)).offset(x: 6, y: -4)
                }
            }
            .scaleEffect(focused ? 1.1 : 1)
            .shadow(color: focused ? Theme.accent.opacity(0.4) : .clear, radius: 14)
            Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(focused || hover ? Theme.text : Theme.secondary)
        }
        .animation(.spring(duration: 0.25), value: focused)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
    }
}

private struct HintsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            if model.pads.pads.isEmpty {
                Hint(glyph: "←", text: L("Move"))
                Hint(glyph: "↩", text: model.homeRow == .games ? L("Play") : L("Open"))
                Hint(glyph: "⌘,", text: L("Settings"))
            } else if model.homeRow == .games, let g = model.selectedGame, model.isRunning(g) {
                let suspended = model.session?.game.titleID == g.titleID && model.session?.suspended == true
                Hint(glyph: "A", text: suspended ? L("Resume") : L("Show Game"))
                Hint(glyph: "X", text: L("Close Game"))
                if suspended { Hint(glyph: "⌂", text: L("Back to the game")) }
                Hint(glyph: "+", text: L("Options"))
            } else if model.homeRow == .games {
                Hint(glyph: "A", text: L("Play"))
                Hint(glyph: "X", text: L("Options"))
                Hint(glyph: "Y", text: L("Rebuild"))
                Hint(glyph: "−", text: L("Settings"))
            } else {
                Hint(glyph: "A", text: L("Open"))
                Hint(glyph: "B", text: L("Back"))
            }
        }
        .padding(.horizontal, 40)
    }
}

/// The actions every game has, in the tiles' context menus and the game page's menu
struct GameMenuItems: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if game.app != nil {
            Button("Play") { Task { await model.play(game) } }
        }
        if model.isRunning(game) {
            Button("Close Game") { model.closePrompt = game }
        }
        Button("Options") { model.open(.game(game.titleID)) }
        if game.canBuild {
            Button(LocalizedStringKey(game.app == nil ? "Build App" : "Rebuild")) { model.build(game) }
                .disabled(model.builds.job(for: game.titleID) != nil)
            Button(LocalizedStringKey(model.config.nightQueue.contains(game.titleID) ? "Do Not Build Tonight" : "Build Tonight")) { model.toggleNight(game) }
                .disabled(model.builds.job(for: game.titleID) != nil)
        }
        if game.app != nil {
            Toggle("Keep This Build", isOn: Binding(get: { model.config.keptBuilds.contains(game.titleID) }, set: { _ in model.toggleKept(game) }))
        }
        Divider()
        Button("Mods") { model.open(.mods(game.titleID)) }
        Button("Saves") { model.open(.saves) }
        Divider()
        if let f = game.folder { Button("Show Game Folder") { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
        if let a = game.app { Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([a.url]) } }
        Button("Open Game Log") {
            let l = Paths.gameLog(game.titleID)
            if Paths.exists(l) { NSWorkspace.shared.open(l) } else { model.notice = L("The game has no log yet: it is written when the game runs.") }
        }
        Button("Copy Title ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(game.titleID, forType: .string)
        }
    }
}
