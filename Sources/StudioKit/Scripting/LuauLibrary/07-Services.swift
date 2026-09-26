// The Luau library, part 7 of 16: Instance.new, the services, the screen and Lighting.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let services = #"""
--------------------------------------------------------------------------------
-- Instance.new

-- An Animation made by Instance.new; assigned once Animation objects exist.
local newAnimation

-- The screen's GUI objects and chat, filled in by the GUI part: one table, declared here
-- so Instance.new can make them.
local gui = {}
-- Accessories, Shirt, Pants and HumanoidDescription, filled in by the player part.
local avatarKit = {}

Instance = table.freeze({
	new = function(className, parent)
		if gui.classes ~= nil and gui.classes[className] then
			return gui.new(className, parent)
		end
		if className == "Animation" then
			return newAnimation()
		end
		if avatarKit.classes ~= nil and avatarKit.classes[className] then
			return avatarKit.new(className, parent)
		end
		if dataKit.classes ~= nil and dataKit.classes[className] then
			return dataKit.new(className, parent)
		end
		if className == "Attachment" then
			local partId = if parent ~= nil then partIdOf[parent] else nil
			if partId == nil then
				raise("Instance.new(\"Attachment\") needs a Part as its parent", 2)
			end
			return wrapAttachment(invoke("attachment.create", partId))
		end
		if constraintKit.constraintMembers[className] ~= nil then
			local constraint = wrapConstraint(invoke("constraint.create", className))
			if parent ~= nil then
				constraint.Parent = parent
			end
			return constraint
		end
		if className == "Model" or className == "Folder" or className == "Tool" then
			local group = wrapGroup(invoke("group.create", className))
			if parent ~= nil then
				group.Parent = parent
			end
			return group
		end
		if className == "Sound" then
			return soundKit.new(parent)
		end
		if className == "ClickDetector" then
			local detector = mouseKit.newDetector()
			if parent ~= nil then
				mouseKit.parentDetector(detector, parent)
			end
			return detector
		end
		if className == "PointLight" then
			local light = lights.newPointLight()
			if parent ~= nil then
				lights.parentLight(light, parent)
			end
			return light
		end
		local shape
		if className == "Part" or className == "Seat" or className == "MeshPart" then
			shape = "block"
		elseif className == "WedgePart" then
			shape = "wedge"
		elseif className == "TrussPart" then
			shape = "truss"
		else
			raise(string.format("Unable to create an Instance of type \"%s\"", tostring(className)), 2)
		end
		local part = wrapPart(invoke("workspace.create", shape))
		-- Roblox's defaults: medium stone grey, unanchored.
		part.Color = color(163 / 255, 162 / 255, 165 / 255)
		part.Anchored = false
		if className == "Seat" then
			invoke("part.set", partIdOf[part], "isseat", true)
		elseif className == "MeshPart" then
			-- No model until MeshId names one: drawn as a block meanwhile.
			invoke("part.set", partIdOf[part], "ismeshpart", true)
		elseif className == "TrussPart" then
			part.Size = vector(2, 10, 2)
			part.Anchored = true
		end
		if parent ~= nil and parent ~= workspace_ then
			raise("Instance.new only supports workspace as a parent", 2)
		end
		return part
	end,
})

--------------------------------------------------------------------------------
-- Singleton services, as userdata so sandboxing leaves their assignment behaviour alone

local function service(name, members, methods, assign)
	local object = newproxy(true)
	local meta = getmetatable(object)
	typeTags[object] = "Instance"
	meta.__index = function(_, key)
		-- A service is named after its class, unless it says otherwise: the player's
		-- Name is what the player chose.
		if key == "ClassName" or (key == "Name" and not (members and members.Name)) then
			return name
		end
		local getter = members and members[key]
		if getter ~= nil then
			return getter()
		end
		local method = methods and methods[key]
		if method ~= nil then
			return method
		end
		if methods and methods.__child then
			local child = methods.__child(key)
			if child ~= nil then
				return child
			end
		end
		raise(string.format("%s is not a valid member of %s \"%s\"", tostring(key), name, name), 2)
	end
	meta.__newindex = function(_, key, value)
		if assign ~= nil and assign(key, value) then
			return
		end
		raise(string.format("Unable to assign property %s of %s", tostring(key), name), 2)
	end
	meta.__tostring = function()
		return name
	end
	meta.__metatable = LOCKED
	return object
end

-- workspace

local workspaceMethods = {}

for name, method in treeMethods do
	if name ~= "GetPivot" and name ~= "PivotTo" and name ~= "ClearAllChildren" then
		workspaceMethods[name] = method
	end
end

function workspaceMethods.GetFullName()
	return "Workspace"
end

function workspaceMethods.IsA(_, className)
	return className == "Workspace" or className == "Instance"
end

-- `workspace.Baseplate`: children can be reached by name, as in Roblox.
function workspaceMethods.__child(key)
	if type(key) ~= "string" then
		return nil
	end
	return wrapToken(invoke("tree.find", "w", key, false))
end

workspace_ = service("Workspace", {
	Gravity = function()
		return invoke("player.get", "gravity")
	end,
}, workspaceMethods, function(key, value)
	if key ~= "Gravity" then
		return false
	end
	if type(value) ~= "number" then
		raise("Unable to assign property Gravity. number expected, got " .. typeof(value), 3)
	end
	invoke("player.set", "gravity", value)
	return true
end)
workspace = workspace_
Workspace = workspace_

-- Shaders and the screen (Studio extensions)

local shadersMethods = {}

function shadersMethods.FindFirstChild(_, name)
	if type(name) ~= "string" then
		return nil
	end
	return wrapShader(invoke("shader.find", name))
end

function shadersMethods.GetChildren()
	local children = {}
	for index, id in invoke("shader.ids") do
		children[index] = wrapShader(id)
	end
	return children
end

function shadersMethods.GetScreenShaders()
	local children = {}
	for index, id in invoke("shader.ids", "screen") do
		children[index] = wrapShader(id)
	end
	return children
end

function shadersMethods.__child(key)
	if type(key) ~= "string" then
		return nil
	end
	return wrapShader(invoke("shader.find", key))
end

Shaders = service("Shaders", nil, shadersMethods)

Screen = service("Screen", {
	-- The first effect switched on; setting it switches that one on alone.
	Shader = function()
		return wrapShader(invoke("screen.get"))
	end,
}, {
	-- Every effect switched on, in the order they run (the Explorer's).
	GetShaders = function()
		local list = {}
		for index, id in invoke("screen.list") do
			list[index] = wrapShader(id)
		end
		return list
	end,
	AddShader = function(_, shader)
		if typeTags[shader] ~= "Shader" then
			raise("AddShader expects a Shader, got " .. typeof(shader), 2)
		end
		invoke("screen.add", shaderIdOf[shader])
	end,
	RemoveShader = function(_, shader)
		if typeTags[shader] ~= "Shader" then
			raise("RemoveShader expects a Shader, got " .. typeof(shader), 2)
		end
		invoke("screen.remove", shaderIdOf[shader])
	end,
}, function(key, value)
	if key ~= "Shader" then
		return false
	end
	if value == nil then
		invoke("screen.set", nil)
	elseif typeTags[value] == "Shader" then
		invoke("screen.set", shaderIdOf[value])
	else
		raise(string.format("Unable to assign property Shader. Shader expected, got %s", typeof(value)), 3)
	end
	return true
end)

-- Lighting: the sun, sky, shadows and fog, as Roblox's Lighting service.
local lightingNumbers = {
	ClockTime = "clocktime", Brightness = "brightness", ShadowSoftness = "shadowsoftness",
	ExposureCompensation = "exposurecompensation", FogStart = "fogstart", FogEnd = "fogend",
	GeographicLatitude = "geographiclatitude",
}
local lightingColors = {
	Ambient = "ambient", OutdoorAmbient = "outdoorambient", ColorShift_Top = "colorshift_top",
	FogColor = "fogcolor",
}

local lightingMembers = {
	TimeOfDay = function()
		return invoke("lighting.get", "timeofday")
	end,
	GlobalShadows = function()
		return invoke("lighting.get", "globalshadows")
	end,
	Technology = function()
		return Enum.Technology[invoke("lighting.get", "technology")]
	end,
}
for name, host in lightingNumbers do
	lightingMembers[name] = function()
		return invoke("lighting.get", host)
	end
end
for name, host in lightingColors do
	lightingMembers[name] = function()
		return toColor(invoke("lighting.get", host))
	end
end

Lighting = service("Lighting", lightingMembers, {
	GetSunDirection = function()
		return toVector(invoke("lighting.get", "sundirection"))
	end,
	GetMinutesAfterMidnight = function()
		return invoke("lighting.get", "clocktime") * 60
	end,
	SetMinutesAfterMidnight = function(_, minutes)
		if type(minutes) ~= "number" then
			raise("SetMinutesAfterMidnight expects a number, got " .. typeof(minutes), 2)
		end
		invoke("lighting.set", "clocktime", minutes / 60)
	end,
	IsA = function(_, className)
		return className == "Lighting" or className == "Instance"
	end,
}, function(key, value)
	local function fail(expected)
		raise(string.format("Unable to assign property %s. %s expected, got %s", key, expected, typeof(value)), 3)
	end
	if lightingNumbers[key] then
		if type(value) ~= "number" then fail("number") end
		invoke("lighting.set", lightingNumbers[key], value)
	elseif lightingColors[key] then
		if not isColor(value) then fail("Color3") end
		invoke("lighting.set", lightingColors[key], { value[1], value[2], value[3] })
	elseif key == "GlobalShadows" then
		if type(value) ~= "boolean" then fail("bool") end
		invoke("lighting.set", "globalshadows", value)
	elseif key == "TimeOfDay" then
		if type(value) ~= "string" then fail("string") end
		invoke("lighting.set", "timeofday", value)
	elseif key == "Technology" then
		local name = enumName(value, "Technology")
		if name == nil then fail("EnumItem") end
		invoke("lighting.set", "technology", name)
	else
		return false
	end
	return true
end)

"""#
}
