// The Luau library, part 10 of 16: the player, the character, the Humanoid and input.
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
			local worn = avatarKit.child(generation, key)
			if worn ~= nil then
				return worn
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
		if held ~= nil and held.Name == name then
			return held
		end
		return avatarKit.child(generation, name)
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
		for _, worn in avatarKit.children(generation) do
			table.insert(children, worn)
		end
		return children
	end

	function modelMethods.FindFirstChildOfClass(_, className)
		if className == "Humanoid" then
			return record.humanoid
		elseif className == "Tool" then
			return toolKit.held(generation)
		end
		return avatarKit.ofClass(generation, className)
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

	avatarKit.humanoidMethods(humanoidMethods, generation)

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
				elseif key == "face" and partName == "Head" then
					return avatarKit.face(generation)
				elseif key == "FindFirstChild" then
					return function(_, name)
						return if name == "face" and partName == "Head" then avatarKit.face(generation) else nil
					end
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

--------------------------------------------------------------------------------
-- What characters wear: Accessories, a Shirt and Pants, the face, HumanoidDescription
--
-- The look lives in the host, as `look.get`/`look.set` see it: {face, shirt, pants,
-- {accessory…}}, each accessory {id, name, item, type, texture, colour, offset,
-- rotation, scale}. An Accessory Luau holds is that entry: worn, it reads and writes
-- the character's; not worn (new, or taken off), it keeps its own copy.

do
	local accessoryState = setmetatable({}, { __mode = "k" })
	-- Worn accessories' proxies by character and id, so the same one comes back.
	local wornProxies = {}
	local clothingProxies = {}
	local faceProxies = {}
	local serial = 0
	local slotTypes = {
		HatAccessory = "Hat", HairAccessory = "Hair", FaceAccessory = "Face", NeckAccessory = "Neck",
		ShouldersAccessory = "Shoulder", FrontAccessory = "Front", BackAccessory = "Back", WaistAccessory = "Waist",
	}
	local slotOrder = { "HatAccessory", "HairAccessory", "FaceAccessory", "NeckAccessory", "ShouldersAccessory",
		"FrontAccessory", "BackAccessory", "WaistAccessory" }
	local colorSlots = { HeadColor = "Head", TorsoColor = "Torso", LeftArmColor = "Left Arm",
		RightArmColor = "Right Arm", LeftLegColor = "Left Leg", RightLegColor = "Right Leg" }
	local templateKey = { Shirt = "ShirtTemplate", Pants = "PantsTemplate" }
	local noFace = "builtin://None"
	local classicFace = "builtin://Smile"

	local function look(generation)
		return invoke("look.get", generation) or { "", "", "", {} }
	end

	local function newId()
		serial += 1
		return string.format("lua-%d-%d", serial, math.random(1, 1e9))
	end

	local function findEntry(generation, id)
		for index, entry in look(generation)[4] do
			if entry[1] == id then
				return entry, index
			end
		end
		return nil
	end

	local function setAccessories(generation, list)
		invoke("look.set", generation, "accessories", list)
	end

	-- The entry an Accessory stands for now: the character's, while it is worn.
	local function current(state)
		if state.generation ~= nil then
			local entry = findEntry(state.generation, state.entry[1])
			if entry ~= nil and invoke("character.alive", state.generation) then
				state.entry = entry
			else
				state.generation = nil
			end
		end
		return state.entry
	end

	local function update(state, field, value)
		local entry = table.clone(current(state))
		entry[field] = value
		state.entry = entry
		if state.generation ~= nil then
			local list = look(state.generation)[4]
			for index, existing in list do
				if existing[1] == entry[1] then
					list[index] = entry
				end
			end
			setAccessories(state.generation, list)
		end
	end

	local function takeOff(state)
		if state.generation == nil then
			return
		end
		local list = {}
		for _, existing in look(state.generation)[4] do
			if existing[1] ~= state.entry[1] then
				table.insert(list, existing)
			end
		end
		setAccessories(state.generation, list)
		local proxies = wornProxies[state.generation]
		if proxies ~= nil then
			proxies[state.entry[1]] = nil
		end
		state.generation = nil
	end

	local accessoryMethods = {}
	local accessoryMeta

	local function wrapAccessory(entry, generation)
		if generation ~= nil then
			local proxies = wornProxies[generation]
			if proxies == nil then
				proxies = {}
				wornProxies[generation] = proxies
			end
			local known = proxies[entry[1]]
			if known ~= nil then
				return known
			end
		end
		local proxy = setmetatable({}, accessoryMeta)
		typeTags[proxy] = "Instance"
		accessoryState[proxy] = { entry = entry, generation = generation }
		if generation ~= nil then
			wornProxies[generation][entry[1]] = proxy
		end
		return proxy
	end

	local function wear(state, proxy, generation)
		if state.generation == generation then
			return
		end
		takeOff(state)
		local list = look(generation)[4]
		if #list >= 10 then
			raise("A character wears at most 10 accessories", 3)
		end
		local entry = table.clone(state.entry)
		entry[1] = newId()
		state.entry = entry
		table.insert(list, entry)
		setAccessories(generation, list)
		state.generation = generation
		wornProxies[generation] = wornProxies[generation] or {}
		wornProxies[generation][entry[1]] = proxy
	end

	local accessoryFields = {
		Name = { index = 2, kind = "string" },
		MeshId = { index = 3, kind = "string" },
		TextureID = { index = 5, kind = "string" },
		Scale = { index = 9, kind = "number" },
	}

	accessoryMeta = {
		__index = function(self, key)
			local state = accessoryState[self]
			local entry = current(state)
			local field = accessoryFields[key]
			if field ~= nil then
				return entry[field.index]
			elseif key == "ClassName" then
				return "Accessory"
			elseif key == "AccessoryType" then
				return Enum.AccessoryType[entry[4]]
			elseif key == "Color" then
				return toColor(entry[6])
			elseif key == "Offset" then
				return toVector(entry[7])
			elseif key == "Rotation" then
				return toVector(entry[8])
			elseif key == "Parent" then
				local record = if state.generation ~= nil then characterFor(state.generation) else nil
				return record and record.model
			end
			local method = accessoryMethods[key]
			if method ~= nil then
				return method
			end
			raise(string.format("%s is not a valid member of Accessory \"%s\"", tostring(key), entry[2]), 2)
		end,
		__newindex = function(self, key, value)
			local state = accessoryState[self]
			local field = accessoryFields[key]
			if field ~= nil then
				expect(value, field.kind, key)
				update(state, field.index, value)
				if key == "MeshId" then
					-- A built-in accessory comes with where it goes and its colour.
					local catalog = invoke("look.catalog", value)
					if catalog ~= nil then
						update(state, 4, catalog[1])
						update(state, 6, catalog[2])
					end
				end
			elseif key == "AccessoryType" then
				local name = enumName(value, "AccessoryType")
				if name == nil or rawget(Enum.AccessoryType, name) == nil then
					raise("Unable to assign property AccessoryType. EnumItem expected, got " .. typeof(value), 2)
				end
				update(state, 4, name)
			elseif key == "Color" then
				expect(value, "Color3", key)
				update(state, 6, { value[1], value[2], value[3] })
			elseif key == "Offset" or key == "Rotation" then
				expect(value, "Vector3", key)
				update(state, if key == "Offset" then 7 else 8, { value[1], value[2], value[3] })
			elseif key == "Parent" then
				if value == nil then
					takeOff(state)
				elseif isCharacterModel[value] ~= nil then
					wear(state, self, isCharacterModel[value])
				else
					raise("An Accessory can only be parented to a character", 2)
				end
			else
				raise(string.format("%s is not a valid member of Accessory", tostring(key)), 2)
			end
		end,
		__tostring = function(self)
			return current(accessoryState[self])[2]
		end,
		__metatable = LOCKED,
	}

	function accessoryMethods.Destroy(self)
		checkSelf(self, "Instance", "Destroy")
		takeOff(accessoryState[self])
	end

	accessoryMethods.Remove = accessoryMethods.Destroy

	function accessoryMethods.Clone(self)
		checkSelf(self, "Instance", "Clone")
		return wrapAccessory(table.clone(current(accessoryState[self])), nil)
	end

	function accessoryMethods.IsA(_, className)
		return className == "Accessory" or className == "Accoutrement" or className == "Instance"
	end

	function accessoryMethods.GetChildren()
		return {}
	end

	function accessoryMethods.FindFirstChild()
		return nil
	end

	-- Shirt and Pants: a character wears one of each, the picture on its template.

	local clothingState = setmetatable({}, { __mode = "k" })
	local clothingMeta
	local function lookKey(className)
		return if className == "Shirt" then 2 else 3
	end

	local function wrapClothing(className, template, generation)
		if generation ~= nil then
			local proxies = clothingProxies[generation]
			if proxies ~= nil and proxies[className] ~= nil then
				return proxies[className]
			end
		end
		local proxy = setmetatable({}, clothingMeta)
		typeTags[proxy] = "Instance"
		clothingState[proxy] = { className = className, template = template, generation = generation }
		if generation ~= nil then
			clothingProxies[generation] = clothingProxies[generation] or {}
			clothingProxies[generation][className] = proxy
		end
		return proxy
	end

	local function clothingCurrent(state)
		if state.generation ~= nil then
			local worn = look(state.generation)[lookKey(state.className)]
			-- One put on with no picture yet is still on, as in Roblox.
			if (worn ~= "" or state.template == "") and invoke("character.alive", state.generation) then
				state.template = worn
			else
				state.generation = nil
			end
		end
		return state.template
	end

	local function clothingOff(state)
		if state.generation ~= nil then
			invoke("look.set", state.generation, string.lower(state.className), "")
			local proxies = clothingProxies[state.generation]
			if proxies ~= nil then
				proxies[state.className] = nil
			end
			state.generation = nil
		end
	end

	clothingMeta = {
		__index = function(self, key)
			local state = clothingState[self]
			if key == "Name" or key == "ClassName" then
				return state.className
			elseif key == templateKey[state.className] then
				return clothingCurrent(state)
			elseif key == "Parent" then
				clothingCurrent(state)
				local record = if state.generation ~= nil then characterFor(state.generation) else nil
				return record and record.model
			elseif key == "Destroy" or key == "Remove" then
				return function(object)
					checkSelf(object, "Instance", key)
					clothingOff(clothingState[object])
				end
			elseif key == "Clone" then
				return function(object)
					local from = clothingState[object]
					return wrapClothing(from.className, clothingCurrent(from), nil)
				end
			elseif key == "IsA" then
				return function(_, className)
					return className == state.className or className == "Clothing" or className == "Instance"
				end
			end
			raise(string.format("%s is not a valid member of %s", tostring(key), state.className), 2)
		end,
		__newindex = function(self, key, value)
			local state = clothingState[self]
			if key == templateKey[state.className] then
				expect(value, "string", key)
				clothingCurrent(state)
				state.template = value
				if state.generation ~= nil then
					invoke("look.set", state.generation, string.lower(state.className), value)
				end
			elseif key == "Parent" then
				if value == nil then
					clothingCurrent(state)
					clothingOff(state)
				elseif isCharacterModel[value] ~= nil then
					local generation = isCharacterModel[value]
					invoke("look.set", generation, string.lower(state.className), state.template)
					state.generation = generation
					clothingProxies[generation] = clothingProxies[generation] or {}
					clothingProxies[generation][state.className] = self
				else
					raise(string.format("A %s can only be parented to a character", state.className), 2)
				end
			else
				raise(string.format("Unable to assign property %s of %s", tostring(key), state.className), 2)
			end
		end,
		__tostring = function(self)
			return clothingState[self].className
		end,
		__metatable = LOCKED,
	}

	-- The face: the Head's Decal named "face".

	local function faceOf(generation)
		local worn = look(generation)[1]
		if worn == noFace then
			return nil
		end
		local known = faceProxies[generation]
		if known ~= nil then
			return known
		end
		local decal = setmetatable({}, {
			__index = function(_, key)
				if key == "Name" then
					return "face"
				elseif key == "ClassName" then
					return "Decal"
				elseif key == "Texture" then
					local face = look(generation)[1]
					return if face == "" then classicFace else face
				elseif key == "Parent" then
					local record = characterFor(generation)
					return record and record.parts.Head
				elseif key == "Destroy" or key == "Remove" then
					return function()
						invoke("look.set", generation, "face", noFace)
						faceProxies[generation] = nil
					end
				elseif key == "IsA" then
					return function(_, className)
						return className == "Decal" or className == "Instance"
					end
				end
				raise(string.format("%s is not a valid member of Decal \"face\"", tostring(key)), 2)
			end,
			__newindex = function(_, key, value)
				if key ~= "Texture" then
					raise(string.format("Unable to assign property %s of Decal", tostring(key)), 2)
				end
				expect(value, "string", key)
				invoke("look.set", generation, "face", if value == classicFace then "" else value)
			end,
			__tostring = function()
				return "face"
			end,
			__metatable = LOCKED,
		})
		typeTags[decal] = "Instance"
		faceProxies[generation] = decal
		return decal
	end

	-- HumanoidDescription: a whole look (and body colours) in one object.

	local descriptionMeta = {}
	local descriptionFields = {}
	local descriptionMethods = {}

	local function newDescription()
		local fields = { Face = "", Shirt = "", Pants = "", Name = "HumanoidDescription" }
		for _, slot in slotOrder do
			fields[slot] = ""
		end
		for key in colorSlots do
			fields[key] = color(163 / 255, 162 / 255, 165 / 255)
		end
		local description = setmetatable({}, descriptionMeta)
		typeTags[description] = "Instance"
		descriptionFields[description] = fields
		return description
	end

	descriptionMeta.__index = function(self, key)
		local fields = descriptionFields[self]
		if fields[key] ~= nil then
			return fields[key]
		elseif key == "ClassName" then
			return "HumanoidDescription"
		elseif key == "Parent" then
			return nil
		end
		local method = descriptionMethods[key]
		if method ~= nil then
			return method
		end
		raise(string.format("%s is not a valid member of HumanoidDescription", tostring(key)), 2)
	end
	descriptionMeta.__newindex = function(self, key, value)
		local fields = descriptionFields[self]
		if colorSlots[key] ~= nil then
			expect(value, "Color3", key)
		elseif fields[key] ~= nil then
			expect(value, "string", key)
		else
			raise(string.format("%s is not a valid member of HumanoidDescription", tostring(key)), 2)
		end
		fields[key] = value
	end
	descriptionMeta.__tostring = function()
		return "HumanoidDescription"
	end
	descriptionMeta.__metatable = LOCKED

	function descriptionMethods.IsA(_, className)
		return className == "HumanoidDescription" or className == "Instance"
	end

	function descriptionMethods.Clone(self)
		local copy = newDescription()
		for key, value in descriptionFields[self] do
			descriptionFields[copy][key] = value
		end
		return copy
	end

	-- Hooks for the character, its Humanoid and Instance.new.

	avatarKit.classes = { Accessory = true, Shirt = true, Pants = true, HumanoidDescription = true }

	function avatarKit.new(className, parent)
		local object
		if className == "Accessory" then
			object = wrapAccessory({ newId(), "Accessory", "", "Hat", "", { 0.8, 0.8, 0.8 }, { 0, 0, 0 },
				{ 0, 0, 0 }, 1 }, nil)
		elseif className == "HumanoidDescription" then
			return newDescription()
		else
			object = wrapClothing(className, "", nil)
		end
		if parent ~= nil then
			object.Parent = parent
		end
		return object
	end

	-- A character's child by name: an accessory, its Shirt or its Pants.
	-- The Shirt or Pants a character has on: one with a picture, or one put on without.
	local function clothingOn(generation, className, worn)
		if worn ~= "" then
			return wrapClothing(className, worn, generation)
		end
		local known = clothingProxies[generation] and clothingProxies[generation][className]
		if known ~= nil and clothingState[known].generation == generation and clothingState[known].template == "" then
			return known
		end
		return nil
	end

	function avatarKit.child(generation, name)
		local worn = look(generation)
		if name == "Shirt" or name == "Pants" then
			local found = clothingOn(generation, name, worn[lookKey(name)])
			if found ~= nil then
				return found
			end
		end
		for _, entry in worn[4] do
			if entry[2] == name then
				return wrapAccessory(entry, generation)
			end
		end
		return nil
	end

	function avatarKit.children(generation)
		local worn = look(generation)
		local list = {}
		for _, entry in worn[4] do
			table.insert(list, wrapAccessory(entry, generation))
		end
		for _, className in { "Shirt", "Pants" } do
			local found = clothingOn(generation, className, worn[lookKey(className)])
			if found ~= nil then
				table.insert(list, found)
			end
		end
		return list
	end

	function avatarKit.ofClass(generation, className)
		if className == "Shirt" or className == "Pants" then
			return avatarKit.child(generation, className)
		elseif className == "Accessory" or className == "Accoutrement" then
			local entry = look(generation)[4][1]
			return entry and wrapAccessory(entry, generation)
		end
		return nil
	end

	avatarKit.face = faceOf

	function avatarKit.humanoidMethods(methods, generation)
		function methods.AddAccessory(self, accessory)
			checkSelf(self, "Instance", "AddAccessory")
			local state = accessoryState[accessory]
			if state == nil then
				raise("AddAccessory expects an Accessory, got " .. typeof(accessory), 2)
			end
			wear(state, accessory, generation)
		end

		function methods.GetAccessories(self)
			checkSelf(self, "Instance", "GetAccessories")
			local list = {}
			for _, entry in look(generation)[4] do
				table.insert(list, wrapAccessory(entry, generation))
			end
			return list
		end

		function methods.RemoveAccessories(self)
			checkSelf(self, "Instance", "RemoveAccessories")
			setAccessories(generation, {})
			wornProxies[generation] = {}
		end

		function methods.GetAppliedDescription(self)
			checkSelf(self, "Instance", "GetAppliedDescription")
			local description = newDescription()
			local fields = descriptionFields[description]
			local worn = look(generation)
			fields.Face = if worn[1] == "" then classicFace else worn[1]
			fields.Shirt = worn[2]
			fields.Pants = worn[3]
			for _, slot in slotOrder do
				local items = {}
				for _, entry in worn[4] do
					if entry[4] == slotTypes[slot] then
						table.insert(items, entry[3])
					end
				end
				fields[slot] = table.concat(items, ",")
			end
			for key, part in colorSlots do
				fields[key] = toColor(invoke("body.get", generation, part, "color"))
			end
			return description
		end

		function methods.ApplyDescription(self, description)
			checkSelf(self, "Instance", "ApplyDescription")
			local fields = descriptionFields[description]
			if fields == nil then
				raise("ApplyDescription expects a HumanoidDescription, got " .. typeof(description), 2)
			end
			invoke("look.set", generation, "face", if fields.Face == classicFace then "" else fields.Face)
			invoke("look.set", generation, "shirt", fields.Shirt)
			invoke("look.set", generation, "pants", fields.Pants)
			local list = {}
			for _, slot in slotOrder do
				for item in string.gmatch(fields[slot], "[^,%s]+") do
					local catalog = invoke("look.catalog", item)
					local name = string.match(item, "([^/]+)$") or item
					table.insert(list, { newId(), name, item, slotTypes[slot], "",
						if catalog ~= nil then catalog[2] else { 0.8, 0.8, 0.8 }, { 0, 0, 0 }, { 0, 0, 0 }, 1 })
				end
			end
			setAccessories(generation, list)
			wornProxies[generation] = {}
			for key, part in colorSlots do
				local value = fields[key]
				invoke("body.set", generation, part, "color", { value[1], value[2], value[3] })
			end
		end
	end
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

-- The Backpack and PlayerGui; data objects in the player (leaderstats) are found too.
local function localPlayerChild(name)
	if name == "Backpack" then
		return toolKit.backpack(invoke("backpack.me"))
	end
	return if name == "PlayerGui" then gui.playerGui else nil
end

function localPlayerMethods.FindFirstChild(_, name)
	return localPlayerChild(name) or dataKit.playerChild(invoke("backpack.me"), name)
end

-- Waits for what isn't there yet: leaderstats a host script is still making.
function localPlayerMethods.WaitForChild(_, name, timeout)
	return dataKit.waitForPlayerChild(invoke("backpack.me"), name, timeout, localPlayerChild)
end

function localPlayerMethods.GetChildren()
	local list = { toolKit.backpack(invoke("backpack.me")), gui.playerGui }
	for _, child in dataKit.playerChildren(invoke("backpack.me")) do
		table.insert(list, child)
	end
	return list
end

function localPlayerMethods.__child(key)
	return dataKit.playerChild(invoke("backpack.me"), key)
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
	-- Shift lock (Left Ctrl) for this player; false takes it away.
	DevEnableMouseLock = function()
		return invoke("player.get", "devenablemouselock")
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
	elseif key == "DevEnableMouseLock" then
		expect(value, "boolean", key)
		invoke("player.set", "devenablemouselock", value)
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
			return if name == "Backpack" then toolKit.backpack(id) else dataKit.playerChild(id, name)
		end,
		WaitForChild = function(_, name, timeout)
			return dataKit.waitForPlayerChild(id, name, timeout, function(key)
				return if key == "Backpack" then toolKit.backpack(id) else nil
			end)
		end,
		GetChildren = function()
			local list = { toolKit.backpack(id) }
			for _, child in dataKit.playerChildren(id) do
				table.insert(list, child)
			end
			return list
		end,
		__child = function(key)
			return dataKit.playerChild(id, key)
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
