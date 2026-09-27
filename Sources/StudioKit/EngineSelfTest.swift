import Foundation
import AVFoundation
import simd

/// The engine over a long game, through the real audio engine (rendered offline, so
/// nothing is heard): the sounds of nightfall — music stopped, music started, a gong,
/// then the first sound in a part — which once crashed the game; sounds never knocking
/// each other off the mix; the engine started again after a change of audio device,
/// the music carrying on; and Nightfall played into the night and its fighting with
/// nothing growing that should stay the same size.
enum EngineSelfTest {
    static func run(check: Checker) {
        testNightfallSounds(check)
        testManySounds(check)
        testDeviceChange(check)
        testLongGame(check)
    }

    private static func tone(_ seconds: Double) -> AVAudioPCMBuffer {
        BuiltinSounds.buffer(for: seconds > 5 ? "builtin://ObbyRun" : "builtin://Groan")!
    }

    private static func testNightfallSounds(_ check: Checker) {
        print("\nEngine: the sounds of nightfall")
        let output = SpeakerOutput(offline: true)
        let day = UUID(), night = UUID(), gong = UUID(), groan = UUID()
        output.start(day, buffer: tone(20), from: 0, looped: true, volume: 0.3, speed: 1, at: nil)
        output.stop(day)
        output.start(night, buffer: tone(20), from: 0, looped: true, volume: 0.4, speed: 1, at: nil)
        output.start(gong, buffer: tone(1), from: 0, looped: false, volume: 0.9, speed: 1, at: nil)
        // This one threw "player started when in a disconnected state", and ended the app.
        output.start(groan, buffer: tone(1), from: 0, looped: false, volume: 0.9, speed: 1, at: Vec3(-85, 4.8, 113))
        check("the first sound in a part starts, where it once crashed the game", output.isHeard(groan))
        check("…and the music and the gong still play: a new sound knocks no other off the mix",
              output.isHeard(night) && output.isHeard(gong))
        check("…and something comes out", output.renderOffline(frames: 4096) > 0.01)
    }

    private static func testManySounds(_ check: Checker) {
        print("\nEngine: many sounds")
        let output = SpeakerOutput(offline: true)
        var generator = SystemRandomNumberGenerator()
        let ids = (0..<16).map { _ in UUID() }
        var live = Set<UUID>()
        for step in 0..<200 {
            let id = ids.randomElement(using: &generator)!
            let spatial = ids.firstIndex(of: id)! >= 6
            output.start(id, buffer: tone(1), from: 0, looped: step % 5 == 0, volume: 0.5, speed: 1,
                         at: spatial ? Vec3(Float(step % 20), 1, 5) : nil)
            live.insert(id)
            if step % 7 == 0, let gone = ids.randomElement(using: &generator) {
                output.stop(gone)
                live.remove(gone)
            }
        }
        let silent = live.filter { !output.isHeard($0) }
        check("200 sounds started and stopped, flat and in parts, the same ones again and again: every one playing is heard",
              silent.isEmpty, "\(silent.count) of \(live.count) cut off")
    }

    private static func testDeviceChange(_ check: Checker) {
        print("\nEngine: a change of audio device")
        let output = SpeakerOutput(offline: true)
        let music = UUID(), bang = UUID()
        output.start(music, buffer: tone(20), from: 0, looped: true, volume: 0.4, speed: 1, at: nil)
        output.start(bang, buffer: tone(1), from: 0, looped: false, volume: 0.9, speed: 1, at: Vec3(3, 0, 0))
        // What macOS does to the engine when headphones go in or a display wakes.
        output.recover()
        check("the engine starts again: the music carries on, a short sound is let go",
              output.isHeard(music) && !output.isHeard(bang))
        let after = UUID()
        output.start(after, buffer: tone(1), from: 0, looped: false, volume: 0.9, speed: 1, at: Vec3(0, 0, 4))
        check("…and new sounds, in parts too, start as before", output.isHeard(after)
              && output.renderOffline(frames: 4096) > 0.01)
    }

    private static func testLongGame(_ check: Checker) {
        print("\nEngine: a long game")
        let previous = SoundSystem.makeOutput
        SoundSystem.makeOutput = { SpeakerOutput(offline: true) }
        defer { SoundSystem.makeOutput = previous }
        let model = SceneModel()
        NightfallSelfTest.quick(model)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let frame: Float = 1.0 / 60
        var samples: [(parts: Int, sounds: Int, groups: Int, gui: Int, luau: Int)] = []
        var nights = Set<Double>()
        for second in 0..<45 {
            // Stand at the camp and fight: swing now and then, the way a player would.
            for tick in 0..<60 {
                if tick == 0 { session.key("One", pressed: true) }
                if tick == 2 { session.key("One", pressed: false) }
                if tick % 20 == 0 { session.mouseButton(1, pressed: true) }
                if tick % 20 == 2 { session.mouseButton(1, pressed: false) }
                session.step(dt: frame)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            if let night = model.dataObjects.first(where: { $0.name == "Night" })?.number { nights.insert(night) }
            if second % 15 == 14 {
                samples.append((model.parts.count, model.sounds.count, model.groups.count, session.gui.objects.count,
                                session.scripts.luauMemory))
            }
        }
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("Nightfall through nightfall and the night's fighting, heard through the real audio engine: no errors",
              nights.contains(1) && errors.isEmpty, "nights \(nights.sorted()) \(errors.prefix(3))")
        if let first = samples.first, let last = samples.last {
            check("…and nothing growing that should stay the same size: parts, Sounds, Models, GUI, Luau's memory",
                  last.parts < first.parts + 60 && last.sounds < first.sounds + 40 && last.groups < first.groups + 20
                  && last.gui < first.gui + 40 && last.luau < first.luau * 3 + 4_000_000, "\(samples)")
        }
        session.stop()
        DataStoreFiles.shared.clear(place: Nightfall.placeID)
    }
}
