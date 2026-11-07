import Foundation
import AppKit
import UserNotifications

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var projects: [Project] = []
    @Published var selectedKey: String?
    @Published var liveSessions: [String: Session] = [:]
    @Published var claudePath: String?
    @Published var envReady = false
    @Published var showTemp = UserDefaults.standard.bool(forKey: "showTemp") {
        didSet { UserDefaults.standard.set(showTemp, forKey: "showTemp"); refreshProjects() }
    }
    @Published var expanded: Set<String> = []

    private(set) var env: [String: String] = ProcessInfo.processInfo.environment
    let bridge = Bridge()
    private var refreshWork: DispatchWorkItem?

    private var extraPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraProjects") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraProjects") }
    }
    private var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenProjects") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenProjects") }
    }

    init() {
        bridge.model = self
        DispatchQueue.global(qos: .userInitiated).async {
            let env = ShellEnv.load()
            let path = ShellEnv.findClaude(env: env)
            DispatchQueue.main.async {
                self.env = env
                self.claudePath = path
                self.envReady = true
                self.bridge.sendConfig()
                let waiting = self.envWaiters
                self.envWaiters = []
                waiting.forEach { $0() }
            }
        }
        refreshProjects()
        DispatchQueue.main.async { self.handleLaunchArguments() }
        // Stop chat processes that have sat idle; they resume transparently on the next message.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.reapIdle() }
        if Self.canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    private var envWaiters: [() -> Void] = []

    /// Run once the login-shell environment (and `claude` path) is known.
    func afterEnv(_ f: @escaping () -> Void) {
        if envReady { f() } else { envWaiters.append(f) }
    }

    private func reapIdle() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        for s in liveSessions.values where s.phase == .idle && s.pendingPrompts.isEmpty && s.runningTasks == 0 && s.lastActivity < cutoff {
            s.stop()
        }
    }

    /// `ncode [folder] [--resume id] [--prompt text] [--model name] [--mode permissionMode]`
    private func handleLaunchArguments() {
        let args = Array(CommandLine.arguments.dropFirst())
        var folder: String?, prompt: String?, model: String?, mode: String?, resume: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            let value: String? = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--prompt": prompt = value; i += 1
            case "--resume": resume = value; i += 1
            case "--model": model = value; i += 1
            case "--mode", "--permission-mode": mode = value; i += 1
            default:
                if a.hasPrefix("-") { i += 1 }   // skip system flags like -NSDocumentRevisionsDebugMode YES
                else if folder == nil { folder = a }
            }
            i += 1
        }
        if let resume, let found = ProjectStore.locate(sessionId: resume) {
            let s = liveSessions[resume] ?? makeSession(key: resume, cwd: found.cwd, title: ProjectStore.title(for: SessionMeta(id: resume, title: "", modified: .distantPast, file: found.file)), hasTranscript: true)
            s.transcriptFile = found.file
            expanded.insert(found.cwd)
            select(resume)
            if prompt != nil || model != nil || mode != nil { bridge.launch(key: resume, prompt: prompt, model: model, mode: mode) }
            return
        }
        guard let folder else { return }
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        if !extraPaths.contains(path) { extraPaths.append(path) }
        refreshProjects()
        newChat(in: path)
        if let key = selectedKey, prompt != nil || model != nil || mode != nil {
            bridge.launch(key: key, prompt: prompt, model: model, mode: mode)
        }
    }

    // MARK: - Projects

    func refreshProjects(debounce: Double = 0) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let extra = self.extraPaths, hidden = self.hidden, temp = self.showTemp
            DispatchQueue.global(qos: .userInitiated).async {
                var list = ProjectStore.scan(extraPaths: extra, hidden: hidden, showTemp: temp)
                // Titles only for the sessions we will show.
                for i in list.indices {
                    for j in list[i].sessions.indices.prefix(30) {
                        list[i].sessions[j].title = ProjectStore.title(for: list[i].sessions[j])
                    }
                }
                DispatchQueue.main.async {
                    self.projects = list
                    if self.expanded.isEmpty, let first = list.first { self.expanded.insert(first.cwd) }
                }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if !extraPaths.contains(path) { extraPaths.append(path) }
        var h = hidden; h.remove(path); hidden = h
        expanded.insert(path)
        refreshProjects()
        newChat(in: path)
    }

    func hideProject(_ cwd: String) {
        var h = hidden; h.insert(cwd); hidden = h
        extraPaths.removeAll { $0 == cwd }
        refreshProjects()
    }

    func project(for cwd: String) -> Project? { projects.first { $0.cwd == cwd } }

    // MARK: - Sessions

    func newChat(in cwd: String) {
        let key = UUID().uuidString.lowercased()
        let s = makeSession(key: key, cwd: cwd, title: "New chat", hasTranscript: false)
        s.historyLoaded = true
        expanded.insert(cwd)
        select(s.key)
    }

    func newChatInCurrentProject() {
        if let key = selectedKey, let s = liveSessions[key] { newChat(in: s.cwd) }
        else if let p = projects.first { newChat(in: p.cwd) }
        else { addProject() }
    }

    func open(_ meta: SessionMeta, in project: Project) {
        if liveSessions[meta.id] == nil {
            _ = makeSession(key: meta.id, cwd: project.cwd, title: meta.title, hasTranscript: true)
        }
        select(meta.id)
    }

    @discardableResult
    private func makeSession(key: String, cwd: String, title: String, hasTranscript: Bool) -> Session {
        let s = Session(key: key, cwd: cwd, title: title, hasTranscript: hasTranscript)
        s.onLine = { [weak self] sess, line in self?.bridge.event(key: sess.key, line: line) }
        s.onAttention = { [weak self] sess, reason in self?.attention(sess, reason) }
        liveSessions[key] = s
        return s
    }

    func select(_ key: String) {
        selectedKey = key
        guard let s = liveSessions[key] else { return }
        bridge.open(session: s)
        if !s.historyLoaded {
            s.historyLoaded = true
            let file = s.transcriptFile ?? project(for: s.cwd)?.sessions.first { $0.id == key }?.file
                ?? ProjectStore.projectsDir.appendingPathComponent(ProjectStore.encode(s.cwd)).appendingPathComponent("\(key).jsonl")
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = ProjectStore.historyLines(file: file)
                DispatchQueue.main.async { self.bridge.history(key: key, lines: lines) }
            }
        }
        bridge.select(key: key)
        updateBadge()
    }

    func session(_ key: String) -> Session? { liveSessions[key] }

    func ensureStarted(_ s: Session, options: [String: Any]) -> Bool {
        if s.isLive { return true }
        guard let path = claudePath else {
            bridge.toast("Couldn't find the `claude` CLI. Install Claude Code or set its path in Settings.")
            return false
        }
        s.start(claudePath: path, env: env, options: options)
        return true
    }

    func endSession(_ key: String) {
        liveSessions[key]?.stop()
    }

    func closeSession(_ key: String) {
        guard let s = liveSessions[key] else { return }
        s.stop()
        liveSessions.removeValue(forKey: key)
        bridge.drop(key: key)
        if selectedKey == key { selectedKey = nil; bridge.select(key: nil) }
        refreshProjects(debounce: 0.5)
    }

    func shutdown() {
        liveSessions.values.forEach { $0.kill() }
    }

    // MARK: - Attention

    private func attention(_ s: Session, _ reason: String) {
        updateBadge()
        if reason == "done" {
            refreshProjects(debounce: 1.0)
            refreshTitle(s)
        }
        let frontAndSelected = NSApp.isActive && selectedKey == s.key
        guard !frontAndSelected, Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = s.title.isEmpty ? (s.cwd as NSString).lastPathComponent : s.title
        content.body = reason == "permission" ? "Claude needs your permission to continue." : "Claude finished responding."
        content.userInfo = ["key": s.key]
        let req = UNNotificationRequest(identifier: "\(s.key)-\(reason)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Pick up the title Claude generates for the session (or one set with /rename).
    private func refreshTitle(_ s: Session) {
        let file = ProjectStore.projectsDir.appendingPathComponent(ProjectStore.encode(s.cwd)).appendingPathComponent("\(s.sessionId).jsonl")
        let candidates = [file] + (project(for: s.cwd)?.transcriptDirs.map { $0.appendingPathComponent("\(s.sessionId).jsonl") } ?? [])
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            for f in candidates {
                if let t = ProjectStore.explicitTitle(file: f) {
                    DispatchQueue.main.async { if s.title != t { s.title = t } }
                    return
                }
            }
        }
    }

    func updateBadge() {
        let n = liveSessions.values.reduce(0) { $0 + $1.pendingPrompts.count }
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    /// Notifications need a real .app bundle; `swift run` has none.
    static let canNotify = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    // MARK: - Utilities

    func openInTerminal(_ key: String) {
        guard let s = liveSessions[key] else { return }
        let claude = claudePath ?? "claude"
        let resume = s.hasTranscript ? " --resume \(s.sessionId)" : ""
        let script = "#!/bin/zsh -l\ncd \(shellQuote(s.cwd)) && \(shellQuote(claude))\(resume)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ncode-\(s.key.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { bridge.toast("Couldn't open Terminal: \(error.localizedDescription)") }
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
