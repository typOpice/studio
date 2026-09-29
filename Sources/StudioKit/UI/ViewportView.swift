import SwiftUI
import Combine
import MetalKit
import simd

/// MTKView subclass that routes input either to the editor controller or,
/// while a play session is running, to the character controller.
///
/// In play the mouse works as in Roblox: in third person the pointer is free — it
/// points and clicks at the world and the GUI — and right-drag turns the camera; in
/// first person, or when a script sets MouseBehavior, the pointer is captured and moving
/// the mouse looks around. Escape frees a captured pointer until the next click.
final class StudioMTKView: MTKView {
    var editor: ViewportController?
    var player: PlayController? {
        didSet {
            typingWatch = nil
            captureWatch = nil
            cursorWatch = nil
            cursorAssetsWatch = nil
            if player == nil {
                releaseMouse()
                oldValue?.mouseCaptured = false
                wantsCapture = false
                oldValue?.releaseAllKeys()
                NSCursor.arrow.set()
            } else {
                syncViewSize()
                // Keys reach a TextBox through this view, so it takes the keyboard when
                // one is focused — even by a click on the GUI before any on the game.
                typingWatch = player?.gui.$focused.sink { [weak self] focused in
                    guard let self, focused != nil, self.showsWorld else { return }
                    self.window?.makeFirstResponder(self)
                }
                // First person, shift lock, or a script's MouseBehavior holds the pointer.
                if let hud = player?.hud {
                    cursorWatch = hud.$cursorIcon.sink { [weak self] name in
                        self?.cursorName = name
                        self?.refreshCursor()
                    }
                    captureWatch = hud.$firstPerson.combineLatest(hud.$mouseLock, hud.$shiftLock)
                        .sink { [weak self] firstPerson, locked, shiftLock in
                            self?.wantsCapture = firstPerson || locked || shiftLock
                        }
                }
                cursorAssetsWatch = player?.model.$assets.sink { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.refreshCursor() }
                }
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    private var typingWatch: AnyCancellable?
    private var captureWatch: AnyCancellable?
    private var cursorWatch: AnyCancellable?
    private var cursorAssetsWatch: AnyCancellable?
    private var windowFocusWatch: NSObjectProtocol?
    private let cursorImages = MouseCursor()
    private var cursorName = ""
    private var pointerInside = false

    var playCursor: NSCursor {
        guard showsWorld, let player else { return .arrow }
        return cursorImages.resolve(cursorName, assets: player.model.assets)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if showsWorld && player != nil { addCursorRect(bounds, cursor: playCursor) }
    }

    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
        if pointerInside && window?.isKeyWindow == true && !mouseCaptured { playCursor.set() }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshCursor()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        if !mouseCaptured { NSCursor.arrow.set() }
    }
    /// Whether play wants the pointer held now; Escape lets go until the next click.
    private var wantsCapture = false {
        didSet {
            guard wantsCapture != oldValue else { return }
            if wantsCapture { captureMouse() } else { releaseMouse() }
        }
    }
    /// Turning the camera with the right button held, in third person.
    private var rightDragging = false
    /// False in split view, where the keyboard stays wherever it was clicked last.
    var takesKeyboard = true

    private var draggingGizmo = false
    private var mouseCaptured = false
    private var renderLink: AnyObject?
    private var renderTimer: Timer?
    private var backgroundTimer: Timer?

    /// Runs a frame's worth of everything but drawing — set by `ViewportView` to the
    /// renderer's `tick`.
    var backgroundTick: (() -> Void)?
    /// Ticks run while hidden, so tests can see the world kept going.
    private(set) var backgroundTicks = 0

    /// False while a script or shader tab covers the world. Nothing is drawn and the
    /// view takes no mouse or keys, but a play test keeps running and edited shaders
    /// keep compiling, on a timer of their own — a display link may pause for a
    /// hidden view.
    var showsWorld = true {
        didSet {
            guard showsWorld != oldValue else { return }
            isHidden = !showsWorld
            if showsWorld {
                stopBackgroundTicks()
                if takesKeyboard { window?.makeFirstResponder(self) }
            } else {
                // Let go of everything held, so nothing is stuck down on return.
                releaseMouse()
                NSCursor.arrow.set()
                player?.releaseAllKeys()
                editor?.clearFlyKeys()
                editor?.orbiting = false
                if draggingGizmo {
                    editor?.mouseUp()
                    draggingGizmo = false
                }
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
                startBackgroundTicks()
            }
        }
    }

    /// Frames this view has asked for, so the status bar can show that the viewport
    /// is genuinely live rather than merely present.
    private(set) var framesRequested = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowFocusWatch { NotificationCenter.default.removeObserver(windowFocusWatch) }
        windowFocusWatch = nil
        guard window != nil else {
            releaseMouse()
            stopRenderLoop()
            return
        }
        windowFocusWatch = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                self?.releaseMouse()
                self?.player?.releaseAllKeys()
                NSCursor.arrow.set()
            }
        if showsWorld {
            window?.makeFirstResponder(self)
        } else {
            startBackgroundTicks()
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        startRenderLoop()
    }

    deinit {
        if let windowFocusWatch { NotificationCenter.default.removeObserver(windowFocusWatch) }
        releaseMouse()
        renderTimer?.invalidate()
    }

    // MARK: - Render loop

    /// Drives drawing from an explicit display link, with a timer as a safety net.
    ///
    /// `MTKView`'s own timer and `CADisplayLink` are both driven by a display's vsync.
    /// In a session with no display attached — headless, or screen-sharing only — they
    /// never fire at all: the delegate, device and drawable are perfectly valid and a
    /// manual `draw()` renders correctly, but no frames are ever requested. Owning the
    /// loop lets us notice that and fall back to a plain run-loop timer.
    func startRenderLoop() {
        stopRenderLoop()
        isPaused = true
        enableSetNeedsDisplay = false
        framesRequested = 0

        guard #available(macOS 14.0, *) else {
            startTimerLoop()
            return
        }
        let link = displayLink(target: self, selector: #selector(renderLoopFired))
        link.add(to: .main, forMode: .common)
        renderLink = link

        // On a normal Mac this has already delivered ~45 frames by now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.window != nil, self.framesRequested == 0 else { return }
            self.startTimerLoop()
        }
    }

    private func startTimerLoop() {
        invalidateSources()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.renderLoopFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    func stopRenderLoop() {
        invalidateSources()
        stopBackgroundTicks()
    }

    private func startBackgroundTicks() {
        stopBackgroundTicks()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.window != nil else { return }
            self.backgroundTicks += 1
            self.backgroundTick?()
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    private func stopBackgroundTicks() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func invalidateSources() {
        if #available(macOS 14.0, *), let link = renderLink as? CADisplayLink {
            link.invalidate()
        }
        renderLink = nil
        renderTimer?.invalidate()
        renderTimer = nil
    }

    @objc private func renderLoopFired() {
        // A view with no window or no area has nothing to present, and a hidden one
        // is ticked by its background timer instead.
        guard window != nil, showsWorld, bounds.width > 0, bounds.height > 0 else { return }
        framesRequested += 1
        draw()
    }

    // MARK: - Mouse capture (play mode)

    private func captureMouse() {
        guard !mouseCaptured, player != nil, showsWorld else { return }
        mouseCaptured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        player?.mouseCaptured = true
    }

    private func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        player?.mouseCaptured = false
        refreshCursor()
    }

    /// Converts an AppKit event into top-left origin view coordinates.
    private func viewPoint(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2<Float>(Float(p.x), Float(bounds.height - p.y))
    }

    private func syncViewSize() {
        let size = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        editor?.viewSize = size
        player?.viewSize = size
    }

    /// Where the pointer is, for the Mouse and ClickDetectors.
    private func trackPointer(_ event: NSEvent, moved: Bool = false) {
        player?.viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        if moved {
            player?.mousePointerMoved(to: viewPoint(event))
        } else {
            player?.pointer = viewPoint(event)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let player {
            player.viewSize = SIMD2(Float(bounds.width), Float(bounds.height))
            let surfacePoint = mouseCaptured ? player.viewSize / 2 : viewPoint(event)
            if player.clickSurface(at: surfacePoint) { return }
            // A click on the game, not the GUI, stops typing, as in Roblox.
            if player.isTyping { player.gui.releaseFocus(enterPressed: false) }
            // A pointer let go of with Escape is taken back by a click, not used.
            if wantsCapture && !mouseCaptured {
                captureMouse()
                return
            }
            if !mouseCaptured { trackPointer(event) }
            player.mouseButton(1, pressed: true)
            return
        }
        syncViewSize()
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        draggingGizmo = editor?.mouseDown(at: viewPoint(event), additive: additive,
                                          alternate: event.modifierFlags.contains(.option)) ?? false
    }

    override func mouseDragged(with event: NSEvent) {
        if let player {
            if mouseCaptured {
                player.look(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
                player.mousePointerMoved(to: nil, delta: SIMD2(Float(event.deltaX), Float(event.deltaY)))
            } else {
                trackPointer(event, moved: true)
            }
            return
        }
        syncViewSize()
        if draggingGizmo {
            editor?.mouseDragged(to: viewPoint(event))
        } else {
            // Left-drag on empty space orbits, which keeps trackpad-only use workable.
            editor?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let player {
            player.mouseButton(1, pressed: false)
            return
        }
        editor?.mouseUp()
        draggingGizmo = false
    }

    override func mouseMoved(with event: NSEvent) {
        if let player {
            if mouseCaptured {
                player.look(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
                player.mousePointerMoved(to: nil, delta: SIMD2(Float(event.deltaX), Float(event.deltaY)))
            } else {
                trackPointer(event, moved: true)
            }
            return
        }
        syncViewSize()
        editor?.updateHover(at: viewPoint(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let player {
            player.mouseButton(2, pressed: true)
            // Right-drag turns the camera; the pointer stays put while it does.
            if !mouseCaptured {
                rightDragging = true
                CGAssociateMouseAndMouseCursorPosition(0)
            }
            return
        }
        editor?.orbiting = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        if let player {
            player.look(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
            player.mousePointerMoved(to: nil, delta: SIMD2(Float(event.deltaX), Float(event.deltaY)))
            return
        }
        if event.modifierFlags.contains(.shift) {
            editor?.pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else {
            editor?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if let player {
            player.mouseButton(2, pressed: false)
            if rightDragging {
                rightDragging = false
                if !mouseCaptured { CGAssociateMouseAndMouseCursorPosition(1) }
            }
            return
        }
        editor?.orbiting = false
        editor?.clearFlyKeys()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard player == nil else { return }
        editor?.pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        // Over a ScrollingFrame, the wheel scrolls it rather than zooming.
        if let player, !mouseCaptured {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let point = viewPoint(event)
            if player.gui.scroll(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
                                 by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)) {
                return
            }
            if player.scrollSurface(at: point, by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)) { return }
        }
        let amount = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY)
        if let player { player.zoom(amount) } else { editor?.zoom(amount) }
    }

    /// ⌘A, ⌘C, ⌘X and ⌘V belong to a TextBox being typed in, before the menu sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let player, player.isTyping, showsWorld, window?.firstResponder === self,
           event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers,
           player.typeCommand(key) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        let amount = Float(event.magnification) * 12
        if let player { player.zoom(amount) } else { editor?.zoom(amount) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Keys are for the world only while it shows: Delete with a script in front must
        // never delete parts behind it.
        guard showsWorld else { return }
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if let player {
            // A TextBox has the keyboard: the keys type, and never reach the game.
            if player.isTyping {
                player.typeKey(keyCode: event.keyCode, characters: event.characters ?? "")
                return
            }
            if event.keyCode == 53 {           // escape releases the pointer
                releaseMouse()
                return
            }
            // Every key goes to scripts as a physical key: moving and jumping are the
            // ControlScript; flying, respawning and the output window (`) are the
            // default HUD's scripts in StarterGui — nothing here.
            player.key(KeyCodes.name(virtualKey: event.keyCode), pressed: true)
            return
        }

        let model = editor?.model
        if let guiKeys = editor?.guiKeys, guiKeys(event.keyCode, event.modifierFlags.contains(.shift)) { return }
        switch key {
        case "1": model?.selectGizmo(.select)
        case "2": model?.selectGizmo(.move)
        case "3": model?.selectGizmo(.scale)
        case "4": model?.selectGizmo(.rotate)
        case "f": editor?.focusSelection()
        case "g": model?.showGrid.toggle()
        case "l": model?.localSpace.toggle()
        case "t": model?.snapEnabled.toggle()
        case "w", "a", "s", "d", "q", "e":
            editor?.setFlyKey(key, pressed: true)
        default:
            if event.keyCode == 51 || event.keyCode == 117 {  // delete / forward delete
                model?.deleteSelected()
            } else if event.keyCode == 53 {                   // escape: nothing selected at all
                model?.deselectAll()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if let player {
            player.key(KeyCodes.name(virtualKey: event.keyCode), pressed: false)
            return
        }
        if ["w", "a", "s", "d", "q", "e"].contains(key) {
            editor?.setFlyKey(key, pressed: false)
        } else {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if let player {
            // A modifier's own key code says which one changed; its flag says which way.
            let flags = event.modifierFlags
            let down: Bool
            switch event.keyCode {
            case 56, 60: down = flags.contains(.shift)
            case 59, 62: down = flags.contains(.control)
            case 58, 61: down = flags.contains(.option)
            case 55: down = flags.contains(.command)
            default: return
            }
            player.key(KeyCodes.name(virtualKey: event.keyCode), pressed: down)
        } else {
            editor?.setFlyKey("shift", pressed: shift)
        }
    }
}

/// Bridges the Metal viewport into SwiftUI. `source` may switch between the
/// editor controller and a play session without rebuilding the Metal stack.
struct ViewportView: NSViewRepresentable {
    let editor: ViewportController?
    let player: PlayController?
    /// False while a script or shader tab is in front of the world.
    var showsWorld = true
    /// False in split view: the viewport shares the window with a tab, and only takes the
    /// keyboard when clicked, never by itself.
    var takesKeyboard = true

    init(editor: ViewportController? = nil, player: PlayController? = nil, showsWorld: Bool = true,
         takesKeyboard: Bool = true) {
        self.editor = editor
        self.player = player
        self.showsWorld = showsWorld
        self.takesKeyboard = takesKeyboard
    }

    private var source: ViewportSource? { player ?? editor }

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> StudioMTKView {
        let view = StudioMTKView(frame: .zero)
        view.editor = editor
        guard let device = MTLCreateSystemDefaultDevice(), let source else {
            NSLog("No Metal device available")
            return view
        }
        let renderer = Renderer(device: device, view: view, source: source)
        context.coordinator.renderer = renderer
        view.delegate = renderer
        view.backgroundTick = { [weak renderer] in renderer?.tick() }
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        // The loop is started from viewDidMoveToWindow, once there is a window to draw into.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: StudioMTKView, context: Context) {
        nsView.editor = editor
        nsView.takesKeyboard = takesKeyboard
        // Before the player: Play pressed from a script tab shows the world and starts
        // the game in one update, and the game can only take the mouse once it shows.
        nsView.showsWorld = showsWorld
        if nsView.player !== player {
            nsView.player = player
        }
        if let source { context.coordinator.renderer?.source = source }
        editor?.viewSize = SIMD2<Float>(Float(nsView.bounds.width), Float(nsView.bounds.height))
        if player != nil, showsWorld, takesKeyboard { nsView.window?.makeFirstResponder(nsView) }
    }
}
