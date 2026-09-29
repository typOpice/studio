import SwiftUI

/// StarterGui drawn over the editor's viewport at the previewed screen's size — a
/// device's screen shrunk to fit, framed, or the viewport itself — and, with the GUI tab
/// open, edited there: see `GuiEditController`.
struct GuiPreviewArea: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var model: SceneModel
    @ObservedObject var editor: GuiEditController
    @ObservedObject var store: GuiStore

    var body: some View {
        GeometryReader { geometry in
            let editing = session.editingGui
            let layout = GuiPreviewGeometry(view: geometry.size, device: editor.device, canvas: editing ? editor.surfaceSize : nil)
            ZStack(alignment: .topLeading) {
                if editor.device != .window || (editing && editor.surfaceRoot != nil) {
                    DeviceFrame(layout: layout, view: geometry.size, dimmed: editing, title: editor.device.title)
                }
                GuiLayer(store: store, interactive: false, outlinesSelection: !editing, root: editing ? editor.surfaceRoot : nil)
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipped()
                    .scaleEffect(layout.scale, anchor: .topLeading)
                    .offset(x: layout.origin.x, y: layout.origin.y)
                    .allowsHitTesting(false)
                if editing {
                    GuiEditOverlay(editor: editor, store: store, model: model, layout: layout)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

/// A previewed device's screen: its outline and name, and the world around it darkened
/// while the GUI is being edited.
private struct DeviceFrame: View {
    let layout: GuiPreviewGeometry
    let view: CGSize
    let dimmed: Bool
    let title: String

    var body: some View {
        let rect = layout.frameInView
        ZStack(alignment: .topLeading) {
            if dimmed {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: view))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))
            }
            Rectangle()
                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                .frame(width: rect.width + 2, height: rect.height + 2)
                .offset(x: rect.minX - 1, y: rect.minY - 1)
            Text("\(title) · \(Int(layout.screen.width)) × \(Int(layout.screen.height)) · \(Int((layout.scale * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                .offset(x: rect.minX, y: max(rect.minY - 22, 2))
        }
        .allowsHitTesting(false)
    }
}

/// The GUI tab's layer over the preview: the object under the pointer outlined, the
/// selected one with its handles and size, the guides a drag snaps to — and the presses,
/// which it takes only on GUI objects, so everywhere else still reaches the world.
private struct GuiEditOverlay: View {
    @ObservedObject var editor: GuiEditController
    @ObservedObject var store: GuiStore
    @ObservedObject var model: SceneModel
    let layout: GuiPreviewGeometry
    @State private var pressing = false

    var body: some View {
        let placed = editor.surfaceRoot.map { store.layout(root: $0, in: layout.screen) } ?? store.layout(in: layout.screen)
        let selected = editor.selectedCopy
        let chosen = placed.first { $0.id == selected }
        let hovering = placed.first { $0.id == editor.hovered && $0.id != selected }
        ZStack(alignment: .topLeading) {
            // One see-through target per GUI object and handle, and nothing else: the
            // press and the pointer are taken only there, so everywhere else reaches the
            // world. (Hover tracking claims its view's whole frame, so each target has
            // its own rather than one layer over everything.)
            ZStack(alignment: .topLeading) {
                ForEach(Array(targets(placed, chosen).enumerated()), id: \.offset) { _, rect in
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .offset(x: rect.minX, y: rect.minY)
                        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                            editor.viewScale = layout.scale
                            switch phase {
                            case .active(let point): editor.hover(at: layout.toScreen(point))
                            case .ended: editor.hover(at: nil)
                            }
                        }
                }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    editor.viewScale = layout.scale
                    if !pressing {
                        pressing = true
                        editor.begin(at: layout.toScreen(value.startLocation))
                    }
                    editor.drag(to: layout.toScreen(value.location))
                }
                .onEnded { _ in
                    pressing = false
                    editor.end()
                })
            Group {
                if let hovering {
                    let rect = layout.toView(GuiEditController.visible(hovering))
                    Rectangle()
                        .stroke(Theme.accent.opacity(0.7), lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                if let chosen { selection(chosen) }
                ForEach(editor.shownGuides.indices, id: \.self) { index in
                    guideLine(editor.shownGuides[index])
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private static let space = "guiEditOverlay"

    /// Where presses are taken: on what's drawn, and on the selection's handles.
    private func targets(_ placed: [GuiStore.Placed], _ chosen: GuiStore.Placed?) -> [CGRect] {
        var rects = placed.filter { !$0.object.kind.isModifier }.map { layout.toView(GuiEditController.visible($0)) }
        if let chosen, editor.canResize(chosen.id) {
            let frame = layout.toView(chosen.frame)
            rects += GuiEditController.Handle.allCases.map { handle in
                let spot = handle.point(in: frame)
                return CGRect(x: spot.x - 7, y: spot.y - 7, width: 14, height: 14)
            }
        }
        return rects
    }

    @ViewBuilder private func selection(_ chosen: GuiStore.Placed) -> some View {
        let rect = layout.toView(chosen.frame)
        let arranged = editor.arrangingLayout(of: chosen.id)
        Rectangle()
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: arranged == nil ? [] : [4, 3]))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        if editor.canResize(chosen.id) {
            ForEach(GuiEditController.Handle.allCases, id: \.self) { handle in
                let spot = handle.point(in: rect)
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .offset(x: spot.x - 3.5, y: spot.y - 3.5)
            }
        }
        let note = arranged.map { "placed by \($0.kind.rawValue)" }
            ?? "\(Int(chosen.frame.width.rounded())) × \(Int(chosen.frame.height.rounded()))"
        Text(note)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(SwiftUI.Capsule().fill(Theme.accent))
            .fixedSize()
            .frame(width: max(rect.width, 1), alignment: .center)
            .offset(x: rect.minX, y: rect.maxY + 6)
    }

    private func guideLine(_ guide: GuiEditController.Guide) -> some View {
        let start = layout.toView(guide.vertical ? CGPoint(x: guide.at, y: guide.from) : CGPoint(x: guide.from, y: guide.at))
        let end = layout.toView(guide.vertical ? CGPoint(x: guide.at, y: guide.to) : CGPoint(x: guide.to, y: guide.at))
        return Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color(red: 1, green: 0.3, blue: 0.75), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
    }
}
