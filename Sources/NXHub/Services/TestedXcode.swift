import Foundation

/// The Xcode whose Metal compiler nxnative tested (dm/gfx/tools/dmsh_chain.lock; nxnative docs/reference/shaders.md, Metal compiler of a newer Xcode).
/// The compiler is the selected Xcode's, and each Xcode downloads its own, so an Xcode update stops every build. Beside the newer Xcode, NX Hub builds
/// with the tested one through DEVELOPER_DIR: the Mac's selected Xcode stays as it is for everything else
enum TestedXcode {
    struct Pick {
        let app: URL
        let version: String
        var developerDir: String { app.appendingPathComponent("Contents/Developer").path }
        var name: String { version.isEmpty ? app.deletingPathExtension().lastPathComponent : "Xcode \(version)" }
    }

    /// The macOS Metal compiler the lock records ("Apple metal version 32023.921 (metalfe-32023.921.6)"), nil without a lock
    static func lockedMetal(_ source: URL) -> String? {
        guard let text = try? String(contentsOf: source.appendingPathComponent("dm/gfx/tools/dmsh_chain.lock"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, parts[0] == "metal_macosx" { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// The Xcode version nxnative names for that compiler ("27.1"), from dm/gfx/tools/own_compilers.py (XCODE_VERSION = '27.1', or XCODE = 'Xcode 27.1 …' before it)
    static func lockedVersion(_ source: URL) -> String? {
        guard let text = try? String(contentsOf: source.appendingPathComponent("dm/gfx/tools/own_compilers.py"), encoding: .utf8) else { return nil }
        for pattern in [#"XCODE_VERSION\s*=\s*'([0-9.]+)'"#, #"XCODE\s*=\s*'Xcode ([0-9.]+)"#] {
            guard let r = text.range(of: pattern, options: .regularExpression) else { continue }
            let s = String(text[r])
            if let v = s.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) { return String(s[v]) }
        }
        return nil
    }

    /// The Xcodes in /Applications and ~/Applications (any name: Xcode.app, Xcode-27.1.app, Xcode_27.1.app), with their versions
    static func installed() -> [(app: URL, version: String)] {
        var out: [(URL, String)] = []
        for dir in [URL(fileURLWithPath: "/Applications"), Paths.home.appendingPathComponent("Applications")] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".app") && name.lowercased().hasPrefix("xcode") {
                let app = dir.appendingPathComponent(name)
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" else { continue }
                out.append((app, info["CFBundleShortVersionString"] as? String ?? ""))
            }
        }
        return out
    }

    /// The first line of `xcrun -sdk macosx metal --version` (with DEVELOPER_DIR when given), nil when that Xcode has no Metal toolchain
    static func metal(developerDir: String?) async -> String? {
        var env = Shell.environment()
        if let developerDir { env["DEVELOPER_DIR"] = developerDir }
        let r = await Shell.run("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"], env: env, timeout: 60)
        guard r.ok else { return nil }
        return r.out.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The Xcode to build with when the selected one's compiler is not the tested one and an installed Xcode has it; nil when nothing is to change
    static func pick(source: URL) async -> Pick? {
        guard let want = lockedMetal(source) else { return nil }
        if await metal(developerDir: nil) == want { return nil }
        let version = lockedVersion(source)
        let all = installed().sorted { a, b in (a.version == version ? 0 : 1, a.app.path) < (b.version == version ? 0 : 1, b.app.path) }   // the named version first
        for x in all {
            let dev = x.app.appendingPathComponent("Contents/Developer").path
            if ProcessInfo.processInfo.environment["DEVELOPER_DIR"] == dev { continue }
            if await metal(developerDir: dev) == want { return Pick(app: x.app, version: x.version) }
        }
        return nil
    }

    /// What to do when a build stopped on another Metal compiler: install the tested Xcode beside the selected one, or download its Metal toolchain
    static func hint(source: URL) -> String? {
        guard let v = lockedVersion(source) else { return nil }
        if let x = installed().first(where: { $0.version == v }) {
            return LF("%@ is at %@, but its Metal toolchain isn't downloaded. In Terminal: DEVELOPER_DIR=%@ xcodebuild -downloadComponent MetalToolchain, then build again.",
                      "Xcode \(v)", Paths.pretty(x.app), x.app.appendingPathComponent("Contents/Developer").path)
        }
        return LF("Install Xcode %@ beside your Xcode (from developer.apple.com/download/all, as /Applications/Xcode-%@.app), open it once and download its Metal toolchain (DEVELOPER_DIR=/Applications/Xcode-%@.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain). NX Hub then builds with it, and your Xcode stays selected for everything else. Or turn on Settings › Build › Build with this Mac's Metal compiler.", v, v, v)
    }
}
