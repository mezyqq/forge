import Foundation

struct Todo: Codable, Identifiable, Hashable {
	var id: String
	var content: String
	var status: String  // pending | in_progress | completed | cancelled
}

/// Инструменты агента в стиле opencode (read/edit/write/glob/grep/list/todowrite/webfetch + запуск кода).
/// Описания и поведение перенесены из opencode (MIT) и адаптированы под Forge: пути относительно
/// корня проекта, нет shell, есть run для встроенных интерпретаторов.
@MainActor
final class ToolBox {
	let project: Project
	unowned let store: ProjectStore
	var todos: [Todo] = []
	/// Исходное содержимое файлов, которые агент менял с последнего просмотра правок (text == nil — файла не было).
	struct Original { let text: String? }
	var originals: [String: Original] = [:]
	/// Когда модель читала файл — edit/write существующего файла без чтения запрещены (как в opencode).
	private var readAt: [String: Date] = [:]

	init(project: Project, store: ProjectStore) {
		self.project = project
		self.store = store
	}

	// MARK: схема

	private static func prop(_ type: String, _ desc: String) -> [String: Any] { ["type": type, "description": desc] }

	private static func tool(_ name: String, _ desc: String, _ props: [String: [String: Any]], _ required: [String]) -> [String: Any] {
		["name": name, "description": desc,
		 "input_schema": ["type": "object", "properties": props, "required": required]]
	}

	static let definitions: [[String: Any]] = [
		tool("read", """
		Read a file or directory of the project. Paths are relative to the project root.
		- By default returns up to 2000 lines from the start of the file; use offset (1-indexed line) and limit to read other parts.
		- Lines are returned as `<line>: <content>`. Never include this prefix in oldString when editing.
		- For a directory, entries are listed one per line with a trailing / for subdirectories.
		- Read several files in parallel when you need them. Avoid tiny 30-line slices — read larger windows.
		""", ["filePath": prop("string", "Path relative to the project root, e.g. src/main.py"),
		      "offset": prop("integer", "Line number to start from (1-indexed)"),
		      "limit": prop("integer", "Maximum number of lines to read (default 2000)")], ["filePath"]),

		tool("edit", """
		Performs exact string replacement in a file.
		- You must read the file with the read tool first; the edit fails otherwise.
		- Preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix of read output.
		- Fails if oldString is not found, or found multiple times — then give more surrounding lines or use replaceAll.
		- Use replaceAll to rename a variable across the file.
		- Prefer editing existing files; do not create new files unless required.
		""", ["filePath": prop("string", "Path relative to the project root"),
		      "oldString": prop("string", "The exact text to replace"),
		      "newString": prop("string", "The text to replace it with (must be different)"),
		      "replaceAll": prop("boolean", "Replace all occurrences (default false)")], ["filePath", "oldString", "newString"]),

		tool("write", """
		Writes a whole file (creates folders as needed), overwriting it if it exists.
		- If the file exists, you must read it first.
		- Prefer edit for changing existing files. Never create documentation files unless asked.
		""", ["filePath": prop("string", "Path relative to the project root"),
		      "content": prop("string", "Full file content")], ["filePath", "content"]),

		tool("list", "Lists the project tree (or a subfolder), folders first. Skips build output, .git and dependency folders.",
		     ["path": prop("string", "Folder relative to the project root; empty = whole project")], []),

		tool("glob", """
		Fast file name pattern matching. Supports patterns like "**/*.py", "src/**/*.swift", "*.{js,ts}".
		Returns matching paths sorted by modification time (newest first).
		""", ["pattern": prop("string", "Glob pattern"),
		      "path": prop("string", "Folder to search in (default: project root)")], ["pattern"]),

		tool("grep", """
		Searches file contents with a regular expression (e.g. "log.*Error", "func\\s+\\w+").
		Filter files with include (e.g. "*.py", "*.{ts,tsx}"). Returns path:line: text for each match.
		""", ["pattern": prop("string", "Regular expression"),
		      "path": prop("string", "Folder to search in (default: project root)"),
		      "include": prop("string", "File name glob filter")], ["pattern"]),

		tool("move", "Moves or renames a file or folder.",
		     ["from": prop("string", "Existing path"), "to": prop("string", "New path")], ["from", "to"]),

		tool("delete", "Deletes a file or a folder with everything inside.", ["path": prop("string", "Path to delete")], ["path"]),

		tool("run", """
		Runs a script inside Forge and returns its console output (stdout + stderr) and exit status.
		Supports .py (pocketpy), .js (JavaScriptCore), .lua (Lua 5.4) and .c (picoc interpreter). No stdin; stops after 15 s.
		Use it to test your changes and to reproduce and fix errors.
		""", ["filePath": prop("string", "Script path relative to the project root")], ["filePath"]),

		tool("build", """
		Builds the iOS app of this project (ipa.conf + src/) into build/<NAME>.ipa with Forge's on-device clang and lld, and returns
		the result with compiler errors and warnings as <diagnostics> (path:line:col: severity: message).
		Use it after changing C / Objective-C / C++ code of an iOS app, fix every error and build again until it succeeds.
		Only for projects with ipa.conf; Swift is not compiled on the phone.
		""", [:], []),

		tool("todowrite", """
		Create and maintain a structured task list for the current task. Use it proactively when the task has 3+ steps,
		when the user gives several tasks, or asks for a plan. Keep exactly ONE item in_progress while work remains; mark items
		completed right after finishing them (never batch). Skip it for single, trivial or purely informational requests.
		States: pending, in_progress, completed, cancelled. Always send the full list.
		""", ["todos": ["type": "array", "description": "The full updated todo list",
		                "items": ["type": "object",
		                          "properties": ["content": prop("string", "Short actionable description"),
		                                         "status": ["type": "string", "enum": ["pending", "in_progress", "completed", "cancelled"]],
		                                         "id": prop("string", "Stable id")],
		                          "required": ["content", "status"]]]], ["todos"]),

		tool("webfetch", """
		Fetches a URL and returns its content as plain text (HTML is converted) — for documentation and references.
		Only use URLs from the user, from project files, or well-known documentation sites. Never invent URLs.
		""", ["url": prop("string", "Full http(s) URL"),
		      "format": ["type": "string", "enum": ["text", "html"], "description": "text (default) or raw html"]], ["url"]),
	]

	static let names: [String] = definitions.compactMap { $0["name"] as? String }

	/// Модели часто зовут Read/read_file/str_replace — приводим к нашим именам.
	static func canonical(_ name: String) -> String? {
		let n = name.lowercased().replacingOccurrences(of: "-", with: "_")
		if names.contains(n) { return n }
		let aliases: [String: String] = [
			"read_file": "read", "view": "read", "cat": "read", "open": "read",
			"edit_file": "edit", "str_replace": "edit", "replace": "edit", "str_replace_editor": "edit", "multiedit": "edit",
			"write_file": "write", "create_file": "write", "create": "write",
			"list_files": "list", "ls": "list", "list_dir": "list", "tree": "list",
			"find": "glob", "find_files": "glob", "search": "grep", "search_files": "grep", "ripgrep": "grep",
			"rename": "move", "mv": "move", "remove": "delete", "rm": "delete", "delete_file": "delete",
			"run_file": "run", "execute": "run", "exec": "run", "build_app": "build", "compile": "build", "make": "build", "build_ipa": "build", "todo": "todowrite", "todo_write": "todowrite",
			"fetch": "webfetch", "web_fetch": "webfetch",
		]
		return aliases[n]
	}

	// MARK: выполнение

	struct Result {
		var output: String
		var isError: Bool
		var summary: String   // для строки в чате
	}

	private struct ArgError: Error { let message: String }

	func run(_ rawName: String, _ input: [String: Any]) async -> Result {
		guard let name = ToolBox.canonical(rawName) else {
			return Result(output: "Unknown tool \"\(rawName)\". Available tools: \(ToolBox.names.joined(separator: ", ")).",
			              isError: true, summary: L("unknown tool %@", rawName))
		}
		if let raw = input["_raw"] as? String {
			return Result(output: "The arguments for \(name) were not valid JSON: \(raw.prefix(300)). Call the tool again with a proper JSON object.",
			              isError: true, summary: L("%@: invalid arguments", name))
		}
		do {
			let r = try await execute(name, input)
			return Result(output: ToolBox.truncate(r.0), isError: false, summary: r.1)
		} catch let e as ArgError {
			return Result(output: "Invalid arguments for tool \(name): \(e.message)", isError: true, summary: "\(name): \(e.message)")
		} catch {
			return Result(output: error.localizedDescription, isError: true, summary: "\(name): \(error.localizedDescription)")
		}
	}

	private static func truncate(_ s: String) -> String {
		let limit = 50_000
		guard s.count > limit else { return s }
		return String(s.prefix(limit)) + "\n\n… [output truncated: \(s.count - limit) more characters. Use offset/limit or a narrower search.]"
	}

	/// Аргументы: принимаем и наши имена, и привычные моделям синонимы.
	private func str(_ input: [String: Any], _ keys: [String], required: Bool = true) throws -> String? {
		for k in keys { if let v = input[k] as? String { return v } }
		if required { throw ArgError(message: "missing required parameter \"\(keys[0])\"") }
		return nil
	}

	private func int(_ input: [String: Any], _ key: String) -> Int? {
		if let v = input[key] as? Int { return v }
		if let v = input[key] as? Double { return Int(v) }
		if let v = input[key] as? String { return Int(v) }
		return nil
	}

	/// Приводит путь от модели к относительному: убирает абсолютный префикс проекта, ведущий «/», «./».
	private func rel(_ p: String) -> String {
		var s = p.trimmingCharacters(in: .whitespacesAndNewlines)
		let root = project.url.path
		if s.hasPrefix(root) { s.removeFirst(root.count) }
		if let r = s.range(of: "/" + project.name + "/"), s.hasPrefix("/") { s = String(s[r.upperBound...]) }
		while s.hasPrefix("/") || s.hasPrefix("./") { s.removeFirst(s.hasPrefix("/") ? 1 : 2) }
		while s.hasSuffix("/") { s.removeLast() }
		return s == "." ? "" : s
	}

	private func url(_ r: String) throws -> URL { r.isEmpty ? project.url : try store.resolve(r, in: project) }

	private func mtime(_ u: URL) -> Date? {
		(try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
	}

	private func requireRead(_ path: String, _ u: URL) throws {
		guard FileManager.default.fileExists(atPath: u.path) else { return }
		guard let at = readAt[path] else {
			throw StoreError("You must read \(path) with the read tool before editing or overwriting it.")
		}
		if let m = mtime(u), m > at.addingTimeInterval(0.5) {
			throw StoreError("\(path) was modified since you last read it (maybe by the user). Read it again before editing.")
		}
	}

	private func markRead(_ path: String) { readAt[path] = Date() }

	/// Запомнить файл до первой правки агента (для «Просмотреть правки» → откатить).
	private func remember(_ path: String) {
		guard originals[path] == nil, let u = try? url(path) else { return }
		var isDir: ObjCBool = false
		if !FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) { originals[path] = Original(text: nil); return }
		guard !isDir.boolValue, let t = try? String(contentsOf: u, encoding: .utf8) else { return }
		originals[path] = Original(text: t)
	}

	private func execute(_ name: String, _ input: [String: Any]) async throws -> (String, String) {
		let fm = FileManager.default
		switch name {
		case "read":
			let path = rel(try str(input, ["filePath", "path", "file_path", "file"])!)
			let u = try url(path)
			var isDir: ObjCBool = false
			guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else {
				let similar = store.entries(in: project, dirs: false)
					.filter { ($0 as NSString).lastPathComponent == (path as NSString).lastPathComponent }.prefix(5)
				throw StoreError("File not found: \(path)" + (similar.isEmpty ? "" : ". Did you mean: \(similar.joined(separator: ", "))?"))
			}
			if isDir.boolValue {
				let items = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { !Git.internalNames.contains($0) }.sorted()
				let lines = items.map { item -> String in
					var d: ObjCBool = false
					fm.fileExists(atPath: u.appendingPathComponent(item).path, isDirectory: &d)
					return d.boolValue ? item + "/" : item
				}
				return ("<path>\(path.isEmpty ? "." : path)</path>\n<type>directory</type>\n" + lines.joined(separator: "\n"), path.isEmpty ? L("viewing the project") : L("viewing %@/", path))
			}
			guard let data = fm.contents(atPath: u.path) else { throw StoreError("Cannot read \(path)") }
			guard let text = String(data: data, encoding: .utf8) else {
				return ("<path>\(path)</path>\n(binary file, \(data.count) bytes — cannot display)", L("reading %@ (binary)", path))
			}
			markRead(path)
			var all = text.components(separatedBy: "\n")
			if all.last == "" { all.removeLast() }
			let offset = max(1, int(input, "offset") ?? 1)
			let limit = max(1, int(input, "limit") ?? 2000)
			if all.isEmpty { return ("<path>\(path)</path>\n<type>file</type>\n(empty file)", L("reading %@", path)) }
			guard offset <= all.count else { throw StoreError("offset \(offset) is beyond the end of the file (\(all.count) lines)") }
			let end = min(all.count, offset + limit - 1)
			var out = "<path>\(path)</path>\n<type>file</type>\n<content>\n"
			for i in (offset - 1)..<end {
				let line = all[i]
				out += "\(i + 1): " + (line.count > 2000 ? String(line.prefix(2000)) + "... (line truncated to 2000 chars)" : line) + "\n"
			}
			out += "</content>\n"
			out += end < all.count ? "\n(Showing lines \(offset)-\(end) of \(all.count). Use offset=\(end + 1) to continue.)"
			                       : "\n(End of file - total \(all.count) lines)"
			return (out, L("reading %@", path) + (offset > 1 || end < all.count ? " [\(offset)–\(end)]" : ""))

		case "edit":
			let path = rel(try str(input, ["filePath", "path", "file_path"])!)
			let old = try str(input, ["oldString", "old_string", "old_str", "old"])!
			let new = try str(input, ["newString", "new_string", "new_str", "new"])!
			let all = (input["replaceAll"] as? Bool) ?? (input["replace_all"] as? Bool) ?? false
			let u = try url(path)
			if !fm.fileExists(atPath: u.path) {
				guard old.isEmpty else { throw StoreError("File not found: \(path). Use write to create a new file.") }
				remember(path)
				try store.write(path, new, in: project)
				markRead(path)
				return ("Created \(path).", L("creating %@", path))
			}
			try requireRead(path, u)
			let content = try store.read(path, in: project)
			let updated = try Replace.replace(content, old, new, all: all)
			remember(path)
			try store.write(path, updated, in: project)
			markRead(path)
			let delta = updated.components(separatedBy: "\n").count - content.components(separatedBy: "\n").count
			let diag = await diagnose(updated, path)
			return ("Edit applied successfully." + diag.0, L("editing %@", path) + (delta == 0 ? "" : L(" (%@%@ lines)", delta > 0 ? "+" : "", delta)) + diag.1)

		case "write":
			let path = rel(try str(input, ["filePath", "path", "file_path"])!)
			let content = try str(input, ["content", "text", "contents"])!
			guard !path.isEmpty else { throw ArgError(message: "filePath is empty") }
			let u = try url(path)
			let existed = fm.fileExists(atPath: u.path)
			if existed { try requireRead(path, u) }
			remember(path)
			try store.write(path, content, in: project)
			markRead(path)
			let n = content.components(separatedBy: "\n").count
			let diag = await diagnose(content, path)
			return ("Wrote \(path) (\(n) lines)." + diag.0, L(existed ? "overwriting %@ (%@ lines)" : "creating %@ (%@ lines)", path, n) + diag.1)

		case "list":
			let dir = rel(try str(input, ["path", "dir", "directory"], required: false) ?? "")
			let tree = ToolBox.tree(store.entries(in: project), under: dir, limit: 500)
			return (tree.isEmpty ? "(empty)" : tree, dir.isEmpty ? L("viewing the project tree") : L("viewing the tree of %@", dir))

		case "glob":
			let pattern = try str(input, ["pattern", "glob"])!
			let dir = rel(try str(input, ["path", "dir"], required: false) ?? "")
			let re = try ToolBox.globRegex(pattern)
			let byName = !pattern.contains("/")
			var hits: [(String, Date)] = []
			for f in store.entries(in: project, dirs: false) where !ToolBox.junk(f) {
				guard dir.isEmpty || f.hasPrefix(dir + "/") else { continue }
				let subject = byName ? (f as NSString).lastPathComponent : (dir.isEmpty ? f : String(f.dropFirst(dir.count + 1)))
				if re.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil {
					hits.append((f, mtime(project.url.appendingPathComponent(f)) ?? .distantPast))
				}
			}
			hits.sort { $0.1 > $1.1 }
			let shown = hits.prefix(200).map(\.0)
			return (shown.isEmpty ? "No files found" : shown.joined(separator: "\n") + (hits.count > 200 ? "\n(… \(hits.count - 200) more)" : ""),
			        L("searching files %@", pattern))

		case "grep":
			let pattern = try str(input, ["pattern", "query", "regex"])!
			let dir = rel(try str(input, ["path", "dir"], required: false) ?? "")
			let include = try str(input, ["include", "glob"], required: false)
			guard let re = try? NSRegularExpression(pattern: pattern) else { throw ArgError(message: "invalid regular expression") }
			let inc = try include.map(ToolBox.globRegex)
			var out: [String] = []
			var count = 0
			outer: for f in store.entries(in: project, dirs: false) where !ToolBox.junk(f) {
				guard dir.isEmpty || f.hasPrefix(dir + "/") else { continue }
				if let inc {
					let n = (f as NSString).lastPathComponent
					if inc.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) == nil { continue }
				}
				guard let text = try? String(contentsOf: project.url.appendingPathComponent(f), encoding: .utf8) else { continue }
				var ln = 0
				for line in text.components(separatedBy: "\n") {
					ln += 1
					if re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
						out.append("\(f):\(ln): \(line.trimmingCharacters(in: .whitespaces).prefix(300))")
						count += 1
						if count >= 200 { break outer }
					}
				}
			}
			return (out.isEmpty ? "No matches found" : "Found \(count)\(count >= 200 ? "+" : "") matches\n" + out.joined(separator: "\n"),
			        L("searching “%@”", pattern))

		case "move":
			let from = rel(try str(input, ["from", "source", "oldPath"])!), to = rel(try str(input, ["to", "destination", "newPath"])!)
			remember(from)
			remember(to)
			try store.move(from, to: to, in: project)
			if let t = readAt.removeValue(forKey: from) { readAt[to] = t }
			return ("Moved \(from) → \(to)", L("moving %@ → %@", from, to))

		case "delete":
			let path = rel(try str(input, ["path", "filePath", "file_path"])!)
			guard !path.isEmpty else { throw ArgError(message: "refusing to delete the whole project") }
			remember(path)
			try store.remove(path, in: project)
			return ("Deleted \(path)", L("deleting %@", path))

		case "run":
			let path = rel(try str(input, ["filePath", "path", "file_path"])!)
			guard let kind = RunKind.detect(path), kind != .web else {
				throw StoreError("run supports .py .js .lua .c (and .cpp .m .mm when native run is available) files (HTML is previewed by the user)")
			}
			let out = await Runner.shared.capture(try url(path))
			return (out, L("running %@", path))

		case "build":
			guard fm.fileExists(atPath: project.url.appendingPathComponent("ipa.conf").path) else {
				throw StoreError("This project has no ipa.conf — it is not an iOS app. Use run for scripts.")
			}
			guard IpaBuilder.available else {
				throw StoreError("This Forge build has no on-device compiler — the user builds the app with ipab on a computer. Check your code carefully instead.")
			}
			let (out, code) = await Runner.shared.captureBuild(project.url)
			let issues = Clang.issues(in: out)
			let root = project.url.path + "/"
			var text = code == 0 ? "Build succeeded: " + (out.components(separatedBy: "\n").last { $0.hasPrefix("==> done") } ?? "build/")
			                     : "Build FAILED (exit code \(code))."
			if !issues.isEmpty {
				text += "\n<diagnostics>\n" + issues.prefix(50).map { i in
					let f = i.file.hasPrefix(root) ? String(i.file.dropFirst(root.count)) : i.file
					return (f.isEmpty ? "" : "\(f):\(i.line):\(i.col): ") + "\(i.severity): \(i.message)"
				}.joined(separator: "\n") + "\n</diagnostics>"
			}
			if code != 0 { text += "\n\nBuild log (end):\n" + String(out.suffix(4000)) }
			let errors = issues.filter(\.isError).count
			return (text, code == 0 ? L("building the app — success") : L("building the app — %@ errors", max(errors, 1)))

		case "todowrite":
			guard let list = input["todos"] as? [[String: Any]] else { throw ArgError(message: "todos must be an array") }
			let valid = ["pending", "in_progress", "completed", "cancelled"]
			todos = list.enumerated().map { i, t in
				let s = (t["status"] as? String ?? "pending").lowercased()
				return Todo(id: t["id"] as? String ?? "\(i + 1)", content: t["content"] as? String ?? "", status: valid.contains(s) ? s : "pending")
			}
			let left = todos.filter { $0.status == "pending" || $0.status == "in_progress" }.count
			let json = (try? JSONSerialization.data(withJSONObject: todos.map { ["content": $0.content, "status": $0.status, "id": $0.id] }))
				.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
			return ("\(left) todos remaining\n\(json)", L("plan: %@ of %@ left", left, todos.count))

		case "webfetch":
			let s = try str(input, ["url"])!
			guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
				throw ArgError(message: "url must start with http:// or https://")
			}
			var req = URLRequest(url: u)
			req.timeoutInterval = 30
			req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Forge", forHTTPHeaderField: "User-Agent")
			let (d, r) = try await URLSession.shared.data(for: req)
			let code = (r as? HTTPURLResponse)?.statusCode ?? 0
			guard (200..<400).contains(code) else { throw StoreError("HTTP \(code) for \(s)") }
			let body = String(decoding: d.prefix(5_000_000), as: UTF8.self)
			let isHTML = ((r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html") || body.contains("<html")
			let text = isHTML && (input["format"] as? String) != "html" ? ToolBox.htmlToText(body) : body
			return (text, L("reading %@", u.host ?? s))

		default:
			throw StoreError("unknown tool \(name)")
		}
	}

	// MARK: помощники

	/// Диагностика после правки: clang для C-семейства (если есть компилятор), иначе встроенные движки.
	private func diagnose(_ text: String, _ path: String) async -> (String, String) {
		let isApp = FileManager.default.fileExists(atPath: project.url.appendingPathComponent("ipa.conf").path)
		guard IpaBuilder.available, Clang.supports(path), isApp || (path as NSString).pathExtension.lowercased() != "c",
		      let u = try? url(path) else { return ToolBox.diagnostics(text, path) }
		let errors = await Clang.check(text, file: u, project: project.url).filter(\.isError)
		guard !errors.isEmpty else { return ("", "") }
		let lines = errors.prefix(10).map { "line \($0.line):\($0.col): \($0.message)" }.joined(separator: "\n")
		return ("\n\n<diagnostics file=\"\(path)\">\n\(lines)\n</diagnostics>\nFix these errors before continuing (unless a later planned edit fixes them).",
		        L(" ⚠︎ errors: %@", errors.count))
	}

	/// Синтаксическая ошибка после правки — сразу сообщаем модели (как диагностика LSP в opencode).
	static func diagnostics(_ text: String, _ path: String) -> (String, String) {
		guard SyntaxCheck.supports(path), let d = SyntaxCheck.check(text, path: path) else { return ("", "") }
		return ("\n\n<diagnostics file=\"\(path)\">\nSyntax error\(d.line > 0 ? " at line \(d.line)" : ""): \(d.message)\n</diagnostics>\nFix this error before continuing.",
		        L(" ⚠︎ syntax: line %@", d.line))
	}

	/// Папки, которые почти никогда не нужны модели.
	nonisolated static func junk(_ path: String) -> Bool {
		let skip: Set<String> = ["node_modules", "build", "dist", ".build", "__pycache__", ".venv", "venv", "Pods", "DerivedData", ".next", "target"]
		return path.split(separator: "/").dropLast().contains { skip.contains(String($0)) }
	}

	nonisolated static func tree(_ entries: [String], under dir: String, limit: Int) -> String {
		var out: [String] = []
		var hidden = 0
		for e in entries {
			let isDir = e.hasSuffix("/")
			let p = isDir ? String(e.dropLast()) : e
			guard dir.isEmpty || p.hasPrefix(dir + "/") else { continue }
			let r = dir.isEmpty ? p : String(p.dropFirst(dir.count + 1))
			if junk(p + (isDir ? "/x" : "")) { continue }
			if out.count >= limit { hidden += 1; continue }
			let depth = r.split(separator: "/").count - 1
			out.append(String(repeating: "  ", count: depth) + (r as NSString).lastPathComponent + (isDir ? "/" : ""))
		}
		return out.joined(separator: "\n") + (hidden > 0 ? "\n(… \(hidden) more entries)" : "")
	}

	/// glob → regex: ** / * / ? / {a,b}
	nonisolated static func globRegex(_ g: String) throws -> NSRegularExpression {
		var r = "^"
		let c = Array(g)
		var i = 0
		var inBrace = false
		while i < c.count {
			let ch = c[i]
			switch ch {
			case "*":
				if i + 1 < c.count && c[i + 1] == "*" {
					if i + 2 < c.count && c[i + 2] == "/" { r += "(?:.*/)?"; i += 2 } else { r += ".*"; i += 1 }
				} else { r += "[^/]*" }
			case "?": r += "[^/]"
			case "{": r += "(?:"; inBrace = true
			case "}": r += ")"; inBrace = false
			case ",": r += inBrace ? "|" : ","
			default: r += NSRegularExpression.escapedPattern(for: String(ch))
			}
			i += 1
		}
		guard let re = try? NSRegularExpression(pattern: r + "$", options: [.caseInsensitive]) else {
			throw ArgError(message: "invalid glob pattern")
		}
		return re
	}

	nonisolated static func htmlToText(_ html: String) -> String {
		var s = html
		for tag in ["script", "style", "noscript", "svg", "head"] {
			s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
		}
		s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
		s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
		s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
		for (e, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'"] {
			s = s.replacingOccurrences(of: e, with: v)
		}
		s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
		s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
		return s.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
