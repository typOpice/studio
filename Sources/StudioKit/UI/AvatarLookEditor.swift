import SwiftUI

/// StarterPlayer's Avatar section in Studio: what every character wears — a face, shirt
/// and pants (built in, or a picture imported into the place) and accessories (built in,
/// or an imported 3D model) — with a preview, and whether players keep their own look.
struct StarterPlayerAvatarSection: View {
    @ObservedObject var model: SceneModel
    @State private var expanded: String?

    private var look: AvatarLook { model.starterPlayer.look }
    private var pictures: [SceneAsset] { model.assets.filter { $0.kind == .image } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                AvatarPreview(look: look, colors: model.starterPlayer.bodyColors, assets: model.assets,
                              width: 170, height: 220)
                Spacer()
            }
            Toggle("Players wear their own look too", isOn: Binding(
                get: { model.starterPlayer.playersWearOwnLook },
                set: { value in model.commit("Changed StarterPlayer") { model.starterPlayer.playersWearOwnLook = value } }))
                .help("On, players keep what they chose in the client, with this face, shirt and pants in place of theirs where set, and these accessories added. Off, everyone wears only this.")

            picker("Face", \.face, none: "Classic smile", catalog: AvatarCatalog.faces.filter { $0.id != AvatarCatalog.classicFace })
            picker("Shirt", \.shirt, none: "None", catalog: AvatarCatalog.shirts)
            picker("Pants", \.pants, none: "None", catalog: AvatarCatalog.pants)

            HStack {
                Text("Accessories")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                addMenu
            }
            if look.accessories.isEmpty {
                Text("None. Hats, hair, glasses and more: Add.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(look.accessories) { accessory in
                accessoryRow(accessory)
            }
            Text("Shirts and pants are pictures on Roblox's clothing template (585 × 559); real Roblox templates work. Import pictures and 3D models in the Explorer's Assets.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func change(_ title: String, _ body: (inout AvatarLook) -> Void) {
        model.commit(title) {
            body(&model.starterPlayer.look)
            model.starterPlayer.look.tidy()
        }
    }

    private func picker(_ title: String, _ key: WritableKeyPath<AvatarLook, String>, none: String,
                        catalog: [AvatarCatalog.Picture]) -> some View {
        LabeledRow(title) {
            Picker("", selection: Binding(get: { look[keyPath: key] }, set: { value in
                change("Set \(title.lowercased())") { $0[keyPath: key] = value }
            })) {
                Text(none).tag("")
                Section("Built in") {
                    ForEach(catalog, id: \.id) { Text($0.name).tag(AvatarCatalog.prefix + $0.id) }
                }
                if !pictures.isEmpty {
                    Section("Imported pictures") {
                        ForEach(pictures) { Text($0.name).tag($0.reference) }
                    }
                }
                // Whatever is set now, even if it names nothing any more.
                if !look[keyPath: key].isEmpty, !catalog.contains(where: { AvatarCatalog.prefix + $0.id == look[keyPath: key] }),
                   !pictures.contains(where: { $0.reference == look[keyPath: key] }) {
                    Text(look[keyPath: key]).tag(look[keyPath: key])
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private var addMenu: some View {
        Menu {
            Section("Built in") {
                ForEach(AvatarCatalog.accessories, id: \.id) { entry in
                    Button(entry.name) {
                        guard let accessory = AvatarAccessory(builtIn: entry.id) else { return }
                        change("Added \(entry.name)") { $0.accessories.append(accessory) }
                    }
                }
            }
            if !model.meshAssets.isEmpty {
                Section("Imported 3D models") {
                    ForEach(model.meshAssets) { asset in
                        Button(asset.name) {
                            let accessory = AvatarAccessory(name: asset.name, item: asset.reference, type: .hat,
                                                            color: Vec3(repeating: 0.8))
                            change("Added \(asset.name)") { $0.accessories.append(accessory) }
                            expanded = accessory.id
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(look.accessories.count >= AvatarLook.mostAccessories)
    }

    private func accessoryRow(_ accessory: AvatarAccessory) -> some View {
        let open = expanded == accessory.id
        func edit(_ title: String, _ body: @escaping (inout AvatarAccessory) -> Void) {
            change(title) { look in
                if let index = look.accessories.firstIndex(where: { $0.id == accessory.id }) { body(&look.accessories[index]) }
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { expanded = open ? nil : accessory.id } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 10)
                }
                .buttonStyle(.plain)
                Image(systemName: AvatarCatalog.accessory(accessory.item)?.icon ?? "cube.transparent")
                    .foregroundStyle(Theme.textDim)
                Text(accessory.name).lineLimit(1)
                Spacer()
                ColorPicker("", selection: Binding(get: { Color(vec: accessory.color) }, set: { value in
                    edit("Set accessory colour") { $0.color = value.vec }
                }), supportsOpacity: false)
                .labelsHidden()
                Button {
                    change("Removed \(accessory.name)") { $0.accessories.removeAll { $0.id == accessory.id } }
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textDim) }
                .buttonStyle(.plain)
                .help("Take it off")
            }
            if open {
                LabeledRow("Goes on") {
                    Picker("", selection: Binding(get: { accessory.type }, set: { value in
                        edit("Set accessory type") { $0.type = value }
                    })) {
                        ForEach(AccessoryType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                if !accessory.item.hasPrefix(AvatarCatalog.prefix) {
                    LabeledRow("Texture") {
                        Picker("", selection: Binding(get: { accessory.textureId }, set: { value in
                            edit("Set accessory texture") { $0.textureId = value }
                        })) {
                            Text("None").tag("")
                            ForEach(pictures) { Text($0.name).tag($0.reference) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                }
                VectorEditor(title: "Offset (studs)", value: accessory.offset) { axis, value in
                    edit("Moved accessory") { $0.offset[axis] = value }
                }
                VectorEditor(title: "Rotation (degrees)", value: accessory.rotation) { axis, value in
                    edit("Turned accessory") { $0.rotation[axis] = value }
                }
                HStack {
                    Text("Scale").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Spacer()
                    NumericField(label: "", tint: .clear, range: 0.05...20, value: accessory.scale) { value in
                        edit("Scaled accessory") { $0.scale = value }
                    }
                    .frame(width: 84)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelAlt))
    }
}
