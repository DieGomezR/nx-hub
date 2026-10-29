import Foundation

/// Where nxnative and NX Hub keep things (docs/frontends.md in nxnative)
enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    static func expand(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    /// A path for display: the home folder as ~
    static func pretty(_ url: URL) -> String {
        let p = url.path, h = home.path
        return p == h ? "~" : p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    /// A Mac app's saves, temporary files and the player's env.txt
    static func gameSupport(_ titleID: String) -> URL { home.appendingPathComponent("Library/Application Support/nxnative/\(titleID)", isDirectory: true) }
    static func gameSaves(_ titleID: String) -> URL { gameSupport(titleID).appendingPathComponent("save", isDirectory: true) }
    static func playerEnv(_ titleID: String) -> URL { gameSupport(titleID).appendingPathComponent("env.txt") }
    static func gameLog(_ titleID: String) -> URL { home.appendingPathComponent("Library/Logs/nxnative/\(titleID).log") }

    static let hubLogs = home.appendingPathComponent("Library/Logs/NX Hub", isDirectory: true)

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Localized text from the app's Localizable.strings (Spanish and English; the key is the English text)
func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
/// A localized format: the key holds %@ / %lld, as String(format:) takes them
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), locale: Locale.current, arguments: args) }
/// Text from a game's settings list (launcher.json is English): Settings.strings, else as it is
func LS(_ text: String) -> String { Bundle.main.localizedString(forKey: text, value: text, table: "Settings") }

extension Date {
    /// "hace 3 horas" / "3 hours ago"
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        let now = Date()
        // A file written a moment ago can carry a time a hair past now
        return f.localizedString(for: abs(timeIntervalSince(now)) < 30 ? now : self, relativeTo: now)
    }
}

/// A diagnostics log for development: written only when the app runs from its project folder (NX Hub.app beside a .dev folder), to .dev/runtime.log
enum DevLog {
    private static let queue = DispatchQueue(label: "nxhub.devlog")
    nonisolated(unsafe) private static var handle: FileHandle? = {
        let dev = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".dev")
        guard Paths.isDirectory(dev) else { return nil }
        let url = dev.appendingPathComponent("runtime.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        queue.async { if let d = line.data(using: .utf8) { handle?.write(d) } }
    }
}
