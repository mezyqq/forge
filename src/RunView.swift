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
				ConsoleText(output: runner.output)
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
			if await LiveContainer.install(ipa) { installed = true }
			else { error = L("LiveContainer did not open. Is it installed? You can also share the .ipa.") }
		}
	}

	private func launch() {
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

/// Проект, собранный прямо в память Forge (без установки): консоль программы, а если в проекте есть
/// `UIViewController *forge_preview(void)` — её экран здесь же.
struct QuickRunView: View {
	let project: URL
	@ObservedObject private var runner = Runner.shared
	@Environment(\.dismiss) private var dismiss
	@State private var input = ""
	@State private var preview: UIViewController?
	@State private var showConsole = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Group {
				if let preview, !showConsole {
					HostedController(vc: preview).id(ObjectIdentifier(preview)).ignoresSafeArea(edges: .bottom)
				} else {
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
				}
			}
			.navigationTitle(project.lastPathComponent)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					if preview != nil {
						Button { showConsole.toggle() } label: { Image(systemName: showConsole ? "iphone" : "terminal") }
					}
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
		preview = nil
		showConsole = false
		runner.quickRun(project) { jit in
			guard let jit else { return }
			switch Clang.previewController(jit) {
			case .success(let vc): preview = vc
			case .failure(let f): error = f.message; showConsole = true
			}
		}
	}
}

/// UIViewController из JIT-кода внутри SwiftUI (как дочерний контроллер).
struct HostedController: UIViewControllerRepresentable {
	let vc: UIViewController

	func makeUIViewController(context: Context) -> UIViewController {
		let host = UIViewController()
		host.addChild(vc)
		vc.view.frame = host.view.bounds
		vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		host.view.addSubview(vc.view)
		vc.didMove(toParent: host)
		return host
	}

	func updateUIViewController(_ host: UIViewController, context: Context) {}
}
