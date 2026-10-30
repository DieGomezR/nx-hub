import Foundation

/// nxnative's cloud saves (nxnative docs/frontends.md, The cloud saves folder; docs/settings.md, Cloud saves): a Mac app syncs its committed save through
/// <folder>/<title ID>/save.dmsync. The folder is the cloudSaves.folder string in the app's preferences domain, which its launcher reads at every start,
/// with or without its window, and passes to the host as DM_SAVE_SYNC. NX Hub writes the same folder into every game's app, as a front end may
enum CloudSaves {
    static let key = "cloudSaves.folder"
    /// iCloud Drive on this Mac (missing while iCloud Drive is off)
    static let iCloudDrive = Paths.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static var iCloudDriveOn: Bool { Paths.isDirectory(iCloudDrive) }
    /// The folder nxnative's own "icloud" value names: iCloud Drive › nxnative Saves
    static var defaultFolder: URL { iCloudDrive.appendingPathComponent("nxnative Saves", isDirectory: true) }

    /// The key as the app keeps it: nil when never set, "" when turned off in the game's own window
    static func rawFolder(of app: AppBundle) -> String? { CFPreferencesCopyAppValue(key as CFString, app.bundleID as CFString) as? String }

    /// The folder an app syncs through, as its launcher will read it ("" when off; "icloud" is iCloud Drive › nxnative Saves, as the host takes it)
    static func folder(of app: AppBundle) -> String {
        let v = rawFolder(of: app) ?? ""
        return v == "icloud" ? defaultFolder.path : v
    }

    /// The folder the game's next start syncs through, in the launcher's order (dm/mac/launcher.c): DM_SAVE_SYNC from the launch options NX Hub adds,
    /// the player's env.txt or the app's own, then the key; "0" is off
    static func effectiveFolder(of app: AppBundle, launchEnv: [String: String]) -> String {
        let v = launchEnv["DM_SAVE_SYNC"] ?? EnvFile.read(Paths.playerEnv(app.titleID))["DM_SAVE_SYNC"] ?? EnvFile.read(app.bundledEnv)["DM_SAVE_SYNC"] ?? folder(of: app)
        if v == "0" { return "" }
        return v == "icloud" ? defaultFolder.path : v
    }

    /// Whether a folder lies in iCloud Drive while iCloud Drive is off (nxnative would then sync into a plain folder that goes nowhere)
    static func unreachable(_ folder: String) -> Bool { Paths.expand(folder).path.hasPrefix(iCloudDrive.path) && !iCloudDriveOn }

    /// Writes the folder into the app's preferences, or removes the key ("" or nil): its next start takes it
    static func set(_ folder: String?, for app: AppBundle) {
        let v = (folder?.isEmpty == false) ? folder : nil
        CFPreferencesSetAppValue(key as CFString, v.map { $0 as CFString }, app.bundleID as CFString)
        CFPreferencesAppSynchronize(app.bundleID as CFString)
    }

    nonisolated(unsafe) private static var supportCache: [String: (Date?, Bool)] = [:]
    /// Whether the app's launcher reads the key: apps nxnative built since its cloud saves (October 2026) name it in their launcher
    static func supported(_ app: AppBundle) -> Bool {
        let exe = Bundle(url: app.url)?.executableURL ?? app.url.appendingPathComponent("Contents/MacOS/nxnative")
        let m = Paths.modified(exe)
        if let c = supportCache[exe.path], c.0 == m { return c.1 }
        let ok = (try? Data(contentsOf: exe, options: .alwaysMapped)).map { $0.range(of: Data(key.utf8)) != nil } ?? false
        supportCache[exe.path] = (m, ok)
        return ok
    }

    /// The game's file in the folder (a folder named after the title ID is taken as the game's own, as the host does)
    static func file(_ titleID: String, in folder: String) -> URL? {
        guard !folder.isEmpty else { return nil }
        let dir = Paths.expand(folder == "icloud" ? defaultFolder.path : folder)
        if dir.lastPathComponent.uppercased() == titleID.uppercased() { return dir.appendingPathComponent("save.dmsync") }
        return dir.appendingPathComponent(titleID.uppercased(), isDirectory: true).appendingPathComponent("save.dmsync")
    }

    /// When the save last went to the folder or came into it from another device (the file's date), nil before the first sync
    static func lastSync(_ titleID: String, in folder: String) -> Date? { file(titleID, in: folder).flatMap(Paths.modified) }

    /// The copies of saves a sync replaced, which nxnative keeps beside the save (<save>-backups/<date> local|cloud)
    static func hostBackups(_ saveFolder: URL) -> URL { URL(fileURLWithPath: saveFolder.path + "-backups", isDirectory: true) }

    /// Makes the folder (iCloud Drive › nxnative Saves) so the apps find it; false when it cannot be made (iCloud Drive off, no access)
    @discardableResult
    static func prepare(_ folder: String) -> Bool {
        let u = Paths.expand(folder)
        if Paths.isDirectory(u) { return true }
        return (try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: u.path.hasPrefix(iCloudDrive.path) ? false : true)) != nil
    }
}
