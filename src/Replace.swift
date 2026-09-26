import Foundation

// Замена текста для инструмента edit с «прощающим» поиском: если модель ошиблась в отступах,
// пробелах, экранировании или чуть переврала середину блока — правка всё равно находит нужное место.
// Портировано из opencode (MIT License, Copyright (c) 2025 opencode):
// packages/opencode/src/tool/edit.ts — SimpleReplacer … MultiOccurrenceReplacer, replace().
enum Replace {
	struct Failure: LocalizedError {
		let message: String
		var errorDescription: String? { message }
	}

	/// Возвращает кандидатов — точные куски `content`, которые можно заменить.
	typealias Replacer = (_ content: String, _ find: String) -> [String]

	private static let singleThreshold = 0.65
	private static let multipleThreshold = 0.65

	static func replace(_ content: String, _ old: String, _ new: String, all: Bool = false) throws -> String {
		if old == new { throw Failure(message: "No changes to apply: oldString and newString are identical.") }
		if old.isEmpty {
			throw Failure(message: "oldString cannot be empty when editing an existing file. Provide the exact text to replace, or use write for an intentional full-file replacement.")
		}
		var notFound = true
		let replacers: [Replacer] = [simple, lineTrimmed, blockAnchor, whitespaceNormalized, indentationFlexible,
		                             escapeNormalized, trimmedBoundary, contextAware, multiOccurrence]
		for r in replacers {
			for search in r(content, old) where !search.isEmpty {
				guard let first = content.range(of: search, options: .literal) else { continue }
				notFound = false
				if disproportionate(search, old) {
					throw Failure(message: "Refusing replacement because the matched span is much larger than oldString. Re-read the file and provide the full exact oldString for the intended replacement.")
				}
				if all { return content.replacingOccurrences(of: search, with: new, options: .literal) }
				let last = content.range(of: search, options: [.literal, .backwards])!
				if first.lowerBound != last.lowerBound { continue }
				return content.replacingCharacters(in: first, with: new)
			}
		}
		if notFound {
			throw Failure(message: "Could not find oldString in the file. It must match exactly, including whitespace, indentation, and line endings. Read the file again and copy the exact text.")
		}
		throw Failure(message: "Found multiple matches for oldString. Provide more surrounding context to make the match unique, or set replaceAll to true.")
	}

	private static func disproportionate(_ search: String, _ old: String) -> Bool {
		let oldLines = lines(old).count, searchLines = lines(search).count
		if searchLines >= max(oldLines + 3, oldLines * 2) { return true }
		if oldLines == 1 { return false }
		let s = search.trimmingCharacters(in: .whitespacesAndNewlines).count
		let o = old.trimmingCharacters(in: .whitespacesAndNewlines).count
		return s > max(o + 500, o * 4)
	}

	// MARK: утилиты

	private static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
	private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
	private static func block(_ l: [String], _ from: Int, _ to: Int) -> String { l[from...to].joined(separator: "\n") }

	private static func dropTrailingEmpty(_ l: [String]) -> [String] {
		var l = l
		if l.last == "" { l.removeLast() }
		return l
	}

	static func levenshtein(_ a: String, _ b: String) -> Int {
		let a = Array(a), b = Array(b)
		if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
		var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
		for i in 1...a.count {
			cur[0] = i
			for j in 1...b.count {
				cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
			}
			swap(&prev, &cur)
		}
		return prev[b.count]
	}

	// MARK: стратегии поиска (в порядке opencode)

	static let simple: Replacer = { _, find in [find] }

	/// Совпадение строк без учёта отступов по краям.
	static let lineTrimmed: Replacer = { content, find in
		let o = lines(content), s = dropTrailingEmpty(lines(find))
		guard !s.isEmpty, o.count >= s.count else { return [] }
		var out: [String] = []
		for i in 0...(o.count - s.count) where (0..<s.count).allSatisfy({ trim(o[i + $0]) == trim(s[$0]) }) {
			out.append(block(o, i, i + s.count - 1))
		}
		return out
	}

	/// Первая и последняя строки совпадают, середина похожа (расстояние Левенштейна).
	static let blockAnchor: Replacer = { content, find in
		let o = lines(content)
		var s = lines(find)
		guard s.count >= 3 else { return [] }
		if s.last == "" { s.removeLast() }
		let firstS = trim(s[0]), lastS = trim(s[s.count - 1])
		let size = s.count
		let maxDelta = max(1, size / 4)
		var candidates: [(Int, Int)] = []
		for i in 0..<o.count where trim(o[i]) == firstS {
			var j = i + 2
			while j < o.count {
				if trim(o[j]) == lastS {
					if abs((j - i + 1) - size) <= maxDelta { candidates.append((i, j)) }
					break
				}
				j += 1
			}
		}
		guard !candidates.isEmpty else { return [] }

		func similarity(_ c: (Int, Int), averaged: Bool) -> Double {
			let actual = c.1 - c.0 + 1
			let check = min(size - 2, actual - 2)
			guard check > 0 else { return 1 }
			var sim = 0.0
			var j = 1
			while j < size - 1 && j < actual - 1 {
				let a = trim(o[c.0 + j]), b = trim(s[j])
				let m = max(a.count, b.count)
				if m > 0 {
					let d = 1 - Double(levenshtein(a, b)) / Double(m)
					sim += averaged ? d : d / Double(check)
					if !averaged && sim >= singleThreshold { break }
				}
				j += 1
			}
			return averaged ? sim / Double(check) : sim
		}

		if candidates.count == 1 {
			let c = candidates[0]
			return similarity(c, averaged: false) >= singleThreshold ? [block(o, c.0, c.1)] : []
		}
		var best: (Int, Int)?
		var bestSim = -1.0
		for c in candidates {
			let sim = similarity(c, averaged: true)
			if sim > bestSim { bestSim = sim; best = c }
		}
		if let b = best, bestSim >= multipleThreshold { return [block(o, b.0, b.1)] }
		return []
	}

	/// Все пробельные последовательности считаются одним пробелом.
	static let whitespaceNormalized: Replacer = { content, find in
		func norm(_ s: String) -> String {
			s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		}
		let nf = norm(find)
		let o = lines(content)
		var out: [String] = []
		for line in o {
			let nl = norm(line)
			if nl == nf { out.append(line) }
			else if !nf.isEmpty, nl.contains(nf) {
				let words = find.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
				if !words.isEmpty, let re = try? NSRegularExpression(pattern: words.joined(separator: "\\s+")),
				   let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
				   let r = Range(m.range, in: line) {
					out.append(String(line[r]))
				}
			}
		}
		let fl = lines(find)
		if fl.count > 1, o.count >= fl.count {
			for i in 0...(o.count - fl.count) {
				let b = block(o, i, i + fl.count - 1)
				if norm(b) == nf { out.append(b) }
			}
		}
		return out
	}

	/// Совпадение с точностью до общего отступа блока.
	static let indentationFlexible: Replacer = { content, find in
		func dedent(_ text: String) -> String {
			let l = lines(text)
			let nonEmpty = l.filter { !trim($0).isEmpty }
			guard !nonEmpty.isEmpty else { return text }
			let minIndent = nonEmpty.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
			return l.map { trim($0).isEmpty ? $0 : String($0.dropFirst(minIndent)) }.joined(separator: "\n")
		}
		let nf = dedent(find)
		let o = lines(content), fl = lines(find)
		guard o.count >= fl.count else { return [] }
		var out: [String] = []
		for i in 0...(o.count - fl.count) {
			let b = block(o, i, i + fl.count - 1)
			if dedent(b) == nf { out.append(b) }
		}
		return out
	}

	/// Модель прислала «\n», «\t», «\"» буквально вместо символов.
	static let escapeNormalized: Replacer = { content, find in
		func unescape(_ s: String) -> String {
			var out = ""
			var it = s.makeIterator()
			while let c = it.next() {
				guard c == "\\", let n = it.next() else { out.append(c); continue }
				switch n {
				case "n": out.append("\n")
				case "t": out.append("\t")
				case "r": out.append("\r")
				case "'", "\"", "`", "\\", "\n", "$": out.append(n)
				default: out.append(c); out.append(n)
				}
			}
			return out
		}
		let uf = unescape(find)
		var out: [String] = []
		if content.range(of: uf, options: .literal) != nil { out.append(uf) }
		let o = lines(content), fl = lines(uf)
		if o.count >= fl.count {
			for i in 0...(o.count - fl.count) {
				let b = block(o, i, i + fl.count - 1)
				if unescape(b) == uf { out.append(b) }
			}
		}
		return out
	}

	/// Лишние пустые строки/пробелы по краям oldString.
	static let trimmedBoundary: Replacer = { content, find in
		let tf = find.trimmingCharacters(in: .whitespacesAndNewlines)
		guard tf != find else { return [] }
		var out: [String] = []
		if content.range(of: tf, options: .literal) != nil { out.append(tf) }
		let o = lines(content), fl = lines(find)
		if o.count >= fl.count {
			for i in 0...(o.count - fl.count) {
				let b = block(o, i, i + fl.count - 1)
				if b.trimmingCharacters(in: .whitespacesAndNewlines) == tf { out.append(b) }
			}
		}
		return out
	}

	/// Якоря по краям + хотя бы половина средних строк совпадает.
	static let contextAware: Replacer = { content, find in
		var fl = lines(find)
		guard fl.count >= 3 else { return [] }
		if fl.last == "" { fl.removeLast() }
		let o = lines(content)
		let first = trim(fl[0]), last = trim(fl[fl.count - 1])
		for i in 0..<o.count where trim(o[i]) == first {
			var j = i + 2
			while j < o.count {
				if trim(o[j]) == last {
					let bl = Array(o[i...j])
					if bl.count == fl.count {
						var match = 0, total = 0
						for k in 1..<(bl.count - 1) {
							let a = trim(bl[k]), b = trim(fl[k])
							if !a.isEmpty || !b.isEmpty {
								total += 1
								if a == b { match += 1 }
							}
						}
						if total == 0 || Double(match) / Double(total) >= 0.5 { return [bl.joined(separator: "\n")] }
					}
					break
				}
				j += 1
			}
		}
		return []
	}

	static let multiOccurrence: Replacer = { content, find in
		content.components(separatedBy: find).count > 1 ? [find] : []
	}
}
