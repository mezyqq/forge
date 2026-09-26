import Foundation
import JavaScriptCore

struct Diagnostic: Equatable {
	let line: Int       // 1-based, 0 — неизвестно
	let message: String
}

/// Проверка синтаксиса без запуска — встроенными движками: pocketpy, Lua, picoc, JavaScriptCore, JSONSerialization.
/// Используется редактором (подсветка строки с ошибкой) и агентом (ошибки сразу после edit/write).
enum SyntaxCheck {
	static func supports(_ path: String) -> Bool {
		["py", "lua", "c", "js", "mjs", "cjs", "json"].contains((path as NSString).pathExtension.lowercased())
	}

	static func check(_ text: String, path: String) -> Diagnostic? {
		let name = (path as NSString).lastPathComponent
		switch (path as NSString).pathExtension.lowercased() {
		case "py": return parse(forge_check_python(text, name), lineRegex: "line (\\d+)")
		case "lua": return parse(forge_check_lua(text, name), lineRegex: ":(\\d+): ")
		case "c": return parse(forge_check_c(text, name), lineRegex: ":(\\d+):\\d+ ")
		case "js", "mjs", "cjs": return js(text, name)
		case "json": return json(text)
		default: return nil
		}
	}

	/// Сообщение движка → строка + последняя содержательная строка текста ошибки.
	private static func parse(_ c: UnsafeMutablePointer<CChar>?, lineRegex: String) -> Diagnostic? {
		guard let c else { return nil }
		defer { free(c) }
		let s = String(cString: c)
		let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		var line = 0
		if let re = try? NSRegularExpression(pattern: lineRegex),
		   let m = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).last,
		   let r = Range(m.range(at: 1), in: s) { line = Int(s[r]) ?? 0 }
		var msg = lines.last ?? s
		// «a.lua:2: <eof> expected» / «a.c:3:0 ';' expected» → только суть
		if let r = msg.range(of: "^[^ ]+:\\d+(:\\d+)?:? ", options: .regularExpression) { msg.removeSubrange(r) }
		return Diagnostic(line: line, message: msg)
	}

	private static func js(_ text: String, _ name: String) -> Diagnostic? {
		guard let ctx = JSContext() else { return nil }
		let src = JSStringCreateWithCFString(text as CFString)
		let url = JSStringCreateWithCFString(name as CFString)
		defer { JSStringRelease(src); JSStringRelease(url) }
		var exc: JSValueRef?
		if JSCheckScriptSyntax(ctx.jsGlobalContextRef, src, url, 1, &exc) { return nil }
		guard let exc, let v = JSValue(jsValueRef: exc, in: ctx) else { return Diagnostic(line: 0, message: "SyntaxError") }
		let line = v.objectForKeyedSubscript("line")?.toInt32() ?? 0
		return Diagnostic(line: Int(line), message: v.toString() ?? "SyntaxError")
	}

	private static func json(_ text: String) -> Diagnostic? {
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		do {
			_ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
			return nil
		} catch let e as NSError {
			let d = (e.userInfo[NSDebugDescriptionErrorKey] as? String) ?? e.localizedDescription
			var line = 0
			if let r = d.range(of: "line (\\d+)", options: .regularExpression) {
				line = Int(d[r].dropFirst(5)) ?? 0
			}
			return Diagnostic(line: line, message: d)
		}
	}
}
