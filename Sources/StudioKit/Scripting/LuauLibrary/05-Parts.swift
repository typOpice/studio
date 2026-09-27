// The Luau library, part 5 of 16: parts, the tree they sit in, and part physics.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let parts = #"""
--------------------------------------------------------------------------------
-- Parts

local PartMeta = {}
local partIdOf = setmetatable({}, { __mode = "k" })
local partForId = setmetatable({}, { __mode = "v" })
local workspace_ -- assigned below; parts report it as their Parent
-- A part's Touched / TouchEnded signal, by name; assigned once signals exist.
local partSignal

local function wrapPart(id)
	if id == nil then
		return nil
	end
	local existing = partForId[id]
	if existing ~= nil then
		return existing
	end
	local proxy = setmetatable({}, PartMeta)
	partIdOf[proxy] = id
	partForId[id] = proxy
	typeTags[proxy] = "Instance"
	return proxy
end

local function toVector(list)
	return vector(list[1], list[2], list[3])
end

local function toColor(list)
	return color(list[1], list[2], list[3])
end

-- Each property: how to read it from the host, and how to check and convert a value
-- being assigned. `write` returns the host value, or nil and the reason it failed.
local partProperties = {
	Name = {
		host = "name",
		write = function(value)
			if type(value) ~= "string" then
				return nil, "string expected, got " .. typeof(value)
			end
			return value
		end,
	},
	Position = {
		host = "position",
		read = toVector,
		write = function(value)
			if not isVector(value) then
				return nil, "Vector3 expected, got " .. typeof(value)
			end
			return { value[1], value[2], value[3] }
		end,
	},
	Size = {
		host = "size",
		read = toVector,
		write = function(value)
			if not isVector(value) then
				return nil, "Vector3 expected, got " .. typeof(value)
			end
			return { value[1], value[2], value[3] }
		end,
	},
	-- MeshPart only: the 3D model it shows ("studio://Name"), its picture, how it collides,
	-- and the size the model was made at.
	MeshId = {
		host = "meshid",
		meshOnly = true,
		write = function(value)
			if type(value) ~= "string" then
				return nil, "string expected, got " .. typeof(value)
			end
			return value
		end,
	},
	TextureID = {
		host = "textureid",
		meshOnly = true,
		write = function(value)
			if type(value) ~= "string" then
				return nil, "string expected, got " .. typeof(value)
			end
			return value
		end,
	},
	CollisionFidelity = {
		host = "collisionfidelity",
		meshOnly = true,
		read = function(raw)
			return Enum.CollisionFidelity[raw]
		end,
		write = function(value)
			local name = enumName(value, "CollisionFidelity")
			if name == nil or not pcall(function() return Enum.CollisionFidelity[name] end) then
				return nil, "EnumItem expected, got " .. typeof(value)
			end
			return if name == "Default" then "Hull" else name
		end,
	},
	MeshSize = { host = "meshsize", meshOnly = true, read = toVector, readOnly = true },
	-- Physics (during play; zero in the editor, where nothing moves).
	AssemblyLinearVelocity = { motion = "velocity" },
	Velocity = { motion = "velocity" },
	AssemblyAngularVelocity = { motion = "angularvelocity" },
	RotVelocity = { motion = "angularvelocity" },
	Mass = { host = "mass", readOnly = true },
	AssemblyMass = { host = "mass", readOnly = true },
	CFrame = {
		host = "cframe",
		read = cframeMath.cframeFromList,
		write = function(value)
			if not isCFrame(value) then
				return nil, "CFrame expected, got " .. typeof(value)
			end
			return cframeMath.cframeList(value)
		end,
	},
	Orientation = {
		host = "rotation",
		read = toVector,
		write = function(value)
			if not isVector(value) then
				return nil, "Vector3 expected, got " .. typeof(value)
			end
			return { value[1], value[2], value[3] }
		end,
	},
	Color = {
		host = "color",
		read = toColor,
		write = function(value)
			if not isColor(value) then
				return nil, "Color3 expected, got " .. typeof(value)
			end
			return { value[1], value[2], value[3] }
		end,
	},
	Transparency = {
		host = "transparency",
		write = function(value)
			if type(value) ~= "number" then
				return nil, "number expected, got " .. typeof(value)
			end
			return value
		end,
	},
	CanCollide = {
		host = "cancollide",
		write = function(value)
			if type(value) ~= "boolean" then
				return nil, "bool expected, got " .. typeof(value)
			end
			return value
		end,
	},
	CanTouch = {
		host = "cantouch",
		write = function(value)
			if type(value) ~= "boolean" then
				return nil, "bool expected, got " .. typeof(value)
			end
			return value
		end,
	},
	Anchored = {
		host = "anchored",
		write = function(value)
			if type(value) ~= "boolean" then
				return nil, "bool expected, got " .. typeof(value)
			end
			return value
		end,
	},
	Locked = {
		host = "locked",
		write = function(value)
			if type(value) ~= "boolean" then
				return nil, "bool expected, got " .. typeof(value)
			end
			return value
		end,
	},
	Material = {
		host = "material",
		read = function(name)
			return Enum.Material[materialFromHost[name] or "Plastic"]
		end,
		write = function(value)
			local name = enumName(value, "Material")
			local host = name and materialToHost[name]
			if host == nil then
				if name ~= nil then
					return nil, name .. " is a terrain material; a part can be Plastic, SmoothPlastic, Metal, Neon, Wood or Water"
				end
				return nil, "EnumItem expected, got " .. typeof(value)
			end
			return host
		end,
	},
	Shape = {
		host = "shape",
		read = function(name)
			return Enum.PartType[shapeFromHost[name] or "Block"]
		end,
		write = function(value)
			local name = enumName(value, "PartType")
			local host = name and shapeToHost[name]
			if host == nil then
				return nil, "EnumItem expected, got " .. typeof(value)
			end
			return host
		end,
	},
	Shader = {
		host = "shader",
		nullable = true,
		read = wrapShader,
		write = function(value)
			if value == nil then
				return false -- sentinel for "clear it"; see __newindex
			end
			if typeTags[value] ~= "Shader" then
				return nil, "Shader expected, got " .. typeof(value)
			end
			return shaderIdOf[value]
		end,
	},
}

local partMethods = {}
-- A part's PointLight, if it has one; assigned with PointLight below.
local pointLightOf
-- The mouse and ClickDetectors, filled in with PointLight's neighbours in part 6.
local mouseKit = {}
-- Sounds, filled in with the services in part 14.
local soundKit = {}
-- ParticleEmitters, filled in beside the Sounds in part 14.
local emitterKit = {}
-- Lighting's Sky, Atmosphere and Clouds, filled in there too.
local skyKit = {}
-- workspace.Terrain, and Region3, filled in there as well.
local terrainKit = {}
-- LogService's signal, filled in with the service (part 14).
local logKit = {}

local function partName(id)
	return invoke("part.get", id, "name") or "Part"
end

-- Models and Folders; assigned below, with their proxies.
local groupIdOf = setmetatable({}, { __mode = "k" })
local wrapGroup
-- Attachments and the welds and joints between them; assigned below too.
local attachmentIdOf = setmetatable({}, { __mode = "k" })
local constraintIdOf = setmetatable({}, { __mode = "k" })
local wrapAttachment, wrapConstraint

-- Folders, Value objects, remotes and ModuleScripts, filled in by part 15.
local dataKit = {}

-- The tree. The host hands back tokens — "p:<id>" a part, "g:<id>" a Model or
-- Folder, "w" the Workspace, "v:<id>" a data object, "m:<id>" a ModuleScript — and
-- takes a node's id, or "w", as a parent.
local function wrapToken(token)
	if token == nil then
		return nil
	elseif token == "w" then
		return workspace_
	elseif token == "rs" then
		return dataKit.ReplicatedStorage
	elseif token == "ss" then
		return dataKit.ServerStorage
	elseif token == "terrain" then
		return terrainKit.object
	end
	local id = string.sub(token, 3)
	local kind = string.sub(token, 1, 1)
	if kind == "p" then
		return wrapPart(id)
	elseif kind == "a" then
		return wrapAttachment(id)
	elseif kind == "c" then
		return wrapConstraint(id)
	elseif kind == "s" then
		return soundKit.wrap(id)
	elseif kind == "e" then
		return emitterKit.wrap(id)
	elseif kind == "v" then
		return dataKit.wrap(id)
	elseif kind == "m" then
		return dataKit.wrapModule(id)
	end
	return wrapGroup(id)
end

local function wrapTokens(tokens)
	local list = table.create(#tokens)
	for index, token in tokens do
		list[index] = wrapToken(token)
	end
	return list
end

local function nodeId(object)
	if object == workspace_ then
		return "w"
	end
	return partIdOf[object] or groupIdOf[object] or attachmentIdOf[object] or constraintIdOf[object]
end

local function parentOf(object)
	local id = nodeId(object)
	if id == nil or id == "w" then
		return nil
	end
	return wrapToken(invoke("tree.parent", id))
end

-- Sets Parent the Roblox way: to the Workspace, a Model, a Folder or a part.
local function assignParent(object, value, destroy)
	local id = nodeId(object)
	if value == nil then
		destroy(id)
		return
	end
	-- Kept out of the world, in ReplicatedStorage or ServerStorage.
	if value == dataKit.ReplicatedStorage or value == dataKit.ServerStorage then
		if not invoke("tree.store", id, if value == dataKit.ReplicatedStorage then "rs" else "ss") then
			raise("Unable to assign property Parent. Only parts, Models and Folders can be kept there", 3)
		end
		return
	end
	local target = nodeId(value)
	if target == nil then
		raise("Unable to assign property Parent. Parent must be the Workspace, a Model, a Folder or a Part, got "
			.. typeof(value), 3)
	end
	if not invoke("tree.setparent", id, target) then
		raise("Unable to assign property Parent. It can't go inside itself", 3)
	end
end

-- The same parent-and-child methods for parts, Models, Folders and the Workspace.
local treeMethods = {}

function treeMethods.GetChildren(self)
	return wrapTokens(invoke("tree.children", nodeId(self)))
end

function treeMethods.GetDescendants(self)
	return wrapTokens(invoke("tree.descendants", nodeId(self)))
end

function treeMethods.FindFirstChild(self, name, recursive)
	if type(name) ~= "string" then
		return nil
	end
	return wrapToken(invoke("tree.find", nodeId(self), name, recursive == true))
end

function treeMethods.WaitForChild(self, name)
	local child = self:FindFirstChild(name)
	if child == nil then
		warn(string.format("Infinite yield possible on '%s:WaitForChild(\"%s\")'", self:GetFullName(), tostring(name)))
	end
	return child
end

function treeMethods.FindFirstChildOfClass(self, className)
	for _, child in self:GetChildren() do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

function treeMethods.FindFirstChildWhichIsA(self, className)
	for _, child in self:GetChildren() do
		if child:IsA(className) then
			return child
		end
	end
	return nil
end

function treeMethods.IsDescendantOf(self, ancestor)
	local current = parentOf(self)
	while current ~= nil do
		if current == ancestor then
			return true
		end
		if current == workspace_ then
			return false
		end
		current = parentOf(current)
	end
	return false
end

function treeMethods.IsAncestorOf(self, descendant)
	return descendant ~= nil and nodeId(descendant) ~= nil and treeMethods.IsDescendantOf(descendant, self)
end

function treeMethods.FindFirstAncestor(self, name)
	local current = parentOf(self)
	while current ~= nil and current ~= workspace_ do
		if current.Name == name then
			return current
		end
		current = parentOf(current)
	end
	return if current == workspace_ and name == "Workspace" then current else nil
end

function treeMethods.FindFirstAncestorOfClass(self, className)
	local current = parentOf(self)
	while current ~= nil do
		if current.ClassName == className then
			return current
		end
		if current == workspace_ then
			return nil
		end
		current = parentOf(current)
	end
	return nil
end

function treeMethods.FindFirstAncestorWhichIsA(self, className)
	local current = parentOf(self)
	while current ~= nil do
		if current:IsA(className) then
			return current
		end
		if current == workspace_ then
			return nil
		end
		current = parentOf(current)
	end
	return nil
end

function treeMethods.GetFullName(self)
	local names = {}
	local current = self
	while current ~= nil and current ~= workspace_ do
		table.insert(names, 1, current.Name)
		current = parentOf(current)
	end
	table.insert(names, 1, "Workspace")
	return table.concat(names, ".")
end

function treeMethods.ClearAllChildren(self)
	for _, child in self:GetChildren() do
		child:Destroy()
	end
end

function treeMethods.GetPivot(self)
	local list = invoke("node.pivot", nodeId(self))
	if list == nil then
		raise("attempt to use an Instance that has been destroyed", 2)
	end
	return cframeMath.cframeFromList(list)
end

function treeMethods.PivotTo(self, target)
	checkOther(target, "CFrame", "PivotTo")
	invoke("node.pivotto", nodeId(self), cframeMath.cframeList(target))
end

-- Physics. An impulse is mass × change in velocity; it does nothing to an anchored part.
function partMethods.ApplyImpulse(self, impulse)
	checkSelf(self, "Instance", "ApplyImpulse")
	checkOther(impulse, "Vector3", "ApplyImpulse")
	invoke("physics.impulse", partIdOf[self], { impulse[1], impulse[2], impulse[3] })
end

function partMethods.ApplyAngularImpulse(self, impulse)
	checkSelf(self, "Instance", "ApplyAngularImpulse")
	checkOther(impulse, "Vector3", "ApplyAngularImpulse")
	invoke("physics.angularimpulse", partIdOf[self], { impulse[1], impulse[2], impulse[3] })
end

function partMethods.GetMass(self)
	checkSelf(self, "Instance", "GetMass")
	return invoke("part.get", partIdOf[self], "mass")
end

function partMethods.Destroy(self)
	checkSelf(self, "Instance", "Destroy")
	invoke("part.destroy", partIdOf[self])
end

-- Roblox leaves a clone unparented until you set its Parent; here it goes straight
-- into the workspace, and setting Parent = workspace afterwards is harmless.
function partMethods.Clone(self)
	checkSelf(self, "Instance", "Clone")
	return wrapPart(invoke("part.clone", partIdOf[self]))
end

function partMethods.IsA(self, className)
	checkSelf(self, "Instance", "IsA")
	local shape = invoke("part.get", partIdOf[self], "shape")
	local mesh = invoke("part.get", partIdOf[self], "ismeshpart")
	if className == "WedgePart" then
		return shape == "wedge" and not mesh
	elseif className == "MeshPart" then
		return mesh == true
	end
	return className == "Part" and shape ~= "wedge" and not mesh
		or className == "BasePart" or className == "PVInstance" or className == "Instance"
end

for name, method in treeMethods do
	partMethods[name] = function(self, ...)
		checkSelf(self, "Instance", name)
		return method(self, ...)
	end
end

-- A part's children also include its PointLight and ClickDetector.
function partMethods.GetChildren(self)
	checkSelf(self, "Instance", "GetChildren")
	local children = treeMethods.GetChildren(self)
	local light = pointLightOf(partIdOf[self])
	if light then
		table.insert(children, light)
	end
	local detector = mouseKit.detectorOf(partIdOf[self])
	if detector then
		table.insert(children, detector)
	end
	return children
end

function partMethods.FindFirstChild(self, name, recursive)
	checkSelf(self, "Instance", "FindFirstChild")
	if name == "PointLight" then
		local light = pointLightOf(partIdOf[self])
		if light then
			return light
		end
	elseif name == "ClickDetector" then
		local detector = mouseKit.detectorOf(partIdOf[self])
		if detector then
			return detector
		end
	end
	return treeMethods.FindFirstChild(self, name, recursive)
end

PartMeta.__index = function(part, key)
	local id = partIdOf[part]
	local property = partProperties[key]
	if property ~= nil and property.meshOnly and not invoke("part.get", id, "ismeshpart") then
		property = nil
	end
	if property ~= nil and property.motion ~= nil then
		if not invoke("part.exists", id) then
			raise("attempt to use a part that has been destroyed", 2)
		end
		return toVector(invoke("physics.get", id, property.motion))
	end
	if property ~= nil then
		local raw = invoke("part.get", id, property.host)
		if raw == nil then
			if property.nullable and invoke("part.exists", id) then
				return nil
			end
			raise("attempt to use a part that has been destroyed", 2)
		end
		if property.read ~= nil then
			return property.read(raw)
		end
		return raw
	end
	if key == "ClassName" then
		local shape = invoke("part.get", id, "shape")
		if invoke("part.get", id, "ismeshpart") then
			return "MeshPart"
		elseif invoke("part.get", id, "isseat") then
			return "Seat"
		end
		return if shape == "wedge" then "WedgePart" elseif shape == "truss" then "TrussPart" else "Part"
	elseif key == "Touched" or key == "TouchEnded" then
		return partSignal(id, key)
	elseif key == "Parent" then
		return if invoke("part.exists", id) then wrapToken(invoke("tree.parent", id)) else nil
	end
	local method = partMethods[key]
	if method ~= nil then
		return method
	end
	if key == "PointLight" then
		local light = pointLightOf(id)
		if light ~= nil then
			return light
		end
	elseif key == "ClickDetector" then
		local detector = mouseKit.detectorOf(id)
		if detector ~= nil then
			return detector
		end
	end
	-- Children can be reached by name, as in Roblox.
	if type(key) == "string" then
		local child = wrapToken(invoke("tree.find", id, key, false))
		if child ~= nil then
			return child
		end
	end
	raise(string.format("%s is not a valid member of Part \"%s\"", tostring(key), partName(id)), 2)
end

PartMeta.__newindex = function(part, key, value)
	local id = partIdOf[part]
	if key == "Parent" then
		assignParent(part, value, function(target)
			invoke("part.destroy", target)
		end)
		return
	end
	if key == "ClassName" or key == "Touched" or key == "TouchEnded" then
		raise(string.format("Unable to assign property %s. Property is read only", key), 2)
	end
	local property = partProperties[key]
	if property ~= nil and property.meshOnly and not invoke("part.get", id, "ismeshpart") then
		property = nil
	end
	if property == nil then
		raise(string.format("%s is not a valid member of Part \"%s\"", tostring(key), partName(id)), 2)
	end
	if property.readOnly then
		raise(string.format("Unable to assign property %s. Property is read only", key), 2)
	end
	if property.motion ~= nil then
		if not isVector(value) then
			raise(string.format("Unable to assign property %s. Vector3 expected, got %s", key, typeof(value)), 2)
		end
		invoke("physics.set", id, property.motion, { value[1], value[2], value[3] })
		return
	end
	local converted, problem = property.write(value)
	if converted == nil then
		raise(string.format("Unable to assign property %s. %s", key, problem), 2)
	end
	if converted == false and property.nullable then
		converted = nil
	end
	invoke("part.set", id, property.host, converted)
end

PartMeta.__tostring = function(part)
	return partName(partIdOf[part])
end

PartMeta.__metatable = LOCKED

"""#
}
