import SwiftUI

@main
struct ForgeApp: App {
	@StateObject private var store = ProjectStore()
	@AppStorage("theme") private var themeID = "xcode"

	init() { CrashLog.install() }

	var body: some Scene {
		WindowGroup {
			ProjectsView()
				.environmentObject(store)
				.tint(Theme.find(themeID).accentColor)
		}
	}
}
