import Foundation
import simd

/// Verification for custom animations: the keyframe model, playback and layering, the
/// Animation Editor's tools (headless), and the Luau AnimationTrack API in play.
enum AnimationSelfTest {

    static func run(check: Checker) {
        testKeys(check)
        testSampling(check)
        testSaving(check)
        testPlayback(check)
        testLayering(check)
        testEditor(check)
        testScripting(check)
        testCompletion(check)
        testReadmeExample(check)
    }

    /// The README's "wave when E is pressed" script, verbatim.
    private static func testReadmeExample(_ check: Checker) {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterCharacter
        script.source = """
        local humanoid = script.Parent:WaitForChild("Humanoid")
        local animator = humanoid:WaitForChild("Animator")
        local wave = animator:LoadAnimation(Animations.Wave)

        wave:GetMarkerReachedSignal("Hello"):Connect(function()
        \tprint("Hello!")
        end)

        game:GetService("UserInputService").InputBegan:Connect(function(input)
        \tif input.KeyCode == Enum.KeyCode.E then
        \t\twave:Play()
        \tend
        end)
        """
        model.scripts = [script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<10 { session.step(dt: 1.0 / 60) }
        session.key("E", pressed: true)
        session.key("E", pressed: false)
        for _ in 0..<30 { session.step(dt: 1.0 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let lines = session.console.lines.map(\.text)
        check("the README wave example waves on E", lines.contains("Hello!") && session.currentJoints.rightShoulder.z > 1,
              "\(lines)")
        session.stop()
    }

    private static func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-3) -> Bool { abs(a - b) <= tolerance }
    private static func near(_ a: Vec3, _ b: Vec3, _ tolerance: Float = 1e-3) -> Bool { simd_distance(a, b) <= tolerance }
    private static let degrees: Float = .pi / 180

    // MARK: - The model

    private static func testKeys(_ check: Checker) {
        print("\nAnimation: keys")
        var animation = AnimationObject(name: "Test")
        animation.length = 2
        let arm = AnimationJoint.leftShoulder
        animation.setKey(arm, at: 1, rotation: Vec3(90, 0, 0))
        animation.setKey(arm, at: 0, rotation: .zero)
        animation.setKey(arm, at: 1, rotation: Vec3(45, 0, 0))
        check("keys are kept in time order, one per moment",
              animation.keys(for: arm).map(\.time) == [0, 1] && animation.keys(for: arm)[1].rotation.x == 45)

        animation.moveKey(arm, from: 1, to: 1.5)
        check("a key can be moved in time", animation.keys(for: arm).map(\.time) == [0, 1.5])
        animation.moveKey(arm, from: 1.5, to: 0)
        check("moving onto another key replaces it", animation.keys(for: arm).count == 1
              && animation.keys(for: arm)[0].rotation.x == 45)

        animation.setKey(arm, at: 1.8, rotation: Vec3(10, 20, 30))
        animation.setLength(1)
        check("shortening drops keys past the end", animation.keys(for: arm).map(\.time) == [0])

        animation.setKey(arm, at: 0.5, rotation: Vec3(10, 20, 30))
        animation.mirror(arm)
        let mirrored = animation.keys(for: .rightShoulder)
        check("mirroring copies to the other side, flipped",
              mirrored.count == 2 && mirrored[1].rotation == Vec3(10, -20, -30), "\(mirrored.map(\.rotation))")

        animation.removeKey(arm, at: 0.5)
        animation.removeKey(arm, at: 0)
        check("removing the last key un-keys the joint", animation.keys[arm.rawValue] == nil)

        animation.setKey(.rootJoint, at: 0, rotation: .zero, position: Vec3(0, 1, 0))
        check("the root keys an offset too", animation.keys(for: .rootJoint)[0].position.y == 1)
    }

    private static func testSampling(_ check: Checker) {
        var animation = AnimationObject()
        animation.length = 2
        animation.keys[AnimationJoint.neck.rawValue] = [
            JointKey(time: 0.5, rotation: Vec3(0, 0, 0), easing: .linear),
            JointKey(time: 1.5, rotation: Vec3(40, 0, 0), easing: .constant),
            JointKey(time: 2, rotation: Vec3(-40, 0, 0)),
        ]
        let x = { (t: Float) in (animation.sample(.neck, at: t)?.rotation.x ?? .nan) / degrees }
        check("before the first key, the first key holds", near(x(0), 0))
        check("linear keys interpolate evenly", near(x(1), 20))
        check("a constant key holds until the next", near(x(1.75), 40))
        check("after the last key, it holds", near(x(2.5), -40))
        check("an unkeyed joint isn't animated", animation.sample(.leftHip, at: 1) == nil)
        check("rotations come out in radians", near(animation.sample(.neck, at: 1.5)!.rotation.x, 40 * degrees))

        let curves = AnimationEasing.allCases.filter { $0 != .constant }
        check("every easing starts at 0 and ends at 1",
              curves.allSatisfy { near($0.apply(0), 0) && near($0.apply(1), 1) })
        check("cubic eases through the middle", near(AnimationEasing.cubic.apply(0.5), 0.5))
    }

    private static func testSaving(_ check: Checker) {
        var state = SceneState()
        state.animations = [AnimationObject.waveExample()]
        let data = try? JSONEncoder().encode(state)
        let back = data.flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) }
        check("animations are saved with the scene", back?.animations == state.animations)
        let old = try? JSONDecoder().decode(SceneState.self, from: Data(#"{"parts":[]}"#.utf8))
        check("older files open with no animations", old?.animations.isEmpty == true)

        let model = SceneModel()
        model.animations = []
        let id = model.addAnimation(.waveExample())
        model.editAnimation(id, "Longer") { $0.setLength(3) }
        model.undo()
        check("animation edits undo", model.animation(id: id)?.length == 1.6)
        model.undo()
        check("adding one undoes too", model.animations.isEmpty && model.selectedAnimation == nil)
        check("the starter scene comes with the Wave example",
              SceneModel().animations.map(\.name) == ["Wave"])
    }

    // MARK: - Playback

    private static func testPlayback(_ check: Checker) {
        print("\nAnimation: playback")
        var animation = AnimationObject.waveExample()
        let library = { (id: UUID) in id == animation.id ? animation : nil }
        var player = AnimationPlayer()
        let handle = player.load(animation, generation: 1)
        player.play(handle, fadeTime: 0.2)

        var events: [AnimationTrackEvent] = []
        func run(_ seconds: Float) {
            var elapsed: Float = 0
            while elapsed < seconds - 1e-4 {
                events += player.step(dt: 1.0 / 60, animation: library).map(\.event)
                elapsed += 1.0 / 60
            }
        }
        run(0.1)
        check("playing fades in", near(player.track(handle)!.weight, 0.5, 0.05), "\(player.track(handle)!.weight)")
        run(0.3)
        check("…to full weight", player.track(handle)!.weight == 1)
        check("a marker fires when reached", events == [.marker("Hello")], "\(events)")
        run(1.3)
        check("a non-looped track stops at its end", events.last == .stopped && !player.track(handle)!.isPlaying,
              "\(events)")
        run(0.2)
        check("…and fades out", player.track(handle)!.weight == 0)

        animation.looped = true
        var looping = AnimationPlayer()
        let loop = looping.load(animation, generation: 1)
        looping.play(loop, fadeTime: 0, speed: 2)
        var loopEvents: [AnimationTrackEvent] = []
        for _ in 0..<120 { loopEvents += looping.step(dt: 1.0 / 60, animation: library).map(\.event) }
        check("a looped track loops — twice as often at speed 2",
              loopEvents.filter { $0 == .didLoop }.count == 2 && looping.track(loop)!.isPlaying, "\(loopEvents)")
        check("markers fire on every pass", loopEvents.filter { $0 == .marker("Hello") }.count == 3, "\(loopEvents)")
        check("stopping a playing track reports it", looping.stop(loop) && !looping.stop(loop))
    }

    private static func testLayering(_ check: Checker) {
        var low = AnimationObject(name: "Low")
        low.priority = .movement
        low.keys[AnimationJoint.leftShoulder.rawValue] = [JointKey(time: 0, rotation: Vec3(90, 0, 0))]
        low.keys[AnimationJoint.leftHip.rawValue] = [JointKey(time: 0, rotation: Vec3(30, 0, 0))]
        var high = AnimationObject(name: "High")
        high.priority = .action
        high.keys[AnimationJoint.leftShoulder.rawValue] = [JointKey(time: 0, rotation: Vec3(0, 0, -60))]
        let library = { (id: UUID) in [low, high].first { $0.id == id } }

        var player = AnimationPlayer()
        let a = player.load(high, generation: 1)
        let b = player.load(low, generation: 1)
        player.play(a, fadeTime: 0)
        player.play(b, fadeTime: 0)    // played later, but lower priority
        _ = player.step(dt: 1.0 / 60, animation: library)
        var base = AvatarJoints()
        base.rightHip = Vec3(0.3, 0, 0)
        let joints = player.apply(to: base, animation: library)
        check("a higher priority wins the joints both key",
              near(joints.leftShoulder, Vec3(0, 0, -60 * degrees)), "\(joints.leftShoulder)")
        check("a lower one still drives the joints only it keys", near(joints.leftHip.x, 30 * degrees))
        check("joints nobody keys keep the built-in animation", joints.rightHip == base.rightHip)

        player.adjustWeight(a, 0.5, fadeTime: 0)
        _ = player.step(dt: 1.0 / 60, animation: library)
        let half = player.apply(to: base, animation: library)
        check("weight blends a track in part-way",
              near(half.leftShoulder, (Vec3(90, 0, 0) * 0.5 + Vec3(0, 0, -60) * 0.5) * degrees), "\(half.leftShoulder)")
    }

    // MARK: - The editor

    private static func testEditor(_ check: Checker) {
        print("\nAnimation: the editor")
        let model = SceneModel()
        model.parts = []
        model.animations = []
        let viewport = ViewportController(model: model)
        let editor = viewport.animationEditor
        check("no rig until the editor is open", viewport.avatars.isEmpty)

        let id = model.addAnimation()
        editor.isOpen = true
        editor.placeRig(near: Vec3(4, 0, -2))
        check("the rig stands in the viewport while editing", viewport.avatars.count == 1
              && viewport.avatars[0].position == Vec3(4, 0, -2))

        editor.selectedJoint = .leftShoulder
        editor.setTime(0.52)
        check("the playhead snaps to frames", near(editor.time, 0.5333, 1e-3), "\(editor.time)")
        editor.setTime(5)
        check("…and stays inside the animation", editor.time == 1)

        editor.setTime(0.5)
        model.commit("Posed") { editor.setPose(.leftShoulder, rotation: Vec3(80, 0, -20)) }
        check("posing keys the joint at the playhead",
              model.animation(id: id)?.keys(for: .leftShoulder).map(\.time) == [0.5]
              && editor.hasKey(.leftShoulder))
        check("the rig shows the pose", near(viewport.avatars[0].joints.leftShoulder, Vec3(80, 0, -20) * degrees))
        check("the selected body part is highlighted", viewport.avatars[0].highlighted == "Left Arm")
        model.undo()
        check("posing undoes", model.animation(id: id)?.keys(for: .leftShoulder).isEmpty == true)

        // Aim at the rig's right arm and drag it up.
        let rig = viewport.avatars[0]
        let arm = rig.partTransforms().first { $0.name == "Right Arm" }!.matrix
        let target = Vec3(arm.columns.3.x, arm.columns.3.y, arm.columns.3.z)
        let origin = target + Vec3(0, 0, -20)
        let hit = editor.pickJoint(ray: Ray(origin: origin, direction: normalize(target - origin)))
        check("clicking a body part picks its joint", hit?.joint == .rightShoulder, "\(String(describing: hit))")
        editor.setTime(0)
        editor.beginPose(.rightShoulder, at: SIMD2(100, 100), alternate: false)
        editor.dragPose(to: SIMD2(100, 50))
        editor.endPose()
        let raised = model.animation(id: id)?.keys(for: .rightShoulder).first?.rotation ?? .zero
        check("dragging up swings it forward", near(raised.x, 30), "\(raised)")
        model.undo()
        check("a whole drag is one undo step", model.animation(id: id)?.keys(for: .rightShoulder).isEmpty == true)

        model.editAnimation(id, "Loop") { $0.looped = true }
        editor.setTime(0.9)
        editor.togglePlaying()
        editor.step(dt: 0.2)
        check("previewing a looped animation wraps", near(editor.time, 0.1, 1e-3) && editor.playing, "\(editor.time)")
        model.editAnimation(id, "No loop") { $0.looped = false }
        editor.step(dt: 2)
        check("…a one-shot stops at its end", editor.time == 1 && !editor.playing)

        editor.isOpen = false
        check("closing the editor removes the rig", viewport.avatars.isEmpty)
    }

    // MARK: - Scripts

    private static func testScripting(_ check: Checker) {
        print("\nAnimation: scripts")
        let model = SceneModel()
        model.parts = []
        model.shaders = []
        model.scripts = []
        model.animations = [AnimationObject.waveExample()]
        var control = ScriptObject.blank(language: .luau)
        control.name = "ControlScript"
        control.host = .starterPlayer
        control.enabled = false
        var script = ScriptObject.blank(language: .luau)
        script.name = "Waver"
        script.host = .starterCharacter
        script.source = """
        local humanoid = script.Parent:WaitForChild("Humanoid")
        local animator = humanoid:WaitForChild("Animator")
        local wave = animator:LoadAnimation(Animations.Wave)
        print(typeof(wave), wave.ClassName, wave.Name, wave.Length, wave.IsPlaying, wave.Priority == Enum.AnimationPriority.Action)
        wave.KeyframeReached:Connect(function(name) print("reached", name) end)
        wave:GetMarkerReachedSignal("Hello"):Connect(function() print("marker Hello") end)
        wave.Stopped:Connect(function() print("stopped") end)
        wave:Play()
        task.wait(0.2)
        print("playing", wave.IsPlaying, #animator:GetPlayingAnimationTracks())

        local custom = Instance.new("Animation")
        custom.AnimationId = "Wave"
        local again = humanoid:LoadAnimation(custom)
        print("by id", again.Length, custom.ClassName)
        print(pcall(function() humanoid:LoadAnimation(nil) end))
        local missing = Instance.new("Animation")
        missing.AnimationId = "Nope"
        print(pcall(function() humanoid:LoadAnimation(missing) end))
        print(pcall(function() wave.IsPlaying = false end))
        _G.wave = wave
        """
        model.scripts = [control, script]
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        for _ in 0..<30 { session.step(dt: 1.0 / 60) }
        func output() -> [String] {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            return session.console.lines.filter { $0.kind == .output }.map(\.text)
        }
        func errors() -> [String] {
            session.console.lines.filter { $0.kind == .error }.map(\.text)
        }
        var lines = output()
        check("a track loads from the Animations service",
              lines.first == "Instance AnimationTrack Wave 1.6 false true", "\(lines) \(errors())")
        check("playing it moves the arm", session.currentJoints.rightShoulder.z > 1,
              "\(session.currentJoints.rightShoulder)")
        check("markers reach scripts both ways", lines.contains("reached Hello") && lines.contains("marker Hello"),
              "\(lines)")
        // Two playing: the wave and the Animate script's Idle, as Roblox lists them.
        check("IsPlaying and GetPlayingAnimationTracks see it", lines.contains("playing true 2"), "\(lines)")
        check("Instance.new(\"Animation\") with an AnimationId works", lines.contains("by id 1.6 Animation"), "\(lines)")
        check("LoadAnimation explains a missing Animation",
              lines.contains { $0.hasPrefix("false") && $0.contains("requires an Animation object") }, "\(lines)")
        check("…and an unknown one", lines.contains { $0.contains("no animation named \"Nope\"") }, "\(lines)")
        check("read-only track properties refuse writes", lines.contains { $0.contains("read only") }, "\(lines)")

        for _ in 0..<90 { session.step(dt: 1.0 / 60) }
        lines = output()
        check("Stopped fires at the end", lines.contains("stopped"), "\(lines)")
        for _ in 0..<12 { session.step(dt: 1.0 / 60) }
        check("…and the arm comes back", abs(session.currentJoints.rightShoulder.z) < 0.2,
              "\(session.currentJoints.rightShoulder)")
        check("no errors along the way", errors().isEmpty, "\(errors())")

        // Walking keeps the legs moving while an arm-only animation plays.
        _ = session.playerInvoke("player.load", [])
        for _ in 0..<5 { session.step(dt: 1.0 / 60) }
        session.humanoid.moveDirection = Vec3(0, 0, -1)
        for _ in 0..<20 { session.step(dt: 1.0 / 60) }
        let handle = session.animationPlayer.tracks.keys.min()
        check("a respawned character loads its own tracks", handle != nil && session.characterGeneration == 2)
        if let handle { session.animationPlayer.play(handle, fadeTime: 0) }
        var legs: Float = 0
        for _ in 0..<30 {
            session.humanoid.moveDirection = Vec3(0, 0, -1)
            session.step(dt: 1.0 / 60)
            legs = max(legs, abs(session.currentJoints.leftHip.x))
        }
        check("…and the walk still drives the legs under it", legs > 0.3 && session.currentJoints.rightShoulder.z > 1,
              "legs \(legs), arm \(session.currentJoints.rightShoulder)")
        check("the old character's track is forgotten", session.animationPlayer.tracks.values.allSatisfy { $0.generation == 2 })
        session.stop()
    }

    private static func testCompletion(_ check: Checker) {
        func labels(_ source: String) -> [String] {
            LuauCompletion.items(in: source, caret: (source as NSString).length).map(\.label)
        }
        let track = labels("local track = Players.LocalPlayer.Character.Humanoid:LoadAnimation(Animations.Wave)\ntrack:")
        check("completion knows AnimationTrack", track.contains("Play(fadeTime, weight, speed)")
              && track.contains("GetMarkerReachedSignal(name)"), "\(track)")
        let service = labels("Animations:")
        check("…and the Animations service", service.contains("FindFirstChild(name)"), "\(service)")
        let priority = labels("Enum.AnimationPriority.")
        check("…and Enum.AnimationPriority", priority.contains("Action"), "\(priority)")
    }
}
