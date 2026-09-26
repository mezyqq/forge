import Foundation
import JavaScriptCore

enum RunKind {
	case python, lua, c, js, web

	var title: String {
		switch self {
		case .python: return "Python"
		case .lua: return "Lua"
		case .c: return "C"
		case .js: return "JavaScript"
		case .web: return L("Web")
		}
	}

	static func detect(_ path: String) -> RunKind? {
		switch (path as NSString).pathExtension.lowercased() {
		case "py": return .python
		case "lua": return .lua
		case "c": return .c
		case "js", "mjs", "cjs": return .js
		case "html", "htm": return .web
		default: return nil
		}
	}

	/// Файлы, которые ищем для кнопки ▶ у проекта.
	static let entryPoints = ["main.py", "main.js", "index.js", "app.js", "index.html", "main.lua", "main.c",
	                          "src/main.py", "src/main.js", "src/index.js", "src/index.html", "src/main.lua", "src/main.c"]
}

/// Консоль запуска. Одна на приложение: интерпретаторы пишут в stdout/stderr процесса и читают stdin,
/// а мы на время запуска подменяем fd 0/1/2 на pipe'ы. Поэтому одновременно идёт только один запуск.
/// Состояние меняется только на главном потоке.
final class Runner: ObservableObject {
	static let shared = Runner()

	@Published private(set) var output = ""
	@Published private(set) var running = false
	@Published private(set) var title = ""

	private var inWrite: Int32 = -1
	private var generation = 0

	private final class Box { var code: Int32 = 0 }

	func run(_ url: URL) { start(url, interactive: true, completion: nil) }

	/// Сборка iOS-приложения проекта (IpaBuilder) в этой же консоли. completion — код выхода, на главном потоке.
	func build(_ project: URL, release: Bool, completion: ((Int32) -> Void)? = nil) {
		guard !running else { return }
		CrashLog.crumb("сборка ipa: \(project.lastPathComponent)")
		launch(title: L("Build ") + project.lastPathComponent, dir: project.path, interactive: false,
		       body: { IpaBuilder.run(project, release: release) }) { _, code in completion?(code) }
	}

	/// Для агента: запуск без ввода и с тайм-аутом, возвращает весь вывод.
	func capture(_ url: URL, timeout: Double = 15) async -> String {
		await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
			DispatchQueue.main.async {
				guard !self.running else {
					cont.resume(returning: L("Another run is in progress — wait for it or stop it."))
					return
				}
				self.start(url, interactive: false) { cont.resume(returning: $0) }
				let gen = self.generation
				DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
					if self.running && self.generation == gen {
						self.append(L("\n[stopped: longer than %@ s]", Int(timeout)))
						self.stop()
					}
				}
			}
		}
	}

	func send(_ line: String) {
		guard inWrite >= 0 else { return }
		append(line + "\n")  // эхо: pipe не показывает введённое
		let data = Array((line + "\n").utf8)
		_ = data.withUnsafeBytes { write(inWrite, $0.baseAddress, $0.count) }
	}

	func stop() {
		forge_request_stop()
		JSRunner.stop = true
		IpaBuilder.cancel = true
		closeInput()  // разблокирует input() / scanf / prompt()
	}

	func clear() { if !running { output = "" } }

	private func closeInput() {
		if inWrite >= 0 { close(inWrite); inWrite = -1 }
	}

	private func append(_ s: String) {
		output += s
		if output.utf8.count > 400_000 { output = "…\n" + String(output.suffix(200_000)) }
	}

	private func start(_ url: URL, interactive: Bool, completion: ((String) -> Void)?) {
		guard !running, let kind = RunKind.detect(url.path), kind != .web else { return }
		CrashLog.crumb("запуск скрипта: \(url.lastPathComponent)")
		let path = url.path, dir = url.deletingLastPathComponent().path
		launch(title: url.lastPathComponent, dir: dir, interactive: interactive, body: {
			switch kind {
			case .python: return forge_run_python(path)
			case .lua: return forge_run_lua(path)
			case .c: return forge_run_c(path)
			case .js: return JSRunner.run(path: path, dir: dir)
			case .web: return 0
			}
		}) { out, _ in completion?(out) }
	}

	/// `body` на отдельном потоке, fd 0/1/2 на это время подменены на консоль.
	private func launch(title: String, dir: String, interactive: Bool, body: @escaping () -> Int32,
	                    completion: ((String, Int32) -> Void)?) {
		var o: [Int32] = [0, 0], i: [Int32] = [0, 0]
		guard pipe(&o) == 0 else { return }
		guard pipe(&i) == 0 else { close(o[0]); close(o[1]); return }
		running = true
		generation += 1
		output = ""
		self.title = title
		let (outR, outW, inR) = (o[0], o[1], i[0])
		if interactive { inWrite = i[1] } else { close(i[1]) }

		let group = DispatchGroup()
		let result = Box()

		// читатель вывода: отдаём на главный поток только целые UTF-8 последовательности
		group.enter()
		Thread.detachNewThread {
			var buf = [UInt8](repeating: 0, count: 8192)
			var pending: [UInt8] = []
			while true {
				let n = read(outR, &buf, buf.count)
				if n <= 0 { break }
				pending += buf[0..<n]
				var cut = pending.count
				var k = pending.count - 1, back = 0
				while k >= 0, back < 3, pending[k] & 0xC0 == 0x80 { k -= 1; back += 1 }
				if k >= 0 {
					let lead = pending[k]
					let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
					if need > back + 1 { cut = k }
				}
				let chunk = String(decoding: pending[0..<cut], as: UTF8.self)
				pending.removeFirst(cut)
				DispatchQueue.main.async { self.append(chunk) }
			}
			close(outR)
			group.leave()
		}

		group.enter()
		let worker = Thread {
			fflush(stdout); fflush(stderr)
			let s0 = dup(0), s1 = dup(1), s2 = dup(2)
			dup2(outW, 1); dup2(outW, 2); dup2(inR, 0)
			fpurge(stdin); clearerr(stdin)
			setvbuf(stdout, nil, _IONBF, 0)
			FileManager.default.changeCurrentDirectoryPath(dir)
			let code = body()
			fflush(stdout); fflush(stderr)
			dup2(s0, 0); dup2(s1, 1); dup2(s2, 2)
			close(s0); close(s1); close(s2); close(outW); close(inR)
			result.code = code
			group.leave()
		}
		worker.stackSize = 16 << 20  // рекурсия в интерпретаторах и в clang
		worker.start()

		group.notify(queue: .main) {
			self.running = false
			self.closeInput()
			self.append("\n[\(result.code == 0 ? L("done") : L("exit code %@", result.code))]\n")
			completion?(self.output, result.code)
		}
	}
}

/// JavaScript на JavaScriptCore (без JIT-разрешений работает интерпретатором).
/// Есть console.*, prompt(), require() для файлов проекта, setTimeout/setInterval.
enum JSRunner {
	static var stop = false

	static func run(path: String, dir: String) -> Int32 {
		stop = false
		guard let ctx = JSContext(), let src = try? String(contentsOfFile: path, encoding: .utf8) else {
			fputs(L("could not read %@\n", path), stderr)
			return 1
		}
		var failed = false
		ctx.exceptionHandler = { _, e in
			failed = true
			let msg = e?.toString() ?? L("error")
			let stack = e?.objectForKeyedSubscript("stack")?.toString() ?? ""
			fputs(msg + (stack.isEmpty || stack == "undefined" ? "" : "\n" + stack) + "\n", stderr)
		}
		// «Стоп»: JSC каждые 0.2 с работы скрипта спрашивает, не прервать ли его
		JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(ctx.jsGlobalContextRef), 0.2, { _, _ in JSRunner.stop }, nil)

		let json = ctx.objectForKeyedSubscript("JSON")
		func fmt(_ v: JSValue) -> String {
			if v.isString || v.isUndefined || v.isNull || v.isNumber || v.isBoolean { return v.toString() }
			if let s = json?.invokeMethod("stringify", withArguments: [v, NSNull(), 2]), s.isString { return s.toString() }
			return v.toString()
		}
		let log: @convention(block) () -> Void = {
			let args = (JSContext.currentArguments() as? [JSValue]) ?? []
			fputs(args.map(fmt).joined(separator: " ") + "\n", stdout)
		}
		let console = JSValue(newObjectIn: ctx)!
		for name in ["log", "info", "warn", "error", "debug"] { console.setObject(log, forKeyedSubscript: name as NSString) }
		ctx.setObject(console, forKeyedSubscript: "console" as NSString)

		let prompt: @convention(block) (JSValue?) -> String? = { msg in
			if let m = msg, !m.isUndefined { fputs(m.toString() + " ", stdout) }
			return readLine()
		}
		ctx.setObject(prompt, forKeyedSubscript: "prompt" as NSString)

		// require: CommonJS для файлов проекта, пути относительно файла, который вызывает require
		var modules: [String: JSValue] = [:]
		func makeRequire(_ base: String) -> JSValue {
			let fn: @convention(block) (String) -> JSValue? = { name in
				let fm = FileManager.default
				var p = ((name.hasPrefix("/") ? name : (base as NSString).appendingPathComponent(name)) as NSString).standardizingPath
				var isDir: ObjCBool = false
				if !fm.fileExists(atPath: p, isDirectory: &isDir) || isDir.boolValue {
					if fm.fileExists(atPath: p + ".js") { p += ".js" }
					else if fm.fileExists(atPath: p + "/index.js") { p += "/index.js" }
				}
				if let m = modules[p] { return m.objectForKeyedSubscript("exports") }
				guard let code = try? String(contentsOfFile: p, encoding: .utf8) else {
					ctx.exception = JSValue(newErrorFromMessage: "Cannot find module '\(name)'", in: ctx)
					return nil
				}
				let module = JSValue(newObjectIn: ctx)!
				module.setObject(JSValue(newObjectIn: ctx), forKeyedSubscript: "exports" as NSString)
				modules[p] = module
				if p.hasSuffix(".json") {
					module.setObject(json?.invokeMethod("parse", withArguments: [code]), forKeyedSubscript: "exports" as NSString)
				} else {
					let wrapper = ctx.evaluateScript("(function(module, exports, require){\n" + code + "\n})",
					                                 withSourceURL: URL(fileURLWithPath: p))
					_ = wrapper?.call(withArguments: [module, module.objectForKeyedSubscript("exports")!,
					                                  makeRequire((p as NSString).deletingLastPathComponent)])
				}
				return module.objectForKeyedSubscript("exports")
			}
			return JSValue(object: fn, in: ctx)
		}
		ctx.setObject(makeRequire(dir), forKeyedSubscript: "require" as NSString)

		// таймеры: простой цикл событий после основного скрипта
		struct Timer { let id: Int; var at: Date; let every: Double?; let fn: JSValue }
		var timers: [Timer] = []
		var nextID = 1
		func addTimer(_ fn: JSValue, _ ms: JSValue, repeats: Bool) -> Int {
			let d = ms.isUndefined ? 0 : max(0, ms.toDouble().isNaN ? 0 : ms.toDouble()) / 1000
			let id = nextID
			nextID += 1
			timers.append(Timer(id: id, at: Date().addingTimeInterval(d), every: repeats ? max(d, 0.001) : nil, fn: fn))
			return id
		}
		let setTimeout: @convention(block) (JSValue, JSValue) -> Int = { addTimer($0, $1, repeats: false) }
		let setInterval: @convention(block) (JSValue, JSValue) -> Int = { addTimer($0, $1, repeats: true) }
		let clear: @convention(block) (Int) -> Void = { id in timers.removeAll { $0.id == id } }
		ctx.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
		ctx.setObject(setInterval, forKeyedSubscript: "setInterval" as NSString)
		ctx.setObject(clear, forKeyedSubscript: "clearTimeout" as NSString)
		ctx.setObject(clear, forKeyedSubscript: "clearInterval" as NSString)

		ctx.evaluateScript(src, withSourceURL: URL(fileURLWithPath: path))

		while !timers.isEmpty && !stop {
			timers.sort { $0.at < $1.at }
			let wait = timers[0].at.timeIntervalSinceNow
			if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 0.05)); continue }
			var t = timers.removeFirst()
			if let every = t.every {
				t.at = Date().addingTimeInterval(every)
				timers.append(t)
			}
			t.fn.call(withArguments: [])
		}
		if stop { fputs("stopped\n", stderr); return 1 }
		return failed ? 1 : 0
	}
}
