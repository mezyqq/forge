import SwiftUI
import UIKit

/// Ссылка на UITextView для кнопок SwiftUI (поиск, переход к строке).
final class EditorHandle {
	weak var tv: UITextView?

	func find(replace: Bool) {
		tv?.findInteraction?.presentFindNavigator(showingReplace: replace)
	}

	/// Заменить весь текст (с отменой), курсор — примерно на прежнем месте.
	func replaceAll(with s: String) {
		guard let tv, let all = tv.textRange(from: tv.beginningOfDocument, to: tv.endOfDocument) else { return }
		let sel = tv.selectedRange
		tv.replace(all, withText: s)
		tv.selectedRange = NSRange(location: min(sel.location, (s as NSString).length), length: 0)
		tv.delegate?.textViewDidChange?(tv)
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
	/// Автодополнение (clang): текст и позиция курсора (UTF-16) → варианты. nil — выключено.
	var completer: ((String, Int) async -> [Clang.Completion])? = nil
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
		let coord = context.coordinator
		tv.inputAccessoryView = KeyBar(target: tv, complete: completer == nil ? nil : { [weak tv, weak coord] in
			if let tv { coord?.scheduleCompletion(tv, force: true) }
		})
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
			scheduleCompletion(tv)
		}

		func textViewDidChangeSelection(_ tv: UITextView) {
			// курсор ушёл с дополняемого слова — прячем список
			guard let ctv = tv as? CodeTextView, let r = ctv.completionRange else { return }
			if tv.selectedRange.length > 0 || tv.selectedRange.location < r.location || tv.selectedRange.location > r.location + r.length + 1 {
				ctv.hideCompletions()
			}
		}

		func scrollViewDidScroll(_ sv: UIScrollView) {
			if sv.isDragging || sv.isDecelerating { (sv as? CodeTextView)?.hideCompletions() }
		}

		func textViewDidEndEditing(_ tv: UITextView) { (tv as? CodeTextView)?.hideCompletions() }

		private var completionTask: Task<Void, Never>?

		/// Автодополнение после паузы: от двух букв идентификатора, после «.» и «->»; force — по кнопке.
		func scheduleCompletion(_ tv: UITextView, force: Bool = false) {
			completionTask?.cancel()
			guard let completer = parent.completer, let ctv = tv as? CodeTextView else { return }
			if ctv.justAccepted { ctv.justAccepted = false; return }
			let sel = tv.selectedRange
			guard sel.length == 0 else { ctv.hideCompletions(); return }
			let ns = tv.text as NSString
			var start = sel.location
			while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)), u == "_" || CharacterSet.alphanumerics.contains(u), u.isASCII { start -= 1 }
			let prefix = ns.substring(with: NSRange(location: start, length: sel.location - start))
			let before = start > 0 ? ns.character(at: start - 1) : 0
			let member = before == 46 || (before == 62 && start >= 2 && ns.character(at: start - 2) == 45)  // . или ->
			guard force || prefix.count >= 2 || member, !(prefix.first?.isNumber ?? false) else { ctv.hideCompletions(); return }
			let text = tv.text ?? "", offset = sel.location
			completionTask = Task { @MainActor in
				if !force { try? await Task.sleep(nanoseconds: 350_000_000) }
				guard !Task.isCancelled else { return }
				let items = await completer(text, offset)
				guard !Task.isCancelled, tv.text == text, tv.selectedRange.location == offset else { return }
				let p = prefix.lowercased()
				ctv.showCompletions(items.filter { p.isEmpty || $0.name.lowercased().hasPrefix(p) }, replacing: NSRange(location: start, length: offset - start))
			}
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

	// автодополнение
	private(set) var completionRange: NSRange?
	private var completionList: CompletionList?
	var justAccepted = false

	func showCompletions(_ items: [Clang.Completion], replacing r: NSRange) {
		guard !items.isEmpty, let pos = selectedTextRange?.end else { hideCompletions(); return }
		completionRange = r
		let list = completionList ?? CompletionList { [weak self] in self?.accept($0) }
		// в родителе, а не в самом UITextView: иначе его жесты выделения перехватывают нажатия по списку
		let host = superview ?? self
		completionList = list
		if list.superview !== host { list.removeFromSuperview(); host.addSubview(list) }
		list.items = items
		let caret = caretRect(for: pos)
		let rowH: CGFloat = 34
		let h = rowH * CGFloat(min(items.count, 6)), w = min(bounds.width - 16, 380)
		var y = caret.maxY + 4
		// не влезает над клавиатурой — показываем над курсором
		if y + h > contentOffset.y + bounds.height - adjustedContentInset.bottom { y = caret.minY - h - 4 }
		list.frame = convert(CGRect(x: max(8, min(caret.minX - 24, bounds.width - w - 8)), y: y, width: w, height: h), to: host)
		host.bringSubviewToFront(list)
		list.rowHeight = rowH
		list.fontSize = fontSize
		list.reloadData()
		list.setContentOffset(.zero, animated: false)
		list.isHidden = false
	}

	func hideCompletions() {
		completionRange = nil
		completionList?.isHidden = true
	}

	/// Вставка варианта вместо набранного префикса; первый параметр <#…#> выделяется.
	private func accept(_ c: Clang.Completion) {
		guard let r = completionRange, r.location + r.length <= (text as NSString).length else { hideCompletions(); return }
		hideCompletions()
		justAccepted = true
		let ins = c.insert.isEmpty ? c.name : c.insert
		selectedRange = r
		insertText(ins)
		let p = (ins as NSString).range(of: "<#")
		if p.location != NSNotFound {
			let e = (ins as NSString).range(of: "#>", range: NSRange(location: p.location, length: (ins as NSString).length - p.location))
			if e.location != NSNotFound { selectedRange = NSRange(location: r.location + p.location, length: e.location + 2 - p.location) }
		}
	}

	/// Выделить следующий параметр <#…#> на текущей строке; false — нет такого.
	func selectNextPlaceholder() -> Bool {
		let ns = text as NSString
		let from = selectedRange.location + selectedRange.length
		let line = ns.lineRange(for: NSRange(location: min(from, ns.length), length: 0))
		var search = NSRange(location: from, length: max(0, line.location + line.length - from))
		var p = ns.range(of: "<#", range: search)
		if p.location == NSNotFound {
			// курсор уже за последним — с начала строки
			search = NSRange(location: line.location, length: line.length)
			p = ns.range(of: "<#", range: search)
		}
		guard p.location != NSNotFound else { return false }
		let e = ns.range(of: "#>", range: NSRange(location: p.location, length: line.location + line.length - p.location))
		guard e.location != NSNotFound else { return false }
		selectedRange = NSRange(location: p.location, length: e.location + 2 - p.location)
		return true
	}

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

	override func traitCollectionDidChange(_ previous: UITraitCollection?) {
		super.traitCollectionDidChange(previous)
		setNeedsDisplay()  // гуттер и номера строк — в цветах нового оформления
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
	init(target: UITextView, complete: (() -> Void)? = nil) {
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
		// ⇥: сначала — к следующему параметру <#…#> автодополнения, иначе таб
		stack.addArrangedSubview(button("⇥") { [weak target] in
			if (target as? CodeTextView)?.selectNextPlaceholder() == true { return }
			target?.insertText("\t")
		})
		if let complete { stack.addArrangedSubview(button(image: "text.badge.plus") { complete() }) }
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

/// Всплывающий список автодополнения под курсором.
final class CompletionList: UITableView, UITableViewDataSource, UITableViewDelegate {
	var items: [Clang.Completion] = []
	var fontSize: CGFloat = 14
	private let onPick: (Clang.Completion) -> Void

	init(onPick: @escaping (Clang.Completion) -> Void) {
		self.onPick = onPick
		super.init(frame: .zero, style: .plain)
		dataSource = self
		delegate = self
		layer.cornerRadius = 10
		layer.borderWidth = 0.5
		layer.borderColor = UIColor.separator.cgColor
		backgroundColor = .secondarySystemBackground
		separatorStyle = .none
		register(UITableViewCell.self, forCellReuseIdentifier: "c")
	}

	required init?(coder: NSCoder) { fatalError() }

	func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { items.count }

	func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
		let cell = t.dequeueReusableCell(withIdentifier: "c", for: ip)
		let c = items[ip.row]
		var cfg = UIListContentConfiguration.valueCell()
		let (icon, color) = CompletionList.style(c.kind)
		cfg.image = UIImage(systemName: icon)
		cfg.imageProperties.tintColor = color
		cfg.imageProperties.maximumSize = CGSize(width: 18, height: 18)
		let label = NSMutableAttributedString(string: c.label.isEmpty ? c.name : c.label,
		                                      attributes: [.font: UIFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular),
		                                                   .foregroundColor: UIColor.secondaryLabel])
		let nameRange = (label.string as NSString).range(of: c.name)
		if nameRange.location != NSNotFound {
			label.addAttributes([.foregroundColor: UIColor.label, .font: UIFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .semibold)], range: nameRange)
		}
		cfg.attributedText = label
		cfg.textProperties.numberOfLines = 1
		cfg.textProperties.lineBreakMode = .byTruncatingTail
		cfg.secondaryText = c.result
		cfg.secondaryTextProperties.font = .monospacedSystemFont(ofSize: fontSize * 0.75, weight: .regular)
		cfg.secondaryTextProperties.color = .tertiaryLabel
		cfg.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
		cell.contentConfiguration = cfg
		cell.backgroundColor = .clear
		return cell
	}

	func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
		t.deselectRow(at: ip, animated: false)
		onPick(items[ip.row])
	}

	/// Значок по виду объявления clang.
	static func style(_ kind: String) -> (String, UIColor) {
		switch kind {
		case "Function", "FunctionTemplate": return ("f.square.fill", .systemPurple)
		case "ObjCMethod", "CXXMethod", "CXXConstructor": return ("m.square.fill", .systemBlue)
		case "ObjCProperty", "Field", "ObjCIvar": return ("p.square.fill", .systemTeal)
		case "Var", "ParmVar": return ("v.square.fill", .systemGreen)
		case "EnumConstant": return ("e.square.fill", .systemOrange)
		case "Typedef", "Record", "CXXRecord", "Enum", "ObjCInterface", "ObjCProtocol", "ClassTemplate", "TypeAlias":
			return ("t.square.fill", .systemPink)
		case "macro": return ("number.square.fill", .systemBrown)
		case "keyword": return ("k.square.fill", .systemGray)
		default: return ("chevron.left.forwardslash.chevron.right", .systemGray)
		}
	}
}
