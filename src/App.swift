import SwiftUI

@main
struct ForgeApp: App {
	@StateObject private var store = ProjectStore()
	@AppStorage("theme") private var themeID = "xcode"
	@AppStorage(L10n.key) private var language = "en"

	init() {
		CrashLog.install()
		Updater.cleanup()  // старый бандл после обновления
	}

	var body: some Scene {
		WindowGroup {
			ProjectsView()
				.environmentObject(store)
				.tint(Theme.find(themeID).accentColor)
				.id(language)  // L("…") читается при построении — смена языка перестраивает всё
		}
	}
}
