import SwiftUI

/// The dock's Terrain Editor: a brush to paint the world's terrain with in the viewport
/// (Add, Subtract, Grow, Erode, Smooth, Flatten, Paint), its size, strength and material;
/// Generate, for land to start from; the water's look; and Clear.
struct TerrainEditorView: View {
    @ObservedObject var model: SceneModel

    @State private var generateSize: Float = 512
    @State private var generateHeight: Float = 80
    @State private var withWater = true
    @State private var waterLevel: Float = 10
    @State private var seed: Float = 7

    var body: some View {
        // Sideways too: its sections never make the window's column wider than it is.
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 18) {
                brushes.frame(width: 300, alignment: .topLeading)
                Divider().overlay(Theme.stroke)
                materials.frame(width: 250, alignment: .topLeading)
                Divider().overlay(Theme.stroke)
                generate.frame(width: 250, alignment: .topLeading)
                Divider().overlay(Theme.stroke)
                water.frame(width: 220, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .modifier(StartAtTopLeading())
        .font(.system(size: 11))
        .foregroundStyle(Theme.text)
        .toggleStyle(.checkbox)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(Theme.textDim)
    }

    private var brushes: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Brush")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 4), count: 4), alignment: .leading, spacing: 4) {
                ForEach(TerrainData.Brush.allCases) { brush in
                    let on = model.terrainBrush == brush
                    Button { model.terrainBrush = on ? nil : brush } label: {
                        VStack(spacing: 2) {
                            Image(systemName: Self.symbol(brush)).font(.system(size: 13))
                            Text(brush.rawValue).font(.system(size: 10))
                        }
                        .frame(width: 64, height: 40)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.5) : Theme.panelAlt))
                    }
                    .buttonStyle(.plain)
                    .help(Self.help(brush))
                }
            }
            slider("Size", value: model.terrainBrushSize, range: 4...64) { model.terrainBrushSize = $0 }
            slider("Strength", value: model.terrainBrushStrength, range: 0.05...1) { model.terrainBrushStrength = $0 }
            Text(model.terrainBrush == nil ? "Pick a brush, then drag in the world."
                 : "Drag in the world to \(Self.help(model.terrainBrush!).lowercased()) Each stroke is one step to undo.")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var materials: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Material")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 4), count: 4), alignment: .leading, spacing: 4) {
                ForEach(TerrainMaterial.allCases.filter { $0 != .air }) { material in
                    let on = model.terrainMaterial == material
                    Button { model.terrainMaterial = material } label: {
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4).fill(Color(vec: model.terrain.color(of: material)))
                                .frame(width: 40, height: 16)
                            Text(material.name).font(.system(size: 9)).lineLimit(1)
                        }
                        .frame(width: 56, height: 36)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var generate: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Generate")
            slider("Size", value: generateSize, range: 64...1024) { generateSize = ($0 / 64).rounded() * 64 }
            slider("Height", value: generateHeight, range: 8...200) { generateHeight = $0.rounded() }
            Toggle("Water", isOn: $withWater)
            if withWater { slider("Water level", value: waterLevel, range: -20...100) { waterLevel = $0.rounded() } }
            slider("Seed", value: seed, range: 1...999) { seed = $0.rounded() }
            HStack {
                SmallButton("Generate", icon: "mountain.2") {
                    model.commit("Generated terrain") {
                        var terrain = model.terrain
                        terrain.generate(centre: Vec3(0, -8, 0), size: generateSize, height: generateHeight,
                                         waterLevel: withWater ? waterLevel : nil, seed: UInt32(seed))
                        model.terrain = terrain
                    }
                }
                SmallButton("Clear", icon: "trash") {
                    model.commit("Cleared terrain") { model.terrain.chunks = [:] }
                }
            }
            Text("\(model.terrain.chunks.count) chunks of 64 studs")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
    }

    private var water: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Water")
            HStack {
                Text("WaterColor").foregroundStyle(Theme.textDim)
                Spacer()
                ColorPicker("", selection: Binding(get: { Color(vec: model.terrain.waterColor) }, set: { c in
                    model.commit("Set WaterColor") { model.terrain.waterColor = c.vec }
                }), supportsOpacity: false).labelsHidden()
            }
            slider("WaterTransparency", value: model.terrain.waterTransparency, range: 0...1) { v in
                model.beginStroke()
                model.terrain.waterTransparency = v
            } done: { model.endStroke() }
        }
    }

    private func slider(_ label: String, value: Float, range: ClosedRange<Float>, set: @escaping (Float) -> Void,
                        done: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(Theme.textDim)
                Spacer()
                Text(String(format: value < 2 ? "%.2f" : "%.0f", value)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) { editing in if !editing { done() } }
                .controlSize(.small)
        }
    }

    static func symbol(_ brush: TerrainData.Brush) -> String {
        switch brush {
        case .add: return "plus.circle"
        case .subtract: return "minus.circle"
        case .grow: return "arrow.up.circle"
        case .erode: return "arrow.down.circle"
        case .smooth: return "water.waves"
        case .flatten: return "equal.circle"
        case .paint: return "paintbrush"
        }
    }

    static func help(_ brush: TerrainData.Brush) -> String {
        switch brush {
        case .add: return "Add a ball of the material."
        case .subtract: return "Dig a ball out."
        case .grow: return "Build the surface up a little."
        case .erode: return "Wear the surface down a little."
        case .smooth: return "Even out bumps and dips."
        case .flatten: return "Level to where you start the stroke."
        case .paint: return "Paint the surface with the material."
        }
    }
}

/// A scroll view that starts at its top-left corner rather than its middle.
private struct StartAtTopLeading: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.defaultScrollAnchor(.topLeading)
        } else {
            content
        }
    }
}
