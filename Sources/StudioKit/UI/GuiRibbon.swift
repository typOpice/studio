import SwiftUI

/// The ribbon's GUI tab: making StarterGui — insert objects and modifiers where the
/// selection says, line them up, switch units, and preview it at a device's size.
struct GuiRibbonGroups: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @ObservedObject var editor: GuiEditController

    private static let bigInserts: [GuiObject.Kind] = [.screenGui, .frame, .textLabel, .textButton, .imageLabel]
    private static let smallInserts: [GuiObject.Kind] = [.textBox, .imageButton, .scrollingFrame, .surfaceGui]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                RibbonGroup("Insert") {
                    ForEach(Self.bigInserts, id: \.self) { kind in
                        RibbonButton(title: kind.shortName, icon: kind.symbolName, enabled: canInsert(kind)) { insert(kind) }
                            .help(insertHelp(kind))
                    }
                    VStack(spacing: 2) {
                        ForEach(Self.smallInserts, id: \.self) { kind in
                            RibbonSmallButton(title: kind.shortName, icon: kind.symbolName, enabled: canInsert(kind),
                                              width: 104) {
                                insert(kind)
                            }
                            .help(insertHelp(kind))
                        }
                    }
                }
                RibbonDivider()
                RibbonGroup("Modifiers") {
                    let kinds = GuiObject.Kind.insertableModifiers
                    ForEach(0..<3, id: \.self) { column in
                        VStack(spacing: 2) {
                            ForEach(kinds[(column * 3)..<min(column * 3 + 3, kinds.count)], id: \.self) { kind in
                                RibbonSmallButton(title: kind.shortName, icon: kind.symbolName,
                                                  active: has(kind), enabled: canInsert(kind)) { insert(kind) }
                                    .help("\(kind.rawValue) in the selected object")
                            }
                        }
                    }
                }
                RibbonDivider()
                RibbonGroup("Arrange") {
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            align(.left, "align.horizontal.left", "Left edge")
                            align(.centerX, "align.horizontal.center", "Centre across")
                            align(.right, "align.horizontal.right", "Right edge")
                        }
                        HStack(spacing: 2) {
                            align(.top, "align.vertical.top", "Top edge")
                            align(.centerY, "align.vertical.center", "Centre down")
                            align(.bottom, "align.vertical.bottom", "Bottom edge")
                        }
                        RibbonSmallButton(title: "Fill", icon: "arrow.up.left.and.arrow.down.right",
                                          enabled: editable && editor.selectionMovable, width: 80) { editor.fill() }
                            .help("Fill the parent: Size {1, 0}, {1, 0}")
                    }
                    VStack(spacing: 2) {
                        RibbonSmallButton(title: "Front", icon: "square.2.layers.3d.top.filled",
                                          enabled: editable && editor.selectionDrawn) { editor.reorder(toFront: true) }
                            .help("In front of its siblings (ZIndex)")
                        RibbonSmallButton(title: "Back", icon: "square.2.layers.3d.bottom.filled",
                                          enabled: editable && editor.selectionDrawn) { editor.reorder(toFront: false) }
                            .help("Behind its siblings (ZIndex)")
                        RibbonSmallButton(title: "Duplicate", icon: "plus.square.on.square",
                                          enabled: editable && model.selectedGui != nil) { editor.duplicate() }
                            .help("A copy, with what's inside it (⌘D)")
                    }
                    VStack(spacing: 2) {
                        RibbonSmallButton(title: "Delete", icon: "trash", enabled: editable && model.selectedGui != nil) {
                            editor.delete()
                        }
                        .help("Delete it and what's inside it (⌫)")
                    }
                }
                RibbonDivider()
                RibbonGroup("Units") {
                    VStack(spacing: 2) {
                        RibbonSmallButton(title: "To Scale", icon: "percent", enabled: editable && editor.selectionDrawn) {
                            editor.convert(toScale: true)
                        }
                        .help("Position and Size as shares of the parent: the same on every screen")
                        RibbonSmallButton(title: "To Pixels", icon: "number", enabled: editable && editor.selectionDrawn) {
                            editor.convert(toScale: false)
                        }
                        .help("Position and Size in pixels: the same size on every screen")
                    }
                }
                RibbonDivider()
                RibbonGroup("Preview") {
                    VStack(alignment: .leading, spacing: 3) {
                        labelled("Screen") {
                            Picker("", selection: $editor.device) {
                                ForEach(GuiDevice.allCases) { device in Text(device.title).tag(device) }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 124)
                        }
                        labelled("Grid") {
                            Picker("", selection: $editor.grid) {
                                Text("Off").tag(CGFloat(0))
                                ForEach([1, 4, 8, 16] as [CGFloat], id: \.self) { step in Text("\(Int(step)) px").tag(step) }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 124)
                        }
                        HStack(spacing: 10) {
                            Toggle("Guides", isOn: $editor.guides)
                            Toggle("Show", isOn: $session.showsGuiPreview)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }

    private var editable: Bool { !session.isPlaying }

    private func canInsert(_ kind: GuiObject.Kind) -> Bool { editable && model.guiInsertTarget(for: kind) != nil }

    /// Whether the selection already has this modifier (the button then selects it).
    private func has(_ kind: GuiObject.Kind) -> Bool {
        guard let target = model.guiInsertTarget(for: kind)?.parent else { return false }
        return model.guiChildren(of: target).contains { $0.kind == kind }
    }

    private func insert(_ kind: GuiObject.Kind) {
        editor.insert(kind)
        if !session.showsWorld { session.showWorld() }
    }

    private func insertHelp(_ kind: GuiObject.Kind) -> String {
        switch model.guiInsertTarget(for: kind) {
        case nil: return kind.rawValue
        case let target?:
            if target.needsScreen { return "\(kind.rawValue), in a new ScreenGui" }
            guard let parent = target.parent.flatMap(model.guiObject(id:)) else { return kind.rawValue }
            return "\(kind.rawValue) in \(parent.name)"
        }
    }

    private func align(_ alignment: GuiAlignment, _ icon: String, _ help: String) -> some View {
        Button { editor.align(alignment) } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panelAlt))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(editable && editor.selectionMovable ? Theme.text : Theme.textDim.opacity(0.5))
        .disabled(!(editable && editor.selectionMovable))
        .help("Align: \(help) of the parent")
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
                .frame(width: 34, alignment: .leading)
            content()
        }
    }

}

/// A group of ribbon controls under a small title.
struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textDim.opacity(0.8))
            HStack(alignment: .top, spacing: 5) { content }
        }
    }
}

struct RibbonDivider: View {
    var body: some View {
        Rectangle().frame(width: 1, height: 44).foregroundStyle(Theme.stroke)
    }
}

/// A slim ribbon button, three to a column: an icon and a word.
struct RibbonSmallButton: View {
    let title: String
    let icon: String
    var active = false
    var enabled = true
    var width: CGFloat = 92
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).frame(width: 14)
                Text(title).font(.system(size: 10)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(width: width, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(active ? Theme.accent.opacity(0.45) : Theme.panelAlt))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text : Theme.textDim.opacity(0.5))
        .disabled(!enabled)
    }
}

extension EditorSession {
    /// What to do next in the GUI tab, shown over the view in place of the camera keys.
    var guiHint: String? {
        guard editingGui else { return nil }
        guard let selected = guiEditor.selectedTemplate else {
            return model.starterGui.isEmpty ? "GUI: insert a Frame, Text or Button from the ribbon — it goes in a new ScreenGui"
                                            : "GUI: click an object to select it · right-drag still turns the camera"
        }
        if selected.kind.isModifier { return "GUI: set up the \(selected.kind.rawValue) in Properties" }
        if selected.kind.isLayer { return "GUI: insert objects into \(selected.name), or click one to select it" }
        return "GUI: drag to move · handles resize · arrows nudge (⇧ 10 px) · ⌘D duplicate · ⌫ delete · Esc lets go"
    }
}
