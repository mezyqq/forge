import SwiftUI
import UIKit

struct ChatView: View {
	@ObservedObject var agent: Agent
	@ObservedObject private var ps = Providers.shared
	@State private var input = ""
	@State private var showTodos = true

	var body: some View {
		VStack(spacing: 0) {
			modelBar
			Divider()
			if !agent.todos.isEmpty { todoPanel; Divider() }
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 10) {
						if agent.items.isEmpty {
							Text(L("Ask the AI to do something in the project: “add a settings screen”, “find and fix the bug in main.py”, “organize the code into folders”"))
								.foregroundStyle(.secondary)
						}
						ForEach(agent.items) { Bubble(item: $0).id($0.id) }
						if agent.busy {
							if !agent.liveReasoning.isEmpty {
								Text(agent.liveReasoning)
									.font(.caption).italic()
									.foregroundStyle(.secondary)
									.lineLimit(4)
							}
							if !agent.live.isEmpty {
								Text(Bubble.markdown(agent.live)).textSelection(.enabled)
							}
							HStack(spacing: 8) {
								ProgressView()
								Text(agent.status.isEmpty ? L("working…") : agent.status).font(.footnote).foregroundStyle(.secondary)
							}
						}
						if agent.canRetry {
							Button { agent.retry() } label: { Label(L("Retry"), systemImage: "arrow.clockwise") }
								.buttonStyle(.bordered)
						}
						Color.clear.frame(height: 1).id("end")
					}
					.padding()
				}
				.scrollDismissesKeyboard(.interactively)
				.onChange(of: agent.items.count) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
				.onChange(of: agent.live.count / 80) { _ in proxy.scrollTo("end", anchor: .bottom) }
				.onAppear { proxy.scrollTo("end", anchor: .bottom) }
			}
			Divider()
			HStack(alignment: .bottom, spacing: 8) {
				TextField(L("What should I do?"), text: $input, axis: .vertical)
					.lineLimit(1...6)
					.textFieldStyle(.roundedBorder)
				if agent.busy {
					Button { agent.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
				} else {
					Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
						.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
			.padding(8)
		}
	}

	/// План задач, который ведёт модель через todowrite.
	private var todoPanel: some View {
		VStack(alignment: .leading, spacing: 4) {
			Button { withAnimation { showTodos.toggle() } } label: {
				HStack {
					Image(systemName: "checklist")
					let done = agent.todos.filter { $0.status == "completed" }.count
					Text(L("Plan: %@/%@", done, agent.todos.count)).font(.footnote.bold())
					Spacer()
					Image(systemName: showTodos ? "chevron.up" : "chevron.down").font(.caption)
				}
				.foregroundStyle(.primary)
			}
			if showTodos {
				ForEach(agent.todos) { t in
					HStack(alignment: .top, spacing: 6) {
						Image(systemName: t.status == "completed" ? "checkmark.circle.fill"
						                : t.status == "in_progress" ? "circle.dotted.circle"
						                : t.status == "cancelled" ? "xmark.circle" : "circle")
							.foregroundStyle(t.status == "completed" ? Color.green : t.status == "in_progress" ? Color.orange : Color.secondary)
						Text(t.content)
							.font(.footnote)
							.strikethrough(t.status == "completed" || t.status == "cancelled")
							.foregroundStyle(t.status == "completed" || t.status == "cancelled" ? .secondary : .primary)
					}
				}
			}
		}
		.padding(.horizontal)
		.padding(.vertical, 6)
		.background(Color(.secondarySystemBackground))
	}

	/// Быстрое переключение модели прямо из чата.
	private var modelBar: some View {
		Menu {
			ForEach(ps.list) { p in
				Menu(L(p.name) + (p.needsKey && ps.key(p).isEmpty ? L(" (no key)") : "")) {
					ForEach(p.models, id: \.self) { m in
						Button {
							ps.active = ModelRef(provider: p.id, model: m)
						} label: {
							if ps.active == ModelRef(provider: p.id, model: m) { Label(m, systemImage: "checkmark") } else { Text(m) }
						}
					}
				}
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "cpu")
				Text(ps.active.model).font(.footnote.monospaced()).lineLimit(1)
				Text("· \(L(ps.activeProvider?.name ?? "?"))").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
				Image(systemName: "chevron.up.chevron.down").font(.caption2)
			}
			.padding(.horizontal)
			.padding(.vertical, 6)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func send() {
		let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.isEmpty else { return }
		input = ""
		agent.send(t)
	}
}

struct Bubble: View {
	let item: ChatItem

	var body: some View {
		Group {
			switch item.kind {
			case .user:
				Text(item.text)
					.textSelection(.enabled)
					.padding(10)
					.background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
					.frame(maxWidth: .infinity, alignment: .trailing)
			case .assistant:
				VStack(alignment: .leading, spacing: 8) {
					ForEach(Bubble.segments(item.text)) { s in
						if s.code { CodeBlock(code: s.text) } else { Text(Bubble.markdown(s.text)).textSelection(.enabled) }
					}
				}
			case .tool:
				ToolRow(item: item)
			case .error:
				Label(item.text, systemImage: "exclamationmark.triangle")
					.font(.caption)
					.foregroundStyle(.red)
					.textSelection(.enabled)
			case .info:
				Label(item.text, systemImage: "info.circle")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.contextMenu {
			Button { UIPasteboard.general.string = item.text } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
		}
	}

	struct Segment: Identifiable {
		let id: Int
		let code: Bool
		let text: String
	}

	/// Делит ответ по ``` на обычный текст и блоки кода (первая строка блока — язык, отбрасываем).
	static func segments(_ s: String) -> [Segment] {
		s.components(separatedBy: "```").enumerated().compactMap { i, part in
			if i % 2 == 1 {
				var lines = part.components(separatedBy: "\n")
				if let first = lines.first, !first.contains(" ") { lines.removeFirst() }
				let code = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
				return Segment(id: i, code: true, text: code)
			}
			let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
			return t.isEmpty ? nil : Segment(id: i, code: false, text: t)
		}
	}

	static func markdown(_ s: String) -> AttributedString {
		(try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
	}
}

/// Вызов инструмента: краткая строка, по нажатию — что он вернул.
struct ToolRow: View {
	let item: ChatItem
	@State private var open = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Button { if item.detail != nil { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } } label: {
				HStack(spacing: 6) {
					Image(systemName: item.failed ? "exclamationmark.triangle" : "wrench.and.screwdriver")
					Text(item.text).lineLimit(open ? nil : 1)
					if item.detail != nil {
						Spacer(minLength: 4)
						Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2)
					}
				}
				.font(.caption.monospaced())
				.foregroundStyle(item.failed ? Color.orange : Color.secondary)
			}
			.buttonStyle(.plain)
			if open, let d = item.detail {
				ScrollView {
					Text(d)
						.font(.caption2.monospaced())
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(8)
				}
				.frame(maxHeight: 260)
				.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
			}
		}
	}
}

struct CodeBlock: View {
	let code: String
	@State private var copied = false

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			Text(code)
				.font(.system(.footnote, design: .monospaced))
				.textSelection(.enabled)
				.padding(10)
				.padding(.trailing, 28)
		}
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
		.overlay(alignment: .topTrailing) {
			Button {
				UIPasteboard.general.string = code
				copied = true
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
			} label: {
				Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption).padding(8)
			}
		}
	}
}
