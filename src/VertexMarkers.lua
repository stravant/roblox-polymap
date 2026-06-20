--!strict

local RunService = game:GetService("RunService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)

local VertexMarker = require("./VertexMarker")
local TriangleMesh = require("./TriangleMesh")

local e = React.createElement

local function scaleForDepth(point: Vector3): number
	local camera = workspace.CurrentCamera
	if camera then
		local depth = math.abs(camera:WorldToViewportPoint(point).Z)
		return depth / 150
	end
	return 1
end

local SELECTED_VERTEX_RADIUS = 2.5
local HOVER_VERTEX_RADIUS = 2.0

local SELECTED_VERTEX_COLOR = Color3.fromRGB(255, 200, 50)
local HOVER_VERTEX_COLOR = Color3.fromRGB(100, 150, 255)
local DELETE_HOVER_VERTEX_COLOR = Color3.fromRGB(255, 80, 80)
local DISCOVERED_VERTEX_COLOR = Color3.fromRGB(255, 255, 255)

-- The discovered-vertex markers: one faint, fixed-size dot per vertex (the setting is a
-- diameter, so the sphere radius is half it). Memoised on the mesh version, so a hover --
-- which doesn't change the mesh -- doesn't reconcile all ~1000 of them; it re-renders only
-- when a vertex is actually added, moved, or removed.
local DiscoveredMarkers = React.memo(function(props: {
	Mesh: TriangleMesh.TriangleMesh,
	Size: number,
	Version: number?,
})
	local r = props.Size / 2
	local children: { [string]: any } = {}
	for id, vertex in props.Mesh.getVertices() do
		children["D_" .. tostring(id)] = e(VertexMarker, {
			Position = vertex.position,
			Color = DISCOVERED_VERTEX_COLOR,
			Radius = r,
			Transparency = 0.1,
			AlwaysOnTop = false,
			ZIndexOffset = 1,
		})
	end
	return e(React.Fragment, nil, children)
end)

-- Renders the selected / hovered / discovered vertex markers.
--
-- The selected and hovered markers are depth-scaled to keep a steady on-screen size, so
-- they track camera movement: rather than re-render on every camera frame, each such
-- marker's Radius is a React binding derived from a single "camera tick" binding. A
-- camera move bumps the tick, which recomputes and writes the Radius onto each adornment
-- directly -- no reconciliation, and synchronous. Discovered-vertex markers are instead
-- drawn at a fixed world size (the DiscoveredVertexSize setting), so they need no camera
-- tracking at all -- which matters because there can be ~1000 of them.
local function VertexMarkers(props: {
	Mesh: TriangleMesh.TriangleMesh,
	SelectedVertices: { [number]: boolean }?,
	HoverVertexId: number?,
	HoverVertexIsDelete: boolean?,
	ShowDiscoveredVertices: boolean?,
	DiscoveredVertexSize: number?,
	DiscoveredVersion: number?,
})
	local mesh = props.Mesh
	local selectedVertices = props.SelectedVertices or {}

	-- Only the depth-scaled selected/hover markers need camera tracking; the discovered
	-- markers are a fixed size, so showing them alone doesn't require it.
	local hasContent = next(selectedVertices) ~= nil
		or props.HoverVertexId ~= nil

	local cameraTick, setCameraTick = React.useBinding(0)
	React.useEffect(function()
		if not hasContent then
			return
		end
		-- Poll the camera every render frame and bump the tick when it has moved.
		-- RenderStepped runs synchronously just before the frame is drawn, so the
		-- recomputed radii land in the SAME frame. (The camera's property-changed
		-- signal can be Deferred -- firing a frame late -- which made the marker
		-- sizes visibly lag the camera, most noticeably at low framerates.)
		local n = 0
		local lastCF: CFrame? = nil
		local conn = RunService.RenderStepped:Connect(function()
			local cam = workspace.CurrentCamera
			if cam and cam.CFrame ~= lastCF then
				lastCF = cam.CFrame
				n += 1
				setCameraTick(n)
			end
		end)
		return function()
			conn:Disconnect()
		end
	end, { hasContent } :: { any })

	-- A depth-scaled radius that recomputes whenever the camera tick changes.
	local function radius(position: Vector3, base: number, extra: number)
		return cameraTick:map(function()
			return scaleForDepth(position) * base * extra
		end)
	end

	local children: { [string]: any } = {}

	-- Selected markers (scale down when many are selected)
	local selectedCount = 0
	for _ in selectedVertices do
		selectedCount += 1
	end
	local selectionScale = math.max(0.4, 1 / math.sqrt(math.max(1, selectedCount)))

	for id in selectedVertices do
		local vertex = mesh.getVertex(id)
		if vertex then
			children["V_" .. tostring(id)] = e(VertexMarker, {
				Position = vertex.position,
				Color = SELECTED_VERTEX_COLOR,
				Radius = radius(vertex.position, SELECTED_VERTEX_RADIUS, selectionScale),
				ZIndexOffset = 5,
			})
		end
	end

	-- Hovered marker (red when it marks the vertex a Delete click would remove)
	if props.HoverVertexId and not selectedVertices[props.HoverVertexId] then
		local vertex = mesh.getVertex(props.HoverVertexId)
		if vertex then
			children["V_hover"] = e(VertexMarker, {
				Position = vertex.position,
				Color = if props.HoverVertexIsDelete then DELETE_HOVER_VERTEX_COLOR else HOVER_VERTEX_COLOR,
				Radius = radius(vertex.position, HOVER_VERTEX_RADIUS, 1),
				ZIndexOffset = 4,
			})
		end
	end

	-- Every discovered vertex in a faint, de-emphasized state (opt-in via the global
	-- "Show discovered vertices" setting), as a memoised child so a hover doesn't
	-- reconcile them all. No need to skip the selected/hovered vertices: those markers
	-- are AlwaysOnTop and cover the faint dot underneath them.
	if props.ShowDiscoveredVertices then
		children["Discovered"] = e(DiscoveredMarkers, {
			Mesh = mesh,
			Size = props.DiscoveredVertexSize or 0.4,
			Version = props.DiscoveredVersion,
		})
	end

	return e(React.Fragment, nil, children)
end

return VertexMarkers
