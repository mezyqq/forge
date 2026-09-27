import SwiftUI
import WebKit

/// Консоль запуска: вывод программы + строка ввода (stdin).
struct RunView: View {
	let url: URL
	@ObservedObject private var runner = Runner.shared
	@Environment(\.dismiss) private var dismiss
	@State private var input = ""

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				if let frame = runner.frame {
					// скрипт рисует (pygame, love, gfx) — экран сверху, консоль снизу
					GameCanvas(frame: frame)
					Divider()
					ConsoleText(output: runner.output).frame(height: 120)
				} else {
					ConsoleText(output: runner.output)
				}
				Divider()
				HStack(spacing: 8) {
					TextField(runner.running ? L("program input") : L("program is not running"), text: $input)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.textFieldStyle(.roundedBorder)
						.onSubmit(send)
						.disabled(!runner.running)
					Button(action: send) { Image(systemName: "return") }
						.disabled(!runner.running)
				}
				.padding(8)
			}
			.navigationTitle(runner.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button { UIPasteboard.general.string = runner.output } label: { Image(systemName: "doc.on.doc") }
					if runner.running {
						Button { runner.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
					} else {
						Button { runner.run(url) } label: { Image(systemName: "play.fill") }
					}
				}
			}
		}
		.onAppear { runner.run(url) }
		.onDisappear { if runner.running { runner.stop() } }
	}

	private func send() {
		runner.send(input)
		input = ""
	}
}

/// Вывод консоли с автопрокруткой вниз.
struct ConsoleText: View {
	let output: String
	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				Text(output.isEmpty ? " " : output)
					.font(.system(.footnote, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(12)
				Color.clear.frame(height: 1).id("end")
			}
			.onChange(of: output) { _ in proxy.scrollTo("end", anchor: .bottom) }
		}
		.background(Color(.secondarySystemBackground))
	}
}

// MARK: сборка .ipa

/// Консоль сборки iOS-приложения на телефоне. Ошибки clang — списком (нажатие открывает файл на нужной строке),
/// по готовности — установка в LiveContainer и «Поделиться .ipa».
struct BuildView: View {
	let project: URL
	let release: Bool
	@ObservedObject private var runner = Runner.shared
	@Environment(\.dismiss) private var dismiss
	@State private var ipa: URL?
	@State private var share: ShareItem?
	@State private var issues: [Clang.Issue] = []
	@State private var installed = false
	@State private var installing = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				ConsoleText(output: runner.output)
				if !issues.isEmpty && !runner.running {
					Divider()
					issueList
				}
				if let ipa, !runner.running {
					Divider()
					VStack(spacing: 8) {
						Button { install(ipa) } label: {
							Label(L("Install in LiveContainer"), systemImage: "arrow.down.app")
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(.borderedProminent)
						.disabled(installing)
						if installed && LiveContainer.hosting {
							Text(L("Installed into LiveContainer. Open closes Forge and shows LiveContainer — tap the app there (it gets signed on that launch)."))
								.font(.footnote).foregroundStyle(.secondary)
						}
						HStack(spacing: 8) {
							if installed {
								Button(action: launch) {
									Label(L("Open"), systemImage: "play.fill").frame(maxWidth: .infinity)
								}
								.buttonStyle(.bordered)
							}
							Button { share = ShareItem(url: ipa) } label: {
								Label(L("Share %@", ipa.lastPathComponent), systemImage: "square.and.arrow.up")
									.frame(maxWidth: .infinity)
							}
							.buttonStyle(.bordered)
						}
					}
					.padding(8)
				}
			}
			.navigationTitle(release ? L("Release") : L("Build"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button { UIPasteboard.general.string = runner.output } label: { Image(systemName: "doc.on.doc") }
					if runner.running {
						Button { runner.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
					} else {
						Button(action: start) { Image(systemName: "hammer.fill") }
					}
				}
			}
			.errorAlert($error)
		}
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.onAppear(perform: start)
		.onDisappear { if runner.running { runner.stop() } }
	}

	/// Ошибки и предупреждения сборки; нажатие — файл на строке с ошибкой.
	private var issueList: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(issues) { i in
					let rel = relative(i.file)
					NavigationLink {
						if let rel { EditorScreen(project: Project(url: project), path: rel, line: i.line) }
					} label: {
						HStack(alignment: .top, spacing: 8) {
							Image(systemName: i.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
								.foregroundStyle(i.isError ? Color.red : Color.orange)
							VStack(alignment: .leading, spacing: 2) {
								if let rel { Text("\(rel):\(i.line)").font(.caption.monospaced()).foregroundStyle(.secondary) }
								Text(i.message).font(.footnote).multilineTextAlignment(.leading).lineLimit(3)
							}
							Spacer(minLength: 0)
						}
						.foregroundStyle(.primary)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
					}
					.disabled(rel == nil)
					Divider()
				}
			}
		}
		.frame(maxHeight: 220)
	}

	/// Путь от корня проекта, если ошибка в его файле.
	private func relative(_ file: String) -> String? {
		let root = project.path + "/"
		return file.hasPrefix(root) ? String(file.dropFirst(root.count)) : nil
	}

	private func start() {
		ipa = nil
		issues = []
		installed = false
		runner.build(project, release: release) { code in
			issues = Clang.issues(in: runner.output)
			if code == 0 { ipa = IpaBuilder.ipaURL(project) }
		}
	}

	private func install(_ ipa: URL) {
		Task {
			if LiveContainer.hosting {
				// Forge сам в LiveContainer: кладём приложение в его папку, подпишет LiveContainer при запуске
				installing = true
				defer { installing = false }
				do {
					_ = try await LiveContainer.installInside(ipa)
					installed = true
				} catch { self.error = error.localizedDescription }
			} else if await LiveContainer.install(ipa) {
				installed = true
			} else {
				error = L("LiveContainer did not open. Is it installed? You can also share the .ipa.")
			}
		}
	}

	private func launch() {
		if LiveContainer.hosting { LiveContainer.openHostUI(); return }
		let bid = (try? IpaBuilder.Config(project))?.value("BUNDLE_ID") ?? ""
		Task {
			if !(await LiveContainer.launch(bundleID: bid)) { error = L("LiveContainer did not open.") }
		}
	}
}

// MARK: веб-превью

final class WebConsole: NSObject, ObservableObject, WKScriptMessageHandler {
	@Published var lines: [String] = []
	func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
		lines.append("\(m.body)")
		if lines.count > 500 { lines.removeFirst(lines.count - 500) }
	}
}

struct WebView: UIViewRepresentable {
	let url: URL
	let root: URL
	let console: WebConsole
	let reload: Int

	static let hook = """
	(function(){
	  function send(k,a){try{window.webkit.messageHandlers.forge.postMessage(k+': '+Array.from(a).map(function(x){
	    try{return typeof x==='object'?JSON.stringify(x):String(x)}catch(e){return String(x)}}).join(' '))}catch(e){}}
	  ['log','info','warn','error','debug'].forEach(function(k){var o=console[k];console[k]=function(){send(k,arguments);if(o)o.apply(console,arguments)}});
	  window.addEventListener('error',function(e){send('error',[e.message+' ('+(e.filename||'').split('/').pop()+':'+e.lineno+')'])});
	})();
	"""

	func makeUIView(context: Context) -> WKWebView {
		let cfg = WKWebViewConfiguration()
		cfg.userContentController.addUserScript(WKUserScript(source: WebView.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
		cfg.userContentController.add(console, name: "forge")
		let wv = WKWebView(frame: .zero, configuration: cfg)
		if #available(iOS 16.4, *) { wv.isInspectable = true }
		wv.loadFileURL(url, allowingReadAccessTo: root)
		context.coordinator.reload = reload
		return wv
	}

	func updateUIView(_ wv: WKWebView, context: Context) {
		if context.coordinator.reload != reload {
			context.coordinator.reload = reload
			wv.loadFileURL(url, allowingReadAccessTo: root)
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator() }
	final class Coordinator { var reload = 0 }
}

struct WebRunView: View {
	let url: URL
	let root: URL
	@Environment(\.dismiss) private var dismiss
	@StateObject private var console = WebConsole()
	@State private var reload = 0
	@State private var showConsole = true

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				WebView(url: url, root: root, console: console, reload: reload)
				if showConsole {
					Divider()
					ScrollView {
						VStack(alignment: .leading, spacing: 2) {
							ForEach(Array(console.lines.enumerated()), id: \.offset) { _, l in
								Text(l).font(.caption.monospaced())
									.foregroundStyle(l.hasPrefix("error") ? .red : l.hasPrefix("warn") ? .orange : .primary)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(8)
					}
					.frame(height: 150)
					.background(Color(.secondarySystemBackground))
				}
			}
			.navigationTitle(url.lastPathComponent)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button { showConsole.toggle() } label: { Image(systemName: "terminal") }
					Button { console.lines = []; reload += 1 } label: { Image(systemName: "arrow.clockwise") }
				}
			}
		}
	}
}

/// Что открыть по кнопке ▶: консоль или веб-превью.
struct RunTarget: Identifiable {
	let url: URL
	let root: URL
	var id: URL { url }
	var isWeb: Bool { RunKind.detect(url.path) == .web }
}

struct RunSheet: View {
	let target: RunTarget
	var body: some View {
		if target.isWeb { WebRunView(url: target.url, root: target.root) } else { RunView(url: target.url) }
	}
}

// MARK: быстрый запуск (JIT)

/// Проект, собранный прямо в память Forge (без установки): консоль сборки и программы. Если в проекте есть
/// `UIViewController *forge_preview(void)`, консоль закрывается и экран открывает PreviewHost.
struct QuickRunView: View {
	let project: URL
	@ObservedObject private var runner = Runner.shared
	@Environment(\.dismiss) private var dismiss
	@State private var input = ""
	@State private var error: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				ConsoleText(output: runner.output)
				Divider()
				HStack(spacing: 8) {
					TextField(runner.running ? L("program input") : L("program is not running"), text: $input)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.textFieldStyle(.roundedBorder)
						.onSubmit(send)
						.disabled(!runner.running)
					Button(action: send) { Image(systemName: "return") }.disabled(!runner.running)
				}
				.padding(8)
			}
			.navigationTitle(project.lastPathComponent)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					if runner.running {
						Button { runner.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
					} else {
						Button(action: start) { Image(systemName: "bolt.fill") }
					}
				}
			}
			.errorAlert($error)
		}
		.onAppear(perform: start)
		.onDisappear { if runner.running { runner.stop() } }
	}

	private func send() {
		runner.send(input)
		input = ""
	}

	private func start() {
		PreviewHost.shared.close()
		runner.quickRun(project) { jit in
			guard let jit else { return }
			switch Clang.previewController(jit) {
			case .success(let vc):
				// показываем поверх всего приложения, когда эта консоль уже закрыта
				dismiss()
				let p = project
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PreviewHost.shared.show(vc, project: p) }
			case .failure(let f): error = f.message
			}
		}
	}
}

/// UIViewController из JIT-кода внутри SwiftUI (как дочерний контроллер).
struct HostedController: UIViewControllerRepresentable {
	let vc: UIViewController

	func makeUIViewController(context: Context) -> UIViewController {
		let host = UIViewController()
		HostedController.adopt(vc, by: host)
		fill(host)
		return host
	}

	func updateUIViewController(_ host: UIViewController, context: Context) {
		if vc.parent !== host { HostedController.adopt(vc, by: host) }
		fill(host)
	}

	private func fill(_ host: UIViewController) {
		vc.view.transform = .identity
		vc.view.frame = host.view.bounds
		vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
	}

	/// Перенести контроллер в новый контейнер (полный экран ↔ мини-окно).
	static func adopt(_ vc: UIViewController, by host: UIViewController) {
		if vc.parent != nil {
			vc.willMove(toParent: nil)
			vc.view.removeFromSuperview()
			vc.removeFromParent()
		}
		host.addChild(vc)
		host.view.addSubview(vc.view)
		vc.didMove(toParent: host)
	}
}

// MARK: графика скриптов

/// Холст скрипта: кадр во всю доступную область (с сохранением пропорций), касания — мышь, снизу — пульт.
struct GameCanvas: View {
	let frame: CGImage
	@AppStorage("gamePad") private var showPad = true
	@State private var touching = false

	var body: some View {
		GeometryReader { geo in
			let w = CGFloat(frame.width), h = CGFloat(frame.height)
			let scale = min(geo.size.width / w, geo.size.height / h)
			Image(decorative: frame, scale: 1)
				.resizable()
				.frame(width: w * scale, height: h * scale)
				.contentShape(Rectangle())
				.gesture(DragGesture(minimumDistance: 0)
					.onChanged { v in
						let x = Float(v.location.x / scale), y = Float(v.location.y / scale)
						forge_gfx_push(Int32(touching ? GFX_MOVE : GFX_DOWN), x, y, 0)
						touching = true
					}
					.onEnded { v in
						forge_gfx_push(Int32(GFX_UP), Float(v.location.x / scale), Float(v.location.y / scale), 0)
						touching = false
					})
				.position(x: geo.size.width / 2, y: geo.size.height / 2)
		}
		.background(Color.black)
		.overlay(alignment: .bottom) { if showPad { GamePad().padding(10) } }
		.overlay(alignment: .topTrailing) {
			Button { showPad.toggle() } label: {
				Image(systemName: showPad ? "gamecontroller.fill" : "gamecontroller")
					.padding(8)
					.background(.ultraThinMaterial, in: Circle())
			}
			.padding(8)
		}
	}
}

/// Экранный пульт: стрелки, A — пробел, B — Enter, Esc. Нажатие и отпускание — отдельные события.
struct GamePad: View {
	var body: some View {
		HStack(alignment: .bottom) {
			VStack(spacing: 4) {
				PadKey(symbol: "arrowtriangle.up.fill", key: GFX_KEY_UP)
				HStack(spacing: 4) {
					PadKey(symbol: "arrowtriangle.left.fill", key: GFX_KEY_LEFT)
					Color.clear.frame(width: 48, height: 48)
					PadKey(symbol: "arrowtriangle.right.fill", key: GFX_KEY_RIGHT)
				}
				PadKey(symbol: "arrowtriangle.down.fill", key: GFX_KEY_DOWN)
			}
			Spacer()
			VStack(spacing: 8) {
				PadKey(label: "Esc", key: GFX_KEY_ESCAPE, small: true)
				HStack(spacing: 10) {
					PadKey(label: "B", key: GFX_KEY_RETURN)
					PadKey(label: "A", key: GFX_KEY_SPACE)
				}
			}
		}
	}
}

struct PadKey: View {
	var symbol: String? = nil
	var label: String? = nil
	let key: Int
	var small = false
	@State private var down = false

	var body: some View {
		Group {
			if let symbol { Image(systemName: symbol) } else { Text(label ?? "").font(.headline) }
		}
		.frame(width: small ? 44 : 48, height: small ? 30 : 48)
		.foregroundStyle(.white)
		.background(Color.white.opacity(down ? 0.45 : 0.18), in: RoundedRectangle(cornerRadius: small ? 8 : 24))
		.gesture(DragGesture(minimumDistance: 0)
			.onChanged { _ in
				guard !down else { return }
				down = true
				forge_gfx_push(Int32(GFX_KEYDOWN), 0, 0, Int32(key))
			}
			.onEnded { _ in
				down = false
				forge_gfx_push(Int32(GFX_KEYUP), 0, 0, Int32(key))
			})
	}
}
