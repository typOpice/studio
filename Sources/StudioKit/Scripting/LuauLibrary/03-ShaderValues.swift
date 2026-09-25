// The Luau library, part 3 of 15: shaders as values.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let shaderValues = #"""
--------------------------------------------------------------------------------
-- Shaders (Studio extension)

local ShaderMeta = {}
local shaderIdOf = setmetatable({}, { __mode = "k" })
local shaderForId = setmetatable({}, { __mode = "v" })

local function wrapShader(id)
	if id == nil then
		return nil
	end
	local existing = shaderForId[id]
	if existing ~= nil then
		return existing
	end
	local proxy = setmetatable({}, ShaderMeta)
	shaderIdOf[proxy] = id
	shaderForId[id] = proxy
	typeTags[proxy] = "Shader"
	return proxy
end

local shaderMethods = {}

function shaderMethods.GetParameter(self, name)
	checkSelf(self, "Shader", "GetParameter")
	return invoke("shader.param.get", shaderIdOf[self], name)
end

function shaderMethods.SetParameter(self, name, value)
	checkSelf(self, "Shader", "SetParameter")
	if type(value) ~= "number" then
		raise(string.format("SetParameter expects a number, got %s", typeof(value)), 2)
	end
	invoke("shader.param.set", shaderIdOf[self], name, value)
end

function shaderMethods.GetParameters(self)
	checkSelf(self, "Shader", "GetParameters")
	return invoke("shader.parameters", shaderIdOf[self])
end

function shaderMethods.ApplyTo(self, part)
	checkSelf(self, "Shader", "ApplyTo")
	part.Shader = self
end

ShaderMeta.__index = function(shader, key)
	local id = shaderIdOf[shader]
	if key == "Name" then
		return invoke("shader.get", id, "name")
	elseif key == "Kind" then
		local kind = invoke("shader.get", id, "kind")
		return if kind == "screen" then "Screen" else "Surface"
	elseif key == "Enabled" then
		return invoke("shader.get", id, "enabled")
	elseif key == "Compiled" then
		return invoke("shader.get", id, "compiled")
	end
	local method = shaderMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of Shader", tostring(key)), 2)
end

ShaderMeta.__newindex = function(shader, key, value)
	if key == "Enabled" then
		if type(value) ~= "boolean" then
			raise(string.format("Unable to assign property Enabled. bool expected, got %s", typeof(value)), 2)
		end
		invoke("shader.set", shaderIdOf[shader], "enabled", value)
		return
	end
	raise(string.format("Unable to assign property %s of Shader", tostring(key)), 2)
end

ShaderMeta.__tostring = function(shader)
	return invoke("shader.get", shaderIdOf[shader], "name") or "Shader"
end

ShaderMeta.__metatable = LOCKED

"""#
}
