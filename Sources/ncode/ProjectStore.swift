import Foundation

struct SessionMeta: Identifiable, Hashable {
    let id: String          // session id (transcript file name)
    var title: String
    var modified: Date
    let file: URL
}

struct Project: Identifiable, Hashable {
    var id: String { cwd }
    let cwd: String
    var name: String { (cwd as NSString).lastPathComponent }
    var transcriptDirs: [URL]
    var sessions: [SessionMeta]
    var lastActivity: Date
    var pinned: Bool
}

/// Reads Claude Code's own on-disk session store (~/.claude/projects), so the sidebar
/// shows exactly the projects and sessions the CLI knows about.
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

    static func encode(_ cwd: String) -> String {
        String(cwd.map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func scan(extraPaths: [String], hidden: Set<String>, showTemp: Bool) -> [Project] {
        let fm = FileManager.default
        var byCwd: [String: Project] = [:]
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            guard !files.isEmpty else { continue }
            var metas: [SessionMeta] = []
            for f in files {
                let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let size = vals?.fileSize ?? 0
                if size < 200 { continue }
                let mod = vals?.contentModificationDate ?? .distantPast
                metas.append(SessionMeta(id: f.deletingPathExtension().lastPathComponent, title: "", modified: mod, file: f))
            }
            guard !metas.isEmpty else { continue }
            metas.sort { $0.modified > $1.modified }
            guard let cwd = readCwd(metas) else { continue }
            if !showTemp && isTemp(cwd) { continue }
            if var existing = byCwd[cwd] {
                existing.sessions += metas
                existing.sessions.sort { $0.modified > $1.modified }
                existing.transcriptDirs.append(dir)
                existing.lastActivity = max(existing.lastActivity, metas[0].modified)
                byCwd[cwd] = existing
            } else {
                byCwd[cwd] = Project(cwd: cwd, transcriptDirs: [dir], sessions: metas, lastActivity: metas[0].modified, pinned: false)
            }
        }
        for path in extraPaths where byCwd[path] == nil {
            let mod = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            byCwd[path] = Project(cwd: path, transcriptDirs: [], sessions: [], lastActivity: mod, pinned: true)
        }
        for path in extraPaths { byCwd[path]?.pinned = true }
        var projects = byCwd.values.filter { !hidden.contains($0.cwd) && FileManager.default.fileExists(atPath: $0.cwd) }
        projects.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.lastActivity > b.lastActivity
        }
        return projects
    }

    static func isTemp(_ p: String) -> Bool {
        p.hasPrefix("/private/tmp") || p.hasPrefix("/tmp") || p.hasPrefix("/private/var/folders") || p.hasPrefix("/var/folders")
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

    /// Find a session's transcript by id across all projects.
    static func locate(sessionId: String) -> (file: URL, cwd: String)? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let f = d.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: f.path),
               let cwd = readCwd([SessionMeta(id: sessionId, title: "", modified: .distantPast, file: f)]) { return (f, cwd) }
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
