--!strict

-- Extract the 4 rectangle corners from a thin block-shaped Part.
--
-- The thin axis is identified as the smallest Size component.
-- The four corners are computed on the face perpendicular to the thin axis
-- that faces upward (positive Y). They are returned going around the
-- rectangle perimeter so that (v1,v2,v3) and (v1,v3,v4) form a valid
-- diagonal split into two triangles.
local function getBlockVertices(block: BasePart): (Vector3, Vector3, Vector3, Vector3)
	local size = block.Size
	local cf = block.CFrame

	local halfX = size.X / 2
	local halfY = size.Y / 2
	local halfZ = size.Z / 2

	-- Identify the thin axis (smallest Size component).
	-- topSign picks the face that faces upward (positive Y).
	local minAxis: string
	local topSign: number
	if size.X <= size.Y and size.X <= size.Z then
		minAxis = "X"
		topSign = if cf.RightVector.Y >= 0 then 1 else -1
	elseif size.Y <= size.X and size.Y <= size.Z then
		minAxis = "Y"
		topSign = if cf.UpVector.Y >= 0 then 1 else -1
	else
		minAxis = "Z"
		-- LookVector points along -Z, so negate
		topSign = if -cf.LookVector.Y >= 0 then 1 else -1
	end

	local v1, v2, v3, v4: Vector3

	if minAxis == "X" then
		-- Thin along X, rectangle in YZ plane
		local xOffset = halfX * topSign
		v1 = cf:PointToWorldSpace(Vector3.new(xOffset, -halfY,  halfZ))
		v2 = cf:PointToWorldSpace(Vector3.new(xOffset,  halfY,  halfZ))
		v3 = cf:PointToWorldSpace(Vector3.new(xOffset,  halfY, -halfZ))
		v4 = cf:PointToWorldSpace(Vector3.new(xOffset, -halfY, -halfZ))
	elseif minAxis == "Y" then
		-- Thin along Y, rectangle in XZ plane
		local yOffset = halfY * topSign
		v1 = cf:PointToWorldSpace(Vector3.new(-halfX, yOffset,  halfZ))
		v2 = cf:PointToWorldSpace(Vector3.new( halfX, yOffset,  halfZ))
		v3 = cf:PointToWorldSpace(Vector3.new( halfX, yOffset, -halfZ))
		v4 = cf:PointToWorldSpace(Vector3.new(-halfX, yOffset, -halfZ))
	else
		-- Thin along Z, rectangle in XY plane
		local zOffset = halfZ * topSign
		v1 = cf:PointToWorldSpace(Vector3.new(-halfX, -halfY, zOffset))
		v2 = cf:PointToWorldSpace(Vector3.new(-halfX,  halfY, zOffset))
		v3 = cf:PointToWorldSpace(Vector3.new( halfX,  halfY, zOffset))
		v4 = cf:PointToWorldSpace(Vector3.new( halfX, -halfY, zOffset))
	end

	return v1, v2, v3, v4
end

return getBlockVertices
