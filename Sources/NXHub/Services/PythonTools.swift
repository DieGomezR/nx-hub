import Foundation

/// The Python packages nxnative's tools import (its .github/requirements/tools.txt; nxnative docs/development.md: one venv serves every game), installed into the
/// Python NX Hub builds with. nxnative adds one now and then (zbic, November 2026), and its NSP script then stops with "is missing modules"
enum PythonTools {
    static func requirements(in checkout: URL) -> URL { checkout.appendingPathComponent(".github/requirements/tools.txt") }
    /// A build that stopped because the Python lacks a package the tools import
    static func missing(_ message: String) -> Bool { message.contains("is missing modules") }

    /// The command that installs into that Python: its own pip; pip put into it first (ensurepip) when it has none, as in a venv made without one;
    /// uv's pip for a venv uv made (it has no ensurepip either)
    private static func installer(_ python: URL, _ env: [String: String]) async -> [String]? {
        let pip = [python.path, "-m", "pip", "install", "--disable-pip-version-check"]
        if await Shell.run(python.path, ["-m", "pip", "--version"], env: env, timeout: 60).ok { return pip }
        if await Shell.run(python.path, ["-m", "ensurepip", "--upgrade", "--default-pip"], env: env, timeout: 300).ok,
           await Shell.run(python.path, ["-m", "pip", "--version"], env: env, timeout: 60).ok { return pip }
        let uv = await Shell.run("/usr/bin/which", ["uv"], env: env, timeout: 15)
        let path = uv.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return uv.ok && !path.isEmpty ? [path, "pip", "install", "--python", python.path] : nil
    }

    /// The requirements, then backports.zstd where the Python has no compression.zstd (before Python 3.14), as the NSP script asks
    static func install(python: URL, checkout: URL) async -> ShellResult {
        let req = requirements(in: checkout)
        guard FileManager.default.fileExists(atPath: req.path) else { return ShellResult(status: 1, out: "", err: LF("%@ is missing: update nxnative first.", req.path)) }
        let env = Shell.environment()
        guard let cmd = await installer(python, env) else {
            return ShellResult(status: 1, out: "", err: LF("%@ has no pip, and neither ensurepip nor uv could install one.", python.path))
        }
        let r = await Shell.run(cmd[0], Array(cmd.dropFirst()) + ["-r", req.path], cwd: checkout, env: env, timeout: 900)
        guard r.ok else { return r }
        if await Shell.run(python.path, ["-c", "import compression.zstd"], env: env, timeout: 30).ok { return r }
        return await Shell.run(cmd[0], Array(cmd.dropFirst()) + ["backports.zstd"], cwd: checkout, env: env, timeout: 600)
    }
}
