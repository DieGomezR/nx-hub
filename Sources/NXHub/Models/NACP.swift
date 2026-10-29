import Foundation
import Compression

/// The game's control data (control.nacp, which nxnative's extraction keeps in <id>_build/extract/<version>/): its name and display version,
/// for a game that has no Mac app yet. Layout as nxnative's dm/tools/nacp.py reads it.
struct NACP {
    let names: [String]      // per language, in the NACP's order (0 American English, 5 Latin American Spanish, 6 Spanish, …); "" when empty
    let displayVersion: String

    init?(url: URL) {
        guard let b = try? Data(contentsOf: url), b.count >= 0x3070 else { return nil }
        var titles = Data(b.prefix(0x3000))
        // Newer SDKs compress the title area: a u16 size, then raw deflate inflating to 32 languages × 0x300
        let size = Int(b[0]) | Int(b[1]) << 8
        if size > 0, size + 2 <= b.count, let z = NACP.inflate(b.subdata(in: 2..<(2 + size)), max: 0x6000), z.count == 0x6000 { titles = z }
        var n: [String] = []
        var i = 0
        while (i + 1) * 0x300 <= titles.count {
            let raw = titles.subdata(in: (i * 0x300)..<(i * 0x300 + 0x200))
            let cut = raw.firstIndex(of: 0).map { raw[raw.startIndex..<$0] } ?? raw[...]
            n.append(String(data: Data(cut), encoding: .utf8) ?? "")
            i += 1
        }
        names = n
        let v = b.subdata(in: 0x3060..<0x3070)
        let vcut = v.firstIndex(of: 0).map { v[v.startIndex..<$0] } ?? v[...]
        displayVersion = String(data: Data(vcut), encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The name in the Mac's language when the game has one, else the first one it has
    var name: String? {
        let lang = Locale.preferredLanguages.first ?? "en"
        let order: [Int] = lang.hasPrefix("es") ? (lang == "es-ES" ? [6, 5, 0] : [5, 6, 0])
            : lang.hasPrefix("fr") ? [3, 9, 0] : lang.hasPrefix("pt") ? [15, 10, 0] : lang.hasPrefix("ja") ? [2, 0] : [0, 1]
        for i in order where i < names.count && !names[i].isEmpty { return names[i] }
        return names.first { !$0.isEmpty }
    }

    static func inflate(_ data: Data, max: Int) -> Data? {
        var out = Data(count: max + 1)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, max + 1, s, data.count, nil, COMPRESSION_ZLIB)   // COMPRESSION_ZLIB is raw deflate
            }
        }
        return n > 0 ? out.prefix(n) : nil
    }
}
