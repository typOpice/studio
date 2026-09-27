import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ClientAppDelegate: NSObject, NSApplicationDelegate {
    let session = ClientSession()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Studio Client"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ClientRootView(session: session))
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // A scene on the command line — Studio's "Open in Client" — is played straight
        // away; started on its own, the client opens on the game picker.
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = arguments.first {
            do {
                try session.open(URL(fileURLWithPath: path))
                session.play()
            } catch {
                NSLog("Could not open \(path): \(error)")
            }
        } else {
            session.showGames()
        }

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Studio Client", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Studio Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(to: fileMenu, "Choose a Game…", #selector(chooseGame), "g", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Open Scene…", #selector(openScene), "o")
        add(to: fileMenu, "Load Starter Scene", #selector(loadStarter), "")
        add(to: fileMenu, "Load \(AdventureIsland.name)", #selector(loadAdventure), "")
        add(to: fileMenu, "Load \(Nightfall.name)", #selector(loadNightfall), "")
        add(to: fileMenu, "Load \(MegaObby.name)", #selector(loadMegaObby), "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let playItem = NSMenuItem()
        let playMenu = NSMenu(title: "Player")
        add(to: playMenu, "Main Menu", #selector(backToMenu), "l")
        add(to: playMenu, "Rerun Scripts", #selector(rerunScripts), "r", modifiers: [.command, .shift])
        playMenu.addItem(.separator())
        let fullScreen = playMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        playItem.submenu = playMenu
        mainMenu.addItem(playItem)

        NSApp.mainMenu = mainMenu
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                     modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    @objc private func backToMenu() { session.leaveGame() }
    @objc private func chooseGame() { session.showGames() }
    @objc private func rerunScripts() {
        guard let player = session.player else { return }
        player.console.clear()
        player.scripts.stop()
        player.scripts.start()
    }

    @objc private func loadStarter() { session.loadStarterScene() }
    @objc private func loadAdventure() { session.loadAdventureIsland() }
    @objc private func loadNightfall() { session.loadNightfall() }
    @objc private func loadMegaObby() { session.loadMegaObby() }

    @objc private func openScene() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, SceneDocument.sceneType]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.session.open(url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not open \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

/// Entry point for the client executable.
public enum StudioClientApp {
    public static func run() -> Never {
        // An Objective-C exception (AVFoundation's, say) ends the app with a crash report,
        // rather than AppKit swallowing it mid-frame and leaving the game frozen.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        let app = NSApplication.shared
        let delegate = ClientAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}
