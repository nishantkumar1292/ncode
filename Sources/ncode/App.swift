import SwiftUI
import AppKit
import WebKit
import UserNotifications

@main
struct NcodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("ncode", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.newChatInCurrentProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add Project…") { model.addProject() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Stop Response") { model.bridge.command("interrupt") }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Toggle Activity Panel") { model.bridge.command("toggleActivity") }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Focus Composer") { model.bridge.command("focus") }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Open in Terminal") { if let k = model.selectedKey { model.openInTerminal(k) } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Refresh Projects") { model.refreshProjects() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if AppModel.canNotify { UNUserNotificationCenter.current().delegate = self }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { AppModel.shared.shutdown() }
    func applicationDidBecomeActive(_ n: Notification) { AppModel.shared.refreshProjects(debounce: 0.2) }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if let key = r.notification.request.content.userInfo["key"] as? String {
            DispatchQueue.main.async { AppModel.shared.select(key); NSApp.activate(ignoringOtherApps: true) }
        }
        done()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ChatPane()
                .navigationTitle(currentTitle)
                .navigationSubtitle(currentSubtitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let key = model.selectedKey {
                            Button { model.bridge.command("toggleActivity") } label: {
                                Label("Activity", systemImage: "waveform.path.ecg")
                            }.help("Show running commands, subagents and context (⌘J)")
                            Menu {
                                Button("Open in Terminal") { model.openInTerminal(key) }
                                Button("Reveal Project in Finder") {
                                    if let s = model.session(key) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)]) }
                                }
                                Divider()
                                Button("End Session Process") { model.endSession(key) }
                                Button("Close Chat") { model.closeSession(key) }
                            } label: { Label("More", systemImage: "ellipsis.circle") }
                        }
                    }
                }
        }
    }

    private var currentTitle: String {
        guard let k = model.selectedKey, let s = model.session(k) else { return "ncode" }
        return s.title
    }
    private var currentSubtitle: String {
        guard let k = model.selectedKey, let s = model.session(k) else { return "" }
        return (s.cwd as NSString).abbreviatingWithTildeInPath
    }
}

struct ChatPane: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    func makeNSView(context: Context) -> WKWebView { model.bridge.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selectedKey }, set: { k in if let k { selectRow(k) } })) {
            Section {
                ForEach(model.projects) { project in
                    ProjectSection(project: project)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { model.addProject() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a project folder (⌘O)")
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.projects.isEmpty {
                VStack(spacing: 10) {
                    Text("No projects yet").foregroundStyle(.secondary)
                    Button("Add Project…") { model.addProject() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.envReady && model.claudePath == nil {
                Text("`claude` CLI not found. Set its path in Settings (⌘,).")
                    .font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    private func selectRow(_ key: String) {
        if key.hasPrefix("project:") { return }
        if model.session(key) != nil { model.select(key); return }
        for p in model.projects {
            if let meta = p.sessions.first(where: { $0.id == key }) { model.open(meta, in: p); return }
        }
    }
}

struct ProjectSection: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var showAll = false
    @State private var hovering = false

    private var isExpanded: Binding<Bool> {
        Binding(get: { model.expanded.contains(project.cwd) },
                set: { v in if v { model.expanded.insert(project.cwd) } else { model.expanded.remove(project.cwd) } })
    }

    /// Live sessions (including unsaved new chats) first, then saved transcripts.
    private var rows: [(key: String, title: String, date: Date)] {
        var seen = Set<String>()
        var out: [(String, String, Date)] = []
        let live = model.liveSessions.values.filter { $0.cwd == project.cwd && (!$0.hasTranscript || $0.isLive) }
            .sorted { $0.lastActivity > $1.lastActivity }
        for s in live { seen.insert(s.key); out.append((s.key, s.title, s.lastActivity)) }
        for m in project.sessions where !seen.contains(m.id) {
            let t = model.session(m.id)?.title ?? m.title
            out.append((m.id, t.isEmpty ? "Untitled" : t, m.modified))
        }
        return out
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            let all = rows
            let shown = showAll ? all : Array(all.prefix(8))
            ForEach(shown, id: \.key) { row in
                SessionRow(key: row.key, title: row.title, date: row.date).tag(row.key)
            }
            if all.count > 8 {
                Button(showAll ? "Show less" : "Show \(all.count - 8) more") { showAll.toggle() }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: project.pinned ? "folder.fill" : "folder")
                    .foregroundStyle(.secondary)
                Text(project.name).lineLimit(1)
                Spacer(minLength: 4)
                if hasActivity {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Button { model.newChat(in: project.cwd) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New chat in \(project.name)")
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(project.cwd)
            .contextMenu {
                Button("New Chat") { model.newChat(in: project.cwd) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.cwd)]) }
                Divider()
                Button("Remove from Sidebar") { model.hideProject(project.cwd) }
            }
        }
    }

    private var hasActivity: Bool {
        model.liveSessions.values.contains { $0.cwd == project.cwd && ($0.phase == .busy || !$0.pendingPrompts.isEmpty) }
    }
}

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let key: String
    let title: String
    let date: Date

    var body: some View {
        if let s = model.session(key) {
            LiveRow(session: s, key: key, fallbackTitle: title, date: date)
        } else {
            RowContent(key: key, title: title, date: date) { EmptyView() }
        }
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

struct RowContent<Indicator: View>: View {
    @EnvironmentObject var model: AppModel
    let key: String
    let title: String
    let date: Date
    @ViewBuilder var indicator: () -> Indicator

    var body: some View {
        HStack(spacing: 6) {
            indicator()
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Text(SessionRow.relative(date)).font(.caption2).foregroundStyle(.tertiary)
        }
        .contextMenu {
            Button("Open in Terminal") {
                if model.session(key) == nil,
                   let p = model.projects.first(where: { $0.sessions.contains { $0.id == key } }),
                   let m = p.sessions.first(where: { $0.id == key }) { model.open(m, in: p) }
                model.openInTerminal(key)
            }
            if model.session(key) != nil { Button("Close Chat") { model.closeSession(key) } }
        }
    }
}

struct LiveRow: View {
    @ObservedObject var session: Session
    let key: String
    let fallbackTitle: String
    let date: Date

    var body: some View {
        RowContent(key: key, title: session.title.isEmpty ? fallbackTitle : session.title, date: date) { indicator }
    }

    @ViewBuilder private var indicator: some View {
        if !session.pendingPrompts.isEmpty {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption)
                .help("Waiting for your approval")
        } else if session.phase == .busy || session.phase == .starting {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else if session.runningTasks > 0 {
            Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor).font(.caption)
                .help("\(session.runningTasks) background task(s) running")
        } else if session.isLive {
            Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6).frame(width: 12)
                .help("Session process running")
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("promptSuggestions") private var promptSuggestions = false

    var body: some View {
        Form {
            TextField("claude CLI path", text: $claudePath, prompt: Text(model.claudePath ?? "auto-detect"))
                .onSubmit { model.claudePath = ShellEnv.findClaude(env: model.env) }
            Toggle("Show projects in temporary folders", isOn: $model.showTemp)
            Toggle("Prompt suggestions (one extra model call per turn)", isOn: $promptSuggestions)
            Text("Detected: \(model.claudePath ?? "not found")").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }
}
