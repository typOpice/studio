import AppKit
import SwiftUI

/// Verification for selecting in Studio: one thing picked at a time, so picking a part,
/// a GUI object, a Sound, a file, a script or empty space never leaves an older pick to
/// come back in the Explorer and Properties; and Esc, from anywhere in the window, as the
/// way out of every selection. Studio-only: selections are never sent to other players,
/// so there is no multiplayer side.
enum SelectionSelfTest {

    static func run(check: Checker) {
        print("\nStudio: selecting and Esc")
        let model = SceneModel()
        model.starterGui = []
        let session = EditorSession(model: model)
        guard let part = model.parts.first?.id else {
            check("the starter scene has parts", false)
            return
        }

        // Picking one kind of thing lets go of the others.
        let frame = model.insertGui(.frame)!
        model.selection = [part]
        check("picking a part lets go of the GUI object picked before", model.selectedGui == nil)
        model.selectedGui = frame
        check("…and picking a GUI object lets go of the part", model.selection.isEmpty)
        _ = try? model.importAsset(data: AudioSelfTest.wav(seconds: 0.1), name: "Beep", fileExtension: "wav")
        check("importing a file picks it, letting go of the GUI object", model.selectedAsset != nil && model.selectedGui == nil)
        let sound = model.addSound(in: part)
        check("a new Sound is picked alone", model.selectedSound == sound && model.selectedAsset == nil)
        let script = model.addScript(parentID: nil)
        check("…as is a script", model.selectedScript == script && model.selectedSound == nil)
        model.selection = [part]
        let added = model.addScript(parentID: part)
        check("a script added to a picked part leaves the part picked",
              model.selectedScript == added && model.selection == [part])
        model.selection = [part]
        check("picking a part lets go of a script", model.selectedScript == nil)

        // The bug: an old pick coming back after clicking empty space.
        model.selectedGui = frame
        model.selection = [part]
        let controller = session.viewport
        controller.viewSize = SIMD2(800, 600)
        // Somewhere the view shows no part (the sky), away from the gizmo in the middle.
        let candidates = stride(from: 5, to: 600, by: 20).flatMap { y in [SIMD2<Float>(10, Float(y)), SIMD2<Float>(790, Float(y))] }
        guard let sky = candidates.first(where: { Picking.pick(ray: controller.ray(at: $0), in: model.parts) == nil }) else {
            check("the view shows some empty space", false)
            return
        }
        _ = controller.mouseDown(at: sky, additive: false)
        controller.mouseUp()
        check("a click on empty space leaves nothing selected — no older pick comes back",
              !model.hasAnySelection, "part \(model.selection.count), gui \(model.selectedGui != nil)")

        // Esc: everything, at once.
        model.selection = [part]
        model.armJoinTool(.hinge)
        model.selectedAnimation = model.animations.first?.id ?? model.addAnimation()
        session.dockVisible = false
        let esc = { (modifiers: NSEvent.ModifierFlags) in session.handleEscape(keyCode: 53, modifiers: modifiers) }
        esc([.command])
        check("⌘Esc isn't Esc", !model.selection.isEmpty)
        esc([])
        check("Esc deselects everything, and puts the join tool away",
              !model.hasAnySelection && model.joinTool == nil && model.selectedAnimation == nil
              && model.statusText == "Deselected everything")
        model.selectLighting()
        esc([])
        check("…Lighting too", !model.lightingSelected)
        model.selectStarterPlayer()
        esc([])
        check("…and StarterPlayer", !model.starterPlayerSelected)
        model.selectedAnimation = model.animations.first?.id
        session.showDock(.animation)
        esc([])
        check("…but not the animation open in the Animation tab", model.selectedAnimation != nil)

        // From anywhere in the window: the key monitor sees Esc before whatever has the keyboard.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // Something else holding the keyboard, as a text field would. (A real NSTextField
        // here starts the text input service, which then holds up the network tests.)
        let field = KeyHolder(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        func key(_ code: UInt16, in target: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: target.windowNumber, context: nil, characters: "\u{1b}",
                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: code)!
        }
        model.selectedGui = frame
        let passed = session.monitorKey(key(53, in: window), editorWindow: window)
        check("Esc in the window deselects whatever holds the keyboard, and still goes on to it",
              model.selectedGui == nil && passed.keyCode == 53 && window.firstResponder === field)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        model.selectedGui = frame
        _ = session.monitorKey(key(53, in: other), editorWindow: window)
        _ = session.monitorKey(key(12, in: window), editorWindow: window)
        check("…but not Esc in another window, nor another key", model.selectedGui == frame)

        session.startPlay()
        model.selectedGui = frame
        esc([])
        check("in a play test Esc is the game's (it lets the pointer go)", model.selectedGui == frame)
        session.stopPlay()
        window.contentView = nil
    }
}

/// A view that takes the keyboard, standing in for a text field being typed in.
private final class KeyHolder: NSView {
    override var acceptsFirstResponder: Bool { true }
}
