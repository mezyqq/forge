import Foundation
#if canImport(Compression)
import Compression
#endif

/// Снимки данных Forge: проекты (Documents без build/) и настройки в одном файле, сжатом LZMA.
/// Делаются перед сменой версии (обновление, откат) и перед восстановлением — так смена версии ничего не стирает.
/// Ключи ИИ и токен GitHub лежат в Keychain, версии Forge их не трогают — в снимок они не входят.
///
/// Файл: "FORGESNAP1\n", u32 длина + JSON (версия, дата, причина), дальше поток LZMA из записей:
/// u8 вид (1 файл, 2 папка, 3 настройки, 0 конец), u32 длина пути, путь, u64 длина данных, данные.
enum Snapshots {
	struct Info: Identifiable, Hashable {
		let url: URL
		let version: String
		let date: Date
		let reason: String   // leave — уход с этой версии, restore — перед восстановлением, manual
		let size: Int
		var id: URL { url }
	}

	struct Failure: LocalizedError {
		let message: String
		var errorDescription: String? { message }
	}

	static let magic = Data("FORGESNAP1\n".utf8)
	/// Настройки, которые не переносятся (служебные для самих снимков).
	static let skipKeys: Set<String> = ["lastRunVersion"]

	static var dir: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
	}

	static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

	/// Что не берём: служебная Inbox, результаты сборки (build/ внутри проекта — их можно пересобрать).
	static func skipped(_ rel: String) -> Bool {
		let parts = rel.split(separator: "/")
		if parts.first == "Inbox" || parts.first == ".Trash" { return true }
		return parts.count >= 2 && parts[1] == "build"
	}

	// MARK: список

	static func list() -> [Info] {
		let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
		return files.filter { $0.pathExtension == "forgesnap" }.compactMap(info).sorted { $0.date > $1.date }
	}

	static func info(_ url: URL) -> Info? {
		guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? h.close() }
		guard let head = try? h.read(upToCount: magic.count + 4), head.count == magic.count + 4, head.prefix(magic.count) == magic else { return nil }
		let n = head.suffix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
		guard n < 65536, let m = try? h.read(upToCount: n),
		      let j = try? JSONSerialization.jsonObject(with: m) as? [String: Any] else { return nil }
		let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		return Info(url: url, version: j["version"] as? String ?? "?", date: Date(timeIntervalSince1970: j["date"] as? Double ?? 0),
		            reason: j["reason"] as? String ?? "", size: size)
	}

	static func delete(_ s: Info) { try? FileManager.default.removeItem(at: s.url) }

	// MARK: создание

	@discardableResult
	static func create(version: String, reason: String, prefs: [String: Any]?, root: URL = documents, into folder: URL = dir) throws -> Info {
		let fm = FileManager.default
		try fm.createDirectory(at: folder, withIntermediateDirectories: true)
		let df = DateFormatter()
		df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
		let now = Date()
		let url = folder.appendingPathComponent("Forge-\(version)-\(df.string(from: now))-\(reason).forgesnap")
		let tmp = url.appendingPathExtension("part")
		fm.createFile(atPath: tmp.path, contents: nil)
		let out = try FileHandle(forWritingTo: tmp)
		do {
			let meta = try JSONSerialization.data(withJSONObject: ["version": version, "date": now.timeIntervalSince1970, "reason": reason])
			try out.write(contentsOf: magic)
			try out.write(contentsOf: le32(UInt32(meta.count)))
			try out.write(contentsOf: meta)
			let w = try Codec(encodeTo: out)
			// файлы и папки
			var items: [(String, Bool)] = []
			if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
				let base = root.standardizedFileURL.path
				while let u = e.nextObject() as? URL {
					let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
					if skipped(rel) {
						if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }
						continue
					}
					let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
					if v?.isSymbolicLink == true { continue }
					items.append((rel, v?.isDirectory ?? false))
				}
			}
			for (rel, isDir) in items {
				if isDir {
					try w.entry(2, rel, Data())
				} else if let d = try? Data(contentsOf: root.appendingPathComponent(rel), options: .alwaysMapped) {
					try w.entry(1, rel, d)
				}
			}
			if let prefs {
				let clean = prefs.filter { !skipKeys.contains($0.key) }
				let d = try PropertyListSerialization.data(fromPropertyList: clean, format: .binary, options: 0)
				try w.entry(3, "preferences.plist", d)
			}
			try w.entry(0, "", Data())
			try w.finish()
			try out.close()
		} catch {
			try? out.close()
			try? fm.removeItem(at: tmp)
			throw error
		}
		try? fm.removeItem(at: url)
		try fm.moveItem(at: tmp, to: url)
		guard let i = info(url) else { throw Failure(message: "snapshot: cannot read back \(url.lastPathComponent)") }
		return i
	}

	// MARK: восстановление

	/// Заменяет содержимое root снимком. Возвращает настройки из снимка (применяет вызывающий). Текущее
	/// состояние перед этим нужно сохранить отдельным снимком — здесь только распаковка.
	static func extract(_ s: Info, into root: URL = documents) throws -> [String: Any]? {
		let fm = FileManager.default
		let tmp = fm.temporaryDirectory.appendingPathComponent("forge-snap-\(UUID().uuidString)")
		defer { try? fm.removeItem(at: tmp) }
		// 1) развернуть поток во временный файл
		let inH = try FileHandle(forReadingFrom: s.url)
		defer { try? inH.close() }
		guard let head = try inH.read(upToCount: magic.count + 4), head.count == magic.count + 4, head.prefix(magic.count) == magic else {
			throw Failure(message: "snapshot: not a Forge snapshot")
		}
		let n = head.suffix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
		_ = try inH.read(upToCount: n)
		fm.createFile(atPath: tmp.path, contents: nil)
		let raw = try FileHandle(forWritingTo: tmp)
		try Codec.decode(inH, to: raw)
		try raw.close()

		// 2) проверить, что поток цел, прежде чем что-то удалять
		let data = try Data(contentsOf: tmp, options: .alwaysMapped)
		var entries: [(UInt8, String, Range<Int>)] = []
		var p = 0
		func need(_ k: Int) throws { if p + k > data.count { throw Failure(message: "snapshot: data is truncated") } }
		while true {
			try need(5)
			let kind = data[p]
			let plen = Int(u32(data, p + 1))
			p += 5
			try need(plen + 8)
			let path = String(decoding: data[p..<(p + plen)], as: UTF8.self)
			p += plen
			let dlen = Int(u64(data, p))
			p += 8
			try need(dlen)
			if kind == 0 { break }
			guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure(message: "snapshot: unsafe path \(path)") }
			entries.append((kind, path, p..<(p + dlen)))
			p += dlen
		}

		// 3) заменить содержимое (Inbox не трогаем)
		for item in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where item != "Inbox" {
			try fm.removeItem(at: root.appendingPathComponent(item))
		}
		var prefs: [String: Any]?
		for (kind, path, r) in entries {
			let u = root.appendingPathComponent(path)
			switch kind {
			case 1:
				try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
				try data[r].write(to: u)
			case 2:
				try fm.createDirectory(at: u, withIntermediateDirectories: true)
			case 3:
				prefs = try PropertyListSerialization.propertyList(from: data[r], format: nil) as? [String: Any]
			default: break
			}
		}
		return prefs
	}

	// MARK: -

	static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
	static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
	static func u32(_ d: Data, _ o: Int) -> UInt32 { d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
	static func u64(_ d: Data, _ o: Int) -> UInt64 { d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) } }

	/// Потоковое сжатие LZMA (на Linux, где нет Compression, — без сжатия: только для проверки формата).
	final class Codec {
		private let out: FileHandle
		private var buffer = Data()
		#if canImport(Compression)
		private let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
		private let cap = 1 << 20
		private let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
		#endif

		init(encodeTo out: FileHandle) throws {
			self.out = out
			#if canImport(Compression)
			guard compression_stream_init(s, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
				throw Failure(message: "snapshot: lzma init failed")
			}
			#endif
		}

		deinit {
			#if canImport(Compression)
			compression_stream_destroy(s)
			s.deallocate()
			dst.deallocate()
			#endif
		}

		func entry(_ kind: UInt8, _ path: String, _ data: Data) throws {
			let p = Data(path.utf8)
			var head = Data([kind])
			head += Snapshots.le32(UInt32(p.count)) + p + Snapshots.le64(UInt64(data.count))
			try write(head)
			// большие файлы — кусками, чтобы не копировать их целиком в буфер
			var off = 0
			while off < data.count {
				let end = min(data.count, off + (4 << 20))
				try write(data[off..<end])
				off = end
			}
		}

		private func write(_ d: Data) throws {
			buffer += d
			if buffer.count >= 1 << 20 { try flush(final: false) }
		}

		func finish() throws { try flush(final: true) }

		private func flush(final: Bool) throws {
			#if canImport(Compression)
			let chunk = buffer
			buffer = Data()
			try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
				s.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
				s.pointee.src_size = raw.count
				while true {
					s.pointee.dst_ptr = dst
					s.pointee.dst_size = cap
					let st = compression_stream_process(s, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
					guard st != COMPRESSION_STATUS_ERROR else { throw Failure(message: "snapshot: lzma error") }
					let got = cap - s.pointee.dst_size
					if got > 0 { try out.write(contentsOf: Data(bytes: dst, count: got)) }
					if st == COMPRESSION_STATUS_END { break }
					if !final && s.pointee.src_size == 0 && got < cap { break }
				}
			}
			#else
			try out.write(contentsOf: buffer)
			buffer = Data()
			#endif
		}

		/// Поток (с текущей позиции input) → распакованные данные в output.
		static func decode(_ input: FileHandle, to output: FileHandle) throws {
			#if canImport(Compression)
			let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
			defer { s.deallocate() }
			guard compression_stream_init(s, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
				throw Failure(message: "snapshot: lzma init failed")
			}
			defer { compression_stream_destroy(s) }
			let cap = 1 << 20
			let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
			defer { dst.deallocate() }
			var ended = false
			while !ended {
				let chunk = try input.read(upToCount: 1 << 20) ?? Data()
				let last = chunk.isEmpty
				try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
					s.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
					s.pointee.src_size = raw.count
					repeat {
						s.pointee.dst_ptr = dst
						s.pointee.dst_size = cap
						let st = compression_stream_process(s, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
						guard st != COMPRESSION_STATUS_ERROR else { throw Failure(message: "snapshot: data is corrupt") }
						let got = cap - s.pointee.dst_size
						if got > 0 { try output.write(contentsOf: Data(bytes: dst, count: got)) }
						if st == COMPRESSION_STATUS_END { ended = true; break }
						if last && got == 0 { throw Failure(message: "snapshot: data is truncated") }
					} while s.pointee.src_size > 0 || s.pointee.dst_size == 0
				}
			}
			#else
			while let d = try input.read(upToCount: 1 << 20), !d.isEmpty { try output.write(contentsOf: d) }
			#endif
		}
	}
}

// MARK: приложение

extension Snapshots {
	/// Сколько снимков хранить (старые удаляются).
	static let keep = 10

	/// Настройки Forge (UserDefaults приложения).
	static var currentPrefs: [String: Any]? {
		UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
	}

	static func applyPrefs(_ p: [String: Any]) {
		let d = UserDefaults.standard
		for k in (currentPrefs ?? [:]).keys where !skipKeys.contains(k) { d.removeObject(forKey: k) }
		for (k, v) in p where !skipKeys.contains(k) { d.set(v, forKey: k) }
	}

	/// Снимок текущих данных (в фоне).
	@discardableResult
	static func take(reason: String) async throws -> Info {
		let v = Updater.current, prefs = currentPrefs
		let i = try await Task.detached(priority: .userInitiated) { try create(version: v, reason: reason, prefs: prefs) }.value
		for old in list().dropFirst(keep) { delete(old) }
		return i
	}

	/// Восстановить снимок; текущее состояние сначала сохраняется отдельным снимком.
	static func restore(_ s: Info) async throws {
		try await take(reason: "restore")
		let prefs = try await Task.detached(priority: .userInitiated) { try extract(s) }.value
		if let prefs { applyPrefs(prefs) }
	}

	/// Снимок, который стоит предложить при запуске: Forge вернулся на более новую версию, с которой раньше уходил.
	static var pendingRestore: Info?

	static func checkVersionChange() {
		let d = UserDefaults.standard
		let cur = Updater.current, last = d.string(forKey: "lastRunVersion")
		d.set(cur, forKey: "lastRunVersion")
		guard let last, last != cur, Updater.newer(cur, than: last) else { return }
		pendingRestore = list().first { $0.version == cur && $0.reason == "leave" }
	}

	static func reasonText(_ r: String) -> String {
		switch r {
		case "leave": return L("before switching version")
		case "restore": return L("before restoring")
		default: return L("manual")
		}
	}
}
