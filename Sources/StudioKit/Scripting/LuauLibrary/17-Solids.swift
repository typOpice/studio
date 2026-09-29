// Solid modeling methods share the editor's boundary engine; only server scripts
// can author these world objects.
extension LuauLibrary {
    static let solids = #"""
do
	partProperties.UsePartColor = {
		host = "usepartcolor", solidOnly = true,
		write = function(value)
			if type(value) ~= "boolean" then return nil, "boolean expected" end
			return value
		end,
	}
	local function combine(self, parts, subtract, fidelity)
		checkSelf(self, "Instance", if subtract then "SubtractAsync" else "UnionAsync")
		if partIdOf[self] == nil then raise("BasePart expected", 3) end
		if type(parts) ~= "table" or #parts == 0 then raise("a nonempty array of BaseParts is required", 3) end
		local ids = {partIdOf[self]}
		local seen = {[partIdOf[self]] = true}
		local count = 0
		for key, part in parts do
			count += 1
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #parts or partIdOf[part] == nil then
				raise("an array of BaseParts is required", 3)
			end
		end
		if count ~= #parts then raise("an array of BaseParts is required", 3) end
		for _, part in ipairs(parts) do
			local id = partIdOf[part]
			if seen[id] then raise("the same BasePart cannot be used twice", 3) end
			seen[id] = true
			table.insert(ids, id)
		end
		if fidelity ~= nil then
			local valid = partProperties.CollisionFidelity.write(fidelity)
			if valid == nil then raise("Enum.CollisionFidelity expected", 3) end
		end
		local result = invoke("part.boolean", ids, if subtract then "subtract" else "union", inLocalScript())
		if not result[1] then raise(result[2], 3) end
		local part = wrapPart(result[2])
		if fidelity ~= nil then part.CollisionFidelity = fidelity end
		return part
	end
	function partMethods.UnionAsync(self, parts, fidelity) return combine(self, parts, false, fidelity) end
	function partMethods.SubtractAsync(self, parts, fidelity) return combine(self, parts, true, fidelity) end
end
"""#
}
