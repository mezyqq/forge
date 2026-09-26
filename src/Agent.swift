import Foundation

struct ChatItem: Identifiable {
	enum Kind: String { case user, assistant, tool, error, info }
	let id = UUID()
	let kind: Kind
	let text: String
	var detail: String? = nil   // вывод инструмента (раскрывается по нажатию)
	var failed = false
	init(_ kind: Kind, _ text: String, detail: String? = nil, failed: Bool = false) {
		self.kind = kind
		self.text = text
		self.detail = detail
		self.failed = failed
	}
}

/// Агент одного проекта. Цикл как в opencode: стрим ответа → вызовы инструментов → результаты → снова модель,
/// пока модель не закончит. История хранится в формате Anthropic (thinking-блоки без изменений) в <проект>/.chat.json.
@MainActor
final class Agent: ObservableObject {
	@Published private(set) var items: [ChatItem] = []
	@Published private(set) var busy = false
	@Published private(set) var live = ""            // текст ответа, пока он стримится
	@Published private(set) var liveReasoning = ""   // размышления модели (если провайдер их отдаёт)
	@Published private(set) var status = ""
	@Published private(set) var todos: [Todo] = []

	let project: Project
	private unowned let store: ProjectStore
	private let toolbox: ToolBox
	private var messages: [[String: Any]] = []
	private var system: String?       // замораживаем на весь чат — иначе ломается кэш промпта
	private var systemModel = ""
	private var task: Task<Void, Never>?
	private var chatURL: URL { project.url.appendingPathComponent(".chat.json") }

	/// Последний ход упал — можно повторить без нового сообщения.
	var canRetry: Bool { !busy && items.last?.kind == .error && messages.last?["role"] as? String == "user" }

	init(project: Project, store: ProjectStore) {
		self.project = project
		self.store = store
		self.toolbox = ToolBox(project: project, store: store)
		load()
	}

	func send(_ text: String) {
		guard !busy else { return }
		items.append(.init(.user, text))
		messages.append(["role": "user", "content": text])
		start()
	}

	func retry() {
		guard canRetry else { return }
		start()
	}

	func stop() { task?.cancel() }

	func reset() {
		stop()
		messages = []
		items = []
		todos = []
		toolbox.todos = []
		system = nil
		try? FileManager.default.removeItem(at: chatURL)
	}

	private func start() {
		let ps = Providers.shared
		guard let p = ps.activeProvider else { items.append(.init(.error, L("Choose a model in Settings"))); return }
		let key = ps.key(p)
		if p.needsKey && key.isEmpty {
			items.append(.init(.error, L("“%@” has no key. Add it in Settings or choose LLM7 or Pollinations — they need no key.", L(p.name))))
			return
		}
		let model = ps.active.model
		if system == nil || systemModel != model {
			system = Prompts.system(model: model, project: project, store: store)
			systemModel = model
		}
		CrashLog.crumb("ИИ: запрос к \(model)")
		busy = true
		task = Task {
			await loop(provider: p, key: key, model: model)
			busy = false
			live = ""
			liveReasoning = ""
			status = ""
			save()
		}
	}

	// MARK: цикл

	private struct Call: Equatable {
		let name: String
		let input: String
	}

	private func loop(provider: Provider, key: String, model: String) async {
		let checkpoint = messages.lastIndex { $0["role"] as? String == "user" && $0["content"] is String } ?? messages.count
		var recent: [Call] = []
		do {
			for _ in 0..<100 {
				pruneIfNeeded(provider)
				live = ""
				liveReasoning = ""
				status = L("thinking…")
				let r = try await LLM.complete(provider: provider, key: key, model: model, system: system ?? "",
				                               tools: ToolBox.definitions, messages: messages) { [weak self] ev in
					DispatchQueue.main.async {
						guard let self else { return }
						switch ev {
						case .text(let t): self.live += t; self.status = L("writing…")
						case .reasoning(let t):
							self.liveReasoning += t
							if self.liveReasoning.count > 600 { self.liveReasoning = String(self.liveReasoning.suffix(400)) }
							self.status = L("reasoning…")
						case .tool(let n): self.status = L("calling %@…", n)
						}
					}
				}
				if r.stop == "refusal" {
					// откатываем весь ход, чтобы история осталась валидной и можно было переформулировать
					if checkpoint < messages.count { messages.removeSubrange(checkpoint...) }
					live = ""
					items.append(.init(.error, L("The model refused this request. Rephrase it.")))
					return
				}
				messages.append(["role": "assistant", "content": r.content])
				live = ""
				liveReasoning = ""

				let truncated = r.stop == "max_tokens"
				var results: [[String: Any]] = []
				var abort = false
				for b in r.content {
					switch b["type"] as? String {
					case "text":
						if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
							items.append(.init(.assistant, t))
						}
					case "tool_use":
						let name = b["name"] as? String ?? ""
						let input = b["input"] as? [String: Any] ?? [:]
						let id = b["id"] as? String ?? ""
						var res: ToolBox.Result
						if truncated {
							// обрезанный вызов (например, write с половиной файла) не выполняем
							res = .init(output: "Your response was cut off by the output limit, so this tool call was not executed. Split the work into smaller steps.",
							            isError: true, summary: L("%@: response truncated", name))
						} else {
							// защита от зацикливания (opencode: doom loop) — одинаковые вызовы подряд
							let call = Call(name: name, input: Agent.stableJSON(input))
							recent.append(call)
							if recent.count > 8 { recent.removeFirst() }
							let repeats = recent.reversed().prefix { $0 == call }.count
							if repeats >= 6 {
								abort = true
								res = .init(output: "Stopped: the same call was repeated too many times.", isError: true, summary: L("stuck in a loop on %@", name))
							} else if repeats >= 3 {
								res = .init(output: "You have called \(name) with exactly the same arguments \(repeats) times in a row and it does not help. Stop repeating it: change your approach, read the relevant file again, or explain to the user what is blocking you.",
								            isError: true, summary: L("%@: the same call repeated", name))
							} else {
								status = L("running %@…", name)
								CrashLog.crumb("ИИ: инструмент \(name)")
								res = await toolbox.run(name, input)
							}
						}
						items.append(.init(.tool, res.summary, detail: String(res.output.prefix(6000)), failed: res.isError))
						if ToolBox.canonical(name) == "todowrite" { todos = toolbox.todos }
						results.append(["type": "tool_result", "tool_use_id": id, "content": res.output, "is_error": res.isError])
					default: break
					}
				}
				save()
				if !results.isEmpty { messages.append(["role": "user", "content": results]) }
				if abort {
					items.append(.init(.error, L("The model got stuck repeating one action — stopped. Clarify the task or switch models.")))
					return
				}
				if results.isEmpty {
					if truncated { items.append(.init(.error, L("The response was cut off by length. Say “continue”."))) }
					else if r.content.isEmpty { items.append(.init(.error, L("The model returned an empty response."))) }
					return
				}
				try Task.checkCancellation()
			}
			items.append(.init(.info, L("100 steps in a row — pausing. Say “continue” to go on.")))
		} catch is CancellationError {
			items.append(.init(.info, L("Stopped")))
		} catch let e as URLError where e.code == .cancelled {
			items.append(.init(.info, L("Stopped")))
		} catch {
			items.append(.init(.error, error.localizedDescription))
		}
	}

	private static func stableJSON(_ v: [String: Any]) -> String {
		(try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
	}

	/// Когда история разрастается, старые результаты инструментов заменяются заглушкой (как prune в opencode).
	/// Только для OpenAI-совместимых: у Claude правка истории ломает кэш и thinking-блоки, а контекст и так 1M.
	private func pruneIfNeeded(_ p: Provider) {
		guard p.kind == .openai else { return }
		let size = (try? JSONSerialization.data(withJSONObject: messages).count) ?? 0
		guard size > 280_000 else { return }  // ≈ 80k токенов
		let keepFrom = max(0, messages.count - 8)
		for i in 0..<keepFrom {
			guard var blocks = messages[i]["content"] as? [[String: Any]] else { continue }
			var changed = false
			for j in blocks.indices where blocks[j]["type"] as? String == "tool_result" {
				if let c = blocks[j]["content"] as? String, c.count > 300 {
					blocks[j]["content"] = "[old tool output cleared to save context — call the tool again if you need it]"
					changed = true
				}
			}
			if changed { messages[i]["content"] = blocks }
		}
	}

	// MARK: сохранение чата

	private func save() {
		let its = items.map { i -> [String: Any] in
			var d: [String: Any] = ["kind": i.kind.rawValue, "text": i.text]
			if let det = i.detail { d["detail"] = det }
			if i.failed { d["failed"] = true }
			return d
		}
		var j: [String: Any] = ["messages": messages, "items": its,
		                        "todos": todos.map { ["id": $0.id, "content": $0.content, "status": $0.status] }]
		if let system { j["system"] = system; j["systemModel"] = systemModel }
		if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: chatURL, options: .atomic) }
	}

	private func load() {
		guard let d = try? Data(contentsOf: chatURL),
		      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
		messages = j["messages"] as? [[String: Any]] ?? []
		items = (j["items"] as? [[String: Any]] ?? []).compactMap { i in
			guard let k = ChatItem.Kind(rawValue: i["kind"] as? String ?? ""), let t = i["text"] as? String else { return nil }
			return ChatItem(k, t, detail: i["detail"] as? String, failed: i["failed"] as? Bool ?? false)
		}
		todos = (j["todos"] as? [[String: String]] ?? []).map {
			Todo(id: $0["id"] ?? UUID().uuidString, content: $0["content"] ?? "", status: $0["status"] ?? "pending")
		}
		toolbox.todos = todos
		system = j["system"] as? String
		systemModel = j["systemModel"] as? String ?? ""
	}
}
