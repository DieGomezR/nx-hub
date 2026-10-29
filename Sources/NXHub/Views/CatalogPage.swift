import SwiftUI
import UniformTypeIdentifiers

/// The games nxnative has a profile for, from the checkout: add one by choosing its NSP / XCI files, NX Hub puts them in a folder and builds it
struct CatalogPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var detail: CatalogEntry?

    enum Filter: Hashable { case all, mine, missing }

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 20)]

    var body: some View {
        let owned = Set(model.games.map(\.titleID))
        let shown = model.catalog.filter { e in
            (search.isEmpty || e.name.localizedCaseInsensitiveContains(search) || e.id.localizedCaseInsensitiveContains(search))
            && (filter == .all || (filter == .mine) == owned.contains(e.id))
        }
        PageShell(title: L("Catalog"), systemImage: "square.grid.3x3.fill") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Search", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.panel)).overlay(Capsule().stroke(Theme.stroke))
                    .frame(maxWidth: 320)
                    Picker("", selection: $filter) {
                        Text(LF("All (%lld)", model.catalog.count)).tag(Filter.all)
                        Text("Mine").tag(Filter.mine)
                        Text("Not yet").tag(Filter.missing)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Text(LF("nxnative %@ supports %lld games", model.repo.shortHead, model.catalog.count)).font(.caption).foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 32)
                if model.catalog.isEmpty {
                    Text("The catalog comes from your nxnative checkout (Settings › Build).").foregroundStyle(Theme.secondary).padding(.horizontal, 32)
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(shown) { e in
                            CatalogCard(entry: e, owned: owned.contains(e.id)).onTapGesture { detail = e }
                        }
                    }
                    .padding(.horizontal, 32).padding(.bottom, 32)
                }
            }
        }
        .sheet(item: $detail) { e in CatalogDetail(entry: e) }
    }
}

private struct CatalogCard: View {
    let entry: CatalogEntry
    let owned: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let u = entry.image, let img = NSImage(contentsOf: u) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 34)).foregroundStyle(Theme.tertiary))
                    }
                }
                .frame(height: 150).frame(maxWidth: .infinity).clipped()
                if owned { Chip(text: L("In your library"), color: Theme.good, systemImage: "checkmark.circle.fill").padding(10) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let v = entry.version { Text(LF("Version %@", v)).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                    if let n = entry.note { Text("· " + n).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(hover ? Theme.accent : Theme.stroke, lineWidth: hover ? 2 : 1))
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.spring(duration: 0.2), value: hover)
        .onHover { hover = $0 }
    }
}

/// One supported game: what nxnative says about it, and adding it from your own files
private struct CatalogDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: CatalogEntry
    @State private var picked: [URL] = []
    @State private var busy = false
    @State private var problem: String?

    private var owned: Game? { model.games.first { $0.titleID == entry.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let u = entry.image, let img = NSImage(contentsOf: u) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(height: 260).frame(maxWidth: .infinity).clipped()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.name).font(.system(size: 28, weight: .bold))
                HStack(spacing: 8) {
                    Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let v = entry.version { Chip(text: LF("Update %@", v), color: Theme.accent) }
                    if let n = entry.note { Chip(text: n, color: Theme.warn) }
                }
                if let s = entry.summary { Text(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Divider()
                if let g = owned {
                    HStack {
                        Label("You have this game", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        Spacer()
                        Button("Open") { dismiss(); model.open(.game(g.titleID)) }.buttonStyle(PrimaryPill())
                    }
                } else {
                    Text(LF("Choose your dump of the base game and its update %@ (NSP, XCI, NSZ or XCZ; DLC too, if you have it). NX Hub puts them in a folder of your library and builds the game for the Mac.", entry.version ?? ""))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !picked.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(picked, id: \.self) { u in Label(u.lastPathComponent, systemImage: "doc.fill").font(.caption) }
                        }
                    }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.callout) }
                    HStack {
                        Button("Choose Files…") { choose() }.buttonStyle(GlassPill())
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Add and Build") { Task { await add() } }.buttonStyle(PrimaryPill()).disabled(picked.isEmpty || busy)
                    }
                }
                HStack {
                    Button("nxnative's notes on this game") { NSWorkspace.shared.open(entry.readme) }.buttonStyle(.link)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
        }
        .frame(width: 620)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = ["nsp", "xci", "nsz", "xcz"].compactMap { UTType(filenameExtension: $0) }
        p.message = LF("Choose the files of %@", entry.name)
        guard p.runModal() == .OK else { return }
        picked = p.urls
        let others = picked.compactMap { TitleID.inName($0.lastPathComponent).flatMap(TitleID.base) }.filter { $0 != entry.id }
        problem = others.isEmpty ? nil : LF("Some files are of another game (%@): check that you chose the right ones.", Set(others).joined(separator: ", "))
    }

    private func add() async {
        busy = true; defer { busy = false }
        do {
            try await model.addGame(entry, files: picked)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
