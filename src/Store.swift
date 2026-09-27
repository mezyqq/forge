import Foundation

struct StoreError: LocalizedError {
	let message: String
	init(_ m: String) { message = m }
	var errorDescription: String? { message }
}

struct Project: Identifiable, Hashable {
	let url: URL
	var id: URL { url }
	var name: String { url.lastPathComponent }
}

struct FileNode: Identifiable, Hashable {
	let path: String      // относительно корня проекта
	let isDir: Bool
	var children: [FileNode]?
	var id: String { path }
	var name: String { (path as NSString).lastPathComponent }
	var parent: String { (path as NSString).deletingLastPathComponent }
}

/// ipa.conf — bash, но на практике строки вида KEY="value" # комментарий.
/// Правим значение прямо в строке, чтобы не потерять комментарии пользователя.
enum Conf {
	static var fields: [(String, String)] { [
		("NAME", L("Name (executable)")), ("DISPLAY_NAME", L("Display name")), ("BUNDLE_ID", "Bundle ID"),
		("VERSION", L("Version")), ("BUILD", L("Build number")), ("MIN_IOS", L("Minimum iOS")),
		("FRAMEWORKS", L("Frameworks")), ("LIBS", L("Libraries (-l)")), ("CFLAGS", "CFLAGS"),
		("SWIFTFLAGS", "SWIFTFLAGS"), ("LDFLAGS", "LDFLAGS"), ("BRIDGING_HEADER", "Bridging header"),
		("ICON", L("Icon (PNG 1024)")), ("ENTITLEMENTS", "Entitlements"),
	] }

	private static func valueRange(_ line: String, _ key: String) -> Range<String.Index>? {
		guard line.hasPrefix(key + "=\"") else { return nil }
		let start = line.index(line.startIndex, offsetBy: key.count + 2)
		guard let end = line[start...].firstIndex(of: "\"") else { return nil }
		return start..<end
	}

	static func get(_ text: String, _ key: String) -> String {
		for line in text.components(separatedBy: "\n") {
			if let r = valueRange(line, key) { return String(line[r]) }
		}
		return ""
	}

	static func set(_ text: String, _ key: String, _ value: String) -> String {
		let v = value.replacingOccurrences(of: "\"", with: "")
		var lines = text.components(separatedBy: "\n")
		if let i = lines.firstIndex(where: { valueRange($0, key) != nil }) {
			lines[i].replaceSubrange(valueRange(lines[i], key)!, with: v)
		} else if !v.isEmpty {
			if lines.last == "" { lines.insert("\(key)=\"\(v)\"", at: lines.count - 1) } else { lines.append("\(key)=\"\(v)\"") }
		}
		return lines.joined(separator: "\n")
	}
}

/// Проекты лежат прямо в Documents/<имя>/ в формате ipab (ipa.conf + src/ + res/),
/// так что их видно в «Файлах» и можно собрать ipab на компьютере.
@MainActor
final class ProjectStore: ObservableObject {
	@Published private(set) var projects: [Project] = []
	/// Растёт, когда файлы меняет не редактор (агент, удаление) — открытые экраны перечитывают диск.
	@Published private(set) var fsVersion = 0

	/// Файлы поменялись не через write (пакеты, распаковка) — обновить дерево и открытые редакторы.
	func touch() { fsVersion += 1 }

	let root: URL
	private let fm = FileManager.default
	private var agents: [URL: Agent] = [:]

	init() {
		root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
		reload()
	}

	func reload() {
		let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
		projects = dirs
			.filter { isDir($0) && $0.lastPathComponent != "Inbox" }  // Inbox — служебная папка iOS
			.map(Project.init)
			.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	func create(name: String, template: Template) throws -> Project {
		let dir = try checkedNewProjectURL(name)
		let name = dir.lastPathComponent
		if template.isApp {
			try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
			try template.conf(name: name).write(to: dir.appendingPathComponent("ipa.conf"), atomically: true, encoding: .utf8)
			if !template.source.isEmpty {
				try template.source.write(to: dir.appendingPathComponent("src/" + template.file), atomically: true, encoding: .utf8)
			}
		} else {
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			for (path, body) in template.scriptFiles(name: name) {
				let u = dir.appendingPathComponent(path)
				try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
				try body.write(to: u, atomically: true, encoding: .utf8)
			}
		}
		reload()
		return Project(url: dir)
	}

	/// Файл для кнопки ▶ у проекта (main.py, index.html…).
	func entryPoint(in p: Project) -> String? {
		RunKind.entryPoints.first { fm.fileExists(atPath: p.url.appendingPathComponent($0).path) }
	}

	/// Файлы поменялись снаружи (git): обновить списки и открытые редакторы.
	func externalChange() {
		fsVersion += 1
		reload()
	}

	func delete(_ p: Project) {
		try? fm.removeItem(at: p.url)
		agents[p.url] = nil
		reload()
	}

	func agent(for p: Project) -> Agent {
		if let a = agents[p.url] { return a }
		let a = Agent(project: p, store: self)
		agents[p.url] = a
		return a
	}

	func rename(_ p: Project, to name: String) throws {
		let dst = try checkedNewProjectURL(name)
		try fm.moveItem(at: p.url, to: dst)
		agents[p.url] = nil
		reload()
	}

	func duplicate(_ p: Project) throws {
		var n = 2
		while fm.fileExists(atPath: root.appendingPathComponent("\(p.name)\(n)").path) { n += 1 }
		let dst = root.appendingPathComponent("\(p.name)\(n)")
		try fm.copyItem(at: p.url, to: dst)
		try? fm.removeItem(at: dst.appendingPathComponent(".chat.json"))
		try? fm.removeItem(at: dst.appendingPathComponent("build"))
		reload()
	}

	private func checkedNewProjectURL(_ name: String) throws -> URL {
		let name = name.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty, !name.contains("/"), !name.contains(" "), !name.hasPrefix(".") else {
			throw StoreError(L("A name without spaces or “/”"))
		}
		let dir = root.appendingPathComponent(name)
		guard !fm.fileExists(atPath: dir.path) else { throw StoreError(L("Project %@ already exists", name)) }
		return dir
	}

	// MARK: файлы проекта

	private func isDir(_ u: URL) -> Bool {
		(try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
	}

	/// Все файлы и папки проекта (папки с «/» на конце), без build/ и скрытых.
	func entries(in p: Project, dirs: Bool = true) -> [String] {
		let base = p.url.resolvingSymlinksInPath().path + "/"
		guard let e = fm.enumerator(at: p.url, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
		var out: [String] = []
		for case let u as URL in e {
			if Git.internalNames.contains(u.lastPathComponent) { e.skipDescendants(); continue }
			let full = u.resolvingSymlinksInPath().path
			guard full.hasPrefix(base) else { continue }
			let rel = String(full.dropFirst(base.count))
			if rel == "build" { e.skipDescendants(); continue }
			if isDir(u) { if dirs { out.append(rel + "/") } } else { out.append(rel) }
		}
		return out.sorted()
	}

	/// Дерево для списка файлов: папки сверху, потом файлы.
	func tree(in p: Project, _ rel: String = "") -> [FileNode] {
		let dir = rel.isEmpty ? p.url : p.url.appendingPathComponent(rel)
		let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
		return items.compactMap { u -> FileNode? in
			if Git.internalNames.contains(u.lastPathComponent) { return nil }
			let path = rel.isEmpty ? u.lastPathComponent : rel + "/" + u.lastPathComponent
			if path == "build" { return nil }
			return isDir(u) ? FileNode(path: path, isDir: true, children: tree(in: p, path))
			                : FileNode(path: path, isDir: false, children: nil)
		}
		.sorted { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	func makeDir(_ rel: String, in p: Project) throws {
		try fm.createDirectory(at: resolve(rel, in: p), withIntermediateDirectories: true)
		fsVersion += 1
	}

	func move(_ from: String, to: String, in p: Project) throws {
		let src = try resolve(from, in: p), dst = try resolve(to, in: p)
		guard fm.fileExists(atPath: src.path) else { throw StoreError(L("No %@", from)) }
		guard !fm.fileExists(atPath: dst.path) else { throw StoreError(L("%@ already exists", to)) }
		try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
		try fm.moveItem(at: src, to: dst)
		fsVersion += 1
	}

	/// Копирует выбранные в «Файлах» файлы в папку проекта.
	func importFiles(_ urls: [URL], into dir: String, in p: Project) throws {
		let base = dir.isEmpty ? p.url : try resolve(dir, in: p)
		try fm.createDirectory(at: base, withIntermediateDirectories: true)
		for u in urls {
			let scoped = u.startAccessingSecurityScopedResource()
			defer { if scoped { u.stopAccessingSecurityScopedResource() } }
			let dst = base.appendingPathComponent(u.lastPathComponent)
			try? fm.removeItem(at: dst)
			try fm.copyItem(at: u, to: dst)
		}
		fsVersion += 1
	}

	/// Поиск без учёта регистра по текстовым файлам; результат — «путь:строка: текст».
	func search(_ query: String, in p: Project, under dir: String = "", limit: Int = 200) -> [String] {
		let d = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
		var out: [String] = []
		for f in entries(in: p, dirs: false) where d.isEmpty || d == "." || f.hasPrefix(d + "/") {
			guard let text = try? String(contentsOf: p.url.appendingPathComponent(f), encoding: .utf8) else { continue }
			var n = 0
			text.enumerateLines { line, stop in
				n += 1
				if line.range(of: query, options: .caseInsensitive) != nil {
					out.append("\(f):\(n): \(line.trimmingCharacters(in: .whitespaces).prefix(200))")
					if out.count >= limit { stop = true }
				}
			}
			if out.count >= limit { break }
		}
		return out
	}

	/// Путь внутри проекта; «..» и абсолютные пути запрещены, чтобы агент не вылез наружу.
	func resolve(_ rel: String, in p: Project) throws -> URL {
		let parts = rel.split(separator: "/")
		guard !rel.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
			throw StoreError(L("Invalid path: %@", rel))
		}
		return p.url.appendingPathComponent(rel)
	}

	func read(_ rel: String, in p: Project) throws -> String {
		try String(contentsOf: resolve(rel, in: p), encoding: .utf8)
	}

	func write(_ rel: String, _ text: String, in p: Project, external: Bool = true) throws {
		let u = try resolve(rel, in: p)
		try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
		try text.write(to: u, atomically: true, encoding: .utf8)
		if external { fsVersion += 1 }
	}

	/// Файл или папка целиком.
	func remove(_ rel: String, in p: Project) throws {
		try fm.removeItem(at: resolve(rel, in: p))
		fsVersion += 1
	}

	/// zip проекта для «Поделиться»: NSFileCoordinator с .forUploading пакует папку сам.
	func archive(_ p: Project) throws -> URL {
		let dst = fm.temporaryDirectory.appendingPathComponent(p.name + ".zip")
		var coordErr: NSError?
		var copyErr: Error?
		NSFileCoordinator().coordinate(readingItemAt: p.url, options: .forUploading, error: &coordErr) { tmp in
			do {
				try? FileManager.default.removeItem(at: dst)
				try FileManager.default.copyItem(at: tmp, to: dst)
			} catch { copyErr = error }
		}
		if let e = coordErr ?? copyErr { throw e }
		return dst
	}
}

// MARK: шаблоны: iOS-приложения (как у ipab new) и скрипты, которые запускаются прямо в Forge

enum Template: String, CaseIterable, Identifiable {
	case python, pygame, js, web, lua, love, cscript, cppscript, objc, game, c, objcpp, swift, swiftui, empty
	var id: String { rawValue }

	var isApp: Bool { [.objc, .game, .c, .objcpp, .swift, .swiftui, .empty].contains(self) }

	static let scripts: [Template] = [.python, .pygame, .js, .web, .lua, .love, .cscript, .cppscript]
	static let apps: [Template] = [.swiftui, .swift, .objc, .game, .objcpp, .c, .empty]

	var title: String {
		switch self {
		case .python: return "Python"
		case .js: return "JavaScript"
		case .web: return L("Website (HTML/CSS/JS)")
		case .lua: return "Lua"
		case .cscript: return L("C (console)")
		case .cppscript: return L("C++ (console, JIT)")
		case .pygame: return L("Game (Python, pygame)")
		case .love: return L("Game (Lua, LÖVE)")
		case .game: return L("Game (Objective-C)")
		case .objc: return "Objective-C"
		case .c: return L("C (UIKit via runtime)")
		case .objcpp: return "Objective-C++"
		case .empty: return L("Empty app")
		case .swift: return "Swift (UIKit)"
		case .swiftui: return "SwiftUI"
		}
	}

	var file: String {
		switch self {
		case .objc: return "main.m"
		case .game: return "main.m"
		case .c: return "main.c"
		case .objcpp: return "main.mm"
		case .swift, .swiftui: return "App.swift"
		default: return ""
		}
	}

	func scriptFiles(name: String) -> [(String, String)] {
		switch self {
		case .python: return [
			("main.py", """
			# \(L("Run: the ▶ button. Powered by pocketpy — Python 3 without pip, with basic modules (math, random, json, time…)."))
			import utils

			name = input("\(L("What is your name?")) ")
			print(utils.greet(name))

			squares = [n * n for n in range(1, 11)]
			print("\(L("Squares:"))", squares)
			print("\(L("Sum:"))", sum(squares))

			"""),
			("utils.py", """
			def greet(name):
			    return f"\(L("Hello")), {name or '\(L("world"))'}!"

			"""),
		]
		case .js: return [
			("main.js", """
			// Запуск: кнопка ▶. JavaScriptCore: console.log, prompt(), require('./файл'), setTimeout.
			const { greet } = require('./utils');

			const name = prompt('\(L("What is your name?"))');
			console.log(greet(name));

			const squares = Array.from({ length: 10 }, (_, i) => (i + 1) ** 2);
			console.log('\(L("Squares:"))', squares);

			setTimeout(() => console.log('\(L("A second has passed"))'), 1000);

			"""),
			("utils.js", """
			module.exports.greet = (name) => `\(L("Hello")), ${name || '\(L("world"))'}!`;

			"""),
		]
		case .web: return [
			("index.html", """
			<!doctype html>
			<html lang="ru">
			<head>
			  <meta charset="utf-8">
			  <meta name="viewport" content="width=device-width, initial-scale=1">
			  <title>\(name)</title>
			  <link rel="stylesheet" href="style.css">
			</head>
			<body>
			  <main>
			    <h1>\(name)</h1>
			    <p>\(L("Tapped:")) <span id="count">0</span></p>
			    <button id="btn">\(L("Tap me"))</button>
			  </main>
			  <script src="script.js"></script>
			</body>
			</html>

			"""),
			("style.css", """
			:root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
			body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
			main { text-align: center; }
			button { font-size: 1.1rem; padding: .7em 1.4em; border: 0; border-radius: 12px; background: #ff7a1a; color: white; }

			"""),
			("script.js", """
			let n = 0;
			document.getElementById('btn').addEventListener('click', () => {
			  n += 1;
			  document.getElementById('count').textContent = n;
			  console.log('\(L("click"))', n);
			});

			"""),
		]
		case .lua: return [
			("main.lua", """
			-- \(L("Run: the ▶ button. Lua 5.4."))
			local utils = require("utils")

			io.write("\(L("What is your name?")) ")
			local name = io.read("l")
			print(utils.greet(name))

			local squares = {}
			for i = 1, 10 do squares[#squares + 1] = i * i end
			print("\(L("Squares:")) " .. table.concat(squares, ", "))

			"""),
			("utils.lua", """
			local M = {}

			function M.greet(name)
			  if name == nil or name == "" then name = "\(L("world"))" end
			  return "\(L("Hello")), " .. name .. "!"
			end

			return M

			"""),
		]
		case .cscript: return [
			("main.c", """
			/* \(L("Run: the ▶ button. The picoc interpreter: most of C89, stdio/stdlib/string/math."))
			   \(L("Limitation: declare struct fields one per line.")) */
			#include <stdio.h>
			#include <string.h>

			struct Point {
			    int x;
			    int y;
			};

			int square(int v) { return v * v; }

			int main() {
			    char name[64];
			    struct Point p;
			    int i;

			    printf("\(L("What is your name?")) ");
			    scanf("%63s", name);
			    printf("\(L("Hello")), %s!\\n", name);

			    p.x = 3;
			    p.y = 4;
			    printf("\(L("Squared distance")): %d\\n", square(p.x) + square(p.y));

			    for (i = 1; i <= 5; i++) printf("%d ", square(i));
			    printf("\\n");
			    return 0;
			}

			"""),
		]
		case .pygame: return [
			("main.py", """
			# \(L("Catch the ball: tap to move the paddle (or use the arrows). Forge's pygame — the main part of the pygame API."))
			import pygame, random

			pygame.init()
			W, H = 400, 700
			screen = pygame.display.set_mode((W, H))
			clock = pygame.time.Clock()
			font = pygame.font.SysFont(None, 36)

			paddle = pygame.Rect(W // 2 - 50, H - 60, 100, 16)
			ball = pygame.Rect(W // 2, 80, 20, 20)
			vx, vy = 4, 5
			score = 0
			running = True
			while running:
			    for e in pygame.event.get():
			        if e.type == pygame.QUIT:
			            running = False
			        elif e.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEMOTION):
			            paddle.centerx = e.pos[0]
			    keys = pygame.key.get_pressed()
			    if keys[pygame.K_LEFT]:
			        paddle.x -= 8
			    if keys[pygame.K_RIGHT]:
			        paddle.x += 8

			    ball.x += vx
			    ball.y += vy
			    if ball.left < 0 or ball.right > W:
			        vx = -vx
			    if ball.top < 0:
			        vy = -vy
			    if ball.colliderect(paddle) and vy > 0:
			        vy = -vy
			        score += 1
			    if ball.top > H:
			        ball.center = (W // 2, 80)
			        vx, vy = random.choice([-4, 4]), 5
			        score = 0

			    screen.fill((20, 22, 35))
			    pygame.draw.rect(screen, (255, 122, 26), paddle, border_radius=8)
			    pygame.draw.circle(screen, (255, 255, 255), ball.center, 10)
			    screen.blit(font.render("\(L("Score:")) %d" % score, True, (230, 230, 230)), (16, 16))
			    pygame.display.flip()
			    clock.tick(60)

			pygame.quit()

			"""),
		]
		case .love: return [
			("main.lua", """
			-- \(L("A LÖVE-style program: love.load / love.update / love.draw. Tap to add circles, the arrows move the square."))
			local x, y = 200, 300
			local dots = {}

			function love.load()
			  love.window.setMode(400, 700)
			  love.graphics.setBackgroundColor(0.08, 0.09, 0.14)
			end

			function love.update(dt)
			  local speed = 220 * dt
			  if love.keyboard.isDown("left") then x = x - speed end
			  if love.keyboard.isDown("right") then x = x + speed end
			  if love.keyboard.isDown("up") then y = y - speed end
			  if love.keyboard.isDown("down") then y = y + speed end
			end

			function love.mousepressed(mx, my)
			  dots[#dots + 1] = {mx, my, math.random(), math.random(), math.random()}
			end

			function love.draw()
			  for _, d in ipairs(dots) do
			    love.graphics.setColor(d[3], d[4], d[5])
			    love.graphics.circle("fill", d[1], d[2], 18)
			  end
			  love.graphics.setColor(1, 0.48, 0.1)
			  love.graphics.rectangle("fill", x - 25, y - 25, 50, 50)
			  love.graphics.setColor(1, 1, 1)
			  love.graphics.print("FPS " .. love.timer.getFPS(), 12, 12)
			end

			"""),
		]
		case .cppscript: return [
			("main.cpp", """
			// \(L("Run: the ▶ button. Real clang + JIT: C++20 and the standard library, running natively. Needs JIT enabled for Forge."))
			#include <algorithm>
			#include <iostream>
			#include <map>
			#include <string>
			#include <vector>

			int main() {
				std::string name;
				std::cout << "\(L("What is your name?")) ";
				std::getline(std::cin, name);
				std::cout << "\(L("Hello")), " << (name.empty() ? "\(L("world"))" : name) << "!\\n";

				std::vector<int> v{5, 3, 9, 1, 7};
				std::sort(v.begin(), v.end());
				for (int x : v) std::cout << x << ' ';
				std::cout << '\\n';

				std::map<char, int> freq;
				for (char c : name) freq[c]++;
				for (auto [c, n] : freq) std::cout << c << ": " << n << '\\n';
			}

			"""),
		]
		default: return []
		}
	}

	func conf(name: String) -> String {
		let bid = name.lowercased().filter { $0.isLetter || $0.isNumber }
		let fw = self == .swiftui ? "Foundation UIKit SwiftUI" : self == .game ? "Foundation UIKit QuartzCore" : "Foundation UIKit"
		return """
		# \(L("Project config. It is bash — variables can be used."))
		NAME="\(name)"
		BUNDLE_ID="com.example.\(bid)"
		VERSION="1.0"
		BUILD="1"
		MIN_IOS="15.0"
		FRAMEWORKS="\(fw)"   # -framework X
		LIBS=""                         # -lX
		CFLAGS=""                       # \(L("for C/C++/ObjC"))
		SWIFTFLAGS=""
		LDFLAGS=""
		BRIDGING_HEADER=""              # \(L("e.g. src/Bridging.h — ObjC/C from Swift"))
		ICON=""                         # \(L("e.g. res/icon.png (1024x1024 square)"))
		ENTITLEMENTS=""                 # \(L("e.g. app.entitlements"))

		"""
	}

	var source: String {
		switch self {
		case .objc: return """
			#import <UIKit/UIKit.h>

			@interface ViewController : UIViewController
			@end

			@implementation ViewController {
				UILabel *_label;
				NSInteger _taps;
			}
			- (void)viewDidLoad {
				[super viewDidLoad];
				self.view.backgroundColor = UIColor.systemBackgroundColor;
				_label = [[UILabel alloc] initWithFrame:self.view.bounds];
				_label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
				_label.textAlignment = NSTextAlignmentCenter;
				_label.text = @"\(L("Hello")) (ObjC)";
				[self.view addSubview:_label];
				[self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
			}
			- (void)tap {
				_taps++;
				_label.text = [NSString stringWithFormat:@"\(L("Tapped:")) %ld", (long)_taps];
			}
			@end

			// \(L("Screen for the quick run in Forge (⋯ → Run in Forge): no install, right inside the IDE."))
			UIViewController *forge_preview(void) { return [ViewController new]; }

			@interface AppDelegate : UIResponder <UIApplicationDelegate>
			@property (nonatomic, strong) UIWindow *window;
			@end

			@implementation AppDelegate
			- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
				self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
				self.window.rootViewController = [ViewController new];
				[self.window makeKeyAndVisible];
				return YES;
			}
			@end

			int main(int argc, char *argv[]) {
				@autoreleasepool {
					return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
				}
			}

			"""
		case .game: return """
			// \(L("Mini game: catch the ball. CADisplayLink + drawing in drawRect:."))
			#import <UIKit/UIKit.h>

			@interface GameView : UIView
			@end

			@implementation GameView {
				CADisplayLink *_link;
				CGPoint _ball, _vel;
				CGFloat _radius;
				NSInteger _score;
				CFTimeInterval _last;
			}

			- (instancetype)initWithFrame:(CGRect)f {
				if ((self = [super initWithFrame:f])) {
					self.backgroundColor = UIColor.blackColor;
					_radius = 36;
					_ball = CGPointMake(120, 220);
					_vel = CGPointMake(240, 320);
				}
				return self;
			}

			// \(L("on screen — the game runs; removed — the timer stops (it retains self)"))
			- (void)didMoveToWindow {
				[super didMoveToWindow];
				if (self.window && !_link) {
					_last = 0;
					_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
					[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
				} else if (!self.window) {
					[_link invalidate];
					_link = nil;
				}
			}

			- (void)step:(CADisplayLink *)link {
				CFTimeInterval dt = _last ? MIN(link.timestamp - _last, 1.0 / 30) : 0;
				_last = link.timestamp;
				_ball.x += _vel.x * dt;
				_ball.y += _vel.y * dt;
				CGSize s = self.bounds.size;
				if (_ball.x < _radius) { _ball.x = _radius; _vel.x = fabs(_vel.x); }
				if (_ball.x > s.width - _radius) { _ball.x = s.width - _radius; _vel.x = -fabs(_vel.x); }
				if (_ball.y < _radius + 60) { _ball.y = _radius + 60; _vel.y = fabs(_vel.y); }
				if (_ball.y > s.height - _radius) { _ball.y = s.height - _radius; _vel.y = -fabs(_vel.y); }
				[self setNeedsDisplay];
			}

			- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
				CGPoint p = [touches.anyObject locationInView:self];
				if (hypot(p.x - _ball.x, p.y - _ball.y) < _radius * 1.4) {
					_score++;
					double a = arc4random_uniform(360) * M_PI / 180, speed = hypot(_vel.x, _vel.y) * 1.1;
					_vel = CGPointMake(cos(a) * speed, sin(a) * speed);
				} else if (_score > 0) {
					_score--;
				}
			}

			- (void)drawRect:(CGRect)rect {
				[UIColor.systemOrangeColor setFill];
				[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(_ball.x - _radius, _ball.y - _radius, _radius * 2, _radius * 2)] fill];
				NSString *text = [NSString stringWithFormat:@"\(L("Score:")) %ld", (long)_score];
				[text drawAtPoint:CGPointMake(20, 20) withAttributes:@{
					NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:28 weight:UIFontWeightBold],
					NSForegroundColorAttributeName: UIColor.whiteColor,
				}];
			}
			@end

			@interface GameController : UIViewController
			@end

			@implementation GameController
			- (void)loadView { self.view = [[GameView alloc] initWithFrame:UIScreen.mainScreen.bounds]; }
			- (BOOL)prefersStatusBarHidden { return YES; }
			@end

			// \(L("Screen for the quick run in Forge (⋯ → Run in Forge): no install, right inside the IDE."))
			UIViewController *forge_preview(void) { return [GameController new]; }

			@interface AppDelegate : UIResponder <UIApplicationDelegate>
			@property (nonatomic, strong) UIWindow *window;
			@end

			@implementation AppDelegate
			- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
				self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
				self.window.rootViewController = [GameController new];
				[self.window makeKeyAndVisible];
				return YES;
			}
			@end

			int main(int argc, char *argv[]) {
				@autoreleasepool {
					return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
				}
			}

			"""
		case .c: return """
			// Чистый C: UIKit через objc runtime.
			#include <objc/runtime.h>
			#include <objc/message.h>
			#include <CoreFoundation/CoreFoundation.h>

			extern int UIApplicationMain(int, char **, void *, CFStringRef);

			#define MSG(ret, ...) ((ret (*)(id, SEL, ##__VA_ARGS__))objc_msgSend)
			#define CLS(n) ((id)objc_getClass(n))
			#define SEL_(n) sel_registerName(n)

			static BOOL did_finish(id self, SEL _cmd, id app, id opts) {
				id screen = MSG(id)(CLS("UIScreen"), SEL_("mainScreen"));
				CGRect b = MSG(CGRect)(screen, SEL_("bounds"));
				id win = MSG(id, CGRect)(MSG(id)(CLS("UIWindow"), SEL_("alloc")), SEL_("initWithFrame:"), b);
				id vc = MSG(id)(MSG(id)(CLS("UIViewController"), SEL_("alloc")), SEL_("init"));
				id view = MSG(id)(vc, SEL_("view"));
				MSG(void, id)(view, SEL_("setBackgroundColor:"), MSG(id)(CLS("UIColor"), SEL_("systemIndigoColor")));
				MSG(void, id)(win, SEL_("setRootViewController:"), vc);
				MSG(void)(win, SEL_("makeKeyAndVisible"));
				object_setInstanceVariable(self, "window", win);
				return YES;
			}

			int main(int argc, char *argv[]) {
				Class c = objc_allocateClassPair(objc_getClass("UIResponder"), "AppDelegate", 0);
				class_addIvar(c, "window", sizeof(id), 3, "@");
				class_addMethod(c, SEL_("application:didFinishLaunchingWithOptions:"), (IMP)did_finish, "B@:@@");
				objc_registerClassPair(c);
				return UIApplicationMain(argc, argv, NULL, CFSTR("AppDelegate"));
			}

			"""
		case .swift: return """
			import UIKit

			@main
			class AppDelegate: UIResponder, UIApplicationDelegate {
				var window: UIWindow?

				func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
					let vc = UIViewController()
					vc.view.backgroundColor = .systemBackground
					let l = UILabel(frame: vc.view.bounds)
					l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
					l.textAlignment = .center
					l.text = "\(L("Hello")) (Swift)"
					vc.view.addSubview(l)
					let w = UIWindow(frame: UIScreen.main.bounds)
					w.rootViewController = vc
					w.makeKeyAndVisible()
					window = w
					return true
				}
			}

			"""
		case .objcpp: return """
			// Objective-C++: UIKit + стандартная библиотека C++.
			#import <UIKit/UIKit.h>
			#include <numeric>
			#include <string>
			#include <vector>

			@interface AppDelegate : UIResponder <UIApplicationDelegate>
			@property (nonatomic, strong) UIWindow *window;
			@end

			@implementation AppDelegate
			- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
				std::vector<int> v(10);
				std::iota(v.begin(), v.end(), 1);
				std::string s = "\(L("Sum 1..10 = "))" + std::to_string(std::accumulate(v.begin(), v.end(), 0));

				self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
				UIViewController *vc = [UIViewController new];
				vc.view.backgroundColor = UIColor.systemBackgroundColor;
				UILabel *l = [[UILabel alloc] initWithFrame:vc.view.bounds];
				l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
				l.textAlignment = NSTextAlignmentCenter;
				l.text = [NSString stringWithUTF8String:s.c_str()];
				[vc.view addSubview:l];
				self.window.rootViewController = vc;
				[self.window makeKeyAndVisible];
				return YES;
			}
			@end

			int main(int argc, char *argv[]) {
				@autoreleasepool {
					return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
				}
			}

			"""

		case .swiftui: return """
			import SwiftUI

			@main
			struct MyApp: App {
				@State private var n = 0
				var body: some Scene {
					WindowGroup {
						VStack(spacing: 16) {
							Text("\(L("Hello")) (SwiftUI)")
							Button("\(L("Tapped:")) \\(n)") { n += 1 }
						}
					}
				}
			}

			"""
		default: return ""
		}
	}
}
