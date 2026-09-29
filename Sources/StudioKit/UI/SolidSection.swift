import SwiftUI

struct SolidSection: View {
    @ObservedObject var model: SceneModel
    let part: Part
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOLID MODELING").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
            Toggle("Use Part Color", isOn: Binding(get: { part.usePartColor }, set: { value in
                model.commit("Use Part Color") { model.updateSelected { $0.usePartColor = value } }
            })).toggleStyle(.checkbox).font(.system(size: 11))
            LabeledRow("Collision") {
                Picker("", selection: Binding(get: { part.mesh?.collisionFidelity ?? .precise },
                                               set: { model.setCollisionFidelity($0, of: model.selection) })) {
                    ForEach(CollisionFidelity.allCases) { Text($0.displayName).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
            }
            Text("\((part.solid?.mesh.indices.count ?? 0) / 3) triangles. Precise preserves openings while anchored; moving solids use a convex hull.")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            SmallButton("Separate", icon: "square.on.square") { model.separateSelected() }
        }
    }
}
