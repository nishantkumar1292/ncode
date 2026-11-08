import Foundation

/// A Claude Code account = a config directory (what `CLAUDE_CONFIG_DIR` points at).
/// `dir == nil` means "don't override": Claude's default location (~/.claude + ~/.claude.json),
/// or whatever the login shell already exports.
struct ClaudeAccount: Identifiable, Hashable {
    let dir: String?
    var email: String?
    var org: String?

    var id: String { dir ?? "" }
    /// Stable color slot for this account's initial (0 = neutral, for the default account).
    var slot: Int = 0
    var initial: String { String(name.prefix(1)).uppercased() }

    /// Short name: "default", or the folder name without the `.claude-` prefix ("personal", "om").
    var name: String {
        guard let dir else { return "default" }
        let base = (dir as NSString).lastPathComponent
        if base.hasPrefix(".claude-") { return String(base.dropFirst(".claude-".count)) }
        return base.hasPrefix(".") ? String(base.dropFirst()) : base
    }
    var title: String { email.map { "\(name) · \($0)" } ?? name }

    var root: URL {
        if let dir { return URL(fileURLWithPath: dir) }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }
    var configFile: URL {
        if dir == nil, ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.isEmpty ?? true {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        }
        return root.appendingPathComponent(".claude.json")
    }
    var projectsDir: URL { root.appendingPathComponent("projects") }
    var historyFile: URL { root.appendingPathComponent("history.jsonl") }
}

/// Claude in Chrome settings, read from (and the default written to) the account's config file,
/// the same keys the terminal's /chrome screen uses.
enum ChromeSettings {
    static let defaultKey = "claudeInChromeDefaultEnabled"

    /// The config file the CLI uses for this config dir (`~/.claude.json` when none is set).
    static func configFile(configDir: String?) -> URL {
        if let d = configDir, !d.isEmpty { return URL(fileURLWithPath: d).appendingPathComponent(".claude.json") }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    private static func load(_ file: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func enabledByDefault(configDir: String?) -> Bool {
        load(configFile(configDir: configDir))[defaultKey] as? Bool == true
    }

    static func info(configDir: String?) -> [String: Any] {
        let o = load(configFile(configDir: configDir))
        var out: [String: Any] = [
            "enabledByDefault": o[defaultKey] as? Bool == true,
            "installed": o["cachedChromeExtensionInstalled"] as? Bool == true,
        ]
        if let b = (o["chromeExtension"] as? [String: Any])?["pairedDeviceName"] as? String { out["browser"] = b }
        return out
    }

    /// Flip "Enabled by default" without rewriting the rest of the file: the CLI owns this file
    /// and keeps its formatting, so only the one value changes. Written atomically, owner-only.
    static func setEnabledByDefault(_ on: Bool, configDir: String?) -> Bool {
        let file = configFile(configDir: configDir)
        guard var text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let pattern = "\"\(defaultKey)\"\\s*:\\s*(true|false)"
        if let r = text.range(of: pattern, options: .regularExpression) {
            text.replaceSubrange(r, with: "\"\(defaultKey)\": \(on)")
        } else if let brace = text.firstIndex(of: "{") {
            text.insert(contentsOf: "\n  \"\(defaultKey)\": \(on),", at: text.index(after: brace))
        } else { return false }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return false }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".ncode-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(tmp.path, file.path) != 0 { try? FileManager.default.removeItem(at: tmp); return false }
        return true
    }
}

enum Accounts {
    /// The default account plus every `~/.claude-*` folder that has a Claude config file,
    /// plus any folders the user added by hand.
    static func discover(extra: [String]) -> [ClaudeAccount] {
        var list = [identity(ClaudeAccount(dir: nil))]
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var dirs = ((try? fm.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".claude-") }
            .map { "\(home)/\($0)" }
        dirs += extra
        var slots = UserDefaults.standard.dictionary(forKey: "accountSlots") as? [String: Int] ?? [:]
        var seen = Set<String>()
        for d in dirs.sorted() where !seen.contains(d) {
            seen.insert(d)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: "\(d)/.claude.json") else { continue }
            var a = identity(ClaudeAccount(dir: d))
            if slots[d] == nil {   // assign once, so adding an account never reshuffles colors
                let used = Set(slots.values)
                slots[d] = (1...5).first { !used.contains($0) } ?? (slots.count % 5 + 1)
            }
            a.slot = slots[d] ?? 1
            list.append(a)
        }
        UserDefaults.standard.set(slots, forKey: "accountSlots")
        return list
    }

    /// Email and organisation of the account logged in for this config dir (from its config file).
    static func identity(_ a: ClaudeAccount) -> ClaudeAccount {
        var a = a
        if let data = try? Data(contentsOf: a.configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["oauthAccount"] as? [String: Any] {
            a.email = oauth["emailAddress"] as? String
            a.org = oauth["organizationName"] as? String
        }
        return a
    }

    /// Per-folder usage from an account's history.jsonl: last prompt time (ms) and prompt count.
    /// Only the `project` and `timestamp` fields are read; prompt text is never kept.
    static func usage(_ a: ClaudeAccount) -> [String: (last: Double, count: Int)] {
        let file = a.historyFile
        let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        lock.lock()
        if let c = usageCache[file.path], c.0 == mod { lock.unlock(); return c.1 }
        lock.unlock()
        var out: [String: (last: Double, count: Int)] = [:]
        if let data = try? Data(contentsOf: file, options: .alwaysMapped) {
            for line in data.split(separator: 0x0A) {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let p = o["project"] as? String else { continue }
                let t = o["timestamp"] as? Double ?? 0
                let prev = out[p] ?? (0, 0)
                out[p] = (max(prev.last, t), prev.count + 1)
            }
        }
        lock.lock(); usageCache[file.path] = (mod, out); lock.unlock()
        return out
    }
    private static var usageCache: [String: (Date, [String: (last: Double, count: Int)])] = [:]
    private static let lock = NSLock()

    /// The account this folder was used with most recently (nil if none has history for it).
    static func detect(for path: String, among accounts: [ClaudeAccount]) -> ClaudeAccount? {
        var best: (ClaudeAccount, Double)?
        for a in accounts {
            if let u = usage(a)[path], u.last > (best?.1 ?? -1) { best = (a, u.last) }
            else if best == nil, FileManager.default.fileExists(atPath: a.projectsDir.appendingPathComponent(ProjectStore.encode(path)).path) { best = (a, 0) }
        }
        return best?.0
    }
}
