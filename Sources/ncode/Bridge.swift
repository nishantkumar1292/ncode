import Foundation
import AppKit
import WebKit
import UniformTypeIdentifiers

/// The chat pane is a single WKWebView. Swift pushes raw stream-json lines into it and
/// answers a small set of requests (files, shell, clipboard, URLs).
final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    weak var model: AppModel?
    private(set) var webView: DropWebView!
    private var ready = false
    private var outbox: [String] = []
    private var flushScheduled = false

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: "ncode")
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let wv = DropWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        wv.allowsMagnification = true
        wv.onDrop = { [weak self] urls in self?.dropped(urls) }
        webView = wv
        wv.load(URLRequest(url: URL(string: "ncode://app/index.html")!))
    }

    // MARK: - Swift → JS

    private func post(_ json: String) {
        outbox.append(json)
        guard ready, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { self.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard ready, !outbox.isEmpty else { return }
        let batch = outbox
        outbox.removeAll(keepingCapacity: true)
        webView.evaluateJavaScript("window.__recv([" + batch.joined(separator: ",") + "])") { _, err in
            if let err { NSLog("ncode bridge error: \(err)") }
        }
    }

    private func postObj(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        post(s)
    }

    func event(key: String, line: String) {
        post(#"{"t":"ev","k":"# + jsonQuote(key) + #","e":"# + line + "}")
    }

    func history(key: String, lines: [String]) {
        post(#"{"t":"history","k":"# + jsonQuote(key) + #","lines":["# + lines.joined(separator: ",") + "]}")
    }

    func open(session s: Session) {
        postObj(["t": "open", "k": s.key, "cwd": s.cwd, "title": s.title, "resumable": s.hasTranscript, "live": s.isLive])
    }

    func select(key: String?) { postObj(["t": "select", "k": key ?? NSNull()]) }
    func drop(key: String) { postObj(["t": "drop", "k": key]) }
    func launch(key: String, prompt: String?, model: String?, mode: String?) {
        postObj(["t": "launch", "k": key, "prompt": prompt ?? NSNull(), "model": model ?? NSNull(), "mode": mode ?? NSNull()])
    }
    func toast(_ text: String) { postObj(["t": "toast", "text": text]) }
    func command(_ name: String) { postObj(["t": "cmd", "name": name]) }

    func sendConfig() {
        guard let m = model else { return }
        postObj(["t": "config", "claude": m.claudePath ?? NSNull(), "home": NSHomeDirectory(), "envReady": m.envReady])
    }

    private func jsonQuote(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s])
        let arr = String(data: d, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - JS → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String, let m = model else {
            replyHandler(nil, "bad message"); return
        }
        let key = body["k"] as? String ?? ""
        switch op {
        case "ready":
            ready = true
            sendConfig()
            if let k = m.selectedKey, let s = m.session(k) { open(session: s); select(key: k) }
            flush()
            replyHandler(true, nil)

        case "write":
            guard let s = m.session(key), let line = body["line"] as? String else { replyHandler(false, "no session"); return }
            let opts = body["opts"] as? [String: Any] ?? [:]
            m.afterEnv {
                guard m.ensureStarted(s, options: opts) else { replyHandler(false, nil); return }
                s.write(line)
                replyHandler(true, nil)
            }

        case "start":
            guard let s = m.session(key) else { replyHandler(false, "no session"); return }
            m.afterEnv { replyHandler(m.ensureStarted(s, options: body["opts"] as? [String: Any] ?? [:]), nil) }

        case "files":
            guard let s = m.session(key) else { replyHandler([], nil); return }
            FileIndex.shared.files(in: s.cwd) { replyHandler($0, nil) }

        case "end":
            m.endSession(key); replyHandler(true, nil)

        case "close":
            m.closeSession(key); replyHandler(true, nil)

        case "addProject":
            m.addProject(); replyHandler(true, nil)

        case "projectCandidates":
            let added = m.addedPaths
            DispatchQueue.global(qos: .userInitiated).async {
                let list = ProjectFinder.candidates(added: added)
                DispatchQueue.main.async { replyHandler(list, nil) }
            }

        case "listDir":
            let dir = body["dir"] as? String ?? "~"
            DispatchQueue.global(qos: .userInitiated).async {
                let r = ProjectFinder.listDir(dir)
                DispatchQueue.main.async { replyHandler(r, nil) }
            }

        case "addProjectPath":
            m.addProject(at: body["path"] as? String ?? "", openChat: body["chat"] as? Bool ?? true)
            replyHandler(true, nil)

        case "browseProject":
            m.browseForProject(startingAt: body["dir"] as? String)
            replyHandler(true, nil)

        case "newChat":
            if let s = m.session(key) { m.newChat(in: s.cwd) } else { m.newChatInCurrentProject() }
            replyHandler(true, nil)

        case "title":
            if let s = m.session(key), let t = body["title"] as? String, !t.isEmpty { s.title = t }
            replyHandler(true, nil)

        case "openURL":
            if let u = body["url"] as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            replyHandler(true, nil)

        case "openPath":
            if let p = body["path"] as? String {
                let url = URL(fileURLWithPath: resolve(p, key: key))
                if body["reveal"] as? Bool == true { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSWorkspace.shared.open(url) }
            }
            replyHandler(true, nil)

        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
            replyHandler(true, nil)

        case "terminal":
            m.openInTerminal(key); replyHandler(true, nil)

        case "pickFiles":
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            if let s = m.session(key) { panel.directoryURL = URL(fileURLWithPath: s.cwd) }
            guard panel.runModal() == .OK else { replyHandler([], nil); return }
            replyHandler(panel.urls.map(describeFile), nil)

        case "subagent":
            let agentId = body["agentId"] as? String ?? ""
            let s = m.session(key)
            let proj = s.flatMap { m.project(for: $0.cwd) }
            let sid = s?.sessionId ?? key
            DispatchQueue.global().async {
                let lines = ProjectStore.subagentLines(project: proj, sessionId: sid, agentId: agentId)
                DispatchQueue.main.async { replyHandler(lines, nil) }
            }

        case "shell":
            guard let s = m.session(key), let cmd = body["cmd"] as? String else { replyHandler(nil, "no session"); return }
            runShell(cmd, cwd: s.cwd, env: m.env, reply: replyHandler)

        case "readImage":
            let p = resolve(body["path"] as? String ?? "", key: key)
            replyHandler(describeFile(URL(fileURLWithPath: p)), nil)

        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }

    private func resolve(_ p: String, key: String) -> String {
        var path = (p as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let s = model?.session(key) { path = (s.cwd as NSString).appendingPathComponent(path) }
        return path
    }

    private func describeFile(_ url: URL) -> [String: Any] {
        var info: [String: Any] = ["path": url.path, "name": url.lastPathComponent]
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { info["dir"] = true }
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let type, type.conforms(to: .image), size < 20_000_000,
           let mime = type.preferredMIMEType, ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime),
           let data = try? Data(contentsOf: url) {
            info["mime"] = mime
            info["data"] = data.base64EncodedString()
        }
        return info
    }

    private func runShell(_ cmd: String, cwd: String, env: [String: String], reply: @escaping (Any?, String?) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            var o = Data(), e = Data()
            let g = DispatchGroup()
            g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            do { try p.run() } catch {
                DispatchQueue.main.async { reply(["stdout": "", "stderr": error.localizedDescription, "code": -1], nil) }
                return
            }
            p.waitUntilExit(); g.wait()
            let res: [String: Any] = [
                "stdout": String(decoding: o.prefix(400_000), as: UTF8.self),
                "stderr": String(decoding: e.prefix(100_000), as: UTF8.self),
                "code": Int(p.terminationStatus),
            ]
            DispatchQueue.main.async { reply(res, nil) }
        }
    }

    private func dropped(_ urls: [URL]) {
        postObj(["t": "drop-files", "files": urls.map(describeFile)])
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "ncode" { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated || action.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(url.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()
    }
}

/// WKWebView that hands file drops to Swift (to get real paths, which the DOM never sees).
final class DropWebView: WKWebView {
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if fileURLs(sender).isEmpty { return super.draggingEntered(sender) }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if fileURLs(sender).isEmpty { return super.draggingUpdated(sender) }
        return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        if urls.isEmpty { return super.performDragOperation(sender) }
        onDrop?(urls)
        return true
    }
    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// Serves the bundled web UI at ncode://app/… and local files at ncode://file/<abs path>.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static var webRoot: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
        // `swift run` during development: Resources/web next to Package.swift.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("Resources/web")
    }()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let fileURL: URL
        if url.host == "file" {
            fileURL = URL(fileURLWithPath: url.path)
        } else {
            var rel = url.path
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.isEmpty { rel = "index.html" }
            fileURL = Self.webRoot.appendingPathComponent(rel).standardizedFileURL
            guard fileURL.path.hasPrefix(Self.webRoot.standardizedFileURL.path) else {
                task.didFailWithError(URLError(.noPermissionsToReadFile)); return
            }
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Cache-Control": "no-cache"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
