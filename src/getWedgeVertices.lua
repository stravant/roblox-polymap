--!strict

-- Extract the 3 triangle vertices from a thin wedge-shaped Part.
--
-- Standard Roblox wedge geometry in local space (YZ cross-section):
--   The wedge slopes from bottom-back to top-front.
--   Right-angle vertex at (-Y/2, -Z/2) in local YZ
--   Top vertex at (Y/2, -Z/2) -- actually this is the slope top
--   The three vertices of the triangular face are:
--     Bottom-back:  (0, -Y/2, -Z/2)
--     Bottom-front: (0, -Y/2,  Z/2)
--     Top-front:    (0,  Y/2,  Z/2)
--
-- The thin axis is identified as the smallest Size component.
-- The triangle vertices are computed in the plane perpendicular to the thin axis.

-- Pick a consistent sign for a direction vector to select which face of a
-- wedge part to use. This is an odd function: f(-dir) = -f(dir), which
-- ensures both parts of a fillTriangle pair extract from the same face
-- even though their thin axes point in opposite directions.
-- Y is checked first because fillTriangle guarantees normal.Y > 0, so the
-- thin axis direction always has a nonzero Y component for non-vertical
-- triangles. For vertical walls (Y ≈ 0), Z then X break the tie.
local function consistentSign(dir: Vector3): number
	if dir.Y > 0.0001 then
		return 1
	elseif dir.Y < -0.0001 then
		return -1
	elseif dir.Z > 0.0001 then
		return 1
	elseif dir.Z < -0.0001 then
		return -1
	elseif dir.X > 0.0001 then
		return 1
	else
		return -1
	end
end

local function getWedgeVertices(wedge: BasePart, hitNormal: Vector3?): (Vector3, Vector3, Vector3)
	local size = wedge.Size
	local cf = wedge.CFrame

	-- The standard wedge cross-section vertices in local space (X is thin axis):
	-- These are the 3 unique vertices of the triangular profile.
	-- Roblox wedge: right angle at bottom, slope goes from bottom-back up to top-front
	local halfX = size.X / 2
	local halfY = size.Y / 2
	local halfZ = size.Z / 2

	-- Identify the thin axis (the thickness/depth direction) as the smallest
	-- Size component. fillTriangle always puts depth in Size.X, but foreign
	-- parts may use any axis, so we check all three.
	-- topSign picks which triangular end-face to extract vertices from:
	--   +1 = face at +halfThinAxis, -1 = face at -halfThinAxis.
	-- When hitNormal is provided, we pick the face whose outward normal is
	-- most aligned with the hit normal (i.e., the face the raycast hit).
	-- Otherwise we use consistentSign to pick a face deterministically.
	local minAxis: string
	local topSign: number
	if size.X <= size.Y and size.X <= size.Z then
		minAxis = "X"
		if hitNormal then
			topSign = if hitNormal:Dot(cf.RightVector) > 0 then 1 else -1
		else
			topSign = consistentSign(cf.RightVector)
		end
	elseif size.Y <= size.X and size.Y <= size.Z then
		minAxis = "Y"
		if hitNormal then
			topSign = if hitNormal:Dot(cf.UpVector) > 0 then 1 else -1
		else
			topSign = consistentSign(cf.UpVector)
		end
	else
		minAxis = "Z"
		if hitNormal then
			-- LookVector points along -Z, so negate
			topSign = if hitNormal:Dot(-cf.LookVector) > 0 then 1 else -1
		else
			topSign = consistentSign(-cf.LookVector)
		end
	end

	local v1, v2, v3: Vector3

	if minAxis == "X" then
		-- Thin along X, triangle in YZ plane
		local xOffset = halfX * topSign
		v1 = cf:PointToWorldSpace(Vector3.new(xOffset, -halfY,  halfZ))
		v2 = cf:PointToWorldSpace(Vector3.new(xOffset,  halfY,  halfZ))
		v3 = cf:PointToWorldSpace(Vector3.new(xOffset, -halfY, -halfZ))
	elseif minAxis == "Y" then
		-- Thin along Y, triangle in XZ plane
		local yOffset = halfY * topSign
		v1 = cf:PointToWorldSpace(Vector3.new(-halfX, yOffset,  halfZ))
		v2 = cf:PointToWorldSpace(Vector3.new( halfX, yOffset,  halfZ))
		v3 = cf:PointToWorldSpace(Vector3.new(-halfX, yOffset, -halfZ))
	else
		-- Thin along Z
		local zOffset = halfZ * topSign
		v1 = cf:PointToWorldSpace(Vector3.new(-halfX, -halfY, zOffset))
		v2 = cf:PointToWorldSpace(Vector3.new(-halfX,  halfY, zOffset))
		v3 = cf:PointToWorldSpace(Vector3.new( halfX, -halfY, zOffset))
	end

	return v1, v2, v3
end

return getWedgeVertices
