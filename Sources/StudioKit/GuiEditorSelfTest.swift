import AppKit
import SwiftUI

/// Verification for the GUI tab and the modifiers it brought: UIStroke, UIGradient,
/// UIGridLayout, UIAspectRatioConstraint, UISizeConstraint and UITextSizeConstraint —
/// laid out, drawn (rendered and read back), from Luau, saved, and copied to a joined
/// player — then the tab itself: inserting where the selection says, aligning, filling,
/// ordering, duplicating, units, the device preview, and editing in the view by dragging,
/// snapping and the arrow keys, down to real mouse events in a window. The editing is
/// Studio's alone (it changes StarterGui, which the multiplayer test here covers), so it
/// has no network side of its own.
enum GuiEditorSelfTest {

    static func run(check: Checker) {
        testLayout(check)
        testDrawing(check)
        testLuau(check)
        testSaving(check)
        testTwoPlayers(check)
        testInserting(check)
        testArranging(check)
        testPreview(check)
        testDragging(check)
        testKeys(check)
        testWindow(check)
    }

    // MARK: - A store to lay out

    private final class Screen {
        let store = GuiStore()
        let root: Int

        init() {
            root = store.create(.screenGui)
            store.setParent(root, to: GuiStore.playerGui)
        }

        @discardableResult
        func add(_ kind: GuiObject.Kind, in parent: Int? = nil, _ values: [String: ScriptValue] = [:]) -> Int {
            let id = store.create(kind)
            store.setParent(id, to: parent ?? root)
            store.update(id) { object in
                for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                    _ = PlayController.setGuiProperty(&object, key, value)
                }
            }
            return id
        }

        func frame(_ id: Int, in size: CGSize = CGSize(width: 800, height: 600)) -> CGRect? {
            store.layout(in: size).first { $0.id == id }?.frame
        }
    }

    private static func udim2(_ xs: Double, _ xo: Double, _ ys: Double, _ yo: Double) -> ScriptValue {
        .list([.number(xs), .number(xo), .number(ys), .number(yo)])
    }

    private static func pair(_ a: Double, _ b: Double) -> ScriptValue { .list([.number(a), .number(b)]) }

    private static func near(_ a: CGRect?, _ b: CGRect, _ tolerance: CGFloat = 0.51) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    // MARK: - Layout

    private static func testLayout(_ check: Checker) {
        print("\nGUI modifiers: layout")
        let screen = Screen()
        let holder = screen.add(.frame, [ "size": udim2(0, 400, 0, 300)])
        screen.add(.uiGridLayout, in: holder, ["cellsize": udim2(0, 100, 0, 50), "cellpadding": udim2(0, 10, 0, 10)])
        let cells = (0..<5).map { index in
            screen.add(.frame, in: holder, ["size": udim2(0, 10, 0, 10), "position": udim2(0, 300, 0, 300),
                                            "layoutorder": .number(Double(index))])
        }
        check("a UIGridLayout puts its parent's children in cells, as many to a row as fit",
              near(screen.frame(cells[0]), CGRect(x: 0, y: 0, width: 100, height: 50))
              && near(screen.frame(cells[2]), CGRect(x: 220, y: 0, width: 100, height: 50))
              && near(screen.frame(cells[3]), CGRect(x: 0, y: 60, width: 100, height: 50)),
              "\(cells.map { screen.frame($0) ?? .zero })")
        let grid = screen.store.children(of: holder).first { screen.store.object($0)?.kind == .uiGridLayout }!
        screen.store.update(grid) { _ = PlayController.setGuiProperty(&$0, "filldirectionmaxcells", .number(2)) }
        check("…no more to a row than FillDirectionMaxCells", near(screen.frame(cells[2]), CGRect(x: 0, y: 60, width: 100, height: 50)))
        screen.store.update(grid) {
            _ = PlayController.setGuiProperty(&$0, "filldirectionmaxcells", .number(0))
            _ = PlayController.setGuiProperty(&$0, "horizontalalignment", .string("Center"))
        }
        check("…the block of cells aligned in the parent", near(screen.frame(cells[0]), CGRect(x: 40, y: 0, width: 100, height: 50)))
        screen.store.update(grid) {
            _ = PlayController.setGuiProperty(&$0, "horizontalalignment", .string("Left"))
            _ = PlayController.setGuiProperty(&$0, "startcorner", .string("TopRight"))
        }
        check("…started from StartCorner", near(screen.frame(cells[0]), CGRect(x: 220, y: 0, width: 100, height: 50))
              && near(screen.frame(cells[3]), CGRect(x: 220, y: 60, width: 100, height: 50)))
        screen.store.update(grid) {
            _ = PlayController.setGuiProperty(&$0, "startcorner", .string("TopLeft"))
            _ = PlayController.setGuiProperty(&$0, "filldirection", .string("Vertical"))
        }
        check("…or filling down first", near(screen.frame(cells[1]), CGRect(x: 0, y: 60, width: 100, height: 50))
              && near(screen.frame(cells[4]), CGRect(x: 0, y: 240, width: 100, height: 50)))
        screen.store.update(cells[1]) { $0.layoutOrder = 10 }
        screen.store.update(cells[0]) { $0.visible = false }
        check("…in LayoutOrder, leaving out what's hidden",
              near(screen.frame(cells[2]), CGRect(x: 0, y: 0, width: 100, height: 50)) && screen.frame(cells[0]) == nil
              && near(screen.frame(cells[1]), CGRect(x: 0, y: 180, width: 100, height: 50)))

        let box = screen.add(.frame, ["position": udim2(0.5, 0, 0.5, 0), "anchorpoint": pair(0.5, 0.5),
                                       "size": udim2(0, 200, 0, 100)])
        let aspect = screen.add(.uiAspectRatioConstraint, in: box)
        check("a UIAspectRatioConstraint fits its shape inside the Size, staying anchored",
              near(screen.frame(box), CGRect(x: 350, y: 250, width: 100, height: 100)), "\(screen.frame(box) ?? .zero)")
        screen.store.update(aspect) {
            _ = PlayController.setGuiProperty(&$0, "aspecttype", .string("ScaleWithParentSize"))
            _ = PlayController.setGuiProperty(&$0, "aspectratio", .number(2))
        }
        check("…or keeps the width and works out the height", near(screen.frame(box), CGRect(x: 300, y: 250, width: 200, height: 100)))
        screen.store.update(aspect) { _ = PlayController.setGuiProperty(&$0, "dominantaxis", .string("Height")) }
        check("…or the other way round", near(screen.frame(box), CGRect(x: 300, y: 250, width: 200, height: 100)))
        screen.store.update(aspect) { _ = PlayController.setGuiProperty(&$0, "aspectratio", .number(3)) }
        check("…at any ratio", near(screen.frame(box), CGRect(x: 250, y: 250, width: 300, height: 100)))

        let bar = screen.add(.frame, ["size": udim2(0, 500, 0, 20)])
        screen.add(.uiSizeConstraint, in: bar, ["minsize": pair(0, 40), "maxsize": pair(300, 1e9)])
        check("a UISizeConstraint holds the size between MinSize and MaxSize",
              near(screen.frame(bar), CGRect(x: 0, y: 0, width: 300, height: 40)))

        let label = screen.add(.textLabel, ["size": udim2(0, 300, 0, 100), "textscaled": .bool(true), "text": .string("Hi")])
        let limit = screen.add(.uiTextSizeConstraint, in: label, ["maxtextsize": .number(20)])
        let scaled = { screen.store.layout(in: CGSize(width: 800, height: 600)).first { $0.id == label }?.textSize ?? 0 }
        check("a UITextSizeConstraint caps TextScaled", scaled() == 20, "\(scaled())")
        screen.store.update(label) { $0.size = UDim2(xOffset: 20, yOffset: 8) }
        screen.store.update(limit) { _ = PlayController.setGuiProperty(&$0, "mintextsize", .number(30)) }
        check("…and floors it", scaled() == 30, "\(scaled())")

        let outlined = screen.add(.frame)
        let stroke = screen.add(.uiStroke, in: outlined)
        screen.add(.uiGradient, in: outlined)
        let placed = { screen.store.layout(in: CGSize(width: 800, height: 600)).first { $0.id == outlined } }
        check("a UIStroke and a UIGradient go with what they're in", placed()?.stroke != nil && placed()?.gradient != nil)
        screen.store.update(stroke) { $0.enabled = false }
        check("…unless switched off", placed()?.stroke == nil)
        check("a gradient's colour and transparency are read between keypoints",
              GuiObject.sample([GradientStop(time: 0, color: Vec3(0, 0, 0)), GradientStop(time: 1, color: Vec3(1, 1, 1))],
                               at: 0.25) == Vec3(0.25, 0.25, 0.25)
              && GuiObject.sample([SIMD2(0, 0), SIMD2(0.5, 1), SIMD2(1, 0)], at: 0.75) == 0.5)
    }

    // MARK: - Drawing

    private static func render(_ store: GuiStore, size: CGSize = CGSize(width: 700, height: 400)) -> NSBitmapImageRep? {
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: GuiLayer(store: store, interactive: false)
                .frame(width: size.width, height: size.height))
            renderer.scale = 1
            return renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
        }
    }

    private static func pixel(_ bitmap: NSBitmapImageRep?, _ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let colour = bitmap?.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0, 0) }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }

    private static func testDrawing(_ check: Checker) {
        print("\nGUI modifiers: drawn")
        let screen = Screen()
        let square = screen.add(.frame, ["position": udim2(0, 50, 0, 50), "size": udim2(0, 100, 0, 100)])
        screen.add(.uiStroke, in: square, ["color": .list([.number(1), .number(0), .number(0)]), "thickness": .number(6)])
        let label = screen.add(.textLabel, ["position": udim2(0, 50, 0, 250), "size": udim2(0, 200, 0, 50),
                                             "backgroundtransparency": .number(1), "text": .string("Hello")])
        screen.add(.uiStroke, in: label, ["color": .list([.number(1), .number(0), .number(0)]), "thickness": .number(6)])
        let across = screen.add(.frame, ["position": udim2(0, 200, 0, 50), "size": udim2(0, 200, 0, 40)])
        screen.add(.uiGradient, in: across, ["color": .list([0, 0, 0, 0, 1, 1, 1, 1].map { .number($0) })])
        let down = screen.add(.frame, ["position": udim2(0, 200, 0, 120), "size": udim2(0, 40, 0, 200)])
        screen.add(.uiGradient, in: down, ["color": .list([0, 0, 0, 0, 1, 1, 1, 1].map { .number($0) }),
                                           "rotation": .number(90)])
        let fading = screen.add(.frame, ["position": udim2(0, 450, 0, 50), "size": udim2(0, 200, 0, 40)])
        screen.add(.uiGradient, in: fading, ["transparency": .list([0, 0, 1, 1].map { .number($0) })])
        let bitmap = render(screen.store)

        let outside = pixel(bitmap, 47, 100), inside = pixel(bitmap, 100, 100), beyond = pixel(bitmap, 40, 100)
        check("a UIStroke draws round the outside of the border",
              outside.r > 0.8 && outside.b < 0.2 && outside.a > 0.9 && inside.r > 0.9 && inside.b > 0.9 && beyond.a < 0.1,
              "outside \(outside), inside \(inside), beyond \(beyond)")
        let besideText = pixel(bitmap, 47, 275)
        check("…but round a text object's text, not its box, when Contextual", besideText.a < 0.1, "\(besideText)")
        let left = pixel(bitmap, 205, 70), right = pixel(bitmap, 395, 70)
        check("a UIGradient colours the background along it", left.r < 0.2 && right.r > 0.8, "\(left) → \(right)")
        let top = pixel(bitmap, 220, 125), bottom = pixel(bitmap, 220, 315)
        check("…turned by Rotation", top.r < 0.2 && bottom.r > 0.8, "\(top) → \(bottom)")
        let solid = pixel(bitmap, 455, 70), clear = pixel(bitmap, 645, 70)
        check("…and fades it by its Transparency", solid.a > 0.9 && clear.a < 0.1, "\(solid) → \(clear)")
    }

    // MARK: - Luau

    private static func playScript(_ source: String, in model: SceneModel = emptyModel()) -> (PlayController, ScriptConsole) {
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterPlayer
        script.source = source
        model.scripts.append(script)
        let console = ScriptConsole()
        let session = PlayController(model: model, console: console)
        session.start()
        for _ in 0..<6 { session.step(dt: 1.0 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return (session, console)
    }

    private static func emptyModel() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        var controls = ScriptObject.blank(language: .luau)
        controls.name = "ControlScript"
        controls.host = .starterPlayer
        controls.enabled = false
        model.scripts = [controls]
        return model
    }

    private static func testLuau(_ check: Checker) {
        print("\nGUI modifiers: Luau")
        let (session, console) = playScript("""
        local screen = Instance.new("ScreenGui")
        local frame = Instance.new("Frame", screen)
        frame.Size = UDim2.fromOffset(200, 100)
        local stroke = Instance.new("UIStroke", frame)
        stroke.Color = Color3.new(1, 0, 0)
        stroke.Thickness = 4
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        print("stroke", stroke.Color == Color3.new(1, 0, 0), stroke.Thickness, stroke.ApplyStrokeMode.Name,
        \tstroke.LineJoinMode.Name, stroke.Enabled, stroke.Transparency, stroke:IsA("UIComponent"))

        local gradient = Instance.new("UIGradient", frame)
        gradient.Color = ColorSequence.new(Color3.new(1, 0, 0), Color3.new(0, 0, 1))
        gradient.Transparency = NumberSequence.new({
        \tNumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.5), NumberSequenceKeypoint.new(1, 1),
        })
        gradient.Rotation = 45
        gradient.Offset = Vector2.new(0.25, 0)
        local colours = gradient.Color.Keypoints
        print("gradient", typeof(gradient.Color), #colours, colours[1].Time, colours[2].Value == Color3.new(0, 0, 1),
        \t#gradient.Transparency.Keypoints, gradient.Transparency.Keypoints[2].Value, gradient.Rotation, gradient.Offset.X,
        \tgradient.Color == ColorSequence.new(Color3.new(1, 0, 0), Color3.new(0, 0, 1)))
        print("one colour", #ColorSequence.new(Color3.new(1, 1, 1)).Keypoints, NumberSequence.new(0.5).Keypoints[2].Value)

        local function fails(f)
        \tlocal ok, message = pcall(f)
        \treturn if ok then "no error" else message
        end
        print("bad sequence", fails(function()
        \tColorSequence.new({ ColorSequenceKeypoint.new(0.2, Color3.new()), ColorSequenceKeypoint.new(1, Color3.new()) })
        end))
        print("bad order", fails(function()
        \tNumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.8, 0),
        \t\tNumberSequenceKeypoint.new(0.4, 0), NumberSequenceKeypoint.new(1, 0) })
        end))
        print("wrong type", fails(function() gradient.Color = Color3.new() end))
        print("stroke colour", fails(function() stroke.Color = ColorSequence.new(Color3.new()) end))

        local grid = Instance.new("UIGridLayout", frame)
        grid.CellSize = UDim2.fromOffset(50, 40)
        grid.StartCorner = Enum.StartCorner.BottomRight
        grid.FillDirectionMaxCells = 3
        print("grid", grid.FillDirection.Name, grid.CellSize == UDim2.fromOffset(50, 40), grid.StartCorner.Name,
        \tgrid.FillDirectionMaxCells, grid.CellPadding == UDim2.fromOffset(5, 5), grid:IsA("UIGridStyleLayout"),
        \tgrid:IsA("UILayout"))

        local holder = Instance.new("Frame", screen)
        holder.Size = UDim2.fromOffset(300, 100)
        local aspect = Instance.new("UIAspectRatioConstraint", holder)
        aspect.AspectRatio = 2
        print("aspect", aspect.AspectType.Name, aspect.DominantAxis.Name, aspect:IsA("UIConstraint"),
        \tfails(function() aspect.AspectRatio = 0 end))
        local limit = Instance.new("UISizeConstraint", holder)
        limit.MaxSize = Vector2.new(150, math.huge)
        print("limit", limit.MinSize == Vector2.zero, limit.MaxSize.Y == math.huge)
        local textLimit = Instance.new("UITextSizeConstraint")
        textLimit.MaxTextSize = 20
        print("text limit", textLimit.MinTextSize, textLimit.MaxTextSize, textLimit.ClassName)
        screen.Parent = game:GetService("Players").LocalPlayer.PlayerGui
        task.wait()
        print("sized", holder.AbsoluteSize.X, holder.AbsoluteSize.Y)
        """)
        let said = console.lines.filter { $0.kind == .output }.map(\.text)
        func line(_ prefix: String) -> String { said.first { $0.hasPrefix(prefix + " ") } ?? "(missing \(prefix))" }
        check("UIStroke from Luau", line("stroke") == "stroke true 4 Border Round true 0 true", line("stroke"))
        check("UIGradient with ColorSequence and NumberSequence",
              line("gradient") == "gradient ColorSequence 2 0 true 3 0.5 45 0.25 true", line("gradient"))
        check("…made from one colour or number, too", line("one colour") == "one colour 2 0.5", line("one colour"))
        check("…refusing keypoints that don't run 0 to 1 in order",
              line("bad sequence").contains("must start at time 0") && line("bad order").contains("ordered by time"),
              line("bad sequence") + " | " + line("bad order"))
        check("…and the wrong type for each class's Color",
              line("wrong type").contains("ColorSequence expected") && line("stroke colour").contains("Color3 expected"),
              line("wrong type") + " | " + line("stroke colour"))
        check("UIGridLayout from Luau", line("grid") == "grid Horizontal true BottomRight 3 true true true", line("grid"))
        check("UIAspectRatioConstraint, refusing a ratio of 0",
              line("aspect").hasPrefix("aspect FitWithinMaxSize Width true ") && line("aspect").contains("out of range"),
              line("aspect"))
        check("UISizeConstraint and UITextSizeConstraint",
              line("limit") == "limit true true" && line("text limit") == "text limit 1 20 UITextSizeConstraint",
              line("limit") + " | " + line("text limit"))
        check("…and they shape what they're in: AbsoluteSize", line("sized") == "sized 150 75", line("sized"))
        let errors = console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, errors.joined(separator: " | "))
        session.stop()
    }

    // MARK: - Saving and joined players

    /// A shop panel made in Studio with every new modifier.
    private static func buildShop(_ model: SceneModel) -> (panel: UUID, items: UUID, cells: [UUID]) {
        let screen = model.addGuiObject(.screenGui, in: nil)!
        let panel = model.addGuiObject(.frame, in: screen)!
        model.setGuiProperties(panel, [("size", SceneModel.guiValue(UDim2(xOffset: 400, yOffset: 300))),
                                       ("position", SceneModel.guiValue(UDim2()))])
        let stroke = model.addGuiObject(.uiStroke, in: panel)!
        model.setGuiProperties(stroke, [("color", .triple(1, 0.8, 0.2)), ("thickness", .number(3))])
        let gradient = model.addGuiObject(.uiGradient, in: panel)!
        model.setGuiProperties(gradient, [("color", .list([0, 1, 1, 1, 0.5, 0.25, 0.5, 0.75, 1, 0, 0, 0].map { .number($0) })),
                                          ("rotation", .number(90))])
        let items = model.addGuiObject(.frame, in: panel)!
        model.setGuiProperties(items, [("size", SceneModel.guiValue(UDim2(xScale: 1, yScale: 1))),
                                       ("position", SceneModel.guiValue(UDim2()))])
        let grid = model.addGuiObject(.uiGridLayout, in: items)!
        model.setGuiProperties(grid, [("cellsize", SceneModel.guiValue(UDim2(xOffset: 90, yOffset: 60))),
                                      ("startcorner", .string("TopRight"))])
        let cells = (0..<4).map { _ in model.addGuiObject(.frame, in: items)! }
        let aspect = model.addGuiObject(.uiAspectRatioConstraint, in: panel)!
        model.setGuiProperties(aspect, [("aspectratio", .number(1.5))])
        let limit = model.addGuiObject(.uiSizeConstraint, in: panel)!
        model.setGuiProperties(limit, [("minsize", .list([.number(100), .number(100)])),
                                       ("maxsize", .list([.number(Double.infinity), .number(Double.infinity)]))])
        let title = model.addGuiObject(.textLabel, in: panel)!
        let textLimit = model.addGuiObject(.uiTextSizeConstraint, in: title)!
        model.setGuiProperties(textLimit, [("maxtextsize", .number(24))])
        return (panel, items, cells)
    }

    private static func testSaving(_ check: Checker) {
        print("\nGUI modifiers: saved")
        let model = SceneModel()
        model.starterGui = []
        _ = buildShop(model)
        let limit = model.starterGui.first { $0.kind == .uiSizeConstraint }
        check("a MaxSize of no limit is kept as none (files have no infinity)", limit?.properties["maxsize"] == nil)
        guard let data = try? model.encodeScene(),
              let reopened = try? JSONDecoder().decode(SceneState.self, from: data) else {
            check("StarterGui with every modifier saves", false)
            return
        }
        check("StarterGui with every modifier saves and opens again the same",
              reopened.starterGui == model.starterGui
              && Set(reopened.starterGui.map(\.kind)).isSuperset(of: [.uiStroke, .uiGradient, .uiGridLayout,
                                                                      .uiAspectRatioConstraint, .uiSizeConstraint,
                                                                      .uiTextSizeConstraint]))
        let gradient = reopened.starterGui.first { $0.kind == .uiGradient }?.object()
        check("…a gradient's keypoints included",
              gradient?.gradientColor.count == 3 && gradient?.gradientColor[1].color == Vec3(0.25, 0.5, 0.75)
              && gradient?.rotation == 90)
    }

    private static func testTwoPlayers(_ check: Checker) {
        print("\nGUI modifiers: joined players")
        var cells: [UUID] = []
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            cells = buildShop(model).cells
            let reader = model.starterGui.first { $0.kind == .frame && $0.parentID != nil
                && model.guiObject(id: $0.parentID!)?.kind == .screenGui }!
            _ = model.addScript(parentID: reader.id, host: .starterGui)
            if let index = model.scripts.firstIndex(where: { $0.host == .starterGui }) {
                model.scripts[index].source = """
                local gradient = script.Parent:FindFirstChildOfClass("UIGradient")
                local grid = script.Parent.Frame.UIGridLayout
                print("copy", gradient.Color.Keypoints[2].Value == Color3.new(0.25, 0.5, 0.75), grid.StartCorner.Name,
                \tscript.Parent.UIStroke.Thickness, script.Parent.AbsoluteSize.X, script.Parent.AbsoluteSize.Y)
                """
            }
        }), let host = hosting.player, let player = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        func frames(_ session: PlayController) -> [CGRect] {
            let placed = session.gui.layout(in: CGSize(width: 800, height: 600))
            return cells.compactMap { session.guiCopies[$0] }.compactMap { copy in placed.first { $0.id == copy }?.frame }
        }
        let hostCells = frames(host), playerCells = frames(player)
        check("every player gets StarterGui's modifiers in their copy, laid out the same",
              hostCells.count == 4 && hostCells == playerCells && hostCells[0].minX > hostCells[1].minX,
              "\(hostCells) | \(playerCells)")
        let heard = { (session: PlayController) in
            session.console.lines.filter { $0.kind == .output }.map(\.text).first { $0.hasPrefix("copy ") } ?? "nothing"
        }
        check("…and a LocalScript in it reads them on each machine",
              heard(host) == "copy true TopRight 3 400 266.6666564941406" || heard(host).hasPrefix("copy true TopRight 3 400 266"),
              heard(host))
        check("…the joined player's too", heard(player) == heard(host), heard(player))
        hosting.leaveGame()
        joining.leaveGame()
    }

    // MARK: - Inserting

    private static func testInserting(_ check: Checker) {
        print("\nGUI tab: inserting")
        let model = SceneModel()
        model.starterGui = []
        check("a modifier needs something to go in", model.guiInsertTarget(for: .uiCorner) == nil)
        let steps = model.undoCount
        let frame = model.insertGui(.frame)
        check("a Frame with nothing selected comes in a new ScreenGui, as one step to undo",
              model.starterGui.count == 2 && model.starterGui[0].kind == .screenGui
              && frame.flatMap(model.guiObject(id:))?.parentID == model.starterGui[0].id
              && model.selectedGui == frame && model.undoCount == steps + 1)
        let label = model.insertGui(.textLabel)
        check("…with a Frame selected, the next goes inside it", label.flatMap(model.guiObject(id:))?.parentID == frame)
        let button = model.insertGui(.textButton)
        check("…with a TextLabel selected, beside it", button.flatMap(model.guiObject(id:))?.parentID == frame)
        let corner = model.insertGui(.uiCorner)
        check("a modifier goes in the selected object", corner.flatMap(model.guiObject(id:))?.parentID == button)
        let inside = model.insertGui(.frame)
        check("…and with a modifier selected, what it modifies is used",
              inside.flatMap(model.guiObject(id:))?.parentID == frame)
        model.selectedGui = button
        let count = model.starterGui.count
        let again = model.insertGui(.uiCorner)
        check("a second of the same modifier selects the first instead", again == corner && model.starterGui.count == count)
        model.selectedGui = frame
        let list = model.insertGui(.uiListLayout)
        let grid = model.insertGui(.uiGridLayout)
        check("…and one layout is all a parent gets", grid == list && list.flatMap(model.guiObject(id:))?.kind == .uiListLayout)
        model.selectedGui = model.starterGui[0].id
        check("a ScreenGui takes layouts and padding, not borders or gradients",
              model.guiInsertTarget(for: .uiListLayout) != nil && model.guiInsertTarget(for: .uiStroke) == nil
              && model.guiInsertTarget(for: .uiGradient) == nil)
        _ = try? model.importAsset(data: AudioSelfTest.png(red: 0, green: 1, blue: 0), name: "Coin", fileExtension: "png")
        let image = model.insertGui(.imageLabel)
        check("a new ImageLabel shows the first picture", image.flatMap(model.guiObject(id:))?.object().image == "studio://Coin")
        model.undo()
        check("undo takes an insert back", image.flatMap(model.guiObject(id:)) == nil)
        let positions = [label, button].compactMap { $0.flatMap(model.guiObject(id:))?.object().position }
        check("new objects step in from the corner so none hides another",
              positions.count == 2 && positions[0] != positions[1], "\(positions)")
    }

    // MARK: - Arranging

    private static func testArranging(_ check: Checker) {
        print("\nGUI tab: arranging")
        let model = SceneModel()
        model.starterGui = []
        let session = EditorSession(model: model)
        let editor = session.guiEditor
        let screenSize = CGSize(width: 800, height: 600)
        func frame(_ id: UUID?) -> CGRect? {
            guard let id, let copy = editor.copies[id] else { return nil }
            return session.guiPreview.layout(in: screenSize).first { $0.id == copy }?.frame
        }
        _ = session.guiPreview.layout(in: screenSize)
        let box = model.insertGui(.frame)
        model.selectedGui = nil
        let other = model.insertGui(.frame)
        model.selectedGui = box
        editor.align(.centerX)
        editor.align(.bottom)
        check("Align puts it at the parent's middle or edge, by scale and anchor",
              frame(box).map { abs($0.midX - 400) < 0.5 && abs($0.maxY - 600) < 0.5 } ?? false
              && box.flatMap(model.guiObject(id:))?.object().anchorPoint == SIMD2(0.5, 1), "\(frame(box) ?? .zero)")
        editor.align(.right)
        editor.align(.top)
        check("…any of the six", frame(box).map { abs($0.maxX - 800) < 0.5 && abs($0.minY) < 0.5 } ?? false)
        editor.fill()
        check("Fill makes it the parent's size", near(frame(box), CGRect(origin: .zero, size: screenSize)))
        model.undo()
        check("…one step to undo", frame(box).map { abs($0.maxX - 800) < 0.5 && $0.width == 100 } ?? false)

        editor.reorder(toFront: false)
        let z = { (id: UUID?) in id.flatMap(model.guiObject(id:))?.object().zIndex ?? 0 }
        check("Back puts it behind its siblings", z(box) < z(other))
        editor.reorder(toFront: true)
        let drawn = session.guiPreview.layout(in: screenSize).map(\.id)
        check("Front puts it in front, and drawn last",
              z(box) > z(other) && drawn.lastIndex(of: editor.copies[box!]!)! > drawn.lastIndex(of: editor.copies[other!]!)!)

        model.selectedGui = box
        _ = model.insertGui(.uiCorner)
        model.selectedGui = box
        let script = model.addScript(parentID: box, host: .starterGui)
        model.selectedGui = box
        model.duplicateSelected()
        let copy = model.selectedGui
        let copied = copy.flatMap(model.guiObject(id:))
        check("⌘D with a GUI object selected copies it, what's inside and its LocalScripts",
              copy != box && copied?.parentID == box.flatMap(model.guiObject(id:))?.parentID
              && model.guiChildren(of: copy!).map(\.kind) == [.uiCorner] && model.guiScripts(in: copy!).count == 1
              && model.scripts.contains { $0.id == script })
        check("…a step down and to the right, under its own name",
              frame(copy).map { copyFrame in frame(box).map { copyFrame.minX == $0.minX + 10 && copyFrame.minY == $0.minY + 10 } ?? false } ?? false
              && copied?.name != box.flatMap(model.guiObject(id:))?.name)
        let parts = model.parts.count
        model.selection = []
        model.deleteSelected()
        check("Delete with a GUI object selected deletes it, not parts",
              copy.flatMap(model.guiObject(id:)) == nil && model.parts.count == parts)

        model.selectedGui = other
        model.setGuiProperties(other!, [("position", SceneModel.guiValue(UDim2(xScale: 0.1, xOffset: 20, yOffset: 30))),
                                        ("size", SceneModel.guiValue(UDim2(xOffset: 200, yScale: 0.25)))])
        let before = frame(other)
        editor.convert(toScale: true)
        let scaled = other.flatMap(model.guiObject(id:))?.object()
        check("To Scale turns pixels into shares of the parent, where it is",
              near(frame(other), before ?? .zero) && scaled?.position.xOffset == 0 && scaled?.size.xOffset == 0
              && scaled?.size.xScale == 0.25 && scaled?.position.yScale == 0.05, "\(String(describing: scaled?.position))")
        editor.convert(toScale: false)
        let pixels = other.flatMap(model.guiObject(id:))?.object()
        check("…and To Pixels back", near(frame(other), before ?? .zero) && pixels?.position == UDim2(xOffset: 100, yOffset: 30)
              && pixels?.size == UDim2(xOffset: 200, yOffset: 150), "\(String(describing: pixels?.size))")
    }

    // MARK: - The preview

    private static func testPreview(_ check: Checker) {
        print("\nGUI tab: previewing screens")
        let view = CGSize(width: 1000, height: 700)
        let window = GuiPreviewGeometry(view: view, device: .window)
        check("Fit Window previews at the viewport's own size",
              window.screen == view && window.scale == 1 && window.origin == .zero)
        let phone = GuiPreviewGeometry(view: view, device: .phone)
        check("a phone's screen sits in the middle, full size when it fits",
              phone.screen == CGSize(width: 844, height: 390) && phone.scale == 1 && phone.origin == CGPoint(x: 78, y: 155))
        let tablet = GuiPreviewGeometry(view: view, device: .tablet)
        let point = CGPoint(x: 300, y: 200)
        let back = tablet.toScreen(tablet.toView(point))
        check("…a bigger one shrunk to fit, with the margin, and points mapped both ways",
              abs(tablet.scale - 644.0 / 768) < 0.001 && tablet.frameInView.maxY <= 700 - 27
              && abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
        let model = SceneModel()
        model.starterGui = []
        let session = EditorSession(model: model)
        let box = model.insertGui(.frame)!
        model.setGuiProperties(box, [("position", SceneModel.guiValue(UDim2(xScale: 0.5, yScale: 0.5))),
                                     ("anchorpoint", SceneModel.guiValue(SIMD2<Float>(0.5, 0.5)))])
        let copy = session.guiEditor.copies[box]!
        let onPhone = session.guiPreview.layout(in: phone.screen).first { $0.id == copy }?.frame
        let onDesktop = session.guiPreview.layout(in: CGSize(width: 1920, height: 1080)).first { $0.id == copy }?.frame
        check("the preview lays StarterGui out at the device's size",
              onPhone.map { abs($0.midX - 422) < 0.5 } ?? false && onDesktop.map { abs($0.midX - 960) < 0.5 } ?? false)
        session.ribbonTab = .gui
        check("the GUI tab edits the preview only with the world showing, outside play",
              session.editingGui && session.guiHint?.contains("drag to move") == true)
        session.showsGuiPreview = false
        check("…and the preview showing", !session.editingGui && session.guiHint == nil)
        session.showsGuiPreview = true
        session.startPlay()
        check("…not while playing", !session.editingGui)
        session.stopPlay()
    }

    // MARK: - Dragging

    private static func testDragging(_ check: Checker) {
        print("\nGUI tab: dragging in the view")
        let model = SceneModel()
        model.starterGui = []
        let session = EditorSession(model: model)
        session.ribbonTab = .gui
        let editor = session.guiEditor
        let screenSize = CGSize(width: 800, height: 600)
        _ = session.guiPreview.layout(in: screenSize)
        let box = model.insertGui(.frame)!
        model.selectedGui = nil
        let other = model.insertGui(.frame)!
        model.setGuiProperties(other, [("position", SceneModel.guiValue(UDim2(xOffset: 600, yOffset: 410)))])
        model.selectedGui = nil
        func object(_ id: UUID) -> GuiObject? { model.guiObject(id: id)?.object() }
        func frame(_ id: UUID) -> CGRect? {
            editor.copies[id].flatMap { copy in session.guiPreview.layout(in: screenSize).first { $0.id == copy }?.frame }
        }

        check("a press finds the object drawn on top", editor.hit(at: CGPoint(x: 90, y: 90)) == editor.copies[box]
              && editor.hit(at: CGPoint(x: 5, y: 5)) == nil)
        let steps = model.undoCount
        editor.guides = false
        editor.begin(at: CGPoint(x: 90, y: 90))
        check("…and selects it", model.selectedGui == box)
        editor.drag(to: CGPoint(x: 140, y: 115))
        check("dragging moves it in the preview as it goes, not yet in the scene",
              near(frame(box), CGRect(x: 90, y: 65, width: 100, height: 100)) && object(box)?.position == UDim2(xOffset: 40, yOffset: 40))
        editor.end()
        check("…and letting go moves it for good, one step to undo",
              object(box)?.position == UDim2(xOffset: 90, yOffset: 65) && model.undoCount == steps + 1)
        model.undo()
        check("…which undo puts back", object(box)?.position == UDim2(xOffset: 40, yOffset: 40))

        model.setGuiProperties(box, [("position", SceneModel.guiValue(UDim2(xScale: 0.25, yScale: 0.25)))])
        editor.begin(at: CGPoint(x: 250, y: 200))
        editor.drag(to: CGPoint(x: 330, y: 260))
        editor.end()
        check("a position in scale stays in scale", object(box)?.position == UDim2(xScale: 0.35, yScale: 0.35),
              "\(String(describing: object(box)?.position))")

        model.setGuiProperties(box, [("position", SceneModel.guiValue(UDim2(xOffset: 40, yOffset: 40)))])
        editor.guides = true
        editor.viewScale = 1
        editor.begin(at: CGPoint(x: 90, y: 90))
        editor.drag(to: CGPoint(x: 403, y: 90))
        let guides = editor.shownGuides
        editor.end()
        check("guides snap it to the parent's middle, and show where",
              frame(box).map { abs($0.midX - 400) < 0.01 } ?? false && guides.contains { $0.vertical && $0.at == 400 }
              && editor.shownGuides.isEmpty, "\(frame(box) ?? .zero) \(guides)")
        editor.begin(at: CGPoint(x: 400, y: 90))
        editor.drag(to: CGPoint(x: 400, y: 358))
        editor.end()
        check("…and to a sibling's edge", frame(box).map { abs($0.maxY - 410) < 0.01 } ?? false, "\(frame(box) ?? .zero)")

        editor.guides = false
        editor.grid = 8
        model.setGuiProperties(box, [("position", SceneModel.guiValue(UDim2(xOffset: 40, yOffset: 40)))])
        editor.begin(at: CGPoint(x: 90, y: 90))
        editor.drag(to: CGPoint(x: 103, y: 101))
        editor.end()
        check("with a grid, it lands on the grid", object(box)?.position == UDim2(xOffset: 56, yOffset: 48),
              "\(String(describing: object(box)?.position))")
        editor.grid = 0

        model.setGuiProperties(box, [("position", SceneModel.guiValue(UDim2(xOffset: 40, yOffset: 40)))])
        model.selectedGui = box
        check("the selection's corner is a handle", editor.handle(at: CGPoint(x: 141, y: 139)) == .bottomRight)
        editor.begin(at: CGPoint(x: 140, y: 140))
        editor.drag(to: CGPoint(x: 190, y: 170))
        editor.end()
        check("dragging a handle resizes it, the other corner staying put",
              object(box)?.size == UDim2(xOffset: 150, yOffset: 130) && object(box)?.position == UDim2(xOffset: 40, yOffset: 40))
        model.setGuiProperties(box, [("anchorpoint", SceneModel.guiValue(SIMD2<Float>(0.5, 0.5))),
                                     ("position", SceneModel.guiValue(UDim2(xOffset: 200, yOffset: 200))),
                                     ("size", SceneModel.guiValue(UDim2(xOffset: 100, yOffset: 100)))])
        editor.begin(at: CGPoint(x: 150, y: 200))
        editor.drag(to: CGPoint(x: 130, y: 200))
        editor.end()
        check("…whatever its AnchorPoint: the left edge out, the right where it was",
              near(frame(box), CGRect(x: 130, y: 150, width: 120, height: 100)), "\(frame(box) ?? .zero)")

        model.selectedGui = box
        let child = model.insertGui(.frame)!
        model.selectedGui = box
        let list = model.insertGui(.uiListLayout)!
        let copy = editor.copies[child]!
        check("in a UIListLayout it can't be dragged about, only sized", !editor.canMove(copy) && editor.canResize(copy)
              && editor.arrangingLayout(of: copy)?.kind == .uiListLayout)
        model.deleteGuiObject(list)
        model.selectedGui = box
        _ = model.insertGui(.uiGridLayout)
        check("…in a UIGridLayout neither", editor.copies[child].map { !editor.canMove($0) && !editor.canResize($0) } ?? false)
    }

    // MARK: - Keys

    private static func testKeys(_ check: Checker) {
        print("\nGUI tab: keys")
        let model = SceneModel()
        model.starterGui = []
        let session = EditorSession(model: model)
        _ = session.guiPreview.layout(in: CGSize(width: 800, height: 600))
        let box = model.insertGui(.frame)!
        let keys = session.viewport.guiKeys
        let position = { model.guiObject(id: box)?.object().position }
        check("the arrows are the world's outside the GUI tab", keys?(124, false) == false && position() == UDim2(xOffset: 40, yOffset: 40))
        session.ribbonTab = .gui
        _ = keys?(124, false)
        _ = keys?(125, true)
        check("in the GUI tab they nudge the selected object: a pixel, or ten with Shift",
              position() == UDim2(xOffset: 41, yOffset: 50))
        _ = keys?(53, false)
        check("Escape lets go of it", model.selectedGui == nil && keys?(124, false) == false)
    }

    // MARK: - A real window

    private static func testWindow(_ check: Checker) {
        print("\nGUI tab: in a window")
        let model = SceneModel()
        model.starterGui = []
        var ground = Part()
        ground.name = "Ground"
        ground.size = Vec3(4000, 1, 4000)
        ground.position = Vec3(0, -0.5, 0)
        model.parts = [ground]
        let session = EditorSession(model: model)
        session.ribbonTab = .gui
        let box = model.insertGui(.frame)!
        model.selectedGui = nil
        model.selection = []
        let size = NSRect(x: 0, y: 0, width: 900, height: 500)
        let hosting = NSHostingView(rootView: DocumentArea(model: model, session: session))
        hosting.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        var stamp = ProcessInfo.processInfo.systemUptime
        // As the window would: the view under the press gets it, and keeps the drag.
        var pressed: NSView?
        var targets: [String] = []
        func send(_ kind: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) {
            stamp += 0.02
            let location = NSPoint(x: x, y: size.height - y)
            guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [], timestamp: stamp,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1) else { return }
            if kind == .leftMouseDown {
                pressed = hosting.hitTest(location)
                targets.append(pressed.map { String(describing: type(of: $0)) } ?? "nothing")
            }
            window.sendEvent(event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        session.guiEditor.guides = false
        send(.leftMouseDown, 90, 90)
        send(.leftMouseDragged, 110, 100)
        send(.leftMouseDragged, 130, 110)
        send(.leftMouseUp, 130, 110)
        check("a click on a GUI object in the view selects it, not the ground behind",
              model.selectedGui == box && model.selection.isEmpty, "\(targets)")
        check("…and a drag moves it", model.guiObject(id: box)?.object().position == UDim2(xOffset: 80, yOffset: 60),
              "\(String(describing: model.guiObject(id: box)?.object().position))")
        send(.leftMouseDown, 600, 400)
        send(.leftMouseUp, 600, 400)
        check("…while a click beside it still reaches the world",
              model.selection == [ground.id] && targets.last == "StudioMTKView", "\(model.selection.count) selected, \(targets)")
        window.orderOut(nil)
        window.contentView = nil
    }
}
