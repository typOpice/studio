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
    static func run(game: String, seconds: Double, render: Bool = false, audio: Bool = false) -> Bool {
        let template: PlaceTemplate
        switch game.lowercased() {
        case "adventure": template = .adventure
        case "nightfall": template = .nightfall
        case "obby", "megaobby": template = .megaObby
        case "starter": template = .starter
        default:
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
        var worst = 0.0
        if render, let device = MTLCreateSystemDefaultDevice() {
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), device: device)
            renderer = Renderer(device: device, view: view, source: session)
            for shader in model.shaders { renderer?.shaderLibrary.compileNow(shader) }
            print("rendering: \(model.lighting.technology), ray tracing \(renderer?.rayTracingSupported == true ? "supported" : "not supported")")
        }
        let frame: Float = 1.0 / 60
        var random = SystemRandomNumberGenerator()
        let keys = ["W", "A", "S", "D"]
        var held: String?
        print("time   footprint  luau    parts groups sounds data  gui   voices nav   console  ms/frame")
        var elapsed = 0.0, lastReport = -10.0
        var busy = 0.0, frames = 0
        while elapsed < seconds {
            // A player: a new direction every second or so, now and then a jump, a swing
            // (Nightfall's sword is on 1), and a fall.
            if frames % 70 == 0 {
                if let held { session.key(held, pressed: false) }
                held = keys.randomElement(using: &random)
                session.key(held!, pressed: true)
            }
            if frames % 150 == 0 { session.key("Space", pressed: true) }
            if frames % 150 == 5 { session.key("Space", pressed: false) }
            if frames == 30 { session.key("One", pressed: true) }
            if frames == 32 { session.key("One", pressed: false) }
            if frames % 40 == 0 { session.mouseButton(1, pressed: true) }
            if frames % 40 == 3 { session.mouseButton(1, pressed: false) }
            if frames % 3600 == 1800 { session.humanoid.takeDamage(1000) }
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
            if took > 0.25 { print(String(format: "  slow frame at %.1fs: %.0fms", elapsed, took * 1000)) }
            frames += 1
            elapsed += Double(frame)
            if elapsed - lastReport >= 10 {
                lastReport = elapsed
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                print(String(format: "%5.0fs %8.1fMB %6.1fMB %5d %6d %6d %5d %5d %6d %5d %7d %8.2f",
                             elapsed, footprintMB(), Double(session.scripts.luauMemory) / 1_048_576,
                             model.parts.count, model.groups.count, model.sounds.count, model.dataObjects.count,
                             session.gui.objects.count, session.sounds.voiceCount, session.scripts.navigation.partsDrawn,
                             session.console.lines.count, busy / Double(frames) * 1000) + String(format: "  worst %.0fms", worst * 1000))
                busy = 0
                worst = 0
                frames = 0
            }
        }
        let errors = session.console.lines.filter { $0.kind == .error }.map(\.text)
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
