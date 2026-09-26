// The Luau library, part 12 of 16: Tools, StarterPack and the Backpack.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let tools = #"""
--------------------------------------------------------------------------------
-- Tools
--
-- A Tool is a group, like a Model, that the host moves between the Workspace,
-- StarterPack, a player's Backpack and their hand (PlayController+Tools.swift); its
-- Parent says which. `toolKit` is declared with the group proxies, which ask it about
-- the members only a Tool has. Players go by number here: 0 is the host (or the only
-- player), and `backpack.me` is this one.

toolKit.properties = { ToolTip = "string", Enabled = "boolean", RequiresHandle = "boolean", CanBeDropped = "boolean" }
toolKit.events = { Equipped = true, Unequipped = true, Activated = true, Deactivated = true }
toolKit.signals = {}
toolKit.backpacks = {}
toolKit.backpackOwner = setmetatable({}, { __mode = "k" })

function toolKit.isTool(id)
	return invoke("group.get", id, "kind") == "Tool"
end

function toolKit.signal(id, name)
	local byName = toolKit.signals[id]
	if byName == nil then
		byName = {}
		toolKit.signals[id] = byName
	end
	local signal = byName[name]
	if signal == nil then
		signal = makeSignal()
		byName[name] = signal
	end
	return signal
end

function toolKit.fire(id, name)
	local byName = toolKit.signals[id]
	if byName ~= nil and byName[name] ~= nil then
		-- Equipped hands over the Mouse, when the tool is this player's.
		local mouse = if name == "Equipped" and invoke("tool.get", id, "holder") == invoke("backpack.me")
			then mouseKit.mouse() else nil
		fire(byName[name], mouse)
	end
end

-- The Player a number stands for: this one, or another in a network game.
function toolKit.playerOf(number)
	if number == nil then
		return nil
	elseif number == invoke("backpack.me") then
		return LocalPlayer
	end
	return otherPlayers.get(number).player
end

function toolKit.parent(id)
	local place = invoke("tool.get", id, "place")
	if place == "starterpack" then
		return StarterPack
	elseif place == "backpack" then
		return toolKit.backpack(invoke("tool.get", id, "holder"))
	elseif place == "hand" then
		local player = toolKit.playerOf(invoke("tool.get", id, "holder"))
		return player and player.Character
	elseif place == nil then
		return nil
	end
	return wrapToken(invoke("tree.parent", id))
end

toolKit.methods = {
	Activate = function(self)
		invoke("backpack.activate", groupIdOf[self], true)
	end,
	Deactivate = function(self)
		invoke("backpack.activate", groupIdOf[self], false)
	end,
}

-- A member only a Tool has: found, and its value.
function toolKit.member(id, key)
	if toolKit.properties[key] == nil and not toolKit.events[key] and toolKit.methods[key] == nil
		and key ~= "Grip" then
		return false
	end
	if not toolKit.isTool(id) then
		return false
	end
	if toolKit.properties[key] ~= nil then
		return true, invoke("tool.get", id, string.lower(key))
	elseif toolKit.events[key] then
		return true, toolKit.signal(id, key)
	elseif key == "Grip" then
		return true, cframeMath.cframeFromList(invoke("tool.get", id, "grip"))
	end
	return true, toolKit.methods[key]
end

-- Setting a Tool's own properties, or its Parent; false when it is not for a Tool.
function toolKit.assign(id, key, value)
	if key ~= "Parent" and key ~= "Grip" and toolKit.properties[key] == nil then
		return false
	end
	if not toolKit.isTool(id) then
		return false
	end
	if key == "Parent" then
		toolKit.setParent(id, value)
	elseif key == "Grip" then
		if not isCFrame(value) then
			raise("Unable to assign property Grip. CFrame expected, got " .. typeof(value), 3)
		end
		invoke("tool.set", id, "grip", cframeMath.cframeList(value))
	else
		if type(value) ~= toolKit.properties[key] then
			raise(string.format("Unable to assign property %s. %s expected, got %s", key,
				toolKit.properties[key], typeof(value)), 3)
		end
		invoke("tool.set", id, string.lower(key), value)
	end
	return true
end

-- Parent = a Backpack gives the tool to that player, a character equips it, and the
-- Workspace (or anything in it) drops it into the world.
function toolKit.setParent(id, value)
	if value == nil then
		invoke("group.destroy", id)
		return
	end
	local owner = toolKit.backpackOwner[value]
	if owner ~= nil then
		invoke("backpack.give", owner, id)
		return
	end
	local generation = isCharacterModel[value]
	if generation ~= nil then
		invoke("backpack.equip", generation, id)
		return
	end
	local target = nodeId(value)
	if target == nil then
		raise("Unable to assign property Parent. A Tool goes in the Workspace, a Backpack or a character, not "
			.. typeof(value), 4)
	end
	if invoke("tool.get", id, "place") ~= "workspace" then
		invoke("backpack.drop", id)
	end
	if not invoke("tree.setparent", id, target) then
		raise("Unable to assign property Parent. It can't go inside itself", 4)
	end
end

-- The tool in a character's hand, by the character's number.
function toolKit.held(generation)
	return wrapGroup(invoke("backpack.held", generation))
end

function toolKit.list(ids)
	local tools = {}
	for _, id in ids do
		table.insert(tools, wrapGroup(id))
	end
	return tools
end

function toolKit.named(tools, name)
	for _, tool in tools do
		if tool.Name == name then
			return tool
		end
	end
	return nil
end

-- A player's Backpack: the tools they have but aren't holding.
function toolKit.backpack(number)
	local existing = toolKit.backpacks[number]
	if existing ~= nil then
		return existing
	end
	local function tools()
		return toolKit.list(invoke("backpack.list", number))
	end
	local backpack = service("Backpack", {
		Parent = function()
			return toolKit.playerOf(number)
		end,
	}, {
		GetChildren = function()
			return tools()
		end,
		FindFirstChild = function(_, name)
			return toolKit.named(tools(), name)
		end,
		WaitForChild = function(_, name)
			return toolKit.named(tools(), name)
		end,
		FindFirstChildOfClass = function(_, className)
			return if className == "Tool" then tools()[1] else nil
		end,
		IsA = function(_, className)
			return className == "Backpack" or className == "Instance"
		end,
		ClearAllChildren = function()
			for _, tool in tools() do
				tool:Destroy()
			end
		end,
		__child = function(key)
			return toolKit.named(tools(), key)
		end,
	})
	toolKit.backpackOwner[backpack] = number
	toolKit.backpacks[number] = backpack
	return backpack
end

-- StarterPack: the tools every player is given when their character spawns.
StarterPack = service("StarterPack", nil, {
	GetChildren = function()
		return toolKit.list(invoke("tool.starterpack"))
	end,
	FindFirstChild = function(_, name)
		return toolKit.named(toolKit.list(invoke("tool.starterpack")), name)
	end,
	WaitForChild = function(_, name)
		return toolKit.named(toolKit.list(invoke("tool.starterpack")), name)
	end,
	IsA = function(_, className)
		return className == "StarterPack" or className == "Instance"
	end,
	__child = function(key)
		return toolKit.named(toolKit.list(invoke("tool.starterpack")), key)
	end,
})
"""#
}
