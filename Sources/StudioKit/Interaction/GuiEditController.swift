import Foundation
import CoreGraphics
import Combine

/// Screen sizes StarterGui can be previewed at in Studio.
enum GuiDevice: String, CaseIterable, Identifiable {
    case window, phone, phonePortrait, tablet, laptop, desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: return "Fit Window"
        case .phone: return "Phone"
        case .phonePortrait: return "Phone, Portrait"
        case .tablet: return "Tablet"
        case .laptop: return "Laptop"
        case .desktop: return "Desktop 1080p"
        }
    }

    /// Its screen in points; nil is the viewport as it is.
    var size: CGSize? {
        switch self {
        case .window: return nil
        case .phone: return CGSize(width: 844, height: 390)
        case .phonePortrait: return CGSize(width: 390, height: 844)
        case .tablet: return CGSize(width: 1024, height: 768)
        case .laptop: return CGSize(width: 1366, height: 768)
        case .desktop: return CGSize(width: 1920, height: 1080)
        }
    }
}

/// Where the previewed screen sits in the viewport: a device's screen, shrunk to fit
/// with a margin and centred, or the viewport itself.
struct GuiPreviewGeometry: Equatable {
    static let margin: CGFloat = 28

    /// The screen the GUI is laid out on, in its own points.
    let screen: CGSize
    /// Its top-left corner in the viewport, and how big one of its points is there.
    let origin: CGPoint
    let scale: CGFloat

    init(view: CGSize, device: GuiDevice, canvas: CGSize? = nil) {
        guard let size = canvas ?? device.size, view.width > 2 * Self.margin, view.height > 2 * Self.margin else {
            screen = view
            origin = .zero
            scale = 1
            return
        }
        let fit = min((view.width - 2 * Self.margin) / size.width, (view.height - 2 * Self.margin) / size.height, 1)
        screen = size
        scale = fit
        origin = CGPoint(x: ((view.width - size.width * fit) / 2).rounded(), y: ((view.height - size.height * fit) / 2).rounded())
    }

    var frameInView: CGRect { toView(CGRect(origin: .zero, size: screen)) }

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}

/// Editing StarterGui in the viewport, from the ribbon's GUI tab: clicking an object in
/// the preview selects it, dragging moves it, its handles resize it, the arrow keys nudge
/// it — snapped to its parent's and its siblings' edges and middles (the guides shown
/// while dragging), or to a grid. A drag changes only the preview until it ends, then is
/// one step to undo. Also everything else the GUI tab's buttons do.
final class GuiEditController: ObservableObject {
    /// A resize handle: a corner or the middle of a side.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                    y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
        }
    }

    /// A line something snapped to, in screen points: across (at a y) or down (at an x).
    struct Guide: Equatable {
        let vertical: Bool
        let at: CGFloat
        let from: CGFloat
        let to: CGFloat
    }

    @Published var device: GuiDevice = .window
    /// Moves and sizes land on multiples of this many pixels; 0 is off.
    @Published var grid: CGFloat = 0
    /// Snapping to the parent's and siblings' edges and middles.
    @Published var guides = true
    @Published private(set) var hovered: Int?
    @Published private(set) var shownGuides: [Guide] = []
    /// True between a drag's start and end.
    @Published private(set) var isDragging = false

    private unowned let model: SceneModel
    let store: GuiStore
    /// Each StarterGui object's copy in the preview, and back: set when the preview is rebuilt.
    var copies: [UUID: Int] = [:] {
        didSet { templates = Dictionary(copies.map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    private(set) var templates: [Int: UUID] = [:]
    /// How many screen points a viewport point is, for snapping and grabbing distances.
    var viewScale: CGFloat = 1

    private struct Drag {
        let template: UUID
        let handle: Handle?
        let start: CGPoint
        let frame: CGRect
        let area: CGRect
        let position: UDim2
        let size: UDim2
        let anchor: SIMD2<Float>
        let others: [CGRect]
        var result: (position: UDim2, size: UDim2)?
    }
    private var drag: Drag?

    init(model: SceneModel, store: GuiStore) {
        self.model = model
        self.store = store
    }

    // MARK: - What is where

    var surfaceRoot: Int? {
        guard let id = model.selectedGui, let root = model.screenGui(containing: id), root.kind == .surfaceGui else { return nil }
        return copies[root.id]
    }

    var surfaceSize: CGSize? {
        guard let id = surfaceRoot, let object = store.object(id) else { return nil }
        if let part = store.surfacePart(object, in: model) { return SurfaceFace(part: part, face: object.face).canvas(object) }
        return CGSize(width: CGFloat(object.surfaceCanvasSize.x), height: CGFloat(object.surfaceCanvasSize.y))
    }

    var screen: CGSize { surfaceSize ?? store.lastScreen }

    var selectedTemplate: StarterGuiObject? { model.selectedGui.flatMap(model.guiObject(id:)) }
    var selectedCopy: Int? { model.selectedGui.flatMap { copies[$0] } }

    func placed() -> [GuiStore.Placed] {
        if let root = surfaceRoot { return store.layout(root: root, in: screen) }
        return store.layout(in: screen)
    }

    /// What shows of an object: its frame, less what a clipping ancestor cuts off.
    static func visible(_ item: GuiStore.Placed) -> CGRect {
        item.clip.map { $0.intersection(item.frame) } ?? item.frame
    }

    /// The object drawn on top at a point on the screen.
    func hit(at point: CGPoint) -> Int? {
        placed().last { !$0.object.kind.isModifier && Self.visible($0).contains(point) }?.id
    }

    /// The selected object's handle near a point, if it can be resized.
    func handle(at point: CGPoint) -> Handle? {
        guard let copy = selectedCopy, canResize(copy),
              let frame = placed().first(where: { $0.id == copy })?.frame else { return nil }
        let reach = 7 / viewScale
        return Handle.allCases.first { handle in
            let spot = handle.point(in: frame)
            return abs(spot.x - point.x) <= reach && abs(spot.y - point.y) <= reach
        }
    }

    /// The UIListLayout or UIGridLayout placing an object, if one is.
    func arrangingLayout(of copy: Int) -> GuiObject? {
        guard let parent = store.object(copy)?.parent else { return nil }
        return store.children(of: parent).compactMap(store.object).first { $0.kind.isLayout }
    }

    /// Only objects that are drawn move, and not those a layout places.
    func canMove(_ copy: Int) -> Bool {
        guard let object = store.object(copy), !object.kind.isModifier, !object.kind.isLayer else { return false }
        return arrangingLayout(of: copy) == nil
    }

    /// A UIGridLayout decides its cells' sizes.
    func canResize(_ copy: Int) -> Bool {
        guard let object = store.object(copy), !object.kind.isModifier, !object.kind.isLayer else { return false }
        return arrangingLayout(of: copy)?.kind != .uiGridLayout
    }

    func hover(at point: CGPoint?) {
        let now = point.flatMap(hit(at:))
        if now != hovered { hovered = now }
    }

    // MARK: - Dragging

    /// A press at a screen point: a handle of the selection starts a resize; an object
    /// is selected and starts a move. False when there's nothing there.
    @discardableResult
    func begin(at point: CGPoint) -> Bool {
        drag = nil
        if let handle = handle(at: point), let template = model.selectedGui, let copy = copies[template] {
            start(template: template, copy: copy, handle: handle, at: point)
            return true
        }
        guard let copy = hit(at: point), let template = templates[copy] else { return false }
        if model.selectedGui != template || !model.selection.isEmpty {
            model.selection = []
            model.selectedGui = template
        }
        // Selecting rebuilt the preview: the copy's number may have changed.
        if let now = copies[template], canMove(now) { start(template: template, copy: now, handle: nil, at: point) }
        return true
    }

    private func start(template: UUID, copy: Int, handle: Handle?, at point: CGPoint) {
        let all = placed()
        guard let object = store.object(copy), let item = all.first(where: { $0.id == copy }),
              let area = store.area(for: copy, in: screen) else { return }
        let others = all.filter { $0.object.parent == object.parent && $0.id != copy && !$0.object.kind.isModifier }
            .map(\.frame)
        drag = Drag(template: template, handle: handle, start: point, frame: item.frame, area: area,
                    position: object.position, size: object.size, anchor: object.anchorPoint, others: others)
        isDragging = true
    }

    /// The press moved: the object follows in the preview.
    func drag(to point: CGPoint) {
        guard var current = drag else { return }
        let delta = CGSize(width: point.x - current.start.x, height: point.y - current.start.y)
        var frame = current.frame
        var lines: [Guide] = []
        if let handle = current.handle {
            var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
            if handle.movesLeft { minX = snap(edge: minX + delta.width, vertical: true, current, &lines) }
            if handle.movesRight { maxX = snap(edge: maxX + delta.width, vertical: true, current, &lines) }
            if handle.movesTop { minY = snap(edge: minY + delta.height, vertical: false, current, &lines) }
            if handle.movesBottom { maxY = snap(edge: maxY + delta.height, vertical: false, current, &lines) }
            // Never turned inside out: at least a pixel across.
            if handle.movesLeft { minX = min(minX, maxX - 1) } else { maxX = max(maxX, minX + 1) }
            if handle.movesTop { minY = min(minY, maxY - 1) } else { maxY = max(maxY, minY + 1) }
            frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            frame = frame.offsetBy(dx: delta.width, dy: delta.height)
            frame.origin.x += snap(moving: frame, vertical: true, current, &lines)
            frame.origin.y += snap(moving: frame, vertical: false, current, &lines)
        }
        let result = Self.udims(for: frame, in: current.area, anchor: current.anchor,
                                position: current.position, size: current.size, resized: current.handle != nil)
        current.result = result
        drag = current
        if lines != shownGuides { shownGuides = lines }
        if let copy = copies[current.template] {
            store.update(copy) { object in
                object.position = result.position
                object.size = result.size
            }
        }
    }

    /// The press let go: what the drag did becomes one step to undo.
    func end() {
        defer {
            drag = nil
            isDragging = false
            if !shownGuides.isEmpty { shownGuides = [] }
        }
        guard let finished = drag, let result = finished.result,
              result.position != finished.position || result.size != finished.size,
              let name = model.guiObject(id: finished.template)?.name else { return }
        var values: [(String, ScriptValue)] = [("position", SceneModel.guiValue(result.position))]
        if result.size != finished.size { values.append(("size", SceneModel.guiValue(result.size))) }
        model.setGuiProperties(finished.template, values, label: finished.handle == nil ? "Moved \(name)" : "Resized \(name)")
    }

    /// Nudged by pixels, from the arrow keys.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let template = model.selectedGui, let copy = copies[template], canMove(copy),
              let frame = placed().first(where: { $0.id == copy })?.frame,
              let area = store.area(for: copy, in: screen), let object = store.object(copy) else { return }
        let moved = frame.offsetBy(dx: dx, dy: dy)
        let result = Self.udims(for: moved, in: area, anchor: object.anchorPoint, position: object.position,
                                size: object.size, resized: false)
        model.setGuiProperties(template, [("position", SceneModel.guiValue(result.position))],
                               label: "Nudged \(model.guiObject(id: template)?.name ?? "GUI")")
    }

    // MARK: - Snapping

    /// Where lines may be snapped to on one axis: the parent's edges and middle, and each
    /// sibling's.
    private func candidates(vertical: Bool, _ drag: Drag) -> [CGFloat] {
        let rects = [drag.area] + drag.others
        return rects.flatMap { vertical ? [$0.minX, $0.midX, $0.maxX] : [$0.minY, $0.midY, $0.maxY] }
    }

    /// How far a moving frame shifts on one axis to snap its edges or middle to a guide,
    /// or its corner to the grid.
    private func snap(moving frame: CGRect, vertical: Bool, _ drag: Drag, _ lines: inout [Guide]) -> CGFloat {
        let features = vertical ? [frame.minX, frame.midX, frame.maxX] : [frame.minY, frame.midY, frame.maxY]
        if guides, let (feature, target) = nearest(features, candidates(vertical: vertical, drag)) {
            lines.append(guide(at: target, vertical: vertical, frame: frame.offsetBy(dx: vertical ? target - feature : 0,
                                                                                      dy: vertical ? 0 : target - feature), drag))
            return target - feature
        }
        guard grid > 0 else { return 0 }
        let start = vertical ? frame.minX - drag.area.minX : frame.minY - drag.area.minY
        return (start / grid).rounded() * grid - start
    }

    /// One moving edge, snapped.
    private func snap(edge: CGFloat, vertical: Bool, _ drag: Drag, _ lines: inout [Guide]) -> CGFloat {
        if guides, let (_, target) = nearest([edge], candidates(vertical: vertical, drag)) {
            lines.append(guide(at: target, vertical: vertical, frame: drag.frame, drag))
            return target
        }
        guard grid > 0 else { return edge }
        let origin = vertical ? drag.area.minX : drag.area.minY
        return origin + ((edge - origin) / grid).rounded() * grid
    }

    /// The closest feature–candidate pair within reach (six viewport points).
    private func nearest(_ features: [CGFloat], _ targets: [CGFloat]) -> (CGFloat, CGFloat)? {
        let reach = 6 / viewScale
        var best: (CGFloat, CGFloat, CGFloat)?
        for feature in features {
            for target in targets {
                let distance = abs(target - feature)
                if distance <= reach && distance < (best?.2 ?? .infinity) { best = (feature, target, distance) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func guide(at value: CGFloat, vertical: Bool, frame: CGRect, _ drag: Drag) -> Guide {
        let span = drag.area.union(frame)
        return vertical ? Guide(vertical: true, at: value, from: span.minY, to: span.maxY)
                        : Guide(vertical: false, at: value, from: span.minX, to: span.maxX)
    }

    /// Position and Size for a frame in an area, kept in the units they were in: a
    /// component that was all scale stays scale, anything else changes by pixels.
    static func udims(for frame: CGRect, in area: CGRect, anchor: SIMD2<Float>, position: UDim2, size: UDim2,
                      resized: Bool) -> (position: UDim2, size: UDim2) {
        func component(_ scale: Float, _ offset: Float, target: CGFloat, length: CGFloat) -> (Float, Float) {
            if scale != 0 && offset == 0 && length > 0 {
                return (SceneModel.tidy(Float(target / length), 10000), 0)
            }
            return (scale, (Float(target) - scale * Float(length)).rounded())
        }
        var newSize = size
        if resized {
            (newSize.xScale, newSize.xOffset) = component(size.xScale, size.xOffset, target: frame.width, length: area.width)
            (newSize.yScale, newSize.yOffset) = component(size.yScale, size.yOffset, target: frame.height, length: area.height)
        }
        let x = frame.minX - area.minX + CGFloat(anchor.x) * frame.width
        let y = frame.minY - area.minY + CGFloat(anchor.y) * frame.height
        var newPosition = position
        (newPosition.xScale, newPosition.xOffset) = component(position.xScale, position.xOffset, target: x, length: area.width)
        (newPosition.yScale, newPosition.yOffset) = component(position.yScale, position.yOffset, target: y, length: area.height)
        return (newPosition, newSize)
    }

    // MARK: - The GUI tab's buttons

    func insert(_ kind: GuiObject.Kind) { model.insertGui(kind) }

    func align(_ alignment: GuiAlignment) {
        if let id = model.selectedGui { model.alignGui(id, alignment) }
    }

    func fill() {
        if let id = model.selectedGui { model.fillGuiParent(id) }
    }

    func reorder(toFront: Bool) {
        if let id = model.selectedGui { model.reorderGui(id, toFront: toFront) }
    }

    func duplicate() {
        if let id = model.selectedGui { model.duplicateGui(id) }
    }

    func delete() {
        if let id = model.selectedGui { model.deleteGuiObject(id) }
    }

    /// Position and Size in scale or in pixels, for the parent as it is on the previewed screen.
    func convert(toScale: Bool) {
        guard let template = model.selectedGui, let copy = copies[template],
              let area = store.area(for: copy, in: screen) else { return }
        model.convertGuiUnits(template, toScale: toScale, parentSize: area.size)
    }

    /// Whether the selected object can be moved around (aligned, filled, nudged).
    var selectionMovable: Bool { selectedCopy.map(canMove) ?? false }
    /// Whether it's something drawn (not a ScreenGui or a modifier).
    var selectionDrawn: Bool {
        guard let kind = selectedTemplate?.kind else { return false }
        return !kind.isModifier && !kind.isLayer
    }
}
