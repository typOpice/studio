import Foundation
import Network

/// Multiplayer on the local network. A client can host the scene it is playing: the
/// game is advertised over Bonjour, so other clients on the same network find it
/// without typing an address, and a player who joins says hello with their name and
/// look and gets the host's world back. From then on it is one world: the host runs the
/// scene's scripts and physics and sends what changed, every player sends where their
/// character is and how it is posed, and the host passes everyone's on to everyone.
enum LAN {
    /// The Bonjour service type. It must also be in each app's `NSBonjourServices`.
    static let serviceType = "_studioplay._tcp"
    /// Bumped whenever the messages change; hosts refuse players on another version.
    static let protocolVersion = 15
    /// How often each player says where they are.
    static let updatesPerSecond: Double = 20
    /// A scene is one message; this is far above any real one.
    static let largestMessage = 64 << 20
}

/// What hosts and players say to each other.
enum LANMessage: Codable, Equatable {
    /// A player joining: who they are, which protocol they speak, how they look.
    case hello(name: String, version: Int, colors: BodyColors)
    /// The host's answer: its game, the scene to play (a scene file), who is there, and
    /// the number the player goes by.
    case welcome(game: String, sceneName: String, scene: Data, players: [String], you: Int)
    /// The host said no, and why.
    case refused(reason: String)
    /// Who is in the game now, sent to everyone when someone comes or goes.
    case players([String])
    /// A player's character now, sent to the host many times a second.
    case state(PlayerState)
    /// Every character in the game, host's included, sent by the host to everyone.
    case world([PlayerState])
    /// What changed in the host's world, sent by the host to everyone.
    case scene(SceneDelta)
    /// A host script acting on this player's character — damage, Health, a teleport —
    /// as the host call it made, less the character's number. Sent to that player alone.
    case call(name: String, arguments: [ScriptValue])
    /// A chat message. A player sends it to the host (who fills in `from` with the name
    /// that player said hello with); the host sends it on to everyone else.
    case chat(from: String, text: String)
    /// A joined player asking the host to act for them — equip or drop a tool, click
    /// with one — as the host call it would make there. Sent to the host alone.
    case action(name: String, arguments: [ScriptValue])
}

/// What changed in the host's world since it last said: parts as they are now (new or
/// changed), parts gone, and the other things scripts change as a game runs.
struct SceneDelta: Codable, Equatable {
    var parts: [Part] = []
    var removed: [UUID] = []
    var groups: [SceneGroup]?
    var lighting: LightingSettings?
    var shaders: [ShaderObject]?
    /// Welds and joints, and the attachments they join, whole when any change.
    var attachments: [SceneAttachment]?
    var constraints: [SceneConstraint]?
    /// The screen effects switched on, when that changes.
    var screenShaders: [UUID]?
    /// The Sounds — playing or not — when any changes.
    var sounds: [SceneSound]?
    /// Folders, Value objects (leaderstats among them) and remotes, when any changes.
    var dataObjects: [DataObject]?
    /// Authored and server-created world canvases; each player owns runtime handles.
    var starterGui: [StarterGuiObject]?
    var guiScripts: [ScriptObject]?
    /// The terrain's changed chunks, when any changes.
    var terrain: TerrainPatch?

    var isEmpty: Bool {
        parts.isEmpty && removed.isEmpty && groups == nil && lighting == nil && shaders == nil
            && attachments == nil && constraints == nil && screenShaders == nil && sounds == nil && dataObjects == nil
            && terrain == nil && starterGui == nil && guiScripts == nil
    }

    /// From what was last sent to how things are now. Applying it is idempotent, so a
    /// player who joined in between, holding something newer, comes out the same.
    static func between(_ sent: SceneState, _ now: SceneState) -> SceneDelta {
        var delta = SceneDelta()
        let before = Dictionary(sent.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        delta.parts = now.parts.filter { before[$0.id] != $0 }
        let current = Set(now.parts.map(\.id))
        delta.removed = sent.parts.map(\.id).filter { !current.contains($0) }
        if now.groups != sent.groups { delta.groups = now.groups }
        if now.lighting != sent.lighting { delta.lighting = now.lighting }
        if now.shaders != sent.shaders { delta.shaders = now.shaders }
        if now.attachments != sent.attachments { delta.attachments = now.attachments }
        if now.constraints != sent.constraints { delta.constraints = now.constraints }
        if now.screenShaderIDs != sent.screenShaderIDs { delta.screenShaders = now.screenShaderIDs }
        if now.sounds != sent.sounds { delta.sounds = now.sounds }
        if now.dataObjects != sent.dataObjects { delta.dataObjects = now.dataObjects }
        if now.starterGui != sent.starterGui { delta.starterGui = now.starterGui }
        if now.scripts.filter({ $0.host == .starterGui }) != sent.scripts.filter({ $0.host == .starterGui }) {
            delta.guiScripts = now.scripts.filter { $0.host == .starterGui }.map {
                var script = $0; script.breakpoints = []; script.breakpointConditions = [:]; script.breakpointLogs = [:]
                return script
            }
        }
        delta.terrain = TerrainPatch.between(sent.terrain, now.terrain)
        return delta
    }

    /// Brings a player's copy of the world up to the host's.
    func apply(to model: SceneModel) {
        if !parts.isEmpty || !removed.isEmpty {
            let gone = Set(removed)
            var updated = model.parts.filter { !gone.contains($0.id) }
            var index = Dictionary(updated.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for part in parts {
                if let at = index[part.id] {
                    updated[at] = part
                } else {
                    index[part.id] = updated.count
                    updated.append(part)
                }
            }
            model.parts = updated
        }
        if let groups { model.groups = groups }
        if let lighting { model.lighting = lighting }
        if let shaders { model.shaders = shaders }
        if let attachments { model.attachments = attachments }
        if let constraints { model.constraints = constraints }
        if let screenShaders { model.screenShaderIDs = screenShaders }
        // A joined player's own sounds are theirs; the host's replace the rest.
        if let sounds { model.sounds = sounds + model.sounds.filter(\.local) }
        // The same for data objects: a joined player's LocalScripts' own stay.
        if let dataObjects { model.dataObjects = dataObjects + model.dataObjects.filter(\.local) }
        if let starterGui { model.starterGui = starterGui }
        if let guiScripts { model.scripts = model.scripts.filter { $0.host != .starterGui } + guiScripts }
        if let terrain {
            var copy = model.terrain
            terrain.apply(to: &copy)
            model.terrain = copy
        }
    }
}

/// One player's character, as the others draw it.
struct PlayerState: Codable, Equatable {
    /// 0 is the host; players are numbered as they join.
    var id: Int
    var name: String
    var colors: BodyColors
    /// What they wear.
    var look = AvatarLook()
    /// Where the feet are.
    var position: Vec3
    var yaw: Float
    /// The pose, walking and any animation a script plays included.
    var joints: AvatarJoints
    var dead: Bool
    /// Which of this player's characters it is: it goes up with every respawn.
    var generation: Int = 1
    /// The Humanoid as its player's game has it, for the other games' scripts to read.
    var health: Float = 100
    var maxHealth: Float = 100
    var walkSpeed: Float = 16
    var jumpPower: Float = 50
    var state = "Running"
    /// How the body is moving, and where the Humanoid is asked to go.
    var velocity = Vec3.zero
    var moveDirection = Vec3.zero
    /// The Seat they sit in, if any, and — a VehicleSeat — how their keys drive it.
    var seat: UUID?
    var throttle: Float = 0
    var steer: Float = 0
}

enum LANError: Error, Equatable {
    case messageTooLarge(Int)
    case refused(String)
    case closed
}

/// Messages on a TCP stream: each one a four-byte big-endian length, then that much JSON.
enum LANFraming {
    static func frame(_ message: LANMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= LAN.largestMessage else { throw LANError.messageTooLarge(body.count) }
        let length = UInt32(body.count)
        return Data([UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            + body
    }

    /// Takes every whole message off the front of `buffer`, leaving a partial one there
    /// for the rest of it to arrive.
    static func messages(from buffer: inout Data) throws -> [LANMessage] {
        var messages: [LANMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start ..< start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= LAN.largestMessage else { throw LANError.messageTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: start + 4 ..< start + 4 + length)
            buffer.removeSubrange(start ..< start + 4 + length)
            messages.append(try JSONDecoder().decode(LANMessage.self, from: body))
        }
        return messages
    }
}

/// One connection carrying messages, both ways. Everything happens on the main queue.
final class LANLink {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((LANMessage) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
                self?.receive()
            case .failed(let error):
                self?.close(error)
            case .cancelled:
                self?.close(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: LANMessage) {
        guard !closed, let data = try? LANFraming.frame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends a last message, then closes once it is on its way — closing straight after
    /// `send` would throw it away unsent.
    func sendAndClose(_ message: LANMessage) {
        guard !closed, let data = try? LANFraming.frame(message) else { return close() }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        })
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    for message in try LANFraming.messages(from: &self.buffer) {
                        self.onMessage?(message)
                    }
                } catch {
                    self.close(error)
                    return
                }
            }
            if complete || error != nil {
                self.close(error)
            } else {
                self.receive()
            }
        }
    }
}

/// A game found on the network.
struct LANGame: Identifiable, Equatable {
    /// The host's game name, which Bonjour keeps unique on the network.
    let name: String
    let sceneName: String
    let players: Int
    let version: Int
    let endpoint: NWEndpoint

    var id: String { name }
    var compatible: Bool { version == LAN.protocolVersion }

    init(name: String, txt: [String: String], endpoint: NWEndpoint) {
        self.name = name
        sceneName = txt["scene"] ?? "Unknown scene"
        players = Int(txt["players"] ?? "") ?? 0
        version = Int(txt["version"] ?? "") ?? 0
        self.endpoint = endpoint
    }

    init?(result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }
        self.init(name: name, txt: txt, endpoint: result.endpoint)
    }

    /// What a host advertises alongside its name.
    static func txt(sceneName: String, players: Int) -> [String: String] {
        ["scene": sceneName, "players": String(players), "version": String(LAN.protocolVersion)]
    }
}

/// Hosts a game on the local network: advertised over Bonjour, taking players in over
/// TCP. Each player who says hello gets the scene to play; everyone hears who is there.
final class LANHost: ObservableObject {
    let gameName: String
    @Published private(set) var players: [String] = []
    @Published private(set) var port: UInt16?
    @Published private(set) var failure: String?
    /// Everyone else's characters, as the host draws them.
    @Published private(set) var others: [PlayerState] = []

    private let sceneName: String
    private let scene: () -> Data
    private var listener: NWListener?
    private var advertised = false
    /// Every open connection, the name it said hello with and the number it was given.
    private var links: [ObjectIdentifier: (link: LANLink, name: String?, id: Int, colors: BodyColors)] = [:]
    private var nextID = 1
    /// The latest from each joined player, by number.
    private var states: [Int: PlayerState] = [:]
    /// Called with each chat message a joined player sends: who, and what.
    var onChat: ((String, String) -> Void)?
    /// Called when a joined player asks the host to act for them: their number, the
    /// call and its arguments.
    var onAction: ((Int, String, [ScriptValue]) -> Void)?

    /// `scene` is asked for when someone joins, so they get it as it is then.
    init(gameName: String, sceneName: String, scene: @escaping () -> Data) {
        self.gameName = gameName
        self.sceneName = sceneName
        self.scene = scene
    }

    /// Starts listening. `advertise: false` skips Bonjour — for the self-tests, which
    /// connect straight to the port over loopback.
    func start(advertise: Bool = true) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        advertised = advertise
        if advertise { listener.service = service() }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.port = listener?.port?.rawValue
            case .failed(let error): self?.failure = "\(error)"
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        for entry in links.values { entry.link.close() }
        links = [:]
        listener?.cancel()
        listener = nil
        port = nil
        players = []
    }

    private func service() -> NWListener.Service {
        NWListener.Service(name: gameName, type: LAN.serviceType, domain: nil,
                           txtRecord: NWTXTRecord(LANGame.txt(sceneName: sceneName, players: players.count)))
    }

    private func accept(_ connection: NWConnection) {
        let link = LANLink(connection)
        let key = ObjectIdentifier(link)
        links[key] = (link, nil, nextID, BodyColors())
        nextID += 1
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, let entry = self.links[key] else { return }
            if case .state(var state) = message, let name = entry.name {
                // Who a player is comes from their hello, not from what they claim now.
                state.id = entry.id
                state.name = name
                state.colors = entry.colors
                self.states[entry.id] = state
                return
            }
            if case .action(let name, let arguments) = message, entry.name != nil {
                self.onAction?(entry.id, name, arguments)
                return
            }
            if case .chat(_, let said) = message, let name = entry.name {
                let text = String(said.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PlayController.longestChat))
                guard !text.isEmpty else { return }
                self.chat(from: name, text: text, except: key)
                self.onChat?(name, text)
                return
            }
            guard case .hello(let name, let version, let colors) = message else { return }
            guard version == LAN.protocolVersion else {
                link.sendAndClose(.refused(reason: "This game speaks version \(LAN.protocolVersion); you have \(version)."))
                return
            }
            self.links[key]?.name = PlayerProfile.tidy(name)
            self.links[key]?.colors = colors
            self.refreshPlayers()
            link.send(.welcome(game: self.gameName, sceneName: self.sceneName, scene: self.scene(),
                               players: self.players, you: entry.id))
        }
        link.onClose = { [weak self] _ in
            guard let self else { return }
            if let id = self.links[key]?.id { self.states[id] = nil }
            self.links[key] = nil
            self.refreshPlayers()
            self.others = self.states.values.sorted { $0.id < $1.id }
        }
        link.start()
    }

    /// A message for one player only.
    func send(_ message: LANMessage, toPlayer id: Int) {
        for entry in links.values where entry.id == id && entry.name != nil { entry.link.send(message) }
    }

    /// What changed in the world, to everyone in the game.
    func broadcast(_ delta: SceneDelta) {
        for entry in links.values where entry.name != nil { entry.link.send(.scene(delta)) }
    }

    /// A chat message to everyone in the game (but the player it came from, who has it).
    func chat(from name: String, text: String, except sender: ObjectIdentifier? = nil) {
        let message = LANMessage.chat(from: name, text: String(text.prefix(PlayController.longestChat)))
        for (key, entry) in links where entry.name != nil && key != sender { entry.link.send(message) }
    }

    /// The host's own character, many times a second: everyone gets every character, and
    /// the host's `others` is brought up to date.
    func share(_ own: PlayerState) {
        var own = own
        own.id = 0
        let everyone = [own] + states.values.sorted { $0.id < $1.id }
        for entry in links.values where entry.name != nil { entry.link.send(.world(everyone)) }
        others = Array(everyone.dropFirst())
    }

    private func refreshPlayers() {
        let now = links.values.compactMap(\.name).sorted()
        guard now != players else { return }
        players = now
        for entry in links.values where entry.name != nil { entry.link.send(.players(now)) }
        // Browsers show how many are in.
        if advertised { listener?.service = service() }
    }
}

/// Looks for games on the local network, keeping `games` up to date as hosts come and go.
final class LANBrowser: ObservableObject {
    @Published private(set) var games: [LANGame] = []
    @Published private(set) var looking = false
    @Published private(set) var failure: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LAN.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.games = results.compactMap(LANGame.init(result:)).sorted { $0.name < $1.name }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.looking = true; self?.failure = nil
            case .failed(let error): self?.looking = false; self?.failure = "\(error)"
            case .waiting(let error): self?.failure = "\(error)"
            default: break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        looking = false
        games = []
    }
}

/// A player's side of a game they joined.
final class LANMembership: ObservableObject {
    let game: String
    /// The number the host gave this player.
    let id: Int
    @Published private(set) var players: [String] = []
    @Published private(set) var connected = true
    /// Everyone else's characters, host's included.
    @Published private(set) var others: [PlayerState] = []
    /// Called with each change to the host's world.
    var onScene: ((SceneDelta) -> Void)?
    /// Called when a host script acts on this player's character.
    var onCall: ((String, [ScriptValue]) -> Void)?
    /// Called with each chat message from someone else in the game: who, and what.
    var onChat: ((String, String) -> Void)?
    private let link: LANLink

    fileprivate init(game: String, id: Int, players: [String], link: LANLink) {
        self.game = game
        self.id = id
        self.players = players
        self.link = link
        link.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .players(let now): self.players = now
            case .world(let everyone): self.others = everyone.filter { $0.id != self.id }
            case .scene(let delta): self.onScene?(delta)
            case .call(let name, let arguments): self.onCall?(name, arguments)
            case .chat(let from, let text): self.onChat?(from, text)
            default: break
            }
        }
        link.onClose = { [weak self] _ in
            self?.connected = false
            self?.others = []
        }
    }

    /// This player's character now, for the host to pass on.
    func send(_ state: PlayerState) {
        var state = state
        state.id = id
        link.send(.state(state))
    }

    /// Asks the host to act for this player.
    func action(_ name: String, _ arguments: [ScriptValue]) {
        link.send(.action(name: name, arguments: arguments))
    }

    /// A chat message from this player, for the host to pass on.
    func chat(_ text: String) {
        link.send(.chat(from: "", text: text))
    }

    func leave() { link.close() }
}

/// Joining a game: connect, say hello, and wait for the welcome with the scene.
enum LANJoin {
    struct Welcome {
        let membership: LANMembership
        let sceneName: String
        let scene: Data
    }

    static func join(_ endpoint: NWEndpoint, as profile: PlayerProfile,
                     completion: @escaping (Result<Welcome, Error>) -> Void) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let link = LANLink(NWConnection(to: endpoint, using: parameters))
        var finished = false
        func finish(_ result: Result<Welcome, Error>) {
            guard !finished else { return }
            finished = true
            completion(result)
        }
        link.onReady = {
            link.send(.hello(name: PlayerProfile.tidy(profile.name), version: LAN.protocolVersion, colors: profile.colors))
        }
        link.onMessage = { message in
            switch message {
            case .welcome(let game, let sceneName, let scene, let players, let you):
                finish(.success(Welcome(membership: LANMembership(game: game, id: you, players: players, link: link),
                                        sceneName: sceneName, scene: scene)))
            case .refused(let reason):
                finish(.failure(LANError.refused(reason)))
                link.close()
            default:
                break
            }
        }
        link.onClose = { error in finish(.failure(error ?? LANError.closed)) }
        link.start()
    }
}
