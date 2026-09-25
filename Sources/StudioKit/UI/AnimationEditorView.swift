import SwiftUI
import simd

/// The Animation tab: a timeline of keys per joint, a playhead, preview playback and
/// an inspector for the selected joint. The rig it poses stands in the viewport —
/// click a body part there to select its joint and drag to pose it.
struct AnimationEditorView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @ObservedObject var editor: AnimationEditor

    var body: some View {
        Group {
            if session.isPlaying {
                note("Stop the play test to edit animations",
                     detail: "Scripts play them with humanoid:LoadAnimation(Animations.Name):Play()")
            } else if let animation = editor.animation {
                VStack(spacing: 0) {
                    toolbar(animation)
                    HStack(spacing: 0) {
                        KeyframeTimeline(animation: animation, editor: editor, model: model)
                        Rectangle().fill(Theme.stroke).frame(width: 1)
                        JointInspector(animation: animation, editor: editor, model: model)
                            .frame(width: 250)
                    }
                }
            } else {
                emptyState
            }
        }
        .onAppear {
            editor.isOpen = true
            if editor.rigPosition == nil { session.viewport.showRig() }
        }
        .onDisappear {
            editor.isOpen = false
            editor.playing = false
        }
        .onChange(of: model.selectedAnimation) { _ in
            editor.playing = false
            editor.time = 0
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.system(size: 24))
                .foregroundStyle(Theme.textDim.opacity(0.6))
            Text("No animation selected")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            HStack(spacing: 8) {
                SmallButton("New Animation", icon: "plus") { model.addAnimation() }
                SmallButton("Example: Wave", icon: "hand.wave") { model.addAnimation(.waveExample()) }
            }
            if !model.animations.isEmpty {
                Menu("Open…") {
                    ForEach(model.animations) { animation in
                        Button(animation.name) { model.selectedAnimation = animation.id }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func note(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textDim.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbar(_ animation: AnimationObject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.45))
            Text(animation.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)

            Button { editor.setTime(0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.plain)
                .help("Go to the start")
            Button { editor.togglePlaying() } label: {
                Image(systemName: editor.playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .help("Preview")

            Text(String(format: "%.2f / %.2f s", editor.time, animation.length))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 96, alignment: .leading)

            Rectangle().fill(Theme.stroke).frame(width: 1, height: 14)

            Text("Length").font(.system(size: 10)).foregroundStyle(Theme.textDim)
            NumericField(label: "", tint: .clear,
                         range: AnimationObject.minimumLength...AnimationObject.maximumLength,
                         value: animation.length) { value in
                model.editAnimation(animation.id, "Set length") { $0.setLength(value) }
                editor.setTime(editor.time)
            }
            .frame(width: 58)

            Toggle("Looped", isOn: Binding(get: { animation.looped }, set: { value in
                model.editAnimation(animation.id, value ? "Looped" : "Not looped") { $0.looped = value }
            }))
            .toggleStyle(.checkbox)

            Picker("", selection: Binding(get: { animation.priority }, set: { value in
                model.editAnimation(animation.id, "Set priority") { $0.priority = value }
            })) {
                ForEach(AnimationPriority.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 96)
            .help("Priority: a higher one overrides a lower one, and the walk, jump and fall are Core")

            Toggle("Snap", isOn: $editor.snap)
                .toggleStyle(.checkbox)
                .help("Snap to 1/30 s frames")

            Spacer()

            Menu {
                Button("Frame Rig") { session.viewport.showRig() }
                Button("Move Rig to View Centre") { session.viewport.showRig(reposition: true) }
            } label: {
                Image(systemName: "figure.stand")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("The rig in the viewport: click a body part to select it, drag to pose")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.panelAlt.opacity(0.5))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }
}

/// Keys as diamonds on one row per joint, a row of markers, a ruler and the playhead.
/// Click or drag anywhere to move the playhead; drag a diamond to move that key.
struct KeyframeTimeline: View {
    let animation: AnimationObject
    @ObservedObject var editor: AnimationEditor
    let model: SceneModel

    static let rowHeight: CGFloat = 22
    static let rulerHeight: CGFloat = 20
    static let labelWidth: CGFloat = 128
    static let inset: CGFloat = 10

    @State private var movingKey: (joint: AnimationJoint, from: Float)?
    @State private var movingTo: Float?

    private var rows: [AnimationJoint] { AnimationJoint.allCases }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.rulerHeight)
                rowLabel("Markers", icon: "flag.fill", selected: false, keyed: false) {}
                ForEach(rows) { joint in
                    rowLabel(joint.rawValue, icon: nil, selected: editor.selectedJoint == joint,
                             keyed: editor.hasKey(joint)) {
                        editor.selectedJoint = joint
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.labelWidth)
            .background(Theme.panelAlt.opacity(0.35))

            GeometryReader { geometry in
                let width = max(geometry.size.width - Self.inset * 2, 1)
                ZStack(alignment: .topLeading) {
                    rowBackgrounds(width: geometry.size.width)
                    ruler(width: width)
                    markers(width: width)
                    ForEach(rows) { joint in
                        ForEach(animation.keys(for: joint)) { key in
                            diamond(joint: joint, key: key, width: width)
                        }
                    }
                    playhead(width: width, height: geometry.size.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    editor.playing = false
                    editor.setTime(time(at: value.location.x, width: width))
                    if let joint = joint(at: value.startLocation.y) { editor.selectedJoint = joint }
                })
            }
            .clipped()
        }
        .font(.system(size: 10))
    }

    // MARK: - Geometry

    private func x(_ time: Float, width: CGFloat) -> CGFloat {
        Self.inset + CGFloat(time / max(animation.length, 1e-3)) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Float {
        Float((x - Self.inset) / width) * animation.length
    }

    private func rowY(_ index: Int) -> CGFloat {
        Self.rulerHeight + Self.rowHeight * CGFloat(index) + Self.rowHeight / 2
    }

    private func joint(at y: CGFloat) -> AnimationJoint? {
        let index = Int((y - Self.rulerHeight) / Self.rowHeight) - 1
        return rows.indices.contains(index) ? rows[index] : nil
    }

    // MARK: - Pieces

    private func rowLabel(_ title: String, icon: String?, selected: Bool, keyed: Bool,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8)).foregroundStyle(Theme.textDim)
            } else {
                Circle()
                    .fill(keyed ? Color(red: 0.98, green: 0.78, blue: 0.3) : Theme.textDim.opacity(0.3))
                    .frame(width: 5, height: 5)
                    .help(keyed ? "Keyed at the playhead" : "Not keyed at the playhead")
            }
            Text(title)
                .foregroundStyle(selected ? Theme.text : Theme.textDim)
                .fontWeight(selected ? .semibold : .regular)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(selected ? Theme.accent.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func rowBackgrounds(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.rulerHeight)
            ForEach(0...rows.count, id: \.self) { index in
                let joint = index == 0 ? nil : rows[index - 1]
                Rectangle()
                    .fill(joint != nil && joint == editor.selectedJoint ? Theme.accent.opacity(0.12)
                          : (index % 2 == 0 ? Color.white.opacity(0.02) : Color.clear))
                    .frame(height: Self.rowHeight)
            }
        }
        .frame(width: width, alignment: .top)
    }

    private func ruler(width: CGFloat) -> some View {
        let length = animation.length
        let (tick, label): (Float, Float) = length > 8 ? (0.5, 2) : length > 3 ? (0.25, 1) : (0.1, 0.5)
        return Canvas { context, size in
            var t: Float = 0
            while t <= length + 1e-4 {
                let px = x(t, width: width)
                let major = abs((t / label).rounded() * label - t) < 1e-3
                var path = Path()
                path.move(to: CGPoint(x: px, y: major ? 8 : 13))
                path.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(path, with: .color(.white.opacity(major ? 0.14 : 0.06)), lineWidth: 1)
                if major {
                    context.draw(Text(String(format: "%.1f", t)).font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(Theme.textDim),
                                 at: CGPoint(x: px + 2, y: 6), anchor: .leading)
                }
                t += tick
            }
        }
        .allowsHitTesting(false)
    }

    private func markers(width: CGFloat) -> some View {
        ForEach(animation.markers) { marker in
            HStack(spacing: 2) {
                Image(systemName: "flag.fill").font(.system(size: 8))
                Text(marker.name).font(.system(size: 8))
            }
            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.55))
            .fixedSize()
            .position(x: x(marker.time, width: width) + 4, y: rowY(0))
            .offset(x: 16)
            .onTapGesture { editor.setTime(marker.time) }
            .contextMenu {
                Button("Delete Marker \"\(marker.name)\"") {
                    model.editAnimation(animation.id, "Deleted marker") { anim in
                        anim.markers.removeAll { $0.id == marker.id }
                    }
                }
            }
            .help("Marker \"\(marker.name)\" at \(String(format: "%.2f", marker.time)) s")
        }
    }

    private func diamond(joint: AnimationJoint, key: JointKey, width: CGFloat) -> some View {
        let row = rows.firstIndex(of: joint)! + 1
        let moving = movingKey?.joint == joint && movingKey.map { abs($0.from - key.time) < 1e-4 } == true
        let shownTime = moving ? (movingTo ?? key.time) : key.time
        let atPlayhead = abs(key.time - editor.time) < AnimationObject.timeTolerance
        return Rectangle()
            .fill(atPlayhead ? Color(red: 0.98, green: 0.78, blue: 0.3) : Color(red: 0.82, green: 0.84, blue: 0.9))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 1)
                        .frame(width: 8, height: 8).rotationEffect(.degrees(45)))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .position(x: x(shownTime, width: width), y: rowY(row))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    editor.playing = false
                    editor.selectedJoint = joint
                    if abs(value.translation.width) > 3 || movingKey != nil {
                        movingKey = (joint, key.time)
                        let raw = key.time + Float(value.translation.width / width) * animation.length
                        movingTo = min(max(editor.snapped(raw), 0), animation.length)
                    }
                }
                .onEnded { _ in
                    if let from = movingKey?.from, let to = movingTo, abs(to - from) > 1e-4 {
                        model.editAnimation(animation.id, "Moved key") { $0.moveKey(joint, from: from, to: to) }
                        editor.setTime(to)
                    } else {
                        editor.setTime(key.time)
                    }
                    movingKey = nil
                    movingTo = nil
                })
            .contextMenu {
                Button("Delete Key") {
                    model.editAnimation(animation.id, "Deleted key") { $0.removeKey(joint, at: key.time) }
                }
                Menu("Easing") {
                    ForEach(AnimationEasing.allCases) { easing in
                        Button(easing.rawValue + (key.easing == easing ? " ✓" : "")) {
                            model.editAnimation(animation.id, "Set easing") { $0.setEasing(joint, at: key.time, easing) }
                        }
                    }
                }
            }
            .help("\(joint.rawValue) at \(String(format: "%.2f", key.time)) s · \(key.easing.rawValue) · drag to move")
    }

    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        let px = x(editor.time, width: width)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color(red: 0.95, green: 0.38, blue: 0.35)).frame(width: 1.5, height: height)
            Rectangle().fill(Color(red: 0.95, green: 0.38, blue: 0.35))
                .frame(width: 9, height: 9).rotationEffect(.degrees(45)).offset(y: 4)
        }
        .position(x: px, y: height / 2)
        .allowsHitTesting(false)
    }
}

/// The selected joint at the playhead: its rotation (and the root's offset), the easing
/// of its key there, and tools for keys and markers.
struct JointInspector: View {
    let animation: AnimationObject
    @ObservedObject var editor: AnimationEditor
    let model: SceneModel

    @State private var markerName = "Marker"

    var body: some View {
        ScrollView { content }
    }

    /// Everything but the scrolling, so `--render-panel inspector` can draw it.
    var content: some View {
            VStack(alignment: .leading, spacing: 9) {
                if let joint = editor.selectedJoint {
                    jointSection(joint)
                } else {
                    Text("Select a joint — click a body part on the rig, or a row in the timeline")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                }
                Divider().overlay(Theme.stroke)
                markerSection
            }
            .padding(10)
            .font(.system(size: 10))
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private func jointSection(_ joint: AnimationJoint) -> some View {
        let keyed = editor.hasKey(joint)
        VStack(alignment: .leading, spacing: 2) {
            Text(joint.rawValue).font(.system(size: 11, weight: .semibold))
            Text(keyed ? String(format: "Key at %.2f s", editor.time) : "No key here — changing it adds one")
                .foregroundStyle(keyed ? Color(red: 0.98, green: 0.78, blue: 0.3) : Theme.textDim)
        }

        let rotation = editor.rotation(of: joint)
        ForEach(0..<3, id: \.self) { axis in
            angleRow(["X", "Y", "Z"][axis], value: rotation[axis],
                     help: ["swing forward / back", "twist", "raise sideways"][axis]) { value in
                var next = editor.rotation(of: joint)
                next[axis] = value
                editor.setPose(joint, rotation: next)
            }
        }

        if joint.hasPosition {
            let position = editor.position(of: joint)
            VectorEditor(title: "Offset (studs)", value: position) { axis, value in
                var next = editor.position(of: joint)
                next[axis] = min(max(value, -10), 10)
                model.commit("Moved root") { editor.setPose(joint, position: next) }
            }
        }

        if keyed, let index = animation.keyIndex(for: joint, at: editor.time) {
            LabeledRow("Easing") {
                Picker("", selection: Binding(get: { animation.keys(for: joint)[index].easing }, set: { easing in
                    let at = editor.time
                    model.editAnimation(animation.id, "Set easing") { $0.setEasing(joint, at: at, easing) }
                })) {
                    ForEach(AnimationEasing.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .help("How this key eases into the next one")
        }

        HStack(spacing: 5) {
            SmallButton(keyed ? "Re-key" : "Add Key", icon: "diamond.fill") {
                model.commit("Added key") { editor.setPose(joint) }
            }
            .help("Key the pose the joint has at the playhead")
            if keyed {
                SmallButton("Delete", icon: "trash") {
                    let at = editor.time
                    model.editAnimation(animation.id, "Deleted key") { $0.removeKey(joint, at: at) }
                }
            }
        }
        HStack(spacing: 5) {
            if joint.mirrored != joint {
                SmallButton("Mirror to \(joint.mirrored.rawValue)", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    model.editAnimation(animation.id, "Mirrored \(joint.rawValue)") { $0.mirror(joint) }
                }
                .help("Copies every key of this joint to the other side, flipped")
            }
            SmallButton("Clear", icon: "xmark") {
                model.editAnimation(animation.id, "Cleared \(joint.rawValue)") { $0.keys[joint.rawValue] = nil }
            }
            .help("Removes every key of this joint")
        }
    }

    private func angleRow(_ axis: String, value: Float, help: String,
                          set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(axis)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle([Color(red: 0.94, green: 0.40, blue: 0.42),
                                  Color(red: 0.52, green: 0.85, blue: 0.45),
                                  Color(red: 0.42, green: 0.64, blue: 0.96)][["X", "Y", "Z"].firstIndex(of: axis)!])
                .frame(width: 10)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0).rounded()) }),
                   in: -180...180) { editing in
                if editing { model.beginStroke() } else { model.endStroke() }
            }
            .controlSize(.mini)
            NumericField(label: "", tint: .clear, range: -180...180, value: value) { newValue in
                model.commit("Posed joint") { set(newValue) }
            }
            .frame(width: 50)
        }
        .help("\(axis): \(help), in degrees")
    }

    private var markerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MARKERS")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.textDim)
            HStack(spacing: 5) {
                TextField("Name", text: $markerName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                SmallButton("Add at playhead", icon: "flag") {
                    let name = markerName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let at = editor.time
                    model.editAnimation(animation.id, "Added marker") { anim in
                        anim.markers.append(AnimationMarker(time: at, name: name))
                        anim.markers.sort { $0.time < $1.time }
                    }
                }
            }
            Text("Reaching one fires KeyframeReached and GetMarkerReachedSignal(name)")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
