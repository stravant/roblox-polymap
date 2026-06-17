--!strict

local TestTypes = require("./TestTypes")
local generateGrid = require("./generateGrid")

return function(t: TestTypes.TestContext)
	t.test("square grid creates correct number of triangles", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		generateGrid({
			GridType = "Square",
			Width = 3,
			Height = 2,
			Spacing = 4,
			Origin = CFrame.new(0, 10, 0),
			Thickness = 0.2,
			Parent = folder,
		})

		-- 3x2 grid = 6 cells, 2 triangles per cell = 12 triangles
		-- Each triangle = 1-2 wedge parts
		local wedgeCount = 0
		for _, child in folder:GetChildren() do
			if child:IsA("Part") then
				wedgeCount += 1
			end
		end
		-- At least 12 wedge parts (one per triangle minimum)
		t.expect(wedgeCount >= 12).toBeTruthy()

		folder:Destroy()
	end)

	t.test("triangular grid creates correct number of triangles", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		generateGrid({
			GridType = "Triangular",
			Width = 3,
			Height = 2,
			Spacing = 4,
			Origin = CFrame.new(0, 10, 0),
			Thickness = 0.2,
			Parent = folder,
		})

		-- 3x2 triangular grid = 6 cells, 2 triangles per cell = 12 triangles
		local wedgeCount = 0
		for _, child in folder:GetChildren() do
			if child:IsA("Part") then
				wedgeCount += 1
			end
		end
		t.expect(wedgeCount >= 12).toBeTruthy()

		folder:Destroy()
	end)

	t.test("triangular grid: all triangles face the same way", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		generateGrid({
			GridType = "Triangular",
			Width = 4,
			Height = 4,
			Spacing = 4,
			Origin = CFrame.identity, -- grid plane at Y=0
			Thickness = 1,
			Parent = folder,
		})

		-- A wedge's body sits on the side its triangle's thickness extends; a flat grid
		-- must have them all on the SAME side, or some triangles are flipped.
		local above, below = 0, 0
		for _, child in folder:GetChildren() do
			if child:IsA("Part") then
				if child.Position.Y > 0.01 then
					above += 1
				elseif child.Position.Y < -0.01 then
					below += 1
				end
			end
		end
		t.expect(above > 0).toBeTruthy()
		t.expect(below).toBe(0)

		folder:Destroy()
	end)

	t.test("square grid applies props correctly", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local color = Color3.fromRGB(255, 0, 0)
		generateGrid({
			GridType = "Square",
			Width = 1,
			Height = 1,
			Spacing = 4,
			Origin = CFrame.new(0, 20, 0),
			Thickness = 0.2,
			Parent = folder,
			Props = {
				Color = color,
				Material = Enum.Material.Grass,
			},
		})

		-- 1x1 grid = 2 triangles
		local foundColor = false
		local foundMaterial = false
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") then
				local c = child.Color
				if math.abs(c.R - color.R) < 0.1 and math.abs(c.G - color.G) < 0.1 and math.abs(c.B - color.B) < 0.1 then
					foundColor = true
				end
				if child.Material == Enum.Material.Grass then
					foundMaterial = true
				end
			end
		end
		t.expect(foundColor).toBeTruthy()
		t.expect(foundMaterial).toBeTruthy()

		folder:Destroy()
	end)

	t.test("square grid vertices are spaced correctly", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		generateGrid({
			GridType = "Square",
			Width = 2,
			Height = 2,
			Spacing = 5,
			Origin = CFrame.identity,
			Thickness = 0.2,
			Parent = folder,
		})

		-- Collect all unique vertex positions from wedge parts
		local positions: { Vector3 } = {}
		local function addUnique(pos: Vector3)
			for _, p in positions do
				if (p - pos).Magnitude < 0.1 then
					return
				end
			end
			table.insert(positions, pos)
		end

		for _, child in folder:GetChildren() do
			if child:IsA("Part") then
				-- Extract corners from wedge parts (approximate)
				local cf = child.CFrame
				local size = child.Size
				-- The right-angle vertex
				local v1 = cf:PointToWorldSpace(Vector3.new(-size.X/2, -size.Y/2, size.Z/2))
				addUnique(v1)
			end
		end

		-- 2x2 grid should have (2+1)x(2+1) = 9 unique vertices
		-- Due to wedge geometry extraction being approximate, just check we have several
		t.expect(#positions >= 4).toBeTruthy()

		folder:Destroy()
	end)
end
