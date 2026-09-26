import Foundation

/// Менеджер пакетов проекта: модули из интернета для скриптов и приложений.
/// - Python (PyPI) → py_modules/ — только чистый Python (wheel py3-none-any или исходники без C-расширений);
///   интерпретатор — pocketpy, так что работают не все пакеты.
/// - JavaScript (npm) → node_modules/ — с зависимостями; require('имя') ищет там, как Node (без его API: fs, http…).
/// - Lua (LuaRocks) → lua_modules/ — модули на чистом Lua (build.modules из rockspec).
/// - C/C++ → vendor/ (src/vendor/ в iOS-проекте) — каталог библиотек из заголовков.
/// Что поставлено вручную, записано в packages.json (для «Восстановить всё» после клона).
enum Ecosystem: String, CaseIterable, Identifiable {
	case pypi, npm, luarocks, c
	var id: String { rawValue }

	var title: String {
		switch self {
		case .pypi: return "Python"
		case .npm: return "JavaScript"
		case .luarocks: return "Lua"
		case .c: return "C / C++"
		}
	}

	var registry: String {
		switch self {
		case .pypi: return "PyPI"
		case .npm: return "npm"
		case .luarocks: return "LuaRocks"
		case .c: return L("catalog")
		}
	}

	/// Папка установленных пакетов (не уходит в git, кроме vendor/ — это исходники).
	func folder(_ project: URL) -> URL {
		switch self {
		case .pypi: return project.appendingPathComponent("py_modules")
		case .npm: return project.appendingPathComponent("node_modules")
		case .luarocks: return project.appendingPathComponent("lua_modules")
		case .c:
			let src = project.appendingPathComponent("src")
			return FileManager.default.fileExists(atPath: src.path) ? src.appendingPathComponent("vendor") : project.appendingPathComponent("vendor")
		}
	}

	/// Синонимы для агента: pip, python, node, js…
	static func parse(_ s: String) -> Ecosystem? {
		switch s.lowercased() {
		case "pypi", "pip", "python", "py": return .pypi
		case "npm", "node", "javascript", "js": return .npm
		case "luarocks", "lua", "rocks": return .luarocks
		case "c", "c++", "cpp", "vendor", "header": return .c
		default: return nil
		}
	}
}

/// Библиотека из каталога C/C++: файлы по прямым ссылкам.
struct CLibrary: Identifiable {
	let id: String
	let title: String
	let note: String
	let files: [String]

	static let catalog: [CLibrary] = [
		CLibrary(id: "stb_image", title: "stb_image", note: "PNG/JPEG/GIF… decoding",
		         files: ["https://raw.githubusercontent.com/nothings/stb/master/stb_image.h"]),
		CLibrary(id: "stb_image_write", title: "stb_image_write", note: "PNG/JPEG/BMP writing",
		         files: ["https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h"]),
		CLibrary(id: "stb_truetype", title: "stb_truetype", note: "TrueType font rasterizer",
		         files: ["https://raw.githubusercontent.com/nothings/stb/master/stb_truetype.h"]),
		CLibrary(id: "stb_ds", title: "stb_ds", note: "dynamic arrays and hash maps for C",
		         files: ["https://raw.githubusercontent.com/nothings/stb/master/stb_ds.h"]),
		CLibrary(id: "cjson", title: "cJSON", note: "JSON parser/printer for C",
		         files: ["https://raw.githubusercontent.com/DaveGamble/cJSON/master/cJSON.h",
		                 "https://raw.githubusercontent.com/DaveGamble/cJSON/master/cJSON.c"]),
		CLibrary(id: "nlohmann_json", title: "nlohmann/json", note: "JSON for modern C++ (json.hpp)",
		         files: ["https://raw.githubusercontent.com/nlohmann/json/develop/single_include/nlohmann/json.hpp"]),
		CLibrary(id: "miniaudio", title: "miniaudio", note: "audio playback and capture",
		         files: ["https://raw.githubusercontent.com/mackron/miniaudio/master/miniaudio.h"]),
		CLibrary(id: "dr_wav", title: "dr_wav", note: "WAV reading/writing",
		         files: ["https://raw.githubusercontent.com/mackron/dr_libs/master/dr_wav.h"]),
		CLibrary(id: "dr_mp3", title: "dr_mp3", note: "MP3 decoding",
		         files: ["https://raw.githubusercontent.com/mackron/dr_libs/master/dr_mp3.h"]),
		CLibrary(id: "linmath", title: "linmath.h", note: "vectors and matrices for graphics",
		         files: ["https://raw.githubusercontent.com/datenwolf/linmath.h/master/linmath.h"]),
		CLibrary(id: "tinyexpr", title: "TinyExpr", note: "math expression evaluator",
		         files: ["https://raw.githubusercontent.com/codeplea/tinyexpr/master/tinyexpr.h",
		                 "https://raw.githubusercontent.com/codeplea/tinyexpr/master/tinyexpr.c"]),
		CLibrary(id: "sqlite_note", title: "SQLite", note: "already in iOS: add sqlite3 to LIBS and #include <sqlite3.h>", files: []),
	]
}

struct PackageFailure: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}

/// Установка и удаление пакетов одного проекта. Вызывается не с главного потока.
final class PackageManager {
	let project: URL
	let log: (String) -> Void
	private var installedThisRun = Set<String>()
	private var count = 0
	private static let maxPackages = 200

	init(project: URL, log: @escaping (String) -> Void) {
		self.project = project
		self.log = log
	}

	// MARK: packages.json

	var manifestURL: URL { project.appendingPathComponent("packages.json") }

	func manifest() -> [String: [String: String]] {
		guard let d = try? Data(contentsOf: manifestURL),
		      let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] else { return [:] }
		return j
	}

	private func record(_ eco: Ecosystem, _ name: String, _ version: String?) {
		var m = manifest()
		var e = m[eco.rawValue] ?? [:]
		e[name] = version
		m[eco.rawValue] = e.isEmpty ? nil : e
		if m.isEmpty { try? FileManager.default.removeItem(at: manifestURL); return }
		if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
			try? d.write(to: manifestURL, options: .atomic)
		}
	}

	/// Установленные вручную пакеты экосистемы (имя → версия).
	func installed(_ eco: Ecosystem) -> [(String, String)] {
		(manifest()[eco.rawValue] ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }.map { ($0.key, $0.value) }
	}

	// MARK: общие операции

	/// spec: «имя», «имя@версия» (npm, LuaRocks) или «имя==версия» (PyPI).
	func install(_ eco: Ecosystem, _ spec: String) async throws {
		let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !s.isEmpty else { throw PackageFailure(message: L("Enter a package name")) }
		ignoreInGit()
		switch eco {
		case .npm:
			var name = s, range = "latest"
			// @scope/name@1.2 — версия после последней @, если она не в начале
			if let at = s.lastIndex(of: "@"), at != s.startIndex { name = String(s[..<at]); range = String(s[s.index(after: at)...]) }
			let v = try await npmInstall(name, range)
			record(.npm, name, range == "latest" ? "^" + v : range)
		case .pypi:
			let parts = s.components(separatedBy: "==")
			let v = try await pypiInstall(parts[0], version: parts.count > 1 ? parts[1] : nil)
			record(.pypi, Self.pyNormalize(parts[0]), v)
		case .luarocks:
			let parts = s.components(separatedBy: "@")
			let v = try await rockInstall(parts[0], version: parts.count > 1 ? parts[1] : nil)
			record(.luarocks, parts[0], v)
		case .c:
			guard let lib = CLibrary.catalog.first(where: { $0.id == s || $0.title.lowercased() == s.lowercased() }) else {
				throw PackageFailure(message: L("No such library in the catalog: %@", s))
			}
			try await cInstall(lib)
			record(.c, lib.id, "latest")
		}
	}

	func remove(_ eco: Ecosystem, _ name: String) throws {
		let fm = FileManager.default
		switch eco {
		case .npm:
			try? fm.removeItem(at: eco.folder(project).appendingPathComponent(name))
		case .pypi:
			for f in pyRecordFiles(name) { try? fm.removeItem(at: eco.folder(project).appendingPathComponent(f)) }
			removeEmptyDirs(eco.folder(project))
		case .luarocks:
			let rec = eco.folder(project).appendingPathComponent(".rocks/\(name).txt")
			for f in ((try? String(contentsOf: rec, encoding: .utf8)) ?? "").split(separator: "\n") {
				try? fm.removeItem(at: eco.folder(project).appendingPathComponent(String(f)))
			}
			try? fm.removeItem(at: rec)
			removeEmptyDirs(eco.folder(project))
		case .c:
			if let lib = CLibrary.catalog.first(where: { $0.id == name }) {
				for u in lib.files { try? fm.removeItem(at: eco.folder(project).appendingPathComponent((u as NSString).lastPathComponent)) }
			}
		}
		record(eco, name, nil)
		log(L("removed %@", name))
	}

	/// Всё из packages.json — после клона проекта или чтобы собрать заново.
	func restoreAll() async throws {
		for eco in Ecosystem.allCases {
			for (name, v) in installed(eco) {
				switch eco {
				case .npm: _ = try await npmInstall(name, v)
				case .pypi: _ = try await pypiInstall(name, version: v)
				case .luarocks: _ = try await rockInstall(name, version: v)
				case .c: if let lib = CLibrary.catalog.first(where: { $0.id == name }) { try await cInstall(lib) }
				}
			}
		}
		ignoreInGit()
	}

	/// Корень проекта файла: первая папка под Documents (там py_modules/, node_modules/…).
	static func projectRoot(of url: URL) -> URL {
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
		let p = url.standardizedFileURL.path
		guard p.hasPrefix(docs + "/"), let first = p.dropFirst(docs.count + 1).split(separator: "/").first else {
			return url.deletingLastPathComponent()
		}
		return URL(fileURLWithPath: docs).appendingPathComponent(String(first))
	}

	/// Пути для движков: import Python и require Lua.
	static func modulePaths(_ project: URL) -> (python: String, lua: String) {
		let py = Ecosystem.pypi.folder(project).path, lua = Ecosystem.luarocks.folder(project).path
		return (py, "\(lua)/?.lua;\(lua)/?/init.lua")
	}

	// MARK: сеть

	private func get(_ url: URL, accept: String? = nil) async throws -> Data {
		var req = URLRequest(url: url)
		req.timeoutInterval = 60
		req.setValue("Forge (iOS IDE)", forHTTPHeaderField: "User-Agent")
		if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
		let (d, r) = try await URLSession.shared.data(for: req)
		let code = (r as? HTTPURLResponse)?.statusCode ?? 0
		guard code == 200 else {
			throw PackageFailure(message: code == 404 ? L("Not found: %@", url.absoluteString) : "HTTP \(code): \(url.absoluteString)")
		}
		return d
	}

	private func json(_ url: URL, accept: String? = nil) async throws -> [String: Any] {
		guard let j = try JSONSerialization.jsonObject(with: try await get(url, accept: accept)) as? [String: Any] else {
			throw PackageFailure(message: L("Unexpected answer from %@", url.host ?? ""))
		}
		return j
	}

	private func counted() throws {
		count += 1
		if count > Self.maxPackages { throw PackageFailure(message: L("Too many dependencies (more than %@) — stopped", Self.maxPackages)) }
	}

	// MARK: npm

	private func npmInstall(_ name: String, _ range: String) async throws -> String {
		let root = Ecosystem.npm.folder(project)
		let dir = root.appendingPathComponent(name)
		// уже есть подходящая версия — не качаем (зависимости у всех общие, как в npm с поднятием)
		if let pj = try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("package.json"))) as? [String: Any],
		   let have = pj["version"] as? String, range == "latest" ? installedThisRun.contains("npm:" + name) : Semver.satisfies(have, range) {
			return have
		}
		try counted()
		let enc = name.replacingOccurrences(of: "/", with: "%2F")
		let doc = try await json(URL(string: "https://registry.npmjs.org/\(enc)")!, accept: "application/vnd.npm.install-v1+json")
		let versions = doc["versions"] as? [String: [String: Any]] ?? [:]
		let tags = doc["dist-tags"] as? [String: String] ?? [:]
		guard let version = tags[range] ?? Semver.best(Array(versions.keys), range), let meta = versions[version],
		      let tarball = (meta["dist"] as? [String: Any])?["tarball"] as? String, let tu = URL(string: tarball) else {
			throw PackageFailure(message: L("npm: no version of %@ matches %@", name, range))
		}
		log("npm  \(name)@\(version)")
		let entries = try Git.untar(try Git.gunzip(try await get(tu)))
		try? FileManager.default.removeItem(at: dir)
		for e in entries {
			// в архиве всё лежит в package/ (иногда в другой папке) — убираем первый компонент
			guard let slash = e.path.firstIndex(of: "/") else { continue }
			let rel = String(e.path[e.path.index(after: slash)...])
			guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else { continue }
			let u = dir.appendingPathComponent(rel)
			try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
			try e.data.write(to: u)
		}
		installedThisRun.insert("npm:" + name)
		for (dep, r) in (meta["dependencies"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
			if r.contains(":") || r.contains("/") {  // git, file:, url — не поддерживаем
				log(L("  skipped %@ (%@)", dep, r))
				continue
			}
			_ = try await npmInstall(dep, r)
		}
		return version
	}

	// MARK: PyPI

	static func pyNormalize(_ n: String) -> String {
		n.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
	}

	/// Файлы пакета из его dist-info/RECORD (для удаления и проверки «уже стоит»).
	private func pyDistInfo(_ name: String) -> URL? {
		let key = Self.pyNormalize(name).replacingOccurrences(of: "-", with: "_")
		let root = Ecosystem.pypi.folder(project)
		return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).first {
			$0.hasSuffix(".dist-info") && $0.lowercased().replacingOccurrences(of: "-", with: "_").hasPrefix(key + "_")
		}.map { root.appendingPathComponent($0) }
	}

	private func pyRecordFiles(_ name: String) -> [String] {
		guard let di = pyDistInfo(name) else { return [] }
		let rec = (try? String(contentsOf: di.appendingPathComponent("RECORD"), encoding: .utf8)) ?? ""
		var files = rec.split(separator: "\n").compactMap { $0.split(separator: ",").first.map(String.init) }
		files.append(di.lastPathComponent)
		return files
	}

	private func pypiInstall(_ rawName: String, version: String?) async throws -> String {
		let name = Self.pyNormalize(rawName)
		if installedThisRun.contains("py:" + name) { return version ?? "" }
		if version == nil, pyDistInfo(name) != nil, !installedThisRun.isEmpty { return "" }  // зависимость уже стоит
		try counted()
		let path = version.map { "\(name)/\($0)" } ?? name
		let doc = try await json(URL(string: "https://pypi.org/pypi/\(path)/json")!)
		let info = doc["info"] as? [String: Any] ?? [:]
		let v = info["version"] as? String ?? version ?? "?"
		let files = doc["urls"] as? [[String: Any]] ?? []
		let root = Ecosystem.pypi.folder(project)
		let fm = FileManager.default
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		for f in pyRecordFiles(name) { try? fm.removeItem(at: root.appendingPathComponent(f)) }
		log("pip  \(name)==\(v)")

		let wheel = files.first { ($0["filename"] as? String ?? "").hasSuffix("-none-any.whl") && ($0["filename"] as? String ?? "").contains("py3") }
		if let w = wheel, let s = w["url"] as? String, let u = URL(string: s) {
			let tmp = fm.temporaryDirectory.appendingPathComponent("forge-whl-\(UUID().uuidString)")
			defer { try? fm.removeItem(at: tmp) }
			let whl = tmp.appendingPathExtension("whl")
			try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
			try await get(u).write(to: whl)
			defer { try? fm.removeItem(at: whl) }
			try Unzip.unpack(whl, to: tmp)
			for item in try fm.contentsOfDirectory(atPath: tmp.path) where !item.hasSuffix(".data") {
				let dst = root.appendingPathComponent(item)
				try? fm.removeItem(at: dst)
				try fm.copyItem(at: tmp.appendingPathComponent(item), to: dst)
			}
		} else if let sd = files.first(where: { $0["packagetype"] as? String == "sdist" && ($0["filename"] as? String ?? "").hasSuffix(".tar.gz") }),
		          let s = sd["url"] as? String, let u = URL(string: s) {
			// исходники: берём пакеты (папки с __init__.py) и модули верхнего уровня, в том числе из src/
			let entries = try Git.untar(try Git.gunzip(try await get(u)))
			var rels: [(String, Data)] = entries.compactMap { e in
				guard let slash = e.path.firstIndex(of: "/") else { return nil }
				var r = String(e.path[e.path.index(after: slash)...])
				if r.hasPrefix("src/") { r.removeFirst(4) }
				return (r, e.data)
			}
			let packages = Set(rels.compactMap { r -> String? in
				let p = r.0.split(separator: "/")
				return p.count == 2 && p[1] == "__init__.py" ? String(p[0]) : nil
			}).subtracting(["tests", "test", "docs", "examples"])
			rels = rels.filter { r in
				let p = r.0.split(separator: "/")
				if p.count == 1 { return r.0.hasSuffix(".py") && !["setup.py", "conftest.py"].contains(r.0) }
				return packages.contains(String(p[0])) && r.0.hasSuffix(".py")
			}
			guard !rels.isEmpty else { throw PackageFailure(message: L("PyPI: no Python code found in %@", name)) }
			let di = "\(name.replacingOccurrences(of: "-", with: "_"))-\(v).dist-info"
			var record = ""
			for (r, d) in rels {
				let dst = root.appendingPathComponent(r)
				try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
				try d.write(to: dst)
				record += r + ",,\n"
			}
			try fm.createDirectory(at: root.appendingPathComponent(di), withIntermediateDirectories: true)
			try record.write(to: root.appendingPathComponent(di + "/RECORD"), atomically: true, encoding: .utf8)
		} else {
			throw PackageFailure(message: L("PyPI: %@ has no pure-Python version (it needs compiled C code, which Forge cannot run)", name))
		}
		installedThisRun.insert("py:" + name)
		// зависимости без «extra» (необязательные группы пропускаем)
		for req in info["requires_dist"] as? [String] ?? [] where !req.contains("extra ==") && !req.contains("extra==") {
			guard let r = req.range(of: "^[A-Za-z0-9._-]+", options: .regularExpression) else { continue }
			_ = try await pypiInstall(String(req[r]), version: nil)
		}
		return v
	}

	// MARK: LuaRocks

	private static var rocksManifest: [String: [String: Any]]?

	private func rocks() async throws -> [String: [String: Any]] {
		if let m = Self.rocksManifest { return m }
		let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("luarocks-manifest-5.4.json")
		let fresh = ((try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) < 86400 }) ?? false
		var data = fresh ? try? Data(contentsOf: cache) : nil
		if data == nil {
			log(L("downloading the LuaRocks list…"))
			data = try await get(URL(string: "https://luarocks.org/manifest-5.4.json")!)
			try? data?.write(to: cache)
		}
		guard let d = data, let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
		      let repo = j["repository"] as? [String: [String: Any]] else { throw PackageFailure(message: L("LuaRocks: bad package list")) }
		Self.rocksManifest = repo
		return repo
	}

	private func rockInstall(_ name: String, version: String?) async throws -> String {
		if installedThisRun.contains("rock:" + name) { return version ?? "" }
		let root = Ecosystem.luarocks.folder(project)
		let rec = root.appendingPathComponent(".rocks/\(name).txt")
		if version == nil, !installedThisRun.isEmpty, FileManager.default.fileExists(atPath: rec.path) { return "" }
		try counted()
		let repo = try await rocks()
		guard let versions = repo[name]?.keys, !versions.isEmpty else { throw PackageFailure(message: L("LuaRocks: no package %@", name)) }
		let v = version ?? versions.filter { !$0.hasPrefix("scm") && !$0.hasPrefix("dev") }.max(by: Semver.rockLess) ?? versions.max(by: Semver.rockLess)!
		let text = String(decoding: try await get(URL(string: "https://luarocks.org/\(name)-\(v).rockspec")!), as: UTF8.self)
		var err: UnsafeMutablePointer<CChar>?
		guard let p = forge_parse_rockspec(text, &err) else {
			let m = err.map { String(cString: $0) } ?? "?"
			free(err)
			throw PackageFailure(message: "rockspec: \(m)")
		}
		let spec = String(cString: p)
		free(p)
		var fields: [String: String] = [:], mods: [(String, String)] = [], deps: [String] = []
		for line in spec.split(separator: "\n") {
			let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			if f[0] == "mod", f.count >= 3 { mods.append((f[1], f[2])) }
			else if f[0] == "dep", f.count >= 2 { deps.append(f[1]) }
			else if f.count >= 2 { fields[f[0]] = f[1] }
		}
		guard ["builtin", "module", "none"].contains(fields["type"] ?? "builtin"), !mods.isEmpty else {
			throw PackageFailure(message: L("LuaRocks: %@ is not a pure-Lua package (build type %@)", name, fields["type"] ?? "?"))
		}
		if let c = mods.first(where: { !$0.1.hasSuffix(".lua") }) {
			throw PackageFailure(message: L("LuaRocks: %@ needs C code (module %@) — not supported", name, c.0))
		}
		log("rock \(name) \(v)")
		let files = try await rockSource(fields)
		var written: [String] = []
		for (mod, file) in mods {
			guard let data = files[file] else { throw PackageFailure(message: L("LuaRocks: %@ not found in the source of %@", file, name)) }
			let rel = mod.replacingOccurrences(of: ".", with: "/") + ".lua"
			let dst = root.appendingPathComponent(rel)
			try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
			try data.write(to: dst)
			written.append(rel)
		}
		try FileManager.default.createDirectory(at: rec.deletingLastPathComponent(), withIntermediateDirectories: true)
		try written.joined(separator: "\n").write(to: rec, atomically: true, encoding: .utf8)
		installedThisRun.insert("rock:" + name)
		for d in deps {
			let dn = String(d.split(separator: " ").first ?? "")
			if dn.isEmpty || dn == "lua" { continue }
			_ = try await rockInstall(dn, version: nil)
		}
		return v
	}

	/// Исходники пакета: путь внутри архива (без верхней папки) → содержимое.
	private func rockSource(_ f: [String: String]) async throws -> [String: Data] {
		guard var url = f["url"] else { throw PackageFailure(message: L("LuaRocks: the rockspec has no source URL")) }
		// git+https://github.com/o/r.git → архив GitHub нужного тега/ветки
		if url.hasPrefix("git"), let r = url.range(of: "github.com/") {
			var repo = String(url[r.upperBound...])
			if repo.hasSuffix(".git") { repo.removeLast(4) }
			url = "https://codeload.github.com/\(repo)/tar.gz/\(f["tag"] ?? f["branch"] ?? "HEAD")"
		} else if url.hasPrefix("git") {
			throw PackageFailure(message: L("LuaRocks: only GitHub git sources are supported (%@)", url))
		}
		guard let u = URL(string: url) else { throw PackageFailure(message: "bad url \(url)") }
		let data = try await get(u)
		var out: [String: Data] = [:]
		func strip(_ p: String) -> String? {
			guard let s = p.firstIndex(of: "/") else { return nil }
			return String(p[p.index(after: s)...])
		}
		if url.hasSuffix(".zip") {
			let fm = FileManager.default
			let tmp = fm.temporaryDirectory.appendingPathComponent("forge-rock-\(UUID().uuidString)")
			defer { try? fm.removeItem(at: tmp); try? fm.removeItem(at: tmp.appendingPathExtension("zip")) }
			try data.write(to: tmp.appendingPathExtension("zip"))
			try Unzip.unpack(tmp.appendingPathExtension("zip"), to: tmp)
			if let e = fm.enumerator(atPath: tmp.path) {
				while let p = e.nextObject() as? String {
					if let r = strip(p), let d = fm.contents(atPath: tmp.appendingPathComponent(p).path) { out[r] = d }
				}
			}
		} else {
			for e in try Git.untar(try Git.gunzip(data)) { if let r = strip(e.path) { out[r] = e.data } }
		}
		return out
	}

	// MARK: C/C++

	private func cInstall(_ lib: CLibrary) async throws {
		guard !lib.files.isEmpty else { throw PackageFailure(message: lib.note) }
		let dir = Ecosystem.c.folder(project)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		for s in lib.files {
			guard let u = URL(string: s) else { continue }
			let name = u.lastPathComponent
			log("c    \(name)")
			try await get(u).write(to: dir.appendingPathComponent(name))
		}
	}

	// MARK: -

	/// Установленные модули не уходят в git (их восстанавливает packages.json); vendor/ — исходники, остаются.
	private func ignoreInGit() {
		let gi = project.appendingPathComponent(".gitignore")
		var text = (try? String(contentsOf: gi, encoding: .utf8)) ?? ""
		let lines = Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
		var add = ""
		for d in ["node_modules/", "py_modules/", "lua_modules/"] where !lines.contains(d) && !lines.contains(String(d.dropLast())) { add += d + "\n" }
		guard !add.isEmpty else { return }
		if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
		try? (text + add).write(to: gi, atomically: true, encoding: .utf8)
	}

	private func removeEmptyDirs(_ root: URL) {
		let fm = FileManager.default
		guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
		var dirs: [URL] = []
		while let u = e.nextObject() as? URL { if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(u) } }
		for d in dirs.sorted(by: { $0.path.count > $1.path.count }) where ((try? fm.contentsOfDirectory(atPath: d.path)) ?? ["x"]).isEmpty {
			try? fm.removeItem(at: d)
		}
	}
}

/// Версии npm (semver) и LuaRocks.
enum Semver {
	struct V: Comparable {
		var n: [Int]      // major, minor, patch
		var pre: String   // пустая — релиз
		static func < (a: V, b: V) -> Bool {
			if a.n != b.n { return a.n.lexicographicallyPrecedes(b.n) }
			if a.pre.isEmpty != b.pre.isEmpty { return !a.pre.isEmpty }
			return a.pre < b.pre
		}
	}

	static func parse(_ s: String) -> V? {
		var t = s.trimmingCharacters(in: .whitespaces)
		if t.hasPrefix("v") || t.hasPrefix("=") { t.removeFirst() }
		let parts = t.split(separator: "-", maxSplits: 1).map(String.init)
		let nums = parts.first?.split(separator: "+").first?.split(separator: ".").map { Int($0) } ?? []
		guard nums.count == 3, nums.allSatisfy({ $0 != nil }) else { return nil }
		return V(n: nums.map { $0! }, pre: parts.count > 1 ? parts[1] : "")
	}

	/// Лучшая (наибольшая) версия под диапазон; предрелизы — только если диапазон сам их называет.
	static func best(_ versions: [String], _ range: String) -> String? {
		versions.compactMap { s -> (String, V)? in parse(s).map { (s, $0) } }
			.filter { (s, v) in (v.pre.isEmpty || range.contains("-")) && satisfies(s, range) }
			.max { $0.1 < $1.1 }?.0
	}

	static func satisfies(_ version: String, _ range: String) -> Bool {
		guard let v = parse(version) else { return false }
		let r = range.trimmingCharacters(in: .whitespaces)
		if r.isEmpty || r == "*" || r == "latest" || r == "x" { return v.pre.isEmpty }
		return r.components(separatedBy: "||").contains { alt in
			let a = alt.trimmingCharacters(in: .whitespaces)
			if let dash = a.range(of: " - ") {
				guard let lo = bound(String(a[..<dash.lowerBound])), let hi = bound(String(a[dash.upperBound...])) else { return false }
				return v >= lo.0 && (hi.1 ? v < hi.0 : v <= hi.0)
			}
			// ">= 1.2" → ">=1.2"
			let joined = a.replacingOccurrences(of: "(>=|<=|>|<|=|\\^|~)\\s+", with: "$1", options: .regularExpression)
			return joined.split(separator: " ").allSatisfy { comparator(v, String($0)) }
		}
	}

	/// Частичная версия (1, 1.2, 1.x) → нижняя граница и верхняя (не включая), если частичная.
	private static func bound(_ s: String) -> (V, Bool)? {
		let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "v", with: "")
		let p = t.split(separator: ".").map(String.init)
		let nums = p.map { Int($0) }
		if nums.count == 3, nums.allSatisfy({ $0 != nil }) { return parse(t).map { ($0, false) } }
		let fixed = nums.prefix { $0 != nil }.map { $0! }
		if fixed.isEmpty { return (V(n: [0, 0, 0], pre: ""), false) }
		var hi = fixed
		hi[hi.count - 1] += 1
		return (V(n: hi + Array(repeating: 0, count: 3 - hi.count), pre: ""), true)
	}

	private static func comparator(_ v: V, _ c: String) -> Bool {
		for op in [">=", "<=", ">", "<", "^", "~", "="] where c.hasPrefix(op) {
			let rest = String(c.dropFirst(op.count))
			let p = rest.split(separator: ".").map { Int($0) }
			let fixed = p.prefix { $0 != nil }.map { $0! }
			let lo = V(n: fixed + Array(repeating: 0, count: max(0, 3 - fixed.count)), pre: rest.split(separator: "-").dropFirst().joined(separator: "-"))
			switch op {
			case ">=": return v >= lo
			case ">": return v > lo
			case "<": return v < lo
			case "<=": return v <= lo
			case "=": return inRange(v, rest)
			case "^":
				var hi: [Int]
				if fixed.first ?? 0 > 0 || fixed.count == 1 { hi = [(fixed.first ?? 0) + 1, 0, 0] }
				else if fixed.count >= 2 && fixed[1] > 0 || fixed.count == 2 { hi = [0, fixed[1] + 1, 0] }
				else { hi = [0, 0, (fixed.count > 2 ? fixed[2] : 0) + 1] }
				return v >= lo && v < V(n: hi, pre: "") && (v.pre.isEmpty || !lo.pre.isEmpty)
			default:  // ~
				let hi = fixed.count >= 2 ? [fixed[0], fixed[1] + 1, 0] : [(fixed.first ?? 0) + 1, 0, 0]
				return v >= lo && v < V(n: hi, pre: "") && (v.pre.isEmpty || !lo.pre.isEmpty)
			}
		}
		return inRange(v, c)
	}

	/// «1.2.3» — точно, «1.2» / «1.x» — всё внутри.
	private static func inRange(_ v: V, _ s: String) -> Bool {
		guard let (lo, partial) = bound(s) else { return false }
		if !partial { return v == lo }
		let fixed = s.split(separator: ".").compactMap { Int($0) }
		return v.pre.isEmpty && v >= V(n: fixed + Array(repeating: 0, count: 3 - fixed.count), pre: "") && v < lo
	}

	/// «3.1.3-0» < «3.10-1»: числа по частям.
	static func rockLess(_ a: String, _ b: String) -> Bool {
		let x = a.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? -1 }
		let y = b.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? -1 }
		return x.lexicographicallyPrecedes(y)
	}
}
