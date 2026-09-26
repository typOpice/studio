// The Luau library, part 15 of 16: data objects (Folders, Values, remotes), ModuleScripts
// and require, ReplicatedStorage and ServerScriptService, and workspace:Raycast.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let data = #"""
-- One block: its helpers stay out of the library's top-level locals.
do
	--------------------------------------------------------------------------------
	-- Data objects: Folders, IntValue/NumberValue/StringValue/BoolValue, RemoteEvent and
	-- RemoteFunction. The host keeps them (`data.*`), as "v:<id>" tokens; they can be in the
	-- Workspace tree, ReplicatedStorage, a Player (leaderstats), or each other.

	-- For parts that run before the scheduler's: whether the running thread is a LocalScript's.
	dataKit.isLocal = inLocalScript

	dataKit.idOf = setmetatable({}, { __mode = "k" })
	dataKit.proxies = setmetatable({}, { __mode = "v" })
	dataKit.names = {}
	dataKit.signals = {}
	dataKit.callbacks = {}
	dataKit.replies = {}
	dataKit.methods = {}
	dataKit.Meta = {}
	dataKit.valueKinds = { IntValue = "number", NumberValue = "number", StringValue = "string", BoolValue = "boolean",
		ObjectValue = "Instance", Vector3Value = "Vector3", Color3Value = "Color3", CFrameValue = "CFrame" }
	-- A tag for this VM: GUI objects sent through a remote mean something only on the
	-- machine they came from.
	dataKit.vmTag = tostring(math.random(1, 2 ^ 30)) .. "-" .. tostring(os.clock())

	function dataKit.wrap(id)
		if id == nil then
			return nil
		end
		local known = dataKit.proxies[id]
		if known ~= nil then
			return known
		end
		local proxy = setmetatable({}, dataKit.Meta)
		typeTags[proxy] = "Instance"
		dataKit.idOf[proxy] = id
		dataKit.proxies[id] = proxy
		return proxy
	end

	-- A Folder that was a Model-tree Folder until it went into a Player or ReplicatedStorage:
	-- its old proxy answers as the data Folder it became.
	dataKit.adopted = setmetatable({}, { __mode = "k" })

	function dataKit.adopt(proxy, id)
		dataKit.adopted[proxy] = true
		dataKit.idOf[proxy] = id
		-- The same object wherever it's found from now on.
		dataKit.proxies[id] = proxy
	end

	function dataKit.signalsOf(id)
		local signals = dataKit.signals[id]
		if signals == nil then
			signals = { Changed = makeSignal(), Value = makeSignal(), OnServerEvent = makeSignal(),
				OnClientEvent = makeSignal(), Event = makeSignal() }
			dataKit.signals[id] = signals
		end
		return signals
	end

	-- The number a Player goes by in the game (0 the host), or nil for anything else.
	function dataKit.playerNumber(player)
		if player == nil then
			return nil
		elseif player == LocalPlayer then
			return invoke("backpack.me")
		end
		for id, entry in otherPlayers.byId do
			if entry.player == player then
				return id
			end
		end
		return nil
	end

	-- Where an object can put a data object, as the host takes it: "rs", "pl:<n>", "v:<id>",
	-- "w", or "n:<id>" for a part, Model or Folder; nil if it can't hold one.
	function dataKit.placeOf(object)
		if object == nil then
			return nil
		elseif object == dataKit.ReplicatedStorage then
			return "rs"
		elseif object == dataKit.ServerStorage then
			return "ss"
		elseif object == workspace_ then
			return "w"
		end
		local id = dataKit.idOf[object]
		if id ~= nil then
			return "v:" .. id
		end
		local number = dataKit.playerNumber(object)
		if number ~= nil then
			return "pl:" .. number
		end
		local node = partIdOf[object] or groupIdOf[object]
		return if node ~= nil then "n:" .. node else nil
	end

	-- A token for a place the host names ("rs", "sss", "pl:<n>", or a tree or data token).
	function dataKit.wrapPlace(token)
		if token == nil then
			return nil
		elseif token == "rs" then
			return dataKit.ReplicatedStorage
		elseif token == "ss" then
			return dataKit.ServerStorage
		elseif token == "sss" then
			return dataKit.ServerScriptService
		elseif string.sub(token, 1, 3) == "pl:" then
			return toolKit.playerOf(tonumber(string.sub(token, 4)))
		end
		return wrapToken(token)
	end

	-- WaitForChild that waits: the child may be on its way from the host.
	function dataKit.waitFor(find, where, name, timeout)
		local found = find()
		if found ~= nil then
			return found
		end
		local waited, warned = 0, false
		while true do
			waited += task.wait()
			found = find()
			if found ~= nil then
				return found
			end
			if timeout ~= nil and waited >= timeout then
				return nil
			end
			if not warned and waited >= 5 then
				warned = true
				warn(string.format("Infinite yield possible on '%s:WaitForChild(\"%s\")'", where, tostring(name)))
			end
		end
	end

	local function dataClass(id)
		return invoke("data.get", id, "class")
	end

	local function dataChild(id, name)
		return wrapToken(invoke("data.find", "v:" .. id, name))
	end

	-- A Value's value, as scripts see it.
	function dataKit.readValue(id, class)
		local raw = invoke("data.get", id, "value")
		if class == "ObjectValue" then
			return if raw ~= nil then dataKit.wrapPlace(raw) else nil
		elseif class == "Vector3Value" then
			return toVector(raw)
		elseif class == "Color3Value" then
			return toColor(raw)
		elseif class == "CFrameValue" then
			return CFrame.new(table.unpack(raw, 1, 12))
		end
		return raw
	end

	-- What an ObjectValue keeps for an Instance: its token, which every machine reads the
	-- same way. Nil for what can't be kept (a character, a GUI object).
	function dataKit.tokenOf(object)
		if object == workspace_ then
			return "w"
		elseif object == dataKit.ReplicatedStorage then
			return "rs"
		elseif object == dataKit.ServerStorage then
			return "ss"
		elseif partIdOf[object] then
			return "p:" .. partIdOf[object]
		elseif dataKit.idOf[object] then
			return "v:" .. dataKit.idOf[object]
		elseif groupIdOf[object] then
			return "g:" .. groupIdOf[object]
		elseif dataKit.moduleIdOf[object] then
			return "m:" .. dataKit.moduleIdOf[object]
		elseif soundKit.idOf[object] then
			return "s:" .. soundKit.idOf[object]
		elseif attachmentIdOf[object] then
			return "a:" .. attachmentIdOf[object]
		elseif constraintIdOf[object] then
			return "c:" .. constraintIdOf[object]
		end
		local number = dataKit.playerNumber(object)
		return if number ~= nil then "pl:" .. number else nil
	end

	dataKit.Meta.__index = function(self, key)
		local id = dataKit.idOf[self]
		local class = dataClass(id)
		if class == nil then
			-- Destroyed: it keeps its name, and is nowhere.
			if key == "Parent" then
				return nil
			elseif key == "Name" then
				return dataKit.names[id] or "Instance"
			end
			raise(string.format("%s is not a valid member of a destroyed Instance", tostring(key)), 2)
		end
		if key == "Name" then
			local name = invoke("data.get", id, "name")
			dataKit.names[id] = name
			return name
		elseif key == "ClassName" then
			return class
		elseif key == "Parent" then
			return dataKit.wrapPlace(invoke("data.get", id, "parent"))
		elseif key == "Value" and dataKit.valueKinds[class] then
			return dataKit.readValue(id, class)
		elseif key == "Changed" then
			return dataKit.signalsOf(id).Changed
		elseif (class == "RemoteEvent" or class == "UnreliableRemoteEvent")
			and (key == "OnServerEvent" or key == "OnClientEvent") then
			return dataKit.signalsOf(id)[key]
		elseif class == "BindableEvent" and key == "Event" then
			return dataKit.signalsOf(id).Event
		elseif (class == "RemoteFunction" and (key == "OnServerInvoke" or key == "OnClientInvoke"))
			or (class == "BindableFunction" and key == "OnInvoke") then
			raise(string.format("%s is a callback member of RemoteFunction; you can only set the callback value, get is not available", key), 2)
		end
		local method = dataKit.methods[key]
		if method ~= nil then
			return method
		end
		if type(key) == "string" then
			local child = dataChild(id, key)
			if child ~= nil then
				return child
			end
		end
		raise(string.format("%s is not a valid member of %s \"%s\"", tostring(key), class,
			invoke("data.get", id, "name") or "?"), 2)
	end

	dataKit.Meta.__newindex = function(self, key, value)
		local id = dataKit.idOf[self]
		local class = dataClass(id)
		if class == nil then
			raise(string.format("Unable to assign property %s of a destroyed Instance", tostring(key)), 2)
		end
		if key == "Name" then
			expect(value, "string", "Name")
			invoke("data.set", id, "name", value)
		elseif key == "Value" and dataKit.valueKinds[class] then
			local kind = dataKit.valueKinds[class]
			local ok = typeof(value) == kind or (class == "StringValue" and type(value) == "number")
				or (class == "ObjectValue" and value == nil)
			if not ok then
				raise(string.format("Unable to assign property Value. %s expected, got %s", kind, typeof(value)), 2)
			end
			local host = value
			if class == "ObjectValue" then
				host = if value == nil then nil else dataKit.tokenOf(value)
				if value ~= nil and host == nil then
					raise("Unable to assign property Value. An ObjectValue can't hold a " .. typeof(value) .. " here", 2)
				end
			elseif kind == "Vector3" or kind == "Color3" then
				host = { value[1], value[2], value[3] }
			elseif kind == "CFrame" then
				host = { value:GetComponents() }
			end
			if invoke("data.set", id, "value", host) then
				-- Changed at once, with the value as it went in (an IntValue's rounded).
				local signals = dataKit.signals[id]
				if signals ~= nil then
					fire(signals.Changed, dataKit.readValue(id, class))
					fire(signals.Value)
				end
			end
		elseif key == "Parent" then
			local place = if value == nil then "" else dataKit.placeOf(value)
			if place == nil then
				raise("Unable to assign property Parent. It can't hold a " .. class .. ", got " .. typeof(value), 2)
			end
			if not invoke("data.set", id, "parent", place) then
				raise("Unable to assign property Parent. It can't go inside itself", 2)
			end
		elseif (class == "RemoteFunction" and (key == "OnServerInvoke" or key == "OnClientInvoke"))
			or (class == "BindableFunction" and key == "OnInvoke") then
			if value ~= nil and type(value) ~= "function" then
				raise(string.format("Unable to assign property %s. function expected, got %s", key, typeof(value)), 2)
			end
			dataKit.callbacks[id] = dataKit.callbacks[id] or {}
			dataKit.callbacks[id][if key == "OnClientInvoke" then "client" else "server"] = value
		else
			raise(string.format("Unable to assign property %s of %s", tostring(key), class), 2)
		end
	end

	dataKit.Meta.__tostring = function(self)
		local id = dataKit.idOf[self]
		return invoke("data.get", id, "name") or dataKit.names[id] or "Instance"
	end

	dataKit.Meta.__metatable = LOCKED

	-- Instance.new for the Values and remotes (a Folder is made in the Workspace tree,
	-- and becomes a data Folder if it goes where only one can).
	dataKit.classes = { IntValue = true, NumberValue = true, StringValue = true, BoolValue = true,
		ObjectValue = true, Vector3Value = true, Color3Value = true, CFrameValue = true,
		RemoteEvent = true, UnreliableRemoteEvent = true, RemoteFunction = true,
		BindableEvent = true, BindableFunction = true }

	function dataKit.new(className, parent)
		local object = dataKit.wrap(invoke("data.create", className))
		if parent ~= nil then
			object.Parent = parent
		end
		return object
	end

	local dataMethods = dataKit.methods

	function dataMethods.GetChildren(self)
		return wrapTokens(invoke("data.children", "v:" .. dataKit.idOf[self]))
	end

	function dataMethods.GetDescendants(self)
		local list = {}
		for _, child in dataMethods.GetChildren(self) do
			table.insert(list, child)
			if dataKit.idOf[child] ~= nil then
				for _, inner in dataMethods.GetDescendants(child) do
					table.insert(list, inner)
				end
			end
		end
		return list
	end

	function dataMethods.FindFirstChild(self, name)
		return dataChild(dataKit.idOf[self], name)
	end

	function dataMethods.WaitForChild(self, name, timeout)
		local id = dataKit.idOf[self]
		return dataKit.waitFor(function()
			return dataChild(id, name)
		end, invoke("data.get", id, "name") or "Instance", name, timeout)
	end

	function dataMethods.FindFirstChildOfClass(self, className)
		for _, child in dataMethods.GetChildren(self) do
			if child.ClassName == className then
				return child
			end
		end
		return nil
	end

	function dataMethods.FindFirstChildWhichIsA(self, className)
		for _, child in dataMethods.GetChildren(self) do
			if child:IsA(className) then
				return child
			end
		end
		return nil
	end

	function dataMethods.IsA(self, className)
		local class = dataClass(dataKit.idOf[self])
		return className == class or className == "Instance" or (className == "ValueBase" and dataKit.valueKinds[class] ~= nil)
			or (className == "BaseRemoteEvent" and (class == "RemoteEvent" or class == "UnreliableRemoteEvent"))
	end

	function dataMethods.GetFullName(self)
		local names = { self.Name }
		local parent = self.Parent
		while parent ~= nil and parent ~= workspace_ do
			table.insert(names, 1, parent.Name)
			parent = if dataKit.idOf[parent] ~= nil or partIdOf[parent] ~= nil or groupIdOf[parent] ~= nil
				then parent.Parent else nil
		end
		return table.concat(names, ".")
	end

	function dataMethods.Destroy(self)
		local id = dataKit.idOf[self]
		dataKit.names[id] = invoke("data.get", id, "name")
		invoke("data.destroy", id)
	end

	dataMethods.Remove = dataMethods.Destroy

	function dataMethods.ClearAllChildren(self)
		for _, child in dataMethods.GetChildren(self) do
			child:Destroy()
		end
	end

	function dataMethods.Clone(self)
		return dataKit.wrap(invoke("data.clone", dataKit.idOf[self]))
	end

	function dataMethods.GetPropertyChangedSignal(self, property)
		if property == "Value" then
			return dataKit.signalsOf(dataKit.idOf[self]).Value
		end
		return makeSignal()
	end

	-- Values crossing machines: numbers, strings and booleans as they are; everything else
	-- as a list whose first item says what it is. Functions and threads become nil, as
	-- Roblox drops them.

	function dataKit.encode(value, depth)
		local kind = typeof(value)
		if kind == "number" or kind == "string" or kind == "boolean" then
			return value
		elseif kind == "nil" then
			return { "$nil" }
		elseif kind == "Vector3" then
			return { "$v3", value[1], value[2], value[3] }
		elseif kind == "Color3" then
			return { "$c3", value[1], value[2], value[3] }
		elseif kind == "Vector2" then
			return { "$v2", value.X, value.Y }
		elseif kind == "CFrame" then
			return { "$cf", value:GetComponents() }
		elseif kind == "EnumItem" then
			return { "$e", rawget(value, 2), rawget(value, 1) }
		elseif kind == "Instance" then
			if partIdOf[value] then
				return { "$p", partIdOf[value] }
			elseif groupIdOf[value] and not dataKit.adopted[value] then
				return { "$g", groupIdOf[value] }
			elseif dataKit.idOf[value] then
				return { "$d", dataKit.idOf[value] }
			elseif dataKit.moduleIdOf[value] then
				return { "$m", dataKit.moduleIdOf[value] }
			elseif soundKit.idOf[value] then
				return { "$s", soundKit.idOf[value] }
			elseif attachmentIdOf[value] then
				return { "$a", attachmentIdOf[value] }
			elseif constraintIdOf[value] then
				return { "$cn", constraintIdOf[value] }
			elseif gui.idOf[value] then
				-- A GUI object is this machine's own: it means something only here.
				return { "$ui", gui.idOf[value], dataKit.vmTag }
			elseif value == workspace_ then
				return { "$w" }
			elseif value == dataKit.ReplicatedStorage or value == dataKit.ServerStorage then
				return { "$st", if value == dataKit.ReplicatedStorage then "rs" else "ss" }
			elseif isCharacterModel[value] then
				local owner = invoke("character.owner", isCharacterModel[value])
				return { "$ch", if owner < 0 then invoke("backpack.me") else owner }
			elseif gui.bodyPartOf[value] then
				local generation, name = string.match(gui.bodyPartOf[value], "^c:(%d+):(.+)$")
				local owner = invoke("character.owner", tonumber(generation))
				return { "$bp", if owner < 0 then invoke("backpack.me") else owner, name }
			end
			local number = dataKit.playerNumber(value)
			if number ~= nil then
				return { "$pl", number }
			end
			return { "$nil" }
		elseif kind == "table" then
			depth = (depth or 0) + 1
			if depth > 30 then
				raise("Tables sent through a remote can't be nested more than 30 deep", 4)
			end
			local list = { "$t" }
			for key, item in value do
				local k = dataKit.encode(key, depth)
				if typeof(item) ~= "function" and typeof(item) ~= "thread" then
					table.insert(list, k)
					table.insert(list, dataKit.encode(item, depth))
				end
			end
			return list
		end
		return { "$nil" }
	end

	function dataKit.decode(value)
		if type(value) ~= "table" then
			return value
		end
		local tag = value[1]
		if tag == "$v3" then
			return vector(value[2], value[3], value[4])
		elseif tag == "$c3" then
			return color(value[2], value[3], value[4])
		elseif tag == "$v2" then
			return Vector2.new(value[2], value[3])
		elseif tag == "$cf" then
			return CFrame.new(table.unpack(value, 2, 13))
		elseif tag == "$e" then
			local enum = rawget(Enum, value[2])
			return enum and rawget(enum, value[3])
		elseif tag == "$p" then
			return if invoke("part.exists", value[2]) then wrapPart(value[2]) else nil
		elseif tag == "$g" then
			return if invoke("group.get", value[2], "kind") then wrapGroup(value[2]) else nil
		elseif tag == "$d" then
			return if invoke("data.exists", value[2]) then dataKit.wrap(value[2]) else nil
		elseif tag == "$m" then
			return dataKit.wrapModule(value[2])
		elseif tag == "$s" then
			return if invoke("sound.get", value[2], "name") ~= nil then soundKit.wrap(value[2]) else nil
		elseif tag == "$a" then
			return if invoke("tree.parent", value[2]) ~= nil then wrapAttachment(value[2]) else nil
		elseif tag == "$cn" then
			return if invoke("tree.parent", value[2]) ~= nil then wrapConstraint(value[2]) else nil
		elseif tag == "$ui" then
			return if value[3] == dataKit.vmTag then gui.wrap(value[2]) else nil
		elseif tag == "$w" then
			return workspace_
		elseif tag == "$st" then
			return dataKit.wrapPlace(value[2])
		elseif tag == "$pl" then
			return toolKit.playerOf(value[2])
		elseif tag == "$ch" then
			local player = toolKit.playerOf(value[2])
			return player and player.Character
		elseif tag == "$bp" then
			local player = toolKit.playerOf(value[2])
			local character = player and player.Character
			return character and character:FindFirstChild(value[3])
		elseif tag == "$t" then
			local result = {}
			for index = 2, #value - 1, 2 do
				local key = dataKit.decode(value[index])
				if key ~= nil then
					result[key] = dataKit.decode(value[index + 1])
				end
			end
			return result
		end
		return nil
	end

	function dataKit.encodeAll(...)
		local count = select("#", ...)
		local list = table.create(count)
		for index = 1, count do
			list[index] = dataKit.encode((select(index, ...)))
		end
		return list
	end

	function dataKit.decodeAll(list)
		local values = table.create(#list)
		for index, item in list do
			values[index] = dataKit.decode(item)
		end
		return table.unpack(values, 1, #list)
	end

	-- Remotes

	local function remoteOf(self, className, method)
		local id = dataKit.idOf[self]
		local class = id and dataClass(id)
		if class == "UnreliableRemoteEvent" and className == "RemoteEvent" then
			class = className
		end
		if id == nil or class ~= className then
			raise(string.format("Expected ':' not '.' calling member function %s", method), 3)
		end
		return id
	end

	local function playerArgument(player, method)
		local number = dataKit.playerNumber(player)
		if number == nil then
			raise(string.format("%s: player argument must be a Player object", method), 3)
		end
		return number
	end

	-- On the host, scene scripts are the server and LocalScripts the client; a joined
	-- player only has a client.
	local function onServer()
		return invoke("remote.isServer") and not inLocalScript()
	end

	function dataMethods.FireServer(self, ...)
		local id = remoteOf(self, "RemoteEvent", "FireServer")
		if onServer() then
			raise("FireServer can only be called from the client", 2)
		end
		invoke("remote.fire", id, "server", -1, dataKit.encodeAll(...))
	end

	function dataMethods.FireClient(self, player, ...)
		local id = remoteOf(self, "RemoteEvent", "FireClient")
		if not onServer() then
			raise("FireClient can only be called from the server", 2)
		end
		invoke("remote.fire", id, "client", playerArgument(player, "FireClient"), dataKit.encodeAll(...))
	end

	function dataMethods.FireAllClients(self, ...)
		local id = remoteOf(self, "RemoteEvent", "FireAllClients")
		if not onServer() then
			raise("FireAllClients can only be called from the server", 2)
		end
		invoke("remote.fire", id, "all", -1, dataKit.encodeAll(...))
	end

	local function awaitReply(call)
		while dataKit.replies[call] == nil do
			task.wait()
		end
		local reply = dataKit.replies[call]
		dataKit.replies[call] = nil
		if not reply[1] then
			raise(tostring(reply[2]), 3)
		end
		return dataKit.decodeAll(reply[2])
	end

	function dataMethods.InvokeServer(self, ...)
		local id = remoteOf(self, "RemoteFunction", "InvokeServer")
		if onServer() then
			raise("InvokeServer can only be called from the client", 2)
		end
		return awaitReply(invoke("remote.invoke", id, "server", -1, dataKit.encodeAll(...)))
	end

	function dataMethods.InvokeClient(self, player, ...)
		local id = remoteOf(self, "RemoteFunction", "InvokeClient")
		if not onServer() then
			raise("InvokeClient can only be called from the server", 2)
		end
		return awaitReply(invoke("remote.invoke", id, "client", playerArgument(player, "InvokeClient"),
			dataKit.encodeAll(...)))
	end

	-- A remote event with nobody listening yet keeps what arrives, as Roblox does, and
	-- hands it over when the first handler connects.
	function dataKit.deliver(signal, ...)
		local listening = false
		for _, connection in signal.connections do
			if connection.Connected then
				listening = true
				break
			end
		end
		if listening or #signal.waiting > 0 then
			fire(signal, ...)
			return
		end
		local queue = rawget(signal, "queued")
		if queue == nil then
			queue = {}
			rawset(signal, "queued", queue)
			rawset(signal, "onConnect", function()
				local waiting = rawget(signal, "queued")
				rawset(signal, "queued", nil)
				for _, arguments in waiting do
					fire(signal, table.unpack(arguments, 1, arguments.n))
				end
			end)
		end
		if #queue < 256 then
			table.insert(queue, table.pack(...))
		end
	end

	-- BindableEvents and BindableFunctions: scripts on the same machine calling each other.

	function dataMethods.Fire(self, ...)
		local id = remoteOf(self, "BindableEvent", "Fire")
		fire(dataKit.signalsOf(id).Event, ...)
	end

	function dataMethods.Invoke(self, ...)
		local id = remoteOf(self, "BindableFunction", "Invoke")
		local callbacks = dataKit.callbacks[id]
		local callback = callbacks and callbacks.server
		local waited = 0
		while callback == nil do
			if waited >= 30 then
				raise("OnInvoke was never set", 2)
			end
			waited += task.wait()
			callbacks = dataKit.callbacks[id]
			callback = callbacks and callbacks.server
		end
		return callback(...)
	end

	-- The host's events for remotes and Values, from part 13's dispatch.
	function dataKit.dispatch(event)
		local kind = event[1]
		if kind == "DataChanged" then
			local id = event[2]
			local signals = dataKit.signals[id]
			if signals ~= nil and invoke("data.exists", id) then
				fire(signals.Changed, dataKit.readValue(id, dataClass(id)))
				fire(signals.Value)
			end
		elseif kind == "RemoteServer" then
			-- ["RemoteServer", remote, fromPlayer, arguments]
			dataKit.deliver(dataKit.signalsOf(event[2]).OnServerEvent, toolKit.playerOf(event[3]),
				dataKit.decodeAll(event[4]))
		elseif kind == "RemoteClient" then
			dataKit.deliver(dataKit.signalsOf(event[2]).OnClientEvent, dataKit.decodeAll(event[3]))
		elseif kind == "RemoteReply" then
			-- ["RemoteReply", call, ok, results | message]
			dataKit.replies[event[2]] = { event[3], event[4] }
		elseif kind == "RemoteInvoke" then
			-- ["RemoteInvoke", remote, "server" | "client", caller, call, arguments]
			local id, side, caller, call, payload = event[2], event[3], event[4], event[5], event[6]
			task.spawn(function()
				local callbacks = dataKit.callbacks[id]
				local callback = callbacks and callbacks[side]
				local waited = 0
				while callback == nil and waited < 30 do
					waited += task.wait()
					callbacks = dataKit.callbacks[id]
					callback = callbacks and callbacks[side]
				end
				if callback == nil then
					invoke("remote.reply", caller, call, false,
						if side == "server" then "OnServerInvoke is not set" else "OnClientInvoke is not set")
					return
				end
				local results
				if side == "server" then
					results = table.pack(pcall(callback, toolKit.playerOf(caller), dataKit.decodeAll(payload)))
				else
					results = table.pack(pcall(callback, dataKit.decodeAll(payload)))
				end
				if results[1] then
					invoke("remote.reply", caller, call, true, dataKit.encodeAll(table.unpack(results, 2, results.n)))
				else
					invoke("remote.reply", caller, call, false, tostring(results[2]))
				end
			end)
		end
	end

	--------------------------------------------------------------------------------
	-- ModuleScripts and require

	dataKit.moduleIdOf = setmetatable({}, { __mode = "k" })
	dataKit.moduleProxies = {}
	dataKit.modules = {}
	dataKit.moduleResults = {}
	dataKit.moduleLoading = {}

	-- The host defines each ModuleScript as a function when the VM starts.
	function __studio_define_module(id, chunk)
		dataKit.modules[id] = chunk
	end

	function dataKit.moduleParent(id)
		return dataKit.wrapPlace(invoke("module.parent", id))
	end

	function dataKit.wrapModule(id)
		if id == nil or invoke("module.name", id) == nil then
			return nil
		end
		local known = dataKit.moduleProxies[id]
		if known ~= nil then
			return known
		end
		local proxy = setmetatable({}, {
			__index = function(_, key)
				if key == "Name" then
					return invoke("module.name", id)
				elseif key == "ClassName" then
					return "ModuleScript"
				elseif key == "Parent" then
					return dataKit.moduleParent(id)
				elseif key == "IsA" then
					return function(_, className)
						return className == "ModuleScript" or className == "LuaSourceContainer" or className == "Instance"
					end
				elseif key == "GetFullName" then
					return function()
						local parent = dataKit.moduleParent(id)
						return (if parent ~= nil and parent ~= workspace_ then tostring(parent) .. "." else "")
							.. invoke("module.name", id)
					end
				elseif key == "FindFirstChild" then
					return function()
						return nil
					end
				elseif key == "GetChildren" then
					return function()
						return {}
					end
				end
				raise(string.format("%s is not a valid member of ModuleScript", tostring(key)), 2)
			end,
			__newindex = function(_, key)
				raise(string.format("Unable to assign property %s of ModuleScript", tostring(key)), 2)
			end,
			__tostring = function()
				return invoke("module.name", id) or "ModuleScript"
			end,
			__metatable = LOCKED,
		})
		typeTags[proxy] = "Instance"
		dataKit.moduleIdOf[proxy] = id
		dataKit.moduleProxies[id] = proxy
		return proxy
	end

	-- Runs a ModuleScript the first time it's required on this machine, and hands every
	-- script that requires it what it returned.
	function require(target)
		local id = dataKit.moduleIdOf[target] or (dataKit.scriptModuleId and dataKit.scriptModuleId(target))
		if id == nil then
			if type(target) == "number" then
				raise("require by asset id isn't supported: require a ModuleScript in the place", 2)
			end
			raise("Attempted to call require with invalid argument(s).", 2)
		end
		-- The server and the clients each run a module for themselves, as in Roblox — on
		-- the host too, where both share this VM.
		local key = (if onServer() then "server:" else "client:") .. id
		local done = dataKit.moduleResults[key]
		if done ~= nil then
			return done.value
		end
		if dataKit.moduleLoading[key] then
			raise("Requested module was required recursively", 2)
		end
		local chunk = dataKit.modules[id]
		if chunk == nil then
			raise("Requested module experienced an error while loading", 2)
		end
		dataKit.moduleLoading[key] = true
		local results = table.pack(pcall(chunk))
		dataKit.moduleLoading[key] = nil
		if not results[1] then
			-- It won't load again; this time, the module's own error.
			dataKit.modules[id] = nil
			error(results[2], 0)
		end
		if results.n ~= 2 then
			dataKit.modules[id] = nil
			raise("Module code did not return exactly one value", 2)
		end
		dataKit.moduleResults[key] = { value = results[2] }
		return results[2]
	end

	--------------------------------------------------------------------------------
	-- ReplicatedStorage and ServerScriptService

	-- `serverOnly`: ServerStorage, which clients see empty.
	local function container(name, token, serverOnly)
		local function hidden()
			return serverOnly and not onServer()
		end
		local function find(key)
			if type(key) ~= "string" or hidden() then
				return nil
			end
			return wrapToken(invoke("data.find", token, key))
		end
		return service(name, nil, {
			GetChildren = function()
				return if hidden() then {} else wrapTokens(invoke("data.children", token))
			end,
			GetDescendants = function(self)
				local list = {}
				for _, child in self:GetChildren() do
					table.insert(list, child)
					if dataKit.idOf[child] ~= nil then
						for _, inner in child:GetDescendants() do
							table.insert(list, inner)
						end
					end
				end
				return list
			end,
			FindFirstChild = function(_, key)
				return find(key)
			end,
			WaitForChild = function(_, key, timeout)
				return dataKit.waitFor(function()
					return find(key)
				end, name, key, timeout)
			end,
			FindFirstChildOfClass = function(self, className)
				for _, child in self:GetChildren() do
					if child.ClassName == className then
						return child
					end
				end
				return nil
			end,
			IsA = function(_, className)
				return className == name or className == "Instance"
			end,
			GetFullName = function()
				return name
			end,
			__child = find,
		})
	end

	dataKit.ReplicatedStorage = container("ReplicatedStorage", "rs")
	dataKit.ServerStorage = container("ServerStorage", "ss", true)
	dataKit.ServerScriptService = container("ServerScriptService", "sss", true)
	services.ReplicatedStorage = dataKit.ReplicatedStorage
	services.ServerStorage = dataKit.ServerStorage
	services.ServerScriptService = dataKit.ServerScriptService

	-- What a Player holds: their Backpack and PlayerGui, and data objects (leaderstats).
	function dataKit.playerChild(number, name)
		if type(name) ~= "string" then
			return nil
		end
		return wrapToken(invoke("data.find", "pl:" .. number, name))
	end

	function dataKit.playerChildren(number)
		return wrapTokens(invoke("data.children", "pl:" .. number))
	end

	function dataKit.waitForPlayerChild(number, name, timeout, fallback)
		return dataKit.waitFor(function()
			return fallback(name) or dataKit.playerChild(number, name)
		end, "Player", name, timeout)
	end

	--------------------------------------------------------------------------------
	-- workspace:Raycast

	local RaycastParamsMeta = {}
	local paramsFields = setmetatable({}, { __mode = "k" })

	RaycastParamsMeta.__index = function(self, key)
		local fields = paramsFields[self]
		if key == "FilterDescendantsInstances" then
			return table.clone(fields.filter)
		elseif key == "FilterType" then
			return Enum.RaycastFilterType[fields.filterType]
		elseif key == "IgnoreWater" or key == "RespectCanCollide" or key == "CollisionGroup" then
			return fields[key]
		elseif key == "AddToFilter" then
			return function(_, value)
				local list = if type(value) == "table" and typeTags[value] == nil then value else { value }
				for _, item in list do
					table.insert(fields.filter, item)
				end
			end
		end
		raise(string.format("%s is not a valid member of RaycastParams", tostring(key)), 2)
	end

	RaycastParamsMeta.__newindex = function(self, key, value)
		local fields = paramsFields[self]
		if key == "FilterDescendantsInstances" then
			if type(value) ~= "table" then
				raise("Unable to assign property FilterDescendantsInstances. table expected, got " .. typeof(value), 2)
			end
			fields.filter = table.clone(value)
		elseif key == "FilterType" then
			local name = enumName(value, "RaycastFilterType")
			if name == nil or rawget(Enum.RaycastFilterType, name) == nil then
				raise("Unable to assign property FilterType. EnumItem expected, got " .. typeof(value), 2)
			end
			fields.filterType = name
		elseif key == "IgnoreWater" or key == "RespectCanCollide" then
			expect(value, "bool", key)
			fields[key] = value
		elseif key == "CollisionGroup" then
			expect(value, "string", key)
			fields[key] = value
		else
			raise(string.format("%s is not a valid member of RaycastParams", tostring(key)), 2)
		end
	end

	RaycastParamsMeta.__tostring = function()
		return "RaycastParams"
	end

	RaycastParamsMeta.__metatable = LOCKED

	RaycastParams = table.freeze({
		new = function()
			local params = setmetatable({}, RaycastParamsMeta)
			typeTags[params] = "RaycastParams"
			paramsFields[params] = { filter = {}, filterType = "Exclude", IgnoreWater = false, RespectCanCollide = false,
				CollisionGroup = "Default" }
			return params
		end,
	})

	local function raycastResult(hit)
		local instance
		local token = hit[1]
		if string.sub(token, 1, 3) == "bp:" then
			local number, name = string.match(token, "^bp:(%d+):(.+)$")
			local record = characterFor(tonumber(number))
			instance = record and record.parts[name]
		else
			instance = wrapToken(token)
		end
		local result = {}
		result.Instance = instance
		result.Position = toVector(hit[2])
		result.Normal = toVector(hit[3])
		result.Distance = hit[4]
		result.Material = Enum.Material[materialFromHost[hit[5]] or "Plastic"]
		typeTags[result] = "RaycastResult"
		return table.freeze(result)
	end

	function workspaceMethods.Raycast(self, origin, direction, params)
		checkSelf(self, "Instance", "Raycast")
		checkOther(origin, "Vector3", "Raycast")
		checkOther(direction, "Vector3", "Raycast")
		local filter, include, respect, ignoreWater = {}, false, false, false
		if params ~= nil then
			if typeTags[params] ~= "RaycastParams" then
				raise("Raycast expects RaycastParams as its third argument, got " .. typeof(params), 2)
			end
			local fields = paramsFields[params]
			include = fields.filterType == "Include" or fields.filterType == "Whitelist"
			respect = fields.RespectCanCollide
			ignoreWater = fields.IgnoreWater
			for _, item in fields.filter do
				if item == workspace_ then
					-- The whole Workspace: included, everything; excluded, nothing.
					if include then
						include, filter = false, {}
						break
					end
					return nil
				end
				local id = partIdOf[item] or groupIdOf[item]
				if id ~= nil then
					table.insert(filter, id)
				elseif isCharacterModel[item] ~= nil then
					table.insert(filter, "ch:" .. isCharacterModel[item])
				end
			end
		end
		local hit = invoke("workspace.raycast", { origin[1], origin[2], origin[3] },
			{ direction[1], direction[2], direction[3] }, filter, include, respect, ignoreWater)
		return if hit ~= nil then raycastResult(hit) else nil
	end
end

"""#
}
