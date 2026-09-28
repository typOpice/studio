import Foundation
import simd

/// The Toolbox: every model going in in front of Studio's camera, on what's there,
/// selected, one step to undo; each one's picture; the boat floating and driving on a
/// pond; the door opening and shutting when clicked; the windmill's sails turning; the
/// campfire's fire, smoke and light; the lamp's light, the tree, the rig's Humanoid; and a
/// joined player opening the host's door.
enum ToolboxSelfTest {
    static func run(check: Checker) {
        testInserting(check)
        testPictures(check)
        testBoat(check)
        testDoor(check)
        testWindmill(check)
        testStill(check)
        testTogether(check)
    }

    private static let frame = ForceSelfTest.frame

    private static func steps(_ session: PlayController, _ count: Int) {
        for _ in 0..<count { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    private static func inside(_ model: SceneModel, _ group: String) -> [Part] {
        guard let id = model.groups.first(where: { $0.name == group })?.id else { return [] }
        return model.parts.filter { model.isDescendant($0.id, of: id) }
    }

    // MARK: - Inserting

    private static func testInserting(_ check: Checker) {
        print("\nToolbox: inserting")
        let model = SceneModel()
        let session = EditorSession(model: model)
        let camera = session.viewport.camera
        var ahead = camera.target + camera.forward * 10
        // The starter place's Platform is under it.
        let platform = model.parts.first { $0.name == "Platform" }
        ahead.y = platform.map { $0.position.y + $0.size.y / 2 } ?? 0
        func lowest(_ part: Part) -> Float {
            let m = float3x3(part.orientation)
            let reach = abs(m[0].y) * part.size.x + abs(m[1].y) * part.size.y + abs(m[2].y) * part.size.z
            return part.position.y - reach / 2
        }
        var landed: [String] = []
        for item in ToolboxModel.allCases {
            let before = (parts: model.parts.count, groups: model.groups.count)
            session.viewport.insert(item)
            guard let group = model.groups.last, model.groups.count == before.groups + 1 else {
                landed.append("\(item.rawValue): no Model")
                continue
            }
            let parts = model.parts.filter { model.isDescendant($0.id, of: group.id) }
            let bottom = parts.map(lowest).min() ?? -99
            let middle = parts.reduce(Vec3.zero) { $0 + $1.position } / Float(max(parts.count, 1))
            // Standing on the Platform, in front of the camera.
            if parts.isEmpty || model.parts.count <= before.parts || !model.selection.contains(group.id)
                || abs(bottom - ahead.y) > 0.3 || simd_distance(SIMD2(middle.x, middle.z), SIMD2(ahead.x, ahead.z)) > 8 {
                landed.append("\(item.rawValue): \(parts.count) parts, bottom \(bottom), at \(middle), ahead \(ahead)")
            }
            model.undo()
            if model.parts.count != before.parts || model.groups.count != before.groups {
                landed.append("\(item.rawValue): not undone")
            }
        }
        check("each Toolbox model goes in as a Model in front of the camera, on the ground, selected, one step to undo",
              landed.isEmpty, "\(landed)")
        check("…with its name and what it is", ToolboxModel.allCases.allSatisfy { !$0.summary.isEmpty && !$0.symbolName.isEmpty }
              && ToolboxModel.allCases.count == 8)
        let scripted = ToolboxModel.allCases.filter { $0.file?.state.scripts.isEmpty == false }.map(\.rawValue)
        check("the car, boat, door and windmill bring their scripts", scripted == ["Car", "Boat", "Door", "Windmill"], "\(scripted)")
    }

    // MARK: - Pictures

    private static func testPictures(_ check: Checker) {
        print("\nToolbox: pictures")
        guard let painter = AvatarSnapshot.ToolboxPicture(width: 120, height: 80) else {
            print("  (no Metal device; skipped)")
            return
        }
        var plain: [String] = []
        for item in ToolboxModel.allCases {
            guard let image = painter.picture(of: item, width: 120, height: 80), image.width == 120, image.height == 80,
                  let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
                plain.append(item.rawValue)
                continue
            }
            // Something drawn: the middle isn't all one colour.
            var seen = Set<UInt32>()
            for y in stride(from: 20, to: 60, by: 4) {
                for x in stride(from: 30, to: 90, by: 4) {
                    let at = y * image.bytesPerRow + x * 4
                    seen.insert(UInt32(bytes[at]) << 16 | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]))
                }
            }
            if seen.count < 8 { plain.append(item.rawValue) }
        }
        check("each model has a picture for its card, drawn by one renderer", plain.isEmpty, "\(plain)")
    }

    // MARK: - The boat

    private static func testBoat(_ check: Checker) {
        print("\nToolbox: the boat")
        let model = ForceSelfTest.scene([ForceSelfTest.block("Ground", Vec3(0, -0.5, 0), size: Vec3(400, 1, 400), anchored: true)])
        var pond = ForceSelfTest.block("Pond", Vec3(0, 4, 0), size: Vec3(200, 8, 200), anchored: true)
        pond.material = .water
        model.parts.append(pond)
        model.insert(.boat, at: Vec3(0, 9, 0))
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local seat = workspace:WaitForChild("Boat"):WaitForChild("VehicleSeat")
        task.wait(3)
        seat.ThrottleFloat = 1
        task.wait(3)
        seat.SteerFloat = 1
        """
        model.scripts.append(script)
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        steps(session, 60 * 3)
        func hull() -> Part { model.parts.first { $0.name == "Hull" }! }
        let afloat = hull()
        check("it floats on the pond, riding high", afloat.position.y > 7.3 && afloat.position.y < 8.6
              && abs(afloat.orientation.act(Vec3(0, 1, 0)).y) > 0.98, "\(afloat.position)")
        steps(session, 60 * 3)
        let driven = hull()
        check("…Throttle drives it forward", afloat.position.z - driven.position.z > 20
              && abs(driven.position.y - afloat.position.y) < 1, "\(driven.position)")
        let facing = driven.orientation.act(Vec3(0, 0, -1))
        steps(session, 60 * 2)
        let turned = hull().orientation.act(Vec3(0, 0, -1))
        // Right, about TurnSpeed (1) radians a second.
        let angle = atan2(-simd_cross(facing, turned).y, simd_dot(facing, turned))
        check("…and Steer turns it right, about TurnSpeed radians a second", angle > 1.2 && angle < 2.3,
              "\(angle)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - The door

    private static func testDoor(_ check: Checker) {
        print("\nToolbox: the door")
        let model = ForceSelfTest.scene([ForceSelfTest.block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true)])
        model.insert(.door, at: Vec3(0, 0, -8))
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        steps(session, 60)
        guard let door = model.parts.first(where: { $0.name == "Door" })?.id else {
            check("the door is there", false)
            return
        }
        func panel() -> Part { model.part(id: door)! }
        let shut = panel()
        check("it stands shut in its frame", simd_distance(shut.position, Vec3(0, 3.6, -8)) < 0.1, "\(shut.position)")
        session.queueClick(door, by: session.playerID, "MouseClick")
        steps(session, 90)
        let open = panel()
        let swung = acos(min(abs(simd_dot(open.orientation.act(Vec3(1, 0, 0)), Vec3(1, 0, 0))), 1)) * 180 / .pi
        check("clicked, it swings open on its hinge", swung > 75 && simd_distance(open.position, Vec3(-2, 3.6, -8)) < 2.3
              && simd_distance(open.position, Vec3(-2, 3.6, -8)) > 1.7, "\(swung) \(open.position)")
        session.queueClick(door, by: session.playerID, "MouseClick")
        steps(session, 90)
        check("…and clicked again, shuts", simd_distance(panel().position, shut.position) < 0.15, "\(panel().position)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - The windmill

    private static func testWindmill(_ check: Checker) {
        print("\nToolbox: the windmill")
        let model = ForceSelfTest.scene([ForceSelfTest.block("Ground", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true)])
        model.insert(.windmill, at: .zero)
        let session = PlayController(model: model, console: ScriptConsole(), withPlayer: false)
        session.start()
        let turn = model.constraints.first { $0.name == "Turn" }!.id
        steps(session, 60 * 3)
        let angle = session.physics.jointValue(turn) ?? 0
        let hub = model.parts.first { $0.name == "Hub" }!
        check("its sails keep turning (about 1.2 radians a second)", angle > 3 && angle < 4.2
              && simd_distance(hub.position, Vec3(0, 11, -2.6)) < 0.2, "\(angle) \(hub.position)")
        session.stop()
    }

    // MARK: - Standing still

    private static func testStill(_ check: Checker) {
        print("\nToolbox: the campfire, lamp, tree and rig")
        let model = ForceSelfTest.scene([])
        model.insert(.campfire, at: .zero)
        let flames = model.parts.first { $0.name == "Flames" }
        check("the campfire burns: fire and smoke, and a light that casts shadows",
              flames?.emitters.map(\.name) == ["Fire", "Smoke"] && flames?.light?.shadows == true
              && inside(model, "Campfire").allSatisfy(\.anchored))
        model.insert(.streetLamp, at: Vec3(10, 0, 0))
        check("the street lamp has its light, high up", inside(model, "Street Lamp").contains { $0.light != nil && $0.position.y > 10 })
        model.insert(.tree, at: Vec3(-10, 0, 0))
        check("the tree stands still", inside(model, "Tree").count == 4 && inside(model, "Tree").allSatisfy(\.anchored))
        model.insert(.rig, at: Vec3(0, 0, 10))
        let rig = model.groups.last { $0.name.hasPrefix("Rig") }
        check("the rig has its Humanoid", rig.map { rig in
            model.dataObjects.contains { $0.className == .humanoid && $0.parent == .node(rig.id) } } == true)
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nToolbox: a joined player opens the host's door")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            var base = Part()
            base.name = "Baseplate"
            base.position = Vec3(0, -0.5, 0)
            base.size = Vec3(200, 1, 200)
            model.parts = [base]
            model.insert(.door, at: Vec3(0, 0, -10))
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1)
        guard let door = joining.model.parts.first(where: { $0.name == "Door" })?.id else {
            check("the joined player sees the door", false)
            return
        }
        // What clicking it does in a joined player's game: the host is asked.
        sam.sendAction?("click.part", [.string(door.uuidString)])
        LANSelfTest.run([hosting, joining], seconds: 2)
        let onHost = hosting.model.part(id: door)?.orientation ?? Pose.identity.orientation
        let onSam = joining.model.part(id: door)?.orientation ?? Pose.identity.orientation
        let swung = acos(min(abs(simd_dot(onSam.act(Vec3(1, 0, 0)), Vec3(1, 0, 0))), 1)) * 180 / .pi
        check("the joined player's click opens the host's door, and they see it open",
              swung > 75 && abs(simd_dot(onHost.vector, onSam.vector)) > 0.99, "\(swung)")
        let errors = (host.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
