--!strict

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local MeshOverlay = require("./MeshOverlay")
local VertexMarkers = require("./VertexMarkers")
local createTriangleMesh = require("./TriangleMesh")
local TestTypes = require("./TestTypes")

local e = React.createElement

local THICKNESS = 1
local SPACING = 4

-- Build a small grid of triangles and return the mesh + container folder
local function buildTestGrid(): (createTriangleMesh.TriangleMesh, Folder)
	local folder = Instance.new("Folder")
	folder.Name = "$MeshOverlayTestParts"
	folder.Parent = workspace

	local mesh = createTriangleMesh()

	-- 4x4 square grid centered at origin
	local cols, rows = 4, 4
	local halfW = cols * SPACING / 2
	local halfH = rows * SPACING / 2

	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local x0, z0 = c * SPACING - halfW, r * SPACING - halfH
			local tl = Vector3.new(x0, 0, z0)
			local tr = Vector3.new(x0 + SPACING, 0, z0)
			local bl = Vector3.new(x0, 0, z0 + SPACING)
			local br = Vector3.new(x0 + SPACING, 0, z0 + SPACING)
			mesh.addTriangle(tl, tr, bl, THICKNESS, folder, {
				Color = Color3.fromRGB(75, 151, 75),
				Material = Enum.Material.Grass,
			}, Vector3.new(0, 1, 0))
			mesh.addTriangle(tr, br, bl, THICKNESS, folder, {
				Color = Color3.fromRGB(75, 151, 75),
				Material = Enum.Material.Grass,
			}, Vector3.new(0, 1, 0))
		end
	end

	return mesh, folder
end

local function pointCameraAt(target: Vector3, distance: number, angle: number)
	local cam = workspace.CurrentCamera
	if cam then
		local offset = CFrame.Angles(math.rad(-angle), 0, 0) * Vector3.new(0, 0, distance)
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(target + offset, target)
	end
end

return function(t: TestTypes.TestContext)
	-- Clean up any leftover portal elements from previous test runs
	for _, child in CoreGui:GetChildren() do
		if child.Name == "$PolyMapOverlay" or child.Name == "$PolyMapMarquee" then
			child:Destroy()
		end
	end

	-- Set up geometry and camera once before all tests
	local mesh, folder = buildTestGrid()
	pointCameraAt(Vector3.zero, 24, 30)

	-- Persistent React root — re-render with new props each test instead of
	-- unmount/remount, so adornments update in place.
	local screen = Instance.new("ScreenGui")
	screen.Name = "$MeshOverlayTest"
	screen.Parent = CoreGui
	local root = ReactRoblox.createRoot(screen)

	local function renderOverlayAndScreenshot(
		name: string,
		overlayProps: {
			SelectedVertices: { [number]: boolean }?,
			HoverVertexId: number?,
			OutlineTriangleIds: { number }?,
			HoverOutlineTriangleIds: { number }?,
			MarqueeStart: Vector2?,
			MarqueeEnd: Vector2?,
		}
	)
		ReactRoblox.act(function()
			root:render(e(MeshOverlay, {
				Mesh = mesh,
				SelectedVertices = overlayProps.SelectedVertices,
				HoverVertexId = overlayProps.HoverVertexId,
				OutlineTriangleIds = overlayProps.OutlineTriangleIds,
				HoverOutlineTriangleIds = overlayProps.HoverOutlineTriangleIds,
				MarqueeStart = overlayProps.MarqueeStart,
				MarqueeEnd = overlayProps.MarqueeEnd,
			}))
		end)
		-- Flush useEffect then wait for 3D pipeline to render adornments
		--ReactRoblox.act(function() end)
		--waitFrames(3)

		--t.screenshot(name)

		-- CaptureService reads the framebuffer asynchronously — wait long
		-- enough for the capture to resolve before re-rendering new props.
		--waitFrames(15)
	end

	t.test("viewport: mesh with no overlay", function()
		renderOverlayAndScreenshot("Overlay_None", {})
	end)

	t.test("viewport: selected vertices", function()
		local selected: { [number]: boolean } = {}
		local vertices = mesh.getVertices()
		for id, vertex in vertices do
			if (vertex.position - Vector3.zero).Magnitude < SPACING * 1.5 then
				selected[id] = true
			end
		end
		renderOverlayAndScreenshot("Overlay_Selected", {
			SelectedVertices = selected,
		})
	end)

	t.test("viewport: hover vertex", function()
		local hoverId = mesh.findVertexNear(Vector3.zero, SPACING)
		t.expect(hoverId ~= nil).toBe(true)
		renderOverlayAndScreenshot("Overlay_Hover", {
			HoverVertexId = hoverId,
		})
	end)

	t.test("viewport: outline triangles", function()
		local centerTris = mesh.findTrianglesInRadius(Vector3.zero, SPACING * 1.2)
		t.expect(#centerTris > 0).toBe(true)
		renderOverlayAndScreenshot("Overlay_Outline", {
			OutlineTriangleIds = centerTris,
		})
	end)

	t.test("viewport: selection + hover + outline combined", function()
		local selected: { [number]: boolean } = {}
		local hoverId: number? = nil
		local vertices = mesh.getVertices()

		for id, vertex in vertices do
			local dist = (vertex.position - Vector3.zero).Magnitude
			if dist < SPACING * 1.0 then
				selected[id] = true
			elseif dist < SPACING * 2.0 and not hoverId then
				hoverId = id
			end
		end

		local outlineTris = mesh.findTrianglesInRadius(Vector3.zero, SPACING * 1.2)

		renderOverlayAndScreenshot("Overlay_Combined", {
			SelectedVertices = selected,
			HoverVertexId = hoverId,
			OutlineTriangleIds = outlineTris,
		})
	end)

	t.test("viewport: selection + hover outline", function()
		-- Select center vertices, hover a nearby vertex
		local selected: { [number]: boolean } = {}
		local hoverId: number? = nil
		local vertices = mesh.getVertices()
		for id, vertex in vertices do
			local dist = (vertex.position - Vector3.zero).Magnitude
			if dist < SPACING * 1.0 then
				selected[id] = true
			elseif dist < SPACING * 2.0 and not hoverId then
				hoverId = id
			end
		end
		t.expect(hoverId ~= nil).toBe(true)

		-- Selection outline: triangles touching selected vertices
		local selTriSet: { [number]: boolean } = {}
		for vid in selected do
			local v = mesh.getVertex(vid)
			if v then
				for _, triId in v.triangles do
					selTriSet[triId] = true
				end
			end
		end
		local outlineTris: { number } = {}
		for triId in selTriSet do
			table.insert(outlineTris, triId)
		end

		-- Hover outline: triangles touching hovered vertex
		local hoverTris: { number } = {}
		local hv = mesh.getVertex(hoverId :: number)
		if hv then
			for _, triId in hv.triangles do
				table.insert(hoverTris, triId)
			end
		end

		t.expect(#outlineTris > 0).toBe(true)
		t.expect(#hoverTris > 0).toBe(true)

		renderOverlayAndScreenshot("Overlay_HoverOutline", {
			SelectedVertices = selected,
			HoverVertexId = hoverId,
			OutlineTriangleIds = outlineTris,
			HoverOutlineTriangleIds = hoverTris,
		})
	end)

	t.test("viewport: marquee selection", function()
		local cam = workspace.CurrentCamera
		local viewSize = cam and cam.ViewportSize or Vector2.new(800, 600)
		local cx, cy = viewSize.X / 2, viewSize.Y / 2

		renderOverlayAndScreenshot("Overlay_Marquee", {
			MarqueeStart = Vector2.new(cx - 100, cy - 75),
			MarqueeEnd = Vector2.new(cx + 100, cy + 75),
		})
	end)

	t.test("show discovered vertices: a faint marker per vertex only when enabled", function()
		local function countSpheres(): number
			local overlay = CoreGui:FindFirstChild("$PolyMapOverlay")
			if not overlay then
				return 0
			end
			local n = 0
			for _, d in overlay:GetDescendants() do
				if d:IsA("SphereHandleAdornment") then
					n += 1
				end
			end
			return n
		end

		local vertexCount = 0
		for _ in mesh.getVertices() do
			vertexCount += 1
		end
		t.expect(vertexCount > 0).toBe(true)

		-- Off (and nothing selected/hovered): no vertex markers at all.
		ReactRoblox.act(function()
			root:render(e(MeshOverlay, { Mesh = mesh }))
		end)
		t.expect(countSpheres()).toBe(0)

		-- On: exactly one marker per discovered vertex.
		ReactRoblox.act(function()
			root:render(e(MeshOverlay, { Mesh = mesh, ShowDiscoveredVertices = true }))
		end)
		t.expect(countSpheres()).toBe(vertexCount)

		-- De-emphasized: occluded by geometry (not always on top) and translucent.
		local overlay = CoreGui:FindFirstChild("$PolyMapOverlay")
		local checked = 0
		if overlay then
			for _, d in overlay:GetDescendants() do
				if d:IsA("SphereHandleAdornment") then
					checked += 1
					t.expect(d.AlwaysOnTop).toBe(false)
					t.expect(d.Transparency > 0).toBe(true)
				end
			end
		end
		t.expect(checked).toBe(vertexCount)
	end)

	t.test("discovered markers are a fixed size, not depth-scaled", function()
		-- A large mesh so the cost is representative (~1024 vertices).
		local perfFolder = Instance.new("Folder")
		perfFolder.Name = "$MeshOverlayPerfParts"
		perfFolder.Parent = workspace
		local perfMesh = createTriangleMesh()
		local center = Vector3.new(0, 1000, 0)
		local N = 31 -- N*N cells -> (N+1)^2 vertices
		local extent = N * SPACING
		for r = 0, N - 1 do
			for c = 0, N - 1 do
				local base = center + Vector3.new(c * SPACING - extent / 2, 0, r * SPACING - extent / 2)
				perfMesh.addTriangle(base, base + Vector3.new(SPACING, 0, 0), base + Vector3.new(0, 0, SPACING), THICKNESS, perfFolder, nil, Vector3.new(0, 1, 0))
				perfMesh.addTriangle(base + Vector3.new(SPACING, 0, 0), base + Vector3.new(SPACING, 0, SPACING), base + Vector3.new(0, 0, SPACING), THICKNESS, perfFolder, nil, Vector3.new(0, 1, 0))
			end
		end
		local vertexCount = 0
		for _ in perfMesh.getVertices() do
			vertexCount += 1
		end

		local cam = workspace.CurrentCamera
		local savedCF = if cam then cam.CFrame else nil
		local savedType = if cam then cam.CameraType else nil
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = CFrame.lookAt(center + Vector3.new(0, 80, 150), center)
		end

		local SIZE = 0.5 -- exactly representable as a float32, so SphereHandleAdornment.Radius round-trips
		local perfScreen = Instance.new("ScreenGui")
		perfScreen.Name = "$MeshOverlayPerf"
		perfScreen.Parent = CoreGui
		local perfRoot = ReactRoblox.createRoot(perfScreen)

		ReactRoblox.act(function()
			perfRoot:render(e(VertexMarkers, {
				Mesh = perfMesh,
				ShowDiscoveredVertices = true,
				DiscoveredVertexSize = SIZE,
			}))
		end)
		for _ = 1, 2 do
			RunService.Heartbeat:Wait()
		end

		local function radiusSum(): number
			local s = 0
			for _, d in perfScreen:GetDescendants() do
				if d:IsA("SphereHandleAdornment") then
					s += d.Radius
				end
			end
			return s
		end
		local function markerCount(): number
			local n = 0
			for _, d in perfScreen:GetDescendants() do
				if d:IsA("SphereHandleAdornment") then
					n += 1
				end
			end
			return n
		end

		-- One marker per discovered vertex, each at the configured fixed size. The setting
		-- is a diameter, so the sphere radius is half it.
		t.expect(vertexCount > 1000).toBeTruthy()
		t.expect(markerCount()).toBe(vertexCount)
		for _, d in perfScreen:GetDescendants() do
			if d:IsA("SphereHandleAdornment") then
				t.expect(d.Radius).toBe(SIZE / 2)
			end
		end

		-- Discovered markers are a fixed world size, unlike the depth-scaled selection
		-- markers: moving the camera far away and re-rendering must NOT change the radii.
		local nearSum = radiusSum()
		if cam then
			cam.CFrame = CFrame.lookAt(center + Vector3.new(0, 300, 600), center)
		end
		ReactRoblox.act(function()
			perfRoot:render(e(VertexMarkers, {
				Mesh = perfMesh,
				ShowDiscoveredVertices = true,
				DiscoveredVertexSize = SIZE,
			}))
		end)
		t.expect(radiusSum()).toBe(nearSum)

		ReactRoblox.act(function()
			perfRoot:unmount()
		end)
		perfScreen:Destroy()
		perfFolder:Destroy()
		if cam then
			if savedCF then
				cam.CFrame = savedCF
			end
			if savedType then
				cam.CameraType = savedType
			end
		end
	end)

	t.test("discovered markers update incrementally as the mesh changes", function()
		local mesh = createTriangleMesh()
		local incrFolder = Instance.new("Folder")
		incrFolder.Name = "$MeshOverlayIncrParts"
		incrFolder.Parent = workspace

		-- One triangle (3 vertices) to start.
		local tri1 = mesh.addTriangle(Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(2, 0, 3), THICKNESS, incrFolder, nil, Vector3.new(2, 5, 0))
		assert(tri1)

		local incrScreen = Instance.new("ScreenGui")
		incrScreen.Name = "$MeshOverlayIncr"
		incrScreen.Parent = CoreGui
		local incrRoot = ReactRoblox.createRoot(incrScreen)
		ReactRoblox.act(function()
			incrRoot:render(e(VertexMarkers, {
				Mesh = mesh,
				ShowDiscoveredVertices = true,
				DiscoveredVertexSize = 0.5,
			}))
		end)

		local function adorns(): { SphereHandleAdornment }
			local out = {}
			for _, d in incrScreen:GetDescendants() do
				if d:IsA("SphereHandleAdornment") then
					table.insert(out, d)
				end
			end
			return out
		end

		-- One marker per discovered vertex to start.
		t.expect(#adorns()).toBe(3)

		-- Add a triangle sharing an edge -> exactly one new vertex. The pool grows by one
		-- with NO re-render: the mesh's VertexChanged signal drives the update synchronously.
		local tri2 = mesh.addTriangle(Vector3.new(4, 0, 0), Vector3.new(2, 0, 3), Vector3.new(6, 0, 3), THICKNESS, incrFolder, nil, Vector3.new(4, 5, 0))
		assert(tri2)
		t.expect(#adorns()).toBe(4)

		-- Moving a vertex moves its marker (still no re-render).
		local movedTo = Vector3.new(0, 9, 0)
		local v00: number? = nil
		for id, v in mesh.getVertices() do
			if (v.position - Vector3.new(0, 0, 0)).Magnitude < 0.01 then
				v00 = id
				break
			end
		end
		assert(v00)
		mesh.moveVertex(v00, movedTo, THICKNESS, nil)
		local atMoved = 0
		for _, a in adorns() do
			if (a.CFrame.Position - movedTo).Magnitude < 0.01 then
				atMoved += 1
			end
		end
		t.expect(atMoved).toBe(1)

		-- Removing the first triangle orphans only its (0,0,0) corner; its marker goes away,
		-- the two shared with the second triangle stay.
		mesh.removeTriangle(tri1)
		t.expect(#adorns()).toBe(3)

		ReactRoblox.act(function()
			incrRoot:unmount()
		end)
		incrScreen:Destroy()
		incrFolder:Destroy()
	end)

	-- Clean up
	ReactRoblox.act(function()
		root:unmount()
	end)
	screen:Destroy()
	folder:Destroy()
end
