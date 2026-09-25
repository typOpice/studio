import CoreGraphics
import Foundation
import ImageIO
import simd

/// Roblox's classic clothing template: a 585 × 559 picture with a region for each face
/// of the torso and of each arm (on a shirt) or leg (on pants). Real Roblox shirt and
/// pants templates work as they are.
enum ClothingTemplate {
    static let width: Float = 585
    static let height: Float = 559

    /// The regions of one body part, by the outward normal of the face they cover, in
    /// pixels (x, y, width, height), from the top-left.
    typealias Regions = [SIMD3<Int>: SIMD4<Float>]

    private static func block(front: SIMD2<Float>, right: SIMD2<Float>, back: SIMD2<Float>, left: SIMD2<Float>,
                              up: SIMD2<Float>, down: SIMD2<Float>, width: Float, depth: Float, height: Float) -> Regions {
        [
            SIMD3(0, 0, -1): SIMD4(front.x, front.y, width, height),
            SIMD3(0, 0, 1): SIMD4(back.x, back.y, width, height),
            SIMD3(1, 0, 0): SIMD4(right.x, right.y, depth, height),
            SIMD3(-1, 0, 0): SIMD4(left.x, left.y, depth, height),
            SIMD3(0, 1, 0): SIMD4(up.x, up.y, width, depth),
            SIMD3(0, -1, 0): SIMD4(down.x, down.y, width, depth),
        ]
    }

    static let torso = block(front: SIMD2(231, 74), right: SIMD2(165, 74), back: SIMD2(427, 74), left: SIMD2(361, 74),
                             up: SIMD2(231, 8), down: SIMD2(231, 204), width: 128, depth: 64, height: 128)
    /// The character's right arm (or leg), on the template's left.
    static let right = block(front: SIMD2(217, 355), right: SIMD2(151, 355), back: SIMD2(85, 355), left: SIMD2(19, 355),
                             up: SIMD2(217, 289), down: SIMD2(217, 485), width: 64, depth: 64, height: 128)
    static let left = block(front: SIMD2(308, 355), right: SIMD2(506, 355), back: SIMD2(440, 355), left: SIMD2(374, 355),
                            up: SIMD2(308, 289), down: SIMD2(308, 485), width: 64, depth: 64, height: 128)

    static func regions(for part: String) -> Regions? {
        switch part {
        case "Torso": return torso
        case "Right Arm", "Right Leg": return right
        case "Left Arm", "Left Leg": return left
        default: return nil
        }
    }

    /// The texture coordinate (0…1, from the top-left) of a point `p` on the face of a
    /// box of half-size `half` whose outward normal is `normal` — as the face is seen
    /// from outside, with the character facing −Z (so its right is +X).
    static func uv(_ p: Vec3, normal: SIMD3<Int>, half: Vec3, region: SIMD4<Float>) -> SIMD2<Float> {
        let across: Float, down: Float
        switch normal {
        case SIMD3(0, 0, -1): across = (half.x - p.x) / (2 * half.x); down = (half.y - p.y) / (2 * half.y)
        case SIMD3(0, 0, 1): across = (p.x + half.x) / (2 * half.x); down = (half.y - p.y) / (2 * half.y)
        case SIMD3(1, 0, 0): across = (half.z - p.z) / (2 * half.z); down = (half.y - p.y) / (2 * half.y)
        case SIMD3(-1, 0, 0): across = (p.z + half.z) / (2 * half.z); down = (half.y - p.y) / (2 * half.y)
        case SIMD3(0, 1, 0): across = (half.x - p.x) / (2 * half.x); down = (half.z - p.z) / (2 * half.z)
        default: across = (half.x - p.x) / (2 * half.x); down = (p.z + half.z) / (2 * half.z)
        }
        let a = min(max(across, 0), 1), d = min(max(down, 0), 1)
        return SIMD2((region.x + a * region.z) / width, (region.y + d * region.w) / height)
    }
}

/// The things every copy of the app has to dress a character in, with no files: a
/// dozen accessories made from shapes, faces, shirts and pants drawn in code. They are
/// named `builtin://Id`; a player's own look may only use these (a place's imported
/// files stay in that place).
enum AvatarCatalog {
    static let prefix = "builtin://"
    /// The classic smile, drawn as shapes: a look's face is "" for it.
    static let classicFace = "Smile"
    /// No face at all.
    static let noFaceReference = prefix + "None"

    struct Accessory {
        let id: String
        let name: String
        let type: AccessoryType
        let color: Vec3
        let icon: String
    }

    struct Picture {
        let id: String
        let name: String
    }

    static let accessories: [Accessory] = [
        Accessory(id: "TopHat", name: "Top Hat", type: .hat, color: Vec3(0.1, 0.1, 0.12), icon: "hat.widebrim.fill"),
        Accessory(id: "Cap", name: "Cap", type: .hat, color: Vec3(0.8, 0.15, 0.12), icon: "hat.cap.fill"),
        Accessory(id: "Crown", name: "Crown", type: .hat, color: Vec3(0.96, 0.76, 0.2), icon: "crown.fill"),
        Accessory(id: "PartyHat", name: "Party Hat", type: .hat, color: Vec3(0.95, 0.4, 0.75), icon: "party.popper.fill"),
        Accessory(id: "Beanie", name: "Beanie", type: .hat, color: Vec3(0.2, 0.4, 0.75), icon: "snowflake"),
        Accessory(id: "ShortHair", name: "Short Hair", type: .hair, color: Vec3(0.35, 0.22, 0.12), icon: "comb.fill"),
        Accessory(id: "Glasses", name: "Glasses", type: .face, color: Vec3(0.08, 0.08, 0.1), icon: "eyeglasses"),
        Accessory(id: "Scarf", name: "Scarf", type: .neck, color: Vec3(0.75, 0.12, 0.15), icon: "wind"),
        Accessory(id: "Medal", name: "Medal", type: .front, color: Vec3(0.95, 0.75, 0.25), icon: "medal.fill"),
        Accessory(id: "Backpack", name: "Backpack", type: .back, color: Vec3(0.35, 0.42, 0.25), icon: "backpack.fill"),
        Accessory(id: "Cape", name: "Cape", type: .back, color: Vec3(0.65, 0.1, 0.15), icon: "theatermasks.fill"),
        Accessory(id: "Belt", name: "Belt", type: .waist, color: Vec3(0.3, 0.18, 0.1), icon: "line.3.horizontal"),
    ]

    static let faces: [Picture] = [
        Picture(id: classicFace, name: "Smile"), Picture(id: "Grin", name: "Grin"), Picture(id: "Wink", name: "Wink"),
        Picture(id: "Surprised", name: "Surprised"), Picture(id: "Cool", name: "Cool"), Picture(id: "Sleepy", name: "Sleepy"),
        Picture(id: "Happy", name: "Happy"), Picture(id: "Angry", name: "Angry"), Picture(id: "None", name: "No Face"),
    ]

    static let shirts: [Picture] = [
        Picture(id: "Tee", name: "White Tee"), Picture(id: "StripedTee", name: "Striped Tee"),
        Picture(id: "Hoodie", name: "Hoodie"), Picture(id: "Plaid", name: "Plaid Shirt"),
        Picture(id: "Suit", name: "Suit Jacket"), Picture(id: "Sweater", name: "Sweater"),
    ]

    static let pants: [Picture] = [
        Picture(id: "Jeans", name: "Jeans"), Picture(id: "BlackPants", name: "Black Pants"),
        Picture(id: "Shorts", name: "Shorts"), Picture(id: "SuitPants", name: "Suit Pants"),
        Picture(id: "Joggers", name: "Joggers"),
    ]

    static func accessory(_ id: String) -> Accessory? {
        let bare = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        return accessories.first { $0.id == bare }
    }

    /// The id of a built-in reference, or nil for anything else.
    static func builtIn(_ reference: String) -> String? {
        reference.hasPrefix(prefix) ? String(reference.dropFirst(prefix.count)) : nil
    }

    /// The name a reference is shown by: a built-in item's name, or the imported file's.
    static func displayName(_ reference: String, kind: [Picture]) -> String {
        if let id = builtIn(reference) { return kind.first { $0.id == id }?.name ?? id }
        return reference.hasPrefix("studio://") ? String(reference.dropFirst("studio://".count)) : reference
    }

    // MARK: - Accessory meshes

    /// A built-in accessory's mesh, at its real size around its attachment point (the
    /// head's top for a hat, the face's middle for glasses, and so on).
    static func mesh(_ id: String) -> ([Vertex], [UInt16])? {
        typealias Piece = ([Vertex], [UInt16])
        func at(_ piece: Piece, _ position: Vec3, scale: Vec3 = Vec3(repeating: 1),
                turn: simd_quatf = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))) -> Piece {
            MeshFactory.placed(piece, Mat.translation(position) * Mat.rotation(turn) * Mat.scale(scale))
        }
        func disc(radius: Float, top: Float, bottom: Float) -> Piece {
            MeshFactory.lathe([(0, bottom, SIMD2(0, -1)), (radius, bottom, SIMD2(0, -1)), (radius, bottom, SIMD2(1, 0)),
                               (radius, top, SIMD2(1, 0)), (radius, top, SIMD2(0, 1)), (0, top, SIMD2(0, 1))])
        }
        // A dome: the top half of a squashed sphere.
        func dome(radius: Float, height: Float, bottom: Float, steps: Int = 8) -> Piece {
            var profile: [(r: Float, y: Float, normal: SIMD2<Float>)] = [(0, bottom, SIMD2(0, -1)),
                                                                          (radius, bottom, SIMD2(0, -1))]
            for k in 0...steps {
                let phi = Float(k) / Float(steps) * .pi / 2
                let normal = normalize(SIMD2(cos(phi) / radius, sin(phi) / height))
                profile.append((radius * cos(phi), bottom + height * sin(phi), normal))
            }
            return MeshFactory.lathe(profile)
        }
        switch id {
        case "TopHat":
            return MeshFactory.merged([disc(radius: 1.0, top: -0.24, bottom: -0.3),
                                       disc(radius: 0.66, top: 0.95, bottom: -0.32)])
        case "Cap":
            return MeshFactory.merged([dome(radius: 0.68, height: 0.5, bottom: -0.32),
                                       at(MeshFactory.roundedBox(size: Vec3(0.95, 0.07, 0.6), radius: 0.03),
                                          Vec3(0, -0.28, -0.8), turn: simd_quatf(angle: -0.12, axis: Vec3(1, 0, 0)))])
        case "Crown":
            var pieces = [disc(radius: 0.7, top: 0.1, bottom: -0.2)]
            for k in 0..<6 {
                let angle = Float(k) / 6 * 2 * .pi
                pieces.append(at(MeshFactory.cone(segments: 10), Vec3(sin(angle) * 0.6, 0.08, -cos(angle) * 0.6),
                                 scale: Vec3(0.26, 0.4, 0.26)))
                pieces.append(at(MeshFactory.sphere(slices: 10, stacks: 6), Vec3(sin(angle) * 0.6, 0.52, -cos(angle) * 0.6),
                                 scale: Vec3(repeating: 0.1)))
            }
            return MeshFactory.merged(pieces)
        case "PartyHat":
            return MeshFactory.merged([at(MeshFactory.cone(segments: 28), Vec3(0, -0.12, 0), scale: Vec3(0.95, 1.15, 0.95)),
                                       at(MeshFactory.sphere(slices: 12, stacks: 8), Vec3(0, 1.05, 0),
                                          scale: Vec3(repeating: 0.2))])
        case "Beanie":
            return MeshFactory.merged([dome(radius: 0.69, height: 0.62, bottom: -0.36),
                                       disc(radius: 0.72, top: -0.2, bottom: -0.38),
                                       at(MeshFactory.sphere(slices: 12, stacks: 8), Vec3(0, 0.3, 0),
                                          scale: Vec3(repeating: 0.3))])
        case "ShortHair":
            return MeshFactory.merged([dome(radius: 0.67, height: 0.34, bottom: -0.3),
                                       at(MeshFactory.roundedBox(size: Vec3(1.0, 0.75, 0.22), radius: 0.09),
                                          Vec3(0, -0.55, 0.52))])
        case "Glasses":
            var pieces: [Piece] = []
            for x in [Float(-0.22), 0.22] {
                pieces.append(at(MeshFactory.torus(majorSegments: 28, minorSegments: 8, minorRadius: 0.2),
                                 Vec3(x, 0.05, -0.05), scale: Vec3(repeating: 0.17),
                                 turn: simd_quatf(angle: .pi / 2, axis: Vec3(1, 0, 0))))
                pieces.append(at(MeshFactory.roundedBox(size: Vec3(0.04, 0.05, 0.62), radius: 0.015),
                                 Vec3(x < 0 ? -0.62 : 0.62, 0.08, 0.24)))
            }
            pieces.append(at(MeshFactory.roundedBox(size: Vec3(0.13, 0.04, 0.04), radius: 0.015), Vec3(0, 0.1, -0.05)))
            pieces.append(at(MeshFactory.roundedBox(size: Vec3(0.26, 0.04, 0.04), radius: 0.015),
                             Vec3(-0.5, 0.1, -0.05)))
            pieces.append(at(MeshFactory.roundedBox(size: Vec3(0.26, 0.04, 0.04), radius: 0.015), Vec3(0.5, 0.1, -0.05)))
            return MeshFactory.merged(pieces)
        case "Scarf":
            return MeshFactory.merged([at(MeshFactory.torus(majorSegments: 36, minorSegments: 10, minorRadius: 0.3),
                                          Vec3(0, 0.02, 0), scale: Vec3(0.78, 0.62, 0.52)),
                                       at(MeshFactory.roundedBox(size: Vec3(0.34, 0.95, 0.1), radius: 0.04),
                                          Vec3(0.42, -0.5, -0.58), turn: simd_quatf(angle: 0.12, axis: Vec3(0, 0, 1)))])
        case "Medal":
            return MeshFactory.merged([at(MeshFactory.cylinder(segments: 24), Vec3(-0.5, 0.35, -0.04),
                                          scale: Vec3(0.34, 0.06, 0.34),
                                          turn: simd_quatf(angle: .pi / 2, axis: Vec3(1, 0, 0))),
                                       at(MeshFactory.roundedBox(size: Vec3(0.16, 0.3, 0.04), radius: 0.015),
                                          Vec3(-0.5, 0.62, -0.03))])
        case "Backpack":
            return MeshFactory.merged([at(MeshFactory.roundedBox(size: Vec3(1.45, 1.6, 0.6), radius: 0.18),
                                          Vec3(0, 0.05, 0.3)),
                                       at(MeshFactory.roundedBox(size: Vec3(1.0, 0.65, 0.22), radius: 0.09),
                                          Vec3(0, -0.3, 0.66))])
        case "Cape":
            return at(MeshFactory.roundedBox(size: Vec3(1.9, 3.1, 0.06), radius: 0.025), Vec3(0, -0.6, 0.12),
                      turn: simd_quatf(angle: 0.08, axis: Vec3(1, 0, 0)))
        case "Belt":
            return MeshFactory.merged([at(MeshFactory.roundedBox(size: Vec3(2.08, 0.26, 1.08), radius: 0.05),
                                          Vec3(0, 0.15, 0)),
                                       at(MeshFactory.roundedBox(size: Vec3(0.34, 0.3, 0.06), radius: 0.03),
                                          Vec3(0, 0.15, -0.55))])
        default:
            return nil
        }
    }

    // MARK: - Pictures

    /// A built-in face, shirt or pants as a picture: faces 256 × 256 on a clear ground,
    /// clothing on the template. Nil for anything that isn't built in (or the classic
    /// smile and no face, which aren't pictures). Made once each.
    static func image(_ reference: String) -> CGImage? {
        guard let id = builtIn(reference) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = images[id] { return known }
        let made: CGImage?
        if faces.contains(where: { $0.id == id }) {
            made = id == classicFace || id == "None" ? nil : draw(width: 256, height: 256) { drawFace(id, $0) }
        } else if shirts.contains(where: { $0.id == id }) || pants.contains(where: { $0.id == id }) {
            made = draw(width: Int(ClothingTemplate.width), height: Int(ClothingTemplate.height)) { drawClothing(id, $0) }
        } else {
            made = nil
        }
        images[id] = made
        return made
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var images: [String: CGImage?] = [:]

    /// A clear picture drawn with the origin at the top-left, y down.
    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        body(context)
        return context.makeImage()
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func drawFace(_ id: String, _ c: CGContext) {
        let ink = rgb(0.08, 0.08, 0.1)
        c.setFillColor(ink)
        c.setStrokeColor(ink)
        c.setLineCap(.round)
        c.setLineWidth(12)
        func eye(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 26, h: CGFloat = 40) {
            c.fillEllipse(in: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
        }
        func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat = 12) {
            c.setLineWidth(width)
            c.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: from, endAngle: to, clockwise: false)
            c.strokePath()
        }
        func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat = 12) {
            c.setLineWidth(width)
            c.move(to: a)
            c.addLine(to: b)
            c.strokePath()
        }
        switch id {
        case "Grin":
            eye(88, 96)
            eye(168, 96)
            c.move(to: CGPoint(x: 68, y: 150))
            c.addQuadCurve(to: CGPoint(x: 188, y: 150), control: CGPoint(x: 128, y: 240))
            c.closePath()
            c.fillPath()
            c.setFillColor(rgb(1, 1, 1))
            c.fill(CGRect(x: 78, y: 150, width: 100, height: 16))
        case "Wink":
            eye(88, 96)
            line(CGPoint(x: 150, y: 100), CGPoint(x: 186, y: 94))
            arc(128, 128, 56, from: .pi * 0.2, to: .pi * 0.8)
        case "Surprised":
            eye(88, 92, w: 30, h: 44)
            eye(168, 92, w: 30, h: 44)
            c.fillEllipse(in: CGRect(x: 104, y: 150, width: 48, height: 60))
        case "Cool":
            c.addPath(CGPath(roundedRect: CGRect(x: 40, y: 70, width: 80, height: 50), cornerWidth: 18, cornerHeight: 18,
                             transform: nil))
            c.addPath(CGPath(roundedRect: CGRect(x: 136, y: 70, width: 80, height: 50), cornerWidth: 18,
                             cornerHeight: 18, transform: nil))
            c.fillPath()
            c.fill(CGRect(x: 110, y: 80, width: 36, height: 10))
            arc(140, 118, 60, from: .pi * 0.25, to: .pi * 0.62)
        case "Sleepy":
            line(CGPoint(x: 66, y: 100), CGPoint(x: 110, y: 104))
            line(CGPoint(x: 146, y: 104), CGPoint(x: 190, y: 100))
            c.fillEllipse(in: CGRect(x: 114, y: 170, width: 28, height: 22))
        case "Happy":
            arc(88, 106, 20, from: .pi, to: 2 * .pi)
            arc(168, 106, 20, from: .pi, to: 2 * .pi)
            c.setFillColor(rgb(0.95, 0.45, 0.5, 0.55))
            c.fillEllipse(in: CGRect(x: 40, y: 130, width: 44, height: 24))
            c.fillEllipse(in: CGRect(x: 172, y: 130, width: 44, height: 24))
            c.setFillColor(ink)
            arc(128, 138, 42, from: .pi * 0.15, to: .pi * 0.85)
        case "Angry":
            eye(90, 104, w: 24, h: 32)
            eye(166, 104, w: 24, h: 32)
            line(CGPoint(x: 60, y: 66), CGPoint(x: 112, y: 84))
            line(CGPoint(x: 196, y: 66), CGPoint(x: 144, y: 84))
            arc(128, 212, 40, from: .pi * 1.2, to: .pi * 1.8)
        default:
            break
        }
    }

    private static func drawClothing(_ id: String, _ c: CGContext) {
        let torso = [ClothingTemplate.torso]
        let limbs = [ClothingTemplate.right, ClothingTemplate.left]
        func rects(_ blocks: [ClothingTemplate.Regions]) -> [CGRect] {
            blocks.flatMap { $0.values.map { CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.z), height: CGFloat($0.w)) } }
        }
        /// The side faces of limbs (not their tops and bottoms), from the top down to `fraction`.
        func sides(_ blocks: [ClothingTemplate.Regions], down fraction: CGFloat) -> [CGRect] {
            blocks.flatMap { block in
                block.filter { $0.key.y == 0 }.values.map {
                    CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.z), height: CGFloat($0.w) * fraction)
                }
            }
        }
        func fill(_ rects: [CGRect], _ color: CGColor) {
            c.setFillColor(color)
            for r in rects { c.fill(r) }
        }
        func tops(_ blocks: [ClothingTemplate.Regions]) -> [CGRect] {
            blocks.compactMap { $0[SIMD3(0, 1, 0)] }.map { CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.z), height: CGFloat($0.w)) }
        }
        let front = CGRect(x: 231, y: 74, width: 128, height: 128)
        let back = CGRect(x: 427, y: 74, width: 128, height: 128)
        // The torso's sides and front and back, not its top and bottom.
        let torsoBand = sides(torso, down: 1)

        switch id {
        case "Tee", "StripedTee":
            let cloth = id == "Tee" ? rgb(0.96, 0.96, 0.95) : rgb(0.12, 0.18, 0.4)
            fill(rects(torso), cloth)
            fill(sides(limbs, down: 0.4) + tops(limbs), cloth)
            if id == "StripedTee" {
                c.setFillColor(rgb(0.95, 0.95, 0.95))
                for band in torsoBand + sides(limbs, down: 0.4) {
                    var y = band.minY + 8
                    while y < band.maxY { c.fill(CGRect(x: band.minX, y: y, width: band.width, height: 9)); y += 22 }
                }
            }
            // A round neck.
            c.setFillColor(rgb(0.7, 0.7, 0.72))
            c.fill(CGRect(x: front.midX - 22, y: front.minY, width: 44, height: 6))
        case "Hoodie":
            let cloth = rgb(0.5, 0.52, 0.56)
            fill(rects(torso) + rects(limbs.map { $0.filter { $0.key.y >= 0 } }), cloth)
            fill(sides(limbs, down: 1).map { CGRect(x: $0.minX, y: $0.maxY - 12, width: $0.width, height: 12) },
                 rgb(0.42, 0.44, 0.48))
            // The pocket, the drawstrings and the zip.
            c.setFillColor(rgb(0.43, 0.45, 0.49))
            c.fill(CGRect(x: front.minX + 22, y: front.maxY - 48, width: front.width - 44, height: 40))
            c.setFillColor(rgb(0.93, 0.93, 0.93))
            c.fill(CGRect(x: front.midX - 18, y: front.minY + 4, width: 4, height: 34))
            c.fill(CGRect(x: front.midX + 14, y: front.minY + 4, width: 4, height: 34))
            c.setFillColor(rgb(0.43, 0.45, 0.49))
            c.fill(CGRect(x: back.minX + 24, y: back.minY, width: back.width - 48, height: 34))
        case "Plaid":
            fill(rects(torso) + rects(limbs.map { $0.filter { $0.key.y >= 0 } }), rgb(0.72, 0.12, 0.12))
            c.setFillColor(rgb(0.1, 0.05, 0.05, 0.45))
            for band in rects(torso) + rects(limbs) {
                var x = band.minX + 6
                while x < band.maxX { c.fill(CGRect(x: x, y: band.minY, width: 8, height: band.height)); x += 24 }
                var y = band.minY + 6
                while y < band.maxY { c.fill(CGRect(x: band.minX, y: y, width: band.width, height: 8)); y += 24 }
            }
            c.setFillColor(rgb(0.95, 0.9, 0.8))
            for k in 0..<4 { c.fillEllipse(in: CGRect(x: front.midX - 3, y: front.minY + 22 + CGFloat(k) * 28, width: 7, height: 7)) }
        case "Suit":
            let jacket = rgb(0.1, 0.1, 0.13)
            fill(rects(torso) + rects(limbs.map { $0.filter { $0.key.y >= 0 } }), jacket)
            // The white shirt in the V of the lapels, and the tie.
            c.setFillColor(rgb(0.96, 0.96, 0.96))
            c.move(to: CGPoint(x: front.midX - 30, y: front.minY))
            c.addLine(to: CGPoint(x: front.midX + 30, y: front.minY))
            c.addLine(to: CGPoint(x: front.midX, y: front.minY + 70))
            c.closePath()
            c.fillPath()
            c.setFillColor(rgb(0.7, 0.1, 0.15))
            c.move(to: CGPoint(x: front.midX - 7, y: front.minY + 4))
            c.addLine(to: CGPoint(x: front.midX + 7, y: front.minY + 4))
            c.addLine(to: CGPoint(x: front.midX + 5, y: front.minY + 50))
            c.addLine(to: CGPoint(x: front.midX, y: front.minY + 60))
            c.addLine(to: CGPoint(x: front.midX - 5, y: front.minY + 50))
            c.closePath()
            c.fillPath()
            c.setFillColor(rgb(0.85, 0.85, 0.85))
            for k in 0..<2 { c.fillEllipse(in: CGRect(x: front.midX - 3, y: front.minY + 80 + CGFloat(k) * 22, width: 7, height: 7)) }
        case "Sweater":
            fill(rects(torso) + rects(limbs.map { $0.filter { $0.key.y >= 0 } }), rgb(0.2, 0.5, 0.3))
            c.setFillColor(rgb(0.95, 0.9, 0.75))
            for band in torsoBand {
                var x = band.minX + 4
                while x < band.maxX - 8 {
                    c.move(to: CGPoint(x: x, y: band.minY + 58))
                    c.addLine(to: CGPoint(x: x + 8, y: band.minY + 50))
                    c.addLine(to: CGPoint(x: x + 16, y: band.minY + 58))
                    c.addLine(to: CGPoint(x: x + 8, y: band.minY + 66))
                    c.closePath()
                    c.fillPath()
                    x += 20
                }
            }
            fill(sides(limbs, down: 1).map { CGRect(x: $0.minX, y: $0.maxY - 12, width: $0.width, height: 12) },
                 rgb(0.15, 0.4, 0.24))
        case "Jeans", "BlackPants", "SuitPants", "Joggers", "Shorts":
            let cloth: CGColor
            switch id {
            case "Jeans": cloth = rgb(0.2, 0.32, 0.55)
            case "BlackPants": cloth = rgb(0.1, 0.1, 0.11)
            case "SuitPants": cloth = rgb(0.12, 0.12, 0.15)
            case "Joggers": cloth = rgb(0.45, 0.46, 0.5)
            default: cloth = rgb(0.76, 0.66, 0.45)
            }
            // The legs (down to the knee for shorts), and the torso below the belt.
            let down: CGFloat = id == "Shorts" ? 0.45 : 1
            fill(sides(limbs, down: down) + tops(limbs), cloth)
            if id != "Shorts" { fill(limbs.compactMap { $0[SIMD3(0, -1, 0)] }.map {
                CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.z), height: CGFloat($0.w)) }, cloth) }
            fill(torsoBand.map { CGRect(x: $0.minX, y: $0.maxY - 26, width: $0.width, height: 26) }
                 + rects([ClothingTemplate.torso.filter { $0.key == SIMD3(0, -1, 0) }]), cloth)
            // A belt line, and a seam down each leg.
            fill(torsoBand.map { CGRect(x: $0.minX, y: $0.maxY - 26, width: $0.width, height: 5) },
                 rgb(0.05, 0.04, 0.03, 0.6))
            if id == "Jeans" {
                c.setFillColor(rgb(0.85, 0.65, 0.3, 0.8))
                for leg in sides(limbs, down: 1) { c.fill(CGRect(x: leg.midX - 1, y: leg.minY, width: 2, height: leg.height)) }
            }
            if id == "Joggers" {
                fill(sides(limbs, down: 1).map { CGRect(x: $0.minX, y: $0.maxY - 12, width: $0.width, height: 12) },
                     rgb(0.35, 0.36, 0.4))
            }
        default:
            break
        }
    }

    /// An imported picture's bytes as a CGImage.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
