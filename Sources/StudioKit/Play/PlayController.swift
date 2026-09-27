import Foundation
import AppKit
import simd
import QuartzCore
import Combine

/// Live readout for the HUD. Published separately from the simulation so the 60 Hz
/// physics never forces a SwiftUI re-render more than a few times a second.
/// What the view needs to know about the camera and the pointer. Everything a player
/// sees on screen during play is GUI objects — the default HUD is StarterGui's PlayerHud —
/// so there is nothing else here.
final class PlayHUD: ObservableObject {
    @Published var firstPerson = false
    @Published var mouseCaptured = false
    /// A script asked for the pointer to be locked (UserInputService.MouseBehavior).
    @Published var mouseLock = false
    /// Shift lock is on: the pointer is held in the middle.
    @Published var shiftLock = false
}

/// Runs a play session: the player's character, its Humanoid, input and scripts.
///
/// Each frame, in Roblox's order:
///   1. scripts run — they receive last frame's events and this frame's input, and
///      steer the Humanoid (the default ControlScript turns keys into `Move` calls);
///   2. physics obeys the Humanoid;
///   3. deaths and respawns are handled, and what happened is queued as events.
///
/// Conforms to `ViewportSource` (so the renderer draws it) and `PlayerBridge` (so
/// scripts reach the character through `PlayerHost.swift`).
final class PlayController: ViewportSource, PlayerBridge {
    let model: SceneModel
    let hud = PlayHUD()
    let console: ScriptConsole
    let scripts: ScriptRuntime
    let shaderStatus: ShaderStatusStore
    var shaderConsole: ScriptConsole { console }

    var character = CharacterController()
    /// Poses the avatar from what the Humanoid is doing.
    private(set) var animator = AvatarAnimator()
    /// Custom animations that scripts have loaded and played, layered over `animator`.
    var animationPlayer = AnimationPlayer()
    /// Unanchored parts fall, collide and stack (Jolt Physics).
    let physics = PhysicsWorld()
    /// This player's screen GUI — PlayerGui — made by the scripts, drawn by `GuiLayer`.
    let gui = GuiStore()
    /// What the scene's Sounds sound like, from where the camera is.
    let sounds = SoundSystem()
    /// Pictures for ImageLabels, decoded once each.
    var imageCache: [UUID: (size: Int, image: NSImage)] = [:]
    /// Sends this player's chat message to the others, in a network game (ClientSession).
    var sendChat: ((String) -> Void)?
    /// Part pairs touching last frame, for part-to-part Touched.
    private var touchingParts: Set<[UUID]> = []
    var camera = PlayerCamera()
    var humanoid: Humanoid
    private(set) var settings: StarterPlayerSettings

    /// Counts characters. Scripts address a character by its generation, so one that
    /// holds an old character cannot reach the new one.
    private(set) var characterGeneration = 0

    /// This character's appearance, which scripts may change for this session.
    var bodyColors: BodyColors
    /// What `player.Name` and the character's Name say: the client sets it from the
    /// player's profile before `start()`.
    var playerName = "Player"
    var bodyTransparency: [String: Float] = [:]
    /// The player's own look, from their profile: the client sets it before `start()`.
    /// Studio's play test has none, so characters wear StarterPlayer's.
    var playerLook: AvatarLook?
    /// What this character wears now; scripts may change it.
    var look = AvatarLook()

    var gravity: Float = CharacterController.gravity
    var respawnTime: Float
    private var deathCountdown: Float?
    var respawnRequested = false
    private var lastReportedRunSpeed: Float = 0
    /// What the body is touching now, so changes can be reported as they happen.
    private(set) var touching: Set<CharacterTouch.Touch> = []

    /// Keys held down, by Roblox KeyCode name.
    private(set) var heldKeys: Set<String> = []
    /// Everything scripts have not seen yet, as host values; drained each frame.
    var pendingEvents: [ScriptValue] = []
    /// Every line of output this session, oldest first, for LogService:GetLogHistory.
    private(set) var logHistory: [ScriptValue] = []

    private var lastTime = CACurrentMediaTime()
    private var hudClock: CFTimeInterval = 0

    var mouseCaptured = false {
        didSet { hud.mouseCaptured = mouseCaptured }
    }

    /// Player.DevEnableMouseLock: a script can take shift lock away from this player.
    var devEnableMouseLock = true {
        didSet { if !devEnableMouseLock { setShiftLock(false) } }
    }

    /// False in Studio's Run mode: the scene's scripts and physics run with no player —
    /// no character, no StarterPlayer scripts, and the editor keeps the camera.
    let hasPlayer: Bool

    init(model: SceneModel, console: ScriptConsole,
         shaderStatus: ShaderStatusStore = ShaderStatusStore(), withPlayer: Bool = true) {
        self.model = model
        self.hasPlayer = withPlayer
        self.console = console
        self.shaderStatus = shaderStatus
        self.scripts = ScriptRuntime(model: model, console: console)
        self.settings = model.starterPlayer
        self.humanoid = Humanoid(settings: model.starterPlayer)
        self.bodyColors = model.starterPlayer.bodyColors
        self.respawnTime = model.starterPlayer.respawnTime
        camera.yaw = .pi
        scripts.shaderStatus = shaderStatus
        scripts.player = withPlayer ? self : nil
        applyCameraSettings()
        gui.onFocus = { [weak self] in self?.releaseAllKeys() }
        gui.billboardPlacer = { [weak self] object, size in self?.placeBillboard(object, in: size) }
        gui.imageProvider = { [weak self] reference in self?.image(named: reference) }
        scripts.soundSystem = sounds
        scripts.clock = { [weak self] in self?.clock ?? 0 }
        // What the Output shows, LogService hears: each line the frame after.
        console.onAppend = { [weak self] line in self?.log(line) }
        scripts.logSource = { [weak self] in self?.logHistory ?? [] }
        scripts.statsSource = { [weak self] in
            guard let self else { return .nothing }
            let stats = self.frameStats
            return .list([.number(stats.frame), .number(stats.scripts), .number(stats.physics), .number(stats.draw),
                          .number(FrameStats.memoryMB()), .number(Double(self.model.parts.count)),
                          .number(Double(self.model.parts.count + self.model.groups.count + self.model.dataObjects.count
                                         + self.model.sounds.count + self.gui.objects.count))])
        }
        if !withPlayer {
            scripts.eventSource = { [weak self] in
                guard let self else { return [] }
                defer { self.pendingEvents.removeAll() }
                return self.pendingEvents
            }
        }
    }

    /// Spawns the first character, then runs the scene's scripts — scene scripts,
    /// StarterPlayerScripts, then StarterCharacterScripts for that character.
    func start() {
        model.clearLocalScreenShaders()
        BuiltinSounds.prepare(for: model)
        // A game is running: macOS mustn't nap the app when its window is hidden or
        // behind another, or its timers slow to a crawl and — hosting — the world stops
        // for everyone who joined.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Playing a game")
        scripts.runsSceneScripts = !worldFromHost
        settings = model.starterPlayer
        respawnTime = settings.respawnTime
        applyCameraSettings()
        if hasPlayer { spawnCharacter() }
        let toolScripts = hasPlayer ? copyStarterTools(to: playerID) : []
        let guiFound = hasPlayer ? copyStarterGui(resetting: false) : []
        scripts.start()
        runToolScripts(toolScripts, scope: characterGeneration)
        runGuiScripts(guiFound)
    }

    func stop() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        model.clearLocalScreenShaders()
        scripts.stop()
        sounds.stopAll()
        console.onAppend = nil
    }

    /// A line of output, for LogService: MessageOut next frame, and GetLogHistory.
    private func log(_ line: ScriptConsole.Line) {
        let type: String
        switch line.kind {
        case .output: type = "MessageOutput"
        case .info: type = "MessageInfo"
        case .warning: type = "MessageWarning"
        case .error: type = "MessageError"
        }
        logHistory.append(.list([.string(line.text), .string(type), .number(clock)]))
        if logHistory.count > Self.logKept { logHistory.removeFirst(logHistory.count - Self.logKept) }
        pendingEvents.append(.list([.string("Log"), .string(line.text), .string(type)]))
    }

    static let logKept = 200

    /// A picture asset for an ImageLabel's Image.
    func image(named reference: String) -> NSImage? {
        guard let asset = model.asset(named: reference), asset.kind == .image else { return nil }
        if let known = imageCache[asset.id], known.size == asset.data.count { return known.image }
        guard let image = NSImage(data: asset.data) else { return nil }
        imageCache[asset.id] = (asset.data.count, image)
        return image
    }

    /// Makes the Sounds heard as they are now; on the host, one that ran out stops and
    /// its scripts hear Ended. A joined player's game only goes quiet: the host says so.
    func updateSounds() {
        let camera = renderCamera
        let forward = normalize(camera.target - camera.position)
        let ended = sounds.sync(model, clock: clock, listener: camera.position, forward: forward, up: Vec3(0, 1, 0))
        guard !worldFromHost else { return }
        for id in ended {
            model.updateSound(id: id) { $0.playing = false; $0.timePosition = 0 }
            pendingEvents.append(.list([.string("Sound"), .string(id.uuidString), .string("Ended")]))
        }
    }

    private func applyCameraSettings() {
        camera.setZoomLimits(minimum: settings.cameraMinZoomDistance, maximum: settings.cameraMaxZoomDistance)
        camera.lockFirstPerson = settings.cameraMode == .lockFirstPerson
    }

    // MARK: - ViewportSource

    var renderCamera: Camera {
        // The camera, like the body, passes through parts that don't collide.
        camera.renderCamera(eye: character.eyePosition, parts: partsOutOfHands.filter(\.isSolid))
    }

    var editorOverlay: EditorOverlay? { nil }

    var avatars: [AvatarPose] {
        var pose = AvatarPose(position: character.position,
                              yaw: character.facingYaw,
                              joints: currentJoints,
                              hidden: camera.isFirstPerson)
        pose.colors = bodyColors
        pose.look = look
        pose.transparency = bodyTransparency
        pose.dead = humanoid.isDead
        return [pose] + remoteAvatars
    }

    /// True on a player who joined a network game: the host runs the scene's scripts and
    /// physics, and this machine shows the parts as the host sends them. Set before
    /// `start()`.
    var worldFromHost = false

    /// The other players in a network game, as last heard. They're drawn, walked into, and
    /// on the host they stand in the physics; `PlayController+Multiplayer.swift` has the rest.
    var remotePlayers: [PlayerState] = [] {
        didSet {
            let ids = Set(remotePlayers.map(\.id))
            shownRemote = shownRemote.filter { ids.contains($0.key) }
            if !quietRemoteChanges { noteRemoteChanges(from: oldValue) }
        }
    }
    private var quietRemoteChanges = false

    /// The players already in a game this player joins, before `start()`: they are
    /// there from the first frame, in GetPlayers, and nobody is told they arrived.
    func knowPlayersAtStart(_ players: [PlayerState]) {
        quietRemoteChanges = true
        remotePlayers = players
        quietRemoteChanges = false
    }
    /// Where each remote player is drawn, gliding towards where they were last heard to
    /// be: updates come 20 times a second, frames 60.
    var shownRemote: [Int: (position: Vec3, yaw: Float)] = [:]
    /// What each remote player's body was touching last frame, on the host.
    var remoteTouching: [Int: Set<CharacterTouch.Touch>] = [:]
    /// Sends a host script's action on another player's character to that player's game:
    /// their id, the host call, its arguments after the character's number.
    var forwardToPlayer: ((Int, String, [ScriptValue]) -> Void)?
    /// What host scripts just set on other players' characters, by player then property:
    /// read back until that player's own report catches up (see `pendingWrite`).
    var pendingRemoteWrites: [Int: [String: PendingRemoteWrite]] = [:]
    /// Animation tracks host scripts play on other players' characters, by the handle the
    /// scripts hold (numbered like the characters: see `RemoteCharacter`).
    var remoteTracks: [Int: RemoteTrack] = [:]
    var remoteTracksLoaded = 0
    /// On a joined player: the host's handle for a track it plays on this character, and
    /// this game's own handle for it.
    var hostTracks: [Int: Int] = [:]
    /// RemoteFunction calls this machine made, counted: a reply comes back with its number.
    var remoteCalls = 0
    /// On the host: which player each of its InvokeClient calls is waiting on, so a
    /// player who leaves fails their calls instead of leaving them hanging.
    var invokesWaiting: [Int: Int] = [:]
    /// Each Value object's value as last seen, so a change from outside raises Changed.
    var knownDataValues: [UUID: ScriptValue] = [:]
    /// Seconds of play so far, by the frames stepped.
    private(set) var clock: Double = 0

    /// This player's number in a network game: 0 for the host (or playing alone), and
    /// the number the host gave a joined player. Tools say whose they are by it.
    var playerID = 0
    /// Asks the host to do something for this player — equip, drop, click with a tool —
    /// on a joined player's game (ClientSession wires it).
    var sendAction: ((String, [ScriptValue]) -> Void)?
    /// Each held tool's parts around its Handle, taken when it was put in the hand.
    var toolLayouts: [UUID: [UUID: Pose]] = [:]
    /// The parts of tools in hands this frame: drawn and touched, but not collided with.
    var heldToolParts: Set<UUID> = []
    /// Who dropped a tool and when, so they don't pick it straight back up.
    var toolDrops: [UUID: (player: Int, time: Double)] = [:]
    /// The scripts of each character's StarterPack copies, by the scope they run in.
    var toolScripts: [Int: [ScriptObject]] = [:]
    /// Each StarterGui object's copy in the PlayerGui, and the LocalScripts that go with
    /// each character (ResetOnSpawn), by its scope.
    var guiCopies: [UUID: Int] = [:]
    var guiScripts: [Int: [ScriptObject]] = [:]

    /// Where the pointer is in the view (top-left origin, points) and how big the view is;
    /// the view keeps both up to date. See PlayController+Mouse.
    var pointer: SIMD2<Float>?
    var viewSize = SIMD2<Float>(0, 0)
    /// The ClickDetector part the mouse is over.
    var hoveredPart: UUID?
    /// The part the body stood on at the end of last frame, and where it was then.
    var standingOn: (id: UUID, pose: Pose)?
    /// The Seat the character sits in, and when it may sit again after getting up.
    var seatPart: UUID?
    var seatDelayUntil: Double = 0
    /// UserInputService.MouseBehavior: "Default", or "LockCenter" to hold the pointer.
    var mouseBehavior = "Default" {
        didSet {
            let locked = mouseBehavior != "Default"
            DispatchQueue.main.async { [hud] in hud.mouseLock = locked }
        }
    }

    /// The built-in animations with any playing custom ones on top. A dead body is
    /// left to fall as it does.
    var currentJoints: AvatarJoints {
        guard !humanoid.isDead else { return animator.joints }
        var joints = animator.joints
        // Holding a tool, the right arm is out in front, as in Roblox.
        if isHoldingTool { joints.rightShoulder = Vec3(.pi / 2, 0, 0) }
        return animationPlayer.apply(to: joints, animation: model.animation(id:))
    }

    /// `["Track", handle, "Stopped" | "DidLoop" | "Marker", markerName?]`
    func queueTrackEvent(_ handle: Int, _ event: AnimationTrackEvent) {
        var values: [ScriptValue] = [.string("Track"), .number(Double(handle))]
        switch event {
        case .stopped: values.append(.string("Stopped"))
        case .didLoop: values.append(.string("DidLoop"))
        case .marker(let name): values += [.string("Marker"), .string(name)]
        }
        pendingEvents.append(.list(values))
    }

    // MARK: - The frame

    func stepFrame() {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 0.25))
        lastTime = now
        // Stopped at a breakpoint: the world waits, and the time paused doesn't count.
        if scripts.debugger?.paused != nil { return }
        if scripts.debugger?.stopRequested == true {
            onDebuggerStop?()
            return
        }
        step(dt: dt)
        refreshHUD(dt: dt)
    }

    /// Where the frames go (FrameStats.swift): the Stats service reads it.
    var frameStats = FrameStats()

    /// Keeps App Nap away while the game runs (`start` to `stop`).
    private var activity: NSObjectProtocol?

    /// What Stop in the debugger does: the editor ends the session.
    var onDebuggerStop: (() -> Void)?

    /// One frame with an explicit step, which is how the tests drive it.
    func step(dt: Float) {
        // Not while stopped at a breakpoint: the scripts are mid-run.
        guard scripts.debugger?.paused == nil else { return }
        let began = CACurrentMediaTime()
        var scriptTime = 0.0, physicsTime = 0.0
        defer { frameStats.note(step: CACurrentMediaTime() - began, scripts: scriptTime, physics: physicsTime) }
        func timed(_ total: inout Double, _ work: () -> Void) {
            let started = CACurrentMediaTime()
            work()
            total += CACurrentMediaTime() - started
        }
        clock += Double(dt)
        noteDataChanges()
        guard hasPlayer else {
            timed(&scriptTime) { scripts.update(dt: Double(dt)) }
            timed(&physicsTime) { simulateParts(dt: dt) }
            updateSounds()
            return
        }
        glideRemotePlayers(dt: dt)
        timed(&scriptTime) { scripts.update(dt: Double(dt)) }
        timed(&physicsTime) {
            simulate(dt: dt)
            simulateParts(dt: dt)
        }
        animator.update(dt: dt, state: humanoid.state, horizontalSpeed: character.horizontalSpeed,
                        verticalVelocity: character.velocity.y)
        for (handle, event) in animationPlayer.step(dt: dt, animation: model.animation(id:)) {
            queueTrackEvent(handle, event)
        }
        positionHeldTools()
        updateHover()
        updateTouches()
        updateRemoteTouches()
        updateRemoteTracks()
        noteGround()
        updateSounds()
        handleLifecycle(dt: dt)
    }

    /// Reports each body part starting or stopping touching a part, as
    /// `["Touch", "Began" | "Ended", partID, bodyPart, generation]`. A dead character
    /// touches nothing; a part that was destroyed is forgotten without an event.
    private func updateTouches() {
        let now = humanoid.isDead ? [] : CharacterTouch.contacts(position: character.position,
                                                                  yaw: character.facingYaw,
                                                                  parts: model.parts)
        let existing = Set(model.parts.map(\.id))
        let ended = touching.subtracting(now).filter { existing.contains($0.partID) }
        let began = now.subtracting(touching)
        queueTouches(ended, phase: "Ended")
        queueTouches(began, phase: "Began")
        touching = now
        pickUpTools(touched: began, by: playerID)
        sitOnTouchedSeat(now)
    }

    /// Touch events for a character — this player's own unless another's number is given.
    func queueTouches(_ touches: Set<CharacterTouch.Touch>, phase: String, character: Int? = nil) {
        // Body-part order, then part order, so scripts see the same sequence every run.
        let limbOrder = Dictionary(uniqueKeysWithValues: AvatarPose.bodyParts.enumerated().map { ($1.name, $0) })
        let partOrder = Dictionary(uniqueKeysWithValues: model.parts.enumerated().map { ($1.id, $0) })
        let sorted = touches.sorted {
            (limbOrder[$0.limb] ?? 0, partOrder[$0.partID] ?? 0) < (limbOrder[$1.limb] ?? 0, partOrder[$1.partID] ?? 0)
        }
        for touch in sorted {
            pendingEvents.append(.list([.string("Touch"), .string(phase), .string(touch.partID.uuidString),
                                        .string(touch.limb), .number(Double(character ?? characterGeneration))]))
        }
    }

    private func simulate(dt: Float) {
        // MoveTo walks straight at its target, overriding Move, until it arrives or
        // gives up — both reported through MoveToFinished.
        if let target = humanoid.moveToTarget, !humanoid.isDead {
            humanoid.moveToElapsed += dt
            let offset = Vec3(target.x - character.position.x, 0, target.z - character.position.z)
            if length(offset) < 1 {
                humanoid.finishMoveTo(reached: true)
            } else if humanoid.moveToElapsed > Humanoid.moveToTimeout {
                humanoid.finishMoveTo(reached: false)
            } else {
                humanoid.moveDirection = normalize(offset)
            }
        }

        // In a seat the body stays put; otherwise whatever it stands on carries it.
        if isSeated {
            stayInSeat()
        }
        if isSeated {
            updateState()
            for event in humanoid.drainEvents() {
                pendingEvents.append(.list([.string("Humanoid"), .number(Double(characterGeneration))]
                                           + Self.scriptArguments(for: event)))
            }
            return
        }
        rideGround()

        var intent = CharacterIntent()
        intent.direction = humanoid.moveDirection
        intent.jump = humanoid.jump
        intent.flying = humanoid.state == .flying
        intent.dead = humanoid.isDead
        intent.walkSpeed = max(humanoid.walkSpeed, 0)
        intent.jumpVelocity = humanoid.jumpVelocity(gravity: gravity)
        intent.maxSlopeCosine = humanoid.maxSlopeCosine
        intent.gravity = gravity
        intent.autoRotate = humanoid.autoRotate

        let jumped = character.step(dt: dt, intent: intent, parts: partsOutOfHands + otherPlayersInTheWay)
        if jumped {
            humanoid.jump = false
            humanoid.enter(.jumping)
        }
        // Shift lock turns the body with the camera, whichever way it walks — except
        // sitting, climbing (facing the truss) or dead.
        if camera.shiftLock, !humanoid.isDead, seatPart == nil, !character.climbing {
            character.facingYaw = camera.yaw
        }
        updateState()

        // Roblox destroys whatever falls out of the world; for a character that is death.
        if character.fellIntoVoid, !humanoid.isDead {
            humanoid.die()
        }

        for event in humanoid.drainEvents() {
            pendingEvents.append(.list([.string("Humanoid"), .number(Double(characterGeneration))]
                                       + Self.scriptArguments(for: event)))
        }
    }

    /// Physics for the parts: sync with the scene, step, write moved parts back,
    /// destroy what fell out of the world, and let the character push what it walks into.
    private func simulateParts(dt: Float) {
        // A joined player's parts are the host's, as the host's physics moved them.
        guard !worldFromHost else { return }
        physics.gravity = gravity
        physics.groundPlane = character.solidBaseplate
        physics.sync(partsOutOfHands, constraints: model.constraints, attachments: model.attachments)
        // The capsule stands in for a living character; a dead one lies on the ground.
        if humanoid.isDead || !hasPlayer {
            physics.removeCharacter()
        } else {
            physics.moveCharacter(feet: character.position, radius: CharacterController.capsuleRadius,
                                  height: CharacterController.capsuleHeight, dt: dt)
        }
        moveRemoteCapsules(dt: dt)
        takeHits(dt: dt)
        remotePlayersPush()
        let result = physics.step(dt: dt)
        if !result.moved.isEmpty {
            var parts = model.parts
            let index = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
            for (id, pose) in result.moved {
                if let i = index[id] { parts[i].pose = pose }
            }
            model.parts = parts
        }
        if !result.fallen.isEmpty { model.removeSubtrees(result.fallen) }

        // Walking into an unanchored part shoves it.
        if hasPlayer && !humanoid.isDead {
            let walk = Vec3(humanoid.moveDirection.x, 0, humanoid.moveDirection.z) * humanoid.walkSpeed
            var reach = character.capsule
            reach.radius += 0.15
            for part in model.parts where !part.anchored && part.isSolid
                && simd_distance(part.position, character.position) < length(part.size) + 4 {
                guard let contact = Collision.contact(capsule: reach, part: part) else { continue }
                var direction = -contact.normal
                direction.y = 0
                guard length(direction) > 0.3 else { continue }
                direction = normalize(direction)
                physics.push(part.id, along: direction, speed: dot(walk, direction))
            }
        }

        // Parts starting and stopping touching each other.
        let now = physics.touchingPairs
        let canTouch = Set(model.parts.filter(\.canTouch).map(\.id))
        for pair in now.subtracting(touchingParts) where pair.allSatisfy(canTouch.contains) {
            pendingEvents.append(.list([.string("PartTouch"), .string("Began"),
                                        .string(pair[0].uuidString), .string(pair[1].uuidString)]))
        }
        let existing = Set(model.parts.map(\.id))
        for pair in touchingParts.subtracting(now) where pair.allSatisfy(existing.contains) {
            pendingEvents.append(.list([.string("PartTouch"), .string("Ended"),
                                        .string(pair[0].uuidString), .string(pair[1].uuidString)]))
        }
        touchingParts = now
    }

    /// The Running → Jumping → Freefall → Landed → Running cycle, read off the body.
    private func updateState() {
        guard !humanoid.isDead, humanoid.state != .flying else { return }
        if isSeated { return }
        if character.swimming {
            humanoid.enter(.swimming)
            return
        }
        if character.climbing {
            humanoid.enter(.climbing)
            return
        }
        // Out of the water, or off the truss.
        if humanoid.state == .swimming || humanoid.state == .climbing || humanoid.state == .seated {
            humanoid.enter(character.grounded ? .running : .freefall)
        }
        let speed = character.horizontalSpeed
        if character.grounded {
            switch humanoid.state {
            case .jumping, .freefall:
                humanoid.enter(.landed)
            case .landed:
                humanoid.enter(.running)
            default:
                break
            }
            if abs(speed - lastReportedRunSpeed) > 0.5 || (speed == 0 && lastReportedRunSpeed != 0) {
                lastReportedRunSpeed = speed
                humanoid.record(.running(speed: speed))
            }
        } else if humanoid.state == .running || humanoid.state == .landed
                    || (humanoid.state == .jumping && character.velocity.y <= 0) {
            humanoid.enter(.freefall)
        }
    }

    private func handleLifecycle(dt: Float) {
        if humanoid.isDead, deathCountdown == nil {
            deathCountdown = respawnTime
        }
        if let remaining = deathCountdown {
            deathCountdown = remaining - dt
            if remaining - dt <= 0 { respawnRequested = true }
        }
        if respawnRequested {
            respawnRequested = false
            deathCountdown = nil
            let previous = characterGeneration
            takeTools(from: playerID, scope: previous)
            takeStarterGui(scope: previous)
            spawnCharacter()
            scripts.characterRespawned(from: previous, to: characterGeneration)
            giveStarterTools(to: playerID, scope: characterGeneration)
            runGuiScripts(copyStarterGui(resetting: true))
        }
    }

    /// A fresh character from the template: new Humanoid, appearance and position.
    private func spawnCharacter() {
        if characterGeneration > 0 {
            let existing = Set(model.parts.map(\.id))
            queueTouches(touching.filter { existing.contains($0.partID) }, phase: "Ended")
            touching = []
            pendingEvents.append(.list([.string("CharacterRemoving"), .number(Double(characterGeneration))]))
        }
        characterGeneration += 1
        // Tracks belong to the old character; scripts holding them now hold nothing.
        animationPlayer.removeAll()
        humanoid = Humanoid(settings: settings)
        bodyColors = settings.bodyColors
        look = settings.look.worn(by: playerLook, playersWearOwn: settings.playersWearOwnLook)
        bodyTransparency = [:]
        lastReportedRunSpeed = 0
        character.chooseSpawn(in: model.parts)
        character.respawn()
        // The first character is there before any script starts, so nothing connected
        // could have missed it: announcing it would reach scripts that already had it
        // from `player.Character`, and Roblox's usual idiom — handle Character, then
        // connect CharacterAdded — would run twice for it.
        if characterGeneration > 1 {
            pendingEvents.append(.list([.string("CharacterAdded"), .number(Double(characterGeneration))]))
        }
    }

    static func scriptArguments(for event: HumanoidEvent) -> [ScriptValue] {
        switch event {
        case .stateChanged(let from, let to):
            return [.string("StateChanged"), .string(from.rawValue), .string(to.rawValue)]
        case .jumping: return [.string("Jumping"), .bool(true)]
        case .freeFalling: return [.string("FreeFalling"), .bool(true)]
        case .running(let speed): return [.string("Running"), .number(Double(speed))]
        case .died: return [.string("Died")]
        case .healthChanged(let health): return [.string("HealthChanged"), .number(Double(health))]
        case .moveToFinished(let reached): return [.string("MoveToFinished"), .bool(reached)]
        case .seated(let active, let seat): return [.string("Seated"), .bool(active), .string(seat?.uuidString ?? "")]
        }
    }

    /// Tells the view whether the camera is in first person (it captures the pointer then).
    private func refreshHUD(dt: Float) {
        hudClock += Double(dt)
        guard hudClock > 0.12 else { return }
        hudClock = 0
        let firstPerson = camera.isFirstPerson
        guard firstPerson != hud.firstPerson else { return }
        DispatchQueue.main.async { [hud] in hud.firstPerson = firstPerson }
    }

    // MARK: - Input from the view

    /// A key went down or up. Held keys answer `IsKeyDown`; changes become
    /// `InputBegan` / `InputEnded` for scripts.
    func key(_ name: String, pressed: Bool) {
        if pressed {
            guard heldKeys.insert(name).inserted else { return }   // ignore auto-repeat
            if name == "LeftControl" { toggleShiftLock() }
        } else {
            guard heldKeys.remove(name) != nil else { return }
        }
        pendingEvents.append(.list([.string("Input"), .string(pressed ? "Began" : "Ended"),
                                    .string(name), .string("Keyboard")]))
    }

    /// A mouse button while the pointer is captured.
    func mouseButton(_ number: Int, pressed: Bool) {
        // With a tool in hand a click uses it; without, it clicks what it's over.
        if number == 1 {
            if isHoldingTool { clickTool(down: pressed) } else if pressed { clickPart() }
        }
        pendingEvents.append(.list([.string("Input"), .string(pressed ? "Began" : "Ended"),
                                    .string("Unknown"), .string("MouseButton\(number)")]))
    }

    func releaseAllKeys() {
        for name in heldKeys { key(name, pressed: false) }
    }

    func look(deltaX: Float, deltaY: Float) {
        camera.look(deltaX: deltaX, deltaY: deltaY)
    }

    // MARK: - Shift lock

    /// Whether this player may use shift lock: the place allows it (StarterPlayer's
    /// EnableMouseLockOption) and no script has turned it off (Player.DevEnableMouseLock).
    var shiftLockAllowed: Bool { settings.enableMouseLockOption && devEnableMouseLock }

    func toggleShiftLock() {
        setShiftLock(!camera.shiftLock)
    }

    func setShiftLock(_ on: Bool) {
        let wanted = on && shiftLockAllowed
        guard camera.shiftLock != wanted else { return }
        camera.shiftLock = wanted
        DispatchQueue.main.async { [hud] in hud.shiftLock = wanted }
    }

    func zoom(_ amount: Float) {
        camera.zoom(amount)
    }

    /// Re-read the scene after it changes underneath us (opening another file).
    func sceneChanged() {
        scripts.stop()
        console.clear()
        characterGeneration = 0
        start()
    }
}
