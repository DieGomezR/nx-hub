import Foundation

/// Finds the games in the library folders: each folder and its subfolders that hold a game's packages (NSP, NSZ, XCI, XCZ), its nxnative work folder
/// (<title ID>_build) or a Mac app nxnative packed. A folder may hold more than one game. Apps are also looked for in /Applications.
enum LibraryScanner {
    static let packageExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    static func scan(folders: [URL]) -> [Game] {
        var byID: [String: Game] = [:]
        var seen = Set<String>()
        for root in folders where Paths.isDirectory(root) {
            var candidates = [root]
            candidates += subfolders(of: root)
            for dir in candidates where seen.insert(dir.standardizedFileURL.path).inserted {
                for g in games(in: dir) { merge(g, into: &byID) }
            }
        }
        // Apps moved to /Applications (or ~/Applications) join the game they were built from
        for appsDir in [URL(fileURLWithPath: "/Applications"), Paths.home.appendingPathComponent("Applications")] where Paths.isDirectory(appsDir) {
            for url in (try? FileManager.default.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            where url.pathExtension == "app" {
                if let a = AppBundle(url: url) { merge(Game(titleID: a.titleID, name: a.name, version: a.version, app: a), into: &byID) }
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func subfolders(of root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true && u.pathExtension != "app"
        }
    }

    /// The games one folder holds
    private static func games(in dir: URL) -> [Game] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var packages: [String: [URL]] = [:]       // base title ID → packages
        var buildDirs: [String: URL] = [:]
        var apps: [String: AppBundle] = [:]
        for u in items {
            let name = u.lastPathComponent
            if packageExtensions.contains(u.pathExtension.lowercased()) {
                if let t = TitleID.inName(name), let b = TitleID.base(t) { packages[b, default: []].append(u) }
                else { packages["?", default: []].append(u) }   // a package without an ID in its name ("Mario Party Superstars.nsp")
            } else if name.count == 22, name.hasSuffix("_build"), let b = TitleID.base(String(name.prefix(16)).uppercased()), Paths.isDirectory(u) {
                buildDirs[b] = u
            } else if u.pathExtension == "app", let a = AppBundle(url: u) {
                if let old = apps[a.titleID], (old.builtAt ?? .distantPast) > (a.builtAt ?? .distantPast) { continue }
                apps[a.titleID] = a
            }
        }
        var ids = Set(packages.keys).union(buildDirs.keys).union(apps.keys)
        // Packages without an ID belong to the folder's only game
        if let loose = packages["?"] {
            ids.remove("?")
            if ids.count == 1, let only = ids.first { packages[only, default: []] += loose }
        }
        packages["?"] = nil
        return ids.sorted().map { tid in
            var g = Game(titleID: tid, name: "", folder: dir, app: apps[tid], buildDir: buildDirs[tid], packages: (packages[tid] ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent })
            let nacp = buildDirs[tid].flatMap(newestExtraction)
            g.extractIcon = nacp.map { $0.deletingLastPathComponent().appendingPathComponent("icon.jpg") }.flatMap { Paths.exists($0) ? $0 : nil }
            let control = nacp.flatMap { NACP(url: $0) }
            g.name = apps[tid]?.name ?? control?.name ?? basePackageName(g.packages, tid) ?? dir.lastPathComponent
            g.version = apps[tid]?.version ?? control.flatMap { $0.displayVersion.isEmpty ? nil : $0.displayVersion }
            return g
        }
    }

    /// control.nacp of the newest version nxnative extracted (extract/v<N>/control.nacp, the highest N)
    private static func newestExtraction(_ build: URL) -> URL? {
        let ex = build.appendingPathComponent("extract")
        let vs = ((try? FileManager.default.contentsOfDirectory(atPath: ex.path)) ?? []).compactMap { v -> (Int, URL)? in
            guard v.hasPrefix("v"), let n = Int(v.dropFirst()) else { return nil }
            let c = ex.appendingPathComponent(v).appendingPathComponent("control.nacp")
            return Paths.exists(c) ? (n, c) : nil
        }
        return vs.max { $0.0 < $1.0 }?.1
    }

    private static func basePackageName(_ packages: [URL], _ tid: String) -> String? {
        let base = packages.first { TitleID.inName($0.lastPathComponent) == tid } ?? packages.first
        return base.map { TitleID.cleanName($0.lastPathComponent) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The same game found twice (an app in /Applications, its packages in a library folder): one entry, with the folder that can build it
    private static func merge(_ g: Game, into games: inout [String: Game]) {
        guard var old = games[g.titleID] else { games[g.titleID] = g; return }
        if old.folder == nil || (old.packages.isEmpty && !g.packages.isEmpty) {
            old.folder = g.folder; old.packages = g.packages; old.buildDir = g.buildDir ?? old.buildDir; old.extractIcon = g.extractIcon ?? old.extractIcon
        }
        if let a = g.app, (old.app?.builtAt ?? .distantPast) < (a.builtAt ?? .distantPast) { old.app = a; old.name = a.name; old.version = a.version ?? old.version }
        games[g.titleID] = old
    }
}
