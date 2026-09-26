import Foundation
import Security

enum Keychain {
	static func get(_ k: String) -> String? {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k,
		                        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
		var out: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
		return String(data: d, encoding: .utf8)
	}

	static func set(_ k: String, _ v: String) {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k]
		SecItemDelete(q as CFDictionary)
		guard !v.isEmpty else { return }
		var a = q
		a[kSecValueData as String] = Data(v.utf8)
		a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		SecItemAdd(a as CFDictionary, nil)
	}
}

// MARK: провайдеры

enum APIKind: String, Codable, CaseIterable, Identifiable, Sendable {
	case openai, anthropic
	var id: String { rawValue }
	var title: String { self == .openai ? L("OpenAI-compatible") : "Anthropic" }
}

struct Provider: Codable, Identifiable, Hashable, Sendable {
	var id: String          // у пресетов фиксированный (ключ в Keychain переживает обновления), у своих — UUID
	var name: String
	var kind: APIKind
	var baseURL: String     // без /chat/completions и /messages
	var models: [String]
	var needsKey: Bool
	var note: String = ""
	var isPreset: Bool { Providers.presets.contains { $0.id == id } }
}

struct ModelRef: Codable, Hashable {
	var provider: String
	var model: String
}

@MainActor
final class Providers: ObservableObject {
	static let shared = Providers()

	@Published var list: [Provider] { didSet { save() } }
	@Published var active: ModelRef { didSet { save() } }

	nonisolated static let presets: [Provider] = [
		Provider(id: "pollinations", name: "Pollinations (free, no key)", kind: .openai,
		         baseURL: "https://text.pollinations.ai/openai", models: ["openai-fast"], needsKey: false,
		         note: "Works right away, no sign-up. The model is weak (GPT-OSS 20B) but free."),
		Provider(id: "llm7", name: "LLM7 (free, no key)", kind: .openai,
		         baseURL: "https://api.llm7.io/v1", models: ["GLM-5.3-Flash", "minimax-m2.7", "codestral-latest"], needsKey: false,
		         note: "Works without a key; the listed models support the agent's tools. Anonymous limit: one request at a time — after Stop it may refuse for a few minutes. Other models need a key from llm7.io."),
		Provider(id: "opencode-zen", name: "OpenCode Zen", kind: .openai,
		         baseURL: "https://opencode.ai/zen/v1",
		         models: ["big-pickle", "deepseek-v4-flash-free", "mimo-v2.6-flash-free", "nemotron-3-ultra-free",
		                  "space-bunny-free", "ling-3.0-flash-fin-free"],
		         needsKey: true,
		         note: "Needs a Zen API key: opencode.ai/auth. Zen's free tier (*-free models, Big Pickle) only works inside OpenCode itself."),
		Provider(id: "openrouter", name: "OpenRouter (free :free models)", kind: .openai,
		         baseURL: "https://openrouter.ai/api/v1",
		         models: ["qwen/qwen3.8-27b:free", "nvidia/nemotron-3-super-120b-a12b:free", "google/gemma-4-31b-it:free",
		                  "cohere/north-mini-code:free", "poolside/laguna-s-2.1:free"],
		         needsKey: true,
		         note: "Models with :free are free (rate-limited). Key without a card: openrouter.ai/keys"),
		Provider(id: "anthropic", name: "Anthropic (Claude)", kind: .anthropic,
		         baseURL: "https://api.anthropic.com/v1",
		         models: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"], needsKey: true,
		         note: "Paid. Key: console.anthropic.com"),
		Provider(id: "openai", name: "OpenAI", kind: .openai, baseURL: "https://api.openai.com/v1",
		         models: ["gpt-5.5", "gpt-5.4-mini"], needsKey: true,
		         note: "Paid. Key: platform.openai.com. The model list can be fetched with the button."),
		Provider(id: "gemini", name: "Google Gemini", kind: .openai,
		         baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
		         models: ["gemini-3.5-flash", "gemini-3.1-pro"], needsKey: true,
		         note: "Has a free tier. Key: aistudio.google.com/apikey"),
		Provider(id: "local", name: "Ollama / LM Studio (local network)", kind: .openai,
		         baseURL: "http://192.168.1.10:11434/v1", models: ["qwen3-coder"], needsKey: false,
		         note: "Enter the computer's IP. Ollama: port 11434, LM Studio: 1234. Start the server with network access."),
	]

	private init() {
		let d = UserDefaults.standard
		var saved = (d.data(forKey: "providers.v1")).flatMap { try? JSONDecoder().decode([Provider].self, from: $0) } ?? []
		for p in Providers.presets where !saved.contains(where: { $0.id == p.id }) { saved.append(p) }
		// имя и описание пресетов — всегда из определения (английские, на экран через L()); так уходят старые русские
		for i in saved.indices {
			guard let pre = Providers.presets.first(where: { $0.id == saved[i].id }) else { continue }
			saved[i].name = pre.name
			saved[i].note = pre.note
		}
		list = saved
		active = (d.data(forKey: "active.v1")).flatMap { try? JSONDecoder().decode(ModelRef.self, from: $0) }
			?? ModelRef(provider: "pollinations", model: "openai-fast")
		// ключ из первой версии Forge
		if let old = Keychain.get("anthropic-api-key"), Keychain.get("key.anthropic") == nil {
			Keychain.set("key.anthropic", old)
		}
	}

	private func save() {
		let d = UserDefaults.standard
		d.set(try? JSONEncoder().encode(list), forKey: "providers.v1")
		d.set(try? JSONEncoder().encode(active), forKey: "active.v1")
	}

	var activeProvider: Provider? { list.first { $0.id == active.provider } }

	func key(_ p: Provider) -> String { Keychain.get("key." + p.id) ?? "" }

	func setKey(_ k: String, for p: Provider) {
		Keychain.set("key." + p.id, k.trimmingCharacters(in: .whitespacesAndNewlines))
		objectWillChange.send()
	}

	func update(_ p: Provider) {
		if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
	}

	func remove(_ p: Provider) {
		list.removeAll { $0.id == p.id }
		Keychain.set("key." + p.id, "")
		if active.provider == p.id { active = ModelRef(provider: "pollinations", model: "openai-fast") }
	}

	func resetPreset(_ p: Provider) {
		if let orig = Providers.presets.first(where: { $0.id == p.id }) { update(orig) }
	}

	func addCustom() -> Provider {
		let p = Provider(id: UUID().uuidString, name: L("My provider"), kind: .openai,
		                 baseURL: "https://", models: [], needsKey: true)
		list.append(p)
		return p
	}

	/// GET /models — у OpenAI-совместимых и у Anthropic ответ одного вида: {"data":[{"id":…}]}.
	func fetchModels(_ p: Provider) async throws -> [String] {
		var req = URLRequest(url: try LLM.url(p.baseURL, "models"))
		req.timeoutInterval = 30
		LLM.auth(&req, p, key(p))
		let (d, r) = try await URLSession.shared.data(for: req)
		let code = (r as? HTTPURLResponse)?.statusCode ?? 0
		let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
		guard code == 200 else { throw StoreError("HTTP \(code): \(LLM.errorText(j, d))") }
		let ids = (j["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		guard !ids.isEmpty else { throw StoreError(L("The server did not return a model list")) }
		return ids.sorted()
	}
}

// MARK: клиент

/// История чата хранится в формате Anthropic Messages (text / tool_use / tool_result / thinking).
/// Для OpenAI-совместимых провайдеров она конвертируется туда и обратно — модель можно менять посреди чата.
enum LLM {
	struct Reply {
		var content: [[String: Any]]
		var stop: String   // end_turn | tool_use | max_tokens | refusal
	}

	/// Картинка Anthropic (base64) → часть сообщения OpenAI (data URL).
	static func imageURLPart(_ b: [String: Any]) -> [String: Any]? {
		guard b["type"] as? String == "image", let s = b["source"] as? [String: Any], let d = s["data"] as? String else { return nil }
		let mt = s["media_type"] as? String ?? "image/jpeg"
		return ["type": "image_url", "image_url": ["url": "data:\(mt);base64,\(d)"]]
	}

	static func url(_ base: String, _ path: String) throws -> URL {
		var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
		while b.hasSuffix("/") { b.removeLast() }
		guard let u = URL(string: b + "/" + path), u.scheme != nil, u.host != nil else {
			throw StoreError(L("Invalid provider URL: %@", base))
		}
		return u
	}

	static func isOfficialAnthropic(_ p: Provider) -> Bool { p.baseURL.contains("api.anthropic.com") }

	static func auth(_ req: inout URLRequest, _ p: Provider, _ key: String) {
		switch p.kind {
		case .anthropic:
			req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
			if !key.isEmpty {
				req.setValue(key, forHTTPHeaderField: "x-api-key")
				if !isOfficialAnthropic(p) { req.setValue("Bearer " + key, forHTTPHeaderField: "authorization") }
			}
		case .openai:
			if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "authorization") }
			req.setValue("Forge", forHTTPHeaderField: "X-Title")
		}
	}

	static func errorText(_ j: [String: Any], _ d: Data) -> String {
		if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
		if let e = j["error"] as? String { return e }
		if let m = j["message"] as? String { return m }
		return String(decoding: d.prefix(500), as: UTF8.self)
	}

	/// Живые события стрима — для показа текста по мере генерации.
	enum Event {
		case text(String)
		case reasoning(String)
		case tool(String)   // модель начала вызывать инструмент
	}

	static func complete(provider p: Provider, key: String, model: String, system: String,
	                     tools: [[String: Any]], messages: [[String: Any]],
	                     onEvent: @escaping (Event) -> Void) async throws -> Reply {
		switch p.kind {
		case .anthropic: return try await anthropic(p, key, model, system, tools, messages, onEvent)
		case .openai: return try await openai(p, key, model, system, tools, messages, onEvent)
		}
	}

	/// POST со стримом SSE: повторяет 429/5xx до начала ответа, затем отдаёт строки `data: …`.
	private static func stream(_ url: URL, _ p: Provider, _ key: String, _ body: [String: Any], beta: String? = nil,
	                           onData: (String) throws -> Void) async throws {
		let data = try JSONSerialization.data(withJSONObject: body)
		var attempt = 0
		while true {
			var req = URLRequest(url: url)
			req.httpMethod = "POST"
			req.timeoutInterval = 600  // модели с рассуждениями долго молчат до первого байта
			req.setValue("application/json", forHTTPHeaderField: "content-type")
			req.setValue("text/event-stream", forHTTPHeaderField: "accept")
			auth(&req, p, key)
			if let beta { req.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
			req.httpBody = data

			let (bytes, r) = try await URLSession.shared.bytes(for: req)
			let http = r as? HTTPURLResponse
			let code = http?.statusCode ?? 0
			guard code == 200 else {
				var d = Data()
				for try await b in bytes { d.append(b); if d.count > 200_000 { break } }
				if [408, 429, 500, 502, 503, 504, 529].contains(code), attempt < 3 {
					attempt += 1
					let wait = Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(1 << attempt)
					try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
					continue
				}
				let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
				if code == 401 || code == 403 { throw StoreError(L("The key was rejected (%@): %@", code, errorText(j, d))) }
				throw StoreError("HTTP \(code): \(errorText(j, d))")
			}
			for try await line in bytes.lines {
				try Task.checkCancellation()
				guard line.hasPrefix("data:") else { continue }
				let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
				if payload.isEmpty || payload == "[DONE]" { continue }
				try onData(payload)
			}
			return
		}
	}

	private static func json(_ s: String) -> [String: Any]? {
		(try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
	}

	private static func anthropic(_ p: Provider, _ key: String, _ model: String, _ system: String,
	                              _ tools: [[String: Any]], _ messages: [[String: Any]],
	                              _ onEvent: @escaping (Event) -> Void) async throws -> Reply {
		let official = isOfficialAnthropic(p)
		var body: [String: Any] = ["model": model, "max_tokens": official ? 64000 : 32000, "system": system,
		                           "messages": messages, "stream": true]
		var tl = tools
		var beta: String?
		if official {
			// большие аргументы (содержимое файлов) стримятся сразу; мы сами проверяем, что JSON целый
			tl = tools.map { var t = $0; t["eager_input_streaming"] = true; return t }
			body["cache_control"] = ["type": "ephemeral"]  // автокэш: история не оплачивается заново каждый шаг
			if !model.contains("haiku") { body["thinking"] = ["type": "adaptive", "display": "summarized"] }
			if model == "claude-opus-5" {
				// при отказе классификатора запрос сам перезапускается на рекомендованной модели
				body["fallbacks"] = "default"
				beta = "server-side-fallback-2026-07-01"
			}
		}
		body["tools"] = tl

		var blocks: [Int: [String: Any]] = [:]
		var partial: [Int: String] = [:]
		var stop = "end_turn"
		func appendText(_ i: Int, _ key: String, _ s: String) {
			guard var b = blocks[i] else { return }
			b[key] = (b[key] as? String ?? "") + s
			blocks[i] = b
		}
		try await stream(try url(p.baseURL, "messages"), p, key, body, beta: beta) { payload in
			guard let e = json(payload) else { return }
			switch e["type"] as? String {
			case "content_block_start":
				guard let i = e["index"] as? Int, let cb = e["content_block"] as? [String: Any] else { return }
				blocks[i] = cb
				if cb["type"] as? String == "tool_use" {
					partial[i] = ""
					onEvent(.tool(cb["name"] as? String ?? ""))
				}
			case "content_block_delta":
				guard let i = e["index"] as? Int, let d = e["delta"] as? [String: Any] else { return }
				switch d["type"] as? String {
				case "text_delta":
					let t = d["text"] as? String ?? ""
					appendText(i, "text", t)
					onEvent(.text(t))
				case "thinking_delta":
					let t = d["thinking"] as? String ?? ""
					appendText(i, "thinking", t)
					onEvent(.reasoning(t))
				case "signature_delta":
					appendText(i, "signature", d["signature"] as? String ?? "")
				case "input_json_delta":
					partial[i, default: ""] += d["partial_json"] as? String ?? ""
				default: break
				}
			case "content_block_stop":
				guard let i = e["index"] as? Int, let raw = partial.removeValue(forKey: i) else { return }
				if raw.trimmingCharacters(in: .whitespaces).isEmpty { blocks[i]?["input"] = [String: Any]() }
				else if let obj = json(raw) { blocks[i]?["input"] = obj }
				else { blocks[i]?["input"] = ["_raw": raw] }  // обрезанный/битый JSON — инструмент вернёт ошибку
			case "message_delta":
				if let s = (e["delta"] as? [String: Any])?["stop_reason"] as? String { stop = s }
			case "error":
				let m = (e["error"] as? [String: Any])?["message"] as? String ?? payload
				throw StoreError(L("API error: %@", m))
			default: break
			}
		}
		let content = blocks.keys.sorted().compactMap { blocks[$0] }
		return Reply(content: content, stop: stop)
	}

	private static func openai(_ p: Provider, _ key: String, _ model: String, _ system: String,
	                           _ tools: [[String: Any]], _ messages: [[String: Any]],
	                           _ onEvent: @escaping (Event) -> Void) async throws -> Reply {
		var msgs: [[String: Any]] = [["role": "system", "content": system]]
		for m in messages {
			let role = m["role"] as? String ?? "user"
			if let s = m["content"] as? String { msgs.append(["role": role, "content": s]); continue }
			let blocks = m["content"] as? [[String: Any]] ?? []
			if role == "assistant" {
				let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
				let calls: [[String: Any]] = blocks.filter { $0["type"] as? String == "tool_use" }.map { b in
					let args = (try? JSONSerialization.data(withJSONObject: b["input"] ?? [String: Any]())).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
					return ["id": b["id"] ?? "", "type": "function", "function": ["name": b["name"] ?? "", "arguments": args]]
				}
				var a: [String: Any] = ["role": "assistant", "content": text]
				if !calls.isEmpty { a["tool_calls"] = calls }
				msgs.append(a)
			} else {
				// текст и картинки пользователя — одним сообщением; картинки из tool_result (screenshot) —
				// отдельным сообщением user после ответов инструментов: в role tool картинки нельзя
				var parts: [[String: Any]] = [], toolImages: [[String: Any]] = []
				for b in blocks {
					switch b["type"] as? String {
					case "tool_result":
						var text = b["content"] as? String ?? ""
						if let arr = b["content"] as? [[String: Any]] {
							text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
							toolImages += arr.compactMap(LLM.imageURLPart)
						}
						msgs.append(["role": "tool", "tool_call_id": b["tool_use_id"] ?? "", "content": text])
					case "text":
						parts.append(["type": "text", "text": b["text"] as? String ?? ""])
					case "image":
						if let p = LLM.imageURLPart(b) { parts.append(p) }
					default: break
					}
				}
				if !toolImages.isEmpty {
					msgs.append(["role": "user", "content": [["type": "text", "text": "Screenshot returned by the tool:"]] + toolImages])
				}
				if parts.count == 1, let t = parts[0]["text"] as? String {
					msgs.append(["role": "user", "content": t])
				} else if !parts.isEmpty {
					msgs.append(["role": "user", "content": parts])
				}
			}
		}
		let fns: [[String: Any]] = tools.map {
			["type": "function", "function": ["name": $0["name"]!, "description": $0["description"]!, "parameters": $0["input_schema"]!]]
		}

		var text = ""
		var finish = "stop"
		var calls: [Int: (id: String, name: String, args: String)] = [:]
		try await stream(try url(p.baseURL, "chat/completions"), p, key,
		                 ["model": model, "messages": msgs, "tools": fns, "stream": true]) { payload in
			guard let j = json(payload) else { return }
			if j["error"] != nil { throw StoreError(L("API error: %@", errorText(j, Data(payload.utf8)))) }
			guard let ch = (j["choices"] as? [[String: Any]])?.first else { return }
			if let f = ch["finish_reason"] as? String { finish = f }
			let d = ch["delta"] as? [String: Any] ?? ch["message"] as? [String: Any] ?? [:]
			if let t = d["content"] as? String, !t.isEmpty { text += t; onEvent(.text(t)) }
			if let r = (d["reasoning_content"] ?? d["reasoning"]) as? String, !r.isEmpty { onEvent(.reasoning(r)) }
			for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
				let i = tc["index"] as? Int ?? calls.count
				var c = calls[i] ?? ("", "", "")
				if let id = tc["id"] as? String, !id.isEmpty { c.id = id }
				let fn = tc["function"] as? [String: Any] ?? [:]
				if let n = fn["name"] as? String, !n.isEmpty, c.name.isEmpty { c.name = n; onEvent(.tool(n)) }
				if let a = fn["arguments"] as? String { c.args += a }
				calls[i] = c
			}
		}

		var content: [[String: Any]] = []
		if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.append(["type": "text", "text": text]) }
		for i in calls.keys.sorted() {
			guard let c = calls[i], !c.name.isEmpty else { continue }
			let raw = c.args.trimmingCharacters(in: .whitespacesAndNewlines)
			var input: [String: Any] = raw.isEmpty ? [:] : (json(raw) ?? ["_raw": raw])
			// некоторые слабые модели заворачивают аргументы в {"input": "<json>"}
			if input.count == 1, let inner = input["input"] as? String, let obj = json(inner) { input = obj }
			// id должен подходить и для Anthropic, если потом переключиться на Claude
			let id = String((c.id.isEmpty ? "call_\(i)" : c.id).map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
			content.append(["type": "tool_use", "id": id, "name": c.name, "input": input])
		}
		let hasTools = content.contains { $0["type"] as? String == "tool_use" }
		let stop = hasTools ? "tool_use" : finish == "length" ? "max_tokens" : finish == "content_filter" ? "refusal" : "end_turn"
		return Reply(content: content, stop: stop)
	}
}
