import SwiftUI
import UniformTypeIdentifiers

/// Bringing 3D models in: the file dialog, limited to what Model I/O reads.
enum MeshImport {
    /// Asks for 3D model files and imports them; returns the new assets' ids.
    static func choose(into model: SceneModel) -> [UUID] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SceneAsset.meshExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.message = "3D models (OBJ, STL, PLY, USD, USDZ) — kept inside the scene when it's saved"
        guard panel.runModal() == .OK else { return [] }
        var made: [UUID] = []
        for url in panel.urls {
            do { made.append(try model.importAsset(from: url)) } catch {
                model.statusText = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return made
    }
}

/// The Home tab's Mesh button: a MeshPart of any imported model, or a new one, from a
/// menu popped up under it. (A SwiftUI `Menu` would drop the tile its neighbours have.)
struct RibbonMeshButton: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    var body: some View {
        RibbonButton(title: "Mesh", icon: "cube.transparent", enabled: !session.isPlaying) {
            MeshMenu.show(model: model, session: session)
        }
        .help("A MeshPart: an imported 3D model")
    }
}

/// The Mesh button's menu: each imported model, then Import 3D Model….
enum MeshMenu {
    private final class Item: NSMenuItem {
        let run: () -> Void
        init(_ title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("not used") }
        @objc private func fire() { run() }
    }

    static func show(model: SceneModel, session: EditorSession) {
        let menu = NSMenu()
        for asset in model.meshAssets {
            menu.addItem(Item(asset.name) { _ = session.viewport.insertMeshPart(asset.id) })
        }
        if !model.meshAssets.isEmpty { menu.addItem(.separator()) }
        menu.addItem(Item("Import 3D Model…") { importAndInsert(model: model, session: session) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Asks for models, imports them and makes a MeshPart of each.
    static func importAndInsert(model: SceneModel, session: EditorSession) {
        for asset in MeshImport.choose(into: model) { _ = session.viewport.insertMeshPart(asset) }
    }
}

/// The Properties panel's Mesh section, for a MeshPart: which model, which picture,
/// how it collides, and what the model is.
struct MeshSection: View {
    @ObservedObject var model: SceneModel
    let part: Part

    var body: some View {
        let mesh = part.mesh ?? MeshSettings()
        let geometry = MeshLibrary.shared.geometry(for: part)
        let meshes = model.meshAssets
        let pictures = model.assets.filter { $0.kind == .image }
        VStack(alignment: .leading, spacing: 8) {
            Text("MESH")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textDim)
            LabeledRow("MeshId") {
                Picker("", selection: Binding(get: { mesh.meshId },
                                              set: { model.setMesh($0, of: model.selection) })) {
                    Text("None").tag("")
                    ForEach(meshes) { Text($0.name).tag($0.reference) }
                    if !mesh.meshId.isEmpty && !meshes.contains(where: { $0.reference == mesh.meshId }) {
                        Text(mesh.meshId).tag(mesh.meshId)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            LabeledRow("Texture") {
                Picker("", selection: Binding(get: { mesh.textureId },
                                              set: { model.setMeshTexture($0, of: model.selection) })) {
                    Text("None").tag("")
                    ForEach(pictures) { Text($0.name).tag($0.reference) }
                    if !mesh.textureId.isEmpty && !pictures.contains(where: { $0.reference == mesh.textureId }) {
                        Text(mesh.textureId).tag(mesh.textureId)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            LabeledRow("Collision") {
                Picker("", selection: Binding(get: { mesh.collisionFidelity },
                                              set: { model.setCollisionFidelity($0, of: model.selection) })) {
                    ForEach(CollisionFidelity.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            Text(note(mesh, geometry))
                .font(.system(size: 10))
                .foregroundStyle(geometry == nil && !mesh.meshId.isEmpty ? Color(red: 0.95, green: 0.7, blue: 0.4)
                                                                          : Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if geometry != nil {
                SmallButton("Reset Size", icon: "arrow.uturn.backward") { model.resetMeshSize(of: model.selection) }
            }
        }
    }

    private func note(_ mesh: MeshSettings, _ geometry: MeshGeometry?) -> String {
        guard let geometry else {
            return mesh.meshId.isEmpty ? "Pick a 3D model, or import one in the Explorer's Assets. Until then it's a block."
                                       : "\(mesh.meshId) isn't an imported 3D model that can be read: drawn as a block."
        }
        let s = geometry.nativeSize
        var text = "\(geometry.triangleCount) triangles, made \(format(s.x)) × \(format(s.y)) × \(format(s.z)) studs."
        switch mesh.collisionFidelity {
        case .box: text += " Collides as its box."
        case .hull: text += " Collides as its outline (convex hull)."
        case .precise:
            text += part.anchored ? " Collides exactly." : " Collides exactly while anchored; its outline while it moves."
        }
        if !mesh.textureId.isEmpty && geometry.uvs.isEmpty { text += " This model has no texture coordinates, so the picture can't show." }
        return text
    }

    private func format(_ value: Float) -> String { NumericField.format(value) }
}
