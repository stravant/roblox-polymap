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

	-- Identify the thin axis (smallest dimension)
	local minAxis: string
	local minVal = math.huge
	if size.X <= size.Y and size.X <= size.Z then
		minAxis = "X"
		minVal = size.X
	elseif size.Y <= size.X and size.Y <= size.Z then
		minAxis = "Y"
		minVal = size.Y
	else
		minAxis = "Z"
		minVal = size.Z
	end

	-- The standard wedge shape has 3 vertices on each triangular face.
	-- In the default orientation (thin axis = X), the triangular face
	-- vertices in local space are:
	--   v1 = (0, -halfY,  halfZ)  -- bottom-front (right angle)
	--   v2 = (0,  halfY,  halfZ)  -- top-front
	--   v3 = (0, -halfY, -halfZ)  -- bottom-back
	--
	-- When the thin axis is Y or Z, we need to remap accordingly.

	local v1, v2, v3: Vector3

	if minAxis == "X" then
		-- Thin along X, triangle in YZ plane
		v1 = cf:PointToWorldSpace(Vector3.new(0, -halfY,  halfZ))
		v2 = cf:PointToWorldSpace(Vector3.new(0,  halfY,  halfZ))
		v3 = cf:PointToWorldSpace(Vector3.new(0, -halfY, -halfZ))
	elseif minAxis == "Y" then
		-- Thin along Y, triangle in XZ plane
		-- The wedge shape would be rotated so that Y is thin.
		-- However, fillTriangle always creates wedges with the thin axis as X (Size.X = thickness).
		-- This case shouldn't normally occur with fillTriangle output, but handle it for robustness.
		v1 = cf:PointToWorldSpace(Vector3.new(-halfX, 0,  halfZ))
		v2 = cf:PointToWorldSpace(Vector3.new( halfX, 0,  halfZ))
		v3 = cf:PointToWorldSpace(Vector3.new(-halfX, 0, -halfZ))
	else
		-- Thin along Z
		v1 = cf:PointToWorldSpace(Vector3.new(-halfX, -halfY, 0))
		v2 = cf:PointToWorldSpace(Vector3.new(-halfX,  halfY, 0))
		v3 = cf:PointToWorldSpace(Vector3.new( halfX, -halfY, 0))
	end

	return v1, v2, v3
end

return getWedgeVertices
