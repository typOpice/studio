import Foundation
import simd

/// Verification for the scene tree: Models and Folders, reparenting, grouping,
/// deleting and duplicating subtrees, pivots, saving — and, in Luau, CFrame and the
/// Instance hierarchy.
enum HierarchySelfTest {

    static func run(check: Checker) {
        testTree(check)
        testEditing(check)
        testPivots(check)
        testSaving(check)
        testCFrame(check)
        testLuauTree(check)
    }

    private static func testCFrame(_ check: Checker) {
        print("\nHierarchy: CFrame")
        let fuzzy = "local function near(a, b) return math.abs(a - b) < 1e-4 end\n"
            + "local function vnear(a, b) return (a - b).Magnitude < 1e-4 end\n"
        ScriptSelfTest.assertAll(check, "construction and components", preamble: fuzzy, [
            "CFrame.new() == CFrame.identity",
            "CFrame.new(1, 2, 3).Position == Vector3.new(1, 2, 3)",
            "select('#', CFrame.new():GetComponents()) == 12",
            "typeof(CFrame.new()) == 'CFrame'",
            "CFrame.new(Vector3.new(4, 5, 6)).Y == 5",
            "tostring(CFrame.new(1, 2, 3)) == '1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1'",
        ])
        ScriptSelfTest.assertAll(check, "vectors and directions", preamble: fuzzy, [
            "vnear(CFrame.new().LookVector, Vector3.new(0, 0, -1))",
            "vnear(CFrame.Angles(0, math.rad(90), 0).LookVector, Vector3.new(-1, 0, 0))",
            "vnear(CFrame.lookAt(Vector3.zero, Vector3.new(10, 0, 0)).LookVector, Vector3.new(1, 0, 0))",
            "vnear(CFrame.new(Vector3.new(0, 5, 0), Vector3.new(0, 5, -9)).LookVector, Vector3.new(0, 0, -1))",
            "vnear(CFrame.lookAt(Vector3.zero, Vector3.new(0, 10, 0)).LookVector, Vector3.new(0, 1, 0))",
        ])
        ScriptSelfTest.assertAll(check, "composition and inverses", preamble: fuzzy + """
            local a = CFrame.new(1, 2, 3) * CFrame.Angles(0.3, 1.1, -0.4)
            local b = CFrame.new(-4, 0, 2) * CFrame.Angles(-1, 0.2, 0.5)
            local p = Vector3.new(3, -1, 7)
            """, [
            "vnear(a * (a:Inverse() * p), p)",
            "a:ToObjectSpace(a * b):FuzzyEq(b)",
            "a:ToWorldSpace(b) == a * b",
            "vnear(a:PointToObjectSpace(a:PointToWorldSpace(p)), p)",
            "vnear(a:VectorToWorldSpace(Vector3.new(0, 0, -1)), a.LookVector)",
            "vnear((a + Vector3.new(0, 10, 0)).Position, a.Position + Vector3.new(0, 10, 0))",
            "vnear((CFrame.new(5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)) * Vector3.new(0, 0, -2), Vector3.new(3, 0, 0))",
        ])
        ScriptSelfTest.assertAll(check, "angles round-trip", preamble: fuzzy, [
            "(function() local x, y, z = CFrame.Angles(0.2, -0.7, 1.1):ToEulerAnglesXYZ() return near(x, 0.2) and near(y, -0.7) and near(z, 1.1) end)()",
            "(function() local x, y, z = CFrame.fromOrientation(0.3, 0.9, -0.2):ToOrientation() return near(x, 0.3) and near(y, 0.9) and near(z, -0.2) end)()",
            "CFrame.fromEulerAnglesYXZ(0.3, 0.9, -0.2):FuzzyEq(CFrame.fromOrientation(0.3, 0.9, -0.2))",
            "(function() local axis, angle = CFrame.fromAxisAngle(Vector3.new(0, 2, 0), 0.8):ToAxisAngle() return vnear(axis, Vector3.yAxis) and near(angle, 0.8) end)()",
        ])
        ScriptSelfTest.assertAll(check, "lerp", preamble: fuzzy + """
            local a = CFrame.new(0, 0, 0)
            local b = CFrame.new(10, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
            local mid = a:Lerp(b, 0.5)
            """, [
            "vnear(mid.Position, Vector3.new(5, 0, 0))",
            "mid:FuzzyEq(CFrame.new(5, 0, 0) * CFrame.Angles(0, math.pi / 4, 0))",
            "a:Lerp(b, 1):FuzzyEq(b)",
        ])
        let orientation = ScriptSelfTest.runScript("""
            local brick = workspace.Brick
            brick.CFrame = CFrame.new(1, 2, 3) * CFrame.fromOrientation(math.rad(20), math.rad(35), math.rad(-10))
            local o = brick.Orientation
            print(math.round(o.X), math.round(o.Y), math.round(o.Z), brick.Position == Vector3.new(1, 2, 3))
            brick.Orientation = Vector3.new(0, 90, 0)
            print((brick.CFrame.LookVector - Vector3.new(-1, 0, 0)).Magnitude < 1e-4)
            print(pcall(function() brick.CFrame = Vector3.new() end))
            """)
        check("a part's CFrame and Orientation agree",
              orientation.output.prefix(2) == ["20 35 -10 true", "true"], "\(orientation.output) \(orientation.errors)")
        check("CFrame is type-checked on a part",
              orientation.output.count > 2 && orientation.output[2].contains("CFrame expected"), "\(orientation.output)")
    }

    private static func testLuauTree(_ check: Checker) {
        print("\nHierarchy: Luau")
        let (model, car, _, _, _, cushion, rock) = garage()
        ScriptSelfTest.add(model, """
            local car = workspace.Car
            print(car.ClassName, car:IsA("Model"), car.PrimaryPart.Name, car.Seat.ClassName, car.Seat.Cushion.Name)
            print(#workspace:GetChildren(), #workspace:GetDescendants(), #car:GetChildren(),
                workspace:FindFirstChild("Cushion"), workspace:FindFirstChild("Cushion", true).Name)
            print(car.Seat.Cushion:GetFullName(), car.Seat.Cushion:IsDescendantOf(car),
                car:IsAncestorOf(car.Body), car.Seat.Cushion:FindFirstAncestorOfClass("Model") == car)

            car:PivotTo(car:GetPivot() * CFrame.new(0, 0, -10))
            print(car.Body.Position.Z, car.Wheel.Position.Z)
            car:MoveTo(Vector3.new(50, 2, 0))
            print(car:GetPivot().Position.X)

            local rock = workspace.Rock
            rock.Parent = car.Seat
            print(rock.Parent.Name, workspace:FindFirstChild("Rock"))
            print(pcall(function() car.Parent = car.Seat end))
            print(pcall(function() rock.Parent = 5 end))

            local folder = Instance.new("Folder", workspace)
            folder.Name = "Junk"
            local box = Instance.new("Part")
            box.Parent = folder
            local copy = car:Clone()
            print(folder.ClassName, box.Parent == folder, copy.Name, #copy:GetDescendants(), copy ~= car)
            folder:Destroy()
            print(workspace:FindFirstChild("Junk"), pcall(function() return box.Name end))
            car.PrimaryPart = car.Wheel
            print(car.PrimaryPart.Name, pcall(function() car.PrimaryPart = Instance.new("Part") end))
            print(script.Parent == nil)
            """)
        let result = ScriptSelfTest.execute(model)
        let out = result.output
        func line(_ i: Int) -> String { i < out.count ? out[i] : "(missing)" }
        check("Models, Folders and PrimaryPart read like Roblox's",
              line(0) == "Model true Body Folder Cushion", "\(out) \(result.errors)")
        check("children and descendants", line(1) == "2 6 3 nil Cushion", line(1))
        check("names and ancestry", line(2) == "Workspace.Car.Seat.Cushion true true true", line(2))
        check("PivotTo moves the whole Model", line(3) == "-10 -7", line(3))
        check("MoveTo puts its pivot there", line(4) == "50", line(4))
        check("Parent moves things into Models and Folders",
              line(5) == "Seat nil" && model.parentID(of: rock) != nil, line(5))
        check("…but not into themselves", line(6).hasPrefix("false") && line(6).contains("inside itself"), line(6))
        check("…and only into instances", line(7).hasPrefix("false") && line(7).contains("got number"), line(7))
        check("Instance.new makes Folders, Clone copies a Model whole",
              line(8) == "Folder true Car 5 true", line(8))
        check("Destroy takes everything inside with it",
              line(9).hasPrefix("nil false"), line(9))
        check("PrimaryPart must be inside the Model",
              line(10).hasPrefix("Wheel false") && line(10).contains("inside the Model"), line(10))
        check("a loose script's Parent is nil", line(11) == "true", line(11))
        check("the scene changed to match", model.isDescendant(cushion, of: car) && model.groups.count == 4)
    }

    private static func near(_ a: Vec3, _ b: Vec3, _ tolerance: Float = 1e-3) -> Bool {
        simd_distance(a, b) <= tolerance
    }

    /// Workspace ─ Car (Model) ─ Body, Wheel, Seat (Folder) ─ Cushion; and a loose Rock.
    static func garage() -> (SceneModel, car: UUID, seat: UUID, body: UUID, wheel: UUID, cushion: UUID, rock: UUID) {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.groups = []
        var car = SceneGroup(name: "Car", kind: .model)
        var seat = SceneGroup(name: "Seat", kind: .folder)
        seat.parentID = car.id
        var body = Part()
        body.name = "Body"
        body.position = Vec3(0, 2, 0)
        body.size = Vec3(4, 1, 8)
        body.parentID = car.id
        var wheel = Part()
        wheel.name = "Wheel"
        wheel.shape = .cylinder
        wheel.position = Vec3(2, 1, 3)
        wheel.size = Vec3(1, 2, 2)
        wheel.parentID = car.id
        var cushion = Part()
        cushion.name = "Cushion"
        cushion.position = Vec3(0, 3, 0)
        cushion.size = Vec3(2, 0.5, 2)
        cushion.parentID = seat.id
        var rock = Part()
        rock.name = "Rock"
        rock.position = Vec3(20, 1, 0)
        car.primaryPartID = body.id
        model.groups = [car, seat]
        model.parts = [body, wheel, cushion, rock]
        return (model, car.id, seat.id, body.id, wheel.id, cushion.id, rock.id)
    }

    private static func testTree(_ check: Checker) {
        print("\nHierarchy: the tree")
        let (model, car, seat, body, wheel, cushion, rock) = garage()
        check("the Workspace holds the car and the rock",
              model.children(of: nil) == [.group(car), .part(rock)])
        check("children come groups first", model.children(of: car) == [.group(seat), .part(body), .part(wheel)])
        check("descendants go all the way down",
              Set(model.descendants(of: car).map(\.id)) == [seat, body, wheel, cushion])
        check("a Model's parts include those in its Folders",
              Set(model.partIDs(inSubtree: car)) == [body, wheel, cushion])
        check("ancestry is known", model.isDescendant(cushion, of: car) && !model.isDescendant(rock, of: car))
        check("a click on a part inside selects the outermost Model", model.outermostModel(containing: cushion) == car)
        check("…but a loose part is itself", model.outermostModel(containing: rock) == nil)
        check("children are found by name", model.findChild(named: "Wheel", in: car) == .part(wheel)
              && model.findChild(named: "Cushion", in: car) == nil
              && model.findChild(named: "Cushion", in: car, recursive: true) == .part(cushion))
        check("nothing moves into itself", !model.canReparent(car, to: cushion) && !model.canReparent(car, to: car))
        check("parts can hold things too", model.canReparent(rock, to: body))
    }

    private static func testEditing(_ check: Checker) {
        let (model, car, seat, body, wheel, cushion, rock) = garage()

        model.selection = [car]
        check("selecting a Model selects its parts for the gizmo",
              Set(model.selectedParts.map(\.id)) == [body, wheel, cushion])
        model.selection = [seat]
        check("…a Folder only organises", model.selectedParts.isEmpty)

        model.selection = [rock, wheel]
        let group = model.groupSelection(kind: .model)
        check("grouping makes a Model around the selection",
              group != nil && model.parentID(of: rock) == group && model.parentID(of: wheel) == group
              && model.selection == [group!])
        check("…in the Workspace, since the pieces came from different places", model.parentID(of: group!) == nil)
        model.undo()
        check("grouping undoes", model.groups.count == 2 && model.parentID(of: wheel) == car)

        model.ungroup(seat)
        check("ungrouping lifts the children out", model.parentID(of: cushion) == car && model.group(id: seat) == nil)
        model.undo()

        var script = ScriptObject.blank(language: .luau)
        script.parentID = seat
        model.scripts = [script]
        model.selection = [car]
        model.duplicateSelected()
        let copy = model.selection.first!
        check("duplicating a Model copies everything inside",
              model.partIDs(inSubtree: copy).count == 3 && model.groups.count == 4 && copy != car)
        check("…including its scripts", model.scripts.count == 2
              && model.scripts.contains { $0.parentID.map { model.isDescendant($0, of: copy) } ?? false })
        check("…and its PrimaryPart points at its own copy",
              model.group(id: copy)?.primaryPartID.map { model.isDescendant($0, of: copy) } == true)
        check("…lifted clear of the original",
              (model.pivot(of: copy)?.position.y ?? 0) > (model.pivot(of: car)?.position.y ?? 0) + 1)

        model.selection = [copy]
        model.deleteSelected()
        check("deleting a Model deletes everything inside",
              model.groups.count == 2 && model.parts.count == 4 && model.scripts.count == 1)

        model.move(wheel, to: rock)
        check("things move in the Explorer", model.parentID(of: wheel) == rock)
        model.move(car, to: cushion)
        check("…but never into themselves", model.parentID(of: car) == nil)
    }

    private static func testPivots(_ check: Checker) {
        let (model, car, _, body, wheel, _, _) = garage()
        check("a Model's pivot is its PrimaryPart", model.pivot(of: car)?.position == Vec3(0, 2, 0))
        let turn = simd_quatf(angle: .pi / 2, axis: Vec3(0, 1, 0))
        model.movePivot(of: car, to: Pose(position: Vec3(10, 2, 0), orientation: turn))
        check("moving the pivot moves the body there", near(model.part(id: body)!.position, Vec3(10, 2, 0)))
        check("…and carries the rest round with it",
              near(model.part(id: wheel)!.position, Vec3(10, 1, 0) + turn.act(Vec3(2, 0, 3))),
              "\(model.part(id: wheel)!.position)")
        model.updateGroup(id: car) { $0.primaryPartID = nil }
        let box = model.boundingBox(of: model.partIDs(inSubtree: car))!
        check("without a PrimaryPart the pivot is the middle", near(model.pivot(of: car)!.position, box.center))
    }

    private static func testSaving(_ check: Checker) {
        let (model, car, seat, _, _, cushion, _) = garage()
        let data = try? JSONEncoder().encode(model.state)
        let back = data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("the tree is saved", back?.groups == model.groups && back?.parts == model.parts)
        let old = try? JSONDecoder().decode(SceneState.self, from: Data(#"{"parts":[{"name":"Old"}]}"#.utf8))
        check("older files open flat, in the Workspace", old?.groups.isEmpty == true && old?.parts.first?.parentID == nil)

        let document = SceneDocument(model: model)
        model.selection = [car]
        guard let file = try? document.modelData(name: "Car") else {
            check("a Model can be saved as a model file", false)
            return
        }
        let before = model.groups.count
        _ = try? document.insertModel(from: file, at: Vec3(40, 0, 0))
        let inserted = model.selection.first
        check("…and inserted again, whole", model.groups.count == before + 2
              && inserted.map { model.group(id: $0)?.name == "Car" && model.partIDs(inSubtree: $0).count == 3 } == true)
        check("…as a new copy", inserted != car && model.group(id: seat)?.parentID == car
              && model.parentID(of: cushion) == seat)
    }
}
