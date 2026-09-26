// The Luau library, part 16 of 16: the entry points the host calls.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let entryPoints = #"""
--------------------------------------------------------------------------------
-- Host entry points

local ScriptMeta = {}
local scriptIdOf = setmetatable({}, { __mode = "k" })
local scriptScopeOf = setmetatable({}, { __mode = "k" })

ScriptMeta.__index = function(object, key)
	local id = scriptIdOf[object]
	if key == "Name" then
		return invoke("script.get", id, "name")
	elseif key == "ClassName" then
		return invoke("script.get", id, "class") or "Script"
	elseif key == "Parent" and invoke("script.get", id, "class") == "ModuleScript" then
		return dataKit.moduleParent(id)
	elseif key == "Parent" then
		-- A script in something (a Tool from StarterPack, say) is in it; the
		-- StarterCharacterScripts live inside their character, as in Roblox.
		local parent = invoke("tree.scriptParent", id)
		local scope = scriptScopeOf[object]
		if parent == nil and scope ~= nil and scope > 0 then
			local record = characterFor(scope)
			return record and record.model
		end
		-- A LocalScript from StarterGui: in this player's copy of its GUI.
		if type(parent) == "string" and string.sub(parent, 1, 2) == "u:" then
			return gui.wrap(tonumber(string.sub(parent, 3)))
		end
		return wrapToken(parent)
	elseif key == "IsA" then
		return function(_, className)
			local class = invoke("script.get", id, "class") or "Script"
			if class == "ModuleScript" then
				return className == class or className == "LuaSourceContainer" or className == "Instance"
			end
			return className == class or className == "BaseScript" or className == "LuaSourceContainer"
				or className == "Instance"
		end
	end
	raise(string.format("%s is not a valid member of Script", tostring(key)), 2)
end

ScriptMeta.__newindex = function(_, key)
	raise(string.format("Unable to assign property %s of Script", tostring(key)), 2)
end

ScriptMeta.__tostring = function(object)
	return invoke("script.get", scriptIdOf[object], "name") or "Script"
end

ScriptMeta.__metatable = LOCKED

-- `require(script)` inside a ModuleScript, or of a module's own `script`.
function dataKit.scriptModuleId(object)
	local id = scriptIdOf[object]
	return if id ~= nil and invoke("script.get", id, "class") == "ModuleScript" then id else nil
end

local sharedTable = {}
local globalTable = {}

-- Each script gets its own `script`, and sees the same `shared` and `_G`.
function __studio_env_setup(id, scope)
	local object = setmetatable({}, ScriptMeta)
	scriptIdOf[object] = id
	scriptScopeOf[object] = scope or 0
	typeTags[object] = "Instance"
	return object, sharedTable, globalTable
end

-- Runs a script's top level inside a thread, so it may task.wait from the start.
function __studio_spawn(chunk)
	local thread = coroutine.create(chunk)
	threadScope[thread] = spawnScope
	threadLocal[thread] = spawnLocal
	return resumeThread(thread)
end

-- The host sets the scope for the scripts it is about to spawn.
function __studio_set_spawn_scope(scope)
	spawnScope = scope
end

-- …and whether they are LocalScripts (1) or not (0).
function __studio_set_spawn_local(flag)
	spawnLocal = flag == 1
end

-- Stops everything a scope started: its connections, its waits, its threads.
-- Called by the host when a character is replaced.
function __studio_kill_scope(scope)
	for signal in allSignals do
		for _, connection in signal.connections do
			if connection.scope == scope then
				connection.Connected = false
			end
		end
		local keep = {}
		for _, thread in signal.waiting do
			if threadScope[thread] == scope then
				pcall(coroutine.close, thread)
			else
				table.insert(keep, thread)
			end
		end
		signal.waiting = keep
	end
	for index = #sleeping, 1, -1 do
		local entry = sleeping[index]
		if entry.scope == scope then
			table.remove(sleeping, index)
			pcall(coroutine.close, entry.thread)
		end
	end
	for index = #deferring.queue, 1, -1 do
		local entry = deferring.queue[index]
		if entry.scope == scope then
			table.remove(deferring.queue, index)
			pcall(coroutine.close, entry.thread)
		end
	end
	characters[scope] = nil
	for handle, record in tracks do
		if record.generation == scope then
			tracks[handle] = nil
		end
	end
end

-- Called by the host once per frame.
function __studio_tick(dt)
	clock += dt
	for _, event in invoke("player.events") do
		dispatch(event)
	end
	fire(renderStepped, dt)
	fire(stepped, clock, dt)
	tweens.step(dt)
	fire(heartbeat, dt)

	-- Those due wake soonest-due first, and those due together in the order they
	-- went to sleep, as in Roblox.
	local due, still = {}, {}
	for _, entry in sleeping do
		table.insert(if entry.wakeAt <= clock then due else still, entry)
	end
	sleeping = still
	for position, entry in due do
		entry.position = position
	end
	table.sort(due, function(a, b)
		if a.wakeAt ~= b.wakeAt then
			return a.wakeAt < b.wakeAt
		end
		return a.position < b.position
	end)
	for _, entry in due do
		if entry.arguments ~= nil then
			resumeThread(entry.thread, table.unpack(entry.arguments, 1, entry.arguments.n))
		else
			resumeThread(entry.thread, clock - entry.startedAt)
		end
	end
	-- Anything deferred outside a thread (a property setter, a tween) runs now.
	if not deferring.draining then
		runDeferred()
	end
end

table.freeze(Vector3Meta)
table.freeze(Color3Meta)
table.freeze(EnumItemMeta)
table.freeze(PartMeta)
table.freeze(ShaderMeta)
table.freeze(ScriptMeta)
table.freeze(SignalMeta)
table.freeze(randoms.RandomMeta)
"""#
}
