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
	@State private var error: String?

	var body: some View {
		VStack(spacing: 0) {
			Picker("", selection: $tab) {
				Text("Файлы").tag(0)
				Text("ИИ").tag(1)
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
					if let e = store.entryPoint(in: project) {
						run = RunTarget(url: project.url.appendingPathComponent(e), root: project.url)
					} else {
						error = "Не нашёл, что запускать (main.py, main.js, index.html, main.lua, main.c). Открой файл и нажми ▶ в редакторе. iOS-приложения собираются через ipab на компьютере."
					}
				} label: { Image(systemName: "play.fill") }
				Button { showGit = true } label: { Image(systemName: "arrow.triangle.branch") }
				Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
				Menu {
					Button { showConf = true } label: { Label("Настройки проекта", systemImage: "slider.horizontal.3") }
					Button {
						do { share = ShareItem(url: try store.archive(project)) } catch { self.error = error.localizedDescription }
					} label: {
						Label("Поделиться .zip", systemImage: "square.and.arrow.up")
					}
					Button(role: .destructive) { confirmReset = true } label: { Label("Новый чат", systemImage: "trash") }
				} label: { Image(systemName: "ellipsis.circle") }
			}
		}
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.sheet(isPresented: $showConf) { ConfView(project: project) }
		.sheet(isPresented: $showSearch) { SearchView(project: project) }
		.sheet(isPresented: $showGit) { GitView(project: project) }
		.fullScreenCover(item: $run) { RunSheet(target: $0) }
		.confirmationDialog("Очистить историю чата?", isPresented: $confirmReset, titleVisibility: .visible) {
			Button("Очистить", role: .destructive) { store.agent(for: project).reset() }
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
					.swipeActions { Button(role: .destructive) { toDelete = node } label: { Label("Удалить", systemImage: "trash") } }
			}
			Section {
				Button { newFile(in: "src") } label: { Label("Новый файл", systemImage: "doc.badge.plus") }
				Button { newFolder(in: "") } label: { Label("Новая папка", systemImage: "folder.badge.plus") }
				Button { importDir = "res"; showImport = true } label: { Label("Импорт из «Файлов» в res/", systemImage: "square.and.arrow.down") }
			}
		}
		.promptAlert($prompt, error: $error)
		.errorAlert($error)
		.confirmationDialog("Удалить \(toDelete?.path ?? "")\(toDelete?.isDir == true ? " со всем содержимым" : "")?",
		                    isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
		                    titleVisibility: .visible) {
			Button("Удалить", role: .destructive) {
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
		Button { newFile(in: dir) } label: { Label("Новый файл здесь", systemImage: "doc.badge.plus") }
		Button { newFolder(in: dir) } label: { Label("Новая папка здесь", systemImage: "folder.badge.plus") }
		Button { importDir = dir; showImport = true } label: { Label("Импорт сюда", systemImage: "square.and.arrow.down") }
		Button {
			prompt = Prompt(title: "Переименовать / переместить", text: n.path) { new in
				if new != n.path { try store.move(n.path, to: new, in: project) }
			}
		} label: { Label("Переименовать", systemImage: "pencil") }
		if !n.isDir {
			Button { UIPasteboard.general.string = n.path } label: { Label("Копировать путь", systemImage: "doc.on.doc") }
		}
		Button(role: .destructive) { toDelete = n } label: { Label("Удалить", systemImage: "trash") }
	}

	private func newFile(in dir: String) {
		prompt = Prompt(title: "Новый файл", text: dir.isEmpty ? "" : dir + "/", placeholder: "src/Foo.m") { path in
			if (try? store.resolve(path, in: project)).map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
				throw StoreError("\(path) уже существует")
			}
			try store.write(path, "", in: project)
		}
	}

	private func newFolder(in dir: String) {
		prompt = Prompt(title: "Новая папка", text: dir.isEmpty ? "" : dir + "/", placeholder: "src/Views") { path in
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

	private var lang: Lang { Lang.detect(path) }

	var body: some View {
		Group {
			if binary {
				BinaryPreview(url: (try? store.resolve(path, in: project)))
			} else {
				CodeEditor(text: $text, lang: lang, fontSize: CGFloat(fontSize), lineNumbers: lineNumbers,
				           theme: Theme.find(themeID), errorLine: diag?.line, handle: handle)
					.ignoresSafeArea(.container, edges: .bottom)
					.safeAreaInset(edge: .bottom) {
						if let d = diag {
							Button { if d.line > 0 { handle.go(toLine: d.line) } } label: {
								HStack(alignment: .top, spacing: 8) {
									Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
									Text((d.line > 0 ? "Строка \(d.line): " : "") + d.message)
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
					if RunKind.detect(path) != nil {
						Button {
							saveTask?.cancel()
							save()
							if let u = try? store.resolve(path, in: project) { run = RunTarget(url: u, root: project.url) }
						} label: { Image(systemName: "play.fill") }
					}
					Button { handle.find(replace: false) } label: { Image(systemName: "magnifyingglass") }
					Menu {
						Button { handle.find(replace: true) } label: { Label("Найти и заменить", systemImage: "arrow.left.arrow.right") }
						Button {
							prompt = Prompt(title: "Перейти к строке", text: "", placeholder: "номер") { s in
								if let n = Int(s) { handle.go(toLine: n) }
							}
						} label: { Label("Перейти к строке", systemImage: "arrow.down.to.line") }
						Button { fontSize = min(28, fontSize + 1) } label: { Label("Крупнее", systemImage: "textformat.size.larger") }
						Button { fontSize = max(9, fontSize - 1) } label: { Label("Мельче", systemImage: "textformat.size.smaller") }
						Toggle(isOn: $lineNumbers) { Label("Номера строк", systemImage: "list.number") }
						if SyntaxCheck.supports(path) {
							Toggle(isOn: $syntaxCheck) { Label("Проверка синтаксиса", systemImage: "checkmark.shield") }
						}
						Button { UIPasteboard.general.string = text } label: { Label("Копировать всё", systemImage: "doc.on.doc") }
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
			scheduleCheck(delay: 0.7)
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
		guard syntaxCheck, !binary, SyntaxCheck.supports(path) else { diag = nil; return }
		checkTask = Task {
			if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
			guard !Task.isCancelled else { return }
			CrashLog.crumb("проверка синтаксиса: \(path)")
			diag = SyntaxCheck.check(text, path: path)
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
				Text("Не текстовый файл")
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
						Label("Открыть ipa.conf как текст", systemImage: "doc.text")
					}
				} footer: {
					Text("Фреймворки через пробел, напр. «Foundation UIKit SwiftUI AVFoundation».")
				}
			}
			.navigationTitle("Настройки проекта")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save) }
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
				if hits.isEmpty && !query.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
			}
			.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Текст в файлах проекта")
			.textInputAutocapitalization(.never)
			.autocorrectionDisabled()
			.onChange(of: query) { q in hits = q.count < 2 ? [] : store.search(q, in: project) }
			.navigationTitle("Поиск")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
		}
	}
}

extension Array {
	subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
