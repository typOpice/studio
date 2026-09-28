// The Luau library, part 9 of 16: the screen — GUI objects and TextChatService.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let gui = #"""
--------------------------------------------------------------------------------
-- The screen: GUI objects, and TextChatService
--
-- ScreenGui, Frame, TextLabel, TextButton, TextBox, ImageLabel and the rest, with the
-- modifiers that go inside them (UICorner, UIPadding, UIStroke, UIGradient, the layouts
-- and the constraints), placed with UDim2 and parented under the player's PlayerGui, as in Roblox. Each lives in the host
-- (Play/Gui.swift) under a number; the tables here are only its face. The `gui` table,
-- declared beside Instance.new, holds all of it — one local, as the library's top
-- level is close to Luau's limit of 200.

-- UDim, UDim2 and Vector2

gui.UDimMeta, gui.UDim2Meta, gui.Vector2Meta = {}, {}, {}

function gui.udim(scale, offset)
	local value = setmetatable({ scale or 0, offset or 0 }, gui.UDimMeta)
	typeTags[value] = "UDim"
	return value
end

function gui.udim2(xScale, xOffset, yScale, yOffset)
	local value = setmetatable({ xScale or 0, xOffset or 0, yScale or 0, yOffset or 0 }, gui.UDim2Meta)
	typeTags[value] = "UDim2"
	return value
end

function gui.vector2(x, y)
	local value = setmetatable({ x or 0, y or 0 }, gui.Vector2Meta)
	typeTags[value] = "Vector2"
	return value
end

local function readOnly(typeName)
	return function(_, key)
		raise(string.format("%s cannot be assigned to", tostring(key)), 2)
	end
end

gui.UDimMeta.__index = function(value, key)
	if key == "Scale" then
		return rawget(value, 1)
	elseif key == "Offset" then
		return rawget(value, 2)
	end
	raise(string.format("%s is not a valid member of UDim", tostring(key)), 2)
end
gui.UDimMeta.__newindex = readOnly("UDim")
gui.UDimMeta.__eq = function(a, b)
	return rawget(a, 1) == rawget(b, 1) and rawget(a, 2) == rawget(b, 2)
end
gui.UDimMeta.__tostring = function(v)
	return string.format("%g, %g", rawget(v, 1), rawget(v, 2))
end
gui.UDimMeta.__metatable = LOCKED

gui.UDim2Meta.__index = function(value, key)
	if key == "X" or key == "Width" then
		return gui.udim(rawget(value, 1), rawget(value, 2))
	elseif key == "Y" or key == "Height" then
		return gui.udim(rawget(value, 3), rawget(value, 4))
	end
	raise(string.format("%s is not a valid member of UDim2", tostring(key)), 2)
end
gui.UDim2Meta.__newindex = readOnly("UDim2")
local function checkUDim2s(a, b, operation)
	if typeTags[a] ~= "UDim2" or typeTags[b] ~= "UDim2" then
		raise(string.format("attempt to perform arithmetic (%s) on %s and %s", operation, typeof(a), typeof(b)), 3)
	end
end
gui.UDim2Meta.__add = function(a, b)
	checkUDim2s(a, b, "add")
	return gui.udim2(a[1] + b[1], a[2] + b[2], a[3] + b[3], a[4] + b[4])
end
gui.UDim2Meta.__sub = function(a, b)
	checkUDim2s(a, b, "sub")
	return gui.udim2(a[1] - b[1], a[2] - b[2], a[3] - b[3], a[4] - b[4])
end
gui.UDim2Meta.__eq = function(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end
gui.UDim2Meta.__tostring = function(v)
	return string.format("{%g, %g}, {%g, %g}", v[1], v[2], v[3], v[4])
end
gui.UDim2Meta.__metatable = LOCKED

gui.Vector2Meta.__index = function(value, key)
	if key == "X" then
		return rawget(value, 1)
	elseif key == "Y" then
		return rawget(value, 2)
	elseif key == "Magnitude" then
		return math.sqrt(value[1] * value[1] + value[2] * value[2])
	end
	raise(string.format("%s is not a valid member of Vector2", tostring(key)), 2)
end
gui.Vector2Meta.__newindex = readOnly("Vector2")
local function vector2Pair(a, b, operation)
	if typeTags[a] ~= "Vector2" or (typeTags[b] ~= "Vector2" and type(b) ~= "number") then
		raise(string.format("attempt to perform arithmetic (%s) on %s and %s", operation, typeof(a), typeof(b)), 3)
	end
	if type(b) == "number" then
		return b, b
	end
	return b[1], b[2]
end
gui.Vector2Meta.__add = function(a, b)
	local x, y = vector2Pair(a, b, "add")
	return gui.vector2(a[1] + x, a[2] + y)
end
gui.Vector2Meta.__sub = function(a, b)
	local x, y = vector2Pair(a, b, "sub")
	return gui.vector2(a[1] - x, a[2] - y)
end
gui.Vector2Meta.__mul = function(a, b)
	if type(a) == "number" then
		a, b = b, a
	end
	local x, y = vector2Pair(a, b, "mul")
	return gui.vector2(a[1] * x, a[2] * y)
end
gui.Vector2Meta.__unm = function(a)
	return gui.vector2(-a[1], -a[2])
end
gui.Vector2Meta.__eq = function(a, b)
	return a[1] == b[1] and a[2] == b[2]
end
gui.Vector2Meta.__tostring = function(v)
	return string.format("%g, %g", v[1], v[2])
end
gui.Vector2Meta.__metatable = LOCKED

UDim = table.freeze({
	new = function(scale, offset)
		checkNumber(scale, 1, "UDim.new")
		checkNumber(offset, 2, "UDim.new")
		return gui.udim(scale, offset)
	end,
})

UDim2 = table.freeze({
	new = function(xScale, xOffset, yScale, yOffset)
		checkNumber(xScale, 1, "UDim2.new")
		checkNumber(xOffset, 2, "UDim2.new")
		checkNumber(yScale, 3, "UDim2.new")
		checkNumber(yOffset, 4, "UDim2.new")
		return gui.udim2(xScale, xOffset, yScale, yOffset)
	end,
	fromScale = function(x, y)
		return gui.udim2(x, 0, y, 0)
	end,
	fromOffset = function(x, y)
		return gui.udim2(0, x, 0, y)
	end,
})

-- ColorSequence and NumberSequence: a UIGradient's colours and transparencies, as
-- keypoints from time 0 to time 1.

gui.ColorKeyMeta, gui.NumberKeyMeta, gui.ColorSequenceMeta, gui.NumberSequenceMeta = {}, {}, {}, {}

function gui.colorKey(time, color)
	local key = setmetatable({ time, color }, gui.ColorKeyMeta)
	typeTags[key] = "ColorSequenceKeypoint"
	return key
end

function gui.numberKey(time, value, envelope)
	local key = setmetatable({ time, value, envelope or 0 }, gui.NumberKeyMeta)
	typeTags[key] = "NumberSequenceKeypoint"
	return key
end

gui.ColorKeyMeta.__index = function(key, name)
	if name == "Time" then
		return rawget(key, 1)
	elseif name == "Value" then
		return rawget(key, 2)
	end
	raise(string.format("%s is not a valid member of ColorSequenceKeypoint", tostring(name)), 2)
end
gui.ColorKeyMeta.__newindex = readOnly("ColorSequenceKeypoint")
gui.ColorKeyMeta.__eq = function(a, b)
	return rawget(a, 1) == rawget(b, 1) and rawget(a, 2) == rawget(b, 2)
end
gui.ColorKeyMeta.__tostring = function(key)
	return string.format("%g %s", rawget(key, 1), tostring(rawget(key, 2)))
end
gui.ColorKeyMeta.__metatable = LOCKED

gui.NumberKeyMeta.__index = function(key, name)
	if name == "Time" then
		return rawget(key, 1)
	elseif name == "Value" then
		return rawget(key, 2)
	elseif name == "Envelope" then
		return rawget(key, 3)
	end
	raise(string.format("%s is not a valid member of NumberSequenceKeypoint", tostring(name)), 2)
end
gui.NumberKeyMeta.__newindex = readOnly("NumberSequenceKeypoint")
gui.NumberKeyMeta.__eq = function(a, b)
	return rawget(a, 1) == rawget(b, 1) and rawget(a, 2) == rawget(b, 2)
end
gui.NumberKeyMeta.__tostring = function(key)
	return string.format("%g %g %g", rawget(key, 1), rawget(key, 2), rawget(key, 3))
end
gui.NumberKeyMeta.__metatable = LOCKED

-- Keypoints as Roblox wants them: 2 to 20, from time 0 to time 1, in order.
function gui.checkKeypoints(points, typeName, keyType)
	for _, point in points do
		if typeof(point) ~= keyType then
			raise(string.format("%s.new expects %ss, got %s", typeName, keyType, typeof(point)), 3)
		end
	end
	if #points < 2 or #points > 20 then
		raise(typeName .. " requires 2 to 20 keypoints", 3)
	elseif points[1].Time ~= 0 or points[#points].Time ~= 1 then
		raise(typeName .. " must start at time 0 and end at time 1", 3)
	end
	for index = 2, #points do
		if points[index].Time < points[index - 1].Time then
			raise(typeName .. " keypoints must be ordered by time", 3)
		end
	end
end

function gui.sequence(points, meta, typeName)
	local value = setmetatable({ points = table.freeze(points) }, meta)
	typeTags[value] = typeName
	return value
end

for _, meta in { gui.ColorSequenceMeta, gui.NumberSequenceMeta } do
	local typeName = if meta == gui.ColorSequenceMeta then "ColorSequence" else "NumberSequence"
	meta.__index = function(value, key)
		if key == "Keypoints" then
			return table.clone(rawget(value, "points"))
		end
		raise(string.format("%s is not a valid member of %s", tostring(key), typeName), 2)
	end
	meta.__newindex = readOnly(typeName)
	meta.__eq = function(a, b)
		local left, right = rawget(a, "points"), rawget(b, "points")
		if #left ~= #right then
			return false
		end
		for index, point in left do
			if point ~= right[index] then
				return false
			end
		end
		return true
	end
	meta.__tostring = function(value)
		local parts = {}
		for _, point in rawget(value, "points") do
			table.insert(parts, tostring(point))
		end
		return table.concat(parts, " ")
	end
	meta.__metatable = LOCKED
end

ColorSequenceKeypoint = table.freeze({
	new = function(time, color)
		checkNumber(time, 1, "ColorSequenceKeypoint.new")
		if typeof(color) ~= "Color3" then
			raise("ColorSequenceKeypoint.new expects a Color3, got " .. typeof(color), 2)
		end
		return gui.colorKey(math.clamp(time, 0, 1), color)
	end,
})

NumberSequenceKeypoint = table.freeze({
	new = function(time, value, envelope)
		checkNumber(time, 1, "NumberSequenceKeypoint.new")
		checkNumber(value, 2, "NumberSequenceKeypoint.new")
		return gui.numberKey(math.clamp(time, 0, 1), value, envelope)
	end,
})

ColorSequence = table.freeze({
	new = function(first, last)
		if typeof(first) == "Color3" then
			last = if last == nil then first else last
			if typeof(last) ~= "Color3" then
				raise("ColorSequence.new expects two Color3s, got " .. typeof(last), 2)
			end
			return gui.sequence({ gui.colorKey(0, first), gui.colorKey(1, last) }, gui.ColorSequenceMeta, "ColorSequence")
		elseif type(first) == "table" and typeTags[first] == nil then
			gui.checkKeypoints(first, "ColorSequence", "ColorSequenceKeypoint")
			return gui.sequence(table.clone(first), gui.ColorSequenceMeta, "ColorSequence")
		end
		raise("ColorSequence.new expects a Color3, two Color3s or a table of ColorSequenceKeypoints", 2)
	end,
})

NumberSequence = table.freeze({
	new = function(first, last)
		if type(first) == "number" then
			last = if last == nil then first else last
			checkNumber(last, 2, "NumberSequence.new")
			return gui.sequence({ gui.numberKey(0, first), gui.numberKey(1, last) }, gui.NumberSequenceMeta, "NumberSequence")
		elseif type(first) == "table" and typeTags[first] == nil then
			gui.checkKeypoints(first, "NumberSequence", "NumberSequenceKeypoint")
			return gui.sequence(table.clone(first), gui.NumberSequenceMeta, "NumberSequence")
		end
		raise("NumberSequence.new expects a number, two numbers or a table of NumberSequenceKeypoints", 2)
	end,
})

Vector2 = table.freeze({
	new = function(x, y)
		checkNumber(x, 1, "Vector2.new")
		checkNumber(y, 2, "Vector2.new")
		return gui.vector2(x, y)
	end,
	zero = gui.vector2(0, 0),
	one = gui.vector2(1, 1),
})

-- GUI objects

gui.classes = {
	ScreenGui = true, BillboardGui = true, Frame = true, ScrollingFrame = true, TextLabel = true,
	TextButton = true, TextBox = true, ImageLabel = true, ImageButton = true,
	UICorner = true, UIPadding = true, UIListLayout = true, UIStroke = true, UIGradient = true, UIGridLayout = true,
	UIAspectRatioConstraint = true, UISizeConstraint = true, UITextSizeConstraint = true,
}
gui.isGuiObject = { Frame = true, ScrollingFrame = true, TextLabel = true, TextButton = true, TextBox = true,
	ImageLabel = true, ImageButton = true }
gui.isText = { TextLabel = true, TextButton = true, TextBox = true }
gui.isImage = { ImageLabel = true, ImageButton = true }
gui.isLayer = { ScreenGui = true, BillboardGui = true }
gui.isLayout = { UIListLayout = true, UIGridLayout = true }
gui.hasEnabled = { ScreenGui = true, BillboardGui = true, UIStroke = true, UIGradient = true }
gui.isConstraint = { UIAspectRatioConstraint = true, UISizeConstraint = true, UITextSizeConstraint = true }
gui.isSized = { Frame = true, ScrollingFrame = true, TextLabel = true, TextButton = true, TextBox = true,
	ImageLabel = true, ImageButton = true, BillboardGui = true }
-- Properties whose values are Enum items, by the enum's name.
gui.enumKinds = { TextXAlignment = true, TextYAlignment = true, AutomaticSize = true, Font = true, ScaleType = true,
	FillDirection = true, SortOrder = true, HorizontalAlignment = true, VerticalAlignment = true,
	ApplyStrokeMode = true, LineJoinMode = true, StartCorner = true, AspectType = true, DominantAxis = true }
-- Reading a BillboardGui's Adornee back: filled in with the character (part 10).
gui.bodyPartOf = setmetatable({}, { __mode = "k" })

-- Each property: its type, and the classes that have it.
gui.properties = {
	Position = { "UDim2", gui.isGuiObject },
	Size = { "UDim2", gui.isSized },
	AnchorPoint = { "Vector2", gui.isGuiObject },
	BackgroundColor3 = { "Color3", gui.isGuiObject },
	BackgroundTransparency = { "number", gui.isGuiObject },
	Visible = { "boolean", gui.isGuiObject },
	ZIndex = { "number", gui.isGuiObject },
	LayoutOrder = { "number", gui.isGuiObject },
	ClipsDescendants = { "boolean", gui.isGuiObject },
	AutomaticSize = { "AutomaticSize", gui.isGuiObject },
	AbsoluteSize = { "Vector2", gui.isGuiObject, readOnly = true },
	AbsolutePosition = { "Vector2", gui.isGuiObject, readOnly = true },
	Enabled = { "boolean", gui.hasEnabled },
	ResetOnSpawn = { "boolean", { ScreenGui = true } },
	DisplayOrder = { "number", { ScreenGui = true } },
	Text = { "string", gui.isText },
	TextColor3 = { "Color3", gui.isText },
	TextSize = { "number", gui.isText },
	TextTransparency = { "number", gui.isText },
	TextXAlignment = { "TextXAlignment", gui.isText },
	TextYAlignment = { "TextYAlignment", gui.isText },
	TextWrapped = { "boolean", gui.isText },
	TextScaled = { "boolean", gui.isText },
	Font = { "Font", gui.isText },
	TextStrokeColor3 = { "Color3", gui.isText },
	TextStrokeTransparency = { "number", gui.isText },
	PlaceholderText = { "string", { TextBox = true } },
	ClearTextOnFocus = { "boolean", { TextBox = true } },
	TextEditable = { "boolean", { TextBox = true } },
	CursorPosition = { "number", { TextBox = true } },
	Image = { "string", gui.isImage },
	ImageColor3 = { "Color3", gui.isImage },
	ImageTransparency = { "number", gui.isImage },
	ScaleType = { "ScaleType", gui.isImage },
	FillDirection = { "FillDirection", gui.isLayout },
	Padding = { "UDim", { UIListLayout = true } },
	SortOrder = { "SortOrder", gui.isLayout },
	HorizontalAlignment = { "HorizontalAlignment", gui.isLayout },
	VerticalAlignment = { "VerticalAlignment", gui.isLayout },
	CellSize = { "UDim2", { UIGridLayout = true } },
	CellPadding = { "UDim2", { UIGridLayout = true } },
	FillDirectionMaxCells = { "number", { UIGridLayout = true } },
	StartCorner = { "StartCorner", { UIGridLayout = true } },
	-- UIStroke's Color is a Color3 and its Transparency a number; UIGradient's are sequences.
	Color = { "Color3", { UIStroke = true, UIGradient = true }, byClass = { UIGradient = "ColorSequence" } },
	Transparency = { "number", { UIStroke = true, UIGradient = true }, byClass = { UIGradient = "NumberSequence" } },
	Thickness = { "number", { UIStroke = true } },
	ApplyStrokeMode = { "ApplyStrokeMode", { UIStroke = true } },
	LineJoinMode = { "LineJoinMode", { UIStroke = true } },
	Rotation = { "number", { UIGradient = true } },
	Offset = { "Vector2", { UIGradient = true } },
	AspectRatio = { "number", { UIAspectRatioConstraint = true } },
	AspectType = { "AspectType", { UIAspectRatioConstraint = true } },
	DominantAxis = { "DominantAxis", { UIAspectRatioConstraint = true } },
	MinSize = { "Vector2", { UISizeConstraint = true } },
	MaxSize = { "Vector2", { UISizeConstraint = true } },
	MinTextSize = { "number", { UITextSizeConstraint = true } },
	MaxTextSize = { "number", { UITextSizeConstraint = true } },
	CanvasSize = { "UDim2", { ScrollingFrame = true } },
	CanvasPosition = { "Vector2", { ScrollingFrame = true } },
	ScrollBarThickness = { "number", { ScrollingFrame = true } },
	ScrollingEnabled = { "boolean", { ScrollingFrame = true } },
	AutomaticCanvasSize = { "AutomaticSize", { ScrollingFrame = true } },
	Adornee = { "Adornee", { BillboardGui = true } },
	StudsOffset = { "Vector3", { BillboardGui = true } },
	AlwaysOnTop = { "boolean", { BillboardGui = true } },
	MaxDistance = { "number", { BillboardGui = true } },
	CornerRadius = { "UDim", { UICorner = true } },
	PaddingLeft = { "UDim", { UIPadding = true } },
	PaddingRight = { "UDim", { UIPadding = true } },
	PaddingTop = { "UDim", { UIPadding = true } },
	PaddingBottom = { "UDim", { UIPadding = true } },
}

-- Their events, and the classes that have them.
gui.events = {
	MouseButton1Click = { TextButton = true, ImageButton = true },
	Activated = { TextButton = true, ImageButton = true },
	Focused = { TextBox = true },
	FocusLost = { TextBox = true },
}

gui.byId = {}
gui.idOf = setmetatable({}, { __mode = "k" })
gui.signals = {}
gui.methods = {}

function gui.signal(id, name)
	local byName = gui.signals[id]
	if byName == nil then
		byName = {}
		gui.signals[id] = byName
	end
	local signal = byName[name]
	if signal == nil then
		signal = makeSignal()
		byName[name] = signal
	end
	return signal
end

function gui.fire(id, name, ...)
	local byName = gui.signals[id]
	local signal = byName and byName[name]
	if signal ~= nil then
		fire(signal, ...)
	end
end

-- A property's value as the host holds it, and back.
function gui.read(kind, raw)
	if raw == nil then
		return nil
	elseif kind == "UDim2" then
		return gui.udim2(raw[1], raw[2], raw[3], raw[4])
	elseif kind == "Vector2" then
		return gui.vector2(raw[1], raw[2])
	elseif kind == "UDim" then
		return gui.udim(raw[1], raw[2])
	elseif kind == "Color3" then
		return toColor(raw)
	elseif kind == "Vector3" then
		return toVector(raw)
	elseif kind == "CFrame" then
		return cframeMath.cframeFromList(raw)
	elseif kind == "Adornee" then
		return gui.adorneeFrom(raw)
	elseif kind == "ColorSequence" then
		local points = {}
		for index = 1, #raw, 4 do
			table.insert(points, gui.colorKey(raw[index], toColor({ raw[index + 1], raw[index + 2], raw[index + 3] })))
		end
		return gui.sequence(points, gui.ColorSequenceMeta, "ColorSequence")
	elseif kind == "NumberSequence" then
		local points = {}
		for index = 1, #raw, 2 do
			table.insert(points, gui.numberKey(raw[index], raw[index + 1]))
		end
		return gui.sequence(points, gui.NumberSequenceMeta, "NumberSequence")
	elseif gui.enumKinds[kind] then
		return Enum[kind][raw]
	end
	return raw
end

-- A BillboardGui's Adornee as the host names it, and back.
function gui.adorneeFrom(token)
	if type(token) ~= "string" then
		return nil
	elseif string.sub(token, 1, 2) == "p:" then
		return wrapPart(string.sub(token, 3))
	end
	return gui.bodyPartFromToken and gui.bodyPartFromToken(token)
end

function gui.write(kind, value)
	if kind == "ColorSequence" or kind == "NumberSequence" then
		if typeof(value) ~= kind then
			return nil
		end
		local list = {}
		for _, point in rawget(value, "points") do
			table.insert(list, rawget(point, 1))
			local held = rawget(point, 2)
			if kind == "ColorSequence" then
				for index = 1, 3 do
					table.insert(list, rawget(held, index))
				end
			else
				table.insert(list, held)
			end
		end
		return list
	elseif kind == "UDim2" or kind == "Vector2" or kind == "UDim" or kind == "Color3" then
		if typeof(value) ~= kind then
			return nil
		end
		local list = {}
		for index = 1, (if kind == "UDim2" then 4 elseif kind == "Color3" then 3 else 2) do
			list[index] = rawget(value, index)
		end
		return list
	elseif kind == "Vector3" then
		return if typeof(value) == "Vector3" then { value[1], value[2], value[3] } else nil
	elseif kind == "CFrame" then
		return if isCFrame(value) then cframeMath.cframeList(value) else nil
	elseif kind == "Adornee" then
		local id = partIdOf[value]
		if id ~= nil then
			return "p:" .. id
		end
		-- A character's body part, or the character itself (its Head).
		return gui.bodyPartOf[value]
	elseif gui.enumKinds[kind] then
		-- Only one of the enum's own items, or its name.
		local name = enumName(value, kind)
		local ok, item = pcall(function()
			return name and Enum[kind][name]
		end)
		return if ok and item ~= nil then name else nil
	end
	return if type(value) == kind then value else nil
end

function gui.childrenOf(parent)
	local list = {}
	for _, id in invoke("gui.children", parent) do
		table.insert(list, gui.wrap(id))
	end
	return list
end

function gui.childNamed(parent, name)
	for _, id in invoke("gui.children", parent) do
		if invoke("gui.get", id, "name") == name then
			return gui.wrap(id)
		end
	end
	return nil
end

function gui.setParent(id, parent)
	local target
	if parent == nil then
		target = -1
	elseif parent == gui.playerGui then
		target = 0
	else
		target = gui.idOf[parent]
	end
	if target == nil then
		raise("GUI objects go in the PlayerGui or in other GUI objects, not " .. typeof(parent), 3)
	end
	if not invoke("gui.setParent", id, target) then
		raise("Attempt to set parent would result in circular reference", 3)
	end
end

function gui.wrap(id)
	if id == nil or id <= 0 then
		return nil
	end
	local existing = gui.byId[id]
	if existing ~= nil then
		return existing
	end
	local className = invoke("gui.class", id)
	if className == nil then
		return nil
	end
	local object = setmetatable({}, {
		__index = function(_, key)
			if key == "ClassName" then
				return className
			elseif key == "Name" then
				return invoke("gui.get", id, "name")
			elseif key == "Parent" then
				local parent = invoke("gui.parent", id)
				return if parent == 0 then gui.playerGui else gui.wrap(parent)
			end
			local property = gui.properties[key]
			if property ~= nil and property[2][className] then
				local kind = property.byClass and property.byClass[className] or property[1]
				return gui.read(kind, invoke("gui.get", id, string.lower(key)))
			end
			local event = gui.events[key]
			if event ~= nil and event[className] then
				return gui.signal(id, key)
			end
			local method = gui.methods[key]
			if method ~= nil then
				return method
			end
			-- A child by name, as Roblox allows.
			local child = gui.childNamed(id, key)
			if child ~= nil then
				return child
			end
			raise(string.format("%s is not a valid member of %s \"%s\"",
				tostring(key), className, tostring(invoke("gui.get", id, "name"))), 2)
		end,
		__newindex = function(_, key, value)
			if key == "Parent" then
				gui.setParent(id, value)
				return
			elseif key == "Name" then
				if type(value) ~= "string" then
					raise("Unable to assign property Name. string expected, got " .. typeof(value), 2)
				end
				invoke("gui.set", id, "name", value)
				return
			end
			local property = gui.properties[key]
			if property == nil or not property[2][className] then
				raise(string.format("%s is not a valid member of %s", tostring(key), className), 2)
			elseif property.readOnly then
				raise(string.format("Unable to assign property %s. Property is read only", key), 2)
			elseif property[1] == "Adornee" and value == nil then
				invoke("gui.set", id, "adornee", nil)
				return
			end
			local kind = property.byClass and property.byClass[className] or property[1]
			local converted = gui.write(kind, value)
			if converted == nil then
				raise(string.format("Unable to assign property %s. %s expected, got %s", key, kind, typeof(value)), 2)
			end
			if invoke("gui.set", id, string.lower(key), converted) == false then
				raise(string.format("Unable to assign property %s. %s is out of range", key, tostring(value)), 2)
			end
		end,
		__tostring = function()
			return tostring(invoke("gui.get", id, "name"))
		end,
		__metatable = LOCKED,
	})
	typeTags[object] = "Instance"
	gui.byId[id] = object
	gui.idOf[object] = id
	return object
end

local function guiId(self, methodName)
	local id = gui.idOf[self]
	if id == nil then
		raise(string.format("Expected ':' not '.' calling member function %s", methodName), 3)
	end
	return id
end

function gui.methods.Destroy(self)
	local id = guiId(self, "Destroy")
	invoke("gui.destroy", id)
	gui.byId[id] = nil
	gui.signals[id] = nil
end

function gui.methods.FindFirstChild(self, name)
	return gui.childNamed(guiId(self, "FindFirstChild"), name)
end

function gui.methods.WaitForChild(self, name)
	local found = gui.childNamed(guiId(self, "WaitForChild"), name)
	if found == nil then
		warn(string.format("Infinite yield possible on WaitForChild(\"%s\")", tostring(name)))
	end
	return found
end

function gui.methods.FindFirstChildOfClass(self, className)
	for _, child in gui.childrenOf(guiId(self, "FindFirstChildOfClass")) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

function gui.methods.FindFirstChildWhichIsA(self, className)
	for _, child in gui.childrenOf(guiId(self, "FindFirstChildWhichIsA")) do
		if child:IsA(className) then
			return child
		end
	end
	return nil
end

function gui.methods.GetChildren(self)
	return gui.childrenOf(guiId(self, "GetChildren"))
end

function gui.methods.ClearAllChildren(self)
	for _, child in gui.childrenOf(guiId(self, "ClearAllChildren")) do
		child:Destroy()
	end
end

function gui.methods.IsA(self, className)
	local own = invoke("gui.class", guiId(self, "IsA"))
	return className == own or className == "Instance"
		or (className == "GuiObject" and gui.isGuiObject[own] == true)
		or (className == "GuiBase2d" and (gui.isGuiObject[own] or own == "ScreenGui") == true)
		or (className == "LayerCollector" and own == "ScreenGui")
		or (className == "GuiButton" and (own == "TextButton" or own == "ImageButton"))
		or (className == "UIComponent" and string.sub(own, 1, 2) == "UI")
		or (className == "UIConstraint" and gui.isConstraint[own] == true)
		or (className == "UILayout" and gui.isLayout[own] == true)
		or (className == "UIGridStyleLayout" and gui.isLayout[own] == true)
end

function gui.methods.CaptureFocus(self)
	invoke("gui.focus", guiId(self, "CaptureFocus"))
end

function gui.methods.ReleaseFocus(self)
	invoke("gui.release", guiId(self, "ReleaseFocus"))
end

function gui.methods.IsFocused(self)
	return invoke("gui.focused") == guiId(self, "IsFocused")
end

function gui.new(className, parent)
	local object = gui.wrap(invoke("gui.create", className))
	if object == nil then
		raise(string.format("Unable to create an Instance of type \"%s\"", tostring(className)), 3)
	end
	if parent ~= nil then
		object.Parent = parent
	end
	return object
end

-- The player's screen: LocalPlayer.PlayerGui.
gui.playerGui = service("PlayerGui", nil, {
	FindFirstChild = function(_, name)
		return gui.childNamed(0, name)
	end,
	WaitForChild = function(_, name)
		return gui.childNamed(0, name)
	end,
	GetChildren = function()
		return gui.childrenOf(0)
	end,
	IsA = function(_, className)
		return className == "PlayerGui" or className == "Instance"
	end,
	__child = function(key)
		return gui.childNamed(0, key)
	end,
})

-- TextChatService: TextChannels.RBXGeneral:SendAsync(text), and MessageReceived with
-- every message, this player's included. No filtering, and none of Roblox's commands.

gui.chatReceived = makeSignal()

gui.generalChannel = service("TextChannel", {
	Name = function()
		return "RBXGeneral"
	end,
	MessageReceived = function()
		return gui.chatReceived
	end,
}, {
	SendAsync = function(_, text)
		if type(text) ~= "string" then
			raise("SendAsync expects a string, got " .. typeof(text), 2)
		end
		invoke("chat.send", text)
	end,
})

gui.textChannels = service("TextChannels", nil, {
	FindFirstChild = function(_, name)
		return if name == "RBXGeneral" then gui.generalChannel else nil
	end,
	WaitForChild = function(_, name)
		return if name == "RBXGeneral" then gui.generalChannel else nil
	end,
	__child = function(key)
		return if key == "RBXGeneral" then gui.generalChannel else nil
	end,
})

-- Chat bubbles over speakers' heads: the ChatScript draws them while this is on.
gui.bubbles = true
gui.bubbleConfiguration = service("BubbleChatConfiguration", {
	Enabled = function()
		return gui.bubbles
	end,
}, nil, function(key, value)
	if key == "Enabled" then
		if type(value) ~= "boolean" then
			raise("Unable to assign property Enabled. bool expected, got " .. typeof(value), 3)
		end
		gui.bubbles = value
		return true
	end
	return false
end)

TextChatService = service("TextChatService", {
	MessageReceived = function()
		return gui.chatReceived
	end,
	TextChannels = function()
		return gui.textChannels
	end,
	BubbleChatConfiguration = function()
		return gui.bubbleConfiguration
	end,
})

-- A message as MessageReceived hands it over.
function gui.message(name, text)
	return table.freeze({ Text = text, PrefixText = name, TextSource = table.freeze({ Name = name }) })
end
"""#
}
