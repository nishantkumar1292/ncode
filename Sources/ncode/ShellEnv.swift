import Foundation

/// GUI apps on macOS don't inherit the user's shell PATH. We capture the login-shell
/// environment once so `claude` (and every command Claude runs) sees the same
/// environment it would see in Terminal.
enum ShellEnv {
    static func load() -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"] ?? "/bin/zsh"
        let marker = "__NCODE_ENV_7f3a__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '\(marker)'; env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return withFallbackPath(base) }

        // Hard timeout so a slow or interactive shell rc can't hang startup.
        let deadline = DispatchTime.now() + .seconds(6)
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: marker) else { return withFallbackPath(base) }
        let envText = text[range.upperBound...]
        var env: [String: String] = [:]
        for entry in envText.split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let k = String(entry[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let v = String(entry[entry.index(after: eq)...])
            if !k.isEmpty { env[k] = v }
        }
        if env["PATH"] == nil { return withFallbackPath(base) }
        // Drop variables that only make sense inside the probing shell.
        for k in ["SHLVL", "_", "OLDPWD", "PWD"] { env.removeValue(forKey: k) }
        base.merge(env) { _, new in new }
        return base
    }

    private static func withFallbackPath(_ env: [String: String]) -> [String: String] {
        var env = env
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [current]).joined(separator: ":")
        return env
    }

    static func findClaude(env: [String: String]) -> String? {
        if let custom = UserDefaults.standard.string(forKey: "claudePath"),
           FileManager.default.isExecutableFile(atPath: custom) { return custom }
        let home = NSHomeDirectory()
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let path = (d as NSString).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
