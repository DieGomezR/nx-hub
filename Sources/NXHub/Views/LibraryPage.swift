import SwiftUI

/// All your games at once: a grid of cards, or a list with how each stands (build, nxnative's changes, save, mods, cheats)
struct LibraryPage: View {
    @Environment(AppModel.self) private var model
    @State private var asList = false
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 22)]

    var body: some View {
        let games = model.games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        PageShell(title: L("Library"), systemImage: "square.grid.2x2.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Search", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.panel)).overlay(Capsule().stroke(Theme.stroke))
                    .frame(maxWidth: 300)
                    Picker("", selection: $asList) {
                        Image(systemName: "square.grid.2x2").tag(false)
                        Image(systemName: "list.bullet").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if !model.gamesWorthRebuilding.isEmpty {
                        Button { model.open(.nxnative) } label: { Label(LF("Improvements for %lld games", model.gamesWorthRebuilding.count), systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(GlassPill(tint: Theme.warn))
                    }
                    Button { model.open(.catalog) } label: { Label("Add Game", systemImage: "plus") }.buttonStyle(PrimaryPill())
                }
                .padding(.horizontal, 32)
                ScrollView {
                    if asList {
                        VStack(spacing: 8) {
                            ForEach(games) { g in LibraryRow(game: g) }
                        }
                        .padding(.horizontal, 32).padding(.bottom, 32)
                    } else {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(games) { g in LibraryCard(game: g) }
                        }
                        .padding(.horizontal, 32).padding(.bottom, 32)
                    }
                }
            }
        }
    }
}

private struct LibraryCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                GameTileArt(game: game, size: 190)
                    .opacity(game.app == nil ? 0.55 : 1)
                if hover && game.app != nil {
                    Button { Task { await model.play(game) } } label: {
                        Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 46, height: 46).background(Circle().fill(.white))
                    }
                    .buttonStyle(.plain).padding(10)
                    .shadow(radius: 8)
                }
            }
            .frame(width: 190, height: 190)
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(hover ? Theme.accent : .clear, lineWidth: 3).padding(-4))
            Text(game.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            StatusChips(game: game)
        }
        .frame(width: 190, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(.game(game.titleID)) }
        .contextMenu { GameMenuItems(game: game) }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

private struct LibraryRow: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let c = model.changes[game.id]
        let mods = (model.config.enabledMods[game.titleID] ?? []).count
        let cheats = (model.config.enabledCheats[game.titleID] ?? []).count
        HStack(spacing: 14) {
            GameTileArt(game: game, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.system(size: 15, weight: .semibold))
                Text([game.version.map { LF("Version %@", $0) }, game.titleID].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.secondary)
            }
            .frame(width: 300, alignment: .leading)
            StatusChips(game: game).frame(width: 220, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let built = game.app?.builtAt { Text(LF("Built %@", built.relative)).font(.caption).foregroundStyle(Theme.secondary) }
                if let c, c.known, !c.profile.isEmpty { Text(LF("%lld profile changes", c.profile.count)).font(.caption).foregroundStyle(Theme.warn) }
            }
            Spacer()
            if mods > 0 { Chip(text: LF("%lld mods", mods), color: Color(red: 0.75, green: 0.55, blue: 1), systemImage: "puzzlepiece.extension.fill") }
            if cheats > 0 { Chip(text: LF("%lld cheats", cheats), color: Theme.warn, systemImage: "wand.and.stars") }
            if game.app != nil {
                Button { Task { await model.play(game) } } label: { Image(systemName: "play.fill") }.buttonStyle(GlassPill())
            }
            Button { model.open(.game(game.titleID)) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(GlassPill())
        }
        .card(padding: 12)
        .contextMenu { GameMenuItems(game: game) }
    }
}
