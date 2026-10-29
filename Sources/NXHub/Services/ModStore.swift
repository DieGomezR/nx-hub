import Foundation

/// A mod in NX Hub's mods folder (Application Support/NX Hub/mods/<title ID>/<name>). nxnative replaces RomFS files with a mod's when the game starts
/// with DM_ROMFS_OVERLAY (folders separated by ":", the first that has a file wins; hle_fs.c). Code mods (exefs, .ips patches) do not apply: nxnative
/// recompiles the game's code when it builds it
struct GameMod: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let folder: URL
    let romfs: URL?          // the folder that mirrors the game's RomFS
    let hasCode: Bool        // it also has exefs / .ips files, which nxnative does not take
    let size: Int64
    var usable: Bool { romfs != nil }
}

enum ModStore {
    static let root = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/mods", isDirectory: true)
    static func folder(_ titleID: String) -> URL { root.appendingPathComponent(titleID, isDirectory: true) }

    static func list(_ titleID: String) -> [GameMod] {
        let dir = folder(titleID)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
        return names.compactMap { n -> GameMod? in
            let f = dir.appendingPathComponent(n)
            guard Paths.isDirectory(f) else { return nil }
            let (romfs, code) = inspect(f, titleID: titleID)
            return GameMod(name: n, folder: f, romfs: romfs, hasCode: code, size: size(f))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Where a mod's RomFS files are: a romfs folder at any depth (the one under the game's title ID first, as in Atmosphère's atmosphere/contents/<ID>/romfs),
    /// else the mod folder itself unless it holds only code
    static func inspect(_ mod: URL, titleID: String) -> (URL?, Bool) {
        var romfs: [URL] = []
        var code = false
        if let e = FileManager.default.enumerator(at: mod, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                let n = u.lastPathComponent.lowercased()
                if n == "exefs" || u.pathExtension.lowercased() == "ips" || n == "exefs_patches" { code = true }
                if n == "romfs", Paths.isDirectory(u) { romfs.append(u); e.skipDescendants() }
                if e.level > 5 { e.skipDescendants() }
            }
        }
        if let best = romfs.first(where: { $0.path.uppercased().contains(titleID) }) ?? romfs.min(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            return (best, code)
        }
        let top = ((try? FileManager.default.contentsOfDirectory(atPath: mod.path)) ?? []).filter { !$0.hasPrefix(".") }
        let onlyCode = !top.isEmpty && top.allSatisfy { ["exefs", "atmosphere", "contents", "exefs_patches"].contains($0.lowercased()) || $0.lowercased().hasSuffix(".ips") }
        return (onlyCode || top.isEmpty ? nil : mod, code)
    }

    /// Copies a folder, or unpacks an archive (zip, 7z, rar), into the game's mods folder; returns the mod's name
    static func install(_ src: URL, titleID: String, name wanted: String? = nil) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder(titleID), withIntermediateDirectories: true)
        var name = (wanted ?? src.deletingPathExtension().lastPathComponent).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = "mod" }
        var dest = folder(titleID).appendingPathComponent(name)
        var i = 2
        while fm.fileExists(atPath: dest.path) { dest = folder(titleID).appendingPathComponent("\(name) \(i)"); i += 1 }
        if Paths.isDirectory(src) {
            try fm.copyItem(at: src, to: dest)
        } else {
            let (tmp, isTemp) = try await SaveStore.unpack(src)
            // An archive that holds one folder: that folder is the mod
            let items = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
            let source = items.count == 1 && Paths.isDirectory(items[0]) && !["romfs", "atmosphere", "contents", "exefs"].contains(items[0].lastPathComponent.lowercased()) ? items[0] : tmp
            try fm.copyItem(at: source, to: dest)
            if isTemp { try? fm.removeItem(at: tmp) }
        }
        return dest.lastPathComponent
    }

    static func remove(_ m: GameMod) throws { try FileManager.default.trashItem(at: m.folder, resultingItemURL: nil) }

    /// The mods of an Atmosphère SD card (or a copy of its folders): atmosphere/contents/<title ID>/ (or contents/<title ID>/) with a romfs or exefs folder.
    /// Each game of the list gets the one it has, as a mod named after the folder it came from; returns title ID → mod name
    static func importAtmosphere(_ root: URL, titleIDs: Set<String>) throws -> [(String, String)] {
        let fm = FileManager.default
        var contents: [URL] = []
        for c in ["atmosphere/contents", "contents", "atmosphere/titles", "titles", ""] {
            let u = c.isEmpty ? root : root.appendingPathComponent(c)
            if Paths.isDirectory(u) { contents.append(u) }
        }
        var done: [(String, String)] = []
        for dir in contents {
            for e in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where e.count == 16 && titleIDs.contains(e.uppercased()) {
                let src = dir.appendingPathComponent(e)
                let parts = ((try? fm.contentsOfDirectory(atPath: src.path)) ?? []).map { $0.lowercased() }
                guard parts.contains("romfs") || parts.contains("exefs") else { continue }
                let tid = e.uppercased()
                try fm.createDirectory(at: folder(tid), withIntermediateDirectories: true)
                var name = "Atmosphère (\(root.lastPathComponent))"
                var dest = folder(tid).appendingPathComponent(name)
                var i = 2
                while fm.fileExists(atPath: dest.path) { name = "Atmosphère (\(root.lastPathComponent)) \(i)"; dest = folder(tid).appendingPathComponent(name); i += 1 }
                try fm.copyItem(at: src, to: dest)
                done.append((tid, name))
            }
        }
        return done
    }

    static func size(_ u: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    /// DM_ROMFS_OVERLAY for the mods turned on, in priority order (the first wins where two replace one file)
    static func overlay(enabled: [String], mods: [GameMod]) -> String? {
        let paths = enabled.compactMap { n in mods.first { $0.name == n }?.romfs?.path }.filter { !$0.contains(":") }
        return paths.isEmpty ? nil : paths.joined(separator: ":")
    }
}
