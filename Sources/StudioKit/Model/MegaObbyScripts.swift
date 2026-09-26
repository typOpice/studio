import Foundation

/// Mega Obby's scripts, in Luau, and its floor shaders.
enum MegaObbyScripts {

    static let mechanics = """
    -- Mechanics: what makes the course dangerous and alive, all by part name, so any
    -- stage you add in Studio works the same way:
    --   KillBrick, KillFloor   knock you out
    --   Mover                  slides to and fro by its Offset (a Vector3Value) over its Seconds
    --   KillMover              a Mover that knocks you out
    --   Spinner                turns at its Speed (degrees a second) and knocks you out
    --   FadeTile               gives way a moment after you step on it, then comes back
    --   JumpPad                throws you up at its Power
    local RunService = game:GetService("RunService")
    local TweenService = game:GetService("TweenService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Utils = require(ReplicatedStorage.Utils)

    local function knockOut(hit)
    \tlocal humanoid = Utils.getHumanoid(hit)
    \tif humanoid and humanoid.Health > 0 then
    \t\thumanoid.Health = 0
    \tend
    end

    local function number(part, name, default)
    \tlocal value = part:FindFirstChild(name)
    \treturn if value then value.Value else default
    end

    local spinners = {}

    for _, part in workspace:GetDescendants() do
    \tif not part:IsA("BasePart") then
    \t\tcontinue
    \tend
    \tlocal name = part.Name
    \tif name == "KillBrick" or name == "KillFloor" or name == "KillMover" or name == "Spinner" then
    \t\tpart.Touched:Connect(knockOut)
    \tend
    \tif name == "Mover" or name == "KillMover" then
    \t\tlocal offset = part:FindFirstChild("Offset")
    \t\tif offset then
    \t\t\tlocal info = TweenInfo.new(number(part, "Seconds", 2), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
    \t\t\tTweenService:Create(part, info, { Position = part.Position + offset.Value }):Play()
    \t\tend
    \telseif name == "Spinner" then
    \t\ttable.insert(spinners, {
    \t\t\tpart = part, centre = part.Position, angle = math.rad(part.Orientation.Y),
    \t\t\tspeed = math.rad(number(part, "Speed", 90)),
    \t\t})
    \telseif name == "FadeTile" then
    \t\tlocal fading = false
    \t\tpart.Touched:Connect(function(hit)
    \t\t\tif fading or Utils.getHumanoid(hit) == nil then
    \t\t\t\treturn
    \t\t\tend
    \t\t\tfading = true
    \t\t\tUtils.tween(part, 0.5, { Transparency = 0.8 })
    \t\t\ttask.wait(0.5)
    \t\t\tpart.CanCollide = false
    \t\t\tpart.Transparency = 1
    \t\t\ttask.wait(2.5)
    \t\t\tpart.CanCollide = true
    \t\t\tpart.Transparency = 0
    \t\t\tfading = false
    \t\tend)
    \telseif name == "JumpPad" then
    \t\tlocal power = number(part, "Power", 90)
    \t\tlocal ready = Utils.cooldown(0.5)
    \t\tpart.Touched:Connect(function(hit)
    \t\t\tlocal player = Utils.playerFromPart(hit)
    \t\t\tlocal root = Utils.getRoot(hit)
    \t\t\tif player and root and ready(player) then
    \t\t\t\troot.AssemblyLinearVelocity = Vector3.new(0, power, 0)
    \t\t\tend
    \t\tend)
    \tend
    end

    RunService.Heartbeat:Connect(function(dt)
    \tfor _, spinner in spinners do
    \t\tspinner.angle += spinner.speed * dt
    \t\tspinner.part.CFrame = CFrame.new(spinner.centre) * CFrame.Angles(0, spinner.angle, 0)
    \tend
    end)
    """

    static let game = """
    -- ObbyGame: stages and checkpoints. Each Checkpoint has a Stage number: touch one and
    -- that's where you come back to; the highest you've reached is your Stage on the
    -- leaderboard. The Finish after the last stage is a Win, with your time. The screen's
    -- stage picker (GoToStage) takes you to any stage you've reached. Your furthest stage
    -- and your wins are saved (a DataStore), so next time you carry on from there.
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local DataStoreService = game:GetService("DataStoreService")
    local Utils = require(ReplicatedStorage.Utils)

    local Progress = DataStoreService:GetDataStore("ObbyProgress")

    local Notify = ReplicatedStorage.Notify
    local GoToStage = ReplicatedStorage.GoToStage

    -- The checkpoints by stage, read from the course.
    local checkpoints = {}
    local worlds = {}
    local last = 0
    for _, part in workspace:GetDescendants() do
    \tif part.Name == "Checkpoint" and part:IsA("BasePart") then
    \t\tlocal stage = part:FindFirstChild("Stage")
    \t\tif stage then
    \t\t\tcheckpoints[stage.Value] = part
    \t\t\tlast = math.max(last, stage.Value)
    \t\t\tlocal world = part:FindFirstChild("World")
    \t\t\tif world then
    \t\t\t\tworlds[stage.Value] = world.Value
    \t\t\tend
    \t\tend
    \tend
    end

    -- Where each player comes back to, the furthest they've got, and when they began.
    local current, reached, startedAt = {}, {}, {}

    -- Saved by name: the same player next time, whoever hosts.
    local function saveKey(player)
    \treturn "player_" .. player.Name
    end

    local function save(player)
    \tif reached[player] == nil then
    \t\treturn
    \tend
    \tlocal ok, problem = pcall(function()
    \t\tProgress:SetAsync(saveKey(player), { Stage = reached[player], Wins = player.leaderstats.Wins.Value })
    \tend)
    \tif not ok then
    \t\twarn("Couldn't save " .. player.Name .. "'s progress: " .. tostring(problem))
    \tend
    end

    local function sendTo(player, stage)
    \tlocal pad = checkpoints[stage]
    \tlocal root = Utils.getRoot(player)
    \tif pad and root then
    \t\troot.Position = pad.Position + Vector3.new(0, 4, 0)
    \t\troot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    \tend
    end

    local function setCurrent(player, stage)
    \tcurrent[player] = stage
    \tlocal run = player:FindFirstChild("Run")
    \tif run then
    \t\trun.Current.Value = stage
    \tend
    end

    local function setUp(player)
    \tlocal leaderstats = Instance.new("Folder")
    \tleaderstats.Name = "leaderstats"
    \tleaderstats.Parent = player
    \tlocal stage = Instance.new("IntValue")
    \tstage.Name = "Stage"
    \tstage.Value = 1
    \tstage.Parent = leaderstats
    \tlocal wins = Instance.new("IntValue")
    \twins.Name = "Wins"
    \twins.Parent = leaderstats
    \tlocal run = Instance.new("Folder")
    \trun.Name = "Run"
    \trun.Parent = player
    \tfor _, name in { "Current", "Deaths" } do
    \t\tlocal value = Instance.new("IntValue")
    \t\tvalue.Name = name
    \t\tvalue.Parent = run
    \tend
    \t-- Back where they got to last time.
    \tlocal ok, saved = pcall(function()
    \t\treturn Progress:GetAsync(saveKey(player))
    \tend)
    \tlocal from = 1
    \tif ok and type(saved) == "table" then
    \t\tfrom = math.clamp(math.floor(tonumber(saved.Stage) or 1), 1, last)
    \t\twins.Value = tonumber(saved.Wins) or 0
    \tend
    \tstage.Value = from
    \trun.Current.Value = from
    \tcurrent[player], reached[player], startedAt[player] = from, from, time()
    \tif from > 1 then
    \t\tNotify:FireClient(player, "Welcome back! You're on stage " .. from .. ".")
    \tend

    \tlocal function arrived(character)
    \t\tsendTo(player, current[player])
    \t\tlocal humanoid = Utils.getHumanoid(character)
    \t\tif humanoid then
    \t\t\thumanoid.Died:Connect(function()
    \t\t\t\trun.Deaths.Value += 1
    \t\t\tend)
    \t\tend
    \tend
    \tplayer.CharacterAdded:Connect(arrived)
    \tif player.Character then
    \t\tarrived(player.Character)
    \tend
    end

    for stage, pad in checkpoints do
    \tpad.Touched:Connect(function(hit)
    \t\tlocal player = Utils.playerFromPart(hit)
    \t\tif player == nil or current[player] == nil then
    \t\t\treturn
    \t\tend
    \t\tif current[player] ~= stage then
    \t\t\tsetCurrent(player, stage)
    \t\tend
    \t\tif stage > reached[player] then
    \t\t\treached[player] = stage
    \t\t\tplayer.leaderstats.Stage.Value = stage
    \t\t\tNotify:FireClient(player, worlds[stage] or ("Stage " .. stage .. "!"))
    \t\t\tsave(player)
    \t\tend
    \tend)
    end

    -- The finish: a Win, once each time you get there.
    local canWin = Utils.cooldown(5)
    workspace:FindFirstChild("Finish Line").Finish.Touched:Connect(function(hit)
    \tlocal player = Utils.playerFromPart(hit)
    \tif player == nil or current[player] == nil or reached[player] < last or not canWin(player) then
    \t\treturn
    \tend
    \tplayer.leaderstats.Wins.Value += 1
    \tsave(player)
    \tlocal took = Utils.formatTime(time() - startedAt[player])
    \tNotify:FireClient(player, "You beat all " .. last .. " stages in " .. took .. "!")
    \tNotify:FireAllClients(player.Name .. " finished the Mega Obby!")
    \tstartedAt[player] = time()
    end)

    GoToStage.OnServerEvent:Connect(function(player, stage)
    \tif type(stage) ~= "number" or reached[player] == nil then
    \t\treturn
    \tend
    \tstage = math.floor(stage)
    \tif stage >= 1 and stage <= reached[player] and checkpoints[stage] then
    \t\tsetCurrent(player, stage)
    \t\tsendTo(player, stage)
    \tend
    end)

    Players.PlayerRemoving:Connect(function(player)
    \tsave(player)
    \tcurrent[player], reached[player], startedAt[player] = nil, nil, nil
    end)

    for _, player in Players:GetPlayers() do
    \tsetUp(player)
    end
    Players.PlayerAdded:Connect(setUp)
    print("Mega Obby: " .. last .. " stages. Good luck!")
    """

    static let screen = """
    -- ObbyScreen: your stage and world, how far along you are, your time and deaths; a
    -- stage picker (the arrows, or Q and E) to go back to any stage you've reached; R to
    -- go back to your checkpoint; the stage number over every checkpoint; and news.
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    local Utils = require(ReplicatedStorage:WaitForChild("Utils"))
    local Notify = ReplicatedStorage:WaitForChild("Notify")
    local GoToStage = ReplicatedStorage:WaitForChild("GoToStage")
    local stages = ReplicatedStorage:WaitForChild("Stages").Value
    local leaderstats = player:WaitForChild("leaderstats")
    local reachedValue = leaderstats:WaitForChild("Stage")
    local run = player:WaitForChild("Run")
    local currentValue = run:WaitForChild("Current")
    local deathsValue = run:WaitForChild("Deaths")

    local GOLD = Color3.fromRGB(255, 210, 80)
    local WHITE = Color3.new(1, 1, 1)
    local WORLDS = { "Grassy Meadows", "Lava Caves", "Frozen Peaks", "Candy Land", "Neon City", "Sky Kingdom" }

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

    local screen = make("ScreenGui", { Name = "ObbyScreen", ResetOnSpawn = false })

    local top = make("Frame", {
    \tName = "Top", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
    \tSize = UDim2.fromOffset(420, 74), BackgroundTransparency = 1,
    }, screen)
    local stageLabel = make("TextLabel", {
    \tName = "StageLabel", Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, TextColor3 = WHITE,
    \tTextSize = 26, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.4, Text = "",
    }, top)
    local worldLabel = make("TextLabel", {
    \tName = "WorldLabel", Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
    \tTextColor3 = GOLD, TextSize = 14, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.5, Text = "",
    }, top)
    local bar = make("Frame", {
    \tName = "Progress", Position = UDim2.fromOffset(60, 54), Size = UDim2.new(1, -120, 0, 8),
    \tBackgroundColor3 = Color3.fromRGB(30, 34, 44), BackgroundTransparency = 0.2,
    }, top)
    make("UICorner", { CornerRadius = UDim.new(0, 4) }, bar)
    local fill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD }, bar)
    make("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)
    local clock = make("TextLabel", {
    \tName = "Clock", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 86),
    \tSize = UDim2.fromOffset(300, 18), BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(210, 220, 235),
    \tTextSize = 14, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.5, Text = "",
    }, screen)

    -- The stage picker, bottom middle.
    local picker = make("Frame", {
    \tName = "Picker", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -56),
    \tSize = UDim2.fromOffset(260, 40), BackgroundColor3 = Color3.fromRGB(18, 20, 28), BackgroundTransparency = 0.2,
    }, screen)
    make("UICorner", { CornerRadius = UDim.new(0, 10) }, picker)
    local back = make("TextButton", {
    \tName = "Back", Position = UDim2.fromOffset(6, 5), Size = UDim2.fromOffset(40, 30), Text = "<",
    \tBackgroundColor3 = Color3.fromRGB(44, 48, 64), TextColor3 = WHITE, TextSize = 18, Font = Enum.Font.GothamBold,
    }, picker)
    make("UICorner", { CornerRadius = UDim.new(0, 7) }, back)
    local on = make("TextButton", {
    \tName = "Next", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 5), Size = UDim2.fromOffset(40, 30),
    \tText = ">", BackgroundColor3 = Color3.fromRGB(44, 48, 64), TextColor3 = WHITE, TextSize = 18,
    \tFont = Enum.Font.GothamBold,
    }, picker)
    make("UICorner", { CornerRadius = UDim.new(0, 7) }, on)
    local pickerLabel = make("TextLabel", {
    \tName = "PickerLabel", Position = UDim2.fromOffset(50, 0), Size = UDim2.new(1, -100, 1, 0),
    \tBackgroundTransparency = 1, TextColor3 = WHITE, TextSize = 15, Font = Enum.Font.GothamBold, Text = "",
    }, picker)

    local banner = make("TextLabel", {
    \tName = "Banner", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 250),
    \tSize = UDim2.fromOffset(640, 40), BackgroundTransparency = 1, TextColor3 = GOLD,
    \tTextSize = 28, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.4, TextTransparency = 1,
    }, screen)

    screen.Parent = player.PlayerGui

    -- News, one at a time.
    local news = {}
    local telling = false
    Notify.OnClientEvent:Connect(function(text)
    \ttable.insert(news, text)
    \tif telling then
    \t\treturn
    \tend
    \ttelling = true
    \ttask.spawn(function()
    \t\twhile #news > 0 do
    \t\t\tbanner.Text = table.remove(news, 1)
    \t\t\tbanner.TextTransparency = 0
    \t\t\tbanner.TextStrokeTransparency = 0.4
    \t\t\ttask.wait(2.2)
    \t\tend
    \t\tbanner.TextTransparency = 1
    \t\tbanner.TextStrokeTransparency = 1
    \t\ttelling = false
    \tend)
    end)

    local function go(step)
    \tlocal target = math.clamp(currentValue.Value + step, 1, reachedValue.Value)
    \tif target ~= currentValue.Value then
    \t\tGoToStage:FireServer(target)
    \tend
    end
    back.MouseButton1Click:Connect(function()
    \tgo(-1)
    end)
    on.MouseButton1Click:Connect(function()
    \tgo(1)
    end)

    UserInputService.InputBegan:Connect(function(input, processed)
    \tif processed then
    \t\treturn
    \tend
    \tif input.KeyCode == Enum.KeyCode.Q then
    \t\tgo(-1)
    \telseif input.KeyCode == Enum.KeyCode.E then
    \t\tgo(1)
    \telseif input.KeyCode == Enum.KeyCode.R then
    \t\tplayer:LoadCharacter()
    \tend
    end)

    -- The stage number over every checkpoint.
    for _, pad in workspace.Checkpoints:GetChildren() do
    \tlocal stage = pad:FindFirstChild("Stage")
    \tif stage then
    \t\tlocal board = make("BillboardGui", {
    \t\t\tAdornee = pad, Size = UDim2.fromOffset(60, 30), StudsOffset = Vector3.new(0, 3, 0), MaxDistance = 70,
    \t\t}, screen)
    \t\tmake("TextLabel", {
    \t\t\tSize = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = tostring(stage.Value), TextColor3 = WHITE,
    \t\t\tTextSize = 24, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.3,
    \t\t}, board)
    \tend
    end

    local startedAt = time()
    local function refresh()
    \tlocal stage = reachedValue.Value
    \tstageLabel.Text = "Stage " .. currentValue.Value .. " / " .. stages
    \tworldLabel.Text = "World " .. math.min((currentValue.Value - 1) // 10 + 1, #WORLDS) .. ": "
    \t\t.. WORLDS[math.min((currentValue.Value - 1) // 10 + 1, #WORLDS)]
    \tfill.Size = UDim2.fromScale(math.clamp(stage / stages, 0, 1), 1)
    \tclock.Text = Utils.formatTime(time() - startedAt) .. "     Deaths " .. deathsValue.Value
    \tpickerLabel.Text = "Stage " .. currentValue.Value .. " of " .. stage
    end

    task.spawn(function()
    \twhile true do
    \t\trefresh()
    \t\ttask.wait(0.2)
    \tend
    end)
    """

    // MARK: - Shaders

    static let gridShader = """
    // Grid: a dark floor with glowing lines that pulse outwards.
    float2 cell = fract(worldPosition.xz / 8.0);
    float line = max(smoothstep(0.94, 1.0, cell.x) + smoothstep(0.06, 0.0, cell.x),
                     smoothstep(0.94, 1.0, cell.y) + smoothstep(0.06, 0.0, cell.y));
    float pulse = 0.5 + 0.5 * sin(length(worldPosition.xz) * 0.05 - time * speed * 2.0);
    float3 glow = mix(float3(0.0, 0.9, 1.0), float3(1.0, 0.2, 0.8), pulse);
    return baseColor * 0.4 + glow * line * (0.6 + 0.6 * pulse);
    """

    static let cloudShader = """
    // Clouds: soft white that drifts, with a glow where the sun catches it.
    float drift = sin(worldPosition.x * 0.08 + time * speed) * sin(worldPosition.z * 0.07 - time * speed * 0.8);
    float puff = 0.85 + 0.15 * drift;
    float sun = saturate(dot(normal, lightDirection)) * shadow;
    return float3(0.96, 0.97, 1.0) * puff * (0.75 + 0.35 * sun) + float3(0.05, 0.05, 0.1);
    """
}
