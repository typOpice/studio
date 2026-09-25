import SwiftUI
import simd

enum Theme {
    static let panel = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let panelAlt = Color(red: 0.16, green: 0.17, blue: 0.20)
    static let ribbon = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.25, green: 0.56, blue: 0.95)
    static let text = Color(red: 0.88, green: 0.89, blue: 0.91)
    static let textDim = Color(red: 0.58, green: 0.60, blue: 0.64)
}

extension Color {
    init(vec: Vec3) {
        self.init(.sRGB, red: Double(vec.x), green: Double(vec.y), blue: Double(vec.z), opacity: 1)
    }

    var vec: Vec3 {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Vec3(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
    }
}

/// Text field that edits a float and only commits on Return or focus loss,
/// so typing "1.05" never gets mangled halfway through.
struct NumericField: View {
    let label: String
    let tint: Color
    var range: ClosedRange<Float>? = nil
    let value: Float
    let onCommit: (Float) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 12)
            TextField("", text: $text)
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
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { newValue in
            if !focused { text = Self.format(newValue) }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard var parsed = Float(text.trimmingCharacters(in: .whitespaces)) else {
            text = Self.format(value)
            return
        }
        if let range { parsed = min(max(parsed, range.lowerBound), range.upperBound) }
        text = Self.format(parsed)
        if parsed != value { onCommit(parsed) }
    }

    static func format(_ v: Float) -> String {
        abs(v.rounded() - v) < 0.0005 ? String(format: "%.0f", v) : String(format: "%.3g", v)
    }
}

/// Three-component vector row used for Position / Size / Rotation.
struct VectorEditor: View {
    let title: String
    let value: Vec3
    var minComponent: Float? = nil
    let onChange: (Int, Float) -> Void

    private let tints: [Color] = [
        Color(red: 0.94, green: 0.40, blue: 0.42),
        Color(red: 0.52, green: 0.85, blue: 0.45),
        Color(red: 0.42, green: 0.64, blue: 0.96)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    NumericField(label: ["X", "Y", "Z"][i],
                                 tint: tints[i],
                                 range: minComponent.map { $0...Float.greatestFiniteMagnitude },
                                 value: value[i]) { newValue in
                        onChange(i, newValue)
                    }
                }
            }
        }
    }
}
