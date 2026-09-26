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
			Button(L("Cancel"), role: .cancel) {}
		}
	}

	func errorAlert(_ error: Binding<String?>) -> some View {
		alert(L("Error"), isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
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
	@ObservedObject private var updater = Updater.shared
	@State private var checkedUpdates = false
	@State private var restoreOffer: Snapshots.Info?
	@State private var restoring = false
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
							Button { prompt = Prompt(title: L("Rename"), text: p.name) { try store.rename(p, to: $0) } } label: {
								Label(L("Rename"), systemImage: "pencil")
							}
							Button { do { try store.duplicate(p) } catch { self.error = error.localizedDescription } } label: {
								Label(L("Duplicate"), systemImage: "plus.square.on.square")
							}
							Button(role: .destructive) { toDelete = p } label: { Label(L("Delete"), systemImage: "trash") }
						}
				}
				.onDelete { idx in toDelete = idx.first.map { store.projects[$0] } }
			}
			.overlay {
				if store.projects.isEmpty {
					Text(L("No projects yet.\n+ — new project, ⤓ — clone from GitHub"))
						.multilineTextAlignment(.center)
						.foregroundStyle(.secondary)
				}
			}
			.navigationTitle("Forge")
			.navigationDestination(for: Project.self) { ProjectView(project: $0) }
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button { showSettings = true } label: {
						Image(systemName: "gearshape")
							.overlay(alignment: .topTrailing) {
								// есть обновление — точка на шестерёнке
								if case .available = updater.state { Circle().fill(.red).frame(width: 8, height: 8).offset(x: 3, y: -3) }
							}
					}
				}
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button { showClone = true } label: { Image(systemName: "square.and.arrow.down.on.square") }
					Button { showNew = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showNew) { NewProjectView() }
			.sheet(isPresented: $showClone) { CloneView() }
			.sheet(isPresented: $showSettings) { SettingsView() }
			.onAppear {
				if let s = Snapshots.pendingRestore { Snapshots.pendingRestore = nil; restoreOffer = s }
			}
			.alert(L("Restore your Forge %@ data?", restoreOffer?.version ?? ""),
			       isPresented: Binding(get: { restoreOffer != nil }, set: { if !$0 { restoreOffer = nil } })) {
				Button(L("Restore")) {
					guard let s = restoreOffer else { return }
					restoring = true
					Task {
						do { try await Snapshots.restore(s) } catch { self.error = error.localizedDescription }
						store.reload()
						restoring = false
					}
				}
				Button(L("Keep current"), role: .cancel) {}
			} message: {
				Text(L("You are back on a newer version. Forge saved your projects and settings when you left it (%@). Restore them? The current state is saved to a snapshot first.",
				       restoreOffer?.date.formatted(date: .abbreviated, time: .shortened) ?? ""))
			}
			.overlay { if restoring { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
			.task {
				guard !checkedUpdates, Feature.on(Feature.autoUpdate) else { return }
				checkedUpdates = true
				await updater.check()
			}
			.confirmationDialog(L("Delete project “%@” with all its files?", toDelete?.name ?? ""),
			                    isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
			                    titleVisibility: .visible) {
				Button(L("Delete"), role: .destructive) { if let p = toDelete { store.delete(p) } }
			}
			.promptAlert($prompt, error: $error)
			.errorAlert($error)
			.navigationDestination(isPresented: $showCrash) {
				if let r = openReport { CrashReportView(url: r) }
			}
			.alert(L("Forge crashed last time"), isPresented: Binding(get: { crashReport != nil && !showCrash }, set: { if !$0 { crashReport = nil; CrashLog.clearPending() } })) {
				Button(L("Open report")) { openReport = crashReport; showCrash = true }
				Button(L("Later"), role: .cancel) {}
			} message: {
				Text(L("The report is saved in Settings → Crash log. You can send it to the developer."))
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
				TextField(L("Name (Latin letters, no spaces)"), text: $name)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Picker(L("Template"), selection: $template) {
					Section(L("Runs right on the phone")) {
						ForEach(Template.scripts) { Text($0.title).tag($0) }
					}
					Section(L("iOS app (.ipa build)")) {
						ForEach(Template.apps) { Text($0.title).tag($0) }
					}
				}
				.pickerStyle(.inline)
				if let error { Text(error).foregroundStyle(.red) }
			}
			.navigationTitle(L("New project"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button(L("Create")) {
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
	@AppStorage(L10n.key) private var language = "en"
	@State private var newProvider: Provider?
	@State private var showNewProvider = false

	var body: some View {
		NavigationStack {
			Form {
				UpdateSection()
				FeaturesSection()
				if IpaBuilder.available { JITSection() }
				Section(L("Appearance")) { AppearancePicker() }
				Section(L("Language")) {
					Picker(L("Language"), selection: $language) {
						ForEach(L10n.languages, id: \.id) { Text($0.title).tag($0.id) }
					}
				}
				Section {
					HStack {
						Text(L("Current"))
						Spacer()
						Text("\(L(ps.activeProvider?.name ?? "—"))\n\(ps.active.model)")
							.multilineTextAlignment(.trailing)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} header: {
					Text(L("AI model"))
				} footer: {
					Text(L("Pick the model inside a provider or right in the chat."))
				}
				Section {
					ForEach(ps.list) { p in
						NavigationLink { ProviderView(provider: p) } label: { ProviderRow(provider: p) }
					}
					Button { newProvider = ps.addCustom(); showNewProvider = true } label: { Label(L("Add provider"), systemImage: "plus") }
				} header: {
					Text(L("Providers"))
				} footer: {
					Text(L("Any OpenAI-compatible API works (Groq, DeepSeek, Mistral, Together, your own server…) or an Anthropic-compatible one."))
				}
				Section {
					NavigationLink { GitHubAccountView() } label: {
						HStack {
							Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
							Spacer()
							Text(GH.token.isEmpty ? L("not connected") : (UserDefaults.standard.string(forKey: "github-login") ?? L("connected")))
								.font(.footnote).foregroundStyle(.secondary)
						}
					}
				} header: {
					Text(L("Accounts"))
				}
				Section {
					NavigationLink { CrashListView() } label: {
						HStack {
							Label(L("Crash log"), systemImage: "ladybug")
							Spacer()
							Text("\(CrashLog.reports().count)").font(.footnote).foregroundStyle(.secondary)
						}
					}
				} header: {
					Text(L("Debugging"))
				} footer: {
					Text("Forge \(CrashLog.version)")
				}
				Section(L("Editor")) {
					NavigationLink { ThemePickerView() } label: {
						HStack {
							Label(L("Theme"), systemImage: "paintpalette")
							Spacer()
							Text(L(Theme.find(themeID).name)).font(.footnote).foregroundStyle(.secondary)
						}
					}
					Toggle(L("Syntax checking"), isOn: $syntaxCheck)
					Stepper(L("Font: %@", Int(fontSize)), value: $fontSize, in: 9...28)
					Toggle(L("Line numbers"), isOn: $lineNumbers)
				}
			}
			.navigationTitle(L("Settings"))
			.navigationBarTitleDisplayMode(.inline)
			.navigationDestination(isPresented: $showNewProvider) {
				if let p = newProvider { ProviderView(provider: p) }
			}
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
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
				Text(L(provider.name))
				if ps.active.provider == provider.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
			}
			if provider.needsKey && ps.key(provider).isEmpty {
				Text(L("no key")).font(.caption).foregroundStyle(.orange)
			} else {
				Text(L("%@ models", provider.models.count)).font(.caption).foregroundStyle(.secondary)
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
				Section { Text(L(p.note)).font(.footnote) }
			}
			Section(L("Connection")) {
				TextField(L("Name"), text: $p.name)
				Picker(L("API type"), selection: $p.kind) {
					ForEach(APIKind.allCases) { Text($0.title).tag($0) }
				}
				TextField(L("URL, e.g. https://api.groq.com/openai/v1"), text: $p.baseURL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
					.font(.footnote.monospaced())
				Toggle(L("Requires a key"), isOn: $p.needsKey)
				SecureField(L("API key"), text: $key)
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
					TextField(L("Model ID"), text: $newModel)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.font(.footnote.monospaced())
					Button(L("Add")) {
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
						Label(L("Fetch the list from the server"), systemImage: "arrow.down.circle")
						if loading { Spacer(); ProgressView() }
					}
				}
				.disabled(loading)
			} header: {
				Text(L("Models — tap to select"))
			}
			Section {
				if p.isPreset {
					Button(L("Reset to defaults")) {
						ps.resetPreset(p)
						if let orig = Providers.presets.first(where: { $0.id == p.id }) { p = orig }
					}
				} else {
					Button(L("Delete provider"), role: .destructive) { ps.remove(p); dismiss() }
				}
			}
		}
		.navigationTitle(L(p.name))
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
	@Environment(\.colorScheme) private var scheme

	var body: some View {
		List {
			Section {
				AppearancePicker()
			} footer: {
				Text(L("Themes in the first group switch between their light and dark version together with the appearance."))
			}
			group(.both, L("Light and dark"))
			group(.dark, L("Dark only"))
			group(.light, L("Light only"))
		}
		.navigationTitle(L("Theme"))
		.navigationBarTitleDisplayMode(.inline)
	}

	private func group(_ kind: Theme.Kind, _ title: String) -> some View {
		Section(title) {
			ForEach(Theme.all.filter { $0.kind == kind }) { t in
				Button { themeID = t.id } label: {
					HStack(spacing: 12) {
						ThemePreview(theme: t, dark: scheme == .dark)
						VStack(alignment: .leading, spacing: 4) {
							Text(L(t.name)).foregroundStyle(.primary)
							HStack(spacing: 4) {
								ForEach(Array(t.swatches(dark: scheme == .dark).enumerated()), id: \.offset) { _, c in
									Circle().fill(c).frame(width: 12, height: 12)
								}
							}
						}
						Spacer()
						if t.id == themeID { Image(systemName: "checkmark").foregroundStyle(t.accentColor) }
					}
				}
			}
		}
	}
}

/// Кусочек кода в цветах темы.
struct ThemePreview: View {
	let theme: Theme
	var dark = true

	var body: some View {
		let p = theme.palette(dark: dark)
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
		.background(c(p.bg), in: RoundedRectangle(cornerRadius: 6))
		.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
	}
}

/// Оформление приложения: как в системе, светлое или тёмное.
enum Appearance: String, CaseIterable {
	case system, light, dark
	static let key = "appearance"

	var scheme: ColorScheme? {
		switch self {
		case .system: return nil
		case .light: return .light
		case .dark: return .dark
		}
	}

	/// Стиль всем окнам сразу (и листам поверх): preferredColorScheme(nil) не всегда возвращает системное.
	static func apply(_ raw: String) {
		let a = Appearance(rawValue: raw) ?? .system
		let style: UIUserInterfaceStyle = a == .light ? .light : a == .dark ? .dark : .unspecified
		for scene in UIApplication.shared.connectedScenes {
			(scene as? UIWindowScene)?.windows.forEach { $0.overrideUserInterfaceStyle = style }
		}
	}

	var title: String {
		switch self {
		case .system: return L("System")
		case .light: return L("Light")
		case .dark: return L("Dark")
		}
	}
}

struct AppearancePicker: View {
	@AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

	var body: some View {
		Picker(L("Appearance"), selection: $appearance) {
			ForEach(Appearance.allCases, id: \.rawValue) { a in
				Label(a.title, systemImage: a == .light ? "sun.max" : a == .dark ? "moon" : "circle.lefthalf.filled").tag(a.rawValue)
			}
		}
		.pickerStyle(.segmented)
	}
}
