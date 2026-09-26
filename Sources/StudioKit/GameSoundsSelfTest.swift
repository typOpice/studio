import Foundation
import AVFoundation
import simd

/// Built-in sounds and the sample games' sound: every built-in made (mono, levelled,
/// the same each time, effects short and music looping without a gap); used from a
/// script and from the scene; Nightfall's music following day and night, its gong and
/// chime, groaning zombies, swings, hits and falls heard from where they happen, and a
/// player's own sounds heard by them alone; Mega Obby's music, jump pads, fading tiles,
/// checkpoints and falls; and in a network game, the host's sounds heard by a joined
/// player while the joined player's own stay theirs.
enum GameSoundsSelfTest {
    static func run(check: Checker) {
        testCatalog(check)
        testScripts(check)
        testReadme(check)
        testNightfall(check)
        testMegaObby(check)
        testTogether(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func errors(_ session: PlayController) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == .error }.map(\.text)
    }

    private static func output(_ session: PlayController) -> RecordingOutput {
        session.sounds.output as! RecordingOutput
    }

    /// The Sounds (still in the scene) that have been started, by name.
    private static func started(_ session: PlayController, in model: SceneModel) -> [SceneSound] {
        let ids = Set(output(session).started)
        return model.sounds.filter { ids.contains($0.id) }
    }

    private static func heard(_ session: PlayController, _ model: SceneModel, soundId: String) -> [SceneSound] {
        started(session, in: model).filter { $0.soundId == BuiltinSounds.prefix + soundId }
    }

    private static func playingNow(_ session: PlayController, _ model: SceneModel, named name: String) -> Bool {
        guard let sound = model.sounds.first(where: { $0.name == name }) else { return false }
        return output(session).playing[sound.id] != nil
    }

    // MARK: - The sounds themselves

    private static func testCatalog(_ check: Checker) {
        print("\nBuilt-in sounds: made")
        let names = BuiltinSounds.catalog.map(\.name)
        check("twenty effects and three pieces of music, each named once",
              BuiltinSounds.catalog.filter { $0.kind == .effect }.count == 20
              && BuiltinSounds.catalog.filter { $0.kind == .music }.count == 3 && Set(names).count == names.count)
        var problems: [String] = []
        for entry in BuiltinSounds.catalog {
            guard let buffer = BuiltinSounds.buffer(for: BuiltinSounds.prefix + entry.name),
                  let channel = buffer.floatChannelData else {
                problems.append("\(entry.name): none")
                continue
            }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: count))
            let peak = samples.reduce(0) { max($0, abs($1)) }
            let seconds = Double(count) / BuiltinSounds.sampleRate
            if buffer.format.channelCount != 1 || buffer.format.sampleRate != BuiltinSounds.sampleRate {
                problems.append("\(entry.name): format")
            }
            if samples.contains(where: { !$0.isFinite }) || peak < 0.3 || peak > 1 {
                problems.append("\(entry.name): peak \(peak)")
            }
            if entry.kind == .effect && seconds > 4 { problems.append("\(entry.name): \(seconds)s") }
            if entry.kind == .music {
                // Sound right up to the end and from the very start: no gap where it loops.
                let edge = Int(0.05 * BuiltinSounds.sampleRate)
                func loudness(_ slice: ArraySlice<Float>) -> Float {
                    (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
                }
                if seconds < 10 || loudness(samples.prefix(edge)) < 0.01 || loudness(samples.suffix(edge)) < 0.01 {
                    problems.append("\(entry.name): \(seconds)s, gap at the loop")
                }
            }
        }
        check("each is mono, levelled, short (effects) or a long loop with no gap (music)", problems.isEmpty, "\(problems)")
        check("…the same every time it's made",
              BuiltinSounds.samples(named: "Groan") == BuiltinSounds.samples(named: "Groan")
              && BuiltinSounds.samples(named: "ObbyRun") == BuiltinSounds.samples(named: "ObbyRun"))
        check("…and made once", BuiltinSounds.buffer(for: "builtin://Hit") === BuiltinSounds.buffer(for: "builtin://Hit"))
        check("anything else isn't one", BuiltinSounds.name(of: "builtin://Nope") == nil
              && BuiltinSounds.buffer(for: "builtin://Nope") == nil && BuiltinSounds.name(of: "studio://Hit") == nil)
    }

    // MARK: - From scripts and the scene

    private static func testScripts(_ check: Checker) {
        print("\nBuilt-in sounds: in a place")
        let model = SceneModel()
        model.scripts = []
        var music = SceneSound(name: "Music")
        music.soundId = "builtin://CalmDay"
        music.looped = true
        music.playing = true
        model.sounds = [music]
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local ding = Instance.new("Sound")
        ding.SoundId = "builtin://Checkpoint"
        ding.Parent = game:GetService("SoundService")
        print("ding", ding.IsLoaded, math.floor(ding.TimeLength * 10 + 0.5) / 10)
        ding:Play()
        local nothing = Instance.new("Sound")
        nothing.SoundId = "builtin://Nope"
        nothing.Parent = workspace
        print("nothing", nothing.IsLoaded, nothing.TimeLength)
        """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.3)
        let lines = session.console.lines.map(\.text)
        check("a script's Sound can be a built-in one: loaded, and as long as it is",
              lines.contains("ding true 0.9") && lines.contains("nothing false 0"), "\(lines)")
        let ding = model.sounds.first { $0.soundId == "builtin://Checkpoint" }
        check("…and it plays", ding.map { output(session).playing[$0.id]?.frames == Int(0.9 * BuiltinSounds.sampleRate) } == true)
        check("a Sound in the scene plays one from the start, looping",
              output(session).playing[music.id]?.looped == true && output(session).playing[music.id]!.frames > 200_000)
        check("no errors", errors(session).isEmpty, "\(errors(session))")
        session.stop()
    }

    /// The README's coin, as it's written.
    private static func testReadme(_ check: Checker) {
        print("\nBuilt-in sounds: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Built-in sounds"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = SceneModel()
        var coin = Part()
        coin.name = "Coin"
        coin.anchored = true
        coin.canCollide = false
        coin.size = Vec3(4, 6, 4)
        coin.position = Vec3(0, 3, 12)
        model.parts.append(coin)
        var script = ScriptObject.blank(language: .luau)
        script.source = String(block)
        model.scripts.append(script)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.3)
        session.character.position = coin.position - Vec3(0, 3, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.3)
        check("the README's coin dings, from the coin", heard(session, model, soundId: "Pickup").contains { $0.parentID == coin.id }
              && errors(session).isEmpty, "\(errors(session))")
        session.stop()
    }

    // MARK: - Nightfall

    private static func testNightfall(_ check: Checker) {
        print("\nBuilt-in sounds: Nightfall")
        let state = Nightfall.state()
        let everywhere = state.sounds.filter { $0.parentID == nil }
        check("its music and news sounds are in SoundService, all built in",
              Set(everywhere.map(\.name)) == ["DayMusic", "NightMusic", "NightFalls", "Dawn", "KeyFound", "GateOpens"]
              && everywhere.allSatisfy { BuiltinSounds.name(of: $0.soundId) != nil })
        let groans = state.sounds.filter { $0.name == "Groan" }
        check("…and every zombie has a groan in its head", groans.count == 3 && groans.allSatisfy { groan in
            state.parts.first { $0.id == groan.parentID }?.name == "Head"
        })

        let model = SceneModel()
        NightfallSelfTest.quick(model)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.5)
        check("the day's music plays from the start", playingNow(session, model, named: "DayMusic")
              && !playingNow(session, model, named: "NightMusic"))
        step(session, seconds: 1.5)
        check("night: the night's music instead, and a gong", playingNow(session, model, named: "NightMusic")
              && !playingNow(session, model, named: "DayMusic") && !heard(session, model, soundId: "Gong").isEmpty)
        step(session, seconds: 3)
        let groaning = heard(session, model, soundId: "Groan")
        check("zombies groan, heard from where they are", !groaning.isEmpty && groaning.allSatisfy { groan in
            groan.parentID != nil && output(session).started.contains(groan.id)
        }, "\(groaning.count)")

        NightfallSelfTest.press(session, "One")
        let hurt = heard(session, model, soundId: "Hurt").count
        if let zombie = NightfallSelfTest.zombies(model).first {
            // Close enough to bite, before it's swung at.
            let pivot = model.pivot(of: zombie.id)
            model.movePivot(of: zombie.id, to: Pose(position: session.character.position + Vec3(0, 0, -2.5),
                                                    orientation: pivot?.orientation ?? simd_quatf(angle: 0, axis: Vec3(0, 1, 0))))
            step(session, seconds: 1.2)
            check("a bite: a hit heard where you are, and your own hurt", !heard(session, model, soundId: "Hit").isEmpty
                  && heard(session, model, soundId: "Hurt").count > hurt
                  && heard(session, model, soundId: "Hurt").allSatisfy(\.local))
            _ = NightfallSelfTest.slay(session, model, zombie: zombie.id)
            check("a swing, and a zombie falling", !heard(session, model, soundId: "Swing").isEmpty
                  && !heard(session, model, soundId: "ZombieDown").isEmpty)
        }
        step(session, seconds: 1)
        check("the orb it dropped, heard by you alone", heard(session, model, soundId: "Pickup").contains { $0.local })
        if let last = NightfallSelfTest.zombies(model).first?.id { _ = NightfallSelfTest.slay(session, model, zombie: last) }
        step(session, seconds: 0.5)
        check("dawn: a chime, and the day's music back", !heard(session, model, soundId: "Chime").isEmpty
              && playingNow(session, model, named: "DayMusic") && !playingNow(session, model, named: "NightMusic"))
        session.humanoid.takeDamage(1000)
        step(session, seconds: 0.4)
        check("falling: the run's end, heard by you alone", heard(session, model, soundId: "Defeat").contains { $0.local })
        check("no errors", errors(session).isEmpty, "\(errors(session))")
        session.stop()
        DataStoreFiles.shared.clear(place: Nightfall.placeID)
    }

    // MARK: - Mega Obby

    private static func pad(_ model: SceneModel, _ stage: Int) -> Vec3 {
        model.parts.first { pad in
            pad.name == "Checkpoint"
                && model.dataObjects.contains { $0.name == "Stage" && $0.parent == .node(pad.id) && $0.number == Double(stage) }
        }?.position ?? .zero
    }

    private static func teleport(_ session: PlayController, onto spot: Vec3) {
        session.character.position = spot + Vec3(0, 0.6, 0)
        session.character.velocity = .zero
    }

    private static func testMegaObby(_ check: Checker) {
        print("\nBuilt-in sounds: Mega Obby")
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
        let model = SceneModel()
        model.loadMegaObby()
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.6)
        check("its music plays from the start, looping", playingNow(session, model, named: "Music")
              && output(session).playing[model.sounds.first { $0.name == "Music" }!.id]?.looped == true)
        check("every jump pad and fading tile has its sound", model.parts.filter { $0.name == "JumpPad" || $0.name == "FadeTile" }
            .allSatisfy { part in model.sounds.contains { $0.parentID == part.id } })
        teleport(session, onto: pad(model, 2))
        step(session, seconds: 0.3)
        check("a new checkpoint: a ding, yours alone", heard(session, model, soundId: "Checkpoint").contains { $0.local })
        let jump = model.parts.first { $0.name == "JumpPad" }!
        teleport(session, onto: jump.position + Vec3(0, jump.size.y / 2, 0))
        step(session, seconds: 0.2)
        let boing = heard(session, model, soundId: "Boing")
        check("a jump pad boings, heard from the pad", boing.contains { $0.parentID == jump.id && !$0.local })
        let tile = model.parts.first { $0.name == "FadeTile" }!
        step(session, seconds: 1)
        teleport(session, onto: tile.position + Vec3(0, tile.size.y / 2, 0))
        step(session, seconds: 0.2)
        check("a fading tile cracks", heard(session, model, soundId: "Crack").contains { $0.parentID == tile.id })
        session.humanoid.takeDamage(1000)
        step(session, seconds: 0.2)
        check("a fall: oof", heard(session, model, soundId: "Oof").contains { $0.local })
        check("no errors", errors(session).isEmpty, "\(errors(session))")
        session.stop()
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nBuilt-in sounds: a host and a joined player")
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
        let state = MegaObby.state()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let kept = model.scripts
            model.state = state
            model.scripts += kept
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1)
        check("the joined player hears the music too", playingNow(sam, joining.model, named: "Music"))
        let checkpoint = state.parts.first { pad in
            pad.name == "Checkpoint"
                && state.dataObjects.contains { $0.name == "Stage" && $0.parent == .node(pad.id) && $0.number == 3 }
        }!
        sam.character.position = checkpoint.position + Vec3(0, 0.6, 0)
        sam.character.velocity = .zero
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        check("their checkpoint's ding is theirs: heard by them, not by the host",
              heard(sam, joining.model, soundId: "Checkpoint").contains { $0.local }
              && heard(host, hosting.model, soundId: "Checkpoint").isEmpty)
        let jump = state.parts.first { $0.name == "JumpPad" }!
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        sam.character.position = jump.position + Vec3(0, jump.size.y / 2 + 0.6, 0)
        sam.character.velocity = .zero
        LANSelfTest.run([hosting, joining], seconds: 0.4)
        check("a jump pad the host's script boings for them is heard in their game",
              heard(sam, joining.model, soundId: "Boing").contains { $0.parentID == jump.id })
        let problems = errors(host) + errors(sam)
        check("…with no errors on either", problems.isEmpty, "\(problems)")
        joining.leaveGame()
        hosting.leaveGame()
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
    }
}
