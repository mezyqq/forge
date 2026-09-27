import SwiftUI
import UIKit

/// Экран forge_preview() проекта, запущенного в память Forge (JIT). Живёт отдельно от консоли запуска:
/// его можно свернуть в мини-окно поверх редактора, смотреть логи (stdout/stderr), а при включённой
/// «Живой перезагрузке» — после сохранения исходника проект пересобирается и экран подменяется.
@MainActor
final class PreviewHost: ObservableObject {
	static let shared = PreviewHost()

	@Published private(set) var vc: UIViewController?
	@Published private(set) var project: URL?
	@Published var expanded = false
	/// iPad: превью пристыковано справа от редактора.
	@Published var docked = false
	@Published private(set) var log = ""
	@Published private(set) var reloading = false
	@Published private(set) var reloadError: String?
	/// Меняется при каждой новой версии экрана — пересоздаёт контейнеры.
	@Published private(set) var generation = 0

	private var watch: Timer?
	private var stamp = ""
	private var logHandle: FileHandle?

	var isOpen: Bool { vc != nil }

	func show(_ vc: UIViewController, project: URL) {
		self.vc = vc
		self.project = project
		reloadError = nil
		generation += 1
		stamp = PreviewHost.sourcesStamp(project)
		startLog()
		watch?.invalidate()
		watch = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
			Task { @MainActor in PreviewHost.shared.tick() }
		}
		expanded = true
	}

	func close() {
		expanded = false
		vc = nil
		project = nil
		watch?.invalidate()
		watch = nil
		try? logHandle?.close()
		logHandle = nil
	}

	func clearLog() { log = "" }

	/// Пересборка изменённых файлов и новая версия экрана. Старый код остаётся в памяти (JIT-сессии не выгружаются).
	func reload() {
		guard let project, !reloading, !Runner.shared.running else { return }
		reloading = true
		reloadError = nil
		CrashLog.crumb("перезагрузка превью")
		let t = Thread {
			let r = Result { try Clang.loadProject(project) }
			DispatchQueue.main.async { PreviewHost.shared.finish(r) }
		}
		t.stackSize = 16 << 20
		t.start()
	}

	private func finish(_ r: Result<OpaquePointer, Error>) {
		reloading = false
		guard project != nil else { return }  // превью закрыли, пока собиралось
		switch r {
		case .success(let jit):
			switch Clang.previewController(jit) {
			case .success(let new):
				vc = new
				generation += 1
			case .failure(let f):
				reloadError = f.message
			}
		case .failure(let e):
			reloadError = (e as? IpaBuilder.Failure)?.message ?? e.localizedDescription
		}
	}

	private func tick() {
		readLog()
		// пока идёт другой запуск, отпечаток не обновляем — изменение подхватится после него
		guard Feature.on(Feature.hotReload), let project, !reloading, !Runner.shared.running else { return }
		let s = PreviewHost.sourcesStamp(project)
		if s != stamp {
			stamp = s
			reload()
		}
	}

	/// Отпечаток src/: пути и время изменения файлов.
	private static func sourcesStamp(_ proj: URL) -> String {
		let src = proj.appendingPathComponent("src")
		var parts: [String] = []
		if let e = FileManager.default.enumerator(at: src, includingPropertiesForKeys: [.contentModificationDateKey]) {
			while let u = e.nextObject() as? URL {
				let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
				parts.append("\(u.lastPathComponent):\(d)")
			}
		}
		return parts.sorted().joined(separator: "|")
	}

	// MARK: логи

	/// stdout/stderr Forge уже пишутся в файл журнала вылетов — читаем его хвост с момента открытия превью.
	private func startLog() {
		try? logHandle?.close()
		log = ""
		logHandle = try? FileHandle(forReadingFrom: CrashLog.stderrLog)
		_ = try? logHandle?.seekToEnd()
	}

	private func readLog() {
		guard let h = logHandle, let d = try? h.readToEnd(), !d.isEmpty else { return }
		log += String(decoding: d, as: UTF8.self)
		if log.utf8.count > 200_000 { log = "…\n" + String(log.suffix(100_000)) }
	}

	// MARK: скриншот для агента

	/// JPEG открытого превью (длинная сторона до 1024 px).
	func screenshot() -> Data? {
		guard let v = vc?.view, v.bounds.width > 0 else { return nil }
		let size = v.bounds.size
		let format = UIGraphicsImageRendererFormat()
		format.scale = min(UIScreen.main.scale, 1024 / max(size.width, size.height))
		let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
			v.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
		}
		return img.jpegData(compressionQuality: 0.7)
	}
}

/// Показ превью поверх всего приложения: полный экран или мини-окно.
struct PreviewHostModifier: ViewModifier {
	@ObservedObject private var host = PreviewHost.shared

	func body(content: Content) -> some View {
		GeometryReader { geo in
			HStack(spacing: 0) {
				content
				if host.isOpen && host.docked && !host.expanded && EditorTabs.enabled {
					Divider()
					DockedPreview().frame(width: max(320, geo.size.width * 0.4))
				}
			}
		}
		.fullScreenCover(isPresented: $host.expanded) { PreviewScreen() }
		.overlay(alignment: .bottomTrailing) {
			if host.isOpen && !host.expanded && !(host.docked && EditorTabs.enabled) { MiniPreview() }
		}
	}
}

struct PreviewScreen: View {
	@ObservedObject private var host = PreviewHost.shared
	@AppStorage(Feature.hotReload) private var hotReload = false
	@State private var showLog = false

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				if let e = host.reloadError {
					Button { showLog = true } label: {
						HStack(alignment: .top, spacing: 8) {
							Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
							Text(e).font(.caption.monospaced()).lineLimit(3).multilineTextAlignment(.leading)
							Spacer(minLength: 0)
						}
						.foregroundStyle(.primary)
						.padding(10)
						.background(Color.red.opacity(0.12))
					}
					.buttonStyle(.plain)
				}
				if let vc = host.vc {
					HostedController(vc: vc).id(host.generation)
				}
				if showLog {
					Divider()
					LogPanel()
				}
			}
			.navigationTitle(host.project?.lastPathComponent ?? "")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItemGroup(placement: .cancellationAction) {
					Button { host.close() } label: { Image(systemName: "xmark") }
					Button { host.docked = false; host.expanded = false } label: { Image(systemName: "pip.enter") }
					if EditorTabs.enabled {
						Button { host.docked = true; host.expanded = false } label: { Image(systemName: "sidebar.right") }
					}
				}
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					if hotReload { Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange) }
					Button { withAnimation { showLog.toggle() } } label: { Image(systemName: showLog ? "terminal.fill" : "terminal") }
					if host.reloading {
						ProgressView()
					} else {
						Button { host.reload() } label: { Image(systemName: "arrow.clockwise") }
					}
				}
			}
		}
	}
}

/// Логи превью: всё, что программа пишет в stdout/stderr (printf, NSLog).
struct LogPanel: View {
	@ObservedObject private var host = PreviewHost.shared

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(L("Log")).font(.caption.bold())
				Spacer()
				Button(L("Clear")) { host.clearLog() }.font(.caption)
				Button { UIPasteboard.general.string = host.log } label: { Image(systemName: "doc.on.doc") }.font(.caption)
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 4)
			ConsoleText(output: host.log)
		}
		.frame(height: 220)
	}
}

/// Свёрнутое превью: живое уменьшенное окно, перетаскивается, нажатие — развернуть.
struct MiniPreview: View {
	@ObservedObject private var host = PreviewHost.shared
	@State private var offset = CGSize.zero
	@GestureState private var drag = CGSize.zero
	private let scale: CGFloat = 0.3

	var body: some View {
		let screen = UIScreen.main.bounds.size
		ZStack(alignment: .topTrailing) {
			if let vc = host.vc {
				ScaledController(vc: vc, size: screen, scale: scale).id(host.generation)
			}
			// касания не уходят в приложение: жесты окна важнее
			Color.clear.contentShape(Rectangle())
			if host.reloading {
				ProgressView().padding(6)
			} else if host.reloadError != nil {
				Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).padding(6)
			}
		}
		.frame(width: screen.width * scale, height: screen.height * scale)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4)))
		.overlay(alignment: .topLeading) {
			Button { host.close() } label: {
				Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
			}
			.offset(x: -8, y: -8)
		}
		.shadow(radius: 8)
		.offset(x: offset.width + drag.width, y: offset.height + drag.height)
		.gesture(DragGesture()
			.updating($drag) { v, s, _ in s = v.translation }
			.onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height })
		.onTapGesture { host.expanded = true }
		.padding(.trailing, 16)
		.padding(.bottom, 90)
	}
}

/// UIViewController превью в полном размере экрана, уменьшенный трансформом.
struct ScaledController: UIViewControllerRepresentable {
	let vc: UIViewController
	let size: CGSize
	let scale: CGFloat

	func makeUIViewController(context: Context) -> UIViewController {
		let host = UIViewController()
		host.view.clipsToBounds = true
		HostedController.adopt(vc, by: host)
		layout(host)
		return host
	}

	func updateUIViewController(_ host: UIViewController, context: Context) {
		if vc.parent !== host { HostedController.adopt(vc, by: host) }
		layout(host)
	}

	private func layout(_ host: UIViewController) {
		vc.view.autoresizingMask = []
		vc.view.transform = .identity
		vc.view.bounds = CGRect(origin: .zero, size: size)
		vc.view.transform = CGAffineTransform(scaleX: scale, y: scale)
		vc.view.center = CGPoint(x: size.width * scale / 2, y: size.height * scale / 2)
	}
}

/// iPad: превью справа от редактора — пишешь код слева, экран приложения живёт справа.
struct DockedPreview: View {
	@ObservedObject private var host = PreviewHost.shared
	@State private var showLog = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 14) {
				Text(host.project?.lastPathComponent ?? "").font(.subheadline.bold()).lineLimit(1)
				Spacer()
				if host.reloading { ProgressView() } else {
					Button { host.reload() } label: { Image(systemName: "arrow.clockwise") }
				}
				Button { withAnimation { showLog.toggle() } } label: { Image(systemName: showLog ? "terminal.fill" : "terminal") }
				Button { host.docked = false } label: { Image(systemName: "pip.enter") }
				Button { host.expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
				Button { host.close() } label: { Image(systemName: "xmark") }
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(Color(.secondarySystemBackground))
			if let e = host.reloadError {
				Text(e).font(.caption.monospaced()).foregroundStyle(.red).lineLimit(3)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
					.background(Color.red.opacity(0.1))
			}
			if let vc = host.vc { HostedController(vc: vc).id(host.generation) }
			if showLog {
				Divider()
				LogPanel()
			}
		}
	}
}
