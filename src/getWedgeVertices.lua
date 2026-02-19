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
local function getWedgeVertices(wedge: BasePart): (Vector3, Vector3, Vector3)
	local size = wedge.Size
	local cf = wedge.CFrame

	-- The standard wedge cross-section vertices in local space (X is thin axis):
	-- These are the 3 unique vertices of the triangular profile.
	-- Roblox wedge: right angle at bottom, slope goes from bottom-back up to top-front
	local halfX = size.X / 2
	local halfY = size.Y / 2
	local halfZ = size.Z / 2

	-- Identify the thin axis (the thickness/depth direction).
	-- For heightmap terrain the depth axis points roughly vertical, so we
	-- pick the local axis with the largest absolute Y component. This works
	-- for both PolyMap parts (depth always in Size.X) and foreign parts
	-- (e.g. GapFill), and avoids the sliver problem where the smallest
	-- dimension isn't the depth.
	local absRY = math.abs(cf.RightVector.Y)
	local absUY = math.abs(cf.UpVector.Y)
	local absLY = math.abs(cf.LookVector.Y)

	local minAxis: string
	local topSign: number
	if absRY >= absUY and absRY >= absLY then
		minAxis = "X"
		topSign = if cf.RightVector.Y >= 0 then 1 else -1
	elseif absUY >= absRY and absUY >= absLY then
		minAxis = "Y"
		topSign = if cf.UpVector.Y >= 0 then 1 else -1
	else
		minAxis = "Z"
		-- LookVector points along -Z, so negate
		topSign = if -cf.LookVector.Y >= 0 then 1 else -1
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
