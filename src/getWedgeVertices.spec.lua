--!strict

local TestTypes = require("./TestTypes")
local fillTriangle = require("./fillTriangle")
local getWedgeVertices = require("./getWedgeVertices")

local function fuzzyEqVec3(a: Vector3, b: Vector3, epsilon: number?): boolean
	local eps = epsilon or 0.05
	return (a - b).Magnitude < eps
end

-- Check if a set of 3 vertices matches another set of 3 vertices (in any order)
local function verticesSetsMatch(set1: { Vector3 }, set2: { Vector3 }, epsilon: number?): boolean
	if #set1 ~= 3 or #set2 ~= 3 then
		return false
	end
	local used = { false, false, false }
	for _, v1 in set1 do
		local found = false
		for j, v2 in set2 do
			if not used[j] and fuzzyEqVec3(v1, v2, epsilon) then
				used[j] = true
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end
	return true
end

return function(t: TestTypes.TestContext)
	-- With _polyTopSign attribute, getWedgeVertices extracts from the correct face
	-- so the round-trip is accurate to floating-point precision.
	local ROUND_TRIP_EPSILON = 0.05

	t.test("round-trip: fillTriangle -> getWedgeVertices recovers original vertices", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(2, 3, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Collect all vertices from all wedge parts
		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part)
			table.insert(allVerts, v1)
			table.insert(allVerts, v2)
			table.insert(allVerts, v3)
		end

		-- The combined vertices from 1-2 wedge parts should contain the original 3 vertices
		local foundA, foundB, foundC = false, false, false
		for _, v in allVerts do
			if fuzzyEqVec3(v, a, ROUND_TRIP_EPSILON) then foundA = true end
			if fuzzyEqVec3(v, b, ROUND_TRIP_EPSILON) then foundB = true end
			if fuzzyEqVec3(v, c, ROUND_TRIP_EPSILON) then foundC = true end
		end

		t.expect(foundA).toBeTruthy()
		t.expect(foundB).toBeTruthy()
		t.expect(foundC).toBeTruthy()

		folder:Destroy()
	end)

	t.test("round-trip with equilateral triangle", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 5, 0)
		local b = Vector3.new(4, 5, 0)
		local c = Vector3.new(2, 5, 4 * math.sqrt(3) / 2)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part)
			table.insert(allVerts, v1)
			table.insert(allVerts, v2)
			table.insert(allVerts, v3)
		end

		local foundA, foundB, foundC = false, false, false
		for _, v in allVerts do
			if fuzzyEqVec3(v, a, ROUND_TRIP_EPSILON) then foundA = true end
			if fuzzyEqVec3(v, b, ROUND_TRIP_EPSILON) then foundB = true end
			if fuzzyEqVec3(v, c, ROUND_TRIP_EPSILON) then foundC = true end
		end

		t.expect(foundA).toBeTruthy()
		t.expect(foundB).toBeTruthy()
		t.expect(foundC).toBeTruthy()

		folder:Destroy()
	end)

	t.test("single wedge part returns exactly 3 vertices", function()
		-- Create a simple wedge part manually
		local wedge = Instance.new("Part")
		wedge.Shape = Enum.PartType.Wedge
		wedge.Size = Vector3.new(0.2, 3, 4)
		wedge.CFrame = CFrame.new(5, 5, 5)
		wedge.Anchored = true
		wedge.Parent = workspace

		local v1, v2, v3 = getWedgeVertices(wedge)

		-- All three should be different
		t.expect(fuzzyEqVec3(v1, v2)).toBeFalsy()
		t.expect(fuzzyEqVec3(v2, v3)).toBeFalsy()
		t.expect(fuzzyEqVec3(v1, v3)).toBeFalsy()

		wedge:Destroy()
	end)
end
