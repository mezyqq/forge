import Foundation

/// Язык интерфейса: английский по умолчанию, русский — Настройки → Language.
/// Строки в коде — английские, обёрнутые в L("…"); русские переводы — в таблице ниже (ключ — английский текст).
/// Подстановки: L("Build %@", name) — каждый %@ по порядку заменяется на аргумент.
/// Смена языка перестраивает интерфейс целиком (корневой .id(language) в App.swift).
enum L10n {
	static let key = "language"
	static let languages: [(id: String, title: String)] = [("en", "English"), ("ru", "Русский")]

	static var isRussian: Bool { UserDefaults.standard.string(forKey: key) == "ru" }

	static let ru: [String: String] = Dictionary(ruPairs, uniquingKeysWith: { a, _ in a })
}

func L(_ en: String, _ args: Any...) -> String {
	var s = L10n.isRussian ? (L10n.ru[en] ?? en) : en
	for a in args {
		guard let r = s.range(of: "%@") else { break }
		s.replaceSubrange(r, with: "\(a)")
	}
	return s
}
