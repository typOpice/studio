// The Luau library, part 8 of 16: task, RunService and events.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let scheduler = #"""
--------------------------------------------------------------------------------
-- The scheduler: task, and the events RunService fires

local clock = 0
local sleeping = {}
local threadOwner = setmetatable({}, { __mode = "k" })

-- Scopes: 0 for everything that lives as long as the session, or a character's
-- generation for everything that character's scripts started. A thread keeps its
-- scope, threads it starts inherit it, and connections remember it — so when a
-- character goes, `__studio_kill_scope` can stop exactly what belonged to it.
local threadScope = setmetatable({}, { __mode = "k" })
local spawnScope = 0
-- Threads a LocalScript started (StarterPlayer, StarterCharacter, StarterGui): what
-- they make of their own — a Sound, say — stays on this machine. Carried like scopes.
local threadLocal = setmetatable({}, { __mode = "k" })
local spawnLocal = false
local allSignals = setmetatable({}, { __mode = "k" })

local function currentScope()
	return threadScope[coroutine.running()] or 0
end

local function adopt(thread, scope)
	if threadScope[thread] == nil then
		threadScope[thread] = scope
		threadLocal[thread] = threadLocal[coroutine.running()]
	end
	return thread
end

local function inLocalScript()
	return threadLocal[coroutine.running()] == true
end

local function report(message, thread)
	local trace = ""
	if thread ~= nil then
		trace = debug.traceback(thread) or ""
	end
	invoke("runtime.error", tostring(message), trace)
end

-- task.defer's threads: run once the code running now is done — when the outermost
-- resume returns, in the same frame, as in Roblox — oldest first, with any they defer.
local deferring = { queue = {}, depth = 0, draining = false }
local runDeferred

-- Every resume gets its own time budget from the watchdog. A thread closed while it
-- waited (task.cancel, coroutine.close) is left alone, wherever it was waiting.
local function resumeThread(thread, ...)
	if coroutine.status(thread) == "dead" then
		return false
	end
	arm()
	deferring.depth += 1
	local ok, problem = coroutine.resume(thread, ...)
	deferring.depth -= 1
	if not ok then
		report(problem, thread)
		local owner = threadOwner[thread]
		if owner ~= nil and owner.Connected then
			owner.Connected = false
			invoke("runtime.warn", "A connected function errored and was disconnected")
		end
	end
	if deferring.depth == 0 and not deferring.draining then
		runDeferred()
	end
	return ok
end

-- Up to ten thousand a time, so a thread that defers itself forever can't stall the
-- game: the rest wait for the next resume, or the end of the frame.
runDeferred = function()
	deferring.draining = true
	local head, ran = 1, 0
	while head <= #deferring.queue and ran < 10000 do
		local entry = deferring.queue[head]
		head += 1
		ran += 1
		resumeThread(entry.thread, table.unpack(entry.arguments, 1, entry.arguments.n))
	end
	local rest = {}
	for index = head, #deferring.queue do
		table.insert(rest, deferring.queue[index])
	end
	deferring.queue = rest
	deferring.draining = false
end

-- What task's functions take, checked as Roblox checks it.
local function taskThread(value, functionName, position)
	if type(value) == "function" then
		return coroutine.create(value)
	elseif type(value) == "thread" then
		return value
	end
	raise(string.format("invalid argument #%d to '%s' (function or thread expected, got %s)",
		position, functionName, typeof(value)), 3)
end

local function taskSeconds(value, functionName, position)
	if value == nil then
		return 0
	elseif type(value) ~= "number" then
		raise(string.format("invalid argument #%d to '%s' (number expected, got %s)",
			position, functionName, typeof(value)), 3)
	end
	return if value > 0 then value else 0
end

local function checkYieldable(functionName)
	if not coroutine.isyieldable() then
		raise(functionName .. " can only be called from a script, not from a metamethod or callback", 3)
	end
end

task = table.freeze({
	wait = function(seconds)
		seconds = taskSeconds(seconds, "wait", 1)
		checkYieldable("task.wait")
		local thread = coroutine.running()
		table.insert(sleeping, {
			thread = thread,
			wakeAt = clock + seconds,
			startedAt = clock,
			scope = threadScope[thread] or 0,
		})
		return coroutine.yield()
	end,

	spawn = function(callback, ...)
		local thread = taskThread(callback, "spawn", 1)
		if coroutine.status(thread) == "dead" then
			raise("cannot resume dead coroutine", 2)
		end
		adopt(thread, currentScope())
		resumeThread(thread, ...)
		return thread
	end,

	delay = function(seconds, callback, ...)
		seconds = taskSeconds(seconds, "delay", 1)
		local thread = taskThread(callback, "delay", 2)
		local scope = threadScope[adopt(thread, currentScope())]
		table.insert(sleeping, {
			thread = thread,
			wakeAt = clock + seconds,
			startedAt = clock,
			arguments = table.pack(...),
			scope = scope,
		})
		return thread
	end,

	defer = function(callback, ...)
		local thread = taskThread(callback, "defer", 1)
		local scope = threadScope[adopt(thread, currentScope())]
		table.insert(deferring.queue, { thread = thread, arguments = table.pack(...), scope = scope })
		return thread
	end,

	-- Stops a thread for good, wherever it waits: task.wait, delay, defer, or an
	-- event's Wait. A thread can't cancel itself, or one waiting on it to return.
	cancel = function(thread)
		if type(thread) ~= "thread" then
			raise("invalid argument #1 to 'cancel' (thread expected, got " .. typeof(thread) .. ")", 2)
		end
		local status = coroutine.status(thread)
		if status == "running" or status == "normal" then
			raise("task.cancel can't cancel a thread that is running; return from it instead", 2)
		end
		for index = #sleeping, 1, -1 do
			if sleeping[index].thread == thread then
				table.remove(sleeping, index)
			end
		end
		for signal in allSignals do
			for index = #signal.waiting, 1, -1 do
				if signal.waiting[index] == thread then
					table.remove(signal.waiting, index)
				end
			end
		end
		if status == "suspended" then
			coroutine.close(thread)
		end
	end,

	-- Parallel Luau runs scripts under Actors, and there are none: everything runs in
	-- series, so these carry straight on.
	synchronize = function()
		checkYieldable("task.synchronize")
	end,
	desynchronize = function()
		checkYieldable("task.desynchronize")
	end,
})

-- The deprecated globals still turn up in every older tutorial, and behave as Roblox's
-- still do: wait and delay never less than a thirtieth of a second, wait returning the
-- game time as well, spawn starting its function a frame later rather than now.
wait = function(seconds)
	seconds = taskSeconds(seconds, "wait", 1)
	checkYieldable("wait")
	local elapsed = task.wait(math.max(seconds, 1 / 30))
	return elapsed, clock
end
spawn = function(callback)
	task.delay(0, taskThread(callback, "spawn", 1))
end
delay = function(seconds, callback)
	seconds = taskSeconds(seconds, "delay", 1)
	task.delay(math.max(seconds, 1 / 30), taskThread(callback, "delay", 2))
end

-- Seconds the game has been running.
time = function()
	return clock
end

-- Events

local ConnectionMeta = {
	__index = {
		Disconnect = function(self)
			self.Connected = false
		end,
	},
	__metatable = LOCKED,
}

local SignalMeta = {}
local signalMethods = {}

function signalMethods.Connect(self, callback)
	if type(callback) ~= "function" then
		raise("Attempt to connect failed: Passed value is not a function", 2)
	end
	local connection = setmetatable(
		{ Connected = true, callback = callback, scope = currentScope(), isLocal = inLocalScript() },
		ConnectionMeta
	)
	table.insert(self.connections, connection)
	return connection
end

function signalMethods.Once(self, callback)
	local connection = signalMethods.Connect(self, callback)
	connection.once = true
	return connection
end

function signalMethods.Wait(self)
	checkYieldable("Wait")
	table.insert(self.waiting, coroutine.running())
	return coroutine.yield()
end

SignalMeta.__index = function(_, key)
	local method = signalMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of RBXScriptSignal", tostring(key)), 2)
end

SignalMeta.__metatable = LOCKED

local function makeSignal()
	local signal = setmetatable({ connections = {}, waiting = {} }, SignalMeta)
	typeTags[signal] = "RBXScriptSignal"
	allSignals[signal] = true
	return signal
end

-- Each handler runs in its own thread, as in Roblox, so it may call task.wait.
local function fire(signal, ...)
	local live = {}
	for _, connection in signal.connections do
		if connection.Connected then
			table.insert(live, connection)
		end
	end
	signal.connections = live

	for _, connection in table.clone(live) do
		if connection.Connected then
			if connection.once then
				connection.Connected = false
			end
			local thread = coroutine.create(connection.callback)
			threadOwner[thread] = connection
			threadScope[thread] = connection.scope
			threadLocal[thread] = connection.isLocal
			resumeThread(thread, ...)
		end
	end

	local waiting = signal.waiting
	signal.waiting = {}
	for _, thread in waiting do
		resumeThread(thread, ...)
	end
end

local heartbeat = makeSignal()
local stepped = makeSignal()
local renderStepped = makeSignal()

RunService = service("RunService", {
	Heartbeat = function()
		return heartbeat
	end,
	Stepped = function()
		return stepped
	end,
	RenderStepped = function()
		return renderStepped
	end,
})

"""#
}
