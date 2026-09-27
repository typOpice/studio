import Foundation
import simd

/// Every sample game played for a while by a player running about, jumping, fighting and
/// falling (`Soak.play`, the same moves each time): no script errors, and nothing that
/// should stay about the same size — parts, Models, Sounds, values, GUI, Luau's memory —
/// growing from the first sample to the last. And a host and a joined player in
/// Nightfall together: the joined player's copy of the world holding what the host's
/// does, and not piling up what the host has done with.
enum SoakSelfTest {
    static func run(check: Checker) {
        for (name, template, seconds) in [("Adventure Island", PlaceTemplate.adventure, 40.0),
                                          ("Nightfall", .nightfall, 60), ("Mega Obby", .megaObby, 40)] {
            testGame(check, name: name, template: template, seconds: seconds)
        }
        testTogether(check)
    }

    /// What grew too much between two samples, if anything.
    static func growth(from first: Soak.Sample, to last: Soak.Sample) -> [String] {
        var grew: [String] = []
        if last.parts > first.parts + 40 { grew.append("parts \(first.parts) → \(last.parts)") }
        if last.groups > first.groups + 12 { grew.append("Models \(first.groups) → \(last.groups)") }
        if last.sounds > first.sounds + 24 { grew.append("Sounds \(first.sounds) → \(last.sounds)") }
        if last.data > first.data + 24 { grew.append("values \(first.data) → \(last.data)") }
        if last.gui > first.gui + 40 { grew.append("GUI \(first.gui) → \(last.gui)") }
        if last.voices > 24 { grew.append("voices \(last.voices)") }
        if last.luau > max(first.luau * 3, first.luau + 8_000_000) { grew.append("Luau \(first.luau) → \(last.luau)") }
        return grew
    }

    private static func testGame(_ check: Checker, name: String, template: PlaceTemplate, seconds: Double) {
        print("\nSoak: \(name) for \(Int(seconds)) seconds")
        let model = SceneModel()
        model.loadTemplate(template)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        let (samples, errors) = Soak.play(session, seconds: seconds, every: 5)
        check("no script errors", errors.isEmpty, "\(Set(errors).prefix(3))")
        // From once it has settled (the first few seconds make the world) to the end.
        if samples.count > 3, let last = samples.last {
            let grew = growth(from: samples[2], to: last)
            check("nothing growing that should stay about the same size", grew.isEmpty, "\(grew)")
        }
        session.stop()
        DataStoreFiles.shared.clear(place: model.placeID ?? UUID())
    }

    private static func testTogether(_ check: Checker) {
        print("\nSoak: a host and a joined player in Nightfall")
        let state = Nightfall.state()
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            let kept = model.scripts
            model.state = state
            model.scripts += kept
        }), let host = hosting.player, let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        var counts: [(host: Int, joined: Int, hostSounds: Int, joinedSounds: Int)] = []
        var tick = 0
        LANSelfTest.run([hosting, joining], seconds: 50) {
            // Both players move about and swing; the joined one falls now and then.
            tick += 1
            let direction = ["W", "A", "S", "D"][(tick / 70) % 4]
            for (index, player) in [host, sam].enumerated() where tick % 70 == index {
                for key in ["W", "A", "S", "D"] { player.key(key, pressed: key == direction) }
            }
            if tick % 40 == 0 { sam.mouseButton(1, pressed: true) }
            if tick % 40 == 3 { sam.mouseButton(1, pressed: false) }
            if tick % 1500 == 750 { sam.humanoid.takeDamage(1000) }
            for player in [host, sam] where simd_length(SIMD2(player.character.position.x, player.character.position.z)) > 150 {
                player.character.position = Vec3(0, 5, 0)
            }
            if tick % 300 == 0 {
                counts.append((hosting.model.parts.count, joining.model.parts.count,
                               hosting.model.sounds.filter { !$0.local }.count,
                               joining.model.sounds.filter { !$0.local }.count))
            }
        }
        let errors = (host.console.lines + sam.console.lines).filter { $0.kind == .error }.map(\.text)
        check("50 seconds, night included, with no script errors on either", errors.isEmpty, "\(Set(errors).prefix(3))")
        // The joined player's world is the host's, less what ServerStorage keeps: the gap
        // between them stays what it was.
        if counts.count > 3, let last = counts.last {
            let settled = counts[2]
            let gapThen = settled.host - settled.joined, gapNow = last.host - last.joined
            check("the joined player's world keeps pace with the host's, holding nothing the host has done with",
                  abs(gapNow - gapThen) <= 12 && abs((last.hostSounds - last.joinedSounds)
                                                      - (settled.hostSounds - settled.joinedSounds)) <= 8,
                  "\(counts)")
        }
        joining.leaveGame()
        hosting.leaveGame()
        DataStoreFiles.shared.clear(place: Nightfall.placeID)
    }
}
