import SwiftUI

/// Properties for a picture or sound brought into the scene: its name, how scripts name
/// it, and a look or a listen.
struct AssetInspector: View {
    @ObservedObject var model: SceneModel
    var session: EditorSession?
    let asset: SceneAsset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("Name") {
                    TextField("", text: Binding(get: { asset.name }, set: { model.renameAsset(asset.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                }
                LabeledRow("Kind") {
                    Text("\(asset.kind == .image ? "Picture" : asset.kind == .mesh ? "3D model" : "Sound") · .\(asset.fileExtension) · \(max(asset.data.count / 1024, 1)) KB")
                        .font(.system(size: 11)).foregroundStyle(Theme.text)
                }
                LabeledRow("In scripts") {
                    HStack(spacing: 6) {
                        Text(asset.reference).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(asset.reference, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textDim)
                        .help("Copy")
                    }
                }
                if asset.kind == .image, let image = NSImage(data: asset.data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelAlt))
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                } else if asset.kind == .mesh {
                    if let geometry = MeshLibrary.shared.geometry(asset.id) {
                        let s = geometry.nativeSize
                        Text("\(geometry.triangleCount) triangles · \(NumericField.format(s.x)) × \(NumericField.format(s.y)) × \(NumericField.format(s.z)) studs\(geometry.uvs.isEmpty ? " · no texture coordinates" : "")")
                            .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        if let session {
                            SmallButton("Insert MeshPart", icon: "cube.transparent") {
                                session.viewport.insertMeshPart(asset.id)
                            }
                        }
                    } else {
                        Text("This file can't be read as a 3D model.")
                            .font(.system(size: 10)).foregroundStyle(Color(red: 0.95, green: 0.7, blue: 0.4))
                    }
                } else if asset.kind == .sound, let session {
                    let length = session.previewSounds.duration(of: asset)
                    Text(length.map { String(format: "%.2f seconds", $0) } ?? "This file can't be played.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    HStack(spacing: 6) {
                        SmallButton("Listen", icon: "play.fill") { session.preview(asset) }
                        SmallButton("Stop", icon: "stop.fill") { session.stopPreview() }
                    }
                }
                SmallButton("Delete", icon: "trash") { model.deleteAsset(asset.id) }
            }
            .padding(12)
        }
    }
}

/// Properties for a Sound: what it plays, how, and where it is heard.
struct SoundInspector: View {
    @ObservedObject var model: SceneModel
    let sound: SceneSound

    private func change(_ label: String, _ body: @escaping (inout SceneSound) -> Void) {
        model.commit(label) { model.updateSound(id: sound.id, body) }
    }

    var body: some View {
        let sounds = model.assets.filter { $0.kind == .sound }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("Name") {
                    TextField("", text: Binding(get: { sound.name }, set: { name in change("Renamed") { $0.name = name } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                }
                LabeledRow("Heard") {
                    Text(sound.parentID.flatMap { model.part(id: $0)?.name }.map { "from \($0)" } ?? "everywhere")
                        .font(.system(size: 11)).foregroundStyle(Theme.text)
                }
                LabeledRow("SoundId") {
                    Picker("", selection: Binding(get: { sound.soundId }, set: { id in change("Set SoundId") { $0.soundId = id } })) {
                        Text("None").tag("")
                        if !sounds.isEmpty {
                            Section("This place") {
                                ForEach(sounds) { Text($0.name).tag($0.reference) }
                            }
                        }
                        Section("Built in") {
                            ForEach(BuiltinSounds.catalog, id: \.name) { entry in
                                Text("\(entry.name) — \(entry.summary)").tag(BuiltinSounds.prefix + entry.name)
                            }
                        }
                        if !sound.soundId.isEmpty && !sounds.contains(where: { $0.reference == sound.soundId })
                            && BuiltinSounds.name(of: sound.soundId) == nil {
                            Text(sound.soundId).tag(sound.soundId)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                if sound.soundId.isEmpty {
                    Text("Pick a built-in sound, or import your own in the Explorer's Assets.")
                        .font(.system(size: 10)).foregroundStyle(Color(red: 0.95, green: 0.7, blue: 0.4))
                }
                LabeledRow("Volume") {
                    NumericField(label: "", tint: Theme.textDim, range: 0...10, value: sound.volume) { value in
                        change("Set Volume") { $0.volume = value }
                    }
                }
                LabeledRow("Speed") {
                    NumericField(label: "", tint: Theme.textDim, range: 0.01...20, value: sound.playbackSpeed) { value in
                        change("Set PlaybackSpeed") { $0.playbackSpeed = value }
                    }
                }
                if sound.parentID != nil {
                    LabeledRow("Reach") {
                        NumericField(label: "", tint: Theme.textDim, range: 0...10000, value: sound.rollOffMaxDistance) { value in
                            change("Set RollOffMaxDistance") { $0.rollOffMaxDistance = value }
                        }
                    }
                    .help("RollOffMaxDistance: past this many studs from its part, it can't be heard")
                }
                Toggle("Looped", isOn: Binding(get: { sound.looped }, set: { on in change("Set Looped") { $0.looped = on } }))
                Toggle("Plays when the game starts", isOn: Binding(get: { sound.playing },
                                                                  set: { on in change("Set Playing") { $0.playing = on } }))
                SmallButton("Delete", icon: "trash") { model.deleteSound(sound.id) }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
            .padding(12)
        }
    }
}
