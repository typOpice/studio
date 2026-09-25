// The Luau library, part 1 of 15: the host bridge, raise, print and typeof.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let core = #"""
--!nocheck
local invoke = __studio_invoke
local arm = __studio_arm

local LOCKED = "The metatable is locked"
local typeTags = setmetatable({}, { __mode = "k" })

-- error() with a level counted from the caller of raise: 2 blames whoever called
-- the function that is raising, which is where a learner needs to look.
local function raise(message, level)
	error(message, (level or 1) + 1)
end

--------------------------------------------------------------------------------
-- Output and typeof

local function describeArguments(...)
	local count = select("#", ...)
	local pieces = table.create(count)
	for index = 1, count do
		pieces[index] = tostring((select(index, ...)))
	end
	return table.concat(pieces, " ")
end

print = function(...)
	invoke("runtime.print", describeArguments(...))
end

warn = function(...)
	invoke("runtime.warn", describeArguments(...))
end

local nativeTypeof = typeof
typeof = function(value)
	if value ~= nil then
		local tag = typeTags[value]
		if tag ~= nil then
			return tag
		end
	end
	return nativeTypeof(value)
end

"""#
}
