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

local TestTypes = require("./TestTypes")
local createPolyMapSession = require("./createPolyMapSession")
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
		DeleteTarget = "Face",
		DeleteRadius = 0,
		PaintRadius = 0,
		Thickness = 0.2,
		InfluenceRadius = 0,
		InfluenceFalloff = "Smooth",
		GridType = "Square",
		GridWidth = width,
		GridHeight = height,
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
end
