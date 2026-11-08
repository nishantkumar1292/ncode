import Foundation

struct SessionMeta: Identifiable, Hashable {
    let id: String          // session id (transcript file name)
    var title: String
    var modified: Date
    let file: URL
    var configDir: String? = nil   // account the transcript belongs to (nil = default)
}

struct Project: Identifiable, Hashable {
    var id: String { cwd }
    let cwd: String
    var name: String { (cwd as NSString).lastPathComponent }
    var transcriptDirs: [URL]
    var sessions: [SessionMeta]
    var lastActivity: Date
    var pinned: Bool
    var accountDir: String? = nil   // account new chats use (nil = default)
}

/// Chats started in ncode. The CLI saves every chat in a folder to the same place (terminal
/// chats, `claude -p` scripts, other apps), so ncode keeps its own list and the sidebar shows
/// only these.
enum OwnedSessions {
    private static let key = "ncodeSessions"
    private static let seededKey = "ncodeSessionsSeeded"
    private static let lock = NSLock()

    static func all() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func add(_ id: String) { add([id]) }

    static func add(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        var known = Set(list), changed = false
        for id in ids where !id.isEmpty && !known.contains(id) { list.append(id); known.insert(id); changed = true }
        if changed { UserDefaults.standard.set(list, forKey: key) }
    }

    /// One-time upgrade from before ncode kept this list: adopt the chats in the added folders
    /// that ran headless (`claude -p`, entrypoint "sdk-cli"), which is how ncode runs `claude`.
    static func seedIfNeeded(paths: [String], accounts: [ClaudeAccount]) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        var ids: [String] = []
        for path in Set(paths) {
            for account in accounts {
                guard let dir = ProjectStore.transcriptDir(for: path, in: account.projectsDir) else { continue }
                let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "jsonl" }
                for f in files where ProjectStore.entrypoint(of: f) == "sdk-cli" {
                    ids.append(f.deletingPathExtension().lastPathComponent)
                }
            }
        }
        add(ids)
        UserDefaults.standard.set(true, forKey: seededKey)
    }
}

/// Reads Claude Code's own on-disk session store (~/.claude/projects) for the folders the user
/// added, and lists the chats ncode started there (see `OwnedSessions`).
enum ProjectStore {
    static var claudeDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }
    static var projectsDir: URL { claudeDir.appendingPathComponent("projects") }

    private static var titleCache: [String: (Date, String)] = [:]
    private static let cacheLock = NSLock()

    /// Same folder-name encoding the CLI uses for ~/.claude/projects/<encoded cwd>.
    static func encode(_ cwd: String) -> String {
        String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    /// Only the folders the user added. Each one lists the chats ncode started there (`owned`),
    /// from every account.
    static func scan(paths: [String], addedAt: [String: Double] = [:], accounts: [ClaudeAccount], owned: Set<String>) -> [Project] {
        let fm = FileManager.default
        var projects: [Project] = []
        for path in Set(paths) where fm.fileExists(atPath: path) {
            var metas: [SessionMeta] = [], dirs: [URL] = []
            for account in accounts {
                guard let dir = transcriptDir(for: path, in: account.projectsDir) else { continue }
                dirs.append(dir)
                let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
                    .filter { $0.pathExtension == "jsonl" }
                for f in files where owned.contains(f.deletingPathExtension().lastPathComponent) {
                    let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    if (vals?.fileSize ?? 0) < 200 { continue }
                    metas.append(SessionMeta(id: f.deletingPathExtension().lastPathComponent, title: "", modified: vals?.contentModificationDate ?? .distantPast, file: f, configDir: account.dir))
                }
            }
            metas.sort { $0.modified > $1.modified }
            let added = addedAt[path].map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let lastSession = metas.first?.modified ?? .distantPast
            projects.append(Project(cwd: path, transcriptDirs: dirs, sessions: metas,
                                    lastActivity: max(added, lastSession), pinned: true))
        }
        projects.sort { $0.lastActivity > $1.lastActivity }
        return projects
    }

    static func transcriptDir(for path: String, in projectsDir: URL) -> URL? {
        let fm = FileManager.default
        let encoded = encode(path)
        let direct = projectsDir.appendingPathComponent(encoded)
        if fm.fileExists(atPath: direct.path) { return direct }
        // Very long paths get shortened by the CLI; match on the prefix and confirm via the recorded cwd.
        guard encoded.count > 200 else { return nil }
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for d in dirs where d.lastPathComponent.hasPrefix(String(encoded.prefix(200))) {
            let f = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "jsonl" }
            if let f, readCwd([SessionMeta(id: "", title: "", modified: .distantPast, file: f)]) == path { return d }
        }
        return nil
    }

    /// The transcript directory name is a lossy encoding of the path; read the real cwd.
    static func readCwd(_ metas: [SessionMeta]) -> String? {
        for m in metas.prefix(3) {
            guard let h = try? FileHandle(forReadingFrom: m.file) else { continue }
            defer { try? h.close() }
            let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
            if let r = data.range(of: Data(#""cwd":""#.utf8)) {
                var end = r.upperBound
                while end < data.endIndex && data[end] != UInt8(ascii: "\"") { end += 1 }
                if let s = String(data: data[r.upperBound..<end], encoding: .utf8), !s.isEmpty { return s }
            }
        }
        return nil
    }

    /// Which program started the chat, as the CLI records it: "cli" (terminal), "sdk-cli" (`claude -p`), ...
    /// The key sits after the message body, so search the whole (memory-mapped) file, not a prefix:
    /// a first prompt with a pasted image can be megabytes long.
    static func entrypoint(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let r = data.range(of: Data(#""entrypoint":""#.utf8)) else { return nil }
        return jsonString(data, from: r.upperBound)
    }

    /// Title precedence mirrors the CLI: custom title > AI title > first prompt.
    static func title(for meta: SessionMeta) -> String {
        cacheLock.lock()
        if let (d, t) = titleCache[meta.file.path], d == meta.modified { cacheLock.unlock(); return t }
        cacheLock.unlock()
        let t = computeTitle(meta.file)
        cacheLock.lock(); titleCache[meta.file.path] = (meta.modified, t); cacheLock.unlock()
        return t
    }

    /// Only a title the user or Claude explicitly set (no first-prompt fallback).
    static func explicitTitle(file url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        for key in [#""customTitle":""#, #""aiTitle":""#] {
            if let r = data.range(of: Data(key.utf8), options: .backwards),
               let s = jsonString(data, from: r.upperBound), !s.isEmpty { return s }
        }
        return nil
    }

    private static func computeTitle(_ url: URL) -> String {
        if let t = explicitTitle(file: url) { return t }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return "Untitled" }
        // First real user prompt.
        var searchStart = data.startIndex
        let needle = Data(#""type":"user""#.utf8)
        var tries = 0
        while tries < 40, let r = data.range(of: needle, in: searchStart..<data.endIndex) {
            tries += 1
            searchStart = r.upperBound
            let lineStart = data[..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[r.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            guard let obj = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any] else { continue }
            if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { continue }
            guard let msg = obj["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = msg["content"] as? String { text = s }
            else if let arr = msg["content"] as? [[String: Any]] {
                text = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first ?? ""
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("<") { continue }
            return String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        }
        return "Untitled"
    }

    private static func jsonString(_ data: Data, from start: Data.Index) -> String? {
        var i = start
        var bytes = [UInt8(ascii: "\"")]
        while i < data.endIndex {
            let c = data[i]
            if c == UInt8(ascii: "\\") && i + 1 < data.endIndex { bytes.append(c); bytes.append(data[i + 1]); i += 2; continue }
            if c == UInt8(ascii: "\"") { break }
            bytes.append(c); i += 1
        }
        bytes.append(UInt8(ascii: "\""))
        return (try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed)) as? String
    }

    /// Find a session's transcript by id across all projects of all accounts.
    static func locate(sessionId: String, accounts: [ClaudeAccount]) -> (file: URL, cwd: String, configDir: String?)? {
        for account in accounts {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: account.projectsDir, includingPropertiesForKeys: nil)) ?? []
            for d in dirs {
                let f = d.appendingPathComponent("\(sessionId).jsonl")
                if FileManager.default.fileExists(atPath: f.path),
                   let cwd = readCwd([SessionMeta(id: sessionId, title: "", modified: .distantPast, file: f)]) { return (f, cwd, account.dir) }
            }
        }
        return nil
    }

    /// Keep big tool outputs from flooding the web view: long strings are cut, huge images dropped.
    private static func shrink(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            d.removeValue(forKey: "originalFile")
            for (k, x) in d {
                if k == "data", let s = x as? String { if s.count > 4_000_000 { d[k] = "" }; continue }
                d[k] = shrink(x)
            }
            return d
        }
        if let a = v as? [Any] { return a.map(shrink) }
        if let s = v as? String, s.count > 20_000 { return String(s.prefix(20_000)) + "\n… [truncated by ncode]" }
        return v
    }

    /// Transcript records worth rendering, as raw JSON lines (the renderer parses them).
    static func historyLines(file: URL, limit: Int = 2500) -> [String] {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return [] }
        var lines: [String] = []
        let keepTypes: Set<String> = ["user", "assistant", "system"]
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // Cheap prefilter before parsing.
            guard let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any],
                  let type = obj["type"] as? String, keepTypes.contains(type) else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            if type == "system" {
                let st = obj["subtype"] as? String ?? ""
                if !["compact_boundary", "local_command", "informational", "api_error"].contains(st) { continue }
            }
            if slice.count > 60_000, let small = try? JSONSerialization.data(withJSONObject: shrink(obj)),
               let s = String(data: small, encoding: .utf8) { lines.append(s); continue }
            if let s = String(data: slice, encoding: .utf8) { lines.append(s) }
        }
        if lines.count > limit { lines = Array(lines.suffix(limit)) }
        return lines
    }

    static func subagentLines(project: Project?, sessionId: String, agentId: String) -> [String] {
        let dirs = project?.transcriptDirs ?? []
        let candidates = dirs.map { $0.appendingPathComponent(sessionId).appendingPathComponent("subagents").appendingPathComponent("agent-\(agentId).jsonl") }
            + [projectsDir.appendingPathComponent(encode(project?.cwd ?? "")).appendingPathComponent(sessionId).appendingPathComponent("subagents").appendingPathComponent("agent-\(agentId).jsonl")]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            return data.split(separator: 0x0A).compactMap { slice in
                guard let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any],
                      let t = obj["type"] as? String, t == "user" || t == "assistant" else { return nil }
                return String(data: slice, encoding: .utf8)
            }
        }
        return []
    }
}
