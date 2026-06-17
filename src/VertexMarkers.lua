--!strict

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
local DISCOVERED_VERTEX_RADIUS = 1.2

local SELECTED_VERTEX_COLOR = Color3.fromRGB(255, 200, 50)
local HOVER_VERTEX_COLOR = Color3.fromRGB(100, 150, 255)
local DISCOVERED_VERTEX_COLOR = Color3.fromRGB(255, 255, 255)

-- Renders the selected / hovered / discovered vertex markers.
--
-- A marker's radius is depth-scaled, so it has to track camera movement or it
-- visibly snaps to a new size only when some other state happens to change. Rather
-- than re-render the whole marker set on every camera frame -- which, with the
-- discovered display on, means React reconciling one element per vertex (measured
-- ~25 ms/frame at ~1000 vertices) -- each marker's Radius is a React binding
-- derived from a single "camera tick" binding. A camera move just bumps that tick,
-- which recomputes and writes the Radius onto each adornment directly: no
-- reconciliation, and synchronous.
local function VertexMarkers(props: {
	Mesh: TriangleMesh.TriangleMesh,
	SelectedVertices: { [number]: boolean }?,
	HoverVertexId: number?,
	ShowDiscoveredVertices: boolean?,
})
	local mesh = props.Mesh
	local selectedVertices = props.SelectedVertices or {}

	-- Only track the camera when there's actually something on screen to resize.
	local hasContent = next(selectedVertices) ~= nil
		or props.HoverVertexId ~= nil
		or props.ShowDiscoveredVertices == true

	local cameraTick, setCameraTick = React.useBinding(0)
	React.useEffect(function()
		if not hasContent then
			return
		end
		-- Bump the tick whenever the camera CFrame changes (i.e. the user
		-- navigates), which is exactly when the depth scale needs recomputing.
		local n = 0
		local cameraConn: RBXScriptConnection? = nil
		local function bump()
			n += 1
			setCameraTick(n)
		end
		local function watch()
			if cameraConn then
				cameraConn:Disconnect()
				cameraConn = nil
			end
			local cam = workspace.CurrentCamera
			if cam then
				cameraConn = cam:GetPropertyChangedSignal("CFrame"):Connect(bump)
			end
		end
		watch()
		local swapConn = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			watch()
			bump()
		end)
		return function()
			if cameraConn then
				cameraConn:Disconnect()
			end
			swapConn:Disconnect()
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

	-- Hovered marker
	if props.HoverVertexId and not selectedVertices[props.HoverVertexId] then
		local vertex = mesh.getVertex(props.HoverVertexId)
		if vertex then
			children["V_hover"] = e(VertexMarker, {
				Position = vertex.position,
				Color = HOVER_VERTEX_COLOR,
				Radius = radius(vertex.position, HOVER_VERTEX_RADIUS, 1),
				ZIndexOffset = 4,
			})
		end
	end

	-- Every discovered vertex in a faint, de-emphasized state (opt-in via the
	-- global "Show discovered vertices" setting). Skip ones already drawn as
	-- selected or hovered so those stay prominent.
	if props.ShowDiscoveredVertices then
		for id, vertex in mesh.getVertices() do
			if not selectedVertices[id] and props.HoverVertexId ~= id then
				children["D_" .. tostring(id)] = e(VertexMarker, {
					Position = vertex.position,
					Color = DISCOVERED_VERTEX_COLOR,
					Radius = radius(vertex.position, DISCOVERED_VERTEX_RADIUS, 1),
					Transparency = 0.1,
					AlwaysOnTop = false,
					ZIndexOffset = 1,
				})
			end
		end
	end

	return e(React.Fragment, nil, children)
end

return VertexMarkers
