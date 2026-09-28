import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// `StudioApp --render-panel animation out.png`: draws a Studio panel to a PNG with no
/// window, via SwiftUI's ImageRenderer. `--render-window script out.png` draws the whole
/// Studio window instead, off screen, with a script (or `shader`, `world` or `newscript`) in front. AppKit-backed controls (sliders, pickers,
/// checkboxes) may draw as placeholders; layout, text and custom drawing are real.
enum PanelSnapshot {
    @MainActor
    static func render(panel: String, to url: URL) -> Bool {
        if ["suggestions", "picked", "require", "module", "service", "utils"].contains(panel) { return renderSuggestions(panel, to: url) }
        let model = SceneModel()
        let session = EditorSession(model: model)
        let view: AnyView
        switch panel {
        case "animation":
            model.selectedAnimation = model.animations.first?.id
            let editor = session.viewport.animationEditor
            editor.isOpen = true
            editor.selectedJoint = .rightShoulder
            editor.setTime(0.3)
            view = AnyView(AnimationEditorView(model: model, session: session, editor: editor)
                .frame(width: 1100, height: 240))
        case "inspector":
            model.selectedAnimation = model.animations.first?.id
            let editor = session.viewport.animationEditor
            editor.selectedJoint = .rightShoulder
            editor.setTime(0.3)
            guard let animation = editor.animation else { return false }
            view = AnyView(JointInspector(animation: animation, editor: editor, model: model).content
                .frame(width: 250, height: 420, alignment: .top))
        case "lighting":
            model.lighting.technology = .rayTraced
            model.lighting.clockTime = 17.5
            view = AnyView(LightingInspector(model: model).content.frame(width: 270, height: 900, alignment: .top))
        case "sky":
            // Lighting's Sky, Atmosphere and Clouds, all three added.
            model.lighting.skyObject = SkySettings()
            model.lighting.atmosphere = AtmosphereSettings()
            model.lighting.clouds = CloudSettings()
            view = AnyView(SkyObjectsEditor(model: model).padding(12).font(.system(size: 11))
                .foregroundStyle(Theme.text).frame(width: 270, height: 860, alignment: .top))
        case "explorer":
            view = AnyView(ExplorerView(model: model, session: session).frame(width: 280, height: 720))
        case "ribbon":
            // Every tab, one under another, at the window's default width; the Physics
            // tab with the weld tool armed and a part held, as mid-weld.
            model.armJoinTool(.weld)
            model.joinPending = model.parts.first?.id
            let tabs = RibbonTab.allCases.map { tab -> EditorSession in
                let tabSession = EditorSession(model: model)
                tabSession.ribbonTab = tab
                return tabSession
            }
            view = AnyView(VStack(spacing: 6) {
                ForEach(tabs.indices, id: \.self) { i in
                    RibbonView(model: model, session: tabs[i])
                }
                ViewportOverlay(model: model).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 1400))
        default:
            print("Unknown panel \"\(panel)\" — try animation, inspector, lighting, explorer, ribbon, suggestions, picked, require, module, service or utils.")
            return false
        }
        let renderer = ImageRenderer(content: view.background(Theme.panel).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("Could not render the \(panel) panel.")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        print("Wrote \(url.path)")
        return true
    }

    /// A script with the suggestion list open: `suggestions` under `part.C`, `picked`
    /// after Down twice, `require` just after `require(`, `module` after a required
    /// module's name, `service` inside `GetService("`, `utils` after `Utils.d` in a new
    /// place. The list is its own little window, so it is drawn over the editor's picture.
    @MainActor
    static func renderSuggestions(_ state: String, to url: URL) -> Bool {
        _ = NSApplication.shared
        let size = NSRect(x: 0, y: 0, width: 640, height: 330)
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let container = NSView(frame: size)
        window.contentView = container
        let entry = CodeEditor.makeEntry()
        entry.scrollView.frame = size
        container.addSubview(entry.scrollView)
        let scene = state == "utils" ? SceneModel().luauScene() : SyntaxSelfTest.sampleScene()
        let coordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2, language: .luau,
                                                 completions: { LuauCompletion.items(in: $0, caret: $1, scene: scene) })
        coordinator.entry = entry
        entry.textView.delegate = coordinator
        entry.textView.source = coordinator
        CodeEditor.setLineNumbers(true, on: entry)
        let modules = """
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Utils = require(ReplicatedStorage.Utils)
        local Enemy = require(
        """
        let source: String
        switch state {
        case "require": source = modules
        case "module": source = modules.replacingOccurrences(of: "local Enemy = require(", with: "\nlocal speed = Utils.")
        case "utils":
            source = modules.replacingOccurrences(of: "local Enemy = require(", with: "\nlocal onTouch = Utils.d")
        case "service":
            source = """
            local ReplicatedStorage = game:GetService("ReplicatedStorage")
            local Players = game:GetService("Players")
            local TweenService = game:GetService("
            """
        default:
            source = """
            local Players = game:GetService("Players")
            local part = workspace.Part

            part.Touched:Connect(function(hit)
            \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
            \tif humanoid then
            \t\tpart.C
            """
        }
        entry.textView.string = source
        CodeEditor.highlight(entry.textView, language: .luau)
        window.makeFirstResponder(entry.textView)
        entry.textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.suggest(in: entry.textView, typed: true)
        if state == "picked" {
            entry.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
            entry.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        }
        let list = coordinator.completionList
        guard list.isOpen else { print("The list didn't open."); return false }
        let rows = list.snapshotView()
        rows.frame.origin = window.convertFromScreen(list.panelFrame).origin
        container.addSubview(rows)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return false }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
        } catch {
            print("Could not write \(url.path): \(error)")
            return false
        }
        print("Wrote \(url.path)")
        return true
    }

    /// `--render-home out.png [empty]`: Studio's home page with two saved places as recents
    /// (or none), every picture drawn first.
    @MainActor
    static func renderHome(to url: URL, withRecents: Bool = true, height: CGFloat = 1120) -> Bool {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StudioHomeSnapshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PlaceThumbnail.shared.directory = folder.appendingPathComponent("Thumbnails", isDirectory: true)
        var recents: [URL] = []
        if withRecents {
            for (name, template) in [("My Obby", PlaceTemplate.obby), ("Shader Playground", .starter)] {
                let file = folder.appendingPathComponent("\(name).\(SceneDocument.sceneExtension)")
                if let data = try? JSONEncoder().encode(template.state()) { try? data.write(to: file) }
                recents.append(file)
            }
        }
        let home = HomeModel()
        home.canGoBack = true
        home.currentName = "Untitled"
        home.refresh(recentURLs: recents, drawNow: true)
        let size = NSRect(x: 0, y: 0, width: 1400, height: height)
        let hosting = NSHostingView(rootView: HomeView(home: home))
        hosting.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
        } catch {
            print("Could not write \(url.path): \(error)")
            return false
        }
        print("Wrote \(url.path)")
        return true
    }

    /// The whole editor window, laid out in an off-screen window and drawn with
    /// `cacheDisplay`, which — unlike ImageRenderer — draws AppKit views such as the code
    /// editor. The Metal viewport and SwiftUI's checkboxes and pickers don't show.
    @MainActor
    static func renderWindow(showing state: String, to url: URL) -> Bool {
        _ = NSApplication.shared
        let model = SceneModel()
        let session = EditorSession(model: model)
        let script = model.scripts.first?.id ?? model.addScript()
        let shader = model.shaders.first?.id ?? model.addShader()
        session.console.info("▶ Play started")
        session.console.output("Hello from \(model.script(id: script)?.name ?? "Script")")
        session.console.error("\(model.script(id: script)?.name ?? "Script"):3: attempt to index nil with 'Position'")
        session.console.info("■ Play stopped — scene restored")
        switch state {
        case "world":
            session.openScript(script)
            session.showWorld()
        case "shader":
            session.openScript(script)
            session.openShader(shader)
        case "guitab", "guigradient":
            // The GUI tab: a shop panel on a phone's screen, a button selected with its handles.
            session.ribbonTab = .gui
            session.guiEditor.device = .phone
            let screen = model.insertGui(.screenGui)!
            model.renameGuiObject(screen, to: "Shop")
            model.selectedGui = screen
            let panel = model.insertGui(.frame)!
            model.renameGuiObject(panel, to: "Panel")
            model.setGuiProperties(panel, [("position", .list([.number(0.5), .number(0), .number(0.5), .number(0)])),
                                           ("anchorpoint", .list([.number(0.5), .number(0.5)])),
                                           ("size", .list([.number(0), .number(420), .number(0), .number(260)])),
                                           ("backgroundcolor3", .triple(0.13, 0.15, 0.2))])
            _ = model.insertGui(.uiCorner)
            let stroke = model.insertGui(.uiStroke)!
            model.setGuiProperties(stroke, [("color", .triple(1, 0.8, 0.3)), ("thickness", .number(3))])
            model.selectedGui = panel
            let items = model.insertGui(.frame)!
            model.renameGuiObject(items, to: "Items")
            model.setGuiProperties(items, [("position", .list([.number(0), .number(16), .number(0), .number(56)])),
                                           ("size", .list([.number(1), .number(-32), .number(1), .number(-72)])),
                                           ("backgroundtransparency", .number(1))])
            let grid = model.insertGui(.uiGridLayout)!
            model.setGuiProperties(grid, [("cellsize", .list([.number(0), .number(88), .number(0), .number(80)])),
                                          ("cellpadding", .list([.number(0), .number(8), .number(0), .number(8)]))])
            for (index, colour) in [(0.9, 0.4, 0.35), (0.4, 0.75, 0.45), (0.35, 0.55, 0.9), (0.85, 0.7, 0.3),
                                    (0.7, 0.45, 0.85), (0.4, 0.8, 0.8)].enumerated() {
                model.selectedGui = items
                let item = model.insertGui(.frame)!
                model.renameGuiObject(item, to: "Item\(index + 1)")
                model.setGuiProperties(item, [("backgroundcolor3", .triple(Float(colour.0), Float(colour.1), Float(colour.2)))])
                _ = model.insertGui(.uiCorner)
                let gradient = model.insertGui(.uiGradient)!
                model.setGuiProperties(gradient, [("color", .list([0, 1, 1, 1, 1, 0.55, 0.55, 0.6].map { .number($0) })),
                                                  ("rotation", .number(90))])
            }
            model.selectedGui = panel
            let title = model.insertGui(.textLabel)!
            model.setGuiProperties(title, [("position", .list([.number(0), .number(16), .number(0), .number(12)])),
                                           ("size", .list([.number(1), .number(-32), .number(0), .number(36)])),
                                           ("text", .string("Shop")), ("textsize", .number(26)),
                                           ("font", .string("GothamBold")), ("textcolor3", .triple(1, 1, 1)),
                                           ("textxalignment", .string("Left")), ("backgroundtransparency", .number(1))])
            model.selectedGui = panel
            let close = model.insertGui(.textButton)!
            model.setGuiProperties(close, [("position", .list([.number(1), .number(-12), .number(0), .number(12)])),
                                           ("anchorpoint", .list([.number(1), .number(0)])),
                                           ("size", .list([.number(0), .number(36), .number(0), .number(36)])),
                                           ("text", .string("X")), ("textsize", .number(20)),
                                           ("backgroundcolor3", .triple(0.85, 0.3, 0.3)), ("textcolor3", .triple(1, 1, 1))])
            _ = model.insertGui(.uiCorner)
            model.selectedGui = state == "guigradient" ? model.starterGui.first { $0.kind == .uiGradient }?.id : close
            session.showWorld()
        case "gui":
            // StarterGui being made: a HUD, previewed over the viewport, its title selected.
            let screen = model.addGuiObject(.screenGui, in: nil)!
            model.renameGuiObject(screen, to: "Hud")
            let bar = model.addGuiObject(.frame, in: screen)!
            model.setGuiProperty(bar, "position", .list([.number(0.5), .number(-160), .number(0), .number(16)]))
            model.setGuiProperty(bar, "size", .list([.number(0), .number(320), .number(0), .number(56)]))
            model.setGuiProperty(bar, "backgroundcolor3", .triple(0.1, 0.12, 0.16))
            model.setGuiProperty(bar, "backgroundtransparency", .number(0.2))
            _ = model.addGuiObject(.uiCorner, in: bar)
            let title = model.addGuiObject(.textLabel, in: bar)!
            model.renameGuiObject(title, to: "Title")
            model.setGuiProperty(title, "position", .list([.number(0), .number(0), .number(0), .number(0)]))
            model.setGuiProperty(title, "size", .list([.number(1), .number(0), .number(1), .number(0)]))
            model.setGuiProperty(title, "text", .string("Coins: 0"))
            model.setGuiProperty(title, "textcolor3", .triple(1, 0.85, 0.3))
            model.setGuiProperty(title, "textsize", .number(24))
            model.setGuiProperty(title, "font", .string("GothamBold"))
            model.setGuiProperty(title, "backgroundtransparency", .number(1))
            _ = model.addScript(parentID: screen, host: .starterGui)
            model.selectedGui = title
        case "split":
            session.openScript(script, line: 3)
            session.splitView = true
        case "debugger":
            // Stopped at a breakpoint, as a real stop is caught: watches, a condition, and
            // a table opened.
            var counter = ScriptObject.blank(language: .luau)
            counter.name = "Counter"
            counter.source = DebuggerSelfTest.counting
            counter.breakpoints = [4, 9, 13]
            counter.breakpointConditions = [4: "amount > 1"]
            counter.breakpointLogs = [13: "\"total\", total"]
            model.scripts.append(counter)
            for watch in ["total", "#items", "index * 10", "items.missing.field"] { session.addWatch(watch) }
            let play = PlayController(model: model, console: ScriptConsole())
            var caught: ScriptDebugger.Pause?
            var opened: [String: [LuauInterpreter.DebugVariable]] = [:]
            let debugger = ScriptDebugger()
            debugger.watches = session.watchExpressions
            debugger.handler = { [unowned debugger] pause in
                if caught == nil && pause.frames.first?.line == 9 && pause.frames.first?.variables.first(where: { $0.name == "index" })?.value == "2" {
                    caught = pause
                    opened["items"] = debugger.fields(of: "items")
                }
                return .resume
            }
            play.scripts.debugger = debugger
            play.start()
            for _ in 0..<5 { play.step(dt: 1.0 / 60) }
            play.stop()
            if let caught { session.show(caught, opened: opened, hits: debugger.hits) }
            session.dockHeight = 330
        case "sounds", "picture":
            // A sound and a picture imported, a Sound in SoundService and one in a part,
            // and the Sound's (or the picture's) properties.
            let (music, picture) = addSampleAssets(to: model)
            session.showWorld()
            if state == "sounds" { model.selectedSound = music } else { model.selectedAsset = picture }
        case "mesh", "meshasset":
            // An arch imported and made a MeshPart with a picture on it, and its (or the
            // 3D model's) properties.
            let arch = (try? model.importAsset(data: MeshSelfTest.arch, name: "Arch", fileExtension: "obj")) ?? UUID()
            _ = addSampleAssets(to: model)
            session.showWorld()
            if state == "mesh", let part = model.insertMeshPart(arch, at: Vec3(0, 0, -6)) {
                model.setMeshTexture("studio://Star", of: [part])
                model.selection = [part]
            } else {
                model.selectedAsset = arch
            }
        case "replicated":
            // ReplicatedStorage with a module, remotes and a Folder of Values, a Value picked.
            session.showWorld()
            model.addModuleScript(name: "Weapons")
            model.addDataObject(.remoteEvent)
            model.updateDataObject(id: model.dataObjects.last!.id) { $0.name = "Damage" }
            model.addDataObject(.remoteFunction)
            model.updateDataObject(id: model.dataObjects.last!.id) { $0.name = "BuyItem" }
            let folder = model.addDataObject(.folder)
            model.updateDataObject(id: folder) { $0.name = "Settings" }
            let round = model.addDataObject(.intValue, in: .node(folder))
            model.updateDataObject(id: round) { $0.name = "RoundLength"; $0.number = 120 }
            // ServerStorage: a Model to clone, a module, a Value.
            if let tower = model.parts.first(where: { $0.name == "Tower" }) {
                model.moveToStorage([tower.id], .serverStorage)
            }
            model.addModuleScript(host: .serverStorage, name: "Economy")
            let spawn = model.addDataObject(.vector3Value, in: .serverStorage)
            model.updateDataObject(id: spawn) { $0.name = "SpawnPoint"; _ = $0.setValue(.list([.number(0), .number(5), .number(20)])) }
            model.selectDataObject(round)
        case "terrain":
            // Hills and Lake, the Terrain Editor open with a brush picked, over the land.
            model.loadTemplate(.terrain)
            session.showDock(.terrain)
            model.terrainBrush = .add
            model.terrainMaterial = .rock
            session.viewport.camera.target = Vec3(0, 10, 0)
            session.viewport.camera.distance = 220
            session.viewport.camera.pitch = 0.5
        case "beam":
            // Two posts and a Beam between them, made with the Beam tool, picked.
            session.showWorld()
            let a = model.addPart(shape: .block, at: Vec3(-6, 3, -6))
            let b = model.addPart(shape: .block, at: Vec3(6, 3, -6))
            if let beam = model.join(.beam, a, b) {
                model.updateConstraint(id: beam) { $0.look.texture = "builtin://Glow"; $0.look.lightEmission = 1 }
            }
        case "particles":
            // A campfire: Fire and Smoke in a part, Fire picked.
            session.showWorld()
            let pit = model.addPart(shape: .cylinder, at: Vec3(0, 0.5, -4))
            model.update(id: pit) { $0.name = "Campfire" }
            let fire = model.addEmitter(.fire, to: pit)
            model.addEmitter(.smoke, to: pit)
            model.selection = []
            model.selectedEmitter = fire
        case "rig":
            // Insert › Rig, its Humanoid picked: the Explorer opens the Rig to show it.
            session.showWorld()
            let rig = model.addRig(at: Vec3(0, 0, -4))
            if let humanoid = model.dataObjects.first(where: { $0.className == .humanoid && $0.parent == .node(rig) }) {
                model.updateDataObject(id: humanoid.id) { $0.walkSpeed = 12 }
                model.selection = []
                model.selectDataObject(humanoid.id)
            }
        case "avatar":
            // StarterPlayer dressed: a top hat and suit for everyone, the hat opened up.
            session.showWorld()
            model.starterPlayer.look = AvatarSnapshot.sampleLooks[0]
            model.selectStarterPlayer()
        case "newscript":
            // What someone sees on adding a script to a part.
            let platform = model.parts.first { $0.name == "Platform" } ?? model.parts[0]
            session.openScript(model.addScript(parentID: platform.id))
        default:
            session.openShader(shader)
            session.openCoreScript(named: CoreScripts.controlScript.name)
            session.openScript(script, line: 3)
        }
        // The Mesh section is far down Properties: a taller window shows it.
        let size = NSRect(x: 0, y: 0, width: 1400, height: state == "avatar" ? 2500 : state == "mesh" || state == "replicated" ? 1500 : 880)
        let hosting = NSHostingView(rootView: ContentView(model: model, session: session))
        hosting.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
        } catch {
            print("Could not write \(url.path): \(error)")
            return false
        }
        print("Wrote \(url.path)")
        return true
    }

    /// Assets and Sounds to show: a chime, a star picture, looping music in SoundService
    /// and a chime in the first part.
    @MainActor
    private static func addSampleAssets(to model: SceneModel) -> (music: UUID, picture: UUID) {
        let tone = (0..<11025).map { Int16(sin(Double($0) * 0.125) * 9000) }
        var wav = Data("RIFF".utf8)
        func field(_ value: Int, _ size: Int) {
            wav.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init).prefix(size))
        }
        field(36 + tone.count * 2, 4)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        for (value, size) in [(16, 4), (1, 2), (1, 2), (22050, 4), (44100, 4), (2, 2), (16, 2)] { field(value, size) }
        wav.append(contentsOf: Array("data".utf8))
        field(tone.count * 2, 4)
        for sample in tone { wav.append(contentsOf: withUnsafeBytes(of: sample.littleEndian, Array.init)) }
        let star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .regular).applying(.init(paletteColors: [.systemYellow])))
        let picture = star.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .png, properties: [:]) } ?? Data()
        _ = try? model.importAsset(data: wav, name: "Chime", fileExtension: "wav")
        let logo = (try? model.importAsset(data: picture, name: "Star", fileExtension: "png")) ?? UUID()
        let music = model.addSound(in: nil)
        model.updateSound(id: music) { $0.name = "Music"; $0.looped = true; $0.playing = true; $0.volume = 0.3 }
        if let part = model.parts.first?.id {
            let chime = model.addSound(in: part)
            model.updateSound(id: chime) { $0.name = "Chime" }
        }
        model.selection = []
        model.selectedAsset = nil
        model.selectedSound = nil
        return (music, logo)
    }

    /// `--render-client menu|character|faces|clothes|outfit|join|chat|leaderboard|talk out.png`: a client screen, drawn off
    /// screen like `renderWindow`, for a player called Robin with a red torso. `chat` is
    /// a game in progress with the default chat open: its screen GUI over a plain sky,
    /// since the 3D view doesn't draw off screen.
    @MainActor
    static func renderClient(screen: String, to url: URL) -> Bool {
        _ = NSApplication.shared
        let suite = "studio-render-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ClientSession(defaults: defaults)
        session.profile.name = "Robin"
        session.profile.colors.torso = Vec3(0.77, 0.16, 0.11)
        session.profile.look = AvatarSnapshot.sampleLooks[1]
        switch screen {
        case "character": session.screen = .character
        case "outfit", "faces", "clothes":
            session.screen = .character
            CharacterEditorView.startingTab = screen == "faces" ? .face : screen == "clothes" ? .clothes : .accessories
        case "join": session.screen = .join
        case "games":
            // The picker, its pictures drawn.
            session.showGames()
            session.games.refresh(recentURLs: session.recentPlaces, drawNow: true)
        case "nightfall":
            // Nightfall by day: its title top middle, the game bar clear of it.
            session.loadNightfall()
            session.play()
            if let player = session.player {
                for _ in 0..<120 { player.step(dt: 1.0 / 60) }
            }
        case "talk":
            // Adventure Island, talking to Guide Pip with a gem found.
            session.loadAdventureIsland()
            session.play()
            if let player = session.player {
                for _ in 0..<30 { player.step(dt: 1.0 / 60) }
                player.character.position = Vec3(-6, 0.4, 18)
                for _ in 0..<10 { player.step(dt: 1.0 / 60) }
                player.key("E", pressed: true)
                player.step(dt: 1.0 / 60)
                player.key("E", pressed: false)
                for _ in 0..<150 { player.step(dt: 1.0 / 60) }
            }
        case "leaderboard":
            // A game whose players have leaderstats: the list top right, the numbers below.
            var stats = ScriptObject.blank(language: .luau)
            stats.name = "Leaderstats"
            stats.source = """
            local player = game:GetService("Players").LocalPlayer
            local leaderstats = Instance.new("Folder")
            leaderstats.Name = "leaderstats"
            leaderstats.Parent = player
            for name, value in { Coins = 1250, Kills = 7 } do
            \tlocal stat = Instance.new("IntValue")
            \tstat.Name = name
            \tstat.Value = value
            \tstat.Parent = leaderstats
            end
            """
            session.model.scripts.append(stats)
            session.play()
            if let player = session.player {
                for _ in 0..<40 { player.step(dt: 1.0 / 60) }
            }
        case "chat":
            session.play()
            if let player = session.player {
                for _ in 0..<6 { player.step(dt: 1.0 / 60) }
                player.receiveChat(from: "Sam", text: "anyone want to race to the tower?")
                player.receiveChat(from: "Robin", text: "sure, go!")
                player.receiveChat(from: "Alex", text: "wait for me")
                player.key("Slash", pressed: true)
                for _ in 0..<3 { player.step(dt: 1.0 / 60) }
                player.key("Slash", pressed: false)
                for character in "on my way" { player.typeKey(keyCode: 0, characters: String(character)) }
                player.step(dt: 1.0 / 60)
            }
        default: session.screen = .menu
        }
        let size = NSRect(x: 0, y: 0, width: 1100, height: 680)
        let root: AnyView
        if screen == "chat" || screen == "leaderboard" || screen == "talk", let player = session.player {
            root = AnyView(ZStack {
                LinearGradient(colors: [Color(red: 0.45, green: 0.68, blue: 0.95), Color(red: 0.78, green: 0.88, blue: 0.98)],
                               startPoint: .top, endPoint: .bottom)
                GuiLayer(store: player.gui)
            })
        } else {
            root = AnyView(ClientRootView(session: session))
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return false }
        session.browser.stop()
        session.leaveGame()
        print("Wrote \(url.path)")
        return true
    }
}
