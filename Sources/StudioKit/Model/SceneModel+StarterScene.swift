import Foundation
import simd

// SceneModel — The scene a new Studio opens on.

extension SceneModel {
    func loadStarterScene() {
        var made: [Part] = []

        var platform = Part()
        platform.name = "Platform"
        platform.shape = .block
        platform.position = Vec3(0, 0.5, 0)
        platform.size = Vec3(24, 1, 24)
        platform.color = Vec3(0.42, 0.50, 0.38)
        platform.material = .smooth
        made.append(platform)

        var tower = Part()
        tower.name = "Tower"
        tower.shape = .cylinder
        tower.position = Vec3(-6, 4, -4)
        tower.size = Vec3(3, 6, 3)
        tower.color = Vec3(0.85, 0.72, 0.45)
        made.append(tower)

        var ramp = Part()
        ramp.name = "Ramp"
        ramp.shape = .wedge
        ramp.position = Vec3(6, 2, 2)
        ramp.size = Vec3(6, 3, 4)
        ramp.rotationDegrees = Vec3(0, -35, 0)
        ramp.color = Vec3(0.78, 0.35, 0.30)
        made.append(ramp)

        var orb = Part()
        orb.name = "Orb"
        orb.shape = .sphere
        orb.position = Vec3(0, 5, 4)
        orb.size = Vec3(3, 3, 3)
        orb.color = Vec3(0.35, 0.72, 0.95)
        orb.material = .neon
        // A glowing orb that really glows: its light falls on the platform below.
        orb.light = PointLight()
        orb.light?.color = Vec3(0.45, 0.8, 1.0)
        orb.light?.brightness = 2
        orb.light?.range = 14
        made.append(orb)

        var beam = Part()
        beam.name = "Beam"
        beam.shape = .block
        beam.position = Vec3(-1, 8.5, -4)
        beam.size = Vec3(12, 1, 1.5)
        beam.rotationDegrees = Vec3(0, 0, 12)
        beam.color = Vec3(0.55, 0.55, 0.60)
        beam.material = .metal
        made.append(beam)

        var spin = ScriptObject()
        spin.name = "BobScript"
        spin.parentID = orb.id
        spin.source = """
        -- The orb bobs, the beam spins, and the orb's shader is driven from here.
        local RunService = game:GetService("RunService")

        local orb = script.Parent
        local beam = workspace:FindFirstChild("Beam")
        local pulse = Shaders:FindFirstChild("Pulse")
        local origin = orb.Position

        print(`Scene running with {#workspace:GetChildren()} parts and {#Shaders:GetChildren()} shaders`)

        RunService.Heartbeat:Connect(function()
        	local t = time()
        	local height = math.sin(t * 2)

        	orb.Position = origin + Vector3.new(0, height * 1.5, 0)
        	if beam then
        		beam.Orientation = Vector3.new(0, t * 40, 12)
        	end

        	-- The shader parameter follows how high the orb has bobbed, so the glow
        	-- is brightest at the top and bottom of the arc.
        	if pulse then
        		pulse:SetParameter("glow", math.map(math.abs(height), 0, 1, 0.35, 1.25))
        	end
        end)
        """

        var pulse = ShaderObject()
        pulse.name = "Pulse"
        pulse.source = ShaderObject.pulseExample
        pulse.parameters = [ShaderParameter(name: "speed", value: 2),
                            ShaderParameter(name: "glow", value: 1)]

        // The orb is the thing that shows it off.
        if let orbIndex = made.firstIndex(where: { $0.name == "Orb" }) {
            made[orbIndex].shaderID = pulse.id
        }

        var monochrome = ShaderObject.blank(kind: .screen)
        monochrome.name = "Black & White"
        monochrome.source = ShaderObject.blackAndWhiteExample
        monochrome.parameters = [ShaderParameter(name: "amount", value: 1)]

        parts = made
        groups = []
        attachments = []
        constraints = []
        // The screen effect ships switched off, so the scene opens in colour.
        shaders = [pulse, monochrome]
        screenShaderID = nil
        let hud = DefaultHud.make()
        starterGui = hud.objects
        defaultGui = DefaultHud.version
        assets = []
        sounds = []
        dataObjects = []
        starterPlayer = StarterPlayerSettings()
        animations = [AnimationObject.waveExample()]
        lighting = LightingSettings()
        selectedAnimation = nil
        // Every new place has the Utils ModuleScript in ReplicatedStorage.
        scripts = [spin] + hud.scripts + [UtilsModule.make()]
        selection = []
        selectedScript = nil
        selectedShader = nil
        clearHistory()
        noteChange()
        statusText = "Loaded starter scene"
    }
}
