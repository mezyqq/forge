import Foundation
import UIKit

/// Встроенный clang для редактора и быстрого запуска: диагностика, автодополнение, clang-format, JIT.
/// ioscc не потокобезопасен — все вызовы (и сборка IpaBuilder) идут по очереди под одним замком,
/// на потоке со стеком 16 МБ (clang рекурсивен).
enum Clang {
	static let lock = NSLock()

	/// Файлы, которые понимает clang.
	static func supports(_ path: String) -> Bool {
		["c", "m", "mm", "cpp", "cc", "cxx", "h", "hpp", "hh", "hxx"].contains((path as NSString).pathExtension.lowercased())
	}

	/// Можно ли запускать нативный код прямо в Forge: есть компилятор и включён JIT.
	static var canJIT: Bool {
		#if FORGE_COMPILER
		return IpaBuilder.available && ioscc_jit_enabled() != 0
		#else
		return false
		#endif
	}

	// MARK: диагностика

	struct Issue: Hashable, Identifiable {
		let file: String     // абсолютный путь или "" (линковщик)
		let line: Int
		let col: Int
		let severity: String // error | warning | fatal error
		let message: String
		var id: String { "\(file):\(line):\(col):\(message)" }
		var isError: Bool { severity != "warning" }
	}

	/// Строки вида «/path/a.m:12:5: error: …» и «ld: error: …» из вывода clang/lld.
	static func issues(in output: String) -> [Issue] {
		var out: [Issue] = []
		let re = try! NSRegularExpression(pattern: "^(?:clang: )?(.+?):(\\d+):(\\d+): (fatal error|error|warning): (.*)$")
		for line in output.components(separatedBy: "\n") {
			let ns = line as NSString
			if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
				out.append(Issue(file: ns.substring(with: m.range(at: 1)), line: Int(ns.substring(with: m.range(at: 2))) ?? 0,
				                 col: Int(ns.substring(with: m.range(at: 3))) ?? 0, severity: ns.substring(with: m.range(at: 4)),
				                 message: ns.substring(with: m.range(at: 5))))
			} else if let p = ["ld: error: ", "jit: "].first(where: line.hasPrefix) {
				out.append(Issue(file: "", line: 0, col: 0, severity: "error", message: String(line.dropFirst(p.count))))
			}
		}
		// одна ошибка — одна строка списка (clang повторяет её для каждого включения заголовка)
		var seen = Set<String>()
		return out.filter { seen.insert($0.id).inserted }
	}

	/// Флаги для файла: из ipa.conf проекта (если есть) + язык по расширению.
	static func args(for file: URL, project: URL) -> [String] {
		let cfg = try? IpaBuilder.Config(project)
		var a = [IpaBuilder.clangPath] + IpaBuilder.baseFlags(project, cfg)
		if cfg == nil { a.append("-I" + file.deletingLastPathComponent().path) }
		return a + IpaBuilder.langFlags(file.pathExtension)
	}

	/// Проверка несохранённого текста файла; только проблемы этого файла.
	static func check(_ text: String, file: URL, project: URL) async -> [Issue] {
		#if FORGE_COMPILER
		guard IpaBuilder.available else { return [] }
		let args = args(for: file, project: project)
		let out = await background {
			IpaBuilder.withArgv(args) { argc, argv in take(ioscc_check(argc, argv, file.path, text)) }
		}
		return issues(in: out).filter { $0.file == file.path }
		#else
		return []
		#endif
	}

	// MARK: автодополнение

	struct Completion: Hashable {
		let kind: String    // Function, ObjCMethod, Var, macro, keyword…
		let name: String    // что уже набирается (typed text)
		let insert: String  // вставка с параметрами <#…#>
		let label: String   // подпись для списка
		let result: String  // тип результата
	}

	/// Варианты для позиции offset (UTF-16) в тексте.
	static func complete(_ text: String, offset: Int, file: URL, project: URL) async -> [Completion] {
		#if FORGE_COMPILER
		guard IpaBuilder.available else { return [] }
		let ns = text as NSString
		let before = ns.substring(to: min(offset, ns.length))
		let lineStart = (before as NSString).range(of: "\n", options: .backwards)
		let line = before.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
		let col = (lineStart.location == NSNotFound ? before : String((before as NSString).substring(from: lineStart.location + 1))).utf8.count + 1
		let args = args(for: file, project: project)
		let out = await background {
			IpaBuilder.withArgv(args) { argc, argv in take(ioscc_complete(argc, argv, file.path, text, Int32(line), Int32(col), 60)) }
		}
		return out.components(separatedBy: "\n").compactMap { l in
			let f = l.components(separatedBy: "\t")
			guard f.count >= 5 else { return nil }
			return Completion(kind: f[0], name: f[1], insert: f[2], label: f[3], result: f[4])
		}
		#else
		return []
		#endif
	}

	// MARK: clang-format

	/// Форматирование; стиль — .clang-format из корня проекта, иначе стиль Forge (табы).
	static func format(_ text: String, file: URL, project: URL) async throws -> String {
		#if FORGE_COMPILER
		guard IpaBuilder.available else { throw IpaBuilder.Failure(message: L("this Forge build has no compiler")) }
		let style = try? String(contentsOf: project.appendingPathComponent(".clang-format"), encoding: .utf8)
		let out: String? = await background {
			guard let p = ioscc_format(text, file.path, style) else { return nil }
			return take(p)
		}
		guard let out else { throw IpaBuilder.Failure(message: L("clang-format could not format this file (check .clang-format)")) }
		return out
		#else
		throw IpaBuilder.Failure(message: L("this Forge build has no compiler"))
		#endif
	}

	// MARK: JIT

	#if FORGE_COMPILER
	/// Последняя загруженная сессия (её UI-превью ещё может работать — сессии не выгружаются).
	private(set) static var lastJIT: OpaquePointer?
	#endif

	/// Скрипт .c/.cpp/.m: компилируем один файл и запускаем main. Вызывается на потоке Runner.
	static func runFile(_ path: String) -> Int32 {
		#if FORGE_COMPILER
		guard IpaBuilder.available else {
			fputs(L("this Forge build has no compiler") + "\n", stderr)
			return 1
		}
		let fm = FileManager.default
		let file = URL(fileURLWithPath: path)
		let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("forge-jit")
		try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
		let o = cache.appendingPathComponent(String(format: "%@-%08x.o", file.deletingPathExtension().lastPathComponent, UInt32(truncatingIfNeeded: path.hashValue)))
		let args = [IpaBuilder.clangPath] + IpaBuilder.baseFlags(file.deletingLastPathComponent(), nil) + ["-g", "-I" + file.deletingLastPathComponent().path]
			+ IpaBuilder.langFlags(file.pathExtension) + ["-c", path, "-o", o.path]
		let r: Int32 = locked { IpaBuilder.withArgv(args) { ioscc_cc($0, $1) } }
		fflush(stderr)
		guard r == 0 else { return r }
		guard let jit = load([o.path], frameworks: ["Foundation"]) else { return 1 }
		return runMain(jit, name: file.lastPathComponent)
		#else
		fputs(L("this Forge build has no compiler") + "\n", stderr)
		return 1
		#endif
	}

	/// Проект: компилируем src/ и загружаем. Есть forge_preview — вернём его сессию для превью UI,
	/// иначе запускаем main (консольная программа). Вызывается на потоке Runner.
	static func runProject(_ proj: URL, preview: inout OpaquePointer?) -> Int32 {
		#if FORGE_COMPILER
		guard canJIT else {
			fputs(L("JIT is not enabled. Launch Forge with JIT (the same way you enable it for other apps) to run code without installing.") + "\n", stderr)
			return 1
		}
		do {
			let (objects, frameworks) = try IpaBuilder.jitObjects(proj)
			print(L("==> linking in memory (JIT)"))
			guard let jit = load(objects, frameworks: frameworks) else { return 1 }
			if ioscc_jit_lookup(jit, "forge_preview") != nil {
				preview = jit
				print(L("==> showing forge_preview()"))
				return 0
			}
			let src = (try? String(contentsOf: proj.appendingPathComponent("src/main.m"), encoding: .utf8)) ?? ""
			if src.contains("UIApplicationMain") {
				fputs(L("An app's main() starts UIApplicationMain, which cannot run inside Forge. Add a function\n  UIViewController *forge_preview(void) { return [MyViewController new]; }\nand Forge will show that screen.") + "\n", stderr)
				return 1
			}
			return runMain(jit, name: proj.lastPathComponent)
		} catch let f as IpaBuilder.Failure {
			fputs(L("error: %@\n", f.message), stderr)
			return 1
		} catch {
			fputs(L("error: %@\n", error.localizedDescription), stderr)
			return 1
		}
		#else
		fputs(L("this Forge build has no compiler") + "\n", stderr)
		return 1
		#endif
	}

	/// Вызов forge_preview() на главном потоке; ошибка — nil и сообщение.
	static func previewController(_ jit: OpaquePointer) -> Result<UIViewController, IpaBuilder.Failure> {
		#if FORGE_COMPILER
		var status: Int32 = 0
		// без замка: JIT-код не трогает clang, а главный поток не должен ждать автодополнение
		let p = ioscc_jit_call(jit, "forge_preview", &status)
		if status != 0 { return .failure(.init(message: L("forge_preview() crashed (code %@)", status))) }
		guard let p else { return .failure(.init(message: L("forge_preview() returned nil"))) }
		let obj = Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
		guard let vc = obj as? UIViewController else { return .failure(.init(message: L("forge_preview() must return a UIViewController"))) }
		return .success(vc)
		#else
		return .failure(.init(message: L("this Forge build has no compiler")))
		#endif
	}

	static func stop() {
		#if FORGE_COMPILER
		ioscc_jit_stop()
		#endif
	}

	#if FORGE_COMPILER
	private static func load(_ objects: [String], frameworks: [String]) -> OpaquePointer? {
		guard ioscc_jit_enabled() != 0 else {
			fputs(L("JIT is not enabled. Launch Forge with JIT (the same way you enable it for other apps) to run code without installing.") + "\n", stderr)
			return nil
		}
		// фреймворки из FRAMEWORKS, которых нет в Forge, — иначе их символы не найдутся
		for fw in frameworks where dlopen("/System/Library/Frameworks/\(fw).framework/\(fw)", RTLD_NOW | RTLD_GLOBAL) == nil {
			print(L("warning: framework %@ not found", fw))
		}
		let jit = locked { IpaBuilder.withArgv(objects) { ioscc_jit_load($0, $1) } }
		fflush(stderr)
		if let jit { lastJIT = jit }
		return jit
	}

	private static func runMain(_ jit: OpaquePointer, name: String) -> Int32 {
		IpaBuilder.withArgv([name]) { ioscc_jit_main(jit, $0, $1) }
	}

	/// Строка из malloc-буфера ioscc (освобождаем).
	private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
		guard let p else { return "" }
		defer { free(p) }
		return String(cString: p)
	}
	#endif

	private static func locked<T>(_ body: () -> T) -> T {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}

	/// body под замком на отдельном потоке с большим стеком.
	private static func background<T>(_ body: @escaping () -> T) async -> T {
		await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
			let t = Thread {
				c.resume(returning: locked(body))
			}
			t.stackSize = 16 << 20
			t.start()
		}
	}
}
