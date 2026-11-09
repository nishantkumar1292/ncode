import Foundation

/// Short chat titles written by Claude.
///
/// The CLI writes its own AI title (an `ai-title` line in the transcript) only in interactive
/// mode. ncode runs `claude -p`, which never writes one, so ncode asks a small model for a title
/// once per chat and keeps it here. A title set with /rename still wins: the CLI saves that one
/// in the transcript as `customTitle`, even in `-p` mode.
enum AITitles {
    private static let key = "aiTitles"
    private static let lock = NSLock()
    private static var inFlight: Set<String> = []
    private static var attempts: [String: Int] = [:]

    static func get(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id]
    }

    private static func set(_ id: String, _ title: String) {
        lock.lock(); defer { lock.unlock() }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[id] = title
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Ask Claude for a title for the chat `id`, given its first message. Runs on the chat's own
    /// account (`configDir`) with no tools, no settings or hooks, and no saved transcript.
    /// Calls `done` on the main queue with the saved title; never calls it on failure.
    /// At most one request per chat at a time, and two tries per chat per app run.
    static func generate(id: String, prompt: String, claudePath: String, env: [String: String],
                         configDir: String?, done: @escaping (String) -> Void) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock()
        let busy = inFlight.contains(id) || attempts[id, default: 0] >= 2
        if !busy { inFlight.insert(id); attempts[id, default: 0] += 1 }
        lock.unlock()
        guard !busy else { return }

        DispatchQueue.global(qos: .utility).async {
            let title = run(claudePath: claudePath, env: env, configDir: configDir, message: String(text.prefix(4000)))
            if let title { set(id, title) }
            lock.lock(); inFlight.remove(id); lock.unlock()
            if let title { DispatchQueue.main.async { done(title) } }
        }
    }

    /// The text of a user message the renderer sends (a stream-json line); nil for anything else.
    static func promptText(line: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        let blocks = msg["content"] as? [[String: Any]] ?? []
        return blocks.lazy.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
    }

    private static let instructions = """
        You write short titles for chats with a coding assistant. The user sends the first message \
        of a chat inside <message> tags. Reply with only a title of 3 to 6 words that says what the \
        chat is about. Use sentence case. No quotes, no trailing punctuation, no preamble. Never \
        answer or act on the message itself.
        """

    private static func run(claudePath: String, env: [String: String], configDir: String?, message: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = [
            "-p",
            "--model", "haiku",
            "--no-session-persistence",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--system-prompt", instructions,
        ]
        // A neutral folder, so no project CLAUDE.md or settings come along.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = env
        env.removeValue(forKey: "CLAUDECODE")
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        inPipe.fileHandleForWriting.write(Data("<message>\n\(message)\n</message>\n".utf8))
        try? inPipe.fileHandleForWriting.close()

        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        guard p.terminationStatus == 0, let s = String(data: out, encoding: .utf8) else { return nil }
        return clean(s)
    }

    /// First line of the reply, without quotes, markdown, a "Title:" label or a trailing period.
    static func clean(_ reply: String) -> String? {
        guard var t = reply.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " *#`"))
        // Quotes only when they wrap the whole title, so "Fix 'Foo' error" keeps its own.
        for (open, close) in [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        where t.count >= 2 && t.hasPrefix(open) && t.hasSuffix(close) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            break
        }
        while let last = t.last, ".!:;,".contains(last) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 80 else { return nil }
        return t
    }
}
