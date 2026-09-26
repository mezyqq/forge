import SwiftUI

/// Пакеты проекта: поиск и установка из PyPI / npm / LuaRocks, каталог C/C++, список установленного.
struct PackagesView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@AppStorage("packagesEcosystem") private var ecoRaw = Ecosystem.pypi.rawValue
	@State private var query = ""
	@State private var results: [(String, String)] = []  // имя, описание (поиск npm)
	@State private var installed: [(String, String)] = []
	@State private var busy = false
	@State private var log = ""
	@State private var error: String?
	@State private var searchTask: Task<Void, Never>?

	private var eco: Ecosystem { Ecosystem(rawValue: ecoRaw) ?? .pypi }

	var body: some View {
		NavigationStack {
			List {
				Section {
					Picker("", selection: $ecoRaw) {
						ForEach(Ecosystem.allCases) { Text($0.title).tag($0.rawValue) }
					}
					.pickerStyle(.segmented)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets())
				}
				if eco == .c {
					Section {
						ForEach(CLibrary.catalog) { lib in
							HStack {
								VStack(alignment: .leading, spacing: 2) {
									Text(lib.title).font(.body.monospaced())
									Text(L(lib.note)).font(.caption).foregroundStyle(.secondary)
								}
								Spacer()
								if installed.contains(where: { $0.0 == lib.id }) {
									Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
								} else if !lib.files.isEmpty {
									Button(L("Install")) { install(lib.id) }.buttonStyle(.bordered).disabled(busy)
								}
							}
						}
					} header: {
						Text(L("Catalog"))
					} footer: {
						Text(L("Files go to %@ — include them as #include \"name.h\".", eco.folder(project.url).path.replacingOccurrences(of: project.url.path + "/", with: "")))
					}
				} else {
					Section {
						HStack {
							TextField(placeholder, text: $query)
								.textInputAutocapitalization(.never)
								.autocorrectionDisabled()
								.font(.body.monospaced())
								.onSubmit { install(query) }
							Button(L("Install")) { install(query) }
								.buttonStyle(.borderedProminent)
								.disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
						}
						ForEach(results, id: \.0) { r in
							Button { install(r.0) } label: {
								VStack(alignment: .leading, spacing: 2) {
									Text(r.0).font(.body.monospaced()).foregroundStyle(.primary)
									if !r.1.isEmpty { Text(r.1).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
								}
							}
							.disabled(busy)
						}
					} header: {
						Text(eco.registry)
					} footer: {
						Text(footer)
					}
				}
				if eco != .c {
					Section(L("Installed")) {
						if installed.isEmpty { Text(L("Nothing yet")).foregroundStyle(.secondary) }
						ForEach(installed, id: \.0) { p in
							HStack {
								Text(p.0).font(.body.monospaced())
								Spacer()
								Text(p.1).font(.caption.monospaced()).foregroundStyle(.secondary)
							}
							.swipeActions {
								Button(role: .destructive) { remove(p.0) } label: { Label(L("Delete"), systemImage: "trash") }
							}
						}
					}
				} else if !installed.isEmpty {
					Section(L("Installed")) {
						ForEach(installed, id: \.0) { p in
							Text(p.0).font(.body.monospaced())
								.swipeActions { Button(role: .destructive) { remove(p.0) } label: { Label(L("Delete"), systemImage: "trash") } }
						}
					}
				}
				if busy || !log.isEmpty {
					Section(L("Log")) {
						if busy { ProgressView() }
						Text(log).font(.caption.monospaced()).textSelection(.enabled)
					}
				}
			}
			.navigationTitle(L("Packages"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Menu {
						Button { restoreAll() } label: { Label(L("Install everything from packages.json"), systemImage: "arrow.down.circle") }
					} label: { Image(systemName: "ellipsis.circle") }
					.disabled(busy)
				}
			}
			.errorAlert($error)
			.onAppear(perform: refresh)
			.onChange(of: ecoRaw) { _ in results = []; query = ""; refresh() }
			.onChange(of: query) { q in search(q) }
		}
	}

	private var placeholder: String {
		switch eco {
		case .pypi: return "requests==2.32.0"
		case .npm: return "lodash@^4"
		case .luarocks: return "inspect"
		case .c: return ""
		}
	}

	private var footer: String {
		switch eco {
		case .pypi: return L("Pure-Python packages only (no compiled C code). Python in Forge is pocketpy, so packages that need the full standard library may not work. Installed into py_modules/ — just import them.")
		case .npm: return L("Installed into node_modules/ with dependencies; require('name') finds them. JavaScriptCore is not Node: packages that need fs, http or other Node modules will not work.")
		case .luarocks: return L("Pure-Lua modules only. Installed into lua_modules/ — require('name') finds them.")
		case .c: return ""
		}
	}

	private func refresh() {
		installed = PackageManager(project: project.url, log: { _ in }).installed(eco)
	}

	/// Поиск по npm (у PyPI и LuaRocks нет открытого API поиска — там ставим по точному имени).
	private func search(_ q: String) {
		searchTask?.cancel()
		guard eco == .npm, q.count >= 2, !q.contains("@") || q.hasPrefix("@") else { results = []; return }
		searchTask = Task {
			try? await Task.sleep(nanoseconds: 350_000_000)
			guard !Task.isCancelled, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
			      let u = URL(string: "https://registry.npmjs.org/-/v1/search?size=8&text=\(enc)"),
			      let (d, _) = try? await URLSession.shared.data(from: u),
			      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
			let objs = j["objects"] as? [[String: Any]] ?? []
			results = objs.compactMap { o in
				guard let p = o["package"] as? [String: Any], let n = p["name"] as? String else { return nil }
				return (n, p["description"] as? String ?? "")
			}
		}
	}

	private func run(_ body: @escaping (PackageManager) async throws -> Void) {
		busy = true
		log = ""
		let root = project.url
		Task {
			let pm = PackageManager(project: root) { line in Task { @MainActor in log += line + "\n" } }
			do {
				try await body(pm)
				log += L("done") + "\n"
			} catch {
				self.error = error.localizedDescription
			}
			busy = false
			refresh()
			store.touch()
		}
	}

	private func install(_ spec: String) {
		let s = spec.trimmingCharacters(in: .whitespaces)
		guard !s.isEmpty else { return }
		let e = eco
		run { try await $0.install(e, s) }
		query = ""
		results = []
	}

	private func remove(_ name: String) {
		let e = eco
		run { try $0.remove(e, name) }
	}

	private func restoreAll() {
		run { try await $0.restoreAll() }
	}
}
