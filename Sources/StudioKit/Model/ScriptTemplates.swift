import Foundation

/// What a new script starts with. It depends on where the script is made, since that
/// decides what it can reach: each one runs cleanly as it is, prints a line to show it
/// is alive, shows the thing most worth knowing in that place, and leaves a few lines
/// to try — commented out so that taking away the `--` gives working code.
enum ScriptTemplates {
    /// Where a new script lives.
    enum Place: CaseIterable {
        /// Inside a part: `script.Parent` is the part.
        case part
        /// Inside a Model, or a Folder.
        case model, folder
        /// In Script Service, attached to nothing.
        case service
        /// StarterPlayerScripts, and StarterCharacterScripts.
        case starterPlayer, starterCharacter
        /// Inside a GUI in StarterGui: `script.Parent` is the player's copy.
        case gui
    }

    static func source(_ language: ScriptLanguage, in place: Place) -> String {
        switch (language, place) {
        case (.luau, .part): return luauPart
        case (.luau, .model): return luauModel
        case (.luau, .folder): return luauFolder
        case (.luau, .service): return luauService
        case (.luau, .starterPlayer): return luauStarterPlayer
        case (.luau, .starterCharacter): return luauStarterCharacter
        case (.luau, .gui): return luauGui
        // Wren sees parts, not Models or Folders, and StarterPlayer is Luau's (Luau first).
        case (.wren, .part): return wrenPart
        case (.wren, .model), (.wren, .folder): return wrenInGroup
        case (.wren, _): return wrenService
        }
    }

    // MARK: - Luau

    static let luauPart = """
    -- Runs when you press Play. script.Parent is the part this script is in.
    local part = script.Parent

    print(`{script.Name} is running in {part.Name}`)

    -- Touched fires when something bumps into the part: a player, or another part.
    -- The debounce stops it firing again and again while someone stands here.
    local debounce = false

    part.Touched:Connect(function(hit)
    \tlocal character = hit.Parent
    \tlocal humanoid = character and character:FindFirstChild("Humanoid")
    \tif humanoid == nil or debounce then
    \t\treturn
    \tend
    \tdebounce = true
    \tprint(`{character.Name} touched {part.Name}`)

    \t-- Try one of these:
    \t-- humanoid.Health = 0                  -- a kill brick
    \t-- part.Color = Color3.new(0, 1, 0)     -- light up when touched

    \ttask.wait(1)
    \tdebounce = false
    end)
    """

    static let luauModel = """
    -- Runs when you press Play. script.Parent is the model this script is in.
    local model = script.Parent

    -- GetDescendants lists everything inside, however deeply it is nested.
    local parts = 0
    for _, thing in model:GetDescendants() do
    \tif thing:IsA("BasePart") then
    \t\tparts += 1
    \tend
    end
    print(`Parts in {model.Name}: {parts}`)

    -- A model moves as one. Try lifting it 5 studs:
    -- model:PivotTo(model:GetPivot() + Vector3.new(0, 5, 0))
    """

    static let luauFolder = """
    -- Runs when you press Play. script.Parent is the folder this script is in: a way
    -- to keep things tidy, with no position of its own.
    local folder = script.Parent

    print(`Things in {folder.Name}: {#folder:GetChildren()}`)

    -- To change everything inside at once, go through its descendants:
    -- for _, thing in folder:GetDescendants() do
    -- \tif thing:IsA("BasePart") then
    -- \t\tthing.Anchored = true
    -- \tend
    -- end
    """

    static let luauService = """
    -- Runs when you press Play. print writes to the Output below; errors land there
    -- too, and clicking one opens its script at that line.
    print("Hello world!")

    -- Parts are found by name in the Workspace:
    -- local platform = workspace:FindFirstChild("Platform")

    -- task.wait pauses this script without pausing the game:
    -- task.wait(2)
    -- print("Two seconds later")

    -- Heartbeat runs a function every frame; dt is the seconds since the last one:
    -- game:GetService("RunService").Heartbeat:Connect(function(dt)
    -- \t-- runs about 60 times a second
    -- end)
    """

    static let luauStarterPlayer = """
    -- Runs once when you press Play, for the player: the place for keys, the camera,
    -- and anything that outlasts one character.
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer

    -- Every character the player gets: the first, and each one after a respawn.
    local function onCharacter(character)
    \tlocal humanoid = character:WaitForChild("Humanoid")
    \tprint(`{player.Name} spawned with {humanoid.Health} health`)
    end
    if player.Character then
    \tonCharacter(player.Character)
    end
    player.CharacterAdded:Connect(onCharacter)

    -- Keys the player presses. WASD, Space and Shift already belong to the ControlScript.
    UserInputService.InputBegan:Connect(function(input)
    \tif input.KeyCode == Enum.KeyCode.E then
    \t\tprint("E pressed")
    \tend
    end)
    """

    static let luauGui = """
    -- A LocalScript in StarterGui. It runs in each player's own copy of this GUI,
    -- once when they join, or for each new character if ResetOnSpawn is on.
    -- script.Parent is the copy, on this player's screen alone.
    local gui = script.Parent
    local player = game:GetService("Players").LocalPlayer

    print(`{script.Name} is running in {player.Name}'s {gui.Name}`)

    -- Try one of these:
    -- for _, child in gui:GetChildren() do print(child.Name) end
    -- gui.Enabled = false                -- hide a ScreenGui (Visible, for anything else)
    """

    static let luauStarterCharacter = """
    -- Runs for every new character, and stops when that character goes. script.Parent
    -- is the character.
    local character = script.Parent
    local humanoid = character:WaitForChild("Humanoid")

    print(`{script.Name} is running in {character.Name}`)

    humanoid.Died:Connect(function()
    \tprint(`{character.Name} died`)
    end)

    -- Change how this character moves:
    -- humanoid.WalkSpeed = 24
    -- humanoid.JumpPower = 60
    """

    // MARK: - Wren

    static let wrenPart = """
    // Runs when you press Play. script.parent is the part this script is in.
    import "studio" for Runtime, Vec3

    var part = script.parent
    Runtime.log("%(script.name) is running in %(part.name)")

    // Runtime.onUpdate runs every frame; dt is the seconds since the last one.
    // Try turning the part a quarter turn a second:
    // Runtime.onUpdate { |dt|
    //   part.rotation = part.rotation + Vec3.new(0, 90 * dt, 0)
    // }
    """

    static let wrenService = """
    // Runs when you press Play. Runtime.log writes to the Output below.
    import "studio" for Workspace, Runtime

    Runtime.log("Hello from Wren! The workspace has %(Workspace.count) parts.")

    // Parts are found by name:
    // var platform = Workspace.find("Platform")

    // Runtime.onUpdate runs every frame; dt is the seconds since the last one:
    // Runtime.onUpdate { |dt|
    //   // runs about 60 times a second
    // }
    """

    static let wrenInGroup = """
    // Runs when you press Play. Wren doesn't see Models and Folders yet, so script.parent
    // is null here: find parts by name instead, or use Luau, which sees the whole tree.
    import "studio" for Workspace, Runtime

    Runtime.log("Hello from Wren! The workspace has %(Workspace.count) parts.")

    // var platform = Workspace.find("Platform")
    """
}
