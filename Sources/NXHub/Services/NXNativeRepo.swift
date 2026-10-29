import Foundation
import Observation

/// One upstream commit, with what it touches
struct Commit: Identifiable, Hashable {
    let hash: String
    let short: String
    let author: String
    let date: Date
    let subject: String
    let files: [String]
    var id: String { hash }

    /// Title IDs whose profile it changes (dm/games/<title ID>/)
    var games: Set<String> {
        Set(files.compactMap { f -> String? in
            guard f.hasPrefix("dm/games/") else { return nil }
            let rest = f.dropFirst("dm/games/".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let t = String(rest[..<slash])
            return t.count == 16 ? t.uppercased() : nil
        })
    }
    /// It changes the shader translation chain: every NVN game's shaders are built again
    var chain: Bool { files.contains("dm/gfx/nvn/dmsh_chain.h") }
    var host: Bool { files.contains { $0.hasPrefix("dm/host/") || $0.hasPrefix("dm/mac/") || $0.hasPrefix("dm/audio") } }
    var graphics: Bool { files.contains { $0.hasPrefix("dm/gfx/") || $0.hasPrefix("dm/tex/") } }
    var tools: Bool { files.contains { $0.hasPrefix("scripts/") || $0.hasPrefix("dm/tools/") || $0.hasPrefix("dm/games/settings") } }
    /// Changes what a built game runs (not only docs, tests or CI)
    var affectsGames: Bool {
        files.contains { f in
            !(f.hasPrefix("docs/") || f.hasSuffix(".md") || f.hasPrefix(".github/") || f.contains("/tests/") || f.hasPrefix("dm/tools/fuzz/"))
        }
    }
}

/// What changed in nxnative since a game was built
struct GameChanges {
    var known: Bool                 // the build's commit (or date) is known
    var approximate: Bool           // counted from the build's date, not its commit
    var profile: [Commit]           // commits to the game's profile
    var engine: Int                 // other commits that change what games run
    var chainOutdated: Bool         // its shaders are from an older translation chain
    var worthRebuilding: Bool { !profile.isEmpty || chainOutdated }
}

/// The nxnative checkout NX Hub builds with: where it stands against GitHub, and its update
@Observable
@MainActor
final class NXNativeRepo {
    var url: URL
    var valid = false
    var head = ""                  // full hash
    var headDate: Date?
    var branch: String?            // nil: detached (a worktree checked out at origin/main)
    var dirty = false
    var remoteURL = ""
    var upstream = ""              // origin/main's hash
    var incoming: [Commit] = []    // HEAD..origin/main, newest first
    var chain = ""                 // the shader chain of the checked-out tree
    var upstreamChain = ""         // origin/main's
    var lastFetch: Date?
    var busy = false
    var error: String?

    init(url: URL) { self.url = url }

    var shortHead: String { String(head.prefix(8)) }
    var webBase: String? {
        var s = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("git@github.com:") { s = "https://github.com/" + s.dropFirst("git@github.com:".count) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return s.hasPrefix("https://github.com/") ? s : nil
    }
    func commitURL(_ c: Commit) -> URL? { webBase.flatMap { URL(string: "\($0)/commit/\(c.hash)") } }

    static func isCheckout(_ url: URL) -> Bool {
        Paths.exists(url.appendingPathComponent(".git")) && Paths.exists(url.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
    }

    /// Reads the checkout's state (no network)
    func refresh() async {
        valid = NXNativeRepo.isCheckout(url)
        guard valid else { error = L("This folder is not an nxnative checkout."); return }
        error = nil
        let r = await Shell.git(url, ["rev-parse", "HEAD", "origin/main"])
        let lines = r.out.split(separator: "\n").map(String.init)
        head = lines.first ?? ""
        upstream = lines.count > 1 ? lines[1] : ""
        let b = await Shell.git(url, ["symbolic-ref", "--short", "-q", "HEAD"])
        branch = b.ok ? b.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let s = await Shell.git(url, ["status", "--porcelain", "--untracked-files=no"])
        dirty = s.ok && !s.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        remoteURL = (await Shell.git(url, ["remote", "get-url", "origin"])).out
        let d = await Shell.git(url, ["log", "-1", "--format=%ct", "HEAD"])
        headDate = Double(d.out.trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) }
        chain = NXNativeRepo.chain(in: (try? String(contentsOf: url.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h"), encoding: .utf8)) ?? "")
        upstreamChain = NXNativeRepo.chain(in: (await Shell.git(url, ["show", "origin/main:dm/gfx/nvn/dmsh_chain.h"])).out)
        if upstream.isEmpty || upstream == head { incoming = [] } else { incoming = await log(range: "HEAD..origin/main") }
    }

    /// Asks GitHub for new commits (git fetch), then reads the state again
    func fetch() async {
        guard NXNativeRepo.isCheckout(url) else { await refresh(); return }
        busy = true; defer { busy = false }
        let r = await Shell.git(url, ["fetch", "--quiet", "origin"], timeout: 180)
        if r.ok { lastFetch = Date(); error = nil } else { error = LF("Could not reach GitHub: %@", r.message) }
        await refresh()
        if !r.ok { error = LF("Could not reach GitHub: %@", r.message) }
    }

    /// Moves the checkout to origin/main: a detached worktree checks it out, a branch that tracks it fast-forwards. Local changes stop it
    func update() async -> Bool {
        busy = true; defer { busy = false }
        await refresh()
        if dirty { error = L("The checkout has local changes: commit or stash them in Terminal first."); return false }
        let r: ShellResult
        switch branch {
        case nil: r = await Shell.git(url, ["checkout", "--detach", "origin/main"])
        case "main"?: r = await Shell.git(url, ["merge", "--ff-only", "origin/main"])
        case let other?:
            error = LF("The checkout is on branch %@, not main: update it in Terminal.", other); return false
        }
        if !r.ok { error = r.message }
        await refresh()
        return r.ok
    }

    /// Commits of a range (newest first) with the files each changes
    func log(range: String? = nil, since: Date? = nil, paths: [String] = []) async -> [Commit] {
        var args = ["log", "--no-merges", "--name-only", "--format=%x1e%H%x1f%h%x1f%an%x1f%ct%x1f%s"]
        if let since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        args.append(range ?? "origin/main")
        if !paths.isEmpty { args.append("--"); args += paths }
        let r = await Shell.git(url, args, timeout: 60)
        guard r.ok else { return [] }
        return r.out.split(separator: "\u{1e}").compactMap { rec -> Commit? in
            let lines = rec.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let first = lines.first else { return nil }
            let f = first.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return nil }
            return Commit(hash: f[0], short: f[1], author: f[2], date: Date(timeIntervalSince1970: Double(f[3]) ?? 0),
                          subject: f[4...].joined(separator: " "), files: Array(lines.dropFirst()))
        }
    }

    /// What changed upstream since a game's build: from the app's DMCommit or NX Hub's record of it; else, roughly, from the app's date
    func changes(for game: Game, record: [String]?) async -> GameChanges {
        guard valid, !upstream.isEmpty else { return GameChanges(known: false, approximate: false, profile: [], engine: 0, chainOutdated: false) }
        let appChain = game.app?.chain ?? record.flatMap { $0.count > 1 && !$0[1].isEmpty ? $0[1] : nil }
        let chainOutdated = appChain != nil && !upstreamChain.isEmpty && appChain != upstreamChain
        var commits: [Commit] = []
        var known = false, approximate = false
        if let c = game.app?.cleanCommit ?? record?.first, !c.isEmpty, (await Shell.git(url, ["cat-file", "-e", c + "^{commit}"])).ok {
            commits = await log(range: "\(c)..origin/main"); known = true
        } else if let date = game.app?.builtAt {
            commits = await log(since: date); known = true; approximate = true
        }
        let profile = commits.filter { $0.games.contains(game.titleID) }
        let engine = commits.filter { $0.affectsGames && !$0.games.contains(game.titleID) && ($0.host || $0.graphics || $0.chain) }.count
        return GameChanges(known: known, approximate: approximate, profile: profile, engine: engine, chainOutdated: chainOutdated)
    }

    static func chain(in header: String) -> String {
        guard let r = header.range(of: #"DMSH_CHAIN\s+"([0-9a-f]+)""#, options: .regularExpression) else { return "" }
        let s = header[r]
        guard let q1 = s.firstIndex(of: "\"") else { return "" }
        return String(s[s.index(after: q1)...].prefix { $0 != "\"" })
    }
}
