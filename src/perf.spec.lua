--!strict

-- Guards the undo/redo rediscovery fast path. On undo, rediscoverMesh() clears
-- the in-memory mesh and rebuilds the WHOLE connected mesh via
-- discoverRegion(everyVertexPosition, math.huge). That unbounded path used to
-- issue one workspace GetPartBoundsInRadius per vertex (plus three more per part
-- inside discoverPart) -- O(n) spatial queries that made undo take ~1.7s on a
-- 40x40 grid. It now resolves those lookups against a single bulk query indexed
-- by corner, in memory. This test rebuilds a large mesh that way and asserts the
-- result is identical to the live mesh (same triangles, still manifold) and that
-- the rebuild stays far below the old per-vertex-query cost.
--
-- Also guards the interactive hover -> select -> drag -> undo flow on a large
-- mesh with a large influence radius (the flow that most needs to stay fast).

local TestTypes = require("./TestTypes")
local createPolyMapSession = require("./createPolyMapSession")
local createTriangleMesh = require("./TriangleMesh")
local Settings = require("./Settings")

local kCameraEye = Vector3.new(7000, 30, 60)
local kCameraTarget = Vector3.new(7000, 0, 40)
local kRegionCenter = Vector3.new(7000, 0, 40)

local function makeSettings(width: number, height: number): Settings.PolyMapSettings
	return {
		WindowPosition = Vector2.new(24, 24),
		WindowAnchor = Vector2.zero,
		WindowHeightDelta = 0,
		HaveHelp = true,
		DoneTutorial = true,

		Mode = "Move",
		ShowDiscoveredVertices = false,
		DiscoveredVertexSize = 0.4,
		MultiuserSupport = false,
		DeleteTarget = "Face",
		DeleteRadius = 0,
		PaintRadius = 0,
		Thickness = 0.2,
		MatchThickness = true,
		AddNonSnapped = "Extend",
		InfluenceRadius = 0,
		InfluenceFalloff = "Smooth",
		GridType = "Square",
		GridWidth = width,
		GridHeight = height,
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
		HealSameColor = false,
		HealSameMaterial = false,
		ConvertTopShellOnly = true,
		ConvertDeleteOriginal = true,
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

-- Count edges shared by more than two triangles: a grid surface is a
-- manifold-with-boundary, so anything higher is phantom/duplicated geometry.
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

return function(t: TestTypes.TestContext)
	local function sweepRegion()
		for _, p in workspace:GetPartBoundsInRadius(kRegionCenter, 600) do
			if p:IsA("BasePart") then
				p:Destroy()
			end
		end
	end

	t.test("unbounded rebuild rediscovers a large mesh correctly and quickly", function()
		local cam = workspace.CurrentCamera
		local savedCF = if cam then cam.CFrame else nil
		if cam then
			cam.CFrame = CFrame.lookAt(kCameraEye, kCameraTarget)
		end
		sweepRegion()

		-- 32x32 grid ~= 1089 vertices / 2048 triangles. The old rebuild measured
		-- ~1.1s here (one workspace query per vertex, plus three per part inside
		-- discoverPart); routing discoverPart's merge search through an in-memory
		-- corner index brings it to ~0.4s.
		local settings = makeSettings(32, 32)
		local session = createPolyMapSession(t.plugin, settings)
		local mesh = session.GetMesh()

		local ok, err = pcall(function()
			session.GenerateGrid()
			-- GenerateGrid only discovers a disc around the centre; seed an
			-- unbounded walk from everything so the WHOLE grid is in the mesh.
			local seeds0: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(seeds0, v.position)
			end
			mesh.discoverRegion(seeds0, math.huge)

			local originalTriCount = countDict(mesh.getTriangles())
			t.expect(originalTriCount > 1500).toBeTruthy()
			t.expect(nonManifoldEdges(mesh)).toBe(0)

			-- The undo hot path: seed from every live vertex, clear, rebuild.
			local seedsAll: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(seedsAll, v.position)
			end

			mesh.clear()
			local t0 = os.clock()
			mesh.discoverRegion(seedsAll, math.huge)
			local elapsedMs = (os.clock() - t0) * 1000

			-- Correctness: the rebuild must reproduce the mesh exactly. This is the
			-- real guard on discoverPart's in-memory merge resolver -- if it ever
			-- diverged from the workspace-query merge, the count/manifold would move.
			t.expect(countDict(mesh.getTriangles())).toBe(originalTriCount)
			t.expect(nonManifoldEdges(mesh)).toBe(0)

			-- Perf guard: must stay well under the old ~1.1s cost. Generous so
			-- machine variance never makes it flaky, but low enough to catch a
			-- regression back to a workspace query per part inside discoverPart.
			t.expect(elapsedMs < 900).toBeTruthy()
		end)

		session.Destroy()
		sweepRegion()
		if cam and savedCF then
			cam.CFrame = savedCF
		end
		if not ok then
			error(err)
		end
	end)

	t.test("large-radius hover/drag/undo flow stays fast", function()
		local ChangeHistoryService = game:GetService("ChangeHistoryService")
		local cam = workspace.CurrentCamera
		local savedCF = if cam then cam.CFrame else nil
		if cam then
			cam.CFrame = CFrame.lookAt(Vector3.new(7000, 220, 40), kCameraTarget)
		end
		sweepRegion()
		ChangeHistoryService:ResetWaypoints()

		local settings = makeSettings(40, 40)
		settings.InfluenceRadius = 60
		local session = createPolyMapSession(t.plugin, settings)
		local mesh = session.GetMesh()

		local ok, err = pcall(function()
			session.GenerateGrid()
			local seeds: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				table.insert(seeds, v.position)
			end
			mesh.discoverRegion(seeds, math.huge)

			local camera = workspace.CurrentCamera :: Camera
			local function screenAt(world: Vector3): Vector2
				local p = camera:WorldToViewportPoint(world)
				return Vector2.new(p.X, p.Y)
			end

			-- A marquee-sized selection (everything within 40 studs of centre).
			local bigSel: { Vector3 } = {}
			for _, v in mesh.getVertices() do
				local d = v.position - kRegionCenter
				if Vector3.new(d.X, 0, d.Z).Magnitude < 40 then
					table.insert(bigSel, v.position)
				end
			end
			session.SelectVerticesNear(bigSel)
			t.expect(session.GetSelectedVertexCount() > 200).toBeTruthy()

			-- Hover across the mesh, recomputing the overlay props each frame as a
			-- render would. Was ~75ms/frame (region re-discovery per frame); now the
			-- probed-clean memo and outline caches keep it a few ms.
			local N = 20
			local t0 = os.clock()
			for i = 1, N do
				session.DebugHoverAt(screenAt(kRegionCenter + Vector3.new((i - N / 2) * 3, 0, 0)))
				local _a = session.GetOutlineTriangleIds()
				local _b = session.GetHoverOutlineTriangleIds()
			end
			local hoverMs = (os.clock() - t0) / N * 1000
			t.expect(hoverMs < 25).toBeTruthy()

			-- Drag the selection with influence. Was ~450ms/frame (each triangle
			-- rebuilt once per moved corner); batching keeps it well under 200.
			session.StartHandleDrag()
			t0 = os.clock()
			for i = 1, N do
				session.ApplyHandleDrag(Vector3.new(0, i * 0.1, 0))
				local _a = session.GetOutlineTriangleIds()
			end
			local dragMs = (os.clock() - t0) / N * 1000
			session.EndHandleDrag()
			t.expect(dragMs < 250).toBeTruthy()

			-- Undo the move: the bounded restore re-discovers only the moved region.
			-- Was ~10s (workspace queries per corner, quadratic seed scans).
			task.wait()
			t0 = os.clock()
			ChangeHistoryService:Undo()
			task.wait()
			task.wait()
			local undoMs = (os.clock() - t0) * 1000
			t.expect(session.GetRediscoverCount()).toBe(0)
			t.expect(undoMs < 3000).toBeTruthy()
		end)

		session.Destroy()
		ChangeHistoryService:ResetWaypoints()
		sweepRegion()
		if cam and savedCF then
			cam.CFrame = savedCF
		end
		if not ok then
			error(err)
		end
	end)

	-- A/B analysis of the part-watching (Team Create staleness) overhead: build one
	-- large mesh's worth of parts, then discover and bulk-drag them through a raw
	-- TriangleMesh with watching off vs on, printing where the time goes. The
	-- assertions are deliberately loose (this is an analysis harness first, a
	-- regression tripwire second).
	t.test("part watching: connection and self-filter overhead stays modest", function()
		local cam = workspace.CurrentCamera
		local savedCF = if cam then cam.CFrame else nil
		if cam then
			cam.CFrame = CFrame.lookAt(kCameraEye, kCameraTarget)
		end
		sweepRegion()

		-- 32x32 grid ~= 2048 triangles / ~2-4k wedge parts.
		local settings = makeSettings(32, 32)
		local session = createPolyMapSession(t.plugin, settings)
		local buildMesh = session.GetMesh()
		local sessionDestroyed = false

		local ok, err = pcall(function()
			session.GenerateGrid()
			local seeds: { Vector3 } = {}
			for _, v in buildMesh.getVertices() do
				table.insert(seeds, v.position)
			end
			buildMesh.discoverRegion(seeds, math.huge)
			table.clear(seeds)
			for _, v in buildMesh.getVertices() do
				table.insert(seeds, v.position)
			end
			local expectTris = countDict(buildMesh.getTriangles())
			t.expect(expectTris > 1500).toBeTruthy()
			session.Destroy() -- the parts stay in the world
			sessionDestroyed = true

			local kDragFrames = 5
			local function measure(watch: boolean)
				local mem0 = gcinfo()
				local mesh = createTriangleMesh(0.2, watch)
				local t0 = os.clock()
				mesh.discoverRegion(seeds, math.huge)
				local discoverMs = (os.clock() - t0) * 1000
				local memKb = gcinfo() - mem0
				t.expect(countDict(mesh.getTriangles())).toBe(expectTris)

				-- Whole-mesh drag: rebuilds every part in place each frame (the worst
				-- realistic stress for the self-touch stamping and event volume).
				t0 = os.clock()
				for _ = 1, kDragFrames do
					local moves: { [number]: Vector3 } = {}
					for vid, v in mesh.getVertices() do
						moves[vid] = v.position + Vector3.new(0, 0.05, 0)
					end
					mesh.moveVertices(moves, 0.2, nil)
				end
				local dragMs = (os.clock() - t0) / kDragFrames * 1000

				-- The timed loop never yields, so (with deferred signals) every Changed
				-- event it queued delivers during the frames right after it. Timing
				-- those frames captures the event-delivery cost the loop timing can't.
				t0 = os.clock()
				task.wait()
				task.wait()
				local settleMs = (os.clock() - t0) * 1000

				local stats = mesh.debugGetWatchStats()

				-- Put the mesh back where it started: the next measurement discovers
				-- from the same seed positions, which must still be part corners.
				local restore: { [number]: Vector3 } = {}
				for vid, v in mesh.getVertices() do
					restore[vid] = v.position - Vector3.new(0, 0.05 * kDragFrames, 0)
				end
				mesh.moveVertices(restore, 0.2, nil)

				mesh.clear()
				task.wait() -- let the final sweep run before the next measurement
				return {
					discoverMs = discoverMs,
					dragMs = dragMs,
					settleMs = settleMs,
					memKb = memKb,
					stats = stats,
				}
			end

			local off = measure(false)
			local on = measure(true)

			local okSb, signalBehavior = pcall(function()
				return tostring((workspace :: any).SignalBehavior)
			end)
			t.log(string.format(
				"[PartWatch perf] SignalBehavior=%s, %d triangles, %d watched parts",
				if okSb then signalBehavior else "unknown", expectTris, on.stats.watchedParts
			))
			t.log(string.format(
				"[PartWatch perf] discover: off=%.1fms on=%.1fms (+%.1fms, %.2fus/part connect)",
				off.discoverMs, on.discoverMs, on.discoverMs - off.discoverMs,
				(on.discoverMs - off.discoverMs) * 1000 / math.max(1, on.stats.connects)
			))
			t.log(string.format(
				"[PartWatch perf] whole-mesh drag frame: off=%.1fms on=%.1fms (+%.1fms)",
				off.dragMs, on.dragMs, on.dragMs - off.dragMs
			))
			t.log(string.format(
				"[PartWatch perf] post-drag settle: off=%.1fms on=%.1fms; events=%d selfDropped=%d external=%d",
				off.settleMs, on.settleMs, on.stats.events, on.stats.selfDropped, on.stats.externalParts
			))
			t.log(string.format(
				"[PartWatch perf] discovery memory: off=%dKB on=%dKB (+%dKB, ~%dB/part; rough, GC noise)",
				off.memKb, on.memKb, on.memKb - off.memKb,
				math.floor((on.memKb - off.memKb) * 1024 / math.max(1, on.stats.watchedParts))
			))

			-- Watching disabled must be entirely inert.
			t.expect(off.stats.connects).toBe(0)
			t.expect(off.stats.events).toBe(0)
			-- Every part of the discovered mesh is being watched, and none of our own
			-- edits leaked through as an external change.
			t.expect(on.stats.watchedParts > 1500).toBeTruthy()
			t.expect(on.stats.externalParts).toBe(0)
			-- Loose regression bounds: connecting shouldn't dominate discovery, and
			-- stamping shouldn't dominate a drag frame.
			t.expect(on.discoverMs < off.discoverMs * 3 + 500).toBeTruthy()
			t.expect(on.dragMs < off.dragMs * 2 + 150).toBeTruthy()
		end)

		if not sessionDestroyed then
			session.Destroy()
		end
		sweepRegion()
		if cam and savedCF then
			cam.CFrame = savedCF
		end
		if not ok then
			error(err)
		end
	end)
end
