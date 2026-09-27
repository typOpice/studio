import SwiftUI

/// The Properties panel's section for a Beam or a Trail (below its name and Enabled):
/// how it looks, and a Beam's widths and curve or a Trail's lifetime and length.
struct RibbonSection: View {
    @ObservedObject var model: SceneModel
    let constraint: SceneConstraint

    private var look: RibbonLook { constraint.look }

    private func change(_ label: String, _ body: @escaping (inout RibbonLook) -> Void) {
        model.commit(label) { model.updateConstraint(id: constraint.id) { body(&$0.look) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            texturePicker
            LabeledRow("Color", width: 86) {
                HStack {
                    colour(look.color.first?.color ?? Vec3(1, 1, 1)) { c in change("Set Color") { $0.color[0].color = c } }
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                    colour(look.color.last?.color ?? Vec3(1, 1, 1)) { c in
                        change("Set Color") { $0.color[$0.color.count - 1].color = c }
                    }
                    Spacer()
                }
            }
            ends("Transparency", look.transparency, range: 0...1) { first, value in
                change("Set Transparency") { $0.transparency[first ? 0 : $0.transparency.count - 1].value = value }
            }
            number("LightEmission", look.lightEmission, 0...1) { v in change("Set LightEmission") { $0.lightEmission = v } }
            number("Brightness", look.brightness, 0...10) { v in change("Set Brightness") { $0.brightness = v } }
            number("TextureLength", look.textureLength, 0.01...1000) { v in change("Set TextureLength") { $0.textureLength = v } }
            LabeledRow("TextureMode", width: 86) {
                Picker("", selection: Binding(get: { look.textureMode }, set: { m in change("Set TextureMode") { $0.textureMode = m } })) {
                    ForEach(RibbonLook.TextureMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            Toggle("FaceCamera", isOn: Binding(get: { look.faceCamera }, set: { on in change("Set FaceCamera") { $0.faceCamera = on } }))
                .help("Turned to face whoever is looking, so it looks the same from every side")
            if constraint.kind == .beam {
                number("Width0", look.width0, 0...1000) { v in change("Set Width0") { $0.width0 = v } }
                number("Width1", look.width1, 0...1000) { v in change("Set Width1") { $0.width1 = v } }
                number("CurveSize0", look.curveSize0, -1000...1000) { v in change("Set CurveSize0") { $0.curveSize0 = v } }
                    .help("How far it heads out along Attachment0's axis before curving to the other end")
                number("CurveSize1", look.curveSize1, -1000...1000) { v in change("Set CurveSize1") { $0.curveSize1 = v } }
                number("Segments", Float(look.segments), 1...100) { v in change("Set Segments") { $0.segments = Int(v.rounded()) } }
                number("TextureSpeed", look.textureSpeed, -100...100) { v in change("Set TextureSpeed") { $0.textureSpeed = v } }
                    .help("How fast the picture runs along it, in picture lengths a second")
            } else {
                number("Lifetime", look.lifetime, 0.01...20) { v in change("Set Lifetime") { $0.lifetime = v } }
                number("MinLength", look.minLength, 0...100) { v in change("Set MinLength") { $0.minLength = v } }
                number("MaxLength", look.maxLength, 0...10_000) { v in change("Set MaxLength") { $0.maxLength = v } }
                    .help("0: as long as Lifetime makes it")
                ends("WidthScale", look.widthScale, range: 0...100) { first, value in
                    change("Set WidthScale") { $0.widthScale[first ? 0 : $0.widthScale.count - 1].value = value }
                }
                Text("It's left behind as its attachments move, so it shows once the game is running and the part moves.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var texturePicker: some View {
        let pictures = model.assets.filter { $0.kind == .image }
        return LabeledRow("Texture", width: 86) {
            Picker("", selection: Binding(get: { look.texture }, set: { name in change("Set Texture") { $0.texture = name } })) {
                Text("None (plain colour)").tag("")
                Section("Built in") {
                    ForEach(RibbonLook.builtinTextures, id: \.self) { Text($0).tag("builtin://" + $0) }
                }
                if !pictures.isEmpty {
                    Section("This place") {
                        ForEach(pictures) { Text($0.name).tag($0.reference) }
                    }
                }
                if !look.texture.isEmpty && !look.texture.hasPrefix("builtin://")
                    && !pictures.contains(where: { $0.reference == look.texture }) {
                    Text(look.texture).tag(look.texture)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private func number(_ title: String, _ value: Float, _ range: ClosedRange<Float>,
                        _ set: @escaping (Float) -> Void) -> some View {
        LabeledRow(title, width: 86) {
            NumericField(label: "", tint: Theme.textDim, range: range, value: value, onCommit: set)
        }
    }

    private func ends(_ title: String, _ keys: [NumberKey], range: ClosedRange<Float>,
                      _ set: @escaping (_ first: Bool, Float) -> Void) -> some View {
        LabeledRow(title, width: 86) {
            HStack(spacing: 4) {
                NumericField(label: "", tint: Theme.textDim, range: range, value: keys.first?.value ?? 0) { set(true, $0) }
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                NumericField(label: "", tint: Theme.textDim, range: range, value: keys.last?.value ?? 0) { set(false, $0) }
            }
        }
    }

    private func colour(_ value: Vec3, _ set: @escaping (Vec3) -> Void) -> some View {
        ColorPicker("", selection: Binding(get: { Color(vec: value) }, set: { set($0.vec) }), supportsOpacity: false)
            .labelsHidden()
    }
}
