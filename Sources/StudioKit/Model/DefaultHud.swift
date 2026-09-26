import Foundation

/// The heads-up display a new scene starts with: an ordinary ScreenGui in StarterGui,
/// "PlayerHud" — the health bar, the respawn countdown, a few numbers about the
/// character, the controls, a crosshair in first person and a script output window —
/// with the LocalScripts that drive it and the Studio keys (F flies, R respawns). None
/// of it is built into the app: move it, restyle it in the GUI tab, edit its scripts or
/// delete it, and a game has exactly the screen it was made with.
enum DefaultHud {
    /// Scenes remember which HUD they were offered, so one saved before it existed gets
    /// it on opening — and one whose maker deleted it doesn't get it back.
    /// 1: PlayerHud. 2: the PlayerList (leaderboard) as well.
    static let version = 2
    static let screenName = "PlayerHud"
    static let listName = "PlayerList"
    static let listScriptName = "LeaderboardScript"
    static let hudScriptName = "HudScript"
    static let keysScriptName = "FlyAndRespawn"

    /// A fresh copy — new ids every time — of the objects and the LocalScripts inside.
    /// `keys` leaves out FlyAndRespawn (a scene with its own ControlScript may already
    /// handle F and R).
    static func make(keys: Bool = true) -> (objects: [StarterGuiObject], scripts: [ScriptObject]) {
        var objects: [StarterGuiObject] = []
        @discardableResult
        func add(_ kind: GuiObject.Kind, _ name: String, in parent: UUID?,
                 _ properties: [String: ScriptValue] = [:]) -> UUID {
            var object = StarterGuiObject(kind: kind, name: name, parentID: parent)
            object.properties = properties
            objects.append(object)
            return object.id
        }
        func udim2(_ xs: Double, _ xo: Double, _ ys: Double, _ yo: Double) -> ScriptValue {
            .list([.number(xs), .number(xo), .number(ys), .number(yo)])
        }
        func pair(_ a: Double, _ b: Double) -> ScriptValue { .list([.number(a), .number(b)]) }
        func card(_ id: UUID) {
            add(.uiCorner, "UICorner", in: id, ["cornerradius": pair(0, 8)])
            add(.uiStroke, "UIStroke", in: id, ["color": .triple(1, 1, 1), "transparency": .number(0.9)])
        }
        let dark: [String: ScriptValue] = ["backgroundcolor3": .triple(0, 0, 0), "backgroundtransparency": .number(0.5)]
        func label(_ name: String, in parent: UUID, text: String, size: Double = 11, font: String = "RobotoMono",
                   colour: ScriptValue = .triple(0.92, 0.92, 0.92), align: String = "Left", order: Int = 0,
                   extra: [String: ScriptValue] = [:]) {
            var properties: [String: ScriptValue] = [
                "text": .string(text), "textsize": .number(size), "font": .string(font), "textcolor3": colour,
                "textxalignment": .string(align), "backgroundtransparency": .number(1),
                "size": udim2(1, 0, 0, size + 4), "layoutorder": .number(Double(order)),
            ]
            properties.merge(extra) { _, new in new }
            add(.textLabel, name, in: parent, properties)
        }

        let screen = add(.screenGui, screenName, in: nil, ["resetonspawn": .bool(false)])

        // Health, along the bottom: a heart, a bar and the number.
        let health = add(.frame, "Health", in: screen, dark.merging([
            "anchorpoint": pair(0.5, 1), "position": udim2(0.5, 0, 1, -16), "size": udim2(0, 214, 0, 26),
        ]) { _, new in new })
        card(health)
        label("Heart", in: health, text: "♥", size: 14, font: "SourceSans", colour: .triple(0.36, 0.8, 0.4),
              align: "Center", extra: ["position": udim2(0, 6, 0, 0), "size": udim2(0, 18, 1, 0)])
        let bar = add(.frame, "Bar", in: health, [
            "anchorpoint": pair(0, 0.5), "position": udim2(0, 28, 0.5, 0), "size": udim2(0, 150, 0, 7),
            "backgroundcolor3": .triple(1, 1, 1), "backgroundtransparency": .number(0.85),
        ])
        add(.uiCorner, "UICorner", in: bar, ["cornerradius": pair(0.5, 0)])
        let fill = add(.frame, "Fill", in: bar, ["size": udim2(1, 0, 1, 0), "backgroundcolor3": .triple(0.36, 0.8, 0.4)])
        add(.uiCorner, "UICorner", in: fill, ["cornerradius": pair(0.5, 0)])
        label("Amount", in: health, text: "100", colour: .triple(1, 1, 1),
              extra: ["position": udim2(0, 184, 0, 0), "size": udim2(0, 28, 1, 0), "texttransparency": .number(0.25)])

        // Shown while the character waits to come back.
        let respawning = add(.textLabel, "Respawning", in: screen, dark.merging([
            "anchorpoint": pair(0.5, 1), "position": udim2(0.5, 0, 1, -50), "size": udim2(0, 180, 0, 28),
            "text": .string("Respawning in 5…"), "textsize": .number(14), "font": .string("SourceSansBold"),
            "textcolor3": .triple(1, 1, 1), "visible": .bool(false),
        ]) { _, new in new })
        card(respawning)

        // A few numbers, top right.
        let stats = add(.frame, "Stats", in: screen, dark.merging([
            "anchorpoint": pair(1, 0), "position": udim2(1, -14, 0, 14), "size": udim2(0, 210, 0, 0),
            "automaticsize": .string("Y"),
        ]) { _, new in new })
        card(stats)
        add(.uiPadding, "UIPadding", in: stats, ["paddingleft": pair(0, 10), "paddingright": pair(0, 10),
                                                 "paddingtop": pair(0, 7), "paddingbottom": pair(0, 7)])
        add(.uiListLayout, "UIListLayout", in: stats, ["padding": pair(0, 1), "horizontalalignment": .string("Right")])
        // Not "Position": stats.Position is the frame's own Position, as in Roblox.
        for (order, (name, text)) in [("Coordinates", "pos  0.0, 0.0, 0.0"), ("Speed", "speed  0.0 studs/s"),
                                      ("State", "state  Running"), ("Fps", "fps  60")].enumerated() {
            label(name, in: stats, text: text, align: "Right", order: order)
        }
        label("Errors", in: stats, text: "0 errors · ` to view", colour: .triple(0.95, 0.45, 0.42), align: "Right",
              order: 9, extra: ["visible": .bool(false)])

        // The controls, bottom left; H hides them.
        let controls = add(.frame, "Controls", in: screen, dark.merging([
            "anchorpoint": pair(0, 1), "position": udim2(0, 14, 1, -14), "size": udim2(0, 232, 0, 0),
            "automaticsize": .string("Y"),
        ]) { _, new in new })
        card(controls)
        add(.uiPadding, "UIPadding", in: controls, ["paddingleft": pair(0, 10), "paddingright": pair(0, 10),
                                                    "paddingtop": pair(0, 7), "paddingbottom": pair(0, 7)])
        add(.uiListLayout, "UIListLayout", in: controls, ["padding": pair(0, 1)])
        let help = [("W A S D", "move"), ("Space", "jump"), ("Shift", "sprint"), ("Ctrl", "shift lock"), ("right-drag", "look"),
                    ("scroll", "zoom, first person"), ("Esc", "free the mouse"), ("F", "fly"), ("R", "respawn"),
                    ("/", "chat"), ("`", "script output"), ("H", "hide this")]
        for (order, (key, what)) in help.enumerated() {
            label("Line\(order + 1)", in: controls, text: key.padding(toLength: 11, withPad: " ", startingAt: 0) + what,
                  order: order)
        }

        // Where the pointer is, in first person.
        let crosshair = add(.frame, "Crosshair", in: screen, [
            "anchorpoint": pair(0.5, 0.5), "position": udim2(0.5, 0, 0.5, 0), "size": udim2(0, 6, 0, 6),
            "backgroundcolor3": .triple(1, 1, 1), "backgroundtransparency": .number(0.2), "visible": .bool(false),
        ])
        add(.uiCorner, "UICorner", in: crosshair, ["cornerradius": pair(0.5, 0)])
        add(.uiStroke, "UIStroke", in: crosshair, ["color": .triple(0, 0, 0), "thickness": .number(1.5),
                                                   "transparency": .number(0.5)])

        // What scripts print; ` shows it.
        let output = add(.frame, "Output", in: screen, dark.merging([
            "anchorpoint": pair(1, 1), "position": udim2(1, -14, 1, -14), "size": udim2(0, 440, 0, 230),
            "visible": .bool(false),
        ]) { _, new in new })
        card(output)
        add(.uiPadding, "UIPadding", in: output, ["paddingleft": pair(0, 10), "paddingright": pair(0, 6),
                                                  "paddingtop": pair(0, 7), "paddingbottom": pair(0, 7)])
        label("Title", in: output, text: "SCRIPT OUTPUT   ` hides", size: 10, font: "SourceSansBold",
              colour: .triple(0.6, 0.6, 0.6))
        let lines = add(.scrollingFrame, "Lines", in: output, [
            "position": udim2(0, 0, 0, 18), "size": udim2(1, 0, 1, -18), "backgroundtransparency": .number(1),
            "canvassize": udim2(0, 0, 0, 0), "automaticcanvassize": .string("Y"), "scrollbarthickness": .number(4),
        ])
        add(.uiListLayout, "UIListLayout", in: lines, ["padding": pair(0, 1)])

        var scripts = [script(hudScriptName, hudSource, in: screen)]
        if keys { scripts.append(script(keysScriptName, keysSource, in: screen)) }
        let list = makeLeaderboard()
        return (objects + list.objects, scripts + list.scripts)
    }

    /// The leaderboard: a ScreenGui of its own, top right, which its LocalScript fills
    /// from each player's leaderstats — and shows only when someone has some.
    static func makeLeaderboard() -> (objects: [StarterGuiObject], scripts: [ScriptObject]) {
        func udim2(_ xs: Double, _ xo: Double, _ ys: Double, _ yo: Double) -> ScriptValue {
            .list([.number(xs), .number(xo), .number(ys), .number(yo)])
        }
        func pair(_ a: Double, _ b: Double) -> ScriptValue { .list([.number(a), .number(b)]) }
        var screen = StarterGuiObject(kind: .screenGui, name: listName, parentID: nil)
        screen.properties = ["resetonspawn": .bool(false)]
        var board = StarterGuiObject(kind: .frame, name: "Board", parentID: screen.id)
        board.properties = [
            "anchorpoint": pair(1, 0), "position": udim2(1, -14, 0, 14), "size": udim2(0, 0, 0, 0),
            "automaticsize": .string("XY"), "backgroundcolor3": .triple(0, 0, 0),
            "backgroundtransparency": .number(0.5), "visible": .bool(false),
        ]
        var corner = StarterGuiObject(kind: .uiCorner, name: "UICorner", parentID: board.id)
        corner.properties = ["cornerradius": pair(0, 8)]
        var stroke = StarterGuiObject(kind: .uiStroke, name: "UIStroke", parentID: board.id)
        stroke.properties = ["color": .triple(1, 1, 1), "transparency": .number(0.9)]
        var padding = StarterGuiObject(kind: .uiPadding, name: "UIPadding", parentID: board.id)
        padding.properties = ["paddingleft": pair(0, 10), "paddingright": pair(0, 10),
                              "paddingtop": pair(0, 7), "paddingbottom": pair(0, 7)]
        var layout = StarterGuiObject(kind: .uiListLayout, name: "UIListLayout", parentID: board.id)
        layout.properties = ["padding": pair(0, 2)]
        return ([screen, board, corner, stroke, padding, layout], [script(listScriptName, leaderboardSource, in: screen.id)])
    }

    private static func script(_ name: String, _ source: String, in parent: UUID) -> ScriptObject {
        var script = ScriptObject.blank(language: .luau)
        script.name = name
        script.host = .starterGui
        script.parentID = parent
        script.source = source
        return script
    }

    static let hudSource = """
    -- HudScript: the default heads-up display — health, the respawn countdown, a few
    -- numbers about the character, the controls (H hides them), a crosshair in first
    -- person, and script output (` shows it). It is all ordinary GUI objects in
    -- StarterGui > PlayerHud: move them, restyle them in the GUI tab, change this
    -- script, or delete whatever the game doesn't want.

    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local LogService = game:GetService("LogService")

    local player = Players.LocalPlayer
    local hud = script.Parent

    local GREEN = Color3.fromRGB(92, 204, 102)
    local AMBER = Color3.fromRGB(242, 191, 77)
    local RED = Color3.fromRGB(235, 87, 77)

    -- Health, and the countdown after dying.
    local deathAt = nil

    local function showHealth(humanoid)
    \tlocal health = hud:FindFirstChild("Health")
    \tif health == nil then
    \t\treturn
    \tend
    \tlocal fraction = if humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
    \tlocal colour = if fraction > 0.5 then GREEN elseif fraction > 0.25 then AMBER else RED
    \thealth.Bar.Fill.Size = UDim2.fromScale(fraction, 1)
    \thealth.Bar.Fill.BackgroundColor3 = colour
    \thealth.Heart.TextColor3 = colour
    \thealth.Amount.Text = tostring(math.ceil(humanoid.Health))
    end

    local function follow(character)
    \tdeathAt = nil
    \tif hud:FindFirstChild("Respawning") then
    \t\thud.Respawning.Visible = false
    \tend
    \tlocal humanoid = character:WaitForChild("Humanoid")
    \tshowHealth(humanoid)
    \thumanoid.HealthChanged:Connect(function()
    \t\tshowHealth(humanoid)
    \tend)
    \thumanoid.Died:Connect(function()
    \t\tdeathAt = time()
    \tend)
    end

    if player.Character then
    \tfollow(player.Character)
    end
    player.CharacterAdded:Connect(follow)

    -- Each frame: the countdown and the crosshair; the numbers a few times a second.
    local frames, elapsed = 0, 0

    RunService.Heartbeat:Connect(function(dt)
    \tlocal respawning = hud:FindFirstChild("Respawning")
    \tif respawning and deathAt then
    \t\tlocal left = Players.RespawnTime - (time() - deathAt)
    \t\trespawning.Visible = left > 0
    \t\trespawning.Text = string.format("Respawning in %d…", math.ceil(math.max(left, 0)))
    \tend
    \tlocal crosshair = hud:FindFirstChild("Crosshair")
    \tif crosshair then
    \t\t-- In first person the pointer is held in the middle of the screen.
    \t\tcrosshair.Visible = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
    \tend

    \tframes += 1
    \telapsed += dt
    \tlocal stats = hud:FindFirstChild("Stats")
    \tif elapsed < 0.25 or stats == nil then
    \t\treturn
    \tend
    \tlocal character = player.Character
    \tlocal root = character and character:FindFirstChild("HumanoidRootPart")
    \tlocal humanoid = character and character:FindFirstChild("Humanoid")
    \tif root then
    \t\tlocal at = root.Position
    \t\tlocal velocity = root.AssemblyLinearVelocity
    \t\tstats.Coordinates.Text = string.format("pos  %.1f, %.1f, %.1f", at.X, at.Y, at.Z)
    \t\tstats.Speed.Text = string.format("speed  %.1f studs/s", Vector3.new(velocity.X, 0, velocity.Z).Magnitude)
    \tend
    \tif humanoid then
    \t\tstats.State.Text = "state  " .. humanoid:GetState().Name
    \tend
    \tstats.Fps.Text = string.format("fps  %d", math.floor(frames / elapsed + 0.5))
    \tframes, elapsed = 0, 0
    end)

    -- Script output: what's printed, warned and errored, newest at the bottom.
    local KEEP = 60
    local COLOURS = {
    \tMessageOutput = Color3.fromRGB(235, 235, 235),
    \tMessageInfo = Color3.fromRGB(150, 150, 150),
    \tMessageWarning = AMBER,
    \tMessageError = RED,
    }
    local shown = {}
    local errors = 0

    local function addLine(message, messageType)
    \tlocal output = hud:FindFirstChild("Output")
    \tif output == nil then
    \t\treturn
    \tend
    \tlocal line = Instance.new("TextLabel")
    \tline.Name = "Line"
    \tline.BackgroundTransparency = 1
    \tline.Size = UDim2.new(1, -8, 0, 0)
    \tline.AutomaticSize = Enum.AutomaticSize.Y
    \tline.TextWrapped = true
    \tline.TextXAlignment = Enum.TextXAlignment.Left
    \tline.Font = Enum.Font.RobotoMono
    \tline.TextSize = 11
    \tline.TextColor3 = COLOURS[messageType.Name] or COLOURS.MessageOutput
    \tline.Text = message
    \ttable.insert(shown, line)
    \tline.LayoutOrder = #shown
    \tline.Parent = output.Lines
    \tif #shown > KEEP then
    \t\ttable.remove(shown, 1):Destroy()
    \t\tfor order, kept in shown do
    \t\t\tkept.LayoutOrder = order
    \t\tend
    \tend
    \toutput.Lines.CanvasPosition = Vector2.new(0, 1000000)
    \tif messageType == Enum.MessageType.MessageError then
    \t\terrors += 1
    \t\tlocal stats = hud:FindFirstChild("Stats")
    \t\tif stats and stats:FindFirstChild("Errors") then
    \t\t\tstats.Errors.Visible = true
    \t\t\tstats.Errors.Text = string.format("%d error%s · ` to view", errors, if errors == 1 then "" else "s")
    \t\tend
    \tend
    end

    for _, entry in LogService:GetLogHistory() do
    \taddLine(entry.message, entry.messageType)
    end
    LogService.MessageOut:Connect(addLine)

    UserInputService.InputBegan:Connect(function(input)
    \tif input.KeyCode == Enum.KeyCode.Backquote and hud:FindFirstChild("Output") then
    \t\thud.Output.Visible = not hud.Output.Visible
    \telseif input.KeyCode == Enum.KeyCode.H and hud:FindFirstChild("Controls") then
    \t\thud.Controls.Visible = not hud.Controls.Visible
    \tend
    end)
    """

    static let leaderboardSource = """
    -- LeaderboardScript: the player list, top right, for a game that gives players
    -- leaderstats — a Folder called "leaderstats" in each Player, holding IntValues,
    -- NumberValues, StringValues or BoolValues, one column each. Players are sorted by
    -- the first column, this player's row picked out. Tab hides it. It's ordinary GUI
    -- in StarterGui > PlayerList: restyle it, change this script, or delete it.

    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    local board = script.Parent:WaitForChild("Board")

    local NAME_WIDTH = 14
    local COLUMN_WIDTH = 9
    local hidden = false
    local lines = {}

    local function statsOf(someone)
    	local values = {}
    	local folder = someone:FindFirstChild("leaderstats")
    	if folder then
    		for _, value in folder:GetChildren() do
    			if value:IsA("ValueBase") then
    				values[value.Name] = value.Value
    			end
    		end
    	end
    	return values, folder ~= nil
    end

    local function cell(text, width)
    	text = string.sub(tostring(text), 1, width - 1)
    	return text .. string.rep(" ", width - #text)
    end

    local function shown(value)
    	if type(value) == "number" then
    		return if value == math.floor(value) then string.format("%d", value) else string.format("%.1f", value)
    	end
    	return tostring(value)
    end

    local function line(index)
    	local label = lines[index]
    	if label == nil then
    		label = Instance.new("TextLabel")
    		label.Name = "Line" .. index
    		label.BackgroundTransparency = 1
    		label.Size = UDim2.new(0, 0, 0, 15)
    		label.AutomaticSize = Enum.AutomaticSize.X
    		label.Font = Enum.Font.RobotoMono
    		label.TextSize = 12
    		label.TextXAlignment = Enum.TextXAlignment.Left
    		label.LayoutOrder = index
    		label.Parent = board
    		lines[index] = label
    	end
    	return label
    end

    -- The HUD's numbers sit top right too: while the list shows, they go below it.
    local function makeRoomFor(rows)
    	local hud = player.PlayerGui:FindFirstChild("PlayerHud")
    	local stats = hud and hud:FindFirstChild("Stats")
    	if stats then
    		stats.Position = UDim2.new(1, -14, 0, if rows > 0 then 14 + rows * 17 + 26 else 14)
    	end
    end

    local function refresh()
    	local columns, rows = {}, {}
    	for _, someone in Players:GetPlayers() do
    		local values, has = statsOf(someone)
    		if has then
    			table.insert(rows, { player = someone, values = values })
    			local folder = someone:FindFirstChild("leaderstats")
    			for _, value in folder:GetChildren() do
    				if value:IsA("ValueBase") and not table.find(columns, value.Name) then
    					table.insert(columns, value.Name)
    				end
    			end
    		end
    	end
    	local showing = #rows > 0 and not hidden
    	board.Visible = showing
    	makeRoomFor(if showing then #rows + 1 else 0)
    	if not showing then
    		return
    	end
    	local first = columns[1]
    	table.sort(rows, function(a, b)
    		local x, y = a.values[first], b.values[first]
    		if type(x) == "number" and type(y) == "number" and x ~= y then
    			return x > y
    		end
    		return a.player.Name < b.player.Name
    	end)
    	local header = cell("Player", NAME_WIDTH)
    	for _, column in columns do
    		header ..= cell(column, COLUMN_WIDTH)
    	end
    	local top = line(1)
    	top.Text = header
    	top.TextColor3 = Color3.fromRGB(150, 150, 150)
    	for index, row in rows do
    		local text = cell(row.player.Name, NAME_WIDTH)
    		for _, column in columns do
    			text ..= cell(if row.values[column] ~= nil then shown(row.values[column]) else "-", COLUMN_WIDTH)
    		end
    		local label = line(index + 1)
    		label.Visible = true
    		label.Text = text
    		label.TextColor3 = if row.player == player then Color3.fromRGB(255, 214, 102) else Color3.fromRGB(235, 235, 235)
    	end
    	for index = #rows + 2, #lines do
    		lines[index].Visible = false
    	end
    end

    local elapsed = 1
    RunService.Heartbeat:Connect(function(dt)
    	elapsed += dt
    	if elapsed >= 0.2 then
    		elapsed = 0
    		refresh()
    	end
    end)

    UserInputService.InputBegan:Connect(function(input)
    	if input.KeyCode == Enum.KeyCode.Tab then
    		hidden = not hidden
    		refresh()
    	end
    end)
    """

    static let keysSource = """
    -- FlyAndRespawn: two Studio conveniences for trying out a build. F flies (the
    -- ControlScript steers: W A S D, Space up, C down) and F again lands; R respawns.
    -- They are only this script: delete it, or a line, and the game doesn't have them.

    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer

    UserInputService.InputBegan:Connect(function(input)
    \tlocal character = player.Character
    \tlocal humanoid = character and character:FindFirstChild("Humanoid")
    \tif humanoid == nil then
    \t\treturn
    \tend
    \tif input.KeyCode == Enum.KeyCode.F then
    \t\tif humanoid:GetState() == Enum.HumanoidStateType.Flying then
    \t\t\thumanoid:ChangeState(Enum.HumanoidStateType.Running)
    \t\telse
    \t\t\thumanoid:ChangeState(Enum.HumanoidStateType.Flying)
    \t\tend
    \telseif input.KeyCode == Enum.KeyCode.R then
    \t\tplayer:LoadCharacter()
    \tend
    end)
    """
}

extension DefaultHud {
    /// Changes the controls panel's line for a key (as it's listed: "F", "R"), for a game
    /// with keys of its own — by the key, since the lines are numbered by position.
    static func relabel(_ objects: inout [StarterGuiObject], key: String, to text: String) {
        let prefix = key.padding(toLength: 11, withPad: " ", startingAt: 0)
        for index in objects.indices where objects[index].name.hasPrefix("Line") {
            if case .string(let current)? = objects[index].properties["text"], current.hasPrefix(prefix) {
                objects[index].properties["text"] = .string(text)
                return
            }
        }
    }
}

extension SceneModel {
    /// Adds the default HUD to StarterGui — a new copy even if one is there. With undo.
    @discardableResult
    func addDefaultHud() -> UUID? {
        let made = DefaultHud.make(keys: !Self.handlesStudioKeys(scripts))
        commit("Added the default HUD") {
            starterGui += made.objects
            scripts += made.scripts
            defaultGui = DefaultHud.version
            selectedGui = made.objects.first?.id
        }
        return made.objects.first?.id
    }

    /// Whether a scene's own scripts already turn F and R into flying and respawning —
    /// a ControlScript edited from the old default did — so the HUD's keys would undo them.
    static func handlesStudioKeys(_ scripts: [ScriptObject]) -> Bool {
        scripts.contains { $0.host == .starterPlayer && $0.name == CoreScripts.controlScript.name
            && $0.source.contains("Enum.KeyCode.F") }
    }
}

extension SceneState {
    /// A scene from before the default HUD, given it; one from before the leaderboard
    /// that still has the HUD, given that. Nothing else changes, and a HUD its maker
    /// deleted stays deleted.
    func upgradedToDefaultHud() -> SceneState {
        guard defaultGui < DefaultHud.version else { return self }
        var state = self
        if defaultGui == 0 {
            let made = DefaultHud.make(keys: !SceneModel.handlesStudioKeys(scripts))
            state.starterGui += made.objects
            state.scripts += made.scripts
        } else if starterGui.contains(where: { $0.parentID == nil && $0.name == DefaultHud.screenName }),
                  !starterGui.contains(where: { $0.parentID == nil && $0.name == DefaultHud.listName }) {
            let list = DefaultHud.makeLeaderboard()
            state.starterGui += list.objects
            state.scripts += list.scripts
        }
        state.defaultGui = DefaultHud.version
        return state
    }
}
