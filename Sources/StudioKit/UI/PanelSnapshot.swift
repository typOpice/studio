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
            print("Unknown panel \"\(panel)\" — try animation, inspector, lighting, explorer or ribbon.")
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
        let size = NSRect(x: 0, y: 0, width: 1400, height: state == "mesh" ? 1500 : 880)
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

    /// `--render-client menu|character|join|chat out.png`: a client screen, drawn off
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
        switch screen {
        case "character": session.screen = .character
        case "join": session.screen = .join
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
        if screen == "chat", let player = session.player {
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
