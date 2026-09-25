import Foundation
import AppKit
import SwiftUI
import Metal
import simd

/// Verification for the tabs: scripts and shaders open full size in front of the world,
/// as in Roblox Studio, with the console along the bottom. Covers the tabs themselves,
/// what each keeps while another is in front, the menu commands that go to text rather
/// than the world, errors in the Output that open their script, and the world hidden
/// behind a tab but still running.
enum DocumentTabsSelfTest {

    static func run(check: Checker) {
        _ = NSApplication.shared
        testTabs(check)
        testTabsFollowTheScene(check)
        testUndoKeepsText(check)
        testLineNumbers(check)
        testConsoleLinks(check)
        testTextCommands(check)
        testEditorsSurviveSwitching(check)
        testHiddenWorld(check)
    }

    // MARK: - The tabs

    private static func testTabs(_ check: Checker) {
        print("\nTabs: opening, closing and moving between them")
        let model = SceneModel()
        let session = EditorSession(model: model)
        check("the world is in front to begin with, with no tabs", session.showsWorld && session.documents.isEmpty)
        check("the console shows along the bottom from the start", session.dockVisible && session.dockTab == .output)

        let a = model.addScript(name: "Alpha")
        let b = model.addScript(name: "Beta")
        let shader = model.addShader(name: "Glow")
        session.openScript(a)
        check("opening a script puts it in front, in a tab",
              session.activeDocument == .script(a) && session.documents == [.script(a)])
        session.openScript(a)
        check("opening it again reuses its tab", session.documents.count == 1)
        session.openScript(b)
        session.openShader(shader)
        check("tabs line up in the order they were opened",
              session.documents == [.script(a), .script(b), .shader(shader)])
        check("a shader opens like a script", session.activeDocument == .shader(shader))
        check("something that doesn't exist opens nothing",
              !session.openScript(UUID()) && session.documents.count == 3)
        let control = CoreScripts.controlScript.name
        check("a built-in script opens in a tab of its own",
              session.openCoreScript(named: control) && session.activeDocument == .coreScript(control))
        session.close(.coreScript(control))
        check("closing the tab in front brings forward the one to its left",
              session.activeDocument == .shader(shader))

        session.showWorld()
        check("the world tab comes back without closing anything",
              session.showsWorld && session.documents.count == 3)
        check("⌘W does nothing with the world in front",
              !session.closeActiveDocument() && session.documents.count == 3)

        session.selectAdjacentTab(1)
        check("the tab after the world is the first document", session.activeDocument == .script(a))
        session.selectAdjacentTab(-1)
        session.selectAdjacentTab(-1)
        check("going back past the world wraps round to the last tab", session.activeDocument == .shader(shader))
        session.selectAdjacentTab(1)
        check("…and on from the last comes back to the world", session.showsWorld)

        session.open(.script(a))
        session.close(.script(a))
        check("closing the first tab while it is in front shows the world",
              session.showsWorld && session.documents == [.script(b), .shader(shader)])

        model.updateScript(id: b) { $0.name = "Renamed" }
        check("a tab is named after its script as it is now", session.title(of: .script(b)) == "Renamed")

        session.closeOtherDocuments(than: .shader(shader))
        check("Close Other Tabs keeps just that one, in front",
              session.documents == [.shader(shader)] && session.activeDocument == .shader(shader))
        session.closeAllDocuments()
        check("Close All Tabs leaves the world", session.documents.isEmpty && session.showsWorld)

        session.openScript(a, line: 3)
        let first = session.revealRequest(for: .script(a))
        check("an error's line goes to that script's tab",
              first?.line == 3 && session.activeDocument == .script(a) && session.revealRequest(for: .script(b)) == nil)
        session.openScript(a, line: 3)
        check("asking for the same line again is a new request",
              session.revealRequest(for: .script(a))?.token != first?.token)

        session.showDock(.animation)
        check("the Animation Editor brings the world forward, for its rig",
              session.showsWorld && session.dockTab == .animation)

        session.openScript(a)
        session.startPlay()
        check("Play brings the world forward and keeps the tabs",
              session.showsWorld && session.documents.contains(.script(a)))
        session.stopPlay()
        check("…and they are still there after Stop", session.documents.contains(.script(a)))
    }

    private static func testTabsFollowTheScene(_ check: Checker) {
        print("\nTabs: following the scene")
        let model = SceneModel()
        let session = EditorSession(model: model)
        let script = model.addScript(name: "Doomed")
        let shader = model.addShader(name: "Doomed Shader")
        let control = CoreScripts.controlScript.name
        session.openScript(script)
        session.openShader(shader)
        session.openCoreScript(named: control)

        model.deleteScript(id: script)
        check("deleting a script closes its tab", !session.documents.contains(.script(script)))
        model.undo()
        check("undoing the delete brings the script back but not its tab",
              model.script(id: script) != nil && !session.documents.contains(.script(script)))
        model.deleteShader(id: shader)
        check("deleting a shader closes its tab", !session.documents.contains(.shader(shader)))

        session.openScript(script)
        model.loadStarterScene()
        check("another scene closes the old scene's tabs",
              !session.documents.contains(.script(script)))
        check("…but not a built-in script's, which every scene has",
              session.documents.contains(.coreScript(control)))
    }

    private static func testUndoKeepsText(_ check: Checker) {
        print("\nTabs: scene undo leaves code alone")
        let model = SceneModel()
        let part = model.parts[0].id
        let start = model.part(id: part)!.position.x
        let script = model.addScript(name: "Notes", source: "print(1)")
        let shader = model.shaders[0].id
        model.commit("Moved") { model.update(id: part) { $0.position.x += 10 } }
        model.setScriptSource(id: script, source: "print(1)\nprint(2) -- typed after the move")
        model.setShaderSource(id: shader, source: "return float3(1, 0, 0);")

        model.undo()
        check("undo takes the part back", model.part(id: part)?.position.x == start)
        check("…but keeps the code typed since", model.script(id: script)?.source.hasSuffix("typed after the move") == true)
        check("…and the shader's text too", model.shader(id: shader)?.source == "return float3(1, 0, 0);")
        model.redo()
        check("redo keeps it as well", model.part(id: part)?.position.x == start + 10
              && model.script(id: script)?.source.hasSuffix("typed after the move") == true)
        model.deleteScript(id: script)
        model.undo()
        check("a deleted script comes back with the text it had",
              model.script(id: script)?.source.hasSuffix("typed after the move") == true)
    }

    // MARK: - The editor

    private static func testLineNumbers(_ check: Checker) {
        print("\nTabs: line numbers")
        let text = "one\ntwo\n\nfour\n" as NSString
        check("the first character is on line 1", LineNumbers.line(atOffset: 0, in: text) == 1)
        check("a character after a newline is on the next line", LineNumbers.line(atOffset: 4, in: text) == 2)
        check("the end of a text that ends in a newline is on the empty last line",
              LineNumbers.line(atOffset: text.length, in: text) == 5)
        check("lines are counted as an editor shows them",
              LineNumbers.count(in: text) == 5 && LineNumbers.count(in: "" as NSString) == 1)
        check("a line's range leaves out its newline", LineNumbers.range(ofLine: 2, in: text) == NSRange(location: 4, length: 3))
        check("an empty line is an empty range where it starts",
              LineNumbers.range(ofLine: 3, in: text) == NSRange(location: 8, length: 0))
        check("a line the text doesn't have has no range",
              LineNumbers.range(ofLine: 6, in: text) == nil && LineNumbers.range(ofLine: 0, in: text) == nil)
        check("the gutter keeps room for three digits",
              LineNumberRuler.thickness(forLines: 1) == LineNumberRuler.thickness(forLines: 999))
        check("…and widens for a fourth",
              LineNumberRuler.thickness(forLines: 1000) > LineNumberRuler.thickness(forLines: 999))

        let entry = CodeEditor.makeEntry()
        entry.textView.string = "a\nb\nc"
        CodeEditor.setLineNumbers(true, on: entry)
        check("an editor with line numbers has the gutter beside its text",
              entry.scrollView.verticalRulerView is LineNumberRuler && entry.scrollView.rulersVisible)
        entry.textView.reveal(line: 2)
        check("jumping to a line selects it", entry.textView.selectedRange() == NSRange(location: 2, length: 1))
    }

    private static func testConsoleLinks(_ check: Checker) {
        print("\nTabs: errors in the Output")
        func find(_ text: String) -> ConsoleLocation? { ConsoleLocation.find(in: text) }
        check("a Luau error names its script and line",
              find("BobScript:3: attempt to index nil with 'Position'") == ConsoleLocation(scriptName: "BobScript", line: 3))
        check("so does a Luau stack frame",
              find("    Mover:12 function onTouched") == ConsoleLocation(scriptName: "Mover", line: 12))
        check("and a Wren error and its trace",
              find("Spinner:4 — Error at 'x': Expect expression.") == ConsoleLocation(scriptName: "Spinner", line: 4)
              && find("    in Spinner:9") == ConsoleLocation(scriptName: "Spinner", line: 9))
        check("a name may have spaces or colons in it",
              find("My Script:7: oops") == ConsoleLocation(scriptName: "My Script", line: 7)
              && find("Door:Open:9: oops") == ConsoleLocation(scriptName: "Door:Open", line: 9))
        check("Wren's second script of a name is the first's name",
              find("Spinner#2:5 — oops") == ConsoleLocation(scriptName: "Spinner", line: 5))
        check("plain messages point nowhere",
              find("▶ Play started") == nil && find("Wren update callbacks stopped after an error.") == nil)
        check("nor does a number that isn't a line", find("time:12seconds") == nil && find("Script:0: x") == nil)
    }

    private static func testTextCommands(_ check: Checker) {
        print("\nTabs: menu commands in the code editor")
        let entry = CodeEditor.makeEntry()
        let coordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2)
        coordinator.entry = entry
        entry.textView.delegate = coordinator
        entry.textView.source = coordinator
        let original = "local a = 1\nlocal b = 2"
        entry.textView.string = original
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = entry.scrollView
        window.makeFirstResponder(entry.textView)
        check("the editor keeps its own document's undo history", entry.textView.undoManager === entry.undo)

        let model = SceneModel()
        let parts = model.parts.count
        model.commit("Removed a part") { model.parts.removeLast() }
        entry.textView.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        entry.textView.insertText(" ", replacementRange: entry.textView.selectedRange())
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("typing is undoable in the editor", entry.undo.canUndo)
        let handled = TextCommand.perform(.undo, in: window.firstResponder)
        check("⌘Z with the editor in charge undoes the typing",
              handled && entry.textView.string == original, "\"\(entry.textView.string)\"")
        check("…and leaves the scene alone", model.parts.count == parts - 1 && model.canUndo)

        TextCommand.perform(.selectAll, in: entry.textView)
        check("⌘A selects all the text", entry.textView.selectedRange() == NSRange(location: 0, length: (original as NSString).length))
        entry.textView.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        TextCommand.perform(.deleteToLineStart, in: entry.textView)
        check("⌘⌫ deletes to the start of the line", entry.textView.string == "local a = 1\n", "\"\(entry.textView.string)\"")
        entry.textView.isEditable = false
        let claimed = TextCommand.perform(.deleteToLineStart, in: entry.textView)
        check("…and nothing in a read-only editor, which still keeps it from the world",
              claimed && entry.textView.string == "local a = 1\n")
        TextCommand.perform(.find, in: entry.textView)
        check("⌘F opens the find bar", entry.scrollView.isFindBarVisible)
        check("with the world in charge they are the world's",
              !TextCommand.perform(.undo, in: NSView()) && !TextCommand.perform(.selectAll, in: nil))
        window.contentView = nil
    }

    /// Switching tabs rebuilds the SwiftUI views, but each script's text view — caret,
    /// scroll and undo — must come back as it was.
    private static func testEditorsSurviveSwitching(_ check: Checker) {
        print("\nTabs: switching keeps each editor")
        let documents = SwitchingDocuments()
        let cache = CodeEditorCache()
        let hosting = NSHostingView(rootView: SwitchingHarness(documents: documents, cache: cache))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let a = cache.entry(for: "a") else {
            check("an open tab's editor is made", false)
            return
        }
        check("an open tab's editor is in the window, with the keyboard",
              a.textView.window === window && window.firstResponder === a.textView)
        check("…and has line numbers", a.scrollView.verticalRulerView is LineNumberRuler)
        a.textView.setSelectedRange(NSRange(location: (a.textView.string as NSString).length, length: 0))
        a.textView.insertText(" ", replacementRange: a.textView.selectedRange())
        a.textView.setSelectedRange(NSRange(location: 3, length: 2))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        documents.key = "b"
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let b = cache.entry(for: "b")
        check("another tab gets a text view of its own",
              b != nil && b?.textView !== a.textView && b?.textView.window === window)
        check("the one behind leaves the window but is kept", a.textView.window == nil && cache.count == 2)

        documents.key = "a"
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check("coming back shows the very same text view",
              cache.entry(for: "a")?.textView === a.textView && a.textView.window === window)
        check("…with the selection where it was left", a.textView.selectedRange() == NSRange(location: 3, length: 2))
        check("…and its typing undoable, apart from the other tab's",
              a.undo.canUndo && b?.undo.canUndo == false)
        check("typing reached the document", documents.texts["a"] == "print(\"a\") ")
        window.contentView = nil
    }

    // MARK: - The world behind a tab

    private static func testHiddenWorld(_ check: Checker) {
        print("\nTabs: the world behind a tab")
        guard let device = MTLCreateSystemDefaultDevice() else {
            check("a Metal device is available", false)
            return
        }
        // Keys: Delete behind a script must never delete the selected part.
        let editorModel = SceneModel()
        let keysView = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        keysView.editor = ViewportController(model: editorModel)
        let keysWindow = NSWindow(contentRect: keysView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        keysWindow.contentView = keysView
        let target = editorModel.parts[0].id
        editorModel.selection = [target]
        keysView.showsWorld = false
        check("a tab in front hides the viewport and takes its keyboard",
              keysView.isHidden && keysWindow.firstResponder !== keysView)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: keysWindow.windowNumber, context: nil,
                                      characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                      isARepeat: false, keyCode: 51)!
        keysView.keyDown(with: delete)
        check("Delete with a tab in front leaves the selected part alone", editorModel.part(id: target) != nil)
        keysView.showsWorld = true
        check("back on the world, the viewport has the keyboard again",
              !keysView.isHidden && keysWindow.firstResponder === keysView)
        keysView.keyDown(with: delete)
        check("…and Delete deletes again", editorModel.part(id: target) == nil)
        keysWindow.contentView = nil

        // A play test with a crate falling from high up, and a shader switched on while
        // the world is hidden.
        let model = SceneModel()
        var crate = PhysicsSelfTest.block(Vec3(300, 400, 0))
        crate.name = "Crate"
        model.parts.append(crate)
        let shader = model.addShader(name: "Late")
        model.updateShader(id: shader) { $0.enabled = false }
        let play = PlayController(model: model, console: ScriptConsole())
        play.start()
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        view.device = device
        guard let renderer = Renderer(device: device, view: view, source: play) else {
            check("the renderer builds", false)
            return
        }
        view.delegate = renderer
        view.backgroundTick = { [weak renderer] in renderer?.tick() }
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        view.showsWorld = false
        let frames = view.framesRequested
        let ticks = view.backgroundTicks
        let height = model.part(id: crate.id)?.position.y ?? 0
        model.updateShader(id: shader) { $0.enabled = true }
        let deadline = Date().addingTimeInterval(4)
        while renderer.shaderLibrary.pipeline(for: shader) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check("hidden, it draws nothing", view.framesRequested == frames, "\(view.framesRequested) vs \(frames)")
        check("…but keeps ticking", view.backgroundTicks > ticks + 5, "\(view.backgroundTicks - ticks) ticks")
        let fallen = model.part(id: crate.id)?.position.y ?? height
        check("…so a play test runs on behind a script", fallen < height - 1, "\(height) → \(fallen)")
        check("…and a shader switched on meanwhile compiles", renderer.shaderLibrary.pipeline(for: shader) != nil)

        view.showsWorld = true
        let resumed = view.backgroundTicks
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check("shown again, it stops ticking in the background", view.backgroundTicks == resumed)
        play.stop()
        window.contentView = nil
    }
}

/// Two documents and which one is in front, for `testEditorsSurviveSwitching`.
private final class SwitchingDocuments: ObservableObject {
    @Published var key = "a"
    var texts = ["a": "print(\"a\")", "b": "print(\"b\")"]
}

/// Shows one document's editor at a time, rebuilt on every switch as a tab's is.
private struct SwitchingHarness: View {
    @ObservedObject var documents: SwitchingDocuments
    let cache: CodeEditorCache

    var body: some View {
        let key = documents.key
        CodeEditor(text: documents.texts[key] ?? "", cache: cache, cacheKey: key,
                   showsLineNumbers: true, focusOnAppear: true) { [documents] text in
            documents.texts[key] = text
        }
        .id(key)
    }
}
