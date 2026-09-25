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

/// The Light section of a part's properties: its PointLight, if any.
struct PointLightEditor: View {
    @ObservedObject var model: SceneModel
    let part: Part

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIGHT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.textDim.opacity(0.9))
            Toggle("PointLight", isOn: Binding(get: { part.light != nil }, set: { on in
                model.commit(on ? "Added PointLight" : "Removed PointLight") {
                    model.updateSelected { $0.light = on ? ($0.light ?? PointLight()) : nil }
                }
            }))
            if let light = part.light {
                Toggle("Enabled", isOn: binding(light.enabled) { $0.enabled = $1 })
                HStack {
                    Text("Color").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Spacer()
                    ColorPicker("", selection: Binding(get: { Color(vec: light.color) }, set: { value in
                        model.commit("Light colour") { model.updateSelected { $0.light?.color = value.vec } }
                    }), supportsOpacity: false)
                    .labelsHidden()
                }
                numberRow("Brightness", light.brightness, 0...100) { value in
                    model.updateSelected { $0.light?.brightness = value }
                }
                numberRow("Range", light.range, 0...PointLight.maximumRange) { value in
                    model.updateSelected { $0.light?.range = value }
                }
                Toggle("Shadows", isOn: binding(light.shadows) { $0.shadows = $1 })
                    .help("Ray-traced lighting only: other parts block this light")
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .foregroundStyle(Theme.text)
    }

    private func binding(_ value: Bool, _ set: @escaping (inout PointLight, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { newValue in
            model.commit("Changed PointLight") {
                model.updateSelected { part in
                    if part.light != nil { set(&part.light!, newValue) }
                }
            }
        })
    }

    private func numberRow(_ label: String, _ value: Float, _ range: ClosedRange<Float>,
                           set: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            NumericField(label: "", tint: .clear, range: range, value: value) { newValue in
                model.commit("Light \(label.lowercased())") { set(newValue) }
            }
            .frame(width: 70)
        }
    }
}
