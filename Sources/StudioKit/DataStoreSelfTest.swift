import Foundation
import simd

/// DataStoreService: places keeping an id of their own (old files given one from where
/// they are); what's saved kept on disk, by place, store and scope; the Luau API — tables
/// read back as copies, UpdateAsync, IncrementAsync, RemoveAsync, ordered stores in pages
/// — refusing what Roblox can't store, and LocalScripts; what's saved still there the next
/// time the place is played; the three sample games carrying on where you left off; and
/// in a network game, the host keeping each player's progress, a joined player none.
enum DataStoreSelfTest {
    static func run(check: Checker) {
        testPlaceIDs(check)
        testFiles(check)
        testLuau(check)
        testNextTime(check)
        testCompletion(check)
        testReadme(check)
        testSampleGames(check)
        testTogether(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func line(_ session: PlayController, _ prefix: String) -> String {
        said(session).first { $0.hasPrefix(prefix) } ?? "(nothing said)"
    }

    private static func gui(_ session: PlayController, _ name: String) -> GuiObject? {
        session.gui.objects.values.first { $0.name == name }
    }

    private static func stat(_ model: SceneModel, _ name: String, of player: Int = 0) -> Double? {
        guard let folder = model.dataObjects.first(where: { $0.name == "leaderstats" && $0.parent == .player(player) })
        else { return nil }
        return model.dataObjects.first { $0.name == name && $0.parent == .node(folder.id) }?.number
    }

    /// A scene with nothing in it but these scripts, the first a server Script.
    private static func place(_ sources: [(String, ScriptHost)]) -> SceneModel {
        let model = SceneModel()
        model.scripts = sources.enumerated().map { index, entry in
            var script = ScriptObject.blank(language: .luau)
            script.name = "Script\(index + 1)"
            script.host = entry.1
            script.source = entry.0
            return script
        }
        return model
    }

    private static func played(_ model: SceneModel, seconds: Float = 0.3) -> PlayController {
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: seconds)
        return session
    }

    // MARK: - Place ids

    private static func testPlaceIDs(_ check: Checker) {
        print("\nDataStores: which place is which")
        let one = SceneModel(), two = SceneModel()
        check("a new place has an id of its own", one.placeID != nil && one.placeID != two.placeID)
        let before = one.placeID
        one.clearScene()
        check("…and New Scene makes another", one.placeID != nil && one.placeID != before)
        let saved = (try? one.encodeScene()).flatMap { data in
            let reopened = SceneModel()
            try? reopened.loadScene(from: data)
            return reopened.placeID
        }
        check("it's saved with the place, and opened again", saved == one.placeID)
        check("joined players' copies have it too (their games save nothing)", one.sharedState.placeID == one.placeID)

        // A file from before places had ids.
        let old = SceneModel()
        var state = old.state
        state.placeID = nil
        let data = (try? JSONEncoder().encode(state)) ?? Data()
        let file = URL(fileURLWithPath: "/Places/Old Place.studio")
        let opened = SceneModel()
        let document = SceneDocument(model: opened)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DataStoreSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let onDisk = folder.appendingPathComponent("Old Place.studio")
        try? data.write(to: onDisk)
        try? document.open(onDisk)
        let first = opened.placeID
        check("an old file gets one from where it is, without being marked edited", first != nil && !document.isDirty)
        try? document.open(onDisk)
        check("…the same one each time it's opened", opened.placeID == first)
        let elsewhere = SceneModel()
        try? elsewhere.loadScene(from: data)
        elsewhere.ensurePlaceID(from: file)
        check("…and a different one for a file somewhere else", elsewhere.placeID != first)
        try? FileManager.default.removeItem(at: folder)

        check("the sample games keep theirs wherever they're opened",
              AdventureIsland.state().placeID == AdventureIsland.placeID && Nightfall.state().placeID == Nightfall.placeID
              && MegaObby.state().placeID == MegaObby.placeID
              && Set([AdventureIsland.placeID, Nightfall.placeID, MegaObby.placeID]).count == 3)
        let fromTemplate = SceneModel()
        fromTemplate.loadTemplate(.megaObby)
        check("…opened from the home page too", fromTemplate.placeID == MegaObby.placeID)
    }

    // MARK: - Files

    private static func testFiles(_ check: Checker) {
        print("\nDataStores: kept on disk")
        let files = DataStoreFiles.shared
        let place = UUID(), other = UUID()
        files.set(.number(3), place: place, store: "Coins", scope: "global", key: "player_Robin")
        files.set(.list([.string("$t"), .string("Stage"), .number(7)]), place: place, store: "Progress",
                  scope: "global", key: "player_Robin")
        files.set(.string("elsewhere"), place: other, store: "Coins", scope: "global", key: "player_Robin")
        files.set(.string("a scope"), place: place, store: "Coins", scope: "Test/..", key: "player_Robin")
        check("a value is kept by place, store, scope and key",
              files.value(place: place, store: "Coins", scope: "global", key: "player_Robin") == .number(3)
              && files.value(place: other, store: "Coins", scope: "global", key: "player_Robin") == .string("elsewhere")
              && files.value(place: place, store: "Coins", scope: "Test/..", key: "player_Robin") == .string("a scope"))
        let folder = files.directory.appendingPathComponent(place.uuidString)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check("…a file for each store and scope, named safely", names.count == 3 && names.contains("Coins@global.json")
              && !names.contains { $0.contains("/") }, "\(names)")

        // Read back by a fresh reader, as the next time Studio opens would.
        let saved = files.directory
        files.directory = saved
        check("…and read back from disk", files.value(place: place, store: "Progress", scope: "global", key: "player_Robin")
              == .list([.string("$t"), .string("Stage"), .number(7)]))
        check("removing a key hands back what it held",
              files.remove(place: place, store: "Coins", scope: "global", key: "player_Robin") == .number(3)
              && files.value(place: place, store: "Coins", scope: "global", key: "player_Robin") == nil)
        check("a store with nothing left has no file",
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Coins@global.json").path))
        check("there's saved data for a place", files.hasData(place: place) && !files.hasData(place: UUID()))
        files.clear(place: place)
        check("clearing a place forgets all of it, and only it", !files.hasData(place: place)
              && files.value(place: place, store: "Progress", scope: "global", key: "player_Robin") == nil
              && files.value(place: other, store: "Coins", scope: "global", key: "player_Robin") == .string("elsewhere"))
        files.clear(place: other)
    }

    // MARK: - Luau

    static let serverTest = """
    local DataStoreService = game:GetService("DataStoreService")
    local store = DataStoreService:GetDataStore("Test")
    print("same store", DataStoreService:GetDataStore("Test") == store, store.Name, store.ClassName, store:IsA("GlobalDataStore"))
    print("nothing yet", store:GetAsync("missing") == nil)
    store:SetAsync("profile", { Name = "Robin", Level = 3, Items = { "Sword", "Shield" }, Flags = { Tutorial = true } })
    local profile = store:GetAsync("profile")
    print("read back", profile.Name, profile.Level, #profile.Items, profile.Items[2], profile.Flags.Tutorial)
    profile.Level = 99
    print("a copy", store:GetAsync("profile").Level)
    print("update", store:UpdateAsync("profile", function(old) old.Level += 1 return old end).Level, store:GetAsync("profile").Level)
    print("cancelled", store:UpdateAsync("profile", function() return nil end), store:GetAsync("profile").Level)
    print("increment", store:IncrementAsync("coins", 5), store:IncrementAsync("coins"), store:IncrementAsync("coins", -2.5))
    print("removed", store:RemoveAsync("coins"), store:GetAsync("coins"))
    store:SetAsync(7, "seven")
    print("number key", store:GetAsync("7"))
    print("scopes apart", DataStoreService:GetDataStore("Test", "other"):GetAsync("profile") == nil)
    local function fails(f)
    \tlocal ok, message = pcall(f)
    \treturn if ok then "no error" else message
    end
    print("instance:", fails(function() store:SetAsync("x", workspace) end))
    print("vector:", fails(function() store:SetAsync("x", Vector3.new(1, 2, 3)) end))
    print("function:", fails(function() store:SetAsync("x", { f = print }) end))
    print("nan:", fails(function() store:SetAsync("x", 0 / 0) end))
    print("mixed:", fails(function() store:SetAsync("x", { 1, 2, name = "three" }) end))
    local loop = {}
    loop.again = loop
    print("cycle:", fails(function() store:SetAsync("x", loop) end))
    print("nil:", fails(function() store:SetAsync("x", nil) end))
    print("long key:", fails(function() store:GetAsync(string.rep("k", 51)) end))
    print("increment text:", fails(function() store:SetAsync("word", "hi") store:IncrementAsync("word") end))
    print("nothing bad written", store:GetAsync("x") == nil)

    local scores = DataStoreService:GetOrderedDataStore("Scores")
    for index, name in { "Ana", "Ben", "Cy", "Dee", "Eve", "Fin", "Gus" } do
    \tscores:SetAsync(name, index * 10)
    end
    print("whole numbers only:", fails(function() scores:SetAsync("Hal", 1.5) end))
    local pages = scores:GetSortedAsync(false, 3)
    local seen = {}
    while true do
    \tlocal names = {}
    \tfor _, entry in pages:GetCurrentPage() do
    \t\ttable.insert(names, entry.key .. "=" .. entry.value)
    \tend
    \ttable.insert(seen, table.concat(names, ","))
    \tif pages.IsFinished then
    \t\tbreak
    \tend
    \tpages:AdvanceToNextPageAsync()
    end
    print("pages", table.concat(seen, " | "))
    local between = scores:GetSortedAsync(true, 10, 20, 40):GetCurrentPage()
    print("between", #between, between[1].key, between[3].key)
    print("ordered apart", DataStoreService:GetDataStore("Scores"):GetAsync("Ana") == nil, scores:IsA("OrderedDataStore"))
    DataStoreService:GetGlobalDataStore():SetAsync("hello", "world")
    print("global", DataStoreService:GetGlobalDataStore():GetAsync("hello"))
    """

    private static func testLuau(_ check: Checker) {
        print("\nDataStores: from Luau")
        let model = place([(serverTest, .scene), ("""
        local ok, message = pcall(function()
        \treturn game:GetService("DataStoreService"):GetDataStore("Test")
        end)
        print("from a LocalScript", ok, message)
        """, .starterPlayer)])
        let session = played(model)
        check("GetDataStore: the same store each time, a DataStore",
              line(session, "same store") == "same store true Test DataStore true", line(session, "same store"))
        check("nothing saved reads as nil", line(session, "nothing yet") == "nothing yet true")
        check("a table saved reads back", line(session, "read back") == "read back Robin 3 2 Shield true",
              line(session, "read back"))
        check("…a copy each time", line(session, "a copy") == "a copy 3")
        check("UpdateAsync changes it, and hands back what it saved", line(session, "update") == "update 4 4",
              line(session, "update"))
        check("…or leaves it, given nil", line(session, "cancelled") == "cancelled nil 4")
        check("IncrementAsync counts up and down in whole numbers", line(session, "increment") == "increment 5 6 4",
              line(session, "increment"))
        check("RemoveAsync hands back what it held", line(session, "removed") == "removed 4 nil")
        check("a number is a key as its text", line(session, "number key") == "number key seven")
        check("scopes are apart", line(session, "scopes apart") == "scopes apart true")
        let refusals: [(String, String)] = [
            ("instance:", "104: Cannot store Instance in data store"),
            ("vector:", "104: Cannot store Vector3 in data store"),
            ("function:", "104: Cannot store function in data store"),
            ("nan:", "104: Cannot store NaN or infinity in data store"),
            ("mixed:", "104: Cannot store a table with both list and name keys"),
            ("cycle:", "104: Cannot store a table that contains itself"),
            ("nil:", "Argument 2 missing or nil"),
            ("long key:", "103: Key name exceeds the 50 character limit"),
            ("increment text:", "IncrementAsync can only increment a whole number"),
            ("whole numbers only:", "104: OrderedDataStore values must be whole numbers"),
        ]
        let wrong = refusals.filter { !line(session, $0.0).contains($0.1) }.map { line(session, $0.0) }
        check("what Roblox can't store is refused, saying why", wrong.isEmpty, "\(wrong)")
        check("…and not written", line(session, "nothing bad written") == "nothing bad written true")
        check("an OrderedDataStore's pages, highest first",
              line(session, "pages") == "pages Gus=70,Fin=60,Eve=50 | Dee=40,Cy=30,Ben=20 | Ana=10", line(session, "pages"))
        check("…lowest first, between two values", line(session, "between") == "between 3 Ben Dee", line(session, "between"))
        check("…apart from a DataStore of the same name", line(session, "ordered apart") == "ordered apart true true")
        check("GetGlobalDataStore", line(session, "global") == "global world")
        check("a LocalScript can't use them", line(session, "from a LocalScript").hasPrefix("from a LocalScript false")
              && line(session, "from a LocalScript").hasSuffix("DataStore can't be accessed from client"),
              line(session, "from a LocalScript"))
        check("no other errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()

        // Studio's Run mode is the server too.
        let running = place([("""
        local store = game:GetService("DataStoreService"):GetDataStore("Run")
        store:SetAsync("n", 1)
        print("in Run mode", store:GetAsync("n"))
        """, .scene)])
        let run = PlayController(model: running, console: ScriptConsole(), withPlayer: false)
        run.start()
        step(run, seconds: 0.2)
        check("…and in Run mode, with no player", line(run, "in Run mode") == "in Run mode 1", line(run, "in Run mode"))
        run.stop()
        DataStoreFiles.shared.clear(place: model.placeID!)
        DataStoreFiles.shared.clear(place: running.placeID!)
    }

    // MARK: - Next time

    private static func testNextTime(_ check: Checker) {
        print("\nDataStores: next time")
        let counter = """
        local visits = game:GetService("DataStoreService"):GetDataStore("Visits")
        print("visit", visits:IncrementAsync("count"))
        """
        let model = place([(counter, .scene)])
        let snapshot = model.state
        var said: [String] = []
        for _ in 0..<3 {
            model.state = snapshot
            let session = played(model, seconds: 0.2)
            said.append(line(session, "visit"))
            session.stop()
        }
        check("what's saved is there the next time the place is played", said == ["visit 1", "visit 2", "visit 3"], "\(said)")
        let copy = SceneModel()
        copy.state = snapshot
        let reopened = played(copy, seconds: 0.2)
        check("…and when it's saved and opened again", line(reopened, "visit") == "visit 4")
        reopened.stop()
        let different = place([(counter, .scene)])
        let elsewhere = played(different, seconds: 0.2)
        check("another place has its own", line(elsewhere, "visit") == "visit 1")
        elsewhere.stop()
        DataStoreFiles.shared.clear(place: model.placeID!)
        let cleared = played(copy, seconds: 0.2)
        check("Clear Saved Data starts it again", line(cleared, "visit") == "visit 1")
        cleared.stop()
        DataStoreFiles.shared.clear(place: model.placeID!)
        DataStoreFiles.shared.clear(place: different.placeID!)
    }

    // MARK: - Completion

    private static func testCompletion(_ check: Checker) {
        print("\nDataStores: completion")
        func labels(_ source: String) -> [String] {
            LuauCompletion.items(in: source, caret: (source as NSString).length).map { item in
                String(item.label.prefix { $0 != "(" })
            }
        }
        check("GetService offers DataStoreService", labels("game:GetService(\"").contains("DataStoreService"))
        let service = "local DataStoreService = game:GetService(\"DataStoreService\")\n"
        check("…and its methods", Set(["GetDataStore", "GetOrderedDataStore", "GetGlobalDataStore"])
              .isSubset(of: Set(labels(service + "DataStoreService:"))), "\(labels(service + "DataStoreService:"))")
        let store = service + "local store = DataStoreService:GetDataStore(\"Saves\")\nstore:"
        check("a DataStore's", Set(["GetAsync", "SetAsync", "UpdateAsync", "RemoveAsync", "IncrementAsync"])
              .isSubset(of: Set(labels(store))) && !labels(store).contains("GetSortedAsync"), "\(labels(store))")
        let ordered = service + "local scores = DataStoreService:GetOrderedDataStore(\"Scores\")\nscores:"
        check("an OrderedDataStore's", labels(ordered).contains("GetSortedAsync"), "\(labels(ordered))")
    }

    // MARK: - The README

    /// The README's example, as it's written: coins still there next time.
    private static func testReadme(_ check: Checker) {
        print("\nDataStores: the README's example")
        guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
              let start = readme.range(of: "### Saving progress: DataStores"),
              let block = readme[start.upperBound...].components(separatedBy: "```lua\n").dropFirst().first?
                .components(separatedBy: "```").first else {
            print("  (README.md not found from here; skipped)")
            return
        }
        let model = place([(String(block), .scene), ("""
        local Players = game:GetService("Players")
        task.wait(0.2)
        for _, player in Players:GetPlayers() do
        \tplayer.leaderstats.Coins.Value += 5
        end
        """, .scene)])
        let snapshot = model.state
        let first = played(model, seconds: 0.5)
        check("the README's coins are counted", stat(model, "Coins") == 5 && said(first, .error).isEmpty,
              "\(String(describing: stat(model, "Coins"))) \(said(first, .error))")
        first.stop()
        model.state = snapshot
        let second = played(model, seconds: 0.5)
        check("…and still there next time", stat(model, "Coins") == 10 && said(second, .error).isEmpty,
              "\(String(describing: stat(model, "Coins"))) \(said(second, .error))")
        second.stop()
        DataStoreFiles.shared.clear(place: model.placeID!)
    }

    // MARK: - The sample games

    private static func testSampleGames(_ check: Checker) {
        print("\nDataStores: the sample games carry on")
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
        func obby() -> (SceneModel, PlayController) {
            let model = SceneModel()
            model.loadMegaObby()
            return (model, played(model, seconds: 0.6))
        }
        func pad(_ model: SceneModel, _ stage: Int) -> Vec3 {
            model.parts.first { pad in
                pad.name == "Checkpoint"
                    && model.dataObjects.contains { $0.name == "Stage" && $0.parent == .node(pad.id) && $0.number == Double(stage) }
            }?.position ?? .zero
        }
        var (model, session) = obby()
        session.character.position = pad(model, 7) + Vec3(0, 0.6, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.4)
        check("Mega Obby: reaching stage 7", stat(model, "Stage") == 7)
        session.stop()
        (model, session) = obby()
        step(session, seconds: 0.4)
        check("…next time you're on stage 7, at its checkpoint", stat(model, "Stage") == 7
              && simd_distance(session.character.position, pad(model, 7)) < 6, "\(session.character.position)")
        check("…welcomed back", gui(session, "Banner")?.text == "Welcome back! You're on stage 7.",
              "\(String(describing: gui(session, "Banner")?.text))")
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
        (model, session) = obby()
        check("…and cleared, back to stage 1", stat(model, "Stage") == 1)
        session.stop()
        DataStoreFiles.shared.clear(place: MegaObby.placeID)

        // Nightfall: your best, and the top scores.
        DataStoreFiles.shared.clear(place: Nightfall.placeID)
        func nightfall() -> (SceneModel, PlayController) {
            let model = SceneModel()
            NightfallSelfTest.quick(model)
            return (model, played(model, seconds: 0.5))
        }
        (model, session) = nightfall()
        // Night comes quickly; a zombie taken down, then a fall.
        step(session, seconds: 1.5)
        NightfallSelfTest.press(session, "One")
        if let zombie = NightfallSelfTest.zombies(model).first?.id {
            _ = NightfallSelfTest.slay(session, model, zombie: zombie)
        }
        session.humanoid.takeDamage(1000)
        step(session, seconds: 0.5)
        let best = stat(model, "Best") ?? 0
        // The run's summary: the Lines inside RunOver (the HUD has other Lines).
        let summary = session.gui.objects.values.first { $0.name == "RunOver" }
        let lines = session.gui.objects.values.first { $0.name == "Lines" && $0.parent == summary?.id }?.text ?? ""
        check("Nightfall: a run's score is your best, and the top scores list it", best > 0
              && lines.contains("Top scores: Player \(Int(best))"), "\(best) \(lines)")
        session.stop()
        (model, session) = nightfall()
        check("…still your best next time", stat(model, "Best") == best && said(session, .error).isEmpty,
              "\(String(describing: stat(model, "Best"))) \(said(session, .error))")
        session.stop()
        DataStoreFiles.shared.clear(place: Nightfall.placeID)

        // Adventure Island: gems, wins, and what you've earned.
        DataStoreFiles.shared.clear(place: AdventureIsland.placeID)
        func island() -> (SceneModel, PlayController) {
            let model = SceneModel()
            model.loadAdventureIsland()
            return (model, played(model, seconds: 0.5))
        }
        (model, session) = island()
        let gem = model.parts.first { $0.name == "CaveGem" }!
        session.character.position = Vec3(0, 0.4, -106)
        step(session, seconds: 0.4)
        session.character.position = gem.position - Vec3(0, 2.5, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.3)
        let trophy = model.parts.first { $0.name == "Trophy" }!
        session.character.position = trophy.position - Vec3(0, 3, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.5)
        check("Adventure Island: a gem and a win", stat(model, "Gems") == 1 && stat(model, "Wins") == 1
              && session.look.accessories.contains { $0.item == "builtin://PartyHat" })
        session.stop()
        (model, session) = island()
        step(session, seconds: 0.3)
        check("…both still yours next time, the party hat on", stat(model, "Gems") == 1 && stat(model, "Wins") == 1
              && session.look.accessories.contains { $0.item == "builtin://PartyHat" }
              && said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
        DataStoreFiles.shared.clear(place: AdventureIsland.placeID)
    }

    // MARK: - Together

    private static func testTogether(_ check: Checker) {
        print("\nDataStores: a host and a joined player")
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
        let state = MegaObby.state()
        var pads: [Int: Vec3] = [:]
        for pad in state.parts where pad.name == "Checkpoint" {
            if let stage = state.dataObjects.first(where: { $0.name == "Stage" && $0.parent == .node(pad.id) }) {
                pads[Int(stage.number)] = pad.position
            }
        }
        func join() -> (ClientSession, ClientSession)? {
            LANSelfTest.twoPlayers({ model in
                let kept = model.scripts
                model.state = state
                model.scripts += kept
            })
        }
        guard let (hosting, joining) = join(), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1)
        sam.character.position = (pads[4] ?? .zero) + Vec3(0, 0.6, 0)
        sam.character.velocity = .zero
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        let samID = sam.playerID
        check("a joined player reaches stage 4", stat(hosting.model, "Stage", of: samID) == 4)
        let wrote = sam.scripts.invoke("datastore.set", [.string("Sneaky"), .string("global"), .string("k"), .number(1)])
        check("…their own game can't save anything", wrote == .nothing
              && DataStoreFiles.shared.value(place: MegaObby.placeID, store: "Sneaky", scope: "global", key: "k") == nil)
        let errors = said(hosting.player!, .error) + said(sam, .error)
        joining.leaveGame()
        hosting.leaveGame()
        check("the host kept it, by their name",
              DataStoreFiles.shared.value(place: MegaObby.placeID, store: "ObbyProgress", scope: "global", key: "player_Sam")
              != nil && errors.isEmpty, "\(errors)")

        guard let (again, rejoined) = join(), let samAgain = rejoined.player else {
            check("they join again", false)
            return
        }
        LANSelfTest.run([again, rejoined], seconds: 1)
        let samAgainID = samAgain.playerID
        check("joining again, they're on stage 4 and the host on 1",
              stat(again.model, "Stage", of: samAgainID) == 4 && stat(again.model, "Stage", of: 0) == 1
              && stat(rejoined.model, "Stage", of: samAgainID) == 4
              && simd_distance(samAgain.character.position, pads[4] ?? .zero) < 6, "\(samAgain.character.position)")
        check("…and told so on their screen", gui(samAgain, "Banner")?.text == "Welcome back! You're on stage 4.",
              "\(String(describing: gui(samAgain, "Banner")?.text))")
        rejoined.leaveGame()
        again.leaveGame()
        DataStoreFiles.shared.clear(place: MegaObby.placeID)
    }
}
