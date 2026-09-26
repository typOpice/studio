import Foundation
import simd

/// What a script runtime needs from a play session.
protocol PlayerBridge: AnyObject {
    /// The current character's generation, or 0 when there is none yet.
    var characterGeneration: Int { get }
    func playerInvoke(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue
    /// A script set a Value object's value: its Changed is its own to raise, not a
    /// change noticed from the network.
    func noteDataWritten(_ id: UUID)
}

/// Every host call scripts can make about the player — the one place to add to when
/// the player gains a feature.
///
/// Calls are grouped by namespace:
///   `player.*`    the Player: events, camera settings, respawning, position
///   `humanoid.*`  the character's Humanoid, addressed by generation
///   `root.*`      the HumanoidRootPart
///   `body.*`      the six body parts' appearance
///   `input.*`     the keyboard
///   `track.*`     AnimationTracks: loading custom animations onto the character
///   `physics.*`   parts' velocities and impulses (Jolt Physics)
///
/// A character is addressed by its generation, so a script holding an old
/// character's Humanoid gets a dead one rather than silently steering the new one.
/// Property names are compared case-insensitively, so Wren's `position` and
/// Luau's `Position` reach the same thing.
enum PlayerHost {
    static let namespaces: Set<String> = ["player", "humanoid", "root", "body", "look", "remote", "input", "track", "physics",
                                          "character", "players", "gui", "chat", "backpack", "seat"]

    /// Calls whose first argument is a character's number — which may be another player's.
    static let characterNamespaces: Set<String> = ["humanoid", "root", "body", "track", "character", "look"]

    /// A built-in accessory's type and colour, for a script that names it: `{type, {r, g, b}}`.
    static func catalogEntry(_ arguments: [ScriptValue]) -> ScriptValue {
        guard let reference = arguments.first?.asString, AvatarCatalog.builtIn(reference) != nil,
              let entry = AvatarCatalog.accessory(reference) else { return .nothing }
        return .list([.string(entry.type.rawValue), .triple(entry.color.x, entry.color.y, entry.color.z)])
    }

    /// Answers when there is no play session: no character, nothing held down.
    static func withoutPlayer(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "player.events", "input.keys", "players.list", "gui.children", "backpack.list": return .list([])
        case "backpack.me": return .number(0)
        case "seat.occupant": return .nothing
        // Studio's Run mode, or a script run outside play: there is no player at all.
        case "player.present": return .bool(false)
        case "gui.focused", "gui.create": return .number(0)
        case "character.alive": return .bool(false)
        case "character.name", "players.name": return .string("Player")
        case "character.owner": return .number(-1)
        case "look.catalog": return catalogEntry(arguments)
        // Studio's Run mode is the server, and nobody is there to be a client.
        case "remote.isServer": return .bool(true)
        case "look.get": return AvatarLook().scriptValue
        case "players.character": return .number(0)
        case "input.down": return .bool(false)
        case "input.mousebehavior": return .string("Default")
        case "input.mouse": return .list([.number(0), .number(0), .number(0), .string(""),
                                          .number(0), .number(0), .number(0), .number(0)])
        case "track.playing": return .list([])
        case "physics.get":
            // Outside play nothing is moving.
            let property = arguments.count > 1 ? (arguments[1].asString ?? "").lowercased() : ""
            return property == "sleeping" ? .bool(true) : .triple(0, 0, 0)
        case "physics.joint": return .number(0)
        case "player.get":
            switch (arguments.first?.asString ?? "").lowercased() {
            case "position", "velocity": return .triple(0, 0, 0)
            case "grounded": return .bool(false)
            case "speed", "generation": return .number(0)
            case "name": return .string("Player")
            default: return .nothing
            }
        default: return .nothing
        }
    }
}

extension PlayController {

    private func float(_ arguments: [ScriptValue], _ index: Int) -> Float? {
        index < arguments.count ? arguments[index].asFloat : nil
    }

    /// The track a call names, if it still belongs to the current character.
    private func trackHandle(_ arguments: [ScriptValue]) -> Int? {
        guard let raw = arguments.first?.asDouble,
              let track = animationPlayer.track(Int(raw)),
              track.generation == characterGeneration else { return nil }
        return track.handle
    }

    /// A Float setting as the number a script sees: its shortest decimal, so a
    /// Gravity of 196.2 reads back as 196.2 rather than 196.1999969482422.
    func scalar(_ value: Float) -> ScriptValue {
        .number(Double("\(value)") ?? Double(value))
    }

    func playerInvoke(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        let generation = arguments.first?.asDouble.map { Int($0) } ?? -1
        let current = generation == characterGeneration

        // The screen GUI and chat: see PlayController+Gui.
        if name.hasPrefix("gui.") || name.hasPrefix("chat.") {
            return guiCall(name, arguments)
        }
        // Tools: see PlayController+Tools.
        if name.hasPrefix("backpack.") {
            return backpackCall(name, arguments)
        }
        // Remotes, and rays that meet characters: see PlayController+Remotes.
        if name.hasPrefix("remote.") {
            return remoteCall(name, arguments)
        }
        if name == "character.raycast" {
            return characterRaycast(arguments)
        }

        // Another player's character, in a network game: see PlayController+Multiplayer.
        if let owner = RemoteCharacter.owner(of: generation),
           let dot = name.firstIndex(of: "."), PlayerHost.characterNamespaces.contains(String(name[..<dot])) {
            return remoteCharacterCall(name, number: generation, owner: owner, arguments)
        }

        switch name {

        case "player.present":
            return .bool(true)

        case "seat.occupant":
            guard let id = arguments.first?.asString.flatMap(UUID.init(uuidString:)),
                  let number = occupant(of: id) else { return .nothing }
            return .number(Double(number))

        case "track.remote":
            // A host script's track on this character: ["track.remote", generation,
            // hostHandle, "load" | "play" | "stop" | "set", …the call's own arguments].
            guard current, arguments.count >= 3, let host = arguments[1].asDouble.map(Int.init),
                  let operation = arguments[2].asString else { return .nothing }
            let rest = Array(arguments.dropFirst(3))
            if operation == "load" {
                if let handle = playerInvoke("track.load", [.number(Double(characterGeneration))] + rest).asDouble {
                    hostTracks[host] = Int(handle)
                }
                return .nothing
            }
            guard ["play", "stop", "set"].contains(operation), let handle = hostTracks[host] else { return .nothing }
            return playerInvoke("track." + operation, [.number(Double(handle))] + rest)

        // MARK: characters, this player's or (above) another's
        case "character.alive":
            return .bool(current && characterGeneration > 0)

        case "character.name":
            return .string(playerName)

        case "character.owner":
            // −1 is this player; other players are numbered from 0, the host.
            return .number(-1)

        case "character.moveTo":
            // Model:MoveTo — the feet go where the position says.
            guard current, arguments.count >= 2, let (x, y, z) = arguments[1].asTriple else { return .nothing }
            character.position = Vec3(x, y, z)
            character.velocity = .zero
            return .nothing

        // MARK: the other players in a network game
        case "players.list":
            return .list(remotePlayers.map { .number(Double($0.id)) })

        case "players.name":
            let id = Int(arguments.first?.asDouble ?? -1)
            return .string(remotePlayers.first { $0.id == id }?.name ?? "Player")

        case "players.character":
            let id = Int(arguments.first?.asDouble ?? -1)
            guard let remote = remotePlayers.first(where: { $0.id == id }) else { return .number(0) }
            return .number(Double(RemoteCharacter.number(player: id, generation: remote.generation)))

        // MARK: player
        case "player.events":
            defer { pendingEvents.removeAll() }
            return .list(pendingEvents + gui.drainEvents())

        case "player.get":
            return playerProperty((arguments.first?.asString ?? "").lowercased())

        case "player.set":
            guard arguments.count >= 2 else { return .nothing }
            return setPlayerProperty((arguments[0].asString ?? "").lowercased(), arguments[1])

        case "player.load":
            respawnRequested = true
            return .nothing

        // MARK: humanoid
        case "humanoid.get":
            guard arguments.count >= 2 else { return .nothing }
            return humanoidProperty((arguments[1].asString ?? "").lowercased(), current: current)

        case "humanoid.set":
            guard current, arguments.count >= 3 else { return .nothing }
            setHumanoidProperty((arguments[1].asString ?? "").lowercased(), arguments[2])
            return .nothing

        case "humanoid.move":
            guard current, arguments.count >= 2, let (x, y, z) = arguments[1].asTriple else { return .nothing }
            let relative = arguments.count > 2 ? (arguments[2].asBool ?? false) : false
            move(Vec3(x, y, z), relativeToCamera: relative)
            return .nothing

        case "humanoid.moveTo":
            guard current, arguments.count >= 2, let (x, y, z) = arguments[1].asTriple,
                  !humanoid.isDead else { return .nothing }
            humanoid.finishMoveTo(reached: false)      // a new target replaces the old one
            humanoid.moveToTarget = Vec3(x, y, z)
            humanoid.moveToElapsed = 0
            return .nothing

        case "humanoid.damage":
            guard current, arguments.count >= 2, let amount = arguments[1].asFloat else { return .nothing }
            humanoid.takeDamage(amount)
            return .nothing

        case "humanoid.state":
            guard current, arguments.count >= 2, let raw = arguments[1].asString,
                  let state = HumanoidStateType(rawValue: raw) else { return .bool(false) }
            return .bool(humanoid.requestState(state))

        // MARK: root part
        case "root.get":
            guard arguments.count >= 2 else { return .nothing }
            switch (arguments[1].asString ?? "").lowercased() {
            case "position":
                let center = character.position + Vec3(0, 3, 0)
                return .triple(center.x, center.y, center.z)
            case "velocity", "assemblylinearvelocity":
                return .triple(character.velocity.x, character.velocity.y, character.velocity.z)
            default:
                return .nothing
            }

        case "root.set":
            guard current, arguments.count >= 3, let (x, y, z) = arguments[2].asTriple else { return .nothing }
            switch (arguments[1].asString ?? "").lowercased() {
            case "position":
                // The root is the torso's centre, three studs above the feet.
                character.position = Vec3(x, y - 3, z)
                character.velocity = .zero
            case "velocity", "assemblylinearvelocity":
                character.velocity = Vec3(x, y, z)
            default:
                break
            }
            return .nothing

        // MARK: body parts
        case "body.get":
            guard arguments.count >= 3, let part = arguments[1].asString else { return .nothing }
            switch (arguments[2].asString ?? "").lowercased() {
            case "color":
                guard let colour = bodyColors[part] else { return .nothing }
                return .triple(colour.x, colour.y, colour.z)
            case "transparency":
                return scalar(bodyTransparency[part] ?? 0)
            case "size":
                guard let size = AvatarPose.bodyParts.first(where: { $0.name == part })?.size else { return .nothing }
                return .triple(size.x, size.y, size.z)
            default:
                return .nothing
            }

        case "body.set":
            guard current, arguments.count >= 4, let part = arguments[1].asString,
                  bodyColors[part] != nil else { return .nothing }
            switch (arguments[2].asString ?? "").lowercased() {
            case "color":
                if let (r, g, b) = arguments[3].asTriple { bodyColors[part] = Vec3(r, g, b) }
            case "transparency":
                if let t = arguments[3].asFloat { bodyTransparency[part] = min(max(t, 0), 1) }
            default:
                break
            }
            return .nothing

        // MARK: what the character wears
        case "look.catalog":
            return PlayerHost.catalogEntry(arguments)

        case "look.get":
            return look.scriptValue

        case "look.set":
            // [generation, key, value]: `face`, `shirt` or `pants` and a reference, or
            // `accessories` and the whole list.
            guard current, arguments.count >= 3, let key = arguments[1].asString else { return .bool(false) }
            return .bool(look.set(key, arguments[2]))

        // MARK: input
        case "input.down":
            return .bool(heldKeys.contains(arguments.first?.asString ?? ""))

        case "input.keys":
            return .list(heldKeys.sorted().map { .string($0) })

        case "input.mouse":
            return mouseState()

        case "input.mousebehavior":
            if let behavior = arguments.first?.asString, ["Default", "LockCenter", "LockCurrentPosition"].contains(behavior) {
                mouseBehavior = behavior
            }
            // In first person, or with shift lock on, the pointer is held in the middle, as
            // Roblox's camera holds it — so scripts see LockCenter (the HUD's crosshair does).
            let held = camera.isFirstPerson || camera.shiftLock
            return .string(mouseBehavior == "Default" && held ? "LockCenter" : mouseBehavior)

        // MARK: physics
        case "physics.get":
            guard arguments.count >= 2, let id = arguments[0].asString.flatMap(UUID.init(uuidString:)) else { return .nothing }
            let motion = physics.motion(of: id)
            switch (arguments[1].asString ?? "").lowercased() {
            case "velocity":
                let v = motion?.velocity ?? .zero
                return .triple(v.x, v.y, v.z)
            case "angularvelocity":
                let v = motion?.angularVelocity ?? .zero
                return .triple(v.x, v.y, v.z)
            case "sleeping": return .bool(motion?.sleeping ?? true)
            default: return .nothing
            }

        case "physics.set":
            guard arguments.count >= 3, let id = arguments[0].asString.flatMap(UUID.init(uuidString:)),
                  let (x, y, z) = arguments[2].asTriple else { return .nothing }
            // Settle the scene first, so a part made this frame has a body to move.
            physics.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            switch (arguments[1].asString ?? "").lowercased() {
            case "velocity": physics.setVelocity(id, Vec3(x, y, z))
            case "angularvelocity": physics.setAngularVelocity(id, Vec3(x, y, z))
            default: break
            }
            return .nothing

        case "physics.joint":
            // A hinge's angle in degrees or a slider's position in studs, as simulated.
            guard let id = arguments.first?.asString.flatMap(UUID.init(uuidString:)),
                  let value = physics.jointValue(id), let constraint = model.constraint(id: id) else { return .number(0) }
            return .number(Double(constraint.kind == .hinge ? value * 180 / .pi : value))

        case "physics.impulse", "physics.angularimpulse":
            guard arguments.count >= 2, let id = arguments[0].asString.flatMap(UUID.init(uuidString:)),
                  let (x, y, z) = arguments[1].asTriple else { return .nothing }
            physics.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            if name == "physics.impulse" {
                physics.applyImpulse(id, Vec3(x, y, z))
            } else {
                physics.applyAngularImpulse(id, Vec3(x, y, z))
            }
            return .nothing

        // MARK: animation tracks
        // A track is addressed by the handle `track.load` returned. Tracks belong to
        // one character; a respawn forgets them, and calls on them do nothing.
        case "track.load":
            // By id (from the Animations service) or by name (an assigned AnimationId).
            guard current, arguments.count >= 2, let key = arguments[1].asString,
                  let animation = model.animations.first(where: { $0.id.uuidString == key })
                    ?? model.animation(named: key) else { return .nothing }
            return .number(Double(animationPlayer.load(animation, generation: characterGeneration)))

        case "track.play":
            guard let handle = trackHandle(arguments) else { return .nothing }
            animationPlayer.play(handle, fadeTime: float(arguments, 1) ?? AnimationPlayer.defaultFade,
                                 weight: float(arguments, 2) ?? 1, speed: float(arguments, 3) ?? 1)
            return .nothing

        case "track.stop":
            guard let handle = trackHandle(arguments) else { return .nothing }
            if animationPlayer.stop(handle, fadeTime: float(arguments, 1) ?? AnimationPlayer.defaultFade) {
                queueTrackEvent(handle, .stopped)
            }
            return .nothing

        case "track.get":
            guard let handle = trackHandle(arguments), let track = animationPlayer.track(handle),
                  arguments.count >= 2 else { return .nothing }
            let animation = model.animation(id: track.animationID)
            switch (arguments[1].asString ?? "").lowercased() {
            case "isplaying": return .bool(track.isPlaying)
            case "length": return scalar(animation?.length ?? 0)
            case "looped": return .bool(track.looped)
            case "speed": return scalar(track.speed)
            case "timeposition":
                return scalar(track.time.isFinite ? track.time : animation?.length ?? 0)
            case "weightcurrent": return scalar(track.weight)
            case "weighttarget": return scalar(track.targetWeight)
            case "priority": return .string(track.priority.rawValue)
            case "name": return animation.map { .string($0.name) } ?? .nothing
            default: return .nothing
            }

        case "track.set":
            guard let handle = trackHandle(arguments), arguments.count >= 3 else { return .nothing }
            let value = arguments[2]
            switch (arguments[1].asString ?? "").lowercased() {
            case "looped":
                if let looped = value.asBool { animationPlayer.update(handle) { $0.looped = looped } }
            case "speed":
                if let speed = value.asFloat { animationPlayer.update(handle) { $0.speed = speed } }
            case "timeposition":
                if let time = value.asFloat, let track = animationPlayer.track(handle),
                   let length = model.animation(id: track.animationID)?.length {
                    animationPlayer.update(handle) { $0.time = min(max(time, 0), length) }
                }
            case "priority":
                if let raw = value.asString, let priority = AnimationPriority(rawValue: raw) {
                    animationPlayer.update(handle) { $0.priority = priority }
                }
            case "weight":
                if let weight = value.asFloat {
                    animationPlayer.adjustWeight(handle, weight,
                                                 fadeTime: float(arguments, 3) ?? AnimationPlayer.defaultFade)
                }
            default: break
            }
            return .nothing

        case "track.playing":
            guard current else { return .list([]) }
            let playing = animationPlayer.tracks.values.filter(\.isPlaying).map(\.handle).sorted()
            return .list(playing.map { .number(Double($0)) })

        default:
            console.error("Unknown host call \"\(name)\".")
            return .nothing
        }
    }

    // MARK: - Player properties

    private func playerProperty(_ key: String) -> ScriptValue {
        switch key {
        case "name": return .string(playerName)
        case "userid": return .number(1)
        case "generation": return .number(Double(characterGeneration))
        case "position": return .triple(character.position.x, character.position.y, character.position.z)
        case "velocity": return .triple(character.velocity.x, character.velocity.y, character.velocity.z)
        case "grounded": return .bool(character.grounded)
        case "speed": return scalar(character.horizontalSpeed)
        case "cameramode": return .string(camera.lockFirstPerson ? "LockFirstPerson" : "Classic")
        case "cameraminzoomdistance": return scalar(camera.minZoom)
        case "cameramaxzoomdistance": return scalar(camera.maxZoom)
        case "respawntime": return scalar(respawnTime)
        case "gravity": return scalar(gravity)
        case "devenablemouselock": return .bool(devEnableMouseLock)
        default: return .nothing
        }
    }

    private func setPlayerProperty(_ key: String, _ value: ScriptValue) -> ScriptValue {
        switch key {
        case "position":
            if let (x, y, z) = value.asTriple {
                character.position = Vec3(x, y, z)
                character.velocity = .zero
            }
        case "cameramode":
            if let raw = value.asString, let mode = CameraMode(rawValue: raw) {
                camera.lockFirstPerson = mode == .lockFirstPerson
            }
        case "cameraminzoomdistance":
            if let d = value.asFloat { camera.setZoomLimits(minimum: d, maximum: max(d, camera.maxZoom)) }
        case "cameramaxzoomdistance":
            if let d = value.asFloat { camera.setZoomLimits(minimum: min(d, camera.minZoom), maximum: d) }
        case "respawntime":
            if let t = value.asFloat { respawnTime = max(t, 0) }
        case "gravity":
            if let g = value.asFloat { gravity = g }
        case "devenablemouselock":
            if let on = value.asBool { devEnableMouseLock = on }
        default:
            break
        }
        return .nothing
    }

    // MARK: - Humanoid properties

    /// A stale generation reads as a dead humanoid; its other values no longer matter.
    private func humanoidProperty(_ key: String, current: Bool) -> ScriptValue {
        guard current else {
            switch key {
            case "health": return .number(0)
            case "state": return .string(HumanoidStateType.dead.rawValue)
            default: return .nothing
            }
        }
        switch key {
        case "walkspeed": return scalar(humanoid.walkSpeed)
        case "jumppower": return scalar(humanoid.jumpPower)
        case "jumpheight": return scalar(humanoid.jumpHeight)
        case "usejumppower": return .bool(humanoid.useJumpPower)
        case "health": return scalar(humanoid.health)
        case "maxhealth": return scalar(humanoid.maxHealth)
        case "maxslopeangle": return scalar(humanoid.maxSlopeAngle)
        case "autorotate": return .bool(humanoid.autoRotate)
        case "jump": return .bool(humanoid.jump)
        case "movedirection":
            let d = humanoid.moveDirection
            return .triple(d.x, d.y, d.z)
        case "state": return .string(humanoid.state.rawValue)
        case "sit": return .bool(isSeated)
        case "seatpart": return seatPart.map { .string($0.uuidString) } ?? .nothing
        default: return .nothing
        }
    }

    private func setHumanoidProperty(_ key: String, _ value: ScriptValue) {
        switch key {
        case "walkspeed": if let v = value.asFloat { humanoid.walkSpeed = max(v, 0) }
        case "jumppower": if let v = value.asFloat { humanoid.jumpPower = max(v, 0) }
        case "jumpheight": if let v = value.asFloat { humanoid.jumpHeight = max(v, 0) }
        case "usejumppower": if let v = value.asBool { humanoid.useJumpPower = v }
        case "health": if let v = value.asFloat { humanoid.setHealth(v) }
        case "maxhealth": if let v = value.asFloat { humanoid.setMaxHealth(v) }
        case "maxslopeangle": if let v = value.asFloat { humanoid.maxSlopeAngle = min(max(v, 0), 89) }
        case "autorotate": if let v = value.asBool { humanoid.autoRotate = v }
        case "jump": if let v = value.asBool, !humanoid.isDead { humanoid.jump = v }
        case "sit": if value.asBool == false { standUp() }
        default: break
        }
    }

    /// Roblox's Humanoid:Move. Relative to the camera, -Z is the way it faces.
    private func move(_ direction: Vec3, relativeToCamera: Bool) {
        guard !humanoid.isDead else { return }
        var world = direction
        if relativeToCamera {
            let forward = Vec3(-sin(camera.yaw), 0, -cos(camera.yaw))
            let right = Vec3(cos(camera.yaw), 0, -sin(camera.yaw))
            world = right * direction.x + forward * (-direction.z) + Vec3(0, direction.y, 0)
        }
        let horizontal = Vec3(world.x, 0, world.z)
        let clamped = length(horizontal) > 1 ? normalize(horizontal) : horizontal
        humanoid.moveDirection = Vec3(clamped.x, max(-1, min(1, world.y)), clamped.z)
        // Steering by hand cancels a MoveTo, as it does in Roblox.
        if humanoid.moveToTarget != nil, length(horizontal) > 0.01 {
            humanoid.finishMoveTo(reached: false)
            humanoid.moveDirection = Vec3(clamped.x, max(-1, min(1, world.y)), clamped.z)
        }
    }
}
