import Metal
import simd

struct Vertex {
    var position: Vec3
    var normal: Vec3
}

/// A GPU-resident indexed triangle mesh: 16-bit indices for the built-in shapes,
/// 32-bit for imported meshes, which may also carry texture coordinates.
final class Mesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let indexType: MTLIndexType
    let primitiveType: MTLPrimitiveType
    /// A float2 per vertex, for a textured MeshPart; nil for everything else.
    let uvBuffer: MTLBuffer?

    init?(device: MTLDevice, vertices: [Vertex], indices: [UInt16], primitiveType: MTLPrimitiveType = .triangle) {
        guard !vertices.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.stride * indices.count, options: .storageModeShared)
        else { return nil }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = indices.count
        indexType = .uint16
        self.primitiveType = primitiveType
        uvBuffer = nil
    }

    init?(device: MTLDevice, vertices: [Vertex], indices: [UInt32], uvs: [SIMD2<Float>]) {
        guard !vertices.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared)
        else { return nil }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = indices.count
        indexType = .uint32
        primitiveType = .triangle
        uvBuffer = uvs.count == vertices.count
            ? device.makeBuffer(bytes: uvs, length: MemoryLayout<SIMD2<Float>>.stride * uvs.count, options: .storageModeShared)
            : nil
    }

    func draw(_ encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        if let uvBuffer { encoder.setVertexBuffer(uvBuffer, offset: 0, index: 3) }
        encoder.drawIndexedPrimitives(type: primitiveType,
                                      indexCount: indexCount,
                                      indexType: indexType,
                                      indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)
    }
}

/// Procedural geometry. Every shape fits inside a unit cube so a part's `size` scales it directly.
enum MeshFactory {

    static func box() -> ([Vertex], [UInt16]) {
        let faces: [(n: Vec3, a: Vec3, b: Vec3)] = [
            (Vec3(0, 0, 1),  Vec3(1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(1, 0, 0),  Vec3(0, 0, -1), Vec3(0, 1, 0)),
            (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
            (Vec3(0, 1, 0),  Vec3(1, 0, 0), Vec3(0, 0, -1)),
            (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1))
        ]
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        for face in faces {
            let base = UInt16(vertices.count)
            let center = face.n * 0.5
            let ha = face.a * 0.5, hb = face.b * 0.5
            vertices.append(Vertex(position: center - ha - hb, normal: face.n))
            vertices.append(Vertex(position: center + ha - hb, normal: face.n))
            vertices.append(Vertex(position: center + ha + hb, normal: face.n))
            vertices.append(Vertex(position: center - ha + hb, normal: face.n))
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (vertices, indices)
    }

    static func sphere(slices: Int = 32, stacks: Int = 20) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        for stack in 0...stacks {
            let v = Float(stack) / Float(stacks)
            let phi = v * Float.pi
            for slice in 0...slices {
                let u = Float(slice) / Float(slices)
                let theta = u * 2 * Float.pi
                let n = Vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                vertices.append(Vertex(position: n * 0.5, normal: n))
            }
        }
        let stride = slices + 1
        for stack in 0..<stacks {
            for slice in 0..<slices {
                let a = UInt16(stack * stride + slice)
                let b = UInt16((stack + 1) * stride + slice)
                // The pole rows collapse to a point, so one triangle of each quad is empty there.
                if stack > 0 { indices += [a, a + 1, b + 1] }
                if stack < stacks - 1 { indices += [a, b + 1, b] }
            }
        }
        return (vertices, indices)
    }

    static func cylinder(segments: Int = 40) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        // Side wall
        for i in 0...segments {
            let t = Float(i) / Float(segments) * 2 * Float.pi
            let n = Vec3(cos(t), 0, sin(t))
            vertices.append(Vertex(position: Vec3(n.x * 0.5, -0.5, n.z * 0.5), normal: n))
            vertices.append(Vertex(position: Vec3(n.x * 0.5, 0.5, n.z * 0.5), normal: n))
        }
        for i in 0..<segments {
            let a = UInt16(i * 2)
            indices += [a, a + 1, a + 3, a, a + 3, a + 2]
        }
        // Caps
        for (y, normal) in [(Float(0.5), Vec3(0, 1, 0)), (Float(-0.5), Vec3(0, -1, 0))] {
            let center = UInt16(vertices.count)
            vertices.append(Vertex(position: Vec3(0, y, 0), normal: normal))
            for i in 0...segments {
                let t = Float(i) / Float(segments) * 2 * Float.pi
                vertices.append(Vertex(position: Vec3(cos(t) * 0.5, y, sin(t) * 0.5), normal: normal))
            }
            for i in 0..<segments {
                let a = center + 1 + UInt16(i)
                if normal.y > 0 {
                    indices += [center, a + 1, a]
                } else {
                    indices += [center, a, a + 1]
                }
            }
        }
        return (vertices, indices)
    }

    /// A ramp: full height at -Z, sloping down to zero height at +Z.
    static func wedge() -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []

        // Each helper takes corners counter-clockwise as seen from outside the solid.
        func quad(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3) {
            let n = normalize(cross(p1 - p0, p2 - p0))
            let base = UInt16(vertices.count)
            for p in [p0, p1, p2, p3] { vertices.append(Vertex(position: p, normal: n)) }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        func tri(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3) {
            let n = normalize(cross(p1 - p0, p2 - p0))
            let base = UInt16(vertices.count)
            for p in [p0, p1, p2] { vertices.append(Vertex(position: p, normal: n)) }
            indices += [base, base + 1, base + 2]
        }

        let a = Vec3(-0.5, -0.5, -0.5), b = Vec3(0.5, -0.5, -0.5)
        let c = Vec3(0.5, -0.5, 0.5), d = Vec3(-0.5, -0.5, 0.5)
        let e = Vec3(-0.5, 0.5, -0.5), f = Vec3(0.5, 0.5, -0.5)

        quad(a, b, c, d)   // bottom
        quad(a, e, f, b)   // tall back wall at -Z
        quad(e, d, c, f)   // sloped face
        tri(b, f, c)       // right side
        tri(a, d, e)       // left side
        return (vertices, indices)
    }

    /// Cone used for the tip of translate arrows. Base at y = 0, tip at y = 1.
    static func cone(segments: Int = 24) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        let radius: Float = 0.5
        for i in 0..<segments {
            let t0 = Float(i) / Float(segments) * 2 * .pi
            let t1 = Float(i + 1) / Float(segments) * 2 * .pi
            let p0 = Vec3(cos(t0) * radius, 0, sin(t0) * radius)
            let p1 = Vec3(cos(t1) * radius, 0, sin(t1) * radius)
            let tip = Vec3(0, 1, 0)
            let n = normalize(cross(tip - p0, p1 - p0))
            let base = UInt16(vertices.count)
            vertices.append(Vertex(position: p0, normal: n))
            vertices.append(Vertex(position: tip, normal: n))
            vertices.append(Vertex(position: p1, normal: n))
            indices += [base, base + 1, base + 2]
        }
        let center = UInt16(vertices.count)
        vertices.append(Vertex(position: .zero, normal: Vec3(0, -1, 0)))
        for i in 0...segments {
            let t = Float(i) / Float(segments) * 2 * .pi
            vertices.append(Vertex(position: Vec3(cos(t) * radius, 0, sin(t) * radius), normal: Vec3(0, -1, 0)))
        }
        for i in 0..<segments {
            let a = center + 1 + UInt16(i)
            indices += [center, a, a + 1]
        }
        return (vertices, indices)
    }

    /// Torus in the XZ plane, major radius 1, used for rotation rings.
    static func torus(majorSegments: Int = 72, minorSegments: Int = 10, minorRadius: Float = 0.022) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        for i in 0...majorSegments {
            let u = Float(i) / Float(majorSegments) * 2 * .pi
            let ringCenter = Vec3(cos(u), 0, sin(u))
            for j in 0...minorSegments {
                let v = Float(j) / Float(minorSegments) * 2 * .pi
                let n = normalize(ringCenter * cos(v) + Vec3(0, 1, 0) * sin(v))
                vertices.append(Vertex(position: ringCenter + n * minorRadius, normal: n))
            }
        }
        let stride = minorSegments + 1
        for i in 0..<majorSegments {
            for j in 0..<minorSegments {
                let a = UInt16(i * stride + j)
                let b = UInt16((i + 1) * stride + j)
                indices += [a, b + 1, b, a, a + 1, b + 1]
            }
        }
        return (vertices, indices)
    }

    /// A box of `size` with every edge and corner rounded to `radius`, built at its real
    /// size rather than unit size — scaling a rounded box would squash its corners.
    /// Each face is a grid whose outer rows wrap round the edge: a point on the face is
    /// pulled onto a sphere of `radius` around the nearest point of the inner box.
    static func roundedBox(size: Vec3, radius: Float, steps: Int = 4) -> ([Vertex], [UInt16]) {
        let half = size * 0.5
        let r = min(radius, min(half.x, min(half.y, half.z)) * 0.95)
        let inner = half - Vec3(repeating: r)

        // Along one axis: the rounded edge, one flat span, the other rounded edge.
        func coordinates(_ extent: Float) -> [Float] {
            let flat = extent - r
            var values: [Float] = []
            for k in 0...steps {
                values.append(-flat - r * cos(Float(k) / Float(steps) * .pi / 2))
            }
            for k in 0...steps {
                values.append(flat + r * sin(Float(k) / Float(steps) * .pi / 2))
            }
            return values
        }

        let faces: [(n: Vec3, a: Vec3, b: Vec3)] = [
            (Vec3(0, 0, 1),  Vec3(1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(1, 0, 0),  Vec3(0, 0, -1), Vec3(0, 1, 0)),
            (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
            (Vec3(0, 1, 0),  Vec3(1, 0, 0), Vec3(0, 0, -1)),
            (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1))
        ]
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        for face in faces {
            let us = coordinates(dot(abs(face.a), half))
            let vs = coordinates(dot(abs(face.b), half))
            let depth = dot(abs(face.n), half)
            let base = UInt16(vertices.count)
            for u in us {
                for v in vs {
                    let p = face.n * depth + face.a * u + face.b * v
                    let core = simd_clamp(p, -inner, inner)
                    let normal = normalize(p - core)
                    vertices.append(Vertex(position: core + normal * r, normal: normal))
                }
            }
            let stride = vs.count
            for i in 0..<(us.count - 1) {
                for j in 0..<(vs.count - 1) {
                    let a = base + UInt16(i * stride + j)
                    let b = base + UInt16((i + 1) * stride + j)
                    // Same order as `box()`: -a-b, +a-b, +a+b, -a+b.
                    indices += [a, b, b + 1, a, b + 1, a + 1]
                }
            }
        }
        return (vertices, indices)
    }

    /// A solid of revolution about Y. `profile` runs from bottom to top, each row a
    /// radius, a height and the outward normal in (radius, height) terms. Rows of
    /// radius 0 close the ends without degenerate triangles.
    static func lathe(_ profile: [(r: Float, y: Float, normal: SIMD2<Float>)], segments: Int = 32) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        for row in profile {
            for s in 0...segments {
                let t = Float(s) / Float(segments) * 2 * .pi
                let direction = Vec3(cos(t), 0, sin(t))
                let normal = normalize(direction * row.normal.x + Vec3(0, row.normal.y, 0))
                vertices.append(Vertex(position: direction * row.r + Vec3(0, row.y, 0), normal: normal))
            }
        }
        let stride = segments + 1
        for k in 0..<(profile.count - 1) {
            for s in 0..<segments {
                let a = UInt16(k * stride + s)
                let b = UInt16((k + 1) * stride + s)
                if profile[k].r > 1e-6 { indices += [a, b, a + 1] }
                if profile[k + 1].r > 1e-6 { indices += [a + 1, b, b + 1] }
            }
        }
        return (vertices, indices)
    }

    /// The classic Roblox head: a cylinder with generously rounded rims, `height` tall
    /// and `radius` wide, centred on the origin.
    static func head(radius: Float = 0.62, height: Float = 1.25, bevel: Float = 0.28,
                     steps: Int = 6, segments: Int = 40) -> ([Vertex], [UInt16]) {
        let h = height * 0.5
        var profile: [(r: Float, y: Float, normal: SIMD2<Float>)] = [(0, -h, SIMD2(0, -1))]
        for k in 0...steps {
            let phi = -Float.pi / 2 + Float(k) / Float(steps) * .pi / 2
            profile.append((radius - bevel + bevel * cos(phi), -h + bevel + bevel * sin(phi), SIMD2(cos(phi), sin(phi))))
        }
        for k in 0...steps {
            let phi = Float(k) / Float(steps) * .pi / 2
            profile.append((radius - bevel + bevel * cos(phi), h - bevel + bevel * sin(phi), SIMD2(cos(phi), sin(phi))))
        }
        profile.append((0, h, SIMD2(0, 1)))
        return lathe(profile, segments: segments)
    }

    /// A tube bent along an arc in the XY plane (major radius 1), from `start` to `end`
    /// radians — the smile on the default face.
    static func arc(from start: Float, to end: Float, segments: Int = 16,
                    minorSegments: Int = 8, minorRadius: Float = 0.08) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        for i in 0...segments {
            let u = start + (end - start) * Float(i) / Float(segments)
            let centre = Vec3(cos(u), sin(u), 0)
            for j in 0...minorSegments {
                let v = Float(j) / Float(minorSegments) * 2 * .pi
                let n = normalize(centre * cos(v) + Vec3(0, 0, 1) * sin(v))
                vertices.append(Vertex(position: centre + n * minorRadius, normal: n))
            }
        }
        let stride = minorSegments + 1
        for i in 0..<segments {
            for j in 0..<minorSegments {
                let a = UInt16(i * stride + j)
                let b = UInt16((i + 1) * stride + j)
                indices += [a, b, b + 1, a, b + 1, a + 1]
            }
        }
        return (vertices, indices)
    }

    /// The default face — two oval eyes and a smile — for a head of `headRadius`
    /// facing −Z, in head-local units with the head's centre at the origin. Every piece
    /// sits half-sunk into the curved front of the head, so it never floats off it.
    static func face(headRadius R: Float = 0.62) -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        var indices: [UInt16] = []
        func surfaceZ(_ x: Float) -> Float { -sqrt(max(R * R - x * x, 0)) }

        // Eyes: squashed spheres, taller than wide.
        let (ball, ballIndices) = sphere(slices: 16, stacks: 10)
        let eyeScale = Vec3(0.14, 0.24, 0.1)
        for x in [Float(-0.2), 0.2] {
            let base = UInt16(vertices.count)
            let centre = Vec3(x, 0.12, surfaceZ(x))
            for v in ball {
                vertices.append(Vertex(position: centre + v.position * eyeScale,
                                       normal: normalize(v.normal / eyeScale)))
            }
            indices += ballIndices.map { $0 + base }
        }

        // Smile: a tube along the lower part of a circle, wrapped onto the head.
        let (tube, tubeIndices) = arc(from: 3.55, to: 5.87, segments: 18, minorSegments: 8, minorRadius: 0.16)
        let scale: Float = 0.3
        let base = UInt16(vertices.count)
        for v in tube {
            var p = v.position * scale + Vec3(0, 0.02, 0)
            p.z += surfaceZ(p.x)
            vertices.append(Vertex(position: p, normal: v.normal))
        }
        indices += tubeIndices.map { $0 + base }
        return (vertices, indices)
    }

    /// Large ground quad for the procedural grid.
    static func groundQuad(extent: Float = 2000) -> ([Vertex], [UInt16]) {
        let n = Vec3(0, 1, 0)
        let v = [
            Vertex(position: Vec3(-extent, 0, -extent), normal: n),
            Vertex(position: Vec3(extent, 0, -extent), normal: n),
            Vertex(position: Vec3(extent, 0, extent), normal: n),
            Vertex(position: Vec3(-extent, 0, extent), normal: n)
        ]
        return (v, [0, 2, 1, 0, 3, 2])
    }

    /// Unit-cube wireframe used for selection boxes.
    static func boxOutline() -> ([Vertex], [UInt16]) {
        var vertices: [Vertex] = []
        for z in [Float(-0.5), 0.5] {
            for y in [Float(-0.5), 0.5] {
                for x in [Float(-0.5), 0.5] {
                    vertices.append(Vertex(position: Vec3(x, y, z), normal: Vec3(0, 1, 0)))
                }
            }
        }
        let indices: [UInt16] = [
            0, 1, 1, 3, 3, 2, 2, 0,
            4, 5, 5, 7, 7, 6, 6, 4,
            0, 4, 1, 5, 2, 6, 3, 7
        ]
        return (vertices, indices)
    }
}
