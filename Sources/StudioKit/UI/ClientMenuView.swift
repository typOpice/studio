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
                    MenuButton(title: "Join a game", icon: "person.2.fill") { session.screen = .join }
                    MenuButton(title: "Character", icon: "person.crop.square") { session.screen = .character }
                    MenuButton(title: "Quit", icon: "xmark") { NSApp.terminate(nil) }
                }
                if let problem = session.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.5, blue: 0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 60)

            VStack(spacing: 14) {
                BodyFigure(colors: session.profile.colors, unit: 34)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(width: 290)
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

/// Character customization: a name, and a colour for each body part.
struct CharacterEditorView: View {
    @ObservedObject var session: ClientSession
    @State private var part = "Torso"
    @State private var name = ""

    var body: some View {
        HStack(spacing: 60) {
            BodyFigure(colors: session.profile.colors, unit: 48, selected: part) { part = $0 }

            VStack(alignment: .leading, spacing: 18) {
                Text("Character").font(.system(size: 30, weight: .bold))

                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                    TextField("Player", text: $name, onCommit: commitName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(part.uppercased()) COLOUR").font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(.white.opacity(0.6))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), spacing: 8) {
                        ForEach(PlayerProfile.palette, id: \.name) { swatch in
                            let chosen = session.profile.colors[part] == swatch.color
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(vec: swatch.color))
                                .frame(width: 34, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(chosen ? Color.white : Color.white.opacity(0.15), lineWidth: chosen ? 3 : 1))
                                .onTapGesture { session.profile.colors[part] = swatch.color }
                                .help(swatch.name)
                        }
                    }
                    Text("Click a body part on the left, then a colour.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }

                HStack(spacing: 10) {
                    MenuButton(title: "Done", icon: "checkmark", prominent: true) {
                        commitName()
                        session.screen = .menu
                    }
                    .frame(width: 140)
                    Button("Reset colours") { session.profile.colors = BodyColors() }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(MenuBackground())
        .onAppear { name = session.profile.name }
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
            MenuButton(title: "Back", icon: "chevron.left") { session.screen = .menu }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(MenuBackground())
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}
