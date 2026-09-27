import SwiftUI

/// Поиск и замена по всем файлам проекта: регистр, регулярные выражения, предпросмотр, «Заменить всё».
struct SearchView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var replacement = ""
	@State private var showReplace = false
	@AppStorage("searchCase") private var caseSensitive = false
	@AppStorage("searchRegex") private var regex = false
	@State private var hits: [Hit] = []
	@State private var total = 0
	@State private var matched: Set<String> = []  // все файлы с совпадениями (список строк ограничен 500)
	@State private var error: String?
	@State private var confirm = false
	@State private var done: String?

	struct Hit: Identifiable {
		let id = UUID()
		let file: String
		let line: Int
		let text: String
	}

	/// Файлы, в которых ищем: текстовые, без build/, node_modules/ и прочих папок с зависимостями.
	private var files: [String] {
		store.entries(in: project, dirs: false).filter { !ToolBox.junk($0) && !$0.hasPrefix(".") && !$0.contains("/.") && $0 != "packages.json" }
	}

	private var pattern: NSRegularExpression? {
		guard !query.isEmpty else { return nil }
		let p = regex ? query : NSRegularExpression.escapedPattern(for: query)
		return try? NSRegularExpression(pattern: p, options: caseSensitive ? [] : [.caseInsensitive])
	}

	var body: some View {
		NavigationStack {
			List {
				Section {
					HStack {
						Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
						TextField(L("Text in project files"), text: $query)
							.textInputAutocapitalization(.never).autocorrectionDisabled()
							.font(.body.monospaced())
					}
					if showReplace {
						HStack {
							Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
							TextField(L("Replace with"), text: $replacement)
								.textInputAutocapitalization(.never).autocorrectionDisabled()
								.font(.body.monospaced())
						}
					}
					HStack(spacing: 16) {
						Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button)
						Toggle(".*", isOn: $regex).toggleStyle(.button)
						Toggle(isOn: $showReplace) { Image(systemName: "arrow.2.squarepath") }.toggleStyle(.button)
						Spacer()
						if total > 0 { Text(L("%@ matches", total)).font(.caption).foregroundStyle(.secondary) }
					}
					.font(.body.monospaced())
					if showReplace && total > 0 {
						Button(role: .destructive) { confirm = true } label: {
							Label(L("Replace all (%@)", total), systemImage: "arrow.2.squarepath")
						}
					}
				}
				if regex && !query.isEmpty && pattern == nil {
					Text(L("Invalid regular expression")).foregroundStyle(.red).font(.footnote)
				}
				ForEach(grouped, id: \.0) { file, list in
					Section(file) {
						ForEach(list) { h in
							NavigationLink {
								EditorScreen(project: project, path: h.file, line: h.line)
							} label: {
								VStack(alignment: .leading, spacing: 2) {
									Text(highlighted(h.text)).font(.footnote.monospaced()).lineLimit(2)
									if showReplace, let after = preview(h.text) {
										Text(after).font(.footnote.monospaced()).foregroundStyle(.green).lineLimit(2)
									}
								}
							}
							.badge(h.line)
						}
					}
				}
			}
			.overlay { if hits.isEmpty && query.count >= 2 && pattern != nil { Text(L("Nothing found")).foregroundStyle(.secondary) } }
			.navigationTitle(L("Search"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
			.onChange(of: query) { _ in search() }
			.onChange(of: caseSensitive) { _ in search() }
			.onChange(of: regex) { _ in search() }
			.confirmationDialog(L("Replace %@ matches in %@ files?", total, matched.count), isPresented: $confirm, titleVisibility: .visible) {
				Button(L("Replace all"), role: .destructive, action: replaceAll)
			}
			.alert(done ?? "", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) { Button("OK") {} }
			.errorAlert($error)
		}
	}

	private var grouped: [(String, [Hit])] {
		var order: [String] = []
		var map: [String: [Hit]] = [:]
		for h in hits {
			if map[h.file] == nil { order.append(h.file) }
			map[h.file, default: []].append(h)
		}
		return order.map { ($0, map[$0]!) }
	}

	private func search() {
		hits = []
		total = 0
		matched = []
		guard query.count >= (regex ? 1 : 2), let re = pattern else { return }
		var out: [Hit] = []
		var count = 0
		var inFiles = Set<String>()
		for f in files {
			guard let text = try? String(contentsOf: project.url.appendingPathComponent(f), encoding: .utf8) else { continue }
			var n = 0
			text.enumerateLines { line, _ in
				n += 1
				let c = re.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
				if c > 0 {
					count += c
					inFiles.insert(f)
					if out.count < 500 { out.append(Hit(file: f, line: n, text: line.trimmingCharacters(in: .whitespaces))) }
				}
			}
		}
		hits = out
		total = count
		matched = inFiles
	}

	/// Строка с подсвеченными совпадениями.
	private func highlighted(_ s: String) -> AttributedString {
		var a = AttributedString(s)
		guard let re = pattern else { return a }
		for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
			if let r = Range(m.range, in: s), let ar = Range(r, in: a) {
				a[ar].backgroundColor = .yellow.opacity(0.35)
			}
		}
		return a
	}

	private func preview(_ s: String) -> String? {
		guard let re = pattern else { return nil }
		let t = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
		return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
	}

	/// Замена во всех файлах; открытые редакторы подхватят изменения (store.write поднимает fsVersion).
	private func replaceAll() {
		guard let re = pattern else { return }
		let t = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
		var changed = 0, n = 0
		for f in matched.sorted() {
			guard let text = try? String(contentsOf: project.url.appendingPathComponent(f), encoding: .utf8) else { continue }
			let range = NSRange(text.startIndex..., in: text)
			let c = re.numberOfMatches(in: text, range: range)
			guard c > 0 else { continue }
			let updated = re.stringByReplacingMatches(in: text, range: range, withTemplate: t)
			do {
				try store.write(f, updated, in: project)
				changed += 1
				n += c
			} catch {
				self.error = error.localizedDescription
				return
			}
		}
		done = L("Replaced %@ matches in %@ files.", n, changed)
		search()
	}
}
