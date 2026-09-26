import Compression
import CryptoKit
import Foundation

// Git без git: всё через GitHub REST API.
// - клон: tarball коммита → распаковка; SHA каждого файла считаем сами (git blob SHA-1)
// - статус: сравниваем SHA файлов на диске с SHA из последнего синхронизированного коммита
// - коммит+пуш: blobs → tree (поверх base_tree) → commit → перемотка ветки
// - получить изменения: дерево нового коммита, скачиваем только то, что поменялось на GitHub
// Состояние связи с репозиторием лежит в <проект>/.forge-git.json.

struct GitState: Codable {
	var owner: String
	var repo: String
	var branch: String
	var defaultBranch: String
	var head: String                 // SHA последнего синхронизированного коммита
	var tree: String                 // его дерево
	var files: [String: String]      // путь → blob SHA в этом коммите
	var modes: [String: String] = [:]  // путь → режим, если не 100644

	var fullName: String { owner + "/" + repo }
	var api: String { "/repos/\(owner)/\(repo)" }

	static func url(_ dir: URL) -> URL { dir.appendingPathComponent(".forge-git.json") }

	static func load(_ dir: URL) -> GitState? {
		(try? Data(contentsOf: url(dir))).flatMap { try? JSONDecoder().decode(GitState.self, from: $0) }
	}

	func save(_ dir: URL) throws {
		try JSONEncoder().encode(self).write(to: GitState.url(dir), options: .atomic)
	}
}

struct GitChange: Identifiable, Hashable {
	enum Kind: String { case added = "A", modified = "M", deleted = "D" }
	let path: String
	let kind: Kind
	var id: String { path }
}

struct GHRepo: Identifiable, Hashable {
	let fullName: String
	let isPrivate: Bool
	let about: String
	var id: String { fullName }
}

struct GHCommit: Identifiable, Hashable {
	let sha: String
	let message: String
	let author: String
	let date: String
	var id: String { sha }
}

struct GHFile: Identifiable, Hashable {
	let name: String
	let status: String
	let additions: Int
	let deletions: Int
	let patch: String
	var id: String { name }
}

struct GHItem: Identifiable, Hashable {  // issue или pull request
	let number: Int
	let title: String
	let author: String
	let isPR: Bool
	let url: String
	var id: Int { number }
}

// MARK: REST

enum GH {
	static let tokenKey = "github-token"
	static var token: String { Keychain.get(tokenKey) ?? "" }

	@discardableResult
	static func call(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Any {
		guard let url = URL(string: path.hasPrefix("https://") ? path : "https://api.github.com" + path) else {
			throw StoreError(L("Invalid address: %@", path))
		}
		var req = URLRequest(url: url)
		req.httpMethod = method
		req.timeoutInterval = 120
		req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		let t = token
		if !t.isEmpty { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
		if let body {
			req.httpBody = try JSONSerialization.data(withJSONObject: body)
			req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let (d, r) = try await URLSession.shared.data(for: req)
		let code = (r as? HTTPURLResponse)?.statusCode ?? 0
		let j: Any = d.isEmpty ? [String: Any]() : ((try? JSONSerialization.jsonObject(with: d)) ?? [String: Any]())
		guard (200..<300).contains(code) else {
			var msg = (j as? [String: Any])?["message"] as? String ?? String(decoding: d.prefix(300), as: UTF8.self)
			if let errs = (j as? [String: Any])?["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String { msg += ": " + m }
			switch code {
			case 401: msg = L("the token is invalid or expired (%@)", msg)
			case 403 where msg.lowercased().contains("rate limit"): msg = L("rate limit exceeded — add a token in Settings")
			case 403: msg = L("access denied (%@). Check the token permissions: Contents and Pull requests — Read and write", msg)
			case 404: msg = L("not found (%@). Private repositories need a token with access", msg)
			case 409 where msg.contains("empty"): msg = L("the repository is empty — create at least a README in it on GitHub")
			default: break
			}
			throw StoreError("GitHub \(code): \(msg)")
		}
		return j
	}

	static func obj(_ method: String, _ path: String, _ body: Any? = nil) async throws -> [String: Any] {
		try await call(method, path, body) as? [String: Any] ?? [:]
	}

	static func arr(_ path: String) async throws -> [[String: Any]] {
		try await call("GET", path) as? [[String: Any]] ?? []
	}

	static func download(_ path: String) async throws -> Data {
		var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
		req.timeoutInterval = 300
		let t = token
		if !t.isEmpty { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
		let (d, r) = try await URLSession.shared.data(for: req)
		let code = (r as? HTTPURLResponse)?.statusCode ?? 0
		guard code == 200 else { throw StoreError(L("GitHub %@ while downloading the archive", code)) }
		return d
	}

	static func login() async throws -> String {
		try await obj("GET", "/user")["login"] as? String ?? "?"
	}

	static func repos() async throws -> [GHRepo] {
		try await arr("/user/repos?per_page=100&sort=updated").map {
			GHRepo(fullName: $0["full_name"] as? String ?? "", isPrivate: $0["private"] as? Bool ?? false,
			       about: $0["description"] as? String ?? "")
		}
	}

	/// «https://github.com/owner/repo.git», «github.com/owner/repo/tree/x», «owner/repo» → (owner, repo)
	static func parseRepo(_ s: String) -> (String, String)? {
		var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		for p in ["https://", "http://", "www.", "github.com/", "git@github.com:"] where t.hasPrefix(p) { t.removeFirst(p.count) }
		if t.hasPrefix("github.com/") { t.removeFirst("github.com/".count) }
		let parts = t.split(separator: "/").map(String.init)
		guard parts.count >= 2 else { return nil }
		var repo = parts[1]
		if repo.hasSuffix(".git") { repo.removeLast(4) }
		guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
		return (parts[0], repo)
	}

	static func esc(_ s: String) -> String {
		s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
	}
}

// MARK: операции

enum Git {
	/// Служебное: не показываем гиту никогда.
	static let internalNames: Set<String> = [".git", ".chat.json", ".forge-git.json", ".DS_Store"]

	static func blobSHA(_ data: Data) -> String {
		var h = Insecure.SHA1()
		h.update(data: Data("blob \(data.count)\0".utf8))
		h.update(data: data)
		return h.finalize().map { String(format: "%02x", $0) }.joined()
	}

	// ---------------------------------------------------------- .gitignore (упрощённо: без «!»)

	struct Ignore {
		private var rules: [(pattern: String, dirOnly: Bool, anchored: Bool)] = []

		init(_ dir: URL) {
			let text = (try? String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
			for raw in text.components(separatedBy: .newlines) {
				var l = raw.trimmingCharacters(in: .whitespaces)
				if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("!") { continue }
				let dirOnly = l.hasSuffix("/")
				while l.hasSuffix("/") { l.removeLast() }
				if l.hasPrefix("**/") { l.removeFirst(3) }
				let anchored = l.contains("/")
				while l.hasPrefix("/") { l.removeFirst() }
				if !l.isEmpty { rules.append((l, dirOnly, anchored)) }
			}
		}

		/// `isDir` — путь сам по себе папка.
		func ignored(_ path: String, isDir: Bool = false) -> Bool {
			let comps = path.split(separator: "/").map(String.init)
			for r in rules {
				for k in 0..<comps.count {
					let dirPart = k < comps.count - 1 || isDir
					if r.dirOnly && !dirPart { continue }
					let subject = r.anchored ? comps[0...k].joined(separator: "/") : comps[k]
					if fnmatch(r.pattern, subject, r.anchored ? FNM_PATHNAME : 0) == 0 { return true }
				}
			}
			return false
		}
	}

	/// Файлы рабочей папки: путь → blob SHA. Отслеживаемые файлы учитываются, даже если попали в .gitignore.
	static func scan(_ dir: URL, tracked: [String: String]) -> [String: String] {
		let ign = Ignore(dir)
		let fm = FileManager.default
		let base = dir.resolvingSymlinksInPath().path + "/"
		var out: [String: String] = [:]
		guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return out }
		for case let u as URL in e {
			if internalNames.contains(u.lastPathComponent) { e.skipDescendants(); continue }
			let full = u.resolvingSymlinksInPath().path
			guard full.hasPrefix(base) else { continue }
			let rel = String(full.dropFirst(base.count))
			let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			if v?.isSymbolicLink == true { continue }
			if v?.isDirectory == true {
				if ign.ignored(rel, isDir: true) && !tracked.keys.contains(where: { $0.hasPrefix(rel + "/") }) { e.skipDescendants() }
				continue
			}
			if tracked[rel] == nil && (ign.ignored(rel) || rel.hasSuffix(".remote")) { continue }
			if let d = try? Data(contentsOf: u) { out[rel] = blobSHA(d) }
		}
		return out
	}

	static func status(_ dir: URL) throws -> [GitChange] {
		guard let st = GitState.load(dir) else { throw StoreError(L("The project is not linked to GitHub")) }
		let local = scan(dir, tracked: st.files)
		var out: [GitChange] = []
		for (p, s) in local {
			if let b = st.files[p] { if b != s { out.append(GitChange(path: p, kind: .modified)) } }
			else { out.append(GitChange(path: p, kind: .added)) }
		}
		for p in st.files.keys where local[p] == nil { out.append(GitChange(path: p, kind: .deleted)) }
		return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
	}

	static func refSHA(_ st: GitState, _ branch: String) async throws -> String {
		let r = try await GH.obj("GET", st.api + "/git/ref/heads/" + GH.esc(branch))
		guard let sha = (r["object"] as? [String: Any])?["sha"] as? String else { throw StoreError(L("No branch %@", branch)) }
		return sha
	}

	static func treeOf(_ st: GitState, _ commit: String) async throws -> String {
		let c = try await GH.obj("GET", st.api + "/git/commits/" + commit)
		guard let t = (c["tree"] as? [String: Any])?["sha"] as? String else { throw StoreError(L("Could not read the commit")) }
		return t
	}

	static func blob(_ st: GitState, _ sha: String) async throws -> Data {
		let b = try await GH.obj("GET", st.api + "/git/blobs/" + sha)
		guard let c = b["content"] as? String, let d = Data(base64Encoded: c, options: .ignoreUnknownCharacters) else {
			throw StoreError(L("Could not download the file"))
		}
		return d
	}

	/// Текст файла в последнем синхронизированном коммите (для диффа).
	static func baseText(_ dir: URL, _ path: String) async throws -> String? {
		guard let st = GitState.load(dir), let sha = st.files[path] else { return nil }
		return String(data: try await blob(st, sha), encoding: .utf8)
	}

	private static func safe(_ rel: String) -> Bool {
		!rel.isEmpty && !rel.hasPrefix("/") && !rel.split(separator: "/").contains("..")
	}

	// ---------------------------------------------------------- клон

	static func clone(_ spec: String, branch: String, into root: URL, progress: @escaping (String) -> Void) async throws -> URL {
		guard let pr = GH.parseRepo(spec) else { throw StoreError(L("Enter a repository: owner/repo or a link")) }
		let (owner, repo) = pr
		progress(L("Reading %@/%@…", owner, repo))
		let info = try await GH.obj("GET", "/repos/\(owner)/\(repo)")
		let def = info["default_branch"] as? String ?? "main"
		let br = branch.isEmpty ? def : branch
		var st = GitState(owner: owner, repo: repo, branch: br, defaultBranch: def, head: "", tree: "", files: [:])
		st.head = try await refSHA(st, br)
		st.tree = try await treeOf(st, st.head)

		progress(L("Downloading the archive…"))
		let tgz = try await GH.download(st.api + "/tarball/" + st.head)
		progress(L("Unpacking %@…", ByteCountFormatter.string(fromByteCount: Int64(tgz.count), countStyle: .file)))
		let entries = try untar(try gunzip(tgz))

		let fm = FileManager.default
		var name = repo, n = 2
		while fm.fileExists(atPath: root.appendingPathComponent(name).path) { name = "\(repo)\(n)"; n += 1 }
		let dir = root.appendingPathComponent(name)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		for e in entries {
			guard let slash = e.path.firstIndex(of: "/") else { continue }  // корень архива: owner-repo-sha/
			let rel = String(e.path[e.path.index(after: slash)...])
			guard safe(rel) else { continue }
			let u = dir.appendingPathComponent(rel)
			try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
			try e.data.write(to: u)
			st.files[rel] = blobSHA(e.data)
			if e.mode & 0o111 != 0 { st.modes[rel] = "100755" }
		}
		try st.save(dir)
		return dir
	}

	// ---------------------------------------------------------- коммит и пуш

	static func commit(_ dir: URL, message: String, paths: Set<String>, progress: @escaping (String) -> Void) async throws {
		guard var st = GitState.load(dir) else { throw StoreError(L("The project is not linked to GitHub")) }
		let changes = try status(dir).filter { paths.contains($0.path) }
		guard !changes.isEmpty else { throw StoreError(L("Nothing to commit")) }
		progress(L("Checking branch %@…", st.branch))
		guard try await refSHA(st, st.branch) == st.head else {
			throw StoreError(L("Branch %@ on GitHub has new commits. Tap “Pull changes” first.", st.branch))
		}
		var entries: [[String: Any]] = []
		var shas: [String: String] = [:]
		for (i, c) in changes.enumerated() {
			let mode = st.modes[c.path] ?? "100644"
			if c.kind == .deleted {
				entries.append(["path": c.path, "mode": mode, "type": "blob", "sha": NSNull()])
				continue
			}
			progress(L("Uploading %@/%@: %@", i + 1, changes.count, c.path))
			let data = try Data(contentsOf: dir.appendingPathComponent(c.path))
			let b = try await GH.obj("POST", st.api + "/git/blobs", ["content": data.base64EncodedString(), "encoding": "base64"])
			let sha = b["sha"] as? String ?? blobSHA(data)
			shas[c.path] = sha
			entries.append(["path": c.path, "mode": mode, "type": "blob", "sha": sha])
		}
		progress(L("Creating the commit…"))
		guard let tree = try await GH.obj("POST", st.api + "/git/trees", ["base_tree": st.tree, "tree": entries])["sha"] as? String,
		      let commit = try await GH.obj("POST", st.api + "/git/commits",
		                                    ["message": message, "tree": tree, "parents": [st.head]])["sha"] as? String
		else { throw StoreError(L("GitHub did not return the commit SHA")) }
		progress(L("Pushing to %@…", st.branch))
		try await GH.call("PATCH", st.api + "/git/refs/heads/" + GH.esc(st.branch), ["sha": commit, "force": false])
		st.head = commit
		st.tree = tree
		for c in changes {
			if c.kind == .deleted { st.files[c.path] = nil; st.modes[c.path] = nil } else { st.files[c.path] = shas[c.path] }
		}
		try st.save(dir)
	}

	// ---------------------------------------------------------- получить изменения / переключить ветку

	struct SyncResult {
		var updated = 0
		var deleted = 0
		var conflicts: [String] = []
		var upToDate = false
	}

	/// Подтягивает ветку `branch` (по умолчанию текущую). Локальные правки сохраняются;
	/// если файл изменён и тут, и на GitHub — остаётся локальная версия, а GitHub-версия ложится рядом как <файл>.remote.
	static func sync(_ dir: URL, branch: String? = nil, progress: @escaping (String) -> Void) async throws -> SyncResult {
		guard var st = GitState.load(dir) else { throw StoreError(L("The project is not linked to GitHub")) }
		let br = branch ?? st.branch
		progress(L("Checking %@…", br))
		let head = try await refSHA(st, br)
		if head == st.head && br == st.branch { return SyncResult(upToDate: true) }
		let treeSha = try await treeOf(st, head)
		progress(L("Fetching the file list…"))
		let t = try await GH.obj("GET", st.api + "/git/trees/\(treeSha)?recursive=1")
		if t["truncated"] as? Bool == true { throw StoreError(L("The repository is too large to sync over the API")) }
		var remote: [String: String] = [:], modes: [String: String] = [:]
		for e in t["tree"] as? [[String: Any]] ?? [] where e["type"] as? String == "blob" {
			guard let p = e["path"] as? String, let s = e["sha"] as? String, safe(p) else { continue }
			let m = e["mode"] as? String ?? "100644"
			if m == "120000" { continue }  // симлинки не поддерживаем
			remote[p] = s
			if m != "100644" { modes[p] = m }
		}
		let local = scan(dir, tracked: st.files)
		var r = SyncResult()
		let fm = FileManager.default
		for p in Set(remote.keys).union(st.files.keys).sorted() {
			let base = st.files[p], rem = remote[p], loc = local[p]
			if rem == base || loc == rem { continue }
			let u = dir.appendingPathComponent(p)
			if loc == base {
				if let rem {
					progress(L("Downloading %@", p))
					let d = try await blob(st, rem)
					try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
					try d.write(to: u)
					r.updated += 1
				} else {
					try? fm.removeItem(at: u)
					r.deleted += 1
				}
			} else {
				if let rem { try await blob(st, rem).write(to: URL(fileURLWithPath: u.path + ".remote")) }
				r.conflicts.append(p)
			}
		}
		st.branch = br
		st.head = head
		st.tree = treeSha
		st.files = remote
		st.modes = modes
		try st.save(dir)
		return r
	}

	static func branches(_ dir: URL) async throws -> [String] {
		guard let st = GitState.load(dir) else { return [] }
		return try await GH.arr(st.api + "/branches?per_page=100").compactMap { $0["name"] as? String }
	}

	static func switchBranch(_ dir: URL, to branch: String, progress: @escaping (String) -> Void) async throws {
		guard try status(dir).isEmpty else { throw StoreError(L("Commit or discard your changes before switching branches")) }
		_ = try await sync(dir, branch: branch, progress: progress)
	}

	static func createBranch(_ dir: URL, name: String) async throws {
		guard var st = GitState.load(dir) else { return }
		try await GH.call("POST", st.api + "/git/refs", ["ref": "refs/heads/" + name, "sha": st.head])
		st.branch = name
		try st.save(dir)
	}

	/// Отменить локальные изменения файла: вернуть версию из последнего коммита.
	static func discard(_ dir: URL, _ change: GitChange) async throws {
		guard let st = GitState.load(dir) else { return }
		let u = dir.appendingPathComponent(change.path)
		if change.kind == .added { try FileManager.default.removeItem(at: u); return }
		guard let sha = st.files[change.path] else { return }
		try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
		try await blob(st, sha).write(to: u)
	}

	// ---------------------------------------------------------- новый репозиторий из проекта

	static func publish(_ dir: URL, name: String, isPrivate: Bool, progress: @escaping (String) -> Void) async throws {
		progress(L("Creating the repository…"))
		let r = try await GH.obj("POST", "/user/repos", ["name": name, "private": isPrivate, "auto_init": true])
		guard let full = r["full_name"] as? String, let pr = GH.parseRepo(full) else {
			throw StoreError(L("GitHub did not return the repository name"))
		}
		let (owner, repo) = pr
		let def = r["default_branch"] as? String ?? "main"
		try GitState(owner: owner, repo: repo, branch: def, defaultBranch: def, head: "", tree: "", files: [:]).save(dir)
		// ветка с README появляется не мгновенно
		for i in 0..<6 {
			do { _ = try await sync(dir, progress: progress); break } catch where i < 5 {
				try await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
		let all = Set(try status(dir).map(\.path))
		if !all.isEmpty { try await commit(dir, message: L("Initial commit from Forge"), paths: all, progress: progress) }
	}

	// ---------------------------------------------------------- история, PR, issues

	static func history(_ dir: URL) async throws -> [GHCommit] {
		guard let st = GitState.load(dir) else { return [] }
		return try await GH.arr(st.api + "/commits?per_page=50&sha=" + GH.esc(st.branch)).map {
			let c = $0["commit"] as? [String: Any] ?? [:]
			let a = c["author"] as? [String: Any] ?? [:]
			return GHCommit(sha: $0["sha"] as? String ?? "", message: c["message"] as? String ?? "",
			                author: a["name"] as? String ?? "", date: String((a["date"] as? String ?? "").prefix(10)))
		}
	}

	static func commitFiles(_ dir: URL, _ sha: String) async throws -> [GHFile] {
		guard let st = GitState.load(dir) else { return [] }
		return (try await GH.obj("GET", st.api + "/commits/" + sha)["files"] as? [[String: Any]] ?? []).map {
			GHFile(name: $0["filename"] as? String ?? "", status: $0["status"] as? String ?? "",
			       additions: $0["additions"] as? Int ?? 0, deletions: $0["deletions"] as? Int ?? 0,
			       patch: $0["patch"] as? String ?? L("(binary file or diff too large)"))
		}
	}

	static func items(_ dir: URL, pulls: Bool) async throws -> [GHItem] {
		guard let st = GitState.load(dir) else { return [] }
		return try await GH.arr(st.api + (pulls ? "/pulls" : "/issues") + "?state=open&per_page=50")
			.filter { pulls || $0["pull_request"] == nil }
			.map {
				GHItem(number: $0["number"] as? Int ?? 0, title: $0["title"] as? String ?? "",
				       author: ($0["user"] as? [String: Any])?["login"] as? String ?? "",
				       isPR: pulls, url: $0["html_url"] as? String ?? "")
			}
	}

	static func openPR(_ dir: URL, title: String, body: String, base: String) async throws -> String {
		guard let st = GitState.load(dir) else { throw StoreError(L("The project is not linked to GitHub")) }
		let r = try await GH.obj("POST", st.api + "/pulls", ["title": title, "body": body, "head": st.branch, "base": base])
		return r["html_url"] as? String ?? ""
	}

	static func createIssue(_ dir: URL, title: String, body: String) async throws -> String {
		guard let st = GitState.load(dir) else { throw StoreError(L("The project is not linked to GitHub")) }
		return try await GH.obj("POST", st.api + "/issues", ["title": title, "body": body])["html_url"] as? String ?? ""
	}

	// ---------------------------------------------------------- tar.gz

	/// gzip = заголовок + raw DEFLATE + CRC; COMPRESSION_ZLIB в Compression — это как раз raw DEFLATE.
	static func gunzip(_ d: Data) throws -> Data {
		let bytes = [UInt8](d)
		guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw StoreError(L("The archive is not gzip")) }
		let flags = bytes[3]
		var i = 10
		if flags & 4 != 0 { i += 2 + Int(bytes[i]) + Int(bytes[i + 1]) << 8 }
		if flags & 8 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }
		if flags & 16 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }
		if flags & 2 != 0 { i += 2 }
		guard i < bytes.count else { throw StoreError(L("Corrupt gzip")) }

		let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
		defer { stream.deallocate() }
		guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
			throw StoreError(L("Could not unpack"))
		}
		defer { compression_stream_destroy(stream) }
		let cap = 1 << 20
		let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
		defer { dst.deallocate() }
		var out = Data()
		try bytes.withUnsafeBufferPointer { src in
			stream.pointee.src_ptr = src.baseAddress!.advanced(by: i)
			stream.pointee.src_size = bytes.count - i
			while true {
				stream.pointee.dst_ptr = dst
				stream.pointee.dst_size = cap
				let s = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
				out.append(dst, count: cap - stream.pointee.dst_size)
				if s == COMPRESSION_STATUS_END { break }
				if s != COMPRESSION_STATUS_OK { throw StoreError(L("Archive unpacking error")) }
			}
		}
		return out
	}

	struct TarEntry {
		let path: String
		let data: Data
		let mode: Int
	}

	/// ustar + pax (длинные пути GitHub кладёт в pax-заголовок «x») + GNU «L». Только обычные файлы.
	static func untar(_ d: Data) throws -> [TarEntry] {
		let b = [UInt8](d)
		func str(_ o: Int, _ n: Int) -> String {
			var end = o
			while end < o + n && b[end] != 0 { end += 1 }
			return String(decoding: b[o..<end], as: UTF8.self)
		}
		func num(_ o: Int, _ n: Int) -> Int {
			if b[o] & 0x80 != 0 { return b[(o + 1)..<(o + n)].reduce(0) { $0 << 8 | Int($1) } }
			return Int(str(o, n).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
		}
		var out: [TarEntry] = []
		var i = 0
		var longPath: String?
		while i + 512 <= b.count {
			if b[i..<(i + 512)].allSatisfy({ $0 == 0 }) { break }
			let size = num(i + 124, 12)
			let type = b[i + 156]
			let start = i + 512
			guard start + size <= b.count else { throw StoreError(L("The archive is truncated")) }
			let body = Data(b[start..<(start + size)])
			switch type {
			case UInt8(ascii: "x"):
				// записи вида «<len> key=value\n»
				for rec in String(decoding: body, as: UTF8.self).split(separator: "\n") {
					if let r = rec.range(of: " path=") { longPath = String(rec[r.upperBound...]) }
				}
			case UInt8(ascii: "L"):
				longPath = String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
			case UInt8(ascii: "0"), 0:
				let prefix = str(i + 345, 155), name = str(i, 100)
				let path = longPath ?? (prefix.isEmpty ? name : prefix + "/" + name)
				out.append(TarEntry(path: path, data: body, mode: num(i + 100, 8)))
				longPath = nil
			case UInt8(ascii: "g"):
				break
			default:
				longPath = nil
			}
			i = start + (size + 511) / 512 * 512
		}
		return out
	}
}
