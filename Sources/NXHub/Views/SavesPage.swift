import SwiftUI
import UniformTypeIdentifiers

/// Every game's save in one place: where it is, its backups, and replacing it with one from elsewhere
struct SavesPage: View {
    @Environment(AppModel.self) private var model
    @State private var slots: [SaveSlot] = []

    var body: some View {
        PageShell(title: L("Saves"), systemImage: "externaldrive.fill") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Before NX Hub replaces or restores a save it backs up the current one. A save is replaced only while its game is closed.")
                        .foregroundStyle(Theme.secondary)
                    ForEach(slots) { s in SaveCard(slot: s) }
                    if slots.isEmpty { Text("No saves yet.").foregroundStyle(Theme.secondary) }
                }
                .padding(.horizontal, 32).padding(.bottom, 32)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task { slots = SaveStore.slots(games: model.games) }
    }
}

/// One game's save: where you left it (the picture NX Hub took last while it ran), its size and date, its backups with their pictures, import, restore
struct SaveCard: View {
    @Environment(AppModel.self) private var model
    @State var slot: SaveSlot
    @State private var backups: [URL] = []
    @State private var busy = false
    @State private var importing: ImportPlan?
    @State private var restoring: URL?

    struct ImportPlan: Identifiable {
        let id = UUID()
        let root: URL
        let temporary: Bool
        let candidates: [URL]
        var chosen: URL
    }

    private var game: Game? { model.games.first { $0.titleID == slot.titleID } }

    var body: some View {
        let _ = model.shotStamp
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                ShotThumb(image: ShotStore.lastImage(slot.titleID), game: game, width: 256)
                VStack(alignment: .leading, spacing: 6) {
                    Text(slot.name).font(.system(size: 19, weight: .bold))
                    Text(slot.exists ? LF(slot.files == 1 ? "%lld file · %@ · saved %@" : "%lld files · %@ · saved %@", slot.files, slot.size.bytes, slot.modified?.relative ?? "—") : L("No save yet"))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if let d = Paths.modified(ShotStore.last(slot.titleID)) {
                        Label(LF("Picture of where you left it: %@", d.relative), systemImage: "camera.fill").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Text(Paths.pretty(slot.folder)).font(.caption.monospaced()).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 6)
                    HStack(spacing: 10) {
                        Button { Task { await backupNow() } } label: { Label("Back Up", systemImage: "arrow.down.doc.fill") }
                            .buttonStyle(GlassPill()).disabled(!slot.exists || busy)
                        Button { chooseImport() } label: { Label("Import…", systemImage: "square.and.arrow.down.fill") }
                            .buttonStyle(GlassPill()).disabled(busy)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([slot.exists ? slot.folder : slot.folder.deletingLastPathComponent()]) } label: { Image(systemName: "folder") }
                            .buttonStyle(GlassPill()).help("Show in Finder")
                            .disabled(!Paths.exists(slot.folder) && !Paths.exists(slot.folder.deletingLastPathComponent()))
                        if busy { ProgressView().controlSize(.small) }
                    }
                }
                Spacer(minLength: 0)
            }
            if !backups.isEmpty {
                HStack {
                    Text(LF("Backups (%lld)", backups.count)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(SaveStore.backups(slot.titleID)) }.buttonStyle(.link).font(.caption)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(backups.prefix(40), id: \.self) { b in
                            BackupTile(zip: b, restore: { restoring = b }, trash: { trash(b) })
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 138)
            }
        }
        .card()
        .onAppear { backups = SaveStore.listBackups(slot.titleID) }
        .sheet(item: $importing) { plan in ImportSheet(plan: plan, slot: slot) { chosen in Task { await finishImport(plan, chosen) } } }
        .confirmationDialog(restoring.map { LF("Restore the backup of %@?", SaveStore.describe($0).date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? $0.lastPathComponent) } ?? "",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") { if let b = restoring { Task { await restore(b) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current save is backed up first.")
        }
    }

    private func trash(_ zip: URL) {
        try? FileManager.default.trashItem(at: zip, resultingItemURL: nil)
        let png = ShotStore.forBackup(zip)
        if Paths.exists(png) { try? FileManager.default.trashItem(at: png, resultingItemURL: nil) }
        backups = SaveStore.listBackups(slot.titleID)
    }

    private var running: Bool { game.map { model.isRunning($0) } ?? false }

    private func refresh() {
        slot = SaveStore.slot(slot.titleID, slot.name, slot.folder)
        backups = SaveStore.listBackups(slot.titleID)
    }

    private func backupNow() async {
        busy = true; defer { busy = false }
        do { let z = try await SaveStore.backup(slot); model.notice = LF("Saved a backup: %@", z.lastPathComponent) }
        catch { model.notice = error.localizedDescription }
        refresh()
    }

    private func chooseImport() {
        guard !running else { model.notice = LF("Quit %@ before replacing its save.", slot.name); return }
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = L("Choose a save: a folder, or a zip / 7z / rar with it")
        guard p.runModal() == .OK, let u = p.url else { return }
        Task {
            busy = true; defer { busy = false }
            do {
                let (root, temp) = try await SaveStore.unpack(u)
                let c = SaveStore.candidates(in: root, matching: slot.exists ? slot.folder : nil)
                importing = ImportPlan(root: root, temporary: temp, candidates: c, chosen: c.first ?? root)
            } catch { model.notice = error.localizedDescription }
        }
    }

    private func finishImport(_ plan: ImportPlan, _ chosen: URL?) async {
        defer { if plan.temporary { try? FileManager.default.removeItem(at: plan.root) } }
        guard let chosen else { return }
        guard !running else { model.notice = LF("Quit %@ before replacing its save.", slot.name); return }
        busy = true; defer { busy = false }
        do { try await SaveStore.replace(slot, with: chosen); model.notice = LF("%@: save replaced (the previous one is in its backups).", slot.name) }
        catch { model.notice = error.localizedDescription }
        refresh()
    }

    private func restore(_ zip: URL) async {
        guard !running else { model.notice = LF("Quit %@ before replacing its save.", slot.name); return }
        busy = true; defer { busy = false }
        do { try await SaveStore.restore(slot, from: zip); model.notice = LF("%@: restored %@.", slot.name, zip.deletingPathExtension().lastPathComponent) }
        catch { model.notice = error.localizedDescription }
        refresh()
    }
}

/// Which folder of the imported save becomes the game's save: its files are listed so the right level can be picked
private struct ImportSheet: View {
    let plan: SaveCard.ImportPlan
    let slot: SaveSlot
    let done: (URL?) -> Void
    @State private var chosen: URL
    @Environment(\.dismiss) private var dismiss

    init(plan: SaveCard.ImportPlan, slot: SaveSlot, done: @escaping (URL?) -> Void) {
        self.plan = plan; self.slot = slot; self.done = done
        _chosen = State(initialValue: plan.chosen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LF("Replace the save of %@", slot.name)).font(.title2.bold())
            Text("Pick the folder whose contents are the save: its files go straight into the game's save folder. The current save is backed up first.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Save root", selection: $chosen) {
                ForEach(plan.candidates, id: \.self) { c in
                    Text(c == plan.root ? L("(the whole import)") : String(c.path.dropFirst(plan.root.path.count + 1))).tag(c)
                }
            }
            GroupBox("Contents") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(listing(chosen), id: \.self) { line in Text(line).font(.caption.monospaced()) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace Save") { done(chosen); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func listing(_ u: URL) -> [String] {
        var out: [String] = []
        if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                if out.count >= 200 { out.append("…"); break }
                let rel = String(f.path.dropFirst(u.path.count + 1))
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { Int64($0).bytes }
                out.append(Paths.isDirectory(f) ? rel + "/" : "\(rel)  \(size ?? "")")
            }
        }
        return out.isEmpty ? [L("(empty)")] : out
    }
}

/// A 16:9 picture of where a game was, or its art on a dark card while it has none
struct ShotThumb: View {
    let image: NSImage?
    let game: Game?
    var width: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    if let game { GameTileArt(game: game, size: width * 0.22) }
                    Text("No picture yet: NX Hub takes one while the game runs").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center).padding(.horizontal, 10)
                }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
    }
}

/// One backup: its picture, when and why; a click restores it (after asking)
private struct BackupTile: View {
    let zip: URL
    let restore: () -> Void
    let trash: () -> Void
    @State private var hover = false

    var body: some View {
        let d = SaveStore.describe(zip)
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                ShotThumb(image: ShotStore.image(ShotStore.forBackup(zip)), game: nil, width: 160)
                if hover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.55))
                    Label("Restore", systemImage: "clock.arrow.circlepath").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 160, height: 90)
            Text(d.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? zip.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(d.label).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: restore)
        .contextMenu {
            Button("Restore…", action: restore)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            Divider()
            Button("Move to Trash", role: .destructive, action: trash)
        }
        .help(zip.lastPathComponent)
    }
}
