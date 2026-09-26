// The Luau library, part 6 of 16: Models and Folders, PointLights, attachments, welds and joints.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let modelsLightsJoints = #"""
--------------------------------------------------------------------------------
-- Models and Folders

local GroupMeta = {}
local groupForId = setmetatable({}, { __mode = "v" })
local groupMethods = {}
-- What only a Tool has; filled in with the Tools, in part 12.
local toolKit = {}

wrapGroup = function(id)
	if id == nil then
		return nil
	end
	local existing = groupForId[id]
	if existing ~= nil then
		return existing
	end
	local proxy = setmetatable({}, GroupMeta)
	groupIdOf[proxy] = id
	groupForId[id] = proxy
	typeTags[proxy] = "Instance"
	return proxy
end

local function groupKind(id)
	local kind = invoke("group.get", id, "kind")
	if kind == nil then
		raise("attempt to use a Model that has been destroyed", 3)
	end
	return kind
end

for name, method in treeMethods do
	groupMethods[name] = function(self, ...)
		checkSelf(self, "Instance", name)
		return method(self, ...)
	end
end

function groupMethods.Destroy(self)
	checkSelf(self, "Instance", "Destroy")
	invoke("group.destroy", groupIdOf[self])
end

-- As with parts, the clone goes straight into the Workspace.
function groupMethods.Clone(self)
	checkSelf(self, "Instance", "Clone")
	return wrapGroup(invoke("group.clone", groupIdOf[self]))
end

function groupMethods.IsA(self, className)
	checkSelf(self, "Instance", "IsA")
	local kind = groupKind(groupIdOf[self])
	if kind == "Model" then
		return className == "Model" or className == "PVInstance" or className == "Instance"
	elseif kind == "Tool" then
		return className == "Tool" or className == "BackpackItem" or className == "Instance"
	end
	return className == "Folder" or className == "Instance"
end

-- A box around everything inside, as a CFrame at its middle and a size.
function groupMethods.GetBoundingBox(self)
	checkSelf(self, "Instance", "GetBoundingBox")
	local box = invoke("node.bounds", groupIdOf[self])
	if box == nil then
		return CFrame.new(), vector(0, 0, 0)
	end
	return cframe(box[1], box[2], box[3], 1, 0, 0, 0, 1, 0, 0, 0, 1), vector(box[4], box[5], box[6])
end

function groupMethods.GetExtentsSize(self)
	checkSelf(self, "Instance", "GetExtentsSize")
	local _, size = groupMethods.GetBoundingBox(self)
	return size
end

-- Moves the Model so its pivot is at a position, keeping its rotation.
function groupMethods.MoveTo(self, position)
	checkSelf(self, "Instance", "MoveTo")
	checkOther(position, "Vector3", "MoveTo")
	local pivot = self:GetPivot()
	self:PivotTo(pivot + (position - pivot.Position))
end

GroupMeta.__index = function(group, key)
	-- A Folder that went into a Player or ReplicatedStorage is a data Folder now.
	if dataKit.adopted[group] then
		return dataKit.Meta.__index(group, key)
	end
	local id = groupIdOf[group]
	if key == "Name" then
		return invoke("group.get", id, "name") or raise("attempt to use a Model that has been destroyed", 2)
	elseif key == "ClassName" then
		return groupKind(id)
	elseif key == "Parent" then
		local kind = invoke("group.get", id, "kind")
		if kind == "Tool" then
			return toolKit.parent(id)
		end
		return if kind then wrapToken(invoke("tree.parent", id)) else nil
	elseif key == "PrimaryPart" then
		return wrapPart(invoke("group.get", id, "primarypart"))
	elseif key == "WorldPivot" then
		return groupMethods.GetPivot(group)
	end
	local isToolMember, value = toolKit.member(id, key)
	if isToolMember then
		return value
	end
	local method = groupMethods[key]
	if method ~= nil then
		return method
	end
	if type(key) == "string" then
		local child = wrapToken(invoke("tree.find", id, key, false))
		if child ~= nil then
			return child
		end
	end
	raise(string.format("%s is not a valid member of %s \"%s\"", tostring(key), groupKind(id),
		invoke("group.get", id, "name") or "?"), 2)
end

GroupMeta.__newindex = function(group, key, value)
	if dataKit.adopted[group] then
		return dataKit.Meta.__newindex(group, key, value)
	end
	local id = groupIdOf[group]
	if toolKit.assign(id, key, value) then
		return
	end
	-- A Folder going into a Player (their leaderstats), ReplicatedStorage or a data
	-- Folder leaves the Workspace tree and becomes a data Folder.
	local place = key == "Parent" and value ~= nil and value ~= workspace_ and partIdOf[value] == nil
		and groupIdOf[value] == nil and dataKit.placeOf(value)
	if place then
		if not invoke("data.fromGroup", id, place) then
			raise("Unable to assign property Parent. Only an empty Folder can go there", 2)
		end
		dataKit.adopt(group, id)
		return
	end
	if key == "Parent" then
		assignParent(group, value, function(target)
			invoke("group.destroy", target)
		end)
	elseif key == "Name" then
		if type(value) ~= "string" then
			raise("Unable to assign property Name. string expected, got " .. typeof(value), 2)
		end
		invoke("group.set", id, "name", value)
	elseif key == "PrimaryPart" then
		if value ~= nil then
			local partId = partIdOf[value]
			if partId == nil then
				raise("Unable to assign property PrimaryPart. Part expected, got " .. typeof(value), 2)
			end
			if not treeMethods.IsDescendantOf(value, group) then
				raise("Unable to assign property PrimaryPart. It must be inside the Model", 2)
			end
			invoke("group.set", id, "primarypart", partId)
		else
			invoke("group.set", id, "primarypart", nil)
		end
	else
		raise(string.format("Unable to assign property %s of %s", tostring(key), groupKind(id)), 2)
	end
end

GroupMeta.__tostring = function(group)
	if dataKit.adopted[group] then
		return dataKit.Meta.__tostring(group)
	end
	return invoke("group.get", groupIdOf[group], "name") or "Model"
end

GroupMeta.__metatable = LOCKED

--------------------------------------------------------------------------------
-- PointLight: light from the middle of a part. One per part; made with
-- Instance.new("PointLight", part), or by setting Parent to a part.

-- PointLight's internals, in one table (the top-level local budget).
local lights = {}
lights.PointLightMeta = {}
lights.lightData = setmetatable({}, { __mode = "k" })
lights.lightForPart = setmetatable({}, { __mode = "v" })

lights.lightProperties = {
	Enabled = { host = "enabled", kind = "boolean", default = true },
	Brightness = { host = "brightness", kind = "number", default = 1 },
	Range = { host = "range", kind = "number", default = 8 },
	Shadows = { host = "shadows", kind = "boolean", default = false },
	Color = { host = "color", kind = "Color3" },
}

function lights.wrapLight(partId)
	local existing = lights.lightForPart[partId]
	if existing ~= nil then
		return existing
	end
	local object = setmetatable({}, lights.PointLightMeta)
	lights.lightData[object] = { part = partId }
	lights.lightForPart[partId] = object
	typeTags[object] = "Instance"
	return object
end

pointLightOf = function(partId)
	if partId == nil or not invoke("light.has", partId) then
		return nil
	end
	return lights.wrapLight(partId)
end

function lights.newPointLight()
	local object = setmetatable({}, lights.PointLightMeta)
	lights.lightData[object] = { pending = {} }
	typeTags[object] = "Instance"
	return object
end

function lights.checkLightValue(key, value)
	local property = lights.lightProperties[key]
	local ok = if property.kind == "Color3" then isColor(value) else type(value) == property.kind
	if not ok then
		raise(string.format("Unable to assign property %s. %s expected, got %s",
			key, if property.kind == "boolean" then "bool" else property.kind, typeof(value)), 3)
	end
	if property.kind == "Color3" then
		return { value[1], value[2], value[3] }
	end
	return value
end

-- Puts a light into a part, carrying over anything set before it had one.
function lights.parentLight(object, part)
	local data = lights.lightData[object]
	local partId = partIdOf[part]
	if partId == nil then
		raise("PointLight.Parent must be a Part", 3)
	end
	if data.part == partId then
		return
	end
	if invoke("light.has", partId) then
		raise("That part already has a PointLight", 3)
	end
	if data.part ~= nil then
		invoke("light.destroy", data.part)
		lights.lightForPart[data.part] = nil
	end
	invoke("light.create", partId)
	for key, value in data.pending or {} do
		invoke("light.set", partId, lights.lightProperties[key].host, value)
	end
	data.pending = nil
	data.part = partId
	lights.lightForPart[partId] = object
end

function lights.unparentLight(object)
	local data = lights.lightData[object]
	if data.part == nil then
		return
	end
	-- Keep its settings, as a Roblox light keeps its properties out of the world.
	local pending = {}
	for key, property in lights.lightProperties do
		pending[key] = invoke("light.get", data.part, property.host)
	end
	invoke("light.destroy", data.part)
	lights.lightForPart[data.part] = nil
	data.part = nil
	data.pending = pending
end

lights.PointLightMeta.__index = function(object, key)
	local data = lights.lightData[object]
	local property = lights.lightProperties[key]
	if property ~= nil then
		local raw
		if data.part ~= nil then
			raw = invoke("light.get", data.part, property.host)
		else
			raw = data.pending[key]
		end
		if raw == nil then
			if property.kind == "Color3" then return color(1, 1, 1) end
			return property.default
		end
		if property.kind == "Color3" then
			return color(raw[1], raw[2], raw[3])
		end
		return raw
	end
	if key == "Name" or key == "ClassName" then
		return "PointLight"
	elseif key == "Parent" then
		return if data.part ~= nil and invoke("part.exists", data.part) then wrapPart(data.part) else nil
	elseif key == "Destroy" then
		return function(self)
			lights.unparentLight(self)
		end
	elseif key == "IsA" then
		return function(_, className)
			return className == "PointLight" or className == "Light" or className == "Instance"
		end
	end
	raise(string.format("%s is not a valid member of PointLight", tostring(key)), 2)
end

lights.PointLightMeta.__newindex = function(object, key, value)
	local data = lights.lightData[object]
	if key == "Parent" then
		if value == nil then
			lights.unparentLight(object)
		else
			lights.parentLight(object, value)
		end
		return
	end
	local property = lights.lightProperties[key]
	if property == nil then
		raise(string.format("%s is not a valid member of PointLight", tostring(key)), 2)
	end
	local converted = lights.checkLightValue(key, value)
	if data.part ~= nil then
		invoke("light.set", data.part, property.host, converted)
	else
		data.pending[key] = converted
	end
end

lights.PointLightMeta.__tostring = function()
	return "PointLight"
end

lights.PointLightMeta.__metatable = LOCKED

--------------------------------------------------------------------------------
-- ClickDetector: clicking its part fires MouseClick(player) — on the host, for whoever
-- clicked — with MouseHoverEnter and MouseHoverLeave as the mouse comes and goes. One
-- per part, kept in the part like a PointLight.

mouseKit.DetectorMeta = {}
mouseKit.detectorData = setmetatable({}, { __mode = "k" })
mouseKit.detectorForPart = setmetatable({}, { __mode = "v" })
mouseKit.signals = {}
mouseKit.events = { MouseClick = true, MouseHoverEnter = true, MouseHoverLeave = true, RightMouseClick = true }

function mouseKit.wrapDetector(partId)
	local existing = mouseKit.detectorForPart[partId]
	if existing ~= nil then
		return existing
	end
	local object = setmetatable({}, mouseKit.DetectorMeta)
	mouseKit.detectorData[object] = { part = partId }
	mouseKit.detectorForPart[partId] = object
	typeTags[object] = "Instance"
	return object
end

function mouseKit.detectorOf(partId)
	if partId == nil or not invoke("click.has", partId) then
		return nil
	end
	return mouseKit.wrapDetector(partId)
end

function mouseKit.newDetector()
	local object = setmetatable({}, mouseKit.DetectorMeta)
	mouseKit.detectorData[object] = { distance = 32 }
	typeTags[object] = "Instance"
	return object
end

function mouseKit.parentDetector(object, part)
	local data = mouseKit.detectorData[object]
	local partId = partIdOf[part]
	if partId == nil then
		raise("ClickDetector.Parent must be a Part", 3)
	end
	if data.part == partId then
		return
	end
	if invoke("click.has", partId) then
		raise("That part already has a ClickDetector", 3)
	end
	local distance = data.distance
	if data.part ~= nil then
		distance = invoke("click.get", data.part, "maxactivationdistance")
		invoke("click.destroy", data.part)
		mouseKit.detectorForPart[data.part] = nil
	end
	invoke("click.create", partId)
	invoke("click.set", partId, "maxactivationdistance", distance or 32)
	-- Anything connected before it had a part goes with it.
	if mouseKit.signals[object] ~= nil and mouseKit.signals[partId] == nil then
		mouseKit.signals[partId] = mouseKit.signals[object]
		mouseKit.signals[object] = nil
	end
	data.part = partId
	data.distance = nil
	mouseKit.detectorForPart[partId] = object
end

function mouseKit.unparentDetector(object)
	local data = mouseKit.detectorData[object]
	if data.part == nil then
		return
	end
	data.distance = invoke("click.get", data.part, "maxactivationdistance")
	invoke("click.destroy", data.part)
	mouseKit.detectorForPart[data.part] = nil
	data.part = nil
end

mouseKit.DetectorMeta.__index = function(object, key)
	local data = mouseKit.detectorData[object]
	if key == "MaxActivationDistance" then
		if data.part ~= nil then
			return invoke("click.get", data.part, "maxactivationdistance") or 32
		end
		return data.distance
	elseif key == "Name" or key == "ClassName" then
		return "ClickDetector"
	elseif key == "Parent" then
		return if data.part ~= nil and invoke("part.exists", data.part) then wrapPart(data.part) else nil
	elseif mouseKit.events[key] then
		-- Signals belong to the part, so they carry over with the detector.
		return mouseKit.signal(data.part or object, key)
	elseif key == "Destroy" then
		return function(self)
			mouseKit.unparentDetector(self)
		end
	elseif key == "IsA" then
		return function(_, className)
			return className == "ClickDetector" or className == "Instance"
		end
	end
	raise(string.format("%s is not a valid member of ClickDetector", tostring(key)), 2)
end

mouseKit.DetectorMeta.__newindex = function(object, key, value)
	local data = mouseKit.detectorData[object]
	if key == "Parent" then
		if value == nil then
			mouseKit.unparentDetector(object)
		else
			mouseKit.parentDetector(object, value)
		end
	elseif key == "MaxActivationDistance" then
		if type(value) ~= "number" then
			raise("Unable to assign property MaxActivationDistance. number expected, got " .. typeof(value), 2)
		end
		if data.part ~= nil then
			invoke("click.set", data.part, "maxactivationdistance", value)
		else
			data.distance = value
		end
	else
		raise(string.format("%s is not a valid member of ClickDetector", tostring(key)), 2)
	end
end

mouseKit.DetectorMeta.__tostring = function()
	return "ClickDetector"
end

mouseKit.DetectorMeta.__metatable = LOCKED

--------------------------------------------------------------------------------
-- Attachments, welds and joints
--
-- An Attachment is a point and an axis on a part; a joint connects two of them, as in
-- Roblox. A WeldConstraint holds two parts together directly, and welded parts move
-- as one assembly.

-- Attachment and constraint internals, in one table (the top-level local budget).
local constraintKit = {}
constraintKit.AttachmentMeta = {}
constraintKit.attachmentForId = setmetatable({}, { __mode = "v" })
constraintKit.attachmentMethods = {}

wrapAttachment = function(id)
	if id == nil then
		return nil
	end
	local existing = constraintKit.attachmentForId[id]
	if existing ~= nil then
		return existing
	end
	local proxy = setmetatable({}, constraintKit.AttachmentMeta)
	attachmentIdOf[proxy] = id
	constraintKit.attachmentForId[id] = proxy
	typeTags[proxy] = "Instance"
	return proxy
end

constraintKit.attachmentVectors = {
	Position = "position", Axis = "axis", SecondaryAxis = "secondaryaxis",
	WorldPosition = "worldposition", WorldAxis = "worldaxis", WorldSecondaryAxis = "worldsecondaryaxis",
}

for name, method in treeMethods do
	constraintKit.attachmentMethods[name] = function(self, ...)
		checkSelf(self, "Instance", name)
		return method(self, ...)
	end
end

function constraintKit.attachmentMethods.Destroy(self)
	checkSelf(self, "Instance", "Destroy")
	invoke("attachment.destroy", attachmentIdOf[self])
end

function constraintKit.attachmentMethods.IsA(_, className)
	return className == "Attachment" or className == "Instance"
end

constraintKit.AttachmentMeta.__index = function(object, key)
	local id = attachmentIdOf[object]
	local vectorKey = constraintKit.attachmentVectors[key]
	if vectorKey ~= nil then
		local raw = invoke("attachment.get", id, vectorKey)
		if raw == nil then
			raise("attempt to use an Attachment that has been destroyed", 2)
		end
		return toVector(raw)
	end
	if key == "Name" then
		return invoke("attachment.get", id, "name") or raise("attempt to use an Attachment that has been destroyed", 2)
	elseif key == "ClassName" then
		return "Attachment"
	elseif key == "Parent" then
		return wrapToken(invoke("tree.parent", id))
	elseif key == "CFrame" then
		-- The attachment's own frame: its axis is the X of the CFrame, as in Roblox.
		local position = toVector(invoke("attachment.get", id, "position"))
		local axis = toVector(invoke("attachment.get", id, "axis"))
		local secondary = toVector(invoke("attachment.get", id, "secondaryaxis"))
		return CFrame.fromMatrix(position, axis, secondary)
	elseif key == "WorldCFrame" then
		return CFrame.fromMatrix(object.WorldPosition, object.WorldAxis, object.WorldSecondaryAxis)
	end
	local method = constraintKit.attachmentMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of Attachment", tostring(key)), 2)
end

constraintKit.AttachmentMeta.__newindex = function(object, key, value)
	local id = attachmentIdOf[object]
	if key == "Parent" then
		assignParent(object, value, function(target)
			invoke("attachment.destroy", target)
		end)
		return
	elseif key == "Name" then
		if type(value) ~= "string" then
			raise("Unable to assign property Name. string expected, got " .. typeof(value), 2)
		end
		invoke("attachment.set", id, "name", value)
		return
	elseif key == "Position" or key == "Axis" or key == "SecondaryAxis" then
		if not isVector(value) then
			raise(string.format("Unable to assign property %s. Vector3 expected, got %s", key, typeof(value)), 2)
		end
		invoke("attachment.set", id, constraintKit.attachmentVectors[key], { value[1], value[2], value[3] })
		return
	elseif key == "CFrame" then
		if not isCFrame(value) then
			raise("Unable to assign property CFrame. CFrame expected, got " .. typeof(value), 2)
		end
		invoke("attachment.set", id, "position", { value[1], value[2], value[3] })
		invoke("attachment.set", id, "axis", { value.RightVector[1], value.RightVector[2], value.RightVector[3] })
		invoke("attachment.set", id, "secondaryaxis", { value.UpVector[1], value.UpVector[2], value.UpVector[3] })
		return
	end
	raise(string.format("%s is not a valid member of Attachment", tostring(key)), 2)
end

constraintKit.AttachmentMeta.__tostring = function(object)
	return invoke("attachment.get", attachmentIdOf[object], "name") or "Attachment"
end

constraintKit.AttachmentMeta.__metatable = LOCKED

-- Joints. Each kind has its own properties, named as Roblox names them.
constraintKit.constraintNumbers = {
	LowerAngle = "lowerangle", UpperAngle = "upperangle", AngularVelocity = "angularvelocity",
	MotorMaxTorque = "motormaxtorque", TargetAngle = "targetangle", AngularSpeed = "angularspeed",
	ServoMaxTorque = "servomaxtorque", LowerLimit = "lowerlimit", UpperLimit = "upperlimit",
	Velocity = "velocity", MotorMaxForce = "motormaxforce", TargetPosition = "targetposition",
	Speed = "speed", ServoMaxForce = "servomaxforce", Length = "length", FreeLength = "freelength",
	Stiffness = "stiffness", Damping = "damping",
}

constraintKit.constraintMembers = {
	WeldConstraint = { Part0 = "part", Part1 = "part", Enabled = "bool", Active = "read" },
	HingeConstraint = {
		Attachment0 = "attachment", Attachment1 = "attachment", Enabled = "bool", Active = "read",
		ActuatorType = "actuator", LimitsEnabled = "bool", LowerAngle = "number", UpperAngle = "number",
		AngularVelocity = "number", MotorMaxTorque = "number", TargetAngle = "number",
		AngularSpeed = "number", ServoMaxTorque = "number", CurrentAngle = "read",
	},
	BallSocketConstraint = {
		Attachment0 = "attachment", Attachment1 = "attachment", Enabled = "bool", Active = "read",
	},
	RopeConstraint = {
		Attachment0 = "attachment", Attachment1 = "attachment", Enabled = "bool", Active = "read",
		Length = "number", CurrentDistance = "read",
	},
	SpringConstraint = {
		Attachment0 = "attachment", Attachment1 = "attachment", Enabled = "bool", Active = "read",
		FreeLength = "number", Stiffness = "number", Damping = "number", CurrentLength = "read",
	},
	PrismaticConstraint = {
		Attachment0 = "attachment", Attachment1 = "attachment", Enabled = "bool", Active = "read",
		ActuatorType = "actuator", LimitsEnabled = "bool", LowerLimit = "number", UpperLimit = "number",
		Velocity = "number", MotorMaxForce = "number", TargetPosition = "number", Speed = "number",
		ServoMaxForce = "number", CurrentPosition = "read",
	},
}

constraintKit.ConstraintMeta = {}
constraintKit.constraintForId = setmetatable({}, { __mode = "v" })
constraintKit.constraintMethods = {}

wrapConstraint = function(id)
	if id == nil then
		return nil
	end
	local existing = constraintKit.constraintForId[id]
	if existing ~= nil then
		return existing
	end
	local proxy = setmetatable({}, constraintKit.ConstraintMeta)
	constraintIdOf[proxy] = id
	constraintKit.constraintForId[id] = proxy
	typeTags[proxy] = "Instance"
	return proxy
end

function constraintKit.constraintKind(id)
	local kind = invoke("constraint.get", id, "kind")
	if kind == nil then
		raise("attempt to use a constraint that has been destroyed", 3)
	end
	return kind
end

for name, method in treeMethods do
	constraintKit.constraintMethods[name] = function(self, ...)
		checkSelf(self, "Instance", name)
		return method(self, ...)
	end
end

function constraintKit.constraintMethods.Destroy(self)
	checkSelf(self, "Instance", "Destroy")
	invoke("constraint.destroy", constraintIdOf[self])
end

function constraintKit.constraintMethods.IsA(self, className)
	checkSelf(self, "Instance", "IsA")
	local kind = constraintKit.constraintKind(constraintIdOf[self])
	if className == kind or className == "Instance" then
		return true
	end
	-- Roblox's joints all descend from Constraint; a weld does not.
	return className == "Constraint" and kind ~= "WeldConstraint"
end

constraintKit.ConstraintMeta.__index = function(object, key)
	local id = constraintIdOf[object]
	local kind = constraintKit.constraintKind(id)
	local members = constraintKit.constraintMembers[kind]
	local member = members[key]
	if member == "number" then
		return invoke("constraint.get", id, constraintKit.constraintNumbers[key])
	elseif member == "bool" then
		return invoke("constraint.get", id, string.lower(key))
	elseif member == "actuator" then
		return Enum.ActuatorType[invoke("constraint.get", id, "actuatortype") or "None"]
	elseif member == "part" then
		return wrapPart(invoke("constraint.get", id, string.lower(key)))
	elseif member == "attachment" then
		return wrapAttachment(invoke("constraint.get", id, string.lower(key)))
	elseif member == "read" then
		if key == "Active" then
			return invoke("constraint.get", id, "active")
		elseif key == "CurrentAngle" or key == "CurrentPosition" then
			-- What the physics is actually doing, while the game is running.
			return invoke("physics.joint", id)
		elseif key == "CurrentDistance" or key == "CurrentLength" then
			return invoke("constraint.get", id, "distance")
		end
	end
	if key == "Name" then
		return invoke("constraint.get", id, "name")
	elseif key == "ClassName" then
		return kind
	elseif key == "Parent" then
		return wrapToken(invoke("tree.parent", id))
	end
	local method = constraintKit.constraintMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of %s", tostring(key), kind), 2)
end

constraintKit.ConstraintMeta.__newindex = function(object, key, value)
	local id = constraintIdOf[object]
	local kind = constraintKit.constraintKind(id)
	local member = constraintKit.constraintMembers[kind][key]
	if key == "Parent" then
		assignParent(object, value, function(target)
			invoke("constraint.destroy", target)
		end)
		return
	elseif key == "Name" then
		if type(value) ~= "string" then
			raise("Unable to assign property Name. string expected, got " .. typeof(value), 2)
		end
		invoke("constraint.set", id, "name", value)
		return
	elseif member == "number" then
		if type(value) ~= "number" then
			raise(string.format("Unable to assign property %s. number expected, got %s", key, typeof(value)), 2)
		end
		invoke("constraint.set", id, constraintKit.constraintNumbers[key], value)
		return
	elseif member == "bool" then
		if type(value) ~= "boolean" then
			raise(string.format("Unable to assign property %s. bool expected, got %s", key, typeof(value)), 2)
		end
		invoke("constraint.set", id, string.lower(key), value)
		return
	elseif member == "actuator" then
		local name = enumName(value, "ActuatorType")
		if name == nil then
			raise("Unable to assign property ActuatorType. EnumItem expected, got " .. typeof(value), 2)
		end
		invoke("constraint.set", id, "actuatortype", name)
		return
	elseif member == "part" then
		local partId = if value == nil then nil else partIdOf[value]
		if value ~= nil and partId == nil then
			raise(string.format("Unable to assign property %s. Part expected, got %s", key, typeof(value)), 2)
		end
		invoke("constraint.set", id, string.lower(key), partId)
		return
	elseif member == "attachment" then
		local attachmentId = if value == nil then nil else attachmentIdOf[value]
		if value ~= nil and attachmentId == nil then
			raise(string.format("Unable to assign property %s. Attachment expected, got %s", key, typeof(value)), 2)
		end
		invoke("constraint.set", id, string.lower(key), attachmentId)
		return
	elseif member == "read" then
		raise(string.format("Unable to assign property %s. Property is read only", key), 2)
	end
	raise(string.format("%s is not a valid member of %s", tostring(key), kind), 2)
end

constraintKit.ConstraintMeta.__tostring = function(object)
	return invoke("constraint.get", constraintIdOf[object], "name") or "Constraint"
end

constraintKit.ConstraintMeta.__metatable = LOCKED

"""#
}
