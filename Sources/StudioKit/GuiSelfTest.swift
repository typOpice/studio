import AppKit
import simd

/// Verification for the screen GUI and chat: where objects are placed, the Luau GUI API
/// over them, clicking and typing, and the default ChatScript built from it. Chat
/// between players over the network is in LANSelfTest.
enum GuiSelfTest {

    static func run(check: Checker) {
        testLayout(check)
        testStore(check)
        testLuauGui(check)
        testTyping(check)
        testTextChatService(check)
        testChatScript(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func world(chat: Bool = true) -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.starterPlayer = StarterPlayerSettings()
        add(model, "", name: "ControlScript", host: .starterPlayer, enabled: false)
        if !chat { add(model, "", name: "ChatScript", host: .starterPlayer, enabled: false) }
        return model
    }

    private static func add(_ model: SceneModel, _ source: String, name: String = "Test",
                            host: ScriptHost = .scene, enabled: Bool = true) {
        var script = ScriptObject.blank(language: .luau)
        script.name = name
        script.source = source
        script.host = host
        script.enabled = enabled
        model.scripts.append(script)
    }

    private static func play(_ model: SceneModel, as name: String = "Robin") -> PlayController {
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = name
        session.start()
        run(session, seconds: 0.1)
        return session
    }

    private static func run(_ session: PlayController, seconds: Float = 0.05) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
    }

    private static func lines(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func problems(_ session: PlayController) -> String {
        lines(session, .error).joined(separator: " | ")
    }

    private static func named(_ name: String, in store: GuiStore) -> GuiObject? {
        store.objects.values.first { $0.name == name }
    }

    /// Typing as the keyboard would: each character, then Return.
    static func type(_ text: String, into session: PlayController, thenPress keyCode: UInt16 = 36) {
        for character in text { session.typeKey(keyCode: 0, characters: String(character)) }
        session.typeKey(keyCode: keyCode, characters: "")
    }

    /// What the default chat window holds, oldest first.
    static func chatShown(_ session: PlayController) -> [String] {
        guard let log = session.gui.objects.values.first(where: { $0.name == "Log" }) else { return [] }
        return session.gui.children(of: log.id).compactMap { session.gui.object($0) }
            .filter { $0.kind == .textLabel }.sorted { $0.layoutOrder < $1.layoutOrder }.map(\.text)
    }

    /// A chat bubble's text, and where it is on an 800 × 600 screen.
    static func bubble(_ session: PlayController) -> (text: String, frame: CGRect)? {
        guard let board = session.gui.objects.values.first(where: { $0.name == "Bubble" }),
              let card = session.gui.children(of: board.id).compactMap({ session.gui.object($0) })
                .first(where: { $0.name == "Text" }),
              let placed = session.gui.layout(in: CGSize(width: 800, height: 600)).first(where: { $0.id == card.id })
        else { return nil }
        return (card.text, placed.frame)
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    // MARK: - Layout

    private static func testLayout(_ check: Checker) {
        print("\nGUI: layout")
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        var object = GuiObject(id: 1, kind: .frame)
        object.position = UDim2(xScale: 0.5, xOffset: 0, yScale: 1, yOffset: -20)
        object.size = UDim2(xScale: 0, xOffset: 200, yScale: 0.1, yOffset: 0)
        object.anchorPoint = SIMD2(0.5, 1)
        check("Position, Size and AnchorPoint place an object as Roblox does",
              same(GuiStore.frame(of: object, in: screen), CGRect(x: 300, y: 520, width: 200, height: 60)),
              "\(GuiStore.frame(of: object, in: screen))")
        object.size = UDim2(xScale: 0, xOffset: -10, yScale: 0, yOffset: 5)
        check("a negative size draws nothing rather than inside out",
              GuiStore.frame(of: object, in: screen).width == 0)

        let store = GuiStore()
        let gui = store.create(.screenGui)
        let panel = store.create(.frame)
        let label = store.create(.textLabel)
        let corner = store.create(.uiCorner)
        store.setParent(gui, to: GuiStore.playerGui)
        store.setParent(panel, to: gui)
        store.setParent(label, to: panel)
        store.setParent(corner, to: panel)
        store.update(panel) {
            $0.position = UDim2(xScale: 0, xOffset: 100, yScale: 0, yOffset: 50)
            $0.size = UDim2(xScale: 0, xOffset: 200, yScale: 0, yOffset: 40)
        }
        store.update(label) {
            $0.position = UDim2(xScale: 0.5, xOffset: 0, yScale: 0, yOffset: 0)
            $0.size = UDim2(xScale: 0.5, xOffset: 0, yScale: 1, yOffset: 0)
        }
        store.update(corner) { $0.cornerScale = 0.5; $0.cornerOffset = 0 }
        var placed = store.layout(in: screen.size)
        check("children are placed inside their parent",
              placed.map(\.id) == [panel, label] && placed[1].frame == CGRect(x: 200, y: 50, width: 100, height: 40),
              "\(placed.map(\.frame))")
        check("a UICorner rounds its parent, scale by the shorter side", placed[0].cornerRadius == 20
              && placed[1].cornerRadius == 0)

        let front = store.create(.frame)
        store.setParent(front, to: gui)
        store.update(front) { $0.zIndex = 5 }
        let back = store.create(.frame)
        store.setParent(back, to: gui)
        placed = store.layout(in: screen.size)
        check("siblings draw by ZIndex, then in the order they were made",
              placed.map(\.id) == [panel, label, back, front], "\(placed.map(\.id))")

        let padding = store.create(.uiPadding)
        store.setParent(padding, to: panel)
        store.update(padding) {
            $0.paddingLeft = SIMD2(0, 10)
            $0.paddingRight = SIMD2(0.1, 0)
            $0.paddingTop = SIMD2(0, 4)
            $0.paddingBottom = SIMD2(0.25, 0)
        }
        placed = store.layout(in: screen.size)
        check("a UIPadding keeps its parent's text and children in from the edges",
              same(placed[0].content, CGRect(x: 110, y: 54, width: 170, height: 26))
              && same(placed[1].frame, CGRect(x: 195, y: 54, width: 85, height: 26))
              && same(placed[1].content, placed[1].frame), "\(placed[0].content) \(placed[1].frame)")
        store.destroy(padding)

        store.update(panel) { $0.visible = false }
        check("an invisible object hides what is inside it", !store.layout(in: screen.size).contains { $0.id == label })
        store.update(gui) { $0.enabled = false }
        check("a disabled ScreenGui draws nothing", store.layout(in: screen.size).isEmpty)
        store.update(gui) { $0.enabled = true }
        let loose = store.create(.frame)
        store.setParent(loose, to: GuiStore.playerGui)
        check("only what is in a ScreenGui is drawn", !store.layout(in: screen.size).contains { $0.id == loose })
    }

    private static func testStore(_ check: Checker) {
        print("\nGUI: objects, focus and clicks")
        let store = GuiStore()
        let gui = store.create(.screenGui)
        let panel = store.create(.frame)
        let box = store.create(.textBox)
        let button = store.create(.textButton)
        store.setParent(panel, to: gui)
        store.setParent(box, to: panel)
        store.setParent(button, to: panel)
        check("an object can't be put inside itself", !store.setParent(gui, to: box) && store.object(gui)?.parent == nil)

        var focusedHappened = false
        store.onFocus = { focusedHappened = true }
        store.update(box) { $0.text = "old" }
        store.click(box)
        check("clicking a TextBox gives it the keyboard, clearing it", store.focused == box && focusedHappened
              && store.object(box)?.text == "")
        store.type("hé!\n\u{7f}")
        store.backspace()
        check("typing adds printable characters; Delete takes the last back", store.object(box)?.text == "hé")
        store.releaseFocus(enterPressed: true)
        store.click(button)
        let events = store.drainEvents()
        let expected: [ScriptValue] = [
            .list([.string("Gui"), .number(Double(box)), .string("Focused")]),
            .list([.string("Gui"), .number(Double(box)), .string("FocusLost"), .bool(true)]),
            .list([.string("Gui"), .number(Double(button)), .string("Click")]),
        ]
        check("focus, Return and a button click reach the scripts", events == expected, "\(events)")
        check("…once", store.drainEvents().isEmpty)

        store.focus(box)
        store.destroy(panel)
        check("destroying an object takes what is inside it, and the keyboard back",
              store.object(box) == nil && store.object(button) == nil && store.focused == nil
              && store.children(of: gui).isEmpty)
    }

    // MARK: - Luau

    private static func testLuauGui(_ check: Checker) {
        print("\nGUI: the Luau API")
        let model = world(chat: false)
        add(model, """
        local player = game:GetService("Players").LocalPlayer
        local screen = Instance.new("ScreenGui")
        screen.Name = "Hud"
        local panel = Instance.new("Frame", screen)
        panel.Name = "Panel"
        panel.AnchorPoint = Vector2.new(0.5, 0)
        panel.Position = UDim2.new(0.5, 0, 0, 20)
        panel.Size = UDim2.fromOffset(200, 100)
        panel.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
        Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
        local padding = Instance.new("UIPadding", panel)
        padding.PaddingLeft = UDim.new(0, 8)
        padding.PaddingTop = UDim.new(0.25, 0)
        print("padding", padding.PaddingLeft.Offset, padding.PaddingTop.Scale, padding.PaddingBottom == UDim.new(0, 0))

        local button = Instance.new("TextButton")
        button.Name = "Go"
        button.Text = "Go!"
        button.Parent = panel
        local clicks = 0
        button.MouseButton1Click:Connect(function()
        \tclicks += 1
        \tprint("clicked " .. clicks)
        end)
        button.Activated:Connect(function()
        \tprint("activated")
        end)

        local box = Instance.new("TextBox", panel)
        box.Name = "Entry"
        box.PlaceholderText = "Name?"
        box.Focused:Connect(function()
        \tprint("focused")
        end)
        box.FocusLost:Connect(function(enterPressed)
        \tprint("typed " .. box.Text .. " " .. tostring(enterPressed))
        end)
        screen.Parent = player.PlayerGui

        print("found", player.PlayerGui:FindFirstChild("Hud") == screen, player.PlayerGui.Hud.Panel.Go.Text)
        print("read", panel.Position == UDim2.new(0.5, 0, 0, 20), panel.Size.X.Offset, panel.AnchorPoint.X,
        \tbutton.TextXAlignment == Enum.TextXAlignment.Center, typeof(panel.Size), tostring(panel.Size))
        print("kinds", button:IsA("GuiButton"), button:IsA("GuiObject"), screen:IsA("GuiObject"),
        \tscreen.ClassName, #panel:GetChildren(), button.Parent == panel)
        print("wrong", pcall(function() panel.Text = "x" end), pcall(function() panel.Size = 5 end),
        \tpcall(function() screen.Parent = panel end))
        local gone = Instance.new("TextLabel", panel)
        gone:Destroy()
        print("destroyed", panel:FindFirstChild("TextLabel") == nil, #panel:GetChildren())
        """)
        let session = play(model)
        let said = lines(session)
        check("GUI objects are made, named and found under the PlayerGui",
              said.contains("found true Go!") && problems(session).isEmpty, "\(said) \(problems(session))")
        check("their properties read back as UDim2, Vector2 and enums",
              said.contains("read true 200 0.5 true UDim2 {0, 200}, {0, 100}"), "\(said)")
        check("IsA knows the GUI classes", said.contains("kinds true true false ScreenGui 4 true"), "\(said)")
        check("UIPadding's edges are UDims", said.contains("padding 8 0.25 true"), "\(said)")
        check("a wrong property, a wrong type and a loop are errors",
              said.first { $0.hasPrefix("wrong") }.map { !$0.contains("true") } ?? false, "\(said)")
        check("Destroy removes an object", said.contains("destroyed true 4"), "\(said)")

        let placed = session.gui.layout(in: CGSize(width: 800, height: 600))
        let panel = placed.first { $0.object.name == "Panel" }
        check("the host places what scripts made",
              panel?.frame == CGRect(x: 300, y: 20, width: 200, height: 100) && panel?.cornerRadius == 12
              && panel.map { same($0.content, CGRect(x: 308, y: 45, width: 192, height: 75)) } == true
              && panel?.object.backgroundColor == Vec3(1, 0, 0), "\(String(describing: panel?.frame))")

        guard let button = named("Go", in: session.gui), let box = named("Entry", in: session.gui) else {
            check("the button and box exist", false)
            return
        }
        session.gui.click(button.id)
        session.gui.click(button.id)
        run(session)
        let clicked = lines(session)
        check("a click fires MouseButton1Click and Activated",
              clicked.filter { $0.hasPrefix("clicked") } == ["clicked 1", "clicked 2"]
              && clicked.filter { $0 == "activated" }.count == 2, "\(clicked)")

        session.gui.click(box.id)
        type("Sam", into: session)
        run(session)
        check("a TextBox reports focus and what was typed, and that Return ended it",
              lines(session).suffix(2) == ["focused", "typed Sam true"], "\(lines(session).suffix(3))")
        session.stop()
    }

    private static func testTyping(_ check: Checker) {
        print("\nGUI: typing keeps keys from the game")
        let model = world(chat: false)
        add(model, """
        local UserInputService = game:GetService("UserInputService")
        local box = Instance.new("TextBox")
        box.Name = "Entry"
        local screen = Instance.new("ScreenGui")
        box.Parent = screen
        screen.Parent = game:GetService("Players").LocalPlayer.PlayerGui
        UserInputService.InputBegan:Connect(function(input)
        \tif input.KeyCode == Enum.KeyCode.T then
        \t\tbox:CaptureFocus()
        \telse
        \t\tprint("key " .. input.KeyCode.Name)
        \tend
        end)
        box.FocusLost:Connect(function(enterPressed)
        \tprint("lost " .. box.Text .. " " .. tostring(enterPressed))
        end)
        game:GetService("RunService").Heartbeat:Connect(function()
        \tif UserInputService:IsKeyDown(Enum.KeyCode.W) then
        \t\tprint("holding W")
        \tend
        end)
        """)
        let session = play(model)
        session.key("W", pressed: true)
        run(session, seconds: 1.0 / 60)
        session.key("T", pressed: true)
        run(session, seconds: 2.0 / 60)
        session.key("T", pressed: false)
        let before = lines(session).count
        check("a script can hand a TextBox the keyboard", session.isTyping)
        check("…which lets go of the keys the game was holding", !session.heldKeys.contains("W"))
        run(session)
        check("…so nothing is held down behind the box", !lines(session).dropFirst(before).contains("holding W"))

        // Keys as the window delivers them, to the game's view.
        let view = StudioMTKView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        // Hidden while the player is set, so the test never captures the real pointer.
        view.showsWorld = false
        view.player = session
        view.showsWorld = true
        session.gui.releaseFocus(enterPressed: false)
        run(session)
        window.makeFirstResponder(nil)
        session.gui.click(named("Entry", in: session.gui)?.id ?? 0)
        check("clicking a TextBox gives the game's view the keyboard",
              session.isTyping && window.firstResponder === view)
        run(session)
        let typedFrom = lines(session).count
        func press(_ characters: String, _ keyCode: UInt16) {
            for phase in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: phase, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: characters, charactersIgnoringModifiers: characters,
                                             isARepeat: false, keyCode: keyCode)!
                if phase == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
            }
        }
        for (character, code) in [("w", 13), ("a", 0), ("s", 1), ("d", 2), ("`", 50)] as [(String, UInt16)] {
            press(character, code)
        }
        press("\u{7F}", 51)
        press("\u{1B}", 53)
        run(session)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let after = lines(session).dropFirst(typedFrom)
        check("while typing, keys type rather than play", !after.contains { $0.hasPrefix("key") }, "\(Array(after))")
        check("Escape ends typing, not by Return", after.last == "lost wasd false" && !session.isTyping,
              "\(Array(after.suffix(2)))")
        press("w", 13)
        run(session)
        check("…and then keys play again", lines(session).last == "key W", "\(lines(session).suffix(2))")
        view.player = nil
        window.contentView = nil
        session.stop()
    }

    private static func testTextChatService(_ check: Checker) {
        print("\nGUI: TextChatService")
        let model = world(chat: false)
        add(model, """
        local TextChatService = game:GetService("TextChatService")
        TextChatService.MessageReceived:Connect(function(message)
        \tprint(`heard {message.TextSource.Name}: {message.Text}`)
        end)
        local general = TextChatService.TextChannels:WaitForChild("RBXGeneral")
        general:SendAsync("  hello  ")
        general:SendAsync("   ")
        general:SendAsync(string.rep("x", 500))
        print("channel", general.Name, pcall(function() general:SendAsync(5) end))
        """)
        var sent: [String] = []
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = "Robin"
        session.sendChat = { sent.append($0) }
        session.start()
        run(session, seconds: 0.1)
        let said = lines(session)
        check("SendAsync is heard by this player too, as MessageReceived",
              said.contains("heard Robin: hello") && problems(session).isEmpty, "\(said) \(problems(session))")
        check("…trimmed; blank messages are dropped; long ones cut short",
              sent == ["hello", String(repeating: "x", count: PlayController.longestChat)], "\(sent.map(\.count))")
        check("the channel is RBXGeneral, and only text is sent",
              said.contains { $0.hasPrefix("channel RBXGeneral false") }, "\(said)")
        session.receiveChat(from: "Sam", text: "hi Robin")
        run(session)
        check("messages from others arrive the same way", lines(session).contains("heard Sam: hi Robin"))
        session.stop()
    }

    // MARK: - The default chat

    private static func testChatScript(_ check: Checker) {
        print("\nGUI: the default ChatScript")
        var sent: [String] = []
        let model = world()
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerName = "Robin"
        session.sendChat = { sent.append($0) }
        session.start()
        run(session, seconds: 0.1)
        guard let bar = named("ChatBar", in: session.gui), named("Chat", in: session.gui)?.kind == .screenGui else {
            check("every player gets a chat window, built from GUI objects", false, problems(session))
            return
        }
        check("every player gets a chat window, built from GUI objects",
              problems(session).isEmpty && bar.kind == .textBox && bar.placeholderText == "Press / to chat",
              problems(session))
        let placed = session.gui.layout(in: CGSize(width: 800, height: 600))
        let window = named("Window", in: session.gui).flatMap { window in placed.first { $0.id == window.id }?.frame }
        let barFrame = placed.first { $0.id == bar.id }?.frame
        check("…in the top-left corner, with no gap above it (nothing else is drawn there)",
              window?.origin == CGPoint(x: 16, y: 16) && barFrame.map { $0.minY == (window?.maxY ?? 0) + 8 } == true,
              "\(String(describing: window)) \(String(describing: barFrame))")

        session.key("Slash", pressed: true)
        run(session)
        session.key("Slash", pressed: false)
        check("/ opens the chat bar", session.gui.focused == bar.id)
        type("hello there", into: session)
        run(session)
        check("Return sends what was typed, and it shows as Name: text",
              chatShown(session) == ["Robin: hello there"] && sent == ["hello there"], "\(chatShown(session))")
        check("…leaving the bar empty and the game with the keys", !session.isTyping
              && session.gui.object(bar.id)?.text == "")

        session.gui.click(bar.id)
        type("never mind", into: session, thenPress: 53)
        run(session)
        check("Escape closes the bar without sending", sent.count == 1 && session.gui.object(bar.id)?.text == "")

        let spoken = bubble(session)
        let head = session.screenPoint(of: session.character.position + Vec3(0, 4.65, 0),
                                       in: CGSize(width: 800, height: 600))
        check("what's said shows in a bubble over the speaker's head, a BillboardGui",
              spoken?.text == "hello there"
              && head.map { spoken!.frame.maxY < $0.y && abs(spoken!.frame.midX - $0.x) < 40 } == true,
              "\(String(describing: spoken)) \(String(describing: head))")
        run(session, seconds: 8.2)
        check("…for a while", bubble(session) == nil)

        for number in 1...105 { session.receiveChat(from: "Sam", text: "line \(number)") }
        run(session)
        let shown = chatShown(session)
        check("the log keeps the last hundred messages, oldest first",
              shown.count == 100 && shown.first == "Sam: line 6" && shown.last == "Sam: line 105", "\(shown.count)")
        let log = session.gui.objects.values.first { $0.name == "Log" }!
        let atBottom = session.gui.canvasPosition(of: log.id)
        check("…scrolled to the newest", atBottom.y > 1000, "\(atBottom)")
        let over = session.gui.absoluteFrame(of: log.id).map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        check("…and the wheel scrolls back through them",
              session.gui.scroll(at: over, by: CGSize(width: 0, height: 300))
              && session.gui.canvasPosition(of: log.id).y < atBottom.y - 200)
        session.receiveChat(from: "Sam", text: String(repeating: "word ", count: 40))
        run(session)
        let wrapped = session.gui.objects.values.filter { $0.name == "Message" }.max { $0.layoutOrder < $1.layoutOrder }!
        check("a long message wraps onto more lines", (session.gui.absoluteFrame(of: wrapped.id)?.height ?? 0) > 40,
              "\(String(describing: session.gui.absoluteFrame(of: wrapped.id)))")
        session.stop()

        // It is an ordinary script: the editor lists it, and an edited copy replaces it.
        let custom = world()
        check("the editor offers ChatScript in StarterPlayerScripts",
              custom.defaultScripts(host: .starterPlayer).contains { $0.name == "ChatScript" })
        if let copy = custom.copyCoreScript(named: "ChatScript") {
            custom.updateScript(id: copy) {
                $0.source = $0.source.replacingOccurrences(of: "\"Press / to chat\"", with: "\"Say something\"")
                    .replacingOccurrences(of: "local KEPT = 100", with: "local KEPT = 3")
            }
        }
        let edited = play(custom)
        for number in 1...5 { edited.receiveChat(from: "Sam", text: "line \(number)") }
        run(edited)
        check("…and an edited copy changes the chat",
              named("ChatBar", in: edited.gui)?.placeholderText == "Say something"
              && chatShown(edited) == ["Sam: line 3", "Sam: line 4", "Sam: line 5"]
              && !custom.defaultScripts(host: .starterPlayer).contains { $0.name == "ChatScript" },
              "\(chatShown(edited)) \(problems(edited))")
        edited.stop()

        let quiet = world()
        add(quiet, "", name: "ChatScript", host: .starterPlayer, enabled: false)
        let without = play(quiet)
        without.key("Slash", pressed: true)
        run(without)
        check("a disabled ChatScript in StarterPlayerScripts removes the chat",
              !without.gui.objects.values.contains { ["Chat", "ChatBar", "Window"].contains($0.name) }
              && !without.isTyping)
        without.stop()
    }
}
