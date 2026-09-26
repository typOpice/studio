import Foundation
import Network
import simd

/// The client's game picker: where the client starts on its own; the sample games and
/// the Starter Scene with their pictures; places opened here remembered (newest first,
/// once each, not Studio's hand-over copy, gone when the file is); choosing one, on to
/// the menu to play it; back to the picker; the character and join screens returning to
/// where they came from; and a host choosing a game there that a joined player then
/// plays.
enum GamePickerSelfTest {
    static func run(check: Checker) {
        testPicker(check)
        testRecents(check)
        testChoosing(check)
        testTogether(check)
    }

    private static func client() -> ClientSession {
        ClientSession(defaults: LANSelfTest.freshDefaults().0)
    }

    private static func testPicker(_ check: Checker) {
        print("\nGame picker: what it offers")
        let session = client()
        session.showGames()
        check("the client starts on it", session.screen == .games)
        check("…offering the sample games, and the Starter Scene",
              session.games.templates == [.adventure, .nightfall, .megaObby, .starter])
        session.games.refresh(recentURLs: session.recentPlaces, drawNow: true)
        check("…each with its picture", session.games.templates.allSatisfy { session.games.pictures[$0.id] != nil },
              "\(session.games.pictures.keys.sorted())")
        check("…and nothing played here yet", session.games.recents.isEmpty)
    }

    private static func testRecents(_ check: Checker) {
        print("\nGame picker: places played here")
        let (defaults, _) = LANSelfTest.freshDefaults()
        let session = ClientSession(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GamePicker-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = (try? SceneModel().encodeScene()) ?? Data()
        let files = ["Castle", "Race", "Maze"].map { folder.appendingPathComponent("\($0).studio") }
        for file in files { try? data.write(to: file) }
        for file in files { try? session.open(file) }
        try? session.open(files[0])
        session.showGames()
        check("places opened are there, newest first, each once", session.games.recents.map(\.name) == ["Castle", "Maze", "Race"],
              "\(session.games.recents.map(\.name))")
        let handover = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(LaunchClient.handoverPrefix)test.json")
        try? data.write(to: handover)
        try? session.open(handover)
        try? FileManager.default.removeItem(at: handover)
        let again = ClientSession(defaults: defaults)
        again.showGames()
        check("…remembered next time, and not Studio's hand-over copy",
              again.games.recents.map(\.name) == ["Castle", "Maze", "Race"], "\(again.games.recents.map(\.name))")
        try? FileManager.default.removeItem(at: files[1])
        again.showGames()
        check("…one that's gone isn't shown", again.games.recents.map(\.name) == ["Castle", "Maze"],
              "\(again.games.recents.map(\.name))")
        again.games.openFile(files[2])
        check("choosing one opens it, on the menu", again.screen == .menu && again.sceneName == "Maze",
              "\(again.screen) \(again.sceneName)")
        again.showGames()
        again.choose(file: folder.appendingPathComponent("Nowhere.studio"))
        check("a file that can't be opened says so, and stays on the picker",
              again.screen == .games && again.problem == "Couldn't open Nowhere.studio", "\(String(describing: again.problem))")
    }

    private static func testChoosing(_ check: Checker) {
        print("\nGame picker: choosing a game")
        let session = client()
        session.showGames()
        session.show(.character)
        session.back()
        check("the character screen comes back to the picker", session.screen == .games)
        session.choose(.megaObby)
        check("choosing Mega Obby: on the menu, with it loaded", session.screen == .menu && session.sceneName == MegaObby.name
              && session.model.placeID == MegaObby.placeID && session.model.parts.contains { $0.name == "Checkpoint" })
        session.show(.join)
        session.back()
        check("…the join screen comes back to the menu", session.screen == .menu)
        session.play()
        for _ in 0..<30 { session.player?.step(dt: 1.0 / 60) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("Play plays it", session.screen == .playing
              && session.player?.console.lines.contains { $0.text.hasPrefix("Mega Obby: 60 stages") } == true,
              "\(session.screen) \(session.player?.console.lines.map(\.text).prefix(5) ?? [])")
        session.showGames()
        check("choosing another game leaves it", session.screen == .games && session.player == nil)
        session.choose(.nightfall)
        check("…for another", session.sceneName == Nightfall.name && session.model.placeID == Nightfall.placeID)
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
    }

    private static func testTogether(_ check: Checker) {
        print("\nGame picker: hosting the game chosen")
        let hosting = client()
        hosting.profile.name = "Robin"
        hosting.showGames()
        hosting.choose(.megaObby)
        hosting.hostOnLAN(advertise: false)
        guard let host = hosting.host, LANSelfTest.wait(until: { host.port != nil }),
              let port = host.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            check("the host starts", false)
            return
        }
        check("the game on the network is the one chosen", host.gameName == "Robin's Mega Obby", host.gameName)
        let joining = client()
        joining.profile.name = "Sam"
        joining.showGames()
        joining.show(.join)
        joining.join(LANGame(name: host.gameName, txt: LANGame.txt(sceneName: hosting.sceneName, players: 0),
                             endpoint: .hostPort(host: LANSelfTest.loopback, port: port)))
        LANSelfTest.wait { joining.screen == .playing }
        LANSelfTest.run([hosting, joining], seconds: 1)
        check("a player joining from the picker plays it", joining.screen == .playing
              && joining.model.parts.filter { $0.name == "Checkpoint" }.count == MegaObby.stages,
              "\(joining.screen)")
        let errors = (hosting.player?.console.lines ?? []).filter { $0.kind == .error }.map(\.text)
            + (joining.player?.console.lines ?? []).filter { $0.kind == .error }.map(\.text)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
    }
}
