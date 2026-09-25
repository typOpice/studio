// The Luau library, part 4 of 15: CFrame.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let cframe = #"""
--------------------------------------------------------------------------------
-- CFrame: a position and a rotation, as Roblox's CFrame.
--
-- Stored as 12 numbers — x, y, z, then the rotation matrix row by row (Roblox's
-- GetComponents order). The matrix's columns are RightVector, UpVector and
-- -LookVector; +Y is up and a part faces -Z.

-- CFrame's internals, in one table: the library's top level is close to Luau's 200 locals.
local cframeMath = {}
cframeMath.CFrameMeta = {}
cframeMath.cframeMethods = {}

local function cframe(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	local c = setmetatable({ x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }, cframeMath.CFrameMeta)
	typeTags[c] = "CFrame"
	return c
end

local function isCFrame(value)
	return value ~= nil and typeTags[value] == "CFrame"
end

function cframeMath.cframeFromList(list)
	return cframe(table.unpack(list, 1, 12))
end

function cframeMath.cframeList(c)
	return { c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12] }
end

-- R * (x, y, z)
function cframeMath.rotate(c, x, y, z)
	return c[4] * x + c[5] * y + c[6] * z, c[7] * x + c[8] * y + c[9] * z, c[10] * x + c[11] * y + c[12] * z
end

-- Rᵀ * (x, y, z): the inverse rotation.
function cframeMath.unrotate(c, x, y, z)
	return c[4] * x + c[7] * y + c[10] * z, c[5] * x + c[8] * y + c[11] * z, c[6] * x + c[9] * y + c[12] * z
end

function cframeMath.compose(a, b)
	local x, y, z = cframeMath.rotate(a, b[1], b[2], b[3])
	local r = {}
	for row = 0, 2 do
		for col = 0, 2 do
			r[row * 3 + col + 1] = a[4 + row * 3] * b[4 + col] + a[5 + row * 3] * b[7 + col] + a[6 + row * 3] * b[10 + col]
		end
	end
	return cframe(a[1] + x, a[2] + y, a[3] + z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
end

function cframeMath.inverse(c)
	-- Rᵀ, and -Rᵀp.
	local x, y, z = cframeMath.unrotate(c, c[1], c[2], c[3])
	return cframe(-x, -y, -z, c[4], c[7], c[10], c[5], c[8], c[11], c[6], c[9], c[12])
end

-- Rotation matrices about each axis, as 9 numbers row by row.
function cframeMath.rx(a)
	local c, s = math.cos(a), math.sin(a)
	return { 1, 0, 0, 0, c, -s, 0, s, c }
end
function cframeMath.ry(a)
	local c, s = math.cos(a), math.sin(a)
	return { c, 0, s, 0, 1, 0, -s, 0, c }
end
function cframeMath.rz(a)
	local c, s = math.cos(a), math.sin(a)
	return { c, -s, 0, s, c, 0, 0, 0, 1 }
end
function cframeMath.mul3(a, b)
	local r = {}
	for row = 0, 2 do
		for col = 0, 2 do
			r[row * 3 + col + 1] = a[row * 3 + 1] * b[col + 1] + a[row * 3 + 2] * b[col + 4] + a[row * 3 + 3] * b[col + 7]
		end
	end
	return r
end
function cframeMath.fromRotation(m, x, y, z)
	return cframe(x or 0, y or 0, z or 0, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
end

function cframeMath.quaternionOf(c)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
	local trace = m00 + m11 + m22
	local qw, qx, qy, qz
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		qw, qx, qy, qz = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		qw, qx, qy, qz = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		qw, qx, qy, qz = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		qw, qx, qy, qz = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
	return qx, qy, qz, qw
end

function cframeMath.fromQuaternion(x, y, z, qx, qy, qz, qw)
	local length = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	if length == 0 then
		return cframe(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	qx, qy, qz, qw = qx / length, qy / length, qz / length, qw / length
	return cframe(x, y, z,
		1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
		2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
		2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy))
end

function cframeMath.lookAt(ax, ay, az, tx, ty, tz, ux, uy, uz)
	local fx, fy, fz = tx - ax, ty - ay, tz - az
	local length = math.sqrt(fx * fx + fy * fy + fz * fz)
	if length < 1e-9 then
		return cframe(ax, ay, az, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	fx, fy, fz = fx / length, fy / length, fz / length
	ux, uy, uz = ux or 0, uy or 1, uz or 0
	-- right = look × up; if they are parallel, pick another up.
	local rx_, ry_, rz_ = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
	local rl = math.sqrt(rx_ * rx_ + ry_ * ry_ + rz_ * rz_)
	if rl < 1e-6 then
		ux, uy, uz = 0, 0, if math.abs(fy) > 0 then -1 else 1
		rx_, ry_, rz_ = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
		rl = math.sqrt(rx_ * rx_ + ry_ * ry_ + rz_ * rz_)
	end
	rx_, ry_, rz_ = rx_ / rl, ry_ / rl, rz_ / rl
	-- up = right × look
	local vx, vy, vz = ry_ * fz - rz_ * fy, rz_ * fx - rx_ * fz, rx_ * fy - ry_ * fx
	return cframe(ax, ay, az, rx_, vx, -fx, ry_, vy, -fy, rz_, vz, -fz)
end

cframeMath.CFrameMeta.__index = function(c, key)
	if key == "Position" or key == "p" then
		return vector(c[1], c[2], c[3])
	elseif key == "X" then
		return c[1]
	elseif key == "Y" then
		return c[2]
	elseif key == "Z" then
		return c[3]
	elseif key == "LookVector" then
		return vector(-c[6], -c[9], -c[12])
	elseif key == "RightVector" or key == "XVector" then
		return vector(c[4], c[7], c[10])
	elseif key == "UpVector" or key == "YVector" then
		return vector(c[5], c[8], c[11])
	elseif key == "ZVector" then
		return vector(c[6], c[9], c[12])
	elseif key == "Rotation" then
		return cframe(0, 0, 0, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	end
	local method = cframeMath.cframeMethods[key]
	if method ~= nil then
		return method
	end
	raise(string.format("%s is not a valid member of CFrame", tostring(key)), 2)
end

cframeMath.CFrameMeta.__newindex = function(_, key)
	raise(string.format("%s cannot be assigned to", tostring(key)), 2)
end

cframeMath.CFrameMeta.__mul = function(a, b)
	if not isCFrame(a) then
		raise("attempt to perform arithmetic (mul) on " .. typeof(a) .. " and CFrame", 2)
	end
	if isCFrame(b) then
		return cframeMath.compose(a, b)
	elseif isVector(b) then
		local x, y, z = cframeMath.rotate(a, b[1], b[2], b[3])
		return vector(a[1] + x, a[2] + y, a[3] + z)
	end
	raise("attempt to perform arithmetic (mul) on CFrame and " .. typeof(b), 2)
end

cframeMath.CFrameMeta.__add = function(a, b)
	if isCFrame(a) and isVector(b) then
		return cframe(a[1] + b[1], a[2] + b[2], a[3] + b[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
	end
	raise("attempt to perform arithmetic (add) on " .. typeof(a) .. " and " .. typeof(b), 2)
end

cframeMath.CFrameMeta.__sub = function(a, b)
	if isCFrame(a) and isVector(b) then
		return cframe(a[1] - b[1], a[2] - b[2], a[3] - b[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
	end
	raise("attempt to perform arithmetic (sub) on " .. typeof(a) .. " and " .. typeof(b), 2)
end

cframeMath.CFrameMeta.__eq = function(a, b)
	for i = 1, 12 do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

cframeMath.CFrameMeta.__tostring = function(c)
	local pieces = table.create(12)
	for i = 1, 12 do
		pieces[i] = tostring(math.round(c[i] * 1e6) / 1e6)
	end
	return table.concat(pieces, ", ")
end

cframeMath.CFrameMeta.__metatable = LOCKED

function cframeMath.cframeMethods.Inverse(self)
	checkSelf(self, "CFrame", "Inverse")
	return cframeMath.inverse(self)
end

function cframeMath.cframeMethods.ToWorldSpace(self, other)
	checkSelf(self, "CFrame", "ToWorldSpace")
	checkOther(other, "CFrame", "ToWorldSpace")
	return cframeMath.compose(self, other)
end

function cframeMath.cframeMethods.ToObjectSpace(self, other)
	checkSelf(self, "CFrame", "ToObjectSpace")
	checkOther(other, "CFrame", "ToObjectSpace")
	return cframeMath.compose(cframeMath.inverse(self), other)
end

function cframeMath.cframeMethods.PointToWorldSpace(self, v)
	checkSelf(self, "CFrame", "PointToWorldSpace")
	checkOther(v, "Vector3", "PointToWorldSpace")
	return self * v
end

function cframeMath.cframeMethods.PointToObjectSpace(self, v)
	checkSelf(self, "CFrame", "PointToObjectSpace")
	checkOther(v, "Vector3", "PointToObjectSpace")
	return cframeMath.inverse(self) * v
end

function cframeMath.cframeMethods.VectorToWorldSpace(self, v)
	checkSelf(self, "CFrame", "VectorToWorldSpace")
	checkOther(v, "Vector3", "VectorToWorldSpace")
	return vector(cframeMath.rotate(self, v[1], v[2], v[3]))
end

function cframeMath.cframeMethods.VectorToObjectSpace(self, v)
	checkSelf(self, "CFrame", "VectorToObjectSpace")
	checkOther(v, "Vector3", "VectorToObjectSpace")
	return vector(cframeMath.unrotate(self, v[1], v[2], v[3]))
end

function cframeMath.cframeMethods.GetComponents(self)
	checkSelf(self, "CFrame", "GetComponents")
	return table.unpack(cframeMath.cframeList(self))
end
cframeMath.cframeMethods.components = cframeMath.cframeMethods.GetComponents

function cframeMath.cframeMethods.Lerp(self, goal, alpha)
	checkSelf(self, "CFrame", "Lerp")
	checkOther(goal, "CFrame", "Lerp")
	if type(alpha) ~= "number" then
		raise("Lerp expects a number alpha, got " .. typeof(alpha), 2)
	end
	local ax, ay, az, aw = cframeMath.quaternionOf(self)
	local bx, by, bz, bw = cframeMath.quaternionOf(goal)
	local dot = ax * bx + ay * by + az * bz + aw * bw
	if dot < 0 then
		bx, by, bz, bw, dot = -bx, -by, -bz, -bw, -dot
	end
	local wa, wb
	if dot > 0.9995 then
		wa, wb = 1 - alpha, alpha
	else
		local theta = math.acos(dot)
		local s = math.sin(theta)
		wa, wb = math.sin((1 - alpha) * theta) / s, math.sin(alpha * theta) / s
	end
	return cframeMath.fromQuaternion(
		self[1] + (goal[1] - self[1]) * alpha, self[2] + (goal[2] - self[2]) * alpha, self[3] + (goal[3] - self[3]) * alpha,
		ax * wa + bx * wb, ay * wa + by * wb, az * wa + bz * wb, aw * wa + bw * wb)
end

-- For R = Rx(a) * Ry(b) * Rz(c).
function cframeMath.cframeMethods.ToEulerAnglesXYZ(self)
	checkSelf(self, "CFrame", "ToEulerAnglesXYZ")
	local b = math.asin(math.clamp(self[6], -1, 1))
	if math.abs(self[6]) < 0.99999 then
		return math.atan2(-self[9], self[12]), b, math.atan2(-self[5], self[4])
	end
	return math.atan2(self[11], self[8]), b, 0
end

-- For R = Ry(b) * Rx(a) * Rz(c): Roblox's Orientation order.
function cframeMath.cframeMethods.ToEulerAnglesYXZ(self)
	checkSelf(self, "CFrame", "ToEulerAnglesYXZ")
	local a = math.asin(math.clamp(-self[9], -1, 1))
	if math.abs(self[9]) < 0.99999 then
		return a, math.atan2(self[6], self[12]), math.atan2(self[7], self[8])
	end
	return a, math.atan2(-self[10], self[4]), 0
end
cframeMath.cframeMethods.ToOrientation = cframeMath.cframeMethods.ToEulerAnglesYXZ

function cframeMath.cframeMethods.ToAxisAngle(self)
	checkSelf(self, "CFrame", "ToAxisAngle")
	local qx, qy, qz, qw = cframeMath.quaternionOf(self)
	local angle = 2 * math.acos(math.clamp(qw, -1, 1))
	local s = math.sqrt(math.max(1 - qw * qw, 0))
	if s < 1e-6 then
		return vector(1, 0, 0), 0
	end
	return vector(qx / s, qy / s, qz / s), angle
end

function cframeMath.cframeMethods.FuzzyEq(self, other, epsilon)
	checkSelf(self, "CFrame", "FuzzyEq")
	checkOther(other, "CFrame", "FuzzyEq")
	epsilon = epsilon or 1e-5
	for i = 1, 12 do
		if math.abs(self[i] - other[i]) > epsilon then
			return false
		end
	end
	return true
end

function cframeMath.angleArguments(functionName, x, y, z)
	checkNumber(x, 1, functionName)
	checkNumber(y, 2, functionName)
	checkNumber(z, 3, functionName)
	return x or 0, y or 0, z or 0
end

cframeMath.IDENTITY_CFRAME = cframe(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)

CFrame = table.freeze({
	new = function(...)
		local count = select("#", ...)
		local a, b = ...
		if count == 0 then
			return cframeMath.IDENTITY_CFRAME
		elseif count == 1 and isVector(a) then
			return cframe(a[1], a[2], a[3], 1, 0, 0, 0, 1, 0, 0, 0, 1)
		elseif count == 2 and isVector(a) and isVector(b) then
			return cframeMath.lookAt(a[1], a[2], a[3], b[1], b[2], b[3])
		elseif count == 3 then
			local x, y, z = ...
			checkNumber(x, 1, "new")
			checkNumber(y, 2, "new")
			checkNumber(z, 3, "new")
			return cframe(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		elseif count == 7 then
			local x, y, z, qx, qy, qz, qw = ...
			return cframeMath.fromQuaternion(x, y, z, qx, qy, qz, qw)
		elseif count == 12 then
			local values = { ... }
			for index, value in values do
				checkNumber(value, index, "new")
			end
			return cframe(...)
		end
		raise("CFrame.new takes nothing, a Vector3, two Vector3s, 3, 7 or 12 numbers", 2)
	end,
	lookAt = function(at, target, up)
		checkOther(at, "Vector3", "lookAt")
		checkOther(target, "Vector3", "lookAt")
		if up ~= nil then
			checkOther(up, "Vector3", "lookAt")
			return cframeMath.lookAt(at[1], at[2], at[3], target[1], target[2], target[3], up[1], up[2], up[3])
		end
		return cframeMath.lookAt(at[1], at[2], at[3], target[1], target[2], target[3])
	end,
	Angles = function(x, y, z)
		x, y, z = cframeMath.angleArguments("Angles", x, y, z)
		return cframeMath.fromRotation(cframeMath.mul3(cframeMath.mul3(cframeMath.rx(x), cframeMath.ry(y)), cframeMath.rz(z)))
	end,
	fromEulerAnglesXYZ = function(x, y, z)
		x, y, z = cframeMath.angleArguments("fromEulerAnglesXYZ", x, y, z)
		return cframeMath.fromRotation(cframeMath.mul3(cframeMath.mul3(cframeMath.rx(x), cframeMath.ry(y)), cframeMath.rz(z)))
	end,
	fromEulerAnglesYXZ = function(x, y, z)
		x, y, z = cframeMath.angleArguments("fromEulerAnglesYXZ", x, y, z)
		return cframeMath.fromRotation(cframeMath.mul3(cframeMath.mul3(cframeMath.ry(y), cframeMath.rx(x)), cframeMath.rz(z)))
	end,
	fromOrientation = function(x, y, z)
		x, y, z = cframeMath.angleArguments("fromOrientation", x, y, z)
		return cframeMath.fromRotation(cframeMath.mul3(cframeMath.mul3(cframeMath.ry(y), cframeMath.rx(x)), cframeMath.rz(z)))
	end,
	fromAxisAngle = function(axis, angle)
		checkOther(axis, "Vector3", "fromAxisAngle")
		checkNumber(angle, 2, "fromAxisAngle")
		local length = math.sqrt(axis[1] ^ 2 + axis[2] ^ 2 + axis[3] ^ 2)
		if length == 0 then
			return cframeMath.IDENTITY_CFRAME
		end
		local s = math.sin(angle / 2) / length
		return cframeMath.fromQuaternion(0, 0, 0, axis[1] * s, axis[2] * s, axis[3] * s, math.cos(angle / 2))
	end,
	fromMatrix = function(position, right, up, back)
		checkOther(position, "Vector3", "fromMatrix")
		checkOther(right, "Vector3", "fromMatrix")
		checkOther(up, "Vector3", "fromMatrix")
		if back == nil then
			back = vector(right[2] * up[3] - right[3] * up[2], right[3] * up[1] - right[1] * up[3],
				right[1] * up[2] - right[2] * up[1])
		end
		return cframe(position[1], position[2], position[3],
			right[1], up[1], back[1], right[2], up[2], back[2], right[3], up[3], back[3])
	end,
	identity = cframeMath.IDENTITY_CFRAME,
})

"""#
}
