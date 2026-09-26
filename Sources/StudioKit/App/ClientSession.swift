import Foundation
import AppKit

/// Everything the client app is doing: which screen shows, the player's profile, the
/// scene, the play session, and a LAN game being hosted or joined.
final class ClientSession: ObservableObject {
    /// `games` is the game picker the client starts on; `menu` plays, hosts or joins the
    /// game chosen there.
    enum Screen: Equatable { case games, menu, character, join, playing }

    @Published var screen: Screen = .menu
    /// Where Back (or Done) on the character and join screens goes: the screen they came from.
    private(set) var backScreen: Screen = .menu
    /// Saved whenever it changes.
    @Published var profile: PlayerProfile {
        didSet { if profile != oldValue { profile.save(to: defaults) } }
    }
    @Published private(set) var player: PlayController?
    @Published private(set) var sceneName: String
    @Published private(set) var host: LANHost?
    @Published private(set) var membership: LANMembership?
    /// The game being joined, while the host answers.
    @Published private(set) var joining: String?
    /// Why the last attempt to host or join didn't work.
    @Published var problem: String?

    let model: SceneModel
    let browser = LANBrowser()
    /// The game picker's cards: the sample games and the Starter Scene, and the places
    /// opened here lately, with their pictures.
    let games = HomeModel(templates: PlaceTemplate.samples + [.starter])
    private let defaults: UserDefaults
    /// The scene as it was before play began; leaving a game puts it back.
    private var snapshot = SceneState()
    /// Sends this player's character and draws the others, while in a network game.
    private var syncTimer: Timer?
    /// The host's world as last sent to the players.
    private var shared = SceneState()

    init(model: SceneModel = SceneModel(), sceneName: String = "Starter Scene", defaults: UserDefaults = .standard) {
        self.model = model
        self.sceneName = sceneName
        self.defaults = defaults
        self.profile = PlayerProfile.load(from: defaults)
        games.openFile = { [weak self] url in self?.choose(file: url) }
        games.browse = { [weak self] in
            ClientSession.askForPlace { url in self?.choose(file: url) }
        }
    }

    // MARK: - Choosing a game

    /// Places opened here, newest first.
    var recentPlaces: [URL] {
        (defaults.stringArray(forKey: Self.recentsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static let recentsKey = "recentPlaces"

    private func noteRecent(_ url: URL) {
        // Not Studio's copy of the place it hands over: it's gone once played.
        guard !LaunchClient.isHandover(url) else { return }
        let path = url.standardizedFileURL.path
        let paths = [path] + recentPlaces.map(\.path).filter { $0 != path }
        defaults.set(Array(paths.prefix(HomeModel.recentLimit)), forKey: Self.recentsKey)
    }

    /// The game picker, leaving whatever game was going.
    func showGames() {
        leaveGame()
        problem = nil
        screen = .games
        games.refresh(recentURLs: recentPlaces)
    }

    /// The character or join screen, coming back to this one after.
    func show(_ next: Screen) {
        backScreen = screen == .games ? .games : .menu
        screen = next
    }

    func back() {
        screen = backScreen
        if screen == .games { games.refresh(recentURLs: recentPlaces) }
    }

    /// A game from the picker, on the menu ready to play or host.
    func choose(_ template: PlaceTemplate) {
        leaveGame()
        model.loadTemplate(template)
        sceneName = template.title
        problem = nil
        screen = .menu
    }

    /// A place file from the picker.
    func choose(file url: URL) {
        leaveGame()
        do {
            try open(url)
            problem = nil
            screen = .menu
        } catch {
            problem = "Couldn't open \(url.lastPathComponent)"
            screen = .games
            games.refresh(recentURLs: recentPlaces)
        }
    }

    /// The Open panel, for a place file.
    static func askForPlace(_ chosen: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, SceneDocument.sceneType]
        panel.begin { response in
            if response == .OK, let url = panel.url { chosen(url) }
        }
    }

    // MARK: - Scenes

    func open(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try load(data, named: url.deletingPathExtension().lastPathComponent, file: url)
        noteRecent(url)
    }

    /// The sample game: what the client opens on when started by itself.
    func loadAdventureIsland() {
        let wasPlaying = player != nil
        leaveGame()
        model.loadAdventureIsland()
        sceneName = AdventureIsland.name
        if wasPlaying { play() }
    }

    /// The second sample game.
    func loadNightfall() {
        let wasPlaying = player != nil
        leaveGame()
        model.loadNightfall()
        sceneName = Nightfall.name
        if wasPlaying { play() }
    }

    /// The third sample game.
    func loadMegaObby() {
        let wasPlaying = player != nil
        leaveGame()
        model.loadMegaObby()
        sceneName = MegaObby.name
        if wasPlaying { play() }
    }

    func loadStarterScene() {
        let wasPlaying = player != nil
        leaveGame()
        model.loadStarterScene()
        sceneName = "Starter Scene"
        if wasPlaying { play() }
    }

    private func load(_ data: Data, named name: String, upgrading: Bool = true, file: URL? = nil) throws {
        let wasPlaying = player != nil
        stopPlaying()
        try model.loadScene(from: data, upgrading: upgrading)
        // One from before places had ids: its DataStores go by where the file is.
        if let file { model.ensurePlaceID(from: file) }
        sceneName = name
        if wasPlaying { play() }
    }

    // MARK: - Playing

    /// Plays the scene as this player: their colours, their name.
    func play() {
        stopPlaying()
        snapshot = model.state
        let session = PlayController(model: model, console: ScriptConsole())
        // A joined player's world is the host's, and they go by the number it gave them.
        session.worldFromHost = membership != nil
        session.playerID = membership?.id ?? 0
        if let membership { session.knowPlayersAtStart(membership.others) }
        profile.apply(to: model, session)
        session.start()
        player = session
        problem = nil
        screen = .playing
    }

    /// Back to the menu: stops the game, stops hosting, leaves a joined game.
    func leaveGame() {
        syncTimer?.invalidate()
        syncTimer = nil
        stopPlaying()
        host?.stop()
        host = nil
        membership?.leave()
        membership = nil
        screen = .menu
    }

    private func stopPlaying() {
        guard let running = player else { return }
        running.stop()
        player = nil
        model.state = snapshot
    }

    // MARK: - The local network

    /// What a hosted game is called on the network: whose, and which scene.
    var hostedGameName: String {
        String("\(PlayerProfile.tidy(profile.name))'s \(sceneName)".prefix(60))
    }

    /// Plays the scene and offers it to other clients on the same network.
    func hostOnLAN(advertise: Bool = true) {
        do {
            // Someone joining gets the world as it is then, mid-game.
            let host = LANHost(gameName: hostedGameName, sceneName: sceneName) { [weak self] in
                (try? self?.model.encodeScene(shared: true)) ?? Data()
            }
            try host.start(advertise: advertise)
            play()
            shared = model.sharedState
            self.host = host
            startSyncing()
        } catch {
            problem = "Couldn't host: \(error.localizedDescription)"
        }
    }

    private func startSyncing() {
        // A host script acting on a joined player's character goes to that player's game,
        // which applies it as its own call about its own character.
        if let host {
            player?.forwardToPlayer = { [weak host] id, name, arguments in
                host?.send(.call(name: name, arguments: arguments), toPlayer: id)
            }
        }
        // Chat: what this player says goes to the game; what others say comes in as
        // TextChatService.MessageReceived. The game echoes this player's own lines.
        let name = PlayerProfile.tidy(profile.name)
        if let host {
            player?.sendChat = { [weak host] text in host?.chat(from: name, text: text) }
            host.onChat = { [weak self] from, text in self?.player?.receiveChat(from: from, text: text) }
            host.onAction = { [weak self] id, name, arguments in self?.player?.remoteAction(from: id, name, arguments) }
        } else if let membership {
            player?.sendChat = { [weak membership] text in membership?.chat(text) }
            membership.onChat = { [weak self] from, text in self?.player?.receiveChat(from: from, text: text) }
            player?.sendAction = { [weak membership] name, arguments in membership?.action(name, arguments) }
        }
        membership?.onCall = { [weak self] name, arguments in
            guard let player = self?.player else { return }
            _ = player.playerInvoke(name, [.number(Double(player.characterGeneration))] + arguments)
        }
        syncTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / LAN.updatesPerSecond, repeats: true) { [weak self] _ in
            self?.syncNetwork()
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    /// One exchange with the game: where this player's character is goes out, and the
    /// others' come in to be drawn.
    func syncNetwork() {
        guard let player else { return }
        let own = player.networkState(name: PlayerProfile.tidy(profile.name))
        if let host {
            let now = model.sharedState
            let delta = SceneDelta.between(shared, now)
            if !delta.isEmpty {
                host.broadcast(delta)
                shared = now
            }
            host.share(own)
            player.remotePlayers = host.others
        } else if let membership {
            if membership.connected { membership.send(own) }
            player.remotePlayers = membership.others
        }
    }

    /// Calls back once the host has said who is in the game, or after a second.
    private static func awaitPlayers(_ membership: LANMembership, then body: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(1)
        func check() {
            if !membership.others.isEmpty || !membership.connected || Date() > deadline {
                body()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
            }
        }
        check()
    }

    /// Joins a game found on the network, playing the host's scene once it arrives.
    func join(_ game: LANGame) {
        guard joining == nil else { return }
        guard game.compatible else {
            problem = "\(game.name) is running a different version of Studio."
            return
        }
        joining = game.name
        problem = nil
        LANJoin.join(game.endpoint, as: profile) { [weak self] result in
            guard let self else { return }
            self.joining = nil
            switch result {
            case .success(let welcome):
                // Who is already here comes with the host's next update; wait for it (a
                // moment), so the game starts with them in it rather than announcing them.
                Self.awaitPlayers(welcome.membership) { [weak self] in
                    guard let self else { return }
                    do {
                        // The host's scene exactly: its HUD, or none.
                        try self.load(welcome.scene, named: welcome.sceneName, upgrading: false)
                        self.membership = welcome.membership
                        welcome.membership.onScene = { [weak self] delta in
                            guard let self, self.player != nil else { return }
                            delta.apply(to: self.model)
                        }
                        self.play()
                        self.startSyncing()
                    } catch {
                        welcome.membership.leave()
                        self.problem = "The host's scene couldn't be opened."
                    }
                }
            case .failure(LANError.refused(let reason)):
                self.problem = reason
            case .failure:
                self.problem = "Couldn't reach \(game.name)."
            }
        }
    }
}
