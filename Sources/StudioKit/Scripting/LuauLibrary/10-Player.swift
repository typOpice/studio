// The Luau library, part 10 of 15: the player, the character, the Humanoid and input.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let player = #"""
--------------------------------------------------------------------------------
-- The player and its character
--
-- A character is addressed by its generation, which the host bumps for every new
-- character. Each generation gets its own Model, Humanoid, root and body parts
-- here, so an old character's objects keep answering (as a dead character) after a
-- respawn instead of quietly controlling the new one.

-- Parts' touch signals live here, by part id, for as long as the session: a part's
-- proxy can be collected and remade, and its connections must survive that.
local partSignals = {}

partSignal = function(id, name)
	local signals = partSignals[id]
	if signals == nil then
		signals = { Touched = makeSignal(), TouchEnded = makeSignal() }
		partSignals[id] = signals
	end
	return signals[name]
end

local characters = {}
local isCharacterModel = setmetatable({}, { __mode = "k" })
local characterAdded = makeSignal()
local characterRemoving = makeSignal()

local function currentGeneration()
	return invoke("player.get", "generation")
end

local function expect(value, kind, property)
	local actual = typeof(value)
	local ok = if kind == "Vector3" then isVector(value)
		elseif kind == "Color3" then isColor(value)
		elseif kind == "bool" then type(value) == "boolean"
		else type(value) == kind
	if not ok then
		raise(string.format("Unable to assign property %s. %s expected, got %s", property, kind, actual), 3)
	end
end

local function instanceProxy(className, name, record, fields)
	local object = setmetatable({}, fields)
	typeTags[object] = "Instance"
	return object
end

local characterFor
-- Animation support for Humanoids and Animators; assigned with AnimationTrack below.
local loadTrack, playingTracks

-- Humanoid properties: host key, how to read, and the type a write must have.
local humanoidProperties = {
	WalkSpeed = { host = "walkspeed", kind = "number" },
	JumpPower = { host = "jumppower", kind = "number" },
	JumpHeight = { host = "jumpheight", kind = "number" },
	UseJumpPower = { host = "usejumppower", kind = "bool" },
	Health = { host = "health", kind = "number" },
	MaxHealth = { host = "maxhealth", kind = "number" },
	MaxSlopeAngle = { host = "maxslopeangle", kind = "number" },
	AutoRotate = { host = "autorotate", kind = "bool" },
	Jump = { host = "jump", kind = "bool" },
	MoveDirection = { host = "movedirection", read = toVector, readOnly = true },
	Sit = { host = "sit", kind = "bool" },
	SeatPart = { host = "seatpart", read = wrapPart, readOnly = true },
}

-- A Seat's own properties: who sits in it, and whether it can be sat in.
partProperties.Occupant = {
	host = "occupant",
	nullable = true,
	readOnly = true,
	read = function(number)
		local record = characterFor(number)
		return record and record.humanoid
	end,
}
partProperties.Disabled = {
	host = "seatdisabled",
	write = function(value)
		if type(value) ~= "boolean" then
			return nil, "bool expected, got " .. typeof(value)
		end
		return value
	end,
}

local humanoidSignalNames = {
	"Died", "HealthChanged", "StateChanged", "Jumping", "FreeFalling", "Running", "MoveToFinished", "Touched",
	"Seated",
}

local bodyPartNames = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }
local isBodyPart = {}
for _, name in bodyPartNames do
	isBodyPart[name] = true
end

local function makeCharacter(generation)
	local record = { generation = generation, signals = {} }
	for _, name in humanoidSignalNames do
		record.signals[name] = makeSignal()
	end
	-- Whose it is — this player's or another's in a network game — the host knows.
	local function alive()
		return invoke("character.alive", generation)
	end

	-- The Model

	local modelMethods = {}
	local model = setmetatable({}, {
		__index = function(_, key)
			if key == "Name" then
				return invoke("character.name", generation)
			elseif key == "ClassName" then
				return "Model"
			elseif key == "Parent" then
				return if alive() then workspace_ else nil
			elseif key == "Humanoid" then
				return record.humanoid
			elseif key == "HumanoidRootPart" or key == "PrimaryPart" then
				return record.root
			elseif isBodyPart[key] then
				return record.parts[key]
			end
			local method = modelMethods[key]
			if method ~= nil then
				return method
			end
			-- The tool in hand is in the character, as in Roblox.
			local held = toolKit.held(generation)
			if held ~= nil and held.Name == key then
				return held
			end
			raise(string.format("%s is not a valid member of Model \"Player\"", tostring(key)), 2)
		end,
		__newindex = function(_, key)
			raise(string.format("Unable to assign property %s of Model", tostring(key)), 2)
		end,
		__tostring = function()
			return invoke("character.name", generation)
		end,
		__metatable = LOCKED,
	})
	typeTags[model] = "Instance"
	isCharacterModel[model] = generation
	gui.bodyPartOf[model] = "c:" .. generation .. ":Head"
	record.model = model

	local function child(name)
		if name == "Humanoid" then
			return record.humanoid
		elseif name == "HumanoidRootPart" then
			return record.root
		end
		local part = record.parts[name]
		if part ~= nil then
			return part
		end
		local held = toolKit.held(generation)
		return if held ~= nil and held.Name == name then held else nil
	end

	function modelMethods.FindFirstChild(_, name)
		return child(name)
	end

	function modelMethods.WaitForChild(_, name)
		local found = child(name)
		if found == nil then
			warn(string.format("Infinite yield possible on 'Player:WaitForChild(\"%s\")'", tostring(name)))
		end
		return found
	end

	function modelMethods.GetChildren()
		local children = { record.humanoid, record.root }
		for _, name in bodyPartNames do
			table.insert(children, record.parts[name])
		end
		local held = toolKit.held(generation)
		if held ~= nil then
			table.insert(children, held)
		end
		return children
	end

	function modelMethods.FindFirstChildOfClass(_, className)
		if className == "Humanoid" then
			return record.humanoid
		elseif className == "Tool" then
			return toolKit.held(generation)
		end
		return nil
	end

	function modelMethods.IsA(_, className)
		return className == "Model" or className == "PVInstance" or className == "Instance"
	end

	function modelMethods.MoveTo(_, position)
		expect(position, "Vector3", "MoveTo")
		invoke("character.moveTo", generation, { position[1], position[2], position[3] })
	end

	-- The Humanoid

	local humanoidMethods = {}
	local humanoid = setmetatable({}, {
		__index = function(_, key)
			local property = humanoidProperties[key]
			if property ~= nil then
				local raw = invoke("humanoid.get", generation, property.host)
				if property.read ~= nil and raw ~= nil then
					return property.read(raw)
				end
				return raw
			end
			if key == "Name" or key == "ClassName" then
				return "Humanoid"
			elseif key == "Parent" then
				return model
			elseif key == "RootPart" then
				return record.root
			elseif key == "Animator" then
				return record.animator
			end
			local signal = record.signals[key]
			if signal ~= nil then
				return signal
			end
			local method = humanoidMethods[key]
			if method ~= nil then
				return method
			end
			raise(string.format("%s is not a valid member of Humanoid \"Humanoid\"", tostring(key)), 2)
		end,
		__newindex = function(_, key, value)
			local property = humanoidProperties[key]
			if property == nil then
				raise(string.format("%s is not a valid member of Humanoid \"Humanoid\"", tostring(key)), 2)
			end
			if property.readOnly then
				raise(string.format("Unable to assign property %s. Property is read only", key), 2)
			end
			expect(value, property.kind, key)
			invoke("humanoid.set", generation, property.host, value)
		end,
		__tostring = function()
			return "Humanoid"
		end,
		__metatable = LOCKED,
	})
	typeTags[humanoid] = "Instance"
	record.humanoid = humanoid

	function humanoidMethods.Move(self, direction, relativeToCamera)
		checkSelf(self, "Instance", "Move")
		expect(direction, "Vector3", "Move")
		invoke("humanoid.move", generation, { direction[1], direction[2], direction[3] }, relativeToCamera == true)
	end

	function humanoidMethods.MoveTo(self, position)
		checkSelf(self, "Instance", "MoveTo")
		expect(position, "Vector3", "MoveTo")
		invoke("humanoid.moveTo", generation, { position[1], position[2], position[3] })
	end

	function humanoidMethods.EquipTool(self, tool)
		checkSelf(self, "Instance", "EquipTool")
		local id = groupIdOf[tool]
		if id == nil or not toolKit.isTool(id) then
			raise("EquipTool expects a Tool, got " .. typeof(tool), 2)
		end
		invoke("backpack.equip", generation, id)
	end

	function humanoidMethods.UnequipTools(self)
		checkSelf(self, "Instance", "UnequipTools")
		invoke("backpack.unequip", generation)
	end

	function humanoidMethods.TakeDamage(self, amount)
		checkSelf(self, "Instance", "TakeDamage")
		expect(amount, "number", "TakeDamage")
		invoke("humanoid.damage", generation, amount)
	end

	function humanoidMethods.GetState(self)
		checkSelf(self, "Instance", "GetState")
		return Enum.HumanoidStateType[invoke("humanoid.get", generation, "state")]
	end

	function humanoidMethods.ChangeState(self, state)
		checkSelf(self, "Instance", "ChangeState")
		local name = enumName(state, "HumanoidStateType")
		if name == nil then
			raise("ChangeState expects an Enum.HumanoidStateType", 2)
		end
		return invoke("humanoid.state", generation, name)
	end

	-- The Animator lives inside the Humanoid, as in Roblox.
	local animatorMethods = {}
	local animator = setmetatable({}, {
		__index = function(_, key)
			if key == "Name" or key == "ClassName" then
				return "Animator"
			elseif key == "Parent" then
				return humanoid
			end
			local method = animatorMethods[key]
			if method ~= nil then
				return method
			end
			raise(string.format("%s is not a valid member of Animator \"Animator\"", tostring(key)), 2)
		end,
		__newindex = function(_, key)
			raise(string.format("Unable to assign property %s of Animator", tostring(key)), 2)
		end,
		__tostring = function()
			return "Animator"
		end,
		__metatable = LOCKED,
	})
	typeTags[animator] = "Instance"
	record.animator = animator

	function animatorMethods.LoadAnimation(self, animation)
		checkSelf(self, "Instance", "LoadAnimation")
		return loadTrack(generation, animation)
	end

	function animatorMethods.GetPlayingAnimationTracks(self)
		checkSelf(self, "Instance", "GetPlayingAnimationTracks")
		return playingTracks(generation)
	end

	function animatorMethods.IsA(_, className)
		return className == "Animator" or className == "Instance"
	end

	-- Humanoid:LoadAnimation is deprecated in Roblox but still everywhere; it goes
	-- through the Animator all the same.
	humanoidMethods.LoadAnimation = animatorMethods.LoadAnimation
	humanoidMethods.GetPlayingAnimationTracks = animatorMethods.GetPlayingAnimationTracks

	function humanoidMethods.FindFirstChild(_, name)
		return if name == "Animator" then animator else nil
	end

	function humanoidMethods.FindFirstChildOfClass(_, className)
		return if className == "Animator" then animator else nil
	end

	function humanoidMethods.WaitForChild(self, name)
		local found = humanoidMethods.FindFirstChild(self, name)
		if found == nil then
			warn(string.format("Infinite yield possible on 'Humanoid:WaitForChild(\"%s\")'", tostring(name)))
		end
		return found
	end

	function humanoidMethods.GetChildren()
		return { animator }
	end

	function humanoidMethods.IsA(_, className)
		return className == "Humanoid" or className == "Instance"
	end

	-- The HumanoidRootPart: moving it moves the character.

	local root = setmetatable({}, {
		__index = function(_, key)
			if key == "Name" then
				return "HumanoidRootPart"
			elseif key == "ClassName" then
				return "Part"
			elseif key == "Parent" then
				return model
			elseif key == "Position" then
				return toVector(invoke("root.get", generation, "position"))
			elseif key == "AssemblyLinearVelocity" or key == "Velocity" then
				return toVector(invoke("root.get", generation, "velocity"))
			elseif key == "Size" then
				return vector(2, 2, 1)
			elseif key == "Transparency" then
				return 1
			elseif key == "IsA" then
				return function(_, className)
					return className == "Part" or className == "BasePart" or className == "Instance"
				end
			end
			raise(string.format("%s is not a valid member of Part \"HumanoidRootPart\"", tostring(key)), 2)
		end,
		__newindex = function(_, key, value)
			if key == "Position" or key == "AssemblyLinearVelocity" or key == "Velocity" then
				expect(value, "Vector3", key)
				local host = if key == "Position" then "position" else "velocity"
				invoke("root.set", generation, host, { value[1], value[2], value[3] })
				return
			end
			raise(string.format("Unable to assign property %s of HumanoidRootPart", tostring(key)), 2)
		end,
		__tostring = function()
			return "HumanoidRootPart"
		end,
		__metatable = LOCKED,
	})
	typeTags[root] = "Instance"
	record.root = root

	-- The six body parts: their colour and transparency can be changed.

	record.parts = {}
	record.partTouch = {}
	for _, partName in bodyPartNames do
		local touch = { Touched = makeSignal(), TouchEnded = makeSignal() }
		record.partTouch[partName] = touch
		local part = setmetatable({}, {
			__index = function(_, key)
				local signal = touch[key]
				if signal ~= nil then
					return signal
				end
				if key == "Name" then
					return partName
				elseif key == "ClassName" then
					return "Part"
				elseif key == "Parent" then
					return model
				elseif key == "Color" then
					return toColor(invoke("body.get", generation, partName, "color"))
				elseif key == "Transparency" then
					return invoke("body.get", generation, partName, "transparency")
				elseif key == "Size" then
					return toVector(invoke("body.get", generation, partName, "size"))
				elseif key == "IsA" then
					return function(_, className)
						return className == "Part" or className == "BasePart" or className == "Instance"
					end
				end
				raise(string.format("%s is not a valid member of Part \"%s\"", tostring(key), partName), 2)
			end,
			__newindex = function(_, key, value)
				if key == "Color" then
					expect(value, "Color3", "Color")
					invoke("body.set", generation, partName, "color", { value[1], value[2], value[3] })
				elseif key == "Transparency" then
					expect(value, "number", "Transparency")
					invoke("body.set", generation, partName, "transparency", value)
				else
					raise(string.format("Unable to assign property %s of %s", tostring(key), partName), 2)
				end
			end,
			__tostring = function()
				return partName
			end,
			__metatable = LOCKED,
		})
		typeTags[part] = "Instance"
		record.parts[partName] = part
		-- A body part can be a BillboardGui's Adornee.
		gui.bodyPartOf[part] = "c:" .. generation .. ":" .. partName
	end

	return record
end

characterFor = function(generation)
	if generation == nil or generation <= 0 then
		return nil
	end
	local record = characters[generation]
	if record == nil then
		record = makeCharacter(generation)
		characters[generation] = record
	end
	return record
end

local localPlayerMethods = {}

function localPlayerMethods.LoadCharacter()
	invoke("player.load")
end

function localPlayerMethods.IsA(_, className)
	return className == "Player" or className == "Instance"
end

-- Studio extension, from before characters had a HumanoidRootPart to move.
function localPlayerMethods.Teleport(_, position)
	if not isVector(position) then
		raise("Teleport expects a Vector3, got " .. typeof(position), 2)
	end
	invoke("player.set", "position", { position[1], position[2], position[3] })
end

function localPlayerMethods.FindFirstChild(_, name)
	if name == "Backpack" then
		return toolKit.backpack(invoke("backpack.me"))
	end
	return if name == "PlayerGui" then gui.playerGui else nil
end

function localPlayerMethods.WaitForChild(_, name)
	return localPlayerMethods.FindFirstChild(nil, name)
end

local LocalPlayer = service("Player", {
	Name = function()
		return invoke("player.get", "name")
	end,
	PlayerGui = function()
		return gui.playerGui
	end,
	Backpack = function()
		return toolKit.backpack(invoke("backpack.me"))
	end,
	UserId = function()
		return 1
	end,
	Character = function()
		local record = characterFor(currentGeneration())
		return record and record.model
	end,
	CharacterAdded = function()
		return characterAdded
	end,
	CharacterRemoving = function()
		return characterRemoving
	end,
	CameraMode = function()
		return Enum.CameraMode[invoke("player.get", "cameramode")]
	end,
	CameraMinZoomDistance = function()
		return invoke("player.get", "cameraminzoomdistance")
	end,
	CameraMaxZoomDistance = function()
		return invoke("player.get", "cameramaxzoomdistance")
	end,
	-- Studio extensions: where the character's feet are, and how it is moving.
	Position = function()
		return toVector(invoke("player.get", "position"))
	end,
	Velocity = function()
		return toVector(invoke("player.get", "velocity"))
	end,
	Speed = function()
		return invoke("player.get", "speed")
	end,
	Grounded = function()
		return invoke("player.get", "grounded")
	end,
}, localPlayerMethods, function(key, value)
	if key == "CameraMode" then
		local name = enumName(value, "CameraMode")
		if name == nil then
			raise("Unable to assign property CameraMode. EnumItem expected, got " .. typeof(value), 3)
		end
		invoke("player.set", "cameramode", name)
		return true
	elseif key == "CameraMinZoomDistance" or key == "CameraMaxZoomDistance" then
		expect(value, "number", key)
		invoke("player.set", string.lower(key), value)
		return true
	end
	return false
end)

Player = LocalPlayer

-- The other players in a network game, by the number the host gave them (the host is
-- 0). Each is a Player like LocalPlayer, with a character whose Humanoid, root and body
-- parts answer from what that player last sent; changes a script makes to them are
-- sent to that player's game, which runs its own character. One table, not several
-- locals: the library's top level is close to Luau's limit of 200.
local otherPlayers = { byId = {}, added = makeSignal(), removing = makeSignal() }
-- False in Studio's Run mode, which has no player: no LocalPlayer, nobody in GetPlayers.
otherPlayers.localPresent = invoke("player.present")

function otherPlayers.get(id)
	local entry = otherPlayers.byId[id]
	if entry ~= nil then
		return entry
	end
	entry = { characterAdded = makeSignal(), characterRemoving = makeSignal() }
	entry.player = service("Player", {
		Name = function()
			return entry.leftAs or invoke("players.name", id)
		end,
		UserId = function()
			return 1000 + id
		end,
		Character = function()
			local record = characterFor(invoke("players.character", id))
			return record and record.model
		end,
		CharacterAdded = function()
			return entry.characterAdded
		end,
		CharacterRemoving = function()
			return entry.characterRemoving
		end,
		Backpack = function()
			return toolKit.backpack(id)
		end,
	}, {
		IsA = function(_, className)
			return className == "Player" or className == "Instance"
		end,
		FindFirstChild = function(_, name)
			return if name == "Backpack" then toolKit.backpack(id) else nil
		end,
		WaitForChild = function(_, name)
			return if name == "Backpack" then toolKit.backpack(id) else nil
		end,
	})
	otherPlayers.byId[id] = entry
	return entry
end

Players = service("Players", {
	LocalPlayer = function()
		return if otherPlayers.localPresent then LocalPlayer else nil
	end,
	RespawnTime = function()
		return invoke("player.get", "respawntime")
	end,
	-- Other players joining and leaving; this player is here from the start.
	PlayerAdded = function()
		return otherPlayers.added
	end,
	PlayerRemoving = function()
		return otherPlayers.removing
	end,
}, {
	GetPlayers = function()
		local list = if otherPlayers.localPresent then { LocalPlayer } else {}
		for _, id in invoke("players.list") do
			table.insert(list, otherPlayers.get(id).player)
		end
		return list
	end,
	GetPlayerFromCharacter = function(_, model)
		local generation = isCharacterModel[model]
		if generation == nil then
			return nil
		end
		local owner = invoke("character.owner", generation)
		return if owner < 0 then LocalPlayer else otherPlayers.get(owner).player
	end,
}, function(key, value)
	if key ~= "RespawnTime" then
		return false
	end
	expect(value, "number", "RespawnTime")
	invoke("player.set", "respawntime", value)
	return true
end)

-- UserInputService: the keyboard, as physical keys named by Enum.KeyCode.

local inputBegan = makeSignal()
local inputEnded = makeSignal()

local function inputObject(keyName, inputType, state)
	local object = table.freeze({
		KeyCode = Enum.KeyCode[keyName] or Enum.KeyCode.Unknown,
		UserInputType = Enum.UserInputType[inputType] or Enum.UserInputType.Keyboard,
		UserInputState = Enum.UserInputState[state],
	})
	typeTags[object] = "InputObject"
	return object
end

UserInputService = service("UserInputService", {
	InputBegan = function()
		return inputBegan
	end,
	InputEnded = function()
		return inputEnded
	end,
	MouseBehavior = function()
		return Enum.MouseBehavior[invoke("input.mousebehavior")]
	end,
}, {
	GetMouseLocation = function()
		local state = invoke("input.mouse")
		return gui.vector2(state[5], state[6])
	end,
	IsKeyDown = function(_, keyCode)
		local name = enumName(keyCode, "KeyCode")
		if name == nil then
			raise("IsKeyDown expects an Enum.KeyCode", 2)
		end
		return invoke("input.down", name)
	end,
	GetKeysPressed = function()
		local pressed = {}
		for index, name in invoke("input.keys") do
			pressed[index] = inputObject(name, "Keyboard", "Begin")
		end
		return pressed
	end,
}, function(key, value)
	if key == "MouseBehavior" then
		local name = enumName(value, "MouseBehavior")
		if name == nil then
			raise("Unable to assign property MouseBehavior. EnumItem expected, got " .. typeof(value), 3)
		end
		invoke("input.mousebehavior", name)
		return true
	end
	return false
end)

-- A body part, from the token a BillboardGui's Adornee is kept as.
function gui.bodyPartFromToken(token)
	local generation, name = string.match(token, "^c:(%-?%d+):(.+)$")
	local record = generation and characterFor(tonumber(generation))
	if record == nil then
		return nil
	end
	if name == "HumanoidRootPart" then
		return record.root
	end
	return record.parts[name]
end

-- A ClickDetector's events, by its part (part 6 has the rest; signals come from part 8).
function mouseKit.signal(partId, name)
	local byName = mouseKit.signals[partId]
	if byName == nil then
		byName = {}
		mouseKit.signals[partId] = byName
	end
	if byName[name] == nil then
		byName[name] = makeSignal()
	end
	return byName[name]
end

function mouseKit.fire(partId, name, player)
	local byName = mouseKit.signals[partId]
	if byName ~= nil and byName[name] ~= nil then
		fire(byName[name], player)
	end
end

-- Player:GetMouse(): where the mouse points in the world, and its buttons.
mouseKit.buttons = { Button1Down = makeSignal(), Button1Up = makeSignal(), Button2Down = makeSignal(),
	Button2Up = makeSignal(), Move = makeSignal() }

function mouseKit.mouse()
	if mouseKit.object ~= nil then
		return mouseKit.object
	end
	local function state()
		return invoke("input.mouse")
	end
	local members = {
		Hit = function()
			local s = state()
			return cframe(s[1], s[2], s[3], 1, 0, 0, 0, 1, 0, 0, 0, 1)
		end,
		Target = function()
			local s = state()
			return if s[4] ~= "" then wrapPart(s[4]) else nil
		end,
		X = function()
			return state()[5]
		end,
		Y = function()
			return state()[6]
		end,
		ViewSizeX = function()
			return state()[7]
		end,
		ViewSizeY = function()
			return state()[8]
		end,
		Icon = function()
			return mouseKit.icon or ""
		end,
	}
	for name, signal in mouseKit.buttons do
		members[name] = function()
			return signal
		end
	end
	mouseKit.object = service("Mouse", members, {
		IsA = function(_, className)
			return className == "Mouse" or className == "PlayerMouse" or className == "Instance"
		end,
	}, function(key, value)
		if key == "Icon" then
			mouseKit.icon = value
			return true
		end
		return false
	end)
	return mouseKit.object
end

function localPlayerMethods.GetMouse()
	return mouseKit.mouse()
end

"""#
}
