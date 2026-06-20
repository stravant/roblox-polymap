--!strict

local TestTypes = require("./TestTypes")
local createTriangleMesh = require("./TriangleMesh")
local fillTriangle = require("./fillTriangle")

return function(t: TestTypes.TestContext)
	t.test("addTriangle creates a triangle with vertices and edges", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		t.expect(triId).toBeTruthy()

		-- Should have 3 vertices
		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(3)

		-- Should have 3 edges
		local edgeCount = 0
		for _ in mesh.getEdges() do
			edgeCount += 1
		end
		t.expect(edgeCount).toBe(3)

		-- Should have 1 triangle
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(1)

		folder:Destroy()
	end)

	t.test("two adjacent triangles share vertices and edges", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, -3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		-- Should have 4 vertices (2 shared)
		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(4)

		-- Should have 5 edges (1 shared)
		local edgeCount = 0
		for _ in mesh.getEdges() do
			edgeCount += 1
		end
		t.expect(edgeCount).toBe(5)

		folder:Destroy()
	end)

	t.test("getBoundaryEdges returns correct edges", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		-- A single triangle should have 3 boundary edges
		local boundary = mesh.getBoundaryEdges()
		t.expect(#boundary).toBe(3)

		-- Add adjacent triangle
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, -3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		-- Now the shared edge is internal, so 4 boundary edges
		boundary = mesh.getBoundaryEdges()
		t.expect(#boundary).toBe(4)

		folder:Destroy()
	end)

	t.test("getEdges is keyed by minVertexId_maxVertexId for vertex-pair lookup", function()
		-- Add mode (findNearestBoundaryEdge, edge snapping) looks edges up by
		-- building "minVid_maxVid" and indexing getEdges(); this guards that the
		-- map is keyed that way rather than by the internal numeric EdgeId.
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(triId)
		local tri = mesh.getTriangle(triId)
		assert(tri)

		local edges = mesh.getEdges()
		local verts = tri.vertices
		local edgePairs = { { verts[1], verts[2] }, { verts[2], verts[3] }, { verts[3], verts[1] } }
		for _, pair in edgePairs do
			local key = tostring(math.min(pair[1], pair[2])) .. "_" .. tostring(math.max(pair[1], pair[2]))
			local edge = edges[key]
			t.expect(edge).toBeTruthy()
			assert(edge)
			local matches = (edge.v1 == pair[1] and edge.v2 == pair[2])
				or (edge.v1 == pair[2] and edge.v2 == pair[1])
			t.expect(matches).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("removeTriangle removes triangle and cleans up orphan vertices", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(triId)

		mesh.removeTriangle(triId)

		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(0)

		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(0)

		folder:Destroy()
	end)

	t.test("removeTriangle preserves shared vertices", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local tri1 = mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, -3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(tri1)

		mesh.removeTriangle(tri1)

		-- Should still have 3 vertices (shared 2 + the unique bottom one)
		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(3)

		folder:Destroy()
	end)

	t.test("getVertexNeighbors returns adjacent vertices", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		-- Find the vertex at (0,0,0)
		local vid = mesh.findVertexNear(Vector3.new(0, 0, 0), 0.1)
		t.expect(vid).toBeTruthy()
		assert(vid)

		local neighbors = mesh.getVertexNeighbors(vid)
		t.expect(#neighbors).toBe(2)

		folder:Destroy()
	end)

	t.test("findVertexNear finds closest vertex", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		local vid = mesh.findVertexNear(Vector3.new(0.01, 0, 0), 1)
		t.expect(vid).toBeTruthy()

		local noVid = mesh.findVertexNear(Vector3.new(100, 100, 100), 1)
		t.expect(noVid == nil).toBeTruthy()

		folder:Destroy()
	end)

	t.test("removeTriangle parents out parts instead of destroying", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(triId)

		local tri = mesh.getTriangle(triId)
		assert(tri)
		local parts = table.clone(tri.parts)

		mesh.removeTriangle(triId)

		-- Parts should still be re-parentable (not destroyed)
		for _, part in parts do
			t.expect(part.Parent).toBe(nil)
			part.Parent = folder
			t.expect(part.Parent).toBe(folder)
		end

		folder:Destroy()
	end)

	t.test("moveVertex updates vertex position and recreates parts", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		local vid = mesh.findVertexNear(Vector3.new(2, 0, 3), 0.1)
		t.expect(vid).toBeTruthy()
		assert(vid)

		mesh.moveVertex(vid, Vector3.new(2, 0, 5), 0.2)

		local vertex = mesh.getVertex(vid)
		t.expect(vertex).toBeTruthy()
		assert(vertex)
		t.expect((vertex.position - Vector3.new(2, 0, 5)).Magnitude < 0.02).toBeTruthy()

		-- Should still have 1 triangle
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(1)

		folder:Destroy()
	end)

	t.test("moveVertex regenerates parts at the triangle's own thickness", function()
		-- A triangle keeps the thickness it was discovered/created with when a
		-- vertex moves; the regenerated wedge parts must NOT snap to some other
		-- (e.g. the current global) thickness. fillTriangle makes the thin wedge
		-- dimension its local X, so part.Size.X is the thickness.
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(700, 0, 0),
			Vector3.new(704, 0, 0),
			Vector3.new(702, 0, 3),
			0.5, folder, nil, Vector3.new(702, 1, 1)
		)
		assert(triId)
		local tri = mesh.getTriangle(triId)
		assert(tri)
		t.expect(math.abs(tri.thickness - 0.5) < 1e-4).toBeTruthy()
		t.expect(math.abs(tri.parts[1].Size.X - 0.5) < 1e-4).toBeTruthy()

		-- Move a vertex, passing a DIFFERENT thickness. It must be ignored: the
		-- regenerated parts keep the triangle's recorded 0.5 thickness.
		local vid = mesh.findVertexNear(Vector3.new(702, 0, 3), 0.1)
		assert(vid)
		mesh.moveVertex(vid, Vector3.new(702, 2, 5), 0.2)

		local movedTri = mesh.getTriangle(triId)
		assert(movedTri)
		t.expect(math.abs(movedTri.thickness - 0.5) < 1e-4).toBeTruthy()
		for _, part in movedTri.parts do
			t.expect(math.abs(part.Size.X - 0.5) < 1e-4).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("moveVertex reuses the same Part instances", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(triId)

		-- Save references to parts before moving
		local triBefore = mesh.getTriangle(triId)
		assert(triBefore)
		local partsBefore = table.clone(triBefore.parts)

		local vid = mesh.findVertexNear(Vector3.new(2, 0, 3), 0.1)
		assert(vid)

		mesh.moveVertex(vid, Vector3.new(2, 0, 5), 0.2)

		-- Triangle should still exist with same ID (edit-in-place)
		local triAfter = mesh.getTriangle(triId)
		t.expect(triAfter).toBeTruthy()
		assert(triAfter)

		-- Same number of parts
		t.expect(#triAfter.parts).toBe(#partsBefore)

		-- Same Part instances (reused, not recreated)
		for i, part in triAfter.parts do
			t.expect(part).toBe(partsBefore[i])
		end

		folder:Destroy()
	end)

	t.test("discoverPart pairs fillTriangle wedges", function()
		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(22, 10, 1.5), 10) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a triangle via fillTriangle (produces 1-2 wedge parts)
		local a = Vector3.new(20, 10, 0)
		local b = Vector3.new(24, 10, 0)
		local c = Vector3.new(22, 10, 3)
		local parts = fillTriangle(a, b, c, 0.2, folder)
		t.expect(#parts > 0).toBeTruthy()

		-- Discover one of the parts (hintPoint above the triangle)
		local hintPoint = Vector3.new(22, 11, 1.5)
		local triId = mesh.discoverPart(parts[1], hintPoint)
		t.expect(triId).toBeTruthy()

		-- Should have 1 triangle with 3 vertices
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(1)

		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(3)

		-- Both parts should be tracked
		for _, part in parts do
			t.expect(mesh.getPartTriangle(part, hintPoint)).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("discoverPart with refuseAwayFace skips the far thin face, keeps the near one", function()
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(2200, 10, 0), 30) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local parts = fillTriangle(
			Vector3.new(2200, 10, 0), Vector3.new(2204, 10, 0), Vector3.new(2202, 10, 3),
			0.2, folder
		)
		local wedge = parts[1]
		assert(wedge)
		local center = wedge.CFrame.Position
		local right = wedge.CFrame.RightVector -- the wedge's thin axis
		local viewPoint = center + right * 50 -- camera on the near (+Right) side
		local farHint = center - right -- grazing the far side
		local nearHint = center + right -- the camera-facing side

		-- An interactive hover (refuseAwayFace=true) grazing the far side adopts nothing...
		local farId = mesh.discoverPart(wedge, farHint, viewPoint, nil, true)
		t.expect(farId == nil).toBeTruthy()
		t.expect(#mesh.getPartTriangles(wedge)).toBe(0)

		-- ...the camera-facing side discovers normally.
		local nearId = mesh.discoverPart(wedge, nearHint, viewPoint, nil, true)
		t.expect(nearId ~= nil).toBeTruthy()
		t.expect(#mesh.getPartTriangles(wedge) > 0).toBeTruthy()

		folder:Destroy()
	end)

	t.test("discoverPart without refuseAwayFace still adopts the far face (region/rebuild)", function()
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(2240, 10, 0), 30) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local parts = fillTriangle(
			Vector3.new(2240, 10, 0), Vector3.new(2244, 10, 0), Vector3.new(2242, 10, 3),
			0.2, folder
		)
		local wedge = parts[1]
		assert(wedge)
		local center = wedge.CFrame.Position
		local right = wedge.CFrame.RightVector
		local viewPoint = center + right * 50
		local farHint = center - right

		-- Region scans and the undo rebuild must adopt whatever side their seed sits
		-- on, so the camera filter is OFF (refuseAwayFace nil) -- the far side discovers.
		local id = mesh.discoverPart(wedge, farHint, viewPoint, nil, nil)
		t.expect(id ~= nil).toBeTruthy()
		t.expect(#mesh.getPartTriangles(wedge) > 0).toBeTruthy()

		folder:Destroy()
	end)

	t.test("discoverPart returns cached ID on repeat call", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local parts = fillTriangle(
			Vector3.new(30, 10, 0),
			Vector3.new(34, 10, 0),
			Vector3.new(32, 10, 3),
			0.2, folder
		)

		local hintPoint = Vector3.new(32, 11, 1.5)
		local triId1 = mesh.discoverPart(parts[1], hintPoint)
		local triId2 = mesh.discoverPart(parts[1], hintPoint)
		t.expect(triId1).toBe(triId2)

		folder:Destroy()
	end)

	t.test("discoverRegion discovers multiple triangles", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create two separate triangles near each other (far from other tests)
		fillTriangle(
			Vector3.new(200, 10, 0),
			Vector3.new(204, 10, 0),
			Vector3.new(202, 10, 3),
			0.2, folder
		)
		fillTriangle(
			Vector3.new(200, 10, 0),
			Vector3.new(204, 10, 0),
			Vector3.new(202, 10, -3),
			0.2, folder
		)

		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(202, 10, 0), 25) do
			if p:IsA("BasePart") and p.Parent ~= folder then
				p:Destroy()
			end
		end

		-- Discover the region covering both
		mesh.discoverRegion({Vector3.new(202, 10, 0)}, 20)

		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(2)

		folder:Destroy()
	end)

	t.test("getPartTriangle returns correct mapping", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(52, 10, 0), 10) do
			if p:IsA("BasePart") then
				p:Destroy()
			end
		end

		local parts = fillTriangle(
			Vector3.new(50, 10, 0),
			Vector3.new(54, 10, 0),
			Vector3.new(52, 10, 3),
			0.2, folder
		)

		local hintPoint = Vector3.new(52, 11, 1.5)
		local triId = mesh.discoverPart(parts[1], hintPoint)
		t.expect(triId).toBeTruthy()

		-- Each part should map to the same triangle
		for _, part in parts do
			t.expect(mesh.getPartTriangle(part, hintPoint)).toBe(triId)
		end

		-- A random new part should not be tracked
		local randomPart = Instance.new("Part")
		randomPart.Parent = folder
		t.expect(mesh.getPartTriangle(randomPart, hintPoint) == nil).toBeTruthy()

		folder:Destroy()
	end)

	t.test("discoverPart finds thin Block as two triangles", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a thin block part (thin along Y)
		local block = Instance.new("Part")
		block.Shape = Enum.PartType.Block
		block.Size = Vector3.new(4, 0.2, 3)
		block.CFrame = CFrame.new(300, 10, 0)
		block.Anchored = true
		block.Parent = folder

		-- hintPoint above block center
		local blockHint = Vector3.new(300, 10.2, 0)
		local triId = mesh.discoverPart(block, blockHint)
		t.expect(triId).toBeTruthy()

		-- Should have 2 triangles (Block = quad = 2 triangles)
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(2)

		-- Should have 4 vertices (rectangle corners)
		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(4)

		-- Block part should be tracked
		t.expect(mesh.getPartTriangle(block, blockHint)).toBeTruthy()

		folder:Destroy()
	end)

	t.test("moveVertex upgrades Block to Wedges", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a thin block part
		local block = Instance.new("Part")
		block.Shape = Enum.PartType.Block
		block.Size = Vector3.new(4, 0.2, 3)
		block.CFrame = CFrame.new(320, 10, 0)
		block.Anchored = true
		block.Parent = folder

		mesh.discoverPart(block, Vector3.new(320, 10.2, 0))

		-- Find a vertex and move it up (making the quad non-planar)
		local vid = mesh.findVertexNear(Vector3.new(322, 10.1, 1.5), 1)
		t.expect(vid).toBeTruthy()
		assert(vid)

		mesh.moveVertex(vid, Vector3.new(322, 12, 1.5), 0.2)

		-- Block should be destroyed (Parent = nil)
		t.expect(block.Parent).toBe(nil)

		-- Should still have 2 triangles with Wedge parts
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(2)

		-- All parts should be wedge-shaped
		for _, tri in mesh.getTriangles() do
			for _, part in tri.parts do
				t.expect(part.Parent).toBe(folder)
				t.expect((part :: Part).Shape).toBe(Enum.PartType.Wedge)
			end
		end

		folder:Destroy()
	end)

	t.test("removeTriangle on Block upgrades sibling to Wedges", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a thin block
		local block = Instance.new("Part")
		block.Shape = Enum.PartType.Block
		block.Size = Vector3.new(4, 0.2, 3)
		block.CFrame = CFrame.new(330, 10, 0)
		block.Anchored = true
		block.Parent = folder

		local triId = mesh.discoverPart(block, Vector3.new(330, 10.2, 0))
		t.expect(triId).toBeTruthy()
		assert(triId)

		-- Remove one triangle
		mesh.removeTriangle(triId)

		-- Block should be destroyed
		t.expect(block.Parent).toBe(nil)

		-- Should have 1 remaining triangle (the sibling, upgraded to Wedges)
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(1)

		-- The remaining triangle's parts should be Wedge parts
		for _, tri in mesh.getTriangles() do
			for _, part in tri.parts do
				t.expect(part.Parent).toBe(folder)
				t.expect((part :: Part).Shape).toBe(Enum.PartType.Wedge)
			end
		end

		folder:Destroy()
	end)

	t.test("upgrading a Block to Wedges preserves its colour and material", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- A distinctly coloured/materialed block, not the wedge default grey.
		local block = Instance.new("Part")
		block.Shape = Enum.PartType.Block
		block.Size = Vector3.new(4, 0.2, 3)
		block.CFrame = CFrame.new(1300, 10, 0)
		block.Anchored = true
		block.Color = Color3.fromRGB(200, 40, 40)
		block.Material = Enum.Material.Slate
		block.Transparency = 0.25
		block.MaterialVariant = "PolyMapTestVariant"
		block.Parent = folder

		mesh.discoverPart(block, Vector3.new(1300, 10.2, 0))

		-- Editing a vertex triggers the Block -> Wedge upgrade.
		local vid = mesh.findVertexNear(Vector3.new(1302, 10.1, 1.5), 1)
		assert(vid)
		mesh.moveVertex(vid, Vector3.new(1302, 12, 1.5), 0.2)
		t.expect(block.Parent).toBe(nil)

		-- The generated wedges must inherit the block's appearance.
		local wedges = 0
		for _, tri in mesh.getTriangles() do
			for _, part in tri.parts do
				wedges += 1
				t.expect((part :: Part).Shape).toBe(Enum.PartType.Wedge)
				t.expect(part.Material).toBe(Enum.Material.Slate)
				t.expect(part.MaterialVariant).toBe("PolyMapTestVariant")
				local c = part.Color
				t.expect(math.abs(c.R - 200 / 255) < 0.01).toBeTruthy()
				t.expect(math.abs(c.G - 40 / 255) < 0.01).toBeTruthy()
				t.expect(math.abs(c.B - 40 / 255) < 0.01).toBeTruthy()
				t.expect(math.abs(part.Transparency - 0.25) < 0.001).toBeTruthy()
			end
		end
		t.expect(wedges > 0).toBeTruthy()

		folder:Destroy()
	end)

	t.test("discoverPart uses the viewpoint to pick a thin Block's camera-facing face", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local function makeBlock(x: number): BasePart
			local block = Instance.new("Part")
			block.Shape = Enum.PartType.Block
			block.Size = Vector3.new(4, 0.2, 3) -- thin along Y, centred at Y=10
			block.CFrame = CFrame.new(x, 10, 0)
			block.Anchored = true
			block.Parent = folder
			return block
		end

		-- A hit grazing just BELOW centre -- as the cursor crossing the slab's side
		-- does -- would pick the bottom face on its own. A viewpoint high above must
		-- override it and adopt the TOP face (corners at Y ~ 10.1).
		local meshTop = createTriangleMesh()
		meshTop.discoverPart(makeBlock(1340), Vector3.new(1342, 9.96, 0), Vector3.new(1340, 40, 0))
		local topCount = 0
		for _, v in meshTop.getVertices() do
			topCount += 1
			t.expect(v.position.Y > 10.0).toBeTruthy()
		end
		t.expect(topCount).toBe(4)

		-- And the converse: a hit just above centre with a viewpoint below adopts the
		-- BOTTOM face -- proving the viewpoint, not the hit point, decides the side.
		local meshBot = createTriangleMesh()
		meshBot.discoverPart(makeBlock(1360), Vector3.new(1362, 10.04, 0), Vector3.new(1360, -20, 0))
		for _, v in meshBot.getVertices() do
			t.expect(v.position.Y < 10.0).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("discoverRegion adopts a box-on-baseplate's camera-facing face", function()
		-- The user's bug: a thin box sitting on a baseplate is grabbed on its BACK
		-- (bottom) face. When the cursor is near the box, its raycast hits the
		-- baseplate, and the Add tool's region scan is seeded at that point -- on the
		-- box's BOTTOM plane (= the baseplate's top). Without a viewpoint discoverRegion
		-- bootstraps the box from there and locks the bottom face. With the camera eye
		-- high above it must adopt the TOP face instead.
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local baseplate = Instance.new("Part")
		baseplate.Shape = Enum.PartType.Block
		baseplate.Size = Vector3.new(40, 1, 40)
		baseplate.CFrame = CFrame.new(1380, 9.4, 0) -- top surface at Y=9.9
		baseplate.Anchored = true
		baseplate.Parent = folder

		local box = Instance.new("Part")
		box.Shape = Enum.PartType.Block
		box.Size = Vector3.new(4, 0.2, 4) -- thin along Y; bottom 9.9, top 10.1
		box.CFrame = CFrame.new(1380, 10, 0)
		box.Anchored = true
		box.Parent = folder

		-- Seed on the box's bottom plane (where the baseplate hit lands), camera above.
		mesh.discoverRegion({ Vector3.new(1380, 9.9, 0) }, 6, Vector3.new(1380, 40, 0))

		local boxTris = mesh.getPartTriangles(box)
		t.expect(#boxTris > 0).toBeTruthy()
		for _, tid in boxTris do
			local tri = mesh.getTriangle(tid)
			assert(tri)
			for _, vid in tri.vertices do
				local v = mesh.getVertex(vid)
				assert(v)
				t.expect(v.position.Y > 10.0).toBeTruthy() -- top face, not bottom
			end
		end

		folder:Destroy()
	end)

	t.test("discoverRegion orients a thin Block's face outward even seeded from a face corner (no viewpoint)", function()
		-- Repro for the undo bug: after an undo, rediscoverMesh rebuilds with NO
		-- viewpoint, seeded from the restored vertex positions -- which for a thin
		-- slab's top face are its top-face CORNERS. A corner lies in the face plane, so
		-- orienting the normal by (corner - faceCentroid) is degenerate; it used to leave
		-- the normal pointing into the slab, which then upgraded the Block to wedges on
		-- the wrong side. The adopted face must read outward (+Y here) regardless.
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local block = Instance.new("Part")
		block.Shape = Enum.PartType.Block
		block.Size = Vector3.new(8, 0.2, 8) -- thin along Y; top face at Y=10.1
		block.CFrame = CFrame.new(1395, 10, 0)
		block.Anchored = true
		block.Parent = folder

		local mesh = createTriangleMesh()
		-- Seed exactly on a TOP-FACE CORNER, no viewpoint (the rebuild path).
		mesh.discoverRegion({ Vector3.new(1399, 10.1, 4) }, 6)

		local found = 0
		for _, tri in mesh.getTriangles() do
			found += 1
			t.expect(tri.normal.Y > 0.5).toBeTruthy() -- outward (up), not into the slab
		end
		t.expect(found).toBe(2)

		folder:Destroy()
	end)

	t.test("discovery ignores parts literally named Baseplate", function()
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(1500, 10, 0), 80) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- A block named "Baseplate": a seed on its top would normally bootstrap it into
		-- two giant triangles. It must be skipped so no tool ever turns it into mesh.
		local baseplate = Instance.new("Part")
		baseplate.Name = "Baseplate"
		baseplate.Shape = Enum.PartType.Block
		baseplate.Size = Vector3.new(40, 1, 40)
		baseplate.CFrame = CFrame.new(1500, 9.5, 0) -- top at Y=10
		baseplate.Anchored = true
		baseplate.Parent = folder

		mesh.discoverRegion({ Vector3.new(1500, 10, 0) }, 6, Vector3.new(1500, 40, 0))
		t.expect(#mesh.getPartTriangles(baseplate)).toBe(0)

		-- An identically-shaped block with any other name still discovers, proving the
		-- filter is by name rather than a blanket block on Blocks.
		local box = Instance.new("Part")
		box.Name = "Box"
		box.Shape = Enum.PartType.Block
		box.Size = Vector3.new(4, 1, 4)
		box.CFrame = CFrame.new(1540, 9.5, 0) -- top at Y=10, clear of the baseplate
		box.Anchored = true
		box.Parent = folder

		mesh.discoverRegion({ Vector3.new(1540, 10, 0) }, 6, Vector3.new(1540, 40, 0))
		t.expect(#mesh.getPartTriangles(box) > 0).toBeTruthy()

		folder:Destroy()
	end)

	t.test("walkSurface returns seed triangle with small radius", function()
		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(402, 0, 0), 10) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Use far-away positions to avoid picking up other test geometry
		local triId = mesh.addTriangle(
			Vector3.new(400, 0, 0),
			Vector3.new(404, 0, 0),
			Vector3.new(402, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(triId)

		-- Radius of 3 centered on the centroid should return the seed triangle
		local center = (Vector3.new(400, 0, 0) + Vector3.new(404, 0, 0) + Vector3.new(402, 0, 3)) / 3
		local triangles, vertices = mesh.walkSurface(triId, center, 3)

		t.expect(#triangles).toBe(1)
		t.expect(triangles[1]).toBe(triId)
		t.expect(#vertices).toBe(3)

		folder:Destroy()
	end)

	t.test("walkSurface walks connected triangles within radius", function()
		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(422, 0, 0), 15) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create two adjacent triangles far from other test geometry
		local tri1 = mesh.addTriangle(
			Vector3.new(420, 0, 0),
			Vector3.new(424, 0, 0),
			Vector3.new(422, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		local tri2 = mesh.addTriangle(
			Vector3.new(420, 0, 0),
			Vector3.new(424, 0, 0),
			Vector3.new(422, 0, -3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(tri1)
		assert(tri2)

		-- Walk from tri1 with a large enough radius to include both
		local triangles, vertices = mesh.walkSurface(tri1, Vector3.new(422, 0, 0), 10)

		t.expect(#triangles).toBe(2)
		t.expect(#vertices).toBe(4)

		folder:Destroy()
	end)

	t.test("walkSurface does NOT include disconnected triangles at same position", function()
		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(442, 5, 0), 20) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create two disconnected triangles at nearby positions (no shared vertices)
		local tri1 = mesh.addTriangle(
			Vector3.new(440, 0, 0),
			Vector3.new(444, 0, 0),
			Vector3.new(442, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		-- This triangle is 10 units above, nearby but shares no vertices/edges
		local tri2 = mesh.addTriangle(
			Vector3.new(440, 10, 0),
			Vector3.new(444, 10, 0),
			Vector3.new(442, 10, 3),
			0.2, folder, nil, Vector3.new(442, 11, 1)
		)
		assert(tri1)
		assert(tri2)

		-- Walk from tri1 — should not cross to tri2 even though it's in the mesh
		local triangles = mesh.walkSurface(tri1, Vector3.new(442, 0, 1), 10)

		t.expect(#triangles).toBe(1)
		t.expect(triangles[1]).toBe(tri1)

		folder:Destroy()
	end)

	t.test("walkSurface returns correct vertex IDs", function()
		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(462, 0, 0), 10) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(460, 0, 0),
			Vector3.new(464, 0, 0),
			Vector3.new(462, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		assert(triId)

		-- Large radius to include all vertices
		local triangles, vertices = mesh.walkSurface(triId, Vector3.new(462, 0, 1), 20)

		t.expect(#triangles).toBe(1)
		t.expect(#vertices).toBe(3)

		-- All returned vertex IDs should be valid
		for _, vid in vertices do
			t.expect(mesh.getVertex(vid)).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("discoverPart recovers correct vertices for underhanging triangle", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Clean up any leftover parts from previous runs
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(482, 10, 0), 10) do
			if p:IsA("BasePart") and p.Parent ~= folder then
				p:Destroy()
			end
		end

		-- Create an underhanging triangle via fillTriangle with invertNormal=true
		-- so the parts are oriented with the surface face pointing downward.
		local a = Vector3.new(480, 10, 0)
		local b = Vector3.new(482, 10, 3)
		local c = Vector3.new(484, 10, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder, nil, nil, true)
		t.expect(#parts > 0).toBeTruthy()

		-- Discover the parts from below (hintPoint below center matches the inverted surface)
		local triId = mesh.discoverPart(parts[1], Vector3.new(482, 9.8, 1))
		t.expect(triId).toBeTruthy()
		assert(triId)

		-- The discovered triangle's vertices should match the original positions
		local tri = mesh.getTriangle(triId)
		assert(tri)
		local discoveredPositions: { Vector3 } = {}
		for _, vid in tri.vertices do
			local v = mesh.getVertex(vid)
			assert(v)
			table.insert(discoveredPositions, v.position)
		end

		-- Check that each original vertex has a match in the discovered positions
		local EPSILON = 0.05
		for _, original in { a, b, c } do
			local found = false
			for _, discovered in discoveredPositions do
				if (original - discovered).Magnitude < EPSILON then
					found = true
					break
				end
			end
			t.expect(found).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("discoverPart recovers correct vertices for vertical wall triangle", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a vertical wall triangle with invertNormal=true so the surface
		-- face (at Z=600) has outward normal pointing in -Z direction.
		local a = Vector3.new(600, 0, 600)
		local b = Vector3.new(604, 0, 600)
		local c = Vector3.new(602, 3, 600)
		local parts = fillTriangle(a, b, c, 0.2, folder, nil, nil, true)
		t.expect(#parts > 0).toBeTruthy()

		-- Vertical wall: hintPoint on the -Z side of the surface at Z=600
		local triId = mesh.discoverPart(parts[1], Vector3.new(602, 1, 599.8))
		t.expect(triId).toBeTruthy()
		assert(triId)

		local tri = mesh.getTriangle(triId)
		assert(tri)
		local discoveredPositions: { Vector3 } = {}
		for _, vid in tri.vertices do
			local v = mesh.getVertex(vid)
			assert(v)
			table.insert(discoveredPositions, v.position)
		end

		local EPSILON = 0.05
		for _, original in { a, b, c } do
			local found = false
			for _, discovered in discoveredPositions do
				if (original - discovered).Magnitude < EPSILON then
					found = true
					break
				end
			end
			t.expect(found).toBeTruthy()
		end

		folder:Destroy()
	end)

	t.test("walkSurface connects adjacent underhanging triangles", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Clean up any leftover parts from previous test runs
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(1002, 10, 1000), 30) do
			if p:IsA("BasePart") then
				p:Destroy()
			end
		end

		-- Create two adjacent underhanging triangles via fillTriangle.
		-- Use invertNormal=true so the surface face at Y=10 has outward
		-- normal pointing downward (-Y), matching our hitNormal.
		local a = Vector3.new(1000, 10, 1000)
		local b = Vector3.new(1002, 10, 1003)
		local c = Vector3.new(1004, 10, 1000)
		local d = Vector3.new(1002, 10, 997)
		fillTriangle(a, b, c, 0.2, folder, nil, nil, true)
		fillTriangle(a, c, d, 0.2, folder, nil, nil, true)

		-- Discover all parts in the region (hintPoint below for underhanging)
		mesh.discoverRegion({Vector3.new(1002, 10, 1000)}, 20)

		-- Should have 2 triangles with 4 vertices (a, b, c, d)
		local triCount = 0
		local firstTriId: number? = nil
		for triId in mesh.getTriangles() do
			triCount += 1
			if not firstTriId then
				firstTriId = triId
			end
		end
		t.expect(triCount).toBe(2)

		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(4)

		-- Walk from one triangle should reach both
		assert(firstTriId)
		local triangles = mesh.walkSurface(firstTriId, Vector3.new(1002, 10, 1000), 20)
		t.expect(#triangles).toBe(2)

		folder:Destroy()
	end)

	t.test("walkSurface connects adjacent vertical wall triangles", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Clean up any leftover parts from previous test runs
		local center = Vector3.new(1102, 0, 1100)
		for _, p in workspace:GetPartBoundsInRadius(center, 30) do
			if p:IsA("BasePart") then
				p:Destroy()
			end
		end

		-- Two adjacent vertical wall triangles sharing edge a-b
		local a = Vector3.new(1100, 0, 1100)
		local b = Vector3.new(1104, 0, 1100)
		local c = Vector3.new(1102, 3, 1100)
		local d = Vector3.new(1102, -3, 1100)
		local parts1 = fillTriangle(a, b, c, 0.2, folder)
		fillTriangle(a, b, d, 0.2, folder)

		-- Triangle 1 has natural normal +Z, so depth extends in -Z from Z=1100
		-- to Z=1099.8. The surface face at Z=1100 has outward normal +Z.
		-- Triangle 2 has natural normal -Z, so depth extends in +Z from Z=1100
		-- to Z=1100.2. discoverRegion's snap fallback selects the correct face
		-- for triangle 2 by matching existing vertex positions.
		-- hintPoint on the +Z side of the wall surface at Z=1100
		local wallHint = Vector3.new(1102, 1, 1100.2)
		mesh.discoverPart(parts1[1], wallHint)
		mesh.discoverRegion({Vector3.new(1102, 0, 1100)}, 20)

		local triCount = 0
		local firstTriId: number? = nil
		for triId in mesh.getTriangles() do
			triCount += 1
			if not firstTriId then
				firstTriId = triId
			end
		end
		t.expect(triCount).toBe(2)

		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(4)

		assert(firstTriId)
		local triangles = mesh.walkSurface(firstTriId, Vector3.new(1102, 0, 1100), 20)
		t.expect(#triangles).toBe(2)

		folder:Destroy()
	end)

	t.test("a wedge part maps to its one triangle from either side (no phantom back face)", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- A single horizontal triangle. A wedge part is single-sided: it backs
		-- exactly ONE logical triangle. Hovering/clicking either face must resolve
		-- to that same triangle, and must never spawn a phantom triangle on the
		-- opposite face -- that doubling is what broke hover discovery/selection.
		local a = Vector3.new(1200, 5, 0)
		local b = Vector3.new(1204, 5, 0)
		local c = Vector3.new(1202, 5, 3)
		local triId = mesh.addTriangle(a, b, c, 0.2, folder, nil, Vector3.new(1202, 6, 1))
		assert(triId)
		local tri = mesh.getTriangle(triId)
		assert(tri)
		local part = tri.parts[1]

		local function triangleCount(): number
			local n = 0
			for _ in mesh.getTriangles() do
				n += 1
			end
			return n
		end
		local before = triangleCount()

		-- Maps to the one triangle whether the hint is above or below the part.
		t.expect(mesh.getPartTriangle(part, Vector3.new(1202, 6, 1))).toBe(triId)
		t.expect(mesh.getPartTriangle(part, Vector3.new(1202, 4, 1))).toBe(triId)

		-- Re-discovering from the opposite side returns the SAME triangle and adds
		-- nothing (no phantom back face).
		t.expect(mesh.discoverPart(part, Vector3.new(1202, 4, 1))).toBe(triId)
		t.expect(mesh.discoverPart(part, Vector3.new(1202, 6, 1))).toBe(triId)
		t.expect(triangleCount()).toBe(before)

		folder:Destroy()
	end)

	t.test("discoverRegion expands from already-discovered vertices", function()
		-- Clean up any foreign parts in the test area
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(1406, 10, 0), 30) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a strip of 3 adjacent triangles along X, sharing vertices:
		-- T1: (1400,10,0)-(1404,10,0)-(1402,10,3) — shares (1404,10,0) with T2
		-- T2: (1404,10,0)-(1408,10,0)-(1406,10,3) — shares (1408,10,0) with T3
		-- T3: (1408,10,0)-(1412,10,0)-(1410,10,3)
		fillTriangle(
			Vector3.new(1400, 10, 0), Vector3.new(1404, 10, 0), Vector3.new(1402, 10, 3),
			0.2, folder
		)
		fillTriangle(
			Vector3.new(1404, 10, 0), Vector3.new(1408, 10, 0), Vector3.new(1406, 10, 3),
			0.2, folder
		)
		fillTriangle(
			Vector3.new(1408, 10, 0), Vector3.new(1412, 10, 0), Vector3.new(1410, 10, 3),
			0.2, folder
		)

		-- First call: discover with radius 5 from T1's first vertex.
		-- Within radius 5: v(1400) dist 0, v(1404) dist 4, v(1402,10,3) dist 3.6
		-- T1 returned (has v(1400)), T2 returned (has v(1404) at dist 4)
		-- T3 not returned (closest vertex v(1408) at dist 8)
		local tris1 = mesh.discoverRegion({Vector3.new(1400, 10, 0)}, 5)
		t.expect(#tris1).toBe(2)

		-- Second call: larger radius should discover all 3 triangles.
		-- Radius 15 from (1400,10,0) covers all vertices (max dist 12).
		-- Without the fix, the O(1) bootstrap pre-marks the seed vertex's
		-- triangles as visited, so the BFS never expands and returns only 1.
		local tris2 = mesh.discoverRegion({Vector3.new(1400, 10, 0)}, 15)
		t.expect(#tris2).toBe(3)

		folder:Destroy()
	end)

	t.test("discoverRegion rebuilds the full connected mesh for undo rediscovery", function()
		-- Regression for rediscoverMesh(): after an undo/redo the in-memory mesh
		-- is cleared and rebuilt from the currently-known vertex positions. A
		-- fixed radius (the old value was 5) would leave connected geometry
		-- further out untracked -- e.g. after undoing a large Delete -- so
		-- rediscovery walks the whole connected mesh with an unbounded radius.
		for _, p in workspace:GetPartBoundsInRadius(Vector3.new(1712, 10, 1.5), 60) do
			if p:IsA("BasePart") then p:Destroy() end
		end
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- A chain of 6 adjacent triangles along X (each 4 studs wide, ~24 total),
		-- far longer than the old fixed rediscovery radius of 5.
		local stripCount = 6
		for i = 0, stripCount - 1 do
			local x = 1700 + i * 4
			fillTriangle(
				Vector3.new(x, 10, 0), Vector3.new(x + 4, 10, 0), Vector3.new(x + 2, 10, 3),
				0.2, folder
			)
		end

		-- From a single seed at one end, an unbounded radius must walk the entire
		-- connected chain. (With the old radius of 5 only the first ~2 are found.)
		local tris = mesh.discoverRegion({Vector3.new(1700, 10, 0)}, math.huge)
		t.expect(#tris).toBe(stripCount)

		-- Emulate the rediscover step itself: snapshot every known vertex, clear,
		-- and rebuild. Nothing should be lost.
		local seeds: { Vector3 } = {}
		for _, v in mesh.getVertices() do
			table.insert(seeds, v.position)
		end
		mesh.clear()
		mesh.discoverRegion(seeds, math.huge)

		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(stripCount)

		folder:Destroy()
	end)

	t.test("addTriangle preserves normal direction for adjacent triangle", function()
		-- When extending a mesh via Add mode, the new triangle should face the
		-- same direction as the parent. This requires a hintPoint offset from
		-- the surface by the parent normal — NOT the click position (which is
		-- on the surface and makes the direction ambiguous).
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create an upward-facing parent triangle at Y=10
		local a = Vector3.new(1500, 10, 0)
		local b = Vector3.new(1504, 10, 0)
		local c = Vector3.new(1502, 10, 3)
		local parentId = mesh.addTriangle(a, b, c, 0.2, folder, nil, Vector3.new(1502, 11, 1))
		assert(parentId)
		local parentTri = mesh.getTriangle(parentId)
		assert(parentTri)
		t.expect(parentTri.normal.Y > 0.9).toBeTruthy()

		-- Add adjacent triangle sharing the a-b edge.
		-- Use hintPoint derived from the parent normal (edge midpoint + normal offset).
		-- This is what Add mode should do instead of passing the click position.
		local d = Vector3.new(1502, 10, -3)
		local edgeMid = (a + b) / 2
		local hintPoint = edgeMid + parentTri.normal * 0.5
		local childId = mesh.addTriangle(a, b, d, 0.2, folder, nil, hintPoint)
		assert(childId)
		local childTri = mesh.getTriangle(childId)
		assert(childTri)
		-- Child should face the same direction as parent (upward)
		t.expect(childTri.normal.Y > 0.9).toBeTruthy()

		-- Even a bad hintPoint (e.g. Vector3.zero from a missed raycast) no longer
		-- flips the new triangle: when it shares an edge with an existing triangle,
		-- addTriangle orients to wind consistently with that neighbour and ignores
		-- the hint entirely (the hint is only the fallback for an isolated triangle
		-- with no neighbour to match). This is what keeps Add robust on tilted and
		-- curved edges, where a normal-vs-hint dot test picked the wrong winding.
		mesh.removeTriangle(childId)
		local badChildId = mesh.addTriangle(a, b, d, 0.2, folder, nil, Vector3.zero)
		assert(badChildId)
		local badChildTri = mesh.getTriangle(badChildId)
		assert(badChildTri)
		t.expect(badChildTri.normal.Y > 0.9).toBeTruthy() -- still faces up: matches the parent

		folder:Destroy()
	end)

	t.test("mergeVertices stitches a torn seam into one shared edge", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Two triangles that should meet along z = 0 but are "torn": the second one's
		-- near corners sit 0.2 studs away (well past the 0.02 merge tolerance), so the
		-- mesh holds six separate vertices and no shared edge.
		mesh.addTriangle(
			Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(2, 0, 3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)
		mesh.addTriangle(
			Vector3.new(0, 0, -0.2), Vector3.new(4, 0, -0.2), Vector3.new(2, 0, -3),
			0.2, folder, nil, Vector3.new(0, 1, 0)
		)

		local function countDict(d: any): number
			local n = 0
			for _ in d do
				n += 1
			end
			return n
		end
		local function boundaryCount(): number
			local n = 0
			for _, edge in mesh.getEdges() do
				if #edge.triangles == 1 then
					n += 1
				end
			end
			return n
		end
		local function vidNear(pos: Vector3): number
			local best: number? = nil
			local bestD = 0.05
			for id, v in mesh.getVertices() do
				local d = (v.position - pos).Magnitude
				if d < bestD then
					bestD = d
					best = id
				end
			end
			assert(best, "no vertex near " .. tostring(pos))
			return best
		end

		-- Torn: 6 vertices, 2 triangles, every edge a boundary (nothing shared).
		t.expect(countDict(mesh.getVertices())).toBe(6)
		t.expect(countDict(mesh.getTriangles())).toBe(2)
		t.expect(countDict(mesh.getEdges())).toBe(6)
		t.expect(boundaryCount()).toBe(6)

		local a1 = vidNear(Vector3.new(0, 0, 0))
		local a2 = vidNear(Vector3.new(0, 0, -0.2))
		local b1 = vidNear(Vector3.new(4, 0, 0))
		local b2 = vidNear(Vector3.new(4, 0, -0.2))
		local c1 = vidNear(Vector3.new(2, 0, 3))

		-- Refuses to collapse two corners of the same triangle (would be degenerate).
		t.expect(mesh.mergeVertices(a1, c1, Vector3.new(0, 0, 0), nil)).toBe(false)
		t.expect(countDict(mesh.getVertices())).toBe(6) -- unchanged

		-- Heal both ends of the seam.
		t.expect(mesh.mergeVertices(a1, a2, Vector3.new(0, 0, -0.1), nil)).toBe(true)
		t.expect(mesh.mergeVertices(b1, b2, Vector3.new(4, 0, -0.1), nil)).toBe(true)

		-- Stitched: 4 vertices, still 2 triangles, 5 edges with exactly one shared
		-- (interior) edge -- so only 4 boundary edges remain.
		t.expect(countDict(mesh.getVertices())).toBe(4)
		t.expect(countDict(mesh.getTriangles())).toBe(2)
		t.expect(countDict(mesh.getEdges())).toBe(5)
		t.expect(boundaryCount()).toBe(4)

		local shared = 0
		for _, edge in mesh.getEdges() do
			if #edge.triangles == 2 then
				shared += 1
			end
		end
		t.expect(shared).toBe(1)

		folder:Destroy()
	end)

	t.test("mergeWedgeTriangles folds a bent wedge pair back into one triangle", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Two triangles sharing edge B-F, where the shared foot F sits 0.3 studs off the
		-- straight line A-C between the outer corners -- a wedge nudged just enough that
		-- discovery left them as two triangles instead of one.
		local A = Vector3.new(0, 0, 0)
		local B = Vector3.new(3, 0, 4)
		local C = Vector3.new(6, 0, 0)
		local F = Vector3.new(3, 0, 0.3)
		local hint = Vector3.new(3, 5, 0)
		local t1 = mesh.addTriangle(A, B, F, 0.2, folder, nil, hint)
		local t2 = mesh.addTriangle(B, C, F, 0.2, folder, nil, hint)
		assert(t1 and t2)

		local function countDict(d: any): number
			local n = 0
			for _ in d do
				n += 1
			end
			return n
		end
		local function vidNear(pos: Vector3): number?
			for id, v in mesh.getVertices() do
				if (v.position - pos).Magnitude < 0.05 then
					return id
				end
			end
			return nil
		end

		-- Bent pair: 4 vertices, 2 triangles, 5 edges, F shared by both.
		t.expect(countDict(mesh.getVertices())).toBe(4)
		t.expect(countDict(mesh.getTriangles())).toBe(2)
		t.expect(countDict(mesh.getEdges())).toBe(5)
		local footId = vidNear(F)
		assert(footId)
		t.expect(#mesh.getVertex(footId).triangles).toBe(2)

		-- Fold them: snap F onto A-C and merge into one triangle (A, B, C), dropping F.
		t.expect(mesh.mergeWedgeTriangles(t1, t2, 0.5, nil)).toBe(true)

		t.expect(countDict(mesh.getVertices())).toBe(3)
		t.expect(countDict(mesh.getTriangles())).toBe(1)
		t.expect(countDict(mesh.getEdges())).toBe(3)
		t.expect(vidNear(F)).toBe(nil) -- foot dropped
		t.expect(vidNear(Vector3.new(3, 0, 0))).toBe(nil) -- not left at the snapped spot either

		folder:Destroy()
	end)

	t.test("VertexChanged fires per vertex when vertices are added, moved, or removed", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local fired: { number } = {}
		local conn = mesh.VertexChanged:Connect(function(id: number)
			table.insert(fired, id)
		end)

		local tri = mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(2, 0, 3), 0.2, folder, nil, Vector3.new(2, 5, 0))
		assert(tri)
		t.expect(#fired >= 3).toBeTruthy() -- one fire per new vertex

		table.clear(fired)
		local vid: number? = nil
		for id in mesh.getVertices() do
			vid = id
			break
		end
		assert(vid)
		local v = mesh.getVertex(vid)
		assert(v)
		mesh.moveVertex(vid, v.position + Vector3.new(0, 1, 0), 0.2, nil)
		t.expect(table.find(fired, vid) ~= nil).toBeTruthy() -- the moved vertex fired

		table.clear(fired)
		mesh.removeTriangle(tri)
		t.expect(#fired >= 3).toBeTruthy() -- one fire per removed vertex

		conn:Disconnect()
		folder:Destroy()
	end)

	t.test("moveVertex re-keys the edge lookup so a moved edge can still be shared", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- One triangle, then move its (0,0,4) corner up to (0,3,4).
		local t1 = mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
		assert(t1)
		local cId: number? = nil
		for id, v in mesh.getVertices() do
			if (v.position - Vector3.new(0, 0, 4)).Magnitude < 0.01 then
				cId = id
				break
			end
		end
		assert(cId)
		mesh.moveVertex(cId, Vector3.new(0, 3, 4), 0.2, nil)

		-- Attach a second triangle along the MOVED edge (4,0,0)-(0,3,4). It must reuse that
		-- edge -- which only works if moveVertex re-keyed the lookup to the new position --
		-- rather than minting a parallel one, so the shared edge carries both triangles.
		local t2 = mesh.addTriangle(Vector3.new(4, 0, 0), Vector3.new(0, 3, 4), Vector3.new(4, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
		assert(t2)

		local sharedTris = 0
		for _, edge in mesh.getEdges() do
			local pa = mesh.getVertex(edge.v1)
			local pb = mesh.getVertex(edge.v2)
			if pa and pb then
				local hit = ((pa.position - Vector3.new(4, 0, 0)).Magnitude < 0.01 and (pb.position - Vector3.new(0, 3, 4)).Magnitude < 0.01)
					or ((pb.position - Vector3.new(4, 0, 0)).Magnitude < 0.01 and (pa.position - Vector3.new(0, 3, 4)).Magnitude < 0.01)
				if hit then
					sharedTris = #edge.triangles
				end
			end
		end
		t.expect(sharedTris).toBe(2)

		folder:Destroy()
	end)

	t.test("moveVertex cost is independent of unrelated geometry", function()
		-- Build a single connected triangle, optionally surrounded by many UNRELATED
		-- triangles far away. The connected triangle rebuilt on each move is identical
		-- either way, so timing the SAME number of moves on each and taking the DIFFERENCE
		-- cancels the (identical) geometry-rebuild cost and leaves only the edge bookkeeping.
		-- With moveVertex O(degree) the unrelated triangles add nothing; the old
		-- O(all-edges) scan made each move scale with their count.
		local function build(unrelated: number): (createTriangleMesh.TriangleMesh, number, Folder)
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			local mesh = createTriangleMesh()
			mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
			for i = 1, unrelated do
				local x = 1000 + i * 8
				mesh.addTriangle(Vector3.new(x, 0, 0), Vector3.new(x + 4, 0, 0), Vector3.new(x, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
			end
			local vid: number? = nil
			for id, v in mesh.getVertices() do
				if (v.position - Vector3.new(0, 0, 0)).Magnitude < 0.01 then
					vid = id
					break
				end
			end
			assert(vid)
			return mesh, vid, folder
		end

		local function timeMoves(mesh: createTriangleMesh.TriangleMesh, vid: number, iters: number): number
			local base = (mesh.getVertex(vid) :: any).position
			local t0 = os.clock()
			for i = 1, iters do
				mesh.moveVertex(vid, base + Vector3.new(0, (i % 4) * 0.01, 0), 0.2, nil)
			end
			return os.clock() - t0
		end

		local ITERS = 2000
		local bare, bareVid, bareFolder = build(0)
		local crowded, crowdedVid, crowdedFolder = build(1500) -- ~4500 unrelated edges
		timeMoves(bare, bareVid, 100) -- warm
		timeMoves(crowded, crowdedVid, 100)
		local tBare = timeMoves(bare, bareVid, ITERS)
		local tCrowded = timeMoves(crowded, crowdedVid, ITERS)
		bareFolder:Destroy()
		crowdedFolder:Destroy()

		-- The geometry cost cancels, so this difference is purely the edge work. O(degree)
		-- keeps it near zero; the old scan would have added tens of ms per thousand moves
		-- here. Generous bound so timing noise never makes it flaky.
		t.expect((tCrowded - tBare) < 0.05).toBeTruthy()
	end)

	t.test("getSetBoundaryEdges returns the boundary of a triangle subset", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		-- Two triangles sharing an edge make a square; the shared edge is interior.
		local t1 = mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
		local t2 = mesh.addTriangle(Vector3.new(4, 0, 0), Vector3.new(4, 0, 4), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
		assert(t1 and t2)

		-- Boundary of BOTH = the 4 outer edges of the square (shared edge excluded).
		t.expect(#mesh.getSetBoundaryEdges({ t1, t2 })).toBe(4)
		-- Boundary of just ONE = all 3 of its edges (the shared one counts, since the other
		-- triangle is outside the set).
		t.expect(#mesh.getSetBoundaryEdges({ t1 })).toBe(3)
		-- Empty set has no boundary.
		t.expect(#mesh.getSetBoundaryEdges({})).toBe(0)

		folder:Destroy()
	end)

	t.test("getSetBoundaryEdges cost is independent of unrelated geometry", function()
		-- The overlay recomputes a selection's outline every drag frame. Build the same tiny
		-- two-triangle selection, optionally surrounded by unrelated triangles, and time the
		-- boundary query on each; the difference must stay near zero. The old version scanned
		-- every edge in the mesh, so it scaled with the unrelated geometry.
		local function build(unrelated: number): (createTriangleMesh.TriangleMesh, { number }, Folder)
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			local mesh = createTriangleMesh()
			local a = mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
			local b = mesh.addTriangle(Vector3.new(4, 0, 0), Vector3.new(4, 0, 4), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
			assert(a and b)
			for i = 1, unrelated do
				local x = 1000 + i * 8
				mesh.addTriangle(Vector3.new(x, 0, 0), Vector3.new(x + 4, 0, 0), Vector3.new(x, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
			end
			return mesh, { a, b }, folder
		end

		local function timeBoundary(mesh: createTriangleMesh.TriangleMesh, ids: { number }, iters: number): number
			local t0 = os.clock()
			for _ = 1, iters do
				mesh.getSetBoundaryEdges(ids)
			end
			return os.clock() - t0
		end

		local ITERS = 3000
		local bare, bareIds, bareFolder = build(0)
		local crowded, crowdedIds, crowdedFolder = build(1500)
		timeBoundary(bare, bareIds, 100) -- warm
		timeBoundary(crowded, crowdedIds, 100)
		local tBare = timeBoundary(bare, bareIds, ITERS)
		local tCrowded = timeBoundary(crowded, crowdedIds, ITERS)
		bareFolder:Destroy()
		crowdedFolder:Destroy()

		t.expect((tCrowded - tBare) < 0.05).toBeTruthy()
	end)

	t.test("re-adding a vertex survives a stale re-pointed spatial-hash cell", function()
		-- Repro for an undo (local re-discovery) crash: a corner ~0.008 from an existing
		-- vertex dedups into it but hashes to a neighbouring cell, which gets re-pointed at
		-- the shared vertex. Removing the vertex clears only its OWN cell, so the re-pointed
		-- cell is left pointing at a removed vertex. A full rediscover wipes the whole hash;
		-- a local one doesn't, so getOrCreateVertex must not hand back the stale id.
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local t1 = mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
		-- (0.008, 0, 0) is within the 0.02 merge tolerance of the origin but floor()s into
		-- the next 0.01 hash cell, so it re-points that cell at the origin vertex.
		local t2 = mesh.addTriangle(Vector3.new(0.008, 0, 0), Vector3.new(0, 0, 4), Vector3.new(-4, 0, 0), 0.2, folder, nil, Vector3.new(0, 1, 0))
		assert(t1 and t2)

		mesh.removeTriangle(t1)
		mesh.removeTriangle(t2)

		-- Without the stale-entry guard this throws "attempt to index nil with 'triangles'".
		local t3 = mesh.addTriangle(Vector3.new(0.008, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), 0.2, folder, nil, Vector3.new(0, 1, 0))
		t.expect(t3).toBeTruthy()

		folder:Destroy()
	end)
end
