--!strict

-- Integration tests that drive a real createPolyMapSession through multi-step
-- editing workflows with undo/redo interspersed, asserting that the in-memory
-- mesh and the selection stay consistent with the workspace parts at every step.
-- These exercise the full undo machinery (pushUndoSnapshot / recordings /
-- handleUndo / rediscoverMesh) that the mouse-driven editing relies on.

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local TestTypes = require("./TestTypes")
local createPolyMapSession = require("./createPolyMapSession")
local createTriangleMesh = require("./TriangleMesh")
local fillTriangle = require("./fillTriangle")
local Settings = require("./Settings")

-- Grids spawn relative to the camera; pin it so geometry lands in a known,
-- otherwise-empty region far from the other specs' fixtures.
local kCameraEye = Vector3.new(5000, 30, 60)
local kCameraTarget = Vector3.new(5000, 0, 40)
local kRegionCenter = Vector3.new(5000, 0, 40)

local function makeSettings(): Settings.PolyMapSettings
	return {
		WindowPosition = Vector2.new(24, 24),
		WindowAnchor = Vector2.zero,
		WindowHeightDelta = 0,
		HaveHelp = true,
		DoneTutorial = true,

		Mode = "Move",
		DeleteTarget = "Face",
		DeleteRadius = 0,
		PaintRadius = 0,
		Thickness = 0.2,
		InfluenceRadius = 0,
		InfluenceFalloff = "Smooth",
		GridType = "Square",
		-- Small grid (<=4 cells) so the post-generate discovery covers it fully
		-- and triangle counts are stable.
		GridWidth = 3,
		GridHeight = 3,
		GridSpacing = 4,
		PaintColor = { 0.5, 0.5, 0.5 },
		PaintMaterial = "Plastic",
		PaintStrength = 1.0,
		PaintTarget = "Both",
		PaintEyedropper = "None",
		RelaxRadius = 5,
		RelaxStrength = 0.5,
		FlattenRadius = 5,
		FlattenStrength = 0.5,
		ImportImageId = "",
		ImportWidth = 50,
		ImportHeight = 50,
		ImportSpacing = 4,
		ImportHeightScale = 50,
		RecentMaterials = { "Plastic", "Grass" },
		RecentColors = { { 0.5, 0.5, 0.5 } },
	}
end

local function countDict(dict: { [any]: any }): number
	local n = 0
	for _ in dict do
		n += 1
	end
	return n
end

local function colorsClose(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) < 0.02 and math.abs(a.G - b.G) < 0.02 and math.abs(a.B - b.B) < 0.02
end

-- Two positions that are guaranteed not to share an edge (the farthest-apart
-- pair in the set), used to make a Simplify a no-op.
local function pickTwoFarApart(positions: { Vector3 }): (Vector3, Vector3)
	local bestA, bestB = positions[1], positions[2]
	local bestD = -1
	for i = 1, #positions do
		for j = i + 1, #positions do
			local d = (positions[i] - positions[j]).Magnitude
			if d > bestD then
				bestD = d
				bestA = positions[i]
				bestB = positions[j]
			end
		end
	end
	return bestA, bestB
end

return function(t: TestTypes.TestContext)
	-- Let deferred ChangeHistoryService.OnUndo/OnRedo handlers run before asserting.
	local function settle()
		task.wait()
		task.wait()
	end

	-- Run fn against a fresh session with the camera pinned and the work region
	-- cleaned before and after, so tests are isolated even though parts land
	-- under workspace.Terrain and ChangeHistory is global.
	local function withSession(fn: (any, any, Settings.PolyMapSettings) -> ())
		local cam = workspace.CurrentCamera
		local savedCF = if cam then cam.CFrame else nil
		if cam then
			cam.CFrame = CFrame.lookAt(kCameraEye, kCameraTarget)
		end
		local function sweepRegion()
			for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 150) do
				if p:IsA("BasePart") then
					p:Destroy()
				end
			end
		end
		sweepRegion()
		ChangeHistoryService:ResetWaypoints()

		local settings = makeSettings()
		local session = createPolyMapSession(t.plugin, settings)
		local ok, err = pcall(fn, session, session.GetMesh(), settings)

		session.Destroy()
		ChangeHistoryService:ResetWaypoints()
		sweepRegion()
		if cam and savedCF then
			cam.CFrame = savedCF
		end
		if not ok then
			error(err)
		end
	end

	t.test("workflow: generate grid, move a vertex, undo restores geometry and selection", function()
		withSession(function(session, mesh)
			session.GenerateGrid()
			t.expect(countDict(mesh.getTriangles()) > 0).toBeTruthy()
			local vertsAfterGen = countDict(mesh.getVertices())

			-- Pick a vertex to adjust
			local pickPos: Vector3? = nil
			local pickVid: number? = nil
			for vid, v in mesh.getVertices() do
				pickVid = vid
				pickPos = v.position
				break
			end
			assert(pickVid and pickPos)

			-- Select it and move it up
			session.SelectVerticesNear({ pickPos })
			session.MoveSelectedVertices(Vector3.new(0, 7, 0))
			t.expect(mesh.findVertexNear(pickPos + Vector3.new(0, 7, 0), 0.4)).toBeTruthy()
			t.expect(mesh.findVertexNear(pickPos, 0.4) == nil).toBeTruthy()

			-- Undo the move
			ChangeHistoryService:Undo()
			settle()

			-- Geometry reverted and mesh size unchanged by the round-trip
			local restoredVid = mesh.findVertexNear(pickPos, 0.4)
			t.expect(restoredVid).toBeTruthy()
			t.expect(mesh.findVertexNear(pickPos + Vector3.new(0, 7, 0), 0.4) == nil).toBeTruthy()
			t.expect(countDict(mesh.getVertices())).toBe(vertsAfterGen)

			-- Selection survived the rescan (restored by world position)
			local sel = session.GetSelectedVertices()
			t.expect(countDict(sel)).toBe(1)
			t.expect(sel[restoredVid]).toBeTruthy()
		end)
	end)

	t.test("workflow: generate, add a triangle, then paint, with undo and redo interspersed", function()
		withSession(function(session, mesh, settings)
			-- 1) Add terrain
			session.GenerateGrid()
			local gridTris = countDict(mesh.getTriangles())
			t.expect(gridTris > 0).toBeTruthy()

			-- Capture a grid triangle to colour later (survives the add below)
			local paintPos: Vector3? = nil
			local paintPart: BasePart? = nil
			for _, tri in mesh.getTriangles() do
				local p1 = mesh.getVertex(tri.vertices[1])
				local p2 = mesh.getVertex(tri.vertices[2])
				local p3 = mesh.getVertex(tri.vertices[3])
				if p1 and p2 and p3 and tri.parts[1] then
					paintPos = (p1.position + p2.position + p3.position) / 3
					paintPart = tri.parts[1]
					break
				end
			end
			assert(paintPos and paintPart)
			local origColor = paintPart.Color

			-- 2) Add a triangle off a boundary edge, pointing away from the grid
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local gridCentroid = sum / cnt
			local boundary = mesh.getBoundaryEdges()
			t.expect(#boundary > 0).toBeTruthy()
			local be = boundary[1]
			local bv1 = mesh.getVertex(be.v1)
			local bv2 = mesh.getVertex(be.v2)
			assert(bv1 and bv2)
			local edgeMid = (bv1.position + bv2.position) / 2
			local outward = edgeMid - gridCentroid
			outward = Vector3.new(outward.X, 0, outward.Z)
			outward = if outward.Magnitude < 0.01 then Vector3.xAxis else outward.Unit
			local apex = edgeMid + outward * settings.GridSpacing

			local addedTriId = session.AddTriangleOffEdge(edgeMid, apex)
			t.expect(addedTriId).toBeTruthy()
			t.expect(countDict(mesh.getTriangles())).toBe(gridTris + 1)
			t.expect(mesh.findVertexNear(apex, 0.5)).toBeTruthy()

			-- 3) Colour the captured grid triangle red
			settings.PaintColor = { 1, 0, 0 }
			settings.PaintTarget = "Color"
			session.PaintAt(paintPos)
			local red = Color3.new(1, 0, 0)
			t.expect(colorsClose(paintPart.Color, red)).toBeTruthy()

			-- Undo paint -> colour reverts
			ChangeHistoryService:Undo()
			settle()
			t.expect(colorsClose(paintPart.Color, origColor)).toBeTruthy()

			-- Undo add -> triangle gone, mesh back to grid
			ChangeHistoryService:Undo()
			settle()
			t.expect(countDict(mesh.getTriangles())).toBe(gridTris)
			t.expect(mesh.findVertexNear(apex, 0.5) == nil).toBeTruthy()

			-- Redo add -> triangle back (rediscovered via connectivity)
			ChangeHistoryService:Redo()
			settle()
			t.expect(countDict(mesh.getTriangles())).toBe(gridTris + 1)
			t.expect(mesh.findVertexNear(apex, 0.5)).toBeTruthy()

			-- Redo paint -> colour red again
			ChangeHistoryService:Redo()
			settle()
			t.expect(colorsClose(paintPart.Color, red)).toBeTruthy()
		end)
	end)

	t.test("workflow: subdivide then simplify, undo chain restores each step, redo from empty", function()
		withSession(function(session, mesh)
			session.GenerateGrid()
			local n0 = countDict(mesh.getTriangles())
			t.expect(n0 > 0).toBeTruthy()

			-- Select every vertex and subdivide
			local allPos: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(allPos, v.position)
			end
			session.SelectVerticesNear(allPos)
			session.Subdivide()
			local n1 = countDict(mesh.getTriangles())
			t.expect(n1 > n0).toBeTruthy()

			-- Simplify a couple of edges
			session.Simplify(2)
			local n2 = countDict(mesh.getTriangles())
			t.expect(n2 < n1).toBeTruthy()

			-- Undo simplify -> back to subdivided (full rediscovery of restored parts)
			ChangeHistoryService:Undo()
			settle()
			t.expect(countDict(mesh.getTriangles())).toBe(n1)

			-- Undo subdivide -> back to the original grid
			ChangeHistoryService:Undo()
			settle()
			t.expect(countDict(mesh.getTriangles())).toBe(n0)

			-- Undo generate -> empty
			ChangeHistoryService:Undo()
			settle()
			t.expect(countDict(mesh.getTriangles())).toBe(0)

			-- Redo generate from the empty mesh -> grid re-found via last-known seeds
			ChangeHistoryService:Redo()
			settle()
			t.expect(countDict(mesh.getTriangles())).toBe(n0)
		end)
	end)

	t.test("workflow: a no-op Simplify does not desync the undo selection stack", function()
		withSession(function(session, mesh)
			session.GenerateGrid()

			-- Move vertex A (a real, undoable op whose pre-op selection is {A})
			local aPos: Vector3? = nil
			for _, v in mesh.getVertices() do
				aPos = v.position
				break
			end
			assert(aPos)
			session.SelectVerticesNear({ aPos })
			session.MoveSelectedVertices(Vector3.new(0, 6, 0))

			-- Select two non-adjacent vertices (not A) and Simplify -> a no-op
			local others: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				if (v.position - aPos).Magnitude > 0.5 then
					table.insert(others, v.position)
				end
			end
			local b, c = pickTwoFarApart(others)
			session.SelectVerticesNear({ b, c })
			t.expect(countDict(session.GetSelectedVertices())).toBe(2)
			session.Simplify(1)

			-- Undo the move. If the no-op Simplify leaked a snapshot, this pops the
			-- wrong one and restores {B,C}; with the fix it restores the move's {A}.
			ChangeHistoryService:Undo()
			settle()

			local restoredA = mesh.findVertexNear(aPos, 0.5)
			t.expect(restoredA).toBeTruthy()
			local sel = session.GetSelectedVertices()
			t.expect(countDict(sel)).toBe(1)
			t.expect(sel[restoredA]).toBeTruthy()
		end)
	end)

	t.test("workflow: paint keeps later undo selections balanced", function()
		withSession(function(session, mesh, settings)
			session.GenerateGrid()

			-- Move vertex A; its pre-op selection snapshot is {A}
			local aPos: Vector3? = nil
			local aVid: number? = nil
			for vid, v in mesh.getVertices() do
				aVid = vid
				aPos = v.position
				break
			end
			assert(aVid and aPos)
			session.SelectVerticesNear({ aPos })
			session.MoveSelectedVertices(Vector3.new(0, 6, 0))

			-- Paint a flat grid triangle that does not contain A
			settings.PaintColor = { 1, 0, 0 }
			settings.PaintTarget = "Color"
			local paintPos: Vector3? = nil
			for _, tri in mesh.getTriangles() do
				local hasA = false
				for _, vid in tri.vertices do
					if vid == aVid then
						hasA = true
					end
				end
				if not hasA then
					local p1 = mesh.getVertex(tri.vertices[1])
					local p2 = mesh.getVertex(tri.vertices[2])
					local p3 = mesh.getVertex(tri.vertices[3])
					if p1 and p2 and p3 then
						paintPos = (p1.position + p2.position + p3.position) / 3
						break
					end
				end
			end
			assert(paintPos)
			session.PaintAt(paintPos)

			-- Undo paint, then undo move. If paint committed a waypoint without
			-- pushing a snapshot, the move-undo pops the grid's empty snapshot and
			-- drops the selection; with the fix it restores the move's {A}.
			ChangeHistoryService:Undo()
			settle()
			ChangeHistoryService:Undo()
			settle()

			local restoredA = mesh.findVertexNear(aPos, 0.5)
			t.expect(restoredA).toBeTruthy()
			local sel = session.GetSelectedVertices()
			t.expect(countDict(sel)).toBe(1)
			t.expect(sel[restoredA]).toBeTruthy()
		end)
	end)

	t.test("rediscovering a curved grid from a fresh state has no interior boundary edges", function()
		withSession(function(session, mesh, settings)
			-- A grid small enough that GenerateGrid's own discovery covers it fully.
			settings.GridWidth = 4
			settings.GridHeight = 4

			-- 1) Create a grid
			session.GenerateGrid()
			local flatTris = countDict(mesh.getTriangles())
			local correctVerts = countDict(mesh.getVertices())
			local flatBoundary = #mesh.getBoundaryEdges()
			t.expect(flatTris > 0).toBeTruthy()

			-- 2) Select the center vertex (nearest the XZ centroid)
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local centroidXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centerPos: Vector3? = nil
			local bestD = math.huge
			for _, v in mesh.getVertices() do
				local d = (Vector3.new(v.position.X, 0, v.position.Z) - centroidXZ).Magnitude
				if d < bestD then
					bestD = d
					centerPos = v.position
				end
			end
			assert(centerPos)

			-- 3) Pull it up to form a curved surface
			session.SelectVerticesNear({ centerPos })
			session.MoveSelectedVertices(Vector3.new(0, 8, 0))
			-- The live mesh keeps correct connectivity through the move.
			t.expect(#mesh.getBoundaryEdges()).toBe(flatBoundary)

			-- A surface point (a triangle centroid) to seed a fresh discovery from.
			local seed: Vector3? = nil
			for _, tri in mesh.getTriangles() do
				local a = mesh.getVertex(tri.vertices[1])
				local b = mesh.getVertex(tri.vertices[2])
				local c = mesh.getVertex(tri.vertices[3])
				if a and b and c then
					seed = (a.position + b.position + c.position) / 3
					break
				end
			end
			assert(seed)

			-- 4) Reset the plugin: a fresh mesh rediscovers the same world parts
			-- 5) ...with a large radius
			local mesh2 = createTriangleMesh()
			mesh2.discoverRegion({ seed }, 1000)

			-- 6) ...and its boundary must be exactly the grid perimeter. A boundary
			-- edge whose midpoint is in the interior (not on the XZ bounding box)
			-- means adjacent curved triangles failed to share a vertex -- a crack.
			local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
			for _, v in mesh2.getVertices() do
				minX = math.min(minX, v.position.X)
				maxX = math.max(maxX, v.position.X)
				minZ = math.min(minZ, v.position.Z)
				maxZ = math.max(maxZ, v.position.Z)
			end
			local tol = 0.5
			local interiorBoundary = 0
			for _, edge in mesh2.getBoundaryEdges() do
				local a = mesh2.getVertex(edge.v1)
				local b = mesh2.getVertex(edge.v2)
				if a and b then
					local mid = (a.position + b.position) / 2
					local onPerimeter = math.abs(mid.X - minX) < tol or math.abs(mid.X - maxX) < tol
						or math.abs(mid.Z - minZ) < tol or math.abs(mid.Z - maxZ) < tol
					if not onPerimeter then
						interiorBoundary += 1
					end
				end
			end
			-- Same triangles and vertices as the correctly-connected live mesh:
			-- no spurious back faces and no unmerged (cracked) vertices.
			t.expect(countDict(mesh2.getTriangles())).toBe(flatTris)
			t.expect(countDict(mesh2.getVertices())).toBe(correctVerts)
			-- No boundary edge may lie in the interior.
			t.expect(interiorBoundary).toBe(0)
			t.expect(#mesh2.getBoundaryEdges()).toBe(flatBoundary)
		end)
	end)

	t.test("incremental discovery of a clean curved surface stays coherent and consistently oriented", function()
		-- Build the surface DIRECTLY with fillTriangle (uniform winding) so this
		-- discovery test is not contaminated by the move tool's orientation
		-- handling -- the two concerns are tested separately.
		local region = Vector3.new(7000, 0, 0)
		local function sweep()
			for _, p in workspace:GetPartBoundsInRadius(region, 80) do
				if p:IsA("BasePart") then
					p:Destroy()
				end
			end
		end
		sweep()
		local folder = Instance.new("Folder")
		folder.Parent = workspace

		local n = 5
		local spacing = 4
		local thickness = 0.2
		local function height(x: number, z: number): number
			local dx = x - region.X
			local dz = z - region.Z
			return 5 * math.exp(-(dx * dx + dz * dz) / 60)
		end
		local function vAt(i: number, j: number): Vector3
			local x = region.X - (n * spacing) / 2 + i * spacing
			local z = region.Z - (n * spacing) / 2 + j * spacing
			return Vector3.new(x, height(x, z), z)
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local tl, tr = vAt(i, j), vAt(i + 1, j)
				local bl, br = vAt(i, j + 1), vAt(i + 1, j + 1)
				fillTriangle(tl, tr, bl, thickness, folder)
				fillTriangle(tr, br, bl, thickness, folder)
			end
		end

		-- Discover incrementally -- a small region seeded at each triangle's
		-- centroid, simulating hovering over several areas in turn. The centroid
		-- lies on that triangle's (front) face, exactly like a raycast hit.
		local mesh = createTriangleMesh()
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local tl, tr = vAt(i, j), vAt(i + 1, j)
				local bl, br = vAt(i, j + 1), vAt(i + 1, j + 1)
				mesh.discoverRegion({ (tl + tr + bl) / 3 }, 6)
				mesh.discoverRegion({ (tr + br + bl) / 3 }, 6)
			end
		end

		-- Exact grid topology: (n+1)^2 vertices, 2 n^2 triangles, 4n perimeter edges.
		-- Any excess means cracks (unmerged vertices / unmerged wedge pairs).
		t.expect(countDict(mesh.getVertices())).toBe((n + 1) * (n + 1))
		t.expect(countDict(mesh.getTriangles())).toBe(2 * n * n)
		t.expect(#mesh.getBoundaryEdges()).toBe(4 * n)

		-- Consistent orientation: every shared (interior) edge is traversed in
		-- opposite directions by its two triangles. A flipped triangle traverses
		-- it the same way -- the "some go one way, some the other" bug.
		local function edgeDir(tri, vA: number, vB: number): number
			local v = tri.vertices
			for i = 1, 3 do
				local j = i % 3 + 1
				if v[i] == vA and v[j] == vB then
					return 1
				elseif v[i] == vB and v[j] == vA then
					return -1
				end
			end
			return 0
		end
		local flipped = 0
		for _, edge in mesh.getEdges() do
			if #edge.triangles == 2 then
				local t1 = mesh.getTriangle(edge.triangles[1])
				local t2 = mesh.getTriangle(edge.triangles[2])
				if t1 and t2 then
					local d1 = edgeDir(t1, edge.v1, edge.v2)
					local d2 = edgeDir(t2, edge.v1, edge.v2)
					if d1 ~= 0 and d1 == d2 then
						flipped += 1
					end
				end
			end
		end
		t.expect(flipped).toBe(0)

		folder:Destroy()
		sweep()
	end)

	t.test("the move tool keeps the surface consistently oriented and crack-free", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			session.GenerateGrid()

			-- Sculpt with the move tool.
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local c = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local function moveNearest(xz: Vector3, dy: number)
				local best: Vector3? = nil
				local bestD = math.huge
				for _, v in mesh.getVertices() do
					local d = (Vector3.new(v.position.X, 0, v.position.Z) - xz).Magnitude
					if d < bestD then
						bestD = d
						best = v.position
					end
				end
				if best then
					session.SelectVerticesNear({ best })
					session.MoveSelectedVertices(Vector3.new(0, dy, 0))
				end
			end
			moveNearest(c, 8)
			moveNearest(c + Vector3.new(4, 0, 4), 5)
			moveNearest(c + Vector3.new(-4, 0, -4), -3)

			local function countFlipped(m): number
				local function edgeDir(tri, vA: number, vB: number): number
					local v = tri.vertices
					for i = 1, 3 do
						local j = i % 3 + 1
						if v[i] == vA and v[j] == vB then
							return 1
						elseif v[i] == vB and v[j] == vA then
							return -1
						end
					end
					return 0
				end
				local f = 0
				for _, e in m.getEdges() do
					if #e.triangles == 2 then
						local t1 = m.getTriangle(e.triangles[1])
						local t2 = m.getTriangle(e.triangles[2])
						if t1 and t2 then
							local d1 = edgeDir(t1, e.v1, e.v2)
							if d1 ~= 0 and d1 == edgeDir(t2, e.v1, e.v2) then
								f += 1
							end
						end
					end
				end
				return f
			end

			-- The live mesh stays consistently oriented through the moves.
			t.expect(countFlipped(mesh)).toBe(0)

			-- And the world geometry the move tool produced rediscovers cleanly:
			-- same topology, no cracks, consistently oriented.
			local correctTris = countDict(mesh.getTriangles())
			local correctVerts = countDict(mesh.getVertices())
			local correctBoundary = #mesh.getBoundaryEdges()
			local mesh2 = createTriangleMesh()
			for _, tri in mesh.getTriangles() do
				local a = mesh.getVertex(tri.vertices[1])
				local b = mesh.getVertex(tri.vertices[2])
				local d = mesh.getVertex(tri.vertices[3])
				if a and b and d then
					mesh2.discoverRegion({ (a.position + b.position + d.position) / 3 }, 8)
				end
			end
			t.expect(countDict(mesh2.getTriangles())).toBe(correctTris)
			t.expect(countDict(mesh2.getVertices())).toBe(correctVerts)
			t.expect(#mesh2.getBoundaryEdges()).toBe(correctBoundary)
			t.expect(countFlipped(mesh2)).toBe(0)
		end)
	end)

	t.test("moving a region down then undoing restores the original mesh", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()
			t.expect(n0T > 0).toBeTruthy()

			-- Move a large connected region down -- like a single move-tool drag with
			-- the influence radius -- so every moved vertex ends up far from where it
			-- started.
			local allPos: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(allPos, v.position)
			end
			session.SelectVerticesNear(allPos)
			session.MoveSelectedVertices(Vector3.new(0, -8, 0))

			-- Undo must bring the original flat grid back, not an empty/broken mesh.
			ChangeHistoryService:Undo()
			settle()

			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
		end)
	end)
end
