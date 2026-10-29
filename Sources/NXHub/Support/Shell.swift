import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
    /// The first non-empty line of stderr, else of stdout: what to show when a command fails
    var message: String {
        let pick = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : err
        return pick.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "exit \(status)"
    }
}

/// Bytes a process writes, collected from its pipe's handler thread
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum Shell {
    /// Text as a regular expression that matches it as written (pgrep -f takes one: "Mario + Rabbids", "Smash Bros.")
    static func regexEscape(_ s: String) -> String { s.map { "\\.[]()*+?{}|^$".contains($0) ? "\\\($0)" : String($0) }.joined() }

    /// Processes whose command line matches (pgrep -f), NX Hub left out
    static func pids(matching pattern: String) async -> [pid_t] {
        let r = await run("/usr/bin/pgrep", ["-f", pattern])
        return r.out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != getpid() }
    }
    /// The PATH of the user's login shell. An app opened from Finder gets only /usr/bin:/bin:/usr/sbin:/sbin, while nxnative's build needs
    /// Homebrew's tools, the .NET SDK and the rest the Terminal finds. Loaded once at start (loadUserPath).
    nonisolated(unsafe) static var userPath: String?
    static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = userPath ?? env["PATH"] ?? basePath
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.homebrew/bin", "\(NSHomeDirectory())/.dotnet"] where !path.split(separator: ":").contains(Substring(p)) {
            if FileManager.default.fileExists(atPath: p) { path += ":" + p }
        }
        env["PATH"] = path
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// The user's shell (from the account, since an app opened from Finder may have no SHELL)
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { let s = String(cString: sh); if !s.isEmpty { return s } }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func loadUserPath() async {
        let marker = "__NXHUB_PATH__="
        let r = await run(loginShell, ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""], env: ProcessInfo.processInfo.environment, timeout: 15)
        for line in r.out.split(separator: "\n") where line.hasPrefix(marker) {
            let p = String(line.dropFirst(marker.count))
            if !p.isEmpty { userPath = p }
        }
    }

    /// Runs a command to its end and returns what it wrote. timeout: seconds before it is terminated
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil, timeout: TimeInterval? = nil) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            p.environment = env ?? environment()
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice
            let out = DataBox(), err = DataBox()
            outPipe.fileHandleForReading.readabilityHandler = { h in out.append(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { h in err.append(h.availableData) }
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ShellResult(status: proc.terminationStatus,
                                                   out: String(decoding: out.value, as: UTF8.self),
                                                   err: String(decoding: err.value, as: UTF8.self)))
            }
            do {
                try p.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: ShellResult(status: -1, out: "", err: error.localizedDescription))
                return
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            }
        }
    }

    static func git(_ repo: URL, _ args: [String], timeout: TimeInterval? = 120) async -> ShellResult {
        await run("/usr/bin/git", ["-C", repo.path] + args, env: environment(["GIT_TERMINAL_PROMPT": "0"]), timeout: timeout)
    }
}
