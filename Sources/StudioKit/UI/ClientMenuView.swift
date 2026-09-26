import SwiftUI

/// The client's window: the menu screens, or the game.
struct ClientRootView: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        Group {
            switch session.screen {
            case .playing:
                if let player = session.player {
                    ZStack(alignment: .top) {
                        ClientView(player: player)
                        GuiLayer(store: player.gui)
                        if session.host != nil || session.membership != nil {
                            NameTags(player: player)
                        }
                        GameBar(session: session)
                    }
                }
            case .games: GamePickerView(session: session, games: session.games)
            case .menu: ClientMenuView(session: session)
            case .character: CharacterEditorView(session: session)
            case .join: JoinGameView(session: session)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The other players' names, over their heads, following them every frame.
struct NameTags: View {
    let player: PlayController

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation) { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(player.remoteNameTags.enumerated()), id: \.offset) { _, tag in
                        if let point = player.screenPoint(of: tag.position, in: geometry.size) {
                            Text(tag.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(SwiftUI.Capsule().fill(Color.black.opacity(0.45)))
                                .fixedSize()
                                .position(point)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Along the top of the game: where you are on the network, and the way back to the menu.
struct GameBar: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        HStack(spacing: 10) {
            if let host = session.host {
                HostBadge(host: host)
            } else if let membership = session.membership {
                MemberBadge(membership: membership)
            }
            Button {
                session.leaveGame()
            } label: {
                Label("Menu", systemImage: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(HUDBackground())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Back to the main menu (⌘L)")
        }
        .padding(.top, 10)
    }
}

struct HostBadge: View {
    @ObservedObject var host: LANHost
    var body: some View {
        MenuBadge(icon: "antenna.radiowaves.left.and.right",
                  text: host.players.isEmpty ? "Hosting on your network — no one has joined yet"
                                             : "Hosting — \(host.players.joined(separator: ", ")) joined")
    }
}

struct MemberBadge: View {
    @ObservedObject var membership: LANMembership
    var body: some View {
        MenuBadge(icon: membership.connected ? "person.2.fill" : "wifi.slash",
                  text: membership.connected ? "In \(membership.game) — \(membership.players.count) players"
                                             : "Lost the connection to \(membership.game)")
    }
}

struct MenuBadge: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(HUDBackground())
    }
}

/// The main menu: play, host or join on the local network, and the player's character.
struct ClientMenuView: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("STUDIO").font(.system(size: 42, weight: .heavy)).tracking(4)
                    Text(session.sceneName).font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 10) {
                    MenuButton(title: "Play", icon: "play.fill", prominent: true) { session.play() }
                    MenuButton(title: "Host on your network", icon: "antenna.radiowaves.left.and.right") {
                        session.hostOnLAN()
                    }
                    MenuButton(title: "Join a game", icon: "person.2.fill") { session.show(.join) }
                    MenuButton(title: "Choose another game", icon: "square.grid.2x2") { session.showGames() }
                    MenuButton(title: "Character", icon: "person.crop.square") { session.show(.character) }
                    MenuButton(title: "Quit", icon: "xmark") { NSApp.terminate(nil) }
                }
                if let problem = session.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.5, blue: 0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 60)

            VStack(spacing: 14) {
                AvatarPreview(look: session.profile.look, colors: session.profile.colors, width: 240, height: 320)
                Text(session.profile.name).font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(MenuBackground())
    }
}

struct MenuButton: View {
    let title: String
    let icon: String
    var prominent = false
    var width: CGFloat = 290
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(prominent ? Theme.accent : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct MenuBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.05, green: 0.06, blue: 0.09)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The character, flat: head, torso, arms and legs in their colours, as Roblox's body
/// colour picker shows it. Tapping a part picks it.
struct BodyFigure: View {
    let colors: BodyColors
    var unit: CGFloat = 40
    var selected: String? = nil
    var pick: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: unit * 0.1) {
            piece("Head", width: 1.3, height: 1.3, corner: 0.35)
            HStack(alignment: .top, spacing: unit * 0.1) {
                piece("Right Arm", width: 1, height: 2)
                piece("Torso", width: 2, height: 2)
                piece("Left Arm", width: 1, height: 2)
            }
            HStack(spacing: unit * 0.1) {
                piece("Right Leg", width: 1, height: 2)
                piece("Left Leg", width: 1, height: 2)
            }
        }
    }

    private func piece(_ name: String, width: CGFloat, height: CGFloat, corner: CGFloat = 0.12) -> some View {
        let isSelected = selected == name
        return RoundedRectangle(cornerRadius: unit * corner)
            .fill(Color(vec: colors[name] ?? Vec3(repeating: 0.5)))
            .frame(width: unit * width, height: unit * height)
            .overlay(RoundedRectangle(cornerRadius: unit * corner)
                .stroke(isSelected ? Color.white : Color.black.opacity(0.25), lineWidth: isSelected ? 3 : 1))
            .contentShape(Rectangle())
            .onTapGesture { pick?(name) }
            .help(name)
    }
}

/// Character customization: a name, body colours, a face, clothes and accessories —
/// the built-in catalog — shown on the character itself, which can be turned round.
struct CharacterEditorView: View {
    @ObservedObject var session: ClientSession
    @State private var part = "Torso"
    @State private var name = ""
    @State private var tab = CharacterEditorView.startingTab
    /// The tab it opens on (the window snapshots show another).
    static var startingTab = Tab.colours
    /// The accessory whose colour the palette changes: the one last put on.
    @State private var colouring: String?

    enum Tab: String, CaseIterable, Identifiable {
        case colours = "Colours", face = "Face", clothes = "Clothes", accessories = "Accessories"
        var id: String { rawValue }
    }

    private var look: AvatarLook { session.profile.look }

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(spacing: 10) {
                AvatarPreview(look: look, colors: session.profile.colors, width: 300, height: 420)
                Text("Drag to turn").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Character").font(.system(size: 30, weight: .bold))

                VStack(alignment: .leading, spacing: 6) {
                    heading("NAME")
                    TextField("Player", text: $name, onCommit: commitName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)

                Group {
                    switch tab {
                    case .colours: colours
                    case .face: faces
                    case .clothes: clothes
                    case .accessories: accessories
                    }
                }
                .frame(width: 420, height: 300, alignment: .topLeading)

                HStack(spacing: 10) {
                    MenuButton(title: "Done", icon: "checkmark", prominent: true, width: 140) {
                        commitName()
                        session.back()
                    }
                    Button("Reset colours") { session.profile.colors = BodyColors() }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    Button("Take everything off") { session.profile.look = AvatarLook() }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(MenuBackground())
        .onAppear { name = session.profile.name }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
    }

    private func palette(chosen: Vec3?, pick: @escaping (Vec3) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 7), count: 8), spacing: 7) {
            ForEach(PlayerProfile.palette, id: \.name) { swatch in
                let isChosen = chosen == swatch.color
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(vec: swatch.color))
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(isChosen ? Color.white : Color.white.opacity(0.15), lineWidth: isChosen ? 3 : 1))
                    .onTapGesture { pick(swatch.color) }
                    .help(swatch.name)
            }
        }
    }

    /// A choice in a grid: a picture (or symbol), a name, and whether it's on.
    private func tile(_ title: String, image: NSImage?, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: symbol).font(.system(size: 22))
                    }
                }
                .frame(width: 48, height: 48)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .frame(width: 72, height: 78)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.accent.opacity(0.55) : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.white : Color.white.opacity(0.1), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var grid: [GridItem] { Array(repeating: GridItem(.fixed(72), spacing: 8), count: 5) }

    private var colours: some View {
        HStack(alignment: .top, spacing: 24) {
            BodyFigure(colors: session.profile.colors, unit: 26, selected: part) { part = $0 }
            VStack(alignment: .leading, spacing: 8) {
                heading("\(part.uppercased()) COLOUR")
                palette(chosen: session.profile.colors[part]) { session.profile.colors[part] = $0 }
                Text("Click a body part, then a colour.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var faces: some View {
        LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
            ForEach(AvatarCatalog.faces, id: \.id) { face in
                let reference = face.id == AvatarCatalog.classicFace ? "" : AvatarCatalog.prefix + face.id
                tile(face.name, image: AvatarThumbnails.face(reference),
                     symbol: face.id == "None" ? "circle.slash" : "face.smiling", on: look.face == reference) {
                    session.profile.look.face = reference
                }
            }
        }
    }

    private var clothes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                heading("SHIRT")
                LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                    tile("None", image: nil, symbol: "circle.slash", on: look.shirt.isEmpty) { session.profile.look.shirt = "" }
                    ForEach(AvatarCatalog.shirts, id: \.id) { shirt in
                        let reference = AvatarCatalog.prefix + shirt.id
                        tile(shirt.name, image: AvatarThumbnails.clothing(reference, pants: false), symbol: "tshirt",
                             on: look.shirt == reference) { session.profile.look.shirt = reference }
                    }
                }
                heading("PANTS")
                LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                    tile("None", image: nil, symbol: "circle.slash", on: look.pants.isEmpty) { session.profile.look.pants = "" }
                    ForEach(AvatarCatalog.pants, id: \.id) { pants in
                        let reference = AvatarCatalog.prefix + pants.id
                        tile(pants.name, image: AvatarThumbnails.clothing(reference, pants: true), symbol: "figure.walk",
                             on: look.pants == reference) { session.profile.look.pants = reference }
                    }
                }
            }
        }
    }

    private var accessories: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                ForEach(AvatarCatalog.accessories, id: \.id) { entry in
                    let item = AvatarCatalog.prefix + entry.id
                    let worn = look.accessories.contains { $0.item == item }
                    tile(entry.name, image: nil, symbol: entry.icon, on: worn) {
                        if worn {
                            session.profile.look.accessories.removeAll { $0.item == item }
                            if colouring == item { colouring = nil }
                        } else if let accessory = AvatarAccessory(builtIn: entry.id),
                                  look.accessories.count < AvatarLook.mostAccessories {
                            session.profile.look.accessories.append(accessory)
                            colouring = item
                        }
                    }
                }
            }
            if let item = colouring, let index = look.accessories.firstIndex(where: { $0.item == item }) {
                heading("\(look.accessories[index].name.uppercased()) COLOUR")
                palette(chosen: look.accessories[index].color) { session.profile.look.accessories[index].color = $0 }
            } else {
                Text("Click to put something on or take it off. Up to \(AvatarLook.mostAccessories).")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func commitName() {
        session.profile.name = PlayerProfile.tidy(name)
        name = session.profile.name
    }
}

/// Games hosted on the same network, found as they appear.
struct JoinGameView: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var browser: LANBrowser

    init(session: ClientSession) {
        self.session = session
        self.browser = session.browser
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Join a game").font(.system(size: 30, weight: .bold))
            Text(browser.games.isEmpty
                 ? "Looking for games on your network… On another Mac, choose Host on your network."
                 : "Games on your network")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 8) {
                ForEach(browser.games) { game in
                    HStack(spacing: 12) {
                        Image(systemName: "display").font(.system(size: 16)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.name).font(.system(size: 14, weight: .semibold))
                            Text(game.compatible ? "\(game.sceneName) · \(game.players) joined"
                                                 : "A different version of Studio")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Button(session.joining == game.name ? "Joining…" : "Join") { session.join(game) }
                            .disabled(!game.compatible || session.joining != nil)
                    }
                    .padding(12)
                    .frame(width: 460)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                }
            }

            if let problem = session.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.5, blue: 0.45))
            }
            if let failure = browser.failure {
                Text("The network said: \(failure)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            MenuButton(title: "Back", icon: "chevron.left") { session.back() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(MenuBackground())
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}
