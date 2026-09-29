import SwiftUI
import simd

extension SceneModel {
    func editViewport(_ id: UUID, label: String, _ body: (inout ViewportContent) -> Void) {
        guard let index = starterGui.firstIndex(where: { $0.id == id && $0.kind == .viewportFrame }) else { return }
        var content = starterGui[index].viewportContent ?? ViewportContent()
        body(&content)
        commit(label) { starterGui[index].viewportContent = content }
    }

    @discardableResult
    func addViewportPart(_ shape: PartShape, in id: UUID) -> UUID {
        var part = Part(); part.shape = shape; part.name = shape.displayName; part.position = .zero; part.size = Vec3(repeating: 3)
        editViewport(id, label: "Added preview part") { content in
            part.name = Self.unique(part.name, among: content.parts.map(\.name))
            content.parts.append(part)
            if content.cameras.isEmpty { let camera = PreviewCamera(); content.cameras = [camera]; content.currentCamera = camera.id }
        }
        selectedViewportMember = part.id
        return part.id
    }

    func copyToViewport(_ node: UUID, in id: UUID) {
        let ids = Set([node] + descendants(of: node).map(\.id))
        var incoming = ViewportContent(parts: parts.filter { ids.contains($0.id) }, groups: groups.filter { ids.contains($0.id) }, assets: assets).reidentified()
        if !incoming.parts.isEmpty {
            let center = incoming.parts.reduce(Vec3.zero) { $0 + $1.position } / Float(incoming.parts.count)
            for index in incoming.parts.indices { incoming.parts[index].position -= center; incoming.parts[index].parked = false; incoming.parts[index].storage = nil }
        }
        editViewport(id, label: "Copied into preview") { content in
            content.parts += incoming.parts; content.groups += incoming.groups
            content.assets += incoming.assets.filter { asset in !content.assets.contains { $0.id == asset.id } }
            if content.cameras.isEmpty { let camera = PreviewCamera(); content.cameras = [camera]; content.currentCamera = camera.id }
        }
    }
}

/// Standard scene edits, stored directly in the GUI template and covered by undo.
struct ViewportContentEditor: View {
    @ObservedObject var model: SceneModel
    let template: StarterGuiObject
    private var content: ViewportContent { model.guiObject(id: template.id)?.viewportContent ?? ViewportContent() }
    private var selectedPart: Part? { content.parts.first { $0.id == model.selectedViewportMember } ?? (content.cameras.contains { $0.id == model.selectedViewportMember } ? nil : content.parts.first) }
    private var selectedCamera: PreviewCamera? { content.cameras.first { $0.id == model.selectedViewportMember } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW CONTENT").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
            HStack {
                Menu("Add Part") {
                    ForEach(PartShape.allCases) { shape in Button(shape.displayName) { model.addViewportPart(shape, in: template.id) } }
                }
                Button("Add Camera") {
                    let camera = PreviewCamera()
                    model.editViewport(template.id, label: "Added preview camera") { $0.cameras.append(camera); $0.currentCamera = camera.id }
                    model.selectedViewportMember = camera.id
                }
            }
            Menu("Copy from Workspace") {
                ForEach(model.groups.filter { $0.parentID == nil }) { group in Button(group.name) { model.copyToViewport(group.id, in: template.id) } }
                ForEach(model.parts.filter { $0.parentID == nil }) { part in Button(part.name) { model.copyToViewport(part.id, in: template.id) } }
            }
            ForEach(content.parts) { part in
                Button { model.selectedViewportMember = part.id } label: {
                    Label(part.name, systemImage: part.shape.symbolName).foregroundStyle(selectedPart?.id == part.id ? Theme.accent : Theme.text)
                }.buttonStyle(.plain)
            }
            ForEach(content.cameras) { camera in
                Button { model.selectedViewportMember = camera.id } label: {
                    Label(camera.name + (content.currentCamera == camera.id ? " (current)" : ""), systemImage: "camera").foregroundStyle(selectedCamera?.id == camera.id ? Theme.accent : Theme.text)
                }.buttonStyle(.plain)
            }
            if let part = selectedPart { partFields(part) }
            if let camera = selectedCamera { cameraFields(camera) }
            if content.parts.isEmpty { Text("Add a part or copy a model to preview it here.").foregroundStyle(Theme.textDim) }
        }.font(.system(size: 11))
    }

    private func editPart(_ id: UUID, _ body: @escaping (inout Part) -> Void) {
        model.editViewport(template.id, label: "Changed preview part") { content in
            if let index = content.parts.firstIndex(where: { $0.id == id }) { body(&content.parts[index]) }
        }
    }
    private func editCamera(_ id: UUID, _ body: @escaping (inout PreviewCamera) -> Void) {
        model.editViewport(template.id, label: "Changed preview camera") { content in
            if let index = content.cameras.firstIndex(where: { $0.id == id }) { body(&content.cameras[index]) }
        }
    }
    @ViewBuilder private func partFields(_ part: Part) -> some View {
        TextField("Name", text: Binding(get: { part.name }, set: { value in editPart(part.id) { $0.name = value } }))
        vector("Position", part.position) { value in editPart(part.id) { $0.position = value } }
        vector("Size", part.size) { value in editPart(part.id) { $0.size = simd_max(value, Vec3(repeating: 0.05)) } }
        vector("Rotation", part.rotationDegrees) { value in editPart(part.id) { $0.rotationDegrees = value } }
        ColorPicker("Color", selection: Binding(get: { Color(vec: part.color) }, set: { color in editPart(part.id) { $0.color = color.vec } }), supportsOpacity: false)
        Picker("Material", selection: Binding(get: { part.material }, set: { value in editPart(part.id) { $0.material = value } })) {
            ForEach(PartMaterial.allCases) { material in Text(material.displayName).tag(material) }
        }
        Button("Delete Part") { model.editViewport(template.id, label: "Deleted preview part") { $0.parts.removeAll { $0.id == part.id } } }
    }
    @ViewBuilder private func cameraFields(_ camera: PreviewCamera) -> some View {
        TextField("Name", text: Binding(get: { camera.name }, set: { value in editCamera(camera.id) { $0.name = value } }))
        vector("Position", camera.frame.position) { value in editCamera(camera.id) { $0.frame.position = value } }
        vector("Rotation", camera.frame.orientation.eulerDegrees) { value in editCamera(camera.id) { $0.frame.orientation = .fromEulerDegrees(value) } }
        HStack {
            Text("Field of View")
            NumericField(label: "", tint: .clear, range: 1...120, value: camera.fieldOfView) { value in editCamera(camera.id) { $0.fieldOfView = value } }
        }
        Toggle("Current Camera", isOn: Binding(get: { content.currentCamera == camera.id }, set: { on in
            model.editViewport(template.id, label: "Changed preview camera") { $0.currentCamera = on ? camera.id : nil }
        })).toggleStyle(.checkbox)
        Button("Delete Camera") { model.editViewport(template.id, label: "Deleted preview camera") { content in
            content.cameras.removeAll { $0.id == camera.id }; if content.currentCamera == camera.id { content.currentCamera = nil }
        } }
    }
    private func vector(_ label: String, _ value: Vec3, _ set: @escaping (Vec3) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(Theme.textDim)
            HStack {
                ForEach(0..<3, id: \.self) { axis in
                    NumericField(label: ["X", "Y", "Z"][axis], tint: Theme.accent, value: value[axis]) { number in
                        var result = value; result[axis] = number; set(result)
                    }
                }
            }
        }
    }
}
