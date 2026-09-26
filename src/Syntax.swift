import UIKit

/// Описание языка для подсветки регулярками. Правила применяются по порядку (следующее перекрашивает
/// предыдущее), затем комментарии+строки одним выражением (что началось раньше — то и выигрывает),
/// затем `late`-правила.
struct Lang {
	enum Role { case keyword, type, number, preproc, string, comment, attr }

	var name: String
	var words = ""
	var line: String? = "//"
	var block: (String, String)? = ("/*", "*/")
	var quotes = "\"'"
	var triple = false      // """…"""
	var types = true        // слова с заглавной — типы
	var pre = false         // #include, #define
	var at = false          // @interface, @State
	var ci = false          // ключевые слова без учёта регистра (SQL)
	var extra: [(String, Role)] = []
	var late: [(String, Role)] = []
	var plain = false

	static let plainText = Lang(name: "Текст", plain: true)

	static let cfamily = Lang(name: "C / ObjC / C++", words: """
		if else for while do switch case default break continue return goto struct union enum typedef static const \
		extern inline void int char short long float double signed unsigned bool BOOL YES NO nil Nil NULL self super \
		id SEL Class IMP instancetype sizeof volatile register restrict _Bool nonatomic atomic strong weak copy assign \
		readonly readwrite nullable nonnull __block __weak __strong class namespace template typename auto new delete \
		this nullptr using virtual constexpr noexcept operator public private protected friend try catch throw true \
		false mutable explicit static_cast dynamic_cast reinterpret_cast const_cast override final decltype
		""", pre: true, at: true)

	static let swift = Lang(name: "Swift", words: """
		import class struct enum protocol extension func let var init deinit subscript typealias associatedtype if else \
		guard switch case default for in while repeat break continue return fallthrough do try catch throw throws \
		rethrows async await defer where is as nil true false self Self super public private internal fileprivate open \
		static final override mutating nonmutating lazy weak unowned inout some any get set willSet didSet convenience \
		required indirect operator precedencegroup actor nonisolated isolated consuming borrowing
		""", triple: true, pre: true, at: true)

	static let python = Lang(name: "Python", words: """
		False None True and as assert async await break class continue def del elif else except finally for from \
		global if import in is lambda nonlocal not or pass raise return try while with yield self match case
		""", line: "#", block: nil, triple: true, extra: [("@[A-Za-z_][\\w.]*", .preproc)])

	static let js = Lang(name: "JavaScript / TypeScript", words: """
		break case catch class const continue debugger default delete do else export extends finally for function if \
		import in instanceof let new return super switch this throw try typeof var void while with yield async await \
		of true false null undefined interface type enum implements private public protected readonly static abstract \
		as from declare namespace keyof satisfies
		""", quotes: "\"'`")

	static let rust = Lang(name: "Rust", words: """
		as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move \
		mut pub ref return self Self static struct super trait true type unsafe use where while
		""", quotes: "\"", extra: [("#!?\\[[^\\]]*\\]", .preproc), ("\\b\\w+!", .preproc)])

	static let go = Lang(name: "Go", words: """
		break case chan const continue default defer else fallthrough for func go goto if import interface map package \
		range return select struct switch type var true false nil iota
		""", quotes: "\"'`")

	static let java = Lang(name: "Java / Kotlin", words: """
		abstract boolean break byte case catch char class continue default do double else enum extends final finally \
		float for if implements import instanceof int interface long new package private protected public return short \
		static super switch this throw throws try void while true false null fun val var when object companion data \
		sealed override open lateinit is in out suspend
		""", triple: true, at: true)

	static let lua = Lang(name: "Lua", words: """
		and break do else elseif end false for function goto if in local nil not or repeat return then true until while self
		""", line: "--", block: ("--[[", "]]"))

	static let ruby = Lang(name: "Ruby", words: """
		def end if elsif else unless while until for in do return class module self nil true false yield begin rescue \
		ensure require require_relative attr_accessor attr_reader puts then case when and or not
		""", line: "#", block: ("=begin", "=end"), extra: [(":[A-Za-z_]\\w*", .number)])

	static let shell = Lang(name: "Shell", words: """
		if then else elif fi for while until do done case esac function in return export local echo exit set unset \
		source read shift true false
		""", line: "#", block: nil, types: false, extra: [("\\$\\{[^}]*\\}|\\$\\w+", .attr)])

	static let sql = Lang(name: "SQL", words: """
		select from where insert into values update set delete create table index view drop alter add primary key \
		foreign references not null unique default and or in is like between join left right inner outer on as order \
		by group having limit offset distinct union all case when then else end begin commit rollback integer text \
		real blob
		""", line: "--", types: false, ci: true)

	static let css = Lang(name: "CSS", line: nil, types: false,
		extra: [("[\\w-]+(?=\\s*:)", .attr), ("#[0-9a-fA-F]{3,8}\\b", .number), ("[.#][A-Za-z_][\\w-]*(?=[^;{}]*\\{)", .type)])

	static let markup = Lang(name: "HTML / XML / plist", line: nil, block: ("<!--", "-->"), types: false,
		extra: [("</?[A-Za-z][\\w:.-]*|/?>", .keyword), ("\\b[\\w:-]+(?==)", .attr), ("&\\w+;", .number)])

	static let json = Lang(name: "JSON", words: "true false null", line: nil, block: nil, quotes: "\"", types: false,
		late: [("\"(?:\\\\.|[^\"\\\\\\n])*\"(?=\\s*:)", .attr)])

	static let yaml = Lang(name: "YAML", words: "true false null yes no", line: "#", block: nil, types: false,
		extra: [("^\\s*-?\\s*[\\w.-]+(?=\\s*:)", .attr)])

	static let markdown = Lang(name: "Markdown", line: nil, block: nil, quotes: "`", types: false,
		extra: [("^#{1,6}\\s.*$", .keyword), ("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__", .type),
		        ("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", .attr), ("^\\s*(?:[-*+]|\\d+\\.)\\s", .preproc), ("^>.*$", .comment)],
		late: [("```[\\s\\S]*?(?:```|\\z)", .string)])

	static let make = Lang(name: "Makefile", line: "#", block: nil, types: false,
		extra: [("^[\\w./%-]+(?=\\s*:)", .keyword), ("\\$\\([^)]*\\)|\\$[@<^*]", .attr)])

	static let all: [Lang] = [cfamily, swift, python, js, rust, go, java, lua, ruby, shell, sql, css, markup, json,
	                          yaml, markdown, make, plainText]

	static func detect(_ path: String) -> Lang {
		let file = (path as NSString).lastPathComponent
		if file == "Makefile" || file == "makefile" || file == "GNUmakefile" { return make }
		if file == "ipa.conf" || file.hasPrefix(".bash") || file.hasPrefix(".zsh") { return shell }
		switch (path as NSString).pathExtension.lowercased() {
		case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "metal", "cs": return cfamily
		case "swift": return swift
		case "py", "pyw": return python
		case "js", "mjs", "cjs", "jsx", "ts", "tsx": return js
		case "rs": return rust
		case "go": return go
		case "java", "kt", "kts", "scala", "gradle", "dart": return java
		case "lua": return lua
		case "rb": return ruby
		case "sh", "bash", "zsh", "conf", "env", "command": return shell
		case "sql": return sql
		case "css", "scss", "less": return css
		case "html", "htm", "xml", "plist", "svg", "entitlements", "xib", "storyboard", "vue": return markup
		case "json", "jsonc": return json
		case "yml", "yaml", "toml", "ini": return yaml
		case "md", "markdown": return markdown
		case "mk": return make
		default: return plainText
		}
	}
}

enum Syntax {
	static func font(_ size: CGFloat) -> UIFont { UIFont.monospacedSystemFont(ofSize: size, weight: .regular) }

	static func base(_ size: CGFloat, _ theme: Theme) -> [NSAttributedString.Key: Any] {
		let f = font(size)
		let p = NSMutableParagraphStyle()
		p.tabStops = []
		p.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: f]).width
		return [.font: f, .foregroundColor: theme.fg, .paragraphStyle: p]
	}

	/// Регулярки языка (без цветов — цвета берутся из темы при покраске).
	private final class Compiled {
		var rules: [(NSRegularExpression, Lang.Role)] = []
		var spans: NSRegularExpression?
		var late: [(NSRegularExpression, Lang.Role)] = []
	}

	private static var cache: [String: Compiled] = [:]

	private static func re(_ p: String, _ ci: Bool = false) -> NSRegularExpression? {
		try? NSRegularExpression(pattern: p, options: ci ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines])
	}

	private static func compile(_ l: Lang) -> Compiled {
		if let c = cache[l.name] { return c }
		let c = Compiled()
		func add(_ p: String, _ role: Lang.Role, ci: Bool = false, to list: inout [(NSRegularExpression, Lang.Role)]) {
			if let r = re(p, ci) { list.append((r, role)) }
		}
		if l.types { add("\\b[A-Z][A-Za-z0-9_]*\\b", .type, to: &c.rules) }
		let words = l.words.split(whereSeparator: { $0 == " " || $0 == "\n" })
		if !words.isEmpty { add("\\b(?:" + words.joined(separator: "|") + ")\\b", .keyword, ci: l.ci, to: &c.rules) }
		if l.at { add("@[A-Za-z_]\\w*", .keyword, to: &c.rules) }
		add("\\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[uUlLfF]*\\b", .number, to: &c.rules)
		if l.pre { add("^\\s*#\\s*\\w+", .preproc, to: &c.rules) }
		for (p, r) in l.extra { add(p, r, to: &c.rules) }

		let esc = NSRegularExpression.escapedPattern(for:)
		var comments: [String] = []
		if let s = l.line { comments.append(esc(s) + "[^\\n]*") }
		if let bl = l.block { comments.insert(esc(bl.0) + "[\\s\\S]*?(?:" + esc(bl.1) + "|\\z)", at: 0) }  // --[[ раньше --
		var strings: [String] = []
		if l.triple { strings.append("\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)") }
		for q in l.quotes {
			let e = esc(String(q))
			strings.append(q == "`" ? "`[^`]*`?" : (l.at && q == "\"" ? "@?" : "") + e + "(?:\\\\.|[^" + e + "\\\\\\n])*" + e + "?")
		}
		let g1 = comments.isEmpty ? "(?!)" : comments.joined(separator: "|")
		let g2 = strings.isEmpty ? "(?!)" : strings.joined(separator: "|")
		c.spans = re("(" + g1 + ")|(" + g2 + ")")
		for (p, r) in l.late { add(p, r, to: &c.late) }
		cache[l.name] = c
		return c
	}

	static func highlight(_ tv: UITextView, lang: Lang, size: CGFloat, theme: Theme) {
		guard tv.markedTextRange == nil else { return }  // не мешаем вводу через IME
		let ts = tv.textStorage
		let full = NSRange(location: 0, length: ts.length)
		let s = ts.string
		let b = base(size, theme)
		ts.beginEditing()
		ts.setAttributes(b, range: full)
		if !lang.plain, ts.length < 400_000 {
			let c = compile(lang)
			func paint(_ list: [(NSRegularExpression, Lang.Role)]) {
				for (r, role) in list {
					let col = theme.color(role)
					r.enumerateMatches(in: s, range: full) { m, _, _ in
						if let m { ts.addAttribute(.foregroundColor, value: col, range: m.range) }
					}
				}
			}
			paint(c.rules)
			let comment = theme.color(.comment), string = theme.color(.string)
			c.spans?.enumerateMatches(in: s, range: full) { m, _, _ in
				guard let m else { return }
				ts.addAttribute(.foregroundColor, value: m.range(at: 1).location != NSNotFound ? comment : string, range: m.range)
			}
			paint(c.late)
		}
		ts.endEditing()
		tv.typingAttributes = b
	}
}
