import AppKit
import Darwin
import IOKit.pwr_mgt
import Observation

/// The pictures of where you left each game: Application Support/NX Hub/shots/<title ID>/last.png, taken while it runs from NX Hub.
/// Each save backup keeps the picture of its moment beside it (<backup>.png)
enum ShotStore {
    static let root = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/shots", isDirectory: true)
    static func folder(_ titleID: String) -> URL { root.appendingPathComponent(titleID, isDirectory: true) }
    static func last(_ titleID: String) -> URL { folder(titleID).appendingPathComponent("last.png") }
    static func forBackup(_ zip: URL) -> URL { zip.deletingPathExtension().appendingPathExtension("png") }

    /// A PNG written to its end: the host writes the file in place, and a PNG ends with its IEND chunk
    static func complete(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end >= 20 else { return false }
        try? h.seek(toOffset: end - 8)
        return (try? h.read(upToCount: 8)) == Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
    }

    nonisolated(unsafe) private static var cache: [String: (Date, NSImage)] = [:]
    /// The picture, read again when its file changes
    static func image(_ u: URL) -> NSImage? {
        guard let m = Paths.modified(u) else { return nil }
        if let c = cache[u.path], c.0 == m { return c.1 }
        guard let img = NSImage(contentsOf: u) else { return nil }
        cache[u.path] = (m, img)
        return img
    }
    static func lastImage(_ titleID: String) -> NSImage? { image(last(titleID)) }
}

/// Processes by their ID (sysctl)
enum Proc {
    private static func info(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
    static func parent(_ pid: pid_t) -> pid_t? { info(pid).map { $0.kp_eproc.e_ppid } }
    /// Stopped by SIGSTOP (SSTOP in sys/proc.h)
    static func stopped(_ pid: pid_t) -> Bool { info(pid).map { $0.kp_proc.p_stat == 4 } ?? false }
    static func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }
}

/// Keeps the Mac from going to sleep on its own while something long runs (the display can still turn off)
final class SleepGuard {
    private var id: IOPMAssertionID = 0
    private(set) var on = false
    func set(_ want: Bool, reason: String) {
        if want == on { return }
        if want {
            on = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(id); on = false
        }
    }
}

/// A game started from NX Hub, while it runs: its control file, the pictures of where you are, and its pause when the controller's Home button
/// brings NX Hub back. nxnative's host reads the lines appended to the file DM_CTL names (dm/host/hle_hid.c, every 100 ms): "shot <path>" saves its next
/// frame as a PNG. The host's window losing focus tells the game it is out of focus (front_mac.m, as the Switch tells a game behind its HOME menu); the pause
/// then stops the host process (SIGSTOP) until it goes on (SIGCONT)
@Observable
@MainActor
final class GameSession {
    let game: Game
    let ctl: URL?                      // nil: a game NX Hub did not start, which has no control file (no pictures)
    var launcherPID: pid_t = 0         // the app's own process (dm/mac/launcher.c): it runs the host as its child, passes SIGTERM on and syncs the save after it
    var hostPID: pid_t = 0             // the host (Contents/MacOS/dmhost): the game itself, with its window
    var suspended = false              // Home brought NX Hub in front of it
    var paused = false                 // ... and the game is stopped meanwhile, at that instant
    var pausedSince: Date?
    var lastShot: Date?
    @ObservationIgnored var onShot: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watch: Timer?
    @ObservationIgnored private var saveWatch: Timer?
    @ObservationIgnored private var saveFolders: [URL] = []   // the save and device save folders
    @ObservationIgnored private var saveMarks: [Int?] = []    // their file numbers
    @ObservationIgnored private var workMark: Int?            // <save>.work's, until the game's first save mount makes a new one
    @ObservationIgnored private var saveArmed = false
    @ObservationIgnored private var burstFrom: Date?          // the first commit of a burst not backed up yet
    @ObservationIgnored private var burstLast: Date?
    @ObservationIgnored private var onFirst: (() -> Void)?
    @ObservationIgnored private var onSaved: (() -> Void)?
    /// When the game last committed its save (nil: not this session)
    @ObservationIgnored var lastCommitAt: Date?
    /// The cloud folder the game's save syncs through this run, as its launcher read it at start ("" for none): Home waits for a send before pausing it
    @ObservationIgnored var syncFolder = ""
    var syncs: Bool { !syncFolder.isEmpty }
    /// Home is waiting for the game's last save to reach the cloud before pausing it
    var sendingSave = false
    /// Home pressed and the pause not landed yet (the cloud wait, the picture): the game counts as held, as a paused one does
    var pausing = false
    /// When NX Hub began following this run (save-sync work older than that is a previous run's leftover)
    let since = Date()
    /// A commit is waiting for the burst to end (the session's end backs it up anyway)
    var savePending: Bool { burstFrom != nil }
    @ObservationIgnored private var shooting = false

    init(game: Game, ctl: URL?) { self.game = game; self.ctl = ctl }

    static func ctlFile(_ titleID: String) -> URL { Paths.home.appendingPathComponent("Library/Application Support/NX Hub/ctl/\(titleID).ctl") }

    /// A new, empty control file before the game starts (the host reads it from its first byte)
    static func freshCtl(_ titleID: String) -> URL? {
        let u = ctlFile(titleID)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: u.path, contents: Data()) ? u : nil
    }

    static func append(_ line: String, to url: URL) -> Bool {
        guard let h = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? h.close() }
        do { _ = try h.seekToEnd(); try h.write(contentsOf: Data((line + "\n").utf8)); return true } catch { return false }
    }

    /// The host (the dmhost under the game's app) and its parent, the launcher
    @discardableResult
    func findProcesses() async -> Bool {
        if Proc.alive(hostPID) { return true }
        guard let pid = await CheatSession.hostPID(game) else { return false }
        hostPID = pid
        if let p = Proc.parent(pid), p > 1 { launcherPID = p }
        return true
    }

    /// The game's processes still run (by the app list while NX Hub has not learnt their IDs: a game opened elsewhere whose launcher window is still up)
    var alive: Bool { hostPID > 0 || launcherPID > 0 ? Proc.alive(hostPID) || Proc.alive(launcherPID) : !runningApps().isEmpty }

    /// A picture every so many minutes while the game is in front
    func startShots(every minutes: Int) {
        timer?.invalidate(); timer = nil
        guard ctl != nil, minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isFrontmost else { return }
                await self.shoot()
            }
        }
    }

    /// Calls back once the game's processes are gone (checked every 2 s: the launcher syncs the save after the host quits, and macOS tells nothing when it ends)
    func watchEnd(_ ended: @escaping () -> Void) {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hostPID > 0 || self.launcherPID > 0, !self.alive else { return }
                ended()
            }
        }
    }

    /// Follows the game's save commits. nxnative's host commits by swapping a new clone in for the save folder (dm/host/hle_fs.c: clonefile, then renamex_np
    /// RENAME_SWAP), so the folder's file number changes with every commit, and with nothing else once the game has mounted its save: before that, a cloud save
    /// can come in the same way, so watching starts when <save>.work is made anew (the mount follows the cloud's), or at once for a game that already ran.
    /// `first` is called at the first commit of a burst, `saved` once the folders have stayed the same for 3 s (games often commit several times in a row;
    /// nxnative's cloud sender waits the same, save_sync.c QUIET_MS), or after a minute of commits. Checked every second (and by Home, pollSaves)
    func watchSaves(_ folders: [URL], alreadyRunning: Bool, first: @escaping () -> Void, saved: @escaping () -> Void) {
        saveWatch?.invalidate()
        saveFolders = folders
        saveMarks = folders.map(Paths.fileNumber)
        workMark = Paths.fileNumber(workFolder)
        saveArmed = alreadyRunning
        burstFrom = nil; burstLast = nil
        onFirst = first; onSaved = saved
        saveWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSaves() }
        }
    }

    private var workFolder: URL { URL(fileURLWithPath: (saveFolders.first?.path ?? "") + ".work") }

    /// One look at the save folders: a new file number is a commit. A stopped game cannot commit, so while it is paused only a burst that ended is backed up
    func pollSaves() {
        guard !saveFolders.isEmpty else { return }
        let now = Date()
        if !paused {
            let marks = saveFolders.map(Paths.fileNumber)
            if !saveArmed {
                let w = Paths.fileNumber(workFolder)
                if w != nil, w != workMark { saveArmed = true; saveMarks = marks }
                return
            }
            if marks != saveMarks {
                saveMarks = marks
                lastCommitAt = now
                if burstFrom == nil { burstFrom = now; onFirst?() }
                burstLast = now
            }
        }
        if let from = burstFrom, let last = burstLast, now.timeIntervalSince(last) >= 3 || now.timeIntervalSince(from) >= 60 {
            burstFrom = nil; burstLast = nil
            onSaved?()
        }
    }

    /// nxnative is syncing the save now, since when: its first save mount fetches the cloud's copy into <save>.sync-tmp, and a send works in
    /// <save>.sync-tmp/out; both remove it however they end (save_sync.c mount_once, send_save). A folder from before this run is a leftover (a killed run)
    var syncBusySince: Date? {
        guard let save = saveFolders.first else { return nil }
        let tmp = URL(fileURLWithPath: save.path + ".sync-tmp"), out = tmp.appendingPathComponent("out")
        if let m = Paths.modified(out), m > since.addingTimeInterval(-2) { return Paths.created(out) ?? m }   // a send
        // the first mount's fetch, until the game has its save (a fetch that came too late can leave the folder behind: not counted after that)
        if !saveArmed, let m = Paths.modified(tmp), m > since.addingTimeInterval(-2) { return Paths.created(tmp) ?? m }
        return nil
    }

    /// Where the pause time is kept while the host is stopped ("<host pid> <seconds since 1970>"), so an NX Hub started again knows it (adoptStopped)
    static func pauseFile(_ titleID: String) -> URL { ctlFile(titleID).deletingPathExtension().appendingPathExtension("paused") }
    /// The pause time a previous NX Hub kept for this stopped host
    static func keptPause(_ titleID: String, host: pid_t) -> Date? {
        guard let t = try? String(contentsOf: pauseFile(titleID), encoding: .utf8) else { return nil }
        let f = t.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard f.count == 2, pid_t(f[0]) == host, let s = Double(f[1]) else { return nil }
        return Date(timeIntervalSince1970: s)
    }


    /// The session is over for NX Hub. A paused game goes on, unless it is kept at its instant (NX Hub quits and the player keeps it suspended)
    func end(keepPaused: Bool = false) {
        timer?.invalidate(); timer = nil
        watch?.invalidate(); watch = nil
        saveWatch?.invalidate(); saveWatch = nil
        burstFrom = nil; burstLast = nil
        onFirst = nil; onSaved = nil
        sendingSave = false
        if paused, hostPID > 0, !keepPaused { kill(hostPID, SIGCONT) }
        if !keepPaused { paused = false; suspended = false; pausedSince = nil; pausing = false; try? FileManager.default.removeItem(at: GameSession.pauseFile(game.titleID)) }
    }

    /// Asks the host for a picture of its next frame and waits until it is written whole; it replaces last.png
    @discardableResult
    func shoot(timeout: Double = 2.5) async -> Bool {
        guard let ctl, !shooting, !paused else { return false }
        shooting = true; defer { shooting = false }
        let dir = ShotStore.folder(game.titleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let incoming = dir.appendingPathComponent("incoming.png")
        try? FileManager.default.removeItem(at: incoming)
        guard GameSession.append("shot \(incoming.path)", to: ctl) else { return false }
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            try? await Task.sleep(for: .milliseconds(60))
            guard ShotStore.complete(incoming) else { continue }
            guard rename(incoming.path, ShotStore.last(game.titleID).path) == 0 else { return false }
            lastShot = Date()
            onShot?()
            return true
        }
        DevLog.write("shot \(game.titleID): none within \(timeout) s")
        return false
    }

    /// The game's processes as macOS lists apps: its host first (it has the window), then its launcher
    func runningApps() -> [NSRunningApplication] {
        let id = game.bundleID.lowercased()
        let path = game.app?.url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier == hostPID || $0.bundleIdentifier?.lowercased() == id || ($0.bundleURL?.standardizedFileURL.path).map { $0 == path } == true }
            .sorted { ($0.processIdentifier == hostPID ? 0 : 1) < ($1.processIdentifier == hostPID ? 0 : 1) }
    }

    func owns(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == hostPID || app.processIdentifier == launcherPID || app.bundleIdentifier?.lowercased() == game.bundleID.lowercased()
    }

    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication.map(owns) ?? false }

    func stop() {
        guard hostPID > 0, !paused, kill(hostPID, SIGSTOP) == 0 else { return }
        paused = true
        pausedSince = Date()
        try? FileManager.default.createDirectory(at: GameSession.pauseFile(game.titleID).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(hostPID) \(pausedSince!.timeIntervalSince1970)".write(to: GameSession.pauseFile(game.titleID), atomically: true, encoding: .utf8)
        DevLog.write("session \(game.titleID): host \(hostPID) stopped")
    }

    func cont() {
        if hostPID > 0 { kill(hostPID, SIGCONT) }
        if paused { DevLog.write("session \(game.titleID): host \(hostPID) goes on") }
        paused = false
        pausedSince = nil
        try? FileManager.default.removeItem(at: GameSession.pauseFile(game.titleID))
    }

    /// Back to the game: it goes on and its window comes to the front (NX Hub, the active app, hands activation over: macOS 14's cooperative activation)
    func resume() {
        cont()
        suspended = false
        guard let app = runningApps().first else { return }
        NSApp.yieldActivation(to: app)
        app.unhide()
        app.activate()
    }

    /// Closes the game as its own Quit does (the host quits, then its launcher syncs the save and ends); SIGTERM to the launcher when that does not happen
    func close() async {
        await findProcesses()   // a game opened elsewhere: its IDs, so the waits below wait for it
        if launcherPID <= 0, let a = runningApps().first(where: { $0.processIdentifier != hostPID }) { launcherPID = a.processIdentifier }
        cont()
        suspended = false
        for a in runningApps() { a.terminate() }
        for _ in 0..<40 {
            if !alive { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        DevLog.write("session \(game.titleID): still running 4 s after Quit, SIGTERM to \(launcherPID > 0 ? "launcher \(launcherPID)" : "host \(hostPID)")")
        if launcherPID > 0 { kill(launcherPID, SIGTERM) } else if hostPID > 0 { kill(hostPID, SIGTERM) }
    }

    /// Ends a paused game without letting it run again: its launcher first (so it sends nothing after the host), then the stopped host. Its last commit stays
    /// whole (a commit is one folder swap, hle_fs.c), and nothing unsent goes over a cloud save another device made meanwhile: the next start compares the two
    /// and keeps the newer, with the other among the saves a sync replaced (save_sync.c ss_decide)
    func closeWithoutSending() async {
        await findProcesses()
        killWithoutSending()
        for _ in 0..<30 {
            if !alive { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The same at once, for a moment that cannot wait (the Mac logging out or shutting down)
    func killWithoutSending() {
        if launcherPID > 0 { kill(launcherPID, SIGKILL) }
        if hostPID > 0 { kill(hostPID, SIGKILL) }
        DevLog.write("session \(game.titleID): closed while paused, without sending its save (launcher \(launcherPID), host \(hostPID))")
        paused = false; suspended = false; pausing = false; pausedSince = nil
        try? FileManager.default.removeItem(at: GameSession.pauseFile(game.titleID))
    }

    /// Hosts stopped by a pause that a previous NX Hub left behind (it quit with the game kept suspended, or crashed during a pause)
    static func stoppedHosts() async -> [pid_t] {
        let r = await Shell.run("/usr/bin/pgrep", ["-f", "/Contents/MacOS/dmhost"])
        return r.out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.filter { Proc.stopped($0) }
    }
}

/// How busy the Mac's cores are (every process, from the kernel's tick counters): a build that keeps them busy is limited by the Mac, one that does not, by its own steps
enum CPULoad {
    struct Sample { let busy: UInt32, total: UInt32 }
    static func sample() -> Sample? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks   // user, system, idle, nice
        return Sample(busy: t.0 &+ t.1 &+ t.3, total: t.0 &+ t.1 &+ t.2 &+ t.3)
    }
    /// Cores busy between two samples (0…cores)
    static func cores(from a: Sample, to b: Sample) -> Double? {
        let total = b.total &- a.total
        guard total > 0 else { return nil }
        return Double(b.busy &- a.busy) / Double(total) * Double(count)
    }
    static let count = ProcessInfo.processInfo.activeProcessorCount
    /// Performance and efficiency cores (Apple silicon: hw.perflevel0 / hw.perflevel1)
    static let kinds: (p: Int, e: Int)? = {
        func n(_ name: String) -> Int? { var v: Int32 = 0; var s = MemoryLayout<Int32>.size; return sysctlbyname(name, &v, &s, nil, 0) == 0 ? Int(v) : nil }
        guard let p = n("hw.perflevel0.logicalcpu"), let e = n("hw.perflevel1.logicalcpu") else { return nil }
        return (p, e)
    }()
}
