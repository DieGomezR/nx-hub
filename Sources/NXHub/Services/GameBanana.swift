import Foundation

/// GameBanana's public API (gamebanana.com/apiv11), where the Switch modding community shares the mods Atmosphère loads: the game's mods, a mod's files, a file's download
struct GBMod: Identifiable, Hashable {
    let id: Int
    let name: String
    let likes: Int
    let views: Int
    let category: String?
    let thumb: URL?
    let tags: [String]
    let updated: Date?
    var page: URL { URL(string: "https://gamebanana.com/mods/\(id)")! }
}

struct GBFile: Identifiable, Hashable {
    let id: Int
    let name: String
    let size: Int64
    let url: URL
    let note: String
    let downloads: Int
}

enum GameBanana {
    enum Sort: String, CaseIterable, Identifiable {
        case liked = "Generic_MostLiked", downloaded = "Generic_MostDownloaded", newest = "Generic_Newest", updated = "Generic_LatestModified"
        var id: String { rawValue }
        var title: String {
            switch self { case .liked: return L("Most liked"); case .downloaded: return L("Most downloaded"); case .newest: return L("Newest"); case .updated: return L("Recently updated") }
        }
    }

    private static func json(_ url: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.setValue("NX Hub (nxnative launcher)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    struct GBGame: Identifiable, Hashable { let id: Int; let name: String }

    /// GameBanana's games whose name matches, best first
    static func searchGames(_ text: String) async throws -> [GBGame] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let q = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let j = try await json("https://gamebanana.com/apiv11/Util/Search/Results?_sModelName=Game&_sOrder=best_match&_sSearchString=\(q)&_nPage=1")
        return (j["_aRecords"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["_idRow"] as? Int, let n = r["_sName"] as? String else { return nil }
            return GBGame(id: id, name: n)
        }
    }

    /// The game on GameBanana: the search result whose name is the game's, else the first
    static func game(named name: String) async throws -> GBGame? {
        let found = try await searchGames(name)
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return found.first { norm($0.name) == norm(name) } ?? found.first
    }

    static func mods(game: Int, page: Int, sort: Sort) async throws -> (mods: [GBMod], total: Int) {
        let j = try await json("https://gamebanana.com/apiv11/Mod/Index?_nPerpage=30&_nPage=\(page)&_aFilters[Generic_Game]=\(game)&_sSort=\(sort.rawValue)")
        let total = (j["_aMetadata"] as? [String: Any])?["_nRecordCount"] as? Int ?? 0
        let mods = (j["_aRecords"] as? [[String: Any]] ?? []).compactMap { r -> GBMod? in
            guard let id = r["_idRow"] as? Int, let name = r["_sName"] as? String, (r["_bHasFiles"] as? Bool) != false else { return nil }
            var thumb: URL?
            if let img = ((r["_aPreviewMedia"] as? [String: Any])?["_aImages"] as? [[String: Any]])?.first,
               let base = img["_sBaseUrl"] as? String, let file = (img["_sFile530"] as? String) ?? (img["_sFile220"] as? String) ?? (img["_sFile"] as? String) {
                thumb = URL(string: base + "/" + file)
            }
            return GBMod(id: id, name: name, likes: r["_nLikeCount"] as? Int ?? 0, views: r["_nViewCount"] as? Int ?? 0,
                         category: (r["_aRootCategory"] as? [String: Any])?["_sName"] as? String, thumb: thumb,
                         tags: (r["_aTags"] as? [Any] ?? []).compactMap { $0 as? String },
                         updated: (r["_tsDateModified"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        return (mods, total)
    }

    static func files(mod: Int) async throws -> (files: [GBFile], text: String) {
        let j = try await json("https://gamebanana.com/apiv11/Mod/\(mod)?_csvProperties=_aFiles,_sText")
        let files = (j["_aFiles"] as? [[String: Any]] ?? []).compactMap { f -> GBFile? in
            guard let id = f["_idRow"] as? Int, let name = f["_sFile"] as? String, let s = f["_sDownloadUrl"] as? String, let url = URL(string: s) else { return nil }
            if (f["_bIsArchived"] as? Bool) == true { return nil }
            return GBFile(id: id, name: name, size: Int64(f["_nFilesize"] as? Int ?? 0), url: url, note: f["_sDescription"] as? String ?? "", downloads: f["_nDownloadCount"] as? Int ?? 0)
        }
        let text = (j["_sText"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return (files, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Downloads a file into a temporary folder under its own name (its extension tells the unpacker what it is)
    static func download(_ f: GBFile) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: f.url)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxhub-gb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(f.name.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
