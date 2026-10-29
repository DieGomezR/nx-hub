import Foundation
import Observation

/// One step of a build: its time (the script's stage_end) and the cores busy on average while it ran
struct StageTime: Codable, Hashable {
    var name: String
    var seconds: Double
    var cores: Double?
}

/// The last build of each game, step by step: Application Support/NX Hub/build-times.json
enum BuildStats {
    struct Entry: Codable {
        var date: Date
        var total: Double
        var stages: [StageTime]
    }
    static let file = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/build-times.json")
    static func load() -> [String: Entry] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: d)) ?? [:]
    }
    static func save(_ titleID: String, _ e: Entry) {
        var all = load()
        all[titleID] = e
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: file) }
    }
    /// "11 min 32 s", "48 s"
    static func duration(_ s: Double) -> String {
        Duration.seconds(s.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// One build of a game with nxnative's NSP script (scripts/build_ipa_from_nsp.py --platform mac-app --progress json; nxnative docs/frontends.md, Building)
@Observable
@MainActor
final class BuildJob: Identifiable {
    enum State: Equatable { case queued, running, succeeded, failed(String), cancelled }

    let id = UUID()
    let titleID: String
    let name: String
    let folder: URL
    let appOut: URL?                // where the app goes: the existing app, so a rebuild replaces it in place
    let source: URL                 // the nxnative checkout
    var state: State = .queued
    var stageK = 0
    var stageN = 0
    var stageName = ""
    var step = ""
    var fraction: Double?           // 0…0.99, nil while the work cannot be counted
    var eta: Double?
    var detail = ""                 // "1,234 / 25,693 shaders"
    var lines: [String] = []        // the newest lines of the log (say messages and the tools' output)
    var redLine: String?            // the last error line
    var started: Date?
    var finished: Date?
    var commit = ""                 // the checkout's commit at the start
    var chain = ""
    var logURL: URL?
    var stages: [StageTime] = []     // the steps done, with their times
    var cores: Double?              // the Mac's cores busy right now (all processes; the build's while it runs)
    @ObservationIgnored var cpuLast: CPULoad.Sample?
    @ObservationIgnored var coreSum = 0.0
    @ObservationIgnored var coreN = 0
    @ObservationIgnored var shellPID: Int32 = 0      // the shell that runs the script and writes its exit code to the log
    @ObservationIgnored var scriptPID: Int32 = 0     // the script (its process group, with set -m)
    @ObservationIgnored var offset: UInt64 = 0       // how far the log has been read
    @ObservationIgnored var partial = ""             // a line not ended yet

    init(titleID: String, name: String, folder: URL, appOut: URL?, source: URL) {
        self.titleID = titleID; self.name = name; self.folder = folder; self.appOut = appOut; self.source = source
    }

    var isActive: Bool { state == .queued || state == .running }
    var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started ?? Date()) }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }
}

/// Builds run one at a time, each in a shell of its own whose output goes to a log file, not to NX Hub: a build goes on when NX Hub quits,
/// and NX Hub finds it again at its next start (builds.json) and keeps reading its log. The shell's last line is the script's exit code
@Observable
@MainActor
final class BuildService {
    var jobs: [BuildJob] = []
    @ObservationIgnored var onFinished: ((BuildJob) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polls = 0
    /// The Mac stays awake while a build runs (Settings › nxnative and builds)
    @ObservationIgnored var keepAwake = true
    @ObservationIgnored private let awake = SleepGuard()
    @ObservationIgnored private var activity: NSObjectProtocol?
    private let stateFile = Paths.home.appendingPathComponent("Library/Application Support/NX Hub/builds.json")

    var current: BuildJob? { jobs.first { $0.state == .running } }
    var queued: [BuildJob] { jobs.filter { $0.state == .queued } }
    func job(for titleID: String) -> BuildJob? { jobs.last { $0.titleID == titleID && $0.isActive } }

    // The shell around the script: its own process group (set -m) so Stop reaches the script with SIGINT, as Ctrl-C does; the exit code at the end
    private static let wrapper = """
    set -m
    "$@" &
    c=$!
    printf '{"ev":"nxhub_pid","pid":%d}\\n' "$c"
    trap 'kill -INT -"$c" 2>/dev/null || kill -INT "$c" 2>/dev/null' INT TERM
    wait "$c"; code=$?
    while kill -0 "$c" 2>/dev/null; do wait "$c"; code=$?; done
    printf '{"ev":"nxhub_exit","code":%d}\\n' "$code"
    """

    func enqueue(_ job: BuildJob, config: Config) {
        guard self.job(for: job.titleID) == nil else { return }
        jobs.append(job)
        startNext(config: config)
        save()
    }

    func cancel(_ job: BuildJob) {
        switch job.state {
        case .queued: job.state = .cancelled; job.finished = Date(); save()
        case .running:
            if job.scriptPID > 0 { if kill(-job.scriptPID, SIGINT) != 0 { kill(job.scriptPID, SIGINT) } }
            else if job.shellPID > 0 { kill(job.shellPID, SIGINT) }
        default: break
        }
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    private func startNext(config: Config) {
        keepAwake = config.awakeWhileBuilding
        defer { updateAwake() }
        guard current == nil, let job = jobs.first(where: { $0.state == .queued }) else { return }
        job.state = .running
        job.started = Date()
        let fm = FileManager.default
        let script = job.source.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        let python = Paths.expand(config.pythonPath)
        let keys = Paths.expand(config.keysPath)
        if !fm.fileExists(atPath: script.path) { return fail(job, LF("No nxnative checkout at %@.", Paths.pretty(job.source)), config) }
        if !fm.isExecutableFile(atPath: python.path) { return fail(job, LF("Python not found at %@ (Settings › Build).", Paths.pretty(python)), config) }
        if config.keysPath.isEmpty || !fm.fileExists(atPath: keys.path) { return fail(job, L("Choose your prod.keys in Settings › Build."), config) }

        try? fm.createDirectory(at: Paths.hubLogs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = Paths.hubLogs.appendingPathComponent("build-\(job.titleID)-\(stamp).log")
        var args = [script.path, job.folder.path, "-k", keys.path, "--platform", "mac-app", "--progress", "json"]
        if let out = job.appOut { args += ["-o", out.path] }
        if config.allowOtherMetal { args.append("--allow-other-metal") }
        if config.allowShaderRegressions { args.append("--allow-shader-regressions") }
        let header = "$ cd \(job.source.path) && \(python.path) \(args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))\n"
        fm.createFile(atPath: logURL.path, contents: header.data(using: .utf8))
        job.logURL = logURL
        job.offset = UInt64(header.utf8.count)
        DevLog.write("build start: \(job.name) \(args.joined(separator: " "))")

        Task { [weak self] in
            // A build NX Hub lost track of (an older NX Hub's, or one whose script was killed while its shader step ran on) may still be working in the game's
            // folder: two builds there delete each other's files halfway (dmsh_build.py: FileNotFoundError). It stops before this one starts
            let stale = await BuildService.leftovers(job)
            if !stale.isEmpty {
                job.append(LF("Stopping an earlier build of this game that was still running (%lld processes): two builds in one folder break each other.", stale.count))
                DevLog.write("build \(job.titleID): stopping leftover processes \(stale)")
                await BuildService.stop(stale)
            }
            let dir = BuildService.buildDir(job), tid = job.titleID
            await Task.detached(priority: .utility) { BuildService.clearWork(dir, titleID: tid) }.value
            let head = await Shell.git(job.source, ["rev-parse", "--short=12", "HEAD"])
            job.commit = head.ok ? head.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            job.chain = NXNativeRepo.chain(in: (try? String(contentsOf: job.source.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h"), encoding: .utf8)) ?? "")
            self?.launch(job, python: python, args: args, log: logURL, config: config)
        }
    }

    /// The game's work folder (<title ID>_build beside its packages)
    static func buildDir(_ job: BuildJob) -> URL { job.folder.appendingPathComponent(job.titleID + "_build", isDirectory: true) }

    /// Processes of an earlier build of the game still running: the NSP script for its folder, and every tool working in its <title ID>_build
    static func leftovers(_ job: BuildJob) async -> [pid_t] {
        let script = "build_ipa_from_nsp\\.py " + Shell.regexEscape(job.folder.path) + "( |$)"
        let tools = Shell.regexEscape(buildDir(job).path + "/")
        let a = await Shell.pids(matching: script), b = await Shell.pids(matching: tools)
        return Array(Set(a + b)).sorted()
    }

    /// SIGTERM, then SIGKILL for what is still there after 4 s
    static func stop(_ pids: [pid_t]) async {
        for p in pids { kill(p, SIGTERM) }
        for _ in 0..<40 {
            if !pids.contains(where: { kill($0, 0) == 0 }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for p in pids where kill(p, 0) == 0 { kill(p, SIGKILL) }
    }

    /// The temporary folders the shader step leaves when a run of it does not finish (<title ID>_build/tmp/dmsh_*): each new run makes its own
    nonisolated static func clearWork(_ buildDir: URL, titleID: String) {
        let tmp = buildDir.appendingPathComponent("tmp")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("dmsh_") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            DevLog.write("build \(titleID): removed the leftover work folder tmp/\(name)")
        }
    }

    private func launch(_ job: BuildJob, python: URL, args: [String], log: URL, config: Config) {
        guard let out = try? FileHandle(forWritingTo: log) else { return fail(job, LF("Cannot write the build log %@.", log.path), config) }
        _ = try? out.seekToEnd()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", BuildService.wrapper, "nxhub-build", python.path] + args
        p.currentDirectoryURL = job.source
        p.environment = Shell.environment(["PYTHONUNBUFFERED": "1"])
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        p.qualityOfService = .userInitiated   // work you wait for: the performance cores, not a background app's share
        do {
            try p.run()
            job.shellPID = p.processIdentifier
            save()
            startTimer(config: config)
        } catch {
            fail(job, error.localizedDescription, config)
        }
        try? out.close()
    }

    private func startTimer(config: Config) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll(config: config) }
        }
    }

    /// Reads what each running build wrote since the last look; a build whose shell is gone without its exit line was killed
    /// While a build runs: the Mac does not sleep on its own (when asked), and macOS does not nap NX Hub, so the build's processes keep their priority
    private func updateAwake() {
        let building = current != nil
        awake.set(keepAwake && building, reason: "NX Hub: building a game")
        if building && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Building a game with nxnative")
        } else if !building, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    private func poll(config: Config) {
        let running = jobs.filter { $0.state == .running && $0.logURL != nil }
        if running.isEmpty { timer?.invalidate(); timer = nil; updateAwake(); return }
        polls += 1
        if polls % 4 == 0, let now = CPULoad.sample() {   // every 2 s
            for job in running {
                if let last = job.cpuLast, let c = CPULoad.cores(from: last, to: now) { job.cores = c; job.coreSum += c; job.coreN += 1 }
                job.cpuLast = now
            }
        }
        for job in running {
            read(job, config: config)
            if job.state == .running, job.shellPID > 0, kill(job.shellPID, 0) != 0, job.scriptPID <= 0 || kill(job.scriptPID, 0) != 0 {
                read(job, config: config)
                if job.state == .running { ended(job, status: -1, config: config) }
            }
        }
    }

    private func read(_ job: BuildJob, config: Config) {
        guard let url = job.logURL, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: job.offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return }
        job.offset += UInt64(data.count)
        var parts = (job.partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        job.partial = parts.removeLast()
        for line in parts where !line.isEmpty {
            if line.hasPrefix("{"), let d = line.data(using: .utf8), let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                handle(ev, job: job, config: config)
                if job.state != .running { return }
            } else {
                job.append(line)
                if line.hasPrefix("[RED]") || line.contains("Traceback") { job.redLine = line }
            }
        }
    }

    /// One event of the script's --progress json stream (stage, step, progress, stage_end, say), or the shell's (nxhub_pid, nxhub_exit)
    private func handle(_ ev: [String: Any], job: BuildJob, config: Config) {
        func int(_ k: String) -> Int? { (ev[k] as? NSNumber)?.intValue }
        func dbl(_ k: String) -> Double? { (ev[k] as? NSNumber)?.doubleValue }
        func str(_ k: String) -> String? { ev[k] as? String }
        switch str("ev") {
        case "nxhub_pid":
            job.scriptPID = Int32(int("pid") ?? 0); save()
        case "nxhub_exit":
            ended(job, status: Int32(int("code") ?? -1), config: config)
        case "stage":
            job.stageK = int("k") ?? job.stageK; job.stageN = int("n") ?? job.stageN
            job.stageName = str("name") ?? ""; job.step = str("step") ?? ""
            job.fraction = nil; job.eta = nil; job.detail = ""
            job.coreSum = 0; job.coreN = 0
            job.append("▸ [\(job.stageK)/\(job.stageN)] \(job.stageName)")
        case "step":
            job.step = str("step") ?? job.step
        case "progress":
            job.fraction = dbl("frac")
            job.eta = dbl("eta")
            if let done = dbl("done"), let total = dbl("total"), total > 0 {
                let unit = str("unit") ?? ""
                job.detail = unit == "B" ? "\(ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
                    : "\(Int(done)) / \(Int(total))\(unit.isEmpty ? "" : " " + unit)\((ev["est"] as? Bool) == true ? " ~" : "")"
            }
            if let note = str("note"), !note.isEmpty { job.detail += " · " + note }
        case "stage_end":
            if let s = str("summary"), !s.isEmpty { job.append("  ✓ \(s)") }
            let st = StageTime(name: str("name") ?? job.stageName, seconds: dbl("elapsed") ?? 0, cores: job.coreN > 0 ? job.coreSum / Double(job.coreN) : nil)
            job.stages.append(st)
            DevLog.write("build \(job.titleID) step \(st.name): \(Int(st.seconds)) s, cores \(st.cores.map { String(format: "%.1f", $0) } ?? "-") of \(CPULoad.count)")
        case "say":
            let m = str("msg") ?? ""
            job.append(m)
            if m.hasPrefix("[RED]") { job.redLine = m }
        default: break
        }
    }

    private func ended(_ job: BuildJob, status: Int32, config: Config) {
        guard job.state == .running else { return }
        if !job.partial.isEmpty { job.append(job.partial); job.partial = "" }
        job.finished = Date()
        switch status {
        case 0:
            job.state = .succeeded
            config.buildRecords[job.titleID] = [job.commit, job.chain, ISO8601DateFormatter().string(from: Date())]
            if !job.stages.isEmpty { BuildStats.save(job.titleID, BuildStats.Entry(date: Date(), total: job.elapsed, stages: job.stages)) }
        case 130: job.state = .cancelled
        case 2: job.state = .failed(L("The NSP script rejected its arguments (see the log)."))
        case -1: job.state = .failed(job.redLine.map { $0.replacingOccurrences(of: "[RED] ", with: "") } ?? L("The build was stopped from outside (its process is gone)."))
        default: job.state = .failed(job.redLine.map { $0.replacingOccurrences(of: "[RED] ", with: "") } ?? LF("The build stopped (exit %lld).", Int(status)))
        }
        DevLog.write("build end: \(job.name) status \(status) state \(job.state) in \(Int(job.elapsed)) s")
        save()
        onFinished?(job)
        startNext(config: config)
        updateAwake()
    }

    private func fail(_ job: BuildJob, _ message: String, _ config: Config) {
        job.state = .failed(message)
        job.finished = Date()
        job.append("[RED] " + message)
        save()
        onFinished?(job)
        startNext(config: config)
    }

    // MARK: builds that outlive NX Hub

    private struct Saved: Codable {
        var titleID: String, name: String, folder: String, appOut: String?, source: String, log: String
        var shellPID: Int32, scriptPID: Int32, started: Date, commit: String, chain: String
        var queued: Bool?                 // waiting for its turn (no process yet)
    }

    private func save() {
        let active = jobs.filter { $0.state == .running || $0.state == .queued }.compactMap { j -> Saved? in
            if j.state == .queued {
                return Saved(titleID: j.titleID, name: j.name, folder: j.folder.path, appOut: j.appOut?.path, source: j.source.path, log: "",
                             shellPID: 0, scriptPID: 0, started: Date(), commit: "", chain: "", queued: true)
            }
            guard let log = j.logURL else { return nil }
            return Saved(titleID: j.titleID, name: j.name, folder: j.folder.path, appOut: j.appOut?.path, source: j.source.path, log: log.path,
                         shellPID: j.shellPID, scriptPID: j.scriptPID, started: j.started ?? Date(), commit: j.commit, chain: j.chain)
        }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(active) { try? d.write(to: stateFile) }
    }

    /// At start: the builds a previous NX Hub left running come back, read from their logs (one that finished meanwhile reports its result), and the ones
    /// that waited for their turn wait again
    func restore(config: Config) {
        guard let d = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode([Saved].self, from: d) else { return }
        for s in saved where job(for: s.titleID) == nil {
            let j = BuildJob(titleID: s.titleID, name: s.name, folder: URL(fileURLWithPath: s.folder), appOut: s.appOut.map { URL(fileURLWithPath: $0) }, source: URL(fileURLWithPath: s.source))
            if s.queued == true {
                jobs.append(j)
                DevLog.write("build restored: \(j.name) waiting")
                continue
            }
            j.state = .running; j.started = s.started; j.commit = s.commit; j.chain = s.chain
            j.logURL = URL(fileURLWithPath: s.log); j.shellPID = s.shellPID; j.scriptPID = s.scriptPID
            jobs.append(j)
            read(j, config: config)
            if j.state == .running, kill(j.shellPID, 0) != 0, j.scriptPID <= 0 || kill(j.scriptPID, 0) != 0 { ended(j, status: -1, config: config) }
            DevLog.write("build restored: \(j.name) \(j.state)")
        }
        if current != nil { startTimer(config: config) } else { startNext(config: config) }
        keepAwake = config.awakeWhileBuilding
        updateAwake()
        save()
    }

    /// NX Hub quits: the running build goes on by itself, and the queued ones wait for the next start (builds.json)
    func prepareToQuit() { save() }
}
