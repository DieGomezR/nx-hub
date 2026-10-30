import SwiftUI

/// NX Hub's settings, in the window: the library, nxnative and its build, settings for every game at once, the interface, saves, and where things are
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section = .games

    enum Section: String, CaseIterable, Identifiable {
        case games, library, build, interface, saves, data
        var id: String { rawValue }
        var title: String {
            switch self {
            case .games: return L("All games")
            case .library: return L("Library")
            case .build: return L("nxnative and builds")
            case .interface: return L("Interface")
            case .saves: return L("Saves")
            case .data: return L("Data and folders")
            }
        }
        var icon: String {
            switch self {
            case .games: return "gamecontroller.fill"
            case .library: return "square.grid.2x2.fill"
            case .build: return "hammer.fill"
            case .interface: return "paintbrush.fill"
            case .saves: return "externaldrive.fill"
            case .data: return "folder.fill"
            }
        }
    }

    var body: some View {
        PageShell(title: L("Settings"), systemImage: "gearshape.fill") {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Section.allCases) { s in
                        Button { section = s } label: {
                            Label(s.title, systemImage: s.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(section == s ? .black : Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(section == s ? Color.white : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 230)
                .card(padding: 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch section {
                        case .games: AllGamesSettings()
                        case .library: LibrarySettings()
                        case .build: BuildSettings()
                        case .interface: InterfaceSettings()
                        case .saves: SavesSettings()
                        case .data: DataSettings()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 32)
                }
            }
            .padding(.horizontal, 32)
        }
        .onAppear { if let t = DevSnapshot.tab, let s = Section(rawValue: t) { section = s; DevSnapshot.tab = nil } }
    }
}

/// Settings for every game at once: each choice is written into every game that has the setting, as if it were chosen in each
private struct AllGamesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [Setting] = []
    @State private var revision = 0

    var body: some View {
        let _ = revision
        GroupBox("Settings for all your games") {
            VStack(alignment: .leading, spacing: 14) {
                Text("A choice here goes into every game that has the setting, as if you chose it on each game's page. A game can still be changed on its own afterwards.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                let sections = rows.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
                ForEach(sections, id: \.self) { section in
                    Text(LS(section)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary).padding(.top, 4)
                    ForEach(rows.filter { $0.section == section }) { row in
                        GlobalRow(setting: row, choices: row.kind == .choice ? model.choices(for: row.env) : []) { revision += 1 }
                    }
                }
                if rows.isEmpty { Text("Build a game's Mac app first: the settings come from the games.").foregroundStyle(Theme.secondary) }
                HStack {
                    Spacer()
                    Button("Reset All Games to Tested Defaults") {
                        for r in rows { model.applyToAllGames(r.env, nil) }
                        model.config.globalSettings = [:]
                        revision += 1
                        model.notice = L("Every game is back at its tested defaults.")
                    }
                    .buttonStyle(GlassPill(tint: Theme.warn))
                }
            }
        }
        .onAppear { rows = model.allGameSettings }
    }
}

private struct GlobalRow: View {
    @Environment(AppModel.self) private var model
    let setting: Setting
    let choices: [Setting.Choice]
    let changed: () -> Void

    private var value: String { model.config.globalSettings[setting.env] ?? "" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(LS(setting.label))
                if !setting.note.isEmpty { Text(LS(setting.note)).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            switch setting.kind {
            case .choice:
                Picker("", selection: Binding(get: { value }, set: { apply($0.isEmpty ? nil : $0) })) {
                    Text("Each game's own").tag("")
                    ForEach(choices, id: \.self) { c in Text(LS(c.label)).tag(c.value) }
                }
                .labelsHidden().fixedSize()
            case .toggle:
                Picker("", selection: Binding(get: { value }, set: { apply($0.isEmpty ? nil : $0) })) {
                    Text("Each game's own").tag("")
                    Text("On").tag(setting.on ?? "1")
                    Text("Off").tag(setting.off ?? "0")
                }
                .labelsHidden().fixedSize()
            case .range:
                let lo = setting.min ?? 0, hi = Swift.max(setting.max ?? 1, lo + 0.0001)
                HStack {
                    Toggle("", isOn: Binding(get: { !value.isEmpty }, set: { apply($0 ? setting.default : nil) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Slider(value: Binding(get: { Double(value) ?? Double(setting.default) ?? lo }, set: { apply(setting.format($0)) }), in: lo...hi, step: setting.step ?? 0.05)
                        .frame(width: 160).disabled(value.isEmpty)
                    Text(value.isEmpty ? "—" : value).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            case .unknown:
                EmptyView()
            }
        }
    }

    private func apply(_ v: String?) {
        let n = model.applyToAllGames(setting.env, v)
        changed()
        if v != nil { model.notice = LF("%@: applied to %lld games.", LS(setting.label), n) }
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var picked: String?

    var body: some View {
        @Bindable var config = model.config
        GroupBox("Library folders") {
            VStack(alignment: .leading, spacing: 10) {
                Text("NX Hub looks in each folder and in its subfolders for a game's NSP / XCI files, its nxnative build folder (<title ID>_build) or its Mac app. Apps in Applications are found too.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(config.libraryFolders, id: \.self) { f in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        Text(f).font(.callout.monospaced())
                        Spacer()
                        Button { NSWorkspace.shared.open(Paths.expand(f)) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            config.libraryFolders.removeAll { $0 == f }
                            Task { await model.reloadLibrary(); await model.computeChanges() }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button { addFolder(config) } label: { Label("Add Folder…", systemImage: "plus") }.buttonStyle(GlassPill())
                    Button { Task { await model.reloadLibrary(); await model.computeChanges() } } label: { Label("Look for Games Again", systemImage: "arrow.clockwise") }.buttonStyle(GlassPill())
                    Spacer()
                    Text(LF("%lld games found", model.games.count)).font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private func addFolder(_ config: Config) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = L("Choose the folder that holds your game folders (each with a game's NSP files)")
        guard p.runModal() == .OK else { return }
        for u in p.urls where !config.libraryFolders.contains(Paths.pretty(u)) { config.libraryFolders.append(Paths.pretty(u)) }
        Task { await model.reloadLibrary(); await model.computeChanges() }
    }
}

private struct BuildSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var config = model.config
        GroupBox("nxnative") {
            VStack(alignment: .leading, spacing: 10) {
                PathRowField(title: L("Checkout"), path: $config.nxnativePath, directory: true, ok: NXNativeRepo.isCheckout(config.nxnativeURL), problem: L("Not an nxnative checkout"))
                    .onSubmit { Task { await model.nxnativePathChanged() } }
                Text("A clone or worktree of github.com/seedds/nxnative. NX Hub updates it to origin/main and builds your games with it.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Toggle("Check GitHub for nxnative updates when NX Hub opens", isOn: $config.checkAtLaunch)
                HStack {
                    Button { Task { await model.nxnativePathChanged() } } label: { Label("Use This Checkout", systemImage: "checkmark") }.buttonStyle(GlassPill())
                    Button { model.open(.nxnative) } label: { Label("Updates and Builds", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(GlassPill())
                }
            }
        }
        GroupBox("Build") {
            VStack(alignment: .leading, spacing: 10) {
                PathRowField(title: L("Python"), path: $config.pythonPath, directory: false, ok: FileManager.default.isExecutableFile(atPath: Paths.expand(config.pythonPath).path), problem: L("Not found"))
                PathRowField(title: "prod.keys", path: $config.keysPath, directory: false, ok: !config.keysPath.isEmpty && Paths.exists(Paths.expand(config.keysPath)), problem: L("Not found"))
                Text("The Python that runs nxnative's NSP script (3.12 or newer, with its packages), and the keys of your own Switch.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Toggle("Build with this Mac's Metal compiler even when nxnative tested another (--allow-other-metal)", isOn: $config.allowOtherMetal)
                if let v = TestedXcode.lockedVersion(config.nxnativeURL) {
                    Text(LF("With this off and Xcode %@ (the one nxnative tested) installed beside yours as /Applications/Xcode-%@.app with its Metal toolchain, NX Hub builds with it and leaves your selected Xcode as it is.", v, v))
                        .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Pack the app without shaders that stopped translating (--allow-shader-regressions)", isOn: $config.allowShaderRegressions)
            }
        }
        GroupBox("Rebuilds") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Suggest a rebuild when nxnative changes how shaders are translated", isOn: $config.rebuildForShaders)
                Text("A new translation means every shader of the game is translated again: the longest part of a build. Off: only changes to the game's own profile count. A game can also keep its build (its page, or its menu).")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Keep the Mac awake while a game builds", isOn: $config.awakeWhileBuilding)
                HStack {
                    Text("Night builds start at")
                    Spacer()
                    Picker("", selection: $config.nightHour) {
                        ForEach(0..<24, id: \.self) { h in Text(NightHour.text(h)).tag(h) }
                    }
                    .labelsHidden().fixedSize()
                }
                if let k = CPULoad.kinds {
                    Text(LF("This Mac has %lld cores (%lld performance, %lld efficiency). Each build shows how many it keeps busy, step by step.", CPULoad.count, k.p, k.e))
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

private struct PathRowField: View {
    let title: String
    @Binding var path: String
    let directory: Bool
    let ok: Bool
    let problem: String

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading).foregroundStyle(Theme.secondary)
            TextField("", text: $path).textFieldStyle(.roundedBorder).font(.callout.monospaced())
            Button("Choose…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = directory; p.canChooseFiles = !directory; p.showsHiddenFiles = true
                if p.runModal() == .OK, let u = p.url { path = Paths.pretty(u) }
            }
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Theme.good : Theme.warn).help(ok ? "" : problem)
        }
    }
}

private struct InterfaceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var language: String = {
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return own?.first.flatMap { $0.hasPrefix("es") ? "es" : $0.hasPrefix("en") ? "en" : nil } ?? "system"
    }()

    var body: some View {
        @Bindable var config = model.config
        GroupBox("Interface") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("NX Hub's language")
                    Spacer()
                    Picker("", selection: $language) {
                        Text("Same as the Mac").tag("system")
                        Text(verbatim: "Español").tag("es")
                        Text(verbatim: "English").tag("en")
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: language) {
                        if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                        else { UserDefaults.standard.set([language], forKey: "AppleLanguages") }
                        model.notice = L("The language changes the next time NX Hub opens.")
                    }
                }
                Toggle("Move through NX Hub with a controller (D-pad or stick, A, B)", isOn: $config.padNavigation)
                Toggle("Show the button hints on the start screen", isOn: $config.showHints)
                Toggle("Open NX Hub in full screen, like a console", isOn: $config.startFullScreen)
                Text("Game text follows each game's Game language setting (or the one for all games above).").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        GroupBox("While you play") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("The controller's Home button (PS, Xbox) brings NX Hub back", isOn: $config.homeButton)
                    .onChange(of: config.homeButton) { model.pads.monitorInBackground("game", config.homeButton && model.session != nil) }
                Toggle("Pause the game while NX Hub is in front", isOn: $config.pauseOnHome).disabled(!config.homeButton)
                    .padding(.leading, 20)
                Text("As on the Switch: Home in a game started from NX Hub opens NX Hub's start screen with the game paused; A or Home goes back to it, X closes it.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("A picture of where you are")
                    Spacer()
                    Picker("", selection: $config.shotMinutes) {
                        Text("Only on Home").tag(0)
                        Text("Every minute").tag(1)
                        Text(LF("Every %lld minutes", 2)).tag(2)
                        Text(LF("Every %lld minutes", 5)).tag(5)
                        Text(LF("Every %lld minutes", 10)).tag(10)
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: config.shotMinutes) { model.session?.startShots(every: config.shotMinutes) }
                }
                Text("The last picture shows on the start screen and with the game's save; each save backup keeps the one of its moment.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Saves: backups when a game starts or saves, and the cloud folder every game syncs through
private struct SavesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var config = model.config
        GroupBox("Saves") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Back up a game's save each time it starts from NX Hub", isOn: $config.backupBeforePlay)
                Toggle("Back up the save, with a picture, each time the game saves", isOn: $config.backupOnGameSave)
                HStack {
                    Text("Keep, per game")
                    Spacer()
                    Picker("", selection: $config.gameSaveBackups) {
                        ForEach([10, 20, 50, 100], id: \.self) { n in Text(LF("The last %lld", n)).tag(n) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!config.backupOnGameSave).padding(.leading, 20)
                Text("Restoring one of those backups (Saves) brings back that save, and its picture shows where you were as the game saved. The exact instant you left a game at is kept only while it is suspended: Home pauses it (with Pause the game while NX Hub is in front on), and it waits there until you go back, close it or restart the Mac.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        GroupBox("Cloud saves") { CloudSavesSettings() }
    }
}

/// nxnative's cloud saves for every game: one folder in iCloud Drive that each game's app syncs its save through (docs/settings.md, Cloud saves)
struct CloudSavesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var report = AppModel.CloudReport()

    private var on: Bool { !model.config.cloudSavesFolder.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Sync every game's save through iCloud Drive", isOn: Binding(get: { on }, set: { want in
                if want { use(CloudSaves.defaultFolder.path) } else { model.config.cloudSavesFolder = ""; report = model.applyCloudSaves() }
            }))
            .disabled(!on && !CloudSaves.iCloudDriveOn)
            if on {
                let folder = model.config.cloudSavesFolder
                HStack {
                    Text(CloudSaves.display(folder)).font(.callout).lineLimit(1).truncationMode(.middle).help(Paths.pretty(Paths.expand(folder)))
                    Spacer()
                    Button("Choose Folder…") { choose() }
                    Button { NSWorkspace.shared.open(Paths.expand(model.config.cloudSavesFolder)) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                }
                .padding(.leading, 20)
                if report.iCloudOff {
                    Label("iCloud Drive is off on this Mac: no game syncs until it is on again (System Settings › your name › iCloud › iCloud Drive).", systemImage: "icloud.slash")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                } else if CloudSaves.inICloudDrive(folder) && CloudSaves.access() == .noAccess {
                    Label("NX Hub may not open iCloud Drive, so it cannot show when games sync, nor warn when another device saved a game suspended here: allow it in System Settings › Privacy & Security › Files and Folders. The games ask for themselves.", systemImage: "lock.icloud")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                } else if !CloudSaves.inICloudDrive(folder) {
                    Label("This folder is outside iCloud Drive: the iPhone app cannot reach it, so only games on this Mac use it.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !report.tooOld.isEmpty {
                    Label(LF("Built before nxnative had cloud saves, so they do not sync yet: %@. Rebuilding them brings it.", report.tooOld.map(\.name).joined(separator: ", ")), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                if !report.ownChoice.isEmpty {
                    Label(LF("These keep the folder chosen in their own settings window: %@.", report.ownChoice.map(\.name).joined(separator: ", ")), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if !CloudSaves.iCloudDriveOn {
                Text("iCloud Drive is off on this Mac: turn it on in System Settings › your name › iCloud › iCloud Drive.")
                    .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            Text("Each game keeps one file there and syncs a few seconds after it saves; the newest save wins, and each save a sync replaces is kept beside the game's save. Choose the same folder in the iPhone app's Cloud saves to play the same game on both. macOS may ask once whether a game may open iCloud Drive: a game refused there does not sync (System Settings › Privacy & Security › Files and Folders).")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if on { report = model.applyCloudSaves() } }
    }

    private func use(_ chosen: String) {
        var folder = chosen
        // A game's own folder (named after its title ID, as the iPhone's picker shows it once a device has synced): every game needs the one above it
        let last = Paths.expand(folder).lastPathComponent
        if last.count == 16, last.allSatisfy(\.isHexDigit) { folder = Paths.expand(folder).deletingLastPathComponent().path }
        guard CloudSaves.prepare(folder) else {
            model.notice = CloudSaves.inICloudDrive(folder) && CloudSaves.access() == .noAccess
                ? L("NX Hub may not open iCloud Drive: allow it in System Settings › Privacy & Security › Files and Folders, then try again.")
                : LF("NX Hub cannot make or open %@.", CloudSaves.display(folder))
            return
        }
        model.config.cloudSavesFolder = folder
        report = model.applyCloudSaves()
        model.notice = folder == chosen ? L("Cloud saves are on: each game syncs from its next start.") : LF("Cloud saves are on, through %@ (the folder that holds every game's): each game syncs from its next start.", CloudSaves.display(folder))
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.directoryURL = CloudSaves.iCloudDriveOn ? CloudSaves.iCloudDrive : Paths.home
        p.message = L("Choose the folder every game syncs its save through (the same one as on your iPhone)")
        guard p.runModal() == .OK, let u = p.url else { return }
        use(u.path)
    }
}

private struct DataSettings: View {
    var body: some View {
        GroupBox("Where NX Hub keeps things") {
            VStack(alignment: .leading, spacing: 8) {
                FolderLine(label: L("Mods"), url: ModStore.root)
                FolderLine(label: L("Cheats"), url: CheatStore.root)
                FolderLine(label: L("Save backups"), url: SaveStore.backupsRoot)
                FolderLine(label: L("Pictures of where you left"), url: ShotStore.root)
                FolderLine(label: L("Build logs"), url: Paths.hubLogs)
                FolderLine(label: L("Game saves (nxnative)"), url: Paths.home.appendingPathComponent("Library/Application Support/nxnative"))
                FolderLine(label: L("Game logs (nxnative)"), url: Paths.home.appendingPathComponent("Library/Logs/nxnative"))
            }
        }
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "NX Hub \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.headline)
                Text("A library and launcher for the games nxnative builds. nxnative does the real work: github.com/seedds/nxnative.").foregroundStyle(Theme.secondary)
            }
        }
    }
}

private struct FolderLine: View {
    let label: String
    let url: URL
    var body: some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading).foregroundStyle(Theme.secondary)
            Text(Paths.pretty(url)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
        }
    }
}
