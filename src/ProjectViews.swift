import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProjectView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@State private var tab = 0
	@State private var share: ShareItem?
	@State private var confirmReset = false
	@State private var showConf = false
	@State private var showSearch = false
	@State private var showGit = false
	@State private var run: RunTarget?
	@State private var building: BuildTarget?
	@State private var quickRun = false
	@State private var error: String?

	/// iOS-приложение (есть ipa.conf) — главная кнопка собирает .ipa, а не запускает скрипт.
	private var isApp: Bool { FileManager.default.fileExists(atPath: project.url.appendingPathComponent("ipa.conf").path) }

	private struct BuildTarget: Identifiable {
		let release: Bool
		let id = UUID()
	}

	private func buildApp(release: Bool) {
		if IpaBuilder.available {
			building = BuildTarget(release: release)
		} else {
			error = L("This Forge build has no compiler — build the project with ipab on a computer.")
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			Picker("", selection: $tab) {
				Text(L("Files")).tag(0)
				Text(L("AI")).tag(1)
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
			.padding(.bottom, 8)
			if tab == 0 {
				FilesView(project: project)
			} else {
				ChatView(agent: store.agent(for: project))
			}
		}
		.onAppear { CrashLog.crumb("проект: \(project.name)") }
		.navigationTitle(project.name)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .navigationBarTrailing) {
				Button {
					if isApp {
						buildApp(release: false)
					} else if let e = store.entryPoint(in: project) {
						run = RunTarget(url: project.url.appendingPathComponent(e), root: project.url)
					} else {
						error = L("Nothing to run found (main.py, main.js, index.html, main.lua, main.c). Open a file and tap ▶ in the editor.")
					}
				} label: { Image(systemName: isApp ? "hammer.fill" : "play.fill") }
				Button { showGit = true } label: { Image(systemName: "arrow.triangle.branch") }
				Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
				Menu {
					Button { showConf = true } label: { Label(L("Project settings"), systemImage: "slider.horizontal.3") }
					if isApp && IpaBuilder.available {
						Button { quickRun = true } label: {
							Label(L("Run in Forge (JIT, no install)"), systemImage: "bolt.fill")
						}
					}
					if isApp {
						Button { buildApp(release: true) } label: {
							Label(L("Build release (version +1)"), systemImage: "shippingbox")
						}
						if let ipa = IpaBuilder.ipaURL(project.url) {
							Button { share = ShareItem(url: ipa) } label: {
								Label(L("Share %@", ipa.lastPathComponent), systemImage: "square.and.arrow.up.on.square")
							}
						}
					}
					Button {
						do { share = ShareItem(url: try store.archive(project)) } catch { self.error = error.localizedDescription }
					} label: {
						Label(L("Share .zip"), systemImage: "square.and.arrow.up")
					}
					Button(role: .destructive) { confirmReset = true } label: { Label(L("New chat"), systemImage: "trash") }
				} label: { Image(systemName: "ellipsis.circle") }
			}
		}
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.sheet(isPresented: $showConf) { ConfView(project: project) }
		.sheet(isPresented: $showSearch) { SearchView(project: project) }
		.sheet(isPresented: $showGit) { GitView(project: project) }
		.fullScreenCover(item: $run) { RunSheet(target: $0) }
		.fullScreenCover(item: $building) { BuildView(project: project.url, release: $0.release) }
		.fullScreenCover(isPresented: $quickRun) { QuickRunView(project: project.url) }
		.confirmationDialog(L("Clear the chat history?"), isPresented: $confirmReset, titleVisibility: .visible) {
			Button(L("Clear"), role: .destructive) { store.agent(for: project).reset() }
		}
		.errorAlert($error)
	}
}

// MARK: дерево файлов

struct FilesView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@State private var nodes: [FileNode] = []
	@State private var prompt: Prompt?
	@State private var error: String?
	@State private var importDir = ""
	@State private var showImport = false
	@State private var toDelete: FileNode?

	var body: some View {
		List {
			OutlineGroup(nodes, children: \.children) { node in
				row(node)
					.contextMenu { menu(node) }
					.swipeActions { Button(role: .destructive) { toDelete = node } label: { Label(L("Delete"), systemImage: "trash") } }
			}
			Section {
				Button { newFile(in: "src") } label: { Label(L("New file"), systemImage: "doc.badge.plus") }
				Button { newFolder(in: "") } label: { Label(L("New folder"), systemImage: "folder.badge.plus") }
				Button { importDir = "res"; showImport = true } label: { Label(L("Import from Files into res/"), systemImage: "square.and.arrow.down") }
			}
		}
		.promptAlert($prompt, error: $error)
		.errorAlert($error)
		.confirmationDialog(L(toDelete?.isDir == true ? "Delete %@ with all its contents?" : "Delete %@?", toDelete?.path ?? ""),
		                    isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
		                    titleVisibility: .visible) {
			Button(L("Delete"), role: .destructive) {
				if let n = toDelete { attempt { try store.remove(n.path, in: project) } }
			}
		}
		.fileImporter(isPresented: $showImport, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
			switch r {
			case .success(let urls): attempt { try store.importFiles(urls, into: importDir, in: project) }
			case .failure(let e): error = e.localizedDescription
			}
		}
		.onAppear(perform: refresh)
		.onReceive(store.$fsVersion) { _ in refresh() }
	}

	@ViewBuilder private func row(_ n: FileNode) -> some View {
		if n.isDir {
			Label(n.name, systemImage: "folder.fill").foregroundStyle(.primary)
		} else {
			NavigationLink { EditorScreen(project: project, path: n.path) } label: {
				Label(n.name, systemImage: icon(n.path)).font(.system(.body, design: .monospaced))
			}
		}
	}

	@ViewBuilder private func menu(_ n: FileNode) -> some View {
		let dir = n.isDir ? n.path : n.parent
		Button { newFile(in: dir) } label: { Label(L("New file here"), systemImage: "doc.badge.plus") }
		Button { newFolder(in: dir) } label: { Label(L("New folder here"), systemImage: "folder.badge.plus") }
		Button { importDir = dir; showImport = true } label: { Label(L("Import here"), systemImage: "square.and.arrow.down") }
		Button {
			prompt = Prompt(title: L("Rename / move"), text: n.path) { new in
				if new != n.path { try store.move(n.path, to: new, in: project) }
			}
		} label: { Label(L("Rename"), systemImage: "pencil") }
		if !n.isDir {
			Button { UIPasteboard.general.string = n.path } label: { Label(L("Copy path"), systemImage: "doc.on.doc") }
		}
		Button(role: .destructive) { toDelete = n } label: { Label(L("Delete"), systemImage: "trash") }
	}

	private func newFile(in dir: String) {
		prompt = Prompt(title: L("New file"), text: dir.isEmpty ? "" : dir + "/", placeholder: "src/Foo.m") { path in
			if (try? store.resolve(path, in: project)).map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
				throw StoreError(L("%@ already exists", path))
			}
			try store.write(path, "", in: project)
		}
	}

	private func newFolder(in dir: String) {
		prompt = Prompt(title: L("New folder"), text: dir.isEmpty ? "" : dir + "/", placeholder: "src/Views") { path in
			try store.makeDir(path, in: project)
		}
	}

	private func attempt(_ f: () throws -> Void) {
		do { try f() } catch { self.error = error.localizedDescription }
	}

	private func refresh() { nodes = store.tree(in: project) }

	private func icon(_ f: String) -> String {
		switch (f as NSString).pathExtension.lowercased() {
		case "swift": return "swift"
		case "c", "m", "mm", "cpp", "cc", "cxx", "rs", "go", "java", "kt", "js", "ts", "py", "lua", "rb":
			return "chevron.left.forwardslash.chevron.right"
		case "h", "hpp": return "h.square"
		case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
		case "html", "htm", "css": return "globe"
		case "md", "txt": return "doc.plaintext"
		case "conf", "plist", "json", "entitlements", "yml", "yaml", "toml": return "gearshape"
		case "sh": return "terminal"
		default: return "doc"
		}
	}
}

// MARK: редактор

struct EditorScreen: View {
	let project: Project
	let path: String
	var line: Int? = nil
	@EnvironmentObject var store: ProjectStore
	@AppStorage("fontSize") private var fontSize = 14.0
	@AppStorage("lineNumbers") private var lineNumbers = true
	@AppStorage("theme") private var themeID = "xcode"
	@AppStorage("syntaxCheck") private var syntaxCheck = true
	@State private var diag: Diagnostic?
	@State private var checkTask: Task<Void, Never>?
	@State private var text = ""
	@State private var loaded = false
	@State private var binary = false
	@State private var dirty = false
	@State private var saveTask: Task<Void, Never>?
	@State private var handle = EditorHandle()
	@State private var prompt: Prompt?
	@State private var error: String?
	@State private var run: RunTarget?
	@AppStorage("autocomplete") private var autocomplete = true

	private var lang: Lang { Lang.detect(path) }
	private var isApp: Bool { FileManager.default.fileExists(atPath: project.url.appendingPathComponent("ipa.conf").path) }
	/// Проверка и автодополнение встроенным clang (в iOS-проекте — все C-файлы, в скриптовом — кроме .c для picoc).
	private var useClang: Bool {
		IpaBuilder.available && Clang.supports(path) && (isApp || (path as NSString).pathExtension.lowercased() != "c")
	}
	/// ▶ у файла: скрипты; исходники iOS-приложения запускаются целиком (сборка или JIT-запуск проекта).
	private var canRun: Bool { RunKind.detect(path) != nil && !(isApp && path.hasPrefix("src/")) }

	var body: some View {
		Group {
			if binary {
				BinaryPreview(url: (try? store.resolve(path, in: project)))
			} else {
				CodeEditor(text: $text, lang: lang, fontSize: CGFloat(fontSize), lineNumbers: lineNumbers,
				           theme: Theme.find(themeID), errorLine: diag?.line,
				           completer: useClang && autocomplete ? complete : nil, handle: handle)
					.ignoresSafeArea(.container, edges: .bottom)
					.safeAreaInset(edge: .bottom) {
						if let d = diag {
							Button { if d.line > 0 { handle.go(toLine: d.line) } } label: {
								HStack(alignment: .top, spacing: 8) {
									Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
									Text((d.line > 0 ? L("Line %@: ", d.line) : "") + d.message)
										.font(.caption.monospaced())
										.lineLimit(3)
										.multilineTextAlignment(.leading)
									Spacer(minLength: 0)
								}
								.foregroundStyle(.primary)
								.padding(10)
								.background(.ultraThinMaterial)
							}
							.buttonStyle(.plain)
						}
					}
			}
		}
		.navigationTitle((path as NSString).lastPathComponent)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			if !binary {
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					if canRun {
						Button {
							saveTask?.cancel()
							save()
							if let u = try? store.resolve(path, in: project) { run = RunTarget(url: u, root: project.url) }
						} label: { Image(systemName: "play.fill") }
					}
					Button { handle.find(replace: false) } label: { Image(systemName: "magnifyingglass") }
					Menu {
						Button { handle.find(replace: true) } label: { Label(L("Find and replace"), systemImage: "arrow.left.arrow.right") }
						Button {
							prompt = Prompt(title: L("Go to line"), text: "", placeholder: L("number")) { s in
								if let n = Int(s) { handle.go(toLine: n) }
							}
						} label: { Label(L("Go to line"), systemImage: "arrow.down.to.line") }
						Button { fontSize = min(28, fontSize + 1) } label: { Label(L("Larger"), systemImage: "textformat.size.larger") }
						Button { fontSize = max(9, fontSize - 1) } label: { Label(L("Smaller"), systemImage: "textformat.size.smaller") }
						Toggle(isOn: $lineNumbers) { Label(L("Line numbers"), systemImage: "list.number") }
						if SyntaxCheck.supports(path) || useClang {
							Toggle(isOn: $syntaxCheck) { Label(L("Syntax checking"), systemImage: "checkmark.shield") }
						}
						if useClang {
							Toggle(isOn: $autocomplete) { Label(L("Autocomplete (clang)"), systemImage: "text.badge.plus") }
							Button(action: format) { Label(L("Format (clang-format)"), systemImage: "text.alignleft") }
						}
						Button { UIPasteboard.general.string = text } label: { Label(L("Copy all"), systemImage: "doc.on.doc") }
						Section(lang.name) {}
					} label: { Image(systemName: "ellipsis.circle") }
				}
			}
		}
		.promptAlert($prompt, error: $error)
		.errorAlert($error)
		.fullScreenCover(item: $run) { RunSheet(target: $0) }
		.onAppear {
			CrashLog.crumb("редактор: \(path)")
			guard !loaded else { return }
			do { text = try store.read(path, in: project) } catch { binary = true }
			loaded = true
			scheduleCheck(delay: 0)
			if let line {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { handle.go(toLine: line) }
			}
		}
		.onChange(of: text) { _ in
			guard loaded, !binary else { return }
			dirty = true
			saveTask?.cancel()
			scheduleCheck(delay: useClang ? 1.2 : 0.7)
			saveTask = Task {
				try? await Task.sleep(nanoseconds: 400_000_000)
				if !Task.isCancelled { save() }
			}
		}
		// файл поменял агент — показываем новую версию
		.onReceive(store.$fsVersion.dropFirst()) { _ in
			guard !binary, let d = try? store.read(path, in: project), d != text else { return }
			text = d
			dirty = false
		}
		.onChange(of: syntaxCheck) { _ in scheduleCheck(delay: 0) }
		.onDisappear {
			saveTask?.cancel()
			if dirty { save() }
		}
	}

	private func save() {
		try? store.write(path, text, in: project, external: false)
		dirty = false
	}

	/// Проверка синтаксиса после паузы в наборе.
	private func scheduleCheck(delay: Double) {
		checkTask?.cancel()
		guard syntaxCheck, !binary, useClang || SyntaxCheck.supports(path) else { diag = nil; return }
		let clang = useClang
		checkTask = Task {
			if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
			guard !Task.isCancelled else { return }
			CrashLog.crumb("проверка синтаксиса: \(path)")
			if clang {
				guard let u = try? store.resolve(path, in: project) else { return }
				let errors = await Clang.check(text, file: u, project: project.url).filter(\.isError)
				guard !Task.isCancelled else { return }
				diag = errors.first.map { Diagnostic(line: $0.line, message: $0.message + (errors.count > 1 ? L(" (+%@ more)", errors.count - 1) : "")) }
			} else {
				diag = SyntaxCheck.check(text, path: path)
			}
		}
	}

	private func complete(_ text: String, _ offset: Int) async -> [Clang.Completion] {
		guard let u = try? store.resolve(path, in: project) else { return [] }
		return await Clang.complete(text, offset: offset, file: u, project: project.url)
	}

	private func format() {
		guard let u = try? store.resolve(path, in: project) else { return }
		let src = text
		Task {
			do {
				let out = try await Clang.format(src, file: u, project: project.url)
				if out != text, text == src { handle.replaceAll(with: out) }
			} catch { self.error = error.localizedDescription }
		}
	}
}

struct BinaryPreview: View {
	let url: URL?

	var body: some View {
		if let url, let img = UIImage(contentsOfFile: url.path) {
			ScrollView([.horizontal, .vertical]) {
				Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 600).padding()
			}
			.overlay(alignment: .bottom) {
				Text("\(Int(img.size.width * img.scale))×\(Int(img.size.height * img.scale))")
					.font(.caption).padding(6).background(.thinMaterial, in: Capsule()).padding()
			}
		} else {
			let size = (url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }) ?? 0
			VStack(spacing: 8) {
				Image(systemName: "doc.questionmark").font(.largeTitle)
				Text(L("Not a text file"))
				Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).foregroundStyle(.secondary)
			}
		}
	}
}

// MARK: настройки проекта (ipa.conf формой)

struct ConfView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@State private var raw = ""
	@State private var values: [String: String] = [:]
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				ForEach(Conf.fields, id: \.0) { f in
					VStack(alignment: .leading, spacing: 4) {
						Text(f.1).font(.caption).foregroundStyle(.secondary)
						TextField(f.0, text: Binding(get: { values[f.0] ?? "" }, set: { values[f.0] = $0 }))
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
							.font(.body.monospaced())
					}
				}
				Section {
					NavigationLink { EditorScreen(project: project, path: "ipa.conf") } label: {
						Label(L("Open ipa.conf as text"), systemImage: "doc.text")
					}
				} footer: {
					Text(L("Frameworks separated by spaces, e.g. “Foundation UIKit SwiftUI AVFoundation”."))
				}
			}
			.navigationTitle(L("Project settings"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button(L("Save"), action: save) }
			}
			.errorAlert($error)
			.onAppear {
				raw = (try? store.read("ipa.conf", in: project)) ?? ""
				for f in Conf.fields { values[f.0] = Conf.get(raw, f.0) }
			}
		}
	}

	private func save() {
		var t = raw
		for f in Conf.fields where (values[f.0] ?? "") != Conf.get(raw, f.0) {
			t = Conf.set(t, f.0, values[f.0] ?? "")
		}
		do { try store.write("ipa.conf", t, in: project); dismiss() } catch { self.error = error.localizedDescription }
	}
}

// MARK: поиск по проекту

struct SearchView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var hits: [String] = []

	var body: some View {
		NavigationStack {
			List(hits, id: \.self) { h in
				let parts = h.split(separator: ":", maxSplits: 2).map(String.init)
				NavigationLink {
					EditorScreen(project: project, path: parts[0], line: Int(parts[safe: 1] ?? ""))
				} label: {
					VStack(alignment: .leading, spacing: 2) {
						Text("\(parts[0]):\(parts[safe: 1] ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary)
						Text(parts[safe: 2]?.trimmingCharacters(in: .whitespaces) ?? "").font(.footnote.monospaced()).lineLimit(2)
					}
				}
			}
			.overlay {
				if hits.isEmpty && !query.isEmpty { Text(L("Nothing found")).foregroundStyle(.secondary) }
			}
			.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Text in project files"))
			.textInputAutocapitalization(.never)
			.autocorrectionDisabled()
			.onChange(of: query) { q in hits = q.count < 2 ? [] : store.search(q, in: project) }
			.navigationTitle(L("Search"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
		}
	}
}

extension Array {
	subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
