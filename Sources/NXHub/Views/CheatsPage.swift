import SwiftUI
import UniformTypeIdentifiers

/// Cheats per game: Atmosphère cheat files, the cheats turned on, and the engine that applies them while the game runs
struct CheatsPage: View {
    @Environment(AppModel.self) private var model
    let initial: String?
    @State private var selected: String?

    var body: some View {
        PageShell(title: L("Cheats"), systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(model.games.filter { $0.app != nil }) { g in
                            VStack(spacing: 6) {
                                GameTileArt(game: g, size: 84)
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected == g.titleID ? Theme.accent : .clear, lineWidth: 4).padding(-5))
                                Text(g.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 90)
                                    .foregroundStyle(selected == g.titleID ? Theme.text : Theme.secondary)
                            }
                            .onTapGesture { selected = g.titleID }
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 8)
                }
                ScrollView {
                    if let id = selected, let g = model.games.first(where: { $0.titleID == id }) {
                        CheatsList(game: g)
                            .padding(.horizontal, 32).padding(.bottom, 32)
                            .frame(maxWidth: 1000, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear { selected = initial ?? model.selectedGame?.titleID ?? model.games.first { $0.app != nil }?.titleID }
    }
}

private struct CheatsList: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var files: [CheatFileEntry] = []
    @State private var pasting = false

    private var enabled: [String] { model.config.enabledCheats[game.titleID] ?? [] }
    private var buildID: String? { CheatStore.buildID(game, repo: model.repo.url) }
    private var session: CheatSession { model.cheats }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LF("Cheats for %@", game.name)).font(.system(size: 20, weight: .bold))
                    Text(LF("Version %@ · build ID %@", game.version ?? "?", buildID ?? "?")).font(.caption.monospaced()).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { importFile() } label: { Label("Import .txt…", systemImage: "square.and.arrow.down") }.buttonStyle(PrimaryPill())
                Button { pasting = true } label: { Label("Paste", systemImage: "doc.on.clipboard") }.buttonStyle(GlassPill())
                Button { try? FileManager.default.createDirectory(at: CheatStore.folder(game.titleID), withIntermediateDirectories: true); NSWorkspace.shared.open(CheatStore.folder(game.titleID)) } label: { Image(systemName: "folder") }
                    .buttonStyle(GlassPill())
            }
            statusCard
            Text("NX Hub applies the cheats while the game runs, 12 times a second, as Atmosphère does. Cheats that change values (lives, coins, time) work; cheats that patch the game's code may not, since nxnative recompiles it. Keypress cheats read your controllers.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if files.isEmpty {
                Text("No cheat files yet. Import an Atmosphère cheat file (<build ID>.txt) made for this game's version.").foregroundStyle(Theme.secondary).card()
            }
            ForEach(files) { f in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(Theme.secondary)
                        Text(f.file.lastPathComponent).font(.system(size: 13, weight: .semibold).monospaced())
                        if let b = buildID, !f.file.deletingPathExtension().lastPathComponent.uppercased().hasPrefix(b) {
                            Chip(text: L("made for another version?"), color: Theme.warn, systemImage: "exclamationmark.triangle.fill")
                        }
                        Spacer()
                        Button(role: .destructive) { try? FileManager.default.trashItem(at: f.file, resultingItemURL: nil); reload() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    ForEach(f.cheats) { c in
                        HStack {
                            if c.master {
                                Image(systemName: "lock.fill").foregroundStyle(Theme.tertiary).frame(width: 38)
                            } else {
                                Toggle("", isOn: Binding(get: { enabled.contains(c.name) }, set: { set(c.name, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            Text(c.name).font(.system(size: 14))
                            if c.master { Chip(text: L("always on"), color: Theme.secondary) }
                            Spacer()
                            Text(LF("%lld words", c.words.count)).font(.caption).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .card(padding: 14)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: game.titleID) { reload() }
        .sheet(isPresented: $pasting) { PasteCheats(game: game, buildID: buildID) { reload() } }
    }

    @ViewBuilder private var statusCard: some View {
        HStack(spacing: 12) {
            switch session.titleID == game.titleID ? session.status : .idle {
            case .running(let pid):
                Image(systemName: "bolt.fill").foregroundStyle(Theme.good)
                Text(LF("Applying cheats (process %lld, %lld ticks)", Int(pid), session.ticks)).foregroundStyle(Theme.good)
                if let e = session.lastError { Text(e).font(.caption).foregroundStyle(Theme.warn) }
            case .waiting:
                ProgressView().controlSize(.small)
                Text("Connecting to the game…")
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text(m).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            case .idle:
                Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.secondary)
                Text(model.isRunning(game) ? L("The game is running: apply the cheats now.") : L("Cheats start by themselves when you play the game from NX Hub.")).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if case .running = session.status, session.titleID == game.titleID {
                Button("Stop") { session.stop() }.buttonStyle(GlassPill())
            } else {
                Button("Apply Now") {
                    Task {
                        let all = files.flatMap { $0.cheats }
                        await session.start(game: game, cheats: all, enabled: enabled)
                    }
                }
                .buttonStyle(GlassPill()).disabled(!model.isRunning(game) || files.isEmpty)
            }
        }
        .card(padding: 14)
    }

    private func reload() { files = CheatStore.cheats(game.titleID) }

    private func set(_ name: String, _ on: Bool) {
        var e = enabled.filter { $0 != name }
        if on { e.append(name) }
        model.config.enabledCheats[game.titleID] = e.isEmpty ? nil : e
    }

    private func importFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.plainText, UTType(filenameExtension: "txt") ?? .plainText]
        p.message = LF("Choose cheat files for %@ (Atmosphère format)", game.name)
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            do { _ = try CheatStore.install(u, titleID: game.titleID, buildID: p.urls.count == 1 ? buildID : nil) }
            catch { model.notice = error.localizedDescription }
        }
        reload()
    }
}

/// Cheats pasted as text (from a website or a forum post), saved as the game's cheat file
private struct PasteCheats: View {
    let game: Game
    let buildID: String?
    let done: () -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LF("Paste cheats for %@", game.name)).font(.title2.bold())
            Text("Atmosphère format: a name in [brackets] (or {braces} for a master code), then its lines of 8-digit hex words.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.callout.monospaced()).frame(height: 260)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            let n = CheatFile.parse(text).count
            HStack {
                Text(LF("%lld cheats found", n)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let dir = CheatStore.folder(game.titleID)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    var url = dir.appendingPathComponent((buildID ?? "cheats") + ".txt")
                    if FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).txt") }
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                    done(); dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(n == 0)
            }
        }
        .padding(24).frame(width: 600)
        .preferredColorScheme(.dark)
    }
}
