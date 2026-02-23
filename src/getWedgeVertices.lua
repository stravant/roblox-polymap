--!strict

-- Extract the 3 triangle vertices from a thin wedge-shaped Part. Normal is used
-- to disambiguate which of the two potential triangular faces to use.
--
-- Standard Roblox wedge geometry in local space (YZ cross-section):
--   The wedge slopes from bottom-back to top-front.
--   Right-angle vertex at (-Y/2, -Z/2) in local YZ
--   Top vertex at (Y/2, -Z/2) -- actually this is the slope top
--   The three vertices of the triangular face are:
--     Bottom-back:  (0, -Y/2, -Z/2)
--     Bottom-front: (0, -Y/2,  Z/2)
--     Top-front:    (0,  Y/2,  Z/2)

local function getWedgeVertices(wedge: BasePart, referenceNormal: Vector3): (Vector3, Vector3, Vector3)
	local size = wedge.Size
	local cf = wedge.CFrame

	local topSign = math.sign(referenceNormal:Dot(cf.XVector))
	if topSign == 0 then
		warn("Zero top sign")
		-- Normal is perpendicular to wedge face, can't disambiguate, just pick one
		topSign = 1
	end

	local halfX = size.X / 2
	local halfY = size.Y / 2
	local halfZ = size.Z / 2

	-- Thin along X, triangle in YZ plane
	local xOffset = halfX * topSign
	local v1 = cf:PointToWorldSpace(Vector3.new(xOffset, -halfY,  halfZ))
	local v2 = cf:PointToWorldSpace(Vector3.new(xOffset,  halfY,  halfZ))
	local v3 = cf:PointToWorldSpace(Vector3.new(xOffset, -halfY, -halfZ))

	return v1, v2, v3
end

return getWedgeVertices
