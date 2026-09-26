import SwiftUI
import UIKit

/// Журнал вылетов. Отчёты лежат в Library/Crashes: crash-latest.txt пишет обработчик сигналов,
/// при следующем запуске он переименовывается в crash-<дата>.txt и Forge предлагает его показать.
enum CrashLog {
	static let dir: URL = {
		let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Crashes")
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}()
	private static var latest: URL { dir.appendingPathComponent("crash-latest.txt") }
	private static var stderrLog: URL { dir.appendingPathComponent("stderr.txt") }

	/// Отчёт о вылете прошлого запуска (показать при старте).
	private(set) static var pending: URL?

	static var version: String {
		let i = Bundle.main.infoDictionary
		return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
	}

	static func install() {
		let fm = FileManager.default
		if fm.fileExists(atPath: latest.path) {
			let date = (try? fm.attributesOfItem(atPath: latest.path)[.modificationDate] as? Date) ?? Date()
			let df = DateFormatter()
			df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
			let dst = dir.appendingPathComponent("crash-\(df.string(from: date)).txt")
			try? fm.moveItem(at: latest, to: dst)
			pending = dst
		}
		var u = utsname()
		uname(&u)
		let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		let info = """
		Forge \(version)
		iOS \(UIDevice.current.systemVersion), \(machine)
		Время: смотри дату файла

		"""
		forge_crash_install(latest.path, stderrLog.path, info)
		NSSetUncaughtExceptionHandler(exceptionHandler)
		crumb("запуск Forge \(version)")
	}

	/// Запись в «последние действия» отчёта.
	static func crumb(_ s: String) {
		let df = DateFormatter()
		df.dateFormat = "HH:mm:ss"
		forge_crumb("\(df.string(from: Date()))  \(s)")
	}

	static func reports() -> [URL] {
		let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
		return items.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.lastPathComponent != "crash-latest.txt" }
			.sorted { $0.lastPathComponent > $1.lastPathComponent }
	}

	static func deleteAll() {
		for r in reports() { try? FileManager.default.removeItem(at: r) }
		pending = nil
	}

	static func clearPending() { pending = nil }
}

/// Исключение Objective-C: пишем его в отчёт; следом придёт SIGABRT — сигнальный обработчик допишет стек.
private func exceptionHandler(_ e: NSException) {
	let path = CrashLog.dir.appendingPathComponent("crash-latest.txt")
	let text = """
	=== Отчёт о вылете Forge ===
	Forge \(CrashLog.version), iOS \(UIDevice.current.systemVersion)
	Исключение: \(e.name.rawValue)
	Причина: \(e.reason ?? "—")

	--- Стек исключения ---
	\(e.callStackSymbols.joined(separator: "\n"))

	"""
	try? text.write(to: path, atomically: false, encoding: .utf8)
	forge_crash_mark_exception()
}

// MARK: экраны

struct CrashListView: View {
	@State private var reports = CrashLog.reports()
	@State private var confirmTest = false

	var body: some View {
		List {
			Section {
				if reports.isEmpty { Text(L("No crashes 🎉")).foregroundStyle(.secondary) }
				ForEach(reports, id: \.self) { r in
					NavigationLink { CrashReportView(url: r) } label: {
						Label(r.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "crash-", with: ""),
						      systemImage: "exclamationmark.triangle")
							.font(.footnote.monospaced())
					}
				}
			} footer: {
				Text(L("Open a report and tap Share to send the file to the developer. The report has the Forge version, device model, call stack and recent actions in the app. No keys or project code."))
			}
			if !reports.isEmpty {
				Section {
					Button(L("Delete all reports"), role: .destructive) {
						CrashLog.deleteAll()
						reports = []
					}
				}
			}
			Section {
				Button(L("Test the log (trigger a crash)"), role: .destructive) { confirmTest = true }
			} footer: {
				Text(L("Forge will close. After relaunching, a report should appear here."))
			}
		}
		.navigationTitle(L("Crash log"))
		.navigationBarTitleDisplayMode(.inline)
		.onAppear { reports = CrashLog.reports() }
		.confirmationDialog(L("Close Forge with a test crash?"), isPresented: $confirmTest, titleVisibility: .visible) {
			Button(L("Crash"), role: .destructive) {
				CrashLog.crumb("тестовый вылет из настроек")
				let empty: [Int] = []
				_ = empty[Int.random(in: 1...2)]  // выход за границы массива → SIGTRAP
			}
		}
	}
}

struct CrashReportView: View {
	let url: URL
	@State private var text = ""
	@State private var share: ShareItem?

	var body: some View {
		ScrollView([.vertical, .horizontal]) {
			Text(text)
				.font(.system(size: 11, design: .monospaced))
				.textSelection(.enabled)
				.padding()
		}
		.navigationTitle(L("Report"))
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .navigationBarTrailing) {
				Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
				Button { share = ShareItem(url: url) } label: { Image(systemName: "square.and.arrow.up") }
			}
		}
		.sheet(item: $share) { ShareSheet(url: $0.url) }
		.onAppear { text = (try? String(contentsOf: url, encoding: .utf8)) ?? L("Could not read the report") }
	}
}
