import Foundation
import AppKit
import GameController
import Observation

/// The running game's process, reached as a debugger reaches it (task_for_pid: NX Hub carries the debugger entitlement). Guest addresses are host
/// addresses in nxnative (the game's code runs natively), so the cheat VM reads and writes them as they are
final class GameProcess: CheatMemory {
    let pid: pid_t
    private let task: mach_port_t
    private(set) var writeFailures = 0
    private(set) var readFailures = 0

    enum AttachError: Error { case notRunning, denied(kern_return_t) }

    init(pid: pid_t, task: mach_port_t) { self.pid = pid; self.task = task }
    deinit { _ = mach_port_deallocate(mach_task_self_, task) }

    static func attach(pid: pid_t) -> Result<GameProcess, AttachError> {
        var t: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &t)
        return kr == KERN_SUCCESS ? .success(GameProcess(pid: pid, task: t)) : .failure(.denied(kr))
    }

    func read(_ address: UInt64, _ width: Int) -> UInt64? {
        var v: UInt64 = 0
        var got: mach_vm_size_t = 0
        let kr = withUnsafeMutableBytes(of: &v) { buf in
            mach_vm_read_overwrite(task, mach_vm_address_t(address), mach_vm_size_t(width), mach_vm_address_t(UInt(bitPattern: buf.baseAddress)), &got)
        }
        if kr != KERN_SUCCESS { readFailures += 1; return nil }
        return v
    }

    @discardableResult
    func write(_ address: UInt64, _ value: UInt64, _ width: Int) -> Bool {
        var v = value
        let kr = withUnsafeBytes(of: &v) { buf in
            mach_vm_write(task, mach_vm_address_t(address), vm_offset_t(UInt(bitPattern: buf.baseAddress)), mach_msg_type_number_t(width))
        }
        if kr != KERN_SUCCESS { writeFailures += 1 }
        return kr == KERN_SUCCESS
    }

    func pause() { _ = task_suspend(task) }
    func resume() { _ = task_resume(task) }
    var alive: Bool { kill(pid, 0) == 0 }
}

/// Cheats for one game while it runs: its cheat files, the cheats turned on, and the VM ticking 12 times a second against the game's memory
@Observable
@MainActor
final class CheatSession {
    enum Status: Equatable { case idle, waiting, running(Int32), failed(String) }

    var status: Status = .idle
    var titleID: String?
    var ticks = 0
    var writes = 0
    var lastError: String?
    @ObservationIgnored private var process: GameProcess?
    @ObservationIgnored private var program: [CheatVM.Op] = []
    @ObservationIgnored private var vm = CheatVM()
    @ObservationIgnored private var bases = CheatBases()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored weak var pads: ControllerMonitor?

    /// The cheats turned on for a game, master codes first, as one program
    static func program(_ cheats: [CheatEntry], enabled: [String]) -> [UInt32] {
        cheats.filter { $0.master }.flatMap(\.words) + cheats.filter { !$0.master && enabled.contains($0.name) }.flatMap(\.words)
    }

    func start(game: Game, cheats: [CheatEntry], enabled: [String]) async {
        stop()
        titleID = game.titleID
        do { program = try CheatVM.decode(CheatSession.program(cheats, enabled: enabled)) }
        catch { status = .failed(LF("A cheat could not be read: %@", "\(error)")); return }
        guard !program.isEmpty else { status = .failed(L("No cheats are turned on.")); return }
        status = .waiting
        guard let pid = await CheatSession.hostPID(game) else { status = .failed(L("The game is not running.")); return }
        guard let b = CheatSession.bases(game.titleID) else { status = .failed(L("The game's log does not say where its memory is yet: wait until it has started.")); return }
        bases = b
        switch GameProcess.attach(pid: pid) {
        case .failure(.denied(let kr)): status = .failed(LF("macOS did not let NX Hub reach the game (error %lld).", Int(kr))); return
        case .failure(.notRunning): status = .failed(L("The game is not running.")); return
        case .success(let p): process = p
        }
        vm = CheatVM()
        pads?.monitorInBackground("cheats", true)
        status = .running(pid)
        DevLog.write("cheats on \(game.titleID): pid \(pid) main \(String(b.main, radix: 16)) heap \(String(b.heap, radix: 16)) \(program.count) ops")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        process = nil
        if case .running = status { status = .idle }
        pads?.monitorInBackground("cheats", false)
    }

    private func tick() {
        guard let p = process else { return }
        guard p.alive else { stop(); status = .idle; return }
        vm.run(program, bases: bases, memory: p, keys: keys())
        ticks += 1
        writes = p.writeFailures
        if p.writeFailures > 0 { lastError = LF("%lld writes failed (code cheats need writable memory)", p.writeFailures) }
    }

    /// The buttons held on any controller, as Atmosphère's key bits (A 0, B 1, X 2, Y 3, sticks 4–5, L R ZL ZR 6–9, + − 10–11, D-pad 12–15, stick directions 16–23)
    private func keys() -> UInt64 {
        var k: UInt64 = 0
        let bits: [String: Int] = ["A": 0, "B": 1, "X": 2, "Y": 3, "LS": 4, "RS": 5, "L": 6, "R": 7, "ZL": 8, "ZR": 9, "+": 10, "−": 11, "LEFT": 12, "UP": 13, "RIGHT": 14, "DOWN": 15]
        for pad in pads?.pads ?? [] {
            for b in pad.pressed { if let i = bits[b] { k |= 1 << UInt64(i) } }
            if pad.left.x < -0.5 { k |= 1 << 16 }; if pad.left.y > 0.5 { k |= 1 << 17 }; if pad.left.x > 0.5 { k |= 1 << 18 }; if pad.left.y < -0.5 { k |= 1 << 19 }
            if pad.right.x < -0.5 { k |= 1 << 20 }; if pad.right.y > 0.5 { k |= 1 << 21 }; if pad.right.x > 0.5 { k |= 1 << 22 }; if pad.right.y < -0.5 { k |= 1 << 23 }
        }
        return k
    }

    /// The game's host process: the child dmhost of its app's launcher
    static func hostPID(_ g: Game) async -> pid_t? {
        guard let app = g.app else { return nil }
        let dmhost = app.url.appendingPathComponent("Contents/MacOS/dmhost").path
        return await Shell.pids(matching: Shell.regexEscape(dmhost)).first
    }

    /// The regions' bases the host logs as the game starts: "main: base 0x…" and "guest AS 0x… heap 0x… alias 0x…"
    static func bases(_ titleID: String) -> CheatBases? {
        guard let text = try? String(contentsOf: Paths.gameLog(titleID), encoding: .utf8) else { return nil }
        var b = CheatBases()
        func hex(_ pattern: String) -> UInt64? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            let s = text[r]
            guard let x = s.range(of: #"0x[0-9a-fA-F]+"#, options: [.regularExpression, .backwards]) else { return nil }
            return UInt64(s[x].dropFirst(2), radix: 16)
        }
        guard let main = hex(#"\] main: base 0x[0-9a-fA-F]+"#) else { return nil }
        b.main = main
        b.heap = hex(#"guest AS 0x[0-9a-fA-F]+ \+0x[0-9a-fA-F]+\s+heap 0x[0-9a-fA-F]+"#) ?? 0
        b.alias = hex(#"heap 0x[0-9a-fA-F]+ alias 0x[0-9a-fA-F]+"#) ?? 0
        if let r = text.range(of: #"guest AS 0x[0-9a-fA-F]+"#, options: .regularExpression), let v = UInt64(text[r].dropFirst("guest AS 0x".count), radix: 16) { b.aslr = v }
        return b
    }
}

/// Cheat files per game: Application Support/NX Hub/cheats/<title ID>/<build ID>.txt, as Atmosphère names them (the first 8 bytes of the main module's build ID)
enum CheatStore {
    static let root = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/cheats", isDirectory: true)
    static func folder(_ titleID: String) -> URL { root.appendingPathComponent(titleID, isDirectory: true) }

    static func files(_ titleID: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(titleID), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The main module's build ID the game's profile lists for the app's version (game.tsv build rows: main=<hex>), first 16 hex digits
    static func buildID(_ g: Game, repo: URL) -> String? {
        let tsv = (try? String(contentsOf: repo.appendingPathComponent("dm/games/\(g.titleID)/game.tsv"), encoding: .utf8)) ?? ""
        var rows: [(String, String)] = []
        for line in tsv.split(separator: "\n") where line.hasPrefix("build\t") {
            let f = line.split(separator: "\t").map(String.init)
            if f.count > 2, let m = f.first(where: { $0.hasPrefix("main=") }) { rows.append((f[2], String(m.dropFirst(5).prefix(16)).uppercased())) }
        }
        return (rows.first { $0.0 == g.version } ?? rows.last)?.1
    }

    static func install(_ src: URL, titleID: String, buildID: String?) throws -> URL {
        try FileManager.default.createDirectory(at: folder(titleID), withIntermediateDirectories: true)
        let name = (buildID ?? src.deletingPathExtension().lastPathComponent).uppercased()
        var dest = folder(titleID).appendingPathComponent(name + ".txt")
        if FileManager.default.fileExists(atPath: dest.path) {
            // Several files for one build: keep each, the later ones under their own names
            dest = folder(titleID).appendingPathComponent(src.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    static func cheats(_ titleID: String) -> [CheatFileEntry] {
        files(titleID).map { f in CheatFileEntry(file: f, cheats: CheatFile.parse((try? String(contentsOf: f, encoding: .utf8)) ?? "")) }
    }
}

struct CheatFileEntry: Identifiable {
    let file: URL
    let cheats: [CheatEntry]
    var id: URL { file }
}
