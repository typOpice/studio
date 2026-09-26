import Foundation

/// Adventure Island's scripts and shaders, as the place keeps them. Written the way a
/// Roblox developer would: ModuleScripts in ReplicatedStorage for what every machine
/// shares (who says what, where the zones are), Scripts on the server for the game
/// (leaderstats, gems, the Obby Tower, the Mirror Lab, the NPCs turning to face you),
/// a LocalScript for each player's screen (talking, zone effects, banners), and
/// RemoteEvents/RemoteFunctions and a BindableEvent between them.
enum AdventureIslandScripts {

    // MARK: - Shared: ReplicatedStorage

    static let dialogue = """
    -- Dialogue: what each NPC says, by the NPC's name. The Adventure LocalScript shows
    -- it. A line may say {gems}, {wins} or {name}; an option either goes to another
    -- node (go), asks the server to do something (action, through the Quest
    -- RemoteFunction, whose answer is shown), or ends the talk.
    local Dialogue = {}

    Dialogue["Guide Pip"] = {
    \tstart = {
    \t\ttext = "Hi {name}, welcome to Adventure Island! I'm Pip. Everything here is made in Studio: parts, scripts, shaders, the lot.",
    \t\toptions = {
    \t\t\t{ text = "What is there to do?", go = "todo" },
    \t\t\t{ text = "How do I get around?", go = "controls" },
    \t\t\t{ text = "Bye, Pip!" },
    \t\t},
    \t},
    \ttodo = {
    \t\ttext = "Find the five gems hidden round the island. Beat the Obby Tower to the west. Pull the lever in the Mirror Lab to the east. And see the Crystal Caves to the north!",
    \t\toptions = {
    \t\t\t{ text = "Where are the gems?", go = "gems" },
    \t\t\t{ text = "What do gems buy?", go = "trade" },
    \t\t\t{ text = "Thanks!" },
    \t\t},
    \t},
    \tgems = {
    \t\ttext = "One glows deep in the caves. One floats over the Dream Garden. One sits on the lake's little island. One is on top of the lighthouse. And one hides behind the orb in the Mirror Lab.",
    \t\toptions = { { text = "I'm on it." } },
    \t},
    \ttrade = {
    \t\ttext = "Baker Bo, at the market in the village to the south, swaps three gems for something shiny. You have {gems} so far.",
    \t\toptions = { { text = "Off I go!" } },
    \t},
    \tcontrols = {
    \t\ttext = "W A S D to walk, Space to jump, Shift to run. Walk into a truss to climb it. Press E near anyone to talk, and Tab for the leaderboard.",
    \t\toptions = { { text = "Got it." } },
    \t},
    }

    Dialogue["Baker Bo"] = {
    \tstart = {
    \t\ttext = "Fresh bread! Well, fresh parts. Bring me three gems and I'll trade you a crown fit for a king. You've got {gems}.",
    \t\toptions = {
    \t\t\t{ text = "Here are three gems.", action = "trade" },
    \t\t\t{ text = "A crown? Really?", go = "crown" },
    \t\t\t{ text = "Maybe later." },
    \t\t},
    \t},
    \tcrown = {
    \t\ttext = "A real accessory! The server hands it to your Humanoid with AddAccessory, and everyone in the game sees you wear it.",
    \t\toptions = { { text = "Here are three gems.", action = "trade" }, { text = "Neat." } },
    \t},
    }

    Dialogue["Old Mara"] = {
    \tstart = {
    \t\ttext = "Oh, a visitor. This island was built in an afternoon, you know. Nothing here is painted on: every tree is three parts.",
    \t\toptions = {
    \t\t\t{ text = "Any tips?", go = "tips" },
    \t\t\t{ text = "Who built it?", go = "who" },
    \t\t\t{ text = "Goodbye, Mara." },
    \t\t},
    \t},
    \ttips = {
    \t\ttext = "The lighthouse ladder is a truss: walk into it and keep walking. In the lake, Space swims you up. And the mushrooms in the Dream Garden are for hopping on.",
    \t\toptions = { { text = "Thank you!" } },
    \t},
    \twho = {
    \t\ttext = "A script called AdventureIsland, in Studio's own source. Open this place in Studio and every piece is there to take apart.",
    \t\toptions = { { text = "I'll have a look." } },
    \t},
    }

    Dialogue["Coach Kip"] = {
    \tstart = {
    \t\ttext = "Ready for the Obby Tower? Touch the start pad and go! Wins so far: {wins}.",
    \t\toptions = {
    \t\t\t{ text = "Any advice?", go = "advice" },
    \t\t\t{ text = "What if I fall?", go = "fall" },
    \t\t\t{ text = "Let's go!" },
    \t\t},
    \t},
    \tadvice = {
    \t\ttext = "Jump the red bar as it comes round, don't linger on the yellow tiles, and when the blue pad throws you up, steer north onto the summit.",
    \t\toptions = { { text = "Got it, Coach." } },
    \t},
    \tfall = {
    \t\ttext = "Green pads are checkpoints. Touch the lava and you're back at the last one you reached.",
    \t\toptions = { { text = "Phew." } },
    \t},
    }

    Dialogue["Professor Lumen"] = {
    \tstart = {
    \t\ttext = "Welcome to my Mirror Lab! Pull the lever on the pedestal and the whole island switches to ray-traced lighting.",
    \t\toptions = {
    \t\t\t{ text = "What changes?", go = "what" },
    \t\t\t{ text = "And the red button?", go = "button" },
    \t\t\t{ text = "Fascinating. Bye!" },
    \t\t},
    \t},
    \twhat = {
    \t\ttext = "Mirrors and the chrome orb reflect the room, the coloured lamps cast real shadows, and corners darken with ambient occlusion. It needs a Mac whose GPU can ray trace; otherwise it quietly stays as it was.",
    \t\toptions = { { text = "Let me try it." } },
    \t},
    \tbutton = {
    \t\ttext = "A light show! Each press gives the lamps new colours. Watch them bounce off the mirrors with ray tracing on.",
    \t\toptions = { { text = "Ooh." } },
    \t},
    }

    Dialogue["Miner Moe"] = {
    \tstart = {
    \t\ttext = "Mind your eyes, it's bright down here! These crystals run a surface shader called Crystal: the colour shifts as you walk round them.",
    \t\toptions = {
    \t\t\t{ text = "Why is my screen blue?", go = "screen" },
    \t\t\t{ text = "Seen a gem?", go = "gem" },
    \t\t\t{ text = "See you, Moe." },
    \t\t},
    \t},
    \tscreen = {
    \t\ttext = "That's a screen shader, Cave Glow. Your LocalScript switches it on when you walk in, so it's only on your screen, nobody else's.",
    \t\toptions = { { text = "Clever." } },
    \t},
    \tgem = {
    \t\ttext = "Right at the back of the cave, glowing away. Can't miss it.",
    \t\toptions = { { text = "Thanks!" } },
    \t},
    }

    Dialogue["Dreamer Luna"] = {
    \tstart = {
    \t\ttext = "Everything wobbles here, doesn't it? That's the Dreamy screen shader. And the mushroom caps shimmer with the Rainbow shader.",
    \t\toptions = {
    \t\t\t{ text = "How do I reach the islands?", go = "islands" },
    \t\t\t{ text = "Sweet dreams!" },
    \t\t},
    \t},
    \tislands = {
    \t\ttext = "Hop from the small mushroom to the bigger ones, then leap to each floating island. There's a gem on the highest.",
    \t\toptions = { { text = "Here I go." } },
    \t},
    }

    Dialogue["Fisher Finn"] = {
    \tstart = {
    \t\ttext = "Nice day for it. See that little island? There's a gem on it. You'll have to swim.",
    \t\toptions = {
    \t\t\t{ text = "How do I swim?", go = "swim" },
    \t\t\t{ text = "Caught anything?", go = "fish" },
    \t\t\t{ text = "Bye, Finn." },
    \t\t},
    \t},
    \tswim = {
    \t\ttext = "Just walk in: the water's the Water material. Space swims you up. While you swim, the Underwater shader tints your screen.",
    \t\toptions = { { text = "Splash!" } },
    \t},
    \tfish = {
    \t\ttext = "Not yet. Parts don't float, so neither does bait. Someday!",
    \t\toptions = { { text = "Good luck." } },
    \t},
    }

    return Dialogue
    """

    static let zones = """
    -- Zones: named boxes of the island (the banner you see coming in) and the screen
    -- effect, if any, each one turns on while you're inside. The first that holds you
    -- is where you are.
    return {
    \t{ name = "Crystal Caves", min = Vector3.new(-21, -5, -120), max = Vector3.new(21, 16, -71), effect = "Cave Glow" },
    \t{ name = "Dream Garden", min = Vector3.new(-108, -5, 62), max = Vector3.new(-52, 40, 118), effect = "Dreamy" },
    \t{ name = "Mirror Lab", min = Vector3.new(64, -5, -11), max = Vector3.new(106, 20, 31) },
    \t{ name = "Obby Tower", min = Vector3.new(-135, -5, -20), max = Vector3.new(-40, 60, 20) },
    \t{ name = "The Village", min = Vector3.new(-26, -5, 55), max = Vector3.new(26, 40, 110) },
    \t{ name = "The Lake", min = Vector3.new(56, -5, 66), max = Vector3.new(108, 30, 118) },
    \t{ name = "Lighthouse Hill", min = Vector3.new(75, -5, -115), max = Vector3.new(115, 60, -75) },
    \t{ name = "Whispering Woods", min = Vector3.new(-150, -5, -150), max = Vector3.new(-45, 40, -40) },
    \t{ name = "Spawn Plaza", min = Vector3.new(-17, -5, -7), max = Vector3.new(17, 40, 27) },
    }
    """

    // MARK: - The server

    static let game = """
    -- GameScript: the island's rules. Each player gets leaderstats (Gems and Wins);
    -- gems go to whoever touches them first and come back later; the Quest
    -- RemoteFunction trades gems for a crown; rewards (from here, or the Obby's
    -- BindableEvent) are accessories, put back on every time the character respawns.
    -- Gems, Wins and rewards are saved (a DataStore) and back next time you play.
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local ServerStorage = game:GetService("ServerStorage")
    local DataStoreService = game:GetService("DataStoreService")

    local Notify = ReplicatedStorage:WaitForChild("Notify")
    local Quest = ReplicatedStorage:WaitForChild("Quest")
    local Reward = ServerStorage:WaitForChild("Reward")

    local GEM_RETURN = 30
    local rewards = {}

    -- Saved by name: the same player next time, whoever hosts.
    local Saves = DataStoreService:GetDataStore("IslandProgress")
    local function saveKey(player)
    \treturn "player_" .. player.Name
    end

    local function save(player)
    \tlocal stats = player:FindFirstChild("leaderstats")
    \tif stats == nil or rewards[player] == nil then
    \t\treturn
    \tend
    \tlocal ok, problem = pcall(function()
    \t\tSaves:SetAsync(saveKey(player), { Gems = stats.Gems.Value, Wins = stats.Wins.Value, Rewards = rewards[player] })
    \tend)
    \tif not ok then
    \t\twarn("Couldn't save " .. player.Name .. "'s progress: " .. tostring(problem))
    \tend
    end

    local function wear(player, item, name)
    \tlocal character = player.Character
    \tlocal humanoid = character and character:FindFirstChild("Humanoid")
    \tif humanoid and character:FindFirstChild(name) == nil then
    \t\tlocal accessory = Instance.new("Accessory")
    \t\taccessory.Name = name
    \t\taccessory.MeshId = item
    \t\thumanoid:AddAccessory(accessory)
    \tend
    end

    local function give(player, item, name)
    \tlocal owned = rewards[player]
    \tif owned == nil or owned[name] then
    \t\treturn false
    \tend
    \towned[name] = item
    \twear(player, item, name)
    \tsave(player)
    \treturn true
    end

    local function setUp(player)
    \trewards[player] = {}
    \tlocal leaderstats = Instance.new("Folder")
    \tleaderstats.Name = "leaderstats"
    \tleaderstats.Parent = player
    \tfor _, stat in { "Gems", "Wins" } do
    \t\tlocal value = Instance.new("IntValue")
    \t\tvalue.Name = stat
    \t\tvalue.Parent = leaderstats
    \tend
    \t-- What they had last time, then kept up to date.
    \tlocal ok, saved = pcall(function()
    \t\treturn Saves:GetAsync(saveKey(player))
    \tend)
    \tif ok and type(saved) == "table" then
    \t\tleaderstats.Gems.Value = tonumber(saved.Gems) or 0
    \t\tleaderstats.Wins.Value = tonumber(saved.Wins) or 0
    \t\tfor name, item in (if type(saved.Rewards) == "table" then saved.Rewards else {}) do
    \t\t\tif type(name) == "string" and type(item) == "string" then
    \t\t\t\trewards[player][name] = item
    \t\t\tend
    \t\tend
    \tend
    \tfor _, stat in leaderstats:GetChildren() do
    \t\tstat.Changed:Connect(function()
    \t\t\tsave(player)
    \t\tend)
    \tend
    \tplayer.CharacterAdded:Connect(function()
    \t\ttask.wait()
    \t\tfor name, item in rewards[player] or {} do
    \t\t\twear(player, item, name)
    \t\tend
    \tend)
    \tif player.Character then
    \t\tfor name, item in rewards[player] do
    \t\t\twear(player, item, name)
    \t\tend
    \tend
    end

    for _, player in Players:GetPlayers() do
    \tsetUp(player)
    end
    Players.PlayerAdded:Connect(setUp)
    Players.PlayerRemoving:Connect(function(player)
    \tsave(player)
    \trewards[player] = nil
    end)

    Reward.Event:Connect(function(player, item, name, message)
    \tif give(player, item, name) and message then
    \t\tNotify:FireClient(player, "win", message)
    \tend
    end)

    -- Gems.
    local gems = workspace:WaitForChild("Gems")
    local away = {}

    for _, gem in gems:GetChildren() do
    \tgem.Touched:Connect(function(hit)
    \t\tif away[gem] then
    \t\t\treturn
    \t\tend
    \t\tlocal player = Players:GetPlayerFromCharacter(hit.Parent)
    \t\tlocal stats = player and player:FindFirstChild("leaderstats")
    \t\tif stats == nil then
    \t\t\treturn
    \t\tend
    \t\taway[gem] = time() + GEM_RETURN
    \t\tgem.Transparency = 1
    \t\tstats.Gems.Value += 1
    \t\tNotify:FireClient(player, "gem", string.format("You found a gem! (%d)", stats.Gems.Value))
    \tend)
    end

    RunService.Heartbeat:Connect(function()
    \tlocal now = time()
    \tfor _, gem in gems:GetChildren() do
    \t\tgem.Orientation = Vector3.new(0, (now * 90) % 360, 45)
    \t\tif away[gem] and now >= away[gem] then
    \t\t\taway[gem] = nil
    \t\t\tgem.Transparency = 0
    \t\tend
    \tend
    end)

    -- Baker Bo's trade.
    Quest.OnServerInvoke = function(player, action)
    \tlocal stats = player:FindFirstChild("leaderstats")
    \tif stats == nil then
    \t\treturn "Hold on, I can't see your pockets yet."
    \tend
    \tif action == "trade" then
    \t\tif rewards[player] and rewards[player].BakersCrown then
    \t\t\treturn "You've already got my crown! Keep your gems."
    \t\tend
    \t\tif stats.Gems.Value < 3 then
    \t\t\treturn string.format("Three gems, please! You've only got %d.", stats.Gems.Value)
    \t\tend
    \t\tstats.Gems.Value -= 3
    \t\tgive(player, "builtin://Crown", "BakersCrown")
    \t\treturn "A fair trade! One crown, fresh from the oven. Wear it well."
    \tend
    \treturn "Hmm?"
    end

    print("Adventure Island is open.")
    """

    static let obby = """
    -- ObbyScript: the Obby Tower. Lava and the spinning bar knock you out; green pads
    -- are checkpoints you come back to; the mover glides, the spinner spins, the yellow
    -- tiles give way, the blue pad throws you up; and the trophy is a Win (and, the
    -- first time, a party hat, through the Reward BindableEvent).
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local TweenService = game:GetService("TweenService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local ServerStorage = game:GetService("ServerStorage")

    local Notify = ReplicatedStorage:WaitForChild("Notify")
    local Reward = ServerStorage:WaitForChild("Reward")
    local obby = script.Parent

    local reached = {}
    local startedAt = {}
    local ranks = { Start = 0, Checkpoint1 = 1, Checkpoint2 = 2, Checkpoint3 = 3 }

    local function playerFrom(hit)
    \treturn Players:GetPlayerFromCharacter(hit.Parent)
    end

    local function knockOut(hit)
    \tlocal humanoid = hit.Parent:FindFirstChild("Humanoid")
    \tif humanoid and humanoid.Health > 0 then
    \t\thumanoid.Health = 0
    \tend
    end

    obby.Lava.Touched:Connect(knockOut)
    obby.Spinner.Touched:Connect(knockOut)

    for name, rank in ranks do
    \tlocal pad = obby:FindFirstChild(name)
    \tpad.Touched:Connect(function(hit)
    \t\tlocal player = playerFrom(hit)
    \t\tif player == nil then
    \t\t\treturn
    \t\tend
    \t\tif rank == 0 then
    \t\t\tstartedAt[player] = time()
    \t\tend
    \t\tlocal current = reached[player]
    \t\tif current == nil or ranks[current.Name] < rank then
    \t\t\treached[player] = pad
    \t\t\tif rank > 0 then
    \t\t\t\tNotify:FireClient(player, "checkpoint", "Checkpoint " .. rank .. "!")
    \t\t\tend
    \t\tend
    \tend)
    end

    -- Back to the last checkpoint after a fall.
    local function watch(player)
    \tplayer.CharacterAdded:Connect(function(character)
    \t\tlocal pad = reached[player]
    \t\tif pad == nil then
    \t\t\treturn
    \t\tend
    \t\ttask.wait()
    \t\tcharacter:WaitForChild("HumanoidRootPart").Position = pad.Position + Vector3.new(0, 4, 0)
    \tend)
    end
    for _, player in Players:GetPlayers() do
    \twatch(player)
    end
    Players.PlayerAdded:Connect(watch)
    Players.PlayerRemoving:Connect(function(player)
    \treached[player] = nil
    \tstartedAt[player] = nil
    end)

    -- The mover glides back and forth; the spinner spins.
    local mover = obby.Mover
    TweenService:Create(mover, TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
    \tPosition = mover.Position + Vector3.new(-10.5, 0, 0),
    }):Play()

    local spinner = obby.Spinner
    RunService.Heartbeat:Connect(function()
    \tspinner.Orientation = Vector3.new(0, (time() * 75) % 360, 0)
    end)

    -- Tiles that give way under you, and come back.
    for index = 1, 4 do
    \tlocal tile = obby:FindFirstChild("Tile" .. index)
    \tlocal busy = false
    \ttile.Touched:Connect(function(hit)
    \t\tif busy or playerFrom(hit) == nil then
    \t\t\treturn
    \t\tend
    \t\tbusy = true
    \t\tfor step = 1, 6 do
    \t\t\ttile.Transparency = step / 8
    \t\t\ttask.wait(0.1)
    \t\tend
    \t\ttile.Transparency = 1
    \t\ttile.CanCollide = false
    \t\ttask.wait(2.5)
    \t\ttile.Transparency = 0
    \t\ttile.CanCollide = true
    \t\tbusy = false
    \tend)
    end

    -- The jump pad.
    obby.JumpPad.Touched:Connect(function(hit)
    \tlocal root = hit.Parent:FindFirstChild("HumanoidRootPart")
    \tif root and playerFrom(hit) then
    \t\troot.AssemblyLinearVelocity = Vector3.new(0, 105, 0)
    \tend
    end)

    -- The trophy: a Win, a time, a party hat the first time, and back down to the start.
    local finishing = {}
    obby.Trophy.Touched:Connect(function(hit)
    \tlocal player = playerFrom(hit)
    \tif player == nil or finishing[player] then
    \t\treturn
    \tend
    \tfinishing[player] = true
    \tlocal stats = player:FindFirstChild("leaderstats")
    \tif stats then
    \t\tstats.Wins.Value += 1
    \tend
    \tlocal seconds = startedAt[player] and time() - startedAt[player]
    \tNotify:FireClient(player, "win", if seconds
    \t\tthen string.format("You beat the Obby Tower in %.1f seconds!", seconds)
    \t\telse "You beat the Obby Tower!")
    \tReward:Fire(player, "builtin://PartyHat", "ObbyPartyHat", "A party hat for the champion!")
    \treached[player] = nil
    \ttask.wait(3)
    \tlocal character = player.Character
    \tlocal root = character and character:FindFirstChild("HumanoidRootPart")
    \tif root then
    \t\troot.Position = obby.Start.Position + Vector3.new(0, 4, 0)
    \tend
    \tfinishing[player] = nil
    end)

    RunService.Heartbeat:Connect(function()
    \tobby.Trophy.Orientation = Vector3.new(0, (time() * 60) % 360, 0)
    end)
    """

    static let lab = """
    -- LabScript: the Mirror Lab. The lever switches the island's Lighting.Technology
    -- between Conventional and RayTraced (for everyone in the game); the red button
    -- gives the lamps new colours; the chrome orb floats.
    local Lighting = game:GetService("Lighting")
    local RunService = game:GetService("RunService")

    local lab = script.Parent
    local lever, status, orb = lab.Lever, lab.StatusLight, lab.ChromeOrb
    local orbHome = orb.Position

    local switch = Instance.new("ClickDetector")
    switch.MaxActivationDistance = 16
    switch.Parent = lever
    switch.MouseClick:Connect(function(player)
    \tlocal on = Lighting.Technology ~= Enum.Technology.RayTraced
    \tLighting.Technology = if on then Enum.Technology.RayTraced else Enum.Technology.Conventional
    \tlever.Orientation = Vector3.new(0, 0, if on then -35 else 35)
    \tstatus.Color = if on then Color3.fromRGB(80, 255, 120) else Color3.fromRGB(255, 70, 60)
    \tprint(player.Name .. (if on then " switched ray tracing on" else " switched ray tracing off"))
    end)

    local palettes = {
    \t{ Color3.fromRGB(255, 70, 90), Color3.fromRGB(80, 140, 255), Color3.fromRGB(90, 255, 140), Color3.fromRGB(255, 120, 255) },
    \t{ Color3.fromRGB(255, 180, 60), Color3.fromRGB(255, 90, 40), Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 140, 80) },
    \t{ Color3.fromRGB(60, 220, 255), Color3.fromRGB(40, 120, 255), Color3.fromRGB(120, 255, 240), Color3.fromRGB(160, 120, 255) },
    \t{ Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 60, 60), Color3.fromRGB(60, 255, 60), Color3.fromRGB(60, 60, 255) },
    }
    local palette = 1

    local button = Instance.new("ClickDetector")
    button.MaxActivationDistance = 16
    button.Parent = lab.ShowButton
    button.MouseClick:Connect(function()
    \tpalette = palette % #palettes + 1
    \tfor index, colour in palettes[palette] do
    \t\tlocal lamp = lab:FindFirstChild("Lamp" .. index)
    \t\tlamp.Color = colour
    \t\tlamp.PointLight.Color = colour
    \tend
    \tfor _, name in { "StripNorth", "StripSouth", "StripEast" } do
    \t\tlab[name].Color = palettes[palette][1]
    \tend
    end)

    RunService.Heartbeat:Connect(function()
    \tlocal t = time()
    \torb.Position = orbHome + Vector3.new(0, math.sin(t * 1.4) * 1.2, 0)
    end)
    """

    static let npcBrain = """
    -- NPCBrain: each NPC turns, smoothly, to face the nearest player within 16 studs,
    -- and back to where it faced before when nobody is near.
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")

    local homes = {}
    for _, npc in script.Parent:GetChildren() do
    \tif npc:IsA("Model") then
    \t\thomes[npc] = npc:GetPivot()
    \tend
    end

    RunService.Heartbeat:Connect(function()
    \tfor npc, home in homes do
    \t\tlocal nearest, best = nil, 16
    \t\tfor _, player in Players:GetPlayers() do
    \t\t\tlocal character = player.Character
    \t\t\tlocal root = character and character:FindFirstChild("HumanoidRootPart")
    \t\t\tif root then
    \t\t\t\tlocal away = (root.Position - home.Position).Magnitude
    \t\t\t\tif away < best then
    \t\t\t\t\tnearest, best = root.Position, away
    \t\t\t\tend
    \t\t\tend
    \t\tend
    \t\tlocal goal = home
    \t\tif nearest then
    \t\t\tlocal level = Vector3.new(nearest.X, home.Position.Y, nearest.Z)
    \t\t\tif (level - home.Position).Magnitude > 0.5 then
    \t\t\t\tgoal = CFrame.lookAt(home.Position, level)
    \t\t\tend
    \t\tend
    \t\tlocal now = npc:GetPivot()
    \t\tif (now.LookVector - goal.LookVector).Magnitude > 0.01 then
    \t\t\tnpc:PivotTo(now:Lerp(goal, 0.15))
    \t\tend
    \tend
    end)
    """

    static let ambience = """
    -- Ambience: the lighthouse beam sweeps, the Dream Garden's islands float and its
    -- fireflies drift, and the fountain's orb bobs.
    local RunService = game:GetService("RunService")

    local beam = workspace.Lighthouse.Beam
    local garden = workspace.DreamGarden
    local orb = workspace.Plaza.FountainOrb
    local orbHome = orb.Position

    local floats = {}
    for index = 1, 3 do
    \tlocal island = garden:FindFirstChild("Float" .. index)
    \tlocal roots = garden:FindFirstChild("FloatRoots" .. index)
    \ttable.insert(floats, { island = island, roots = roots, home = island.Position, rootsHome = roots.Position })
    end
    local fireflies = {}
    for _, part in garden:GetChildren() do
    \tif part.Name == "Firefly" then
    \t\ttable.insert(fireflies, { part = part, home = part.Position })
    \tend
    end

    RunService.Heartbeat:Connect(function()
    \tlocal t = time()
    \tbeam.Orientation = Vector3.new(0, (t * 40) % 360, 0)
    \tfor index, float in floats do
    \t\tlocal lift = Vector3.new(0, math.sin(t * 0.7 + index * 2) * 0.8, 0)
    \t\tfloat.island.Position = float.home + lift
    \t\tfloat.roots.Position = float.rootsHome + lift
    \tend
    \tfor index, fly in fireflies do
    \t\tfly.part.Position = fly.home + Vector3.new(math.sin(t * 0.8 + index) * 1.5,
    \t\t\tmath.sin(t * 1.3 + index * 2) * 0.8, math.cos(t * 0.6 + index) * 1.5)
    \tend
    \torb.Position = orbHome + Vector3.new(0, math.sin(t * 1.5) * 0.3, 0)
    end)
    """

    // MARK: - Each player: StarterPlayerScripts

    static let adventure = """
    -- Adventure: each player's own screen. Press E near an NPC to talk (lines from the
    -- Dialogue module, answers from the Quest RemoteFunction); a banner names each zone
    -- you walk into, and some turn on a screen effect — only on your screen; swimming
    -- tints it; signs and name tags float over things; and the server's Notify
    -- RemoteEvent brings news of gems, checkpoints and wins, with a chime.
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local TweenService = game:GetService("TweenService")
    local SoundService = game:GetService("SoundService")
    local Lighting = game:GetService("Lighting")

    local player = Players.LocalPlayer
    local Dialogue = require(ReplicatedStorage:WaitForChild("Dialogue"))
    local Zones = require(ReplicatedStorage:WaitForChild("Zones"))
    local Notify = ReplicatedStorage:WaitForChild("Notify")
    local Quest = ReplicatedStorage:WaitForChild("Quest")

    local GOLD = Color3.fromRGB(255, 214, 102)
    local TALK_DISTANCE = 8

    local function make(className, properties, parent)
    \tlocal object = Instance.new(className)
    \tfor key, value in properties do
    \t\tobject[key] = value
    \tend
    \tif parent then
    \t\tobject.Parent = parent
    \tend
    \treturn object
    end

    local screen = make("ScreenGui", { Name = "Adventure", ResetOnSpawn = false })

    local prompt = make("TextLabel", {
    \tName = "Prompt", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -58),
    \tSize = UDim2.fromOffset(280, 34), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35,
    \tTextColor3 = Color3.new(1, 1, 1), TextSize = 15, Font = Enum.Font.GothamBold, Visible = false,
    }, screen)
    make("UICorner", { CornerRadius = UDim.new(0, 8) }, prompt)

    local panel = make("Frame", {
    \tName = "Dialogue", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -56),
    \tSize = UDim2.fromOffset(600, 200), BackgroundColor3 = Color3.fromRGB(18, 20, 28), BackgroundTransparency = 0.12,
    \tVisible = false,
    }, screen)
    make("UICorner", { CornerRadius = UDim.new(0, 12) }, panel)
    make("UIStroke", { Color = GOLD, Thickness = 2, Transparency = 0.4 }, panel)
    local speaker = make("TextLabel", {
    \tName = "Speaker", Position = UDim2.fromOffset(18, 10), Size = UDim2.new(1, -36, 0, 24),
    \tBackgroundTransparency = 1, TextColor3 = GOLD, TextSize = 17, Font = Enum.Font.GothamBold,
    \tTextXAlignment = Enum.TextXAlignment.Left,
    }, panel)
    local words = make("TextLabel", {
    \tName = "Words", Position = UDim2.fromOffset(18, 38), Size = UDim2.new(1, -36, 0, 64),
    \tBackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1), TextSize = 15, Font = Enum.Font.SourceSans,
    \tTextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    }, panel)
    local choices = make("Frame", {
    \tName = "Choices", Position = UDim2.fromOffset(18, 106), Size = UDim2.new(1, -36, 0, 86),
    \tBackgroundTransparency = 1,
    }, panel)
    make("UIListLayout", { Padding = UDim.new(0, 4) }, choices)
    local buttons = {}
    for index = 1, 3 do
    \tlocal button = make("TextButton", {
    \t\tName = "Choice" .. index, Size = UDim2.new(1, 0, 0, 25), LayoutOrder = index,
    \t\tBackgroundColor3 = Color3.fromRGB(44, 48, 64), TextColor3 = Color3.new(1, 1, 1), TextSize = 14,
    \t\tFont = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
    \t}, choices)
    \tmake("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
    \tmake("UIPadding", { PaddingLeft = UDim.new(0, 10) }, button)
    \tbuttons[index] = button
    end

    local banner = make("TextLabel", {
    \tName = "Banner", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 250),
    \tSize = UDim2.fromOffset(600, 40), BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1),
    \tTextSize = 28, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.4, TextTransparency = 1,
    }, screen)

    screen.Parent = player.PlayerGui

    -- Banners: news (gems, checkpoints, wins) takes turns, a couple of seconds each;
    -- a zone's name shows only when there's no news on screen.
    local shownAt = 0
    local news = {}
    local telling = false

    local function showBanner(text, colour)
    \tshownAt += 1
    \tbanner.Text = text
    \tbanner.TextColor3 = colour or Color3.new(1, 1, 1)
    \tbanner.TextTransparency = 0
    \tbanner.TextStrokeTransparency = 0.4
    \treturn shownAt
    end

    local function fadeLater(mine, seconds)
    \ttask.delay(seconds, function()
    \t\tif mine == shownAt and not telling then
    \t\t\tTweenService:Create(banner, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
    \t\tend
    \tend)
    end

    local function announce(text, colour)
    \tif not telling then
    \t\tfadeLater(showBanner(text, colour), 2.6)
    \tend
    end

    local function tell(text, colour)
    \ttable.insert(news, { text = text, colour = colour })
    \tif telling then
    \t\treturn
    \tend
    \ttelling = true
    \ttask.spawn(function()
    \t\twhile #news > 0 do
    \t\t\tlocal item = table.remove(news, 1)
    \t\t\tshowBanner(item.text, item.colour)
    \t\t\ttask.wait(2.4)
    \t\tend
    \t\ttelling = false
    \t\tfadeLater(shownAt, 0)
    \tend)
    end

    local function chime()
    \tlocal sound = SoundService:FindFirstChild("Chime")
    \tif sound then
    \t\tSoundService:PlayLocalSound(sound)
    \tend
    end

    Notify.OnClientEvent:Connect(function(kind, text)
    \ttell(text, if kind == "win" then GOLD elseif kind == "gem" then Color3.fromRGB(140, 240, 255) else nil)
    \tchime()
    end)

    -- Name tags over the NPCs, and what the signs say.
    local npcs = workspace:WaitForChild("NPCs")
    for _, npc in npcs:GetChildren() do
    \tif npc:IsA("Model") then
    \t\tlocal tag = make("BillboardGui", {
    \t\t\tAdornee = npc:FindFirstChild("Head"), Size = UDim2.fromOffset(200, 26),
    \t\t\tStudsOffset = Vector3.new(0, 2, 0), MaxDistance = 70,
    \t\t})
    \t\tmake("TextLabel", {
    \t\t\tSize = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = npc.Name, TextColor3 = GOLD,
    \t\t\tTextSize = 16, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.3,
    \t\t}, tag)
    \t\ttag.Parent = player.PlayerGui
    \tend
    end

    for _, board in workspace:WaitForChild("Signs"):GetChildren() do
    \tlocal text = board:FindFirstChild("Text")
    \tif text then
    \t\tlocal sign = make("BillboardGui", {
    \t\t\tAdornee = board, Size = UDim2.fromOffset(420, 70), StudsOffset = Vector3.new(0, 2.2, 0), MaxDistance = 55,
    \t\t})
    \t\tmake("TextLabel", {
    \t\t\tSize = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = text.Value, TextColor3 = Color3.new(1, 1, 1),
    \t\t\tTextSize = 15, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.25, TextWrapped = true,
    \t\t}, sign)
    \t\tsign.Parent = player.PlayerGui
    \tend
    end

    local lab = workspace:WaitForChild("MirrorLab")
    local labSign = make("BillboardGui", {
    \tAdornee = lab.StatusLight, Size = UDim2.fromOffset(260, 44), StudsOffset = Vector3.new(0, 2.6, 0), MaxDistance = 40,
    })
    local labText = make("TextLabel", {
    \tSize = UDim2.fromScale(1, 1), BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1), TextSize = 15,
    \tFont = Enum.Font.GothamBold, TextStrokeTransparency = 0.25, TextWrapped = true,
    }, labSign)
    labSign.Parent = player.PlayerGui

    -- Talking.
    local talking = nil
    local node = nil
    local typing = 0

    local function fill(text)
    \tlocal stats = player:FindFirstChild("leaderstats")
    \treturn (string.gsub(text, "{(%w+)}", function(key)
    \t\tif key == "name" then
    \t\t\treturn player.Name
    \t\tend
    \t\tlocal stat = stats and stats:FindFirstChild(key == "gems" and "Gems" or "Wins")
    \t\treturn tostring(stat and stat.Value or 0)
    \tend))
    end

    local function typeOut(text)
    \ttyping += 1
    \tlocal mine = typing
    \twords.Text = ""
    \ttask.spawn(function()
    \t\tlocal shown = 0
    \t\twhile shown < #text and mine == typing do
    \t\t\tshown = math.min(#text, shown + 3)
    \t\t\twords.Text = string.sub(text, 1, shown)
    \t\t\ttask.wait(0.02)
    \t\tend
    \tend)
    end

    local function show(entry)
    \tnode = entry
    \ttypeOut(fill(entry.text))
    \tlocal options = entry.options or { { text = "Bye!" } }
    \tfor index, button in buttons do
    \t\tlocal option = options[index]
    \t\tbutton.Visible = option ~= nil
    \t\tbutton.Text = if option then index .. ".  " .. option.text else ""
    \tend
    end

    local function close()
    \ttalking = nil
    \tnode = nil
    \ttyping += 1
    \tpanel.Visible = false
    end

    local function open(npc)
    \tlocal lines = Dialogue[npc.Name]
    \tif lines == nil then
    \t\treturn
    \tend
    \ttalking = npc
    \tspeaker.Text = npc.Name
    \tpanel.Visible = true
    \tprompt.Visible = false
    \tshow(lines.start)
    end

    local function choose(index)
    \tif talking == nil or node == nil then
    \t\treturn
    \tend
    \tlocal options = node.options or { { text = "Bye!" } }
    \tlocal option = options[index]
    \tif option == nil then
    \t\treturn
    \tend
    \tif option.go then
    \t\tshow(Dialogue[talking.Name][option.go])
    \telseif option.action then
    \t\tlocal ok, answer = pcall(function()
    \t\t\treturn Quest:InvokeServer(option.action)
    \t\tend)
    \t\tshow({ text = if ok then answer else "Sorry, something went wrong.", options = { { text = "Thanks!" } } })
    \telse
    \t\tclose()
    \tend
    end

    for index, button in buttons do
    \tbutton.MouseButton1Click:Connect(function()
    \t\tchoose(index)
    \tend)
    end

    local nearestNpc = nil
    local keys = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3 }
    UserInputService.InputBegan:Connect(function(input)
    \tif input.KeyCode == Enum.KeyCode.E then
    \t\tif talking then
    \t\t\tclose()
    \t\telseif nearestNpc then
    \t\t\topen(nearestNpc)
    \t\tend
    \telseif keys[input.KeyCode] then
    \t\tchoose(keys[input.KeyCode])
    \tend
    end)

    -- Zones and their screen effects.
    local zone = nil
    local effect = nil

    local function setEffect(name)
    \tif name == effect then
    \t\treturn
    \tend
    \tif effect then
    \t\tlocal old = Shaders:FindFirstChild(effect)
    \t\tif old then
    \t\t\tScreen:RemoveShader(old)
    \t\tend
    \tend
    \teffect = name
    \tif name then
    \t\tlocal shader = Shaders:FindFirstChild(name)
    \t\tif shader then
    \t\t\tScreen:AddShader(shader)
    \t\tend
    \tend
    end

    local function zoneAt(position)
    \tfor _, entry in Zones do
    \t\tlocal low, high = entry.min, entry.max
    \t\tif position.X >= low.X and position.X <= high.X and position.Y >= low.Y and position.Y <= high.Y
    \t\t\tand position.Z >= low.Z and position.Z <= high.Z then
    \t\t\treturn entry
    \t\tend
    \tend
    \treturn nil
    end

    local elapsed = 0
    RunService.Heartbeat:Connect(function(dt)
    \tlocal character = player.Character
    \tlocal root = character and character:FindFirstChild("HumanoidRootPart")
    \tlocal humanoid = character and character:FindFirstChild("Humanoid")
    \tif root == nil or humanoid == nil then
    \t\treturn
    \tend
    \tlocal at = root.Position

    \t-- Who is near enough to talk to.
    \tnearestNpc = nil
    \tlocal best = TALK_DISTANCE
    \tfor _, npc in npcs:GetChildren() do
    \t\tif npc:IsA("Model") then
    \t\t\tlocal there = npc:GetPivot().Position
    \t\t\tlocal away = Vector3.new(there.X - at.X, 0, there.Z - at.Z).Magnitude
    \t\t\tif away < best and math.abs(there.Y - at.Y) < 6 then
    \t\t\t\tnearestNpc, best = npc, away
    \t\t\tend
    \t\tend
    \tend
    \tif talking and (talking:GetPivot().Position - at).Magnitude > TALK_DISTANCE + 6 then
    \t\tclose()
    \tend
    \tprompt.Visible = nearestNpc ~= nil and talking == nil
    \tif nearestNpc then
    \t\tprompt.Text = "[E]  Talk to " .. nearestNpc.Name
    \tend

    \t-- A few times a second: the zone, its effect, and the lab's sign.
    \telapsed += dt
    \tif elapsed < 0.15 then
    \t\treturn
    \tend
    \telapsed = 0
    \tlocal here = zoneAt(at)
    \tif here ~= zone then
    \t\tzone = here
    \t\tif here then
    \t\t\tannounce(here.name)
    \t\tend
    \tend
    \tif humanoid:GetState() == Enum.HumanoidStateType.Swimming then
    \t\tsetEffect("Underwater")
    \telse
    \t\tsetEffect(zone and zone.effect or nil)
    \tend
    \tlocal traced = Lighting.Technology == Enum.Technology.RayTraced
    \tlabText.Text = if traced then "Ray tracing: ON\\nclick the lever to switch it off"
    \t\telse "Ray tracing: OFF\\nclick the lever to switch it on"
    \tlabText.TextColor3 = if traced then Color3.fromRGB(120, 255, 150) else Color3.fromRGB(255, 140, 120)
    end)

    task.delay(1.5, function()
    \ttell("Welcome to Adventure Island!", GOLD)
    end)
    """

    // MARK: - Shaders

    static let crystalShader = """
    // Crystal: light inside the stone, shifting colour as you walk round it.
    float diffuse = saturate(dot(normal, lightDirection)) * shadow;
    float facing = saturate(dot(normal, viewDirection));
    float rim = pow(1.0 - facing, 3.0);
    float3 hue = 0.5 + 0.5 * cos(6.28318 * (worldPosition.y * 0.08 + facing * 0.6 + time * speed * 0.1
                                            + float3(0.0, 0.33, 0.67)));
    float pulse = 0.6 + 0.4 * sin(time * speed + worldPosition.x * 0.7 + worldPosition.z * 0.5);
    float3 lit = baseColor * (ambientColor + diffuse * lightColor * 0.6);
    return lit * 0.5 + hue * (0.35 + rim * 1.2) * pulse * glow;
    """

    static let rainbowShader = """
    // Rainbow: bands of colour climbing the surface, as if it were soap film.
    float diffuse = saturate(dot(normal, lightDirection)) * shadow;
    float3 bands = 0.5 + 0.5 * cos(6.28318 * (worldPosition.y * 0.15 + (worldPosition.x + worldPosition.z) * 0.05
                                              - time * speed * 0.2 + float3(0.0, 0.33, 0.67)));
    float3 lit = mix(baseColor, bands, 0.7) * (ambientColor + diffuse * lightColor * 0.9);
    return lit + bands * 0.15;
    """

    static let lavaShader = """
    // Lava: a dark crust with molten cracks that flow and glow.
    float flow = sin(worldPosition.x * 0.6 + time * speed) * sin(worldPosition.z * 0.8 - time * speed * 0.7)
               + 0.5 * sin((worldPosition.x + worldPosition.z) * 1.3 + time * speed * 1.3);
    float cracks = pow(saturate(1.0 - abs(flow) * 1.2), 3.0);
    float3 crust = float3(0.30, 0.05, 0.02);
    float3 molten = float3(1.0, 0.45, 0.05);
    float breathe = 0.8 + 0.2 * sin(time * 2.0 + worldPosition.x * 0.3);
    return mix(crust, molten * 1.7, cracks) * breathe + molten * 0.12;
    """

    static let rippleShader = """
    // Ripple: water whose colour rolls with little waves, and a glint of sun.
    float wave = sin(worldPosition.x * 0.5 + time * speed) * 0.5 + sin(worldPosition.z * 0.7 - time * speed * 0.8) * 0.5;
    float diffuse = saturate(dot(normal, lightDirection)) * shadow;
    float3 deep = float3(0.05, 0.30, 0.50);
    float3 shallow = float3(0.20, 0.65, 0.80);
    float3 colour = mix(deep, shallow, 0.5 + 0.5 * wave);
    float glint = pow(saturate(dot(reflect(-lightDirection, normal), viewDirection)), 40.0) * (0.6 + 0.4 * wave);
    return colour * (ambientColor + diffuse * lightColor * 0.8) + glint;
    """

    static let caveGlowShader = """
    // Cave Glow: cool, dim edges and a faint glitter in the air of the Crystal Caves.
    float2 centre = uv - 0.5;
    float vignette = 1.0 - smoothstep(0.30, 0.85, length(centre * float2(1.2, 1.0)));
    float3 tint = float3(0.78, 0.92, 1.15);
    float2 cell = floor(uv * resolution / 3.0);
    float glitter = step(0.9985, fract(sin(dot(cell, float2(12.9898, 78.233)) + floor(time * 4.0)) * 43758.5453));
    float3 colour = sceneColor * tint * mix(0.55, 1.0, vignette) + glitter * float3(0.6, 0.8, 1.0);
    return mix(sceneColor, colour, amount);
    """

    static let dreamyShader = """
    // Dreamy: the world sways, softens and shimmers with colour in the Dream Garden.
    float2 sway = float2(sin(uv.y * 18.0 + time * 1.6), cos(uv.x * 14.0 + time * 1.3)) * 0.004 * amount;
    float3 swayed = sample(uv + sway);
    float2 px = 3.0 / resolution;
    float3 soft = (sample(uv + float2(px.x, 0.0)) + sample(uv - float2(px.x, 0.0))
                 + sample(uv + float2(0.0, px.y)) + sample(uv - float2(0.0, px.y))) * 0.25;
    float3 shimmer = 0.5 + 0.5 * cos(6.28318 * (uv.x + uv.y * 0.5 + time * 0.1 + float3(0.0, 0.33, 0.67)));
    float3 dream = mix(swayed, swayed * 0.75 + shimmer * 0.3, 0.35) + soft * 0.12;
    return mix(sceneColor, dream, amount);
    """

    static let underwaterShader = """
    // Underwater: blue-green, wavering, murky with distance, with rippling light.
    float2 waver = float2(sin(uv.y * 30.0 + time * 3.0), cos(uv.x * 25.0 + time * 2.4)) * 0.003 * amount;
    float3 seen = sample(uv + waver);
    float murk = saturate(distance / 60.0);
    float3 water = float3(0.05, 0.30, 0.45);
    float3 under = mix(seen * float3(0.55, 0.85, 1.0), water, murk * 0.8);
    float caustic = pow(saturate(sin(uv.x * 40.0 + time * 2.0) * sin(uv.y * 35.0 - time * 1.5)), 8.0) * 0.25;
    return mix(sceneColor, under + caustic, amount);
    """
}
