import SwiftUI
import AppKit

/// Development only (NX Hub.app beside a .dev folder): .dev/snap-request holds "<n> <page> [width height]"; NX Hub writes .dev/snap-<n>.png.
/// <page> is window (the window as it is), home, catalog, saves, mods, cheats, controllers, nxnative or game:<title ID> (that page rendered on its own)
@MainActor
enum DevSnapshot {
    private static var timer: Timer?
    private static var last = ""
    /// "mods:explore", "settings:interface": the tab or section a page opens on for the next capture
    static var tab: String?

    static func start(model: AppModel) {
        let dev = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".dev")
        guard Paths.isDirectory(dev), timer == nil else { return }
        let req = dev.appendingPathComponent("snap-request")
        last = (try? String(contentsOf: req, encoding: .utf8)) ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard let r = try? String(contentsOf: req, encoding: .utf8), r != last else { return }
                last = r
                let parts = r.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
                guard parts.count >= 2 else { return }
                let w = parts.count > 3 ? Double(parts[2]) ?? 1320 : 1320, h = parts.count > 3 ? Double(parts[3]) ?? 840 : 840
                if parts[1] == "home-index", parts.count > 2, let i = Int(parts[2]) { model.homeIndex = i; return }
                // A game session driven from a shell: play <title ID>, home (as the controller's Home button), shot, resume, close
                switch parts[1] {
                case "play":
                    if parts.count > 2, let g = model.games.first(where: { $0.titleID == parts[2].uppercased() }) { DevLog.write("dev: play \(g.titleID)"); await model.play(g) }
                    return
                case "home": DevLog.write("dev: home"); await model.homePressed(); return
                case "shot": let ok = await model.session?.shoot() ?? false; DevLog.write("dev: shot \(ok)"); return
                case "resume": DevLog.write("dev: resume"); model.resumeGame(); return
                case "close": DevLog.write("dev: close"); await model.closeGame(); return
                case "state":
                    let s = model.session
                    DevLog.write("dev: state active \(NSApp.isActive) front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") session \(s?.game.titleID ?? "-") host \(s?.hostPID ?? 0) launcher \(s?.launcherPID ?? 0) suspended \(s?.suspended ?? false) paused \(s?.paused ?? false) stopped \(s.map { Proc.stopped($0.hostPID) } ?? false) page \(model.page)")
                    return
                default: break
                }
                let out = dev.appendingPathComponent("snap-\(parts[0]).png")
                var png: Data?
                if parts[1] == "window" {
                    // "window <page>": the real window, moved to that page for the capture and back
                    let before = model.page
                    if parts.count > 2 { model.page = page(parts[2], model); try? await Task.sleep(for: .seconds(1.2)) }
                    png = window()
                    if parts.count > 2 { model.page = before }
                } else {
                    png = render(page(parts[1], model), model: model, size: CGSize(width: w, height: h))
                }
                if let png { try? png.write(to: out) }
                DevLog.write("snapshot \(parts[1]) → \(out.lastPathComponent) \(png?.count ?? 0) bytes")
            }
        }
    }

    private static func page(_ s: String, _ model: AppModel) -> Page {
        if let colon = s.firstIndex(of: ":"), !s.hasPrefix("game:") {
            tab = String(s[s.index(after: colon)...])
            return page(String(s[..<colon]), model)
        }
        switch s {
        case "catalog": return .catalog
        case "library": return .library
        case "settings": return .settings
        case "saves": return .saves
        case "mods": return .mods(model.selectedGame?.titleID)
        case "cheats": return .cheats(nil)
        case "controllers": return .controllers
        case "nxnative": return .nxnative
        default:
            if s.hasPrefix("game:") { return .game(String(s.dropFirst(5)).uppercased()) }
            return .home
        }
    }

    private static func render(_ p: Page, model: AppModel, size: CGSize) -> Data? {
        let view = PageView(page: p)
            .environment(model)
            .environment(\.colorScheme, .dark)
            .groupBoxStyle(CardGroupBoxStyle())
            .foregroundStyle(Theme.text)
            .frame(width: size.width, height: size.height)
            .background(Theme.bg)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The window's content as AppKit draws it (controls included; blur and materials come out flat)
    private static func window() -> Data? {
        guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 500 })?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
