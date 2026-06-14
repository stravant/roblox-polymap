--!strict

local TestTypes = require("./TestTypes")
local buildHeightmapMesh = require("./buildHeightmapMesh")

-- Min/max world Y over a part's 8 bounding-box corners.
local function partYRange(part: BasePart): (number, number)
	local cf = part.CFrame
	local h = part.Size / 2
	local minY, maxY = math.huge, -math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local y = (cf * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)).Y
				minY = math.min(minY, y)
				maxY = math.max(maxY, y)
			end
		end
	end
	return minY, maxY
end

-- Min/max world Y over every wedge part under a parent.
local function meshYRange(parent: Instance): (number, number)
	local minY, maxY = math.huge, -math.huge
	for _, part in parent:GetChildren() do
		if part:IsA("BasePart") then
			local pMin, pMax = partYRange(part)
			minY = math.min(minY, pMin)
			maxY = math.max(maxY, pMax)
		end
	end
	return minY, maxY
end

-- A (rows+1) x (cols+1) vertex grid where heightOf(r, c) sets each vertex's Y.
local function makeGrid(rows: number, cols: number, spacing: number, heightOf: (number, number) -> number)
	local vertices: { { Vector3 } } = {}
	local colors: { { { number } } } = {}
	for r = 0, rows do
		local vrow: { Vector3 } = {}
		local crow: { { number } } = {}
		for c = 0, cols do
			table.insert(vrow, Vector3.new(c * spacing, heightOf(r, c), r * spacing))
			table.insert(crow, { 0.5, 0.5, 0.5 })
		end
		table.insert(vertices, vrow)
		table.insert(colors, crow)
	end
	return vertices, colors
end

return function(t: TestTypes.TestContext)
	t.test("flat heightmap: smooth surface on top, thickness hangs below", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local surfaceY = 10
		local thickness = 1
		local vertices, colors = makeGrid(2, 2, 4, function()
			return surfaceY
		end)
		buildHeightmapMesh(vertices, colors, thickness, folder)

		local minY, maxY = meshYRange(folder)
		-- The input surface is the TOP face: geometry reaches up to it but not above.
		t.expect(math.abs(maxY - surfaceY) < 0.05).toBeTruthy()
		-- ...and the wedge thickness hangs a full thickness BELOW it.
		t.expect(math.abs(minY - (surfaceY - thickness)) < 0.05).toBeTruthy()

		folder:Destroy()
	end)

	t.test("sloped heightmap: no geometry pokes above the surface", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local thickness = 1
		-- A ramp rising +2 studs per row in +Z. Heights 0,2,4 over rows 0,1,2.
		local hMin, hMax = 0, 4
		local vertices, colors = makeGrid(2, 2, 4, function(r, _c)
			return r * 2
		end)
		buildHeightmapMesh(vertices, colors, thickness, folder)

		local minY, maxY = meshYRange(folder)
		-- Top face follows the ramp: highest geometry is the highest vertex, nothing
		-- above it (if generated upside-down this would be hMax + thickness).
		t.expect(maxY < hMax + 0.05).toBeTruthy()
		t.expect(maxY > hMax - 0.05).toBeTruthy()
		-- Thickness hangs below the lowest vertex.
		t.expect(minY < hMin - 0.5).toBeTruthy()

		folder:Destroy()
	end)
end
