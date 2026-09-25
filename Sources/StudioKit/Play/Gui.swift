import Foundation
import AppKit
import simd

/// Roblox's UDim2: a position or size as a fraction of the parent, plus pixels.
struct UDim2: Equatable {
    var xScale: Float = 0
    var xOffset: Float = 0
    var yScale: Float = 0
    var yOffset: Float = 0

    var list: [Float] { [xScale, xOffset, yScale, yOffset] }

    init(xScale: Float = 0, xOffset: Float = 0, yScale: Float = 0, yOffset: Float = 0) {
        self.xScale = xScale
        self.xOffset = xOffset
        self.yScale = yScale
        self.yOffset = yOffset
    }

    init?(list: [Float]) {
        guard list.count == 4 else { return nil }
        self.init(xScale: list[0], xOffset: list[1], yScale: list[2], yOffset: list[3])
    }

    /// In an area this size, in points.
    func resolved(in size: CGSize) -> CGSize {
        CGSize(width: CGFloat(xScale) * size.width + CGFloat(xOffset),
               height: CGFloat(yScale) * size.height + CGFloat(yOffset))
    }
}

/// A point along a UIGradient's colours: Roblox's ColorSequenceKeypoint.
struct GradientStop: Equatable {
    var time: Float
    var color: Vec3
}

/// One thing on a player's screen — Roblox's ScreenGui, BillboardGui, Frame,
/// ScrollingFrame, TextLabel, TextButton, TextBox, ImageLabel, ImageButton, or a
/// modifier changing its parent: UICorner, UIPadding, UIStroke, UIGradient, UIListLayout,
/// UIGridLayout, UIAspectRatioConstraint, UISizeConstraint, UITextSizeConstraint. Scripts
/// make and change them through the `gui.*` host calls; `GuiLayer` draws them over the game.
struct GuiObject: Equatable {
    enum Kind: String, CaseIterable, Codable {
        case screenGui = "ScreenGui"
        case billboardGui = "BillboardGui"
        case frame = "Frame"
        case scrollingFrame = "ScrollingFrame"
        case textLabel = "TextLabel"
        case textButton = "TextButton"
        case textBox = "TextBox"
        case imageLabel = "ImageLabel"
        case imageButton = "ImageButton"
        case uiCorner = "UICorner"
        case uiPadding = "UIPadding"
        case uiListLayout = "UIListLayout"
        case uiStroke = "UIStroke"
        case uiGradient = "UIGradient"
        case uiGridLayout = "UIGridLayout"
        case uiAspectRatioConstraint = "UIAspectRatioConstraint"
        case uiSizeConstraint = "UISizeConstraint"
        case uiTextSizeConstraint = "UITextSizeConstraint"

        var showsText: Bool { self == .textLabel || self == .textButton || self == .textBox }
        var showsImage: Bool { self == .imageLabel || self == .imageButton }
        /// Takes clicks: buttons and boxes.
        var isInteractive: Bool { self == .textButton || self == .textBox || self == .imageButton }
        /// Not drawn itself; it changes how its parent is drawn.
        var isModifier: Bool { Self.modifiers.contains(self) }
        /// Arranges its parent's children, ignoring their Position.
        var isLayout: Bool { self == .uiListLayout || self == .uiGridLayout }
        static let modifiers: Set<Kind> = [.uiCorner, .uiPadding, .uiListLayout, .uiStroke, .uiGradient, .uiGridLayout,
                                           .uiAspectRatioConstraint, .uiSizeConstraint, .uiTextSizeConstraint]
        /// A layer of its own: a ScreenGui over the screen, a BillboardGui over a point
        /// in the world.
        var isLayer: Bool { self == .screenGui || self == .billboardGui }
    }

    let id: Int
    let kind: Kind
    var name: String
    /// `GuiStore.playerGui` (0) for the top of the screen; nil for nowhere yet, where
    /// Instance.new leaves a new object until its Parent is set.
    var parent: Int?

    var position = UDim2()
    var size = UDim2(xOffset: 100, yOffset: 100)
    var anchorPoint = SIMD2<Float>(0, 0)
    var backgroundColor = Vec3(1, 1, 1)
    var backgroundTransparency: Float = 0
    var visible = true
    /// ScreenGui and BillboardGui: off hides everything in it.
    var enabled = true
    var zIndex = 1
    /// Order among siblings in a UIListLayout.
    var layoutOrder = 0
    /// Cuts off what is inside at its edges.
    var clipsDescendants = false
    /// Grows to fit what is inside it: "None", "X", "Y" or "XY".
    var automaticSize = "None"

    var text = ""
    var textColor = Vec3(0, 0, 0)
    var textSize: Float = 14
    var textTransparency: Float = 0
    /// "Left", "Center" or "Right", as Enum.TextXAlignment names them.
    var textXAlignment = "Center"
    /// "Top", "Center" or "Bottom".
    var textYAlignment = "Center"
    var textWrapped = false
    /// The largest size that fits, instead of TextSize.
    var textScaled = false
    /// An Enum.Font name, drawn with the nearest system font.
    var font = "SourceSans"
    var textStrokeColor = Vec3(0, 0, 0)
    /// 1 is no outline.
    var textStrokeTransparency: Float = 1
    var placeholderText = ""
    var clearTextOnFocus = true
    /// TextBox: off, it can be focused but not typed into.
    var textEditable = true

    /// ImageLabel and ImageButton: an asset ("studio://Name"), tinted and faded.
    var image = ""
    var imageColor = Vec3(1, 1, 1)
    var imageTransparency: Float = 0
    /// "Stretch", "Fit" or "Crop".
    var scaleType = "Stretch"

    /// UICorner only: Roblox's CornerRadius, a UDim.
    var cornerScale: Float = 0
    var cornerOffset: Float = 8

    /// UIPadding only: PaddingLeft, PaddingRight, PaddingTop and PaddingBottom, each a
    /// UDim (scale, offset) keeping the parent's text and children in from that edge.
    var paddingLeft = SIMD2<Float>(0, 0)
    var paddingRight = SIMD2<Float>(0, 0)
    var paddingTop = SIMD2<Float>(0, 0)
    var paddingBottom = SIMD2<Float>(0, 0)

    /// UIListLayout only: children one after another, ignoring their Position.
    var fillDirection = "Vertical"
    /// A UDim between them.
    var listPadding = SIMD2<Float>(0, 0)
    /// "LayoutOrder" or "Name".
    var sortOrder = "LayoutOrder"
    var horizontalAlignment = "Left"
    var verticalAlignment = "Top"

    /// UIStroke only: an outline — round the border, or round a text object's text
    /// ("Contextual") — of this colour, thickness and transparency.
    var strokeColor = Vec3(0, 0, 0)
    var strokeThickness: Float = 1
    var strokeTransparency: Float = 0
    var applyStrokeMode = "Contextual"
    var lineJoinMode = "Round"

    /// UIGradient only: colours and transparencies along a line through the parent,
    /// turned by Rotation (degrees, clockwise from left-to-right) and moved by Offset
    /// (a share of its size). Multiplies what the parent draws.
    var gradientColor = [GradientStop(time: 0, color: Vec3(1, 1, 1)), GradientStop(time: 1, color: Vec3(1, 1, 1))]
    var gradientTransparency: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0)]
    var rotation: Float = 0
    var gradientOffset = SIMD2<Float>(0, 0)

    /// UIGridLayout only: every child the same size, in rows (or columns).
    var cellSize = UDim2(xOffset: 100, yOffset: 100)
    var cellPadding = UDim2(xOffset: 5, yOffset: 5)
    /// Cells in a row (a column, filling vertically) before the next; 0 is as many as fit.
    var fillDirectionMaxCells = 0
    /// "TopLeft", "TopRight", "BottomLeft" or "BottomRight": where the first cell goes.
    var startCorner = "TopLeft"

    /// UIAspectRatioConstraint only: width over height, and how it's kept —
    /// "FitWithinMaxSize" (the largest of that shape inside the Size) or
    /// "ScaleWithParentSize" (the DominantAxis kept, the other worked out).
    var aspectRatio: Float = 1
    var aspectType = "FitWithinMaxSize"
    var dominantAxis = "Width"

    /// UISizeConstraint only: the smallest and largest the parent may be, in pixels.
    var minSize = SIMD2<Float>(0, 0)
    var maxSize = SIMD2<Float>(.infinity, .infinity)

    /// UITextSizeConstraint only: the range TextScaled picks a size from.
    var minTextSize: Float = 1
    var maxTextSize: Float = 100

    /// ScrollingFrame only: the area inside that scrolls, where it is scrolled to, and the bar.
    var canvasSize = UDim2(yScale: 2)
    var canvasPosition = SIMD2<Float>(0, 0)
    var scrollBarThickness: Float = 12
    var scrollingEnabled = true
    /// The canvas grows to fit what is in it: "None", "X", "Y" or "XY".
    var automaticCanvasSize = "None"

    /// BillboardGui only: what it hangs over ("p:<part>" or "c:<character>:<body part>"),
    /// how far above, and how far away it can be seen from.
    var adornee: String?
    var studsOffset = Vec3.zero
    var alwaysOnTop = false
    var maxDistance: Float = .infinity

    /// ScreenGui only: made afresh for each new character, and drawn above lower orders.
    var resetOnSpawn = true
    var displayOrder = 0

    init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
        name = kind.rawValue
        switch kind {
        case .textLabel: text = "Label"; size = UDim2(xOffset: 200, yOffset: 50)
        case .textButton: text = "Button"; size = UDim2(xOffset: 200, yOffset: 50)
        case .textBox: size = UDim2(xOffset: 200, yOffset: 50)
        case .billboardGui: size = UDim2(xOffset: 200, yOffset: 50)
        case .uiGridLayout: fillDirection = "Horizontal"
        default: break
        }
    }

    /// A ColorSequence's colour at a point along it, 0…1.
    static func sample(_ stops: [GradientStop], at time: Float) -> Vec3 {
        guard let first = stops.first else { return Vec3(1, 1, 1) }
        guard time > first.time else { return first.color }
        for (a, b) in zip(stops, stops.dropFirst()) where time <= b.time {
            let t = b.time > a.time ? (time - a.time) / (b.time - a.time) : 1
            return a.color + (b.color - a.color) * t
        }
        return stops.last?.color ?? first.color
    }

    /// A NumberSequence's value at a point along it, 0…1.
    static func sample(_ stops: [SIMD2<Float>], at time: Float) -> Float {
        guard let first = stops.first else { return 0 }
        guard time > first.x else { return first.y }
        for (a, b) in zip(stops, stops.dropFirst()) where time <= b.x {
            let t = b.x > a.x ? (time - a.x) / (b.x - a.x) : 1
            return a.y + (b.y - a.y) * t
        }
        return stops.last?.y ?? first.y
    }
}

/// Enum.Font, drawn with the nearest system font: a weight and a design.
enum GuiFont {
    static func style(_ name: String) -> (weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign) {
        let bold = name.hasSuffix("Bold") || name.hasSuffix("Black") || name == "Bangers" || name == "LuckiestGuy"
        let weight: NSFont.Weight = bold ? .bold : name.hasSuffix("Light") ? .light : .regular
        switch name {
        case "Code", "RobotoMono", "Ubuntu":
            return (weight, .monospaced)
        case "Garamond", "Antique", "Merriweather", "Bodoni", "Fondamento", "SpecialElite":
            return (weight, .serif)
        case "Cartoon", "FredokaOne", "Bangers", "LuckiestGuy", "Kalam", "Highway", "Arcade", "Fantasy":
            return (weight, .rounded)
        default:
            return (weight, .default)
        }
    }

    static func font(_ name: String, size: CGFloat) -> NSFont {
        let style = style(name)
        let base = NSFont.systemFont(ofSize: size, weight: style.weight)
        if style.design != .default, let descriptor = base.fontDescriptor.withDesign(style.design),
           let designed = NSFont(descriptor: descriptor, size: size) {
            return designed
        }
        return base
    }

    /// How much room text takes: on one line, or wrapped to a width.
    static func measure(_ text: String, font name: String, size: CGFloat, width: CGFloat?) -> CGSize {
        guard !text.isEmpty else { return CGSize(width: 0, height: ceil(size * 1.2)) }
        let attributed = NSAttributedString(string: text, attributes: [.font: font(name, size: size)])
        let bounds = attributed.boundingRect(with: CGSize(width: width ?? .greatestFiniteMagnitude,
                                                          height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// TextScaled: the largest size, up to 100, at which the text fits the box.
    static func scaled(_ text: String, font name: String, in box: CGSize, wrapped: Bool) -> CGFloat {
        guard box.width > 1, box.height > 1 else { return 1 }
        var low: CGFloat = 1, high: CGFloat = 100
        for _ in 0..<12 {
            let middle = (low + high) / 2
            let needed = measure(text, font: name, size: middle, width: wrapped ? box.width : nil)
            if needed.width <= box.width + 0.5 && needed.height <= box.height + 0.5 { low = middle } else { high = middle }
        }
        return floor(low)
    }
}

/// A player's screen GUI: Roblox's PlayerGui and everything in it. Each machine has its
/// own, made by the scripts that run there, as Roblox's is.
final class GuiStore: ObservableObject {
    /// The parent that means "on the screen": the PlayerGui.
    static let playerGui = 0

    @Published private(set) var objects: [Int: GuiObject] = [:]
    /// The TextBox the keyboard types into, if any.
    @Published private(set) var focused: Int?
    /// Where the caret is in the focused TextBox's text, in characters, and whether all
    /// of it is selected (⌘A), so typing replaces it.
    @Published private(set) var cursor = 0
    @Published private(set) var selectedAll = false
    /// Called when a TextBox takes the keyboard, so the game can let go of held keys.
    var onFocus: (() -> Void)?
    /// Where a BillboardGui's Adornee is on a screen that size, and how many points a stud
    /// is there; nil when it can't be seen (the play session answers).
    var billboardPlacer: ((GuiObject, CGSize) -> (center: CGPoint, pointsPerStud: CGFloat)?)?
    /// An image for ImageLabels by its Image, from the scene's assets.
    var imageProvider: ((String) -> NSImage?)?
    /// The screen size layout last ran at, for AbsoluteSize and scrolling.
    private(set) var lastScreen = CGSize(width: 800, height: 600)

    /// Made-in order: siblings draw in it, after ZIndex.
    private var order: [Int] = []
    private var nextID = 1
    /// Clicks and focus changes for the scripts, as `["Gui", id, what, …]`.
    private var events: [ScriptValue] = []

    func object(_ id: Int) -> GuiObject? { objects[id] }

    var hasBillboards: Bool { objects.values.contains { $0.kind == .billboardGui } }

    func create(_ kind: GuiObject.Kind) -> Int {
        let id = nextID
        nextID += 1
        objects[id] = GuiObject(id: id, kind: kind)
        order.append(id)
        return id
    }

    func update(_ id: Int, _ body: (inout GuiObject) -> Void) {
        guard var object = objects[id] else { return }
        body(&object)
        if object != objects[id] { objects[id] = object }
    }

    /// Children in the order they draw: by ZIndex, then as they were made.
    func children(of parent: Int) -> [Int] {
        order.filter { objects[$0]?.parent == parent }
            .enumerated()
            .sorted { (objects[$0.element]!.zIndex, $0.offset) < (objects[$1.element]!.zIndex, $1.offset) }
            .map(\.element)
    }

    /// Sets a parent — the PlayerGui, another object, or nil — refusing a loop.
    @discardableResult
    func setParent(_ id: Int, to parent: Int?) -> Bool {
        guard objects[id] != nil else { return false }
        if let parent, parent != Self.playerGui {
            guard objects[parent] != nil else { return false }
            var walk: Int? = parent
            while let at = walk, at != Self.playerGui {
                if at == id { return false }
                walk = objects[at]?.parent
            }
        }
        update(id) { $0.parent = parent }
        return true
    }

    /// Removes an object and everything inside it.
    func destroy(_ id: Int) {
        let doomed = descendants(of: id) + [id]
        if let focused, doomed.contains(focused) { releaseFocus(enterPressed: false) }
        for gone in doomed { objects[gone] = nil }
        order.removeAll { doomed.contains($0) }
    }

    func descendants(of id: Int) -> [Int] {
        order.filter { objects[$0]?.parent == id }.flatMap { [$0] + descendants(of: $0) }
    }

    // MARK: - Focus and typing

    /// Gives a TextBox the keyboard, as TextBox:CaptureFocus does.
    func focus(_ id: Int) {
        guard objects[id]?.kind == .textBox, focused != id else { return }
        if focused != nil { releaseFocus(enterPressed: false) }
        if objects[id]?.clearTextOnFocus == true && objects[id]?.textEditable == true { update(id) { $0.text = "" } }
        focused = id
        cursor = objects[id]?.text.count ?? 0
        selectedAll = false
        events.append(.list([.string("Gui"), .number(Double(id)), .string("Focused")]))
        onFocus?()
    }

    /// Takes the keyboard back: FocusLost, saying whether Return did it.
    func releaseFocus(enterPressed: Bool) {
        guard let id = focused else { return }
        focused = nil
        selectedAll = false
        events.append(.list([.string("Gui"), .number(Double(id)), .string("FocusLost"), .bool(enterPressed)]))
    }

    private var editable: Int? {
        guard let id = focused, objects[id]?.textEditable == true else { return nil }
        return id
    }

    /// Characters typed into the focused TextBox, at the caret.
    func type(_ characters: String) {
        guard let id = editable else { return }
        let printable = characters.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }
        guard !printable.isEmpty else { return }
        if selectedAll { update(id) { $0.text = "" }; cursor = 0; selectedAll = false }
        update(id) { object in
            let at = object.text.index(object.text.startIndex, offsetBy: min(cursor, object.text.count))
            object.text.insert(contentsOf: printable, at: at)
        }
        cursor += printable.count
    }

    /// Delete: the character before the caret, or everything when it's all selected.
    func backspace() {
        guard let id = editable else { return }
        if selectedAll {
            update(id) { $0.text = "" }
            cursor = 0
            selectedAll = false
            return
        }
        guard cursor > 0 else { return }
        update(id) { object in
            let at = object.text.index(object.text.startIndex, offsetBy: min(cursor, object.text.count) - 1)
            object.text.remove(at: at)
        }
        cursor -= 1
    }

    /// Forward delete: the character after the caret.
    func deleteForward() {
        guard let id = editable, let text = objects[id]?.text else { return }
        if selectedAll { backspace(); return }
        guard cursor < text.count else { return }
        update(id) { $0.text.remove(at: $0.text.index($0.text.startIndex, offsetBy: cursor)) }
    }

    /// The caret left or right, or to either end.
    func moveCursor(by step: Int) {
        guard let id = focused, let text = objects[id]?.text else { return }
        if selectedAll {
            cursor = step < 0 ? 0 : text.count
            selectedAll = false
            return
        }
        cursor = min(max(cursor + step, 0), text.count)
    }

    func moveCursor(toEnd: Bool) {
        guard let id = focused, let text = objects[id]?.text else { return }
        selectedAll = false
        cursor = toEnd ? text.count : 0
    }

    func selectAll() {
        guard focused != nil else { return }
        selectedAll = true
    }

    /// What ⌘C copies: all of it when it's selected, nothing otherwise.
    var selectedText: String? {
        guard selectedAll, let id = focused else { return nil }
        return objects[id]?.text
    }

    /// ⌘V: the text, on one line, where the caret is.
    func paste(_ text: String) {
        type(text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "))
    }

    /// A script moving the caret (TextBox.CursorPosition, from 1; -1 when not typing).
    func setCursor(_ id: Int, to position: Int) {
        guard focused == id, let text = objects[id]?.text else { return }
        selectedAll = false
        cursor = min(max(position - 1, 0), text.count)
    }

    // MARK: - Clicks

    /// A click on a button or a box, from the screen.
    func click(_ id: Int) {
        guard let object = objects[id] else { return }
        switch object.kind {
        case .textButton, .imageButton:
            events.append(.list([.string("Gui"), .number(Double(id)), .string("Click")]))
        case .textBox:
            focus(id)
        default:
            break
        }
    }

    // MARK: - Copies of StarterGui

    /// Copies a GUI made in Studio, and everything inside it, under `parent`; returns
    /// each original's copy.
    @discardableResult
    func copy(_ template: StarterGuiObject, from all: [StarterGuiObject], into parent: Int) -> [UUID: Int] {
        let id = create(template.kind)
        let made = template.object(id: id)
        update(id) { $0 = made }
        setParent(id, to: parent)
        var copies = [template.id: id]
        for child in all where child.parentID == template.id {
            copies.merge(copy(child, from: all, into: id)) { first, _ in first }
        }
        return copies
    }

    /// Empties the store: every object goes.
    func removeAll() {
        if focused != nil { releaseFocus(enterPressed: false) }
        objects = [:]
        order = []
        events = []
    }

    /// The object Studio has selected, outlined in its preview of StarterGui.
    @Published var highlighted: Int?

    func drainEvents() -> [ScriptValue] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - Scrolling

    /// The scroll wheel over the GUI: the ScrollingFrame under the point, if any, scrolls
    /// and the wheel is used up.
    func scroll(at point: CGPoint, by delta: CGSize) -> Bool {
        let placed = layout(in: lastScreen)
        guard let hit = placed.last(where: { item in
            item.object.kind == .scrollingFrame && item.object.scrollingEnabled && item.frame.contains(point)
                && (item.clip?.contains(point) ?? true)
        }), let range = hit.scrollRange else { return false }
        update(hit.id) { object in
            let x = min(max(CGFloat(object.canvasPosition.x) - delta.width, 0), range.width)
            let y = min(max(Self.clamped(object.canvasPosition.y, range.height) - delta.height, 0), range.height)
            object.canvasPosition = SIMD2(Float(x), Float(y))
        }
        return true
    }

    private static func clamped(_ value: Float, _ limit: CGFloat) -> CGFloat {
        min(max(CGFloat(value), 0), limit)
    }

    /// Where a ScrollingFrame is scrolled to, as far as its canvas allows.
    func canvasPosition(of id: Int) -> SIMD2<Float> {
        guard let object = objects[id] else { return .zero }
        guard let range = layout(in: lastScreen).first(where: { $0.id == id })?.scrollRange else {
            return object.canvasPosition
        }
        return SIMD2(Float(Self.clamped(object.canvasPosition.x, range.width)),
                     Float(Self.clamped(object.canvasPosition.y, range.height)))
    }

    /// The area an object is placed in: its parent's inside (a ScrollingFrame's canvas,
    /// as scrolled), or the whole screen at the top of a ScreenGui.
    func area(for id: Int, in screen: CGSize) -> CGRect? {
        guard let parent = objects[id]?.parent else { return nil }
        let whole = CGRect(origin: .zero, size: screen)
        guard parent != Self.playerGui, let holder = objects[parent] else { return whole }
        if holder.kind == .screenGui { return whole }
        guard let item = layout(in: screen).first(where: { $0.id == parent }) else { return nil }
        guard holder.kind == .scrollingFrame else { return item.content }
        let canvas = canvasSize(of: holder, content: item.content)
        let range = item.scrollRange ?? .zero
        return CGRect(x: item.content.minX - Self.clamped(holder.canvasPosition.x, range.width),
                      y: item.content.minY - Self.clamped(holder.canvasPosition.y, range.height),
                      width: canvas.width, height: canvas.height)
    }

    /// AbsolutePosition and AbsoluteSize: where an object was last drawn.
    func absoluteFrame(of id: Int) -> CGRect? {
        layout(in: lastScreen).first { $0.id == id }?.frame
    }

    // MARK: - Layout

    /// Something to draw, where, with its corner rounding and the area inside its
    /// padding, where its text and children go.
    struct Placed: Identifiable {
        let object: GuiObject
        let frame: CGRect
        let cornerRadius: CGFloat
        let content: CGRect
        /// Where drawing is cut off — a ScrollingFrame or ClipsDescendants above — or nil.
        let clip: CGRect?
        /// The size text is drawn at: TextScaled's fit, or TextSize.
        let textSize: CGFloat
        /// A ScrollingFrame's bar, when its canvas is bigger than it.
        let scrollBar: CGRect?
        /// How far a ScrollingFrame can scroll, across and down.
        let scrollRange: CGSize?
        /// Its UIStroke and UIGradient, when it has them switched on.
        var stroke: GuiObject? = nil
        var gradient: GuiObject? = nil
        var id: Int { object.id }
    }

    /// Everything showing on a screen this size, in the order to draw it: BillboardGuis
    /// first (they belong to the world), then each ScreenGui by DisplayOrder, parents
    /// before children, siblings by ZIndex.
    func layout(in screen: CGSize) -> [Placed] {
        lastScreen = screen
        var placed: [Placed] = []
        let whole = CGRect(origin: .zero, size: screen)
        let roots = children(of: Self.playerGui).compactMap { objects[$0] }.filter { $0.kind.isLayer && $0.enabled }
        for root in roots where root.kind == .billboardGui {
            guard let spot = billboardPlacer?(root, screen) else { continue }
            let size = CGSize(width: CGFloat(root.size.xScale) * spot.pointsPerStud + CGFloat(root.size.xOffset),
                              height: CGFloat(root.size.yScale) * spot.pointsPerStud + CGFloat(root.size.yOffset))
            let area = CGRect(x: spot.center.x - size.width / 2, y: spot.center.y - size.height / 2,
                              width: max(size.width, 0), height: max(size.height, 0))
            place(childrenOf: root.id, in: area, clip: nil, into: &placed)
        }
        let screens = roots.filter { $0.kind == .screenGui }.enumerated()
            .sorted { ($0.element.displayOrder, $0.offset) < ($1.element.displayOrder, $1.offset) }
        for (_, root) in screens {
            place(childrenOf: root.id, in: whole, clip: nil, into: &placed)
        }
        return placed
    }

    private func place(childrenOf parent: Int, in area: CGRect, clip: CGRect?, into placed: inout [Placed]) {
        for (object, frame) in arranged(childrenOf: parent, in: area) {
            let modifiers = children(of: object.id).compactMap { objects[$0] }
            let corner = modifiers.first { $0.kind == .uiCorner }
            let radius = corner.map { CGFloat($0.cornerScale) * min(frame.width, frame.height) + CGFloat($0.cornerOffset) } ?? 0
            let content = modifiers.first { $0.kind == .uiPadding }.map { Self.inset(frame, by: $0) } ?? frame
            var textSize = CGFloat(object.textSize)
            if object.kind.showsText && object.textScaled {
                textSize = GuiFont.scaled(object.text.isEmpty ? object.placeholderText : object.text,
                                          font: object.font, in: content.size, wrapped: object.textWrapped)
                if let limit = modifiers.first(where: { $0.kind == .uiTextSizeConstraint }) {
                    textSize = min(max(textSize, CGFloat(limit.minTextSize)), CGFloat(max(limit.maxTextSize, limit.minTextSize)))
                }
            }
            var childArea = content
            var childClip = clip
            var bar: CGRect?
            var range: CGSize?
            if object.clipsDescendants || object.kind == .scrollingFrame {
                childClip = clip.map { $0.intersection(frame) } ?? frame
            }
            if object.kind == .scrollingFrame {
                let canvas = canvasSize(of: object, content: content)
                let limit = CGSize(width: max(canvas.width - content.width, 0), height: max(canvas.height - content.height, 0))
                let offset = CGPoint(x: Self.clamped(object.canvasPosition.x, limit.width),
                                     y: Self.clamped(object.canvasPosition.y, limit.height))
                childArea = CGRect(x: content.minX - offset.x, y: content.minY - offset.y,
                                   width: canvas.width, height: canvas.height)
                range = limit
                if limit.height > 0.5 && object.scrollBarThickness > 0 {
                    let thickness = CGFloat(object.scrollBarThickness)
                    let length = max(frame.height * frame.height / max(canvas.height, 1), 16)
                    let travel = frame.height - length
                    bar = CGRect(x: frame.maxX - thickness, y: frame.minY + travel * offset.y / limit.height,
                                 width: thickness, height: length)
                }
            }
            if clip.map({ $0.intersects(frame) }) ?? true {
                placed.append(Placed(object: object, frame: frame, cornerRadius: max(radius, 0), content: content,
                                     clip: clip, textSize: textSize, scrollBar: bar, scrollRange: range,
                                     stroke: modifiers.first { $0.kind == .uiStroke && $0.enabled },
                                     gradient: modifiers.first { $0.kind == .uiGradient && $0.enabled }))
            }
            place(childrenOf: object.id, in: childArea, clip: childClip, into: &placed)
        }
    }

    /// Where each shown child of `parent` goes in `area`: by its own Position, one after
    /// another if a UIListLayout is inside, or in the cells of a UIGridLayout.
    private func arranged(childrenOf parent: Int, in area: CGRect) -> [(GuiObject, CGRect)] {
        let kids = children(of: parent).compactMap { objects[$0] }
        let shown = kids.filter { $0.visible && !$0.kind.isModifier && !$0.kind.isLayer }
        guard let list = kids.first(where: { $0.kind.isLayout }) else {
            return shown.map { ($0, sizedFrame(of: $0, in: area)) }
        }
        let sorted = shown.enumerated().sorted { a, b in
            if list.sortOrder == "Name" { return (a.element.name, a.offset) < (b.element.name, b.offset) }
            return (a.element.layoutOrder, a.offset) < (b.element.layoutOrder, b.offset)
        }.map(\.element)
        if list.kind == .uiGridLayout { return grid(list, sorted, in: area) }
        let vertical = list.fillDirection != "Horizontal"
        let gap = vertical ? CGFloat(list.listPadding.x) * area.height + CGFloat(list.listPadding.y)
                           : CGFloat(list.listPadding.x) * area.width + CGFloat(list.listPadding.y)
        let sizes = sorted.map { sizedFrame(of: $0, in: area).size }
        let total = sizes.map { vertical ? $0.height : $0.width }.reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0))
        var along: CGFloat
        let alignment = vertical ? list.verticalAlignment : list.horizontalAlignment
        let (start, span) = vertical ? (area.minY, area.height) : (area.minX, area.width)
        switch alignment {
        case "Center": along = start + (span - total) / 2
        case "Bottom", "Right": along = start + span - total
        default: along = start
        }
        var result: [(GuiObject, CGRect)] = []
        for (object, size) in zip(sorted, sizes) {
            let across: CGFloat
            if vertical {
                switch list.horizontalAlignment {
                case "Center": across = area.midX - size.width / 2
                case "Right": across = area.maxX - size.width
                default: across = area.minX
                }
                result.append((object, CGRect(x: across, y: along, width: size.width, height: size.height)))
                along += size.height + gap
            } else {
                switch list.verticalAlignment {
                case "Center": across = area.midY - size.height / 2
                case "Bottom": across = area.maxY - size.height
                default: across = area.minY
                }
                result.append((object, CGRect(x: along, y: across, width: size.width, height: size.height)))
                along += size.width + gap
            }
        }
        return result
    }

    /// A UIGridLayout's cells: the children in order, a row at a time (a column, filling
    /// vertically), as many to a row as fit or FillDirectionMaxCells allows, the block of
    /// them aligned in the area and started from StartCorner.
    private func grid(_ layout: GuiObject, _ items: [GuiObject], in area: CGRect) -> [(GuiObject, CGRect)] {
        guard !items.isEmpty else { return [] }
        let resolved = layout.cellSize.resolved(in: area.size)
        let cell = CGSize(width: max(resolved.width, 0), height: max(resolved.height, 0))
        let gap = layout.cellPadding.resolved(in: area.size)
        let horizontal = layout.fillDirection != "Vertical"
        let span = horizontal ? area.width : area.height
        let (length, spacing) = horizontal ? (cell.width, gap.width) : (cell.height, gap.height)
        var perLine = length + spacing > 0 ? Int(floor((span + spacing) / (length + spacing))) : items.count
        if layout.fillDirectionMaxCells > 0 { perLine = min(perLine, layout.fillDirectionMaxCells) }
        perLine = min(max(perLine, 1), items.count)
        let lines = (items.count + perLine - 1) / perLine
        let columns = horizontal ? perLine : lines
        let rows = horizontal ? lines : perLine
        let block = CGSize(width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap.width,
                           height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap.height)
        let left: CGFloat
        switch layout.horizontalAlignment {
        case "Center": left = area.midX - block.width / 2
        case "Right": left = area.maxX - block.width
        default: left = area.minX
        }
        let top: CGFloat
        switch layout.verticalAlignment {
        case "Center": top = area.midY - block.height / 2
        case "Bottom": top = area.maxY - block.height
        default: top = area.minY
        }
        return items.enumerated().map { index, item in
            var column = horizontal ? index % perLine : index / perLine
            var row = horizontal ? index / perLine : index % perLine
            if layout.startCorner.hasSuffix("Right") { column = columns - 1 - column }
            if layout.startCorner.hasPrefix("Bottom") { row = rows - 1 - row }
            return (item, CGRect(x: left + CGFloat(column) * (cell.width + gap.width),
                                 y: top + CGFloat(row) * (cell.height + gap.height),
                                 width: cell.width, height: cell.height))
        }
    }

    /// An object's frame: grown to fit what is in it when it has AutomaticSize, then held
    /// to a UISizeConstraint and a UIAspectRatioConstraint inside it.
    private func sizedFrame(of object: GuiObject, in area: CGRect) -> CGRect {
        let frame = Self.frame(of: object, in: area)
        var size = frame.size
        if object.automaticSize != "None" {
            let fit = contentExtent(of: object, width: frame.width, area: area)
            if object.automaticSize.contains("X") { size.width = max(size.width, fit.width) }
            if object.automaticSize.contains("Y") { size.height = max(size.height, fit.height) }
        }
        let modifiers = children(of: object.id).compactMap { objects[$0] }
        if let limit = modifiers.first(where: { $0.kind == .uiSizeConstraint }) {
            size = Self.clamp(size, min: limit.minSize, max: limit.maxSize)
        }
        if let aspect = modifiers.first(where: { $0.kind == .uiAspectRatioConstraint }) {
            size = Self.keep(size, aspect)
        }
        return size == frame.size ? frame : Self.frame(of: object, in: area, size: size)
    }

    static func clamp(_ size: CGSize, min low: SIMD2<Float>, max high: SIMD2<Float>) -> CGSize {
        CGSize(width: Swift.min(Swift.max(size.width, CGFloat(low.x)), CGFloat(Swift.max(high.x, low.x))),
               height: Swift.min(Swift.max(size.height, CGFloat(low.y)), CGFloat(Swift.max(high.y, low.y))))
    }

    /// A size held to an aspect ratio: the largest of that shape inside it, or one side
    /// kept and the other worked out.
    static func keep(_ size: CGSize, _ aspect: GuiObject) -> CGSize {
        let ratio = CGFloat(aspect.aspectRatio)
        guard ratio > 0, size.width > 0 || size.height > 0 else { return size }
        if aspect.aspectType == "ScaleWithParentSize" {
            return aspect.dominantAxis == "Height" ? CGSize(width: size.height * ratio, height: size.height)
                                                   : CGSize(width: size.width, height: size.width / ratio)
        }
        return size.width / max(size.height, 0.0001) > ratio ? CGSize(width: size.height * ratio, height: size.height)
                                                             : CGSize(width: size.width, height: size.width / ratio)
    }

    /// How much room what is inside takes: its text, or its children.
    private func contentExtent(of object: GuiObject, width: CGFloat, area: CGRect) -> CGSize {
        let modifiers = children(of: object.id).compactMap { objects[$0] }
        let padding = modifiers.first { $0.kind == .uiPadding }
        let box = CGRect(x: 0, y: 0, width: width, height: 0)
        let inner = padding.map { Self.inset(CGRect(x: 0, y: 0, width: width, height: 1000), by: $0) }
            ?? CGRect(x: 0, y: 0, width: width, height: 1000)
        let edges = CGSize(width: width - inner.width, height: 1000 - inner.height)
        var fit = CGSize.zero
        if object.kind.showsText {
            let shown = object.text.isEmpty ? object.placeholderText : object.text
            let measured = GuiFont.measure(shown, font: object.font, size: CGFloat(object.textSize),
                                           width: object.textWrapped && !object.automaticSize.contains("X") ? inner.width : nil)
            fit = CGSize(width: measured.width + 4, height: measured.height)
        }
        let placedKids = arranged(childrenOf: object.id, in: CGRect(x: 0, y: 0, width: inner.width, height: 0))
        for (_, frame) in placedKids {
            fit.width = max(fit.width, frame.maxX)
            fit.height = max(fit.height, frame.maxY)
        }
        _ = box
        return CGSize(width: fit.width + edges.width, height: fit.height + edges.height)
    }

    /// A ScrollingFrame's canvas, grown to what is in it when AutomaticCanvasSize says so.
    private func canvasSize(of object: GuiObject, content: CGRect) -> CGSize {
        var canvas = object.canvasSize.resolved(in: content.size)
        if object.automaticCanvasSize != "None" {
            let kids = arranged(childrenOf: object.id, in: CGRect(x: 0, y: 0, width: content.width, height: content.height))
            let extent = kids.reduce(CGSize.zero) { CGSize(width: max($0.width, $1.1.maxX), height: max($0.height, $1.1.maxY)) }
            if object.automaticCanvasSize.contains("X") { canvas.width = max(canvas.width, extent.width) }
            if object.automaticCanvasSize.contains("Y") { canvas.height = max(canvas.height, extent.height) }
        }
        return CGSize(width: max(canvas.width, content.width), height: max(canvas.height, content.height))
    }

    /// A frame less a UIPadding: left and right as a share of its width, top and bottom
    /// of its height, plus pixels.
    static func inset(_ frame: CGRect, by padding: GuiObject) -> CGRect {
        func amount(_ udim: SIMD2<Float>, of length: CGFloat) -> CGFloat { CGFloat(udim.x) * length + CGFloat(udim.y) }
        let left = amount(padding.paddingLeft, of: frame.width)
        let right = amount(padding.paddingRight, of: frame.width)
        let top = amount(padding.paddingTop, of: frame.height)
        let bottom = amount(padding.paddingBottom, of: frame.height)
        return CGRect(x: frame.minX + left, y: frame.minY + top,
                      width: max(frame.width - left - right, 0), height: max(frame.height - top - bottom, 0))
    }

    /// Where an object sits inside its parent's area, from its Position, Size and
    /// AnchorPoint, as Roblox works it out — at its own size, or one it has grown to.
    static func frame(of object: GuiObject, in area: CGRect, size: CGSize? = nil) -> CGRect {
        let resolved = size ?? object.size.resolved(in: area.size)
        let width = resolved.width, height = resolved.height
        let x = area.minX + CGFloat(object.position.xScale) * area.width + CGFloat(object.position.xOffset)
            - CGFloat(object.anchorPoint.x) * width
        let y = area.minY + CGFloat(object.position.yScale) * area.height + CGFloat(object.position.yOffset)
            - CGFloat(object.anchorPoint.y) * height
        return CGRect(x: x, y: y, width: max(width, 0), height: max(height, 0))
    }
}
