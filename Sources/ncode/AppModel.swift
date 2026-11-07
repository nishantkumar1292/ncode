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
    @Published var expanded: Set<String> = []
    @Published var accounts: [ClaudeAccount] = Accounts.discover(extra: UserDefaults.standard.stringArray(forKey: "extraConfigDirs") ?? [])

    private(set) var env: [String: String] = ProcessInfo.processInfo.environment
    let bridge = Bridge()
    private var refreshWork: DispatchWorkItem?

    private var extraPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraProjects") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraProjects") }
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
        // Warm the project finder so ⌘O opens instantly.
        let accts = accounts
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { _ = ProjectFinder.candidates(added: [], accounts: accts) }
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
        if let resume, let found = ProjectStore.locate(sessionId: resume, accounts: accounts) {
            let s = liveSessions[resume] ?? makeSession(key: resume, cwd: found.cwd, title: ProjectStore.title(for: SessionMeta(id: resume, title: "", modified: .distantPast, file: found.file)), hasTranscript: true, configDir: found.configDir)
            s.transcriptFile = found.file
            if !extraPaths.contains(found.cwd) { extraPaths.append(found.cwd); refreshProjects() }
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
            let paths = self.extraPaths, added = self.addedAt, accounts = self.accounts
            DispatchQueue.global(qos: .userInitiated).async {
                var list = ProjectStore.scan(paths: paths, addedAt: added, accounts: accounts)
                let saved = UserDefaults.standard.dictionary(forKey: "projectAccount") as? [String: String] ?? [:]
                var detected: [String: String] = [:]
                for i in list.indices {
                    if let s = saved[list[i].cwd] { list[i].accountDir = s.isEmpty ? nil : s }
                    else {
                        let d = Accounts.detect(for: list[i].cwd, among: accounts)?.dir
                        list[i].accountDir = d; detected[list[i].cwd] = d ?? ""
                    }
                }
                // Titles only for the sessions we will show.
                for i in list.indices {
                    for j in list[i].sessions.indices.prefix(30) {
                        list[i].sessions[j].title = ProjectStore.title(for: list[i].sessions[j])
                    }
                }
                DispatchQueue.main.async {
                    if !detected.isEmpty { var map = self.projectAccounts; map.merge(detected) { old, _ in old }; self.projectAccounts = map }
                    self.projects = list
                    if self.expanded.isEmpty, let first = list.first { self.expanded.insert(first.cwd) }
                }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// ⌘O, sidebar "+", welcome button: open the project finder in the chat pane.
    func addProject() {
        bridge.webView.window?.makeFirstResponder(bridge.webView)
        bridge.command("projectFinder")
    }

    /// Add a folder to the sidebar (no dialog). Starts a new chat in it unless `openChat` is false.
    func addProject(at rawPath: String, openChat: Bool = true, account accountDir: String? = nil) {
        let path = URL(fileURLWithPath: ProjectFinder.expand(rawPath)).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            bridge.toast("No folder at \(ProjectFinder.abbreviate(path))")
            return
        }
        if !extraPaths.contains(path) { extraPaths.append(path) }
        if let accountDir { var map = projectAccounts; map[path] = accountDir; projectAccounts = map }
        var added = addedAt; added[path] = Date().timeIntervalSince1970; addedAt = added
        expanded.insert(path)
        refreshProjects()
        if openChat {
            if let live = liveSessions.values.first(where: { $0.cwd == path && !$0.hasTranscript }) { select(live.key) }
            else { newChat(in: path) }
            bridge.command("focus")
        }
    }

    /// Fallback: the system folder dialog, attached to the window and opened somewhere useful.
    func browseForProject(startingAt hint: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose one or more project folders"
        let start = hint.map(ProjectFinder.expand) ?? extraPaths.last.map { ($0 as NSString).deletingLastPathComponent }
        if let start, FileManager.default.fileExists(atPath: start) { panel.directoryURL = URL(fileURLWithPath: start) }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let self else { return }
            for (i, url) in panel.urls.enumerated() { self.addProject(at: url.path, openChat: i == panel.urls.count - 1) }
        }
        if let w = bridge.webView.window { panel.beginSheetModal(for: w, completionHandler: done) }
        else { done(panel.runModal()) }
    }

    // MARK: - Accounts (Claude config dirs)

    /// Project path → config dir ("" = default account).
    private var projectAccounts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "projectAccount") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "projectAccount") }
    }

    func accountFor(dir: String?) -> ClaudeAccount {
        accounts.first { $0.dir == dir } ?? Accounts.identity(ClaudeAccount(dir: dir))
    }

    /// The account new chats in this project use: the user's choice, else the one used most recently.
    func account(forProject path: String) -> ClaudeAccount {
        if let saved = projectAccounts[path] { return accountFor(dir: saved.isEmpty ? nil : saved) }
        let detected = Accounts.detect(for: path, among: accounts) ?? accountFor(dir: nil)
        var map = projectAccounts; map[path] = detected.dir ?? ""; projectAccounts = map
        return detected
    }

    /// Switch a project's account. A chat can't move between accounts, so if the current chat has
    /// already started, this opens a new chat on the new account.
    func setAccount(_ a: ClaudeAccount, forProject path: String) {
        var map = projectAccounts; map[path] = a.dir ?? ""; projectAccounts = map
        if let i = projects.firstIndex(where: { $0.cwd == path }) { projects[i].accountDir = a.dir }
        if let k = selectedKey, let s = liveSessions[k], s.cwd == path {
            if !s.isLive && !s.hasTranscript { s.configDir = a.dir; bridge.open(session: s); bridge.toast("This chat will use \(a.title)") }
            else if s.configDir != a.dir { newChat(in: path); bridge.toast("New chat on \(a.title)") }
        }
    }

    func addAccountFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Choose a Claude config folder (the folder you point CLAUDE_CONFIG_DIR at)"
        panel.prompt = "Add Account"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var extra = UserDefaults.standard.stringArray(forKey: "extraConfigDirs") ?? []
        if !extra.contains(url.path) { extra.append(url.path) }
        UserDefaults.standard.set(extra, forKey: "extraConfigDirs")
        accounts = Accounts.discover(extra: extra)
        bridge.sendConfig()
        if !accounts.contains(where: { $0.dir == url.path }) { bridge.toast("No Claude config (.claude.json) found in that folder") }
    }

    private var addedAt: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "projectAddedAt") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "projectAddedAt") }
    }

    var addedPaths: Set<String> { Set(extraPaths) }

    func hideProject(_ cwd: String) {
        for s in liveSessions.values where s.cwd == cwd { closeSession(s.key) }
        extraPaths.removeAll { $0 == cwd }
        refreshProjects()
    }

    func project(for cwd: String) -> Project? { projects.first { $0.cwd == cwd } }

    // MARK: - Sessions

    func newChat(in cwd: String) {
        let key = UUID().uuidString.lowercased()
        let s = makeSession(key: key, cwd: cwd, title: "New chat", hasTranscript: false, configDir: account(forProject: cwd).dir)
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
            let s = makeSession(key: meta.id, cwd: project.cwd, title: meta.title, hasTranscript: true, configDir: meta.configDir)
            s.transcriptFile = meta.file
        }
        select(meta.id)
    }

    @discardableResult
    private func makeSession(key: String, cwd: String, title: String, hasTranscript: Bool, configDir: String? = nil) -> Session {
        let s = Session(key: key, cwd: cwd, title: title, hasTranscript: hasTranscript)
        s.configDir = configDir
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
                ?? self.accountFor(dir: s.configDir).projectsDir.appendingPathComponent(ProjectStore.encode(s.cwd)).appendingPathComponent("\(key).jsonl")
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
        let file = accountFor(dir: s.configDir).projectsDir.appendingPathComponent(ProjectStore.encode(s.cwd)).appendingPathComponent("\(s.sessionId).jsonl")
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
        let account = s.configDir.map { "export CLAUDE_CONFIG_DIR=\(shellQuote($0))\n" } ?? ""
        let script = "#!/bin/zsh -l\n\(account)cd \(shellQuote(s.cwd)) && \(shellQuote(claude))\(resume)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ncode-\(s.key.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { bridge.toast("Couldn't open Terminal: \(error.localizedDescription)") }
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
