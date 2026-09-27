import Foundation
import AppKit
import simd

/// Studio's home page: the templates (built, opened as new places, the Obby played alone
/// and by a host and a joined player), the recent places, the pictures and their cache,
/// opening from the page, and File › Home.
enum HomeSelfTest {
    static func run(check: Checker) {
        _ = NSApplication.shared
        testTemplates(check)
        testObby(check)
        testObbyTogether(check)
        testRecents(check)
        testPictures(check)
        testOpening(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    private static func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func part(_ state: SceneState, _ name: String) -> Part? { state.parts.first { $0.name == name } }

    /// The same place, built twice: the same things by name (the ids are new each time).
    private static func sameShape(_ a: SceneState, _ b: SceneState) -> Bool {
        a.parts.map(\.name) == b.parts.map(\.name) && a.scripts.map(\.name) == b.scripts.map(\.name)
            && a.shaders.map(\.name) == b.shaders.map(\.name)
    }

    // MARK: - Templates

    private static func testTemplates(_ check: Checker) {
        print("\nHome: the templates")
        check("five to start from and three sample games", PlaceTemplate.starters == [.baseplate, .obby, .starter, .terrain, .empty]
              && PlaceTemplate.samples == [.adventure, .nightfall, .megaObby] && PlaceTemplate.allCases.count == 8)
        check("the sample games say what's in them", PlaceTemplate.samples.allSatisfy { $0.tags.count >= 4 })
        check("each has a title, a line about it and a symbol", PlaceTemplate.allCases.allSatisfy {
            !$0.title.isEmpty && !$0.summary.isEmpty && NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil
        })
        func hasBasics(_ state: SceneState) -> Bool {
            state.scripts.contains { $0.name == UtilsModule.name && $0.isModule && $0.host == .replicatedStorage }
                && state.defaultGui == DefaultHud.version && state.dataObjects.isEmpty
        }
        let baseplate = PlaceTemplate.baseplate.state()
        let plate = part(baseplate, "Baseplate")
        check("Baseplate: a locked, anchored baseplate whose top is just above the grid, and a spawn pad",
              plate?.locked == true && plate?.anchored == true && abs((plate?.position.y ?? 0) + 0.5 - 0.2) < 1e-4
              && part(baseplate, "SpawnPad") != nil && baseplate.parts.count == 2)
        check("…with the HUD and Utils, as every new place has", hasBasics(baseplate))
        let obby = PlaceTemplate.obby.state()
        let course = obby.groups.first { $0.name == "Course" }
        let inCourse = obby.parts.filter { $0.parentID == course?.id }.map(\.name)
        check("Obby: a Course of jumps, kill bricks, checkpoints, a start and a finish",
              inCourse.filter { $0 == "KillBrick" }.count == 2 && inCourse.filter { $0 == "Checkpoint" }.count == 2
              && inCourse.contains("Start") && inCourse.contains("Finish"), "\(inCourse)")
        check("…its script, the HUD and Utils", obby.scripts.contains { $0.name == "ObbyScript" && $0.source == PlaceTemplate.obbyScript }
              && hasBasics(obby))
        check("Starter Scene is the scene Studio always had", sameShape(PlaceTemplate.starter.state(), SceneModel().state))
        let empty = PlaceTemplate.empty.state()
        check("Empty: no parts, just the HUD and Utils", empty.parts.isEmpty && hasBasics(empty))
        check("Adventure Island is itself", PlaceTemplate.adventure.state().parts.count == AdventureIsland.state().parts.count)
        check("so is Nightfall", PlaceTemplate.nightfall.state().parts.count == Nightfall.state().parts.count)

        let model = SceneModel()
        model.selection = Set(model.parts.prefix(1).map(\.id))
        model.loadTemplate(.obby)
        check("a template opens as a new place: nothing selected, nothing to undo back into",
              model.parts.contains { $0.name == "Finish" } && model.selection.isEmpty && !model.canUndo)
    }

    // MARK: - The Obby, played

    private static func testObby(_ check: Checker) {
        print("\nHome: the Obby template, played")
        let model = SceneModel()
        model.loadTemplate(.obby)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.5)
        let state = model.state
        let start = part(state, "Start")!
        check("you start on the Start", simd_distance(session.character.position, start.position) < 4,
              "\(session.character.position)")
        let checkpoints = state.parts.filter { $0.name == "Checkpoint" }
        session.character.position = checkpoints[0].position + Vec3(0, 0.2, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.3)
        check("a checkpoint says so", said(session).contains { $0.hasSuffix("reached a checkpoint") }, "\(said(session))")
        let kill = state.parts.first { $0.name == "KillBrick" }!
        session.character.position = kill.position + Vec3(0, 0.6, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.3)
        check("a kill brick knocks you out", session.humanoid.isDead)
        step(session, seconds: 2.4)
        check("…and you're back at your checkpoint, two seconds later",
              !session.humanoid.isDead && simd_distance(session.character.position, checkpoints[0].position) < 5,
              "\(session.character.position)")
        let finish = part(state, "Finish")!
        session.character.position = finish.position + Vec3(0, 0.6, 0)
        session.character.velocity = .zero
        step(session, seconds: 0.3)
        let wins = model.dataObjects.first { $0.name == "Wins" }?.number
        check("the finish is a Win on the leaderboard", wins == 1 && said(session).contains { $0.hasSuffix("finished the obby!") },
              "\(String(describing: wins)) \(said(session))")
        step(session, seconds: 1.3)
        check("…then it's back to the start", simd_distance(session.character.position, start.position) < 6,
              "\(session.character.position)")
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    private static func testObbyTogether(_ check: Checker) {
        print("\nHome: the Obby template, with a host and a joined player")
        let obby = PlaceTemplate.obby.state()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            // Keep the test's own (switched-off) ControlScript.
            let kept = model.scripts
            model.state = obby
            model.scripts += kept
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1)
        let kill = obby.parts.first { $0.name == "KillBrick" }!
        sam.character.position = kill.position + Vec3(0, 0.6, 0)
        sam.character.velocity = .zero
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        check("the host's script knocks out a joined player on a kill brick", sam.humanoid.isDead)
        LANSelfTest.run([hosting, joining], seconds: 2.6)
        let finish = obby.parts.first { $0.name == "Finish" }!
        sam.character.position = finish.position + Vec3(0, 0.6, 0)
        sam.character.velocity = .zero
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        check("…and counts their win when they reach the finish", said(host).contains("Sam finished the obby!"),
              "\(said(host))")
        let errors = said(host, .error) + said(sam, .error)
        check("…with no errors on either", errors.isEmpty, "\(errors)")
        joining.leaveGame()
        hosting.leaveGame()
    }

    // MARK: - Recents

    private static func scratchFolder(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StudioHomeTest-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func save(_ template: PlaceTemplate, as name: String, in folder: URL) -> URL {
        let file = folder.appendingPathComponent("\(name).\(SceneDocument.sceneExtension)")
        try? JSONEncoder().encode(template.state()).write(to: file)
        return file
    }

    private static func testRecents(_ check: Checker) {
        print("\nHome: recent places")
        let folder = scratchFolder("Recents")
        let castle = save(.baseplate, as: "Castle", in: folder)
        let race = save(.obby, as: "Race", in: folder)
        let gone = folder.appendingPathComponent("Deleted.\(SceneDocument.sceneExtension)")
        let places = HomeModel.places(from: [race, gone, castle, race])
        check("the recent places that still exist, newest first, once each", places.map(\.name) == ["Race", "Castle"],
              "\(places.map(\.name))")
        check("…no more than twelve", HomeModel.places(from: Array(repeating: race, count: 3)
            + (0..<20).map { save(.empty, as: "Place \($0)", in: folder) }).count == HomeModel.recentLimit)
        let now = Date()
        var place = places[0]
        place.modified = now.addingTimeInterval(-7200)
        check("when each was edited, in words", places[0].edited(relativeTo: now.addingTimeInterval(10)) == "Edited just now"
              && place.edited(relativeTo: now) == "Edited 2 hours ago", place.edited(relativeTo: now))
        let home = FileManager.default.homeDirectoryForCurrentUser
        check("the folder, with the home folder as ~",
              RecentPlace(url: home.appendingPathComponent("Documents/Tower.studioscene")).folder == "~/Documents")
    }

    // MARK: - Pictures

    /// How many different colours a picture has, roughly: a blank one has one.
    private static func variety(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var colours = Set<UInt32>()
        let stride = max(image.bytesPerRow * image.height / 4 / 2000, 1) * 4
        var index = 0
        while index + 3 < data.count {
            colours.insert(UInt32(data[index] >> 4) << 8 | UInt32(data[index + 1] >> 4) << 4 | UInt32(data[index + 2] >> 4))
            index += stride
        }
        return colours.count
    }

    private static func testPictures(_ check: Checker) {
        print("\nHome: pictures of places")
        let folder = scratchFolder("Pictures")
        let thumbnails = PlaceThumbnail.shared
        let kept = thumbnails.directory
        thumbnails.directory = folder.appendingPathComponent("Thumbnails", isDirectory: true)
        defer { thumbnails.directory = kept }

        let baseplate = PlaceTemplate.baseplate
        let picture = thumbnails.image(of: baseplate.state(), camera: baseplate.thumbnailCamera,
                                       character: baseplate.thumbnailCharacter)
        check("a template's picture is drawn", picture?.width == PlaceThumbnail.width && picture.map(variety) ?? 0 > 20,
              "\(picture.map(variety) ?? 0) colours")
        check("an empty place has none", thumbnails.image(of: PlaceTemplate.empty.state()) == nil)
        let framed = PlaceThumbnail.framing(PlaceTemplate.obby.state())
        check("framing a place looks at its parts, not the huge baseplate under them",
              framed.map { abs($0.target.z + 43) < 12 && $0.distance < 200 } == true,
              "\(String(describing: framed?.target)) \(String(describing: framed?.distance))")

        let file = save(.obby, as: "Speedrun", in: folder)
        let before = thumbnails.drawn
        let first = thumbnails.image(ofFile: file)
        let cached = thumbnails.directory.appendingPathComponent((PlaceThumbnail.cacheKey(for: file) ?? "?") + ".png")
        check("a saved place's picture is drawn from its file, and kept", first != nil
              && FileManager.default.fileExists(atPath: cached.path) && thumbnails.drawn == before + 1)
        let again = thumbnails.image(ofFile: file)
        check("…and read back the next time, not drawn again", again?.width == first?.width && thumbnails.drawn == before + 1)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        _ = thumbnails.image(ofFile: file)
        check("…until the file changes", thumbnails.drawn == before + 2)
        check("a file that isn't a place has no picture",
              thumbnails.image(ofFile: folder.appendingPathComponent("nothing.studioscene")) == nil)

        let home = HomeModel()
        home.refresh(recentURLs: [file], drawNow: true)
        check("the page has every picture but the empty place's, and the recent place's",
              PlaceTemplate.allCases.allSatisfy { ($0 == .empty) == (home.pictures[$0.id] == nil) }
              && home.pictures[home.recents[0].id] != nil)
    }

    // MARK: - Opening

    private static func testOpening(_ check: Checker) {
        print("\nHome: opening places from it")
        let delegate = EditorAppDelegate()
        defer { withExtendedLifetime(delegate) {} }
        delegate.wireHome()
        let menu = delegate.makeMainMenu()
        let file = menu.items.first { $0.submenu?.title == "File" }?.submenu
        let homeItem = file?.items.first { $0.title == "Home" }
        check("File › Home, ⇧⌘H", homeItem?.keyEquivalent == "H" && homeItem?.keyEquivalentModifierMask == [.command, .shift])

        let folder = scratchFolder("Opening")
        let saved = save(.obby, as: "Tower", in: folder)
        delegate.showHome(canGoBack: false, recentURLs: [saved])
        let session = delegate.session
        check("the home page shows, with the recent place", session.showingHome && session.home.recents.map(\.name) == ["Tower"]
              && !session.home.canGoBack)
        let duplicate = menu.items.first { $0.submenu?.title == "Edit" }?.submenu?.items.first { $0.title == "Duplicate" }
        let open = file?.items.first { $0.title == "Open…" }
        check("while it shows, editing waits; opening doesn't",
              duplicate.map(delegate.validateMenuItem) == false && open.map(delegate.validateMenuItem) == true
              && homeItem.map(delegate.validateMenuItem) == true)

        session.home.open(.baseplate)
        check("a template opens as a new, untitled place, and the page goes",
              !session.showingHome && delegate.model.parts.contains { $0.name == "Baseplate" }
              && delegate.document.url == nil && !delegate.document.isDirty && !delegate.model.canUndo)
        delegate.showHome(canGoBack: true, recentURLs: [saved])
        check("File › Home comes back over it, with a way back", session.showingHome && session.home.canGoBack
              && session.home.currentName == "Untitled")
        session.home.goBack()
        check("…which goes back to the place as it was", !session.showingHome
              && delegate.model.parts.contains { $0.name == "Baseplate" })
        delegate.showHome(recentURLs: [saved])
        session.home.openFile(saved)
        check("a recent place opens from its file", !session.showingHome && delegate.document.url == saved
              && delegate.model.parts.contains { $0.name == "Finish" })
        delegate.loadStarter()
        check("the starter scene after a file is untitled, so Save won't write over the file",
              delegate.document.url == nil && sameShape(delegate.model.state, PlaceTemplate.starter.state())
              && ((try? Data(contentsOf: saved)).flatMap { try? JSONDecoder().decode(SceneState.self, from: $0) })?
                .parts.contains { $0.name == "Finish" } == true)
        delegate.showHome(recentURLs: [])
        session.home.open(.adventure)
        check("Adventure Island opens from its card", delegate.model.groups.contains { $0.name == "MirrorLab" }
              && delegate.document.url == nil && !session.showingHome)
        delegate.showHome(recentURLs: [])
        session.home.open(.nightfall)
        check("…and Nightfall from its", delegate.model.groups.contains { $0.name == "Graveyard" }
              && delegate.document.url == nil && !session.showingHome)
    }
}
