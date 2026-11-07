import Foundation

/// Candidate folders for the "Add project" finder.
///
/// Sources, in priority order:
/// 1. Folders Claude Code has run in (`~/.claude.json` project keys, ranked by `history.jsonl`).
/// 2. A quick, bounded scan of common code folders for git repos and project markers.
///
/// Privacy: paths under Desktop, Documents, Downloads and iCloud are never touched on disk
/// here (no existence checks, no scanning), so opening the finder can't trigger macOS
/// file-access prompts. Prompt text in history.jsonl is parsed but never kept.
enum ProjectFinder {
    private static var cache: (Date, [[String: Any]])?
    private static let lock = NSLock()
    private static let home = NSHomeDirectory()

    /// Cached candidates; rebuilt when older than a minute.
    static func candidates(added: Set<String>) -> [[String: Any]] {
        lock.lock()
        let cached = cache
        lock.unlock()
        var list: [[String: Any]]
        if let (at, c) = cached, Date().timeIntervalSince(at) < 60 { list = c }
        else {
            list = build()
            lock.lock(); cache = (Date(), list); lock.unlock()
        }
        return list.map { c in
            var c = c
            c["added"] = added.contains(c["path"] as? String ?? "")
            return c
        }
    }

    static func invalidate() { lock.lock(); cache = nil; lock.unlock() }

    static func isProtected(_ p: String) -> Bool {
        ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .contains { p == "\(home)/\($0)" || p.hasPrefix("\(home)/\($0)/") }
    }

    private static func isNoise(_ p: String) -> Bool {
        p == home || p == "/" || p.contains("/.claude/worktrees/")
            || ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"].contains { p.hasPrefix($0) }
    }

    private static func build() -> [[String: Any]] {
        var byPath: [String: [String: Any]] = [:]

        // 1. Claude Code's own records.
        let configDir = ProjectStore.claudeDir
        let claudeJson = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        var last: [String: Double] = [:], uses: [String: Int] = [:]
        if let data = try? Data(contentsOf: claudeJson),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = obj["projects"] as? [String: Any] {
            for (path, v) in projects {
                let t = ((v as? [String: Any])?["lastStartTime"] as? Double) ?? 0
                last[path] = max(last[path] ?? 0, t)
            }
        }
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("history.jsonl")) {
            for line in data.split(separator: 0x0A) {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let p = o["project"] as? String else { continue }
                let t = (o["timestamp"] as? Double) ?? 0
                last[p] = max(last[p] ?? 0, t)
                uses[p, default: 0] += 1
            }
        }
        let fm = FileManager.default
        for (path, t) in last where !isNoise(path) {
            let prot = isProtected(path)
            if !prot && !fm.fileExists(atPath: path) { continue }
            byPath[path] = entry(path, last: t, uses: uses[path] ?? 0, source: "claude", protected: prot)
        }

        // 2. Quick scan of common code folders (never protected ones, never all of home).
        var roots = ["dev", "code", "projects", "src", "Developer", "repos", "workspace", "git", "work"]
            .map { "\(home)/\($0)" }
        for p in byPath.keys where !isProtected(p) {
            let parent = (p as NSString).deletingLastPathComponent
            if parent != home && parent.hasPrefix(home + "/") { roots.append(parent) }
        }
        var visited = 0
        for root in Set(roots) where fm.fileExists(atPath: root) && !isProtected(root) {
            scan(root, depth: 0, visited: &visited) { path in
                if byPath[path] == nil && !isNoise(path) {
                    byPath[path] = entry(path, last: 0, uses: 0, source: "scan", protected: false)
                }
            }
        }
        return Array(byPath.values)
    }

    private static let markers = [".git", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "go.mod", "setup.py", "Gemfile", "pom.xml", "build.gradle", "CLAUDE.md"]
    private static let skip: Set<String> = ["node_modules", "Library", "build", "dist", "target", "DerivedData", "Pods", "venv", "__pycache__"]

    private static func scan(_ dir: String, depth: Int, visited: inout Int, found: (String) -> Void) {
        guard depth <= 3, visited < 4000 else { return }
        visited += 1
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(atPath: dir) else { return }
        if depth > 0 && kids.contains(where: { markers.contains($0) }) { found(dir); return }
        for k in kids where !k.hasPrefix(".") && !skip.contains(k) {
            let p = (dir as NSString).appendingPathComponent(k)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { scan(p, depth: depth + 1, visited: &visited, found: found) }
        }
    }

    private static func entry(_ path: String, last: Double, uses: Int, source: String, protected: Bool) -> [String: Any] {
        var e: [String: Any] = [
            "path": path,
            "name": (path as NSString).lastPathComponent,
            "parent": abbreviate((path as NSString).deletingLastPathComponent),
            "last": last, "uses": uses, "source": source,
        ]
        if !protected, let b = gitBranch(path) { e["branch"] = b }
        return e
    }

    /// Branch name from .git/HEAD without spawning git.
    static func gitBranch(_ path: String) -> String? {
        let head = (path as NSString).appendingPathComponent(".git/HEAD")
        guard let s = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ref: refs/heads/") { return String(t.dropFirst("ref: refs/heads/".count)) }
        return String(t.prefix(7))
    }

    static func abbreviate(_ p: String) -> String {
        p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    /// Subfolders of a folder, for typed-path completion.
    static func listDir(_ raw: String) -> [String: Any] {
        let dir = expand(raw)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
              let kids = try? fm.contentsOfDirectory(atPath: dir) else { return ["ok": false, "dir": raw] }
        var entries: [[String: Any]] = []
        for k in kids.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let p = (dir as NSString).appendingPathComponent(k)
            var d: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &d), d.boolValue, !k.hasSuffix(".app") else { continue }
            var e: [String: Any] = ["name": k]
            if !isProtected(p), let b = gitBranch(p) { e["branch"] = b }
            entries.append(e)
            if entries.count >= 400 { break }
        }
        return ["ok": true, "dir": raw, "entries": entries]
    }
}
