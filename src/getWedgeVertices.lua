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
	-- fillTriangle always puts depth in Size.X, so when _polyTopSign is
	-- present we can trust that. For foreign parts we fall back to the
	-- smallest-dimension heuristic.
	local polyTopSign: number? = wedge:GetAttribute("_polyTopSign")

	local minAxis: string
	if polyTopSign then
		-- fillTriangle part: depth is always Size.X regardless of sliver geometry
		minAxis = "X"
	elseif size.X <= size.Y and size.X <= size.Z then
		minAxis = "X"
	elseif size.Y <= size.X and size.Y <= size.Z then
		minAxis = "Y"
	else
		minAxis = "Z"
	end

	-- Determine which face of the thin axis to extract vertices from.
	-- _polyTopSign stores the exact sign; for foreign parts infer it
	-- from orientation (fillTriangle orients thickness upward).
	local topSign: number = polyTopSign or 0
	if topSign == 0 then
		local axisDir: Vector3
		if minAxis == "X" then
			axisDir = cf.RightVector
		elseif minAxis == "Y" then
			axisDir = cf.UpVector
		else
			axisDir = -cf.LookVector
		end
		topSign = if axisDir.Y >= 0 then 1 else -1
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
