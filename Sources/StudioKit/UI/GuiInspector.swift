import SwiftUI

/// Properties for a GUI object in StarterGui: its name, where it shows on the previewed
/// screen, the modifiers it has, and the properties its class has in sections, each
/// edited as a script would set it.
struct GuiTemplateInspector: View {
    @ObservedObject var model: SceneModel
    var session: EditorSession?
    let template: StarterGuiObject

    /// How a property is edited.
    enum Editor {
        case udim2, udim, vector2, vector3, color, number(ClosedRange<Float>?), toggle, text, choice([String])
        /// A UIGradient's ColorSequence or NumberSequence: its two ends.
        case colorSequence, numberSequence
        /// A UISizeConstraint's MaxSize: a Vector2 where blank is no limit.
        case limit
    }

    struct Field {
        let label: String
        let key: String
        let editor: Editor
        var section = ""
    }

    static let alignmentsX = ["Left", "Center", "Right"]
    static let alignmentsY = ["Top", "Center", "Bottom"]
    static let fonts = ["SourceSans", "SourceSansBold", "SourceSansLight", "Arial", "ArialBold", "Gotham", "GothamBold",
                        "GothamBlack", "Code", "RobotoMono", "Cartoon", "FredokaOne", "Bangers", "LuckiestGuy", "Garamond",
                        "Merriweather", "Arcade"]
    /// The modifiers the panel offers to add to a drawn object in one click.
    static let quickModifiers: [GuiObject.Kind] = [.uiCorner, .uiStroke, .uiPadding, .uiGradient, .uiListLayout,
                                                   .uiAspectRatioConstraint]

    /// The properties a class has, in the order the panel shows them, each in a section.
    static func fields(for kind: GuiObject.Kind) -> [Field] {
        var fields: [Field] = []
        func add(_ section: String, _ more: [Field]) {
            fields += more.map { field in
                var field = field
                field.section = section
                return field
            }
        }
        let isObject = !kind.isModifier && !kind.isLayer
        if kind == .screenGui || kind == .billboardGui {
            add("Screen", [Field(label: "Enabled", key: "enabled", editor: .toggle)])
        }
        if kind == .screenGui {
            add("Screen", [Field(label: "ResetOnSpawn", key: "resetonspawn", editor: .toggle),
                           Field(label: "DisplayOrder", key: "displayorder", editor: .number(nil))])
        }
        if isObject {
            add("Layout", [
                Field(label: "Position", key: "position", editor: .udim2),
                Field(label: "Size", key: "size", editor: .udim2),
                Field(label: "AnchorPoint", key: "anchorpoint", editor: .vector2),
                Field(label: "AutomaticSize", key: "automaticsize", editor: .choice(["None", "X", "Y", "XY"])),
                Field(label: "ZIndex", key: "zindex", editor: .number(nil)),
                Field(label: "LayoutOrder", key: "layoutorder", editor: .number(nil)),
            ])
            add("Appearance", [
                Field(label: "BackgroundColor3", key: "backgroundcolor3", editor: .color),
                Field(label: "BackgroundTransparency", key: "backgroundtransparency", editor: .number(0...1)),
                Field(label: "Visible", key: "visible", editor: .toggle),
                Field(label: "ClipsDescendants", key: "clipsdescendants", editor: .toggle),
            ])
        }
        if kind.showsText {
            add("Text", [
                Field(label: "Text", key: "text", editor: .text),
                Field(label: "TextColor3", key: "textcolor3", editor: .color),
                Field(label: "TextSize", key: "textsize", editor: .number(1...100)),
                Field(label: "Font", key: "font", editor: .choice(fonts)),
                Field(label: "TextXAlignment", key: "textxalignment", editor: .choice(alignmentsX)),
                Field(label: "TextYAlignment", key: "textyalignment", editor: .choice(alignmentsY)),
                Field(label: "TextWrapped", key: "textwrapped", editor: .toggle),
                Field(label: "TextScaled", key: "textscaled", editor: .toggle),
                Field(label: "TextTransparency", key: "texttransparency", editor: .number(0...1)),
                Field(label: "TextStrokeColor3", key: "textstrokecolor3", editor: .color),
                Field(label: "TextStrokeTransparency", key: "textstroketransparency", editor: .number(0...1)),
            ])
        }
        if kind == .textBox {
            add("Text", [Field(label: "PlaceholderText", key: "placeholdertext", editor: .text),
                         Field(label: "ClearTextOnFocus", key: "cleartextonfocus", editor: .toggle),
                         Field(label: "TextEditable", key: "texteditable", editor: .toggle)])
        }
        if kind.showsImage {
            add("Image", [Field(label: "Image", key: "image", editor: .text),
                          Field(label: "ImageColor3", key: "imagecolor3", editor: .color),
                          Field(label: "ImageTransparency", key: "imagetransparency", editor: .number(0...1)),
                          Field(label: "ScaleType", key: "scaletype", editor: .choice(["Stretch", "Fit", "Crop"]))])
        }
        if kind == .scrollingFrame {
            add("Scrolling", [
                Field(label: "CanvasSize", key: "canvassize", editor: .udim2),
                Field(label: "AutomaticCanvasSize", key: "automaticcanvassize", editor: .choice(["None", "X", "Y", "XY"])),
                Field(label: "ScrollBarThickness", key: "scrollbarthickness", editor: .number(0...40)),
                Field(label: "ScrollingEnabled", key: "scrollingenabled", editor: .toggle),
            ])
        }
        let section = kind.rawValue
        switch kind {
        case .uiCorner:
            add(section, [Field(label: "CornerRadius", key: "cornerradius", editor: .udim)])
        case .uiPadding:
            add(section, ["Left", "Right", "Top", "Bottom"].map {
                Field(label: "Padding\($0)", key: "padding\($0.lowercased())", editor: .udim)
            })
        case .uiListLayout:
            add(section, [Field(label: "FillDirection", key: "filldirection", editor: .choice(["Vertical", "Horizontal"])),
                          Field(label: "Padding", key: "padding", editor: .udim),
                          Field(label: "SortOrder", key: "sortorder", editor: .choice(["LayoutOrder", "Name"])),
                          Field(label: "HorizontalAlignment", key: "horizontalalignment", editor: .choice(alignmentsX)),
                          Field(label: "VerticalAlignment", key: "verticalalignment", editor: .choice(alignmentsY))])
        case .uiGridLayout:
            add(section, [Field(label: "CellSize", key: "cellsize", editor: .udim2),
                          Field(label: "CellPadding", key: "cellpadding", editor: .udim2),
                          Field(label: "FillDirection", key: "filldirection", editor: .choice(["Horizontal", "Vertical"])),
                          Field(label: "FillDirectionMaxCells", key: "filldirectionmaxcells", editor: .number(0...1000)),
                          Field(label: "StartCorner", key: "startcorner",
                                editor: .choice(["TopLeft", "TopRight", "BottomLeft", "BottomRight"])),
                          Field(label: "SortOrder", key: "sortorder", editor: .choice(["LayoutOrder", "Name"])),
                          Field(label: "HorizontalAlignment", key: "horizontalalignment", editor: .choice(alignmentsX)),
                          Field(label: "VerticalAlignment", key: "verticalalignment", editor: .choice(alignmentsY))])
        case .uiStroke:
            add(section, [Field(label: "Enabled", key: "enabled", editor: .toggle),
                          Field(label: "Color", key: "color", editor: .color),
                          Field(label: "Thickness", key: "thickness", editor: .number(0...64)),
                          Field(label: "Transparency", key: "transparency", editor: .number(0...1)),
                          Field(label: "ApplyStrokeMode", key: "applystrokemode", editor: .choice(["Contextual", "Border"])),
                          Field(label: "LineJoinMode", key: "linejoinmode", editor: .choice(["Round", "Bevel", "Miter"]))])
        case .uiGradient:
            add(section, [Field(label: "Enabled", key: "enabled", editor: .toggle),
                          Field(label: "Color", key: "color", editor: .colorSequence),
                          Field(label: "Transparency", key: "transparency", editor: .numberSequence),
                          Field(label: "Rotation", key: "rotation", editor: .number(-360...360)),
                          Field(label: "Offset", key: "offset", editor: .vector2)])
        case .uiAspectRatioConstraint:
            add(section, [Field(label: "AspectRatio", key: "aspectratio", editor: .number(0.01...100)),
                          Field(label: "AspectType", key: "aspecttype", editor: .choice(["FitWithinMaxSize", "ScaleWithParentSize"])),
                          Field(label: "DominantAxis", key: "dominantaxis", editor: .choice(["Width", "Height"]))])
        case .uiSizeConstraint:
            add(section, [Field(label: "MinSize", key: "minsize", editor: .vector2),
                          Field(label: "MaxSize", key: "maxsize", editor: .limit)])
        case .uiTextSizeConstraint:
            add(section, [Field(label: "MinTextSize", key: "mintextsize", editor: .number(1...100)),
                          Field(label: "MaxTextSize", key: "maxtextsize", editor: .number(1...100))])
        default:
            break
        }
        return fields
    }

    var body: some View {
        let object = template.object()
        let fields = Self.fields(for: template.kind)
        let sections = fields.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                LabeledRow("Name") {
                    TextField("", text: Binding(get: { template.name },
                                                set: { model.renameGuiObject(template.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                }
                LabeledRow("Class") {
                    Label(template.kind.rawValue, systemImage: template.kind.symbolName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                }
                if let where_ = onScreen {
                    LabeledRow("Shows") {
                        Text(where_).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textDim)
                    }
                }
                if !template.kind.isModifier && !template.kind.isLayer { modifierChips }
                ForEach(sections, id: \.self) { section in
                    sectionHeader(section)
                    ForEach(fields.filter { $0.section == section }, id: \.key) { field in
                        row(field, value: PlayController.guiProperty(object, field.key))
                    }
                }
                Divider().overlay(Theme.stroke)
                HStack(spacing: 6) {
                    if !template.kind.isModifier {
                        SmallButton("Add LocalScript", icon: "doc.badge.plus") {
                            let script = model.addScript(parentID: template.id, host: .starterGui)
                            session?.openScript(script)
                        }
                    }
                    SmallButton("Duplicate", icon: "plus.square.on.square") { model.duplicateGui(template.id) }
                    SmallButton("Delete", icon: "trash") { model.deleteGuiObject(template.id) }
                }
            }
            .padding(12)
        }
    }

    /// Where it is on the previewed screen, in pixels.
    private var onScreen: String? {
        guard let session, !template.kind.isModifier, !template.kind.isLayer,
              let copy = session.guiEditor.copies[template.id],
              let frame = session.guiPreview.layout(in: session.guiPreview.lastScreen).first(where: { $0.id == copy })?.frame
        else { return nil }
        let device = session.guiEditor.device == .window ? "" : " (\(session.guiEditor.device.title))"
        return "\(Int(frame.width.rounded())) × \(Int(frame.height.rounded())) at \(Int(frame.minX.rounded())), "
            + "\(Int(frame.minY.rounded()))\(device)"
    }

    /// The common modifiers, one click to add; the ones it has are lit, and select them.
    private var modifierChips: some View {
        let inside = model.guiChildren(of: template.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text("MODIFIERS").font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textDim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(Self.quickModifiers, id: \.self) { kind in
                    let existing = inside.first { $0.kind == kind }
                    Button {
                        if let existing {
                            model.selectedGui = existing.id
                        } else {
                            model.addGuiObject(kind, in: template.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: existing == nil ? "plus" : kind.symbolName).font(.system(size: 9))
                            Text(kind.shortName).font(.system(size: 10)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(existing == nil ? Theme.panelAlt : Theme.accent.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .help(existing == nil ? "Add a \(kind.rawValue)" : "Select its \(kind.rawValue)")
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.stroke)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.top, 2)
    }

    private func set(_ key: String, _ value: ScriptValue) { model.setGuiProperty(template.id, key, value) }

    private func numbers(_ value: ScriptValue) -> [Float] {
        if case .list(let items) = value { return items.compactMap(\.asFloat) }
        return []
    }

    @ViewBuilder private func row(_ field: Field, value: ScriptValue) -> some View {
        switch field.editor {
        case .toggle:
            Toggle(field.label, isOn: Binding(get: { value.asBool ?? false }, set: { set(field.key, .bool($0)) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
        case .text:
            GuiRow(field.label) {
                TextField("", text: Binding(get: { value.asString ?? "" }, set: { set(field.key, .string($0)) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
            }
        case .number(let range):
            GuiRow(field.label) {
                NumericField(label: "", tint: Theme.textDim, range: range, value: value.asFloat ?? 0) {
                    set(field.key, .number(Double($0)))
                }
            }
        case .choice(let options):
            GuiRow(field.label) {
                Picker("", selection: Binding(get: { value.asString ?? options[0] }, set: { set(field.key, .string($0)) })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        case .color:
            GuiRow(field.label) { colourWell(value) { set(field.key, $0) } }
        case .udim2:
            // X and Y each as a share of the parent (scale) plus pixels (offset).
            let parts = numbers(value) + Array(repeating: 0, count: max(4 - numbers(value).count, 0))
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                ForEach(0..<2, id: \.self) { axis in
                    HStack(spacing: 4) {
                        Text(axis == 0 ? "X" : "Y")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(axis == 0 ? Color(red: 0.94, green: 0.4, blue: 0.42)
                                                       : Color(red: 0.52, green: 0.85, blue: 0.45))
                            .frame(width: 12)
                        ForEach(0..<2, id: \.self) { half in
                            let index = axis * 2 + half
                            NumericField(label: half == 0 ? "S" : "px", tint: Theme.textDim, value: parts[index]) { edited in
                                var list = parts
                                list[index] = edited
                                set(field.key, .list(list.map { .number(Double($0)) }))
                            }
                            .help(half == 0 ? "Scale: a share of the parent (1 is all of it)" : "Offset: pixels")
                        }
                    }
                }
            }
        case .udim, .vector2, .vector3, .limit:
            let parts = numbers(value)
            let labels = field.editor.componentLabels
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                HStack(spacing: 4) {
                    ForEach(labels.indices, id: \.self) { index in
                        let current = index < parts.count ? parts[index] : 0
                        if field.editor.isLimit {
                            LimitField(label: labels[index], value: current) { newValue in
                                var edited = parts + Array(repeating: 1e9, count: max(2 - parts.count, 0))
                                edited[index] = newValue
                                set(field.key, .list(edited.map { .number(Double($0)) }))
                            }
                        } else {
                            NumericField(label: labels[index], tint: index < 2 ? Theme.accent : Theme.textDim,
                                         value: current) { newValue in
                                var edited = parts + Array(repeating: 0, count: max(labels.count - parts.count, 0))
                                edited[index] = newValue
                                set(field.key, field.editor.isVector3 ? .triple(edited[0], edited[1], edited[2])
                                    : .list(edited.map { .number(Double($0)) }))
                            }
                        }
                    }
                }
            }
        case .colorSequence:
            sequenceEditor(field, value: value, colours: true)
        case .numberSequence:
            sequenceEditor(field, value: value, colours: false)
        }
    }

    private func colourWell(_ value: ScriptValue, _ commit: @escaping (ScriptValue) -> Void) -> some View {
        ColorPicker("", selection: Binding(get: {
            guard let (r, g, b) = value.asTriple else { return Color.white }
            return Color(vec: Vec3(r, g, b))
        }, set: { colour in
            let v = colour.vec
            commit(.triple(v.x, v.y, v.z))
        }))
        .labelsHidden()
    }

    /// A gradient's two ends — the keypoints between them kept — over a strip of it.
    @ViewBuilder private func sequenceEditor(_ field: Field, value: ScriptValue, colours: Bool) -> some View {
        let list = numbers(value)
        let stride = colours ? 4 : 2
        let count = list.count / stride
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            if count >= 2 {
                let strip: [Color] = (0..<count).map { point in
                    let at = point * stride
                    return colours ? Color(vec: Vec3(list[at + 1], list[at + 2], list[at + 3]))
                                   : Color.white.opacity(Double(1 - list[at + 1]))
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(stops: (0..<count).map { Gradient.Stop(color: strip[$0], location: CGFloat(list[$0 * stride])) },
                                         startPoint: .leading, endPoint: .trailing))
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black))
                    .frame(height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
                HStack(spacing: 8) {
                    ForEach([0, count - 1], id: \.self) { point in
                        let at = point * stride
                        HStack(spacing: 4) {
                            Text(point == 0 ? "From" : "To").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                            if colours {
                                colourWell(.triple(list[at + 1], list[at + 2], list[at + 3])) { picked in
                                    guard let (r, g, b) = picked.asTriple else { return }
                                    var edited = list
                                    edited[at + 1] = r
                                    edited[at + 2] = g
                                    edited[at + 3] = b
                                    set(field.key, .list(edited.map { .number(Double($0)) }))
                                }
                            } else {
                                NumericField(label: "", tint: Theme.textDim, range: 0...1, value: list[at + 1]) { picked in
                                    var edited = list
                                    edited[at + 1] = picked
                                    set(field.key, .list(edited.map { .number(Double($0)) }))
                                }
                                .frame(width: 70)
                            }
                        }
                    }
                    if count > 2 {
                        Text("+\(count - 2) between").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
    }
}

private extension GuiTemplateInspector.Editor {
    var isVector3: Bool { if case .vector3 = self { return true } else { return false } }
    var isLimit: Bool { if case .limit = self { return true } else { return false } }

    /// The fields a value is edited in: a UDim's scale and offset, a vector's axes.
    var componentLabels: [String] {
        switch self {
        case .vector3: return ["X", "Y", "Z"]
        case .vector2, .limit: return ["X", "Y"]
        default: return ["S", "px"]
        }
    }
}

/// A limit in pixels, where blank (shown as "none") is no limit at all.
private struct LimitField: View {
    let label: String
    let value: Float
    let onCommit: (Float) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private static func show(_ value: Float) -> String { value >= 1e8 ? "" : NumericField.format(value) }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 12)
            TextField("none", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit(commit)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Theme.accent : Theme.stroke, lineWidth: 1))
        .onAppear { text = Self.show(value) }
        .onChange(of: value) { newValue in if !focused { text = Self.show(newValue) } }
        .onChange(of: focused) { isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed: Float = trimmed.isEmpty || trimmed.lowercased() == "none" ? 1e9 : Float(trimmed).map { max($0, 0) } ?? value
        text = Self.show(parsed)
        if parsed != value { onCommit(parsed) }
    }
}

/// A property's name and its editor on one line; the names are long, so they get room
/// and shrink rather than break.
private struct GuiRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 138, alignment: .leading)
            content
        }
    }
}
