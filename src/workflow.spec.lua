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
		ShowDiscoveredVertices = false,
		DiscoveredVertexSize = 0.4,
		DeleteTarget = "Face",
		DeleteRadius = 0,
		PaintRadius = 0,
		Thickness = 0.2,
		MatchThickness = true,
		AddNonSnapped = "Extend",
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
		PaintMaterialVariant = "",
		PaintStrength = 1.0,
		PaintTarget = "Both",
		PaintEyedropper = "None",
		RelaxRadius = 5,
		RelaxStrength = 0.5,
		FlattenRadius = 5,
		FlattenStrength = 0.5,
		HealRadius = 5,
		HealTolerance = 1,
		ImportImageId = "",
		ImportWidth = 50,
		ImportHeight = 50,
		ImportSpacing = 4,
		ImportMinY = 0,
		ImportMaxY = 50,
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
			-- Parts are parented into PolyMapMesh folders now; drop the empties left
			-- behind so they don't pile up across the suite.
			for _, c in workspace:GetChildren() do
				if c:IsA("Folder") and c.Name == "PolyMapMesh" and #c:GetChildren() == 0 then
					c:Destroy()
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

	t.test("Place grid: the triangular preview shows triangle edges, not square cells", function()
		withSession(function(session, mesh, settings)
			settings.GridSpacing = 8
			local c1 = kRegionCenter
			local c2 = kRegionCenter + Vector3.new(24, 0, 24)

			-- Any preview segment that varies in BOTH X and Z is a slanted triangle edge.
			local function hasDiagonal(): boolean
				local lines = session.GetGridPreviewLines()
				assert(lines)
				for _, seg in lines do
					local d = seg[2] - seg[1]
					if math.abs(d.X) > 0.1 and math.abs(d.Z) > 0.1 then
						return true
					end
				end
				return false
			end

			-- Square: every preview line is axis-aligned (the cell grid).
			settings.GridType = "Square"
			session.StartGridPlacement()
			session.PlaceGridClickAt(c1)
			session.SetGridHover(c2)
			t.expect(hasDiagonal()).toBe(false)

			-- Triangular: the slanted triangle edges appear as diagonals.
			settings.GridType = "Triangular"
			session.StartGridPlacement()
			session.PlaceGridClickAt(c1)
			session.SetGridHover(c2)
			t.expect(hasDiagonal()).toBe(true)
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

	t.test("Place grid: snapping a corner drops the grid a thickness so it aligns, not on top", function()
		withSession(function(session, mesh, settings)
			settings.GridType = "Square"
			settings.GridSpacing = 8
			settings.Thickness = 1

			-- G1 in empty space: the first corner does NOT snap, so the grid sits on
			-- top of its click plane (Y=0) -- discovered vertices a thickness above it.
			local a = Vector3.new(kRegionCenter.X, 0, kRegionCenter.Z)
			local b = a + Vector3.new(16, 0, 16)
			session.StartGridPlacement()
			session.PlaceGridClickAt(a)
			session.PlaceGridClickAt(b)
			local g1Count = countDict(mesh.getVertices())
			local g1Y: number? = nil
			for _, v in mesh.getVertices() do
				g1Y = v.position.Y
				break
			end
			assert(g1Y)
			-- On top: discovered a thickness above the (Y=0) click plane.
			t.expect(math.abs(g1Y - (a.Y + settings.Thickness)) < 0.05).toBeTruthy()

			-- A corner vertex of G1 and the wedge under it.
			local v = Vector3.new(b.X, g1Y, b.Z)
			assert(mesh.findVertexNear(v, 0.1))
			local hitPart: BasePart? = nil
			for _, p in workspace:GetPartBoundsInRadius(v, 2) do
				if p:IsA("Part") and p.Shape == Enum.PartType.Wedge then
					hitPart = p
					break
				end
			end
			assert(hitPart)

			-- G2: the first corner snaps onto that vertex, extending away from G1.
			session.StartGridPlacement()
			session.PlaceGridClickAt(v + Vector3.new(1, 0, 0), hitPart) -- snaps to v
			session.PlaceGridClickAt(v + Vector3.new(16, 0, 16)) -- empty space

			-- G2 added geometry, and EVERY vertex now sits at G1's level: the snapped
			-- grid dropped a thickness to align instead of stacking a thickness on top.
			t.expect(countDict(mesh.getVertices()) > g1Count).toBeTruthy()
			local minY, maxY = math.huge, -math.huge
			for _, vert in mesh.getVertices() do
				minY = math.min(minY, vert.position.Y)
				maxY = math.max(maxY, vert.position.Y)
			end
			t.expect(maxY - minY < 0.1).toBeTruthy()
			t.expect(math.abs(minY - g1Y) < 0.1).toBeTruthy()
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

	t.test("workflow: a move undo/redo re-discovers only its region, not the whole mesh", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 8
			settings.GridHeight = 8
			session.GenerateGrid()
			-- Discover the whole grid so there is plenty of geometry the fast path must leave
			-- untouched.
			local seeds: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(seeds, v.position)
			end
			mesh.discoverRegion(seeds, math.huge)
			local vertsAfter = countDict(mesh.getVertices())
			t.expect(vertsAfter > 50).toBeTruthy()

			local pickPos: Vector3? = nil
			for _, v in mesh.getVertices() do
				pickPos = v.position
				break
			end
			assert(pickPos)
			session.SelectVerticesNear({ pickPos })
			session.MoveSelectedVertices(Vector3.new(0, 6, 0))

			-- Undo, redo, undo the move -- each must take the local fast path (no full
			-- rediscovery), and the geometry/counts must round-trip.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			ChangeHistoryService:Redo()
			settle()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(mesh.findVertexNear(pickPos, 0.4)).toBeTruthy()
			t.expect(mesh.findVertexNear(pickPos + Vector3.new(0, 6, 0), 0.4) == nil).toBeTruthy()
			t.expect(countDict(mesh.getVertices())).toBe(vertsAfter)

			-- Sanity that the counter does move: undoing the (non-move) GenerateGrid falls
			-- back to a full rediscovery.
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount() > before).toBeTruthy()
		end)
	end)

	t.test("workflow: undo in the middle of a Move drag cancels it cleanly", function()
		withSession(function(session, mesh)
			session.GenerateGrid()
			local vertsAfterGen = countDict(mesh.getVertices())

			local pickPos: Vector3? = nil
			for _, v in mesh.getVertices() do
				pickPos = v.position
				break
			end
			assert(pickPos)

			-- A committed move (op A) leaves a waypoint to undo.
			session.SelectVerticesNear({ pickPos })
			session.MoveSelectedVertices(Vector3.new(0, 6, 0))
			settle()
			local movedPos = pickPos + Vector3.new(0, 6, 0)
			t.expect(mesh.findVertexNear(movedPos, 0.4)).toBeTruthy()

			-- Start a NEW handle drag (op B) and drive it partway, but DON'T end it.
			session.SelectVerticesNear({ movedPos })
			session.StartHandleDrag()
			session.ApplyHandleDrag(Vector3.new(0, 5, 0))
			t.expect(session.IsHandleDragging()).toBe(true)

			-- Undo while the drag is still in progress.
			pcall(function()
				ChangeHistoryService:Undo()
			end)
			settle()

			-- The drag was abandoned; ending it now is a harmless no-op.
			t.expect(session.IsHandleDragging()).toBe(false)
			session.EndHandleDrag()
			settle()

			-- The undo reverted op A (vertex back at origin) and the interrupted drag
			-- left no corrupt or leaked geometry (vertex count back to the grid's).
			t.expect(mesh.findVertexNear(pickPos, 0.4)).toBeTruthy()
			t.expect(countDict(mesh.getVertices())).toBe(vertsAfterGen)
			t.expect(countDict(mesh.getTriangles()) > 0).toBeTruthy()
		end)
	end)

	t.test("workflow: undoing mid-drag doesn't recurse the selection sync", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 4
			settings.GridHeight = 4
			session.GenerateGrid()

			local pickPos: Vector3? = nil
			for _, v in mesh.getVertices() do
				pickPos = v.position
				break
			end
			assert(pickPos)

			-- A committed move leaves a waypoint to undo, then start a handle drag and drive
			-- it partway without ending it.
			session.SelectVerticesNear({ pickPos })
			session.MoveSelectedVertices(Vector3.new(0, 6, 0))
			settle()
			local movedPos = pickPos + Vector3.new(0, 6, 0)
			session.SelectVerticesNear({ movedPos })
			session.StartHandleDrag()
			session.ApplyHandleDrag(Vector3.new(0, 5, 0))
			t.expect(session.IsHandleDragging()).toBe(true)

			-- Stand in for the live dragger, which while its drag is still physically active
			-- answers each SelectionChanged by firing the change signal again. Installed now,
			-- mid-drag, so it only starts feeding back once the undo clears the dragging flag
			-- -- exactly the live crash. The < 100 cap keeps a regressed build from looping
			-- forever in the test rather than failing.
			local selectionChanged = session.GetSelectionChangedSignal()
			local syncs = 0
			local conn = selectionChanged:Connect(function()
				syncs += 1
				if syncs < 100 then
					session.ChangeSignal:Fire()
				end
			end)
			settle()
			syncs = 0

			-- Undo while the drag is still in progress. Without the re-entrancy guard the
			-- feedback recurses through task.defer until Studio aborts it; with it, the sync
			-- collapses to one.
			pcall(function()
				ChangeHistoryService:Undo()
			end)
			settle()
			conn:Disconnect()

			t.expect(syncs >= 1).toBeTruthy() -- the sync ran
			t.expect(syncs < 5).toBeTruthy() -- but didn't snowball
		end)
	end)

	t.test("workflow: releasing the mouse after a marquee clears the box and re-renders", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Move"
			-- A marquee box is showing (start + end set), as during a live drag.
			session.DebugSetMarquee(Vector2.new(20, 20), Vector2.new(120, 90))
			local s, e = session.GetMarquee()
			t.expect(s ~= nil and e ~= nil).toBeTruthy()

			-- Mouse-up must both clear the box and fire a change so the UI re-renders without
			-- it -- otherwise the box lingers until the next mouse motion happens to re-render.
			local renders = 0
			local conn = session.ChangeSignal:Connect(function()
				renders += 1
			end)
			session.DebugReleasePointer()
			conn:Disconnect()

			local s2, e2 = session.GetMarquee()
			t.expect(s2 == nil).toBeTruthy()
			t.expect(e2 == nil).toBeTruthy()
			t.expect(renders >= 1).toBeTruthy()
		end)
	end)

	t.test("workflow: undo while placing a grid cancels the placement", function()
		withSession(function(session, mesh, settings)
			settings.GridType = "Square"
			settings.GridSpacing = 8
			session.GenerateGrid() -- a committed op to undo
			settle()

			-- Begin interactive grid placement and drop the first corner.
			session.StartGridPlacement()
			session.PlaceGridClickAt(kRegionCenter)
			t.expect(session.IsPlacingGrid()).toBe(true)

			-- An undo mid-placement abandons the placement (not just the prior op).
			pcall(function()
				ChangeHistoryService:Undo()
			end)
			settle()
			t.expect(session.IsPlacingGrid()).toBe(false)
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

	t.test("workflow: paint undo/redo never rediscovers the mesh", function()
		withSession(function(session, mesh, settings)
			session.GenerateGrid()
			local paintPos: Vector3? = nil
			local paintPart: BasePart? = nil
			for _, tri in mesh.getTriangles() do
				local p1 = mesh.getVertex(tri.vertices[1])
				local p2 = mesh.getVertex(tri.vertices[2])
				local p3 = mesh.getVertex(tri.vertices[3])
				if p1 and p2 and p3 then
					paintPos = (p1.position + p2.position + p3.position) / 3
					paintPart = tri.parts[1]
					break
				end
			end
			assert(paintPos and paintPart)
			local origColor = (paintPart :: BasePart).Color
			settings.PaintColor = { 1, 0, 0 }
			settings.PaintTarget = "Color"
			session.PaintAt(paintPos)

			-- Paint changes no topology, so its undo and redo must do zero rediscovery.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(colorsClose((paintPart :: BasePart).Color, origColor)).toBeTruthy()
			ChangeHistoryService:Redo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(colorsClose((paintPart :: BasePart).Color, Color3.new(1, 0, 0))).toBeTruthy()
		end)
	end)

	t.test("workflow: a flatten stroke undo re-discovers only its region", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 8
			settings.GridHeight = 8
			session.GenerateGrid()
			local seeds: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(seeds, v.position)
			end
			mesh.discoverRegion(seeds, math.huge)
			local vertsAfter = countDict(mesh.getVertices())
			t.expect(vertsAfter > 50).toBeTruthy()

			-- The vertex nearest the centroid is interior (neighbours all around).
			local sum = Vector3.zero
			local n = 0
			for _, v in mesh.getVertices() do
				sum += v.position
				n += 1
			end
			local centroid = sum / n
			local bumpPos: Vector3? = nil
			local bestD = math.huge
			for _, v in mesh.getVertices() do
				local d = (v.position - centroid).Magnitude
				if d < bestD then
					bestD = d
					bumpPos = v.position
				end
			end
			assert(bumpPos)

			-- Bump it up, then flatten the region (Y-smoothing pulls it back down).
			session.SelectVerticesNear({ bumpPos })
			session.MoveSelectedVertices(Vector3.new(0, 5, 0))
			local bumped = (bumpPos :: Vector3) + Vector3.new(0, 5, 0)
			t.expect(mesh.findVertexNear(bumped, 0.4)).toBeTruthy()

			settings.Mode = "Flatten"
			settings.FlattenRadius = 16
			settings.FlattenStrength = 1
			session.DebugFlattenStroke({ bumped })
			t.expect(mesh.findVertexNear(bumped, 0.4) == nil).toBeTruthy() -- flattened away from Y=5

			-- Undo the flatten: the bump returns, with no full rediscovery.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(mesh.findVertexNear(bumped, 0.4)).toBeTruthy()
			t.expect(countDict(mesh.getVertices())).toBe(vertsAfter)
		end)
	end)

	t.test("workflow: Add undo/redo (incl. back-to-back) re-discovers only the added region", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 6
			settings.GridHeight = 6
			settings.GridSpacing = 4
			session.GenerateGrid()
			local seeds: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(seeds, v.position)
			end
			mesh.discoverRegion(seeds, math.huge)
			local baseTris = countDict(mesh.getTriangles())
			local baseVerts = countDict(mesh.getVertices())
			t.expect(baseTris > 30).toBeTruthy()

			-- Add a triangle off the current first boundary edge, pointing outward.
			local function addOne(): Vector3
				local sum = Vector3.zero
				local cnt = 0
				for _, v in mesh.getVertices() do
					sum += v.position
					cnt += 1
				end
				local centroid = sum / cnt
				local be = mesh.getBoundaryEdges()[1]
				local bv1 = mesh.getVertex(be.v1)
				local bv2 = mesh.getVertex(be.v2)
				assert(bv1 and bv2)
				local edgeMid = (bv1.position + bv2.position) / 2
				local outward = edgeMid - centroid
				outward = Vector3.new(outward.X, 0, outward.Z)
				outward = if outward.Magnitude < 0.01 then Vector3.xAxis else outward.Unit
				local apex = edgeMid + outward * settings.GridSpacing
				local tid = session.AddTriangleOffEdge(edgeMid, apex)
				t.expect(tid).toBeTruthy()
				return apex
			end

			local apex1 = addOne()
			t.expect(mesh.findVertexNear(apex1, 0.5)).toBeTruthy()

			-- Undo: triangle gone, no full rediscovery.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(mesh.findVertexNear(apex1, 0.5) == nil).toBeTruthy()
			t.expect(countDict(mesh.getTriangles())).toBe(baseTris)
			t.expect(countDict(mesh.getVertices())).toBe(baseVerts)

			-- Redo: triangle back, still no full rediscovery.
			ChangeHistoryService:Redo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(mesh.findVertexNear(apex1, 0.5)).toBeTruthy()

			-- Back-to-back: add two more, then undo all three in a row. Each undo is a local
			-- region re-discovery -- none triggers a whole-mesh rebuild.
			addOne()
			addOne()
			t.expect(countDict(mesh.getTriangles())).toBe(baseTris + 3)
			local before3 = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			ChangeHistoryService:Undo()
			settle()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before3)
			t.expect(countDict(mesh.getTriangles())).toBe(baseTris)
			t.expect(countDict(mesh.getVertices())).toBe(baseVerts)
		end)
	end)

	t.test("workflow: interactive Add undo/redo re-discovers only the added region", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 8 -- long edges, so the midpoint is clear of vertex snap
			session.GenerateGrid()
			settings.Mode = "Add"
			settings.Thickness = 1
			local baseTris = countDict(mesh.getTriangles())
			t.expect(baseTris > 0).toBeTruthy()

			-- Drive Add the way a user clicks: place an apex out in space, then click an
			-- existing boundary edge to close a triangle onto it (the interactive handler,
			-- not the programmatic AddTriangleOffEdge hook).
			local boundary = mesh.getBoundaryEdges()
			local edge = boundary[1]
			local a = mesh.getVertex(edge.v1)
			local b = mesh.getVertex(edge.v2)
			local tri = mesh.getTriangle(edge.triangles[1])
			assert(a and b and tri)
			local part = tri.parts[1]
			local edgeMid = (a.position + b.position) / 2

			local sum, cnt = Vector3.zero, 0
			for _, vv in mesh.getVertices() do
				sum += vv.position
				cnt += 1
			end
			local outward = (edgeMid - sum / cnt) * Vector3.new(1, 0, 1)
			outward = if outward.Magnitude > 0.1 then outward.Unit else Vector3.new(1, 0, 0)
			local apex = edgeMid + outward * 5

			session.AddClickAt(apex, nil)
			session.AddClickAt(edgeMid, part)
			t.expect(countDict(mesh.getTriangles())).toBe(baseTris + 1)

			-- Undo: the added triangle is forgotten and only its region re-discovered, with
			-- no whole-mesh rebuild.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(countDict(mesh.getTriangles())).toBe(baseTris)

			-- Redo: triangle back, still no full rediscovery.
			ChangeHistoryService:Redo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(countDict(mesh.getTriangles())).toBe(baseTris + 1)
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

	t.test("Add: a fresh disconnected triangle lifts a thickness above the click plane", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Add"
			settings.Thickness = 1
			local p1 = kRegionCenter + Vector3.new(0, 0, 0)
			local p2 = kRegionCenter + Vector3.new(12, 0, 0)
			local p3 = kRegionCenter + Vector3.new(0, 0, 12)

			session.AddClickAt(p1, nil)
			-- The preview shows the corner at the cursor; the lift is applied at commit.
			t.expect(session.GetAddPoints()[1].Y).toBe(p1.Y)
			session.AddClickAt(p2, nil)
			session.AddClickAt(p3, nil)

			-- Nothing snapped: the whole triangle rises a thickness so it rests ABOVE the
			-- click plane (its face-up wedge hangs down to the plane) instead of below it.
			t.expect(countDict(mesh.getTriangles())).toBe(1)
			t.expect(mesh.findVertexNear(p1 + Vector3.yAxis, 0.1) ~= nil).toBeTruthy()
			t.expect(mesh.findVertexNear(p2 + Vector3.yAxis, 0.1) ~= nil).toBeTruthy()
			t.expect(mesh.findVertexNear(p3 + Vector3.yAxis, 0.1) ~= nil).toBeTruthy()
			t.expect(mesh.findVertexNear(p1, 0.1) == nil).toBeTruthy()
		end)
	end)

	t.test("Add: a fresh corner that snaps to a vertex sits flush, not lifted", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			session.GenerateGrid()
			settings.Mode = "Add"
			settings.Thickness = 1
			local vertsBefore = countDict(mesh.getVertices())

			local v: Vector3? = nil
			for _, vert in mesh.getVertices() do
				v = vert.position
				break
			end
			assert(v)

			-- Two corners far out in empty space, and one over empty space 1 stud off the
			-- existing vertex -- close enough to snap onto it.
			local p1 = v + Vector3.new(40, 0, 0)
			local p3 = v + Vector3.new(40, 0, 40)
			session.AddClickAt(p1, nil)
			session.AddClickAt(v + Vector3.new(1, 0, 0), nil) -- snaps to v
			session.AddClickAt(p3, nil)

			-- The snapped corner reused the existing vertex (only p1 and p3 are new), and
			-- did NOT lift to sit a thickness above it.
			t.expect(countDict(mesh.getVertices())).toBe(vertsBefore + 2)
			t.expect(mesh.findVertexNear(v + Vector3.new(1, 1, 0), 0.1) == nil).toBeTruthy()
		end)
	end)

	t.test("Add: place an apex then click an existing edge to extend it (either order)", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 8 -- long edges, so the midpoint is clear of vertex snap
			session.GenerateGrid()
			settings.Mode = "Add"
			settings.Thickness = 1
			local before = countDict(mesh.getTriangles())
			t.expect(before > 0).toBeTruthy()

			-- A boundary edge, the part backing it, its midpoint, and the grid's height.
			local boundary = mesh.getBoundaryEdges()
			t.expect(#boundary > 0).toBeTruthy()
			local edge = boundary[1]
			local a = mesh.getVertex(edge.v1)
			local b = mesh.getVertex(edge.v2)
			local tri = mesh.getTriangle(edge.triangles[1])
			assert(a and b and tri)
			local part = tri.parts[1]
			local edgeMid = (a.position + b.position) / 2
			local gridY = a.position.Y

			-- An apex out past the edge, raised well off the grid plane to prove it gets
			-- dropped onto that plane when the edge closes.
			local sum, cnt = Vector3.zero, 0
			for _, vv in mesh.getVertices() do
				sum += vv.position
				cnt += 1
			end
			local outward = (edgeMid - sum / cnt) * Vector3.new(1, 0, 1)
			outward = if outward.Magnitude > 0.1 then outward.Unit else Vector3.new(1, 0, 0)
			local apex = edgeMid + outward * 5 + Vector3.new(0, 6, 0)

			-- Apex FIRST, then the edge -- the order the user said was broken.
			session.AddClickAt(apex, nil)
			t.expect(countDict(mesh.getTriangles())).toBe(before) -- nothing committed yet
			t.expect(#session.GetAddPoints()).toBe(1)
			session.AddClickAt(edgeMid, part)

			-- One triangle was added, the in-progress state cleared, the apex dropped onto
			-- the grid plane (coplanar extension, not left floating 6 studs up), and the
			-- edge is now shared rather than on the boundary.
			t.expect(countDict(mesh.getTriangles())).toBe(before + 1)
			t.expect(#session.GetAddPoints()).toBe(0)
			t.expect(mesh.findVertexNear(Vector3.new(apex.X, gridY, apex.Z), 0.3) ~= nil).toBeTruthy()
			t.expect(mesh.findVertexNear(apex, 0.3) == nil).toBeTruthy()
		end)
	end)

	-- Thickness of whatever triangle reaches `pos`, or nil. The new Add triangle is the
	-- only one out at its far corner, so this identifies it among the existing grid.
	local function triThicknessAt(mesh: any, pos: Vector3): number?
		for _, tri in mesh.getTriangles() do
			for _, vid in tri.vertices do
				local vert = mesh.getVertex(vid)
				if vert and (vert.position - pos).Magnitude < 0.3 then
					return tri.thickness
				end
			end
		end
		return nil
	end

	-- Y of the (unique) vertex at the given X/Z, ignoring height, or nil.
	local function vertexYAt(mesh: any, x: number, z: number): number?
		for _, v in mesh.getVertices() do
			if math.abs(v.position.X - x) < 0.3 and math.abs(v.position.Z - z) < 0.3 then
				return v.position.Y
			end
		end
		return nil
	end

	-- A standalone, clearly TILTED triangle whose plane is y = z - (kRegionCenter.Z),
	-- plus its horizontal base edge (both ends at y=0) and the part backing it. Used to
	-- tell Flat (apex at the edge height) from Extend (apex following the tilt) apart.
	local function makeTiltedTriangle(session: any, mesh: any)
		local v1 = kRegionCenter + Vector3.new(0, 0, 0)
		local v2 = kRegionCenter + Vector3.new(8, 0, 0)
		local v3 = kRegionCenter + Vector3.new(4, 8, 8)
		mesh.addTriangle(v1, v2, v3, 1, workspace.Terrain, nil, kRegionCenter + Vector3.new(4, 20, 0))
		local edge, a, b
		for _, ee in mesh.getBoundaryEdges() do
			local ea, eb = mesh.getVertex(ee.v1), mesh.getVertex(ee.v2)
			if ea and eb and math.abs(ea.position.Y) < 0.1 and math.abs(eb.position.Y) < 0.1 then
				edge, a, b = ee, ea, eb
				break
			end
		end
		assert(edge and a and b)
		local part = mesh.getTriangle(edge.triangles[1]).parts[1]
		return part, (a.position + b.position) / 2
	end

	t.test("Add: Extend places a non-snapped apex in the snapped triangle's plane", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Add"
			settings.MatchThickness = false
			settings.AddNonSnapped = "Extend"
			local part, edgeMid = makeTiltedTriangle(session, mesh)

			-- Apex out past the edge in +Z (so the tilt matters), then close onto it.
			local apexXZ = kRegionCenter + Vector3.new(4, 0, 16) -- (X, _, Z=center.Z+16)
			session.AddClickAt(apexXZ + Vector3.new(0, 5, 0), nil)
			session.AddClickAt(edgeMid, part)

			-- The plane is y = z - center.Z, so at apexXZ.Z the apex sits 16 high.
			local apexY = vertexYAt(mesh, apexXZ.X, apexXZ.Z)
			assert(apexY)
			t.expect(math.abs(apexY - 16) < 0.3).toBeTruthy()
		end)
	end)

	t.test("Add: Flat places a non-snapped apex level with the edge, not following the tilt", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Add"
			settings.MatchThickness = false
			settings.AddNonSnapped = "Flat"
			local part, edgeMid = makeTiltedTriangle(session, mesh)

			local apexXZ = kRegionCenter + Vector3.new(4, 0, 16)
			session.AddClickAt(apexXZ + Vector3.new(0, 5, 0), nil)
			session.AddClickAt(edgeMid, part)

			-- Flat keeps the apex level with the (horizontal, y=0) edge, not at y=16.
			local apexY = vertexYAt(mesh, apexXZ.X, apexXZ.Z)
			assert(apexY)
			t.expect(math.abs(apexY - 0) < 0.3).toBeTruthy()
		end)
	end)

	t.test("Add: MatchThickness gives a snapped triangle the existing geometry's thickness", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			settings.Thickness = 2
			session.GenerateGrid() -- grid triangles built at thickness 2
			settings.Mode = "Add"
			settings.MatchThickness = true
			settings.Thickness = 0.5 -- fallback, deliberately different from the grid

			local v: Vector3? = nil
			for _, vert in mesh.getVertices() do
				v = vert.position
				break
			end
			assert(v)

			-- Two corners out in empty space, the third snapping onto a grid vertex.
			local p1 = v + Vector3.new(40, 0, 0)
			session.AddClickAt(p1, nil)
			session.AddClickAt(v + Vector3.new(40, 0, 40), nil)
			session.AddClickAt(v + Vector3.new(1, 0, 0), nil) -- snaps to v, commits

			-- It inherited the grid's thickness (2), not the 0.5 setting.
			local th = triThicknessAt(mesh, p1)
			assert(th)
			t.expect(math.abs(th - 2) < 0.01).toBeTruthy()
		end)
	end)

	t.test("Add: MatchThickness off uses the Thickness setting even when snapping", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			settings.Thickness = 2
			session.GenerateGrid()
			settings.Mode = "Add"
			settings.MatchThickness = false
			settings.Thickness = 0.5

			local v: Vector3? = nil
			for _, vert in mesh.getVertices() do
				v = vert.position
				break
			end
			assert(v)

			local p1 = v + Vector3.new(40, 0, 0)
			session.AddClickAt(p1, nil)
			session.AddClickAt(v + Vector3.new(40, 0, 40), nil)
			session.AddClickAt(v + Vector3.new(1, 0, 0), nil) -- snaps to v

			local th = triThicknessAt(mesh, p1)
			assert(th)
			t.expect(math.abs(th - 0.5) < 0.01).toBeTruthy()
		end)
	end)

	t.test("Add: MatchThickness matches the edge thickness when closing onto an edge", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 8 -- long edges so the midpoint clears vertex snap
			settings.Thickness = 2
			session.GenerateGrid()
			settings.Mode = "Add"
			settings.MatchThickness = true
			settings.Thickness = 0.5

			local boundary = mesh.getBoundaryEdges()
			local edge = boundary[1]
			local a = mesh.getVertex(edge.v1)
			local b = mesh.getVertex(edge.v2)
			local tri = mesh.getTriangle(edge.triangles[1])
			assert(a and b and tri)
			local part = tri.parts[1]
			local edgeMid = (a.position + b.position) / 2
			local gridY = a.position.Y

			-- Apex out past the edge (away from the grid centre), then click the edge.
			local sum, cnt = Vector3.zero, 0
			for _, vv in mesh.getVertices() do
				sum += vv.position
				cnt += 1
			end
			local outward = (edgeMid - sum / cnt) * Vector3.new(1, 0, 1)
			outward = if outward.Magnitude > 0.1 then outward.Unit else Vector3.new(1, 0, 0)
			local apex = edgeMid + outward * 5 + Vector3.new(0, 6, 0)
			session.AddClickAt(apex, nil)
			session.AddClickAt(edgeMid, part)

			-- The closing triangle (reaching the apex, dropped onto the grid plane) took
			-- the edge's thickness (2), not the 0.5 setting.
			local th = triThicknessAt(mesh, Vector3.new(apex.X, gridY, apex.Z))
			assert(th)
			t.expect(math.abs(th - 2) < 0.01).toBeTruthy()
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

			-- Seed at the camera-facing surface the way the real brush does (raycast
			-- from the pinned camera), not the grid's bottom plane at kRegionCenter.
			local hit = workspace:Raycast(kCameraEye, (kRegionCenter - kCameraEye) * 1.5)
			assert(hit)
			session.PaintAt(hit.Position)

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

	-- Build a triangle centred on `center`, lying in the plane perpendicular to the
	-- view direction D (so a ray along D hits its interior). Faces the camera.
	local function buildFacingTri(mesh: any, center: Vector3, D: Vector3)
		local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		local u = D:Cross(up).Unit
		local v = D:Cross(u).Unit
		local s = 3.5
		mesh.addTriangle(center + u * s, center - u * s + v * s, center - u * s - v * s, 1, workspace.Terrain, nil, -D)
	end

	t.test("Delete: a lingering click removes one part, not the parts behind it", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Delete"
			settings.DeleteTarget = "Face"
			settings.DeleteRadius = 0

			local cam = workspace.CurrentCamera
			assert(cam)
			-- Aim at the work region; stack two triangles along that view ray so the
			-- near one occludes the far one.
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local sp = Vector2.new(vp.X, vp.Y)
			local ray = cam:ViewportPointToRay(sp.X, sp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			buildFacingTri(mesh, O + D * 18, D) -- front (nearer the camera)
			buildFacingTri(mesh, O + D * 34, D) -- back (directly behind it)

			local before = countDict(mesh.getTriangles())
			t.expect(before).toBe(2)

			-- Linger: hit the same screen pixel 8 times, as holding a click does.
			local linger: { Vector2 } = {}
			for _ = 1, 8 do
				table.insert(linger, sp)
			end
			session.DebugDeleteStroke(linger)

			-- Only the front part went; the one behind it survived the lingering click.
			local mid = countDict(mesh.getTriangles())
			t.expect(before - mid).toBe(1)

			-- A fresh stroke at the same spot now removes the (newly frontmost) back
			-- part -- proving it was reachable along the ray, so the guard (not mere
			-- unreachability) is what spared it above.
			session.DebugDeleteStroke(linger)
			t.expect(mid - countDict(mesh.getTriangles())).toBe(1)
		end)
	end)

	t.test("Delete: dragging the cursor sweeps across and deletes multiple parts", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Delete"
			settings.DeleteTarget = "Face"
			settings.DeleteRadius = 0

			local cam = workspace.CurrentCamera
			assert(cam)
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local ray = cam:ViewportPointToRay(vp.X, vp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
			local u = D:Cross(up).Unit

			-- Three parts side by side (no occlusion), at three distinct screen spots.
			local screenPositions: { Vector2 } = {}
			for _, off in { -9, 0, 9 } do
				local center = O + D * 24 + u * off
				buildFacingTri(mesh, center, D)
				local cvp = cam:WorldToViewportPoint(center)
				table.insert(screenPositions, Vector2.new(cvp.X, cvp.Y))
			end
			t.expect(countDict(mesh.getTriangles())).toBe(3)

			-- A drag visiting each part's screen position removes all three (the
			-- cursor moves well past the guard distance between them).
			session.DebugDeleteStroke(screenPositions)
			t.expect(countDict(mesh.getTriangles())).toBe(0)
		end)
	end)

	t.test("workflow: Delete undo/redo re-discovers only the deleted region", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Delete"
			settings.DeleteTarget = "Face"
			settings.DeleteRadius = 0

			local cam = workspace.CurrentCamera
			assert(cam)
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local ray = cam:ViewportPointToRay(vp.X, vp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
			local u = D:Cross(up).Unit

			-- Three parts side by side, deleted in one drag stroke (one undo entry).
			-- Parent under workspace (not Terrain) so ChangeHistory records their removal
			-- the way it does for real PolyMapMesh folders.
			local v = D:Cross(u).Unit
			local screenPositions: { Vector2 } = {}
			for _, off in { -9, 0, 9 } do
				local center = O + D * 24 + u * off
				local s = 3.5
				mesh.addTriangle(center + u * s, center - u * s + v * s, center - u * s - v * s, 1, workspace, nil, -D)
				local cvp = cam:WorldToViewportPoint(center)
				table.insert(screenPositions, Vector2.new(cvp.X, cvp.Y))
			end
			t.expect(countDict(mesh.getTriangles())).toBe(3)
			-- Commit the freshly built geometry as the undo baseline, so undoing the delete
			-- has a prior state to restore the parts to (the live tool's geometry always
			-- comes from an already-committed waypoint; here we build it ad-hoc).
			ChangeHistoryService:SetWaypoint("delete-test-setup")

			session.DebugDeleteStroke(screenPositions)
			t.expect(countDict(mesh.getTriangles())).toBe(0)

			-- Undo: the parts come back and only the deleted region is re-discovered, no
			-- whole-mesh rebuild.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(countDict(mesh.getTriangles())).toBe(3)

			-- Redo: the parts are removed again and forgotten, still no full rebuild.
			ChangeHistoryService:Redo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(countDict(mesh.getTriangles())).toBe(0)
		end)
	end)

	t.test("Delete: a moving drag still won't punch through to a surface behind", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Delete"
			settings.DeleteTarget = "Face"
			settings.DeleteRadius = 0

			local cam = workspace.CurrentCamera
			assert(cam)
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local ray = cam:ViewportPointToRay(vp.X, vp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
			local u = D:Cross(up).Unit

			-- A near 'front' part and a 'back' part that is both deeper AND off to the
			-- side, so it lands at a different screen spot (clearing the movement
			-- guard) yet sits well behind the front surface.
			local frontCenter = O + D * 18
			local backCenter = O + D * 42 + u * 10
			buildFacingTri(mesh, frontCenter, D)
			buildFacingTri(mesh, backCenter, D)
			local fvp = cam:WorldToViewportPoint(frontCenter)
			local bvp = cam:WorldToViewportPoint(backCenter)
			local frontSp = Vector2.new(fvp.X, fvp.Y)
			local backSp = Vector2.new(bvp.X, bvp.Y)
			-- Far enough apart on screen that the movement guard alone wouldn't stop it
			-- (its threshold is 10px).
			t.expect((frontSp - backSp).Magnitude > 10).toBeTruthy()
			t.expect(countDict(mesh.getTriangles())).toBe(2)

			-- Drag from the front part to the back part. The cursor moves plenty, but
			-- the back part is far behind the surface just deleted, so the depth guard
			-- skips it -- only the front goes.
			session.DebugDeleteStroke({ frontSp, backSp })
			t.expect(countDict(mesh.getTriangles())).toBe(1)
		end)
	end)

	-- The distinct containers (folders) holding the current mesh's wedge parts.
	local function triangleFolders(mesh: any): { [Instance]: boolean }
		local set: { [Instance]: boolean } = {}
		for _, tri in mesh.getTriangles() do
			for _, part in tri.parts do
				if part.Parent then
					set[part.Parent] = true
				end
			end
		end
		return set
	end
	local function folderCount(mesh: any): number
		local n = 0
		for _ in triangleFolders(mesh) do
			n += 1
		end
		return n
	end

	t.test("Folders: a generated grid's parts go in a new workspace folder", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			session.GenerateGrid()
			t.expect(countDict(mesh.getTriangles()) > 0).toBeTruthy()
			-- Every wedge is parented into a Folder directly under workspace.
			for _, tri in mesh.getTriangles() do
				for _, part in tri.parts do
					local container = part.Parent
					t.expect(container ~= nil and container:IsA("Folder")).toBeTruthy()
					t.expect((container :: Instance).Parent == workspace).toBeTruthy()
				end
			end
			t.expect(folderCount(mesh)).toBe(1)
		end)
	end)

	t.test("Folders: separate fresh polygons each get their own folder", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Add"
			-- Fresh triangle 1 (three empty-space clicks).
			session.AddClickAt(kRegionCenter + Vector3.new(0, 0, 0), nil)
			session.AddClickAt(kRegionCenter + Vector3.new(6, 0, 0), nil)
			session.AddClickAt(kRegionCenter + Vector3.new(3, 0, 5), nil)
			-- Fresh triangle 2, far enough away to be disconnected (no snapping).
			session.AddClickAt(kRegionCenter + Vector3.new(40, 0, 0), nil)
			session.AddClickAt(kRegionCenter + Vector3.new(46, 0, 0), nil)
			session.AddClickAt(kRegionCenter + Vector3.new(43, 0, 5), nil)

			t.expect(countDict(mesh.getTriangles())).toBe(2)
			-- Two unconnected fresh pieces -> two distinct folders.
			t.expect(folderCount(mesh)).toBe(2)
		end)
	end)

	t.test("Folders: a polygon added onto existing geometry joins its folder", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			session.GenerateGrid()
			t.expect(folderCount(mesh)).toBe(1)

			-- Grab a grid boundary edge, then close it onto a fresh apex out in empty
			-- space. The new triangle is built from the grid's edge, so it joins the
			-- grid's folder rather than starting a new one.
			settings.Mode = "Add"
			local boundary = mesh.getBoundaryEdges()
			local edge = boundary[1]
			local a = mesh.getVertex(edge.v1)
			local b = mesh.getVertex(edge.v2)
			local tri = mesh.getTriangle(edge.triangles[1])
			assert(a and b and tri)
			local part = tri.parts[1]
			local edgeMid = (a.position + b.position) / 2
			local sum, cnt = Vector3.zero, 0
			for _, v in mesh.getVertices() do
				sum += v.position
				cnt += 1
			end
			local outward = Vector3.new(edgeMid.X - (sum / cnt).X, 0, edgeMid.Z - (sum / cnt).Z)
			outward = if outward.Magnitude > 0.1 then outward.Unit else Vector3.new(1, 0, 0)
			local apex = Vector3.new(edgeMid.X, edgeMid.Y, edgeMid.Z) + outward * 4

			local before = countDict(mesh.getTriangles())
			session.AddClickAt(edgeMid, part)
			session.AddClickAt(apex, nil)
			t.expect(countDict(mesh.getTriangles())).toBe(before + 1)

			-- Still one folder: the added triangle reused the grid's.
			t.expect(folderCount(mesh)).toBe(1)
		end)
	end)

	t.test("Folders: a placed grid snapped onto existing geometry reuses its folder", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			session.GenerateGrid()
			t.expect(folderCount(mesh)).toBe(1)

			local v: Vector3? = nil
			for _, vert in mesh.getVertices() do
				v = vert.position
				break
			end
			assert(v)

			-- Place a second grid whose first corner snaps onto a grid-1 vertex.
			session.StartGridPlacement()
			session.PlaceGridClickAt(v + Vector3.new(1, 0, 0)) -- snaps to v
			session.PlaceGridClickAt(v + Vector3.new(13, 0, 13)) -- empty far corner
			t.expect(countDict(mesh.getTriangles()) > 0).toBeTruthy()

			-- One folder: the placed grid joined grid 1's rather than making its own.
			t.expect(folderCount(mesh)).toBe(1)
		end)
	end)

	t.test("Place grid: snapping inherits the snapped part's colour and material", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			settings.PaintColor = { 1, 0, 0 } -- red
			settings.PaintMaterial = "Grass"
			session.GenerateGrid() -- grid 1: red grass

			local v: Vector3? = nil
			for _, vert in mesh.getVertices() do
				v = vert.position
				break
			end
			assert(v)

			-- Change the paint settings: a snapped place must NOT use these.
			settings.PaintColor = { 0, 0, 1 } -- blue
			settings.PaintMaterial = "Plastic"

			session.StartGridPlacement()
			session.PlaceGridClickAt(v + Vector3.new(1, 0, 0)) -- snaps to grid 1
			session.PlaceGridClickAt(v + Vector3.new(13, 0, 13))

			-- Every wedge matches grid 1 (red grass); none took the blue/plastic setting.
			local red = Color3.new(1, 0, 0)
			for _, tri in mesh.getTriangles() do
				for _, part in tri.parts do
					t.expect(colorsClose(part.Color, red)).toBeTruthy()
					t.expect(part.Material == Enum.Material.Grass).toBeTruthy()
				end
			end
		end)
	end)

	t.test("Paint: applies the material variant to painted parts", function()
		withSession(function(session, mesh, settings)
			settings.GridWidth = 3
			settings.GridHeight = 3
			settings.GridSpacing = 4
			session.GenerateGrid()
			t.expect(countDict(mesh.getTriangles()) > 0).toBeTruthy()

			settings.Mode = "Paint"
			settings.PaintTarget = "Material"
			settings.PaintMaterial = "Grass"
			settings.PaintMaterialVariant = "PolyMapPaintVariant"
			settings.PaintRadius = 0

			local target: Vector3? = nil
			for _, tri in mesh.getTriangles() do
				target = tri.parts[1].Position
				break
			end
			assert(target)
			session.PaintAt(target)

			-- The painted part carries both the base material and the variant.
			local found = false
			for _, p in workspace:GetPartBoundsInRadius(target, 0.5) do
				if p:IsA("BasePart") and p.MaterialVariant == "PolyMapPaintVariant" then
					found = true
					t.expect(p.Material == Enum.Material.Grass).toBeTruthy()
				end
			end
			t.expect(found).toBe(true)
		end)
	end)

	t.test("Settings: recent-material keys round-trip base material and variant", function()
		-- No variant -> the plain material name, so older saved histories still decode.
		t.expect(Settings.EncodeRecentMaterial("Grass", "")).toBe("Grass")
		local m1, v1 = Settings.DecodeRecentMaterial("Grass")
		t.expect(m1).toBe("Grass")
		t.expect(v1).toBe("")
		-- With a variant -> encodes both and decodes back.
		local key = Settings.EncodeRecentMaterial("Grass", "Mossy")
		local m2, v2 = Settings.DecodeRecentMaterial(key)
		t.expect(m2).toBe("Grass")
		t.expect(v2).toBe("Mossy")
	end)

	t.test("Paint: a stroke paints the whole hit triangle, both its wedges", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Paint"
			settings.PaintTarget = "Color"
			settings.PaintColor = { 1, 0, 0 } -- red
			settings.PaintRadius = 0

			local cam = workspace.CurrentCamera
			assert(cam)
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local ray = cam:ViewportPointToRay(vp.X, vp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			local center = O + D * 20
			buildFacingTri(mesh, center, D)

			-- Aim the click at a point clearly inside ONE wedge -- off the split seam
			-- (which runs through the centre), so the ray lands solidly on a single
			-- wedge rather than grazing the boundary between the two.
			local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
			local u = D:Cross(up).Unit
			local v = D:Cross(u).Unit
			local ivp = cam:WorldToViewportPoint(center + v * 1.2)
			local paintSp = Vector2.new(ivp.X, ivp.Y)

			-- The test triangle must be backed by TWO wedges for this to mean anything.
			local twoWedge: any = nil
			for _, tri in mesh.getTriangles() do
				if #tri.parts == 2 then
					twoWedge = tri
				end
			end
			assert(twoWedge)

			-- A single paint click -- whose ray hits ONE wedge -- must colour BOTH.
			session.DebugPaintStroke({ paintSp })

			local red = Color3.new(1, 0, 0)
			for _, part in twoWedge.parts do
				t.expect(colorsClose(part.Color, red)).toBeTruthy()
			end
		end)
	end)

	t.test("Delete/Vertex: hovering marks a vertex and outlines its triangle fan", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Delete"
			settings.DeleteTarget = "Vertex"

			local cam = workspace.CurrentCamera
			assert(cam)
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local ray = cam:ViewportPointToRay(vp.X, vp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			local center = O + D * 20
			buildFacingTri(mesh, center, D)

			-- Aim at a point clearly inside one wedge (off the split seam through the
			-- centre) so the hover raycast lands solidly on the triangle.
			local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
			local u = D:Cross(up).Unit
			local v = D:Cross(u).Unit
			local hvp = cam:WorldToViewportPoint(center + v * 1.2)
			session.DebugHoverAt(Vector2.new(hvp.X, hvp.Y))

			-- A vertex must be marked for deletion, and the outlined fan must be exactly
			-- the triangles that deleting that vertex would remove.
			local vid = session.GetHoverVertexId()
			t.expect(vid).toBeTruthy()
			assert(vid, "expected a hovered vertex in Delete/Vertex mode")
			local vertex = mesh.getVertex(vid)
			assert(vertex)

			local outline = session.GetOutlineTriangleIds()
			t.expect(#outline).toBe(#vertex.triangles)
			local outlineSet: { [number]: boolean } = {}
			for _, id in outline do
				outlineSet[id] = true
			end
			for _, id in vertex.triangles do
				t.expect(outlineSet[id]).toBeTruthy()
			end
		end)
	end)

	t.test("Delete/Vertex: hover discovers the whole fan, not just the part under the cursor", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Delete"
			settings.DeleteTarget = "Vertex"

			local cam = workspace.CurrentCamera
			assert(cam)
			local vp = cam:WorldToViewportPoint(kRegionCenter)
			local ray = cam:ViewportPointToRay(vp.X, vp.Y)
			local O, D = ray.Origin, ray.Direction.Unit
			local center = O + D * 20

			local up = if math.abs(D.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
			local u = D:Cross(up).Unit
			local v = D:Cross(u).Unit
			local s = 3.5

			-- Two separate triangles (separate parts) that meet only at `center`, so the
			-- shared vertex's fan spans BOTH parts. Each has its right angle at `center`
			-- (one wedge apiece): one opening toward +u, the other toward -u.
			mesh.addTriangle(center, center + u * s + v * s, center + u * s - v * s, 1, workspace.Terrain, nil, -D)
			mesh.addTriangle(center, center - u * s + v * s, center - u * s - v * s, 1, workspace.Terrain, nil, -D)
			t.expect(countDict(mesh.getTriangles())).toBe(2)

			-- Forget everything in memory (the workspace parts remain). This reproduces a
			-- fresh hover, where only the part directly under the cursor gets discovered.
			mesh.clear()

			-- Hover just off `center` into the +u triangle, so `center` is the nearest
			-- vertex and the ray lands solidly on one wedge (not the shared corner seam).
			local hvp = cam:WorldToViewportPoint(center + u * 1.5)
			session.DebugHoverAt(Vector2.new(hvp.X, hvp.Y))

			local vid = session.GetHoverVertexId()
			t.expect(vid).toBeTruthy()
			assert(vid, "expected a hovered vertex in Delete/Vertex mode")
			local vertex = mesh.getVertex(vid)
			assert(vertex)

			-- The outlined fan must include BOTH triangles -- the one under the cursor
			-- and its neighbour across the shared vertex -- matching what a click removes.
			-- Without the hover's region discovery only the cursor's triangle is known.
			t.expect(#vertex.triangles).toBe(2)
			t.expect(#session.GetOutlineTriangleIds()).toBe(2)
		end)
	end)

	t.test("Paint: Escape cancels an active Pick (eyedropper) mode", function()
		withSession(function(session, _mesh, settings)
			settings.Mode = "Paint"

			-- Pick Colour active -> Escape returns to normal painting, and notifies the
			-- UI (so the Pick button un-highlights).
			settings.PaintEyedropper = "Color"
			local fired = false
			local cn = session.ChangeSignal:Connect(function()
				fired = true
			end)
			session.DebugEscape()
			cn:Disconnect()
			t.expect(settings.PaintEyedropper).toBe("None")
			t.expect(fired).toBe(true)

			-- Pick Material likewise.
			settings.PaintEyedropper = "Material"
			session.DebugEscape()
			t.expect(settings.PaintEyedropper).toBe("None")

			-- With nothing being picked, Escape leaves the eyedropper setting untouched.
			settings.PaintEyedropper = "None"
			session.DebugEscape()
			t.expect(settings.PaintEyedropper).toBe("None")
		end)
	end)

	t.test("Heal: brushing a torn seam merges the loose vertices", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Heal"
			settings.HealRadius = 8
			settings.HealTolerance = 1

			-- Two triangles that should meet along a line but are torn 0.2 studs apart.
			-- Built around the swept work region so they are cleaned up afterwards.
			local base = kRegionCenter
			local up = base + Vector3.new(2, 6, 0)
			mesh.addTriangle(
				base + Vector3.new(0, 0, 0), base + Vector3.new(4, 0, 0), base + Vector3.new(2, 0, 3),
				1, workspace.Terrain, nil, up
			)
			mesh.addTriangle(
				base + Vector3.new(0, 0, -0.2), base + Vector3.new(4, 0, -0.2), base + Vector3.new(2, 0, -3),
				1, workspace.Terrain, nil, up
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

			-- Torn: six separate vertices, no shared edge.
			t.expect(countDict(mesh.getVertices())).toBe(6)
			t.expect(boundaryCount()).toBe(6)

			session.HealAt(base + Vector3.new(2, 0, -0.1))

			-- Both ends of the seam stitched: 6 -> 4 vertices, and the seam edge is now
			-- shared (interior), leaving four boundary edges.
			t.expect(countDict(mesh.getVertices())).toBe(4)
			t.expect(boundaryCount()).toBe(4)
		end)
	end)

	t.test("workflow: Heal undo/redo re-discovers only the healed region", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Heal"
			settings.HealRadius = 8
			settings.HealTolerance = 1

			-- The torn-seam setup from the merge test: two triangles 0.2 studs apart.
			local base = kRegionCenter
			local up = base + Vector3.new(2, 6, 0)
			mesh.addTriangle(
				base + Vector3.new(0, 0, 0), base + Vector3.new(4, 0, 0), base + Vector3.new(2, 0, 3),
				1, workspace, nil, up
			)
			mesh.addTriangle(
				base + Vector3.new(0, 0, -0.2), base + Vector3.new(4, 0, -0.2), base + Vector3.new(2, 0, -3),
				1, workspace, nil, up
			)
			t.expect(countDict(mesh.getVertices())).toBe(6)
			-- Commit the torn geometry as the undo baseline (the live tool always heals
			-- already-committed geometry).
			ChangeHistoryService:SetWaypoint("heal-test-setup")

			session.DebugHealStroke({ base + Vector3.new(2, 0, -0.1) })
			t.expect(countDict(mesh.getVertices())).toBe(4) -- both seam ends stitched

			-- Undo: the tear reopens, and only the healed region is re-discovered.
			local before = session.GetRediscoverCount()
			ChangeHistoryService:Undo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(countDict(mesh.getVertices())).toBe(6)

			-- Redo: stitched again, still no whole-mesh rebuild.
			ChangeHistoryService:Redo()
			settle()
			t.expect(session.GetRediscoverCount()).toBe(before)
			t.expect(countDict(mesh.getVertices())).toBe(4)
		end)
	end)

	t.test("Heal: folds a bent wedge pair into one logical triangle", function()
		withSession(function(session, mesh, settings)
			settings.Mode = "Heal"
			settings.HealRadius = 8
			settings.HealTolerance = 1

			-- Two triangles sharing edge B-F, with the foot F nudged 0.3 studs off the
			-- straight A-C edge (one wedge of a logical triangle was moved).
			local base = kRegionCenter
			local A = base + Vector3.new(0, 0, 0)
			local B = base + Vector3.new(3, 0, 4)
			local C = base + Vector3.new(6, 0, 0)
			local F = base + Vector3.new(3, 0, 0.3)
			local hint = base + Vector3.new(3, 5, 0)
			mesh.addTriangle(A, B, F, 1, workspace.Terrain, nil, hint)
			mesh.addTriangle(B, C, F, 1, workspace.Terrain, nil, hint)

			local function countDict(d: any): number
				local n = 0
				for _ in d do
					n += 1
				end
				return n
			end
			local function hasVertexNear(pos: Vector3): boolean
				for _, v in mesh.getVertices() do
					if (v.position - pos).Magnitude < 0.05 then
						return true
					end
				end
				return false
			end

			t.expect(countDict(mesh.getVertices())).toBe(4)
			t.expect(countDict(mesh.getTriangles())).toBe(2)
			t.expect(hasVertexNear(F)).toBe(true)

			session.HealAt(base + Vector3.new(3, 0, 1))

			-- The bent pair folded into one triangle, dropping the foot vertex.
			t.expect(countDict(mesh.getVertices())).toBe(3)
			t.expect(countDict(mesh.getTriangles())).toBe(1)
			t.expect(hasVertexNear(F)).toBe(false)
		end)
	end)

end
