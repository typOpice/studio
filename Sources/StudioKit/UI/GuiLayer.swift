import SwiftUI

/// A player's screen GUI, drawn over the game: what the scripts made with ScreenGui,
/// BillboardGui, Frame, ScrollingFrame, TextLabel, TextButton, TextBox and ImageLabel.
/// Buttons and boxes take clicks; everything else lets them through to the game (the
/// scroll wheel over a ScrollingFrame is the viewport's to route, see
/// `StudioMTKView.scrollWheel`). BillboardGuis follow the world, so while there are any
/// the layer redraws every frame.
struct GuiLayer: View {
    @ObservedObject var store: GuiStore
    /// False for Studio's preview of StarterGui: seen, but never in the way of the editor.
    var interactive = true
    /// Whether the object Studio has selected is outlined; the GUI tab draws its own handles.
    var outlinesSelection = true

    var body: some View {
        if store.hasBillboards {
            TimelineView(.animation) { _ in content }
        } else {
            content
        }
    }

    private var content: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(store.layout(in: geometry.size)) { placed in
                    GuiElement(placed: placed, focused: store.focused == placed.id, cursor: store.cursor,
                               selectedAll: store.selectedAll, image: image(for: placed.object),
                               highlighted: outlinesSelection && store.highlighted == placed.id) {
                        store.click(placed.id)
                    }
                    .allowsHitTesting(interactive && placed.object.kind.isInteractive)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func image(for object: GuiObject) -> NSImage? {
        guard object.kind.showsImage, !object.image.isEmpty else { return nil }
        return store.imageProvider?(object.image)
    }
}

private struct GuiElement: View {
    let placed: GuiStore.Placed
    let focused: Bool
    let cursor: Int
    let selectedAll: Bool
    let image: NSImage?
    /// Selected in Studio: outlined.
    var highlighted = false
    let click: () -> Void

    private var object: GuiObject { placed.object }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: alignment) {
                if object.backgroundTransparency < 1 {
                    RoundedRectangle(cornerRadius: placed.cornerRadius).fill(background)
                }
                if let image, object.imageTransparency < 1 {
                    tinted(picture(image))
                        .clipShape(RoundedRectangle(cornerRadius: placed.cornerRadius))
                }
                if object.kind.showsText {
                    label
                        .padding(.horizontal, object.textXAlignment == "Center" ? 0 : 2)
                        .padding(padding)
                }
                if let bar = placed.scrollBar {
                    RoundedRectangle(cornerRadius: bar.width / 2)
                        .fill(Color.white.opacity(0.35))
                        .frame(width: max(bar.width - 4, 2), height: bar.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .offset(x: bar.minX - placed.frame.minX + 2, y: bar.minY - placed.frame.minY)
                }
            }
            .frame(width: placed.frame.width, height: placed.frame.height, alignment: alignment)
            .clipped()
            // A UIStroke round the border sits outside it, as in Roblox.
            if let stroke = borderStroke {
                let thickness = CGFloat(stroke.strokeThickness)
                RoundedRectangle(cornerRadius: placed.cornerRadius > 0 ? placed.cornerRadius + thickness / 2 : 0)
                    .stroke(Color(vec: stroke.strokeColor).opacity(Double(1 - stroke.strokeTransparency)),
                            style: StrokeStyle(lineWidth: thickness, lineJoin: Self.join(stroke.lineJoinMode)))
                    .frame(width: placed.frame.width + thickness, height: placed.frame.height + thickness)
                    .offset(x: -thickness / 2, y: -thickness / 2)
            }
            if highlighted {
                RoundedRectangle(cornerRadius: placed.cornerRadius)
                    .stroke(Theme.accent, lineWidth: 2)
                    .frame(width: placed.frame.width, height: placed.frame.height)
            }
        }
        .frame(width: placed.frame.width, height: placed.frame.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .modifier(ClipToAncestor(frame: placed.frame, clip: placed.clip, margin: CGFloat(borderStroke?.strokeThickness ?? 0)))
        .offset(x: placed.frame.minX, y: placed.frame.minY)
    }

    /// Cuts the element off at a clipping ancestor's edge, if it's inside one.
    private struct ClipToAncestor: ViewModifier {
        let frame: CGRect
        let clip: CGRect?
        let margin: CGFloat

        func body(content: Content) -> some View {
            if let clip {
                let visible = clip.intersection(frame.insetBy(dx: -margin, dy: -margin))
                content.mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: max(visible.width, 0), height: max(visible.height, 0))
                        .offset(x: visible.minX - frame.minX, y: visible.minY - frame.minY)
                }
            } else {
                content
            }
        }
    }

    /// The UIStroke drawn round the border: Border mode, or Contextual on anything but text.
    private var borderStroke: GuiObject? {
        guard let stroke = placed.stroke, stroke.strokeThickness > 0, stroke.strokeTransparency < 1 else { return nil }
        return stroke.applyStrokeMode == "Border" || !object.kind.showsText ? stroke : nil
    }

    /// The outline round the text: a Contextual UIStroke's, or TextStroke's.
    private var textStroke: (color: Color, width: CGFloat)? {
        if let stroke = placed.stroke, stroke.applyStrokeMode == "Contextual", object.kind.showsText,
           stroke.strokeThickness > 0, stroke.strokeTransparency < 1 {
            return (Color(vec: stroke.strokeColor).opacity(Double(1 - stroke.strokeTransparency)),
                    CGFloat(stroke.strokeThickness))
        }
        guard object.textStrokeTransparency < 1 else { return nil }
        return (Color(vec: object.textStrokeColor).opacity(Double(1 - object.textStrokeTransparency)), 1)
    }

    private static func join(_ mode: String) -> CGLineJoin {
        mode == "Miter" ? .miter : mode == "Bevel" ? .bevel : .round
    }

    // MARK: - UIGradient

    /// A colour, or the colour through the UIGradient, faded by a transparency.
    private func style(_ colour: Vec3, transparency: Float) -> AnyShapeStyle {
        guard let gradient = placed.gradient else {
            return AnyShapeStyle(Color(vec: colour).opacity(Double(1 - transparency)))
        }
        return AnyShapeStyle(linear(gradient) { time in
            let tint = GuiObject.sample(gradient.gradientColor, at: time)
            let fade = GuiObject.sample(gradient.gradientTransparency, at: time)
            return Color(vec: colour * tint).opacity(Double((1 - transparency) * (1 - fade)))
        })
    }

    private var background: AnyShapeStyle { style(object.backgroundColor, transparency: object.backgroundTransparency) }

    /// The gradient's line across the element: Rotation turns it, Offset moves it.
    private func linear(_ gradient: GuiObject, colour: (Float) -> Color) -> LinearGradient {
        var times = Set(gradient.gradientColor.map(\.time)).union(gradient.gradientTransparency.map(\.x)).sorted()
        if times.count < 2 { times = [0, 1] }
        let angle = Double(gradient.rotation) * .pi / 180
        let dx = cos(angle) / 2, dy = sin(angle) / 2
        let ox = Double(gradient.gradientOffset.x), oy = Double(gradient.gradientOffset.y)
        return LinearGradient(stops: times.map { Gradient.Stop(color: colour($0), location: CGFloat($0)) },
                              startPoint: UnitPoint(x: 0.5 - dx + ox, y: 0.5 - dy + oy),
                              endPoint: UnitPoint(x: 0.5 + dx + ox, y: 0.5 + dy + oy))
    }

    /// A picture through the UIGradient: its colours multiplied, its transparency faded.
    @ViewBuilder private func tinted(_ picture: some View) -> some View {
        if let gradient = placed.gradient {
            picture
                .overlay(linear(gradient) { Color(vec: GuiObject.sample(gradient.gradientColor, at: $0)) }
                    .blendMode(.multiply))
                .compositingGroup()
                .mask { picture }
                .mask { linear(gradient) { Color.white.opacity(Double(1 - GuiObject.sample(gradient.gradientTransparency, at: $0))) } }
        } else {
            picture
        }
    }

    @ViewBuilder private func picture(_ image: NSImage) -> some View {
        let tinted = Image(nsImage: image).resizable()
        Group {
            switch object.scaleType {
            case "Fit": tinted.aspectRatio(contentMode: .fit)
            case "Crop": tinted.aspectRatio(contentMode: .fill)
            default: tinted
            }
        }
        .frame(width: placed.frame.width, height: placed.frame.height)
        .colorMultiply(Color(vec: object.imageColor))
        .opacity(Double(1 - object.imageTransparency))
    }

    /// Where the text keeps in from the edges: its UIPadding, if it has one.
    private var padding: EdgeInsets {
        let frame = placed.frame, content = placed.content
        return EdgeInsets(top: content.minY - frame.minY, leading: content.minX - frame.minX,
                          bottom: frame.maxY - content.maxY, trailing: frame.maxX - content.maxX)
    }

    private var alignment: Alignment {
        let vertical: VerticalAlignment = object.textYAlignment == "Top" ? .top
            : object.textYAlignment == "Bottom" ? .bottom : .center
        switch object.textXAlignment {
        case "Left": return Alignment(horizontal: .leading, vertical: vertical)
        case "Right": return Alignment(horizontal: .trailing, vertical: vertical)
        default: return Alignment(horizontal: .center, vertical: vertical)
        }
    }

    private var font: Font {
        let style = GuiFont.style(object.font)
        let design: Font.Design
        switch style.design {
        case .monospaced: design = .monospaced
        case .serif: design = .serif
        case .rounded: design = .rounded
        default: design = .default
        }
        let weight: Font.Weight = style.weight == .bold ? .bold : style.weight == .light ? .light : .regular
        return .system(size: placed.textSize, weight: weight, design: design)
    }

    /// The text to show: the placeholder in an empty box, or the text with the caret in
    /// it while typing.
    private var shown: (text: String, placeholder: Bool) {
        let empty = object.kind == .textBox && object.text.isEmpty && !focused
        if empty { return (object.placeholderText, true) }
        guard focused else { return (object.text, false) }
        let at = min(max(cursor, 0), object.text.count)
        let index = object.text.index(object.text.startIndex, offsetBy: at)
        return (String(object.text[..<index]) + "│" + String(object.text[index...]), false)
    }

    @ViewBuilder private var label: some View {
        let (text, placeholder) = shown
        let colour = placeholder ? AnyShapeStyle(Color.gray.opacity(0.8))
            : style(object.textColor, transparency: object.textTransparency)
        let base = Text(text)
            .font(font)
            .lineLimit(object.textWrapped ? nil : 1)
            // A box being typed in keeps its end, and the caret, in view.
            .truncationMode(object.kind == .textBox && focused ? .head : .tail)
            .multilineTextAlignment(alignment.horizontal == .leading ? .leading
                                    : alignment.horizontal == .trailing ? .trailing : .center)
        ZStack {
            if let stroke = textStroke, !placeholder {
                // An outline: the text in the stroke colour, nudged round it — four ways
                // for a thin one, eight for a thick one.
                let ways = stroke.width > 1.5 ? 8 : 4
                ForEach(0..<ways, id: \.self) { index in
                    let angle = Double(index) * 2 * .pi / Double(ways)
                    base.foregroundStyle(stroke.color)
                        .offset(x: (cos(angle) * stroke.width).rounded(), y: (sin(angle) * stroke.width).rounded())
                }
            }
            base.foregroundStyle(colour)
                .background(focused && selectedAll ? Color.accentColor.opacity(0.35) : Color.clear)
        }
    }
}
