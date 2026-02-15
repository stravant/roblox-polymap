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
			Vector3.new(2, 3, 0),
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
			Vector3.new(2, 3, 0),
			0.2, folder
		)
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, -3, 0),
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
			Vector3.new(2, 3, 0),
			0.2, folder
		)

		-- A single triangle should have 3 boundary edges
		local boundary = mesh.getBoundaryEdges()
		t.expect(#boundary).toBe(3)

		-- Add adjacent triangle
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, -3, 0),
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
			Vector3.new(2, 3, 0),
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
			Vector3.new(2, 3, 0),
			0.2, folder
		)
		mesh.addTriangle(
			Vector3.new(0, 0, 0),
			Vector3.new(4, 0, 0),
			Vector3.new(2, -3, 0),
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
			Vector3.new(2, 3, 0),
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
			Vector3.new(2, 3, 0),
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
		local c = Vector3.new(12, 13, 0)
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
			Vector3.new(2, 3, 0),
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
			Vector3.new(2, 3, 0),
			0.2, folder
		)

		local vid = mesh.findVertexNear(Vector3.new(2, 3, 0), 0.1)
		t.expect(vid).toBeTruthy()
		assert(vid)

		mesh.moveVertex(vid, Vector3.new(2, 5, 0), 0.2)

		local vertex = mesh.getVertex(vid)
		t.expect(vertex).toBeTruthy()
		assert(vertex)
		t.expect((vertex.position - Vector3.new(2, 5, 0)).Magnitude < 0.02).toBeTruthy()

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
			Vector3.new(2, 3, 0),
			0.2, folder
		)
		assert(triId)

		-- Save references to parts before moving
		local triBefore = mesh.getTriangle(triId)
		assert(triBefore)
		local partsBefore = table.clone(triBefore.parts)

		local vid = mesh.findVertexNear(Vector3.new(2, 3, 0), 0.1)
		assert(vid)

		mesh.moveVertex(vid, Vector3.new(2, 5, 0), 0.2)

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
		local c = Vector3.new(22, 13, 0)
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
			Vector3.new(32, 13, 0),
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

		-- Create two separate triangles near each other
		fillTriangle(
			Vector3.new(40, 10, 0),
			Vector3.new(44, 10, 0),
			Vector3.new(42, 13, 0),
			0.2, folder
		)
		fillTriangle(
			Vector3.new(40, 10, 0),
			Vector3.new(44, 10, 0),
			Vector3.new(42, 7, 0),
			0.2, folder
		)

		-- Discover the region covering both
		mesh.discoverRegion(Vector3.new(42, 10, 0), 20)

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
			Vector3.new(52, 13, 0),
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
end
