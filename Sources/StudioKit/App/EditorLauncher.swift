import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

final class EditorAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = SceneModel()
    lazy var session = EditorSession(model: model)
    lazy var document = SceneDocument(model: model)
    var window: NSWindow!
    private var titleObserver: AnyCancellable?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = ContentView(model: model, session: session)
        let hosting = NSHostingView(rootView: content)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = document.windowTitle
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.minSize = NSSize(width: 980, height: 620)
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.mainMenu = makeMainMenu()
        // Esc is the way out of any selection, wherever the keyboard is in the window.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.session.monitorKey(event, editorWindow: self.window)
        }
        RecentDocuments.note = { url in
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        // Keep the title bar's name and edited dot in step with the document.
        titleObserver = model.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTitle() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshTitle() {
        window.title = document.windowTitle
        window.isDocumentEdited = document.isDirty
        window.representedURL = document.url
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscardingChanges(verb: "quit") ? .terminateNow : .terminateCancel
    }

    /// Returns true when it is safe to throw away the current scene.
    private func confirmDiscardingChanges(verb: String) -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.displayName)?"
        alert.informativeText = "Your creation has unsaved changes. They will be lost if you \(verb) without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveScene()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - Menus

    /// The menu bar. Built by a function of its own so the self-tests can look it over.
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Studio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(to: fileMenu, "New Scene", #selector(newScene), "n")
        add(to: fileMenu, "Open…", #selector(openScene), "o")

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.perform(Selector(("_setMenuName:")), with: "NSRecentDocumentsMenu")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(.separator())
        add(to: fileMenu, "Close Tab", #selector(closeTab), "w")
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Save", #selector(saveMenuAction), "s")
        add(to: fileMenu, "Save As…", #selector(saveAsMenuAction), "S", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Save Selection as Model…", #selector(saveModel), "e")
        add(to: fileMenu, "Insert Model…", #selector(insertModel), "i")
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Load Starter Scene", #selector(loadStarter), "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(to: editMenu, "Undo", #selector(undo), "z")
        add(to: editMenu, "Redo", #selector(redo), "Z")
        editMenu.addItem(.separator())
        // No target: AppKit sends these to whatever text has the keyboard — the code
        // editor, or a name being typed — and greys them out when nothing can take them.
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        add(to: editMenu, "Duplicate", #selector(duplicate), "d")
        add(to: editMenu, "Delete", #selector(deleteSelection), "\u{8}")
        add(to: editMenu, "Select All", #selector(selectAll), "a")
        editMenu.addItem(.separator())
        add(to: editMenu, "Group as Model", #selector(groupModel), "g")
        add(to: editMenu, "Group as Folder", #selector(groupFolder), "g", modifiers: [.command, .option])
        add(to: editMenu, "Ungroup", #selector(ungroupSelection), "u", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        add(to: editMenu, "Weld", #selector(weldTool), "j")
        add(to: editMenu, "Hinge", #selector(joinHinge), "j", modifiers: [.command, .shift])
        add(to: editMenu, "Ball Socket", #selector(joinBallSocket), "")
        add(to: editMenu, "Rope", #selector(joinRope), "")
        add(to: editMenu, "Spring", #selector(joinSpring), "")
        add(to: editMenu, "Slider", #selector(joinPrismatic), "")
        add(to: editMenu, "Weld Whole Selection", #selector(weldSelection), "j", modifiers: [.command, .option])
        add(to: editMenu, "Unjoin Selection", #selector(unjoinSelection), "j", modifiers: [.command, .control])
        editMenu.addItem(.separator())
        add(to: editMenu, "Deselect All", #selector(deselectAll), "D")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let insertItem = NSMenuItem()
        let insertMenu = NSMenu(title: "Insert")
        add(to: insertMenu, "Block", #selector(insertBlock), "1", modifiers: [.command, .shift])
        add(to: insertMenu, "Sphere", #selector(insertSphere), "2", modifiers: [.command, .shift])
        add(to: insertMenu, "Cylinder", #selector(insertCylinder), "3", modifiers: [.command, .shift])
        add(to: insertMenu, "Wedge", #selector(insertWedge), "4", modifiers: [.command, .shift])
        add(to: insertMenu, "Truss", #selector(insertTruss), "")
        insertItem.submenu = insertMenu
        mainMenu.addItem(insertItem)

        let testItem = NSMenuItem()
        let testMenu = NSMenu(title: "Test")
        add(to: testMenu, "Play / Stop", #selector(togglePlay), "p")
        // F8, as in Roblox Studio.
        add(to: testMenu, "Run / Stop", #selector(toggleRun), String(Character(UnicodeScalar(NSF8FunctionKey)!)),
            modifiers: [])
        add(to: testMenu, "Open in Client…", #selector(launchClient), "P", modifiers: [.command, .shift])
        testMenu.addItem(.separator())
        add(to: testMenu, "New Script", #selector(newScript), "k", modifiers: [.command, .shift])
        add(to: testMenu, "New Wren Script", #selector(newWrenScript), "")
        add(to: testMenu, "New Shader", #selector(newShader), "y", modifiers: [.command, .shift])
        add(to: testMenu, "New Screen Effect", #selector(newScreenShader), "")
        add(to: testMenu, "Show Output", #selector(showOutput), "0")
        add(to: testMenu, "Clear Output", #selector(clearOutput), "k")
        testItem.submenu = testMenu
        mainMenu.addItem(testItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(to: viewMenu, "Focus Selection", #selector(focusSelection), "f", modifiers: [.command])
        add(to: viewMenu, "Toggle Grid", #selector(toggleGrid), "g", modifiers: [.command, .control])
        add(to: viewMenu, "Toggle Local Space", #selector(toggleLocal), "l", modifiers: [.command])
        viewMenu.addItem(.separator())
        add(to: viewMenu, "Show World", #selector(showWorld), "")
        add(to: viewMenu, "Split View", #selector(toggleSplitView), "\\")
        // ⇧⌘] and ⇧⌘[: AppKit matches the shifted character, as with Redo's "Z".
        add(to: viewMenu, "Next Tab", #selector(nextTab), "}")
        add(to: viewMenu, "Previous Tab", #selector(previousTab), "{")
        add(to: viewMenu, "Show or Hide Output", #selector(toggleOutput), "0", modifiers: [.command, .option])
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        return mainMenu
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                     modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Menu actions

    @objc private func newScene() {
        guard confirmDiscardingChanges(verb: "start a new scene") else { return }
        session.stopPlay()
        document.reset()
        refreshTitle()
    }

    @objc private func loadStarter() {
        guard confirmDiscardingChanges(verb: "load the starter scene") else { return }
        session.stopPlay()
        model.loadStarterScene()
        refreshTitle()
    }

    @objc private func newScript() {
        let parent = model.selection.count == 1 ? model.selection.first : nil
        session.openScript(model.addScript(parentID: parent))
    }

    @objc private func newShader() {
        let id = model.addShader()
        if !model.selection.isEmpty { model.assignShader(id, to: model.selection) }
        session.openShader(id)
    }

    @objc private func newScreenShader() {
        session.openShader(model.addShader(kind: .screen))
    }

    @objc private func newWrenScript() {
        let parent = model.selection.count == 1 ? model.selection.first : nil
        session.openScript(model.addScript(parentID: parent, language: .wren))
    }

    @objc private func showOutput() { session.showDock(.output) }
    @objc private func toggleOutput() { session.dockVisible.toggle() }
    @objc private func clearOutput() { session.console.clear() }
    @objc private func closeTab() { session.closeActiveDocument() }
    @objc private func showWorld() { session.showWorld() }
    @objc private func nextTab() { session.selectAdjacentTab(1) }
    @objc private func previousTab() { session.selectAdjacentTab(-1) }

    // Commands that mean something in text go to the code editor while it has the
    // keyboard; the world only gets them when it is the one being edited.
    private var keyResponder: NSResponder? { NSApp.keyWindow?.firstResponder ?? window?.firstResponder }
    @objc private func undo() { if !TextCommand.perform(.undo, in: keyResponder) { model.undo() } }
    @objc private func redo() { if !TextCommand.perform(.redo, in: keyResponder) { model.redo() } }
    @objc private func duplicate() { model.duplicateSelected() }
    @objc private func deleteSelection() {
        if !TextCommand.perform(.deleteToLineStart, in: keyResponder) { model.deleteSelected() }
    }
    @objc private func selectAll() { if !TextCommand.perform(.selectAll, in: keyResponder) { model.selectAll() } }
    @objc private func deselectAll() { session.deselectAll() }
    @objc private func groupModel() {
        if !TextCommand.perform(.findNext, in: keyResponder) { model.groupSelection(kind: .model) }
    }
    @objc private func weldSelection() { model.weldSelection() }
    @objc private func unjoinSelection() { model.unjoinSelection() }
    @objc private func weldTool() { join(.weld) }
    @objc private func joinHinge() { join(.hinge) }
    @objc private func joinBallSocket() { join(.ballSocket) }
    @objc private func joinRope() { join(.rope) }
    @objc private func joinSpring() { join(.spring) }
    @objc private func joinPrismatic() { join(.prismatic) }

    /// Arms the tool: it joins the selection right away when there is one to join,
    /// and otherwise waits for the two parts to be clicked in the viewport.
    private func join(_ kind: SceneConstraint.Kind) {
        model.armJoinTool(kind)
    }
    @objc private func groupFolder() { model.groupSelection(kind: .folder) }
    @objc private func ungroupSelection() {
        for id in model.selection where model.group(id: id) != nil { model.ungroup(id) }
    }
    @objc private func focusSelection() {
        if !TextCommand.perform(.find, in: keyResponder) {
            session.showWorld()
            session.viewport.focusSelection()
        }
    }

    /// Menu items say what they will do: with a code editor in charge, ⌘F finds rather
    /// than focusing the camera, ⌘G finds the next match rather than grouping.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let inCode = keyResponder is CodeTextView
        switch item.action {
        case #selector(focusSelection): item.title = inCode ? "Find…" : "Focus Selection"
        case #selector(groupModel): item.title = inCode ? "Find Next" : "Group as Model"
        case #selector(deleteSelection): item.title = inCode ? "Delete to Start of Line" : "Delete"
        case #selector(closeTab): return session.activeDocument != nil
        default: break
        }
        return true
    }
    @objc private func toggleGrid() { model.showGrid.toggle() }
    @objc private func toggleLocal() { model.localSpace.toggle() }

    @objc private func togglePlay() { session.togglePlay() }
    @objc private func toggleSplitView() { session.toggleSplitView() }
    @objc private func toggleRun() { session.toggleRun() }
    @objc private func launchClient() { LaunchClient.launch(with: model) }

    @objc private func insertBlock() { session.viewport.insertPart(shape: .block, atScreenPoint: nil) }
    @objc private func insertSphere() { session.viewport.insertPart(shape: .sphere, atScreenPoint: nil) }
    @objc private func insertCylinder() { session.viewport.insertPart(shape: .cylinder, atScreenPoint: nil) }
    @objc private func insertWedge() { session.viewport.insertPart(shape: .wedge, atScreenPoint: nil) }
    @objc private func insertTruss() { session.viewport.insertPart(shape: .truss, atScreenPoint: nil) }

    // MARK: - Documents

    @objc private func saveMenuAction() { _ = saveScene() }
    @objc private func saveAsMenuAction() { _ = saveSceneAs() }

    /// Saves in place when the scene already has a file, otherwise prompts.
    @discardableResult
    private func saveScene() -> Bool {
        guard let url = document.url else { return saveSceneAs() }
        do {
            try document.save(to: url)
            refreshTitle()
            return true
        } catch {
            present(error, "Could not save \(url.lastPathComponent)")
            return false
        }
    }

    @discardableResult
    private func saveSceneAs() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.suggestedFileName
        panel.allowedContentTypes = [SceneDocument.sceneType]
        panel.canCreateDirectories = true
        panel.message = "Save this creation, with its parts and scripts."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try document.save(to: url)
            refreshTitle()
            return true
        } catch {
            present(error, "Could not save \(url.lastPathComponent)")
            return false
        }
    }

    @objc private func openScene() {
        guard confirmDiscardingChanges(verb: "open another scene") else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [SceneDocument.sceneType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(url)
    }

    /// Also used by the Open Recent menu, which sends `application:openFile:`.
    func openDocument(_ url: URL) {
        session.stopPlay()
        do {
            try document.open(url)
            refreshTitle()
        } catch {
            present(error, "Could not open \(url.lastPathComponent)")
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard confirmDiscardingChanges(verb: "open another scene") else { return false }
        openDocument(URL(fileURLWithPath: filename))
        return true
    }

    @objc private func saveModel() {
        guard !model.selection.isEmpty else {
            model.statusText = "Select the parts to save as a model first"
            NSSound.beep()
            return
        }
        let suggested = model.selectedParts.count == 1 ? model.selectedParts[0].name : "Model"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggested).\(SceneDocument.modelExtension)"
        panel.allowedContentTypes = [SceneDocument.modelType]
        panel.message = "Save the selected parts, and any scripts inside them, as a reusable model."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = try document.modelData(name: url.deletingPathExtension().lastPathComponent) else { return }
            try data.write(to: url, options: .atomic)
            model.statusText = "Saved model \(url.lastPathComponent)"
        } catch {
            present(error, "Could not save \(url.lastPathComponent)")
        }
    }

    @objc private func insertModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [SceneDocument.modelType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Drop it where the camera is looking.
            let target = session.viewport.camera.target
            let count = try document.insertModel(from: Data(contentsOf: url), at: target)
            model.statusText = "Inserted \(count) part\(count == 1 ? "" : "s") from \(url.lastPathComponent)"
            refreshTitle()
        } catch {
            present(error, "Could not insert \(url.lastPathComponent)")
        }
    }

    private func present(_ error: Error, _ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
        model.statusText = message
    }
}

/// Entry point for the editor executable.
public enum StudioEditor {
    public static func run() -> Never {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-panel") {
            let arguments = CommandLine.arguments
            let panel = flag + 1 < arguments.count ? arguments[flag + 1] : "animation"
            let path = flag + 2 < arguments.count ? arguments[flag + 2] : "\(panel).png"
            let ok = MainActor.assumeIsolated { PanelSnapshot.render(panel: panel, to: URL(fileURLWithPath: path)) }
            exit(ok ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-client") {
            let arguments = Array(CommandLine.arguments[(flag + 1)...])
            let screen = arguments.first ?? "menu"
            let path = arguments.count > 1 ? arguments[1] : "client-\(screen).png"
            let ok = MainActor.assumeIsolated { PanelSnapshot.renderClient(screen: screen, to: URL(fileURLWithPath: path)) }
            exit(ok ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-window") {
            let arguments = Array(CommandLine.arguments[(flag + 1)...])
            let state = arguments.first ?? "script"
            let path = arguments.count > 1 ? arguments[1] : "\(state)-window.png"
            let ok = MainActor.assumeIsolated { PanelSnapshot.renderWindow(showing: state, to: URL(fileURLWithPath: path)) }
            exit(ok ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-scene") {
            let arguments = Array(CommandLine.arguments[(flag + 1)...])
            let path = arguments.first ?? "scene.png"
            let technology: LightingTechnology = arguments.dropFirst().first?.lowercased().hasPrefix("ray") == true
                ? .rayTraced : .conventional
            let clock = arguments.count > 2 ? Float(arguments[2]) : nil
            exit(AvatarSnapshot.renderScene(to: URL(fileURLWithPath: path), technology: technology,
                                            clockTime: clock) ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-car") {
            let arguments = Array(CommandLine.arguments[(flag + 1)...])
            let path = arguments.first ?? "car.png"
            let seconds = arguments.count > 1 ? Float(arguments[1]) ?? 1.5 : 1.5
            exit(AvatarSnapshot.renderCar(to: URL(fileURLWithPath: path), seconds: seconds) ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-physics") {
            let arguments = Array(CommandLine.arguments[(flag + 1)...])
            let path = arguments.first ?? "physics.png"
            let seconds = arguments.count > 1 ? Float(arguments[1]) ?? 1.2 : 1.2
            exit(AvatarSnapshot.renderPhysics(to: URL(fileURLWithPath: path), seconds: seconds) ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-avatar") {
            let arguments = CommandLine.arguments
            let path = flag + 1 < arguments.count ? arguments[flag + 1] : "avatar.png"
            exit(AvatarSnapshot.render(to: URL(fileURLWithPath: path)) ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = EditorAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}
