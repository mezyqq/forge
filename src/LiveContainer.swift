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
