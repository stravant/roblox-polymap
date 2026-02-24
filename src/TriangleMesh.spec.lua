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

	t.test("getPartTriangle with hintPoint selects correct face", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a horizontal triangle at Y=5 (front = up-facing)
		local a = Vector3.new(1200, 5, 0)
		local b = Vector3.new(1204, 5, 0)
		local c = Vector3.new(1202, 5, 3)
		-- hintPoint above centroid at Y=5
		local upId = mesh.addTriangle(a, b, c, 0.2, folder, nil, Vector3.new(1202, 6, 1))
		assert(upId)

		-- Get the parts of this triangle
		local upTri = mesh.getTriangle(upId)
		assert(upTri)
		local part = upTri.parts[1]

		-- Front face found with hintPoint above part center
		local hintAbove = Vector3.new(1202, 6, 1)
		t.expect(mesh.getPartTriangle(part, hintAbove)).toBe(upId)

		-- Back face not yet discovered (hintPoint below)
		local hintBelow = Vector3.new(1202, 4, 1)
		t.expect(mesh.getPartTriangle(part, hintBelow) == nil).toBeTruthy()

		-- Discover the back face from the same parts
		local downId = mesh.discoverPart(part, hintBelow)
		t.expect(downId).toBeTruthy()
		assert(downId)
		t.expect(upId ~= downId).toBeTruthy()

		-- Both should be valid triangles
		local downTri = mesh.getTriangle(downId)
		t.expect(downTri).toBeTruthy()
		assert(downTri)

		-- Collect Y values for each face's vertices
		local upYs: { number } = {}
		local downYs: { number } = {}
		for _, vid in upTri.vertices do
			local v = mesh.getVertex(vid)
			assert(v)
			table.insert(upYs, v.position.Y)
		end
		for _, vid in downTri.vertices do
			local v = mesh.getVertex(vid)
			assert(v)
			table.insert(downYs, v.position.Y)
		end

		-- One face should have vertices at Y≈5.0, the other at Y≈5.2
		-- (thickness extends upward from the surface at Y=5)
		local upAvgY = (upYs[1] + upYs[2] + upYs[3]) / 3
		local downAvgY = (downYs[1] + downYs[2] + downYs[3]) / 3
		t.expect(math.abs(upAvgY - downAvgY) > 0.1).toBeTruthy()

		folder:Destroy()
	end)

	t.test("moveVertex on back-face triangle preserves face direction", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a horizontal triangle at Y=5. fillTriangle makes thickness
		-- extend downward, so surface is at Y=5, bottom at Y≈4.8.
		local a = Vector3.new(1300, 5, 0)
		local b = Vector3.new(1304, 5, 0)
		local c = Vector3.new(1302, 5, 3)
		-- hintPoint above centroid at Y=5
		local frontTriId = mesh.addTriangle(a, b, c, 0.2, folder, nil, Vector3.new(1302, 6, 1))
		assert(frontTriId)

		local frontTri = mesh.getTriangle(frontTriId)
		assert(frontTri)
		local part = frontTri.parts[1]

		-- Discover the bottom (back) face via hintPoint below
		local backTriId = mesh.discoverPart(part, Vector3.new(1302, 4, 1))
		assert(backTriId)
		t.expect(backTriId ~= frontTriId).toBeTruthy()

		-- Identify which vertex of the back-face triangle corresponds to 'c'
		local backTri = mesh.getTriangle(backTriId)
		assert(backTri)
		local moveVid: number? = nil
		for _, vid in backTri.vertices do
			local v = mesh.getVertex(vid)
			assert(v)
			-- c is at (1302, 5, 3), back face should be at Y≈4.8
			if math.abs(v.position.X - 1302) < 0.1 and math.abs(v.position.Z - 3) < 0.1 then
				moveVid = vid
				break
			end
		end
		assert(moveVid, "Should find back-face vertex near c")

		-- Move the vertex slightly in Y
		local oldV = mesh.getVertex(moveVid :: number)
		assert(oldV)
		local oldPosition = oldV.position
		mesh.moveVertex(moveVid :: number, oldPosition + Vector3.new(0, -0.5, 0), 0.2)

		-- After the move, the back-face triangle should still exist and have
		-- its vertices on the BOTTOM side (Y < 5). The bug is that moveVertex
		-- calls fillTriangle which flips winding to face up, putting the
		-- surface face at ~Y=4.3 with thickness extending further down to
		-- ~Y=4.1, when it should keep thickness extending UP.
		local movedBackTri = mesh.getTriangle(backTriId)
		assert(movedBackTri, "Back-face triangle should still exist after move")

		-- Check that the moved vertex actually moved
		local movedV = mesh.getVertex(moveVid :: number)
		assert(movedV)
		t.expect(math.abs(movedV.position.Y - (oldPosition.Y - 0.5)) < 0.05).toBeTruthy()

		-- The key check: the back-face triangle's parts should still have their
		-- surface on the bottom side. Verify by checking that getWedgeVertices
		-- with downward hitNormal returns vertices matching the back-face
		-- triangle's registered vertices (not the top-face vertices).
		local getWedgeVertices = require("./getWedgeVertices")
		local movedPart = movedBackTri.parts[1]
		-- Use a point below the part to select the bottom face
		local wv1, wv2, wv3 = getWedgeVertices(movedPart, movedPart.CFrame.Position - Vector3.new(0, 1, 0))

		-- These wedge vertices (from the downward-facing side) should include
		-- vertices with Y values matching the back-face triangle, NOT the
		-- front-face triangle
		local wedgeAvgY = (wv1.Y + wv2.Y + wv3.Y) / 3
		local backAvgY = 0
		for _, vid in movedBackTri.vertices do
			local v = mesh.getVertex(vid)
			assert(v)
			backAvgY += v.position.Y
		end
		backAvgY /= 3

		-- The wedge's downward face should match the back triangle's vertices
		t.expect(math.abs(wedgeAvgY - backAvgY) < 0.15).toBeTruthy()

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

		-- Verify the BAD hintPoint (Vector3.zero) would produce wrong normal.
		-- This is the bug: Add mode passed worldPos=Vector3.zero when the
		-- raycast missed, flipping the triangle to face downward.
		mesh.removeTriangle(childId)
		local badChildId = mesh.addTriangle(a, b, d, 0.2, folder, nil, Vector3.zero)
		assert(badChildId)
		local badChildTri = mesh.getTriangle(badChildId)
		assert(badChildTri)
		t.expect(badChildTri.normal.Y < -0.9).toBeTruthy() -- wrong: faces down

		folder:Destroy()
	end)
end
