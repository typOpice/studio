// The Luau library, part 14 of 15: TweenService easing, Random and the math extensions.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let extras = #"""
--------------------------------------------------------------------------------
-- The easing curves behind TweenService

-- Easing curves, in one table (the top-level local budget).
local easings = {}
easings.PI = math.pi

function easings.bounceOut(t)
	local n, d = 7.5625, 2.75
	if t < 1 / d then
		return n * t * t
	elseif t < 2 / d then
		t -= 1.5 / d
		return n * t * t + 0.75
	elseif t < 2.5 / d then
		t -= 2.25 / d
		return n * t * t + 0.9375
	end
	t -= 2.625 / d
	return n * t * t + 0.984375
end

-- Every curve written as its "In" form; Out and InOut are derived from it.
easings.easeIn = {
	Linear = function(t) return t end,
	Sine = function(t) return 1 - math.cos(t * easings.PI / 2) end,
	Quad = function(t) return t * t end,
	Cubic = function(t) return t * t * t end,
	Quart = function(t) return t ^ 4 end,
	Quint = function(t) return t ^ 5 end,
	Exponential = function(t) return if t == 0 then 0 else 2 ^ (10 * t - 10) end,
	Circular = function(t) return 1 - math.sqrt(1 - t * t) end,
	Back = function(t) return 2.70158 * t ^ 3 - 1.70158 * t * t end,
	Elastic = function(t)
		if t == 0 or t == 1 then
			return t
		end
		return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * easings.PI / 3))
	end,
	Bounce = function(t) return 1 - easings.bounceOut(1 - t) end,
}

-- Eases 0…1 along a named curve and direction.
function easings.value(alpha, styleName, directionName)
	local curve = easings.easeIn[styleName]
	local t = math.clamp(alpha, 0, 1)
	if styleName == "Linear" then
		return t
	end
	if directionName == "In" then
		return curve(t)
	elseif directionName == "Out" then
		return 1 - curve(1 - t)
	end
	if t < 0.5 then
		return curve(t * 2) / 2
	end
	return 1 - curve(2 - t * 2) / 2
end

--------------------------------------------------------------------------------
-- TweenInfo and TweenService:Create
--
-- Tweens run in the library, not the host: each frame `tweens.step` (called from
-- __studio_tick) writes every running tween's properties through the ordinary
-- property setters, so a tween on a part reaches joined players like any other change.

local tweens = { running = {}, records = setmetatable({}, { __mode = "k" }) }

TweenInfo = table.freeze({
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		local function number(value, default, argument)
			if value == nil then
				return default
			end
			checkNumber(value, argument, "TweenInfo.new")
			return value
		end
		local styleName = if style == nil then "Quad" else enumName(style, "EasingStyle")
		local directionName = if direction == nil then "Out" else enumName(direction, "EasingDirection")
		if styleName == nil then
			raise("TweenInfo.new expects an Enum.EasingStyle as argument 2", 2)
		elseif directionName == nil then
			raise("TweenInfo.new expects an Enum.EasingDirection as argument 3", 2)
		end
		local info = table.freeze({
			Time = math.max(number(time, 1, 1), 0),
			EasingStyle = Enum.EasingStyle[styleName],
			EasingDirection = Enum.EasingDirection[directionName],
			RepeatCount = number(repeatCount, 0, 4),
			Reverses = reverses == true,
			DelayTime = math.max(number(delayTime, 0, 6), 0),
		})
		typeTags[info] = "TweenInfo"
		return info
	end,
})

-- Where a tweened value is `alpha` of the way from `from` to `to`.
function tweens.lerp(from, to, alpha)
	local kind = typeof(from)
	if kind == "number" then
		return from + (to - from) * alpha
	elseif kind == "boolean" then
		return if alpha >= 1 then to else from
	elseif kind == "Vector3" or kind == "Color3" or kind == "CFrame" then
		return from:Lerp(to, alpha)
	elseif kind == "UDim2" then
		return gui.udim2(from[1] + (to[1] - from[1]) * alpha, from[2] + (to[2] - from[2]) * alpha,
			from[3] + (to[3] - from[3]) * alpha, from[4] + (to[4] - from[4]) * alpha)
	elseif kind == "UDim" or kind == "Vector2" then
		local make = if kind == "UDim" then gui.udim else gui.vector2
		return make(from[1] + (to[1] - from[1]) * alpha, from[2] + (to[2] - from[2]) * alpha)
	end
	return to
end

tweens.canTween = { number = true, boolean = true, Vector3 = true, Color3 = true, CFrame = true,
	UDim2 = true, UDim = true, Vector2 = true }

-- Writes where the tween is `elapsed` seconds into a playthrough; false if the
-- instance won't take it (destroyed, say), which ends the tween.
function tweens.apply(record, elapsed)
	local info = record.info
	local t = if info.Time > 0 then elapsed / info.Time else 1
	if info.Reverses and t > 1 then
		t = 2 - t
	end
	local alpha = easings.value(t, info.EasingStyle.Name, info.EasingDirection.Name)
	for property, goal in record.goals do
		local ok = pcall(function()
			record.instance[property] = tweens.lerp(record.starts[property], goal, alpha)
		end)
		if not ok then
			return false
		end
	end
	return true
end

function tweens.finish(record, state)
	tweens.running[record.tween] = nil
	record.state = state
	record.elapsed = 0
	record.phase = nil
	fire(record.completed, Enum.PlaybackState[state])
end

function tweens.step(dt)
	for _, record in table.clone(tweens.running) do
		if tweens.running[record.tween] == nil then
			continue
		end
		local info = record.info
		record.elapsed += dt
		while true do
			if record.phase == "delay" then
				if record.elapsed < info.DelayTime then
					break
				end
				record.elapsed -= info.DelayTime
				record.phase = "run"
				record.state = "Playing"
				if record.starts == nil then
					record.starts = {}
					for property in record.goals do
						record.starts[property] = record.instance[property]
					end
				end
			end
			local length = info.Time * (if info.Reverses then 2 else 1)
			if record.elapsed < length then
				if not tweens.apply(record, record.elapsed) then
					tweens.finish(record, "Cancelled")
				end
				break
			end
			record.cycle += 1
			if info.RepeatCount >= 0 and record.cycle > info.RepeatCount then
				if tweens.apply(record, length) then
					tweens.finish(record, "Completed")
				else
					tweens.finish(record, "Cancelled")
				end
				break
			end
			record.elapsed -= length
			record.phase = "delay"
			if length == 0 and info.DelayTime == 0 then
				-- Endless zero-length repeats would never leave this loop.
				tweens.finish(record, "Completed")
				break
			end
		end
	end
end

function tweens.play(record)
	if record.phase ~= nil and record.state == "Paused" then
		record.state = if record.phase == "delay" then "Delayed" else "Playing"
		tweens.running[record.tween] = record
		return
	end
	-- A tween starting on something another tween is changing takes it over, as in Roblox.
	for other, running in table.clone(tweens.running) do
		if running.instance == record.instance and other ~= record.tween then
			for property in record.goals do
				if running.goals[property] ~= nil then
					tweens.finish(running, "Cancelled")
					break
				end
			end
		end
	end
	record.starts = nil
	record.elapsed = 0
	record.cycle = 0
	record.phase = "delay"
	record.state = if record.info.DelayTime > 0 then "Delayed" else "Playing"
	tweens.running[record.tween] = record
	if record.info.DelayTime == 0 then
		tweens.step(0)
	end
end

TweenService = service("TweenService", nil, {
	GetValue = function(_, alpha, style, direction)
		local styleName = enumName(style, "EasingStyle") or "Quad"
		local directionName = enumName(direction, "EasingDirection") or "Out"
		if easings.easeIn[styleName] == nil then
			raise("GetValue expects an Enum.EasingStyle", 2)
		end
		return easings.value(alpha, styleName, directionName)
	end,
	Create = function(_, instance, info, goals)
		if typeof(instance) ~= "Instance" then
			raise("TweenService:Create expects an Instance, got " .. typeof(instance), 2)
		elseif typeof(info) ~= "TweenInfo" then
			raise("TweenService:Create expects a TweenInfo, got " .. typeof(info), 2)
		elseif type(goals) ~= "table" then
			raise("TweenService:Create expects a table of properties, got " .. typeof(goals), 2)
		end
		local copied = {}
		for property, goal in goals do
			local ok, current = pcall(function()
				return instance[property]
			end)
			if not ok then
				raise(string.format("%s is not a property of %s", tostring(property), tostring(instance)), 2)
			elseif not tweens.canTween[typeof(goal)] or typeof(current) ~= typeof(goal) then
				raise(string.format("Property %s can't be tweened to a %s", tostring(property), typeof(goal)), 2)
			end
			copied[property] = goal
		end
		local record = { instance = instance, info = info, goals = copied, state = "Begin", completed = makeSignal() }
		record.tween = service("Tween", {
			Instance = function()
				return instance
			end,
			TweenInfo = function()
				return info
			end,
			PlaybackState = function()
				return Enum.PlaybackState[record.state]
			end,
			Completed = function()
				return record.completed
			end,
		}, {
			Play = function()
				tweens.play(record)
			end,
			Pause = function()
				if tweens.running[record.tween] ~= nil then
					tweens.running[record.tween] = nil
					record.state = "Paused"
				end
			end,
			Cancel = function()
				if record.phase ~= nil then
					tweens.finish(record, "Cancelled")
				end
			end,
			Destroy = function()
				tweens.running[record.tween] = nil
			end,
			IsA = function(_, className)
				return className == "Tween" or className == "TweenBase" or className == "Instance"
			end,
		})
		tweens.records[record.tween] = record
		return record.tween
	end,
})

--------------------------------------------------------------------------------
-- Sounds: in a part (heard from there) or in SoundService (heard everywhere). Whether
-- one plays is scene data, so the host's are heard by joined players; the play session
-- makes them heard (SoundSystem, in Audio.swift). SoundId names a sound asset,
-- "studio://Name".

soundKit.byId = setmetatable({}, { __mode = "v" })
soundKit.idOf = setmetatable({}, { __mode = "k" })
soundKit.signals = {}
-- Each property: its host name and type, or that scripts only read it.
soundKit.properties = {
	SoundId = { "soundid", "string" },
	Volume = { "volume", "number" },
	Looped = { "looped", "boolean" },
	PlaybackSpeed = { "playbackspeed", "number" },
	RollOffMaxDistance = { "rolloffmaxdistance", "number" },
	TimePosition = { "timeposition", "number" },
	Playing = { "playing", "boolean" },
	IsPlaying = { "isplaying" },
	IsPaused = { "ispaused" },
	IsLoaded = { "isloaded" },
	TimeLength = { "timelength" },
}
soundKit.events = { Played = true, Ended = true, Stopped = true, Paused = true, Resumed = true, Loaded = true }

function soundKit.signal(id, name)
	local byName = soundKit.signals[id]
	if byName == nil then
		byName = {}
		soundKit.signals[id] = byName
	end
	if byName[name] == nil then
		byName[name] = makeSignal()
	end
	return byName[name]
end

function soundKit.fire(id, name)
	local byName = soundKit.signals[id]
	if byName ~= nil and byName[name] ~= nil then
		fire(byName[name], invoke("sound.get", id, "soundid"))
	end
end

function soundKit.setParent(id, value)
	if value == nil then
		invoke("sound.destroy", id)
		soundKit.signals[id] = nil
	elseif value == SoundService or value == workspace_ then
		invoke("sound.parent", id, "g")
	elseif partIdOf[value] ~= nil then
		invoke("sound.parent", id, "p:" .. partIdOf[value])
	else
		raise("A Sound goes in a part, the Workspace or SoundService, not " .. typeof(value), 3)
	end
end

soundKit.methods = {
	Play = function(self)
		local id = soundKit.idOf[self]
		invoke("sound.play", id)
		soundKit.fire(id, "Played")
	end,
	Stop = function(self)
		local id = soundKit.idOf[self]
		invoke("sound.stop", id)
		soundKit.fire(id, "Stopped")
	end,
	Pause = function(self)
		local id = soundKit.idOf[self]
		invoke("sound.pause", id)
		soundKit.fire(id, "Paused")
	end,
	Resume = function(self)
		local id = soundKit.idOf[self]
		invoke("sound.resume", id)
		soundKit.fire(id, "Resumed")
	end,
	Destroy = function(self)
		soundKit.setParent(soundKit.idOf[self], nil)
	end,
	IsA = function(_, className)
		return className == "Sound" or className == "Instance"
	end,
}

soundKit.Meta = {
	__index = function(object, key)
		local id = soundKit.idOf[object]
		if key == "Name" then
			return invoke("sound.get", id, "name")
		elseif key == "ClassName" then
			return "Sound"
		elseif key == "Parent" then
			local parent = invoke("sound.get", id, "parent")
			if parent == "g" then
				return SoundService
			end
			return wrapToken(parent)
		end
		local property = soundKit.properties[key]
		if property ~= nil then
			return invoke("sound.get", id, property[1])
		elseif soundKit.events[key] then
			return soundKit.signal(id, key)
		end
		local method = soundKit.methods[key]
		if method ~= nil then
			return method
		end
		raise(string.format("%s is not a valid member of Sound", tostring(key)), 2)
	end,
	__newindex = function(object, key, value)
		local id = soundKit.idOf[object]
		if key == "Parent" then
			soundKit.setParent(id, value)
			return
		elseif key == "Name" then
			if type(value) ~= "string" then
				raise("Unable to assign property Name. string expected, got " .. typeof(value), 2)
			end
			invoke("sound.set", id, "name", value)
			return
		end
		local property = soundKit.properties[key]
		if property == nil then
			raise(string.format("%s is not a valid member of Sound", tostring(key)), 2)
		elseif property[2] == nil then
			raise(string.format("Unable to assign property %s. Property is read only", key), 2)
		elseif type(value) ~= property[2] then
			raise(string.format("Unable to assign property %s. %s expected, got %s", key, property[2], typeof(value)), 2)
		end
		invoke("sound.set", id, property[1], value)
		if key == "Playing" then
			soundKit.fire(id, if value then "Resumed" else "Paused")
		end
	end,
	__tostring = function(object)
		return invoke("sound.get", soundKit.idOf[object], "name") or "Sound"
	end,
	__metatable = LOCKED,
}

function soundKit.wrap(id)
	if id == nil then
		return nil
	end
	local existing = soundKit.byId[id]
	if existing ~= nil then
		return existing
	end
	local object = setmetatable({}, soundKit.Meta)
	typeTags[object] = "Instance"
	soundKit.byId[id] = object
	soundKit.idOf[object] = id
	return object
end

function soundKit.new(parent)
	local token = if parent ~= nil and partIdOf[parent] ~= nil then "p:" .. partIdOf[parent] else nil
	if parent ~= nil and token == nil and parent ~= SoundService and parent ~= workspace_ then
		raise("A Sound goes in a part, the Workspace or SoundService, not " .. typeof(parent), 3)
	end
	return soundKit.wrap(invoke("sound.create", token, inLocalScript()))
end

function soundKit.list()
	local list = {}
	for _, id in invoke("sound.list", nil) do
		table.insert(list, soundKit.wrap(id))
	end
	return list
end

-- SoundService: the Sounds heard everywhere.
SoundService = service("SoundService", nil, {
	GetChildren = function()
		return soundKit.list()
	end,
	FindFirstChild = function(_, name)
		for _, sound in soundKit.list() do
			if sound.Name == name then
				return sound
			end
		end
		return nil
	end,
	WaitForChild = function(self, name)
		return self:FindFirstChild(name)
	end,
	PlayLocalSound = function(_, sound)
		sound:Play()
	end,
	IsA = function(_, className)
		return className == "SoundService" or className == "Instance"
	end,
	__child = function(key)
		for _, sound in soundKit.list() do
			if sound.Name == key then
				return sound
			end
		end
		return nil
	end,
})

--------------------------------------------------------------------------------
-- LogService: what scripts print, warn and error, as the Output shows it —
-- MessageOut with each new line (the frame after), GetLogHistory for those so far.

logKit.messageOut = makeSignal()

function logKit.fire(message, messageType)
	fire(logKit.messageOut, message, Enum.MessageType[messageType])
end

LogService = service("LogService", {
	MessageOut = function()
		return logKit.messageOut
	end,
}, {
	GetLogHistory = function()
		local history = {}
		for _, entry in invoke("log.history") do
			table.insert(history, table.freeze({
				message = entry[1],
				messageType = Enum.MessageType[entry[2]],
				timestamp = entry[3],
			}))
		end
		return history
	end,
	IsA = function(_, className)
		return className == "LogService" or className == "Instance"
	end,
})

--------------------------------------------------------------------------------
-- game

local services = {
	Workspace = workspace_,
	RunService = RunService,
	Players = Players,
	UserInputService = UserInputService,
	TweenService = TweenService,
	Shaders = Shaders,
	Animations = Animations,
	Lighting = Lighting,
	TextChatService = TextChatService,
	StarterPack = StarterPack,
	SoundService = SoundService,
	LogService = LogService,
}

game = service("Game", nil, {
	GetService = function(_, name)
		local found = services[name]
		if found == nil then
			raise(string.format("'%s' is not a valid Service name", tostring(name)), 2)
		end
		return found
	end,
	__child = function(key)
		return services[key]
	end,
})

--------------------------------------------------------------------------------
-- Random: seeded and repeatable, with Roblox's method names

-- Random's internals, in one table (the top-level local budget).
local randoms = {}
randoms.RandomMeta = {}
randoms.randomState = setmetatable({}, { __mode = "k" })

-- A 32-bit linear congruential generator, exact in doubles, so the same seed gives
-- the same numbers on every machine.
function randoms.nextUnit(generator)
	local state = (1664525 * randoms.randomState[generator] + 1013904223) % 4294967296
	randoms.randomState[generator] = state
	return state / 4294967296
end

randoms.randomMethods = {}

function randoms.randomMethods.NextNumber(self, low, high)
	checkSelf(self, "Random", "NextNumber")
	low = low or 0
	high = high or 1
	return low + randoms.nextUnit(self) * (high - low)
end

-- Both ends inclusive, as Roblox's is.
function randoms.randomMethods.NextInteger(self, low, high)
	checkSelf(self, "Random", "NextInteger")
	if high < low then
		raise("invalid argument #2 to 'NextInteger' (max must be greater than or equal to min)", 2)
	end
	return low + math.floor(randoms.nextUnit(self) * (high - low + 1))
end

-- A direction spread evenly over a sphere rather than bunched at the poles.
function randoms.randomMethods.NextUnitVector(self)
	checkSelf(self, "Random", "NextUnitVector")
	local z = randoms.nextUnit(self) * 2 - 1
	local angle = randoms.nextUnit(self) * 2 * easings.PI
	local radius = math.sqrt(1 - z * z)
	return vector(radius * math.cos(angle), radius * math.sin(angle), z)
end

function randoms.randomMethods.Shuffle(self, list)
	checkSelf(self, "Random", "Shuffle")
	for index = #list, 2, -1 do
		local other = math.floor(randoms.nextUnit(self) * index) + 1
		list[index], list[other] = list[other], list[index]
	end
end

function randoms.randomMethods.Clone(self)
	checkSelf(self, "Random", "Clone")
	local copy = setmetatable({}, randoms.RandomMeta)
	typeTags[copy] = "Random"
	randoms.randomState[copy] = randoms.randomState[self]
	return copy
end

randoms.RandomMeta.__index = function(_, key)
	local method = randoms.randomMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of Random", tostring(key)), 2)
end

randoms.RandomMeta.__metatable = LOCKED

Random = table.freeze({
	new = function(seed)
		local generator = setmetatable({}, randoms.RandomMeta)
		typeTags[generator] = "Random"
		local start = seed or (os.time() + os.clock() * 1000000)
		local state = math.floor(math.abs(start)) % 4294967296
		randoms.randomState[generator] = if state == 0 then 1 else state
		return generator
	end,
})

--------------------------------------------------------------------------------
-- math: the helpers building things needs, next to Luau's own clamp, sign, round
-- and noise. `lerp` and `map` use the names and meaning Luau itself has adopted.

function math.lerp(a, b, t)
	return a + (b - a) * t
end

function math.inverseLerp(a, b, value)
	if math.abs(b - a) < 1e-12 then
		return 0
	end
	return (value - a) / (b - a)
end

function math.map(value, fromLow, fromHigh, toLow, toHigh)
	return toLow + (toHigh - toLow) * math.inverseLerp(fromLow, fromHigh, value)
end

function math.smoothstep(edge0, edge1, value)
	local t = math.clamp(math.inverseLerp(edge0, edge1, value), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Always positive, unlike %, which can go negative for negative lengths.
function math.wrap(value, length)
	if length == 0 then
		return 0
	end
	return value - math.floor(value / length) * length
end

function math.pingPong(value, length)
	if length == 0 then
		return 0
	end
	local t = math.wrap(value, length * 2)
	return length - math.abs(t - length)
end

function math.moveTowards(current, target, maxDelta)
	local delta = target - current
	if math.abs(delta) <= maxDelta then
		return target
	end
	return current + math.sign(delta) * maxDelta
end

-- Rounds to the nearest multiple of step — the same snapping the gizmos use.
function math.snap(value, step)
	if step <= 0 then
		return value
	end
	return math.round(value / step) * step
end

-- Folds an angle in degrees into -180..180.
function math.wrapAngle(degrees)
	return math.wrap(degrees + 180, 360) - 180
end

-- The shortest signed turn between two angles, in degrees: 350 → 10 is 20, not -340.
function math.deltaAngle(from, to)
	return math.wrapAngle(to - from)
end

function math.moveTowardsAngle(current, target, maxDelta)
	local delta = math.deltaAngle(current, target)
	if math.abs(delta) <= maxDelta then
		return target
	end
	return current + math.sign(delta) * maxDelta
end

-- Several octaves of math.noise stacked: large shapes plus fine detail.
function math.fbm(x, y, z, octaves)
	octaves = octaves or 4
	local total, amplitude, frequency, weight = 0, 1, 1, 0
	for _ = 1, octaves do
		total += math.noise(x * frequency, (y or 0) * frequency, (z or 0) * frequency) * amplitude
		weight += amplitude
		amplitude *= 0.5
		frequency *= 2
	end
	return if weight == 0 then 0 else total / weight
end

"""#
}
