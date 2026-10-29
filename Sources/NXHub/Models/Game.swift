import Foundation

/// A game of the library: its folder (the NSPs nxnative builds from, its <title ID>_build work folder) and the Mac app built from it
struct Game: Identifiable, Hashable {
    var id: String { titleID }
    let titleID: String              // the base game's title ID, 16 upper-case hex digits
    var name: String
    var version: String?             // the display version (the app's, else the newest extraction's)
    var folder: URL?                 // the folder with the NSPs and the build folder
    var app: AppBundle?              // the nxnative Mac app (--platform mac-app)
    var buildDir: URL?               // <title ID>_build
    var packages: [URL] = []         // NSP / NSZ / XCI / XCZ of this game (base, update, DLC)
    var extractIcon: URL?            // icon.jpg of the newest extraction, for a game without an app

    enum Kind { case app, devBuild, notBuilt }
    var kind: Kind { app != nil ? .app : buildDir != nil ? .devBuild : .notBuilt }
    var canBuild: Bool { folder != nil && !packages.isEmpty }
    var bundleID: String { app?.bundleID ?? "org.nxnative.\(titleID.lowercased())" }
}

/// What a Mac app nxnative packed says about itself (dm/mac/pack_app.py writes its Info.plist)
struct AppBundle: Hashable {
    let url: URL
    let name: String
    let titleID: String
    let bundleID: String
    let version: String?
    let commit: String?              // DMCommit: the nxnative checkout that packed it (newer apps); "+dirty" with local changes
    let chain: String?               // the shader translation chain of its libraries (DMChain, or Resources/msl/b-<chain>)
    let builtAt: Date?

    var settingsList: URL { url.appendingPathComponent("Contents/Resources/dm/launcher.json") }
    var bundledEnv: URL { url.appendingPathComponent("Contents/Resources/dm/env.txt") }
    /// The commit without the +dirty mark
    var cleanCommit: String? { commit.map { $0.replacingOccurrences(of: "+dirty", with: "") }.flatMap { $0.isEmpty ? nil : $0 } }

    init?(url: URL) {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tid = info["DMTitleID"] as? String, tid.count == 16 else { return nil }
        self.url = url
        titleID = tid.uppercased()
        name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        bundleID = (info["CFBundleIdentifier"] as? String) ?? "org.nxnative.\(tid.lowercased())"
        version = info["CFBundleShortVersionString"] as? String
        commit = info["DMCommit"] as? String
        var ch = info["DMChain"] as? String
        if ch == nil, let libs = try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Resources/msl").path) {
            ch = libs.first { $0.hasPrefix("b-") }.map { String($0.dropFirst(2)) }
        }
        chain = ch
        builtAt = Paths.modified(plist)
    }
}

enum TitleID {
    /// The base game's ID of an update (…800) or a DLC (…+0x1000 + n): the ID with its low 13 bits cleared
    static func base(_ tid: String) -> String? {
        guard tid.count == 16, let v = UInt64(tid, radix: 16) else { return nil }
        return String(format: "%016llX", v & ~UInt64(0x1FFF))
    }
    /// The [0100XXXXXXXXXXXX] in a package's file name
    static func inName(_ name: String) -> String? {
        guard let r = name.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return nil }
        return String(name[r].dropFirst().dropLast()).uppercased()
    }
    /// A package's file name without its brackets and extension: "Super Mario Party Jamboree"
    static func cleanName(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension
        while let r = s.range(of: #"\s*\[[^\]]*\]"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
