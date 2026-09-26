import Foundation
#if canImport(Compression)
import Compression
#endif

/// Распаковка zip (.ipa обновления): методы stored и deflate, unix-права из архива.
/// Архив читается через mmap, большие файлы распаковываются потоково — память не растёт с размером .ipa.
enum Unzip {
	struct Failure: LocalizedError {
		let message: String
		var errorDescription: String? { message }
	}

	static func unpack(_ zip: URL, to dir: URL, progress: ((Double) -> Void)? = nil) throws {
		let fm = FileManager.default
		let data = try Data(contentsOf: zip, options: .alwaysMapped)
		let n = data.count
		func u16(_ o: Int) -> Int { data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in Int(b[o]) | Int(b[o + 1]) << 8 } }
		func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
		func bad(_ what: String) -> Failure { Failure(message: "zip: " + what) }

		// конец центрального каталога — в последних 64 КБ
		guard n >= 22 else { throw bad("file is too small") }
		var e = n - 22
		while e > max(0, n - 22 - 65535), u32(e) != 0x06054b50 { e -= 1 }
		guard u32(e) == 0x06054b50 else { throw bad("no end of central directory") }
		let count = u16(e + 10)
		var p = u32(e + 16)
		let root = dir.standardizedFileURL.path

		for i in 0..<count {
			guard p + 46 <= n, u32(p) == 0x02014b50 else { throw bad("broken central directory") }
			let method = u16(p + 10), csize = u32(p + 20), nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32)
			let attrs = u32(p + 38), local = u32(p + 42)
			let name = String(decoding: data[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
			p += 46 + nlen + xlen + clen

			let dst = dir.appendingPathComponent(name)
			// защита от «../» и абсолютных путей в архиве
			guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
			      dst.standardizedFileURL.path.hasPrefix(root) else { throw bad("unsafe path \(name)") }
			if name.hasSuffix("/") {
				try fm.createDirectory(at: dst, withIntermediateDirectories: true)
				continue
			}
			try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
			guard local + 30 <= n, u32(local) == 0x04034b50 else { throw bad("broken local header of \(name)") }
			let start = local + 30 + u16(local + 26) + u16(local + 28)
			guard start + csize <= n else { throw bad("\(name) is truncated") }
			let body = data[start..<(start + csize)]
			switch method {
			case 0: try body.write(to: dst)
			case 8: try inflate(body, to: dst)
			default: throw bad("unsupported method \(method) for \(name)")
			}
			let mode = (attrs >> 16) & 0o777
			if mode != 0 { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dst.path) }
			progress?(Double(i + 1) / Double(count))
		}
	}

	/// Сырой deflate (zip метод 8) → файл, кусками по 1 МБ.
	private static func inflate(_ src: Data, to dst: URL) throws {
		#if canImport(Compression)
		FileManager.default.createFile(atPath: dst.path, contents: nil)
		let h = try FileHandle(forWritingTo: dst)
		defer { try? h.close() }
		let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
		defer { s.deallocate() }
		guard compression_stream_init(s, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
			throw Failure(message: "zip: inflate init failed")
		}
		defer { compression_stream_destroy(s) }
		let cap = 1 << 20
		let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
		defer { buf.deallocate() }
		try src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
			s.pointee.src_ptr = base
			s.pointee.src_size = raw.count
			while true {
				s.pointee.dst_ptr = buf
				s.pointee.dst_size = cap
				let st = compression_stream_process(s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
				guard st != COMPRESSION_STATUS_ERROR else { throw Failure(message: "zip: corrupt data in \(dst.lastPathComponent)") }
				let got = cap - s.pointee.dst_size
				if got > 0 { try h.write(contentsOf: Data(bytes: buf, count: got)) }
				if st == COMPRESSION_STATUS_END || (got == 0 && s.pointee.src_size == 0) { break }
			}
		}
		#else
		throw Failure(message: "zip: deflate is not supported here")
		#endif
	}
}
