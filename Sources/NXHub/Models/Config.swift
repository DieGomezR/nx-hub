import Foundation
import Observation

/// NX Hub's own settings (its preferences domain)
@Observable
final class Config {
    private let d = UserDefaults.standard

    var libraryFolders: [String] { didSet { d.set(libraryFolders, forKey: "libraryFolders") } }
    /// The nxnative checkout that builds the games (a clone or a worktree of github.com/seedds/nxnative)
    var nxnativePath: String { didSet { d.set(nxnativePath, forKey: "nxnativePath") } }
    /// The Python that runs nxnative's NSP script (3.12+, with its packages)
    var pythonPath: String { didSet { d.set(pythonPath, forKey: "pythonPath") } }
    var keysPath: String { didSet { d.set(keysPath, forKey: "keysPath") } }
    var allowOtherMetal: Bool { didSet { d.set(allowOtherMetal, forKey: "allowOtherMetal") } }
    var allowShaderRegressions: Bool { didSet { d.set(allowShaderRegressions, forKey: "allowShaderRegressions") } }
    var checkAtLaunch: Bool { didSet { d.set(checkAtLaunch, forKey: "checkAtLaunch") } }
    /// Games built from another checkout than nxnativePath (a game whose profile is still in a pull request): title ID → path
    var sourceOverrides: [String: String] { didSet { d.set(sourceOverrides, forKey: "sourceOverrides") } }
    /// What NX Hub built each game with, for apps that do not say it themselves (no DMCommit): title ID → [commit, chain, ISO date]
    var buildRecords: [String: [String]] { didSet { d.set(buildRecords, forKey: "buildRecords") } }
    /// Environment switches NX Hub adds when it starts a game (KEY=VALUE lines): title ID → text. They win over the game's settings for those starts
    var launchEnv: [String: String] { didSet { d.set(launchEnv, forKey: "launchEnv") } }
    /// The mods turned on per game, in priority order: title ID → mod folder names
    var enabledMods: [String: [String]] { didSet { d.set(enabledMods, forKey: "enabledMods") } }
    /// The cheats turned on per game: title ID → cheat names
    var enabledCheats: [String: [String]] { didSet { d.set(enabledCheats, forKey: "enabledCheats") } }
    /// Settings chosen for every game at once (Settings › All games): env → value
    var globalSettings: [String: String] { didSet { d.set(globalSettings, forKey: "globalSettings") } }
    var padNavigation: Bool { didSet { d.set(padNavigation, forKey: "padNavigation") } }
    var showHints: Bool { didSet { d.set(showHints, forKey: "showHints") } }
    var startFullScreen: Bool { didSet { d.set(startFullScreen, forKey: "startFullScreen") } }
    var backupBeforePlay: Bool { didSet { d.set(backupBeforePlay, forKey: "backupBeforePlay") } }
    /// Each game's id on GameBanana (its mods): title ID → id
    var gbGameIDs: [String: Int] { didSet { d.set(gbGameIDs, forKey: "gbGameIDs") } }
    var gbGameNames: [String: String] { didSet { d.set(gbGameNames, forKey: "gbGameNames") } }
    /// A picture of the game every so many minutes while it runs from NX Hub, for its save's "where you left off" (0: only when Home is pressed)
    var shotMinutes: Int { didSet { d.set(shotMinutes, forKey: "shotMinutes") } }
    /// The controller's Home button (PS, Xbox) inside a game started from NX Hub brings NX Hub back
    var homeButton: Bool { didSet { d.set(homeButton, forKey: "homeButton") } }
    /// ... with the game paused until you go back to it
    var pauseOnHome: Bool { didSet { d.set(pauseOnHome, forKey: "pauseOnHome") } }
    /// A change to nxnative's shader translation alone is reason to suggest a rebuild (off: only changes to the game's own profile)
    var rebuildForShaders: Bool { didSet { d.set(rebuildForShaders, forKey: "rebuildForShaders") } }
    /// Games kept as they are built: NX Hub does not suggest rebuilding them
    var keptBuilds: [String] { didSet { d.set(keptBuilds, forKey: "keptBuilds") } }
    /// Builds waiting for the night (title IDs), and the hour they start
    var nightQueue: [String] { didSet { d.set(nightQueue, forKey: "nightQueue") } }
    var nightHour: Int { didSet { d.set(nightHour, forKey: "nightHour") } }
    /// The Mac does not go to sleep while a build runs (or while builds wait for the night)
    var awakeWhileBuilding: Bool { didSet { d.set(awakeWhileBuilding, forKey: "awakeWhileBuilding") } }

    init() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        func firstExisting(_ paths: [String]) -> String? { paths.first { fm.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } }

        libraryFolders = d.stringArray(forKey: "libraryFolders") ?? [firstExisting(["~/Games", "~/Downloads"]) ?? "~/Downloads"]
        nxnativePath = d.string(forKey: "nxnativePath")
            ?? ["~/nxnative-main", "~/nxnative", "~/NX2Apple"].first { fm.fileExists(atPath: ($0 as NSString).expandingTildeInPath + "/scripts/build_ipa_from_nsp.py") }
            ?? "~/nxnative"
        pythonPath = d.string(forKey: "pythonPath")
            ?? firstExisting(["~/.nxnative-py/bin/python", "\(home)/.venv/bin/python", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
            ?? "/usr/bin/python3"
        keysPath = d.string(forKey: "keysPath") ?? firstExisting(["~/.switch/prod.keys", "~/Downloads/prod.keys"]) ?? ""
        allowOtherMetal = d.bool(forKey: "allowOtherMetal")
        allowShaderRegressions = d.bool(forKey: "allowShaderRegressions")
        checkAtLaunch = d.object(forKey: "checkAtLaunch") as? Bool ?? true
        sourceOverrides = d.dictionary(forKey: "sourceOverrides") as? [String: String] ?? [:]
        buildRecords = d.dictionary(forKey: "buildRecords") as? [String: [String]] ?? [:]
        launchEnv = d.dictionary(forKey: "launchEnv") as? [String: String] ?? [:]
        enabledMods = d.dictionary(forKey: "enabledMods") as? [String: [String]] ?? [:]
        enabledCheats = d.dictionary(forKey: "enabledCheats") as? [String: [String]] ?? [:]
        globalSettings = d.dictionary(forKey: "globalSettings") as? [String: String] ?? [:]
        padNavigation = d.object(forKey: "padNavigation") as? Bool ?? true
        showHints = d.object(forKey: "showHints") as? Bool ?? true
        startFullScreen = d.bool(forKey: "startFullScreen")
        backupBeforePlay = d.bool(forKey: "backupBeforePlay")
        gbGameIDs = d.dictionary(forKey: "gbGameIDs") as? [String: Int] ?? [:]
        gbGameNames = d.dictionary(forKey: "gbGameNames") as? [String: String] ?? [:]
        shotMinutes = d.object(forKey: "shotMinutes") as? Int ?? 2
        homeButton = d.object(forKey: "homeButton") as? Bool ?? true
        pauseOnHome = d.object(forKey: "pauseOnHome") as? Bool ?? true
        rebuildForShaders = d.object(forKey: "rebuildForShaders") as? Bool ?? true
        keptBuilds = d.stringArray(forKey: "keptBuilds") ?? []
        nightQueue = d.stringArray(forKey: "nightQueue") ?? []
        nightHour = d.object(forKey: "nightHour") as? Int ?? 3
        awakeWhileBuilding = d.object(forKey: "awakeWhileBuilding") as? Bool ?? true
    }

    var libraryURLs: [URL] { libraryFolders.map(Paths.expand) }
    /// A game's launch switches as a dictionary (lines that are not KEY=VALUE are skipped)
    func launchEnvironment(_ titleID: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in (launchEnv[titleID] ?? "").split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { out[k] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
    var nxnativeURL: URL { Paths.expand(nxnativePath) }
    func source(for titleID: String) -> URL { sourceOverrides[titleID].map(Paths.expand) ?? nxnativeURL }

    /// A prod.keys in a library folder, for a first start without one set
    func findKeys(in folders: [URL]) -> String? {
        for f in folders {
            let direct = f.appendingPathComponent("prod.keys")
            if Paths.exists(direct) { return direct.path }
            for sub in (try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let k = sub.appendingPathComponent("prod.keys")
                if Paths.exists(k) { return k.path }
            }
        }
        return nil
    }
}
