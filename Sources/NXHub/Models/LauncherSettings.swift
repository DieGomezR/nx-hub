import Foundation

/// A Mac app's settings list, Contents/Resources/dm/launcher.json (nxnative docs/frontends.md, The settings list; schema docs/launcher.schema.json).
/// Schema 1 grows only by optional fields: unknown fields are ignored, an unknown kind is not drawn.
struct SettingsList: Decodable {
    let schema: Int?
    let game: String
    let settings: [Setting]

    static func load(_ url: URL) -> SettingsList? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SettingsList.self, from: d)
    }

    /// Sections in the order of their first rows
    var sections: [String] {
        var out: [String] = []
        for s in settings where !out.contains(s.section) { out.append(s.section) }
        return out
    }
}

struct Setting: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable { case choice, range, toggle, unknown
        init(from decoder: Decoder) throws { self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
    }
    struct Base: Decodable, Hashable { let docked: [Int]; let handheld: [Int] }

    var id: String { env }
    let env: String
    let kind: Kind
    let section: String
    let label: String
    let note: String
    let `default`: String
    let options: [[String]]?
    let min: Double?
    let max: Double?
    let step: Double?
    let on: String?
    let off: String?
    let level: String?
    let needs: String?
    let base: Base?

    struct Choice: Hashable { let value: String; let label: String }

    var isBasic: Bool { level == "basic" }
    var choices: [Choice] { (options ?? []).compactMap { $0.count >= 2 ? Choice(value: $0[0], label: $0[1]) : nil } }
    /// needs "DM_RUMBLE=1": (DM_RUMBLE, 1)
    var dependency: (env: String, value: String)? {
        guard let n = needs, let eq = n.firstIndex(of: "=") else { return nil }
        return (String(n[..<eq]), String(n[n.index(after: eq)...]))
    }

    /// Whether a value is one this build accepts (as dm/mac/launcher.c checks a saved choice)
    func accepts(_ v: String) -> Bool {
        switch kind {
        case .choice: return choices.contains { $0.value == v }
        case .toggle: return v == on || v == off
        case .range: guard let x = Double(v), let lo = min, let hi = max else { return false }; return x >= lo - 1e-9 && x <= hi + 1e-9
        case .unknown: return false
        }
    }
    func same(_ a: String, _ b: String) -> Bool {
        if kind == .range, let x = Double(a), let y = Double(b) { return abs(x - y) < 1e-9 }
        return a == b
    }
    /// A range value as a string: as few decimals as the step needs ("0.75", "1.0")
    func format(_ x: Double) -> String {
        let s = step ?? 0.05
        var decimals = 1
        var t = s
        while decimals < 4 && abs(t.rounded() - t) > 1e-9 { t *= 10; decimals += 1 }
        let snapped = (x / s).rounded() * s
        var str = String(format: "%.\(decimals)f", snapped)
        while str.hasSuffix("0") && !str.hasSuffix(".0") { str.removeLast() }
        return str
    }
}

/// The player's saved choices, kept where a Mac app's launcher reads them: launcher.<VAR> strings in the app's preferences domain (its bundle ID).
/// Only choices that differ from the tested default are kept (docs/frontends.md, Saved choices)
struct SavedChoices {
    let domain: String

    func value(_ env: String) -> String? {
        CFPreferencesCopyAppValue(("launcher." + env) as CFString, domain as CFString) as? String
    }
    func set(_ env: String, _ value: String?) {
        CFPreferencesSetAppValue(("launcher." + env) as CFString, value.map { $0 as CFString }, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
    func resetAll(_ list: SettingsList) {
        for s in list.settings { CFPreferencesSetAppValue(("launcher." + s.env) as CFString, nil, domain as CFString) }
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// KEY=VALUE lines of an env.txt (the player's in Application Support, or the app's own): these win over saved choices, so the settings they set are shown fixed
enum EnvFile {
    static func read(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, out[k] == nil { out[k] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
}

/// One game's settings as its next start will take them
struct GameSettings {
    let list: SettingsList
    let saved: SavedChoices
    let fixed: [String: (value: String, source: String)]   // set by an env.txt: the value and which file

    init?(app: AppBundle) {
        guard let l = SettingsList.load(app.settingsList) else { return nil }
        list = l
        saved = SavedChoices(domain: app.bundleID)
        var f: [String: (value: String, source: String)] = [:]
        for (k, v) in EnvFile.read(app.bundledEnv) { f[k] = (value: v, source: L("the app's env.txt")) }
        for (k, v) in EnvFile.read(Paths.playerEnv(app.titleID)) { f[k] = (value: v, source: L("your env.txt")) }   // the player's file wins
        fixed = f
    }

    func current(_ s: Setting) -> String {
        if let f = fixed[s.env] { return f.value }
        if let v = saved.value(s.env), s.accepts(v) { return v }
        return s.default
    }
    func isChanged(_ s: Setting) -> Bool { fixed[s.env] == nil && !s.same(current(s), s.default) }
    func set(_ s: Setting, _ v: String) { saved.set(s.env, s.same(v, s.default) ? nil : v) }
    /// Whether a row is drawn: a sub-setting only while the row it depends on has its value
    func visible(_ s: Setting) -> Bool {
        guard let d = s.dependency, let parent = list.settings.first(where: { $0.env == d.env }) else { return true }
        return current(parent) == d.value
    }
}
