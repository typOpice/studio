import SwiftUI
import AppKit

/// A plain-text code editor backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` cannot be used here: it is driven by a `Binding`, so every
/// keystroke writes to the scene model, the model republishes, and the text view has
/// its whole string re-assigned — which collapses the insertion point to the end of
/// the document. This view pushes edits out through `onChange` and only ever writes
/// text *in* when it genuinely differs from what is on screen, preserving the
/// selection when it does. It also turns off the smart quote and dash substitutions
/// that would otherwise silently corrupt Wren string literals as you type.
/// `NSTextView` with the completion behaviour the editor needs.
///
/// AppKit's completion panel only shows plain strings, so each suggestion is listed as
/// `label  ·  detail` and the coordinator maps that display string back to the text to
/// actually insert.
final class CodeTextView: NSTextView {
    weak var source: CodeEditor.Coordinator?

    /// The identifier characters immediately before the caret — empty right after a
    /// dot, which is what makes member completion insert at the caret.
    override var rangeForUserCompletion: NSRange {
        WrenCompletion.partialWordRange(in: string, caret: selectedRange().location)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal: Bool) {
        let actual = source?.insertion(forDisplay: word) ?? word
        super.insertCompletion(actual, forPartialWordRange: charRange,
                               movement: movement, isFinal: isFinal)
    }

    /// ⌘F and ⌘G, which the menu hands here while the editor has the keyboard.
    func showFindBar() { performTextFinderAction(Self.finderItem(.showFindInterface)) }
    func findNext() { performTextFinderAction(Self.finderItem(.nextMatch)) }

    /// `performTextFinderAction` reads which action from its sender's tag.
    private static func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }

    /// Selects a 1-based line and scrolls it into view — where an error happened.
    func reveal(line: Int) {
        let text = string as NSString
        guard let range = LineNumbers.range(ofLine: line, in: text) else { return }
        setSelectedRange(range)
        scrollRangeToVisible(range)
        if window != nil { showFindIndicator(for: range) }
    }
}

/// Menu commands that mean something in text as well as in the world. While a code
/// editor has the keyboard they go to it, so ⌘Z undoes typing rather than the last part
/// moved, and ⌘⌫ deletes to the start of the line rather than the selected parts.
enum TextCommand {
    case undo, redo, selectAll, deleteToLineStart, find, findNext

    /// Carries the command out in the code editor that has the keyboard, if one does.
    /// False leaves it to the world.
    @discardableResult
    static func perform(_ command: TextCommand, in responder: NSResponder?) -> Bool {
        guard let code = responder as? CodeTextView else { return false }
        switch command {
        case .undo:
            if code.undoManager?.canUndo == true { code.undoManager?.undo() }
        case .redo:
            if code.undoManager?.canRedo == true { code.undoManager?.redo() }
        case .selectAll:
            code.selectAll(nil)
        case .deleteToLineStart:
            if code.isEditable { code.deleteToBeginningOfLine(nil) }
        case .find:
            code.showFindBar()
        case .findNext:
            code.findNext()
        }
        return true
    }
}

/// Line arithmetic for the gutter and for jumping to a line. Lines are counted from 1,
/// and a document ending in a newline has an empty last line, as editors show it.
enum LineNumbers {
    /// The line holding a character offset.
    static func line(atOffset offset: Int, in text: NSString) -> Int {
        let end = min(max(offset, 0), text.length)
        var line = 1
        var index = 0
        while index < end {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: end - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }

    static func count(in text: NSString) -> Int { line(atOffset: text.length, in: text) }

    /// A line's characters, without its newline; nil for a line the text doesn't have.
    static func range(ofLine line: Int, in text: NSString) -> NSRange? {
        guard line >= 1 else { return nil }
        var start = 0
        var current = 1
        while current < line {
            let found = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { return nil }
            start = found.location + 1
            current += 1
        }
        let rest = NSRange(location: start, length: text.length - start)
        let newline = text.range(of: "\n", options: [], range: rest)
        let end = newline.location == NSNotFound ? text.length : newline.location
        return NSRange(location: start, length: end - start)
    }
}

/// The line numbers down the left of a code editor, the caret's line brighter.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var digits = 0

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(refresh),
                           name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(refresh),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        refresh()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let color = NSColor(srgbRed: 0.45, green: 0.47, blue: 0.51, alpha: 1)
    static let currentColor = NSColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 1)
    static let background = NSColor(srgbRed: 0.115, green: 0.125, blue: 0.145, alpha: 1)

    /// Wide enough for the longest line number, and never narrower than three digits.
    static func thickness(forLines lines: Int) -> CGFloat {
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(max(3, String(lines).count)) * digitWidth + 18)
    }

    @objc func refresh() {
        let lines = textView.map { LineNumbers.count(in: $0.string as NSString) } ?? 1
        let needed = max(3, String(lines).count)
        if needed != digits {
            digits = needed
            ruleThickness = Self.thickness(forLines: lines)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = LineNumbers.line(atOffset: textView.selectedRange().location, in: text)
        // Line up each number's baseline with its line's.
        let baseline = layout.defaultBaselineOffset(for: CodeEditor.font)

        func label(_ number: Int, top: CGFloat) {
            let y = convert(NSPoint(x: 0, y: top + origin.y), from: textView).y
            guard y + 20 >= dirtyRect.minY, y - 20 <= dirtyRect.maxY else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: number == caretLine ? Self.currentColor : Self.color
            ]
            let string = "\(number)" as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(at: NSPoint(x: bounds.width - 9 - size.width, y: y + baseline - Self.font.ascender),
                        withAttributes: attributes)
        }

        var number = LineNumbers.line(atOffset: characters.location, in: text)
        var index = text.lineRange(for: NSRange(location: min(characters.location, text.length), length: 0)).location
        let end = NSMaxRange(characters)
        while index < text.length && index <= end {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: line.location),
                                                   effectiveRange: nil)
            label(number, top: fragment.minY)
            number += 1
            index = NSMaxRange(line)
        }
        // The empty line after a final newline, or in an empty document, has a number too.
        if index >= text.length, text.length == 0 || text.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { label(number, top: extra.minY) }
        }
    }
}

/// Keeps each open tab's text view — its caret, scroll position and undo history —
/// while another tab is in front. SwiftUI builds a fresh `CodeEditor` each time a tab
/// comes forward; the text view it shows comes from here.
final class CodeEditorCache {
    final class Entry {
        let scrollView: NSScrollView
        let textView: CodeTextView
        /// This document's own undo history, apart from every other tab's.
        let undo = UndoManager()

        init(scrollView: NSScrollView, textView: CodeTextView) {
            self.scrollView = scrollView
            self.textView = textView
        }
    }

    private var entries: [String: Entry] = [:]

    func entry(for key: String) -> Entry? { entries[key] }
    func store(_ entry: Entry, for key: String) { entries[key] = entry }
    func forget(_ key: String) { entries.removeValue(forKey: key) }
    var count: Int { entries.count }
}

struct CodeEditor: NSViewRepresentable {
    let text: String
    var isEditable: Bool = true
    var indentWidth: Int = 2
    var language: CodeLanguage = .luau
    /// What to suggest at a caret position. Supplied by the owner so the shader
    /// editor can offer the parameters that particular shader declares.
    var completions: (String, Int) -> [CompletionItem] = { LuauCompletion.items(in: $0, caret: $1) }
    /// With both, the text view outlives this view and comes back as it was left: the
    /// tabs use this so switching between them loses nothing.
    var cache: CodeEditorCache? = nil
    var cacheKey: String? = nil
    var showsLineNumbers: Bool = false
    /// Takes the keyboard when it appears, as a tab brought to the front should.
    var focusOnAppear: Bool = false
    /// A line to select and scroll to; each new request is acted on once.
    var reveal: CodeReveal? = nil
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, indentWidth: indentWidth,
                    language: language, completions: completions)
    }

    /// A plain container around the scroll view, so a cached scroll view can move from
    /// the container that showed it last time into this one.
    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let entry: CodeEditorCache.Entry
        if let cache, let cacheKey, let kept = cache.entry(for: cacheKey) {
            entry = kept
        } else {
            entry = Self.makeEntry()
            entry.textView.string = text
            if let cache, let cacheKey { cache.store(entry, for: cacheKey) }
        }
        coordinator.entry = entry
        let textView = entry.textView
        textView.source = coordinator
        textView.delegate = coordinator
        textView.isEditable = isEditable
        // Whatever changed while the tab was away — the text, or its language — shows now.
        Self.syncText(text, into: textView, coordinator: coordinator)
        Self.highlight(textView, language: language)
        coordinator.lastLength = (textView.string as NSString).length
        Self.setLineNumbers(showsLineNumbers, on: entry)
        coordinator.lastReveal = reveal?.token

        let container = NSView()
        entry.scrollView.frame = container.bounds
        entry.scrollView.autoresizingMask = [.width, .height]
        container.addSubview(entry.scrollView)

        let line = reveal?.line
        if focusOnAppear || line != nil {
            // Once the container is in a window.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                if let line { textView.reveal(line: line) }
            }
        }
        return container
    }

    /// A scroll view and text view configured for code, not yet showing anything.
    static func makeEntry() -> CodeEditorCache.Entry {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.background

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: scrollView.contentSize.width,
                                                             height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize),
                                    textContainer: container)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        Self.configure(textView)
        scrollView.documentView = textView
        return CodeEditorCache.Entry(scrollView: scrollView, textView: textView)
    }

    static func setLineNumbers(_ shown: Bool, on entry: CodeEditorCache.Entry) {
        let scrollView = entry.scrollView
        if shown, !(scrollView.verticalRulerView is LineNumberRuler) {
            scrollView.verticalRulerView = LineNumberRuler(textView: entry.textView, scrollView: scrollView)
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        } else if !shown, scrollView.rulersVisible {
            scrollView.rulersVisible = false
        }
    }

    /// Repaints the syntax colours for whatever the view currently holds.
    static func highlight(_ textView: NSTextView, language: CodeLanguage = .luau) {
        guard let storage = textView.textStorage else { return }
        SyntaxTheme.highlight(storage, baseFont: font, language: language)
        textView.typingAttributes = [.font: font, .foregroundColor: foreground]
    }

    /// Applies the code-editor appearance and turns off every input substitution.
    /// Smart quotes in particular would turn `"studio"` into curly quotes and break
    /// the script the moment it was typed.
    static func configure(_ textView: NSTextView) {
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = font
        textView.textColor = foreground
        textView.backgroundColor = background
        textView.drawsBackground = true
        textView.insertionPointColor = insertionPoint
        textView.selectedTextAttributes = [.backgroundColor: selection]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // The gutter is ours; the text view's own paragraph ruler would fight it.
        textView.usesRuler = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Typing attributes matter too, or newly typed text reverts to the system font.
        textView.typingAttributes = [.font: font, .foregroundColor: foreground]
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        guard let entry = coordinator.entry else { return }
        let textView = entry.textView
        let languageChanged = coordinator.language != language
        coordinator.onChange = onChange
        coordinator.indentWidth = indentWidth
        coordinator.language = language
        coordinator.completions = completions

        let replaced = Self.syncText(text, into: textView, coordinator: coordinator)
        if languageChanged && !replaced { Self.highlight(textView, language: language) }

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        Self.setLineNumbers(showsLineNumbers, on: entry)
        if let reveal, reveal.token != coordinator.lastReveal {
            coordinator.lastReveal = reveal.token
            textView.window?.makeFirstResponder(textView)
            textView.reveal(line: reveal.line)
        }
    }

    /// Writes `text` into the view only when it differs from what is already there.
    ///
    /// This is the whole fix for the caret jumping to the end of the document: while
    /// the user types, the round trip through the model hands back the identical
    /// string, so there is nothing to do and the insertion point is left alone.
    /// Returns true when the contents were actually replaced.
    @discardableResult
    static func syncText(_ text: String, into textView: NSTextView, coordinator: Coordinator?) -> Bool {
        guard textView.string != text else { return false }
        let selected = textView.selectedRange()
        coordinator?.isApplyingExternalChange = true
        textView.string = text
        coordinator?.isApplyingExternalChange = false
        highlight(textView, language: coordinator?.language ?? .luau)
        textView.setSelectedRange(clamp(selected, to: text))
        return true
    }

    /// Keeps a selection inside the bounds of newly assigned text.
    static func clamp(_ range: NSRange, to text: String) -> NSRange {
        let limit = (text as NSString).length
        let location = min(max(range.location, 0), limit)
        let length = min(range.length, limit - location)
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var indentWidth: Int
        var language: CodeLanguage
        var completions: (String, Int) -> [CompletionItem]
        var isApplyingExternalChange = false
        var lastLength = 0
        /// The text view this coordinator is driving, and the undo history that goes with it.
        var entry: CodeEditorCache.Entry?
        var lastReveal: UUID?
        /// For a text view built without an entry, as the tests do.
        private lazy var ownUndo = UndoManager()

        /// Display string → text to insert, rebuilt each time the panel is populated.
        private var insertions: [String: String] = [:]

        init(onChange: @escaping (String) -> Void, indentWidth: Int,
             language: CodeLanguage = .luau,
             completions: @escaping (String, Int) -> [CompletionItem] = {
                 LuauCompletion.items(in: $0, caret: $1)
             }) {
            self.onChange = onChange
            self.indentWidth = indentWidth
            self.language = language
            self.completions = completions
        }

        func insertion(forDisplay display: String) -> String {
            insertions[display] ?? display
        }

        /// Each document keeps its own history, so ⌘Z in one tab never unpicks another.
        func undoManager(for view: NSTextView) -> UndoManager? {
            entry?.undo ?? ownUndo
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let textView = notification.object as? NSTextView else { return }

            CodeEditor.highlight(textView, language: language)
            onChange(textView.string)

            let length = (textView.string as NSString).length
            let grew = length > lastLength
            lastLength = length
            if grew { offerCompletions(in: textView) }
        }

        /// Pops the suggestion list after a dot, or once a word is two characters long.
        /// Deliberately restrained: firing on every single keystroke is noise.
        private func offerCompletions(in textView: NSTextView) {
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= text.length else { return }

            let previous = text.character(at: caret - 1)
            let isDot = previous == UInt16(UInt8(ascii: "."))
            let word = WrenCompletion.partialWordRange(in: textView.string, caret: caret)
            guard isDot || word.length >= 2 else { return }
            guard !language.isInCommentOrString(offset: caret, in: textView.string) else { return }

            // Out of the current edit cycle, or the text system is still mid-update.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window?.firstResponder === textView else { return }
                textView.complete(nil)
            }
        }

        // MARK: Completion source

        func textView(_ textView: NSTextView, completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let caret = charRange.location + charRange.length
            let items = completions(textView.string, caret)
            guard !items.isEmpty else { return [] }

            insertions = [:]
            var displays: [String] = []
            for item in items {
                // A unique display string per item, since the map is keyed on it.
                var display = item.detail.isEmpty ? item.label : "\(item.label)  ·  \(item.detail)"
                var attempt = 2
                while insertions[display] != nil {
                    display = "\(item.label)  ·  \(item.detail) (\(attempt))"
                    attempt += 1
                }
                insertions[display] = item.insert
                displays.append(display)
            }
            index?.pointee = 0
            return displays
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                // Tab indents instead of moving focus out of the editor.
                let unit = language == .luau ? "\t" : String(repeating: " ", count: indentWidth)
                textView.insertText(unit,
                                    replacementRange: textView.selectedRange())
                return true

            case #selector(NSResponder.insertNewline(_:)):
                let indent = Coordinator.leadingWhitespace(in: textView.string,
                                                           before: textView.selectedRange().location)
                guard !indent.isEmpty else { return false }
                textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
                return true

            default:
                return false
            }
        }

        /// The indentation of the line containing `location`, carried onto the next line.
        static func leadingWhitespace(in text: String, before location: Int) -> String {
            let ns = text as NSString
            let safe = min(max(location, 0), ns.length)
            let lineStart = ns.lineRange(for: NSRange(location: safe, length: 0)).location
            var index = lineStart
            var indent = ""
            while index < safe {
                let character = ns.character(at: index)
                if character == 32 || character == 9 {
                    indent.append(Character(UnicodeScalar(character) ?? " "))
                    index += 1
                } else {
                    break
                }
            }
            return indent
        }
    }

    // MARK: - Appearance

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let foreground = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1)
    static let background = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
    static let insertionPoint = NSColor(srgbRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)
    static let selection = NSColor(srgbRed: 0.25, green: 0.40, blue: 0.62, alpha: 0.75)
}
