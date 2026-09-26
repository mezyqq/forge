import Foundation
import Compression

/// Минимальный zip-писатель для .ipa: deflate через Compression (COMPRESSION_ZLIB — это «сырой» deflate,
/// как раз метод 8 в zip), unix-права сохраняются — исполняемому файлу в .app нужен 0755.
enum Zip {
	/// Пакует `dir` целиком: пути в архиве начинаются с имени папки (Payload/…).
	static func pack(_ dir: URL, to dst: URL) throws {
		let fm = FileManager.default
		let base = dir.deletingLastPathComponent().standardizedFileURL.path
		var entries: [(name: String, url: URL, isDir: Bool)] = [(dir.lastPathComponent + "/", dir, true)]
		let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
		while let u = e?.nextObject() as? URL {
			let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
			var rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
			if isDir { rel += "/" }
			entries.append((rel, u, isDir))
		}

		var out = Data(), central = Data()
		let (time, date) = dosTime(Date())
		for en in entries {
			let name = Data(en.name.utf8)
			let attrs = try fm.attributesOfItem(atPath: en.url.path)
			let perm = (attrs[.posixPermissions] as? Int) ?? 0o644
			let mode = UInt32(en.isDir ? 0o040000 | 0o755 : 0o100000 | perm)
			let raw = en.isDir ? Data() : try Data(contentsOf: en.url)
			let crc = crc32(raw)
			var method: UInt16 = 0, body = raw
			if raw.count > 64, let d = deflate(raw), d.count < raw.count { method = 8; body = d }
			let offset = UInt32(out.count)

			out.le32(0x04034b50); out.le16(20); out.le16(0x0800); out.le16(method)
			out.le16(time); out.le16(date); out.le32(crc)
			out.le32(UInt32(body.count)); out.le32(UInt32(raw.count))
			out.le16(UInt16(name.count)); out.le16(0)
			out.append(name); out.append(body)

			central.le32(0x02014b50); central.le16(3 << 8 | 20); central.le16(20); central.le16(0x0800); central.le16(method)
			central.le16(time); central.le16(date); central.le32(crc)
			central.le32(UInt32(body.count)); central.le32(UInt32(raw.count))
			central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
			central.le32(mode << 16 | (en.isDir ? 0x10 : 0)); central.le32(offset)
			central.append(name)
		}
		let cdOffset = UInt32(out.count)
		out.append(central)
		out.le32(0x06054b50); out.le16(0); out.le16(0)
		out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
		out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
		try out.write(to: dst, options: .atomic)
	}

	private static func deflate(_ src: Data) -> Data? {
		let cap = src.count + src.count / 16 + 1024
		var dst = Data(count: cap)
		let n = dst.withUnsafeMutableBytes { d in
			src.withUnsafeBytes { s in
				compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
				                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard n > 0 else { return nil }
		return dst.prefix(n)
	}

	private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
		var c = UInt32(i)
		for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
		return c
	}

	static func crc32(_ data: Data) -> UInt32 {
		var c: UInt32 = 0xFFFFFFFF
		data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
			for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
		}
		return c ^ 0xFFFFFFFF
	}

	private static func dosTime(_ d: Date) -> (UInt16, UInt16) {
		let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
		let t = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
		let dt = max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
		return (UInt16(t), UInt16(dt))
	}
}

private extension Data {
	mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
	mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
