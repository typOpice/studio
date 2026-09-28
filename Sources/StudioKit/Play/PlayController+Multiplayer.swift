import Foundation
import QuartzCore
import simd

// PlayController in a network game: the other players — drawn, named, walked into, and
// standing in the host's physics — and this player as the others see it. The stored
// state (`worldFromHost`, `remotePlayers`, `shownRemote`) is in PlayController.swift.

extension PlayController {
    /// The other players as the renderer draws them, where they glide to.
    var remoteAvatars: [AvatarPose] {
        remotePlayers.map { remote in
            let shown = shownRemote[remote.id] ?? (remote.position, remote.yaw)
            var other = AvatarPose(position: shown.position, yaw: shown.yaw, joints: remote.joints)
            other.colors = remote.colors
            other.look = remote.look
            other.dead = remote.dead
            return other
        }
    }

    /// The other players as something to walk into: an upright cylinder each, the size
    /// of the capsule. Empty when the map turns player collisions off, and for the dead.
    var otherPlayersInTheWay: [Part] {
        guard settings.playersCollide else { return [] }
        return remotePlayers.filter { !$0.dead }.map { remote in
            var body = Part()
            body.shape = .cylinder
            body.size = Vec3(CharacterController.capsuleRadius * 2, CharacterController.capsuleHeight,
                             CharacterController.capsuleRadius * 2)
            body.position = remote.position + Vec3(0, CharacterController.capsuleHeight / 2, 0)
            body.anchored = true
            return body
        }
    }

    /// Each remote player's drawn place glides towards where they were last heard to be.
    func glideRemotePlayers(dt: Float) {
        let blend = min(1, dt * 15)
        for remote in remotePlayers {
            guard let shown = shownRemote[remote.id], simd_distance(shown.position, remote.position) < 20 else {
                // New, or teleported: no gliding across the map.
                shownRemote[remote.id] = (remote.position, remote.yaw)
                continue
            }
            var turn = remote.yaw - shown.yaw
            turn = atan2(sin(turn), cos(turn))
            shownRemote[remote.id] = (shown.position + (remote.position - shown.position) * blend,
                                      shown.yaw + turn * blend)
        }
    }

    /// Players in a network game stand in this machine's physics too: parts land on them
    /// and stop against them. The dead lie down, and those who left are taken out.
    func moveRemoteCapsules(dt: Float) {
        // Seated, they ride with their seat: a capsule there would only shove it.
        let standing = remotePlayers.filter { !$0.dead && $0.seat == nil }
        for remote in standing {
            // Placed, not swept: their reports come in steps, and a capsule swept to each
            // would slam into whatever it met. Their walking pushes as ours does, in
            // `remotePlayersPush`.
            physics.moveCharacter(remote.id, feet: remote.position, radius: CharacterController.capsuleRadius,
                                  height: CharacterController.capsuleHeight, dt: dt, placed: true)
        }
        physics.removeCharacters(notIn: Set([0] + standing.map(\.id)))
    }

    /// Where to write each other player's name: just above their head, where it's drawn.
    var remoteNameTags: [(name: String, position: Vec3)] {
        remotePlayers.map { remote in
            ((shownRemote[remote.id]?.position ?? remote.position) + Vec3(0, 6.1, 0), remote.name)
        }.map { (name: $0.1, position: $0.0) }
    }

    /// Where a point in the world lands in a view this size, or nil behind the camera.
    func screenPoint(of point: Vec3, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let clip = renderCamera.viewProjection(aspect: Float(size.width / size.height)) * Vec4(point, 1)
        guard clip.w > 0.1 else { return nil }
        let ndc = Vec3(clip.x, clip.y, clip.z) / clip.w
        guard abs(ndc.x) < 1.2, abs(ndc.y) < 1.2 else { return nil }
        return CGPoint(x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height)
    }

    /// This player's character as the others should see it.
    func networkState(name: String) -> PlayerState {
        PlayerState(id: 0, name: name, colors: bodyColors, look: look, position: character.position,
                    yaw: character.facingYaw, joints: currentJoints, dead: humanoid.isDead,
                    generation: characterGeneration, health: humanoid.health, maxHealth: humanoid.maxHealth,
                    walkSpeed: humanoid.walkSpeed, jumpPower: humanoid.jumpPower, state: humanoid.state.rawValue,
                    velocity: character.velocity, moveDirection: humanoid.moveDirection, seat: seatPart,
                    throttle: seatPart.flatMap { vehicleControls[$0]?.throttle } ?? 0,
                    steer: seatPart.flatMap { vehicleControls[$0]?.steer } ?? 0)
    }

    // MARK: - Other players' characters, for this game's scripts

    /// Events for this game's scripts as other players come, go, respawn, get hurt and die
    /// — the same events this player's own character raises, under their numbers.
    func noteRemoteChanges(from old: [PlayerState]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(remotePlayers.map(\.id))
        for (id, was) in before where !now.contains(id) {
            let number = RemoteCharacter.number(player: id, generation: was.generation)
            endRemoteTouches(of: id, number: number)
            takeTools(from: id, scope: number)
            if !worldFromHost {
                removeDataObjects(ofPlayer: id)
                failInvokes(waitingOn: id)
            }
            pendingEvents.append(.list([.string("CharacterRemoving"), .number(Double(number))]))
            // With their name: by the time a script asks, they're gone from the game.
            pendingEvents.append(.list([.string("PlayerRemoving"), .number(Double(id)), .string(was.name)]))
        }
        for remote in remotePlayers {
            let number = RemoteCharacter.number(player: remote.id, generation: remote.generation)
            guard let was = before[remote.id] else {
                pendingEvents.append(.list([.string("PlayerAdded"), .number(Double(remote.id))]))
                pendingEvents.append(.list([.string("CharacterAdded"), .number(Double(number))]))
                giveStarterTools(to: remote.id, scope: number)
                continue
            }
            if was.generation != remote.generation {
                let old = RemoteCharacter.number(player: remote.id, generation: was.generation)
                endRemoteTouches(of: remote.id, number: old)
                takeTools(from: remote.id, scope: old)
                pendingEvents.append(.list([.string("CharacterRemoving"), .number(Double(old))]))
                pendingEvents.append(.list([.string("CharacterAdded"), .number(Double(number))]))
                giveStarterTools(to: remote.id, scope: number)
                continue
            }
            func humanoid(_ event: HumanoidEvent) {
                pendingEvents.append(.list([.string("Humanoid"), .number(Double(number))] + Self.scriptArguments(for: event)))
            }
            if remote.health != was.health { humanoid(.healthChanged(remote.health)) }
            if remote.state != was.state, let from = HumanoidStateType(rawValue: was.state),
               let to = HumanoidStateType(rawValue: remote.state) {
                humanoid(.stateChanged(from: from, to: to))
            }
            if remote.dead && !was.dead { humanoid(.died) }
        }
    }

    /// On the host, what each other player's body touches, from where they last said they
    /// were: `Touched` and `TouchEnded` on parts, as for this player's own.
    func updateRemoteTouches() {
        guard !worldFromHost else { return }
        for remote in remotePlayers {
            let number = RemoteCharacter.number(player: remote.id, generation: remote.generation)
            let now = remote.dead ? [] : CharacterTouch.contacts(position: remote.position, yaw: remote.yaw,
                                                                 parts: model.parts)
            let was = remoteTouching[remote.id] ?? []
            let existing = Set(model.parts.map(\.id))
            queueTouches(was.subtracting(now).filter { existing.contains($0.partID) }, phase: "Ended", character: number)
            queueTouches(now.subtracting(was), phase: "Began", character: number)
            remoteTouching[remote.id] = now
            if !remote.dead { pickUpTools(touched: now.subtracting(was), by: remote.id) }
        }
    }

    private func endRemoteTouches(of id: Int, number: Int) {
        if let was = remoteTouching.removeValue(forKey: id), !worldFromHost {
            let existing = Set(model.parts.map(\.id))
            queueTouches(was.filter { existing.contains($0.partID) }, phase: "Ended", character: number)
        }
    }

    /// A host call about another player's character, answered from what that player last
    /// said — or, for anything that changes it, sent to their game, which runs it.
    func remoteCharacterCall(_ name: String, number: Int, owner: Int, _ arguments: [ScriptValue]) -> ScriptValue {
        // A track a host script holds on another player: its handle stands where a
        // character's number would.
        if ["track.play", "track.stop", "track.get", "track.set"].contains(name) {
            return remoteTrackCall(name, handle: number, arguments)
        }
        let remote = remotePlayers.first { $0.id == owner }
        let current = remote.map { RemoteCharacter.number(player: owner, generation: $0.generation) == number } ?? false
        let key = arguments.count > 1 ? (arguments[1].asString ?? "").lowercased() : ""
        switch name {
        case "character.alive":
            return .bool(current)
        case "character.name":
            return .string(remote?.name ?? "Player")
        case "character.owner":
            return .number(Double(owner))
        case "humanoid.get":
            guard let remote, current else {
                return key == "health" ? .number(0) : key == "state" ? .string(HumanoidStateType.dead.rawValue) : .nothing
            }
            let reported: ScriptValue
            switch key {
            case "health": reported = scalar(remote.health)
            case "maxhealth": reported = scalar(remote.maxHealth)
            case "walkspeed": reported = scalar(remote.walkSpeed)
            case "jumppower": reported = scalar(remote.jumpPower)
            case "state": return .string(remote.state)
            case "sit": return .bool(remote.seat != nil)
            case "seatpart": return remote.seat.map { .string($0.uuidString) } ?? .nothing
            case "movedirection": return .triple(remote.moveDirection.x, remote.moveDirection.y, remote.moveDirection.z)
            default: return humanoidDefault(key)
            }
            return pendingWrite("humanoid." + key, owner: owner, number: number, reported: reported) ?? reported
        case "root.get":
            guard let remote else { return .nothing }
            switch key {
            case "position":
                let centre = remote.position + Vec3(0, 3, 0)
                let reported = ScriptValue.triple(centre.x, centre.y, centre.z)
                return pendingWrite("root.position", owner: owner, number: number, reported: reported) ?? reported
            case "velocity", "assemblylinearvelocity":
                return .triple(remote.velocity.x, remote.velocity.y, remote.velocity.z)
            default: return .nothing
            }
        case "body.get":
            guard let remote, arguments.count >= 3, let part = arguments[1].asString else { return .nothing }
            switch (arguments[2].asString ?? "").lowercased() {
            case "color":
                guard let colour = remote.colors[part] else { return .nothing }
                return .triple(colour.x, colour.y, colour.z)
            case "transparency": return .number(0)
            case "size":
                guard let size = AvatarPose.bodyParts.first(where: { $0.name == part })?.size else { return .nothing }
                return .triple(size.x, size.y, size.z)
            default: return .nothing
            }
        case "look.get":
            guard let remote else { return AvatarLook().scriptValue }
            let reported = remote.look.scriptValue
            return pendingWrite("look", owner: owner, number: number, reported: reported) ?? reported
        case "humanoid.set", "humanoid.damage", "humanoid.move", "humanoid.moveTo", "humanoid.state",
             "root.set", "body.set", "character.moveTo", "look.set":
            // Only the host runs the scene's scripts, so only the host sends these on.
            guard current, !worldFromHost, let forward = forwardToPlayer else {
                return name == "humanoid.state" ? .bool(false) : .nothing
            }
            forward(owner, name, Array(arguments.dropFirst()))
            if let remote { notePendingWrite(name, owner: owner, number: number, arguments, remote: remote) }
            return name == "humanoid.state" ? .bool(true) : .nothing
        case "track.load":
            // The track is played in that player's game, so everyone sees it; the host
            // keeps its own account of it to answer scripts' reads.
            guard current, !worldFromHost, let forward = forwardToPlayer, arguments.count >= 2,
                  let key = arguments[1].asString,
                  let animation = model.animations.first(where: { $0.id.uuidString == key })
                    ?? model.animation(named: key) else { return .nothing }
            remoteTracksLoaded += 1
            let handle = RemoteCharacter.number(player: owner, generation: remoteTracksLoaded)
            remoteTracks[handle] = RemoteTrack(owner: owner, character: number, animation: animation)
            forward(owner, "track.remote", [.number(Double(handle)), .string("load"), .string(animation.id.uuidString)])
            return .number(Double(handle))
        case "track.playing":
            let playing = remoteTracks.filter { $0.value.character == number && $0.value.isPlaying(at: clock) }
            return .list(playing.keys.sorted().map { .number(Double($0)) })
        default:
            return .nothing
        }
    }

    // MARK: - Animation tracks on other players

    /// A host script's call on a track it plays on another player: sent to their game,
    /// where the track really plays, and remembered here, so reads have an answer.
    private func remoteTrackCall(_ name: String, handle: Int, _ arguments: [ScriptValue]) -> ScriptValue {
        guard var track = remoteTracks[handle], isCurrent(track) else {
            return name == "track.get" && (arguments.count > 1 ? arguments[1].asString?.lowercased() : nil) == "isplaying"
                ? .bool(false) : .nothing
        }
        func number(_ index: Int) -> Float? { arguments.count > index ? arguments[index].asFloat : nil }
        let key = arguments.count > 1 ? (arguments[1].asString ?? "").lowercased() : ""
        switch name {
        case "track.get":
            switch key {
            case "isplaying": return .bool(track.isPlaying(at: clock))
            case "length": return scalar(track.length)
            case "looped": return .bool(track.looped)
            case "speed": return scalar(track.speed)
            case "timeposition": return scalar(track.position(at: clock))
            case "weightcurrent", "weighttarget": return scalar(track.isPlaying(at: clock) ? track.weight : 0)
            case "priority": return .string(track.priority)
            default: return .nothing
            }
        case "track.play":
            track.weight = number(2) ?? 1
            track.rebase(at: clock, time: 0)
            track.speed = number(3) ?? 1
            track.playing = true
        case "track.stop":
            if track.isPlaying(at: clock) { queueTrackEvent(handle, .stopped) }
            track.playing = false
        case "track.set":
            guard arguments.count >= 3 else { return .nothing }
            let value = arguments[2]
            switch key {
            case "looped": if let looped = value.asBool { track.rebase(at: clock); track.looped = looped }
            case "speed": if let speed = value.asFloat { track.rebase(at: clock); track.speed = speed }
            case "timeposition": if let time = value.asFloat { track.rebase(at: clock, time: min(max(time, 0), track.length)) }
            case "priority": if let priority = value.asString { track.priority = priority }
            case "weight": if let weight = value.asFloat { track.weight = weight }
            default: break
            }
        default:
            return .nothing
        }
        remoteTracks[handle] = track
        if !worldFromHost, let forward = forwardToPlayer {
            let operation = String(name.dropFirst("track.".count))
            forward(track.owner, "track.remote", [.number(Double(handle)), .string(operation)] + Array(arguments.dropFirst()))
        }
        return .nothing
    }

    private func isCurrent(_ track: RemoteTrack) -> Bool {
        guard let remote = remotePlayers.first(where: { $0.id == track.owner }) else { return false }
        return RemoteCharacter.number(player: track.owner, generation: remote.generation) == track.character
    }

    /// Stopped for tracks on other players that have run to their end by this game's
    /// clock; tracks whose character has gone are forgotten.
    func updateRemoteTracks() {
        for (handle, track) in remoteTracks {
            if !isCurrent(track) {
                remoteTracks[handle] = nil
            } else if track.playing && !track.isPlaying(at: clock) {
                remoteTracks[handle]?.playing = false
                queueTrackEvent(handle, .stopped)
            }
        }
    }

    // MARK: - Writes waiting on a round trip

    /// How long a host script's change to another player is read back before that
    /// player's own report is believed again.
    static let pendingWriteLifetime: CFTimeInterval = 0.5

    /// Remembers a change a host script sent to another player, as their game will make
    /// it (Health clamped to MaxHealth, damage taken off), so reading it straight back
    /// gives the new value rather than the one from before the round trip.
    private func notePendingWrite(_ name: String, owner: Int, number: Int, _ arguments: [ScriptValue],
                                  remote: PlayerState) {
        func effective(_ key: String, _ reported: Float) -> Float {
            pendingWrite(key, owner: owner, number: number, reported: scalar(reported))?.asFloat ?? reported
        }
        let key = arguments.count > 1 ? (arguments[1].asString ?? "").lowercased() : ""
        var writes: [(String, ScriptValue)] = []
        switch name {
        case "humanoid.set":
            guard arguments.count >= 3 else { return }
            let value = arguments[2]
            switch key {
            case "health":
                guard let health = value.asFloat else { return }
                let most = effective("humanoid.maxhealth", remote.maxHealth)
                writes = [("humanoid.health", scalar(min(max(health, 0), most)))]
            case "maxhealth":
                guard let most = value.asFloat.map({ max($0, 0) }) else { return }
                writes = [("humanoid.maxhealth", scalar(most))]
                let health = effective("humanoid.health", remote.health)
                if health > most { writes.append(("humanoid.health", scalar(most))) }
            case "walkspeed", "jumppower":
                guard let number = value.asFloat else { return }
                writes = [("humanoid." + key, scalar(number))]
            default: return
            }
        case "humanoid.damage":
            guard arguments.count >= 2, let amount = arguments[1].asFloat else { return }
            let health = effective("humanoid.health", remote.health)
            writes = [("humanoid.health", scalar(max(health - max(amount, 0), 0)))]
        case "root.set":
            guard key == "position", arguments.count >= 3, arguments[2].asTriple != nil else { return }
            writes = [("root.position", arguments[2])]
        case "look.set":
            // What they'll wear once their game has it: the change made to what they
            // wear now (or to the last change still on its way).
            guard arguments.count >= 3 else { return }
            var look = remote.look
            if let pending = pendingWrite("look", owner: owner, number: number, reported: remote.look.scriptValue),
               let known = AvatarLook(scriptValue: pending) {
                look = known
            }
            guard look.set(key, arguments[2]) else { return }
            writes = [("look", look.scriptValue)]
        default:
            return
        }
        let until = CACurrentMediaTime() + Self.pendingWriteLifetime
        for (key, value) in writes {
            pendingRemoteWrites[owner, default: [:]][key] = PendingRemoteWrite(number: number, value: value, until: until)
        }
    }

    /// A change still on its way to another player, or nil once their report shows it,
    /// their character has changed, or it has waited long enough.
    func pendingWrite(_ key: String, owner: Int, number: Int, reported: ScriptValue) -> ScriptValue? {
        guard let pending = pendingRemoteWrites[owner]?[key] else { return nil }
        if pending.number != number || CACurrentMediaTime() > pending.until || pending.value.isClose(to: reported) {
            pendingRemoteWrites[owner]?[key] = nil
            return nil
        }
        return pending.value
    }

    /// A Humanoid property no update carries: what StarterPlayer gives every character.
    private func humanoidDefault(_ key: String) -> ScriptValue {
        let settings = model.starterPlayer
        switch key {
        case "jumpheight": return scalar(settings.jumpHeight)
        case "usejumppower": return .bool(settings.useJumpPower)
        case "maxslopeangle": return scalar(settings.maxSlopeAngle)
        case "autorotate": return .bool(settings.autoRotate)
        case "jump": return .bool(false)
        case "movedirection": return .triple(0, 0, 0)
        default: return .nothing
        }
    }
}

/// A track a host script plays on another player's character, as the host reckons it:
/// where it is is worked out from when it started and how fast it goes.
struct RemoteTrack {
    let owner: Int
    /// The character's number; the track ends with the character.
    let character: Int
    let animationID: UUID
    let length: Float
    var looped: Bool
    var priority: String
    var speed: Float = 1
    var weight: Float = 1
    var playing = false
    /// The clock when `time` was the track's position.
    var since: Double = 0
    var time: Float = 0

    init(owner: Int, character: Int, animation: AnimationObject) {
        self.owner = owner
        self.character = character
        animationID = animation.id
        length = animation.length
        looped = animation.looped
        priority = animation.priority.rawValue
    }

    func position(at clock: Double) -> Float {
        guard playing else { return time }
        let now = time + Float(clock - since) * speed
        if looped, length > 0 { return now.truncatingRemainder(dividingBy: length) }
        return min(now, length)
    }

    func isPlaying(at clock: Double) -> Bool {
        playing && (looped || time + Float(clock - since) * speed < length)
    }

    /// Carries on from where it is now (or from `time`), before a change of pace.
    mutating func rebase(at clock: Double, time newTime: Float? = nil) {
        time = newTime ?? position(at: clock)
        since = clock
    }
}

/// A host script's change to another player's character, not yet in their reports.
struct PendingRemoteWrite {
    /// The character it was made to; a respawn makes it moot.
    let number: Int
    let value: ScriptValue
    let until: CFTimeInterval
}

private extension ScriptValue {
    /// Equal, allowing for the Float a value takes on its way through a player's game.
    func isClose(to other: ScriptValue) -> Bool {
        if let a = asDouble, let b = other.asDouble { return abs(a - b) < 1e-3 }
        if let (x1, y1, z1) = asTriple, let (x2, y2, z2) = other.asTriple {
            return abs(x1 - x2) < 1e-2 && abs(y1 - y2) < 1e-2 && abs(z1 - z2) < 1e-2
        }
        return self == other
    }
}

/// Other players' characters, numbered apart from this machine's own: player `p`'s
/// `g`th character is `(p + 1) × 1 000 000 + g`. The host is player 0, so every remote
/// number is at least a million, and this player's own generations never get that far.
enum RemoteCharacter {
    static let stride = 1_000_000

    static func number(player: Int, generation: Int) -> Int { (player + 1) * stride + generation }

    /// Whose character a number is, or nil for this player's own.
    static func owner(of number: Int) -> Int? { number >= stride ? number / stride - 1 : nil }
}
