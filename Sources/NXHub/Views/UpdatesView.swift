import SwiftUI

/// The nxnative checkout against GitHub: new commits, what they touch, the update, and the games worth rebuilding
struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    var showBuilds: () -> Void = {}
    @State private var picked: Set<String> = []
    @State private var filter = Filter.games

    enum Filter: Hashable { case games, all }

    var body: some View {
        let repo = model.repo
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                checkoutBox(repo)
                rebuildBox
                nightBox
                incomingBox(repo)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("nxnative")
        .onAppear { picked = Set(model.gamesWorthRebuilding.map(\.titleID)) }
    }

    private func checkoutBox(_ repo: NXNativeRepo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                InfoRow(L("Checkout"), Paths.pretty(repo.url))
                if repo.valid {
                    InfoRow(L("Your version"), [repo.shortHead, repo.headDate?.relative, repo.branch.map { LF("branch %@", $0) } ?? L("detached (follows origin/main)")].compactMap { $0 }.joined(separator: " · "))
                    InfoRow(L("Shaders"), repo.chain.isEmpty ? "—" : repo.chain)
                    InfoRow(L("Last check"), repo.lastFetch?.relative ?? L("not yet"))
                }
                if repo.dirty {
                    Label("The checkout has local changes: NX Hub does not update it while they are there.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let e = repo.error {
                    Label(e, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                HStack {
                    Button { Task { await repo.fetch(); await model.computeChanges() } } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    .disabled(repo.busy || !repo.valid)
                    Button {
                        Task {
                            if await repo.update() {
                                model.notice = L("nxnative is up to date. Rebuild the games below to get the changes.")
                                await model.computeChanges()
                                picked = Set(model.gamesWorthRebuilding.map(\.titleID))
                            }
                        }
                    } label: {
                        Label(repo.incoming.isEmpty ? L("Up to Date") : LF("Update nxnative (%lld new)", repo.incoming.count), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(repo.busy || repo.incoming.isEmpty || repo.dirty)
                    if repo.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if let web = repo.webBase, let u = URL(string: web + "/commits/main") {
                        Link("Open on GitHub", destination: u)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Your nxnative", systemImage: "externaldrive").font(.headline)
        }
    }

    @ViewBuilder private var rebuildBox: some View {
        let worth = model.gamesWorthRebuilding
        if !worth.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These games have changes in nxnative since they were built. A rebuild takes a few minutes per game; shaders are taken from the cache when they did not change.")
                        .foregroundStyle(.secondary)
                    ForEach(worth) { g in
                        let c = model.changes[g.id]
                        Toggle(isOn: Binding(get: { picked.contains(g.titleID) }, set: { if $0 { picked.insert(g.titleID) } else { picked.remove(g.titleID) } })) {
                            HStack {
                                GameTileArt(game: g, size: 22)
                                Text(g.name)
                                Text(reason(c)).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    HStack {
                        Text(LocalizedStringKey(model.config.rebuildForShaders ? "Shader changes count too (Settings › nxnative and builds)." : "Only changes to each game's profile count (Settings › nxnative and builds)."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(LF("Tonight at %@", NightHour.text(model.config.nightHour))) {
                            for g in worth where picked.contains(g.titleID) && !model.config.nightQueue.contains(g.titleID) { model.toggleNight(g) }
                            model.notice = LF("%lld games build tonight at %@. Leave NX Hub open and the Mac on its charger.", picked.count, NightHour.text(model.config.nightHour))
                        }
                        .disabled(picked.isEmpty || !repo.incoming.isEmpty)
                        Button(LF("Rebuild %lld Games", picked.count)) {
                            for g in worth where picked.contains(g.titleID) { model.build(g) }
                            showBuilds()
                        }
                        .disabled(picked.isEmpty || !repo.incoming.isEmpty)
                        .help(LocalizedStringKey(repo.incoming.isEmpty ? "Builds them one after another" : "Update nxnative first"))
                    }
                }
                .padding(6)
            } label: {
                Label("Games to rebuild", systemImage: "hammer").font(.headline)
            }
        }
    }

    private var repo: NXNativeRepo { model.repo }

    /// The builds waiting for the night
    @ViewBuilder private var nightBox: some View {
        let queued = model.config.nightQueue.compactMap { id in model.games.first { $0.titleID == id } }
        if !queued.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LF("They start at %@ if NX Hub is open then. The Mac stays awake until then while it is on its charger.", NightHour.text(model.config.nightHour)))
                        .foregroundStyle(.secondary).font(.callout)
                    ForEach(queued) { g in
                        HStack {
                            GameTileArt(game: g, size: 22)
                            Text(g.name)
                            Spacer()
                            Button("Remove") { model.toggleNight(g) }.buttonStyle(.link)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Build Them Now") {
                            for g in queued { model.toggleNight(g); model.build(g) }
                            showBuilds()
                        }
                    }
                }
                .padding(6)
            } label: {
                Label(LF("Tonight at %@", NightHour.text(model.config.nightHour)), systemImage: "moon.stars.fill").font(.headline)
            }
        }
    }

    private func reason(_ c: GameChanges?) -> String {
        guard let c else { return "" }
        var parts: [String] = []
        if !c.profile.isEmpty { parts.append(LF("%lld profile changes", c.profile.count)) }
        if c.chainOutdated { parts.append(L("new shaders")) }
        return parts.joined(separator: " · ")
    }

    private func incomingBox(_ repo: NXNativeRepo) -> some View {
        let gameIDs = Set(model.games.map(\.titleID))
        let shown = filter == .all ? repo.incoming : repo.incoming.filter { !$0.games.isDisjoint(with: gameIDs) || $0.chain || $0.host || $0.graphics }
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if repo.incoming.isEmpty {
                    Text(LocalizedStringKey(repo.valid ? "No new commits: your nxnative is at GitHub's newest." : "Choose your nxnative checkout in Settings."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $filter) {
                        Text("Your games and the engine").tag(Filter.games)
                        Text(LF("All (%lld)", repo.incoming.count)).tag(Filter.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if repo.incoming.contains(where: \.chain) {
                        Label("This update changes how shaders are translated: every NVN game's shaders are translated again on its next build.", systemImage: "sparkles")
                            .foregroundStyle(.orange)
                    }
                    ForEach(shown) { c in CommitRow(commit: c, showTags: true) }
                    if shown.isEmpty { Text("None of the new commits touch your games or the engine.").foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("New on GitHub", systemImage: "sparkles.rectangle.stack").font(.headline)
        }
    }
}

struct CommitRow: View {
    @Environment(AppModel.self) private var model
    let commit: Commit
    var showTags = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(commit.subject).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let u = model.repo.commitURL(commit) {
                    Link(commit.short, destination: u).font(.caption.monospaced())
                } else {
                    Text(commit.short).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(commit.date.relative).font(.caption).foregroundStyle(.secondary)
                if showTags {
                    ForEach(model.games.filter { commit.games.contains($0.titleID) }) { g in Badge(text: g.name, color: .accentColor) }
                    if commit.chain { Badge(text: L("Shaders"), color: .orange) }
                    if commit.host { Badge(text: L("Host"), color: .purple) }
                    if commit.graphics && !commit.chain { Badge(text: L("Graphics"), color: .blue) }
                    if commit.tools { Badge(text: L("Build tools"), color: .gray) }
                    let others = commit.games.subtracting(model.games.map(\.titleID))
                    if !others.isEmpty { Badge(text: LF("%lld other games", others.count), color: .secondary) }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
