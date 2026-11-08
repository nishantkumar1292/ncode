import Foundation
import Combine

/// One Claude Code conversation. Owns (lazily) a `claude -p` child process speaking the
/// stream-json protocol. Swift is a thin pipe: raw JSON lines go to the web renderer,
/// which owns the protocol logic. Swift only peeks at a few fields for sidebar state.
final class Session: ObservableObject, Identifiable {
    enum Phase: Equatable { case dormant, starting, idle, busy, exited(Int32) }

    let key: String            // stable UI key == session id we asked the CLI to use
    let cwd: String
    @Published var title: String
    @Published var phase: Phase = .dormant
    @Published var pendingPrompts: Set<String> = []   // control_request ids awaiting the user
    @Published var runningTasks: Int = 0
    @Published var lastActivity = Date()

    var sessionId: String
    /// True if this session already has a transcript on disk (resume instead of new).
    var hasTranscript: Bool
    var historyLoaded = false
    var transcriptFile: URL?
    /// Claude config dir (account) this chat runs on; nil = the default account.
    var configDir: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private let ioQueue: DispatchQueue
    private var writeBacklog: [String] = []
    private var launchOptions: [String: Any] = [:]

    var onLine: ((Session, String) -> Void)?
    var onAttention: ((Session, String) -> Void)?   // reason: "permission" | "done"

    var id: String { key }
    var isLive: Bool { if case .dormant = phase { return false }; if case .exited = phase { return false }; return true }

    init(key: String, cwd: String, title: String, hasTranscript: Bool) {
        self.key = key
        self.sessionId = key
        self.cwd = cwd
        self.title = title
        self.hasTranscript = hasTranscript
        self.ioQueue = DispatchQueue(label: "ncode.session.\(key)")
    }

    // MARK: - Process lifecycle

    func start(claudePath: String, env: [String: String], options: [String: Any]) {
        guard process == nil else { return }
        launchOptions = options
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--forward-subagent-text",
            "--permission-prompt-tool", "stdio",
            "--thinking-display", "summarized",
            "--replay-user-messages",
        ]
        if hasTranscript { args += ["--resume", sessionId] } else { args += ["--session-id", sessionId] }
        if let m = options["model"] as? String, !m.isEmpty { args += ["--model", m] }
        if let pm = options["permissionMode"] as? String, !pm.isEmpty { args += ["--permission-mode", pm] }
        // Only makes "Bypass permissions" selectable from the mode menu; the session still starts in the mode above.
        args += ["--allow-dangerously-skip-permissions"]
        if let e = options["effort"] as? String, !e.isEmpty { args += ["--effort", e] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = env
        env.removeValue(forKey: "CLAUDECODE")
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.ioQueue.async { self.consume(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8) {
                self.ioQueue.async {
                    self.stderrTail = String((self.stderrTail + s).suffix(4000))
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.ioQueue.async {
                let tail = self.stderrTail
                let code = proc.terminationStatus
                DispatchQueue.main.async {
                    self.process = nil
                    self.stdinHandle = nil
                    self.phase = .exited(code)
                    self.pendingPrompts.removeAll()
                    self.runningTasks = 0
                    self.hasTranscript = true
                    let payload: [String: Any] = ["type": "ncode_exit", "code": Int(code), "stderr": tail]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let line = String(data: data, encoding: .utf8) {
                        self.onLine?(self, line)
                    }
                }
            }
        }

        do {
            try p.run()
        } catch {
            phase = .exited(-1)
            let payload: [String: Any] = ["type": "ncode_exit", "code": -1, "stderr": "Could not launch claude at \(claudePath): \(error.localizedDescription)"]
            if let data = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: data, encoding: .utf8) {
                onLine?(self, line)
            }
            return
        }
        process = p
        phase = .starting
        // Handshake: the response carries slash commands, models, account info.
        let suggest = UserDefaults.standard.bool(forKey: "promptSuggestions")
        rawWrite(#"{"type":"control_request","request_id":"init","request":{"subtype":"initialize","promptSuggestions":"# + (suggest ? "true" : "false") + "}}")
        let backlog = writeBacklog
        writeBacklog = []
        backlog.forEach { rawWrite($0) }
    }

    func stop() {
        guard let p = process else { return }
        try? stdinHandle?.close()
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
    }

    func kill() {
        process?.terminate()
    }

    // MARK: - IO

    /// Write a raw stream-json line coming from the renderer.
    func write(_ line: String) {
        inspectOutgoing(line)
        if process == nil { writeBacklog.append(line); return }
        rawWrite(line)
    }

    private func rawWrite(_ line: String) {
        guard let h = stdinHandle else { return }
        var s = line
        if !s.hasSuffix("\n") { s += "\n" }
        if let d = s.data(using: .utf8) {
            do { try h.write(contentsOf: d) } catch { /* process gone; termination handler reports */ }
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            let peek = Self.peek(lineData)
            DispatchQueue.main.async { self.handleIncoming(line, peek) }
        }
    }

    struct Peek { var type = ""; var subtype = ""; var requestId = ""; var sessionId = ""; var hasParent = false }

    static func peek(_ data: Data) -> Peek {
        var p = Peek()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return p }
        p.type = obj["type"] as? String ?? ""
        p.subtype = obj["subtype"] as? String ?? ""
        p.sessionId = obj["session_id"] as? String ?? ""
        p.hasParent = obj["parent_tool_use_id"] is String
        if p.type == "control_request" {
            p.requestId = obj["request_id"] as? String ?? ""
            p.subtype = (obj["request"] as? [String: Any])?["subtype"] as? String ?? ""
        } else if p.type == "control_cancel_request" {
            p.requestId = obj["request_id"] as? String ?? ""
        } else if p.type == "system" && p.subtype == "background_tasks_changed" {
            p.requestId = String((obj["tasks"] as? [Any])?.count ?? 0)
        }
        return p
    }

    private func handleIncoming(_ line: String, _ peek: Peek) {
        lastActivity = Date()
        switch peek.type {
        case "system":
            if peek.subtype == "init" {
                // The CLI can move a chat to a new id (e.g. /clear); keep that one listed too.
                if !peek.sessionId.isEmpty { sessionId = peek.sessionId; OwnedSessions.add(peek.sessionId) }
                if phase == .starting { phase = .idle }
            } else if peek.subtype == "background_tasks_changed" {
                runningTasks = Int(peek.requestId) ?? 0
            }
        case "control_response":
            if phase == .starting { phase = .idle }
        case "stream_event", "assistant":
            if !peek.hasParent { phase = .busy }
        case "control_request":
            if ["can_use_tool", "elicitation", "request_user_dialog"].contains(peek.subtype) {
                pendingPrompts.insert(peek.requestId)
                onAttention?(self, "permission")
            }
        case "control_cancel_request":
            pendingPrompts.remove(peek.requestId)
        case "result":
            phase = .idle
            hasTranscript = true
            onAttention?(self, "done")
        default: break
        }
        onLine?(self, line)
    }

    private func inspectOutgoing(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if type == "user" {
            let shouldQuery = obj["shouldQuery"] as? Bool ?? true
            if shouldQuery { phase = .busy }
            lastActivity = Date()
        } else if type == "control_response",
                  let r = obj["response"] as? [String: Any], let rid = r["request_id"] as? String {
            pendingPrompts.remove(rid)
        }
    }
}
