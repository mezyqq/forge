import SwiftUI
import UIKit

/// Ссылка на UITextView для кнопок SwiftUI (поиск, переход к строке).
final class EditorHandle {
	weak var tv: UITextView?

	func find(replace: Bool) {
		tv?.findInteraction?.presentFindNavigator(showingReplace: replace)
	}

	func go(toLine n: Int) {
		guard let tv else { return }
		let ns = tv.text as NSString
		var loc = 0, line = 1
		while line < n, loc < ns.length {
			let r = ns.range(of: "\n", range: NSRange(location: loc, length: ns.length - loc))
			if r.location == NSNotFound { break }
			loc = r.location + 1
			line += 1
		}
		tv.becomeFirstResponder()
		tv.selectedRange = NSRange(location: loc, length: 0)
		tv.scrollRangeToVisible(tv.selectedRange)
	}
}

/// Редактор кода: подсветка, номера строк, автоотступ, поиск/замена, панель символов над клавиатурой.
struct CodeEditor: UIViewRepresentable {
	@Binding var text: String
	let lang: Lang
	let fontSize: CGFloat
	let lineNumbers: Bool
	var theme: Theme = Theme.all[0]
	var errorLine: Int? = nil
	let handle: EditorHandle

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeUIView(context: Context) -> CodeTextView {
		// TextKit 1 (нужен layoutManager для номеров строк). Стек собираем сами и зовём обычный init подкласса:
		// фабрика UITextView(usingTextLayoutManager:) не гарантирует, что вернёт именно CodeTextView.
		let storage = NSTextStorage()
		let layout = NSLayoutManager()
		storage.addLayoutManager(layout)
		let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
		container.widthTracksTextView = true
		layout.addTextContainer(container)
		let tv = CodeTextView(frame: .zero, textContainer: container)
		tv.autocorrectionType = .no
		tv.autocapitalizationType = .none
		tv.spellCheckingType = .no
		tv.smartQuotesType = .no
		tv.smartDashesType = .no
		tv.smartInsertDeleteType = .no
		tv.keyboardDismissMode = .interactive
		tv.alwaysBounceVertical = true
		tv.isFindInteractionEnabled = true
		tv.delegate = context.coordinator
		tv.inputAccessoryView = KeyBar(target: tv)
		handle.tv = tv
		apply(tv, force: true)
		return tv
	}

	func updateUIView(_ tv: CodeTextView, context: Context) {
		context.coordinator.parent = self
		handle.tv = tv
		apply(tv, force: false)
	}

	private func apply(_ tv: CodeTextView, force: Bool) {
		if tv.errorLine != errorLine { tv.errorLine = errorLine; tv.setNeedsDisplay() }
		let styleChanged = tv.fontSize != fontSize || tv.showLines != lineNumbers || tv.langName != lang.name || tv.theme != theme
		guard force || styleChanged || tv.text != text else { return }
		tv.fontSize = fontSize
		tv.showLines = lineNumbers
		tv.langName = lang.name
		if tv.theme != theme || force { tv.apply(theme) }
		if tv.text != text {
			let sel = tv.selectedRange
			tv.text = text
			tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
		}
		Syntax.highlight(tv, lang: lang, size: fontSize, theme: theme)
		tv.updateGutter()
	}

	final class Coordinator: NSObject, UITextViewDelegate {
		var parent: CodeEditor
		init(_ p: CodeEditor) { parent = p }

		func textViewDidChange(_ tv: UITextView) {
			Syntax.highlight(tv, lang: parent.lang, size: parent.fontSize, theme: parent.theme)
			(tv as? CodeTextView)?.updateGutter()
			parent.text = tv.text
		}

		// Enter: повторяем отступ строки, после «{ ( [ :» — на таб больше
		func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText s: String) -> Bool {
			guard s == "\n" else { return true }
			let ns = tv.text as NSString
			let start = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
			let line = ns.substring(with: NSRange(location: start, length: range.location - start))
			var indent = String(line.prefix { $0 == " " || $0 == "\t" })
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if let last = trimmed.last, "{([".contains(last) || (last == ":" && parent.lang.name == "Python") { indent += "\t" }
			tv.insertText("\n" + indent)
			return false
		}
	}
}

/// UITextView с номерами строк слева. Номера рисуются в draw(_:) под текстом, в области отступа.
final class CodeTextView: UITextView {
	var fontSize: CGFloat = 14
	var showLines = true
	var langName = ""
	var theme = Theme.all[0]
	var errorLine: Int?
	private var gutter: CGFloat = 0

	func apply(_ t: Theme) {
		theme = t
		backgroundColor = t.bg
		tintColor = UIColor(t.accentColor)
		overrideUserInterfaceStyle = t.style ?? .unspecified
		keyboardAppearance = t.style == .dark ? .dark : .default
		setNeedsDisplay()
	}

	func updateGutter() {
		let lines = max(1, text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } })
		let digits = CGFloat(max(2, String(lines).count))
		let w = showLines ? digits * (fontSize * 0.62) + 14 : 0
		if w != gutter {
			gutter = w
			textContainerInset = UIEdgeInsets(top: 8, left: w + 4, bottom: 8, right: 4)
		}
		setNeedsDisplay()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		setNeedsDisplay()  // перерисовать номера при прокрутке
	}

	override func draw(_ rect: CGRect) {
		super.draw(rect)
		guard showLines, gutter > 0 else { return }
		let visible = CGRect(origin: contentOffset, size: bounds.size)
		theme.gutter.setFill()
		UIRectFill(CGRect(x: 0, y: visible.minY, width: gutter, height: visible.height))

		let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize * 0.8, weight: .regular)
		let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.color(.comment)]
		let ns = text as NSString
		let lm = layoutManager
		let inset = textContainerInset
		let area = visible.offsetBy(dx: -inset.left, dy: -inset.top)
		let glyphs = lm.glyphRange(forBoundingRect: area, in: textContainer)

		func draw(_ n: Int, _ frag: CGRect) {
			let s = "\(n)" as NSString
			let sz = s.size(withAttributes: attrs)
			s.draw(at: CGPoint(x: gutter - 6 - sz.width, y: frag.minY + inset.top + (frag.height - sz.height) / 2), withAttributes: attrs)
		}

		var lineNo = 1
		if glyphs.length > 0 {
			let first = lm.characterIndexForGlyph(at: glyphs.location)
			var newlines = 0
			var i = 0
			while i < first { if ns.character(at: i) == 10 { newlines += 1 }; i += 1 }
			let firstIsStart = first == 0 || ns.character(at: first - 1) == 10
			lineNo = newlines + (firstIsStart ? 1 : 2)
			lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
				let ci = lm.characterIndexForGlyph(at: gr.location)
				if ci == 0 || ns.character(at: ci - 1) == 10 {
					if lineNo == self.errorLine {
						UIColor.systemRed.withAlphaComponent(0.18).setFill()
						UIRectFill(CGRect(x: 0, y: frag.minY + inset.top, width: self.bounds.width, height: frag.height))
					}
					draw(lineNo, frag)
					lineNo += 1
				}
			}
		}
		// пустая последняя строка после завершающего \n
		let extra = lm.extraLineFragmentRect
		if extra.height > 0, extra.offsetBy(dx: inset.left, dy: inset.top).intersects(visible) {
			draw(ns.length == 0 ? 1 : text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }, extra)
		}
	}
}

/// Панель над клавиатурой: отмена/повтор, таб и символы, которых нет на первом экране iOS-клавиатуры.
final class KeyBar: UIInputView {
	init(target: UITextView) {
		super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
		autoresizingMask = .flexibleWidth

		let scroll = UIScrollView()
		scroll.showsHorizontalScrollIndicator = false
		let stack = UIStackView()
		stack.spacing = 6
		stack.alignment = .center

		func button(_ title: String? = nil, image: String? = nil, _ action: @escaping () -> Void) -> UIButton {
			var c = UIButton.Configuration.gray()
			c.title = title
			if let image { c.image = UIImage(systemName: image) }
			c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
			c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
				var a = $0; a.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium); return a
			}
			return UIButton(configuration: c, primaryAction: UIAction { _ in action() })
		}

		stack.addArrangedSubview(button(image: "arrow.uturn.backward") { [weak target] in target?.undoManager?.undo() })
		stack.addArrangedSubview(button(image: "arrow.uturn.forward") { [weak target] in target?.undoManager?.redo() })
		stack.addArrangedSubview(button("⇥") { [weak target] in target?.insertText("\t") })
		for k in ["{", "}", "(", ")", "[", "]", ";", "\"", "=", "<", ">", "*", "&", "|", "!", "#", "@", "_", "/", "\\",
		          ":", "'", "+", "-", "%", "^", "~", "$", "`", "?"] {
			stack.addArrangedSubview(button(k) { [weak target] in target?.insertText(k) })
		}

		let hide = button(image: "keyboard.chevron.compact.down") { [weak target] in target?.resignFirstResponder() }
		for v in [scroll, stack, hide] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
		addSubview(scroll)
		addSubview(hide)
		scroll.addSubview(stack)
		NSLayoutConstraint.activate([
			hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			hide.centerYAnchor.constraint(equalTo: centerYAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
			scroll.topAnchor.constraint(equalTo: topAnchor),
			scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
			stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
			stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
			stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
			stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
		])
	}

	required init?(coder: NSCoder) { fatalError() }
}
