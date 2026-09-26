import Foundation
import MetalKit
import ImageIO
import UniformTypeIdentifiers

/// Small pictures of places, for the home page: a template's, or a saved place's read
/// from its file. One off-screen renderer draws them all (making a renderer compiles
/// its shaders, which is the slow part). A saved place's picture is kept in the caches
/// folder under a name made from its path and modification date, so each version of a
/// file is drawn once; change the file and it is drawn again.
final class PlaceThumbnail {
    static let shared = PlaceThumbnail()
    static let width = 480
    static let height = 270

    /// Where pictures of saved places are kept. The tests point it somewhere of their own.
    var directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Studio/Thumbnails", isDirectory: true)
    }()

    /// How many pictures were actually drawn, rather than read back from the folder.
    private(set) var drawn = 0

    private final class Source: ViewportSource {
        let model: SceneModel = {
            let model = SceneModel()
            // A picture of the place, not of the editor.
            model.showGrid = false
            return model
        }()
        var renderCamera = Camera()
        var avatars: [AvatarPose] = []
        let shaderStatus = ShaderStatusStore()
        let shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}
    }

    private let source = Source()
    private lazy var renderer: Renderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), device: device)
        return Renderer(device: device, view: view, source: source)
    }()

    /// A picture of a place, from `camera` or from a corner that fits its parts in, with a
    /// character standing at `character` if given. Nil for a place with nothing to see.
    func image(of state: SceneState, camera: Camera? = nil, character: Vec3? = nil) -> CGImage? {
        guard let renderer, let view = camera ?? Self.framing(state) else { return nil }
        var shown = state
        // Clear air: fog would grey out a picture this small.
        shown.lighting.fogStart = 100_000
        shown.lighting.fogEnd = 100_000
        shown.lighting.technology = .conventional
        source.model.state = shown
        source.renderCamera = view
        source.avatars = character.map { feet in
            var pose = AvatarPose(position: feet, yaw: 0, joints: AvatarSnapshot.poses()[0].pose.joints)
            pose.colors = shown.starterPlayer.bodyColors
            return [pose]
        } ?? []
        drawn += 1
        return renderer.snapshot(width: Self.width, height: Self.height)
    }

    /// A saved place's picture: from the folder if this version of the file was drawn
    /// before, otherwise drawn now and kept.
    func image(ofFile url: URL) -> CGImage? {
        guard let key = Self.cacheKey(for: url) else { return nil }
        let kept = directory.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: kept), let image = Self.decodePNG(data) { return image }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SceneState.self, from: data),
              let image = image(of: state) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png = Self.encodePNG(image) { try? png.write(to: kept, options: .atomic) }
        return image
    }

    /// The file's path and modification date, made into a name.
    static func cacheKey(for url: URL) -> String? {
        // A URL keeps what it read about its file; this must be today's date.
        var file = url
        file.removeAllCachedResourceValues()
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        // FNV-1a: stable from run to run, unlike Swift's hashValue.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(url.standardizedFileURL.path)|\(modified.timeIntervalSince1970)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Looking down from a corner at everything in the Workspace, except ground so big
    /// (a baseplate) that fitting it in would make the rest too small to see.
    static func framing(_ state: SceneState) -> Camera? {
        let placed = state.parts.filter { $0.storage == nil }
        guard !placed.isEmpty else { return nil }
        let smaller = placed.filter { max($0.size.x, $0.size.z) < 300 }
        let framed = smaller.isEmpty ? placed : smaller
        var low = Vec3(repeating: .greatestFiniteMagnitude)
        var high = Vec3(repeating: -.greatestFiniteMagnitude)
        for part in framed {
            // Big enough for any turn the part has.
            let reach = Vec3(repeating: length(part.size) / 2)
            low = simd_min(low, part.position - reach)
            high = simd_max(high, part.position + reach)
        }
        var camera = Camera()
        camera.fovDegrees = 50
        camera.target = (low + high) / 2
        let radius = max(length(high - low) / 2, 6)
        camera.distance = radius / sin(camera.fovDegrees * .pi / 360) * 0.9
        camera.yaw = -0.7
        camera.pitch = 0.5
        return camera
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
