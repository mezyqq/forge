import SwiftUI

// MARK: аккаунт

struct GitHubAccountView: View {
	@State private var token = GH.token
	@AppStorage("github-login") private var login = ""
	@State private var checking = false
	@State private var error: String?

	var body: some View {
		Form {
			Section {
				SecureField(L("ghp_… or github_pat_…"), text: $token)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Button {
					Keychain.set(GH.tokenKey, token.trimmingCharacters(in: .whitespacesAndNewlines))
					checking = true
					Task {
						do { login = try await GH.login() } catch { login = ""; self.error = error.localizedDescription }
						checking = false
					}
				} label: {
					HStack { Text(L("Save and verify")); if checking { Spacer(); ProgressView() } }
				}
				.disabled(token.isEmpty || checking)
			} header: {
				Text("Personal Access Token")
			} footer: {
				Text(L("Fine-grained token: pick the repositories and grant Contents, Pull requests, Issues — Read and write (Administration for new repositories). Or a classic token with the “repo” scope."))
			}
			if !login.isEmpty {
				Section { Label(L("Signed in: %@", login), systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
			}
			Section {
				Link(destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!) {
					Label(L("Create a fine-grained token"), systemImage: "safari")
				}
				Link(destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Forge")!) {
					Label(L("Create a classic token (repo)"), systemImage: "safari")
				}
			}
			if !GH.token.isEmpty {
				Section {
					Button(L("Sign out"), role: .destructive) {
						Keychain.set(GH.tokenKey, "")
						token = ""
						login = ""
					}
				}
			}
		}
		.navigationTitle("GitHub")
		.navigationBarTitleDisplayMode(.inline)
		.errorAlert($error)
	}
}

// MARK: клонирование

struct CloneView: View {
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@State private var spec = ""
	@State private var branch = ""
	@State private var repos: [GHRepo] = []
	@State private var filter = ""
	@State private var loadingRepos = false
	@State private var busy: String?
	@State private var error: String?

	private var filtered: [GHRepo] {
		filter.isEmpty ? repos : repos.filter { $0.fullName.localizedCaseInsensitiveContains(filter) }
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField(L("owner/repo or a GitHub link"), text: $spec)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.keyboardType(.URL)
					TextField(L("branch (default — the main one)"), text: $branch)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					Button { clone(spec) } label: { Label(L("Clone"), systemImage: "arrow.down.circle.fill") }
						.disabled(spec.isEmpty || busy != nil)
				} footer: {
					Text(L("Public repositories can be cloned without a token."))
				}
				if let busy {
					Section { HStack { ProgressView(); Text(busy).font(.footnote) } }
				}
				if GH.token.isEmpty {
					Section {
						Text(L("Add a GitHub token in Settings to get your repositories, private repos, commits and push."))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					Section {
						TextField(L("Search"), text: $filter)
						if loadingRepos { ProgressView() }
						ForEach(filtered) { r in
							Button { clone(r.fullName) } label: {
								VStack(alignment: .leading, spacing: 2) {
									HStack {
										Text(r.fullName).foregroundStyle(.primary)
										if r.isPrivate { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
									}
									if !r.about.isEmpty { Text(r.about).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
								}
							}
							.disabled(busy != nil)
						}
					} header: {
						Text(L("My repositories"))
					}
				}
			}
			.navigationTitle(L("Clone"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
			.errorAlert($error)
			.task {
				guard !GH.token.isEmpty, repos.isEmpty else { return }
				loadingRepos = true
				do { repos = try await GH.repos() } catch { self.error = error.localizedDescription }
				loadingRepos = false
			}
		}
		.interactiveDismissDisabled(busy != nil)
	}

	private func clone(_ s: String) {
		busy = L("Starting…")
		let root = store.root, br = branch.trimmingCharacters(in: .whitespaces)
		Task {
			do {
				_ = try await Git.clone(s, branch: br, into: root) { p in DispatchQueue.main.async { busy = p } }
				store.reload()
				dismiss()
			} catch {
				self.error = error.localizedDescription
			}
			busy = nil
		}
	}
}

// MARK: git-экран проекта

struct GitView: View {
	let project: Project
	@EnvironmentObject var store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@State private var state: GitState?
	@State private var changes: [GitChange] = []
	@State private var selected: Set<String> = []
	@State private var message = ""
	@State private var busy: String?
	@State private var info: String?
	@State private var error: String?
	@State private var repoName = ""
	@State private var isPrivate = true

	var body: some View {
		NavigationStack {
			Form {
				if let st = state { linked(st) } else { unlinked }
				if let busy {
					Section { HStack { ProgressView(); Text(busy).font(.footnote) } }
				}
				if let info {
					Section { Text(info).font(.footnote) }
				}
			}
			.navigationTitle("GitHub")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
			.errorAlert($error)
			.onAppear { repoName = project.name; refresh() }
		}
		.interactiveDismissDisabled(busy != nil)
	}

	@ViewBuilder private func linked(_ st: GitState) -> some View {
		Section {
			Button { openURL(URL(string: "https://github.com/\(st.fullName)/tree/\(st.branch)")!) } label: {
				HStack {
					Image(systemName: "arrow.triangle.branch")
					VStack(alignment: .leading) {
						Text(st.fullName).bold().foregroundStyle(.primary)
						Text(L("branch %@ · %@", st.branch, String(st.head.prefix(7)))).font(.caption.monospaced()).foregroundStyle(.secondary)
					}
					Spacer()
					Image(systemName: "safari").foregroundStyle(.secondary)
				}
			}
		}
		Section {
			if changes.isEmpty {
				Text(L("No changes")).foregroundStyle(.secondary)
			}
			ForEach(changes) { c in
				HStack(spacing: 10) {
					Button { toggle(c.path) } label: {
						Image(systemName: selected.contains(c.path) ? "checkmark.circle.fill" : "circle")
					}
					.buttonStyle(.borderless)
					NavigationLink { DiffView(project: project, change: c) } label: {
						HStack(spacing: 8) {
							Text(c.kind.rawValue).bold().font(.caption.monospaced()).foregroundStyle(color(c.kind))
							Text(c.path).font(.footnote.monospaced()).lineLimit(1).truncationMode(.head)
						}
					}
				}
				.swipeActions {
					Button(L("Discard"), role: .destructive) { perform(L("Discarding…")) { _ in try await Git.discard(project.url, c); return nil } }
				}
			}
			if !changes.isEmpty {
				TextField(L("Commit message"), text: $message, axis: .vertical)
					.lineLimit(1...4)
				Button { commit() } label: {
					Label(L("Commit and push (%@)", selected.count), systemImage: "arrow.up.circle.fill")
				}
				.disabled(selected.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil || GH.token.isEmpty)
			}
		} header: {
			Text(L("Changes"))
		} footer: {
			if GH.token.isEmpty { Text(L("Commits need a GitHub token in Settings.")) }
			else if !changes.isEmpty { Text(L("Swipe left to discard a file's changes.")) }
		}
		Section {
			Button {
				perform(L("Pulling…")) { p in
					let r = try await Git.sync(project.url, progress: p)
					if r.upToDate { return L("Already up to date") }
					var s = L("Files updated: %@, deleted: %@.", r.updated, r.deleted)
					if !r.conflicts.isEmpty {
						s += L("\nConflicts (your version is kept, the GitHub version is next to it as .remote):\n") + r.conflicts.joined(separator: "\n")
					}
					return s
				}
			} label: { Label(L("Pull changes"), systemImage: "arrow.down.circle") }
			.disabled(busy != nil)
			NavigationLink { BranchesView(project: project, onChange: refresh) } label: { Label(L("Branches"), systemImage: "arrow.triangle.branch") }
			NavigationLink { HistoryView(project: project) } label: { Label(L("Commit history"), systemImage: "clock.arrow.circlepath") }
			NavigationLink { ItemsView(project: project, pulls: true) } label: { Label("Pull requests", systemImage: "arrow.triangle.pull") }
			NavigationLink { ItemsView(project: project, pulls: false) } label: { Label("Issues", systemImage: "exclamationmark.bubble") }
		}
		Section {
			Button(L("Unlink from GitHub"), role: .destructive) {
				try? FileManager.default.removeItem(at: GitState.url(project.url))
				refresh()
			}
		} footer: {
			Text(L("Files stay; only the link to the repository is removed."))
		}
	}

	@ViewBuilder private var unlinked: some View {
		Section {
			TextField(L("Repository name"), text: $repoName)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Toggle(L("Private"), isOn: $isPrivate)
			Button {
				let name = repoName.trimmingCharacters(in: .whitespaces), priv = isPrivate
				perform(L("Publishing…")) { p in
					try await Git.publish(project.url, name: name, isPrivate: priv, progress: p)
					return L("Done: the project is on GitHub")
				}
			} label: { Label(L("Create repository and push"), systemImage: "icloud.and.arrow.up") }
			.disabled(repoName.isEmpty || busy != nil || GH.token.isEmpty)
		} header: {
			Text(L("Publish to GitHub"))
		} footer: {
			Text(GH.token.isEmpty ? L("Add a GitHub token in Settings first.")
			                      : L("The project is not linked to a repository yet. To work with an existing repository, clone it from the main screen."))
		}
	}

	private func color(_ k: GitChange.Kind) -> Color {
		switch k {
		case .added: return .green
		case .modified: return .orange
		case .deleted: return .red
		}
	}

	private func toggle(_ p: String) {
		if selected.contains(p) { selected.remove(p) } else { selected.insert(p) }
	}

	private func refresh() {
		state = GitState.load(project.url)
		guard state != nil else { changes = []; return }
		let url = project.url
		Task {
			let c = await Task.detached { (try? Git.status(url)) ?? [] }.value
			changes = c
			selected = Set(c.map(\.path))
		}
	}

	private func commit() {
		let msg = message.trimmingCharacters(in: .whitespacesAndNewlines), paths = selected
		perform(L("Committing…")) { p in
			try await Git.commit(project.url, message: msg, paths: paths, progress: p)
			return L("Pushed to GitHub ✓")
		}
		message = ""
	}

	/// Выполняет git-операцию с прогрессом, потом обновляет экран и файлы проекта.
	private func perform(_ title: String, _ op: @escaping (@escaping (String) -> Void) async throws -> String?) {
		busy = title
		CrashLog.crumb("git: \(title)")
		info = nil
		Task {
			do {
				info = try await op { p in DispatchQueue.main.async { busy = p } }
			} catch {
				self.error = error.localizedDescription
			}
			busy = nil
			refresh()
			store.externalChange()
		}
	}
}

// MARK: дифф

struct DiffRow: Identifiable {
	let id: Int
	let kind: Character  // + - пробел …
	let text: String
}

enum Diff {
	static func rows(_ a: String, _ b: String, context: Int = 3) -> [DiffRow] {
		let A = a.components(separatedBy: "\n"), B = b.components(separatedBy: "\n")
		var removed = Set<Int>(), inserted = Set<Int>()
		for c in B.difference(from: A) {
			switch c {
			case .remove(let o, _, _): removed.insert(o)
			case .insert(let o, _, _): inserted.insert(o)
			}
		}
		var lines: [(Character, String)] = []
		var i = 0, j = 0
		while i < A.count || j < B.count {
			if i < A.count && removed.contains(i) { lines.append(("-", A[i])); i += 1 }
			else if j < B.count && inserted.contains(j) { lines.append(("+", B[j])); j += 1 }
			else if i < A.count && j < B.count { lines.append((" ", A[i])); i += 1; j += 1 }
			else if i < A.count { lines.append(("-", A[i])); i += 1 }
			else { lines.append(("+", B[j])); j += 1 }
		}
		// оставляем только изменения и `context` строк вокруг них
		var keep = [Bool](repeating: false, count: lines.count)
		for (k, l) in lines.enumerated() where l.0 != " " {
			for m in max(0, k - context)...min(lines.count - 1, k + context) { keep[m] = true }
		}
		var out: [DiffRow] = []
		var skipped = 0
		for (k, l) in lines.enumerated() {
			if keep[k] {
				if skipped > 0 { out.append(DiffRow(id: out.count, kind: "…", text: L("⋯ %@ unchanged lines", skipped))); skipped = 0 }
				out.append(DiffRow(id: out.count, kind: l.0, text: l.1))
			} else { skipped += 1 }
		}
		if skipped > 0 && !out.isEmpty { out.append(DiffRow(id: out.count, kind: "…", text: L("⋯ %@ unchanged lines", skipped))) }
		return out
	}

	/// Для патчей из GitHub API (формат unified diff).
	static func rows(patch: String) -> [DiffRow] {
		patch.components(separatedBy: "\n").enumerated().map { k, l in
			let c: Character = l.hasPrefix("@@") ? "…" : l.hasPrefix("+") ? "+" : l.hasPrefix("-") ? "-" : " "
			return DiffRow(id: k, kind: c, text: l)
		}
	}
}

struct DiffLines: View {
	let rows: [DiffRow]

	var body: some View {
		LazyVStack(alignment: .leading, spacing: 0) {
			ForEach(rows) { r in
				Text(r.kind == "…" ? r.text : "\(r.kind) \(r.text)")
					.font(.caption.monospaced())
					.foregroundStyle(r.kind == "…" ? Color.secondary : Color.primary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 8)
					.padding(.vertical, 1)
					.background(r.kind == "+" ? Color.green.opacity(0.18) : r.kind == "-" ? Color.red.opacity(0.18) : Color.clear)
			}
		}
		.textSelection(.enabled)
	}
}

struct DiffView: View {
	let project: Project
	let change: GitChange
	@State private var rows: [DiffRow] = []
	@State private var loading = true
	@State private var error: String?

	var body: some View {
		ScrollView {
			if loading { ProgressView().padding() }
			else if rows.isEmpty { Text(L("No text differences")).foregroundStyle(.secondary).padding() }
			DiffLines(rows: rows)
		}
		.navigationTitle((change.path as NSString).lastPathComponent)
		.navigationBarTitleDisplayMode(.inline)
		.errorAlert($error)
		.task {
			do {
				let base = change.kind == .added ? "" : (try await Git.baseText(project.url, change.path) ?? L("(binary file)"))
				let local = change.kind == .deleted ? ""
					: ((try? String(contentsOf: project.url.appendingPathComponent(change.path), encoding: .utf8)) ?? L("(binary file)"))
				rows = Diff.rows(base, local)
			} catch {
				self.error = error.localizedDescription
			}
			loading = false
		}
	}
}

// MARK: ветки

struct BranchesView: View {
	let project: Project
	let onChange: () -> Void
	@EnvironmentObject var store: ProjectStore
	@State private var names: [String] = []
	@State private var current = ""
	@State private var busy: String?
	@State private var error: String?
	@State private var prompt: Prompt?

	var body: some View {
		List {
			if let busy { HStack { ProgressView(); Text(busy).font(.footnote) } }
			ForEach(names, id: \.self) { n in
				Button {
					guard n != current else { return }
					run(L("Switching to %@…", n)) { p in try await Git.switchBranch(project.url, to: n, progress: p) }
				} label: {
					HStack {
						Text(n).foregroundStyle(.primary)
						Spacer()
						if n == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
					}
				}
				.disabled(busy != nil)
			}
		}
		.navigationTitle(L("Branches"))
		.toolbar {
			Button {
				prompt = Prompt(title: L("New branch from %@", current), text: "", placeholder: L("feature/name")) { name in
					guard !name.isEmpty else { return }
					run(L("Creating %@…", name)) { _ in try await Git.createBranch(project.url, name: name) }
				}
			} label: { Image(systemName: "plus") }
		}
		.promptAlert($prompt, error: $error)
		.errorAlert($error)
		.task { await load() }
	}

	private func load() async {
		current = GitState.load(project.url)?.branch ?? ""
		do { names = try await Git.branches(project.url) } catch { self.error = error.localizedDescription }
	}

	private func run(_ title: String, _ op: @escaping (@escaping (String) -> Void) async throws -> Void) {
		busy = title
		Task {
			do { try await op { p in DispatchQueue.main.async { busy = p } } } catch { self.error = error.localizedDescription }
			busy = nil
			await load()
			onChange()
			store.externalChange()
		}
	}
}

// MARK: история

struct HistoryView: View {
	let project: Project
	@State private var commits: [GHCommit] = []
	@State private var loading = true
	@State private var error: String?

	var body: some View {
		List(commits) { c in
			NavigationLink { CommitView(project: project, commit: c) } label: {
				VStack(alignment: .leading, spacing: 3) {
					Text(c.message.components(separatedBy: "\n").first ?? "").lineLimit(2)
					Text("\(String(c.sha.prefix(7))) · \(c.author) · \(c.date)").font(.caption.monospaced()).foregroundStyle(.secondary)
				}
			}
		}
		.overlay { if loading { ProgressView() } }
		.navigationTitle(L("History"))
		.errorAlert($error)
		.task {
			do { commits = try await Git.history(project.url) } catch { self.error = error.localizedDescription }
			loading = false
		}
	}
}

struct CommitView: View {
	let project: Project
	let commit: GHCommit
	@State private var files: [GHFile] = []
	@State private var loading = true
	@State private var error: String?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				Text(commit.message).textSelection(.enabled).padding(.horizontal)
				if loading { ProgressView().frame(maxWidth: .infinity) }
				ForEach(files) { f in
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Text(f.name).font(.footnote.monospaced()).bold()
							Spacer()
							Text("+\(f.additions)").foregroundStyle(.green).font(.caption)
							Text("−\(f.deletions)").foregroundStyle(.red).font(.caption)
						}
						.padding(.horizontal)
						DiffLines(rows: Diff.rows(patch: f.patch))
					}
				}
			}
			.padding(.vertical)
		}
		.navigationTitle(String(commit.sha.prefix(7)))
		.navigationBarTitleDisplayMode(.inline)
		.errorAlert($error)
		.task {
			do { files = try await Git.commitFiles(project.url, commit.sha) } catch { self.error = error.localizedDescription }
			loading = false
		}
	}
}

// MARK: pull requests и issues

struct ItemsView: View {
	let project: Project
	let pulls: Bool
	@Environment(\.openURL) private var openURL
	@State private var items: [GHItem] = []
	@State private var loading = true
	@State private var error: String?
	@State private var showNew = false

	var body: some View {
		List(items) { it in
			Button { if let u = URL(string: it.url) { openURL(u) } } label: {
				VStack(alignment: .leading, spacing: 3) {
					Text(it.title).foregroundStyle(.primary)
					Text("#\(it.number) · \(it.author)").font(.caption).foregroundStyle(.secondary)
				}
			}
		}
		.overlay {
			if loading { ProgressView() }
			else if items.isEmpty { Text(pulls ? L("No open pull requests") : L("No open issues")).foregroundStyle(.secondary) }
		}
		.navigationTitle(pulls ? "Pull requests" : "Issues")
		.toolbar { Button { showNew = true } label: { Image(systemName: "plus") } }
		.sheet(isPresented: $showNew) { NewItemView(project: project, pulls: pulls) { Task { await load() } } }
		.errorAlert($error)
		.task { await load() }
	}

	private func load() async {
		do { items = try await Git.items(project.url, pulls: pulls) } catch { self.error = error.localizedDescription }
		loading = false
	}
}

struct NewItemView: View {
	let project: Project
	let pulls: Bool
	let onDone: () -> Void
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@State private var title = ""
	@State private var text = ""
	@State private var base = ""
	@State private var busy = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				TextField(L("Title"), text: $title)
				TextField(L("Description"), text: $text, axis: .vertical).lineLimit(4...10)
				if pulls {
					Section {
						TextField(L("into branch"), text: $base)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
					} footer: {
						Text(L("From the current branch “%@”. Commit and push your changes first.", GitState.load(project.url)?.branch ?? ""))
					}
				}
			}
			.navigationTitle(pulls ? L("New pull request") : L("New issue"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					if busy { ProgressView() } else { Button(L("Create"), action: create).disabled(title.isEmpty) }
				}
			}
			.errorAlert($error)
			.onAppear { base = GitState.load(project.url)?.defaultBranch ?? "main" }
		}
	}

	private func create() {
		busy = true
		Task {
			do {
				let url = pulls ? try await Git.openPR(project.url, title: title, body: text, base: base)
				                : try await Git.createIssue(project.url, title: title, body: text)
				onDone()
				dismiss()
				if let u = URL(string: url) { openURL(u) }
			} catch {
				self.error = error.localizedDescription
			}
			busy = false
		}
	}
}
