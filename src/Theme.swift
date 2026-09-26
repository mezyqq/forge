import SwiftUI
import UIKit

/// Тема редактора: цвета подсветки, фон, гуттер и акцент приложения.
/// Парные темы (светлая и тёмная версия) следуют оформлению, остальные — всегда тёмные или всегда светлые.
struct Theme: Identifiable, Hashable {
	struct Palette: Hashable {
		var bg, fg, gutter, keyword, type, number, preproc, string, comment, attr: UInt32
	}

	let id: String
	let name: String
	let light: Palette
	let dark: Palette
	let accent: UInt32
	/// .dark/.light — принудительно для редактора (курсор, выделение, клавиатура), nil — как в системе.
	let style: UIUserInterfaceStyle?

	static func rgb(_ v: UInt32) -> UIColor {
		UIColor(red: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
	}

	private func pick(_ f: @escaping (Palette) -> UInt32) -> UIColor {
		let l = f(light), d = f(dark)
		if l == d { return Theme.rgb(l) }
		return UIColor { $0.userInterfaceStyle == .dark ? Theme.rgb(d) : Theme.rgb(l) }
	}

	var bg: UIColor { pick(\.bg) }
	var fg: UIColor { pick(\.fg) }
	var gutter: UIColor { pick(\.gutter) }
	var accentColor: Color { Color(Theme.rgb(accent)) }

	func color(_ r: Lang.Role) -> UIColor {
		switch r {
		case .keyword: return pick(\.keyword)
		case .type: return pick(\.type)
		case .number: return pick(\.number)
		case .preproc: return pick(\.preproc)
		case .string: return pick(\.string)
		case .comment: return pick(\.comment)
		case .attr: return pick(\.attr)
		}
	}

	private static func fixed(_ id: String, _ name: String, _ p: Palette, accent: UInt32, light: Bool = false) -> Theme {
		Theme(id: id, name: name, light: p, dark: p, accent: accent, style: light ? .light : .dark)
	}

	/// Палитра в порядке полей: фон, текст, гуттер, ключевые слова, типы, числа, препроцессор, строки, комментарии, атрибуты.
	private static func P(_ bg: UInt32, _ fg: UInt32, _ gutter: UInt32, _ keyword: UInt32, _ type: UInt32, _ number: UInt32,
	                      _ preproc: UInt32, _ string: UInt32, _ comment: UInt32, _ attr: UInt32) -> Palette {
		Palette(bg: bg, fg: fg, gutter: gutter, keyword: keyword, type: type, number: number, preproc: preproc, string: string, comment: comment, attr: attr)
	}

	/// Светлая и тёмная версия — следует оформлению (Настройки → Оформление).
	private static func pair(_ id: String, _ name: String, light: Palette, dark: Palette, accent: UInt32) -> Theme {
		Theme(id: id, name: name, light: light, dark: dark, accent: accent, style: nil)
	}

	static let all: [Theme] = [
		// светлая и тёмная версия
		pair("xcode", "Xcode",
		     light: P(0xFFFFFF, 0x1F1F24, 0xF2F2F7, 0xAD3DA4, 0x3E8087, 0x272AD8, 0x78492A, 0xD12F1B, 0x707F8C, 0x0F68A0),
		     dark: P(0x1F1F24, 0xFFFFFF, 0x2A2A30, 0xFF7AB2, 0x9EF1DD, 0xD9C97C, 0xFFA14F, 0xFF8170, 0x7F8C98, 0x6BDFFF), accent: 0xFF7A1A),
		pair("github", "GitHub",
		     light: P(0xFFFFFF, 0x24292F, 0xF6F8FA, 0xCF222E, 0x953800, 0x0550AE, 0x8250DF, 0x0A3069, 0x6E7781, 0x116329),
		     dark: P(0x0D1117, 0xC9D1D9, 0x161B22, 0xFF7B72, 0xFFA657, 0x79C0FF, 0xD2A8FF, 0xA5D6FF, 0x8B949E, 0x7EE787), accent: 0x2F81F7),
		pair("one", "One (Atom)",
		     light: P(0xFAFAFA, 0x383A42, 0xF0F0F0, 0xA626A4, 0xC18401, 0x986801, 0x4078F2, 0x50A14F, 0xA0A1A7, 0xE45649),
		     dark: P(0x282C34, 0xABB2BF, 0x21252B, 0xC678DD, 0xE5C07B, 0xD19A66, 0x61AFEF, 0x98C379, 0x5C6370, 0xE06C75), accent: 0x61AFEF),
		pair("catppuccin", "Catppuccin",
		     light: P(0xEFF1F5, 0x4C4F69, 0xE6E9EF, 0x8839EF, 0xDF8E1D, 0xFE640B, 0xEA76CB, 0x40A02B, 0x9CA0B0, 0x1E66F5),
		     dark: P(0x1E1E2E, 0xCDD6F4, 0x181825, 0xCBA6F7, 0xF9E2AF, 0xFAB387, 0xF5C2E7, 0xA6E3A1, 0x6C7086, 0x89B4FA), accent: 0xF5C2E7),
		pair("tokyo", "Tokyo Night",
		     light: P(0xE1E2E7, 0x3760BF, 0xD0D5E3, 0x9854F1, 0x118C74, 0xB15C00, 0x007197, 0x587539, 0x848CB5, 0x2E7DE9),
		     dark: P(0x1A1B26, 0xC0CAF5, 0x16161E, 0xBB9AF7, 0x2AC3DE, 0xFF9E64, 0x7DCFFF, 0x9ECE6A, 0x565F89, 0x7AA2F7), accent: 0x7AA2F7),
		pair("gruvbox", "Gruvbox",
		     light: P(0xFBF1C7, 0x3C3836, 0xF2E5BC, 0x9D0006, 0xB57614, 0x8F3F71, 0xAF3A03, 0x79740E, 0x928374, 0x076678),
		     dark: P(0x282828, 0xEBDBB2, 0x32302F, 0xFB4934, 0xFABD2F, 0xD3869B, 0xFE8019, 0xB8BB26, 0x928374, 0x83A598), accent: 0xFE8019),
		pair("rosepine", "Rosé Pine",
		     light: P(0xFAF4ED, 0x575279, 0xFFFAF3, 0x286983, 0x56949F, 0xD7827E, 0x907AA9, 0xEA9D34, 0x9893A5, 0xB4637A),
		     dark: P(0x191724, 0xE0DEF4, 0x1F1D2E, 0x31748F, 0x9CCFD8, 0xEBBCBA, 0xC4A7E7, 0xF6C177, 0x6E6A86, 0xEB6F92), accent: 0xEBBCBA),
		pair("ayu", "Ayu",
		     light: P(0xFCFCFC, 0x5C6166, 0xF3F4F5, 0xFA8D3E, 0x399EE6, 0xA37ACC, 0xED9366, 0x86B300, 0xADAEB1, 0xF2AE49),
		     dark: P(0x1F2430, 0xCCCAC2, 0x1C212B, 0xFFAD66, 0x73D0FF, 0xDFBFFF, 0xF29E74, 0xD5FF80, 0x6E7C8F, 0xFFD173), accent: 0xFFAD66),
		pair("everforest", "Everforest",
		     light: P(0xFDF6E3, 0x5C6A72, 0xF4F0D9, 0xF85552, 0xDFA000, 0xDF69BA, 0xF57D26, 0x8DA101, 0x939F91, 0x3A94C5),
		     dark: P(0x2D353B, 0xD3C6AA, 0x272E33, 0xE67E80, 0xDBBC7F, 0xD699B6, 0xE69875, 0xA7C080, 0x859289, 0x7FBBB3), accent: 0xA7C080),
		pair("kanagawa", "Kanagawa",
		     light: P(0xF2ECBC, 0x545464, 0xE7DBA0, 0x624C83, 0x597B75, 0xB35B79, 0xC84053, 0x6F894E, 0x8A8980, 0x4D699B),
		     dark: P(0x1F1F28, 0xDCD7BA, 0x2A2A37, 0x957FB8, 0x7AA89F, 0xD27E99, 0xE46876, 0x98BB6C, 0x727169, 0x7E9CD8), accent: 0x7E9CD8),
		pair("owl", "Night Owl",
		     light: P(0xFBFBFB, 0x403F53, 0xF0F0F0, 0x994CC3, 0x4876D6, 0xAA0982, 0x0C969B, 0xC96765, 0x989FB1, 0x4876D6),
		     dark: P(0x011627, 0xD6DEEB, 0x01111D, 0xC792EA, 0xFFCB8B, 0xF78C6C, 0x7FDBCA, 0xECC48D, 0x637777, 0x82AAFF), accent: 0x82AAFF),
		pair("tomorrow", "Tomorrow",
		     light: P(0xFFFFFF, 0x4D4D4C, 0xEFEFEF, 0x8959A8, 0xEAB700, 0xF5871F, 0x3E999F, 0x718C00, 0x8E908C, 0x4271AE),
		     dark: P(0x1D1F21, 0xC5C8C6, 0x282A2E, 0xB294BB, 0xF0C674, 0xDE935F, 0x8ABEB7, 0xB5BD68, 0x969896, 0x81A2BE), accent: 0x81A2BE),
		pair("material", "Material",
		     light: P(0xFAFAFA, 0x546E7A, 0xEEEEEE, 0x7C4DFF, 0xF6A434, 0xF76D47, 0x39ADB5, 0x91B859, 0xAABFC9, 0x6182B8),
		     dark: P(0x292D3E, 0xA6ACCD, 0x242837, 0xC792EA, 0xFFCB6B, 0xF78C6C, 0x89DDFF, 0xC3E88D, 0x676E95, 0x82AAFF), accent: 0xC792EA),
		pair("solarized", "Solarized",
		     light: P(0xFDF6E3, 0x586E75, 0xEEE8D5, 0x859900, 0xB58900, 0xD33682, 0xCB4B16, 0x2AA198, 0x93A1A1, 0x268BD2),
		     dark: P(0x002B36, 0x839496, 0x073642, 0x859900, 0xB58900, 0xD33682, 0xCB4B16, 0x2AA198, 0x586E75, 0x268BD2), accent: 0x268BD2),

		// только тёмные
		fixed("forge", "Orange (Forge)",
		      P(0x17110D, 0xF3E6D8, 0x211811, 0xFF8A3D, 0xFFC857, 0xFF6B6B, 0xE0A458, 0xB5D67A, 0x7D6B5D, 0xF4A261), accent: 0xFF7A1A),
		fixed("dracula", "Purple (Dracula)",
		      P(0x282A36, 0xF8F8F2, 0x21222C, 0xFF79C6, 0x8BE9FD, 0xBD93F9, 0xFFB86C, 0xF1FA8C, 0x6272A4, 0x50FA7B), accent: 0xBD93F9),
		fixed("monokai", "Monokai",
		      P(0x272822, 0xF8F8F2, 0x1F201B, 0xF92672, 0x66D9EF, 0xAE81FF, 0xFD971F, 0xE6DB74, 0x75715E, 0xA6E22E), accent: 0xA6E22E),
		fixed("nord", "Blue (Nord)",
		      P(0x2E3440, 0xD8DEE9, 0x292E39, 0x81A1C1, 0x8FBCBB, 0xB48EAD, 0x5E81AC, 0xA3BE8C, 0x616E88, 0x88C0D0), accent: 0x88C0D0),
		fixed("matrix", "Green (Matrix)",
		      P(0x0B0F0B, 0xC8FFC8, 0x0F150F, 0x39FF14, 0x7CFC00, 0xADFF2F, 0x00FA9A, 0x98FB98, 0x3B6E3B, 0x00FF7F), accent: 0x39FF14),
		fixed("ocean", "Turquoise (Ocean)",
		      P(0x0F1C24, 0xD6E6EE, 0x0B161D, 0x4FD1C5, 0x63B3ED, 0xF6AD55, 0xB794F4, 0x9AE6B4, 0x4A6572, 0x76E4F7), accent: 0x4FD1C5),
		fixed("amoled", "Black (AMOLED)",
		      P(0x000000, 0xE6E6E6, 0x0A0A0A, 0xFF79C6, 0x8BE9FD, 0xBD93F9, 0xFFB86C, 0x50FA7B, 0x6272A4, 0xF1FA8C), accent: 0x0A84FF),
		fixed("synthwave", "Synthwave '84",
		      P(0x262335, 0xFFFFFF, 0x241B2F, 0xFEDE5D, 0xFE4450, 0xF97E72, 0x36F9F6, 0xFF8B39, 0x848BBD, 0x72F1B8), accent: 0xFF7EDB),
		fixed("cobalt", "Cobalt2",
		      P(0x193549, 0xFFFFFF, 0x15232D, 0xFF9D00, 0x80FFBB, 0xFF628C, 0xFFC600, 0x3AD900, 0x0088FF, 0x9EFFFF), accent: 0xFFC600),
		fixed("horizon", "Horizon",
		      P(0x1C1E26, 0xD5D8DA, 0x16161C, 0xB877DB, 0xFAC29A, 0xF09483, 0x25B0BC, 0xFAB795, 0x6C6F93, 0xE95678), accent: 0xE95678),
		fixed("oceanic", "Oceanic Next",
		      P(0x1B2B34, 0xCDD3DE, 0x16232A, 0xC594C5, 0xFAC863, 0xF99157, 0x5FB3B3, 0x99C794, 0x65737E, 0x6699CC), accent: 0x6699CC),
		fixed("crimson", "Red (Crimson)",
		      P(0x1A0F10, 0xF2DEDE, 0x221314, 0xFF4D5A, 0xFFB3A7, 0xFF8C69, 0xE0525F, 0xF5C99B, 0x7A5557, 0xFF6F7D), accent: 0xFF3B4E),
		fixed("coffee", "Coffee",
		      P(0x1E1814, 0xE8DCCF, 0x261E19, 0xD4A373, 0xE9C46A, 0xF4A261, 0xC08552, 0xA7C957, 0x7F6A5A, 0xBC8A5F), accent: 0xD4A373),

		// только светлые
		fixed("paper", "Paper",
		      P(0xFFFFFF, 0x222222, 0xF7F7F7, 0x3B3BD6, 0x6A1B9A, 0xB22222, 0x555555, 0x2E7D32, 0x9E9E9E, 0x1565C0), accent: 0x3B3BD6, light: true),
		fixed("quiet", "Quiet Light",
		      P(0xF5F5F5, 0x333333, 0xE9E9E9, 0x4B83CD, 0x7A3E9D, 0xAB6526, 0x777777, 0x448C27, 0xAAAAAA, 0xAA3731), accent: 0x4B83CD, light: true),
		fixed("sakura", "Pink (Sakura)",
		      P(0xFFF5F7, 0x4A3B40, 0xFCE8EC, 0xD6336C, 0xB5179E, 0xE8590C, 0xC2255C, 0x2F9E44, 0xB8A1A8, 0x7048E8), accent: 0xE64980, light: true),
	]

	static func find(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

	/// Группа в списке тем.
	enum Kind { case both, dark, light }
	var kind: Kind { style == nil ? .both : style == .dark ? .dark : .light }

	/// Палитра, которую видно сейчас (у парных тем — по оформлению).
	func palette(dark isDark: Bool) -> Palette { style == .light ? light : style == .dark ? dark : (isDark ? dark : light) }
	func swatches(dark isDark: Bool) -> [Color] {
		let p = palette(dark: isDark)
		return [p.keyword, p.type, p.string, p.number, p.comment].map { Color(Theme.rgb($0)) }
	}
}
