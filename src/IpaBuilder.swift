import Foundation

/// Сборка iOS-приложения (C / ObjC / C++) в .ipa прямо на телефоне: встроенные clang и lld (ios-compiler),
/// SDK и заголовки — в бандле Forge (toolchain/). Повторяет ipab: те же ipa.conf, src/, res/, Info.plist,
/// результат в build/<NAME>.ipa. Инкрементально: пересобираются изменённые файлы и зависящие от изменённых
/// заголовков (depfile от clang). Работает на потоке Runner — весь вывод идёт в его консоль.
enum IpaBuilder {
	static var toolchain: URL { Bundle.main.bundleURL.appendingPathComponent("toolchain") }

	/// Встроен ли компилятор в эту сборку Forge.
	static var available: Bool {
		#if FORGE_COMPILER
		return FileManager.default.fileExists(atPath: toolchain.appendingPathComponent("sdk").path)
		#else
		return false
		#endif
	}

	/// Выставляется кнопкой «Стоп»: сборка остановится перед следующим файлом.
	static var cancel = false

	struct Failure: Error { let message: String }

	/// Путь к готовому .ipa последней успешной сборки (для «Поделиться»).
	static func ipaURL(_ project: URL) -> URL? {
		let name = Conf.get((try? String(contentsOf: project.appendingPathComponent("ipa.conf"), encoding: .utf8)) ?? "", "NAME")
		let u = project.appendingPathComponent("build/\(name).ipa")
		return FileManager.default.fileExists(atPath: u.path) ? u : nil
	}

	/// Точка входа для Runner: 0 — успех.
	static func run(_ project: URL, release: Bool) -> Int32 {
		cancel = false
		do {
			let t0 = Date()
			let ipa = try build(project, release: release)
			let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? 0
			print(L("==> done: build/%@ (%@, %@ s)", ipa.lastPathComponent, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), String(format: "%.1f", Date().timeIntervalSince(t0))))
			return 0
		} catch let f as Failure {
			fputs(L("error: %@\n", f.message), stderr)
			return 1
		} catch {
			fputs(L("error: %@\n", error.localizedDescription), stderr)
			return 1
		}
	}

	// MARK: -

	/// ipa.conf проекта. Это bash; поддерживаем KEY="value" и подстановку $PROJ / $NAME.
	struct Config {
		let text: String
		let proj: URL
		private(set) var name = ""

		init(_ proj: URL) throws {
			self.proj = proj
			text = try String(contentsOf: proj.appendingPathComponent("ipa.conf"), encoding: .utf8)
			name = Conf.get(text, "NAME")
			guard !name.isEmpty else { throw Failure(message: L("NAME is empty in ipa.conf")) }
			name = value("NAME")
		}

		func value(_ k: String, _ def: String = "") -> String {
			let v = Conf.get(text, k)
			if v.isEmpty { return def }
			return v.replacingOccurrences(of: "${PROJ}", with: proj.path).replacingOccurrences(of: "$PROJ", with: proj.path)
				.replacingOccurrences(of: "${NAME}", with: name).replacingOccurrences(of: "$NAME", with: name)
		}

		func words(_ k: String) -> [String] { value(k).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
	}

	static let sourceExts = ["c", "m", "mm", "cpp", "cc", "cxx"]
	static let cxxExts = ["mm", "cpp", "cc", "cxx"]

	static var clangPath: String { toolchain.appendingPathComponent("bin/clang").path }
	static var sdkPath: String { toolchain.appendingPathComponent("sdk").path }

	/// Общие флаги clang для файлов проекта: сборка, проверка в редакторе, JIT. cfg == nil — не iOS-проект (скрипт).
	static func baseFlags(_ proj: URL, _ cfg: Config?, optimize: String = "-O0") -> [String] {
		let modCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("forge-clang-modules").path
		let minIOS = cfg?.value("MIN_IOS", "15.0") ?? "16.0"
		return ["-target", "arm64-apple-ios\(minIOS)", "-isysroot", sdkPath, optimize,
		        "-fmodules", "-fmodules-cache-path=\(modCache)", "-I\(proj.appendingPathComponent("src").path)"] + (cfg?.words("CFLAGS") ?? [])
	}

	/// Язык по расширению; заголовки — как ObjC (или ObjC++ для .hpp).
	static func langFlags(_ ext: String) -> [String] {
		switch ext.lowercased() {
		case "c": return ["-std=gnu17"]
		case "m": return ["-fobjc-arc"]
		case "mm": return ["-fobjc-arc", "-std=gnu++20"]
		case "h": return ["-x", "objective-c", "-fobjc-arc"]
		case "hpp", "hh", "hxx": return ["-x", "objective-c++", "-fobjc-arc", "-std=gnu++20"]
		default: return ["-std=gnu++20"]
		}
	}

	/// Исходники C-семейства в src/ (пути относительно src/).
	static func sources(_ proj: URL) -> [String] {
		var files: [String] = []
		if let e = FileManager.default.enumerator(atPath: proj.appendingPathComponent("src").path) {
			while let p = e.nextObject() as? String { files.append(p) }
		}
		return files.sorted()
	}

	/// Компиляция src/ в obj/ инкрементально (depfile + штамп флагов). Возвращает .o и сколько файлов пересобрано.
	private static func compile(_ proj: URL, _ sources: [String], into obj: URL, base: [String]) throws -> (objects: [String], compiled: Int) {
		#if FORGE_COMPILER
		let fm = FileManager.default
		let src = proj.appendingPathComponent("src")
		try fm.createDirectory(at: obj, withIntermediateDirectories: true)
		let stamp = obj.appendingPathComponent("cflags.stamp")
		let flagsLine = ([sdkVersion(sdkPath)] + base).joined(separator: " ")
		let flagsChanged = (try? String(contentsOf: stamp, encoding: .utf8)) != flagsLine
		var objects: [String] = []
		var compiled = 0
		for f in sources {
			if cancel { throw Failure(message: L("stopped")) }
			let o = obj.appendingPathComponent(f + ".o").path, d = obj.appendingPathComponent(f + ".d").path
			objects.append(o)
			if !flagsChanged && upToDate(o, depfile: d) { continue }
			try fm.createDirectory(atPath: (o as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
			print("  CC     \(f)")
			let args = [clangPath] + base + langFlags((f as NSString).pathExtension) + ["-MMD", "-MF", d, "-c", src.appendingPathComponent(f).path, "-o", o]
			guard cc(args) == 0 else {
				try? fm.removeItem(atPath: o)
				throw Failure(message: L("compiling %@ failed", f))
			}
			compiled += 1
		}
		try flagsLine.write(to: stamp, atomically: true, encoding: .utf8)

		// рантайм для @available (как cache/rt у ipab)
		let rt = obj.appendingPathComponent("availability.o").path
		if !fm.fileExists(atPath: rt) {
			let rtSrc = toolchain.appendingPathComponent("rt/availability.c").path
			guard cc([clangPath, "-target", "arm64-apple-ios12.0", "-isysroot", sdkPath, "-O2", "-c", rtSrc, "-o", rt]) == 0 else {
				throw Failure(message: L("availability.c failed to compile"))
			}
		}
		return (objects + [rt], compiled)
		#else
		throw Failure(message: L("this Forge build has no compiler"))
		#endif
	}

	/// Объектные файлы проекта для JIT (build/forge/jit). Вызывается на потоке Runner.
	static func jitObjects(_ proj: URL) throws -> (objects: [String], frameworks: [String]) {
		guard available else { throw Failure(message: L("this Forge build has no compiler")) }
		let cfg = try? Config(proj)
		let sources = Self.sources(proj).filter { sourceExts.contains(($0 as NSString).pathExtension.lowercased()) }
		guard !sources.isEmpty else { throw Failure(message: L("no .c .m .mm .cpp files in src/")) }
		print(L("==> compiling %@ for a quick run", proj.lastPathComponent))
		let r = try compile(proj, sources, into: proj.appendingPathComponent("build/forge/jit"), base: baseFlags(proj, cfg) + ["-g"])
		ignoreBuildInGit(proj)
		return (r.objects, cfg?.words("FRAMEWORKS") ?? [])
	}

	private static func build(_ proj: URL, release: Bool) throws -> URL {
		#if FORGE_COMPILER
		let fm = FileManager.default
		let sdk = sdkPath
		guard available else { throw Failure(message: L("this Forge build has no compiler")) }
		let cfg = try Config(proj)
		let confText = cfg.text, name = cfg.name
		func conf(_ k: String, _ d: String = "") -> String { cfg.value(k, d) }
		let words = cfg.words
		let bundleID = conf("BUNDLE_ID", "")
		guard !bundleID.isEmpty else { throw Failure(message: L("BUNDLE_ID is empty in ipa.conf")) }
		var version = conf("VERSION", "1.0"), buildNo = conf("BUILD", "1")
		if release { (version, buildNo) = bumped(version, buildNo) }
		let minIOS = conf("MIN_IOS", "15.0")
		if !conf("ENTITLEMENTS", "").isEmpty { print(L("warning: ENTITLEMENTS are not embedded on the phone (ad-hoc signature without them)")) }

		// исходники
		let files = sources(proj)
		if files.contains(where: { $0.hasSuffix(".swift") }) {
			throw Failure(message: L("the project has .swift files — Swift is not compiled on the phone. Build it with ipab on a computer or rewrite it in ObjC/C."))
		}
		let sources = files.filter { sourceExts.contains(($0 as NSString).pathExtension.lowercased()) }
		guard !sources.isEmpty else { throw Failure(message: L("no .c .m .mm .cpp files in src/")) }
		let hasCxx = sources.contains { cxxExts.contains(($0 as NSString).pathExtension.lowercased()) }

		let mode = release ? "release" : "debug"
		let B = proj.appendingPathComponent("build")
		let obj = B.appendingPathComponent("forge/\(mode)")
		ignoreBuildInGit(proj)
		let sdkVer = sdkVersion(sdk)

		print(L("==> building %@ (%@, clang %@)", name, mode, String(cString: ioscc_version())))
		let (objects, compiled) = try compile(proj, sources, into: obj, base: baseFlags(proj, cfg, optimize: release ? "-Os" : "-O0"))

		// линковка
		let exe = obj.appendingPathComponent(name).path
		let exeDate = mtime(exe)
		let needLink = compiled > 0 || exeDate == nil || objects.contains { (mtime($0) ?? .distantFuture) > exeDate! }
			|| (try? String(contentsOf: obj.appendingPathComponent("ldflags.stamp"), encoding: .utf8)) != confText
		if needLink {
			if cancel { throw Failure(message: L("stopped")) }
			print("  LD     \(name)")
			var ld = ["ld", "-arch", "arm64", "-platform_version", "ios", minIOS, sdkVer, "-syslibroot", sdk,
			          "-adhoc_codesign", "-rpath", "@executable_path/Frameworks", "-o", exe]
			if release { ld += ["-dead_strip", "-x"] }
			ld += objects
			for fw in words("FRAMEWORKS") { ld += ["-framework", fw] }
			for l in words("LIBS") { ld.append("-l" + l) }
			ld += ldFlags(words("LDFLAGS"))
			if hasCxx { ld.append("-lc++") }
			ld += ["-lobjc", "-lSystem"]
			guard link(ld) == 0 else { throw Failure(message: L("linking failed")) }
			try confText.write(to: obj.appendingPathComponent("ldflags.stamp"), atomically: true, encoding: .utf8)
		}

		// .app
		let payload = B.appendingPathComponent("Payload")
		try? fm.removeItem(at: payload)
		let app = payload.appendingPathComponent("\(name).app")
		try fm.createDirectory(at: app, withIntermediateDirectories: true)
		try fm.copyItem(atPath: exe, toPath: app.appendingPathComponent(name).path)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent(name).path)
		let plist = try infoPlist(proj, name: name, bundleID: bundleID, version: version, build: buildNo,
		                          minIOS: minIOS, sdkVer: sdkVer, display: conf("DISPLAY_NAME", name), hasIcon: !conf("ICON").isEmpty)
		try plist.write(to: app.appendingPathComponent("Info.plist"))
		try Data("APPL????".utf8).write(to: app.appendingPathComponent("PkgInfo"))
		let res = proj.appendingPathComponent("res")
		for item in (try? fm.contentsOfDirectory(atPath: res.path)) ?? [] {
			try fm.copyItem(at: res.appendingPathComponent(item), to: app.appendingPathComponent(item))
		}
		for x in words("EXTRA_RES") {
			let s = proj.appendingPathComponent(x)
			guard fm.fileExists(atPath: s.path) else { throw Failure(message: L("missing %@ (EXTRA_RES)", x)) }
			try fm.copyItem(at: s, to: app.appendingPathComponent(s.lastPathComponent))
		}
		let icon = conf("ICON")
		if !icon.isEmpty {
			let s = proj.appendingPathComponent(icon)
			guard fm.fileExists(atPath: s.path) else { throw Failure(message: L("missing icon %@", icon)) }
			for n in ["AppIcon60x60@2x", "AppIcon60x60@3x", "AppIcon76x76@2x"] {
				try? fm.removeItem(at: app.appendingPathComponent(n + ".png"))
				try fm.copyItem(at: s, to: app.appendingPathComponent(n + ".png"))
			}
		}

		// .ipa
		let ipa = B.appendingPathComponent("\(name).ipa")
		try Zip.pack(payload, to: ipa)
		if release {
			var t = Conf.set(confText, "VERSION", version)
			t = Conf.set(t, "BUILD", buildNo)
			try t.write(to: proj.appendingPathComponent("ipa.conf"), atomically: true, encoding: .utf8)
			print(L("==> release %@ (build %@) — saved to ipa.conf", version, buildNo))
		}
		return ipa
		#else
		throw Failure(message: L("this Forge build has no compiler"))
		#endif
	}

	#if FORGE_COMPILER
	static func withArgv<T>(_ args: [String], _ body: (Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> T) -> T {
		let c = args.map { UnsafePointer<CChar>(strdup($0)!) }
		defer { c.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
		var argv: [UnsafePointer<CChar>?] = c
		return argv.withUnsafeMutableBufferPointer { body(Int32(args.count), $0.baseAddress!) }
	}

	private static func cc(_ args: [String]) -> Int32 {
		Clang.lock.lock()
		defer { Clang.lock.unlock() }
		let r = withArgv(args) { ioscc_cc($0, $1) }
		fflush(stdout); fflush(stderr)
		return r
	}

	private static func link(_ args: [String]) -> Int32 {
		Clang.lock.lock()
		defer { Clang.lock.unlock() }
		let r = withArgv(args) { ioscc_ld($0, $1) }
		fflush(stdout); fflush(stderr)
		return r
	}
	#endif

	/// Флаги в стиле clang (LDFLAGS у ipab) → аргументы ld64: -Wl,a,b → a b; -L/-l/-F/-framework как есть.
	static func ldFlags(_ w: [String]) -> [String] {
		var out: [String] = [], i = 0
		while i < w.count {
			let a = w[i]
			if a.hasPrefix("-Wl,") {
				out += a.dropFirst(4).split(separator: ",").map(String.init)
			} else if a == "-framework" || a == "-weak_framework", i + 1 < w.count {
				out += [a, w[i + 1]]; i += 1
			} else if a.hasPrefix("-L") || a.hasPrefix("-l") || a.hasPrefix("-F") || a.hasSuffix(".a") || a.hasSuffix(".o") {
				out.append(a)
			} else {
				print(L("warning: LDFLAGS %@ skipped (on the phone ld64 links directly)", a))
			}
			i += 1
		}
		return out
	}

	/// .o новее исходника и всех заголовков из depfile.
	static func upToDate(_ o: String, depfile: String) -> Bool {
		guard let od = mtime(o), let text = try? String(contentsOfFile: depfile, encoding: .utf8) else { return false }
		// «obj.o: a.c b.h \⏎ c.h»; пробелы в путях экранированы «\ »
		let body = text.replacingOccurrences(of: "\\\n", with: " ").components(separatedBy: "\n").first ?? ""
		guard let colon = body.range(of: ": ") else { return false }
		let deps = body[colon.upperBound...].replacingOccurrences(of: "\\ ", with: "\u{1}")
			.split(separator: " ").map { $0.replacingOccurrences(of: "\u{1}", with: " ") }
		for d in deps where !d.isEmpty {
			guard let dd = mtime(d), dd <= od else { return false }
		}
		return true
	}

	static func mtime(_ path: String) -> Date? {
		(try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
	}

	/// Как ipab --release: последнее число версии +1, BUILD +1.
	static func bumped(_ version: String, _ build: String) -> (String, String) {
		var v = version
		if let r = v.range(of: "[0-9]+$", options: .regularExpression), let n = Int(v[r]) { v.replaceSubrange(r, with: String(n + 1)) }
		return (v, Int(build).map { String($0 + 1) } ?? build)
	}

	static func sdkVersion(_ sdk: String) -> String {
		if let d = FileManager.default.contents(atPath: sdk + "/SDKSettings.json"),
		   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let v = j["Version"] as? String { return v }
		return "26.5"
	}

	/// build/ не должен уезжать в git при синхронизации.
	static func ignoreBuildInGit(_ proj: URL) {
		let gi = proj.appendingPathComponent(".gitignore")
		let text = (try? String(contentsOf: gi, encoding: .utf8)) ?? ""
		let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
		if lines.contains(where: { ["build", "build/", "/build", "/build/"].contains($0) }) { return }
		let add = (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "build/\n"
		try? (text + add).write(to: gi, atomically: true, encoding: .utf8)
	}

	/// Info.plist как у ipab: свой Info.plist проекта или сгенерированный + Info.extra.plist.
	static func infoPlist(_ proj: URL, name: String, bundleID: String, version: String, build: String,
	                      minIOS: String, sdkVer: String, display: String, hasIcon: Bool) throws -> Data {
		if let own = FileManager.default.contents(atPath: proj.appendingPathComponent("Info.plist").path) { return own }
		func esc(_ s: String) -> String {
			s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
		}
		let icon = hasIcon ? """
			<key>CFBundleIcons</key>
			<dict><key>CFBundlePrimaryIcon</key><dict>
				<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
				<key>CFBundleIconName</key><string>AppIcon</string>
			</dict></dict>
			<key>CFBundleIcons~ipad</key>
			<dict><key>CFBundlePrimaryIcon</key><dict>
				<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string><string>AppIcon76x76</string></array>
				<key>CFBundleIconName</key><string>AppIcon</string>
			</dict></dict>
			""" : ""
		let extra = (try? String(contentsOf: proj.appendingPathComponent("Info.extra.plist"), encoding: .utf8)) ?? ""
		let s = """
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>CFBundleDevelopmentRegion</key><string>en</string>
			<key>CFBundleExecutable</key><string>\(esc(name))</string>
			<key>CFBundleIdentifier</key><string>\(esc(bundleID))</string>
			<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
			<key>CFBundleName</key><string>\(esc(name))</string>
			<key>CFBundleDisplayName</key><string>\(esc(display))</string>
			<key>CFBundlePackageType</key><string>APPL</string>
			<key>CFBundleShortVersionString</key><string>\(esc(version))</string>
			<key>CFBundleVersion</key><string>\(esc(build))</string>
			<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
			<key>DTPlatformName</key><string>iphoneos</string>
			<key>DTSDKName</key><string>iphoneos\(sdkVer)</string>
			<key>DTPlatformVersion</key><string>\(sdkVer)</string>
			<key>MinimumOSVersion</key><string>\(esc(minIOS))</string>
			<key>LSRequiresIPhoneOS</key><true/>
			<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
			<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
			<key>UILaunchScreen</key><dict/>
			<key>UIApplicationSupportsIndirectInputEvents</key><true/>
			<key>UISupportedInterfaceOrientations</key>
			<array>
				<string>UIInterfaceOrientationPortrait</string>
				<string>UIInterfaceOrientationLandscapeLeft</string>
				<string>UIInterfaceOrientationLandscapeRight</string>
			</array>
			<key>UISupportedInterfaceOrientations~ipad</key>
			<array>
				<string>UIInterfaceOrientationPortrait</string>
				<string>UIInterfaceOrientationPortraitUpsideDown</string>
				<string>UIInterfaceOrientationLandscapeLeft</string>
				<string>UIInterfaceOrientationLandscapeRight</string>
			</array>
		\(icon)
		\(extra)
		</dict>
		</plist>

		"""
		return Data(s.utf8)
	}
}
