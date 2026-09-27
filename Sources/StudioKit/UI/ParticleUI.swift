import SwiftUI

/// The Properties panel for a ParticleEmitter: how its particles look, how they come out,
/// and how they move. A sequence (Color, Size, Transparency) shows its first and last
/// keypoints; scripts can give it more, which editing the ends leaves in place.
struct EmitterInspector: View {
    @ObservedObject var model: SceneModel
    let ref: EmitterRef
    let emitter: ParticleEmitter

    static let tint = Color(red: 0.98, green: 0.78, blue: 0.35)

    private func change(_ label: String, _ body: @escaping (inout ParticleEmitter) -> Void) {
        model.commit(label) { model.updateEmitter(ref, body) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("Name", width: 86) {
                    TextField("", text: Binding(get: { emitter.name }, set: { name in change("Renamed") { $0.name = name } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                }
                LabeledRow("In", width: 86) {
                    Text(model.part(id: ref.part)?.name ?? "").font(.system(size: 11)).foregroundStyle(Theme.text)
                }
                Toggle("Enabled", isOn: Binding(get: { emitter.enabled }, set: { on in change("Set Enabled") { $0.enabled = on } }))

                heading("Looks")
                texturePicker
                LabeledRow("Color", width: 86) {
                    HStack {
                        colour(emitter.color.first?.color ?? Vec3(1, 1, 1)) { c in change("Set Color") { $0.color[0].color = c } }
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                        colour(emitter.color.last?.color ?? Vec3(1, 1, 1)) { c in
                            change("Set Color") { $0.color[$0.color.count - 1].color = c }
                        }
                        if emitter.color.count > 2 {
                            Text("+\(emitter.color.count - 2)").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                    }
                }
                ends("Size", emitter.size, range: 0...100) { first, value in
                    change("Set Size") { $0.size[first ? 0 : $0.size.count - 1].value = value }
                }
                ends("Transparency", emitter.transparency, range: 0...1) { first, value in
                    change("Set Transparency") { $0.transparency[first ? 0 : $0.transparency.count - 1].value = value }
                }
                number("LightEmission", emitter.lightEmission, range: 0...1) { v in change("Set LightEmission") { $0.lightEmission = v } }
                    .help("0 drawn over what's behind; 1 added to it, so it glows")
                number("Brightness", emitter.brightness, range: 0...10) { v in change("Set Brightness") { $0.brightness = v } }

                heading("Coming out")
                number("Rate", emitter.rate, range: 0...1000) { v in change("Set Rate") { $0.rate = v } }
                    .help("Particles a second. 0 makes none until a script calls :Emit(count)")
                pair("Lifetime", emitter.lifetime, range: 0...600) { v in change("Set Lifetime") { $0.lifetime = v } }
                pair("Speed", emitter.speed, range: -1000...1000) { v in change("Set Speed") { $0.speed = v } }
                pair("SpreadAngle", emitter.spreadAngle, range: -360...360, ordered: false) { v in
                    change("Set SpreadAngle") { $0.spreadAngle = v }
                }
                LabeledRow("Direction", width: 86) {
                    Picker("", selection: Binding(get: { emitter.emissionDirection },
                                                  set: { face in change("Set EmissionDirection") { $0.emissionDirection = face } })) {
                        ForEach(ParticleEmitter.Face.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                .help("EmissionDirection: the face of the part they fly out of")

                heading("Moving")
                VectorEditor(title: "Acceleration", value: emitter.acceleration) { axis, value in
                    change("Set Acceleration") { $0.acceleration[axis] = value }
                }
                number("Drag", emitter.drag, range: -100...100) { v in change("Set Drag") { $0.drag = v } }
                pair("Rotation", emitter.rotation, range: -36000...36000) { v in change("Set Rotation") { $0.rotation = v } }
                pair("RotSpeed", emitter.rotSpeed, range: -36000...36000) { v in change("Set RotSpeed") { $0.rotSpeed = v } }
                number("TimeScale", emitter.timeScale, range: 0...1) { v in change("Set TimeScale") { $0.timeScale = v } }
                Toggle("LockedToPart", isOn: Binding(get: { emitter.lockedToPart },
                                                     set: { on in change("Set LockedToPart") { $0.lockedToPart = on } }))
                    .help("The particles move with the part, rather than staying where they were made")

                Text("Scripts: emitter:Emit(20) bursts; :Clear() takes them all away. Its particles are drawn on each player's own machine.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                SmallButton("Delete", icon: "trash") { model.removeEmitter(ref) }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
            .padding(12)
        }
    }

    private var texturePicker: some View {
        let pictures = model.assets.filter { $0.kind == .image }
        return LabeledRow("Texture", width: 86) {
            Picker("", selection: Binding(get: { emitter.texture }, set: { name in change("Set Texture") { $0.texture = name } })) {
                Section("Built in") {
                    ForEach(ParticleEmitter.builtinTextures, id: \.self) { Text($0).tag("builtin://" + $0) }
                }
                if !pictures.isEmpty {
                    Section("This place") {
                        ForEach(pictures) { Text($0.name).tag($0.reference) }
                    }
                }
                if !emitter.texture.hasPrefix("builtin://") && !pictures.contains(where: { $0.reference == emitter.texture }) {
                    Text(emitter.texture).tag(emitter.texture)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textDim)
            .padding(.top, 4)
    }

    private func number(_ title: String, _ value: Float, range: ClosedRange<Float>,
                        _ set: @escaping (Float) -> Void) -> some View {
        LabeledRow(title, width: 86) {
            NumericField(label: "", tint: Theme.textDim, range: range, value: value, onCommit: set)
        }
    }

    /// A NumberRange (or SpreadAngle's two angles): each end on its own.
    private func pair(_ title: String, _ value: SIMD2<Float>, range: ClosedRange<Float>, ordered: Bool = true,
                      _ set: @escaping (SIMD2<Float>) -> Void) -> some View {
        LabeledRow(title, width: 86) {
            HStack(spacing: 4) {
                NumericField(label: ordered ? "min" : "x", tint: Theme.textDim, range: range, value: value.x) { x in
                    set(SIMD2(x, ordered ? max(x, value.y) : value.y))
                }
                NumericField(label: ordered ? "max" : "y", tint: Theme.textDim, range: range, value: value.y) { y in
                    set(SIMD2(ordered ? min(value.x, y) : value.x, y))
                }
            }
        }
    }

    /// A NumberSequence's first and last values.
    private func ends(_ title: String, _ keys: [NumberKey], range: ClosedRange<Float>,
                      _ set: @escaping (_ first: Bool, Float) -> Void) -> some View {
        LabeledRow(title, width: 86) {
            HStack(spacing: 4) {
                NumericField(label: "", tint: Theme.textDim, range: range, value: keys.first?.value ?? 0) { set(true, $0) }
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                NumericField(label: "", tint: Theme.textDim, range: range, value: keys.last?.value ?? 0) { set(false, $0) }
                if keys.count > 2 {
                    Text("+\(keys.count - 2)").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private func colour(_ value: Vec3, _ set: @escaping (Vec3) -> Void) -> some View {
        ColorPicker("", selection: Binding(get: { Color(vec: value) }, set: { set($0.vec) }), supportsOpacity: false)
            .labelsHidden()
    }
}
