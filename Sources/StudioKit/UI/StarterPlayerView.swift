import SwiftUI

/// Properties for StarterPlayer: the template every character is built from.
/// Scripts can change a live character's Humanoid; this is where it starts.
struct StarterPlayerInspector: View {
    @ObservedObject var model: SceneModel

    private var settings: StarterPlayerSettings { model.starterPlayer }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Every character starts from these. Scripts can change them while playing, through the character's Humanoid.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                section("Humanoid") {
                    number("WalkSpeed", \.walkSpeed, range: 0...1000)
                    Toggle("UseJumpPower", isOn: toggle(\.useJumpPower))
                    if settings.useJumpPower {
                        number("JumpPower", \.jumpPower, range: 0...1000)
                    } else {
                        number("JumpHeight", \.jumpHeight, range: 0...1000)
                    }
                    number("MaxHealth", \.maxHealth, range: 1...1_000_000)
                    number("MaxSlopeAngle", \.maxSlopeAngle, range: 0...89.9)
                    Toggle("AutoRotate", isOn: toggle(\.autoRotate))
                }

                Divider().overlay(Theme.stroke)

                section("Body Colors") {
                    ForEach(BodyColors.partNames, id: \.self) { part in
                        HStack {
                            Text(part)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textDim)
                            Spacer()
                            ColorPicker("", selection: Binding(
                                get: { Color(vec: settings.bodyColors[part] ?? .zero) },
                                set: { newValue in
                                    model.commit("Set \(part) colour") {
                                        model.starterPlayer.bodyColors[part] = newValue.vec
                                    }
                                }), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    SmallButton("Reset colours", icon: "arrow.counterclockwise") {
                        model.commit("Reset body colours") { model.starterPlayer.bodyColors = BodyColors() }
                    }
                }

                Divider().overlay(Theme.stroke)

                section("Avatar") {
                    StarterPlayerAvatarSection(model: model)
                }

                Divider().overlay(Theme.stroke)

                section("Camera") {
                    LabeledRow("Mode") {
                        Picker("", selection: Binding(
                            get: { settings.cameraMode },
                            set: { newValue in
                                model.commit("Set camera mode") { model.starterPlayer.cameraMode = newValue }
                            })) {
                                ForEach(CameraMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                    }
                    number("MinZoomDistance", \.cameraMinZoomDistance, range: 0.5...1000)
                    number("MaxZoomDistance", \.cameraMaxZoomDistance, range: 0.5...1000)
                }

                Divider().overlay(Theme.stroke)

                section("Players") {
                    number("RespawnTime", \.respawnTime, range: 0...600)
                    Toggle("Players collide", isOn: toggle(\.playersCollide))
                        .help("In a network game, whether players bump into each other. Parts always collide with them.")
                }

                SmallButton("Reset to Roblox defaults", icon: "arrow.uturn.backward") {
                    model.commit("Reset StarterPlayer") { model.starterPlayer = StarterPlayerSettings() }
                }
            }
            .padding(12)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.textDim.opacity(0.9))
            content()
        }
    }

    private func number(_ label: String, _ key: WritableKeyPath<StarterPlayerSettings, Float>,
                        range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            Spacer()
            NumericField(label: "", tint: .clear, range: range, value: settings[keyPath: key]) { newValue in
                model.commit("Set \(label)") { model.starterPlayer[keyPath: key] = newValue }
            }
            .frame(width: 84)
        }
    }

    private func toggle(_ key: WritableKeyPath<StarterPlayerSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { newValue in
            model.commit("Changed StarterPlayer") { model.starterPlayer[keyPath: key] = newValue }
        })
    }
}

/// A built-in script, shown read-only with a way to start from a copy of it.
struct CoreScriptViewer: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    let script: ScriptObject
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                Text(script.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("default · \(script.host.displayName) · read-only")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                SmallButton("Edit a Copy", icon: "doc.on.doc") {
                    if let copy = model.copyCoreScript(named: script.name) { session.openScript(copy) }
                }
                .help("Adds an editable \(script.name) that replaces this default.")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panelAlt.opacity(0.5))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)

            CodeEditor(text: script.source, isEditable: false, language: .luau,
                       completions: { _, _ in [] },
                       cache: session.codeViews,
                       cacheKey: document.id,
                       showsLineNumbers: true,
                       focusOnAppear: true,
                       reveal: session.revealRequest(for: document)) { _ in }
        }
    }
}
