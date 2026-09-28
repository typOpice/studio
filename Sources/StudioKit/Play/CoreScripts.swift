import Foundation

/// The scripts every player gets unless the scene overrides them — Roblox's default
/// PlayerModule, Health, chat and backpack scripts.
///
/// They are ordinary Luau, not special engine code: the character moves only
/// because `ControlScript` calls `humanoid:Move` each frame. A scene script with the
/// same name in the same StarterPlayer folder replaces one of these (even a disabled
/// one, which is how you switch the default controls off), and the editor offers an
/// editable copy of each as a starting point.
enum CoreScripts {

    static let controlScript: ScriptObject = {
        var script = ScriptObject.blank(language: .luau)
        script.id = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
        script.name = "ControlScript"
        script.host = .starterPlayer
        script.source = controlScriptSource
        return script
    }()

    static let healthScript: ScriptObject = {
        var script = ScriptObject.blank(language: .luau)
        script.id = UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!
        script.name = "Health"
        script.host = .starterCharacter
        script.source = healthScriptSource
        return script
    }()

    static let chatScript: ScriptObject = {
        var script = ScriptObject.blank(language: .luau)
        script.id = UUID(uuidString: "00000000-0000-0000-0000-00000000C003")!
        script.name = "ChatScript"
        script.host = .starterPlayer
        script.source = chatScriptSource
        return script
    }()

    static let backpackScript: ScriptObject = {
        var script = ScriptObject.blank(language: .luau)
        script.id = UUID(uuidString: "00000000-0000-0000-0000-00000000C004")!
        script.name = "BackpackScript"
        script.host = .starterPlayer
        script.source = backpackScriptSource
        return script
    }()

    static let animateScript: ScriptObject = {
        var script = ScriptObject.blank(language: .luau)
        script.id = UUID(uuidString: "00000000-0000-0000-0000-00000000C005")!
        script.name = "Animate"
        script.host = .starterCharacter
        script.source = animateScriptSource
        return script
    }()

    static let all: [ScriptObject] = [controlScript, healthScript, chatScript, backpackScript, animateScript]

    static func script(id: UUID) -> ScriptObject? { all.first { $0.id == id } }

    /// The core scripts that still apply once the scene's own scripts are considered.
    static func active(overriddenBy scripts: [ScriptObject]) -> [ScriptObject] {
        all.filter { core in
            !scripts.contains { $0.host == core.host && $0.name == core.name }
        }
    }

    static let animateScriptSource = """
    -- Animate: the character's animations, played as its Humanoid's state changes.
    --
    -- The built-in animations are tracks like any other: "builtin://Walk" and the rest,
    -- at Core priority, under anything else a game plays. To change them, select this in
    -- StarterPlayer and choose "Edit a Copy", then load your own instead — an animation
    -- made in the Animation Editor, by its name. A LocalScript called Animate in
    -- StarterCharacterScripts replaces this one; a disabled one leaves the character
    -- standing still.

    local character = script.Parent
    local humanoid = character:WaitForChild("Humanoid")

    local function load(id)
    	local animation = Instance.new("Animation")
    	animation.AnimationId = id
    	return humanoid:LoadAnimation(animation)
    end

    local tracks = {
    	Idle = load("builtin://Idle"),
    	Walk = load("builtin://Walk"),
    	Jump = load("builtin://Jump"),
    	Fall = load("builtin://Fall"),
    	Climb = load("builtin://Climb"),
    	Swim = load("builtin://Swim"),
    	Sit = load("builtin://Sit"),
    	Fly = load("builtin://Fly"),
    }
    local FADE = 0.15

    local playing = nil
    local function play(name)
    	local track = tracks[name]
    	if track == playing then
    		return
    	end
    	if playing ~= nil then
    		playing:Stop(FADE)
    	end
    	playing = track
    	track:Play(FADE)
    end

    local speed = 0
    local byState = {
    	[Enum.HumanoidStateType.Jumping] = "Jump",
    	[Enum.HumanoidStateType.Freefall] = "Fall",
    	[Enum.HumanoidStateType.Climbing] = "Climb",
    	[Enum.HumanoidStateType.Swimming] = "Swim",
    	[Enum.HumanoidStateType.Seated] = "Sit",
    	[Enum.HumanoidStateType.Flying] = "Fly",
    }
    local function pick(state)
    	if byState[state] then
    		play(byState[state])
    	elseif state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.Landed then
    		play(if speed > 0.3 then "Walk" else "Idle")
    	end
    end

    humanoid.StateChanged:Connect(function(_, state)
    	pick(state)
    end)
    humanoid.Running:Connect(function(newSpeed)
    	speed = newSpeed
    	pick(humanoid:GetState())
    end)
    pick(humanoid:GetState())
    """

    static let controlScriptSource = """
    -- ControlScript: the default character controls.
    --
    -- Keys become calls on the Humanoid, and the Humanoid is all that moves the
    -- character. To change the controls, select this in StarterPlayer and choose
    -- "Edit a Copy", or add your own script named "ControlScript" to
    -- StarterPlayerScripts. It replaces this one; a disabled one removes the controls.
    -- (Flying on F and respawning on R are the default HUD's FlyAndRespawn script, in
    -- StarterGui > PlayerHud.)

    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    local SPRINT_MULTIPLIER = 1.9

    local function currentHumanoid()
    \tlocal character = player.Character
    \tif character == nil then
    \t\treturn nil
    \tend
    \treturn character:FindFirstChild("Humanoid")
    end

    local function held(keyCode)
    \treturn if UserInputService:IsKeyDown(keyCode) then 1 else 0
    end

    -- A VehicleSeat's heads-up display: the driver's speed, while they drive one with
    -- HeadsUpDisplay on.
    local speedometer = nil
    local function showSpeed(seat)
    \tif seat == nil or not seat.HeadsUpDisplay then
    \t\tif speedometer ~= nil and speedometer.Parent.Enabled then
    \t\t\tspeedometer.Parent.Enabled = false
    \t\tend
    \t\treturn
    \tend
    \tif speedometer == nil then
    \t\tlocal screen = Instance.new("ScreenGui")
    \t\tscreen.Name = "VehicleHud"
    \t\tspeedometer = Instance.new("TextLabel")
    \t\tspeedometer.Name = "Speed"
    \t\tspeedometer.Size = UDim2.new(0, 180, 0, 34)
    \t\tspeedometer.Position = UDim2.new(0.5, -90, 1, -120)
    \t\tspeedometer.BackgroundColor3 = Color3.new(0, 0, 0)
    \t\tspeedometer.BackgroundTransparency = 0.45
    \t\tspeedometer.TextColor3 = Color3.new(1, 1, 1)
    \t\tspeedometer.TextSize = 20
    \t\tspeedometer.Parent = screen
    \t\tscreen.Parent = player.PlayerGui
    \tend
    \tspeedometer.Parent.Enabled = true
    \tlocal text = string.format("%d studs/s", math.round(seat.AssemblyLinearVelocity.Magnitude))
    \tif speedometer.Text ~= text then
    \t\tspeedometer.Text = text
    \tend
    end

    -- Every frame, WASD becomes a direction relative to the camera.
    RunService.RenderStepped:Connect(function()
    \tlocal humanoid = currentHumanoid()
    \tif humanoid == nil then
    \t\tshowSpeed(nil)
    \t\treturn
    \tend
    \tlocal forward = held(Enum.KeyCode.W) - held(Enum.KeyCode.S)
    \tlocal right = held(Enum.KeyCode.D) - held(Enum.KeyCode.A)

    \t-- In a VehicleSeat the keys drive it (its Throttle and Steer), and Space gets out.
    \tlocal seat = humanoid.SeatPart
    \tlocal driving = seat ~= nil and seat:IsA("VehicleSeat")
    \tshowSpeed(if driving then seat else nil)
    \tif driving then
    \t\tif seat.ThrottleFloat ~= forward then
    \t\t\tseat.ThrottleFloat = forward
    \t\tend
    \t\tif seat.SteerFloat ~= right then
    \t\t\tseat.SteerFloat = right
    \t\tend
    \t\tif UserInputService:IsKeyDown(Enum.KeyCode.Space) then
    \t\t\thumanoid.Jump = true
    \t\tend
    \t\treturn
    \tend

    \tif humanoid:GetState() == Enum.HumanoidStateType.Flying then
    \t\tlocal up = held(Enum.KeyCode.Space) - held(Enum.KeyCode.C)
    \t\thumanoid:Move(Vector3.new(right, up, -forward), true)
    \telse
    \t\thumanoid:Move(Vector3.new(right, 0, -forward), true)
    \t\t-- Holding Space keeps jumping, as in Roblox.
    \t\tif UserInputService:IsKeyDown(Enum.KeyCode.Space) then
    \t\t\thumanoid.Jump = true
    \t\tend
    \tend
    end)

    -- Shift sprints by raising WalkSpeed while held, then putting it back.
    local sprintingHumanoid = nil
    local walkSpeedBeforeSprint = nil

    UserInputService.InputBegan:Connect(function(input)
    \tlocal humanoid = currentHumanoid()
    \tif humanoid == nil then
    \t\treturn
    \tend
    \tif input.KeyCode == Enum.KeyCode.LeftShift and sprintingHumanoid == nil then
    \t\tsprintingHumanoid = humanoid
    \t\twalkSpeedBeforeSprint = humanoid.WalkSpeed
    \t\thumanoid.WalkSpeed = walkSpeedBeforeSprint * SPRINT_MULTIPLIER
    \tend
    end)

    UserInputService.InputEnded:Connect(function(input)
    \tif input.KeyCode == Enum.KeyCode.Space then
    \t\t-- Letting go drops a jump still waiting to happen. Space asks to jump on every
    \t\t-- frame it is held, the few just after take-off too, and a request left
    \t\t-- standing would jump again the moment the character landed.
    \t\tlocal humanoid = currentHumanoid()
    \t\tif humanoid ~= nil then
    \t\t\thumanoid.Jump = false
    \t\tend
    \telseif input.KeyCode == Enum.KeyCode.LeftShift and sprintingHumanoid ~= nil then
    \t\t-- Only the character that started sprinting; a respawned one starts fresh.
    \t\tif sprintingHumanoid == currentHumanoid() then
    \t\t\tsprintingHumanoid.WalkSpeed = walkSpeedBeforeSprint
    \t\tend
    \t\tsprintingHumanoid = nil
    \t\twalkSpeedBeforeSprint = nil
    \tend
    end)
    """

    static let healthScriptSource = """
    -- Health: slowly regenerates the character, as Roblox's default Health script does.
    -- Runs again for every new character. Add your own script named "Health" to
    -- StarterCharacterScripts to replace it.

    local humanoid = script.Parent:WaitForChild("Humanoid")

    local REGEN_RATE = 1 / 100 -- fraction of MaxHealth restored per second
    local REGEN_STEP = 1 -- seconds between top-ups

    while true do
    \twhile humanoid.Health < humanoid.MaxHealth do
    \t\tlocal dt = task.wait(REGEN_STEP)
    \t\tlocal gained = dt * REGEN_RATE * humanoid.MaxHealth
    \t\thumanoid.Health = math.min(humanoid.Health + gained, humanoid.MaxHealth)
    \tend
    \thumanoid.HealthChanged:Wait()
    end
    """

    static let chatScriptSource = """
    -- ChatScript: the default chat. Press / to chat.
    --
    -- It is built from ordinary GUI objects — a ScrollingFrame of TextLabels in a
    -- UIListLayout, a TextBox to type in, and BillboardGui bubbles over speakers' heads —
    -- and sends through TextChatService, so everyone in the game sees each message. There
    -- is no filter. To change how chat looks or works, select this in StarterPlayer and
    -- choose "Edit a Copy", or add your own script named "ChatScript" to
    -- StarterPlayerScripts. It replaces this one; a disabled one removes the chat.

    local Players = game:GetService("Players")
    local TextChatService = game:GetService("TextChatService")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    local channel = TextChatService.TextChannels.RBXGeneral

    local TOP = 16 -- in from the top-left corner, as the HUD's cards are from theirs
    local WIDTH = 400
    local HEIGHT = 176
    local KEPT = 100 -- messages remembered
    local BUBBLE_TIME = 8 -- seconds a bubble stays over a head

    local screen = Instance.new("ScreenGui")
    screen.Name = "Chat"
    screen.ResetOnSpawn = false

    -- The window the messages show in: they scroll, newest at the bottom.
    local window = Instance.new("Frame")
    window.Name = "Window"
    window.Position = UDim2.new(0, 16, 0, TOP)
    window.Size = UDim2.new(0, WIDTH, 0, HEIGHT)
    window.BackgroundColor3 = Color3.new(0, 0, 0)
    window.BackgroundTransparency = 0.6
    window.Parent = screen
    Instance.new("UICorner").Parent = window
    local windowPadding = Instance.new("UIPadding")
    windowPadding.PaddingLeft = UDim.new(0, 10)
    windowPadding.PaddingRight = UDim.new(0, 4)
    windowPadding.PaddingTop = UDim.new(0, 6)
    windowPadding.PaddingBottom = UDim.new(0, 6)
    windowPadding.Parent = window

    local log = Instance.new("ScrollingFrame")
    log.Name = "Log"
    log.Size = UDim2.fromScale(1, 1)
    log.BackgroundTransparency = 1
    log.CanvasSize = UDim2.new(0, 0, 0, 0)
    log.AutomaticCanvasSize = Enum.AutomaticSize.Y
    log.ScrollBarThickness = 6
    log.Parent = window
    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 2)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = log

    -- The chat bar. Click it, or press /, to type; Return sends, Escape gives up.
    local box = Instance.new("TextBox")
    box.Name = "ChatBar"
    box.Position = UDim2.new(0, 16, 0, TOP + HEIGHT + 8)
    box.Size = UDim2.new(0, WIDTH, 0, 32)
    box.BackgroundColor3 = Color3.new(0, 0, 0)
    box.BackgroundTransparency = 0.4
    box.Text = ""
    box.PlaceholderText = "Press / to chat"
    box.ClearTextOnFocus = true
    box.TextColor3 = Color3.new(1, 1, 1)
    box.TextSize = 15
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.Parent = screen
    Instance.new("UICorner").Parent = box
    local boxPadding = Instance.new("UIPadding")
    boxPadding.PaddingLeft = UDim.new(0, 10)
    boxPadding.PaddingRight = UDim.new(0, 10)
    boxPadding.Parent = box

    screen.Parent = player.PlayerGui

    local count = 0
    local lines = {}

    local function post(text)
    \tcount += 1
    \tlocal line = Instance.new("TextLabel")
    \tline.Name = "Message"
    \tline.LayoutOrder = count
    \tline.Size = UDim2.new(1, -8, 0, 0)
    \tline.AutomaticSize = Enum.AutomaticSize.Y
    \tline.BackgroundTransparency = 1
    \tline.Text = text
    \tline.TextWrapped = true
    \tline.TextXAlignment = Enum.TextXAlignment.Left
    \tline.TextColor3 = Color3.new(1, 1, 1)
    \tline.TextStrokeTransparency = 0.7
    \tline.TextSize = 15
    \tline.Parent = log
    \ttable.insert(lines, line)
    \tif #lines > KEPT then
    \t\ttable.remove(lines, 1):Destroy()
    \tend
    \t-- The newest in view.
    \tlog.CanvasPosition = Vector2.new(0, 1e9)
    end

    -- A bubble over the speaker's head, for a while.
    local bubbles = {}
    local function bubble(name, text)
    \tif not TextChatService.BubbleChatConfiguration.Enabled then
    \t\treturn
    \tend
    \tlocal speaker
    \tfor _, other in Players:GetPlayers() do
    \t\tif other.Name == name then
    \t\t\tspeaker = other
    \t\tend
    \tend
    \tlocal character = speaker and speaker.Character
    \tlocal head = character and character:FindFirstChild("Head")
    \tif head == nil then
    \t\treturn
    \tend
    \tif bubbles[name] then
    \t\tbubbles[name]:Destroy()
    \tend
    \tlocal board = Instance.new("BillboardGui")
    \tboard.Name = "Bubble"
    \tboard.Adornee = head
    \tboard.Size = UDim2.fromOffset(240, 90)
    \tboard.StudsOffset = Vector3.new(0, 2.6, 0)
    \tlocal card = Instance.new("TextLabel")
    \tcard.Name = "Text"
    \tcard.AnchorPoint = Vector2.new(0.5, 1)
    \tcard.Position = UDim2.fromScale(0.5, 1)
    \tcard.Size = UDim2.new(1, 0, 0, 0)
    \tcard.AutomaticSize = Enum.AutomaticSize.Y
    \tcard.BackgroundColor3 = Color3.new(1, 1, 1)
    \tcard.BackgroundTransparency = 0.05
    \tcard.TextColor3 = Color3.fromRGB(30, 30, 35)
    \tcard.TextSize = 15
    \tcard.TextWrapped = true
    \tcard.Text = text
    \tInstance.new("UICorner", card)
    \tlocal cardPadding = Instance.new("UIPadding")
    \tcardPadding.PaddingLeft = UDim.new(0, 8)
    \tcardPadding.PaddingRight = UDim.new(0, 8)
    \tcardPadding.PaddingTop = UDim.new(0, 6)
    \tcardPadding.PaddingBottom = UDim.new(0, 6)
    \tcardPadding.Parent = card
    \tcard.Parent = board
    \tboard.Parent = player.PlayerGui
    \tbubbles[name] = board
    \ttask.delay(BUBBLE_TIME, function()
    \t\tif bubbles[name] == board then
    \t\t\tboard:Destroy()
    \t\t\tbubbles[name] = nil
    \t\tend
    \tend)
    end

    -- Every message, this player's own included.
    TextChatService.MessageReceived:Connect(function(message)
    \tpost(message.TextSource.Name .. ": " .. message.Text)
    \tbubble(message.TextSource.Name, message.Text)
    end)

    Players.PlayerAdded:Connect(function(other)
    \tpost(other.Name .. " joined the game")
    end)

    Players.PlayerRemoving:Connect(function(other)
    \tpost(other.Name .. " left the game")
    end)

    UserInputService.InputBegan:Connect(function(input)
    \tif input.KeyCode == Enum.KeyCode.Slash and not box:IsFocused() then
    \t\tbox:CaptureFocus()
    \tend
    end)

    box.FocusLost:Connect(function(enterPressed)
    \tif enterPressed and box.Text ~= "" then
    \t\tchannel:SendAsync(box.Text)
    \tend
    \tbox.Text = ""
    end)
    """

    static let backpackScriptSource = """
    -- BackpackScript: the default hotbar. The tools you have show along the bottom of
    -- the screen: press 1 to 9 (or click one) to hold it, the same again to put it
    -- away, and Backspace to drop the one in your hand, if it can be dropped.
    --
    -- Built from GUI objects, like ChatScript. Add your own script named
    -- "BackpackScript" to StarterPlayerScripts to replace it; a disabled one removes
    -- the hotbar.

    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    local backpack = player:WaitForChild("Backpack")

    local SLOT = 60 -- each slot's size, in pixels
    local GAP = 6
    local KEYS = { One = 1, Two = 2, Three = 3, Four = 4, Five = 5, Six = 6, Seven = 7, Eight = 8, Nine = 9 }
    local IDLE = Color3.fromRGB(30, 34, 42)
    local HELD = Color3.fromRGB(60, 120, 220)

    local screen = Instance.new("ScreenGui")
    screen.Name = "Backpack"
    screen.ResetOnSpawn = false
    local bar = Instance.new("Frame")
    bar.Name = "Hotbar"
    bar.AnchorPoint = Vector2.new(0.5, 1)
    bar.Position = UDim2.new(0.5, 0, 1, -64) -- just above the health bar
    bar.BackgroundTransparency = 1
    bar.Visible = false
    bar.Parent = screen
    screen.Parent = player.PlayerGui

    local order = {} -- each tool keeps the slot it arrived in
    local slots = {}

    local function held()
    \tlocal character = player.Character
    \treturn character and character:FindFirstChildOfClass("Tool")
    end

    local function toggle(index)
    \tlocal tool = order[index]
    \tlocal character = player.Character
    \tlocal humanoid = character and character:FindFirstChild("Humanoid")
    \tif tool == nil or humanoid == nil then
    \t\treturn
    \tend
    \tif held() == tool then
    \t\thumanoid:UnequipTools()
    \telse
    \t\thumanoid:EquipTool(tool)
    \tend
    end

    local function slot(index)
    \tlocal button = slots[index]
    \tif button == nil then
    \t\tbutton = Instance.new("TextButton")
    \t\tbutton.Name = "Slot" .. index
    \t\tbutton.Size = UDim2.fromOffset(SLOT, SLOT)
    \t\tbutton.BackgroundTransparency = 0.15
    \t\tbutton.TextColor3 = Color3.new(1, 1, 1)
    \t\tbutton.TextSize = 12
    \t\tbutton.TextWrapped = true
    \t\tInstance.new("UICorner", button)
    \t\tlocal number = Instance.new("TextLabel")
    \t\tnumber.Name = "Number"
    \t\tnumber.Position = UDim2.fromOffset(5, 3)
    \t\tnumber.Size = UDim2.fromOffset(14, 14)
    \t\tnumber.BackgroundTransparency = 1
    \t\tnumber.Text = tostring(index)
    \t\tnumber.TextSize = 11
    \t\tnumber.TextColor3 = Color3.fromRGB(190, 200, 215)
    \t\tnumber.TextXAlignment = Enum.TextXAlignment.Left
    \t\tnumber.Parent = button
    \t\tbutton.MouseButton1Click:Connect(function()
    \t\t\ttoggle(index)
    \t\tend)
    \t\tbutton.Parent = bar
    \t\tslots[index] = button
    \tend
    \treturn button
    end

    local function refresh()
    \tlocal now = backpack:GetChildren()
    \tlocal inHand = held()
    \tif inHand ~= nil then
    \t\ttable.insert(now, inHand)
    \tend
    \tlocal present = {}
    \tfor _, tool in now do
    \t\tpresent[tool] = true
    \tend
    \tfor index = #order, 1, -1 do
    \t\tif not present[order[index]] then
    \t\t\ttable.remove(order, index)
    \t\tend
    \tend
    \tfor _, tool in now do
    \t\tif #order < 9 and not table.find(order, tool) then
    \t\t\ttable.insert(order, tool)
    \t\tend
    \tend
    \tfor index = 1, math.max(#order, #slots) do
    \t\tlocal tool = order[index]
    \t\tlocal button = slot(index)
    \t\tbutton.Visible = tool ~= nil
    \t\tif tool ~= nil then
    \t\t\tbutton.Position = UDim2.fromOffset((index - 1) * (SLOT + GAP), 0)
    \t\t\tbutton.Text = tool.Name
    \t\t\tbutton.BackgroundColor3 = if tool == inHand then HELD else IDLE
    \t\tend
    \tend
    \tbar.Size = UDim2.fromOffset(math.max(#order * (SLOT + GAP) - GAP, 0), SLOT)
    \tbar.Visible = #order > 0
    end

    UserInputService.InputBegan:Connect(function(input)
    \tlocal index = KEYS[input.KeyCode.Name]
    \tif index ~= nil then
    \t\ttoggle(index)
    \telseif input.KeyCode == Enum.KeyCode.Backspace then
    \t\tlocal tool = held()
    \t\tif tool ~= nil and tool.CanBeDropped then
    \t\t\ttool.Parent = workspace
    \t\tend
    \tend
    end)

    while true do
    \trefresh()
    \ttask.wait(0.1)
    end
    """
}
