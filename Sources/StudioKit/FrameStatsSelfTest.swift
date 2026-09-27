import Foundation
import Metal
import MetalKit

/// The Stats service and the HUD's frame times: where a frame's time goes (the whole
/// step, scripts, physics, and drawing once something draws it) and what the game holds;
/// the three lines under the numbers top right showing them; a place saved with the HUD
/// before them getting them once (and one whose numbers were deleted, not); and a joined
/// player's numbers being their own machine's.
enum FrameStatsSelfTest {
    static func run(check: Checker) {
        testService(check)
        testHud(check)
        testUpgrade(check)
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

    private static func line(_ session: PlayController, _ prefix: String) -> String {
        session.console.lines.first { $0.text.hasPrefix(prefix) }?.text ?? "(nothing)"
    }

    private static func testService(_ check: Checker) {
        print("\nStats: the service")
        let model = SceneModel()
        var script = ScriptObject.blank(language: .luau)
        script.source = """
        local Stats = game:GetService("Stats")
        -- Some work to time.
        game:GetService("RunService").Heartbeat:Connect(function()
        \tlocal total = 0
        \tfor index = 1, 2000 do
        \t\ttotal += math.sqrt(index)
        \tend
        end)
        task.wait(1)
        print("stats", Stats.HeartbeatTimeMs > 0, Stats.HeartbeatTimeMs >= Stats.ScriptTimeMs, Stats.ScriptTimeMs > 0,
        \tStats.PhysicsStepTimeMs >= 0)
        print("memory", Stats:GetTotalMemoryUsageMb() > 10, Stats:IsA("Stats"), game:GetService("Stats") == Stats)
        print("parts", Stats.PrimitivesCount, Stats.InstanceCount >= Stats.PrimitivesCount)
        """
        model.scripts.append(script)
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 1.3)
        check("frame, script and physics times: the frame the most, the scripts' work in it",
              line(session, "stats").hasPrefix("stats true true true true"), line(session, "stats"))
        check("…memory, and the service is itself", line(session, "memory") == "memory true true true")
        check("…and how many parts there are, and instances", line(session, "parts") == "parts \(model.parts.count) true",
              line(session, "parts"))
        check("no drawing yet, no drawing time", session.frameStats.draw == 0)
        if let device = MTLCreateSystemDefaultDevice() {
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: device)
            if let renderer = Renderer(device: device, view: view, source: session) {
                for _ in 0..<20 { _ = renderer.frameSnapshot(width: 320, height: 200) }
                check("drawn, the drawing time counts, and in the frame", session.frameStats.draw > 0
                      && session.frameStats.frame >= session.frameStats.draw)
            }
        }
        check("no errors", session.console.lines.filter { $0.kind == .error }.isEmpty)
        session.stop()
    }

    private static func testHud(_ check: Checker) {
        print("\nStats: in the HUD")
        let model = SceneModel()
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 1.2)
        func text(_ name: String) -> String { session.gui.objects.values.first { $0.name == name }?.text ?? "" }
        let frameLine = text("FrameTime"), work = text("Work"), memory = text("Memory")
        let numbers = frameLine.split(separator: " ").compactMap { Double($0) }
        check("the frame's time and the drawing's, under the numbers top right",
              frameLine.hasPrefix("frame ") && frameLine.contains(" ms · draw ") && numbers.first.map { $0 > 0 } == true,
              frameLine)
        check("…the scripts' and the physics'", work.hasPrefix("scripts ") && work.contains(" · physics "), work)
        check("…and the memory and the parts", memory.hasPrefix("memory ") && memory.hasSuffix(" \(model.parts.count) parts")
              && (memory.split(separator: " ").compactMap { Int($0) }.first ?? 0) > 10, memory)
        check("no errors", session.console.lines.filter { $0.kind == .error }.isEmpty,
              "\(session.console.lines.filter { $0.kind == .error }.map(\.text))")
        session.stop()
    }

    /// A scene with the HUD as it was before frame times (version 2).
    private static func versionTwo(deletingStats: Bool = false) -> SceneState {
        var state = SceneModel().state
        let frames = Set(state.starterGui.filter { ["FrameTime", "Work", "Memory"].contains($0.name) }.map(\.id))
        state.starterGui.removeAll { frames.contains($0.id) }
        state.scripts.removeAll { $0.name == DefaultHud.frameStatsName }
        if deletingStats, let stats = state.starterGui.first(where: { $0.name == "Stats" }) {
            state.starterGui.removeAll { $0.id == stats.id || $0.parentID == stats.id }
        }
        state.defaultGui = 2
        return state
    }

    private static func testUpgrade(_ check: Checker) {
        print("\nStats: places saved before")
        let upgraded = versionTwo().upgradedToDefaultHud()
        let stats = upgraded.starterGui.first { $0.name == "Stats" }
        check("a place saved with the HUD before frame times gets them, under its numbers",
              ["FrameTime", "Work", "Memory"].allSatisfy { name in
                  upgraded.starterGui.contains { $0.name == name && $0.parentID == stats?.id }
              } && upgraded.scripts.filter { $0.name == DefaultHud.frameStatsName && $0.parentID == stats?.id }.count == 1
              && upgraded.defaultGui == DefaultHud.version)
        let again = upgraded.upgradedToDefaultHud()
        check("…once", again.scripts.filter { $0.name == DefaultHud.frameStatsName }.count == 1
              && again.starterGui.filter { $0.name == "FrameTime" }.count == 1)
        let deleted = versionTwo(deletingStats: true).upgradedToDefaultHud()
        check("…and one whose numbers were deleted isn't given them",
              !deleted.starterGui.contains { $0.name == "FrameTime" }
              && !deleted.scripts.contains { $0.name == DefaultHud.frameStatsName })
    }

    private static func testTogether(_ check: Checker) {
        print("\nStats: a host and a joined player")
        let quick = SceneModel()
        let hudState = quick.state
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.starterGui = hudState.starterGui
            model.scripts += hudState.scripts.filter { $0.host == .starterGui }
        }), let sam = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 1.5)
        let memory = sam.gui.objects.values.first { $0.name == "Memory" }?.text ?? ""
        check("a joined player's numbers are their own machine's: its frames, its parts",
              sam.frameStats.step > 0 && memory.hasSuffix(" \(joining.model.parts.count) parts"),
              "\(memory) vs \(joining.model.parts.count)")
        joining.leaveGame()
        hosting.leaveGame()
    }
}
