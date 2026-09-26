import Foundation
import Network
import UIKit

/// Установка собранного .ipa в LiveContainer одной кнопкой: .ipa отдаётся локальным HTTP-сервером
/// на 127.0.0.1, LiveContainer скачивает его по ссылке livecontainer://install?url=…
enum LiveContainer {
	private static var server: FileServer?

	/// Открыть установку; false — LiveContainer не установлен (или не открылся).
	@MainActor
	static func install(_ ipa: URL) async -> Bool {
		server?.stop()
		guard let s = try? FileServer(file: ipa), let port = await s.start() else { return false }
		server = s
		let file = ipa.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "app.ipa"
		var c = URLComponents(string: "livecontainer://install")!
		c.queryItems = [URLQueryItem(name: "url", value: "http://127.0.0.1:\(port)/\(file)")]
		let ok = await UIApplication.shared.open(c.url!)
		if !ok { s.stop(); server = nil }
		return ok
	}

	/// Запустить установленное приложение по BUNDLE_ID.
	@MainActor
	static func launch(bundleID: String) async -> Bool {
		var c = URLComponents(string: "livecontainer://livecontainer-launch")!
		c.queryItems = [URLQueryItem(name: "bundle-name", value: bundleID)]
		return await UIApplication.shared.open(c.url!)
	}
}

/// Минимальный HTTP-сервер для одного файла: любой GET получает его целиком. Сам выключается через 10 минут.
final class FileServer {
	private let file: URL
	private let listener: NWListener
	private let queue = DispatchQueue(label: "forge.fileserver")

	init(file: URL) throws {
		self.file = file
		let params = NWParameters.tcp
		params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
		listener = try NWListener(using: params)
	}

	/// Запускает сервер, возвращает порт.
	func start() async -> UInt16? {
		listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
		let l = listener
		let port: UInt16? = await withCheckedContinuation { cont in
			// обработчик зовётся на нашей последовательной очереди — после первого ответа снимаем его
			l.stateUpdateHandler = { st in
				switch st {
				case .ready: l.stateUpdateHandler = nil; cont.resume(returning: l.port?.rawValue)
				case .failed, .cancelled: l.stateUpdateHandler = nil; cont.resume(returning: nil)
				default: break
				}
			}
			l.start(queue: queue)
		}
		queue.asyncAfter(deadline: .now() + 600) { l.cancel() }
		return port
	}

	func stop() { listener.cancel() }

	private func serve(_ c: NWConnection) {
		c.start(queue: queue)
		// запрос не разбираем: ждём конец заголовков и отдаём файл
		c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [file] _, _, _, _ in
			guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
				c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
				       completion: .contentProcessed { _ in c.cancel() })
				return
			}
			let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(data.count)\r\n"
				+ "Content-Disposition: attachment; filename=\"\(file.lastPathComponent)\"\r\nConnection: close\r\n\r\n"
			c.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
		}
	}
}

// MARK: изнутри LiveContainer

/// Когда Forge сам запущен в LiveContainer, ссылку livecontainer://install LiveContainer не выполняет
/// («перезапустите для установки»). Зато его папка приложений доступна на запись: кладём .app туда сами,
/// а подпись и патч LiveContainer сделает при запуске приложения из своего списка.
extension LiveContainer {
	/// Forge запущен внутри LiveContainer (его классы есть в процессе).
	static var hosting: Bool { NSClassFromString("LCSharedUtils") != nil }

	/// Папка приложений LiveContainer, в которой лежит сам Forge.
	static var appsFolder: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

	/// .ipa → <папка приложений>/<bundle id>.app. Возвращает bundle id.
	static func installInside(_ ipa: URL, progress: ((Double) -> Void)? = nil) async throws -> String {
		let fm = FileManager.default
		let work = fm.temporaryDirectory.appendingPathComponent("forge-install-\(UUID().uuidString)")
		defer { try? fm.removeItem(at: work) }
		try await Task.detached(priority: .userInitiated) { try Unzip.unpack(ipa, to: work, progress: progress) }.value
		let app = try appInPayload(work.appendingPathComponent("Payload"))
		guard let bid = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String else {
			throw Unzip.Failure(message: L("The .app has no CFBundleIdentifier"))
		}
		guard bid != Bundle.main.bundleIdentifier else {
			throw Unzip.Failure(message: L("This is Forge itself — update Forge in Settings → Updates."))
		}
		try place(app, at: appsFolder.appendingPathComponent(bid + ".app"), trash: work.appendingPathComponent("old.app"))
		return bid
	}

	static func appInPayload(_ payload: URL) throws -> URL {
		guard let name = try FileManager.default.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
			throw Unzip.Failure(message: L("No .app inside the .ipa"))
		}
		return payload.appendingPathComponent(name)
	}

	/// Поставить new на место dest. Если dest уже есть — переносим служебные файлы LiveContainer (LCAppInfo.plist
	/// связывает приложение с его контейнером данных) и bundle id, сбрасываем LCPatchRevision (LiveContainer заново
	/// пропатчит и подпишет при запуске), старый бандл уезжает в trash — переименованием, работающий процесс не страдает.
	static func place(_ new: URL, at dest: URL, trash: URL) throws {
		let fm = FileManager.default
		guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
			throw Unzip.Failure(message: L("LiveContainer's app folder is not writable."))
		}
		if fm.fileExists(atPath: dest.path) {
			for f in ["LCAppInfo.plist", "embedded.mobileprovision"] {
				let src = dest.appendingPathComponent(f), dst = new.appendingPathComponent(f)
				if fm.fileExists(atPath: src.path) {
					try? fm.removeItem(at: dst)
					try fm.copyItem(at: src, to: dst)
				}
			}
			let infoURL = new.appendingPathComponent("Info.plist")
			if let old = NSDictionary(contentsOf: dest.appendingPathComponent("Info.plist")),
			   let info = NSMutableDictionary(contentsOf: infoURL), let bid = old["CFBundleIdentifier"] {
				info["CFBundleIdentifier"] = bid
				try info.write(to: infoURL)
			}
			let lcInfo = new.appendingPathComponent("LCAppInfo.plist")
			if let info = NSMutableDictionary(contentsOf: lcInfo) {
				info["LCPatchRevision"] = -1
				try info.write(to: lcInfo)
			}
			try fm.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? fm.removeItem(at: trash)
			do { try fm.moveItem(at: dest, to: trash) } catch {
				throw Unzip.Failure(message: L("Could not move the current app: %@", error.localizedDescription))
			}
			do { try fm.moveItem(at: new, to: dest) } catch {
				try? fm.moveItem(at: trash, to: dest)
				throw Unzip.Failure(message: L("Could not install the new version: %@", error.localizedDescription))
			}
		} else {
			try fm.moveItem(at: new, to: dest)
		}
	}

	/// Закрыть Forge и открыть список приложений LiveContainer (оттуда запуск с патчем и подписью).
	@MainActor
	static func openHostUI() {
		let url = URL(string: "\(hostScheme)://livecontainer-launch?bundle-name=ui")!
		// LCSharedUtils.launchToGuestAppWithURL: — то же, что делает LiveContainer после вопроса «Переключиться?»
		let sel = NSSelectorFromString("launchToGuestAppWithURL:")
		if let cls = NSClassFromString("LCSharedUtils"), let m = class_getClassMethod(cls, sel) {
			typealias Fn = @convention(c) (AnyClass, Selector, NSURL) -> Bool
			let f = unsafeBitCast(method_getImplementation(m), to: Fn.self)
			if f(cls, sel, url as NSURL) { return }
		}
		UIApplication.shared.open(url)
	}

	/// Схема URL этого экземпляра LiveContainer (livecontainer, livecontainer2…).
	static var hostScheme: String {
		let sel = NSSelectorFromString("lcAppUrlScheme")
		if let m = class_getClassMethod(UserDefaults.self, sel) {
			typealias Fn = @convention(c) (AnyClass, Selector) -> NSString?
			let f = unsafeBitCast(method_getImplementation(m), to: Fn.self)
			if let s = f(UserDefaults.self, sel) as String?, !s.isEmpty { return s }
		}
		return "livecontainer"
	}
}
