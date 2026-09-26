import Foundation

// The script runtime's host calls for `sound.*`: Sounds in parts and in SoundService.
// Whether a Sound plays is scene data (`SceneSound.playing` and `plays`), so it reaches
// joined players; the play session's SoundSystem makes it heard.

extension ScriptRuntime {
    func soundCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        let id = uuid(arguments.first)
        func current() -> SceneSound? { id.flatMap(model.sound(id:)) }
        switch name {
        case "sound.create":
            // In a part ("p:<id>"), or everywhere. A LocalScript's are this machine's alone,
            // on the host as on a joined player.
            let parent = arguments.first?.asString.flatMap { $0.hasPrefix("p:") ? UUID(uuidString: String($0.dropFirst(2))) : nil }
            var sound = SceneSound(parentID: parent.flatMap { model.part(id: $0) != nil ? $0 : nil })
            sound.local = !runsSceneScripts || (arguments.count > 1 && arguments[1].asBool == true)
            model.sounds.append(sound)
            return .string(sound.id.uuidString)

        case "sound.list":
            // A part's Sounds ("p:<id>"), or SoundService's.
            let parent = arguments.first?.asString.flatMap { $0.hasPrefix("p:") ? UUID(uuidString: String($0.dropFirst(2))) : nil }
            return .list(model.sounds(in: parent).map { .string($0.id.uuidString) })

        case "sound.get":
            guard let sound = current(), arguments.count >= 2 else { return .nothing }
            let buffer = soundSystem?.buffer(forSoundId: sound.soundId, in: model)
            switch (arguments[1].asString ?? "").lowercased() {
            case "name": return .string(sound.name)
            case "soundid": return .string(sound.soundId)
            case "volume": return .number(Double(sound.volume))
            case "looped": return .bool(sound.looped)
            case "playbackspeed": return .number(Double(sound.playbackSpeed))
            case "rolloffmaxdistance": return .number(Double(sound.rollOffMaxDistance))
            case "playing", "isplaying": return .bool(sound.playing)
            case "ispaused": return .bool(!sound.playing && sound.timePosition > 0)
            case "isloaded": return .bool(buffer != nil)
            case "timelength": return .number(buffer.map { Double($0.frameLength) / $0.format.sampleRate } ?? 0)
            case "timeposition": return .number(soundSystem?.timePosition(of: sound, clock: clock()) ?? sound.timePosition)
            case "parent": return sound.parentID.map { .string("p:" + $0.uuidString) } ?? .string("g")
            default: return .nothing
            }

        case "sound.set":
            guard let id, current() != nil, arguments.count >= 3 else { return .nothing }
            let value = arguments[2]
            let key = (arguments[1].asString ?? "").lowercased()
            if key == "playing", let on = value.asBool {
                return soundCall(on ? "sound.resume" : "sound.pause", [arguments[0]])
            }
            model.updateSound(id: id) { sound in
                switch key {
                case "name": if let v = value.asString { sound.name = v }
                case "soundid": if let v = value.asString { sound.soundId = v }
                case "volume": if let v = value.asFloat { sound.volume = min(max(v, 0), 10) }
                case "looped": if let v = value.asBool { sound.looped = v }
                case "playbackspeed": if let v = value.asFloat { sound.playbackSpeed = min(max(v, 0.01), 20) }
                case "rolloffmaxdistance": if let v = value.asFloat { sound.rollOffMaxDistance = max(v, 0) }
                case "timeposition":
                    // Playing, it jumps there; stopped, the next Play starts there.
                    if let v = value.asDouble {
                        sound.timePosition = max(v, 0)
                        if sound.playing { sound.plays += 1 }
                    }
                default: break
                }
            }
            return .nothing

        case "sound.play":
            // From the start — or from a TimePosition a script set while it was stopped.
            guard let id else { return .nothing }
            model.updateSound(id: id) { sound in
                if sound.playing { sound.timePosition = 0 }
                sound.playing = true
                sound.plays += 1
            }
            return .nothing

        case "sound.stop":
            guard let id else { return .nothing }
            model.updateSound(id: id) { $0.playing = false; $0.timePosition = 0 }
            return .nothing

        case "sound.pause":
            guard let id, let sound = current(), sound.playing else { return .nothing }
            let at = soundSystem?.timePosition(of: sound, clock: clock()) ?? sound.timePosition
            model.updateSound(id: id) { $0.playing = false; $0.timePosition = at }
            return .nothing

        case "sound.resume":
            guard let id, let sound = current(), !sound.playing else { return .nothing }
            model.updateSound(id: id) { $0.playing = true; $0.plays += 1 }
            return .nothing

        case "sound.parent":
            guard let id, arguments.count >= 2 else { return .bool(false) }
            let target = arguments[1].asString.flatMap { $0.hasPrefix("p:") ? UUID(uuidString: String($0.dropFirst(2))) : nil }
            if let target, model.part(id: target) == nil { return .bool(false) }
            model.updateSound(id: id) { $0.parentID = target }
            return .bool(true)

        case "sound.destroy":
            guard let id else { return .nothing }
            model.sounds.removeAll { $0.id == id }
            return .nothing

        default:
            return unknownCall(name)
        }
    }
}
