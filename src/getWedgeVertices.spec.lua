--!strict

local TestTypes = require("./TestTypes")
local fillTriangle = require("./fillTriangle")
local getWedgeVertices = require("./getWedgeVertices")

local function fuzzyEqVec3(a: Vector3, b: Vector3, epsilon: number?): boolean
	local eps = epsilon or 0.05
	return (a - b).Magnitude < eps
end

return function(t: TestTypes.TestContext)
	-- The orientation heuristic picks the face whose outward normal has the
	-- larger Y component, which is accurate for heightmap-like triangles.
	local ROUND_TRIP_EPSILON = 0.05

	t.test("round-trip: fillTriangle -> getWedgeVertices recovers original vertices", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(2, 0, 3)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Use a point on the bottom face (below part center) as hintPoint
		local hintPoint = Vector3.new(2, -0.2, 1)
		-- Collect all vertices from all wedge parts
		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintPoint)
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

		-- Point below center picks the bottom face (surface at Y=5)
		local hintPoint = Vector3.new(2, 4.8, 1)
		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintPoint)
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

	t.test("round-trip with steep triangle (>45 degree slope)", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- A nearly vertical triangle face (slope ~70 degrees)
		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(2, 8, 1)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Point on the +Z side of the face surface
		local hintPoint = Vector3.new(2, 2, 0.5)
		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintPoint)
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

	t.test("round-trip with underhanging triangle (normal pointing down)", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Winding order gives downward normal: (b-a) x (c-b) has Y < 0
		local a = Vector3.new(500, 10, 0)
		local b = Vector3.new(502, 10, 3)
		local c = Vector3.new(504, 10, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Point above center picks the top face (at Y≈10.2 for this inverted triangle)
		local hintPoint = Vector3.new(502, 10.3, 1)
		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintPoint)
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

	t.test("round-trip with vertical wall triangle", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Vertical wall: normal points in +Z direction
		local a = Vector3.new(510, 0, 0)
		local b = Vector3.new(514, 0, 0)
		local c = Vector3.new(512, 3, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Point on the +Z face surface
		local hintPoint = Vector3.new(512, 1, 0.2)
		local allVerts: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintPoint)
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

	t.test("can select top or bottom face based on hintPoint", function()
		-- Create a thin wedge lying flat (thin along X)
		local wedge = Instance.new("Part")
		wedge.Shape = Enum.PartType.Wedge
		wedge.Size = Vector3.new(0.2, 3, 4)
		wedge.CFrame = CFrame.new(5, 5, 5)
		wedge.Anchored = true
		wedge.Parent = workspace

		-- The wedge's thin axis is X. RightVector is the thin axis direction.
		local rightVec = wedge.CFrame.RightVector
		local center = wedge.CFrame.Position

		-- Point on the +X side should give the +X face
		local topV1, topV2, topV3 = getWedgeVertices(wedge, center + rightVec)
		-- Point on the -X side should give the -X face
		local botV1, botV2, botV3 = getWedgeVertices(wedge, center - rightVec)

		-- Both should return valid triangles (3 distinct vertices)
		t.expect(fuzzyEqVec3(topV1, topV2)).toBeFalsy()
		t.expect(fuzzyEqVec3(topV2, topV3)).toBeFalsy()
		t.expect(fuzzyEqVec3(topV1, topV3)).toBeFalsy()
		t.expect(fuzzyEqVec3(botV1, botV2)).toBeFalsy()
		t.expect(fuzzyEqVec3(botV2, botV3)).toBeFalsy()
		t.expect(fuzzyEqVec3(botV1, botV3)).toBeFalsy()

		-- The two faces should be at different positions (offset by thickness)
		local topCenter = (topV1 + topV2 + topV3) / 3
		local botCenter = (botV1 + botV2 + botV3) / 3
		local diff = topCenter - botCenter

		-- Offset should be ~0.2 (the thickness) along the thin axis
		t.expect(math.abs(diff.Magnitude - 0.2) < 0.05).toBeTruthy()
		t.expect(diff.Unit:Dot(rightVec) > 0.99).toBeTruthy()

		wedge:Destroy()
	end)

	t.test("hintPoint selects correct face for fillTriangle parts", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a horizontal triangle with known normal direction
		local a = Vector3.new(520, 5, 0)
		local b = Vector3.new(524, 5, 0)
		local c = Vector3.new(522, 5, 3)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Point above center (Y=5.3) → depth face at Y ≈ 5.2
		local hintAbove = Vector3.new(522, 5.3, 1)
		local allVertsUp: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintAbove)
			table.insert(allVertsUp, v1)
			table.insert(allVertsUp, v2)
			table.insert(allVertsUp, v3)
		end

		-- Point below center (Y=4.8) → surface face at Y ≈ 5.0
		local hintBelow = Vector3.new(522, 4.8, 1)
		local allVertsDown: { Vector3 } = {}
		for _, part in parts do
			local v1, v2, v3 = getWedgeVertices(part, hintBelow)
			table.insert(allVertsDown, v1)
			table.insert(allVertsDown, v2)
			table.insert(allVertsDown, v3)
		end

		-- For this triangle, natural normal is -Y. fillTriangle extends depth
		-- opposite to the normal (+Y direction), so:
		-- Point above → depth face at Y ≈ 5.2
		-- Point below → surface face at Y ≈ 5.0
		local foundUpAtDepth = false
		local foundDownAtSurface = false
		for _, v in allVertsUp do
			if math.abs(v.Y - 5.2) < ROUND_TRIP_EPSILON then
				foundUpAtDepth = true
				break
			end
		end
		for _, v in allVertsDown do
			if math.abs(v.Y - 5.0) < ROUND_TRIP_EPSILON then
				foundDownAtSurface = true
				break
			end
		end

		t.expect(foundUpAtDepth).toBeTruthy()
		t.expect(foundDownAtSurface).toBeTruthy()

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

		-- Point on the +X face of the wedge
		local v1, v2, v3 = getWedgeVertices(wedge, Vector3.new(5.2, 5, 5))

		-- All three should be different
		t.expect(fuzzyEqVec3(v1, v2)).toBeFalsy()
		t.expect(fuzzyEqVec3(v2, v3)).toBeFalsy()
		t.expect(fuzzyEqVec3(v1, v3)).toBeFalsy()

		wedge:Destroy()
	end)
end
