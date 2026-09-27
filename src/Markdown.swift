import SwiftUI
import WebKit

/// Markdown → HTML для предпросмотра .md: заголовки, абзацы, списки (с вложенностью), ```код```, цитаты,
/// таблицы, линии, **жирный**, *курсив*, ~~зачёркнутый~~, `код`, ссылки и картинки (файлы проекта — встраиваются).
enum Markdown {
	static func html(_ md: String, base: URL) -> String {
		var out = ""
		var lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
		lines.append("")
		var i = 0
		var para: [String] = []
		var lists: [(ordered: Bool, indent: Int)] = []

		func flushPara() {
			if !para.isEmpty { out += "<p>" + inline(para.joined(separator: " "), base) + "</p>\n" }
			para = []
		}
		func closeLists(to depth: Int = 0) {
			while lists.count > depth { out += lists.removeLast().ordered ? "</li></ol>\n" : "</li></ul>\n" }
		}

		while i < lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			// блок кода
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				flushPara(); closeLists()
				let fence = String(trimmed.prefix(3))
				var code: [String] = []
				i += 1
				while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
				out += "<pre><code>" + esc(code.joined(separator: "\n")) + "</code></pre>\n"
				i += 1
				continue
			}
			if trimmed.isEmpty { flushPara(); if !(nextIsList(lines, i)) { closeLists() }; i += 1; continue }
			// заголовок
			if let m = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
				flushPara(); closeLists()
				let level = trimmed[m].count - 1
				out += "<h\(level)>" + inline(String(trimmed[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " #")), base) + "</h\(level)>\n"
				i += 1
				continue
			}
			// линия
			if trimmed.range(of: "^([-*_])( ?\\1){2,}$", options: .regularExpression) != nil {
				flushPara(); closeLists()
				out += "<hr>\n"
				i += 1
				continue
			}
			// цитата
			if trimmed.hasPrefix(">") {
				flushPara(); closeLists()
				var quote: [String] = []
				while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
					var q = lines[i].trimmingCharacters(in: .whitespaces)
					q.removeFirst()
					quote.append(q.hasPrefix(" ") ? String(q.dropFirst()) : q)
					i += 1
				}
				out += "<blockquote>" + html(quote.joined(separator: "\n"), base: base) + "</blockquote>\n"
				continue
			}
			// таблица: строка | a | b | и следом |---|---|
			if trimmed.hasPrefix("|") || (trimmed.contains("|") && i + 1 < lines.count && isTableSep(lines[i + 1])),
			   i + 1 < lines.count, isTableSep(lines[i + 1]) {
				flushPara(); closeLists()
				out += "<table><thead><tr>" + cells(trimmed).map { "<th>" + inline($0, base) + "</th>" }.joined() + "</tr></thead><tbody>\n"
				i += 2
				while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
					out += "<tr>" + cells(lines[i]).map { "<td>" + inline($0, base) + "</td>" }.joined() + "</tr>\n"
					i += 1
				}
				out += "</tbody></table>\n"
				continue
			}
			// элемент списка
			if let item = listItem(line) {
				flushPara()
				let depth = lists.firstIndex { $0.indent >= item.indent }.map { $0 + 1 } ?? lists.count + 1
				if depth <= lists.count {
					closeLists(to: depth)
					if lists[depth - 1].ordered != item.ordered {
						closeLists(to: depth - 1)
						out += item.ordered ? "<ol><li>" : "<ul><li>"
						lists.append((item.ordered, item.indent))
					} else {
						out += "</li><li>"
					}
				} else {
					out += item.ordered ? "<ol><li>" : "<ul><li>"
					lists.append((item.ordered, item.indent))
				}
				out += inline(item.text, base)
				i += 1
				continue
			}
			if !lists.isEmpty && line.hasPrefix("  ") {
				out += " " + inline(trimmed, base)  // продолжение пункта
			} else {
				closeLists()
				para.append(trimmed)
			}
			i += 1
		}
		flushPara()
		closeLists()
		return out
	}

	private static func nextIsList(_ lines: [String], _ i: Int) -> Bool {
		i + 1 < lines.count && listItem(lines[i + 1]) != nil
	}

	private static func listItem(_ line: String) -> (ordered: Bool, indent: Int, text: String)? {
		let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
		let t = line.trimmingCharacters(in: .whitespaces)
		if let r = t.range(of: "^[-*+] ", options: .regularExpression) {
			var text = String(t[r.upperBound...])
			// чекбоксы задач
			if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) } else if text.lowercased().hasPrefix("[x] ") { text = "☑︎ " + text.dropFirst(4) }
			return (false, indent, text)
		}
		if let r = t.range(of: "^[0-9]+[.)] ", options: .regularExpression) { return (true, indent, String(t[r.upperBound...])) }
		return nil
	}

	private static func isTableSep(_ s: String) -> Bool {
		s.trimmingCharacters(in: .whitespaces).range(of: "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$", options: .regularExpression) != nil
	}

	private static func cells(_ s: String) -> [String] {
		var t = s.trimmingCharacters(in: .whitespaces)
		if t.hasPrefix("|") { t.removeFirst() }
		if t.hasSuffix("|") { t.removeLast() }
		return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
	}

	static func esc(_ s: String) -> String {
		s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
	}

	/// Строчная разметка. `код` — первым, чтобы внутри него ничего не трогать.
	static func inline(_ s: String, _ base: URL) -> String {
		var codes: [String] = []
		var t = s.replacingOccurrences(of: "`([^`]+)`", with: "\u{1}$1\u{2}", options: .regularExpression)
		// вынимаем код в заглушки
		while let r = t.range(of: "\u{1}[^\u{2}]*\u{2}", options: .regularExpression) {
			codes.append("<code>" + esc(String(t[r].dropFirst().dropLast())) + "</code>")
			t.replaceSubrange(r, with: "\u{3}\(codes.count - 1)\u{3}")
		}
		t = esc(t)
		// картинки ![alt](src) — файлы проекта встраиваем, WebView не читает их сам
		while let r = t.range(of: "!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)", options: .regularExpression) {
			let m = String(t[r])
			let alt = m.range(of: "\\[([^\\]]*)\\]", options: .regularExpression).map { String(m[$0].dropFirst().dropLast()) } ?? ""
			let src = m.range(of: "\\(([^)\\s]+)", options: .regularExpression).map { String(m[$0].dropFirst()) } ?? ""
			t.replaceSubrange(r, with: "<img alt=\"\(alt)\" src=\"\(imageSource(src, base))\">")
		}
		t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)\\s]+)[^)]*\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
		t = t.replacingOccurrences(of: "(^|[\\s(])(https?://[^\\s<]+)", with: "$1<a href=\"$2\">$2</a>", options: .regularExpression)
		t = t.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
		t = t.replacingOccurrences(of: "__([^_]+)__", with: "<strong>$1</strong>", options: .regularExpression)
		t = t.replacingOccurrences(of: "(^|[^*])\\*([^*\\s][^*]*)\\*", with: "$1<em>$2</em>", options: .regularExpression)
		t = t.replacingOccurrences(of: "(^|[\\s(])_([^_\\s][^_]*)_", with: "$1<em>$2</em>", options: .regularExpression)
		t = t.replacingOccurrences(of: "~~([^~]+)~~", with: "<del>$1</del>", options: .regularExpression)
		for (k, c) in codes.enumerated() { t = t.replacingOccurrences(of: "\u{3}\(k)\u{3}", with: c) }
		return t
	}

	private static func imageSource(_ src: String, _ base: URL) -> String {
		if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") { return src }
		let u = base.appendingPathComponent(src.removingPercentEncoding ?? src)
		guard let d = try? Data(contentsOf: u), d.count < 8_000_000 else { return src }
		let ext = u.pathExtension.lowercased()
		let mime = ext == "svg" ? "image/svg+xml" : ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "gif" ? "image/gif" : "image/png"
		return "data:\(mime);base64," + d.base64EncodedString()
	}

	static func page(_ body: String) -> String {
		"""
		<!doctype html><html><head><meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<style>
		:root { color-scheme: light dark; }
		body { font: -apple-system-body; line-height: 1.5; margin: 16px; max-width: 820px; word-wrap: break-word; }
		h1, h2 { border-bottom: 1px solid rgba(128,128,128,.3); padding-bottom: .2em; }
		code { font-family: ui-monospace, Menlo, monospace; font-size: .9em; background: rgba(128,128,128,.15); padding: .1em .3em; border-radius: 4px; }
		pre { background: rgba(128,128,128,.12); padding: 12px; border-radius: 8px; overflow-x: auto; }
		pre code { background: none; padding: 0; }
		blockquote { margin: 0; padding: 0 1em; border-left: 4px solid rgba(128,128,128,.4); color: gray; }
		table { border-collapse: collapse; display: block; overflow-x: auto; }
		th, td { border: 1px solid rgba(128,128,128,.35); padding: 6px 10px; }
		img { max-width: 100%; }
		a { color: #ff7a1a; }
		</style></head><body>
		\(body)
		</body></html>
		"""
	}
}

/// Предпросмотр Markdown в WebView; ссылки открываются в Safari.
struct MarkdownView: UIViewRepresentable {
	let text: String
	let base: URL

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeUIView(context: Context) -> WKWebView {
		let wv = WKWebView()
		wv.navigationDelegate = context.coordinator
		wv.isOpaque = false
		wv.backgroundColor = .systemBackground
		return wv
	}

	func updateUIView(_ wv: WKWebView, context: Context) {
		guard context.coordinator.shown != text else { return }
		context.coordinator.shown = text
		wv.loadHTMLString(Markdown.page(Markdown.html(text, base: base)), baseURL: nil)
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		var shown: String?
		func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
			if action.navigationType == .linkActivated, let u = action.request.url {
				UIApplication.shared.open(u)
				decisionHandler(.cancel)
			} else {
				decisionHandler(.allow)
			}
		}
	}
}
