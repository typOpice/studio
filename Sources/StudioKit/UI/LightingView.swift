import SwiftUI
import Metal

/// Whether this Mac's GPU can do ray-traced lighting — asked once.
enum RenderCapabilities {
    static let rayTracing: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return Renderer.canRayTrace(device)
    }()
}

/// Properties for Lighting: which technology, the time of day, the sun, ambient
/// light, shadows, fog, and the ray-traced options.
struct LightingInspector: View {
    @ObservedObject var model: SceneModel

    private var lighting: LightingSettings { model.lighting }

    var body: some View {
        ScrollView { content }
    }

    /// Everything but the scrolling, so `--render-panel lighting` can draw it.
    var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                section("Technology") {
                    Picker("", selection: Binding(get: { lighting.technology }, set: { value in
                        model.commit("Lighting: \(value.displayName)") { model.lighting.technology = value }
                    })) {
                        ForEach(LightingTechnology.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(technologyNote)
                        .font(.system(size: 10))
                        .foregroundStyle(lighting.technology == .rayTraced && !RenderCapabilities.rayTracing
                                         ? Color(red: 0.95, green: 0.6, blue: 0.4) : Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.stroke)

                section("Time of day") {
                    HStack {
                        Image(systemName: lighting.sunDirection.y > 0 ? "sun.max.fill" : "moon.fill")
                            .foregroundStyle(lighting.sunDirection.y > 0 ? Color.yellow : Color(red: 0.7, green: 0.75, blue: 0.95))
                        Text(lighting.timeOfDay)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                    }
                    slider("ClockTime", \.clockTime, range: 0...24, step: 0.25)
                    number("GeographicLatitude", \.geographicLatitude, range: -90...90)
                }

                Divider().overlay(Theme.stroke)

                section("Light") {
                    slider("Brightness", \.brightness, range: 0...10, step: 0.1)
                    slider("ExposureCompensation", \.exposureCompensation, range: -3...3, step: 0.1)
                    colorRow("Ambient", \.ambient)
                    colorRow("OutdoorAmbient", \.outdoorAmbient)
                    colorRow("ColorShift_Top", \.colorShiftTop)
                    Toggle("Sky", isOn: toggle(\.sky))
                        .help("A sky that follows the time of day, behind everything")
                }

                Divider().overlay(Theme.stroke)

                section("Shadows") {
                    Toggle("GlobalShadows", isOn: toggle(\.globalShadows))
                    slider("ShadowSoftness", \.shadowSoftness, range: 0...1, step: 0.05)
                }

                Divider().overlay(Theme.stroke)

                section("Fog") {
                    colorRow("FogColor", \.fogColor)
                    number("FogStart", \.fogStart, range: 0...LightingSettings.fogLimit)
                    number("FogEnd", \.fogEnd, range: 0...LightingSettings.fogLimit)
                }

                Divider().overlay(Theme.stroke)

                SkyObjectsEditor(model: model)

                Divider().overlay(Theme.stroke)

                section("Ray tracing") {
                    LabeledRow("Quality") {
                        Picker("", selection: Binding(get: { lighting.rayQuality }, set: { value in
                            model.commit("Ray quality") { model.lighting.rayQuality = value }
                        })) {
                            ForEach(RayQuality.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    Toggle("Reflections", isOn: toggle(\.reflections))
                        .help("Metal and plastic reflect the parts around them")
                    Toggle("Ambient occlusion", isOn: toggle(\.ambientOcclusion))
                        .help("Corners and gaps get darker, where less sky reaches")
                }
                .opacity(lighting.technology == .rayTraced ? 1 : 0.5)

                SmallButton("Reset to defaults", icon: "arrow.uturn.backward") {
                    model.commit("Reset Lighting") { model.lighting = LightingSettings() }
                }
            }
            .padding(12)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
    }

    private var technologyNote: String {
        switch lighting.technology {
        case .conventional:
            return "A shadow map for the sun; point lights without shadows. Fast everywhere."
        case .rayTraced:
            return RenderCapabilities.rayTracing
                ? "Ray-traced soft shadows (point lights too), ambient occlusion and reflections."
                : "This Mac's GPU can't ray trace, so the scene is drawn with conventional lighting."
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.textDim.opacity(0.9))
            content()
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<LightingSettings, Float>,
                        range: ClosedRange<Float>, step: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(String(format: "%.2f", lighting[keyPath: key]))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            Slider(value: Binding(get: { Double(lighting[keyPath: key]) }, set: { value in
                model.beginStroke()
                model.lighting[keyPath: key] = (Float(value) / step).rounded() * step
            }), in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if !editing { model.endStroke() }
            }
            .controlSize(.small)
        }
    }

    private func number(_ label: String, _ key: WritableKeyPath<LightingSettings, Float>,
                        range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            NumericField(label: "", tint: .clear, range: range, value: lighting[keyPath: key]) { value in
                model.commit("Set \(label)") { model.lighting[keyPath: key] = value }
            }
            .frame(width: 84)
        }
    }

    private func colorRow(_ label: String, _ key: WritableKeyPath<LightingSettings, Vec3>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            ColorPicker("", selection: Binding(get: { Color(vec: lighting[keyPath: key]) }, set: { value in
                model.commit("Set \(label)") { model.lighting[keyPath: key] = value.vec }
            }), supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func toggle(_ key: WritableKeyPath<LightingSettings, Bool>) -> Binding<Bool> {
        Binding(get: { lighting[keyPath: key] }, set: { value in
            model.commit("Changed Lighting") { model.lighting[keyPath: key] = value }
        })
    }
}

/// Lights in the selected part; choosing one opens its own inspector.
struct PointLightEditor: View {
    @ObservedObject var model: SceneModel
    let part: Part
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIGHTS").font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(Theme.textDim)
            ForEach(part.lights) { light in
                Button { model.selectedLight = light.id } label: {
                    HStack {
                        Image(systemName: "lightbulb.fill").foregroundStyle(Color(vec: light.color))
                        Text(light.name); Spacer()
                        Text(light.enabled ? light.kind.rawValue : "off").foregroundStyle(Theme.textDim)
                    }
                }.buttonStyle(.plain)
            }
            Menu("Add Light") {
                ForEach(PointLight.Kind.allCases) { kind in
                    Button(kind.rawValue) { model.addLight(kind, to: part.id) }
                }
            }
        }.font(.system(size: 11)).foregroundStyle(Theme.text)
    }
}

/// A selected identified light. Every edit is a scene edit and one undo operation.
struct LightInspector: View {
    @ObservedObject var model: SceneModel
    let light: PointLight

    private func binding<T>(_ key: WritableKeyPath<PointLight, T>) -> Binding<T> {
        Binding(get: { model.light(light.id)?[keyPath: key] ?? light[keyPath: key] }, set: { value in
            model.commit("Changed Light") { model.updateLight(light.id) { $0[keyPath: key] = value } }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(light.kind.rawValue, systemImage: "lightbulb.fill").font(.headline)
                TextField("Name", text: binding(\.name))
                Toggle("Enabled", isOn: binding(\.enabled))
                ColorPicker("Color", selection: Binding(get: { Color(vec: light.color) }, set: { color in
                    model.commit("Light color") { model.updateLight(light.id) { $0.color = color.vec } }
                }), supportsOpacity: false)
                number("Brightness", light.brightness, 0...100, \.brightness)
                number("Range", light.range, 0...PointLight.maximumRange, \.range)
                if light.kind != .point {
                    Picker("Face", selection: binding(\.face)) {
                        ForEach(ParticleEmitter.Face.allCases) { face in Text(face.rawValue).tag(face) }
                    }
                    number("Angle", light.angle, 0...180, \.angle)
                }
                Toggle("Shadows", isOn: binding(\.shadows))
                    .help("Requires ray-traced lighting")
                Button("Delete \(light.kind.rawValue)") { model.removeLight(light.id) }
            }.font(.system(size: 11)).toggleStyle(.checkbox).padding(12)
        }
    }

    private func number(_ name: String, _ value: Float, _ range: ClosedRange<Float>,
                        _ key: WritableKeyPath<PointLight, Float>) -> some View {
        HStack {
            Text(name); Spacer()
            NumericField(label: "", tint: .clear, range: range, value: value) { value in
                model.commit("Light \(name)") { model.updateLight(light.id) { $0[keyPath: key] = value } }
            }.frame(width: 75)
        }
    }
}
