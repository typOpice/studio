import AppKit
import simd

/// Verification for the GUI's second layer: UIListLayout, AutomaticSize, ScrollingFrame,
/// clipping, TextScaled, the TextBox caret and clipboard, BillboardGuis, and StarterGui —
/// made in Studio, previewed, copied to each player, its LocalScripts run, reset for each
/// character, and one copy per player in a network game.
enum GuiLayoutSelfTest {

    static func run(check: Checker) {
        testLists(check)
        testScrolling(check)
        testTextAndCaret(check)
        testLuau(check)
        testStarterGui(check)
        testStarterGuiInMultiplayer(check)
    }

    private static let screen = CGSize(width: 800, height: 600)
    private static let frame: Float = 1.0 / 60

    private static func same(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5
            && abs(a.height - b.height) < 0.5
    }

    private static func make(_ store: GuiStore, _ kind: GuiObject.Kind, in parent: Int,
                             _ body: (inout GuiObject) -> Void = { _ in }) -> Int {
        let id = store.create(kind)
        store.update(id, body)
        store.setParent(id, to: parent)
        return id
    }

    private static func placed(_ store: GuiStore, _ id: Int) -> GuiStore.Placed? {
        store.layout(in: screen).first { $0.id == id }
    }

    // MARK: - Lists

    private static func testLists(_ check: Checker) {
        print("\nGUI: UIListLayout and AutomaticSize")
        let store = GuiStore()
        let root = make(store, .screenGui, in: GuiStore.playerGui)
        let column = make(store, .frame, in: root) {
            $0.position = UDim2(xOffset: 10, yOffset: 20)
            $0.size = UDim2(xOffset: 300, yOffset: 400)
        }
        let list = make(store, .uiListLayout, in: column) { $0.listPadding = SIMD2(0, 5) }
        let second = make(store, .textLabel, in: column) { $0.size = UDim2(xOffset: 100, yOffset: 30); $0.layoutOrder = 2 }
        let first = make(store, .textLabel, in: column) {
            $0.size = UDim2(xOffset: 120, yOffset: 20); $0.layoutOrder = 1; $0.position = UDim2(xOffset: 99, yOffset: 99)
        }
        check("a UIListLayout stacks children by LayoutOrder, with Padding, ignoring Position",
              same(placed(store, first)?.frame, CGRect(x: 10, y: 20, width: 120, height: 20))
              && same(placed(store, second)?.frame, CGRect(x: 10, y: 45, width: 100, height: 30)),
              "\(String(describing: placed(store, first)?.frame)) \(String(describing: placed(store, second)?.frame))")
        store.update(list) { $0.horizontalAlignment = "Center"; $0.verticalAlignment = "Bottom" }
        check("…aligned as it says", same(placed(store, first)?.frame, CGRect(x: 100, y: 365, width: 120, height: 20)),
              "\(String(describing: placed(store, first)?.frame))")
        store.update(list) { $0.fillDirection = "Horizontal"; $0.horizontalAlignment = "Left"; $0.verticalAlignment = "Top" }
        check("…or side by side", same(placed(store, second)?.frame, CGRect(x: 135, y: 20, width: 100, height: 30)))

        let note = make(store, .textLabel, in: root) {
            $0.position = UDim2(xOffset: 400)
            $0.size = UDim2(xOffset: 150, yOffset: 0)
            $0.text = String(repeating: "wrap me please ", count: 6)
            $0.textWrapped = true
            $0.automaticSize = "Y"
        }
        let height = placed(store, note)?.frame.height ?? 0
        check("AutomaticSize Y grows a wrapped label to its text", height > 40 && placed(store, note)?.frame.width == 150,
              "\(height)")
        store.update(note) { $0.text = "short" }
        check("…and shrinks back to it", (placed(store, note)?.frame.height ?? 0) < 25)
        let box = make(store, .frame, in: root) {
            $0.position = UDim2(xOffset: 600); $0.size = UDim2(xOffset: 100, yOffset: 0); $0.automaticSize = "Y"
        }
        _ = make(store, .uiListLayout, in: box)
        for _ in 0..<3 { _ = make(store, .frame, in: box) { $0.size = UDim2(xOffset: 80, yOffset: 25) } }
        check("…and a frame to what is in it", abs((placed(store, box)?.frame.height ?? 0) - 75) < 0.5)
    }

    // MARK: - Scrolling

    private static func testScrolling(_ check: Checker) {
        print("\nGUI: ScrollingFrame and clipping")
        let store = GuiStore()
        let root = make(store, .screenGui, in: GuiStore.playerGui)
        let scroller = make(store, .scrollingFrame, in: root) {
            $0.position = UDim2(xOffset: 50, yOffset: 50)
            $0.size = UDim2(xOffset: 200, yOffset: 100)
            $0.canvasSize = UDim2()
            $0.automaticCanvasSize = "Y"
        }
        _ = make(store, .uiListLayout, in: scroller)
        let rows = (0..<10).map { index in make(store, .textLabel, in: scroller) {
            $0.size = UDim2(xScale: 1, yOffset: 30); $0.layoutOrder = index; $0.text = "row \(index)"
        } }
        let last = placed(store, rows[9])
        check("a ScrollingFrame's canvas grows to what is in it (AutomaticCanvasSize)",
              placed(store, scroller)?.scrollRange.map { abs($0.height - 200) < 0.5 } == true)
        check("…cutting off what is outside it", last == nil && placed(store, rows[0])?.clip.map { same($0, CGRect(x: 50, y: 50, width: 200, height: 100)) } == true)
        check("…with a bar to show where it is", placed(store, scroller)?.scrollBar != nil)
        check("the wheel over it scrolls it", store.scroll(at: CGPoint(x: 100, y: 100), by: CGSize(width: 0, height: -120)))
        check("…moving what is inside", same(placed(store, rows[4])?.frame, CGRect(x: 50, y: 50, width: 200, height: 30)),
              "\(String(describing: placed(store, rows[4])?.frame))")
        _ = store.scroll(at: CGPoint(x: 100, y: 100), by: CGSize(width: 0, height: -900))
        check("…no further than the end", abs(store.canvasPosition(of: scroller).y - 200) < 0.5)
        check("…and the wheel elsewhere is the camera's", !store.scroll(at: CGPoint(x: 600, y: 500), by: CGSize(width: 0, height: 10)))

        let clipped = make(store, .frame, in: root) {
            $0.position = UDim2(xOffset: 400, yOffset: 400); $0.size = UDim2(xOffset: 50, yOffset: 50); $0.clipsDescendants = true
        }
        let inside = make(store, .frame, in: clipped) { $0.size = UDim2(xOffset: 100, yOffset: 100) }
        check("ClipsDescendants cuts children off at the edges",
              placed(store, inside)?.clip.map { same($0, CGRect(x: 400, y: 400, width: 50, height: 50)) } == true)
    }

    // MARK: - Text and the caret

    private static func testTextAndCaret(_ check: Checker) {
        print("\nGUI: text, and editing in a TextBox")
        let store = GuiStore()
        let root = make(store, .screenGui, in: GuiStore.playerGui)
        let big = make(store, .textLabel, in: root) { $0.size = UDim2(xOffset: 300, yOffset: 80); $0.text = "Hi"; $0.textScaled = true }
        let small = make(store, .textLabel, in: root) { $0.size = UDim2(xOffset: 60, yOffset: 20); $0.text = "Hello there"; $0.textScaled = true }
        check("TextScaled fits the text to its box", (placed(store, big)?.textSize ?? 0) > 50
              && (placed(store, small)?.textSize ?? 99) < 14, "\(placed(store, big)?.textSize ?? 0) \(placed(store, small)?.textSize ?? 0)")
        check("fonts map onto system designs", GuiFont.style("Code").design == .monospaced
              && GuiFont.style("GothamBold").weight == .bold && GuiFont.style("Garamond").design == .serif)

        let box = make(store, .textBox, in: root) { $0.text = "helo"; $0.clearTextOnFocus = false }
        store.focus(box)
        check("focusing puts the caret at the end", store.cursor == 4)
        store.moveCursor(by: -1)
        store.type("l")
        check("typing goes in at the caret", store.object(box)?.text == "hello" && store.cursor == 4)
        store.moveCursor(toEnd: false)
        store.deleteForward()
        store.type("H")
        check("Home, forward delete", store.object(box)?.text == "Hello")
        store.selectAll()
        check("⌘A selects it all, for ⌘C", store.selectedText == "Hello")
        store.paste("multi\nline")
        check("typing or pasting replaces what is selected, on one line", store.object(box)?.text == "multi line")
        store.update(box) { $0.textEditable = false }
        store.type("x")
        check("a box that isn't TextEditable can't be typed in", store.object(box)?.text == "multi line")
    }

    // MARK: - Luau

    private static func testLuau(_ check: Checker) {
        print("\nGUI: the new classes from Luau")
        let model = SceneModel()
        model.scripts = []
        var part = Part()
        part.name = "Sign"
        part.position = Vec3(0, 5, -10)
        model.parts = [part]
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterPlayer
        script.source = """
        local player = game:GetService("Players").LocalPlayer
        local screen = Instance.new("ScreenGui", player.PlayerGui)
        screen.DisplayOrder = 3
        local scroller = Instance.new("ScrollingFrame", screen)
        scroller.Size = UDim2.fromOffset(200, 100)
        scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroller.CanvasSize = UDim2.new()
        local list = Instance.new("UIListLayout", scroller)
        list.Padding = UDim.new(0, 4)
        list.SortOrder = Enum.SortOrder.LayoutOrder
        for i = 1, 3 do
        \tlocal row = Instance.new("TextLabel", scroller)
        \trow.Size = UDim2.new(1, 0, 0, 30)
        \trow.LayoutOrder = i
        \trow.Font = Enum.Font.GothamBold
        \trow.TextYAlignment = Enum.TextYAlignment.Top
        \trow.TextStrokeTransparency = 0.5
        end
        local label = scroller:GetChildren()[2]
        print("list", list.Padding.Offset, list.SortOrder.Name, label.Font.Name, label.TextYAlignment.Name,
        \tlabel.AbsoluteSize.Y, scroller.AbsoluteSize.X)
        local image = Instance.new("ImageButton", screen)
        image.Image = "studio://Logo"
        image.ScaleType = Enum.ScaleType.Fit
        print("image", image.Image, image.ScaleType.Name, image:IsA("GuiObject"))
        local sign = Instance.new("BillboardGui", player.PlayerGui)
        sign.Adornee = workspace.Sign
        sign.StudsOffset = Vector3.new(0, 3, 0)
        sign.Size = UDim2.fromOffset(100, 40)
        local text = Instance.new("TextLabel", sign)
        text.Name = "SignText"
        text.Size = UDim2.fromScale(1, 1)
        local head = player.Character:WaitForChild("Head")
        local over = Instance.new("BillboardGui", player.PlayerGui)
        over.Adornee = head
        print("billboard", sign.Adornee == workspace.Sign, over.Adornee == head, sign.StudsOffset.Y)
        print("wrong", pcall(function() label.AbsoluteSize = Vector2.new(1, 1) end),
        \tpcall(function() label.Font = "Nope" end))
        local box = Instance.new("TextBox", screen)
        box.ClearTextOnFocus = false
        box.Text = "abc"
        box:CaptureFocus()
        box.CursorPosition = 2
        print("cursor", box.CursorPosition)
        """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var elapsed: Float = 0
        while elapsed < 0.2 { session.step(dt: frame); elapsed += frame }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let said = session.console.lines.filter { $0.kind == .output }.map(\.text)
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("ScrollingFrame, UIListLayout and the new text properties from Luau",
              said.contains("list 4 LayoutOrder GothamBold Top 30 200"), "\(said) \(errors)")
        check("ImageButton", said.contains("image studio://Logo Fit true"), "\(said)")
        check("a BillboardGui over a part, or a character's head", said.contains("billboard true true 3"), "\(said)")
        check("read-only and wrong values are errors", said.contains { $0.hasPrefix("wrong false false") }, "\(said)")
        check("the caret from Luau", said.contains("cursor 2") && session.gui.cursor == 1, "\(said)")
        // The sign, moved to where the camera looks.
        let camera = session.renderCamera
        let spot = camera.target + normalize(camera.target - camera.position) * 10
        model.update(id: part.id) { $0.position = spot }
        let sign = session.gui.objects.values.first { $0.name == "SignText" }
        let at = session.screenPoint(of: spot + Vec3(0, 3, 0), in: screen)
        let drawn = sign.flatMap { object in session.gui.layout(in: screen).first { $0.id == object.id } }
        check("the BillboardGui is drawn over its part, raised by StudsOffset",
              drawn.map { item in at.map { abs(item.frame.midX - $0.x) < 1 && abs(item.frame.midY - $0.y) < 1 } ?? false } == true
              && drawn?.frame.width == 100, "\(String(describing: drawn?.frame)) \(String(describing: at))")
        check("none of it raised an error", errors.isEmpty, errors.joined(separator: " | "))
        session.stop()
    }

    // MARK: - StarterGui

    /// A scene with a ScreenGui in StarterGui: a title, a button, and a LocalScript.
    static func starterGuiScene(_ model: SceneModel, resets: Bool = true) -> (screen: UUID, button: UUID) {
        let screen = model.addGuiObject(.screenGui, in: nil)!
        model.renameGuiObject(screen, to: "Hud")
        model.setGuiProperty(screen, "resetonspawn", .bool(resets))
        let title = model.addGuiObject(.textLabel, in: screen)!
        model.renameGuiObject(title, to: "Title")
        model.setGuiProperty(title, "text", .string("Welcome"))
        model.setGuiProperty(title, "position", .list([.number(0.5), .number(-100), .number(0), .number(10)]))
        let button = model.addGuiObject(.textButton, in: screen)!
        model.renameGuiObject(button, to: "Go")
        let script = model.addScript(parentID: screen, host: .starterGui)
        model.updateScript(id: script) {
            $0.source = """
            local gui = script.Parent
            local player = game:GetService("Players").LocalPlayer
            print("hud for " .. player.Name .. ": " .. gui.Title.Text .. " " .. gui.ClassName)
            gui.Go.MouseButton1Click:Connect(function()
            \tprint("go pressed by " .. player.Name)
            end)
            """
        }
        return (screen, button)
    }

    private static func testStarterGui(_ check: Checker) {
        print("\nGUI: StarterGui")
        let model = SceneModel()
        model.scripts = []
        model.starterGui = []
        let (screen, button) = starterGuiScene(model)
        check("GUI objects are made in StarterGui, one inside another",
              model.guiChildren(of: nil).map(\.id) == [screen] && model.guiChildren(of: screen).count == 2)
        check("…a ScreenGui only at the top, and nothing else there",
              model.addGuiObject(.frame, in: nil) == nil && model.addGuiObject(.screenGui, in: screen) == nil)
        check("…with only what was changed kept", model.guiObject(id: button)?.properties.keys.sorted() == ["position"])
        let saved = try? JSONEncoder().encode(model.state)
        let loaded = saved.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("StarterGui is saved", loaded?.starterGui == model.starterGui)
        model.undo()
        check("…and undone", model.starterGui.count == 3 && model.scripts.last?.source.contains("hud for") != true)
        model.redo()

        let session = EditorSession(model: model)
        let title = model.guiChildren(of: screen).first { $0.name == "Title" }!
        model.selectedGui = title.id
        let preview = session.guiPreview.layout(in: screen2)
        check("Studio previews StarterGui over the viewport, the selected object outlined",
              preview.contains { $0.object.text == "Welcome" && abs($0.frame.midX - 400) < 1 }
              && session.guiPreview.highlighted == preview.first { $0.object.text == "Welcome" }?.id)

        let play = PlayController(model: model, console: ScriptConsole())
        play.playerName = "Robin"
        play.start()
        var elapsed: Float = 0
        while elapsed < 0.2 { play.step(dt: frame); elapsed += frame }
        func said() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return play.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        let copy = play.guiCopies[screen]
        check("play copies it into the player's PlayerGui", copy != nil && play.gui.object(copy!)?.parent == GuiStore.playerGui
              && play.gui.objects.values.contains { $0.text == "Welcome" })
        check("…and runs its LocalScript there, script.Parent the copy",
              said().contains("hud for Robin: Welcome ScreenGui"), "\(said()) \(play.console.lines.filter { $0.kind == .error }.map(\.text))")
        play.gui.click(play.guiCopies[button]!)
        play.step(dt: frame)
        check("…where it hears clicks", said().contains("go pressed by Robin"))

        play.respawnRequested = true
        elapsed = 0
        while elapsed < 0.2 { play.step(dt: frame); elapsed += frame }
        check("a new character gets a fresh copy (ResetOnSpawn), its script run again",
              play.guiCopies[screen] != copy && said().filter { $0.hasPrefix("hud for") }.count == 2
              && play.gui.objects.values.filter { $0.name == "Hud" }.count == 1)
        play.stop()

        let keeper = SceneModel()
        keeper.scripts = []
        let (kept, _) = starterGuiScene(keeper, resets: false)
        let still = PlayController(model: keeper, console: ScriptConsole())
        still.start()
        elapsed = 0
        while elapsed < 0.1 { still.step(dt: frame); elapsed += frame }
        let first = still.guiCopies[kept]
        still.respawnRequested = true
        elapsed = 0
        while elapsed < 0.2 { still.step(dt: frame); elapsed += frame }
        check("…but one with ResetOnSpawn off stays as it was", still.guiCopies[kept] == first && first != nil)
        still.stop()
    }

    private static let screen2 = CGSize(width: 800, height: 600)

    private static func testStarterGuiInMultiplayer(_ check: Checker) {
        print("\nGUI: StarterGui in a network game")
        var buttonID: UUID?
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            buttonID = starterGuiScene(model).button
        }), let robin = hosting.player, let sam = joining.player, let buttonID else {
            check("two players share a game", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        let samSaid = sam.console.lines.filter { $0.kind == .output }.map(\.text)
        check("each player gets their own copy, its LocalScript running in their game",
              robin.console.lines.map(\.text).contains("hud for Robin: Welcome ScreenGui")
              && samSaid.contains("hud for Sam: Welcome ScreenGui"), "\(samSaid)")
        sam.gui.click(sam.guiCopies[buttonID]!)
        LANSelfTest.run([hosting, joining], seconds: 0.1)
        check("…and clicks on one player's GUI are theirs alone",
              sam.console.lines.map(\.text).contains("go pressed by Sam")
              && !robin.console.lines.map(\.text).contains("go pressed by Sam"))
        joining.leaveGame()
        hosting.leaveGame()
    }
}
