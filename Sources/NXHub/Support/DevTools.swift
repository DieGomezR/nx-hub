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
                // A game session driven from a shell: play <title ID> [KEY=VALUE;KEY=VALUE] (extra environment for this start), home (as the controller's Home button),
                // shot, resume, close, ctl <line> (a raw line for the game's control file: a key press such as "A" or "Down~0.5"), gshot <name> (the game's next frame
                // into .dev/<name>.png), build <title ID>, update (the nxnative checkout to origin/main)
                let line = r.trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = parts.count > 2 ? String(line.dropFirst(parts[0].count + parts[1].count + 2)) : ""
                switch parts[1] {
                case "play":
                    if parts.count > 2, let g = model.games.first(where: { $0.titleID == parts[2].uppercased() }) {
                        var env: [String: String] = [:]
                        if parts.count > 3 {
                            for kv in parts[3...].joined(separator: " ").split(separator: ";") {
                                if let eq = kv.firstIndex(of: "=") { env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...]) }
                            }
                        }
                        DevLog.write("dev: play \(g.titleID) \(env)")
                        await model.play(g, extraEnv: env)
                    }
                    return
                case "ctl":
                    let ok = model.session?.ctl.map { GameSession.append(rest, to: $0) } ?? false
                    DevLog.write("dev: ctl '\(rest)' \(ok)")
                    return
                case "gshot":
                    let name = rest.isEmpty ? "game" : rest
                    let ok = model.session?.ctl.map { GameSession.append("shot " + dev.appendingPathComponent(name + ".png").path, to: $0) } ?? false
                    DevLog.write("dev: gshot \(name) \(ok)")
                    return
                case "build":
                    if parts.count > 2, let g = model.games.first(where: { $0.titleID == parts[2].uppercased() }) { DevLog.write("dev: build \(g.titleID)"); model.build(g) }
                    return
                case "pip":      // nxnative's tool packages into the builds' Python (PythonTools), as the failed build's button does
                    guard model.builds.current == nil else { DevLog.write("dev: pip refused: a game is building"); return }
                    let ok = await model.installPythonTools(); DevLog.write("dev: pip \(ok)"); return
                case "update":   // the nxnative checkout to origin/main (fetch, then as the Updates page's Update does)
                    guard model.builds.current == nil else { DevLog.write("dev: update refused: a game is building"); return }
                    await model.repo.fetch(); let ok = await model.repo.update(); await model.computeChanges()
                    DevLog.write("dev: update \(ok) \(model.repo.shortHead) \(model.repo.error ?? "")"); return
                case "keep":     // keep <title>: the checkout's edits as a change of our own (as the Updates page's Keep as My Own Change)
                    guard model.builds.current == nil else { DevLog.write("dev: keep refused: a game is building"); return }
                    let ok = await model.repo.keepEdits(title: rest); await model.computeChanges()
                    DevLog.write("dev: keep \(ok) \(model.repo.shortHead) \(model.repo.error ?? "")"); return
                case "am":       // am <patch file>: a change of our own from its pull request's patch, on top of the checkout
                    guard model.builds.current == nil else { DevLog.write("dev: am refused: a game is building"); return }
                    let ok = await model.repo.apply(patch: URL(fileURLWithPath: (rest as NSString).expandingTildeInPath)); await model.computeChanges()
                    DevLog.write("dev: am \(ok) \(model.repo.shortHead) \(model.repo.error ?? "")"); return
                case "drop":     // drop <hash>: one of our own changes out
                    guard model.builds.current == nil, let c = model.repo.localCommits.first(where: { $0.hash.hasPrefix(rest) || $0.short == rest }) else { DevLog.write("dev: drop: nothing done"); return }
                    let ok = await model.repo.drop(c); await model.computeChanges()
                    DevLog.write("dev: drop \(ok) \(model.repo.shortHead) \(model.repo.error ?? "")"); return
                case "home": DevLog.write("dev: home"); await model.homePressed(); return
                case "shot": let ok = await model.session?.shoot() ?? false; DevLog.write("dev: shot \(ok)"); return
                case "resume": DevLog.write("dev: resume"); model.resumeGame(); return
                case "close": DevLog.write("dev: close"); await model.closeGame(); return
                case "source":   // source <title ID> [checkout]: the checkout a game builds from (without one, the main checkout again)
                    guard parts.count > 2 else { return }
                    let id = parts[2].uppercased(), path = parts.count > 3 ? parts[3...].joined(separator: " ") : ""
                    if path.isEmpty { model.config.sourceOverrides[id] = nil }
                    else if NXNativeRepo.isCheckout(Paths.expand(path)) { model.config.sourceOverrides[id] = Paths.expand(path).path }
                    DevLog.write("dev: source \(id) → \(model.config.source(for: id).path)"); return
                case "state":
                    let s = model.session
                    DevLog.write("dev: state active \(NSApp.isActive) front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") session \(s?.game.titleID ?? "-") host \(s?.hostPID ?? 0) launcher \(s?.launcherPID ?? 0) suspended \(s?.suspended ?? false) paused \(s?.paused ?? false) stopped \(s.map { Proc.stopped($0.hostPID) } ?? false) page \(model.page) macos \(ProcessInfo.processInfo.operatingSystemVersionString) checkout \(model.config.nxnativeURL.path) overrides \(model.config.sourceOverrides) builds \(model.builds.jobs.filter(\.isActive).map(\.titleID))")
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

/// Development only: when the main thread stops answering for 8 s, macOS's `sample` records where it is, once per hang, into .dev/hang-<time>.txt
/// (a window that froze leaves no other trace: its timers and logs stop with it)
enum HangWatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pong = Date()
    nonisolated(unsafe) private static var activeAtPong = false
    nonisolated(unsafe) private static var started = false

    static func start() {
        let dev = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".dev")
        guard Paths.isDirectory(dev) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        Thread.detachNewThread {
            var sampled = false, samples = 0
            while samples < 3 {
                DispatchQueue.main.async { let a = MainActor.assumeIsolated { NSApp.isActive }; lock.lock(); pong = Date(); activeAtPong = a; lock.unlock() }
                Thread.sleep(forTimeInterval: 2)
                lock.lock(); let quiet = Date().timeIntervalSince(pong), active = activeAtPong; lock.unlock()
                // In the background macOS naps the app (App Nap, sleep), and the main thread answers late without being stuck: only a window in use counts
                if quiet < 8 || !active { sampled = false; continue }
                if sampled { continue }
                sampled = true; samples += 1
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let out = dev.appendingPathComponent("hang-\(stamp).txt")
                DevLog.write("hang: the main thread has not answered for \(Int(quiet)) s; sampling into \(out.lastPathComponent)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(getpid())", "3", "-file", out.path]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
        }
    }
}
