import Foundation

/// A GUI object made in Studio and kept in StarterGui. When play starts, each player's
/// PlayerGui gets a copy of every ScreenGui here, with what is inside; the LocalScripts
/// in it (scripts whose host is `.starterGui`) run in that copy.
///
/// Only the properties that differ from a new object's are kept, by their host names,
/// as `gui.set` takes them — so a scene saved today opens after new properties exist.
struct StarterGuiObject: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The object it is in; nil at the top of StarterGui, where the ScreenGuis are.
    var parentID: UUID?
    /// A world SurfaceGui belongs to this part; other roots belong to StarterGui.
    var worldParent: UUID?
    var viewportContent: ViewportContent?
    var kind: GuiObject.Kind
    var name: String
    var properties: [String: ScriptValue] = [:]

    init(kind: GuiObject.Kind, name: String? = nil, parentID: UUID? = nil) {
        self.kind = kind
        self.name = name ?? kind.rawValue
        self.parentID = parentID
    }

    /// As a GUI object with its properties set, for reading them and for copies.
    func object(id: Int = 0) -> GuiObject {
        var object = GuiObject(id: id, kind: kind)
        object.templateID = self.id
        object.worldParent = worldParent
        object.name = name
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            _ = PlayController.setGuiProperty(&object, key, value)
        }
        return object
    }
}

// SceneModel — StarterGui: the GUIs made in Studio.

extension SceneModel {
    func guiObject(id: UUID) -> StarterGuiObject? { starterGui.first { $0.id == id } }

    @discardableResult
    func addSurfaceGui(to part: UUID) -> UUID? {
        guard self.part(id: part) != nil else { return nil }
        var object = StarterGuiObject(kind: .surfaceGui)
        object.worldParent = part
        commit("Added SurfaceGui") {
            starterGui.append(object)
            selection = []
            selectedGui = object.id
        }
        return object.id
    }

    /// Carries world GUI templates and their scripts with copied parts. References
    /// within the copy follow it; references outside it keep their original target.
    func cloneWorldGui(remap nodes: [UUID: UUID]) {
        let roots = starterGui.filter { $0.worldParent.map { nodes[$0] != nil } ?? false }
        let ids = Set(roots.flatMap { guiSubtree($0.id) })
        var remap = nodes
        for id in ids { remap[id] = UUID() }
        for original in starterGui where ids.contains(original.id) {
            var copy = original
            copy.id = remap[original.id]!
            copy.parentID = original.parentID.flatMap { remap[$0] }
            copy.worldParent = original.worldParent.flatMap { remap[$0] }
            copy.viewportContent = copy.viewportContent?.reidentified()
            if let token = copy.properties["adornee"]?.asString, token.hasPrefix("p:"),
               let old = UUID(uuidString: String(token.dropFirst(2))), let target = remap[old] {
                copy.properties["adornee"] = .string("p:\(target)")
            }
            starterGui.append(copy)
        }
        for original in scripts where original.host == .starterGui && (original.parentID.map(ids.contains) ?? false) {
            var copy = original; copy.id = UUID(); copy.parentID = original.parentID.flatMap { remap[$0] }
            scripts.append(copy)
        }
    }

    /// In the order they were made; nil for the top of StarterGui.
    func guiChildren(of parent: UUID?) -> [StarterGuiObject] { starterGui.filter { $0.parentID == parent } }

    /// An object and everything inside it.
    func guiSubtree(_ id: UUID) -> [UUID] {
        [id] + starterGui.filter { $0.parentID == id }.flatMap { guiSubtree($0.id) }
    }

    /// The ScreenGui an object is in (itself, for a ScreenGui).
    func screenGui(containing id: UUID) -> StarterGuiObject? {
        var current = guiObject(id: id)
        while let object = current, object.parentID != nil { current = object.parentID.flatMap(guiObject(id:)) }
        return current
    }

    /// Adds a GUI object — a ScreenGui at the top, anything else inside another — and
    /// selects it. With undo.
    @discardableResult
    func addGuiObject(_ kind: GuiObject.Kind, in parent: UUID?) -> UUID? {
        // Only ScreenGuis stand at the top; only they can't go inside something.
        guard (parent == nil) == kind.isLayer, parent.map({ guiObject(id: $0) != nil }) ?? true else { return nil }
        let taken = guiChildren(of: parent).map(\.name)
        var object = StarterGuiObject(kind: kind, name: Self.unique(kind.rawValue, among: taken), parentID: parent)
        // Somewhere to be seen: a new object sits in from the corner.
        if !kind.isModifier && kind != .screenGui {
            object.properties["position"] = .list([.number(0), .number(40), .number(0), .number(40)])
        }
        commit("Added \(object.name)") {
            starterGui.append(object)
            selectedGui = object.id
            selection = []
        }
        return object.id
    }

    /// Sets one property, as a script would. With undo.
    func setGuiProperty(_ id: UUID, _ key: String, _ value: ScriptValue) {
        setGuiProperties(id, [(key, value)])
    }

    /// A value as a scene file can hold it: files have no infinities, so "no limit" is
    /// kept as a billion — and a UISizeConstraint with no MaxSize at all as nothing.
    static func storable(_ key: String, _ value: ScriptValue) -> ScriptValue? {
        func finite(_ value: ScriptValue) -> ScriptValue {
            switch value {
            case .number(let d) where !d.isFinite: return .number(d.isNaN ? 0 : d > 0 ? 1e9 : -1e9)
            case .list(let items): return .list(items.map(finite))
            default: return value
            }
        }
        let kept = finite(value)
        if key == "maxsize", let limits = kept.asList?.compactMap(\.asDouble), limits.allSatisfy({ $0 >= 1e8 }) { return nil }
        return kept
    }

    func renameGuiObject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = starterGui.firstIndex(where: { $0.id == id }) else { return }
        commit("Renamed") { starterGui[index].name = trimmed }
    }

    /// Removes an object, what is inside it, and the scripts in any of them. With undo.
    func deleteGuiObject(_ id: UUID) {
        let doomed = Set(guiSubtree(id))
        commit("Deleted \(guiObject(id: id)?.name ?? "GUI")") {
            starterGui.removeAll { doomed.contains($0.id) }
            scripts.removeAll { $0.host == .starterGui && ($0.parentID.map(doomed.contains) ?? true) }
            if let selected = selectedGui, doomed.contains(selected) { selectedGui = nil }
        }
    }

    /// The LocalScripts inside a GUI object.
    func guiScripts(in id: UUID) -> [ScriptObject] {
        scripts.filter { $0.host == .starterGui && $0.parentID == id }
    }
}

// SceneModel — StarterGui: what the GUI tab of the ribbon does.

/// Where the Align buttons put an object in its parent.
enum GuiAlignment: String, CaseIterable, Identifiable {
    case left, centerX, right, top, centerY, bottom
    var id: String { rawValue }
    var horizontal: Bool { self == .left || self == .centerX || self == .right }
    /// The share of the parent it lines up with, which is also its AnchorPoint on that axis.
    var fraction: Float {
        switch self {
        case .left, .top: return 0
        case .centerX, .centerY: return 0.5
        case .right, .bottom: return 1
        }
    }
}

extension GuiObject.Kind {
    /// Holds other objects when something is inserted with it selected; anything else
    /// gets a sibling instead.
    var isContainer: Bool { isLayer || self == .frame || self == .scrollingFrame || self == .viewportFrame }
    /// A modifier that only means something on a drawn object, not on a ScreenGui.
    var needsGuiObject: Bool { isModifier && self != .uiListLayout && self != .uiGridLayout && self != .uiPadding }
}

extension SceneModel {
    /// Several properties at once, as one step to undo; false if any is refused.
    @discardableResult
    func setGuiProperties(_ id: UUID, _ values: [(String, ScriptValue)], label: String? = nil) -> Bool {
        guard let index = starterGui.firstIndex(where: { $0.id == id }) else { return false }
        var object = starterGui[index].object()
        for (key, value) in values where !PlayController.setGuiProperty(&object, key, value) { return false }
        commit(label ?? "Changed \(starterGui[index].name)") {
            for (key, value) in values { starterGui[index].properties[key] = Self.storable(key, value) }
        }
        return true
    }

    /// Where the ribbon would put a new object of a kind, given what is selected: nil
    /// when it can't go anywhere (a modifier with nothing selected).
    func guiInsertTarget(for kind: GuiObject.Kind) -> (parent: UUID?, needsScreen: Bool)? {
        if kind.isLayer { return (nil, false) }
        // A modifier is looked past, to what it modifies.
        var anchor = selectedGui.flatMap(guiObject(id:))
        if let current = anchor, current.kind.isModifier { anchor = current.parentID.flatMap(guiObject(id:)) }
        if kind.isModifier {
            guard let anchor, !anchor.kind.isModifier else { return nil }
            if kind.needsGuiObject && anchor.kind.isLayer { return nil }
            return (anchor.id, false)
        }
        guard let anchor else {
            // Nothing selected: the first ScreenGui, or a new one.
            if let screen = guiChildren(of: nil).first(where: { $0.kind == .screenGui }) { return (screen.id, false) }
            return (nil, true)
        }
        return (anchor.kind.isContainer ? anchor.id : anchor.parentID, false)
    }

    /// The ribbon's Insert: a new object where `guiInsertTarget` says — in a new
    /// ScreenGui if there is none, all one step to undo — selected. A modifier its
    /// target already has is selected instead of doubled.
    @discardableResult
    func insertGui(_ kind: GuiObject.Kind) -> UUID? {
        guard let target = guiInsertTarget(for: kind) else { return nil }
        if kind.isModifier, let parent = target.parent,
           let existing = guiChildren(of: parent).first(where: { $0.kind == kind || ($0.kind.isLayout && kind.isLayout) }) {
            selectedGui = existing.id
            selection = []
            statusText = "\(guiObject(id: parent)?.name ?? "It") already has a \(existing.kind.rawValue)"
            return existing.id
        }
        var made: [StarterGuiObject] = []
        var parent = target.parent
        if target.needsScreen {
            let screen = StarterGuiObject(kind: .screenGui, name: Self.unique("ScreenGui", among: guiChildren(of: nil).map(\.name)))
            made.append(screen)
            parent = screen.id
        }
        let siblings = parent.map(guiChildren(of:)) ?? guiChildren(of: nil)
        var object = StarterGuiObject(kind: kind, name: Self.unique(kind.rawValue, among: siblings.map(\.name)), parentID: parent)
        if kind == .surfaceGui { object.worldParent = selection.first.flatMap { part(id: $0)?.id } }
        if !kind.isModifier && kind != .screenGui {
            // Each new one a little further in than the last, so none hides another.
            let step = Double(20 * (siblings.filter { !$0.kind.isModifier }.count % 10))
            object.properties["position"] = .list([.number(0), .number(40 + step), .number(0), .number(40 + step)])
        }
        if kind.showsImage, let picture = assets.first(where: { $0.kind == .image }) {
            object.properties["image"] = .string(picture.reference)
        }
        made.append(object)
        commit("Added \(object.name)") {
            starterGui += made
            selectedGui = object.id
            selection = []
        }
        return object.id
    }

    /// Lines an object up with its parent's edge or middle on one axis: Position there
    /// by scale, AnchorPoint the same share, so it stays put on any screen size.
    func alignGui(_ id: UUID, _ alignment: GuiAlignment) {
        guard let template = guiObject(id: id), !template.kind.isModifier, !template.kind.isLayer else { return }
        let object = template.object()
        var position = object.position
        var anchor = object.anchorPoint
        if alignment.horizontal {
            position.xScale = alignment.fraction
            position.xOffset = 0
            anchor.x = alignment.fraction
        } else {
            position.yScale = alignment.fraction
            position.yOffset = 0
            anchor.y = alignment.fraction
        }
        setGuiProperties(id, [("position", Self.guiValue(position)), ("anchorpoint", Self.guiValue(anchor))],
                         label: "Aligned \(template.name)")
    }

    /// Fills the parent: Size {1, 0}, {1, 0} at the corner.
    func fillGuiParent(_ id: UUID) {
        guard let template = guiObject(id: id), !template.kind.isModifier, !template.kind.isLayer else { return }
        setGuiProperties(id, [("position", Self.guiValue(UDim2())), ("size", Self.guiValue(UDim2(xScale: 1, yScale: 1))),
                              ("anchorpoint", Self.guiValue(SIMD2<Float>(0, 0)))],
                         label: "\(template.name) fills its parent")
    }

    /// In front of every sibling (ZIndex one more than the highest), or behind them all.
    func reorderGui(_ id: UUID, toFront: Bool) {
        guard let template = guiObject(id: id), !template.kind.isModifier, !template.kind.isLayer else { return }
        let others = guiChildren(of: template.parentID).filter { $0.id != id && !$0.kind.isModifier }
            .map { $0.object().zIndex }
        let z = toFront ? (others.max() ?? 0) + 1 : (others.min() ?? 2) - 1
        setGuiProperties(id, [("zindex", .number(Double(z)))], label: toFront ? "Brought \(template.name) to the front"
                                                                               : "Sent \(template.name) to the back")
    }

    /// A copy of an object, what is inside it and its LocalScripts, beside it and a
    /// little down and to the right; selected.
    @discardableResult
    func duplicateGui(_ id: UUID) -> UUID? {
        guard let original = guiObject(id: id) else { return nil }
        var remap: [UUID: UUID] = [:]
        for member in guiSubtree(id) { remap[member] = UUID() }
        var copies: [StarterGuiObject] = []
        for member in guiSubtree(id) {
            guard var copy = guiObject(id: member) else { continue }
            copy.id = remap[member]!
            copy.viewportContent = copy.viewportContent?.reidentified()
            copy.parentID = member == id ? original.parentID : copy.parentID.flatMap { remap[$0] }
            copies.append(copy)
        }
        let taken = guiChildren(of: original.parentID).map(\.name)
        copies[0].name = Self.unique(original.name, among: taken)
        if !original.kind.isModifier && !original.kind.isLayer {
            var position = original.object().position
            position.xOffset += 10
            position.yOffset += 10
            copies[0].properties["position"] = Self.guiValue(position)
        }
        let scriptCopies = scripts.filter { $0.host == .starterGui && ($0.parentID.map { remap[$0] != nil } ?? false) }
            .map { script -> ScriptObject in
                var copy = script
                copy.id = UUID()
                copy.parentID = script.parentID.flatMap { remap[$0] }
                return copy
            }
        commit("Duplicated \(original.name)") {
            starterGui += copies
            scripts += scriptCopies
            selectedGui = copies[0].id
            selection = []
        }
        return copies[0].id
    }

    /// Position and Size all in scale (a share of the parent) or all in pixels, for a
    /// parent that size, so the object stays exactly where it is on that screen.
    func convertGuiUnits(_ id: UUID, toScale: Bool, parentSize: CGSize) {
        guard let template = guiObject(id: id), !template.kind.isModifier, !template.kind.isLayer,
              parentSize.width > 0, parentSize.height > 0 else { return }
        let object = template.object()
        let width = Float(parentSize.width), height = Float(parentSize.height)
        func converted(_ value: UDim2) -> UDim2 {
            let x = value.xScale * width + value.xOffset, y = value.yScale * height + value.yOffset
            return toScale ? UDim2(xScale: Self.tidy(x / width, 1000), yScale: Self.tidy(y / height, 1000))
                           : UDim2(xOffset: x.rounded(), yOffset: y.rounded())
        }
        setGuiProperties(id, [("position", Self.guiValue(converted(object.position))),
                              ("size", Self.guiValue(converted(object.size)))],
                         label: toScale ? "\(template.name) in scale" : "\(template.name) in pixels")
    }

    static func guiValue(_ value: UDim2) -> ScriptValue { .list(value.list.map { .number(Double($0)) }) }
    static func guiValue(_ value: SIMD2<Float>) -> ScriptValue { .list([.number(Double(value.x)), .number(Double(value.y))]) }

    /// Rounded to so many parts in one: scales to thousandths.
    static func tidy(_ value: Float, _ parts: Float) -> Float { (value * parts).rounded() / parts }
}
