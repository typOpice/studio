import AppKit
import SwiftUI
import Metal
import simd

/// Verification for split view (the world beside a tab, each with the keyboard when
/// clicked) and screen effects chained one after another — drawn and read back — with
/// the Luau Screen API and the effects reaching a joined player.
enum SplitAndEffectsSelfTest {

    static func run(check: Checker) {
        testSplitView(check)
        testEffectChain(check)
        testEffectsFromScripts(check)
    }

    private static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: - Split view

    private static func testSplitView(_ check: Checker) {
        print("\nEditor: split view")
        let model = SceneModel()
        let session = EditorSession(model: model)
        let script = model.addScript(parentID: nil)
        session.openScript(script)
        let hosting = NSHostingView(rootView: DocumentArea(model: model, session: session))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let viewport = views(StudioMTKView.self, in: hosting).first,
              let code = views(CodeTextView.self, in: hosting).first else {
            check("the world and the script are in the window", false)
            return
        }
        check("a tab in front covers the world", viewport.isHidden && !session.showsWorld)

        window.makeFirstResponder(code)
        session.toggleSplitView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let codeNow = views(CodeTextView.self, in: hosting).first
        check("split view shows the world beside the tab", !viewport.isHidden && session.showsWorld
              && !session.worldInFront && codeNow?.window === window)
        let worldWidth = viewport.convert(viewport.bounds, to: nil).width
        check("…sharing the width", abs(worldWidth - 450) < 20, "\(worldWidth)")
        check("…leaving the keyboard in the code", window.firstResponder === codeNow)

        let parts = model.parts.count
        if let codeNow {
            codeNow.setSelectedRange(NSRange(location: (codeNow.string as NSString).length, length: 0))
            let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                          charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!
            model.selection = [model.parts[0].id]
            let before = codeNow.string
            window.sendEvent(delete)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check("Delete in the code deletes code, not parts", model.parts.count == parts && codeNow.string != before)
        }

        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 250), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        viewport.mouseDown(with: click)
        viewport.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 100, y: 250), modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1)!)
        check("a click on the world gives it the keyboard", window.firstResponder === viewport)

        session.toggleSplitView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check("turning split view off covers the world again", viewport.isHidden)
        window.contentView = nil
    }

    // MARK: - Chained effects

    private static func testEffectChain(_ check: Checker) {
        print("\nScreen effects: several at once")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("a Metal device is available", false)
            return
        }
        let model = SceneModel()
        let invert = model.addShader(kind: .screen, name: "Invert", source: "return float3(1.0) - sceneColor;")
        let flat = model.addShader(kind: .screen, name: "Flat", source: "return float3(0.2, 0.4, 0.6);")
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.device = device
        let editor = ViewportController(model: model)
        guard let renderer = Renderer(device: device, view: view, source: editor) else {
            check("the renderer builds", false)
            return
        }
        let deadline = Date().addingTimeInterval(8)
        while (renderer.shaderLibrary.pipeline(for: invert) == nil || renderer.shaderLibrary.pipeline(for: flat) == nil),
              Date() < deadline {
            renderer.shaderLibrary.refresh(shaders: model.shaders)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        func middle() -> SIMD3<Float>? {
            guard let pixels = renderer.frameSnapshot(width: 64, height: 64) else { return nil }
            let p = pixels[32 * 64 + 32]
            return SIMD3(Float(p.z), Float(p.y), Float(p.x)) / 255
        }
        func near(_ a: SIMD3<Float>?, _ b: SIMD3<Float>) -> Bool { a.map { simd_distance($0, b) < 0.03 } ?? false }

        model.toggleScreenShader(flat)
        check("one effect on draws it", near(middle(), SIMD3(0.2, 0.4, 0.6)), "\(String(describing: middle()))")
        model.toggleScreenShader(invert)
        check("two on run one after another, in the Explorer's order (Invert, then Flat)",
              model.activeScreenShaders.map(\.id) == [invert, flat] && near(middle(), SIMD3(0.2, 0.4, 0.6)),
              "\(String(describing: middle()))")
        model.moveShader(flat, by: -1)
        check("…so Flat above Invert inverts the flat colour",
              near(middle(), SIMD3(0.8, 0.6, 0.4)), "\(String(describing: middle()))")
        model.toggleScreenShader(flat)
        let inverted = middle()
        check("switching one off leaves the other", model.activeScreenShaders.map(\.id) == [invert]
              && inverted != nil && !near(inverted, SIMD3(0.8, 0.6, 0.4)))

        let saved = try? JSONEncoder().encode(model.state)
        let loaded = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("the effects switched on are saved", loaded?.screenShaderIDs == [invert])
        let old = try? JSONDecoder().decode(SceneState.self, from: Data(#"{"screenShaderID":"\#(flat.uuidString)"}"#.utf8))
        check("scenes from before chaining open with their one effect", old?.screenShaderIDs == [flat])
    }

    // MARK: - Scripts and the network

    private static func testEffectsFromScripts(_ check: Checker) {
        print("\nScreen effects: from scripts, in a network game")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            _ = model.addShader(kind: .screen, name: "Invert", source: "return float3(1.0) - sceneColor;")
            _ = model.addShader(kind: .screen, name: "Flat", source: "return float3(0.2, 0.4, 0.6);")
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            local Shaders = game:GetService("Shaders")
            task.wait(0.2)
            Screen:AddShader(Shaders:FindFirstChild("Flat"))
            Screen:AddShader(Shaders:FindFirstChild("Invert"))
            local names = {}
            for _, shader in Screen:GetShaders() do
            \ttable.insert(names, shader.Name)
            end
            print("on", table.concat(names, ","), Screen.Shader.Name)
            Screen:RemoveShader(Shaders:FindFirstChild("Invert"))
            print("after", #Screen:GetShaders(), pcall(function() Screen:AddShader(5) end))
            """
            model.scripts.append(script)
        }), let robin = hosting.player else {
            check("two players share a game", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let said = robin.console.lines.filter { $0.kind == .output }.map(\.text)
        check("Screen:AddShader, GetShaders (in Explorer order) and RemoveShader",
              said.contains("on Invert,Flat Invert") && said.contains { $0.hasPrefix("after 1 false") }, "\(said)")
        check("the host's effects reach the joined player", joining.model.screenShaderIDs == hosting.model.screenShaderIDs
              && joining.model.activeScreenShaders.map(\.name) == ["Flat"])
        joining.leaveGame()
        hosting.leaveGame()
    }
}
