// The Luau library, part 11 of 15: Animations and AnimationTracks.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let animations = #"""
--------------------------------------------------------------------------------
-- Animations (made in the Animation Editor) and AnimationTracks
--
-- An Animation names one; the Animations service holds every one in the scene.
-- `Animator:LoadAnimation` makes an AnimationTrack for one character, addressed by
-- the handle the host gives it.

local AnimationMeta = {}
local animationData = setmetatable({}, { __mode = "k" })
local animationForId = setmetatable({}, { __mode = "v" })

local function wrapAnimation(id)
	if id == nil then
		return nil
	end
	local existing = animationForId[id]
	if existing ~= nil then
		return existing
	end
	local object = setmetatable({}, AnimationMeta)
	animationData[object] = { id = id }
	animationForId[id] = object
	typeTags[object] = "Instance"
	return object
end

newAnimation = function()
	local object = setmetatable({}, AnimationMeta)
	animationData[object] = { name = "Animation", assigned = "" }
	typeTags[object] = "Instance"
	return object
end

-- What the host looks the animation up by: its id, or the name a script assigned.
local function animationKey(object)
	local data = animationData[object]
	return data and (data.id or data.assigned)
end

AnimationMeta.__index = function(object, key)
	local data = animationData[object]
	if key == "ClassName" then
		return "Animation"
	elseif key == "Name" then
		return if data.id then invoke("animation.get", data.id, "name") or "Animation" else data.name
	elseif key == "AnimationId" then
		return if data.id then invoke("animation.get", data.id, "name") or "" else data.assigned
	elseif key == "Parent" then
		return if data.id and invoke("animation.get", data.id, "name") then Animations else nil
	elseif key == "IsA" then
		return function(_, className)
			return className == "Animation" or className == "Instance"
		end
	end
	raise(string.format("%s is not a valid member of Animation", tostring(key)), 2)
end

AnimationMeta.__newindex = function(object, key, value)
	local data = animationData[object]
	if data.id ~= nil then
		raise(string.format("Unable to assign property %s. Animations made in the Animation Editor are edited there", tostring(key)), 2)
	end
	if key == "AnimationId" or key == "Name" then
		if type(value) ~= "string" then
			raise(string.format("Unable to assign property %s. string expected, got %s", key, typeof(value)), 2)
		end
		if key == "AnimationId" then
			data.assigned = value
		else
			data.name = value
		end
		return
	end
	raise(string.format("%s is not a valid member of Animation", tostring(key)), 2)
end

AnimationMeta.__tostring = function(object)
	return object.Name
end

AnimationMeta.__metatable = LOCKED

local animationsMethods = {}

function animationsMethods.FindFirstChild(_, name)
	if type(name) ~= "string" then
		return nil
	end
	return wrapAnimation(invoke("animation.find", name))
end

function animationsMethods.WaitForChild(self, name)
	local found = animationsMethods.FindFirstChild(self, name)
	if found == nil then
		warn(string.format("Infinite yield possible on 'Animations:WaitForChild(\"%s\")'", tostring(name)))
	end
	return found
end

function animationsMethods.GetChildren()
	local children = {}
	for index, id in invoke("animation.ids") do
		children[index] = wrapAnimation(id)
	end
	return children
end

function animationsMethods.IsA(_, className)
	return className == "Animations" or className == "Instance"
end

function animationsMethods.__child(key)
	if type(key) ~= "string" then
		return nil
	end
	return wrapAnimation(invoke("animation.find", key))
end

Animations = service("Animations", nil, animationsMethods)

-- AnimationTracks, by host handle.
local tracks = {}

local trackProperties = {
	IsPlaying = { host = "isplaying" },
	Length = { host = "length" },
	Looped = { host = "looped", kind = "bool" },
	Speed = { host = "speed" },
	TimePosition = { host = "timeposition", kind = "number" },
	WeightCurrent = { host = "weightcurrent" },
	WeightTarget = { host = "weighttarget" },
	Name = { host = "name" },
}

local function makeTrack(handle, generation, animation)
	local record = {
		handle = handle,
		generation = generation,
		signals = { Stopped = makeSignal(), DidLoop = makeSignal(), KeyframeReached = makeSignal(), Ended = makeSignal() },
		markers = {},
	}
	local methods = {}
	local track = setmetatable({}, {
		__index = function(_, key)
			local property = trackProperties[key]
			if property ~= nil then
				local value = invoke("track.get", handle, property.host)
				if value == nil then
					-- The character it belonged to has gone.
					if key == "IsPlaying" or key == "Looped" then return false end
					if key == "Name" then return animation.Name end
					return 0
				end
				return value
			end
			if key == "ClassName" then
				return "AnimationTrack"
			elseif key == "Animation" then
				return animation
			elseif key == "Priority" then
				local name = invoke("track.get", handle, "priority")
				return Enum.AnimationPriority[name or "Action"]
			end
			local signal = record.signals[key]
			if signal ~= nil then
				return signal
			end
			local method = methods[key]
			if method ~= nil then
				return method
			end
			raise(string.format("%s is not a valid member of AnimationTrack", tostring(key)), 2)
		end,
		__newindex = function(_, key, value)
			if key == "Priority" then
				local name = enumName(value, "AnimationPriority")
				if name == nil then
					raise("Unable to assign property Priority. EnumItem expected, got " .. typeof(value), 2)
				end
				invoke("track.set", handle, "priority", name)
				return
			end
			local property = trackProperties[key]
			if property == nil or property.kind == nil then
				if property ~= nil then
					raise(string.format("Unable to assign property %s. Property is read only", key), 2)
				end
				raise(string.format("%s is not a valid member of AnimationTrack", tostring(key)), 2)
			end
			expect(value, property.kind, key)
			invoke("track.set", handle, property.host, value)
		end,
		__tostring = function()
			return animation.Name
		end,
		__metatable = LOCKED,
	})
	typeTags[track] = "Instance"
	record.object = track

	local function optionalNumber(value, name)
		if value ~= nil and type(value) ~= "number" then
			raise(string.format("%s must be a number, got %s", name, typeof(value)), 3)
		end
		return value
	end

	function methods.Play(self, fadeTime, weight, speed)
		checkSelf(self, "Instance", "Play")
		invoke("track.play", handle, optionalNumber(fadeTime, "fadeTime") or 0.1,
			optionalNumber(weight, "weight") or 1, optionalNumber(speed, "speed") or 1)
	end

	function methods.Stop(self, fadeTime)
		checkSelf(self, "Instance", "Stop")
		invoke("track.stop", handle, optionalNumber(fadeTime, "fadeTime") or 0.1)
	end

	function methods.AdjustSpeed(self, speed)
		checkSelf(self, "Instance", "AdjustSpeed")
		invoke("track.set", handle, "speed", optionalNumber(speed, "speed") or 1)
	end

	function methods.AdjustWeight(self, weight, fadeTime)
		checkSelf(self, "Instance", "AdjustWeight")
		invoke("track.set", handle, "weight", optionalNumber(weight, "weight") or 1,
			optionalNumber(fadeTime, "fadeTime") or 0.1)
	end

	function methods.GetMarkerReachedSignal(self, name)
		checkSelf(self, "Instance", "GetMarkerReachedSignal")
		if type(name) ~= "string" then
			raise("GetMarkerReachedSignal expects a marker name", 2)
		end
		local signal = record.markers[name]
		if signal == nil then
			signal = makeSignal()
			record.markers[name] = signal
		end
		return signal
	end

	function methods.IsA(_, className)
		return className == "AnimationTrack" or className == "Instance"
	end

	tracks[handle] = record
	return track
end

loadTrack = function(generation, animation)
	local key = animationData[animation] and animationKey(animation)
	if key == nil then
		raise("LoadAnimation requires an Animation object", 3)
	end
	if key == "" then
		raise("LoadAnimation: the Animation has no AnimationId", 3)
	end
	local handle = invoke("track.load", generation, key)
	if handle == nil then
		if generation ~= currentGeneration() then
			raise("LoadAnimation: this character is no longer in the game", 3)
		end
		raise(string.format("LoadAnimation: no animation named \"%s\" in Animations", tostring(animation.AnimationId)), 3)
	end
	return makeTrack(handle, generation, animation)
end

playingTracks = function(generation)
	-- Another player's character: the tracks this game's scripts play on it.
	if generation ~= currentGeneration() and not invoke("character.alive", generation) then
		return {}
	end
	local list = {}
	for _, handle in invoke("track.playing", generation) do
		local record = tracks[handle]
		if record ~= nil then
			table.insert(list, record.object)
		end
	end
	return list
end

"""#
}
