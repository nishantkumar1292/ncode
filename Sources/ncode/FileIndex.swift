import Foundation

/// Relative file paths for @-mention autocomplete. Uses `git ls-files` when possible
/// (respects .gitignore), else a bounded directory walk. Cached briefly per folder.
final class FileIndex {
    static let shared = FileIndex()
    private var cache: [String: (Date, [String])] = [:]
    private let queue = DispatchQueue(label: "ncode.fileindex")
    private let skipDirs: Set<String> = [".git", "node_modules", ".build", "build", "dist", ".next", "__pycache__", ".venv", "venv", ".tox", "target", "DerivedData", ".gradle", ".idea", "Pods"]

    func files(in cwd: String, completion: @escaping ([String]) -> Void) {
        queue.async {
            if let (d, list) = self.cache[cwd], Date().timeIntervalSince(d) < 30 {
                DispatchQueue.main.async { completion(list) }; return
            }
            let list = self.gitFiles(cwd) ?? self.walk(cwd)
            self.cache[cwd] = (Date(), list)
            DispatchQueue.main.async { completion(list) }
        }
    }

    private func gitFiles(_ cwd: String) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        var files = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(30000).map(String.init)
        // Add directories so folders can be mentioned too.
        var dirs = Set<String>()
        for f in files {
            var comps = f.split(separator: "/").dropLast()
            while !comps.isEmpty { dirs.insert(comps.joined(separator: "/") + "/"); comps = comps.dropLast() }
        }
        files += dirs.sorted()
        return files
    }

    private func walk(_ cwd: String) -> [String] {
        let root = URL(fileURLWithPath: cwd)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in e {
            if out.count >= 20000 { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir && skipDirs.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            if e.level > 8 { e.skipDescendants(); continue }
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
            out.append(isDir ? rel + "/" : rel)
        }
        return out
    }
}
