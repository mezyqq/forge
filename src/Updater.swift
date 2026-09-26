import SwiftUI
import UIKit

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

	struct Release: Equatable {
		let version: String
		let notes: String
		let ipa: URL
		let size: Int
	}

	enum State: Equatable {
		case idle, checking, upToDate
		case available(Release)
		case downloading(Double)
		case installing(Double)
		case ready(Release)        // бандл заменён — осталось перезапустить через LiveContainer
		case downloaded(URL)       // не в LiveContainer — .ipa для «Поделиться»
		case failed(String)
	}

	@Published private(set) var state = State.idle

	static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

	private static var workDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("forge-update") }

	/// Остатки прошлого обновления (старый бандл, архив) — удалить при запуске.
	nonisolated static func cleanup() {
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
			let tag = (j["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
			let assets = j["assets"] as? [[String: Any]] ?? []
			guard let a = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".ipa") }),
			      let s = a["browser_download_url"] as? String, let u = URL(string: s) else {
				throw Unzip.Failure(message: L("The latest release has no .ipa"))
			}
			let rel = Release(version: tag, notes: Updater.localizedNotes(j["body"] as? String ?? ""), ipa: u, size: a["size"] as? Int ?? 0)
			state = Updater.newer(tag, than: Updater.current) ? .available(rel) : .upToDate
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	func install(_ rel: Release) async {
		state = .downloading(0)
		CrashLog.crumb("обновление до \(rel.version)")
		let fm = FileManager.default
		do {
			let work = Updater.workDir
			try? fm.removeItem(at: work)
			try fm.createDirectory(at: work, withIntermediateDirectories: true)
			let ipa = work.appendingPathComponent("Forge-\(rel.version).ipa")
			let (tmp, resp) = try await URLSession.shared.download(from: rel.ipa, delegate: Progress { p in
				Task { @MainActor in self.state = .downloading(p) }
			})
			guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
				throw Unzip.Failure(message: L("Download failed (HTTP %@)", (resp as? HTTPURLResponse)?.statusCode ?? 0))
			}
			try fm.moveItem(at: tmp, to: ipa)

			guard LiveContainer.hosting else {
				state = .downloaded(ipa)
				return
			}
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
			try? fm.removeItem(at: ipa)
			let app = try LiveContainer.appInPayload(unpacked.appendingPathComponent("Payload"))
			try LiveContainer.place(app, at: Bundle.main.bundleURL, trash: Updater.workDir.appendingPathComponent("old.app"))
			state = .ready(rel)
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	/// Закрыть Forge и открыть LiveContainer: запуск оттуда пропатчит и подпишет новую версию.
	func relaunch() { LiveContainer.openHostUI() }

	// MARK: -

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

	/// 0.10 > 0.9: сравниваем числа по частям.
	static func newer(_ a: String, than b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) {
			let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
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
			case .downloaded(let ipa):
				Button { share = ShareItem(url: ipa) } label: { Label(L("Share %@", ipa.lastPathComponent), systemImage: "square.and.arrow.up") }
				Text(L("Forge is not running inside LiveContainer, so it cannot replace itself. Install this .ipa over the current app with your installer — data is kept when the bundle ID is the same."))
					.font(.footnote).foregroundStyle(.secondary)
			}
		} header: {
			Text(L("Updates"))
		}
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.task { if case .idle = u.state { await u.check() } }
	}
}
