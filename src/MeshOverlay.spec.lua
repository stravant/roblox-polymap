--!strict

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local MeshOverlay = require("./MeshOverlay")
local createTriangleMesh = require("./TriangleMesh")
local TestTypes = require("./TestTypes")

local e = React.createElement

local THICKNESS = 0.2
local SPACING = 4

-- Wait for N render frames so 3D adornments appear in CaptureService
local function waitFrames(n: number)
	for _ = 1, n do
		RunService.RenderStepped:Wait()
	end
end

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
			})
			mesh.addTriangle(tr, br, bl, THICKNESS, folder, {
				Color = Color3.fromRGB(75, 151, 75),
				Material = Enum.Material.Grass,
			})
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
			InfluenceTriangleIds: { number }?,
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
				InfluenceTriangleIds = overlayProps.InfluenceTriangleIds,
				MarqueeStart = overlayProps.MarqueeStart,
				MarqueeEnd = overlayProps.MarqueeEnd,
			}))
		end)
		-- Flush useEffect then wait for 3D pipeline to render adornments
		ReactRoblox.act(function() end)
		waitFrames(3)

		t.screenshot(name)

		-- CaptureService reads the framebuffer asynchronously — wait long
		-- enough for the capture to resolve before re-rendering new props.
		waitFrames(15)
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

	t.test("viewport: selection + influence outline", function()
		-- Select center vertices, show influence region around them
		local selected: { [number]: boolean } = {}
		local vertices = mesh.getVertices()
		for id, vertex in vertices do
			if (vertex.position - Vector3.zero).Magnitude < SPACING * 0.8 then
				selected[id] = true
			end
		end

		-- Direct outline: triangles touching selected vertices
		local directTriSet: { [number]: boolean } = {}
		for vid in selected do
			local v = mesh.getVertex(vid)
			if v then
				for _, triId in v.triangles do
					directTriSet[triId] = true
				end
			end
		end
		local outlineTris: { number } = {}
		for triId in directTriSet do
			table.insert(outlineTris, triId)
		end

		-- Influence: triangles in a wider radius, excluding direct
		local influenceRadius = SPACING * 2.5
		local influenceVids: { [number]: boolean } = {}
		for vid, vertex in vertices do
			if not selected[vid] then
				for selVid in selected do
					local selV = mesh.getVertex(selVid)
					if selV and (vertex.position - selV.position).Magnitude < influenceRadius then
						influenceVids[vid] = true
						break
					end
				end
			end
		end
		local influenceTriSet: { [number]: boolean } = {}
		for vid in influenceVids do
			local v = mesh.getVertex(vid)
			if v then
				for _, triId in v.triangles do
					if not directTriSet[triId] then
						influenceTriSet[triId] = true
					end
				end
			end
		end
		local influenceTris: { number } = {}
		for triId in influenceTriSet do
			table.insert(influenceTris, triId)
		end

		t.expect(#outlineTris > 0).toBe(true)
		t.expect(#influenceTris > 0).toBe(true)

		renderOverlayAndScreenshot("Overlay_Influence", {
			SelectedVertices = selected,
			OutlineTriangleIds = outlineTris,
			InfluenceTriangleIds = influenceTris,
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

	-- Clean up
	ReactRoblox.act(function()
		root:unmount()
	end)
	screen:Destroy()
	folder:Destroy()
end
