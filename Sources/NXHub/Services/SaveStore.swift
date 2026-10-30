import Foundation

/// A game's save data on the Mac: the folder nxnative mounts as its save (the committed copy; .work and .new beside it exist only while the game runs),
/// the device save beside it for a game that keeps one (<save>_device), and nxnative's record of its last cloud sync (<save>.sync)
struct SaveSlot: Identifiable, Hashable {
    var id: String { titleID }
    let titleID: String
    let name: String
    let folder: URL
    let size: Int64
    let files: Int
    let modified: Date?
    var exists: Bool { files > 0 }
    var device: URL { URL(fileURLWithPath: folder.path + "_device", isDirectory: true) }
    var syncBase: URL { URL(fileURLWithPath: folder.path + ".sync") }
}

/// Where backups go, how a save is backed up, restored and replaced, and how an imported save (a zip or a folder from another tool) is unpacked
enum SaveStore {
    static let backupsRoot = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/save-backups", isDirectory: true)
    static func backups(_ titleID: String) -> URL { backupsRoot.appendingPathComponent(titleID, isDirectory: true) }
    /// In a backup made with the device save too: save/ and save_device/ beside this file
    static let layoutMarker = "nxhub-backup.json"

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

    /// Backup names: the local date and time in fixed digits, whatever the Mac's calendar and clock settings
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Newest first, by when each zip was written (a name sorts wrongly across a change of the clock)
    static func listBackups(_ titleID: String) -> [URL] {
        let dir = backups(titleID)
        let zips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.pathExtension == "zip" }
        func made(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? describe(u).date ?? .distantPast }
        return zips.map { ($0, made($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }.map { $0.0 }
    }

    /// One whole committed version of the save (and of its device save) in a temporary folder. nxnative never changes a committed folder in place: each commit
    /// swaps a new one in (dm/host/hle_fs.c), so a clone taken while the folder's file number stays the same is one version. Retried when a commit lands meanwhile;
    /// never the live folder
    static func snapshot(_ s: SaveSlot) async throws -> URL {
        let fm = FileManager.default
        for attempt in 1...6 {
            let root = fm.temporaryDirectory.appendingPathComponent("nxhub-save-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var whole = true
            for (src, name) in [(s.folder, "save"), (s.device, "save_device")] where Paths.isDirectory(src) {
                let dst = root.appendingPathComponent(name, isDirectory: true)
                let before = Paths.fileNumber(src)
                var ok = clonefile(src.path, dst.path, 0) == 0
                if !ok { ok = (try? fm.copyItem(at: src, to: dst)) != nil }   // another volume: copied, checked the same way
                if !ok || Paths.fileNumber(src) != before { whole = false; break }
            }
            if whole { return root }
            try? fm.removeItem(at: root)
            try? await Task.sleep(for: .milliseconds(150 * attempt))
        }
        throw SaveError.tool(L("The save kept changing while NX Hub copied it: try again in a moment."))
    }

    /// The files of a snapshot as one line each (path, size, date): two equal signatures are the same save
    static func signature(_ root: URL) -> String {
        var lines: [String] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                lines.append("\(u.path.dropFirst(root.path.count)) \(v.fileSize ?? 0) \(v.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// A zip of the save in the backups folder, named by date and why, with a picture beside it: the given one, else (pictureFromLast) the last one taken
    @discardableResult
    static func backup(_ s: SaveSlot, label: String = "", picture: URL? = nil, pictureFromLast: Bool = true) async throws -> URL {
        guard let z = try await archive(s, label: label, picture: picture ?? (pictureFromLast ? ShotStore.last(s.titleID) : nil), unlessSignature: nil).zip else { throw SaveError.tool(L("Nothing to back up.")) }
        return z
    }

    /// The backup made when the game saved: none when the save is the same as the one before (previous signature); returns the zip and the save's signature
    static func gameBackup(_ s: SaveSlot, picture: URL?, previous: String?) async throws -> (zip: URL?, signature: String) {
        try await archive(s, label: "game", picture: picture, unlessSignature: previous)
    }

    private static func archive(_ s: SaveSlot, label: String, picture: URL?, unlessSignature previous: String?) async throws -> (zip: URL?, signature: String) {
        let fm = FileManager.default
        let snap = try await snapshot(s)
        defer { try? fm.removeItem(at: snap) }
        let sig = signature(snap)
        if let previous, previous == sig { return (nil, sig) }
        let marker = ["layout": 2, "device": Paths.isDirectory(snap.appendingPathComponent("save_device")) ? 1 : 0]
        try JSONSerialization.data(withJSONObject: marker).write(to: snap.appendingPathComponent(layoutMarker))
        let dir = backups(s.titleID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = stamp.string(from: Date()) + (label.isEmpty ? "" : "_" + label)
        var out = dir.appendingPathComponent(name + ".zip")
        for k in 2...99 where Paths.exists(out) { out = dir.appendingPathComponent("\(name)-\(k).zip") }
        // Extended attributes go into the zip too (__MACOSX): nxnative keeps a file's real name in one when two names differ only in case (dm/host/hle_fs.c)
        let r = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", snap.path, out.path])
        guard r.ok else { try? fm.removeItem(at: out); throw SaveError.tool(r.message) }
        if let picture, Paths.exists(picture) { try? fm.copyItem(at: picture, to: ShotStore.forBackup(out)) }
        return (out, sig)
    }

    /// Keeps the newest `keep` backups made with this label (and their pictures); the others stay
    /// At most one backup per `minutes`, and the newest save always there: the backup before `newest` goes when it came less than `minutes` after the one
    /// before it (it only held the newest save of that stretch; now `newest` does)
    static func thin(_ titleID: String, label: String, newest: URL, minutes: Int) {
        let mine = listBackups(titleID).filter { describe($0).tag == label && $0 != newest }   // newest first
        guard mine.count >= 2, let a = describe(mine[0]).date, let b = describe(mine[1]).date, a.timeIntervalSince(b) < Double(minutes) * 60 else { return }
        try? FileManager.default.removeItem(at: mine[0])
        let png = ShotStore.forBackup(mine[0])
        if FileManager.default.fileExists(atPath: png.path) { try? FileManager.default.removeItem(at: png) }
    }

    static func prune(_ titleID: String, label: String, keep: Int) {
        let mine = listBackups(titleID).filter { describe($0).tag == label }
        for z in mine.dropFirst(max(0, keep)) {
            try? FileManager.default.removeItem(at: z)
            try? FileManager.default.removeItem(at: ShotStore.forBackup(z))
        }
    }

    /// A backup's date and why it was made, from its name (2026-10-29_21-04-11_auto.zip; a second one in the same second ends in -2)
    static func describe(_ zip: URL) -> (date: Date?, label: String, tag: String) {
        let name = zip.deletingPathExtension().lastPathComponent
        let date = stamp.date(from: String(name.prefix(19)))
        var tag = name.count > 20 && name.dropFirst(19).first == "_" ? String(name.dropFirst(20)) : ""
        if let r = tag.range(of: #"-\d+$"#, options: .regularExpression) { tag.removeSubrange(r) }
        switch tag {
        case "auto": return (date, L("Before playing"), tag)
        case "game": return (date, L("When the game saved"), tag)
        case "before-import": return (date, L("Before it was replaced"), tag)
        case "": return (date, L("Backup"), tag)
        default: return (date, tag, tag)
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

    /// Replaces the save with the contents of a folder (and the device save, when given), after a backup of the current one. The game must be closed.
    /// The restored save then counts as the newest one for nxnative's cloud sync: its files are dated now and the record of the last sync is gone, so its next
    /// start sends it instead of taking the cloud's copy (dm/host/save_sync.c: with no record, the newer side wins)
    static func replace(_ s: SaveSlot, with source: URL, device: URL? = nil) async throws {
        let now = slot(s.titleID, s.name, s.folder)   // what is on disk now, not what a page showed earlier
        if now.exists || Paths.isDirectory(s.device) { try await backup(s, label: "before-import", pictureFromLast: true) }
        try fill(s.folder, from: source)
        touch(s.folder)
        if let device { try fill(s.device, from: device); touch(s.device) }
        try? FileManager.default.removeItem(at: s.syncBase)
    }

    private static func fill(_ dst: URL, from src: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for c in (try? fm.contentsOfDirectory(at: dst, includingPropertiesForKeys: nil)) ?? [] { try fm.removeItem(at: c) }
        for c in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) where !skipped(c.lastPathComponent) {
            try fm.copyItem(at: c, to: dst.appendingPathComponent(c.lastPathComponent))
        }
    }
    /// What a zip or Finder adds that is not part of a save (a save's own hidden files, such as nxnative's .dm-case-N, are kept)
    private static func skipped(_ name: String) -> Bool { name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._") || name == layoutMarker }
    private static func touch(_ dir: URL) {
        let fm = FileManager.default, now = Date()
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) { for case let u as URL in e { try? fm.setAttributes([.modificationDate: now], ofItemAtPath: u.path) } }
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: dir.path)
    }

    /// Restores a backup: NX Hub's own (save/ and save_device/ beside its marker, or, from before, the save's files at the top) or any zip of a save
    static func restore(_ s: SaveSlot, from zip: URL) async throws {
        let (dir, temp) = try await unpack(zip)
        defer { if temp { try? FileManager.default.removeItem(at: dir) } }
        if Paths.exists(dir.appendingPathComponent(layoutMarker)) {
            let dev = dir.appendingPathComponent("save_device", isDirectory: true)
            try await replace(s, with: dir.appendingPathComponent("save", isDirectory: true), device: Paths.isDirectory(dev) ? dev : nil)
        } else {
            try await replace(s, with: dir)
        }
    }

    enum SaveError: LocalizedError {
        case tool(String)
        var errorDescription: String? { switch self { case .tool(let m): return m } }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
