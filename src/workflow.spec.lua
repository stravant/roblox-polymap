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

	-- Faithful replica of updateHover's discovery (createPolyMapSession ~L437):
	-- sweep rays out from the camera eye across the work region and call
	-- discoverPart UNCONDITIONALLY on every wedge hit, exactly as the live cursor
	-- task does every frame (no "already tracked" guard, unlike discoverRegion).
	local function faithfulHover(mesh: any)
		for tx = -16, 16, 2 do
			for tz = -16, 16, 2 do
				local target = kRegionCenter + Vector3.new(tx, 0, tz)
				local dir = target - kCameraEye
				local hit = workspace:Raycast(kCameraEye, dir * 1.25)
				if
					hit
					and hit.Instance:IsA("Part")
					and (hit.Instance :: Part).Shape == Enum.PartType.Wedge
				then
					mesh.discoverPart(hit.Instance :: BasePart, hit.Position)
				end
			end
		end
	end

	-- Count edges shared by more than two triangles. A grid surface is a
	-- manifold-with-boundary: every edge has 1 (boundary) or 2 (interior)
	-- triangles. Anything higher means phantom/duplicated geometry.
	local function nonManifoldEdges(mesh: any): number
		local n = 0
		for _, e in mesh.getEdges() do
			local live = 0
			for _, tid in e.triangles do
				if mesh.getTriangle(tid) then
					live += 1
				end
			end
			if live > 2 then
				n += 1
			end
		end
		return n
	end

	-- The XZ-nearest live vertex to a world position, ignoring height. Used to
	-- follow "the vertex at this column" across mesh rebuilds (undo rediscovery
	-- assigns fresh ids, so we can't track by id).
	local function vertexAtColumn(mesh: any, xz: Vector3): any
		local best: any = nil
		local bestD = math.huge
		for _, v in mesh.getVertices() do
			local d = (Vector3.new(v.position.X, 0, v.position.Z) - Vector3.new(xz.X, 0, xz.Z)).Magnitude
			if d < bestD then
				bestD = d
				best = v
			end
		end
		return best
	end

	t.test("generate grid discovers the camera-facing side, like a hover", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4

			-- Map each triangle (keyed by its XZ centroid) to its discovered facing.
			local function recordByCentroid(m: any): { [string]: number }
				local out: { [string]: number } = {}
				for _, tri in m.getTriangles() do
					local c = Vector3.zero
					for _, vid in tri.vertices do
						c += m.getVertex(vid).position
					end
					c /= 3
					out[string.format("%.1f_%.1f", c.X, c.Z)] = tri.normal.Y
				end
				return out
			end

			session.GenerateGrid()
			local genNormals = recordByCentroid(mesh)

			-- Rediscover from scratch the way a freshly reopened plugin does: raycasts
			-- from the camera, discoverPart on each hit. This is the reference facing.
			mesh.clear()
			faithfulHover(mesh)
			local hoverNormals = recordByCentroid(mesh)

			-- The generate-populated facing must match the hover-populated facing, or a
			-- move right after generate rebuilds the wedges on the wrong side.
			local total, mismatches = 0, 0
			for key, hoverY in hoverNormals do
				local genY = genNormals[key]
				if genY ~= nil then
					total += 1
					if (genY >= 0) ~= (hoverY >= 0) then
						mismatches += 1
					end
				end
			end
			t.expect(total > 0).toBeTruthy()
			t.expect(mismatches).toBe(0)
		end)
	end)

	t.test("Place grid: two corners span the exact rectangle as the grid's diagonal", function()
		withSession(function(session, mesh, settings)
			settings.GridType = "Square"
			settings.GridSpacing = 8
			local c1 = kRegionCenter
			local c2 = kRegionCenter + Vector3.new(24, 0, 16)

			session.StartGridPlacement()
			t.expect(session.IsPlacingGrid()).toBe(true)

			-- First corner: still placing, nothing generated yet, a preview is shown.
			session.PlaceGridClickAt(c1)
			t.expect(session.IsPlacingGrid()).toBe(true)
			t.expect(countDict(mesh.getTriangles())).toBe(0)
			t.expect(session.GetGridPreviewLines() ~= nil).toBeTruthy()

			-- Second corner: the grid is generated and placement ends.
			session.PlaceGridClickAt(c2)
			t.expect(session.IsPlacingGrid()).toBe(false)
			t.expect(session.GetGridPreviewLines() == nil).toBeTruthy()

			-- 24x16 at spacing 8 -> 3x2 cells: 12 triangles, (3+1)x(2+1)=12 vertices.
			t.expect(countDict(mesh.getTriangles())).toBe(12)
			t.expect(countDict(mesh.getVertices())).toBe(12)

			-- Exact corners: the discovered vertices span the clicked rectangle in XZ.
			local minX, maxX = math.huge, -math.huge
			local minZ, maxZ = math.huge, -math.huge
			for _, v in mesh.getVertices() do
				minX = math.min(minX, v.position.X)
				maxX = math.max(maxX, v.position.X)
				minZ = math.min(minZ, v.position.Z)
				maxZ = math.max(maxZ, v.position.Z)
			end
			t.expect(math.abs(minX - math.min(c1.X, c2.X)) < 0.1).toBeTruthy()
			t.expect(math.abs(maxX - math.max(c1.X, c2.X)) < 0.1).toBeTruthy()
			t.expect(math.abs(minZ - math.min(c1.Z, c2.Z)) < 0.1).toBeTruthy()
			t.expect(math.abs(maxZ - math.max(c1.Z, c2.Z)) < 0.1).toBeTruthy()
		end)
	end)

	t.test("Place grid: corner clicks snap to a nearby existing vertex", function()
		withSession(function(session, mesh, settings)
			settings.GridType = "Square"
			settings.GridSpacing = 8
			-- Existing geometry to snap to.
			session.GenerateGrid()
			t.expect(countDict(mesh.getVertices()) > 0).toBeTruthy()

			-- Pick an existing vertex to aim near.
			local target: Vector3? = nil
			for _, v in mesh.getVertices() do
				target = v.position
				break
			end
			assert(target)

			session.StartGridPlacement()
			-- Click 1 stud off the vertex -- inside the 2-stud snap radius.
			session.PlaceGridClickAt(target + Vector3.new(1, 0, 0))

			-- The placed first corner (centre of the preview cross) snapped onto the vertex.
			local lines = session.GetGridPreviewLines()
			assert(lines and #lines >= 1)
			local mid = (lines[1][1] + lines[1][2]) / 2
			t.expect((mid - target).Magnitude < 0.05).toBeTruthy()
		end)
	end)

	t.test("Place grid: a corner discovers an undiscovered part and snaps to its vertex", function()
		withSession(function(session, mesh, settings)
			settings.GridType = "Square"
			settings.GridSpacing = 8
			-- Build geometry, note a vertex, and find its wedge part.
			session.GenerateGrid()
			local target: Vector3? = nil
			for _, v in mesh.getVertices() do
				target = v.position
				break
			end
			assert(target)
			local hitPart: BasePart? = nil
			for _, p in workspace:GetPartBoundsInRadius(target, 2) do
				if p:IsA("Part") and p.Shape == Enum.PartType.Wedge then
					hitPart = p
					break
				end
			end
			assert(hitPart)

			-- Forget it: the workspace parts remain but the in-memory mesh is empty,
			-- like a freshly reopened plugin that has discovered nothing yet.
			mesh.clear()
			t.expect(countDict(mesh.getVertices())).toBe(0)

			session.StartGridPlacement()
			-- Click 1 stud off the (now-undiscovered) vertex, passing the part the cursor
			-- would be over. Placement must discover it and snap onto the vertex.
			session.PlaceGridClickAt(target + Vector3.new(1, 0, 0), hitPart)

			-- Discovery happened on the click...
			t.expect(countDict(mesh.getVertices()) > 0).toBeTruthy()
			-- ...and the corner snapped onto the rediscovered vertex.
			local lines = session.GetGridPreviewLines()
			assert(lines and #lines >= 1)
			local mid = (lines[1][1] + lines[1][2]) / 2
			t.expect((mid - target).Magnitude < 0.05).toBeTruthy()
		end)
	end)

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

	t.test("a single move-tool drag down (with influence) then undo restores the grid", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			settings.InfluenceRadius = 10
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()

			-- Select the centre vertex only, then drag down. Influence moves a whole
			-- region with it, but only the centre is in the undo snapshot.
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local centreXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centre: Vector3? = nil
			local bestD = math.huge
			for _, v in mesh.getVertices() do
				local d = (Vector3.new(v.position.X, 0, v.position.Z) - centreXZ).Magnitude
				if d < bestD then
					bestD = d
					centre = v.position
				end
			end
			assert(centre)
			session.SelectVerticesNear({ centre })
			session.MoveSelectedWithInfluence(Vector3.new(0, -8, 0))

			ChangeHistoryService:Undo()
			settle()

			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
		end)
	end)

	t.test("multiple move-tool drags with undo mixed in restores the grid", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			settings.InfluenceRadius = 5
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()

			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local c = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local function dragNearest(xz: Vector3, delta: Vector3)
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
					session.MoveSelectedWithInfluence(delta)
				end
			end
			local function undo()
				ChangeHistoryService:Undo()
				settle()
			end

			-- A sequence of drags with undo mixed in, ending fully undone.
			dragNearest(c, Vector3.new(0, -6, 0))
			dragNearest(c + Vector3.new(8, 0, 0), Vector3.new(0, -5, 0))
			undo()
			dragNearest(c + Vector3.new(-6, 0, -6), Vector3.new(0, 4, 0))
			dragNearest(c + Vector3.new(0, 0, 8), Vector3.new(0, -7, 0))
			undo()
			undo()
			undo()

			-- Everything undone -> back to the original flat grid.
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
		end)
	end)

	t.test("hovering after a move does not duplicate geometry", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			settings.InfluenceRadius = 5
			session.GenerateGrid()

			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local cXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centre: Vector3? = nil
			local bestD = math.huge
			for _, v in mesh.getVertices() do
				local d = (Vector3.new(v.position.X, 0, v.position.Z) - cXZ).Magnitude
				if d < bestD then
					bestD = d
					centre = v.position
				end
			end
			assert(centre)
			session.SelectVerticesNear({ centre })
			session.MoveSelectedWithInfluence(Vector3.new(0, -8, 0))

			local tBefore = countDict(mesh.getTriangles())
			local vBefore = countDict(mesh.getVertices())

			-- Hover: re-discover every triangle's region, as the cursor task does
			-- continuously. This must NOT change the mesh.
			local centroids: { Vector3 } = {}
			for _, tri in mesh.getTriangles() do
				local a = mesh.getVertex(tri.vertices[1])
				local b = mesh.getVertex(tri.vertices[2])
				local c = mesh.getVertex(tri.vertices[3])
				if a and b and c then
					table.insert(centroids, (a.position + b.position + c.position) / 3)
				end
			end
			for _, ct in centroids do
				mesh.discoverRegion({ ct }, 6)
			end

			t.expect(countDict(mesh.getTriangles())).toBe(tBefore)
			t.expect(countDict(mesh.getVertices())).toBe(vBefore)
		end)
	end)

	t.test("drag down with hovering then undo restores a clean grid", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			settings.InfluenceRadius = 5
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()

			local function hover()
				local centroids: { Vector3 } = {}
				for _, tri in mesh.getTriangles() do
					local a = mesh.getVertex(tri.vertices[1])
					local b = mesh.getVertex(tri.vertices[2])
					local c = mesh.getVertex(tri.vertices[3])
					if a and b and c then
						table.insert(centroids, (a.position + b.position + c.position) / 3)
					end
				end
				for _, ct in centroids do
					mesh.discoverRegion({ ct }, 6)
				end
			end

			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local cXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centre: Vector3? = nil
			local bestD = math.huge
			for _, v in mesh.getVertices() do
				local d = (Vector3.new(v.position.X, 0, v.position.Z) - cXZ).Magnitude
				if d < bestD then
					bestD = d
					centre = v.position
				end
			end
			assert(centre)

			-- Drag down, hover (as the cursor task does), then undo, then hover again.
			session.SelectVerticesNear({ centre })
			session.MoveSelectedWithInfluence(Vector3.new(0, -8, 0))
			hover()
			ChangeHistoryService:Undo()
			settle()
			hover()

			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
		end)
	end)

	t.test("faithful raycast hovers across moves and undos stay a clean grid", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			settings.GridSpacing = 4
			settings.InfluenceRadius = 6
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()

			-- Faithful replica of updateHover's discovery (createPolyMapSession ~L437):
			-- sweep rays out from the camera eye across the region as the cursor moves
			-- and call discoverPart UNCONDITIONALLY on every wedge hit -- there is no
			-- "already tracked" guard in the live path, so a ray grazing a tilted
			-- part's underside can discover its back face, exactly as the cursor task
			-- does. This is the real hover, not the discoverRegion approximation.
			local function hover()
				for tx = -14, 14, 2 do
					for tz = -14, 14, 2 do
						local target = kRegionCenter + Vector3.new(tx, 0, tz)
						local dir = target - kCameraEye
						local hit = workspace:Raycast(kCameraEye, dir * 1.25)
						if
							hit
							and hit.Instance:IsA("Part")
							and (hit.Instance :: Part).Shape == Enum.PartType.Wedge
						then
							mesh.discoverPart(hit.Instance :: BasePart, hit.Position)
						end
					end
				end
			end

			local function vertNear(xz: Vector3): Vector3?
				local best: Vector3? = nil
				local bestD = math.huge
				for _, v in mesh.getVertices() do
					local d = (Vector3.new(v.position.X, 0, v.position.Z) - Vector3.new(xz.X, 0, xz.Z)).Magnitude
					if d < bestD then
						bestD = d
						best = v.position
					end
				end
				return best
			end

			-- Hovering over the freshly generated flat grid discovers nothing new.
			hover()
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)

			-- Several select + influenced-move rounds, hovering after every change as
			-- the cursor task would, with undo mixed in. Track pending (un-undone)
			-- moves so we return exactly to the flat grid without undoing the generate.
			local plan = {
				{ off = Vector3.new(0, 0, 0), dy = -6, undo = true },
				{ off = Vector3.new(4, 0, 4), dy = 5, undo = false },
				{ off = Vector3.new(-4, 0, -4), dy = -5, undo = true },
				{ off = Vector3.new(4, 0, -4), dy = 4, undo = false },
				{ off = Vector3.new(-4, 0, 4), dy = -4, undo = false },
			}
			local pending = 0
			for _, step in plan do
				local vp = vertNear(kRegionCenter + step.off)
				if vp then
					session.SelectVerticesNear({ vp })
					session.MoveSelectedWithInfluence(Vector3.new(0, step.dy, 0))
					pending += 1
					hover()
					if step.undo then
						ChangeHistoryService:Undo()
						settle()
						pending -= 1
						hover()
					end
				end
			end

			-- Undo the remaining moves back to the flat grid, hovering between each.
			for _ = 1, pending do
				ChangeHistoryService:Undo()
				settle()
				hover()
			end

			-- The session mesh is exactly the original flat grid again.
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)

			-- And the world geometry itself is clean: a fresh discovery from scratch
			-- finds exactly the grid, with no leftover/duplicate parts left behind by
			-- the hover-during-move path.
			local fresh = createTriangleMesh()
			fresh.discoverRegion({ kRegionCenter }, 40)
			t.expect(countDict(fresh.getTriangles())).toBe(n0T)
			t.expect(countDict(fresh.getVertices())).toBe(n0V)
			t.expect(#fresh.getBoundaryEdges()).toBe(n0B)
		end)
	end)

	t.test("a move-tool influenced curve rediscovers with no thickness-offset cracks", function()
		withSession(function(session, mesh, settings)
			-- Sculpt a smooth dome with the move tool + influence (many gently tilted
			-- wedges), then rediscover the world from scratch the way rediscoverMesh
			-- does on undo. The rebuilt mesh must match the live one exactly: a wedge
			-- discovered on its back face lands its corners a full thickness off its
			-- neighbours, producing extra vertices and interior boundary edges (cracks)
			-- that corrupt the topology a later edit walks.
			settings.GridWidth = 6
			settings.GridHeight = 6
			settings.GridSpacing = 4
			settings.InfluenceRadius = 10
			session.GenerateGrid()

			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local cXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centreV = vertexAtColumn(mesh, cXZ)
			assert(centreV)
			session.SelectVerticesNear({ centreV.position })
			session.MoveSelectedWithInfluence(Vector3.new(0, 8, 0))
			faithfulHover(mesh)

			local liveT = countDict(mesh.getTriangles())
			local liveV = countDict(mesh.getVertices())
			local liveB = #mesh.getBoundaryEdges()
			t.expect(nonManifoldEdges(mesh)).toBe(0)

			-- Fresh discovery from a surface seed (as rediscoverMesh does on undo).
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

			local livePositions: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(livePositions, v.position)
			end

			local fresh = createTriangleMesh()
			fresh.discoverRegion({ seed }, 1000)

			-- Every rediscovered vertex coincides with a live vertex (no thickness
			-- offset), and the counts match exactly.
			local orphans = 0
			for _, fv in fresh.getVertices() do
				local minD = math.huge
				for _, lp in livePositions do
					minD = math.min(minD, (fv.position - lp).Magnitude)
				end
				if minD > 0.05 then
					orphans += 1
				end
			end
			t.expect(orphans).toBe(0)
			t.expect(countDict(fresh.getTriangles())).toBe(liveT)
			t.expect(countDict(fresh.getVertices())).toBe(liveV)
			t.expect(#fresh.getBoundaryEdges()).toBe(liveB)
			t.expect(nonManifoldEdges(fresh)).toBe(0)
		end)
	end)

	t.test("re-drag a still-selected vertex up after undoing a drag down (small influence, hover first)", function()
		withSession(function(session, mesh, settings)
			-- Grid larger than the influence, so a drag only deforms a couple of
			-- triangles around the selected vertex and leaves the rest flat -- the
			-- partial deformation the user described.
			settings.GridWidth = 6
			settings.GridHeight = 6
			settings.GridSpacing = 4
			settings.InfluenceRadius = 6
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()

			-- Hover BEFORE selecting, as the cursor naturally passes over the surface.
			faithfulHover(mesh)
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(nonManifoldEdges(mesh)).toBe(0)

			-- Select a single interior vertex (influence stays inside the grid).
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local cXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centreV = vertexAtColumn(mesh, cXZ)
			assert(centreV)
			local col = Vector3.new(centreV.position.X, 0, centreV.position.Z)
			local flatY = centreV.position.Y

			session.SelectVerticesNear({ centreV.position })
			t.expect(countDict(session.GetSelectedVertices())).toBe(1)

			-- Drag the selection DOWN, hover, then UNDO. The vertex stays selected.
			session.MoveSelectedWithInfluence(Vector3.new(0, -8, 0))
			faithfulHover(mesh)
			t.expect(nonManifoldEdges(mesh)).toBe(0)

			ChangeHistoryService:Undo()
			settle()
			faithfulHover(mesh)

			-- After undo: flat grid is back, manifold, and the vertex is still selected
			-- at its original column near its original (flat) height.
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
			t.expect(nonManifoldEdges(mesh)).toBe(0)
			t.expect(countDict(session.GetSelectedVertices())).toBe(1)
			local restored = vertexAtColumn(mesh, col)
			assert(restored)
			t.expect(math.abs(restored.position.Y - flatY) < 0.5).toBeTruthy()

			-- WITHOUT reselecting, drag the still-selected vertex UP. This is the step
			-- that "does not work" when the post-undo topology is corrupted.
			session.MoveSelectedWithInfluence(Vector3.new(0, 8, 0))
			faithfulHover(mesh)

			-- The drag must actually raise the vertex at that column to ~flatY+8, and
			-- the mesh must remain a consistent, manifold grid of the same size.
			local raised = vertexAtColumn(mesh, col)
			assert(raised)
			t.expect(math.abs(raised.position.Y - (flatY + 8)) < 0.5).toBeTruthy()
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
			t.expect(nonManifoldEdges(mesh)).toBe(0)
		end)
	end)

	t.test("re-drag after undo works on an already-curved surface (the back-face case)", function()
		withSession(function(session, mesh, settings)
			-- The user's failing case happens on an EXISTING curved surface, where
			-- undo rediscovers the curve from scratch. Build a dome first (un-undone),
			-- then drag a slope vertex down, undo (rediscovering the dome), and re-drag
			-- the still-selected vertex up. Before the discovery fix, the dome came back
			-- with thickness-offset back-face cracks and the re-drag operated on broken
			-- topology.
			settings.GridWidth = 6
			settings.GridHeight = 6
			settings.GridSpacing = 4
			settings.InfluenceRadius = 10
			session.GenerateGrid()
			local n0T = countDict(mesh.getTriangles())
			local n0V = countDict(mesh.getVertices())
			local n0B = #mesh.getBoundaryEdges()

			-- 1) Sculpt a dome with the move tool (this is the "existing" geometry).
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local cXZ = Vector3.new(sum.X / cnt, 0, sum.Z / cnt)
			local centreV = vertexAtColumn(mesh, cXZ)
			assert(centreV)
			session.SelectVerticesNear({ centreV.position })
			session.MoveSelectedWithInfluence(Vector3.new(0, 8, 0))
			faithfulHover(mesh)

			-- 2) Select a vertex partway down the slope and record its dome height.
			local slopeColumn = Vector3.new(cXZ.X + 4, 0, cXZ.Z)
			local slopeV = vertexAtColumn(mesh, slopeColumn)
			assert(slopeV)
			local domeY = slopeV.position.Y
			t.expect(domeY > 0.5).toBeTruthy() -- genuinely on the raised dome
			session.SelectVerticesNear({ slopeV.position })
			t.expect(countDict(session.GetSelectedVertices())).toBe(1)

			-- 3) Drag down, hover, undo (rediscovers the dome), hover.
			session.MoveSelectedWithInfluence(Vector3.new(0, -6, 0))
			faithfulHover(mesh)
			ChangeHistoryService:Undo()
			settle()
			faithfulHover(mesh)

			-- After undo the dome is back -- same size, manifold, no cracks -- and the
			-- slope vertex is restored to its dome height and still selected.
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
			t.expect(nonManifoldEdges(mesh)).toBe(0)
			t.expect(countDict(session.GetSelectedVertices())).toBe(1)
			local backOnDome = vertexAtColumn(mesh, slopeColumn)
			assert(backOnDome)
			t.expect(math.abs(backOnDome.position.Y - domeY) < 0.5).toBeTruthy()

			-- 4) Re-drag the still-selected vertex UP. It must rise from the dome height.
			session.MoveSelectedWithInfluence(Vector3.new(0, 6, 0))
			faithfulHover(mesh)
			local raised = vertexAtColumn(mesh, slopeColumn)
			assert(raised)
			t.expect(math.abs(raised.position.Y - (domeY + 6)) < 0.5).toBeTruthy()
			t.expect(countDict(mesh.getTriangles())).toBe(n0T)
			t.expect(countDict(mesh.getVertices())).toBe(n0V)
			t.expect(#mesh.getBoundaryEdges()).toBe(n0B)
			t.expect(nonManifoldEdges(mesh)).toBe(0)
		end)
	end)

	t.test("Add: grabbing a box edge uses the camera-facing (top) face", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Add"
			-- A thin square tile (thin along Y) centred at the region, raised to Y=10.
			-- The pinned camera sits at Y=30, well above it, so the top face wins.
			local box = Instance.new("Part")
			box.Shape = Enum.PartType.Block
			box.Size = Vector3.new(4, 0.2, 4)
			box.CFrame = CFrame.new(kRegionCenter + Vector3.new(0, 10, 0))
			box.Anchored = true
			box.Parent = workspace.Terrain

			-- Click on the +X side just BELOW the mid-plane (Y=9.96) -- where a cursor
			-- crossing the slab's side first lands. The hint-only path discovers the
			-- bottom face here; handleAddClick must discover with the camera FIRST (it
			-- did not before, because discoverRegion ran first) and grab a TOP edge.
			session.AddClickAt(kRegionCenter + Vector3.new(2.0, 9.96, 0), box)

			local edge = session.GetAddBoundaryEdge()
			assert(edge)
			local a = mesh.getVertex(edge.v1)
			local b = mesh.getVertex(edge.v2)
			assert(a and b)
			-- Top face corners are at Y=10.1, bottom at 9.9.
			t.expect(a.position.Y > 10.0).toBeTruthy()
			t.expect(b.position.Y > 10.0).toBeTruthy()
		end)
	end)

	t.test("Add: three empty-space clicks form a fresh disconnected triangle", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Add"
			-- All three points are over empty space (no geometry to hit).
			local p1 = kRegionCenter + Vector3.new(0, 0, 0)
			local p2 = kRegionCenter + Vector3.new(6, 0, 0)
			local p3 = kRegionCenter + Vector3.new(3, 0, 5)

			session.AddClickAt(p1, nil)
			session.AddClickAt(p2, nil)
			-- Not committed yet: two corners placed, no triangle.
			t.expect(countDict(mesh.getTriangles())).toBe(0)
			t.expect(#session.GetAddPoints()).toBe(2)

			session.AddClickAt(p3, nil)
			-- Third click forms the triangle and clears the in-progress state.
			t.expect(countDict(mesh.getTriangles())).toBe(1)
			t.expect(#session.GetAddPoints()).toBe(0)
			t.expect(mesh.findVertexNear(p1, 0.3)).toBeTruthy()
			t.expect(mesh.findVertexNear(p2, 0.3)).toBeTruthy()
			t.expect(mesh.findVertexNear(p3, 0.3)).toBeTruthy()
		end)
	end)

	t.test("Add: connect a boundary edge to a fresh vertex in empty space", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			session.GenerateGrid()
			settings.Mode = "Add"
			local before = countDict(mesh.getTriangles())
			t.expect(before > 0).toBeTruthy()

			-- A boundary edge, a triangle on it, and one of its parts.
			local boundary = mesh.getBoundaryEdges()
			t.expect(#boundary > 0).toBeTruthy()
			local edge = boundary[1]
			local a = mesh.getVertex(edge.v1)
			local b = mesh.getVertex(edge.v2)
			local tri = mesh.getTriangle(edge.triangles[1])
			assert(a and b and tri)
			local part = tri.parts[1]
			local edgeMid = (a.position + b.position) / 2

			-- Grid centre, for placing the apex outward into empty space.
			local sum = Vector3.zero
			local cnt = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local gridCenter = sum / cnt

			-- Click 1: on the boundary edge (over geometry) -> grabs the edge.
			session.AddClickAt(edgeMid, part)
			t.expect(session.GetAddBoundaryEdge()).toBeTruthy()
			t.expect(countDict(mesh.getTriangles())).toBe(before) -- nothing added yet

			-- Click 2: an apex out in empty space, outward from the grid, same height.
			local outward = Vector3.new(edgeMid.X - gridCenter.X, 0, edgeMid.Z - gridCenter.Z)
			if outward.Magnitude < 0.1 then
				outward = Vector3.new(1, 0, 0)
			end
			local apex = edgeMid + outward.Unit * 4
			apex = Vector3.new(apex.X, edgeMid.Y, apex.Z)
			session.AddClickAt(apex, nil)

			-- A new triangle now connects the edge to the fresh apex; state cleared.
			t.expect(countDict(mesh.getTriangles())).toBe(before + 1)
			t.expect(mesh.findVertexNear(apex, 0.3)).toBeTruthy()
			t.expect(session.GetAddBoundaryEdge() == nil).toBeTruthy()
		end)
	end)

	t.test("Paint discovers the radius region on a freshly opened mesh", function()
		withSession(function(session, mesh, settings)
			-- Build grid PARTS in the world WITHOUT discovering them into the session
			-- mesh -- the "just opened the tool on an existing place" state, where
			-- only on-demand discovery has happened.
			local generateGrid = require("./generateGrid")
			generateGrid({
				GridType = "Square",
				Width = 6,
				Height = 6,
				Spacing = 4,
				Origin = CFrame.new(kRegionCenter),
				Thickness = 0.2,
				Parent = workspace.Terrain,
				Props = { Color = Color3.new(0.5, 0.5, 0.5), Material = Enum.Material.Plastic },
			})
			t.expect(countDict(mesh.getTriangles())).toBe(0) -- nothing discovered yet

			settings.Mode = "Paint"
			settings.PaintTarget = "Color"
			settings.PaintStrength = 1.0
			settings.PaintColor = { 1, 0, 0 }
			settings.PaintRadius = 8

			session.PaintAt(kRegionCenter)

			-- A radius-8 brush must colour a region of triangles -- not just the one
			-- under the cursor, which is all an un-discovered surface walk would find.
			local redCount = 0
			for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 12) do
				if p:IsA("BasePart") then
					local col = (p :: BasePart).Color
					if math.abs(col.R - 1) < 0.05 and col.G < 0.05 and col.B < 0.05 then
						redCount += 1
					end
				end
			end
			t.expect(redCount > 10).toBeTruthy()
		end)
	end)

	t.test("Move influence outline discovers the region on a freshly opened mesh", function()
		withSession(function(session, mesh, settings)
			local generateGrid = require("./generateGrid")
			generateGrid({
				GridType = "Square",
				Width = 6,
				Height = 6,
				Spacing = 4,
				Origin = CFrame.new(kRegionCenter),
				Thickness = 0.2,
				Parent = workspace.Terrain,
				Props = { Color = Color3.new(0.5, 0.5, 0.5), Material = Enum.Material.Plastic },
			})

			-- Discover ONLY the single part at the centre -- the "first hover" state,
			-- where the cursor has touched one triangle but nothing around it.
			local centerPart: BasePart? = nil
			for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 1) do
				if p:IsA("BasePart") then
					centerPart = p :: BasePart
					break
				end
			end
			assert(centerPart)
			mesh.discoverPart(centerPart, (centerPart :: BasePart).Position)
			t.expect(countDict(mesh.getTriangles()) <= 4).toBeTruthy() -- mostly undiscovered

			-- Select one of the (few) discovered vertices near the centre.
			local seedPos: Vector3? = nil
			for _, v in mesh.getVertices() do
				seedPos = v.position
				break
			end
			assert(seedPos)
			session.SelectVerticesNear({ seedPos })
			t.expect(countDict(session.GetSelectedVertices())).toBe(1)
			settings.Mode = "Move"
			settings.InfluenceRadius = 8

			-- The influence outline must cover the radius region, not just the one
			-- discovered triangle around the selected vertex.
			local outline = session.GetOutlineTriangleIds()
			t.expect(#outline > 10).toBeTruthy()
		end)
	end)

end
