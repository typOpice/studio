import Foundation
import AppKit
import Combine
import SwiftUI

enum LuauAnalysisSelfTest {
    static func run(check: Checker) {
        print("\nLuau: genuine static analysis")
        func invalid(_ name: String, _ source: String, containing text: String? = nil) {
            let errors = LuauAnalyzer.analyze(source: source)
            check(name, errors.contains { text == nil || $0.message.contains(text!) }, "\(errors)")
        }
        func valid(_ name: String, _ source: String) {
            let errors = LuauAnalyzer.analyze(source: source)
            check(name, errors.isEmpty, "\(errors)")
        }
        invalid("annotation mismatch is diagnosed without running the script", "--!strict\nlocal count: number = 'wrong'", containing: "number")
        valid("well-typed annotations pass", "--!strict\nlocal count: number = 3")
        invalid("function arguments are checked", "--!strict\nlocal function twice(x: number): number return x * 2 end\ntwice('bad')")
        invalid("function returns are checked", "--!strict\nlocal function twice(x: number): number return 'bad' end")
        invalid("optional values must be refined", "--!strict\nlocal function name(x: string?): number return #x end")
        invalid("table field types are checked", "--!strict\nlocal value: {score: number} = {score = 'bad'}")
        invalid("generics preserve their result type", "--!strict\nlocal function identity<T>(x: T): T return x end\nlocal n: number = identity('text')")
        invalid("strict diagnoses unknown globals", "--!strict\nprint(missingGlobal)")
        valid("nonstrict remains the default", "local function plus(x) return x + 1 end\nplus('text')")
        invalid("strict infers parameter types", "--!strict\nlocal function plus(x) return x + 1 end\nplus('text')")
        invalid("nonstrict still checks explicit annotations", "--!nonstrict\nlocal n: number = 'text'")
        valid("nocheck disables type diagnostics", "--!nocheck\nlocal n: number = 'text'")
        invalid("nocheck still reports syntax errors", "--!nocheck\nlocal =")
        valid("standard library signatures and generic arrays work", "--!strict\nlocal values: {number} = {1, 2}\ntable.insert(values, math.clamp(5, 0, 3))\nlocal text: string = string.format('%d', values[1])")
        invalid("Studio property types catch mistakes", "--!strict\nlocal p = Instance.new('Part')\np.Anchored = 'yes'", containing: "boolean")
        invalid("Studio method argument types catch mistakes", "--!strict\nworkspace:Raycast('wrong', Vector3.new(0, -10, 0))")
        invalid("Studio constructor argument types catch mistakes", "--!strict\nlocal p = Vector3.new('wrong', 2, 3)")
        invalid("typed signal payloads reject a wrong callback parameter", "--!strict\nlocal p = Instance.new('Part')\np.Touched:Connect(function(other: string) print(other) end)")
        valid("new light, solid and viewport APIs retain their types", "--!strict\nlocal p: BasePart = Instance.new('Part')\nlocal made: UnionOperation = p:UnionAsync({Instance.new('MeshPart')}, Enum.CollisionFidelity.PreciseConvexDecomposition)\nmade.UsePartColor = true\nlocal lamp = Instance.new('SpotLight')\nlamp.Face = Enum.NormalId.Front\nlamp.Angle = 60\nlocal gui = Instance.new('SurfaceGui')\ngui.CanvasSize = Vector2.new(400, 200)\ngui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize\nlocal view = Instance.new('ViewportFrame')\nview.CurrentCamera = Instance.new('Camera')\nview.CurrentCamera = nil")
        invalid("new API property types reject invalid values", "--!strict\nlocal gui = Instance.new('SurfaceGui')\ngui.CanvasSize = UDim2.fromScale(1, 1)")
        invalid("Studio API values are not all any", "--!strict\nlocal p = Instance.new('Part')\nlocal wrong: string = p.Position")
        valid("Studio values and methods typecheck", "--!strict\nlocal p = Instance.new('Part')\np.Position = Vector3.new(1, 2, 3)\np.Anchored = true\np.Parent = workspace\nlocal ray = workspace:Raycast(p.Position, Vector3.new(0, -10, 0))\nif ray then local d: number = ray.Distance end\np.Touched:Connect(function(other) print(other) end)")
        invalid("typed required module return is checked", moduleSnapshot(use: "local n: number = require(script.Parent.Config).answer", module: "return {answer = 'text'}"))
        let goodModule = LuauAnalyzer.analyze(moduleSnapshot(use: "local n: number = require(script.Parent.Config).answer", module: "return {answer = 42}"))
        check("editing a required module invalidates its type", goodModule.isEmpty, "\(goodModule)")
        let unicode = "--!strict\nlocal face = '🐱'; local n: number = 'bad'"
        let errors = LuauAnalyzer.analyze(source: unicode)
        let range = errors.first?.range(in: unicode)
        check("UTF-8 diagnostic columns convert to UTF-16 after emoji", range.map { (unicode as NSString).substring(with: $0).contains("bad") } == true, "\(errors) \(String(describing: range))")
        invalid("excessive source size has a bounded diagnostic", String(repeating: " ", count: LuauAnalyzer.maximumSourceBytes + 1), containing: "budget")

        let started = Date()
        invalid("deeply nested syntax stops at the parser complexity limit", "--!strict\nlocal n = " + String(repeating: "(", count: 2000) + "1" + String(repeating: ")", count: 2000))
        check("nested syntax analysis completes within a bounded interval", Date().timeIntervalSince(started) < 3)
        testContextsAndModules(check)
        testDecorations(check)
        testService(check)
        testMountedEditor(check)
        testInFlightRevisions(check)
        testTwoPlayers(check)

        func invalid(_ name: String, _ snapshot: LuauAnalysisSnapshot) {
            let diagnostics = LuauAnalyzer.analyze(snapshot)
            check(name, !diagnostics.isEmpty, "\(diagnostics)")
        }
    }

    private static func testContextsAndModules(_ check: Checker) {
        let model = SceneModel()
        model.parts = []; model.groups = []; model.scripts = []; model.dataObjects = []
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterCharacter
        script.source = "--!strict\nlocal humanoid: Humanoid = script.Parent.Humanoid\nlocal model: Model = script.Parent"
        model.scripts = [script]
        let character = LuauAnalyzer.analyze(.init(source: script.source, scene: model.luauScene(editing: script.id)))
        check("character scripts see a Model and Humanoid as their host", character.isEmpty, "\(character)")
        let label = StarterGuiObject(kind: .textLabel)
        model.starterGui = [label]
        script.host = .starterGui; script.parentID = label.id
        script.source = "--!strict\nlocal text: string = script.Parent.Text"
        model.scripts = [script]
        let gui = LuauAnalyzer.analyze(.init(source: script.source, scene: model.luauScene(editing: script.id)))
        check("StarterGui scripts see the actual GUI host", gui.isEmpty, "\(gui)")
        var cutter = Part(); cutter.name = "Cutter"; cutter.negative = true
        var lamp = PointLight(); lamp.kind = .spot; lamp.name = "Lamp"
        cutter.lights = [lamp]; model.parts = [cutter]
        let objects = LuauAnalyzer.analyze(.init(source: "--!strict\nlocal cutter: NegateOperation = workspace.Cutter\nlocal lamp: SpotLight = workspace.Cutter.Lamp\nlamp.Angle = 30", scene: model.luauScene()))
        check("authored solid operations and identified lights retain their classes", objects.isEmpty, "\(objects)")
        var surface = StarterGuiObject(kind: .surfaceGui, name: "Sign"); surface.worldParent = cutter.id
        var preview = StarterGuiObject(kind: .viewportFrame, name: "Preview", parentID: surface.id)
        var previewPart = Part(); previewPart.name = "Brick"
        preview.viewportContent = ViewportContent(parts: [previewPart], cameras: [PreviewCamera()])
        model.starterGui = [surface, preview]
        script.parentID = preview.id
        script.source = "--!strict\nlocal sign: SurfaceGui = script.Parent.Parent\nlocal brick: Part = script.Parent.Brick\nlocal camera: Camera = script.Parent.Camera\nlocal same: ViewportFrame = workspace.Cutter.Sign.Preview"
        model.scripts = [script]
        let previewTypes = LuauAnalyzer.analyze(.init(source: script.source, scene: model.luauScene(editing: script.id)))
        check("world GUI ancestry and isolated preview contents have scene types", previewTypes.isEmpty, "\(previewTypes)")
        var cycle = LuauScene()
        let root = cycle.places["ReplicatedStorage"]!
        cycle.add(.init(name: "A", className: "ModuleScript", parent: root, source: "--!strict\nreturn require(script.Parent.B)"))
        cycle.add(.init(name: "B", className: "ModuleScript", parent: root, source: "--!strict\nreturn require(script.Parent.A)"))
        cycle.script = cycle.add(.init(name: "Main", className: "Script", parent: root))
        let cyclic = LuauAnalyzer.analyze(.init(source: "--!strict\nlocal a = require(script.Parent.A)", scene: cycle))
        check("cyclic modules produce diagnostics without recursing forever", !cyclic.isEmpty, "\(cyclic)")
        let alias = LuauAnalyzer.analyze(moduleSnapshot(use: "local store = game:GetService('ReplicatedStorage')\nlocal config = require(store:WaitForChild('Config'))\nlocal n: number = config.answer", module: "return {answer = 42}"))
        check("module resolution follows service aliases and WaitForChild", alias.isEmpty, "\(alias)")
        var strange = LuauScene()
        let storage = strange.places["ReplicatedStorage"]!
        strange.add(.init(name: "end", className: "ModuleScript", parent: storage, source: "return {answer = 42}"))
        strange.add(.init(name: "two words", className: "Part", parent: storage))
        strange.script = strange.add(.init(name: "Main", className: "Script", parent: storage))
        let oddNames = LuauAnalyzer.analyze(.init(source: "--!strict\nlocal n: number = require(game:GetService('ReplicatedStorage')['end']).answer\nlocal p: Part = game:GetService('ReplicatedStorage')['two words']", scene: strange))
        check("scene names that are keywords or contain spaces remain valid typed properties", oddNames.isEmpty, "\(oddNames)")
        var foundScene = LuauScene()
        foundScene.add(.init(name: "Brick", className: "Part", parent: foundScene.places["Workspace"]))
        let found = LuauAnalyzer.analyze(.init(source: "--!strict\nlocal brick = workspace:WaitForChild('Brick')\nbrick.Anchored = 'wrong'", scene: foundScene))
        check("literal child lookup keeps the known scene object's property types", found.contains { $0.message.contains("boolean") }, "\(found)")
        let math = LuauAnalyzer.analyze(source: "--!strict\nlocal n: number = math.lerp(0, 10, 0.5)\nlocal v = Vector3.new(1, 2, 3) + Vector3.one\nlocal frame: CFrame = CFrame.new(v) * CFrame.Angles(0, 1, 0)")
        check("Studio maths and value operators retain types", math.isEmpty, "\(math)")
        let definitions = LuauTypeDefinitions.source(scene: LuauScene())
        let missing = LuauAPI.instanceMembers.flatMap { owner, members in members.compactMap { member -> String? in
            let label = String(member.label.prefix { $0 != "(" })
            return definitions.contains("\(label):") ? nil : "\(owner).\(label)"
        } }
        check("every completion property and method is represented in analyzer declarations", missing.isEmpty, "\(missing)")
    }

    private static func testDecorations(_ check: Checker) {
        let entry = CodeEditor.makeEntry()
        let view = entry.textView
        view.string = "--!strict\nlocal n: number = 'bad'"
        let coordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2)
        coordinator.entry = entry
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 9, length: 0))
        let before = view.string
        let diagnostics = LuauAnalyzer.analyze(source: before)
        let caret = view.selectedRange()
        let undo = view.undoManager?.canUndo
        CodeEditor.applyDiagnostics(diagnostics, to: view)
        let decorated = diagnostics.first.map { error in
            view.layoutManager?.temporaryAttribute(.underlineColor, atCharacterIndex: error.range(in: before).location, effectiveRange: nil) != nil
        } ?? false
        check("editor underlines actual diagnostic ranges without moving the caret or creating undo", decorated && view.string == before && view.selectedRange() == caret && view.undoManager?.canUndo == undo)
        CodeEditor.applyDiagnostics([], to: view)
        let cleared = diagnostics.first.map { error in
            view.layoutManager?.temporaryAttribute(.underlineColor, atCharacterIndex: error.range(in: before).location, effectiveRange: nil) == nil
        } ?? false
        check("new source clears diagnostic decorations", cleared)
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau); script.source = before
        model.scripts = [script]
        let session = EditorSession(model: model)
        _ = session.openScript(script.id, line: 2)
        check("diagnostic navigation reveals the correct script and line", session.activeDocument == .script(script.id) && session.revealRequest?.line == 2)
        session.analysis.request(.init(source: before), for: EditorDocument.script(script.id).id)
        session.close(.script(script.id))
        check("EditorSession cancels analysis when its tab closes", session.analysis.checking.isEmpty)
    }

    private static func testTwoPlayers(_ check: Checker) {
        print("\nLuau analysis: annotated scripts still run over loopback")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let remote = DataObject(name: "TypedPing", className: .remoteEvent, parent: .replicatedStorage)
            model.dataObjects = [remote]
            var server = ScriptObject.blank(language: .luau)
            server.source = """
            --!strict
            local remote = game:GetService("ReplicatedStorage"):WaitForChild("TypedPing")
            remote.OnServerEvent:Connect(function(player: Player, count: number)
                print("typed server", player.Name, count)
                remote:FireClient(player, count + 1)
            end)
            """
            var client = ScriptObject.blank(language: .luau)
            client.host = .starterPlayer
            client.source = """
            --!strict
            local remote = game:GetService("ReplicatedStorage"):WaitForChild("TypedPing")
            remote.OnClientEvent:Connect(function(count: number)
                print("typed client", game:GetService("Players").LocalPlayer.Name, count)
            end)
            task.wait(0.2)
            remote:FireServer(41)
            """
            model.scripts += [server, client]
        }), let host = hosting.player, let joined = joining.player else {
            check("annotated scripts start on a host and joiner", false); return
        }
        defer { joining.leaveGame(); hosting.leaveGame() }
        LANSelfTest.run([hosting, joining], seconds: 0.8)
        let hostOutput = host.console.lines.filter { $0.kind == .output }.map(\.text)
        let joinedOutput = joined.console.lines.filter { $0.kind == .output }.map(\.text)
        check("host and joined player exchange their own annotated arguments", hostOutput.contains("typed server Robin 41") && hostOutput.contains("typed server Sam 41") && hostOutput.contains("typed client Robin 42") && joinedOutput.contains("typed client Sam 42"), "\(hostOutput) | \(joinedOutput)")
        check("annotations cause no runtime errors on either machine", !host.console.lines.contains { $0.kind == .error } && !joined.console.lines.contains { $0.kind == .error })
        let before = joined.model.state
        let scripts = joined.model.scripts.filter { $0.source.contains("--!strict") }
        let results = scripts.flatMap { LuauAnalyzer.analyze(.init(source: $0.source, scene: joined.model.luauScene(editing: $0.id))) }
        check("annotated sources arrive intact and analyze without changing the network scene", !scripts.isEmpty && results.isEmpty && joined.model.state == before, "\(results)")
    }

    private static func testService(_ check: Checker) {
        let service = LuauAnalysisService(pause: 0.03)
        let bad = LuauAnalysisSnapshot(source: "--!strict\nlocal n: number = 'bad'")
        let good = LuauAnalysisSnapshot(source: "--!strict\nlocal n: number = 3")
        service.request(bad, for: "first")
        check("analysis is debounced without blocking the editor", service.checking.contains("first") && service.diagnostics["first"] == nil)
        check("background analysis publishes ranged errors", LANSelfTest.wait(4) { !(service.diagnostics["first"] ?? []).isEmpty })
        service.request(bad, for: "second")
        service.request(good, for: "second")
        check("newer text supersedes pending results", LANSelfTest.wait(4) { service.diagnostics["second"] != nil && !service.checking.contains("second") } && service.diagnostics["second"]?.isEmpty == true)
        service.request(bad, for: "closed")
        service.forget("closed")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check("closing a document discards queued diagnostics", service.diagnostics["closed"] == nil && !service.checking.contains("closed"))
        let moduleError = moduleSnapshot(use: "local config = require(script.Parent.Config)", module: "local n: number = 'bad'\nreturn {answer = n}")
        service.request(moduleError, for: "module")
        check("required-module errors remain visible for navigation", LANSelfTest.wait(4) { service.diagnostics["module"] != nil } && service.diagnostics["module"]?.contains { $0.node != moduleError.target } == true)
        service.request(good, for: "first")
        check("old ranges clear immediately when text changes", service.diagnostics["first"] == nil)
        check("another tab keeps its own results", service.diagnostics["second"]?.isEmpty == true)
        var otherScene = good
        otherScene.sceneID = UUID()
        service.request(otherScene, for: "second")
        check("a different scene invalidates results even with identical script text", service.checking.contains("second") && service.diagnostics["second"] == nil)
    }

    private static func testMountedEditor(_ check: Checker) {
        let model = SceneModel()
        model.parts = []; model.groups = []; model.dataObjects = []
        var module = ScriptObject.blank(language: .luau)
        module.name = "Config"; module.kind = .module; module.host = .replicatedStorage
        module.source = "--!strict\nreturn {answer = 'bad'}"
        var script = ScriptObject.blank(language: .luau)
        script.source = "--!strict\nlocal n: number = require(game:GetService('ReplicatedStorage').Config).answer"
        model.scripts = [script, module]
        let session = EditorSession(model: model)
        let document = EditorDocument.script(script.id)
        _ = session.open(document)
        let hosting = NSHostingView(rootView: DocumentView(model: model, session: session, document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil; session.closeAllDocuments() }
        let showed = LANSelfTest.wait(5) { !(session.analysis.diagnostics[document.id] ?? []).isEmpty }
        check("the mounted script editor requests analysis and displays issues", showed && session.codeViews.entry(for: document.id) != nil)
        guard let entry = session.codeViews.entry(for: document.id) else { return }
        let text = entry.textView
        text.setSelectedRange(NSRange(location: 10, length: 0))
        let caret = text.selectedRange()
        model.setScriptSource(id: module.id, source: "--!strict\nreturn {answer = 42}")
        let cleared = LANSelfTest.wait(5) { session.analysis.diagnostics[document.id]?.isEmpty == true && !session.analysis.checking.contains(document.id) }
        check("editing a required module refreshes an open dependent without moving its caret", cleared && text.selectedRange() == caret)
        let source = text.string
        let annotation = (source as NSString).range(of: "number")
        text.insertText("string", replacementRange: annotation)
        let caught = LANSelfTest.wait(5) { !(session.analysis.diagnostics[document.id] ?? []).isEmpty && !session.analysis.checking.contains(document.id) }
        check("typing updates both the scene source and diagnostics", caught && model.script(id: script.id)?.source.contains("n: string") == true, "text=\(text.string) model=\(model.script(id: script.id)?.source ?? "missing") diagnostics=\(session.analysis.diagnostics[document.id] ?? []) module=\(model.script(id: module.id)?.source ?? "missing") checking=\(session.analysis.checking)")
        text.undoManager?.undo()
        let restored = LANSelfTest.wait(5) { text.string == source && session.analysis.diagnostics[document.id]?.isEmpty == true }
        check("text undo restores the source and its diagnostics", restored, "\(text.string)")
    }

    private static func testInFlightRevisions(_ check: Checker) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let bad = LuauAnalysisSnapshot(source: "--!strict\nlocal n: number = 'old'")
        let good = LuauAnalysisSnapshot(source: "--!strict\nlocal n: number = 3")
        let service = LuauAnalysisService(pause: 0) { snapshot in
            if snapshot.source == bad.source {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            return LuauAnalyzer.analyze(snapshot)
        }
        var obsoletePublished = false
        let observation = service.$diagnostics.sink { results in
            if results["race"]?.contains(where: { !$0.message.isEmpty }) == true { obsoletePublished = true }
        }
        service.request(bad, for: "race")
        var didEnter = false
        let running = LANSelfTest.wait(2) { if !didEnter { didEnter = entered.wait(timeout: .now()) == .success }; return didEnter }
        check("analysis runs off the main thread while the editor accepts requests", running)
        service.request(good, for: "race")
        release.signal()
        let finished = LANSelfTest.wait(4) { service.diagnostics["race"] != nil && !service.checking.contains("race") }
        check("an already-running old result is never published over a newer revision", finished && !obsoletePublished && service.diagnostics["race"]?.isEmpty == true)
        service.request(bad, for: "closed-running")
        didEnter = false
        let secondRunning = LANSelfTest.wait(2) { if !didEnter { didEnter = entered.wait(timeout: .now()) == .success }; return didEnter }
        service.forget("closed-running")
        release.signal()
        service.request(good, for: "after-close")
        _ = LANSelfTest.wait(4) { service.diagnostics["after-close"] != nil }
        check("an already-running closed tab cannot resurrect its diagnostics", secondRunning && service.diagnostics["closed-running"] == nil)
        withExtendedLifetime(observation) {}
    }

    static func moduleSnapshot(use: String, module: String) -> LuauAnalysisSnapshot {
        var scene = LuauScene()
        let folder = scene.places["ReplicatedStorage"]!
        scene.add(.init(name: "Config", className: "ModuleScript", parent: folder, source: "--!strict\n" + module))
        scene.script = scene.add(.init(name: "Main", className: "Script", parent: folder))
        return LuauAnalysisSnapshot(source: "--!strict\n" + use, scene: scene)
    }
}
