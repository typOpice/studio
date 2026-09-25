import Foundation
import simd

/// Verification for saving creations: scene files, dirty tracking and model export.
enum DocumentSelfTest {

    static func run(check: Checker) {
        testSceneRoundTrip(check)
        testDirtyTracking(check)
        testSaveAndOpen(check)
        testModelExport(check)
        testDuplicateIDs(check)
    }

    /// A file where two things share an id — edited by hand, say — must open, not bring
    /// the physics down the first time Play is pressed.
    private static func testDuplicateIDs(_ check: Checker) {
        print("\nDocuments: repairing a damaged file")
        var first = Part()
        first.name = "First"
        first.anchored = false
        var second = first
        second.name = "Second"
        second.position = Vec3(0, 10, 0)
        var script = ScriptObject.blank(language: .luau)
        script.parentID = first.id
        let twin = script
        let damaged = SceneState(parts: [first, second], scripts: [script, twin], defaultGui: DefaultHud.version)

        let model = SceneModel()
        do {
            try model.loadScene(from: JSONEncoder().encode(damaged))
            check("a file with two parts on one id opens with both",
                  model.parts.map(\.name) == ["First", "Second"] && Set(model.parts.map(\.id)).count == 2)
            check("…the first keeps its id, and what pointed at it still does",
                  model.parts[0].id == first.id && model.scripts.allSatisfy { $0.parentID == first.id })
            check("…and so do scripts", Set(model.scripts.map(\.id)).count == 2)
            let world = PhysicsWorld()
            world.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            check("…and the physics can run it, with a body for each",
                  model.parts.allSatisfy { world.body(for: $0.id) != nil })
        } catch {
            check("a damaged file opens", false, "\(error)")
        }
    }

    private static func near(_ a: Vec3, _ b: Vec3, _ tol: Float = 1e-3) -> Bool { length(a - b) <= tol }

    private static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-selftest-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    private static func testSceneRoundTrip(_ check: Checker) {
        print("\nDocuments: scene files")
        let model = SceneModel()
        model.loadStarterScene()
        model.addScript(parentID: model.parts[0].id)
        model.updateScript(id: model.scripts.last!.id) { $0.source = "// hello\nvar x = 1" }

        do {
            let data = try model.encodeScene()
            let restored = SceneModel()
            try restored.loadScene(from: data)

            check("parts round-trip", restored.parts.count == model.parts.count,
                  "\(restored.parts.count) vs \(model.parts.count)")
            check("scripts round-trip", restored.scripts.count == model.scripts.count,
                  "\(restored.scripts.count) vs \(model.scripts.count)")
            check("script source survives",
                  restored.scripts.contains { $0.source.contains("// hello") })
            check("script attachment survives",
                  restored.scripts.contains { $0.parentID == model.parts[0].id })
            check("script enabled flag survives",
                  restored.scripts.allSatisfy { $0.enabled })
        } catch {
            check("encode and decode a scene", false, "\(error)")
        }

        // Scripts saved before Luau arrived were all Wren and carry no language field.
        let wrenEra = """
        { "parts": [], "scripts": [ { "name": "Old", "source": "System.print(1)" } ] }
        """
        let upgraded = SceneModel()
        try? upgraded.loadScene(from: Data(wrenEra.utf8))
        check("a script with no language field loads as Wren",
              upgraded.scripts.first?.language == .wren, "\(String(describing: upgraded.scripts.first?.language))")
        check("a brand-new script is Luau", ScriptObject().language == .luau)
        check("each language has its own template",
              ScriptObject.blank(language: .wren).source.contains("import \"studio\"")
                  && ScriptObject.blank(language: .luau).source.contains("game:GetService"))
        if let data = try? upgraded.encodeScene() {
            let again = SceneModel()
            try? again.loadScene(from: data)
            check("the language is saved explicitly from then on",
                  again.scripts.first?.language == .wren
                      && String(decoding: data, as: UTF8.self).contains("\"language\""))
        }

        // A file written before scripts existed still opens.
        let legacy = """
        { "parts": [ { "name": "Old", "size": [2,2,2], "position": [0,1,0] } ] }
        """
        let older = SceneModel()
        do {
            try older.loadScene(from: Data(legacy.utf8))
            check("a scene file without scripts still opens", older.parts.count == 1)
            check("…and, being from before the default HUD, gets it — its only scripts",
                  older.guiChildren(of: nil).map(\.name) == [DefaultHud.screenName]
                  && older.scripts.map(\.name) == [DefaultHud.hudScriptName, DefaultHud.keysScriptName]
                  && older.scripts.allSatisfy { $0.host == .starterGui })
        } catch {
            check("a scene file without scripts still opens", false, "\(error)")
        }
    }

    private static func testDirtyTracking(_ check: Checker) {
        print("\nDocuments: unsaved changes")
        let model = SceneModel()
        model.loadStarterScene()
        let document = SceneDocument(model: model)
        check("a freshly opened scene is clean", !document.isDirty)
        check("an unsaved scene is called Untitled", document.displayName == "Untitled",
              document.displayName)

        model.addPart(shape: .block, at: Vec3(0, 1, 0))
        check("adding a part marks it dirty", document.isDirty)

        let url = temporaryURL(SceneDocument.sceneExtension)
        do {
            try document.save(to: url)
            check("saving clears the dirty flag", !document.isDirty)
            check("the document takes the file's name", document.displayName.hasPrefix("studio-selftest"),
                  document.displayName)
            check("the title shows no edited marker", !document.windowTitle.contains("edited"),
                  document.windowTitle)

            model.updateSelected { $0.position.y += 1 }
            model.commit("moved") {}
            model.beginStroke()
            model.updateSelected { $0.position.y += 1 }
            model.endStroke()
            check("editing after a save marks it dirty again", document.isDirty)
            check("the title shows the edited marker", document.windowTitle.contains("edited"),
                  document.windowTitle)

            try? FileManager.default.removeItem(at: url)
        } catch {
            check("save the scene", false, "\(error)")
        }
    }

    private static func testSaveAndOpen(_ check: Checker) {
        print("\nDocuments: save and reopen")
        let model = SceneModel()
        model.loadStarterScene()
        var tweaked = model.parts[1]
        tweaked.name = "Landmark"
        tweaked.position = Vec3(12, 3, -4)
        tweaked.color = Vec3(0.2, 0.4, 0.8)
        model.parts[1] = tweaked

        let document = SceneDocument(model: model)
        let url = temporaryURL(SceneDocument.sceneExtension)

        do {
            try document.save(to: url)
            check("the file exists on disk", FileManager.default.fileExists(atPath: url.path))

            let reopened = SceneModel()
            let reopenedDocument = SceneDocument(model: reopened)
            try reopenedDocument.open(url)

            check("reopening restores every part", reopened.parts.count == model.parts.count,
                  "\(reopened.parts.count)")
            let landmark = reopened.parts.first { $0.name == "Landmark" }
            check("a renamed part survives", landmark != nil)
            check("its position survives", landmark.map { near($0.position, Vec3(12, 3, -4)) } ?? false,
                  "\(String(describing: landmark?.position))")
            check("its colour survives", landmark.map { near($0.color, Vec3(0.2, 0.4, 0.8)) } ?? false)
            check("the reopened document is clean", !reopenedDocument.isDirty)
            check("undo history does not survive a reopen", !reopened.canUndo)

            // The scripts in the reopened scene still run.
            let console = ScriptConsole()
            let runtime = ScriptRuntime(model: reopened, console: console)
            runtime.start()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            check("scripts from the saved file run",
                  !console.lines.contains { $0.kind == .error },
                  "\(console.lines.filter { $0.kind == .error }.map(\.text))")

            try? FileManager.default.removeItem(at: url)
        } catch {
            check("save and reopen", false, "\(error)")
        }
    }

    private static func testModelExport(_ check: Checker) {
        print("\nDocuments: models")
        let model = SceneModel()
        model.parts = []
        model.scripts = []

        var left = Part()
        left.name = "Left"
        left.position = Vec3(-2, 1, 0)
        var right = Part()
        right.name = "Right"
        right.position = Vec3(2, 1, 0)
        var bystander = Part()
        bystander.name = "Bystander"
        bystander.position = Vec3(40, 1, 0)
        model.parts = [left, right, bystander]

        var script = ScriptObject()
        script.name = "Mover"
        script.source = "// attached to Left"
        script.parentID = left.id
        model.scripts = [script]

        model.selection = [left.id, right.id]
        let document = SceneDocument(model: model)

        do {
            guard let data = try document.modelData(name: "Pair") else {
                check("export the selection", false, "no data")
                return
            }
            check("exports only the selected parts",
                  (try? JSONDecoder().decode(ModelFile.self, from: data))?.state.parts.count == 2)
            check("exports scripts inside the selection",
                  (try? JSONDecoder().decode(ModelFile.self, from: data))?.state.scripts.count == 1)

            // Insert into a different scene, 20 studs away from where it was built.
            let target = SceneModel()
            target.parts = []
            target.scripts = []
            var existing = Part()
            existing.name = "Left"          // deliberate name clash
            target.parts = [existing]

            let targetDocument = SceneDocument(model: target)
            let inserted = try targetDocument.insertModel(from: data, at: Vec3(0, 1, 20))

            check("inserts the right number of parts", inserted == 2, "\(inserted)")
            check("the scene now holds the original plus the model", target.parts.count == 3,
                  "\(target.parts.count)")

            let names = target.parts.map(\.name)
            check("the clashing name was made unique", Set(names).count == names.count, "\(names)")

            // Relative layout is preserved, recentred on the insertion point.
            let placed = target.parts.filter { $0.name != "Left" || $0.id != existing.id }
            let xs = placed.map(\.position.x).sorted()
            check("relative layout is preserved", xs.count >= 2 && abs(xs.last! - xs.first!) == 4,
                  "\(xs)")
            check("the model landed at the insertion point",
                  placed.allSatisfy { abs($0.position.z - 20) < 0.001 },
                  "\(placed.map(\.position.z))")

            check("the attached script came with it", target.scripts.count == 1)
            let movedScript = target.scripts.first
            check("the script kept its source",
                  movedScript?.source.contains("attached to Left") ?? false)
            check("the script was re-parented to the inserted copy",
                  movedScript?.parentID != nil && movedScript?.parentID != left.id,
                  "\(String(describing: movedScript?.parentID))")
            check("the re-parented script points at a real part",
                  movedScript?.parentID.flatMap { target.part(id: $0) } != nil)
            check("inserting can be undone", target.canUndo)

            // Nothing selected means nothing to export.
            model.selection = []
            check("exporting an empty selection produces nothing",
                  (try? document.modelData(name: "Empty")) == nil)

            _ = existing
        } catch {
            check("export and insert a model", false, "\(error)")
        }
    }
}
