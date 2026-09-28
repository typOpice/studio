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
/// `NSTextView` for code. Suggestions come from the editor's own `CompletionList`, not
/// AppKit's completion (see there for why).
final class CodeTextView: NSTextView {
    weak var source: CodeEditor.Coordinator?
    private var scrollObserver: NSObjectProtocol?

    /// ⌥Esc and F5, AppKit's keys for completion, open the list by hand.
    override func complete(_ sender: Any?) {
        source?.suggest(in: self, typed: false)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { source?.completionList.hide() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { source?.completionList.hide() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// The list stays under its word while the text scrolls, as it does when typing
    /// reaches the bottom.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.source?.completionList.follow(self)
        }
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

/// The line numbers down the left of a code editor, the caret's line brighter; the
/// debugger's breakpoints on them (click a number for one), and an arrow where the
/// game is stopped.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var digits = 0
    var breakpoints: Set<Int> = [] {
        didSet { if breakpoints != oldValue { needsDisplay = true } }
    }
    /// Those of them with a condition, drawn in orange, and logpoints, in blue.
    var conditional: Set<Int> = [] {
        didSet { if conditional != oldValue { needsDisplay = true } }
    }
    var logging: Set<Int> = [] {
        didSet { if logging != oldValue { needsDisplay = true } }
    }
    var pausedLine: Int? {
        didSet { if pausedLine != oldValue { needsDisplay = true } }
    }
    /// Clicking a line's number: nil where there are no breakpoints to set.
    var onToggle: ((Int) -> Void)?

    static let breakpointColor = NSColor(srgbRed: 0.86, green: 0.27, blue: 0.27, alpha: 1)
    static let conditionalColor = NSColor(srgbRed: 0.92, green: 0.52, blue: 0.16, alpha: 1)
    static let loggingColor = NSColor(srgbRed: 0.36, green: 0.66, blue: 0.95, alpha: 1)
    static let pausedColor = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.35, alpha: 1)

    /// The line at a point in the ruler, if there's one there.
    func line(at point: NSPoint) -> Int? {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let inText = convert(point, to: textView)
        let origin = textView.textContainerOrigin
        let text = textView.string as NSString
        let y = inText.y - origin.y
        if text.length == 0 || y > layout.usedRect(for: container).maxY {
            // Below the last line's fragment: the empty last line, if it's there.
            let extra = layout.extraLineFragmentRect
            return extra.height > 0 && y >= extra.minY && y <= extra.maxY ? LineNumbers.count(in: text) : nil
        }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let character = layout.characterIndexForGlyph(at: glyph)
        return LineNumbers.line(atOffset: character, in: text)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onToggle, let line = line(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onToggle(line)
    }

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
            let lineHeight = layout.defaultLineHeight(for: CodeEditor.font)
            let marked = breakpoints.contains(number)
            if marked {
                // A tab behind the number, pointing at the line, as Xcode draws one.
                let tag = NSRect(x: 3, y: y + 1, width: bounds.width - 6, height: lineHeight - 2)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: tag.minX + 2, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX - 5, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX, y: tag.midY))
                path.line(to: NSPoint(x: tag.maxX - 5, y: tag.maxY))
                path.line(to: NSPoint(x: tag.minX + 2, y: tag.maxY))
                path.close()
                (logging.contains(number) ? Self.loggingColor
                    : conditional.contains(number) ? Self.conditionalColor : Self.breakpointColor).setFill()
                path.fill()
            }
            if number == pausedLine {
                let arrow = NSBezierPath()
                let mid = y + lineHeight / 2
                arrow.move(to: NSPoint(x: 1, y: mid - 4))
                arrow.line(to: NSPoint(x: 7, y: mid))
                arrow.line(to: NSPoint(x: 1, y: mid + 4))
                arrow.close()
                Self.pausedColor.setFill()
                arrow.fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: marked ? NSColor.white : number == caretLine ? Self.currentColor : Self.color
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
    /// The debugger's: breakpoints in the gutter (and what clicking a number does), the
    /// line the game is stopped at, and breakpoints moving with their lines as they're edited.
    var breakpoints: [Int] = []
    var conditionalBreakpoints: Set<Int> = []
    var loggingBreakpoints: Set<Int> = []
    var pausedLine: Int? = nil
    var onToggleBreakpoint: ((Int) -> Void)? = nil
    var onBreakpointsMoved: (([Int: Int]) -> Void)? = nil
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
        // A kept text view may still have the last coordinator's list up.
        textView.source?.completionList.hide()
        textView.source = coordinator
        textView.delegate = coordinator
        textView.isEditable = isEditable
        // Whatever changed while the tab was away — the text, or its language — shows now.
        Self.syncText(text, into: textView, coordinator: coordinator)
        Self.highlight(textView, language: language)
        coordinator.lastLength = (textView.string as NSString).length
        Self.setLineNumbers(showsLineNumbers, on: entry)
        coordinator.lastReveal = reveal?.token
        applyDebugger(to: entry, coordinator: coordinator)

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
        applyDebugger(to: entry, coordinator: coordinator)
        if let reveal, reveal.token != coordinator.lastReveal {
            coordinator.lastReveal = reveal.token
            textView.window?.makeFirstResponder(textView)
            textView.reveal(line: reveal.line)
        }
    }

    /// Breakpoints and the stopped line into the gutter, the stopped line lit in the text.
    private func applyDebugger(to entry: CodeEditorCache.Entry, coordinator: Coordinator) {
        coordinator.breakpoints = breakpoints
        coordinator.onBreakpointsMoved = onBreakpointsMoved
        if let ruler = entry.scrollView.verticalRulerView as? LineNumberRuler {
            ruler.breakpoints = Set(breakpoints)
            ruler.conditional = conditionalBreakpoints
            ruler.logging = loggingBreakpoints
            ruler.pausedLine = pausedLine
            ruler.onToggle = onToggleBreakpoint
        }
        let textView = entry.textView
        guard let layout = textView.layoutManager, coordinator.litLine != pausedLine else { return }
        let text = textView.string as NSString
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        coordinator.litLine = pausedLine
        if let pausedLine, let range = LineNumbers.range(ofLine: pausedLine, in: text) {
            let whole = text.lineRange(for: range)
            layout.addTemporaryAttribute(.backgroundColor, value: LineNumberRuler.pausedColor.withAlphaComponent(0.22),
                                         forCharacterRange: whole)
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
        let completionList = CompletionList()
        /// A list waiting for typing to pause.
        private var pendingSuggestion: DispatchWorkItem?
        /// Set while a chosen suggestion goes in, so it doesn't open the list again.
        private var accepting = false
        /// How long typing must pause before a list opens for a word (not after a dot).
        static let pause: TimeInterval = 0.18
        /// The text view this coordinator is driving, and the undo history that goes with it.
        var entry: CodeEditorCache.Entry?
        var lastReveal: UUID?
        /// The debugger's: breakpoints to move as lines come and go, and the line lit.
        var breakpoints: [Int] = []
        var onBreakpointsMoved: (([Int: Int]) -> Void)?
        var litLine: Int?
        private var movedBreakpoints: [Int: Int]?
        /// For a text view built without an entry, as the tests do.
        private lazy var ownUndo = UndoManager()

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

        /// Each document keeps its own history, so ⌘Z in one tab never unpicks another.
        func undoManager(for view: NSTextView) -> UndoManager? {
            entry?.undo ?? ownUndo
        }

        /// Where lines are added or taken away, the breakpoints below move with them.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard !isApplyingExternalChange, !breakpoints.isEmpty, let replacementString else { return true }
            let moved = ScriptObject.movingLines(breakpoints, editing: range, replacement: replacementString,
                                                 in: textView.string as NSString)
            if moved.contains(where: { $0.key != $0.value }) || moved.count != breakpoints.count { movedBreakpoints = moved }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let textView = notification.object as? NSTextView else { return }

            CodeEditor.highlight(textView, language: language)
            onChange(textView.string)
            if let moved = movedBreakpoints {
                movedBreakpoints = nil
                breakpoints = Array(Set(moved.values)).sorted()
                onBreakpointsMoved?(moved)
            }

            let length = (textView.string as NSString).length
            let grew = length > lastLength
            lastLength = length
            if grew {
                offerCompletions(in: textView)
            } else if completionList.isOpen {
                // Backspace widens the list again, or closes it once the word is too short.
                suggest(in: textView, typed: true)
            }
        }

        /// After a dot (or a colon in Luau) the list opens at once. For a word it waits
        /// until the word is two letters long and typing pauses, so a word typed straight
        /// through never flashes a list. An open list just follows the typing.
        private func offerCompletions(in textView: NSTextView) {
            pendingSuggestion?.cancel()
            pendingSuggestion = nil
            guard !accepting else { return }
            if completionList.isOpen || Self.opensAtOnce(textView.string, caret: textView.selectedRange().location,
                                                         language: language) {
                suggest(in: textView, typed: true)
                return
            }
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                // Not if the keyboard went elsewhere in the meantime.
                if let window = textView.window, window.firstResponder !== textView { return }
                self.suggest(in: textView, typed: true)
            }
            pendingSuggestion = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pause, execute: work)
        }

        /// Opens, refreshes or closes the list for the caret. `typed` is false when it was
        /// asked for by hand (⌥Esc), which offers something even for a short word.
        func suggest(in textView: NSTextView, typed: Bool) {
            let text = textView.string
            let ns = text as NSString
            let selection = textView.selectedRange()
            let word = language.completionRange(in: text, caret: selection.location)
            guard selection.length == 0,
                  Self.mayOffer(in: ns, word: word, typed: typed, language: language) else {
                completionList.hide()
                return
            }
            // A word already typed in full isn't worth a list: `end`, `then`, a local's
            // whole name. Hiding it is what lets Return after it start a new line.
            let typedWord = ns.substring(with: word)
            let items = completions(text, selection.location).filter { !Self.isSameWord($0, typedWord) }
            completionList.onClick = { [weak self, weak textView] row in
                guard let self, let textView else { return }
                self.completionList.select(row)
                self.acceptSuggestion(in: textView)
            }
            completionList.show(items, anchor: word.location, in: textView)
        }

        /// Puts the highlighted suggestion in place of the word typed so far, as one undo step.
        func acceptSuggestion(in textView: NSTextView) {
            guard let item = completionList.highlighted else { return }
            let caret = textView.selectedRange().location
            let range = NSRange(location: completionList.anchor, length: max(caret - completionList.anchor, 0))
            completionList.hide()
            accepting = true
            // Its own step, not merged into the typing before it.
            textView.breakUndoCoalescing()
            textView.insertText(item.insert, replacementRange: range)
            accepting = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard completionList.isOpen, let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            let ns = textView.string as NSString
            // Typing within the word keeps the list; moving off it closes it.
            var onWord = selection.length == 0 && selection.location >= completionList.anchor
                && selection.location <= ns.length
            // A name inside `WaitForChild("…")` may have spaces in it.
            let inName = language == .luau && LuauCompletion.isNameArgument(in: textView.string, caret: selection.location)
            if onWord && !inName {
                for index in completionList.anchor..<selection.location where !Self.isIdentifier(ns.character(at: index)) {
                    onWord = false
                    break
                }
            }
            if !onWord { completionList.hide() }
        }

        // MARK: When to offer

        static func mayOffer(in text: NSString, word: NSRange, typed: Bool, language: CodeLanguage) -> Bool {
            let caret = word.location + word.length
            guard caret <= text.length else { return false }
            // The strings with suggestions, from the opening quote on: Luau's
            // `GetService("…")` (the services) and `WaitForChild("…")` (the names there).
            if language == .luau, LuauCompletion.isNameArgument(in: text as String, caret: caret) { return true }
            guard !language.isInCommentOrString(offset: caret, in: text as String) else { return false }
            // Editing inside a word: a suggestion would replace only half of it.
            if caret < text.length, isIdentifier(text.character(at: caret)) { return false }
            // `12`, `0x1F`: numbers aren't names.
            if word.length > 0, isDigit(text.character(at: word.location)) { return false }
            if opensAtOnce(text as String, caret: word.location, language: language) { return true }
            return typed ? word.length >= 2 : true
        }

        /// Where the list opens without waiting: after a dot or colon, and in Luau straight
        /// after `require(` (the ModuleScripts), `GetService(` or `GetService("` (the
        /// services) and `WaitForChild("` (the names there).
        static func opensAtOnce(_ text: String, caret: Int, language: CodeLanguage) -> Bool {
            if followsMemberAccess(text as NSString, caret: caret, language: language) { return true }
            return language == .luau && LuauCompletion.opensAtOnce(in: text, caret: caret)
        }

        /// Right after `name.` (or `name:` in Luau), where the members are the suggestions.
        /// Not after `0.`, which is a number being typed, nor `..`, which joins strings.
        static func followsMemberAccess(_ text: NSString, caret: Int, language: CodeLanguage) -> Bool {
            var start = caret
            while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
            guard start > 0, start <= text.length else { return false }
            let separator = text.character(at: start - 1)
            guard separator == dot || (separator == colon && language == .luau) else { return false }
            var receiver = start - 1
            while receiver > 0, isIdentifier(text.character(at: receiver - 1)) { receiver -= 1 }
            if receiver < start - 1 { return !isDigit(text.character(at: receiver)) }
            // `)` or `]` before the dot is a call or index; another dot is `..`.
            guard start >= 2 else { return false }
            let before = text.character(at: start - 2)
            return before == UInt16(UInt8(ascii: ")")) || before == UInt16(UInt8(ascii: "]"))
        }

        /// `print(...)` when `print` is typed, `end` when `end` is.
        static func isSameWord(_ item: CompletionItem, _ word: String) -> Bool {
            guard !word.isEmpty else { return false }
            let name = item.label.prefix { $0 != "(" }
            return item.insert == word || name == word
        }

        private static let dot = UInt16(UInt8(ascii: "."))
        private static let colon = UInt16(UInt8(ascii: ":"))
        static func isIdentifier(_ c: UInt16) -> Bool {
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || isDigit(c) || c == UInt16(UInt8(ascii: "_"))
        }
        static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

        // MARK: Keys

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completionList.isOpen {
                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)):
                    completionList.move(by: 1, in: textView)
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    completionList.move(by: -1, in: textView)
                    return true
                case #selector(NSResponder.insertTab(_:)):
                    acceptSuggestion(in: textView)
                    return true
                case #selector(NSResponder.insertNewline(_:)):
                    if completionList.picked {
                        acceptSuggestion(in: textView)
                        return true
                    }
                    // Not picked: Return is a new line, just as if the list weren't there.
                    completionList.hide()
                case #selector(NSResponder.cancelOperation(_:)):
                    completionList.hide()
                    return true
                default:
                    break
                }
            }
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                // AppKit would open its own completion on Esc.
                pendingSuggestion?.cancel()
                return true

            case #selector(NSResponder.insertTab(_:)):
                // Tab indents instead of moving focus out of the editor.
                let unit = language == .luau ? "\t" : String(repeating: " ", count: indentWidth)
                textView.insertText(unit,
                                    replacementRange: textView.selectedRange())
                return true

            case #selector(NSResponder.insertNewline(_:)):
                pendingSuggestion?.cancel()
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
