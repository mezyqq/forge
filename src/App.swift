import SwiftUI

@main
struct ForgeApp: App {
	@StateObject private var store = ProjectStore()
	@AppStorage("theme") private var themeID = "xcode"
	@AppStorage(L10n.key) private var language = "en"
	@AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

	init() {
		CrashLog.install()
		EditorFonts.register()
		Updater.cleanup()  // старый бандл после обновления
		Snapshots.checkVersionChange()  // вернулись на новую версию — предложим её данные
	}

	var body: some Scene {
		WindowGroup {
			ProjectsView()
				.environmentObject(store)
				.modifier(PreviewHostModifier())
				.tint(Theme.find(themeID).accentColor)
				.onAppear { Appearance.apply(appearance) }
				.onChange(of: appearance) { Appearance.apply($0) }
				.id(language)  // L("…") читается при построении — смена языка перестраивает всё
		}
	}
}
