import SwiftUI
import CryptoKit

/// Syncs the project folder with a GitHub repository through the REST API
/// (no git binary on iOS): compare, pull, and commit + push in one step.
struct GitHubRepo {
    let name: String      // owner/repo
    let branch: String
    let token: String

    struct Change: Identifiable, Hashable {
        enum Kind: String { case added = "جديد", modified = "معدّل", deleted = "محذوف محليا", remoteOnly = "في GitHub فقط", remoteChanged = "تغير في GitHub" }
        let path: String
        let kind: Kind
        let remoteSHA: String?
        var id: String { path }
    }
    struct Snapshot { let head: String?; let tree: String?; let remote: [String:String]; let local: [String:String] }

    private func call(_ method: String, _ path: String, _ body: [String:Any]? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/" + name + path)!, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String:Any])?["message"] as? String ?? ""
            throw GitError.http(status, message)
        }
        return try JSONSerialization.jsonObject(with: data.isEmpty ? Data("{}".utf8) : data)
    }
    enum GitError: Error, LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            guard case .http(let code, let message) = self else { return nil }
            switch code {
            case 401: return "رمز GitHub غير صالح أو منتهي"
            case 403: return "الرمز لا يملك صلاحية الكتابة على هذا المستودع (Contents: Read and write)"
            case 404: return "المستودع أو الفرع غير موجود، أو الرمز لا يصل إليه"
            default: return "GitHub \(code): " + message
            }
        }
    }

    /// Git's blob id: SHA-1 of "blob <size>\0" + content.
    static func blobSHA(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func localFiles(_ root: URL) -> [String:URL] {
        var out = [String:URL]()
        let skip: Set<String> = ["node_modules", "DerivedData", "Pods", "build", ".build", ".git"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey], options: .skipsHiddenFiles) else { return out }
        let base = root.standardizedFileURL.pathComponents.count
        while let url = walker.nextObject() as? URL {
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 20 << 20 else { continue }
            out[url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")] = url
        }
        return out
    }

    func snapshot(_ root: URL) async throws -> Snapshot {
        var local = [String:String]()
        for (path, url) in Self.localFiles(root) { if let data = try? Data(contentsOf: url) { local[path] = Self.blobSHA(data) } }
        let head: String
        do {
            let ref = try await call("GET", "/git/ref/heads/" + branch) as? [String:Any]
            guard let sha = (ref?["object"] as? [String:Any])?["sha"] as? String else { return Snapshot(head: nil, tree: nil, remote: [:], local: local) }
            head = sha
        } catch GitError.http(let code, _) where code == 404 || code == 409 {
            return Snapshot(head: nil, tree: nil, remote: [:], local: local)  // empty repository or new branch
        }
        let commit = try await call("GET", "/git/commits/" + head) as? [String:Any]
        let tree = (commit?["tree"] as? [String:Any])?["sha"] as? String
        var remote = [String:String]()
        if let tree, let listing = try await call("GET", "/git/trees/" + tree + "?recursive=1") as? [String:Any] {
            for entry in listing["tree"] as? [[String:Any]] ?? [] where entry["type"] as? String == "blob" {
                if let path = entry["path"] as? String, let sha = entry["sha"] as? String { remote[path] = sha }
            }
        }
        return Snapshot(head: head, tree: tree, remote: remote, local: local)
    }

    /// Changes relative to the last commit on GitHub. Files that exist only on GitHub are
    /// reported, not deleted, unless the user pushes deletions explicitly.
    static func changes(_ s: Snapshot, pushedBase: [String:String]) -> [Change] {
        var out = [Change]()
        for (path, sha) in s.local where s.remote[path] != sha {
            if s.remote[path] == nil { out.append(Change(path: path, kind: .added, remoteSHA: nil)) }
            else if pushedBase[path] != nil && pushedBase[path] != s.remote[path] { out.append(Change(path: path, kind: .remoteChanged, remoteSHA: s.remote[path])) }
            else { out.append(Change(path: path, kind: .modified, remoteSHA: s.remote[path])) }
        }
        for (path, sha) in s.remote where s.local[path] == nil {
            out.append(Change(path: path, kind: pushedBase[path] != nil ? .deleted : .remoteOnly, remoteSHA: sha))
        }
        return out.sorted { $0.path < $1.path }
    }

    func blob(_ sha: String) async throws -> Data {
        let object = try await call("GET", "/git/blobs/" + sha) as? [String:Any]
        let content = (object?["content"] as? String ?? "").replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: content) else { throw GitError.http(0, "blob") }
        return data
    }

    /// Writes GitHub's version of the given files into the project.
    func pull(_ root: URL, _ changes: [Change]) async throws -> Int {
        var count = 0
        for change in changes {
            guard let sha = change.remoteSHA, [.remoteOnly, .remoteChanged, .modified].contains(change.kind) else { continue }
            let target = try ProjectFiles(root: root).url(change.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await blob(sha).write(to: target, options: .atomic)
            count += 1
        }
        return count
    }

    /// One commit with every local change (and local deletions), then moves the branch to it.
    func push(_ root: URL, _ s: Snapshot, _ changes: [Change], message: String) async throws -> String {
        let files = Self.localFiles(root)
        var entries = [[String:Any]]()
        for change in changes {
            switch change.kind {
            case .added, .modified, .remoteChanged:
                guard let url = files[change.path] else { continue }
                let data = try Data(contentsOf: url)
                let blob = try await call("POST", "/git/blobs", ["content": data.base64EncodedString(), "encoding": "base64"]) as? [String:Any]
                guard let sha = blob?["sha"] as? String else { continue }
                entries.append(["path": change.path, "mode": "100644", "type": "blob", "sha": sha])
            case .deleted:
                entries.append(["path": change.path, "mode": "100644", "type": "blob", "sha": NSNull()])
            case .remoteOnly: continue
            }
        }
        guard !entries.isEmpty else { throw GitError.http(0, "لا توجد تغييرات للرفع") }
        var treeBody: [String:Any] = ["tree": entries]
        if let base = s.tree { treeBody["base_tree"] = base }
        guard let tree = (try await call("POST", "/git/trees", treeBody) as? [String:Any])?["sha"] as? String else { throw GitError.http(0, "tree") }
        var commitBody: [String:Any] = ["message": message, "tree": tree]
        commitBody["parents"] = s.head.map { [$0] } ?? [String]()
        guard let commit = (try await call("POST", "/git/commits", commitBody) as? [String:Any])?["sha"] as? String else { throw GitError.http(0, "commit") }
        if s.head == nil { _ = try await call("POST", "/git/refs", ["ref": "refs/heads/" + branch, "sha": commit]) }
        else { _ = try await call("PATCH", "/git/refs/heads/" + branch, ["sha": commit, "force": false]) }
        return commit
    }
}

/// Line diff for the review sheet.
func lineDiff(_ old: String, _ new: String) -> [(String, Character)] {
    let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
    var out = [(String, Character)]()
    for change in b.difference(from: a) {
        switch change {
        case .remove(_, let line, _): out.append((line, "-"))
        case .insert(_, let line, _): out.append((line, "+"))
        }
    }
    return out
}

struct GitPanel: View {
    @ObservedObject var studio: Studio
    @AppStorage("git.repo") private var repoName = ""
    @AppStorage("git.branch") private var branch = "main"
    @State private var token = ""
    @State private var message = ""
    @State private var commitMessage = ""
    @State private var changes: [GitHubRepo.Change] = []
    @State private var snapshot: GitHubRepo.Snapshot?
    @State private var working = false
    @State private var diff: [(String, Character)] = []
    @State private var diffPath = ""
    private static let tokenID = UUID(uuidString: "6A1D2F3C-0000-4000-8000-00000000617A")!
    private var baseKey: String { "git.base." + repoName + "." + branch + "." + studio.files.root.path }
    private var pushedBase: [String:String] { (UserDefaults.standard.dictionary(forKey: baseKey) as? [String:String]) ?? [:] }
    private var repo: GitHubRepo { GitHubRepo(name: repoName.trimmingCharacters(in: .whitespaces), branch: branch, token: (try? Credentials.key(Self.tokenID)) ?? "") }

    var body: some View {
        Form {
            Section {
                TextField("المستودع (owner/repo)", text: $repoName).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("الفرع", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField((try? Credentials.key(Self.tokenID))?.isEmpty == false ? "الرمز محفوظ (أدخل رمزا جديدا لاستبداله)" : "رمز GitHub (Fine-grained, Contents: Read and write)", text: $token)
                    .onSubmit { saveToken() }
                if !token.isEmpty { Button("حفظ الرمز في Keychain") { saveToken() } }
            } header: { Text("المشروع: " + studio.files.root.lastPathComponent) }
            Section {
                Button(working ? "جار العمل…" : "فحص التغييرات") { Task { await refresh() } }.disabled(working || repoName.isEmpty)
                ForEach(changes) { change in
                    Button { Task { await showDiff(change) } } label: {
                        HStack { Text(change.path).font(.system(.footnote, design: .monospaced)); Spacer(); Text(change.kind.rawValue).font(.caption) }
                    }
                }
                if snapshot != nil && changes.isEmpty { Text("المشروع مطابق لـ GitHub") }
            }
            if !changes.isEmpty {
                Section("رفع") {
                    TextField("وصف التعديل (commit)", text: $commitMessage)
                    Button("حفظ ورفع التغييرات المحلية") { Task { await push() } }.disabled(working || commitMessage.isEmpty)
                }
                Section("سحب") {
                    Button("سحب نسخة GitHub للملفات المعدلة في GitHub") { Task { await pull(all: false) } }.disabled(working)
                    Button("استبدال كل الملفات المختلفة بنسخة GitHub", role: .destructive) { Task { await pull(all: true) } }.disabled(working)
                }
            }
            if !diff.isEmpty {
                Section("الفروقات: " + diffPath) {
                    ForEach(Array(diff.prefix(400).enumerated()), id: \.offset) { item in
                        Text(String(item.element.1) + " " + item.element.0)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(item.element.1 == "+" ? Color.green : Color.red)
                    }
                }
            }
            if !message.isEmpty { Section { Text(message).font(.footnote).textSelection(.enabled) } }
        }
        .navigationTitle("GitHub")
    }

    private func saveToken() {
        do { try Credentials.save(token.trimmingCharacters(in: .whitespacesAndNewlines), Self.tokenID); token = ""; message = "تم حفظ الرمز" }
        catch { message = error.localizedDescription }
    }
    private func run(_ work: () async throws -> Void) async {
        working = true; defer { working = false }
        do { try await work() } catch { message = error.localizedDescription }
    }
    private func refresh() async {
        await run {
            let s = try await repo.snapshot(studio.files.root)
            snapshot = s
            changes = GitHubRepo.changes(s, pushedBase: pushedBase)
            if s.head == nil { message = "المستودع فارغ أو الفرع جديد: سيُنشأ عند الرفع" } else { message = "" }
            diff = []
        }
    }
    private func showDiff(_ change: GitHubRepo.Change) async {
        await run {
            let local = GitHubRepo.localFiles(studio.files.root)[change.path].flatMap { try? Data(contentsOf: $0) } ?? Data()
            var remote = Data()
            if let sha = change.remoteSHA { remote = try await repo.blob(sha) }
            diff = lineDiff(String(decoding: remote, as: UTF8.self), String(decoding: local, as: UTF8.self))
            diffPath = change.path + " (- GitHub / + الجهاز)"
        }
    }
    private func push() async {
        guard let s = snapshot else { return }
        await run {
            let commit = try await repo.push(studio.files.root, s, changes, message: commitMessage)
            message = "تم الرفع: " + String(commit.prefix(7))
            commitMessage = ""
            let fresh = try await repo.snapshot(studio.files.root)
            UserDefaults.standard.set(fresh.remote, forKey: baseKey)
            snapshot = fresh
            changes = GitHubRepo.changes(fresh, pushedBase: fresh.remote)
        }
    }
    private func pull(all: Bool) async {
        await run {
            let selected = all ? changes : changes.filter { $0.kind == .remoteOnly || $0.kind == .remoteChanged }
            let count = try await repo.pull(studio.files.root, selected)
            message = "تم سحب \(count) ملف"
            if let s = snapshot { UserDefaults.standard.set(s.remote, forKey: baseKey) }
        }
        await refresh()
    }
}
