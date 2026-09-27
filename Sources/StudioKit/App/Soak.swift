import AppKit
import Foundation
import Metal
import MetalKit
import simd

/// `StudioApp --soak <game> [seconds]`: plays a sample game headlessly, as fast as it
/// will go, with a player running about, swinging, jumping and falling — and every ten
/// seconds of game time prints what the process and the game hold, so anything that
/// grows and never shrinks shows up. Games: adventure, nightfall, obby, starter.
/// With `render`, every frame is drawn too, off screen, waiting for the GPU each time —
/// a GPU that stops finishing its work stops the soak on that frame.
enum Soak {
    /// What a game holds at a moment of a soak.
    struct Sample {
        var time: Double
        var footprint: Double
        var luau: Int
        var parts: Int
        var groups: Int
        var sounds: Int
        var data: Int
        var gui: Int
        var voices: Int
        var navigation: Int
        var console: Int
        /// Milliseconds a frame took, on average and at worst, since the last sample.
        var average: Double
        var worst: Double
    }

    static func template(named game: String) -> PlaceTemplate? {
        ["adventure": .adventure, "nightfall": .nightfall, "obby": .megaObby, "megaobby": .megaObby,
         "starter": .starter][game.lowercased()]
    }

    /// Plays a running game for `seconds` of game time with a player running about,
    /// jumping, swinging (Nightfall's sword is on 1) and now and then falling, sampling
    /// every `every` seconds. The same moves every time, from a seeded generator.
    /// Returns the samples and every error the scripts reported.
    static func play(_ session: PlayController, seconds: Double, every: Double = 10, renderer: Renderer? = nil,
                     report: (Sample) -> Void = { _ in }) -> (samples: [Sample], errors: [String]) {
        let model = session.model
        let frame: Float = 1.0 / 60
        var seed: UInt32 = 20_260_927
        func roll(_ count: Int) -> Int {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int(seed >> 16) % count
        }
        let keys = ["W", "A", "S", "D"]
        var held: String?
        var samples: [Sample] = []
        var elapsed = 0.0, lastReport = 0.0
        var busy = 0.0, worst = 0.0, frames = 0, total = 0
        while elapsed < seconds {
            if total % 70 == 0 {
                if let held { session.key(held, pressed: false) }
                held = keys[roll(keys.count)]
                session.key(held!, pressed: true)
            }
            if total % 150 == 0 { session.key("Space", pressed: true) }
            if total % 150 == 5 { session.key("Space", pressed: false) }
            if total == 30 { session.key("One", pressed: true) }
            if total == 32 { session.key("One", pressed: false) }
            if total % 40 == 0 { session.mouseButton(1, pressed: true) }
            if total % 40 == 3 { session.mouseButton(1, pressed: false) }
            if total % 3600 == 1800 { session.humanoid.takeDamage(1000) }
            // Wander no further than the game's own ground.
            if simd_length(SIMD2(session.character.position.x, session.character.position.z)) > 150 {
                session.character.position = Vec3(0, 5, 0)
            }
            let started = Date()
            // A pool per frame, as the app's event loop drains one per event.
            autoreleasepool {
                session.step(dt: frame)
                if let renderer { _ = renderer.frameSnapshot(width: 640, height: 400) }
            }
            let took = Date().timeIntervalSince(started)
            busy += took
            worst = max(worst, took)
            frames += 1
            total += 1
            elapsed += Double(frame)
            if elapsed - lastReport >= every {
                lastReport = elapsed
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                let sample = Sample(time: elapsed, footprint: footprintMB(), luau: session.scripts.luauMemory,
                                    parts: model.parts.count, groups: model.groups.count, sounds: model.sounds.count,
                                    data: model.dataObjects.count, gui: session.gui.objects.count,
                                    voices: session.sounds.voiceCount, navigation: session.scripts.navigation.partsDrawn,
                                    console: session.console.lines.count, average: busy / Double(frames) * 1000,
                                    worst: worst * 1000)
                samples.append(sample)
                report(sample)
                busy = 0
                worst = 0
                frames = 0
            }
        }
        if let held { session.key(held, pressed: false) }
        return (samples, session.console.lines.filter { $0.kind == .error }.map(\.text))
    }

    static func run(game: String, seconds: Double, render: Bool = false, audio: Bool = false) -> Bool {
        guard let template = template(named: game) else {
            print("No game called \(game): adventure, nightfall, obby or starter")
            return false
        }
        if !audio { SoundSystem.makeOutput = { RecordingOutput() } }
        DataStoreFiles.shared.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSoak-\(UUID().uuidString)")
        let model = SceneModel()
        model.loadTemplate(template)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        var renderer: Renderer?
        if render, let device = MTLCreateSystemDefaultDevice() {
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), device: device)
            renderer = Renderer(device: device, view: view, source: session)
            for shader in model.shaders { renderer?.shaderLibrary.compileNow(shader) }
            print("rendering: \(model.lighting.technology), ray tracing \(renderer?.rayTracingSupported == true ? "supported" : "not supported")")
        }
        print("time   footprint  luau    parts groups sounds data  gui   voices nav   console  ms/frame")
        let (_, errors) = play(session, seconds: seconds, renderer: renderer) { sample in
            print(String(format: "%5.0fs %8.1fMB %6.1fMB %5d %6d %6d %5d %5d %6d %5d %7d %8.2f  worst %.0fms",
                         sample.time, sample.footprint, Double(sample.luau) / 1_048_576, sample.parts, sample.groups,
                         sample.sounds, sample.data, sample.gui, sample.voices, sample.navigation, sample.console,
                         sample.average, sample.worst))
        }
        print("errors: \(errors.count)")
        for error in Set(errors).prefix(10) { print("  \(error)") }
        session.stop()
        return true
    }

    /// `--soak <game> <seconds> window`: the client's own viewport — a window, its
    /// drawables, the renderer driving the game in real time — drawn as fast as it will
    /// go. A frame that doesn't come back within five seconds is reported as stuck.
    static func runInWindow(game: String, seconds: Double) -> Bool {
        let templates: [String: PlaceTemplate] = ["adventure": .adventure, "nightfall": .nightfall, "obby": .megaObby]
        guard let template = templates[game.lowercased()], let device = MTLCreateSystemDefaultDevice() else { return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SoundSystem.makeOutput = { RecordingOutput() }
        DataStoreFiles.shared.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioSoak-\(UUID().uuidString)")
        let model = SceneModel()
        model.loadTemplate(template)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = MTKView(frame: window.contentLayoutRect, device: device)
        guard let renderer = Renderer(device: device, view: view, source: session) else { return false }
        view.delegate = renderer
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        window.contentView = view
        window.orderFrontRegardless()
        for shader in model.shaders { renderer.shaderLibrary.compileNow(shader) }
        // Watches the main thread from another: a frame that never finishes says so.
        let beat = Heartbeat()
        Thread.detachNewThread {
            var last = -1, still = 0
            while true {
                Thread.sleep(forTimeInterval: 1)
                let now = beat.frames
                still = now == last ? still + 1 : 0
                last = now
                if still == 5 { print("STUCK at frame \(now) (\(String(format: "%.1f", beat.seconds))s)"); fflush(stdout) }
            }
        }
        let started = Date()
        var reported = 0.0
        while Date().timeIntervalSince(started) < seconds {
            autoreleasepool {
                view.draw()
                RunLoop.current.run(until: Date())
            }
            beat.frames += 1
            beat.seconds = Date().timeIntervalSince(started)
            if beat.seconds - reported >= 5 {
                reported = beat.seconds
                print(String(format: "%5.1fs frame %6d  footprint %7.1fMB  phase %@", beat.seconds, beat.frames, footprintMB(),
                             model.dataObjects.first { $0.name == "Phase" }?.text ?? "-"))
                fflush(stdout)
            }
        }
        session.stop()
        return true
    }

    final class Heartbeat: @unchecked Sendable {
        var frames = 0
        var seconds = 0.0
    }

    /// The process's footprint, as Activity Monitor's Memory column counts it.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// `StudioApp --bench`: what the scene's everyday operations cost as places grow —
/// finding a part, changing one, a Model's pivot and moving it, a folder's children.
enum SceneBench {
    static func run() -> Bool {
        print("parts   find part   change part   model pivot   move model   children    (µs per call)")
        for count in [500, 2000, 8000] {
            let model = SceneModel()
            model.parts = []
            model.groups = []
            var ids: [UUID] = []
            var models: [UUID] = []
            for index in 0..<count {
                if index % 10 == 0 {
                    let group = SceneGroup(name: "Model\(index)", kind: .model)
                    model.groups.append(group)
                    models.append(group.id)
                }
                var part = Part()
                part.position = Vec3(Float(index % 100), 1, Float(index / 100))
                part.parentID = models.last
                model.parts.append(part)
                ids.append(part.id)
            }
            func time(_ runs: Int, _ body: (Int) -> Void) -> Double {
                let started = Date()
                for run in 0..<runs { body(run) }
                return Date().timeIntervalSince(started) / Double(runs) * 1_000_000
            }
            var sink = 0.0
            let find = time(2000) { run in sink += Double(model.part(id: ids[(run * 7919) % count])?.position.x ?? 0) }
            let change = time(2000) { run in model.update(id: ids[(run * 7919) % count]) { $0.position.y += 0.001 } }
            let pivot = time(500) { run in sink += Double(model.pivot(of: models[run % models.count])?.position.x ?? 0) }
            let move = time(200) { run in
                let id = models[run % models.count]
                if let pose = model.pivot(of: id) { model.movePivot(of: id, to: pose) }
            }
            let children = time(200) { run in sink += Double(model.children(of: models[run % models.count]).count) }
            print(String(format: "%5d %11.2f %13.2f %13.2f %12.2f %10.2f", count, find, change, pivot, move, children))
            if sink.isNaN { print(sink) }
        }
        return true
    }
}
