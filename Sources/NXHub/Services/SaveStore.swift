import Foundation

/// A game's save data on the Mac: the folder nxnative mounts as its save (the committed copy; .work and .new beside it exist only while the game runs)
struct SaveSlot: Identifiable, Hashable {
    var id: String { titleID }
    let titleID: String
    let name: String
    let folder: URL
    let size: Int64
    let files: Int
    let modified: Date?
    var exists: Bool { files > 0 }
}

/// Where backups go, how a save is backed up, restored and replaced, and how an imported save (a zip or a folder from another tool) is unpacked
enum SaveStore {
    static let backupsRoot = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/save-backups", isDirectory: true)
    static func backups(_ titleID: String) -> URL { backupsRoot.appendingPathComponent(titleID, isDirectory: true) }

    /// Every game's save: Mac apps keep it in Application Support/nxnative/<title ID>/save, a development build in <title ID>_build/run/save
    static func slots(games: [Game]) -> [SaveSlot] {
        var out: [SaveSlot] = []
        var seen = Set<String>()
        for g in games {
            let folder = g.app != nil || g.buildDir == nil ? Paths.gameSaves(g.titleID) : g.buildDir!.appendingPathComponent("run/save")
            out.append(slot(g.titleID, g.name, folder)); seen.insert(g.titleID)
        }
        // Saves of games no longer in the library
        let root = Paths.home.appendingPathComponent("Library/Application Support/nxnative")
        for tid in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where tid.count == 16 && !seen.contains(tid.uppercased()) {
            let s = slot(tid.uppercased(), tid.uppercased(), root.appendingPathComponent(tid).appendingPathComponent("save"))
            if s.exists { out.append(s) }
        }
        return out
    }

    static func slot(_ tid: String, _ name: String, _ folder: URL) -> SaveSlot {
        var size: Int64 = 0, files = 0
        var newest: Date?
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                files += 1; size += Int64(v.fileSize ?? 0)
                if let m = v.contentModificationDate, m > (newest ?? .distantPast) { newest = m }
            }
        }
        return SaveSlot(titleID: tid, name: name, folder: folder, size: size, files: files, modified: newest)
    }

    static func listBackups(_ titleID: String) -> [URL] {
        let dir = backups(titleID)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// A zip of the save's contents in the backups folder, named by date
    @discardableResult
    static func backup(_ s: SaveSlot, label: String = "") async throws -> URL {
        let dir = backups(s.titleID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let out = dir.appendingPathComponent(f.string(from: Date()) + (label.isEmpty ? "" : "_" + label) + ".zip")
        let r = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", s.folder.path, out.path])
        guard r.ok else { throw SaveError.tool(r.message) }
        let shot = ShotStore.last(s.titleID)
        if Paths.exists(shot) { try? FileManager.default.copyItem(at: shot, to: ShotStore.forBackup(out)) }
        return out
    }

    /// A backup's date and why it was made, from its name (2026-10-29_21-04-11_auto.zip)
    static func describe(_ zip: URL) -> (date: Date?, label: String) {
        let name = zip.deletingPathExtension().lastPathComponent
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let date = f.date(from: String(name.prefix(19)))
        let tag = name.count > 20 ? String(name.dropFirst(20)) : ""
        switch tag {
        case "auto": return (date, L("Before playing"))
        case "before-import": return (date, L("Before it was replaced"))
        case "": return (date, L("Backup"))
        default: return (date, tag)
        }
    }

    /// Unpacks a zip / 7z / rar / tar (bsdtar reads them all) or takes a folder; returns the folder to look in and whether it is a temporary copy
    static func unpack(_ src: URL) async throws -> (URL, Bool) {
        if Paths.isDirectory(src) { return (src, false) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nxhub-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let r: ShellResult
        if src.pathExtension.lowercased() == "zip" { r = await Shell.run("/usr/bin/ditto", ["-x", "-k", src.path, tmp.path]) }
        else { r = await Shell.run("/usr/bin/bsdtar", ["-xf", src.path, "-C", tmp.path]) }
        guard r.ok else { try? FileManager.default.removeItem(at: tmp); throw SaveError.tool(r.message) }
        return (tmp, true)
    }

    /// The folders of an unpacked save that could be its root: the folder itself, then down through folders that hold only one folder,
    /// and any folder named save. Sorted best first: the one whose top entries match the current save's, else the deepest single-folder chain
    static func candidates(in root: URL, matching current: URL?) -> [URL] {
        let fm = FileManager.default
        func children(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
        }
        var out: [URL] = [root]
        var cur = root
        while true {
            let c = children(cur)
            guard c.count == 1, let only = c.first, Paths.isDirectory(only) else { break }
            out.append(only); cur = only
        }
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where Paths.isDirectory(u) && u.lastPathComponent.lowercased() == "save" && !out.contains(u) { out.append(u) }
        }
        let want = Set(current.map { children($0).map { $0.lastPathComponent } } ?? [])
        func score(_ u: URL) -> Int { want.isEmpty ? 0 : children(u).filter { want.contains($0.lastPathComponent) }.count }
        let deepest = out.last
        return out.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            return a == deepest && b != deepest
        }
    }

    /// Replaces the save with the contents of a folder, after a backup of the current one
    static func replace(_ s: SaveSlot, with source: URL) async throws {
        if s.exists { try await backup(s, label: "before-import") }
        let fm = FileManager.default
        try fm.createDirectory(at: s.folder, withIntermediateDirectories: true)
        for c in (try? fm.contentsOfDirectory(at: s.folder, includingPropertiesForKeys: nil)) ?? [] { try fm.removeItem(at: c) }
        for c in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) where c.lastPathComponent != "__MACOSX" {
            try fm.copyItem(at: c, to: s.folder.appendingPathComponent(c.lastPathComponent))
        }
    }

    static func restore(_ s: SaveSlot, from zip: URL) async throws {
        let (dir, temp) = try await unpack(zip)
        defer { if temp { try? FileManager.default.removeItem(at: dir) } }
        try await replace(s, with: dir)
    }

    enum SaveError: LocalizedError {
        case tool(String)
        var errorDescription: String? { switch self { case .tool(let m): return m } }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
