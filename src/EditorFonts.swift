import CoreText
import UIKit

/// Шрифты редактора: системный моноширинный, Menlo и встроенные в бандл (res/fonts) с лигатурами для кода.
enum EditorFonts {
	struct Item: Identifiable {
		let id: String
		let title: String
		let file: String?
	}

	static let key = "editorFont"
	static let ligaturesKey = "ligatures"

	static let all: [Item] = [
		Item(id: "system", title: "SF Mono", file: nil),
		Item(id: "jetbrains", title: "JetBrains Mono", file: "JetBrainsMono-Regular.ttf"),
		Item(id: "fira", title: "Fira Code", file: "FiraCode-Regular.ttf"),
		Item(id: "cascadia", title: "Cascadia Code", file: "CascadiaCode.ttf"),
		Item(id: "menlo", title: "Menlo", file: nil),
	]

	private static var names: [String: String] = ["menlo": "Menlo-Regular"]
	private static var cache: [String: UIFont] = [:]

	/// Один раз при запуске: встроенные шрифты доступны только этому процессу.
	static func register() {
		for item in all {
			guard let file = item.file else { continue }
			let url = Bundle.main.bundleURL.appendingPathComponent("fonts/" + file)
			CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
			if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
			   let d = descs.first, let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String {
				names[item.id] = name
			}
		}
	}

	static var ligatures: Bool { UserDefaults.standard.object(forKey: ligaturesKey) as? Bool ?? true }

	/// Текущий шрифт редактора (настройки: шрифт и лигатуры).
	static func font(_ size: CGFloat) -> UIFont {
		let id = UserDefaults.standard.string(forKey: key) ?? "system"
		let lig = ligatures
		let cacheKey = "\(id)|\(size)|\(lig)"
		if let f = cache[cacheKey] { return f }
		var f = names[id].flatMap { UIFont(name: $0, size: size) } ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
		if !lig {
			// лигатуры для кода (!=, ->, =>) приходят из контекстных альтернатив — выключаем их
			let off: [UIFontDescriptor.FeatureKey: Int] = [.type: kContextualAlternatesType, .selector: kContextualAlternatesOffSelector]
			f = UIFont(descriptor: f.fontDescriptor.addingAttributes([.featureSettings: [off]]), size: size)
		}
		cache[cacheKey] = f
		return f
	}
}
