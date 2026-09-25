import Foundation
import Metal
import MetalKit
import AppKit
import simd

/// Headless verification of the parts the GUI cannot easily prove: shader compilation,
/// mesh orientation, ray picking and gizmo drag math. Run with `StudioApp --selftest`.
enum SelfTest {

    private static var failures = 0

    static func run() -> Int32 {
        failures = 0
        // Nothing the tests play reaches the speakers.
        SoundSystem.makeOutput = { RecordingOutput() }
        testRenderLoop()
        testShaderCompilation()
        testUniformLayout()
        testMeshNormals()
        testCameraRay()
        testPicking()
        testTranslateDrag()
        testScaleDrag()
        testRotateDrag()
        testUndoRedo()
        testSerialization()
        ScreenShaderSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        ShaderSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        EditorSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        DocumentSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        ScriptSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        WrenScriptSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        WrenMathSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        SyntaxSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        PlaySelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        PlayerSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        AvatarSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        AnimationSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        LightingSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        HierarchySelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        PhysicsSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        JointsSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        DocumentTabsSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        ScriptTemplateSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        GuiSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        GuiLayoutSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        TweenSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        RunModeSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        ToolSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        MouseSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        MovementSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        SplitAndEffectsSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        GuiEditorSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        SelectionSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        HudSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        AudioSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })
        LANSelfTest.run(check: Checker { name, condition, detail in check(name, condition, detail) })

        if failures == 0 {
            print("\nAll self-tests passed.")
        } else {
            print("\n\(failures) self-test(s) FAILED.")
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: - Assertions

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ok   \(name)")
        } else {
            failures += 1
            let d = detail()
            print("  FAIL \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    private static func near(_ a: Float, _ b: Float, _ tol: Float = 1e-3) -> Bool { abs(a - b) <= tol }
    private static func near(_ a: Vec3, _ b: Vec3, _ tol: Float = 1e-3) -> Bool { length(a - b) <= tol }

    private static func section(_ title: String) { print("\n\(title)") }

    // MARK: - Tests

    /// The viewport has to actually ask for frames.
    ///
    /// A display link only ticks when a display is driving vsync, so in a session with
    /// no display attached — headless, or screen sharing only — the viewport would sit
    /// there perfectly configured and never draw. This checks the fallback works.
    private static func testRenderLoop() {
        section("Render loop")
        _ = NSApplication.shared

        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.device = MTLCreateSystemDefaultDevice()
        check("a fresh view has requested nothing", view.framesRequested == 0)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view

        // Long enough to cover the display-link watchdog and then some frames.
        RunLoop.current.run(until: Date().addingTimeInterval(1.4))
        let afterAttach = view.framesRequested
        check("the viewport requests frames once it has a window", afterAttach > 0,
              "\(afterAttach) frames")

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check("and keeps requesting them", view.framesRequested > afterAttach,
              "\(view.framesRequested) vs \(afterAttach)")

        view.removeFromSuperview()
        let afterRemoval = view.framesRequested
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check("a detached view stops asking", view.framesRequested == afterRemoval,
              "\(view.framesRequested) vs \(afterRemoval)")
    }

    private static func testShaderCompilation() {
        section("Metal shaders")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("metal device", false, "no GPU available")
            return
        }
        check("metal device", true)
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            for name in ["scene_vertex", "scene_fragment", "flat_fragment", "grid_fragment"] {
                check("function \(name)", library.makeFunction(name: name) != nil)
            }
        } catch {
            check("compile shader source", false, "\(error)")
        }
    }

    private static func testUniformLayout() {
        section("Uniform layout")
        // These must match the structs in the Metal source byte for byte.
        check("FrameUniforms is 112 bytes", MemoryLayout<FrameUniforms>.stride == 112,
              "got \(MemoryLayout<FrameUniforms>.stride)")
        check("DrawUniforms is 144 bytes", MemoryLayout<DrawUniforms>.stride == 144,
              "got \(MemoryLayout<DrawUniforms>.stride)")
        check("Vertex is 32 bytes", MemoryLayout<Vertex>.stride == 32,
              "got \(MemoryLayout<Vertex>.stride)")
    }

    /// Every triangle of a closed convex-ish mesh must wind counter-clockwise when
    /// viewed from outside, or back-face culling will punch holes in it.
    private static func testMeshNormals() {
        section("Mesh winding")
        let meshes: [(String, ([Vertex], [UInt16]))] = [
            ("box", MeshFactory.box()),
            ("sphere", MeshFactory.sphere()),
            ("cylinder", MeshFactory.cylinder()),
            ("wedge", MeshFactory.wedge()),
            ("cone", MeshFactory.cone()),
            ("torus", MeshFactory.torus()),
            ("rounded box", MeshFactory.roundedBox(size: Vec3(2, 2, 1), radius: 0.2)),
            ("rounded limb", MeshFactory.roundedBox(size: Vec3(1, 2, 1), radius: 0.25)),
            ("head", MeshFactory.head()),
            ("smile", MeshFactory.arc(from: 3.6, to: 5.8)),
            ("face", MeshFactory.face())
        ]
        for (name, data) in meshes {
            let (vertices, indices) = data
            var bad = 0
            var degenerate = 0
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = vertices[Int(indices[i])]
                let b = vertices[Int(indices[i + 1])]
                let c = vertices[Int(indices[i + 2])]
                let geometric = cross(b.position - a.position, c.position - a.position)
                if length(geometric) < 1e-9 { degenerate += 1; continue }
                let averageNormal = normalize(a.normal + b.normal + c.normal)
                if dot(normalize(geometric), averageNormal) < 0.05 { bad += 1 }
            }
            check("\(name): winding matches normals", bad == 0, "\(bad) reversed triangles")
            check("\(name): no degenerate triangles", degenerate == 0, "\(degenerate) degenerate")
        }
    }

    private static func testCameraRay() {
        section("Camera")
        var camera = Camera()
        camera.target = Vec3(0, 0, 0)
        camera.distance = 20
        let size = SIMD2<Float>(800, 600)
        let centerRay = camera.ray(atViewPoint: SIMD2<Float>(400, 300), viewSize: size)
        check("centre ray points at the target",
              near(normalize(centerRay.direction), camera.forward, 2e-3),
              "\(centerRay.direction) vs \(camera.forward)")

        let t = Intersect.rayPlane(centerRay, point: .zero, normal: Vec3(0, 1, 0))
        check("centre ray reaches the ground plane", t != nil)
        if let t {
            check("ground hit is at the camera target", near(centerRay.point(at: t), camera.target, 0.05),
                  "\(centerRay.point(at: t))")
        }

        // A ray through the right edge must lean toward the camera's right vector.
        let edgeRay = camera.ray(atViewPoint: SIMD2<Float>(790, 300), viewSize: size)
        check("edge ray leans right", dot(edgeRay.direction, camera.right) > 0.2)
    }

    private static func testPicking() {
        section("Picking")
        var block = Part()
        block.shape = .block
        block.position = Vec3(0, 0, 0)
        block.size = Vec3(2, 2, 2)

        let straight = Ray(origin: Vec3(0, 0, 10), direction: Vec3(0, 0, -1))
        let hit = Picking.intersect(ray: straight, part: block)
        check("ray hits a block", hit != nil)
        if let hit { check("block hit distance is 9", near(hit, 9, 0.01), "got \(hit)") }

        let miss = Ray(origin: Vec3(5, 0, 10), direction: Vec3(0, 0, -1))
        check("ray misses an offset block", Picking.intersect(ray: miss, part: block) == nil)

        // Rotating 45° about Y grows the silhouette, so a previously-missing ray now hits.
        var rotated = block
        rotated.rotationDegrees = Vec3(0, 45, 0)
        let grazing = Ray(origin: Vec3(1.3, 0, 10), direction: Vec3(0, 0, -1))
        check("picking respects rotation", Picking.intersect(ray: grazing, part: block) == nil
              && Picking.intersect(ray: grazing, part: rotated) != nil)

        var sphere = Part()
        sphere.shape = .sphere
        sphere.position = .zero
        sphere.size = Vec3(2, 2, 2)
        let sphereHit = Picking.intersect(ray: straight, part: sphere)
        check("ray hits a sphere", sphereHit != nil)
        if let sphereHit { check("sphere hit distance is 9", near(sphereHit, 9, 0.01), "got \(sphereHit)") }
        // The corner of the bounding box is empty for a sphere.
        let corner = Ray(origin: Vec3(0.95, 0.95, 10), direction: Vec3(0, 0, -1))
        check("sphere is not picked at its box corner", Picking.intersect(ray: corner, part: sphere) == nil)

        var cylinder = Part()
        cylinder.shape = .cylinder
        cylinder.size = Vec3(2, 4, 2)
        check("ray hits a cylinder wall", Picking.intersect(ray: straight, part: cylinder) != nil)
        check("ray hits a cylinder cap",
              Picking.intersect(ray: Ray(origin: Vec3(0, 10, 0), direction: Vec3(0, -1, 0)), part: cylinder) != nil)
        check("ray misses outside the cylinder radius",
              Picking.intersect(ray: Ray(origin: Vec3(1.4, 0, 10), direction: Vec3(0, 0, -1)), part: cylinder) == nil)

        // Nearest part wins when two overlap along the ray.
        var near1 = block; near1.id = UUID(); near1.position = Vec3(0, 0, 4)
        var far1 = block; far1.id = UUID(); far1.position = Vec3(0, 0, -4)
        let picked = Picking.pick(ray: straight, in: [far1, near1])
        check("nearest part wins", picked?.part.id == near1.id)

        var locked = block; locked.id = UUID(); locked.locked = true
        check("locked parts are not pickable", Picking.pick(ray: straight, in: [locked]) == nil)
    }

    private static func testTranslateDrag() {
        section("Move gizmo")
        let model = SceneModel()
        model.parts = []
        model.snapEnabled = false
        let id = model.addPart(shape: .block, at: Vec3(0, 0, 0))
        model.gizmoMode = .move
        model.selection = [id]

        var camera = Camera()
        camera.target = .zero
        camera.distance = 25

        let basis = matrix_identity_float3x3
        let s = GizmoLayout.scale(pivot: .zero, cameraPosition: camera.position)

        // Aim at the middle of the X shaft.
        let shaftPoint = Vec3(s * 0.6, 0, 0)
        let aim = Ray(origin: shaftPoint + Vec3(0, 0, 40), direction: Vec3(0, 0, -1))
        let handle = Gizmo.hitTest(ray: aim, mode: .move, pivot: .zero, basis: basis, scale: s)
        check("X arrow is hit", handle == .translateAxis(0), "got \(String(describing: handle))")

        guard let handle, var drag = Gizmo.beginDrag(handle: handle, ray: aim, model: model, camera: camera) else {
            check("begin move drag", false); return
        }
        check("begin move drag", true)
        drag.basis = basis

        // Move the aim 5 studs along +X; the part should follow exactly.
        let moved = Ray(origin: shaftPoint + Vec3(5, 0, 40), direction: Vec3(0, 0, -1))
        Gizmo.updateDrag(drag, ray: moved, model: model)
        check("part moved 5 along X", near(model.part(id: id)!.position, Vec3(5, 0, 0), 0.01),
              "\(model.part(id: id)!.position)")

        // Snapping quantises the motion.
        model.snapEnabled = true
        model.moveSnap = 1
        let fractional = Ray(origin: shaftPoint + Vec3(5.4, 0, 40), direction: Vec3(0, 0, -1))
        Gizmo.updateDrag(drag, ray: fractional, model: model)
        check("snap rounds to whole studs", near(model.part(id: id)!.position.x, 5, 0.001),
              "\(model.part(id: id)!.position.x)")

        // Other axes are untouched.
        check("Y and Z unchanged", near(model.part(id: id)!.position.y, 0) && near(model.part(id: id)!.position.z, 0))
    }

    private static func testScaleDrag() {
        section("Scale gizmo")
        let model = SceneModel()
        model.parts = []
        model.snapEnabled = false
        let id = model.addPart(shape: .block, at: Vec3(0, 0, 0))
        model.update(id: id) { $0.size = Vec3(2, 2, 2) }
        model.gizmoMode = .scale
        model.selection = [id]

        var camera = Camera()
        camera.target = .zero
        camera.distance = 25
        let s = GizmoLayout.scale(pivot: .zero, cameraPosition: camera.position)

        let shaftPoint = Vec3(s * 0.6, 0, 0)
        let aim = Ray(origin: shaftPoint + Vec3(0, 0, 40), direction: Vec3(0, 0, -1))
        guard let handle = Gizmo.hitTest(ray: aim, mode: .scale, pivot: .zero, basis: matrix_identity_float3x3, scale: s),
              let drag = Gizmo.beginDrag(handle: handle, ray: aim, model: model, camera: camera) else {
            check("begin scale drag", false); return
        }
        check("begin scale drag", handle == .scaleAxis(0))

        let pulled = Ray(origin: shaftPoint + Vec3(2, 0, 40), direction: Vec3(0, 0, -1))
        Gizmo.updateDrag(drag, ray: pulled, model: model)
        let part = model.part(id: id)!
        check("size grew by 2 on X", near(part.size.x, 4, 0.01), "\(part.size.x)")
        check("opposite face stayed put", near(part.position.x, 1, 0.01), "\(part.position.x)")
        check("other dimensions unchanged", near(part.size.y, 2) && near(part.size.z, 2))

        // Dragging far inward clamps instead of inverting the part.
        let crushed = Ray(origin: shaftPoint + Vec3(-40, 0, 40), direction: Vec3(0, 0, -1))
        Gizmo.updateDrag(drag, ray: crushed, model: model)
        check("size clamps above zero", model.part(id: id)!.size.x >= 0.05, "\(model.part(id: id)!.size.x)")
    }

    private static func testRotateDrag() {
        section("Rotate gizmo")
        let model = SceneModel()
        model.parts = []
        model.snapEnabled = false
        let id = model.addPart(shape: .block, at: Vec3(0, 0, 0))
        model.gizmoMode = .rotate
        model.selection = [id]

        var camera = Camera()
        camera.target = .zero
        camera.distance = 25
        let s = GizmoLayout.scale(pivot: .zero, cameraPosition: camera.position)
        let radius = GizmoLayout.ringRadius * s

        // The Y ring lies in the XZ plane; aim straight down at its +X point.
        let aim = Ray(origin: Vec3(radius, 30, 0), direction: Vec3(0, -1, 0))
        let handle = Gizmo.hitTest(ray: aim, mode: .rotate, pivot: .zero, basis: matrix_identity_float3x3, scale: s)
        check("Y ring is hit", handle == .rotateAxis(1), "got \(String(describing: handle))")

        guard let handle, let drag = Gizmo.beginDrag(handle: handle, ray: aim, model: model, camera: camera) else {
            check("begin rotate drag", false); return
        }
        check("begin rotate drag", true)

        // Sweep a quarter turn round the ring.
        let quarter = Ray(origin: Vec3(0, 30, radius), direction: Vec3(0, -1, 0))
        Gizmo.updateDrag(drag, ray: quarter, model: model)
        let q = model.part(id: id)!.orientation
        let rotatedX = q.act(Vec3(1, 0, 0))
        check("a quarter turn about Y maps +X somewhere on the XZ plane", near(rotatedX.y, 0, 0.01))
        check("a quarter turn about Y is 90 degrees",
              near(abs(model.part(id: id)!.rotationDegrees.y), 90, 0.5),
              "\(model.part(id: id)!.rotationDegrees)")

        // Rotation snapping.
        model.snapEnabled = true
        model.rotateSnap = 45
        let odd = Ray(origin: Vec3(radius * cos(1.1), 30, radius * sin(1.1)), direction: Vec3(0, -1, 0))
        Gizmo.updateDrag(drag, ray: odd, model: model)
        let snapped = abs(model.part(id: id)!.rotationDegrees.y)
        check("rotation snaps to 45 degree steps", near(snapped.truncatingRemainder(dividingBy: 45), 0, 0.2)
              || near(snapped.truncatingRemainder(dividingBy: 45), 45, 0.2), "\(snapped)")
    }

    private static func testUndoRedo() {
        section("Undo / redo")
        let model = SceneModel()
        model.parts = []
        let id = model.addPart(shape: .block, at: Vec3(0, 0, 0))
        check("insert is undoable", model.canUndo)

        model.commit("move") { model.update(id: id) { $0.position = Vec3(9, 0, 0) } }
        check("part moved", near(model.part(id: id)!.position.x, 9))

        model.undo()
        check("undo restores position", near(model.part(id: id)!.position.x, 0))
        model.redo()
        check("redo reapplies position", near(model.part(id: id)!.position.x, 9))

        // A whole drag collapses into one undo step.
        model.beginStroke()
        for step in 1...10 {
            model.update(id: id) { $0.position = Vec3(9 + Float(step), 0, 0) }
        }
        model.endStroke()
        check("stroke moved the part", near(model.part(id: id)!.position.x, 19))
        model.undo()
        check("one undo rewinds the whole stroke", near(model.part(id: id)!.position.x, 9),
              "\(model.part(id: id)!.position.x)")

        model.selection = [id]
        model.deleteSelected()
        check("delete removes the part", model.parts.isEmpty)
        model.undo()
        check("undo restores the deleted part", model.parts.count == 1)
    }

    private static func testSerialization() {
        section("Scene files")
        let model = SceneModel()
        model.loadStarterScene()
        model.update(id: model.parts[0].id) { $0.rotationDegrees = Vec3(12, 34, 56) }
        do {
            let data = try model.encodeScene()
            let restored = SceneModel()
            try restored.loadScene(from: data)
            check("part count round-trips", restored.parts.count == model.parts.count)
            let a = model.parts[0], b = restored.parts[0]
            check("name round-trips", a.name == b.name)
            check("position round-trips", near(a.position, b.position))
            check("size round-trips", near(a.size, b.size))
            check("colour round-trips", near(a.color, b.color))
            check("orientation round-trips", near(a.rotationDegrees, b.rotationDegrees, 0.01),
                  "\(a.rotationDegrees) vs \(b.rotationDegrees)")
            check("material round-trips", a.material == b.material)
        } catch {
            check("encode/decode scene", false, "\(error)")
        }
    }
}
