import Foundation

/// A game nxnative has a profile for (dm/games/<title ID>/ in the checkout): its name, the update it is built from, its screenshot in the README gallery
struct CatalogEntry: Identifiable, Hashable {
    let id: String                 // title ID
    let name: String
    let version: String?           // the display version of the update the profile packs (package), e.g. 2.3.0
    let versions: [String]         // every version the profile knows
    let image: URL?                // docs/images/<file> from docs/images/gallery.tsv
    let note: String?              // the gallery's remark ("60 fps with 1.0.1")
    let summary: String?           // the README's first paragraph after its title
    let readme: URL
}

enum Catalog {
    static func load(repo: URL) -> [CatalogEntry] {
        let games = repo.appendingPathComponent("dm/games")
        let gallery = Self.gallery(repo)
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []).filter { $0.count == 16 && UInt64($0, radix: 16) != nil }
        var out: [CatalogEntry] = []
        for tid in ids {
            let dir = games.appendingPathComponent(tid)
            let tsv = (try? String(contentsOf: dir.appendingPathComponent("game.tsv"), encoding: .utf8)) ?? ""
            var name: String?, package: String?
            var builds: [(String, String)] = []   // (vNNN, display)
            for line in tsv.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard let k = f.first else { continue }
                if k == "name", f.count > 1 { name = f[1] }
                else if k == "package", f.count > 1 { package = f[1] }
                else if k == "build", f.count > 2 { builds.append((f[1], f[2])) }
            }
            let readme = dir.appendingPathComponent("README.md")
            let (title, summary) = Self.readme(readme)
            let shown = name ?? title ?? tid
            let version = builds.first { $0.0 == package }?.1 ?? builds.last?.1
            let g = gallery[tid.uppercased()]
            out.append(CatalogEntry(id: tid.uppercased(), name: shown, version: version, versions: builds.map { $0.1 }, image: g?.0, note: g?.1, summary: summary, readme: readme))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// docs/images/gallery.tsv: image, name, note, title ID
    private static func gallery(_ repo: URL) -> [String: (URL, String?)] {
        let dir = repo.appendingPathComponent("docs/images")
        let text = (try? String(contentsOf: dir.appendingPathComponent("gallery.tsv"), encoding: .utf8)) ?? ""
        var out: [String: (URL, String?)] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, f[3].count == 16 else { continue }
            out[f[3].uppercased()] = (dir.appendingPathComponent(f[0]), f[2].isEmpty ? nil : f[2])
        }
        return out
    }

    /// The README's title ("# Name (`TID`)") and its first paragraph, without Markdown marks
    private static func readme(_ url: URL) -> (String?, String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        let lines = text.components(separatedBy: "\n")
        var title: String?
        if let h = lines.first(where: { $0.hasPrefix("# ") }) {
            var t = String(h.dropFirst(2))
            if let r = t.range(of: #"\s*\(`[0-9A-Fa-f]{16}`\)\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
            title = t
        }
        var para: [String] = []
        var started = false
        for l in lines.dropFirst() {
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { if started { break } else { continue } }
            if s.hasPrefix("#") || s.hasPrefix("|") || s.hasPrefix("- ") { if started { break } else { continue } }
            para.append(s); started = true
        }
        var p = para.joined(separator: " ")
        p = p.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        p = p.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
        if p.count > 420 { p = String(p.prefix(420)) + "…" }
        return (title, p.isEmpty ? nil : p)
    }
}
