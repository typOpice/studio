import SwiftUI
import simd

/// Inspector for the current selection. Edits apply to every selected part,
/// while the displayed values come from the first one.
struct PropertiesView: View {
    @ObservedObject var model: SceneModel
    /// For opening a LocalScript added from a GUI object's properties.
    var session: EditorSession?

    private var primary: Part? {
        model.parts.first { model.selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Properties", systemImage: "slider.horizontal.3") {
                if model.selection.count > 1 {
                    Text("\(model.selection.count) selected")
                        .font(.system(size: 10))
                }
            }

            if model.selection.isEmpty, let id = model.selectedDataObject, let object = model.dataObject(id: id) {
                DataObjectInspector(model: model, object: object)
            } else if model.selection.isEmpty, let id = model.selectedSound, let sound = model.sound(id: id) {
                SoundInspector(model: model, sound: sound)
            } else if model.selection.isEmpty, let ref = model.selectedEmitter, let emitter = model.emitter(ref) {
                EmitterInspector(model: model, ref: ref, emitter: emitter)
            } else if model.selection.isEmpty, let id = model.selectedAsset, let asset = model.asset(id: id) {
                AssetInspector(model: model, session: session, asset: asset)
            } else if model.selection.isEmpty, let id = model.selectedGui, let template = model.guiObject(id: id) {
                GuiTemplateInspector(model: model, session: session, template: template)
            } else if let id = model.selectedConstraint, let constraint = model.constraint(id: id) {
                ConstraintInspector(model: model, constraint: constraint)
            } else if let id = model.selectedAttachment, let attachment = model.attachment(id: id) {
                AttachmentInspector(model: model, attachment: attachment)
            } else if model.lightingSelected {
                LightingInspector(model: model)
            } else if model.selection.count == 1, let id = model.selection.first, let group = model.group(id: id) {
                GroupInspector(model: model, group: group)
            } else if model.starterPlayerSelected {
                StarterPlayerInspector(model: model)
            } else if let part = primary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        identitySection(part)
                        Divider().overlay(Theme.stroke)
                        transformSection(part)
                        Divider().overlay(Theme.stroke)
                        appearanceSection(part)
                        Divider().overlay(Theme.stroke)
                        if part.mesh != nil {
                            MeshSection(model: model, part: part)
                            Divider().overlay(Theme.stroke)
                        }
                        behaviorSection(part)
                        Divider().overlay(Theme.stroke)
                        PointLightEditor(model: model, part: part)
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textDim.opacity(0.6))
                    Text("Nothing selected")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                    Text("Click a part in the viewport or explorer")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
        }
        .background(Theme.panel)
    }

    // MARK: - Sections

    private func identitySection(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Identity")
            LabeledRow("Name") {
                TextField("", text: Binding(
                    get: { part.name },
                    set: { newValue in
                        model.commit("Renamed part") {
                            model.update(id: part.id) { $0.name = newValue }
                        }
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
            }
            if part.mesh != nil {
                LabeledRow("Class") {
                    Text("MeshPart").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
            LabeledRow("Shape") {
                Picker("", selection: Binding(
                    get: { part.shape },
                    set: { newValue in
                        model.commit("Changed shape") {
                            model.updateSelected { $0.shape = newValue }
                        }
                    })) {
                        ForEach(PartShape.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
            }
            }
        }
    }

    private func transformSection(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Transform")

            VectorEditor(title: "Position", value: part.position) { axis, value in
                let delta = value - part.position[axis]
                model.commit("Set position") {
                    model.updateSelected { $0.position[axis] += delta }
                }
            }

            VectorEditor(title: "Size", value: part.size, minComponent: 0.05) { axis, value in
                model.commit("Set size") {
                    model.updateSelected { $0.size[axis] = max(0.05, value) }
                }
            }

            VectorEditor(title: "Rotation (degrees)", value: part.rotationDegrees) { axis, value in
                var euler = part.rotationDegrees
                euler[axis] = value
                model.commit("Set rotation") {
                    model.updateSelected { $0.rotationDegrees = euler }
                }
            }

            HStack(spacing: 6) {
                SmallButton("Drop to floor", icon: "arrow.down.to.line") { model.groundSelected() }
                SmallButton("Reset rotation", icon: "arrow.counterclockwise") {
                    model.commit("Reset rotation") {
                        model.updateSelected { $0.orientation = simd_quatf(angle: 0, axis: Vec3(0, 1, 0)) }
                    }
                }
            }
        }
    }

    private func appearanceSection(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Appearance")

            LabeledRow("Color") {
                ColorPicker("", selection: Binding(
                    get: { Color(vec: part.color) },
                    set: { newValue in
                        model.commit("Set color") {
                            model.updateSelected { $0.color = newValue.vec }
                        }
                    }), supportsOpacity: false)
                    .labelsHidden()
            }

            swatches(part)

            LabeledRow("Shader") {
                Picker("", selection: Binding(
                    get: { part.shaderID },
                    set: { model.assignShader($0, to: model.selection) })) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.shaders) { shader in
                            Text(shader.name).tag(UUID?.some(shader.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .disabled(model.shaders.isEmpty)
            }

            LabeledRow("Material") {
                Picker("", selection: Binding(
                    get: { part.material },
                    set: { newValue in
                        model.commit("Set material") {
                            model.updateSelected { $0.material = newValue }
                        }
                    })) {
                        ForEach(PartMaterial.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Transparency")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(String(format: "%.2f", part.transparency))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
                Slider(value: Binding(
                    get: { Double(part.transparency) },
                    set: { newValue in
                        model.beginStroke()
                        model.updateSelected { $0.transparency = Float(newValue) }
                    }), in: 0...1) { editing in
                        if !editing { model.endStroke() }
                    }
                    .controlSize(.small)
            }
        }
    }

    private func swatches(_ part: Part) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8), spacing: 5) {
            ForEach(Array(SceneModel.palette.enumerated()), id: \.offset) { _, color in
                let isCurrent = simd_length(color - part.color) < 0.01
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(vec: color))
                    .frame(height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(isCurrent ? Color.white : Theme.stroke, lineWidth: isCurrent ? 2 : 1))
                    .onTapGesture {
                        model.commit("Set color") {
                            model.updateSelected { $0.color = color }
                        }
                    }
            }
        }
    }

    private func behaviorSection(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Behavior")
            Toggle("Anchored", isOn: binding(part.anchored) { $0.anchored = $1 })
            Toggle("Visible", isOn: binding(part.visible) { $0.visible = $1 })
            Toggle("Locked", isOn: binding(part.locked) { $0.locked = $1 })
            Toggle("CanCollide", isOn: binding(part.canCollide) { $0.canCollide = $1 })
                .help("Off: the player walks through it, and it still reports touches.")
            Toggle("CanTouch", isOn: binding(part.canTouch) { $0.canTouch = $1 })
                .help("Off: touching it fires no Touched or TouchEnded events.")
            Toggle("Seat", isOn: binding(part.seat != nil) { $0.seat = $1 ? ($0.seat ?? SeatSettings()) : nil })
                .help("A character touching it sits down; Space gets up.")
            Toggle("ClickDetector", isOn: binding(part.clickDetector != nil) {
                $0.clickDetector = $1 ? ($0.clickDetector ?? ClickDetector()) : nil
            })
            .help("Clicking the part in play fires its ClickDetector's MouseClick.")
            if let detector = part.clickDetector {
                NumericField(label: "Reach", tint: Theme.textDim, range: 0...1000,
                             value: detector.maxActivationDistance) { value in
                    model.commit("Changed property") {
                        model.updateSelected { $0.clickDetector?.maxActivationDistance = value }
                    }
                }
                .help("MaxActivationDistance: how near, in studs, a player must be to click it")
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .foregroundStyle(Theme.text)
    }

    private func binding(_ value: Bool, _ setter: @escaping (inout Part, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { newValue in
            model.commit("Changed property") {
                model.updateSelected { setter(&$0, newValue) }
            }
        })
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(Theme.textDim.opacity(0.9))
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    /// The label's column: wider for panels whose names are long (ParticleEmitter's).
    var width: CGFloat = 58
    @ViewBuilder var content: Content

    init(_ label: String, width: CGFloat = 58, @ViewBuilder content: () -> Content) {
        self.label = label
        self.width = width
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .frame(width: width, alignment: .leading)
            content
        }
    }
}

struct SmallButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 10))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }
}

/// Properties for a Model, Folder or Tool: its name, for a Model its PrimaryPart and
/// pivot, and for a Tool its settings.
struct GroupInspector: View {
    @ObservedObject var model: SceneModel
    let group: SceneGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow("Name") {
                    TextField("", text: Binding(get: { group.name }, set: { model.renameNode(group.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
                }
                LabeledRow("Class") {
                    Text(group.kind.rawValue).font(.system(size: 11)).foregroundStyle(Theme.text)
                }
                let parts = model.partIDs(inSubtree: group.id)
                Text("\(parts.count) part\(parts.count == 1 ? "" : "s") inside")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)

                if group.kind == .model {
                    Divider().overlay(Theme.stroke)
                    LabeledRow("PrimaryPart") {
                        Picker("", selection: Binding(get: { group.primaryPartID }, set: { value in
                            model.commit("Set PrimaryPart") { model.updateGroup(id: group.id) { $0.primaryPartID = value } }
                        })) {
                            Text("None").tag(UUID?.none)
                            ForEach(parts, id: \.self) { id in
                                Text(model.name(of: id) ?? "Part").tag(UUID?.some(id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                    .help("The Model's pivot: where it is and which way it faces")
                    if let pivot = model.pivot(of: group.id) {
                        VectorEditor(title: "Pivot position", value: pivot.position) { axis, value in
                            var target = pivot
                            target.position[axis] = value
                            model.commit("Moved \(group.name)") { model.movePivot(of: group.id, to: target) }
                        }
                    }
                }

                if let tool = group.tool {
                    Divider().overlay(Theme.stroke)
                    LabeledRow("ToolTip") {
                        TextField("", text: Binding(get: { tool.toolTip }, set: { text in
                            model.commit("Set ToolTip") { model.updateTool(id: group.id) { $0.toolTip = text } }
                        }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                    }
                    Toggle("Enabled", isOn: Binding(get: { tool.enabled }, set: { on in
                        model.commit("Set Enabled") { model.updateTool(id: group.id) { $0.enabled = on } }
                    }))
                    .help("Off, clicks don't activate it")
                    Toggle("RequiresHandle", isOn: Binding(get: { tool.requiresHandle }, set: { on in
                        model.commit("Set RequiresHandle") { model.updateTool(id: group.id) { $0.requiresHandle = on } }
                    }))
                    .help("Held by the part named Handle; without one it can't be equipped")
                    Toggle("CanBeDropped", isOn: Binding(get: { tool.canBeDropped }, set: { on in
                        model.commit("Set CanBeDropped") { model.updateTool(id: group.id) { $0.canBeDropped = on } }
                    }))
                    .help("Backspace drops it into the world")
                    if model.handle(of: group.id) == nil && tool.requiresHandle {
                        Text("Add a part named Handle to hold it by.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.95, green: 0.7, blue: 0.4))
                    }
                    HStack(spacing: 6) {
                        if tool.place == .starterPack {
                            SmallButton("Move to Workspace", icon: "globe") { model.moveToWorkspace(group.id) }
                        } else {
                            SmallButton("Move to StarterPack", icon: "backpack") { model.moveToStarterPack(group.id) }
                        }
                    }
                }

                HStack(spacing: 6) {
                    SmallButton("Ungroup", icon: "square.dashed") { model.ungroup(group.id) }
                    SmallButton("Duplicate", icon: "plus.square.on.square") { model.duplicateSelected() }
                }
            }
            .padding(12)
        }
    }
}

/// Properties for a weld or joint: what it joins, and how it behaves.
struct ConstraintInspector: View {
    @ObservedObject var model: SceneModel
    let constraint: SceneConstraint

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: constraint.kind.symbolName)
                        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.45))
                    Text(constraint.kind.rawValue).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                LabeledRow("Name") {
                    TextField("", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                }
                Toggle("Enabled", isOn: Binding(get: { constraint.enabled }, set: { value in
                    model.commit(value ? "Enabled joint" : "Disabled joint") {
                        model.updateConstraint(id: constraint.id) { $0.enabled = value }
                    }
                }))
                .toggleStyle(.checkbox)

                let ends = constraint.parts(in: model)
                let first = model.name(of: ends.0 ?? UUID()) ?? "?", second = model.name(of: ends.1 ?? UUID()) ?? "?"
                Text(constraint.kind == .trail ? "Left behind \(first) as it moves"
                     : constraint.kind == .beam ? "From \(first) to \(second)" : "Joins \(first) and \(second)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)

                Divider().overlay(Theme.stroke)

                switch constraint.kind {
                case .weld:
                    Text("Welded parts move as one. Anchor either and both stay put.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .hinge:
                    actuator(angular: true)
                    Toggle("LimitsEnabled", isOn: toggle(\.limitsEnabled)).toggleStyle(.checkbox)
                    if constraint.limitsEnabled {
                        number("LowerAngle", \.lowerAngle, -180...0)
                        number("UpperAngle", \.upperAngle, 0...180)
                    }
                case .prismatic:
                    actuator(angular: false)
                    Toggle("LimitsEnabled", isOn: toggle(\.limitsEnabled)).toggleStyle(.checkbox)
                    if constraint.limitsEnabled {
                        number("LowerLimit", \.lowerLimit, -1000...0)
                        number("UpperLimit", \.upperLimit, 0...1000)
                    }
                case .rope:
                    number("Length", \.length, 0.1...1000)
                case .spring:
                    number("FreeLength", \.freeLength, 0.1...1000)
                    number("Stiffness", \.stiffness, 0...100_000)
                    number("Damping", \.damping, 0...10_000)
                case .ballSocket:
                    Text("Turns freely about the attachment point.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                case .beam, .trail:
                    RibbonSection(model: model, constraint: constraint)
                case .alignPosition:
                    LabeledRow("Mode") {
                        Picker("", selection: Binding(get: { constraint.alignMode }, set: { value in
                            model.commit("Set Mode") { model.updateConstraint(id: constraint.id) { $0.alignMode = value } }
                        })) {
                            ForEach(AlignMode.allCases) { Text($0 == .oneAttachment ? "One" : "Two").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    if constraint.alignMode == .oneAttachment {
                        VectorEditor(title: "Position", value: constraint.position) { axis, value in
                            model.commit("Set Position") { model.updateConstraint(id: constraint.id) { $0.position[axis] = value } }
                        }
                    }
                    number("MaxForce", \.maxForce, 0...1_000_000_000)
                    number("Responsiveness", \.responsiveness, 5...200)
                    Toggle("Limit speed (MaxVelocity)", isOn: Binding(get: { constraint.maxVelocity.isFinite }, set: { on in
                        model.commit("Set MaxVelocity") {
                            model.updateConstraint(id: constraint.id) { $0.maxVelocity = on ? 20 : .infinity }
                        }
                    }))
                    .toggleStyle(.checkbox)
                    if constraint.maxVelocity.isFinite { number("MaxVelocity", \.maxVelocity, 0...10_000) }
                    Toggle("RigidityEnabled", isOn: toggle(\.rigidityEnabled)).toggleStyle(.checkbox)
                    Text(constraint.alignMode == .oneAttachment
                         ? "Pulls Attachment0's part to Position, as hard as MaxForce lets it."
                         : "Pulls Attachment0's part to Attachment1, as hard as MaxForce lets it.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .vectorForce:
                    VectorEditor(title: "Force", value: constraint.force) { axis, value in
                        model.commit("Set Force") { model.updateConstraint(id: constraint.id) { $0.force[axis] = value } }
                    }
                    LabeledRow("RelativeTo") {
                        Picker("", selection: Binding(get: { constraint.relativeTo }, set: { value in
                            model.commit("Set RelativeTo") { model.updateConstraint(id: constraint.id) { $0.relativeTo = value } }
                        })) {
                            ForEach(ForceFrame.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Toggle("ApplyAtCenterOfMass", isOn: toggle(\.applyAtCenterOfMass)).toggleStyle(.checkbox)
                    Text("A push, all the time: equal to the part's mass × \(Int(CharacterController.gravity)) upwards, it floats.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .noCollision:
                    Text("The two parts pass through each other; everything else still collides with them.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .alignOrientation:
                    LabeledRow("Mode") {
                        Picker("", selection: Binding(get: { constraint.alignMode }, set: { value in
                            model.commit("Set Mode") { model.updateConstraint(id: constraint.id) { $0.alignMode = value } }
                        })) {
                            ForEach(AlignMode.allCases) { Text($0 == .oneAttachment ? "One" : "Two").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    if constraint.alignMode == .oneAttachment {
                        VectorEditor(title: "Orientation", value: constraint.cframe.orientation.eulerDegrees) { axis, value in
                            model.commit("Set CFrame") {
                                model.updateConstraint(id: constraint.id) { c in
                                    var degrees = c.cframe.orientation.eulerDegrees
                                    degrees[axis] = value
                                    c.cframe.orientation = .fromEulerDegrees(degrees)
                                }
                            }
                        }
                    }
                    number("MaxTorque", \.maxTorque, 0...1_000_000_000)
                    number("Responsiveness", \.responsiveness, 5...200)
                    Toggle("Limit spin (MaxAngularVelocity)", isOn: Binding(get: { constraint.maxAngularVelocity.isFinite }, set: { on in
                        model.commit("Set MaxAngularVelocity") {
                            model.updateConstraint(id: constraint.id) { $0.maxAngularVelocity = on ? 4 : .infinity }
                        }
                    }))
                    .toggleStyle(.checkbox)
                    if constraint.maxAngularVelocity.isFinite { number("MaxAngularVelocity", \.maxAngularVelocity, 0...1000) }
                    Toggle("RigidityEnabled", isOn: toggle(\.rigidityEnabled)).toggleStyle(.checkbox)
                    Toggle("PrimaryAxisOnly", isOn: toggle(\.primaryAxisOnly)).toggleStyle(.checkbox)
                    Text(constraint.alignMode == .oneAttachment
                         ? "Turns Attachment0's part to face as Orientation says, as hard as MaxTorque lets it."
                         : "Turns Attachment0's part to face as Attachment1 does, as hard as MaxTorque lets it.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .torque:
                    VectorEditor(title: "Torque", value: constraint.torque) { axis, value in
                        model.commit("Set Torque") { model.updateConstraint(id: constraint.id) { $0.torque[axis] = value } }
                    }
                    LabeledRow("RelativeTo") {
                        Picker("", selection: Binding(get: { constraint.relativeTo }, set: { value in
                            model.commit("Set RelativeTo") { model.updateConstraint(id: constraint.id) { $0.relativeTo = value } }
                        })) {
                            ForEach(ForceFrame.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Text("A twist, all the time, about the Torque's direction: the bigger it is, the harder.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .motor6d:
                    number("DesiredAngle", \.desiredAngle, -1000...1000)
                    number("MaxVelocity", \.maxVelocity, 0...10)
                    number("CurrentAngle", \.currentAngle, -1000...1000)
                    VectorEditor(title: "C0 Position", value: constraint.c0.position) { axis, value in
                        model.commit("Set C0") { model.updateConstraint(id: constraint.id) { $0.c0.position[axis] = value } }
                    }
                    VectorEditor(title: "C0 Orientation", value: constraint.c0.orientation.eulerDegrees) { axis, value in
                        model.commit("Set C0") {
                            model.updateConstraint(id: constraint.id) { c in
                                var degrees = c.c0.orientation.eulerDegrees
                                degrees[axis] = value
                                c.c0.orientation = .fromEulerDegrees(degrees)
                            }
                        }
                    }
                    Text("Holds Part1 to Part0 at C0. It turns about C0's Z axis towards DesiredAngle (radians), "
                         + "MaxVelocity radians a frame at most.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SmallButton("Delete", icon: "trash") { model.deleteConstraint(id: constraint.id) }
            }
            .padding(12)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder
    private func actuator(angular: Bool) -> some View {
        LabeledRow("Actuator") {
            Picker("", selection: Binding(get: { constraint.actuator }, set: { value in
                model.commit("Set actuator") { model.updateConstraint(id: constraint.id) { $0.actuator = value } }
            })) {
                ForEach(ActuatorType.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        switch constraint.actuator {
        case .none:
            EmptyView()
        case .motor:
            if angular {
                number("AngularVelocity", \.angularVelocity, -100...100)
                number("MotorMaxTorque", \.motorMaxTorque, 0...1_000_000)
            } else {
                number("Velocity", \.velocity, -500...500)
                number("MotorMaxForce", \.motorMaxForce, 0...1_000_000)
            }
        case .servo:
            if angular {
                number("TargetAngle", \.targetAngle, -180...180)
                number("AngularSpeed", \.angularSpeed, 0...100)
                number("ServoMaxTorque", \.servoMaxTorque, 0...1_000_000)
            } else {
                number("TargetPosition", \.targetPosition, -1000...1000)
                number("Speed", \.speed, 0...500)
                number("ServoMaxForce", \.servoMaxForce, 0...1_000_000)
            }
        }
    }

    private func binding(_ key: WritableKeyPath<SceneConstraint, String>) -> Binding<String> {
        Binding(get: { constraint[keyPath: key] }, set: { value in
            model.commit("Renamed joint") { model.updateConstraint(id: constraint.id) { $0[keyPath: key] = value } }
        })
    }

    private func toggle(_ key: WritableKeyPath<SceneConstraint, Bool>) -> Binding<Bool> {
        Binding(get: { constraint[keyPath: key] }, set: { value in
            model.commit("Changed joint") { model.updateConstraint(id: constraint.id) { $0[keyPath: key] = value } }
        })
    }

    private func number(_ label: String, _ key: WritableKeyPath<SceneConstraint, Float>,
                        _ range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            NumericField(label: "", tint: .clear, range: range, value: constraint[keyPath: key]) { value in
                model.commit("Set \(label)") { model.updateConstraint(id: constraint.id) { $0[keyPath: key] = value } }
            }
            .frame(width: 84)
        }
    }
}

/// Properties for an attachment: where it sits on its part and which way it points.
struct AttachmentInspector: View {
    @ObservedObject var model: SceneModel
    let attachment: SceneAttachment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "smallcircle.filled.circle")
                        .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.55))
                    Text("Attachment").font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                Text("On \(model.name(of: attachment.parentID) ?? "?")")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                VectorEditor(title: "Position (on the part)", value: attachment.position) { axis, value in
                    model.commit("Moved attachment") {
                        model.updateAttachment(id: attachment.id) { $0.position[axis] = value }
                    }
                }
                VectorEditor(title: "Axis", value: attachment.axis) { axis, value in
                    model.commit("Turned attachment") {
                        model.updateAttachment(id: attachment.id) { a in
                            var next = a.axis
                            next[axis] = value
                            a.setAxis(next)
                        }
                    }
                }
                Text("A hinge turns about the axis; a slider slides along it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let world = model.worldFrame(of: attachment) {
                    Text(String(format: "World: %.2f, %.2f, %.2f", world.position.x, world.position.y, world.position.z))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(12)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
        }
    }
}
