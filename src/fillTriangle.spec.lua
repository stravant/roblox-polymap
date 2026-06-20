--!strict

local TestTypes = require("./TestTypes")
local fillTriangle = require("./fillTriangle")

return function(t: TestTypes.TestContext)
	t.test("creates 1-2 wedge parts for a basic triangle", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(0, 4, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		t.expect(#parts >= 1).toBeTruthy()
		t.expect(#parts <= 2).toBeTruthy()

		for _, part in parts do
			t.expect(part:IsA("Part")).toBeTruthy()
			t.expect((part :: Part).Shape == Enum.PartType.Wedge).toBeTruthy()
			t.expect(part.Anchored).toBe(true)
			-- Thickness is the smallest dimension
			local minSize = math.min(part.Size.X, part.Size.Y, part.Size.Z)
			t.expect(math.abs(minSize - 0.2) < 0.01).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("applies color and material props", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(0, 4, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder, {
			Color = Color3.new(1, 0, 0),
			Material = Enum.Material.Grass,
			Transparency = 0.5,
		})

		for _, part in parts do
			t.expect(part.Color).toBe(Color3.new(1, 0, 0))
			t.expect(part.Material).toBe(Enum.Material.Grass)
			t.expect(part.Transparency).toBe(0.5)
		end

		folder:Destroy()
	end)

	t.test("applies MaterialVariant to new parts and preserves it when regenerating", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(0, 4, 0)
		-- New parts take the variant from props.
		local parts = fillTriangle(a, b, c, 0.2, folder, {
			Material = Enum.Material.Plastic,
			MaterialVariant = "PolyMapTestVariant",
		})
		t.expect(#parts > 0).toBeTruthy()
		for _, part in parts do
			t.expect(part.MaterialVariant).toBe("PolyMapTestVariant")
		end

		-- Regenerating over the same parts (as a vertex move does) keeps the variant.
		local moved = fillTriangle(a, Vector3.new(4, 0, 1), c, 0.2, folder, nil, parts)
		for _, part in moved do
			t.expect(part.MaterialVariant).toBe("PolyMapTestVariant")
		end

		folder:Destroy()
	end)

	t.test("returns empty for degenerate triangle", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Collinear points
		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(1, 0, 0)
		local c = Vector3.new(2, 0, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		t.expect(#parts).toBe(0)

		folder:Destroy()
	end)

	t.test("returns empty for zero-area triangle", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Two identical points
		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(0, 0, 0)
		local c = Vector3.new(1, 0, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		t.expect(#parts).toBe(0)

		folder:Destroy()
	end)

	t.test("works for right-angle triangle (single wedge)", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Right angle at origin
		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(0, 0, 4)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- A right-angle triangle where the right angle vertex projects exactly to
		-- one end of the hypotenuse produces 1 wedge (the other has len < 0.001)
		t.expect(#parts >= 1).toBeTruthy()
		t.expect(#parts <= 2).toBeTruthy()

		folder:Destroy()
	end)

	t.test("works for equilateral triangle", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local a = Vector3.new(0, 0, 0)
		local b = Vector3.new(4, 0, 0)
		local c = Vector3.new(2, 0, 4 * math.sqrt(3) / 2)
		local parts = fillTriangle(a, b, c, 0.2, folder)

		-- Generate parts on the opposite side of the way the normal is facing
		local yDirection = math.sign((b-a):Cross(c-b).Y)
		local partSide = math.sign(parts[1].Position.Y)
		t.expect(yDirection).toBe(-partSide)

		t.expect(#parts).toBe(2)

		folder:Destroy()
	end)
end
