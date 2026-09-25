import AppKit
import SwiftUI
import simd

/// Verification for pictures and sounds: importing files into the scene, what scripts do
/// with Sound and SoundService, what a play session would have played (through a
/// RecordingOutput — nothing reaches the speakers), ImageLabels showing a picture, and a
/// host's sounds being heard by a joined player.
enum AudioSelfTest {

    static func run(check: Checker) {
        testImport(check)
        testSavingAPlace(check)
        testModelFiles(check)
        testSoundScripts(check)
        testPictures(check)
        testSoundsOverTheNetwork(check)
    }

    private static let frame: Float = 1.0 / 60

    // MARK: - Files made here

    /// A WAV of a 440 Hz tone: 16-bit, mono or stereo.
    static func wav(seconds: Double, rate: Int = 22050, stereo: Bool = false) -> Data {
        let channels = stereo ? 2 : 1
        let frames = Int(seconds * Double(rate))
        var data = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + frames * channels * 2)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(frames * channels * 2)
        for frame in 0..<frames {
            let sample = Int16(sin(2 * Double.pi * 440 * Double(frame) / Double(rate)) * 12000)
            for _ in 0..<channels { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    /// A PNG of one colour.
    static func png(width: Int = 8, height: Int = 8, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    private static func emptyModel() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.assets = []
        model.sounds = []
        model.starterGui = []
        return model
    }

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds - frame / 2 {
            session.step(dt: frame)
            elapsed += frame
        }
    }

    private static func lines(_ console: ScriptConsole, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return console.lines.filter { $0.kind == kind }.map(\.text)
    }

    // MARK: - Importing

    private static func testImport(_ check: Checker) {
        print("\nAssets: importing pictures and sounds")
        let model = emptyModel()
        guard let beep = try? model.importAsset(data: wav(seconds: 0.5), name: "Beep", fileExtension: "WAV"),
              let logo = try? model.importAsset(data: png(red: 1, green: 0, blue: 0), name: "Logo", fileExtension: "png") else {
            check("a sound and a picture can be imported", false)
            return
        }
        check("a sound and a picture can be imported",
              model.asset(id: beep)?.kind == .sound && model.asset(id: logo)?.kind == .image
              && model.asset(id: beep)?.fileExtension == "wav" && model.selectedAsset == logo)
        let again = try? model.importAsset(data: wav(seconds: 0.1), name: "Beep", fileExtension: "wav")
        check("…a second of the same name gets a name of its own",
              again.flatMap { model.asset(id: $0)?.name }.map { $0 != "Beep" && $0.hasPrefix("Beep") } ?? false,
              again.flatMap { model.asset(id: $0)?.name } ?? "nothing")
        var refused: [AssetError] = []
        do { try model.importAsset(data: Data("hello".utf8), name: "Notes", fileExtension: "txt") } catch {
            if let error = error as? AssetError { refused.append(error) }
        }
        do { try model.importAsset(data: Data(count: SceneAsset.largest + 1), name: "Huge", fileExtension: "png") } catch {
            if let error = error as? AssetError { refused.append(error) }
        }
        check("other files, and files too big, are refused",
              refused == [.unknownKind("txt"), .tooLarge(SceneAsset.largest + 1)] && model.assets.count == 3, "\(refused)")

        check("scripts name them studio://Name, studio://<id>, or just the name",
              model.asset(named: "studio://Beep")?.id == beep && model.asset(named: "Logo")?.id == logo
              && model.asset(named: "studio://" + beep.uuidString)?.id == beep
              && model.asset(named: "studio://Nothing") == nil && model.asset(named: "") == nil
              && model.asset(id: beep)?.reference == "studio://Beep")

        model.renameAsset(logo, to: "  Badge ")
        check("renaming trims, and keeps names apart", model.asset(id: logo)?.name == "Badge")
        model.renameAsset(logo, to: "Beep")
        check("…from each other", model.asset(id: logo)?.name != "Beep")
        model.undo()
        model.undo()
        check("undo puts the name back", model.asset(id: logo)?.name == "Logo")
        model.undo()
        check("…and undoes an import", model.assets.count == 2 && model.asset(id: beep) != nil)
        model.redo()
        check("…and redo brings it back", model.assets.count == 3)

        let soundID = model.addSound(in: nil)
        check("a new Sound plays the first sound asset",
              model.sound(id: soundID)?.soundId == "studio://Beep" && model.selectedSound == soundID)

        // Saved and opened again, they're all there.
        let copy = SceneModel()
        if let saved = try? JSONEncoder().encode(model.state),
           let opened = try? JSONDecoder().decode(SceneState.self, from: saved) {
            copy.state = opened
        }
        check("pictures, sounds and Sounds are saved with the scene",
              copy.assets.map(\.id) == model.assets.map(\.id) && copy.asset(id: logo)?.data == model.asset(id: logo)?.data
              && copy.sounds.map(\.id) == [soundID])
        let older = try? JSONDecoder().decode(SceneState.self, from: JSONEncoder().encode(SceneState()))
        check("…and scenes saved without any open with none", older?.assets.isEmpty == true && older?.sounds.isEmpty == true)

        // Decoding.
        let system = SoundSystem(output: RecordingOutput())
        let length = model.asset(id: beep).flatMap(system.duration(of:)) ?? 0
        check("a sound is decoded, and knows how long it is", abs(length - 0.5) < 0.01, "\(length)")
        let stereo = SceneAsset(name: "Wide", kind: .sound, data: wav(seconds: 0.25, stereo: true), fileExtension: "wav")
        let buffer = system.buffer(for: stereo)
        check("…stereo is mixed down to one channel, so it can be placed",
              buffer?.format.channelCount == 1 && buffer.map { abs(Double($0.frameLength) / $0.format.sampleRate - 0.25) < 0.01 } == true)
        let broken = SceneAsset(name: "Broken", kind: .sound, data: Data("not a sound".utf8), fileExtension: "wav")
        check("…and a file that isn't really a sound doesn't play", system.buffer(for: broken) == nil)
        var full = SceneSound()
        full.volume = 1
        var loud = SceneSound()
        loud.volume = 2
        check("far from its part a sound fades to nothing",
              SoundSystem.heardVolume(full, at: Vec3(0, 0, 50), listener: .zero) == 0.5
              && SoundSystem.heardVolume(full, at: Vec3(0, 0, 150), listener: .zero) == 0
              && SoundSystem.heardVolume(loud, at: nil, listener: Vec3(0, 0, 900)) == 2)

        // A part's Sounds go with it, and come with its copies.
        var speaker = Part()
        speaker.name = "Speaker"
        model.parts = [speaker]
        let inPart = model.addSound(in: speaker.id)
        let clone = model.cloneSubtree(speaker.id, parent: nil)
        check("a copied part copies its Sounds",
              clone.map { model.sounds(in: $0).count == 1 && model.sounds(in: $0)[0].id != inPart } ?? false)
        model.removeSubtrees([speaker.id])
        check("…and a deleted part takes them with it", model.sound(id: inPart) == nil && model.sound(id: soundID) != nil)
    }

    // MARK: - Saving

    /// As someone would: a sound file on disk imported, the place saved, the file gone,
    /// and the place opened again — played alone, and hosted for another player.
    private static func testSavingAPlace(_ check: Checker) {
        print("\nAssets: a sound saved in the place")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-place-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Bell.wav")
        let place = folder.appendingPathComponent("Belfry.\(SceneDocument.sceneExtension)")
        let bytes = wav(seconds: 0.4, stereo: true)
        try? bytes.write(to: original)

        let model = emptyModel()
        let document = SceneDocument(model: model)
        var tower = Part()
        tower.name = "Tower"
        tower.position = Vec3(0, 6, -12)
        model.parts = [tower]
        let imported = try? model.importAsset(from: original)
        check("a sound file is uploaded from disk, named after the file",
              imported.flatMap { model.asset(id: $0) }.map { $0.name == "Bell" && $0.kind == .sound && $0.data == bytes } ?? false)
        check("…which leaves the place with changes to save", document.isDirty)
        let soundID = model.addSound(in: tower.id)
        model.updateSound(id: soundID) { $0.name = "Chime"; $0.looped = true; $0.playing = true }

        var saved = false
        do {
            try document.save(to: place)
            saved = true
        } catch {
            check("the place saves", false, "\(error)")
        }
        try? FileManager.default.removeItem(at: original)
        let size = (try? FileManager.default.attributesOfItem(atPath: place.path)[.size] as? Int) ?? 0
        check("the place saves, with the sound file inside it",
              saved && !document.isDirty && size > bytes.count && !FileManager.default.fileExists(atPath: original.path),
              "\(size) bytes for a \(bytes.count)-byte sound")

        let reopened = SceneModel()
        let second = SceneDocument(model: reopened)
        do { try second.open(place) } catch { check("the saved place opens", false, "\(error)") }
        let asset = reopened.asset(named: "studio://Bell")
        let sound = reopened.sound(id: soundID)
        check("opened again, the sound is there byte for byte — with the original file gone",
              asset?.data == bytes && asset?.kind == .sound && asset?.fileExtension == "wav" && !second.isDirty)
        check("…and so is the Sound that plays it, where it was",
              sound.map { $0.name == "Chime" && $0.soundId == "studio://Bell" && $0.parentID == tower.id
                          && $0.looped && $0.playing } ?? false)

        let session = PlayController(model: reopened, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.1)
        let heard = (session.sounds.output as? RecordingOutput)?.playing[soundID]
        check("…and it plays", heard.map { $0.frames == 8820 && $0.position == tower.position && $0.looped } ?? false,
              "\(String(describing: heard))")
        session.stop()

        // The saved place, hosted: the joined player gets the sound in it and hears it.
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            guard let data = try? Data(contentsOf: place),
                  let state = try? JSONDecoder().decode(SceneState.self, from: data) else { return }
            model.parts += state.parts
            model.assets = state.assets
            model.sounds = state.sounds
        }), let player = joining.player else {
            check("the saved place can be hosted", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.3)
        check("hosted, the saved place's sound reaches the joined player and plays there",
              player.model.asset(named: "studio://Bell")?.data == bytes
              && (player.sounds.output as? RecordingOutput)?.playing[soundID] != nil)
        hosting.leaveGame()
        joining.leaveGame()
    }

    /// A Model saved from a selection takes its Sounds and their files with it.
    private static func testModelFiles(_ check: Checker) {
        print("\nAssets: sounds in saved Models")
        let bell = wav(seconds: 0.3)
        let source = emptyModel()
        _ = try? source.importAsset(data: bell, name: "Bell", fileExtension: "wav")
        _ = try? source.importAsset(data: wav(seconds: 0.1), name: "Unused", fileExtension: "wav")
        var tower = Part()
        tower.name = "Tower"
        source.parts = [tower]
        let soundID = source.addSound(in: tower.id)
        var script = ScriptObject.blank(language: .luau)
        script.parentID = tower.id
        script.source = "script.Parent.Sound.SoundId = \"studio://Bell\""
        source.scripts = [script]
        source.selection = [tower.id]
        guard let data = try? SceneDocument(model: source).modelData(name: "Belfry"),
              let file = try? JSONDecoder().decode(ModelFile.self, from: data) else {
            check("a Model with a Sound saves", false)
            return
        }
        check("a saved Model keeps its Sounds and the files they play — only those",
              file.state.sounds.map(\.id) == [soundID] && file.state.assets.map(\.name) == ["Bell"])

        // Into a place without it: it comes too.
        let empty = emptyModel()
        _ = try? SceneDocument(model: empty).insertModel(from: data, at: Vec3(10, 0, 0))
        let inserted = empty.sounds.first
        check("inserted elsewhere, the sound comes with it and plays from the new part",
              empty.asset(named: "Bell")?.data == bell && inserted?.soundId == "studio://Bell"
              && inserted.map { $0.id != soundID && empty.part(id: $0.parentID ?? UUID())?.name == "Tower" } ?? false)
        empty.undo()
        check("…and undo takes both away", empty.assets.isEmpty && empty.sounds.isEmpty && empty.parts.isEmpty)

        // Into a place that has it already: no second copy.
        let same = emptyModel()
        _ = try? same.importAsset(data: bell, name: "Bell", fileExtension: "wav")
        _ = try? SceneDocument(model: same).insertModel(from: data, at: .zero)
        check("a place with the same sound uses its own", same.assets.count == 1 && same.sounds.first?.soundId == "studio://Bell")

        // Into a place with a different "Bell": it comes renamed, and what names it follows.
        let clash = emptyModel()
        _ = try? clash.importAsset(data: wav(seconds: 1), name: "Bell", fileExtension: "wav")
        _ = try? SceneDocument(model: clash).insertModel(from: data, at: .zero)
        let brought = clash.assets.first { $0.data == bell }
        check("a place with a different sound of the same name keeps both",
              clash.assets.count == 2 && brought.map { $0.name != "Bell" } ?? false)
        check("…and the Model's Sound and scripts use the one it brought",
              brought.map { asset in
                  clash.sounds.first?.soundId == asset.reference
                  && clash.scripts.first?.source == "script.Parent.Sound.SoundId = \"\(asset.reference)\""
              } ?? false, clash.scripts.first?.source ?? "no script")
    }

    // MARK: - Scripts

    private static func testSoundScripts(_ check: Checker) {
        print("\nSounds: scripts")
        let model = emptyModel()
        _ = try? model.importAsset(data: wav(seconds: 0.5), name: "Beep", fileExtension: "wav")
        var speaker = Part()
        speaker.name = "Speaker"
        speaker.position = Vec3(0, 3, -10)
        var far = Part()
        far.name = "Far"
        far.position = Vec3(0, 3, -600)
        model.parts = [speaker, far]
        // Put in the scene in Studio, set to play from the start.
        var ambient = SceneSound(name: "Ambient", parentID: nil)
        ambient.soundId = "studio://Beep"
        ambient.looped = true
        ambient.playing = true
        model.sounds = [ambient]
        var controls = ScriptObject.blank(language: .luau)
        controls.name = "ControlScript"
        controls.host = .starterPlayer
        controls.enabled = false
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local SoundService = game:GetService("SoundService")
        local ambient = SoundService.Ambient
        print("ambient", ambient.ClassName, ambient.Playing, ambient.Looped, ambient:IsA("Sound"),
        \tambient.Parent == SoundService, SoundService:FindFirstChild("Ambient") == ambient)

        local beep = Instance.new("Sound")
        beep.Name = "Beep"
        beep.SoundId = "studio://Beep"
        beep.Volume = 2
        beep.Parent = workspace.Speaker
        print("made", beep.Parent == workspace.Speaker, workspace.Speaker.Beep == beep,
        \tworkspace.Speaker:FindFirstChild("Beep") == beep, beep.IsLoaded, string.format("%.2f", beep.TimeLength),
        \tbeep.Playing, #SoundService:GetChildren())
        beep.Played:Connect(function(id) print("played", id) end)
        beep.Paused:Connect(function() print("paused event") end)
        beep.Resumed:Connect(function() print("resumed event") end)
        beep.Ended:Connect(function(id) print("ended", id, beep.Playing, beep.TimePosition) end)

        local ok, message = pcall(function() beep.IsPlaying = true end)
        print("read only", ok, message:find("read only") ~= nil)
        ok, message = pcall(function() beep.Volume = "loud" end)
        print("typed", ok, message:find("number expected") ~= nil)
        ok, message = pcall(function() beep.Parent = Vector3.new() end)
        print("parent", ok, message:find("goes in a part") ~= nil)

        beep:Play()
        print("playing", beep.Playing, beep.IsPlaying, beep.IsPaused)
        task.wait(0.2)
        local at = beep.TimePosition
        print("half way", at > 0.1 and at < 0.3)
        beep:Pause()
        local paused = beep.TimePosition
        print("pause", beep.Playing, beep.IsPaused, paused > 0.1)
        task.wait(0.2)
        print("held", beep.TimePosition == paused)
        beep.Playing = true

        local music = Instance.new("Sound", SoundService)
        music.Name = "Music"
        music.SoundId = "studio://Beep"
        music.Looped = true
        music.PlaybackSpeed = 2
        music.Stopped:Connect(function() print("music stopped", music.Playing, music.TimePosition) end)
        music:Play()
        local distant = Instance.new("Sound", workspace.Far)
        distant.Name = "Distant"
        distant.SoundId = "studio://Beep"
        distant.Looped = true
        distant:Play()
        task.wait(1)
        print("still looping", music.Playing, #SoundService:GetChildren())
        music:Stop()
        distant:Destroy()
        print("gone", workspace.Far:FindFirstChild("Distant") == nil, tostring(beep))
        """
        // A LocalScript's Sounds are this machine's own, however it came to make them.
        var own = ScriptObject.blank(language: .luau)
        own.host = .starterPlayer
        own.source = """
        task.spawn(function()
        \tInstance.new("Sound", workspace.Speaker).Name = "Spawned"
        end)
        local connection
        connection = game:GetService("RunService").Heartbeat:Connect(function()
        \tconnection:Disconnect()
        \tInstance.new("Sound", workspace.Speaker).Name = "Later"
        end)
        """
        model.scripts = [controls, script, own]
        let console = ScriptConsole()
        let session = PlayController(model: model, console: console)
        guard let output = session.sounds.output as? RecordingOutput else {
            check("play sessions in the self-tests only record sounds", false)
            return
        }
        session.start()
        // The speaker in front of the camera, a little way off.
        let camera = session.renderCamera
        let ahead = normalize(camera.target - camera.position)
        if let id = model.parts.first(where: { $0.name == "Speaker" })?.id {
            model.update(id: id) { $0.position = camera.target + ahead * 10 }
        }
        step(session, seconds: 0.1)

        var said = lines(console)
        check("a Sound put in the scene is there to scripts, in SoundService, and plays from the start",
              said.first == "ambient Sound true true true true true" && output.playing[ambient.id]?.looped == true
              && output.playing[ambient.id]?.position == nil, said.first ?? "nothing")
        check("scripts make Sounds and put them in parts",
              said.contains("made true true true true 0.50 false 1"), said.joined(separator: " | "))
        check("…read-only and typed properties are kept so",
              said.contains("read only false true") && said.contains("typed false true") && said.contains("parent false true"))
        check("Play plays it, and Played fires with its SoundId",
              said.contains("played studio://Beep") && said.contains("playing true true false"))
        let beepID = model.sounds.first { $0.name == "Beep" }?.id
        let speakerAt = model.parts.first { $0.name == "Speaker" }?.position
        let voice = beepID.flatMap { output.playing[$0] }
        check("…heard from its part", voice?.position == speakerAt && voice?.from == 0 && voice?.speed == 1, "\(String(describing: voice))")
        let expected = model.sounds.first { $0.name == "Beep" }.map {
            SoundSystem.heardVolume($0, at: speakerAt, listener: session.renderCamera.position)
        } ?? -1
        check("…as loud as its Volume, less for how far away it is",
              voice.map { abs($0.volume - expected) < 0.01 && $0.volume > 1 && $0.volume < 2 } ?? false,
              "\(voice?.volume ?? -1) vs \(expected)")

        step(session, seconds: 0.25)
        said = lines(console)
        check("TimePosition moves on while it plays", said.contains("half way true"), said.joined(separator: " | "))
        check("Pause stops it where it is", said.contains("pause false true true") && said.contains("paused event")
              && beepID.map { output.playing[$0] == nil } ?? false)
        step(session, seconds: 0.25)
        said = lines(console)
        let resumed = beepID.flatMap { output.playing[$0] }
        check("…and it holds there", said.contains("held true"))
        check("Playing = true carries on from there",
              said.contains("resumed event") && resumed.map { $0.from > 0.1 && $0.from < 0.35 } ?? false,
              "\(String(describing: resumed))")
        let music = model.sounds.first { $0.name == "Music" }
        let distant = model.sounds.first { $0.name == "Distant" }
        let musicVoice = music.flatMap { output.playing[$0.id] }
        check("a Sound in SoundService is heard the same everywhere, at its speed",
              musicVoice?.position == nil && musicVoice?.speed == 2 && musicVoice?.looped == true && musicVoice?.volume == 0.5,
              "\(String(describing: musicVoice))")
        check("…one past its reach can't be heard", distant.flatMap { output.playing[$0.id] }?.volume == 0)

        step(session, seconds: 0.6)
        said = lines(console)
        check("a Sound that runs out stops, and Ended fires",
              said.contains("ended studio://Beep false 0") && beepID.map { output.playing[$0] == nil } ?? false,
              said.joined(separator: " | "))
        check("…once", said.filter { $0.hasPrefix("ended") }.count == 1)

        step(session, seconds: 0.6)
        said = lines(console)
        check("a Looped one keeps going", said.contains("still looping true 2"), said.joined(separator: " | "))
        check("Stop stops it and goes back to the start",
              said.contains("music stopped false 0") && music.map { output.playing[$0.id] == nil } ?? false)
        check("Destroy takes a Sound away, and silences it",
              said.contains("gone true Beep") && distant.map { model.sound(id: $0.id) == nil && output.playing[$0.id] == nil } ?? false)
        let errors = lines(console, .error)
        check("…with no errors", errors.isEmpty, errors.joined(separator: " | "))
        let localities = Dictionary(model.sounds.map { ($0.name, $0.local) }, uniquingKeysWith: { first, _ in first })
        check("a LocalScript's Sounds are kept to this machine — from task.spawn and events too — a Script's aren't",
              localities["Spawned"] == true && localities["Later"] == true && localities["Beep"] == false
              && localities["Ambient"] == false, "\(localities)")

        session.stop()
        check("Stop in Studio silences everything", output.playing.isEmpty)
    }

    // MARK: - Pictures

    private static func testPictures(_ check: Checker) {
        print("\nAssets: pictures in the GUI")
        let model = emptyModel()
        _ = try? model.importAsset(data: png(red: 1, green: 0, blue: 0), name: "Logo",
                                   fileExtension: "png")
        var controls = ScriptObject.blank(language: .luau)
        controls.name = "ControlScript"
        controls.host = .starterPlayer
        controls.enabled = false
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterPlayer
        script.source = """
        local screen = Instance.new("ScreenGui")
        local logo = Instance.new("ImageLabel")
        logo.Name = "Logo"
        logo.Image = "studio://Logo"
        logo.BackgroundTransparency = 1
        logo.Position = UDim2.fromOffset(20, 20)
        logo.Size = UDim2.fromOffset(100, 100)
        logo.Parent = screen
        screen.Parent = game:GetService("Players").LocalPlayer.PlayerGui
        """
        // Only the picture on screen: no chat, no hotbar.
        let quiet = ["ChatScript", "BackpackScript"].map { name -> ScriptObject in
            var core = ScriptObject.blank(language: .luau)
            core.name = name
            core.host = .starterPlayer
            core.enabled = false
            return core
        }
        model.scripts = [controls, script] + quiet
        let console = ScriptConsole()
        let session = PlayController(model: model, console: console)
        session.start()
        step(session, seconds: 0.1)
        let label = session.gui.objects.values.first { $0.name == "Logo" }
        let image = label.flatMap { session.gui.imageProvider?($0.image) }
        check("an ImageLabel's Image finds the picture", image.map { Int($0.size.width) == 8 } ?? false)
        check("…and one that names nothing shows nothing", session.gui.imageProvider?("studio://Missing") == nil)

        // Drawn: red where the picture is, clear beside it.
        var inside: NSColor?, outside: NSColor?
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: GuiLayer(store: session.gui, interactive: false)
                .frame(width: 400, height: 300))
            renderer.scale = 1
            if let image = renderer.cgImage {
                let bitmap = NSBitmapImageRep(cgImage: image)
                inside = bitmap.colorAt(x: 70, y: 70)?.usingColorSpace(.deviceRGB)
                outside = bitmap.colorAt(x: 200, y: 70)?.usingColorSpace(.deviceRGB)
            }
        }
        check("…and draws it", inside.map { $0.redComponent > 0.8 && $0.blueComponent < 0.2 && $0.alphaComponent > 0.8 } ?? false,
              "\(String(describing: inside))")
        check("…only where it is", outside.map { $0.alphaComponent < 0.1 } ?? false, "\(String(describing: outside))")

        // Studio's StarterGui preview finds pictures too.
        let editor = EditorSession(model: model)
        check("Studio's StarterGui preview shows pictures", editor.guiPreview.imageProvider?("studio://Logo") != nil)
        session.stop()
    }

    // MARK: - Multiplayer

    private static func testSoundsOverTheNetwork(_ check: Checker) {
        print("\nSounds: heard by joined players")
        var partID = UUID()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            _ = try? model.importAsset(data: wav(seconds: 0.3), name: "Bell", fileExtension: "wav")
            _ = try? model.importAsset(data: png(red: 0, green: 0, blue: 1), name: "Badge", fileExtension: "png")
            var tower = Part()
            tower.name = "Tower"
            tower.position = Vec3(0, 6, -12)
            partID = tower.id
            model.parts.append(tower)
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            task.wait(0.5)
            local bell = Instance.new("Sound", workspace.Tower)
            bell.Name = "Bell"
            bell.SoundId = "studio://Bell"
            bell.Looped = true
            bell:Play()
            task.wait(1)
            bell:Stop()
            local once = Instance.new("Sound", game:GetService("SoundService"))
            once.Name = "Once"
            once.SoundId = "studio://Bell"
            once.Ended:Connect(function() print("once ended on the host") end)
            once:Play()
            """
            model.scripts.append(script)
            var mine = ScriptObject.blank(language: .luau)
            mine.host = .starterPlayer
            mine.source = """
            local click = Instance.new("Sound", game:GetService("SoundService"))
            click.Name = "Click"
            click.SoundId = "studio://Bell"
            click.Looped = true
            click:Play()
            """
            model.scripts.append(mine)
        }), let host = hosting.player, let player = joining.player,
              let hostOutput = host.sounds.output as? RecordingOutput,
              let playerOutput = player.sounds.output as? RecordingOutput else {
            check("a host and a player join", false)
            return
        }
        check("pictures and sounds reach the joined player with the scene",
              player.model.assets.map(\.name).sorted() == ["Badge", "Bell"]
              && player.model.asset(named: "Bell")?.data == host.model.asset(named: "Bell")?.data)

        LANSelfTest.run([hosting, joining], seconds: 0.8)
        let bell = host.model.sounds.first { $0.name == "Bell" }
        let heard = bell.flatMap { playerOutput.playing[$0.id] }
        check("a Sound the host's scripts play is heard by the player too",
              bell.map { hostOutput.playing[$0.id] != nil } ?? false && heard != nil, "\(player.model.sounds.map(\.name))")
        check("…from the same part", heard?.position == player.model.part(id: partID)?.position && heard?.looped == true)

        let clicks = player.model.sounds.filter { $0.name == "Click" }
        check("a player's own Sounds are theirs alone",
              clicks.count == 1 && clicks[0].local && clicks.map { playerOutput.playing[$0.id] != nil } == [true]
              && host.model.sounds.filter { $0.name == "Click" }.map(\.local) == [true])

        LANSelfTest.run([hosting, joining], seconds: 1.0)
        check("when the host stops one, the player's stops too",
              bell.map { playerOutput.playing[$0.id] == nil && hostOutput.playing[$0.id] == nil } ?? false)
        check("…while the player's own plays on through the host's changes",
              clicks.map { playerOutput.playing[$0.id] != nil && player.model.sound(id: $0.id) != nil } == [true])
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        let once = host.model.sounds.first { $0.name == "Once" }
        let said = host.console.lines.filter { $0.kind == .output }.map(\.text)
        check("a Sound that runs out ends on the host, and for the player",
              said.contains("once ended on the host")
              && once.map { playerOutput.started.contains($0.id) && playerOutput.playing[$0.id] == nil
                            && player.model.sound(id: $0.id)?.playing == false } ?? false,
              said.joined(separator: " | "))
        hosting.leaveGame()
        joining.leaveGame()
    }
}
