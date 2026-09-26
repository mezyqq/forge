import SwiftUI

/// Необязательные функции (Настройки → Функции). Всё выключено по умолчанию.
enum Feature {
	static let hotReload = "featureHotReload"          // превью пересобирается при сохранении
	static let agentScreenshot = "featureScreenshot"   // инструмент screenshot у агента
	static let voiceInput = "featureVoice"             // микрофон в чате
	static let autoUpdate = "featureAutoUpdate"        // проверка обновлений при запуске

	static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

struct FeaturesSection: View {
	@AppStorage(Feature.hotReload) private var hotReload = false
	@AppStorage(Feature.agentScreenshot) private var screenshot = false
	@AppStorage(Feature.voiceInput) private var voice = false
	@AppStorage(Feature.autoUpdate) private var autoUpdate = false

	var body: some View {
		Section {
			Toggle(isOn: $hotReload) {
				Label(L("Live reload of the preview"), systemImage: "bolt.horizontal.circle")
			}
			Toggle(isOn: $screenshot) {
				Label(L("AI can take screenshots of the preview"), systemImage: "camera.viewfinder")
			}
			Toggle(isOn: $voice) {
				Label(L("Voice input in the chat"), systemImage: "mic")
			}
			Toggle(isOn: $autoUpdate) {
				Label(L("Check for updates on launch"), systemImage: "arrow.triangle.2.circlepath")
			}
		} header: {
			Text(L("Features"))
		} footer: {
			Text(L("Live reload: while a preview (⋯ → Run in Forge) is open, saving a source file rebuilds it and swaps the screen. Screenshots: the AI sees the open preview (the model must support images)."))
		}
	}
}

/// Состояние JIT и ручной переключатель для способов, которые Forge не может распознать.
struct JITSection: View {
	@AppStorage(JIT.forceKey) private var force = false
	@State private var status = JIT.status

	var body: some View {
		Section {
			HStack {
				Text("JIT")
				Spacer()
				Text(text).foregroundStyle(status == .off ? Color.secondary : Color.green)
				Button { status = JIT.status } label: { Image(systemName: "arrow.clockwise") }
					.buttonStyle(.borderless)
			}
			Toggle(L("JIT is enabled by another tool (don't check)"), isOn: $force)
				.onChange(of: force) { _ in status = JIT.status }
		} header: {
			Text(L("Native code"))
		} footer: {
			Text(L("Needed for running C / C++ / ObjC without installing. Forge recognizes debugger-based JIT (StikDebug, SideStore, LiveContainer) and JIT that allows executable memory (Lara). Turn the switch on only if JIT is really enabled — otherwise running code crashes Forge."))
		}
		.onAppear { status = JIT.status }
	}

	private var text: String {
		switch status {
		case .debugger: return L("on (debugger)")
		case .memory: return L("on (memory)")
		case .forced: return L("on (manually)")
		case .off: return L("off")
		}
	}
}
