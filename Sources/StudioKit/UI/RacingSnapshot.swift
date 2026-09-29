import AppKit
import MetalKit
import SwiftUI
import simd

@MainActor
enum RacingSnapshot {
    /// The actual play camera and dashboard, with the world rendered on Metal first.
    static func render(to url: URL, crash: Bool = false) -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SoundSystem.makeOutput = { RecordingOutput() }
        let model = SceneModel(); model.state = Racing.state()
        let player = PlayController(model: model, console: ScriptConsole()); player.start()
        defer { player.stop() }
        for _ in 0..<(crash ? 280 : 130) { player.step(dt: 1.0 / 60) }
        if crash, let car = model.groups.first(where: { $0.name == "Racer1" }) {
            model.movePivot(of: car.id, to: Pose(position: Vec3(109, 2.45, 0), orientation: simd_quatf(angle: -.pi / 2, axis: Vec3(0, 1, 0))))
            player.physics.sync(model.parts, constraints: model.constraints, attachments: model.attachments)
            for part in model.parts where part.parentID == car.id { player.physics.setVelocity(part.id, Vec3(52, 0, 0)) }
            for _ in 0..<30 { player.step(dt: 1.0 / 60) }
        }
        player.camera.distance = crash ? 26 : 40
        player.camera.pitch = 0.48; player.camera.yaw = crash ? -1.3 : -0.35
        player.camera.fovDegrees = 62
        let width = 1280, height = 800
        player.viewSize = SIMD2(Float(width), Float(height))
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        guard let renderer = Renderer(device: device, view: view, source: player), let world = renderer.snapshot(width: width, height: height) else { return false }
        let root = ZStack {
            Image(decorative: world, scale: 1).resizable().frame(width: CGFloat(width), height: CGFloat(height))
            GuiLayer(store: player.gui)
        }.frame(width: CGFloat(width), height: CGFloat(height)).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; hosting.frame = window.contentLayoutRect
        RunLoop.current.run(until: Date().addingTimeInterval(0.2)); hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return false }
        let errors = player.console.lines.filter { $0.kind == .error }.map(\.text)
        for error in errors { print(error) }
        print("Wrote \(url.path)")
        return errors.isEmpty
    }
}
