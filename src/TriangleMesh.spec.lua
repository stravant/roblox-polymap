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
			0.2, folder
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
			0.2, folder
		)
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, -3),
			0.2, folder
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
			0.2, folder
		)

		-- A single triangle should have 3 boundary edges
		local boundary = mesh.getBoundaryEdges()
		t.expect(#boundary).toBe(3)

		-- Add adjacent triangle
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, -3),
			0.2, folder
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
			0.2, folder
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
			0.2, folder
		)
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, 0, -3),
			0.2, folder
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
			0.2, folder
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
			0.2, folder
		)

		local vid = mesh.findVertexNear(Vector3.new(0.01, 0, 0), 1)
		t.expect(vid).toBeTruthy()

		local noVid = mesh.findVertexNear(Vector3.new(100, 100, 100), 1)
		t.expect(noVid == nil).toBeTruthy()

		folder:Destroy()
	end)

	t.test("scanWorkspace finds thin wedge parts", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Name = "PolyMapTestScan"
		folder.Parent = workspace

		-- Create a triangle manually
		local a = Vector3.new(10, 10, 0)
		local b = Vector3.new(14, 10, 0)
		local c = Vector3.new(12, 10, 3)
		fillTriangle(a, b, c, 0.2, folder)

		mesh.scanWorkspace(folder)

		-- Should find 1 triangle
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(1)

		-- Should have 3 vertices
		local vertCount = 0
		for _ in mesh.getVertices() do
			vertCount += 1
		end
		t.expect(vertCount).toBe(3)

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
			0.2, folder
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
			0.2, folder
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
			0.2, folder
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
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a triangle via fillTriangle (produces 1-2 wedge parts)
		local a = Vector3.new(20, 10, 0)
		local b = Vector3.new(24, 10, 0)
		local c = Vector3.new(22, 10, 3)
		local parts = fillTriangle(a, b, c, 0.2, folder)
		t.expect(#parts > 0).toBeTruthy()

		-- Discover one of the parts
		local triId = mesh.discoverPart(parts[1])
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
			t.expect(mesh.getPartTriangle(part)).toBeTruthy()
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

		local triId1 = mesh.discoverPart(parts[1])
		local triId2 = mesh.discoverPart(parts[1])
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

		-- Discover the region covering both
		mesh.discoverRegion(Vector3.new(202, 10, 0), 20)

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

		local parts = fillTriangle(
			Vector3.new(50, 10, 0),
			Vector3.new(54, 10, 0),
			Vector3.new(52, 10, 3),
			0.2, folder
		)

		local triId = mesh.discoverPart(parts[1])
		t.expect(triId).toBeTruthy()

		-- Each part should map to the same triangle
		for _, part in parts do
			t.expect(mesh.getPartTriangle(part)).toBe(triId)
		end

		-- A random new part should not be tracked
		local randomPart = Instance.new("Part")
		randomPart.Parent = folder
		t.expect(mesh.getPartTriangle(randomPart) == nil).toBeTruthy()

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

		local triId = mesh.discoverPart(block)
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
		t.expect(mesh.getPartTriangle(block)).toBeTruthy()

		folder:Destroy()
	end)

	t.test("scanWorkspace finds thin Block parts", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Name = "PolyMapTestBlockScan"
		folder.Parent = workspace

		-- Create a thin block
		local block = Instance.new("Part")
		block.Shape = Enum.PartType.Block
		block.Size = Vector3.new(4, 0.2, 3)
		block.CFrame = CFrame.new(310, 10, 0)
		block.Anchored = true
		block.Parent = folder

		mesh.scanWorkspace(folder)

		-- Should find 2 triangles from the Block
		local triCount = 0
		for _ in mesh.getTriangles() do
			triCount += 1
		end
		t.expect(triCount).toBe(2)

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

		mesh.discoverPart(block)

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

		local triId = mesh.discoverPart(block)
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
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Use far-away positions to avoid picking up other test geometry
		local triId = mesh.addTriangle(
			Vector3.new(400, 0, 0),
			Vector3.new(404, 0, 0),
			Vector3.new(402, 0, 3),
			0.2, folder
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
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create two adjacent triangles far from other test geometry
		local tri1 = mesh.addTriangle(
			Vector3.new(420, 0, 0),
			Vector3.new(424, 0, 0),
			Vector3.new(422, 0, 3),
			0.2, folder
		)
		local tri2 = mesh.addTriangle(
			Vector3.new(420, 0, 0),
			Vector3.new(424, 0, 0),
			Vector3.new(422, 0, -3),
			0.2, folder
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
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create two disconnected triangles at nearby positions (no shared vertices)
		local tri1 = mesh.addTriangle(
			Vector3.new(440, 0, 0),
			Vector3.new(444, 0, 0),
			Vector3.new(442, 0, 3),
			0.2, folder
		)
		-- This triangle is 10 units above, nearby but shares no vertices/edges
		local tri2 = mesh.addTriangle(
			Vector3.new(440, 10, 0),
			Vector3.new(444, 10, 0),
			Vector3.new(442, 10, 3),
			0.2, folder
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
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local triId = mesh.addTriangle(
			Vector3.new(460, 0, 0),
			Vector3.new(464, 0, 0),
			Vector3.new(462, 0, 3),
			0.2, folder
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

		-- Create an underhanging triangle (normal pointing down) via fillTriangle directly
		local a = Vector3.new(480, 10, 0)
		local b = Vector3.new(482, 10, 3)
		local c = Vector3.new(484, 10, 0)
		local parts = fillTriangle(a, b, c, 0.2, folder)
		t.expect(#parts > 0).toBeTruthy()

		-- Discover the parts
		local triId = mesh.discoverPart(parts[1])
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

		-- Create a vertical wall triangle (normal pointing in Z direction)
		local a = Vector3.new(600, 0, 600)
		local b = Vector3.new(604, 0, 600)
		local c = Vector3.new(602, 3, 600)
		local parts = fillTriangle(a, b, c, 0.2, folder)
		t.expect(#parts > 0).toBeTruthy()

		local triId = mesh.discoverPart(parts[1])
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

		-- Create two adjacent underhanging triangles via fillTriangle
		-- (sharing edge a-c, with normals pointing down)
		local a = Vector3.new(1000, 10, 1000)
		local b = Vector3.new(1002, 10, 1003)
		local c = Vector3.new(1004, 10, 1000)
		local d = Vector3.new(1002, 10, 997)
		fillTriangle(a, b, c, 0.2, folder)
		fillTriangle(a, c, d, 0.2, folder)

		-- Discover all parts in the region
		mesh.discoverRegion(Vector3.new(1002, 10, 1000), 20)

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

		-- Discover the first triangle with a hitNormal to anchor the correct
		-- face (the Z=1100 surface). This mirrors actual usage where the user
		-- clicks on a part. The second triangle is then discovered via
		-- discoverRegion and snaps to the first triangle's shared vertices.
		-- Triangle 1's normal is +Z, so parts extend to Z=1100.2. The
		-- surface face at Z=1100 has outward normal (0,0,-1).
		mesh.discoverPart(parts1[1], Vector3.new(0, 0, -1))
		mesh.discoverRegion(Vector3.new(1102, 0, 1100), 20)

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

	t.test("getPartTriangle with hitNormal selects correct face", function()
		local mesh = createTriangleMesh()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		-- Create a horizontal triangle at Y=5
		local a = Vector3.new(1200, 5, 0)
		local b = Vector3.new(1204, 5, 0)
		local c = Vector3.new(1202, 5, 3)
		local triId = mesh.addTriangle(a, b, c, 0.2, folder)
		assert(triId)

		-- Get the parts of this triangle
		local tri = mesh.getTriangle(triId)
		assert(tri)
		local part = tri.parts[1]

		-- Without hitNormal, should return the front face (same as triId)
		local frontId = mesh.getPartTriangle(part)
		t.expect(frontId).toBe(triId)

		-- Opposite hit normals should return different triangle IDs
		local upId = mesh.getPartTriangle(part, Vector3.new(0, 1, 0))
		local downId = mesh.getPartTriangle(part, Vector3.new(0, -1, 0))
		t.expect(upId).toBeTruthy()
		t.expect(downId).toBeTruthy()
		assert(upId)
		assert(downId)
		t.expect(upId ~= downId).toBeTruthy()

		-- Both should be valid triangles
		local upTri = mesh.getTriangle(upId)
		local downTri = mesh.getTriangle(downId)
		t.expect(upTri).toBeTruthy()
		t.expect(downTri).toBeTruthy()
		assert(upTri)
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

		-- One face should have vertices at Y≈5.0, the other at Y≈4.8
		-- (thickness 0.2 extends downward from Y=5)
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
		local frontTriId = mesh.addTriangle(a, b, c, 0.2, folder)
		assert(frontTriId)

		local frontTri = mesh.getTriangle(frontTriId)
		assert(frontTri)
		local part = frontTri.parts[1]

		-- Select the bottom (back) face via downward hitNormal
		local backTriId = mesh.getPartTriangle(part, Vector3.new(0, -1, 0))
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
		local wv1, wv2, wv3 = getWedgeVertices(movedPart, Vector3.new(0, -1, 0))

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
end
