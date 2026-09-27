import SwiftUI

/// Lighting's Sky, Atmosphere and Clouds in its Properties: each added or taken away with
/// its checkbox, and its settings below it when it's there.
struct SkyObjectsEditor: View {
    @ObservedObject var model: SceneModel

    private var lighting: LightingSettings { model.lighting }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Sky", present: lighting.skyObject != nil,
                    note: "Without one, the sky still has a sun, a moon and stars.") { on in
                model.lighting.skyObject = on ? SkySettings() : nil
            } content: {
                if let sky = lighting.skyObject {
                    Toggle("CelestialBodiesShown", isOn: Binding(get: { sky.celestialBodiesShown }, set: { on in
                        model.commit("Set CelestialBodiesShown") { model.lighting.skyObject?.celestialBodiesShown = on }
                    }))
                    number("StarCount", Float(sky.starCount), 0...5000) { v in model.lighting.skyObject?.starCount = Int(v) }
                    number("SunAngularSize", sky.sunAngularSize, 0...60) { v in model.lighting.skyObject?.sunAngularSize = v }
                    number("MoonAngularSize", sky.moonAngularSize, 0...60) { v in model.lighting.skyObject?.moonAngularSize = v }
                    ForEach(SkySettings.Face.allCases) { face in picture(face, sky.picture(face)) }
                    Text(sky.skybox.contains(where: { !$0.isEmpty }) && !sky.hasSkybox
                         ? "Give it all six pictures to see them." : "Six pictures (Ft north, Rt east) wrap round the world instead of the sky.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Atmosphere", present: lighting.atmosphere != nil,
                    note: "Air that far things fade into, hazing the horizon.") { on in
                model.lighting.atmosphere = on ? AtmosphereSettings() : nil
            } content: {
                if let air = lighting.atmosphere {
                    slider("Density", air.density, 0...1) { v in model.lighting.atmosphere?.density = v }
                    slider("Offset", air.offset, 0...1) { v in model.lighting.atmosphere?.offset = v }
                    colour("Color", air.color) { c in model.lighting.atmosphere?.color = c }
                    colour("Decay", air.decay) { c in model.lighting.atmosphere?.decay = c }
                    slider("Glare", air.glare, 0...10) { v in model.lighting.atmosphere?.glare = v }
                    slider("Haze", air.haze, 0...10) { v in model.lighting.atmosphere?.haze = v }
                }
            }

            section("Clouds", present: lighting.clouds != nil, note: "A layer of cloud across the sky, drifting.") { on in
                model.lighting.clouds = on ? CloudSettings() : nil
            } content: {
                if let clouds = lighting.clouds {
                    Toggle("Enabled", isOn: Binding(get: { clouds.enabled }, set: { on in
                        model.commit("Set Enabled") { model.lighting.clouds?.enabled = on }
                    }))
                    slider("Cover", clouds.cover, 0...1) { v in model.lighting.clouds?.cover = v }
                    slider("Density", clouds.density, 0...1) { v in model.lighting.clouds?.density = v }
                    colour("Color", clouds.color) { c in model.lighting.clouds?.color = c }
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func section<Content: View>(_ title: String, present: Bool, note: String,
                                        toggle: @escaping (Bool) -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: Binding(get: { present }, set: { on in
                model.commit(on ? "Added \(title)" : "Removed \(title)") { toggle(on) }
            })) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textDim.opacity(0.9))
            }
            if present {
                content()
            } else {
                Text(note).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func slider(_ label: String, _ value: Float, _ range: ClosedRange<Float>,
                        _ set: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(String(format: "%.2f", value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textDim)
            }
            Slider(value: Binding(get: { Double(value) }, set: { v in
                model.beginStroke()
                set(Float(v))
            }), in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if !editing { model.endStroke() }
            }
            .controlSize(.small)
        }
    }

    private func number(_ label: String, _ value: Float, _ range: ClosedRange<Float>,
                        _ set: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            NumericField(label: "", tint: .clear, range: range, value: value) { v in
                model.commit("Set \(label)") { set(v) }
            }
            .frame(width: 84)
        }
    }

    private func colour(_ label: String, _ value: Vec3, _ set: @escaping (Vec3) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            ColorPicker("", selection: Binding(get: { Color(vec: value) }, set: { c in
                model.commit("Set \(label)") { set(c.vec) }
            }), supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func picture(_ face: SkySettings.Face, _ current: String) -> some View {
        let pictures = model.assets.filter { $0.kind == .image }
        return HStack {
            Text(face.rawValue).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            Picker("", selection: Binding(get: { current }, set: { name in
                model.commit("Set \(face.rawValue)") { model.lighting.skyObject?.setPicture(face, name) }
            })) {
                Text("None").tag("")
                ForEach(pictures) { Text($0.name).tag($0.reference) }
                if !current.isEmpty && !pictures.contains(where: { $0.reference == current }) {
                    Text(current).tag(current)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 150)
        }
    }
}
