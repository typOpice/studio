import AppKit
import MetalKit
import SwiftUI

/// Draws one avatar, alone on a small stage, with the real renderer — for the character
/// editors. It renders a still frame whenever what it shows changes (rather than running
/// a render loop), so it costs nothing while nobody is dressing up, and it shows in
/// window snapshots too.
final class AvatarPreviewRenderer {
    static let shared = AvatarPreviewRenderer()

    private final class Source: ViewportSource {
        let model: SceneModel
        var renderCamera = Camera()
        var avatars: [AvatarPose] = []
        let shaderStatus = ShaderStatusStore()
        let shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}
        init(model: SceneModel) { self.model = model }
    }

    private let source: Source
    private let renderer: Renderer?
    private var assetKey: [String] = []

    private init() {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.starterGui = []
        model.sounds = []
        model.assets = []
        model.lighting.clockTime = 14
        source = Source(model: model)
        if let device = MTLCreateSystemDefaultDevice() {
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
            renderer = Renderer(device: device, view: view, source: source)
        } else {
            renderer = nil
        }
    }

    /// The avatar in `look` and `colors`, turned `turn` radians from facing the viewer,
    /// `width` × `height` pixels. `assets` are the place's files, for imported things.
    func image(look: AvatarLook, colors: BodyColors, assets: [SceneAsset], turn: Float,
               width: Int, height: Int) -> CGImage? {
        guard let renderer else { return nil }
        let key = assets.map { "\($0.id)|\($0.name)|\($0.data.count)" }
        if key != assetKey {
            source.model.assets = assets
            assetKey = key
        }
        var pose = AvatarPose(position: .zero, yaw: .pi + turn, joints: AvatarJoints())
        pose.colors = colors
        pose.look = look
        source.avatars = [pose]
        var camera = Camera()
        camera.target = Vec3(0, 3.2, 0)
        camera.distance = 8.6
        camera.yaw = .pi / 2 + 0.2
        camera.pitch = 0.1
        source.renderCamera = camera
        return renderer.snapshot(width: width, height: height)
    }
}

/// The avatar, drawn as it will look in a game; drag across it to turn it round.
struct AvatarPreview: View {
    let look: AvatarLook
    let colors: BodyColors
    var assets: [SceneAsset] = []
    var width: CGFloat = 240
    var height: CGFloat = 320

    @State private var turn: Float = 0.35
    @State private var dragStart: Float?

    var body: some View {
        let image = AvatarPreviewRenderer.shared.image(look: look, colors: colors, assets: assets, turn: turn,
                                                       width: Int(width * 2), height: Int(height * 2))
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.black.opacity(0.3)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                if dragStart == nil { dragStart = turn }
                turn = (dragStart ?? 0) + Float(drag.translation.width) * 0.012
            }
            .onEnded { _ in dragStart = nil })
        .help("Drag to turn the character round")
    }
}

/// Small pictures of catalog items for choosing them: a face on a head-coloured
/// square, a shirt's front, a pair of trouser legs.
enum AvatarThumbnails {
    private static var cache: [String: NSImage] = [:]

    static func face(_ reference: String) -> NSImage? {
        thumbnail("face:" + reference) {
            guard let picture = AvatarCatalog.image(reference) else { return nil }
            return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                NSColor(red: 0.96, green: 0.8, blue: 0.22, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14).fill()
                NSGraphicsContext.current?.cgContext.draw(picture, in: rect.insetBy(dx: 4, dy: 4))
                return true
            }
        }
    }

    /// A shirt's front (or, for pants, both legs' fronts side by side).
    static func clothing(_ reference: String, pants: Bool) -> NSImage? {
        thumbnail("clothes:" + reference) {
            guard let picture = AvatarCatalog.image(reference) else { return nil }
            let scaleX = CGFloat(picture.width) / CGFloat(ClothingTemplate.width)
            let scaleY = CGFloat(picture.height) / CGFloat(ClothingTemplate.height)
            func crop(_ region: SIMD4<Float>?) -> CGImage? {
                guard let r = region else { return nil }
                return picture.cropping(to: CGRect(x: CGFloat(r.x) * scaleX, y: CGFloat(r.y) * scaleY,
                                                   width: CGFloat(r.z) * scaleX, height: CGFloat(r.w) * scaleY))
            }
            let front = SIMD3(0, 0, -1)
            return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                NSColor(white: 0.5, alpha: 0.25).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                if pants {
                    if let right = crop(ClothingTemplate.right[front]) { context.draw(right, in: CGRect(x: 14, y: 6, width: 18, height: 52)) }
                    if let left = crop(ClothingTemplate.left[front]) { context.draw(left, in: CGRect(x: 32, y: 6, width: 18, height: 52)) }
                } else if let torso = crop(ClothingTemplate.torso[front]) {
                    context.draw(torso, in: rect.insetBy(dx: 8, dy: 8))
                }
                return true
            }
        }
    }

    private static func thumbnail(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let known = cache[key] { return known }
        let made = make()
        if let made { cache[key] = made }
        return made
    }
}
