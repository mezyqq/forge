import SwiftUI
import UIKit

/// Тема редактора: цвета подсветки, фон, гуттер и акцент приложения.
/// У «Xcode» светлая и тёмная версии (следует системе), остальные — фиксированные.
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

	/// Цвета для превью в настройках.
	var swatches: [Color] {
		let p = style == .light ? light : dark
		return [p.keyword, p.type, p.string, p.number, p.comment].map { Color(Theme.rgb($0)) }
	}
	var previewBg: Color { Color(Theme.rgb((style == .light ? light : dark).bg)) }

	private static func fixed(_ id: String, _ name: String, _ p: Palette, accent: UInt32, light: Bool = false) -> Theme {
		Theme(id: id, name: name, light: p, dark: p, accent: accent, style: light ? .light : .dark)
	}

	static let all: [Theme] = [
		Theme(id: "xcode", name: "Xcode (как в системе)",
		      light: Palette(bg: 0xFFFFFF, fg: 0x1F1F24, gutter: 0xF2F2F7, keyword: 0xAD3DA4, type: 0x3E8087, number: 0x272AD8,
		                     preproc: 0x78492A, string: 0xD12F1B, comment: 0x707F8C, attr: 0x0F68A0),
		      dark: Palette(bg: 0x1F1F24, fg: 0xFFFFFF, gutter: 0x2A2A30, keyword: 0xFF7AB2, type: 0x9EF1DD, number: 0xD9C97C,
		                    preproc: 0xFFA14F, string: 0xFF8170, comment: 0x7F8C98, attr: 0x6BDFFF),
		      accent: 0xFF7A1A, style: nil),
		fixed("forge", "Оранжевая (Forge)",
		      Palette(bg: 0x17110D, fg: 0xF3E6D8, gutter: 0x211811, keyword: 0xFF8A3D, type: 0xFFC857, number: 0xFF6B6B,
		              preproc: 0xE0A458, string: 0xB5D67A, comment: 0x7D6B5D, attr: 0xF4A261), accent: 0xFF7A1A),
		fixed("dracula", "Фиолетовая (Dracula)",
		      Palette(bg: 0x282A36, fg: 0xF8F8F2, gutter: 0x21222C, keyword: 0xFF79C6, type: 0x8BE9FD, number: 0xBD93F9,
		              preproc: 0xFFB86C, string: 0xF1FA8C, comment: 0x6272A4, attr: 0x50FA7B), accent: 0xBD93F9),
		fixed("catppuccin", "Розовая (Catppuccin)",
		      Palette(bg: 0x1E1E2E, fg: 0xCDD6F4, gutter: 0x181825, keyword: 0xCBA6F7, type: 0xF9E2AF, number: 0xFAB387,
		              preproc: 0xF5C2E7, string: 0xA6E3A1, comment: 0x6C7086, attr: 0x89B4FA), accent: 0xF5C2E7),
		fixed("monokai", "Monokai",
		      Palette(bg: 0x272822, fg: 0xF8F8F2, gutter: 0x1F201B, keyword: 0xF92672, type: 0x66D9EF, number: 0xAE81FF,
		              preproc: 0xFD971F, string: 0xE6DB74, comment: 0x75715E, attr: 0xA6E22E), accent: 0xA6E22E),
		fixed("nord", "Синяя (Nord)",
		      Palette(bg: 0x2E3440, fg: 0xD8DEE9, gutter: 0x292E39, keyword: 0x81A1C1, type: 0x8FBCBB, number: 0xB48EAD,
		              preproc: 0x5E81AC, string: 0xA3BE8C, comment: 0x616E88, attr: 0x88C0D0), accent: 0x88C0D0),
		fixed("matrix", "Зелёная (Матрица)",
		      Palette(bg: 0x0B0F0B, fg: 0xC8FFC8, gutter: 0x0F150F, keyword: 0x39FF14, type: 0x7CFC00, number: 0xADFF2F,
		              preproc: 0x00FA9A, string: 0x98FB98, comment: 0x3B6E3B, attr: 0x00FF7F), accent: 0x39FF14),
		fixed("ocean", "Бирюзовая (Ocean)",
		      Palette(bg: 0x0F1C24, fg: 0xD6E6EE, gutter: 0x0B161D, keyword: 0x4FD1C5, type: 0x63B3ED, number: 0xF6AD55,
		              preproc: 0xB794F4, string: 0x9AE6B4, comment: 0x4A6572, attr: 0x76E4F7), accent: 0x4FD1C5),
		fixed("solarized", "Светлая (Solarized)",
		      Palette(bg: 0xFDF6E3, fg: 0x586E75, gutter: 0xEEE8D5, keyword: 0x859900, type: 0xB58900, number: 0xD33682,
		              preproc: 0xCB4B16, string: 0x2AA198, comment: 0x93A1A1, attr: 0x268BD2), accent: 0x268BD2, light: true),
	]

	static func find(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}
