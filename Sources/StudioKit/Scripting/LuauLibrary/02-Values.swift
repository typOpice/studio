// The Luau library, part 2 of 16: Vector3, Color3 and Enum.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let values = #"""
--------------------------------------------------------------------------------
-- Vector3

-- Roblox keeps Vector3 and Color3 components as 32-bit floats, and so does the
-- scene. Rounding here too means a value read back from a part still compares
-- equal to the one that was written.
local scratch = buffer.create(4)
local function f32(value)
	buffer.writef32(scratch, 0, value)
	return buffer.readf32(scratch, 0)
end

local Vector3Meta = {}
local vectorMethods = {}

local function vector(x, y, z)
	local v = setmetatable({ f32(x), f32(y), f32(z) }, Vector3Meta)
	typeTags[v] = "Vector3"
	return v
end

local function isVector(value)
	return value ~= nil and typeTags[value] == "Vector3"
end

local function checkNumber(value, argument, functionName)
	if value ~= nil and type(value) ~= "number" then
		raise(string.format("invalid argument #%d to '%s' (number expected, got %s)",
			argument, functionName, typeof(value)), 3)
	end
end

local function checkSelf(self, tag, methodName)
	if self == nil or typeTags[self] ~= tag then
		raise(string.format("Expected ':' not '.' calling member function %s", methodName), 3)
	end
end

-- With `v.Dot(w)`, w arrives as self and the real argument is missing, so the
-- self check alone cannot catch it.
local function checkOther(other, tag, methodName)
	if other == nil or typeTags[other] ~= tag then
		raise(string.format("%s expects a %s argument, got %s — call it as value:%s(other)",
			methodName, tag, typeof(other), methodName), 3)
	end
end

Vector3Meta.__index = function(v, key)
	if key == "X" then
		return rawget(v, 1)
	elseif key == "Y" then
		return rawget(v, 2)
	elseif key == "Z" then
		return rawget(v, 3)
	elseif key == "Magnitude" then
		local x, y, z = rawget(v, 1), rawget(v, 2), rawget(v, 3)
		return math.sqrt(x * x + y * y + z * z)
	elseif key == "Unit" then
		local x, y, z = rawget(v, 1), rawget(v, 2), rawget(v, 3)
		local length = math.sqrt(x * x + y * y + z * z)
		-- Roblox gives NaN here; a NaN position makes a part silently vanish, so zero.
		if length == 0 then
			return vector(0, 0, 0)
		end
		return vector(x / length, y / length, z / length)
	end
	local method = vectorMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of Vector3", tostring(key)), 2)
end

Vector3Meta.__newindex = function(_, key)
	raise(string.format("%s cannot be assigned to", tostring(key)), 2)
end

local function arithmeticError(operation, a, b)
	raise(string.format("attempt to perform arithmetic (%s) on %s and %s",
		operation, typeof(a), typeof(b)), 3)
end

Vector3Meta.__add = function(a, b)
	if not isVector(a) or not isVector(b) then
		arithmeticError("add", a, b)
	end
	return vector(a[1] + b[1], a[2] + b[2], a[3] + b[3])
end

Vector3Meta.__sub = function(a, b)
	if not isVector(a) or not isVector(b) then
		arithmeticError("sub", a, b)
	end
	return vector(a[1] - b[1], a[2] - b[2], a[3] - b[3])
end

Vector3Meta.__mul = function(a, b)
	if type(a) == "number" and isVector(b) then
		return vector(a * b[1], a * b[2], a * b[3])
	elseif isVector(a) and type(b) == "number" then
		return vector(a[1] * b, a[2] * b, a[3] * b)
	elseif isVector(a) and isVector(b) then
		return vector(a[1] * b[1], a[2] * b[2], a[3] * b[3])
	end
	arithmeticError("mul", a, b)
end

Vector3Meta.__div = function(a, b)
	if isVector(a) and type(b) == "number" then
		return vector(a[1] / b, a[2] / b, a[3] / b)
	elseif type(a) == "number" and isVector(b) then
		return vector(a / b[1], a / b[2], a / b[3])
	elseif isVector(a) and isVector(b) then
		return vector(a[1] / b[1], a[2] / b[2], a[3] / b[3])
	end
	arithmeticError("div", a, b)
end

Vector3Meta.__unm = function(a)
	return vector(-a[1], -a[2], -a[3])
end

Vector3Meta.__eq = function(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

Vector3Meta.__tostring = function(v)
	return tostring(v[1]) .. ", " .. tostring(v[2]) .. ", " .. tostring(v[3])
end

Vector3Meta.__metatable = LOCKED

function vectorMethods.Dot(self, other)
	checkSelf(self, "Vector3", "Dot")
	checkOther(other, "Vector3", "Dot")
	return self[1] * other[1] + self[2] * other[2] + self[3] * other[3]
end

function vectorMethods.Cross(self, other)
	checkSelf(self, "Vector3", "Cross")
	checkOther(other, "Vector3", "Cross")
	return vector(
		self[2] * other[3] - self[3] * other[2],
		self[3] * other[1] - self[1] * other[3],
		self[1] * other[2] - self[2] * other[1])
end

function vectorMethods.Lerp(self, goal, alpha)
	checkSelf(self, "Vector3", "Lerp")
	checkOther(goal, "Vector3", "Lerp")
	return vector(
		self[1] + (goal[1] - self[1]) * alpha,
		self[2] + (goal[2] - self[2]) * alpha,
		self[3] + (goal[3] - self[3]) * alpha)
end

function vectorMethods.FuzzyEq(self, other, epsilon)
	checkSelf(self, "Vector3", "FuzzyEq")
	checkOther(other, "Vector3", "FuzzyEq")
	epsilon = epsilon or 1e-5
	return math.abs(self[1] - other[1]) <= epsilon
		and math.abs(self[2] - other[2]) <= epsilon
		and math.abs(self[3] - other[3]) <= epsilon
end

function vectorMethods.Abs(self)
	checkSelf(self, "Vector3", "Abs")
	return vector(math.abs(self[1]), math.abs(self[2]), math.abs(self[3]))
end

function vectorMethods.Floor(self)
	checkSelf(self, "Vector3", "Floor")
	return vector(math.floor(self[1]), math.floor(self[2]), math.floor(self[3]))
end

function vectorMethods.Ceil(self)
	checkSelf(self, "Vector3", "Ceil")
	return vector(math.ceil(self[1]), math.ceil(self[2]), math.ceil(self[3]))
end

function vectorMethods.Sign(self)
	checkSelf(self, "Vector3", "Sign")
	return vector(math.sign(self[1]), math.sign(self[2]), math.sign(self[3]))
end

function vectorMethods.Max(self, other)
	checkSelf(self, "Vector3", "Max")
	checkOther(other, "Vector3", "Max")
	return vector(math.max(self[1], other[1]), math.max(self[2], other[2]), math.max(self[3], other[3]))
end

function vectorMethods.Min(self, other)
	checkSelf(self, "Vector3", "Min")
	checkOther(other, "Vector3", "Min")
	return vector(math.min(self[1], other[1]), math.min(self[2], other[2]), math.min(self[3], other[3]))
end

-- The angle between two directions, in radians, as Roblox returns it.
function vectorMethods.Angle(self, other)
	checkSelf(self, "Vector3", "Angle")
	checkOther(other, "Vector3", "Angle")
	local denominator = math.sqrt(self[1] ^ 2 + self[2] ^ 2 + self[3] ^ 2)
		* math.sqrt(other[1] ^ 2 + other[2] ^ 2 + other[3] ^ 2)
	if denominator == 0 then
		return 0
	end
	local cosine = (self[1] * other[1] + self[2] * other[2] + self[3] * other[3]) / denominator
	return math.acos(math.clamp(cosine, -1, 1))
end

-- Studio extension: turned about Y the same way a part's Orientation.Y turns it.
function vectorMethods.RotatedY(self, degrees)
	checkSelf(self, "Vector3", "RotatedY")
	local radians = math.rad(degrees)
	local c, s = math.cos(radians), math.sin(radians)
	return vector(self[1] * c + self[3] * s, self[2], self[3] * c - self[1] * s)
end

Vector3 = table.freeze({
	new = function(x, y, z)
		checkNumber(x, 1, "new")
		checkNumber(y, 2, "new")
		checkNumber(z, 3, "new")
		return vector(x or 0, y or 0, z or 0)
	end,
	zero = vector(0, 0, 0),
	one = vector(1, 1, 1),
	xAxis = vector(1, 0, 0),
	yAxis = vector(0, 1, 0),
	zAxis = vector(0, 0, 1),
})

--------------------------------------------------------------------------------
-- Color3

local Color3Meta = {}
local colorMethods = {}

local function color(r, g, b)
	local c = setmetatable({ f32(r), f32(g), f32(b) }, Color3Meta)
	typeTags[c] = "Color3"
	return c
end

local function isColor(value)
	return value ~= nil and typeTags[value] == "Color3"
end

Color3Meta.__index = function(c, key)
	if key == "R" then
		return rawget(c, 1)
	elseif key == "G" then
		return rawget(c, 2)
	elseif key == "B" then
		return rawget(c, 3)
	end
	local method = colorMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of Color3", tostring(key)), 2)
end

Color3Meta.__newindex = function(_, key)
	raise(string.format("%s cannot be assigned to", tostring(key)), 2)
end

Color3Meta.__eq = function(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

Color3Meta.__tostring = function(c)
	return tostring(c[1]) .. ", " .. tostring(c[2]) .. ", " .. tostring(c[3])
end

Color3Meta.__metatable = LOCKED

function colorMethods.Lerp(self, goal, alpha)
	checkSelf(self, "Color3", "Lerp")
	checkOther(goal, "Color3", "Lerp")
	return color(
		self[1] + (goal[1] - self[1]) * alpha,
		self[2] + (goal[2] - self[2]) * alpha,
		self[3] + (goal[3] - self[3]) * alpha)
end

-- Hue, saturation and value, each 0..1, as Roblox returns them.
function colorMethods.ToHSV(self)
	checkSelf(self, "Color3", "ToHSV")
	local r, g, b = self[1], self[2], self[3]
	local high, low = math.max(r, g, b), math.min(r, g, b)
	local delta = high - low
	local hue = 0
	if delta > 0 then
		if high == r then
			hue = ((g - b) / delta) % 6
		elseif high == g then
			hue = (b - r) / delta + 2
		else
			hue = (r - g) / delta + 4
		end
		hue /= 6
	end
	local saturation = if high == 0 then 0 else delta / high
	return hue, saturation, high
end

function colorMethods.ToHex(self)
	checkSelf(self, "Color3", "ToHex")
	return string.format("%02X%02X%02X",
		math.round(math.clamp(self[1], 0, 1) * 255),
		math.round(math.clamp(self[2], 0, 1) * 255),
		math.round(math.clamp(self[3], 0, 1) * 255))
end

local function colorFromHSV(h, s, v)
	h = (h % 1) * 6
	local chroma = v * s
	local x = chroma * (1 - math.abs(h % 2 - 1))
	local m = v - chroma
	local r, g, b
	if h < 1 then
		r, g, b = chroma, x, 0
	elseif h < 2 then
		r, g, b = x, chroma, 0
	elseif h < 3 then
		r, g, b = 0, chroma, x
	elseif h < 4 then
		r, g, b = 0, x, chroma
	elseif h < 5 then
		r, g, b = x, 0, chroma
	else
		r, g, b = chroma, 0, x
	end
	return color(r + m, g + m, b + m)
end

Color3 = table.freeze({
	new = function(r, g, b)
		checkNumber(r, 1, "new")
		checkNumber(g, 2, "new")
		checkNumber(b, 3, "new")
		return color(r or 0, g or 0, b or 0)
	end,
	fromRGB = function(r, g, b)
		checkNumber(r, 1, "fromRGB")
		checkNumber(g, 2, "fromRGB")
		checkNumber(b, 3, "fromRGB")
		return color((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
	fromHSV = colorFromHSV,
	fromHex = function(hex)
		local digits = string.gsub(hex, "^#", "")
		if #digits ~= 6 or not string.match(digits, "^%x+$") then
			raise("Unable to convert characters to hex value", 2)
		end
		return color(
			tonumber(string.sub(digits, 1, 2), 16) / 255,
			tonumber(string.sub(digits, 3, 4), 16) / 255,
			tonumber(string.sub(digits, 5, 6), 16) / 255)
	end,
})

--------------------------------------------------------------------------------
-- Enum

local EnumItemMeta = {}

EnumItemMeta.__index = function(item, key)
	if key == "Name" then
		return rawget(item, 1)
	elseif key == "EnumType" then
		return rawget(item, 2)
	elseif key == "Value" then
		return rawget(item, 3)
	end
	raise(string.format("%s is not a valid member of EnumItem", tostring(key)), 2)
end

EnumItemMeta.__newindex = function(_, key)
	raise(string.format("%s cannot be assigned to", tostring(key)), 2)
end

EnumItemMeta.__tostring = function(item)
	return "Enum." .. rawget(item, 2) .. "." .. rawget(item, 1)
end

EnumItemMeta.__metatable = LOCKED

local function makeEnum(typeName, names)
	local items = {}
	local ordered = {}
	for index, name in names do
		local item = setmetatable({ name, typeName, index - 1 }, EnumItemMeta)
		typeTags[item] = "EnumItem"
		items[name] = item
		ordered[index] = item
	end
	-- Frozen rather than locked: table.freeze refuses a protected metatable, and
	-- freezing both the namespace and its metatable prevents tampering just as well.
	local namespace = setmetatable(items, table.freeze({
		__index = function(_, key)
			if key == "GetEnumItems" then
				return function()
					return table.clone(ordered)
				end
			end
			raise(string.format("%s is not a valid member of \"Enum.%s\"", tostring(key), typeName), 2)
		end,
		__tostring = function()
			return typeName
		end,
	}))
	return table.freeze(namespace)
end

Enum = table.freeze({
	-- The parts' materials, then the terrain's (Terrain.swift).
	Material = makeEnum("Material", { "Plastic", "SmoothPlastic", "Metal", "Neon", "Wood", "Water", "Air", "Grass",
		"LeafyGrass", "Sand", "Ground", "Mud", "Rock", "Slate", "Basalt", "Sandstone", "Snow", "Ice", "Asphalt" }),
	PartType = makeEnum("PartType", { "Block", "Ball", "Cylinder", "Wedge" }),
	EasingStyle = makeEnum("EasingStyle", {
		"Linear", "Sine", "Quad", "Cubic", "Quart", "Quint",
		"Exponential", "Circular", "Back", "Elastic", "Bounce",
	}),
	EasingDirection = makeEnum("EasingDirection", { "In", "Out", "InOut" }),
	AnimationPriority = makeEnum("AnimationPriority", { "Core", "Idle", "Movement", "Action" }),
	Technology = makeEnum("Technology", { "Conventional", "RayTraced" }),
	NormalId = makeEnum("NormalId", { "Right", "Top", "Back", "Left", "Bottom", "Front" }),
	TextureMode = makeEnum("TextureMode", { "Stretch", "Wrap" }),
	PositionAlignmentMode = makeEnum("PositionAlignmentMode", { "OneAttachment", "TwoAttachment" }),
	OrientationAlignmentMode = makeEnum("OrientationAlignmentMode", { "OneAttachment", "TwoAttachment" }),
	ActuatorRelativeTo = makeEnum("ActuatorRelativeTo", { "Attachment0", "Attachment1", "World" }),
	ActuatorType = makeEnum("ActuatorType", { "None", "Motor", "Servo" }),
	KeyCode = makeEnum("KeyCode", { __KEYCODE_NAMES__ }),
	UserInputType = makeEnum("UserInputType", { "Keyboard", "MouseButton1", "MouseButton2" }),
	UserInputState = makeEnum("UserInputState", { "Begin", "End" }),
	HumanoidStateType = makeEnum("HumanoidStateType", {
		"Running", "Jumping", "Freefall", "Landed", "Flying", "Dead", "Seated", "Climbing", "Swimming",
	}),
	CameraMode = makeEnum("CameraMode", { "Classic", "LockFirstPerson" }),
	TextXAlignment = makeEnum("TextXAlignment", { "Left", "Right", "Center" }),
	PlaybackState = makeEnum("PlaybackState", { "Begin", "Delayed", "Playing", "Paused", "Completed", "Cancelled" }),
	MouseBehavior = makeEnum("MouseBehavior", { "Default", "LockCenter", "LockCurrentPosition" }),
	TextYAlignment = makeEnum("TextYAlignment", { "Top", "Center", "Bottom" }),
	AutomaticSize = makeEnum("AutomaticSize", { "None", "X", "Y", "XY" }),
	ScaleType = makeEnum("ScaleType", { "Stretch", "Slice", "Tile", "Fit", "Crop" }),
	FillDirection = makeEnum("FillDirection", { "Horizontal", "Vertical" }),
	SortOrder = makeEnum("SortOrder", { "Name", "Custom", "LayoutOrder" }),
	HorizontalAlignment = makeEnum("HorizontalAlignment", { "Center", "Left", "Right" }),
	VerticalAlignment = makeEnum("VerticalAlignment", { "Center", "Top", "Bottom" }),
	ApplyStrokeMode = makeEnum("ApplyStrokeMode", { "Contextual", "Border" }),
	LineJoinMode = makeEnum("LineJoinMode", { "Round", "Bevel", "Miter" }),
	StartCorner = makeEnum("StartCorner", { "TopLeft", "TopRight", "BottomLeft", "BottomRight" }),
	AspectType = makeEnum("AspectType", { "FitWithinMaxSize", "ScaleWithParentSize" }),
	DominantAxis = makeEnum("DominantAxis", { "Width", "Height" }),
	CollisionFidelity = makeEnum("CollisionFidelity", { "Default", "Hull", "Box", "PreciseConvexDecomposition" }),
	RaycastFilterType = makeEnum("RaycastFilterType", { "Exclude", "Include", "Blacklist", "Whitelist" }),
	PathStatus = makeEnum("PathStatus", {
		"Success", "ClosestNoPath", "ClosestOutOfRange", "FailStartNotEmpty", "FailFinishNotEmpty", "NoPath",
	}),
	PathWaypointAction = makeEnum("PathWaypointAction", { "Walk", "Jump", "Custom" }),
	AccessoryType = makeEnum("AccessoryType", { "Hat", "Hair", "Face", "Neck", "Shoulder", "Front", "Back", "Waist" }),
	MessageType = makeEnum("MessageType", { "MessageOutput", "MessageInfo", "MessageWarning", "MessageError" }),
	Font = makeEnum("Font", {
		"Legacy", "Arial", "ArialBold", "SourceSans", "SourceSansBold", "SourceSansLight", "Gotham", "GothamBold",
		"GothamBlack", "Code", "RobotoMono", "Ubuntu", "Cartoon", "FredokaOne", "Bangers", "LuckiestGuy", "Kalam",
		"Highway", "Arcade", "Fantasy", "SciFi", "Garamond", "Antique", "Merriweather", "Bodoni",
	}),
})

-- Roblox enum names ↔ the host's own names.
local materialToHost = { Plastic = "plastic", SmoothPlastic = "smooth", Metal = "metal", Neon = "neon", Wood = "wood",
	Water = "water" }
local materialFromHost = { plastic = "Plastic", smooth = "SmoothPlastic", metal = "Metal", neon = "Neon", wood = "Wood",
	water = "Water" }
local shapeToHost = { Block = "block", Ball = "sphere", Cylinder = "cylinder", Wedge = "wedge" }
local shapeFromHost = { block = "Block", sphere = "Ball", cylinder = "Cylinder", wedge = "Wedge" }

-- An enum property accepts the item itself, or its name as a string, as Roblox does.
local function enumName(value, enumType)
	if typeTags[value] == "EnumItem" and rawget(value, 2) == enumType then
		return rawget(value, 1)
	elseif type(value) == "string" then
		return value
	end
	return nil
end

"""#
}
