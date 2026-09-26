import SwiftUI
import UIKit

// MARK: общие мелочи

/// Алерт с одним текстовым полем (новый файл, переименование…).
struct Prompt: Identifiable {
	let id = UUID()
	let title: String
	var text: String
	var placeholder = ""
	let action: (String) throws -> Void
}

extension View {
	func promptAlert(_ prompt: Binding<Prompt?>, error errorText: Binding<String?>) -> some View {
		alert(prompt.wrappedValue?.title ?? "", isPresented: Binding(get: { prompt.wrappedValue != nil },
		                                                             set: { if !$0 { prompt.wrappedValue = nil } })) {
			TextField(prompt.wrappedValue?.placeholder ?? "", text: Binding(get: { prompt.wrappedValue?.text ?? "" },
			                                                                set: { prompt.wrappedValue?.text = $0 }))
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button("OK") {
				guard let p = prompt.wrappedValue else { return }
				do { try p.action(p.text.trimmingCharacters(in: .whitespaces)) } catch { errorText.wrappedValue = error.localizedDescription }
			}
			Button("Отмена", role: .cancel) {}
		}
	}

	func errorAlert(_ error: Binding<String?>) -> some View {
		alert("Ошибка", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(error.wrappedValue ?? "")
		}
	}
}

struct ShareItem: Identifiable {
	let url: URL
	var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
	let url: URL
	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: [url], applicationActivities: nil)
	}
	func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: проекты

struct ProjectsView: View {
	@EnvironmentObject var store: ProjectStore
	@State private var showNew = false
	@State private var showClone = false
	@State private var showSettings = false
	@State private var prompt: Prompt?
	@State private var error: String?
	@State private var toDelete: Project?
	@State private var crashReport: URL?
	@State private var showCrash = false
	@State private var openReport: URL?

	var body: some View {
		NavigationStack {
			List {
				ForEach(store.projects) { p in
					NavigationLink(value: p) { Label(p.name, systemImage: "folder") }
						.contextMenu {
							Button { prompt = Prompt(title: "Переименовать", text: p.name) { try store.rename(p, to: $0) } } label: {
								Label("Переименовать", systemImage: "pencil")
							}
							Button { do { try store.duplicate(p) } catch { self.error = error.localizedDescription } } label: {
								Label("Дублировать", systemImage: "plus.square.on.square")
							}
							Button(role: .destructive) { toDelete = p } label: { Label("Удалить", systemImage: "trash") }
						}
				}
				.onDelete { idx in toDelete = idx.first.map { store.projects[$0] } }
			}
			.overlay {
				if store.projects.isEmpty {
					Text("Проектов пока нет.\n+ — новый проект, ⤓ — клонировать с GitHub")
						.multilineTextAlignment(.center)
						.foregroundStyle(.secondary)
				}
			}
			.navigationTitle("Forge")
			.navigationDestination(for: Project.self) { ProjectView(project: $0) }
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button { showSettings = true } label: { Image(systemName: "gearshape") }
				}
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button { showClone = true } label: { Image(systemName: "square.and.arrow.down.on.square") }
					Button { showNew = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showNew) { NewProjectView() }
			.sheet(isPresented: $showClone) { CloneView() }
			.sheet(isPresented: $showSettings) { SettingsView() }
			.confirmationDialog("Удалить проект «\(toDelete?.name ?? "")» со всеми файлами?",
			                    isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
			                    titleVisibility: .visible) {
				Button("Удалить", role: .destructive) { if let p = toDelete { store.delete(p) } }
			}
			.promptAlert($prompt, error: $error)
			.errorAlert($error)
			.navigationDestination(isPresented: $showCrash) {
				if let r = openReport { CrashReportView(url: r) }
			}
			.alert("Forge вылетел в прошлый раз", isPresented: Binding(get: { crashReport != nil && !showCrash }, set: { if !$0 { crashReport = nil; CrashLog.clearPending() } })) {
				Button("Открыть отчёт") { openReport = crashReport; showCrash = true }
				Button("Позже", role: .cancel) {}
			} message: {
				Text("Отчёт сохранён в Настройки → Журнал вылетов. Его можно отправить разработчику.")
			}
			.refreshable { store.reload() }
			.onAppear {
				store.reload()
				if let p = CrashLog.pending { crashReport = p; CrashLog.clearPending() }
			}
		}
	}
}

struct NewProjectView: View {
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var template = Template.python
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				TextField("Имя (латиницей, без пробелов)", text: $name)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Picker("Шаблон", selection: $template) {
					Section("Запуск прямо на телефоне") {
						ForEach(Template.scripts) { Text($0.title).tag($0) }
					}
					Section("iOS-приложение (сборка ipab)") {
						ForEach(Template.apps) { Text($0.title).tag($0) }
					}
				}
				.pickerStyle(.inline)
				if let error { Text(error).foregroundStyle(.red) }
			}
			.navigationTitle("Новый проект")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Создать") {
						do { _ = try store.create(name: name, template: template); dismiss() }
						catch { self.error = error.localizedDescription }
					}
					.disabled(name.isEmpty)
				}
			}
		}
	}
}

// MARK: настройки

struct SettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var ps = Providers.shared
	@AppStorage("fontSize") private var fontSize = 14.0
	@AppStorage("lineNumbers") private var lineNumbers = true
	@AppStorage("theme") private var themeID = "xcode"
	@AppStorage("syntaxCheck") private var syntaxCheck = true
	@State private var newProvider: Provider?
	@State private var showNewProvider = false

	var body: some View {
		NavigationStack {
			Form {
				Section {
					HStack {
						Text("Сейчас")
						Spacer()
						Text("\(ps.activeProvider?.name ?? "—")\n\(ps.active.model)")
							.multilineTextAlignment(.trailing)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} header: {
					Text("Модель ИИ")
				} footer: {
					Text("Модель выбирается внутри провайдера или прямо в чате.")
				}
				Section {
					ForEach(ps.list) { p in
						NavigationLink { ProviderView(provider: p) } label: { ProviderRow(provider: p) }
					}
					Button { newProvider = ps.addCustom(); showNewProvider = true } label: { Label("Добавить провайдера", systemImage: "plus") }
				} header: {
					Text("Провайдеры")
				} footer: {
					Text("Подходит любой OpenAI-совместимый API (Groq, DeepSeek, Mistral, Together, свой сервер…) или Anthropic-совместимый.")
				}
				Section {
					NavigationLink { GitHubAccountView() } label: {
						HStack {
							Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
							Spacer()
							Text(GH.token.isEmpty ? "не подключён" : (UserDefaults.standard.string(forKey: "github-login") ?? "подключён"))
								.font(.footnote).foregroundStyle(.secondary)
						}
					}
				} header: {
					Text("Аккаунты")
				}
				Section {
					NavigationLink { CrashListView() } label: {
						HStack {
							Label("Журнал вылетов", systemImage: "ladybug")
							Spacer()
							Text("\(CrashLog.reports().count)").font(.footnote).foregroundStyle(.secondary)
						}
					}
				} header: {
					Text("Отладка")
				} footer: {
					Text("Forge \(CrashLog.version)")
				}
				Section("Редактор") {
					NavigationLink { ThemePickerView() } label: {
						HStack {
							Label("Тема", systemImage: "paintpalette")
							Spacer()
							Text(Theme.find(themeID).name).font(.footnote).foregroundStyle(.secondary)
						}
					}
					Toggle("Проверка синтаксиса", isOn: $syntaxCheck)
					Stepper("Шрифт: \(Int(fontSize))", value: $fontSize, in: 9...28)
					Toggle("Номера строк", isOn: $lineNumbers)
				}
			}
			.navigationTitle("Настройки")
			.navigationBarTitleDisplayMode(.inline)
			.navigationDestination(isPresented: $showNewProvider) {
				if let p = newProvider { ProviderView(provider: p) }
			}
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
			}
		}
	}
}

struct ProviderRow: View {
	let provider: Provider
	@ObservedObject private var ps = Providers.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(provider.name)
				if ps.active.provider == provider.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
			}
			if provider.needsKey && ps.key(provider).isEmpty {
				Text("нет ключа").font(.caption).foregroundStyle(.orange)
			} else {
				Text("\(provider.models.count) моделей").font(.caption).foregroundStyle(.secondary)
			}
		}
	}
}

struct ProviderView: View {
	@ObservedObject private var ps = Providers.shared
	@Environment(\.dismiss) private var dismiss
	@State private var p: Provider
	@State private var key: String
	@State private var newModel = ""
	@State private var loading = false
	@State private var error: String?

	init(provider: Provider) {
		_p = State(initialValue: provider)
		_key = State(initialValue: Providers.shared.key(provider))
	}

	var body: some View {
		Form {
			if !p.note.isEmpty {
				Section { Text(p.note).font(.footnote) }
			}
			Section("Подключение") {
				TextField("Название", text: $p.name)
				Picker("Тип API", selection: $p.kind) {
					ForEach(APIKind.allCases) { Text($0.title).tag($0) }
				}
				TextField("Адрес, напр. https://api.groq.com/openai/v1", text: $p.baseURL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
					.font(.footnote.monospaced())
				Toggle("Нужен ключ", isOn: $p.needsKey)
				SecureField("API-ключ", text: $key)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
			}
			Section {
				ForEach(p.models, id: \.self) { m in
					Button {
						commit()
						ps.active = ModelRef(provider: p.id, model: m)
					} label: {
						HStack {
							Text(m).font(.footnote.monospaced()).foregroundStyle(.primary)
							Spacer()
							if ps.active == ModelRef(provider: p.id, model: m) {
								Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
							}
						}
					}
				}
				.onDelete { p.models.remove(atOffsets: $0) }
				HStack {
					TextField("ID модели", text: $newModel)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.font(.footnote.monospaced())
					Button("Добавить") {
						let m = newModel.trimmingCharacters(in: .whitespaces)
						if !m.isEmpty && !p.models.contains(m) { p.models.append(m) }
						newModel = ""
					}
					.disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
				}
				Button {
					commit()
					loading = true
					Task {
						do { p.models = try await ps.fetchModels(p); commit() } catch { self.error = error.localizedDescription }
						loading = false
					}
				} label: {
					HStack {
						Label("Загрузить список с сервера", systemImage: "arrow.down.circle")
						if loading { Spacer(); ProgressView() }
					}
				}
				.disabled(loading)
			} header: {
				Text("Модели — нажми, чтобы выбрать")
			}
			Section {
				if p.isPreset {
					Button("Сбросить к стандартным настройкам") {
						ps.resetPreset(p)
						if let orig = Providers.presets.first(where: { $0.id == p.id }) { p = orig }
					}
				} else {
					Button("Удалить провайдера", role: .destructive) { ps.remove(p); dismiss() }
				}
			}
		}
		.navigationTitle(p.name)
		.navigationBarTitleDisplayMode(.inline)
		.errorAlert($error)
		.onDisappear(perform: commit)
	}

	private func commit() {
		guard ps.list.contains(where: { $0.id == p.id }) else { return }  // удалён
		ps.update(p)
		if key != ps.key(p) { ps.setKey(key, for: p) }
	}
}

// MARK: темы

struct ThemePickerView: View {
	@AppStorage("theme") private var themeID = "xcode"

	var body: some View {
		List(Theme.all) { t in
			Button { themeID = t.id } label: {
				HStack(spacing: 12) {
					ThemePreview(theme: t)
					VStack(alignment: .leading, spacing: 4) {
						Text(t.name).foregroundStyle(.primary)
						HStack(spacing: 4) {
							ForEach(Array(t.swatches.enumerated()), id: \.offset) { _, c in
								Circle().fill(c).frame(width: 12, height: 12)
							}
						}
					}
					Spacer()
					if t.id == themeID { Image(systemName: "checkmark").foregroundStyle(t.accentColor) }
				}
			}
		}
		.navigationTitle("Тема")
		.navigationBarTitleDisplayMode(.inline)
	}
}

/// Кусочек кода в цветах темы.
struct ThemePreview: View {
	let theme: Theme

	var body: some View {
		let p = theme.style == .light ? theme.light : theme.dark
		let c = { (v: UInt32) in Color(Theme.rgb(v)) }
		VStack(alignment: .leading, spacing: 1) {
			(Text("func ").foregroundColor(c(p.keyword)) + Text("hi").foregroundColor(c(p.fg))
			 + Text("() {").foregroundColor(c(p.fg)))
			(Text("  print(").foregroundColor(c(p.fg)) + Text("\"ok\"").foregroundColor(c(p.string))
			 + Text(", ").foregroundColor(c(p.fg)) + Text("42").foregroundColor(c(p.number)) + Text(")").foregroundColor(c(p.fg)))
			(Text("} ").foregroundColor(c(p.fg)) + Text("// Forge").foregroundColor(c(p.comment)))
		}
		.font(.system(size: 9, design: .monospaced))
		.padding(6)
		.frame(width: 118, alignment: .leading)
		.background(theme.previewBg, in: RoundedRectangle(cornerRadius: 6))
	}
}
