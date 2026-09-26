import AppKit

/// The code editor's suggestion list: a small panel under the word being typed.
///
/// It replaces AppKit's completion, which wrote its first guess into the text as soon as
/// it opened and took Return for itself, so every `end` or `then` at the end of a line
/// needed Return twice. Here nothing in the text changes until a suggestion is chosen:
/// Tab takes the highlighted one, Return only once one has been picked with the arrow
/// keys (otherwise it is a new line, as it would be without the list), and typing just
/// carries on and narrows the list.
///
/// The state is plain and works without a window, so the tests drive it headless; the
/// panel only appears when the text view is in one.
final class CompletionList {
    private(set) var items: [CompletionItem] = []
    private(set) var selected = 0
    /// True once the arrow keys have moved the highlight: from then on Return inserts.
    private(set) var picked = false
    /// Where the word being completed starts; a chosen suggestion replaces from here to the caret.
    private(set) var anchor = 0
    private(set) var isOpen = false

    static let visibleRows = 8

    /// Called when a row is clicked.
    var onClick: ((Int) -> Void)?

    private lazy var panel: CompletionPanel = {
        let panel = CompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view
        return panel
    }()

    private lazy var view: CompletionListView = {
        let view = CompletionListView()
        view.onClick = { [weak self] row in self?.onClick?(row) }
        return view
    }()

    var highlighted: CompletionItem? { isOpen && items.indices.contains(selected) ? items[selected] : nil }

    /// Whether the panel is on screen (it isn't for a text view outside a window).
    var isVisible: Bool { isOpen && panel.isVisible }
    var panelFrame: NSRect { panel.frame }

    /// Opens the list, or refreshes it as the word changes. The highlight is the best
    /// match, unless one was picked with the arrows and is still there.
    func show(_ items: [CompletionItem], anchor: Int, in textView: NSTextView) {
        guard !items.isEmpty else { hide(); return }
        let previous = picked ? highlighted?.label : nil
        self.items = items
        self.anchor = anchor
        if let previous, let index = items.firstIndex(where: { $0.label == previous }) {
            selected = index
        } else {
            selected = 0
            picked = false
        }
        isOpen = true
        layout(in: textView)
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        items = []
        selected = 0
        picked = false
        if let parent = panel.parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    /// Moves the highlight; the list doesn't wrap, as Xcode's doesn't.
    func move(by step: Int, in textView: NSTextView) {
        guard isOpen, !items.isEmpty else { return }
        selected = min(max(selected + step, 0), items.count - 1)
        picked = true
        layout(in: textView)
    }

    func select(_ row: Int) {
        guard items.indices.contains(row) else { return }
        selected = row
        picked = true
    }

    /// The rows as they are drawn now, in a view of their own, for `--render-panel
    /// suggestions` to put over a picture of the editor.
    func snapshotView() -> NSView {
        let copy = CompletionListView()
        copy.items = items
        copy.selected = selected
        copy.picked = picked
        copy.scrollToSelection()
        copy.frame = NSRect(origin: .zero, size: copy.fittingSize)
        return copy
    }

    /// Keeps the panel under its word when the text scrolls.
    func follow(_ textView: NSTextView) {
        if isOpen { layout(in: textView) }
    }

    // MARK: - The panel

    private func layout(in textView: NSTextView) {
        view.items = items
        view.selected = selected
        view.picked = picked
        view.scrollToSelection()
        guard let window = textView.window else { return }

        let size = view.fittingSize
        // Under the start of the word, with the labels lined up with the text.
        let caret = textView.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: nil)
        guard caret.origin.x.isFinite, caret.origin.y.isFinite else { return }
        var origin = NSPoint(x: caret.minX - CompletionListView.labelInset, y: caret.minY - 2 - size.height)
        if let screen = window.screen?.visibleFrame {
            // No room below: above the line instead.
            if origin.y < screen.minY { origin.y = caret.maxY + 2 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        view.needsDisplay = true
        // Placed but not shown for a window that isn't on screen, as in the tests.
        guard window.isVisible else { return }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

/// Never takes the keyboard: the text view keeps it while the list is up.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the rows: a coloured letter for the kind, the name, and the hint on the right.
private final class CompletionListView: NSView {
    var items: [CompletionItem] = []
    var selected = 0
    var picked = false
    var onClick: ((Int) -> Void)?
    private var firstRow = 0

    static let rowHeight: CGFloat = 20
    static let footerHeight: CGFloat = 20
    /// From the panel's left edge to where a label's text starts.
    static let labelInset: CGFloat = 32

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let footerFont = NSFont.systemFont(ofSize: 10.5)
    private static let background = NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 0.98)
    private static let border = NSColor(white: 1, alpha: 0.14)
    private static let highlight = NSColor(srgbRed: 0.25, green: 0.40, blue: 0.62, alpha: 1)
    private static let dim = NSColor(white: 1, alpha: 0.45)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var rows: Int { min(items.count, CompletionList.visibleRows) }

    override var fittingSize: NSSize {
        let widest = items.prefix(40).map { item -> CGFloat in
            let label = (item.label as NSString).size(withAttributes: [.font: Self.font]).width
            let detail = (item.detail as NSString).size(withAttributes: [.font: Self.detailFont]).width
            return label + (item.detail.isEmpty ? 0 : detail + 24)
        }.max() ?? 0
        let footer = (footerText as NSString).size(withAttributes: [.font: Self.footerFont]).width + 20
        let width = min(max(widest + Self.labelInset + 14, footer, 240), 560)
        return NSSize(width: width, height: CGFloat(rows) * Self.rowHeight + Self.footerHeight + 8)
    }

    private var footerText: String {
        picked ? "Return or Tab to insert  ·  Esc to close"
               : "Tab to insert  ·  ↑↓ to choose  ·  Esc to close"
    }

    func scrollToSelection() {
        if selected < firstRow { firstRow = selected }
        if selected >= firstRow + CompletionList.visibleRows { firstRow = selected - CompletionList.visibleRows + 1 }
        firstRow = min(max(firstRow, 0), max(items.count - CompletionList.visibleRows, 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        Self.background.setFill()
        shape.fill()
        Self.border.setStroke()
        shape.stroke()

        for row in 0..<rows {
            let index = firstRow + row
            guard items.indices.contains(index) else { break }
            let item = items[index]
            let rect = NSRect(x: 4, y: 4 + CGFloat(row) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
            if index == selected {
                // Brighter once picked: that's when Return will take it.
                (picked ? Self.highlight : Self.highlight.withAlphaComponent(0.6)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            drawBadge(for: item.kind, in: NSRect(x: rect.minX + 6, y: rect.midY - 7, width: 16, height: 14))
            let labelWidth = (item.label as NSString).size(withAttributes: [.font: Self.font]).width
            (item.label as NSString).draw(at: NSPoint(x: Self.labelInset, y: rect.minY + 2.5),
                                          withAttributes: [.font: Self.font, .foregroundColor: CodeEditor.foreground])
            if !item.detail.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: Self.detailFont, .foregroundColor: Self.dim]
                let size = (item.detail as NSString).size(withAttributes: attributes)
                let x = max(rect.maxX - 8 - size.width, Self.labelInset + labelWidth + 16)
                (item.detail as NSString).draw(at: NSPoint(x: x, y: rect.minY + 3.5), withAttributes: attributes)
            }
        }
        if items.count > CompletionList.visibleRows {
            // A thin bar showing where in a long list the rows are.
            let track = CGFloat(rows) * Self.rowHeight
            let height = max(track * CGFloat(rows) / CGFloat(items.count), 12)
            let y = 4 + (track - height) * CGFloat(firstRow) / CGFloat(items.count - rows)
            Self.dim.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 5, y: y, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let footerY = 4 + CGFloat(rows) * Self.rowHeight
        Self.border.setFill()
        NSRect(x: 8, y: footerY, width: bounds.width - 16, height: 1).fill()
        (footerText as NSString).draw(at: NSPoint(x: 10, y: footerY + 4),
                                      withAttributes: [.font: Self.footerFont, .foregroundColor: Self.dim])
    }

    private func drawBadge(for kind: CompletionItem.Kind, in rect: NSRect) {
        let (letter, colour): (String, NSColor) = {
            switch kind {
            case .property: return ("p", NSColor(srgbRed: 0.45, green: 0.70, blue: 0.95, alpha: 1))
            case .method: return ("f", NSColor(srgbRed: 0.72, green: 0.55, blue: 0.95, alpha: 1))
            case .variable: return ("v", NSColor(srgbRed: 0.40, green: 0.80, blue: 0.70, alpha: 1))
            case .type: return ("T", NSColor(srgbRed: 0.90, green: 0.75, blue: 0.40, alpha: 1))
            case .keyword: return ("k", NSColor(srgbRed: 0.95, green: 0.50, blue: 0.62, alpha: 1))
            }
        }()
        colour.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let size = (letter as NSString).size(withAttributes: [.font: font])
        (letter as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                  withAttributes: [.font: font, .foregroundColor: colour])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 4) / Self.rowHeight)
        guard row >= 0, row < rows else { return }
        onClick?(firstRow + row)
    }
}
