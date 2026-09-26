import SwiftUI
import UIKit
@preconcurrency import UserNotifications

/// Обновление Forge из GitHub Releases (mezyqq/forge) прямо в приложении.
///
/// Внутри LiveContainer: скачанный Forge.app подменяет текущий бандл на месте (LiveContainer хранит
/// приложения у себя в Documents, процессу они доступны на запись). LCAppInfo.plist сохраняется, а
/// LCPatchRevision сбрасывается — при следующем запуске из LiveContainer тот заново пропатчит и подпишет Forge.
/// Данные (проекты, настройки, Keychain с ключами и токеном GitHub) лежат в контейнере данных LiveContainer,
/// бандл их не содержит — они остаются. Затем переключаемся в LiveContainer, там нажать Forge.
///
/// Вне LiveContainer приложение само себя заменить не может: отдаём .ipa в «Поделиться».
@MainActor
final class Updater: ObservableObject {
	static let shared = Updater()
	static let repo = "mezyqq/forge"

	struct Release: Equatable, Identifiable {
		let version: String
		let notes: String
		let ipa: URL
		let size: Int
		var date: Date? = nil
		var id: String { version }
	}

	enum State: Equatable {
		case idle, checking, upToDate
		case saving                // снимок данных перед сменой версии
		case available(Release)
		case downloading(Double)
		case installing(Double)
		case ready(Release)        // бандл заменён — осталось перезапустить через LiveContainer
		case sideload(Release)     // установлен напрямую — ставим через SideStore или вручную
		case downloaded(URL)       // не в LiveContainer — .ipa для «Поделиться»
		case failed(String)
	}

	@Published private(set) var state = State.idle

	nonisolated static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

	private static var workDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("forge-update") }

	/// Остатки прошлого обновления (старый бандл, архив) — удалить при запуске.
	nonisolated static func cleanup() {
		clearReopen()
		try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("forge-update"))
	}

	func check() async {
		if case .downloading = state { return }
		if case .installing = state { return }
		state = .checking
		do {
			var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
			req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
			req.timeoutInterval = 20
			let (d, r) = try await URLSession.shared.data(for: req)
			guard (r as? HTTPURLResponse)?.statusCode == 200,
			      let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
				throw Unzip.Failure(message: L("GitHub did not answer (HTTP %@)", (r as? HTTPURLResponse)?.statusCode ?? 0))
			}
			guard let rel = Updater.release(j) else { throw Unzip.Failure(message: L("The latest release has no .ipa")) }
			state = Updater.newer(rel.version, than: Updater.current) ? .available(rel) : .upToDate
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	func install(_ rel: Release) async {
		CrashLog.crumb("смена версии на \(rel.version)")
		let fm = FileManager.default
		let work = Updater.workDir
		do {
			// сначала — снимок данных этой версии: к ним можно будет вернуться
			state = .saving
			try await Snapshots.take(reason: "leave")
			// установлен напрямую: ставит SideStore (или другой установщик), сами себя не заменим
			guard LiveContainer.hosting else {
				state = .sideload(rel)
				return
			}
			try? fm.removeItem(at: work)
			try fm.createDirectory(at: work, withIntermediateDirectories: true)
			let ipa = try await download(rel, into: work)
			state = .installing(0)
			let unpacked = work.appendingPathComponent("new")
			try await Task.detached(priority: .userInitiated) {
				var shown = -1
				try Unzip.unpack(ipa, to: unpacked) { p in
					// ~9000 файлов — обновляем полосу только при смене процента
					let pct = Int(p * 100)
					guard pct != shown else { return }
					shown = pct
					Task { @MainActor in Updater.shared.state = .installing(p * 0.95) }
				}
			}.value
			try? fm.removeItem(at: ipa)  // распаковали — .ipa больше не нужен
			let app = try LiveContainer.appInPayload(unpacked.appendingPathComponent("Payload"))
			let old = work.appendingPathComponent("old.app")
			try LiveContainer.place(app, at: Bundle.main.bundleURL, trash: old)
			// старая версия и пустая распаковка — сразу: работающий процесс держит свои файлы открытыми,
			// удаление имени их не трогает
			try? fm.removeItem(at: old)
			try? fm.removeItem(at: unpacked)
			state = .ready(rel)
		} catch {
			try? fm.removeItem(at: work)
			state = .failed(error.localizedDescription)
		}
	}

	/// Установка через SideStore: он скачает релиз с GitHub, подпишет и поставит поверх (данные сохраняются).
	/// Forge при этом закроется — уведомление через минуту откроет новую версию одним нажатием.
	func installWithSideStore(_ rel: Release) {
		var c = URLComponents(string: "sidestore://install")!
		c.queryItems = [URLQueryItem(name: "url", value: rel.ipa.absoluteString)]
		UIApplication.shared.open(c.url!) { ok in
			Task { @MainActor in
				if ok { Updater.scheduleReopen(rel.version) }
				else { Updater.shared.state = .failed(L("SideStore did not open. Is it installed? You can download the .ipa and install it another way.")) }
			}
		}
	}

	/// Скачать .ipa для «Поделиться» (другой установщик). Файл удаляется при следующем запуске Forge.
	func downloadForShare(_ rel: Release) async {
		let fm = FileManager.default, work = Updater.workDir
		do {
			try? fm.removeItem(at: work)
			try fm.createDirectory(at: work, withIntermediateDirectories: true)
			state = .downloaded(try await download(rel, into: work))
		} catch {
			try? fm.removeItem(at: work)
			state = .failed(error.localizedDescription)
		}
	}

	private func download(_ rel: Release, into work: URL) async throws -> URL {
		state = .downloading(0)
		let ipa = work.appendingPathComponent("Forge-\(rel.version).ipa")
		let (tmp, resp) = try await URLSession.shared.download(from: rel.ipa, delegate: Progress { p in
			Task { @MainActor in self.state = .downloading(p) }
		})
		guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
			try? FileManager.default.removeItem(at: tmp)
			throw Unzip.Failure(message: L("Download failed (HTTP %@)", (resp as? HTTPURLResponse)?.statusCode ?? 0))
		}
		try FileManager.default.moveItem(at: tmp, to: ipa)
		return ipa
	}

	nonisolated private static let reopenID = "forge-reopen"

	/// Уведомление «открыть новую версию»: приложение, поставленное напрямую, не может перезапуститься само.
	private static func scheduleReopen(_ version: String) {
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
			guard ok else { return }
			let n = UNMutableNotificationContent()
			n.title = "Forge \(version)"
			n.body = L("If the update has finished installing, tap to open Forge.")
			n.sound = .default
			center.add(UNNotificationRequest(identifier: reopenID, content: n,
			                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
		}
	}

	/// При запуске: уведомление больше не нужно.
	nonisolated static func clearReopen() {
		let center = UNUserNotificationCenter.current()
		center.removePendingNotificationRequests(withIdentifiers: [reopenID])
		center.removeDeliveredNotifications(withIdentifiers: [reopenID])
	}

	/// Закрыть Forge и открыть LiveContainer: запуск оттуда пропатчит и подпишет новую версию.
	func relaunch() { LiveContainer.openHostUI() }

	// MARK: -

	/// Все релизы (для отката на прошлую версию), новые сверху.
	func releases() async throws -> [Release] {
		var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases?per_page=30")!)
		req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		req.timeoutInterval = 20
		let (d, r) = try await URLSession.shared.data(for: req)
		guard (r as? HTTPURLResponse)?.statusCode == 200, let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
			throw Unzip.Failure(message: L("GitHub did not answer (HTTP %@)", (r as? HTTPURLResponse)?.statusCode ?? 0))
		}
		return arr.compactMap(Updater.release).sorted { Updater.newer($0.version, than: $1.version) }
	}

	/// Релиз GitHub → версия и .ipa (nil, если .ipa нет).
	private static func release(_ j: [String: Any]) -> Release? {
		let tag = (j["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
		let assets = j["assets"] as? [[String: Any]] ?? []
		guard let a = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".ipa") }),
		      let s = a["browser_download_url"] as? String, let u = URL(string: s) else { return nil }
		let date = (j["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
		return Release(version: tag, notes: localizedNotes(j["body"] as? String ?? ""), ipa: u, size: a["size"] as? Int ?? 0, date: date)
	}

	/// Описание релиза: до «### Русский» — английское, после — русское (как в релизах Forge).
	private static func localizedNotes(_ body: String) -> String {
		let parts = body.components(separatedBy: "### Русский")
		var s = L10n.isRussian && parts.count > 1 ? parts[1] : parts[0]
		s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)  // картинки
		let lines = s.components(separatedBy: "\n").filter { l in
			!l.hasPrefix("**English**") && !l.hasPrefix("## ") && l.trimmingCharacters(in: .whitespaces) != "---"
		}
		return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// 0.10 > 0.9: сравниваем числа по частям; лишняя часть (0.9.test, 0.9.1) — новее.
	nonisolated static func newer(_ a: String, than b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) {
			let p = i < x.count ? x[i] : -1, q = i < y.count ? y[i] : -1
			if p != q { return p > q }
		}
		return false
	}

	/// Прогресс скачивания (делегат задачи).
	private final class Progress: NSObject, URLSessionDownloadDelegate {
		let report: (Double) -> Void
		init(_ report: @escaping (Double) -> Void) { self.report = report }
		func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
		                totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
			if t > 0 { report(Double(w) / Double(t)) }
		}
		func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
	}
}

/// Раздел «Обновления» в настройках.
struct UpdateSection: View {
	@ObservedObject private var u = Updater.shared
	@State private var share: ShareItem?

	var body: some View {
		Section {
			HStack {
				Text(L("Installed"))
				Spacer()
				Text("Forge \(Updater.current)").foregroundStyle(.secondary)
			}
			switch u.state {
			case .idle, .upToDate, .failed:
				Button { Task { await u.check() } } label: { Label(L("Check for updates"), systemImage: "arrow.triangle.2.circlepath") }
				if case .upToDate = u.state { Text(L("You have the latest version.")).font(.footnote).foregroundStyle(.secondary) }
				if case .failed(let m) = u.state { Text(m).font(.footnote).foregroundStyle(.red) }
			case .checking:
				HStack { ProgressView(); Text(L("Checking…")).foregroundStyle(.secondary) }
			case .saving:
				HStack { ProgressView(); Text(L("Saving your data to a snapshot…")).foregroundStyle(.secondary) }
			case .available(let r):
				Button { Task { await u.install(r) } } label: {
					Label(L("Update to %@", r.version) + (r.size > 0 ? " (\(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file)))" : ""),
					      systemImage: "arrow.down.circle.fill")
				}
				if !r.notes.isEmpty {
					DisclosureGroup(L("What's new in %@", r.version)) {
						Text((try? AttributedString(markdown: r.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(r.notes))
							.font(.footnote)
					}
				}
			case .downloading(let p):
				VStack(alignment: .leading, spacing: 6) {
					Text(L("Downloading…")).font(.footnote)
					ProgressView(value: p)
				}
			case .installing(let p):
				VStack(alignment: .leading, spacing: 6) {
					Text(L("Installing…")).font(.footnote)
					ProgressView(value: p)
				}
			case .ready(let r):
				Button { u.relaunch() } label: { Label(L("Restart into %@", r.version), systemImage: "power") }
				Text(L("Forge will close and LiveContainer will open — tap Forge there. LiveContainer re-signs the new version on that launch. Projects, settings, keys and GitHub stay."))
					.font(.footnote).foregroundStyle(.secondary)
			case .sideload(let r):
				Button { u.installWithSideStore(r) } label: { Label(L("Install %@ with SideStore", r.version), systemImage: "arrow.down.app.fill") }
				Button { Task { await u.downloadForShare(r) } } label: { Label(L("Download the .ipa to install another way"), systemImage: "square.and.arrow.down") }
				Text(L("SideStore replaces Forge and keeps its data; Forge closes during the install. A minute later a notification appears — tap it to open the new version."))
					.font(.footnote).foregroundStyle(.secondary)
			case .downloaded(let ipa):
				Button { share = ShareItem(url: ipa) } label: { Label(L("Share %@", ipa.lastPathComponent), systemImage: "square.and.arrow.up") }
				Text(L("Forge is not running inside LiveContainer, so it cannot replace itself. Install this .ipa over the current app with your installer — data is kept when the bundle ID is the same. The file is deleted the next time Forge starts."))
					.font(.footnote).foregroundStyle(.secondary)
			}
			NavigationLink { VersionsView() } label: { Label(L("Other versions (roll back)"), systemImage: "clock.arrow.circlepath") }
			NavigationLink { SnapshotsView() } label: { Label(L("Data snapshots"), systemImage: "archivebox") }
		} header: {
			Text(L("Updates"))
		}
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.task { if Feature.on(Feature.autoUpdate), case .idle = u.state { await u.check() } }
	}
}

/// Все версии Forge из GitHub Releases: установка любой, в том числе откат на прошлую.
struct VersionsView: View {
	@ObservedObject private var u = Updater.shared
	@Environment(\.dismiss) private var dismiss
	@State private var releases: [Updater.Release] = []
	@State private var loading = true
	@State private var error: String?
	@State private var confirm: Updater.Release?

	var body: some View {
		List {
			Section {
				ForEach(releases) { r in
					Button { confirm = r } label: {
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text("Forge \(r.version)").foregroundStyle(.primary)
								if let d = r.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
							}
							Spacer()
							Text(label(r)).font(.caption).foregroundStyle(r.version == Updater.current ? Color.green : Color.secondary)
						}
					}
					.disabled(r.version == Updater.current)
				}
			} footer: {
				Text(L("Before switching, Forge packs your projects and settings into a compressed snapshot. Nothing is deleted: when you come back to a newer version, Forge offers to restore the data you had in it. AI keys and the GitHub account stay as they are."))
			}
		}
		.overlay { if loading { ProgressView() } }
		.navigationTitle(L("Versions"))
		.navigationBarTitleDisplayMode(.inline)
		.errorAlert($error)
		.confirmationDialog(confirm.map { L(Updater.newer($0.version, than: Updater.current) ? "Update to %@?" : "Roll back to %@?", $0.version) } ?? "",
		                    isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
		                    titleVisibility: .visible) {
			Button(L("Install")) {
				if let r = confirm {
					Task { await u.install(r) }
					dismiss()
				}
			}
		} message: {
			Text(L("Your data is saved to a snapshot first."))
		}
		.task {
			do { releases = try await u.releases() } catch { self.error = error.localizedDescription }
			loading = false
		}
	}

	private func label(_ r: Updater.Release) -> String {
		if r.version == Updater.current { return L("installed") }
		return Updater.newer(r.version, than: Updater.current) ? L("newer") : L("older")
	}
}

/// Снимки данных: восстановить, поделиться (резервная копия), удалить, сделать сейчас.
struct SnapshotsView: View {
	@EnvironmentObject var store: ProjectStore
	@State private var list: [Snapshots.Info] = []
	@State private var busy = false
	@State private var error: String?
	@State private var confirm: Snapshots.Info?
	@State private var share: ShareItem?
	@State private var done: String?

	var body: some View {
		List {
			Section {
				Button { run { try await Snapshots.take(reason: "manual") } } label: {
					Label(L("Save a snapshot now"), systemImage: "plus.circle")
				}
				.disabled(busy)
			}
			Section {
				ForEach(list) { s in
					Button { confirm = s } label: {
						VStack(alignment: .leading, spacing: 2) {
							Text("Forge \(s.version) · \(Snapshots.reasonText(s.reason))").foregroundStyle(.primary)
							Text("\(s.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file))")
								.font(.caption).foregroundStyle(.secondary)
						}
					}
					.disabled(busy)
					.swipeActions {
						Button(role: .destructive) { Snapshots.delete(s); reload() } label: { Label(L("Delete"), systemImage: "trash") }
						Button { share = ShareItem(url: s.url) } label: { Label(L("Share"), systemImage: "square.and.arrow.up") }
					}
				}
			} footer: {
				Text(L("Projects (without build/) and settings, compressed with LZMA. The last %@ snapshots are kept.", Snapshots.keep))
			}
		}
		.overlay { if busy { ProgressView() } else if list.isEmpty { Text(L("No snapshots yet")).foregroundStyle(.secondary) } }
		.navigationTitle(L("Data snapshots"))
		.navigationBarTitleDisplayMode(.inline)
		.errorAlert($error)
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.alert(done ?? "", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) { Button("OK") {} }
		.confirmationDialog(L("Restore this snapshot?"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
		                    titleVisibility: .visible) {
			Button(L("Restore"), role: .destructive) {
				if let s = confirm {
					run {
						try await Snapshots.restore(s)
						store.reload()
						done = L("Restored. The current data was saved to a snapshot first.")
					}
				}
			}
		} message: {
			Text(L("Projects and settings will be replaced with the snapshot. The current state is saved to a new snapshot first."))
		}
		.onAppear(perform: reload)
	}

	private func reload() { list = Snapshots.list() }

	private func run(_ body: @escaping () async throws -> Void) {
		busy = true
		Task {
			do { try await body() } catch { self.error = error.localizedDescription }
			busy = false
			reload()
		}
	}
}
