import Foundation
import simd

/// Animate: the default Animate core script playing the built-in animations (idle, a walk
/// that swings the legs, arms up for a jump) as tracks; a place's own Animate replacing it
/// (an empty or disabled one leaves the character still; a copy with its own walk plays
/// that); a built-in track any script loads and plays; Humanoid.Climbing and Swimming;
/// a track's Ended; and a joined player seeing the host walk with the host's own walk.
enum AnimateSelfTest {
    static func run(check: Checker) {
        testDefault(check)
        testReplaced(check)
        testTracks(check)
        testEvents(check)
        testTogether(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func place(_ extra: [Part] = []) -> SceneModel {
        let model = SceneModel()
        model.parts = [ForceSelfTest.block("Baseplate", Vec3(0, -0.5, 0), size: Vec3(200, 1, 200), anchored: true)] + extra
        model.scripts = []
        model.groups = []
        model.animations = []
        return model
    }

    /// A walk of the place's own: the left leg held forward, the right back (keys are in
    /// degrees, as the Animation Editor's are; 60° is about a radian).
    static var stomp: AnimationObject {
        var stomp = AnimationObject(name: "Stomp")
        stomp.looped = true
        stomp.priority = .movement
        for time: Float in [0, 1] {
            stomp.setKey(.leftHip, at: time, rotation: Vec3(60, 0, 0))
            stomp.setKey(.rightHip, at: time, rotation: Vec3(-60, 0, 0))
        }
        return stomp
    }
    static let stompAngle: Float = 60 * .pi / 180

    static var stompingAnimate: ScriptObject {
        var copy = CoreScripts.animateScript
        copy.id = UUID()
        copy.source = copy.source.replacingOccurrences(of: #"Walk = load("builtin://Walk")"#, with: #"Walk = load("Stomp")"#)
        return copy
    }

    /// Plays, holding `keys` for `seconds`; the largest swing of the left leg seen, and
    /// the arms' highest.
    private static func play(_ model: SceneModel, keys: [String] = [], seconds: Float,
                             _ session: PlayController? = nil) -> (session: PlayController, leg: Float, arms: Float) {
        let session = session ?? {
            let session = PlayController(model: model, console: ScriptConsole())
            session.start()
            for _ in 0..<30 { session.step(dt: frame) }
            return session
        }()
        for key in keys { session.key(key, pressed: true) }
        var leg: Float = 0, arms: Float = 0
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            leg = max(leg, abs(session.currentJoints.leftHip.x))
            arms = max(arms, session.currentJoints.leftShoulder.x)
            elapsed += frame
        }
        for key in keys { session.key(key, pressed: false) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return (session, leg, arms)
    }

    // MARK: - The default

    private static func testDefault(_ check: Checker) {
        print("\nAnimate: the default")
        let model = place()
        let still = play(model, seconds: 1)
        let session = still.session
        let loaded = session.animationPlayer.tracks.values.filter { BuiltinAnimation.withID($0.animationID) != nil }
        check("the Animate core script loads the built-in animations as tracks, idling standing still",
              loaded.count == BuiltinAnimation.allCases.count && still.leg < 0.1
              && loaded.filter(\.isPlaying).map { BuiltinAnimation.withID($0.animationID) } == [.idle],
              "\(loaded.count) \(still.leg)")
        let walking = play(model, keys: ["W"], seconds: 1, session)
        check("…walking swings the legs (its Walk)", walking.leg > 0.5, "\(walking.leg)")
        let jumping = play(model, keys: ["Space"], seconds: 0.3, session)
        check("…and a jump puts the arms up", jumping.arms > 2, "\(jumping.arms)")
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
        check("…with no errors", errors.isEmpty, "\(errors)")
        session.stop()
    }

    // MARK: - Replaced

    private static func testReplaced(_ check: Checker) {
        print("\nAnimate: a place's own")
        func walking(with animate: ScriptObject?) -> (leg: Float, hips: (Float, Float), errors: [String]) {
            let model = place()
            model.animations = [stomp]
            if let animate { model.scripts = [animate] }
            let run = play(model, keys: ["W"], seconds: 1)
            let joints = run.session.currentJoints
            let errors = run.session.console.lines.filter { $0.kind == .error }.map(\.text)
            run.session.stop()
            return (run.leg, (joints.leftHip.x, joints.rightHip.x), errors)
        }
        var empty = ScriptObject.blank(language: .luau)
        empty.name = "Animate"
        empty.host = .starterCharacter
        empty.source = "-- Nothing: the character stands still."
        var disabled = CoreScripts.animateScript
        disabled.id = UUID()
        disabled.enabled = false
        let none = walking(with: empty), off = walking(with: disabled)
        check("an Animate of the place's own replaces the default: an empty one leaves the character still",
              none.leg < 0.1 && none.errors.isEmpty, "\(none.leg)")
        check("…and so does a disabled one", off.leg < 0.1, "\(off.leg)")
        let stomping = walking(with: stompingAnimate)
        check("…a copy that loads its own walk plays that", abs(stomping.hips.0 - stompAngle) < 0.05
              && abs(stomping.hips.1 + stompAngle) < 0.05
              && stomping.errors.isEmpty, "\(stomping.hips) \(stomping.errors)")
        let model = place()
        let copied = model.copyCoreScript(named: "Animate").flatMap(model.script(id:))
        check("Edit a Copy makes an Animate in StarterCharacterScripts, as the default is",
              copied?.host == .starterCharacter && copied?.source == CoreScripts.animateScript.source)
        let copy = play(model, keys: ["W"], seconds: 1)
        check("…which walks as the default does", copy.leg > 0.5, "\(copy.leg)")
        copy.session.stop()
    }

    // MARK: - Built-in tracks

    private static func testTracks(_ check: Checker) {
        print("\nAnimate: built-in tracks")
        let model = place()
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterCharacter
        script.source = """
        local humanoid = script.Parent:WaitForChild("Humanoid")
        local animation = Instance.new("Animation")
        animation.AnimationId = "builtin://Swim"
        local swim = humanoid:LoadAnimation(animation)
        print("track", swim.Name, swim.Priority.Name, swim.Looped, swim.Length)
        swim.Priority = Enum.AnimationPriority.Action
        swim:Play(0)
        task.wait(0.5)
        local started = os.clock()
        swim.Ended:Connect(function()
        \tprint("ended", swim.IsPlaying, swim.WeightCurrent)
        end)
        swim:Stop(0.25)
        """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<20 { session.step(dt: frame) }
        let swimming = session.currentJoints
        for _ in 0..<55 { session.step(dt: frame) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        let said = session.console.lines.filter { $0.kind == .output }.map(\.text)
        check("a script loads a built-in animation as a track (Core, looped)",
              said.contains("track Swim Core true 1"), "\(said)")
        check("…plays it over the rest at Action priority: swimming on dry land", swimming.pitch < -0.9, "\(swimming.pitch)")
        check("…and a track stopped fires Ended once it's faded out", said.contains("ended false 0")
              && session.currentJoints.pitch > -0.2, "\(said) \(session.currentJoints.pitch)")
        session.stop()
    }

    // MARK: - Events

    private static func testEvents(_ check: Checker) {
        print("\nAnimate: Climbing and Swimming")
        let listen = """
        local humanoid = script.Parent:WaitForChild("Humanoid")
        humanoid.Climbing:Connect(function(speed) print("climbing", speed > 1) end)
        humanoid.Swimming:Connect(function(speed) print("swimming", speed > 1) end)
        """
        var listener = ScriptObject.blank(language: .luau)
        listener.host = .starterCharacter
        listener.source = listen
        // A truss straight ahead of where the character stands (it starts at z 18, and W
        // walks towards +Z: the camera starts looking back at it).
        var truss = ForceSelfTest.block("Truss", Vec3(0, 10, 24), size: Vec3(2, 20, 2), anchored: true)
        truss.shape = .truss
        let climbing = place([truss])
        climbing.scripts = [listener]
        let climb = play(climbing, keys: ["W"], seconds: 2)
        let climbed = climb.session.console.lines.map(\.text)
        check("Humanoid.Climbing fires with the climbing speed", climbed.contains("climbing true"), "\(climbed.suffix(4))")
        climb.session.stop()

        var water = ForceSelfTest.block("Pool", Vec3(0, 4, 0), size: Vec3(60, 8, 60), anchored: true)
        water.material = .water
        water.canCollide = false
        let swimming = place([water])
        swimming.scripts = [listener]
        let swim = play(swimming, keys: ["W"], seconds: 2)
        let swam = swim.session.console.lines.map(\.text)
        check("…and Swimming, with the swimming speed", swam.contains("swimming true"), "\(swam.suffix(4))")
        swim.session.stop()
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nAnimate: a host and a joined player")
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.animations = [stomp]
            model.scripts.append(stompingAnimate)
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1)
        host.humanoid.moveDirection = Vec3(0, 0, -1)
        LANSelfTest.run([hosting, joining], seconds: 1.5)
        let robin = sam.remotePlayers.first { $0.name == "Robin" }?.joints
        check("the host walks with the place's own walk, and the joined player sees it",
              robin.map { abs($0.leftHip.x - stompAngle) < 0.1 && abs($0.rightHip.x + stompAngle) < 0.1 } == true,
              "\(String(describing: robin))")
        let errors = (host.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
