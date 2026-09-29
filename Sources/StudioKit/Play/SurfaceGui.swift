import Foundation
import simd

/// One part face in world space. Drawing and input use exactly the same basis.
struct SurfaceFace {
    var center: Vec3
    var right: Vec3
    var down: Vec3
    var normal: Vec3
    var size: SIMD2<Float>

    init(part: Part, face: String, offset: Float = 0) {
        let n: Vec3, r: Vec3, d: Vec3
        switch face {
        case "Back": n = Vec3(0, 0, 1); r = Vec3(1, 0, 0); d = Vec3(0, -1, 0)
        case "Right": n = Vec3(1, 0, 0); r = Vec3(0, 0, -1); d = Vec3(0, -1, 0)
        case "Left": n = Vec3(-1, 0, 0); r = Vec3(0, 0, 1); d = Vec3(0, -1, 0)
        case "Top": n = Vec3(0, 1, 0); r = Vec3(1, 0, 0); d = Vec3(0, 0, 1)
        case "Bottom": n = Vec3(0, -1, 0); r = Vec3(1, 0, 0); d = Vec3(0, 0, -1)
        default: n = Vec3(0, 0, -1); r = Vec3(-1, 0, 0); d = Vec3(0, -1, 0)
        }
        normal = part.orientation.act(n)
        right = part.orientation.act(r)
        down = part.orientation.act(d)
        size = SIMD2(simd_dot(simd_abs(r), part.size), simd_dot(simd_abs(d), part.size))
        center = part.position + part.orientation.act(n * part.size * 0.5) + normal * (0.006 + offset * 0.001)
    }

    func point(_ uv: SIMD2<Float>) -> Vec3 { center + right * ((uv.x - 0.5) * size.x) + down * ((uv.y - 0.5) * size.y) }

    func hit(_ ray: Ray) -> (uv: SIMD2<Float>, distance: Float)? {
        let approach = simd_dot(ray.direction, normal)
        guard approach < -0.00001 else { return nil }
        let t = simd_dot(center - ray.origin, normal) / approach
        guard t >= 0, size.x > 0, size.y > 0 else { return nil }
        let delta = ray.origin + ray.direction * t - center
        let uv = SIMD2(simd_dot(delta, right) / size.x + 0.5, simd_dot(delta, down) / size.y + 0.5)
        guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { return nil }
        return (uv, t)
    }

    func canvas(_ object: GuiObject) -> CGSize {
        let pixels = object.sizingMode == "FixedSize" ? object.surfaceCanvasSize : size * object.pixelsPerStud
        return CGSize(width: CGFloat(min(max(pixels.x, 1), 16384)), height: CGFloat(min(max(pixels.y, 1), 16384)))
    }
}

extension GuiStore {
    func surfacePart(_ object: GuiObject, in model: SceneModel) -> Part? {
        let target = object.adornee.map { $0.hasPrefix("p:") ? UUID(uuidString: String($0.dropFirst(2))) : nil } ?? object.worldParent
        guard let target, let part = model.part(id: target), part.inWorld else { return nil }
        return part
    }

    func surfaces(in model: SceneModel) -> [(object: GuiObject, part: Part, face: SurfaceFace)] {
        objects.values.filter { $0.kind == .surfaceGui && $0.enabled && ($0.parent != nil || $0.worldParent != nil) }
            .sorted { ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id) }.compactMap {
                var parent = $0.parent
                while let id = parent, id != Self.playerGui {
                    guard let ancestor = objects[id], ancestor.enabled && ancestor.visible else { return nil }
                    parent = ancestor.parent
                }
                guard let part = surfacePart($0, in: model) else { return nil }
                return ($0, part, SurfaceFace(part: part, face: $0.face, offset: $0.zOffset))
            }
    }

    func surfaceHit(ray: Ray, model: SceneModel, eye: Vec3) -> (root: Int, point: CGPoint, size: CGSize)? {
        let hits = surfaces(in: model).compactMap { surface -> (GuiObject, SurfaceFace, SIMD2<Float>, Float)? in
            guard simd_distance(eye, surface.face.center) <= surface.object.maxDistance,
                  let hit = surface.face.hit(ray) else { return nil }
            if !surface.object.alwaysOnTop && (model.parts + model.terrainParts).contains(where: {
                $0.id != surface.part.id && $0.inWorld && $0.transparency < 0.99
                    && (Picking.intersect(ray: ray, part: $0, exact: true).map { $0 < hit.distance - 0.01 } ?? false)
            }) { return nil }
            return (surface.object, surface.face, hit.uv, hit.distance)
        }.sorted {
            if $0.0.alwaysOnTop != $1.0.alwaysOnTop { return $0.0.alwaysOnTop }
            if abs($0.3 - $1.3) > 0.01 { return $0.3 < $1.3 }
            return ($0.0.displayOrder, $0.0.id) > ($1.0.displayOrder, $1.0.id)
        }
        for (object, face, uv, _) in hits {
            let size = face.canvas(object)
            let point = CGPoint(x: CGFloat(uv.x) * size.width, y: CGFloat(uv.y) * size.height)
            if hit(root: object.id, at: point, size: size) != nil || layout(root: object.id, in: size).contains(where: {
                $0.object.kind == .scrollingFrame && $0.frame.contains(point) && ($0.clip?.contains(point) ?? true)
            }) { return (object.id, point, size) }
        }
        return nil
    }
}

extension PlayController {
    var worldGui: GuiStore? { gui }

    func withGuiInvocation<T>(local: Bool, _ body: () -> T) -> T {
        let previous = guiInvocationLocal
        guiInvocationLocal = local
        defer { guiInvocationLocal = previous }
        return local ? body() : gui.withSharedWorld(body)
    }

    func clickSurface(at point: SIMD2<Float>) -> Bool {
        guard viewSize.x > 0, viewSize.y > 0,
              let surface = gui.surfaceHit(ray: renderCamera.ray(atViewPoint: point, viewSize: viewSize), model: model, eye: renderCamera.position),
              let hit = gui.hit(root: surface.root, at: surface.point, size: surface.size) else { return false }
        if gui.focused != hit { gui.releaseFocus(enterPressed: false) }
        gui.click(hit)
        return true
    }

    func scrollSurface(at point: SIMD2<Float>, by delta: CGSize) -> Bool {
        guard viewSize.x > 0, viewSize.y > 0,
              let surface = gui.surfaceHit(ray: renderCamera.ray(atViewPoint: point, viewSize: viewSize), model: model, eye: renderCamera.position) else { return false }
        return gui.scroll(root: surface.root, at: surface.point, size: surface.size, by: delta)
    }

    /// Only world-parented server GUIs are shared. PlayerGui and LocalScript copies
    /// retain their own input, values and lifetime on every machine.
    func synchronizeWorldGui() {
        gui.withSharedWorld { synchronizeSharedWorldGui() }
    }

    private func synchronizeSharedWorldGui() {
        let roots = model.starterGui.filter { $0.worldParent != nil }
        let sharedIDs = Set(roots.flatMap { model.guiSubtree($0.id) })
        if worldFromHost {
            let shared = model.starterGui.filter { sharedIDs.contains($0.id) }
            guard shared != lastWorldGuiTemplates else { return }
            let old = Dictionary(uniqueKeysWithValues: lastWorldGuiTemplates.map { ($0.id, $0) })
            for gone in old.keys where !sharedIDs.contains(gone) {
                if let id = guiCopies.removeValue(forKey: gone) { gui.destroy(id) }
            }
            for template in shared {
                if guiCopies[template.id].flatMap(gui.object) == nil { guiCopies[template.id] = gui.create(template.kind) }
            }
            for template in shared where old[template.id] != template {
                guard let id = guiCopies[template.id] else { continue }
                var object = gui.object(id) ?? template.object(id: id)
                if let prior = old[template.id] {
                    let defaults = GuiObject(id: id, kind: template.kind)
                    for key in Set(prior.properties.keys).union(template.properties.keys) where prior.properties[key] != template.properties[key] {
                        _ = Self.setGuiProperty(&object, key, template.properties[key] ?? Self.guiProperty(defaults, key))
                    }
                    if prior.name != template.name { object.name = template.name }
                } else {
                    object = template.object(id: id)
                }
                object.worldParent = template.worldParent
                object.parent = template.parentID.flatMap { guiCopies[$0] }
                gui.update(id) { $0 = object }
                if old[template.id]?.viewportContent != template.viewportContent, let content = template.viewportContent {
                    gui.installViewport(content, in: id)
                }
            }
            lastWorldGuiTemplates = shared
            if hasPlayer {
                for root in roots where old[root.id] == nil { startWorldGuiScripts(root.id) }
            }
            retireWorldGuiScripts()
            return
        }
        let known = Set(lastWorldGuiTemplates.map(\.id))
        for root in roots where !known.contains(root.id) && guiCopies[root.id].flatMap(gui.object) == nil {
            guiCopies.merge(gui.copy(root, from: model.starterGui, into: GuiStore.playerGui)) { _, new in new }
            if hasPlayer { startWorldGuiScripts(root.id) }
        }
        for object in gui.objects.values where object.worldParent.map({ model.part(id: $0) == nil }) == true { gui.destroy(object.id) }
        let world = gui.objects.values.filter { $0.worldParent != nil && !$0.localOnly }.sorted { $0.id < $1.id }
        var kept: [StarterGuiObject] = []
        for root in world {
            for id in [root.id] + gui.descendants(of: root.id) {
                guard let object = gui.object(id), !object.localOnly else { continue }
                let sharedName = object.persistentProperties["name"]?.asString ?? model.guiObject(id: object.templateID)?.name ?? object.kind.rawValue
                var template = StarterGuiObject(kind: object.kind, name: sharedName)
                template.id = object.templateID
                template.worldParent = object.worldParent
                template.parentID = object.parent.flatMap { gui.object($0)?.templateID }
                template.properties = object.persistentProperties
                template.viewportContent = model.guiObject(id: object.templateID)?.viewportContent ?? gui.viewportContent(object.id)
                kept.append(template)
                guiCopies[template.id] = id
            }
        }
        let previousIDs = sharedIDs.union(lastWorldGuiTemplates.map(\.id))
        let next = model.starterGui.filter { !previousIDs.contains($0.id) } + kept
        let keptIDs = Set(kept.map(\.id))
        for gone in previousIDs.subtracting(keptIDs) { guiCopies[gone] = nil }
        if next != model.starterGui { model.starterGui = next }
        lastWorldGuiTemplates = kept
        retireWorldGuiScripts()
    }

    private func startWorldGuiScripts(_ root: UUID) {
        let scripts = model.guiSubtree(root).flatMap { model.guiScripts(in: $0) }
        runGuiScripts(scripts.map { ($0, false) })
    }

    func retireWorldGuiScripts() {
        for (root, running) in worldGuiScripts where guiCopies[root].flatMap(gui.object) == nil {
            scripts.endScope(running.scope, scripts: running.scripts)
            worldGuiScripts[root] = nil
        }
    }
}
