import AppKit

/// One cached cursor per viewport. Imported images are bounded to normal cursor size;
/// comparing their bytes also invalidates a replacement with the same asset id.
final class MouseCursor {
    private var reference = ""
    private var imageData: Data?
    private var cached = NSCursor.arrow

    func resolve(_ name: String, assets: [SceneAsset]) -> NSCursor {
        switch name.lowercased() {
        case "", "builtin://arrow": return .arrow
        case "builtin://hand": return .pointingHand
        case "builtin://crosshair": return .crosshair
        case "builtin://text": return .iBeam
        case "builtin://resize", "builtin://resizehorizontal": return .resizeLeftRight
        case "builtin://resizevertical": return .resizeUpDown
        default: break
        }
        guard let asset = assets.first(where: { $0.kind == .image && $0.reference == name }) else { return .arrow }
        if reference == name && imageData == asset.data { return cached }
        reference = name
        imageData = asset.data
        guard let original = NSImage(data: asset.data), original.size.width > 0, original.size.height > 0 else {
            cached = .arrow
            return cached
        }
        let scale = min(1, 32 / max(original.size.width, original.size.height))
        let size = NSSize(width: original.size.width * scale, height: original.size.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        cached = NSCursor(image: image, hotSpot: .zero)
        return cached
    }
}
