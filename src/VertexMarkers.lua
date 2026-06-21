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

-- The discovered-vertex display: one faint, fixed-size dot per vertex (the setting is a
-- diameter, so the sphere radius is half it). Instead of rendering these through React --
-- where any mesh change reconciles all ~1000 of them -- we keep an adornment per vertex
-- and update it incrementally from the mesh's VertexChanged signal: discovering, moving,
-- or deleting a handful of vertices only touches those few markers, never the whole set,
-- and a hover (which doesn't change the mesh) does no marker work at all.
local function DiscoveredMarkers(props: {
	Mesh: TriangleMesh.TriangleMesh,
	Size: number, -- diameter
	-- Vertices whose discovered marker is hidden (the selected/hovered ones, which have their
	-- own markers). Hiding rather than relying on z-order: a fixed-world-size discovered dot
	-- can be larger on screen than the constant-size marker over it and peek out around it.
	Hidden: { [number]: boolean }?,
})
	local containerRef = React.useRef(nil :: Folder?)
	-- Live adornment pool keyed by VertexId, held in a ref so the size effect can reach
	-- it without tearing down the mesh subscription.
	local adornsRef = React.useRef(nil :: { [number]: SphereHandleAdornment }?)
	-- Latest size, read by the long-lived reconcile closure when it creates a marker.
	local sizeRef = React.useRef(props.Size)
	sizeRef.current = props.Size
	-- Latest hidden set, read by the reconcile closure so a marker (re)built while its vertex
	-- is selected/hovered starts hidden; the effect below toggles the rest as it changes.
	local hiddenRef = React.useRef(props.Hidden or {})

	-- Build the pool once and keep it in sync with the mesh. Re-runs only if the mesh
	-- instance itself changes (a new session), never on an ordinary re-render.
	React.useEffect(function()
		local container = containerRef.current
		if not container then
			return
		end
		local mesh = props.Mesh
		local adorns: { [number]: SphereHandleAdornment } = {}
		adornsRef.current = adorns

		local function reconcile(id: number)
			local vertex = mesh.getVertex(id)
			if vertex then
				local adorn = adorns[id]
				if not adorn then
					adorn = Instance.new("SphereHandleAdornment")
					adorn.Adornee = workspace.Terrain
					adorn.Color3 = DISCOVERED_VERTEX_COLOR
					adorn.Transparency = 0.1
					adorn.AlwaysOnTop = false
					adorn.ZIndex = 1
					adorn.Radius = sizeRef.current / 2
					adorn.Parent = container
					adorns[id] = adorn
				end
				adorn.CFrame = CFrame.new(vertex.position)
				adorn.Visible = not hiddenRef.current[id]
			else
				local adorn = adorns[id]
				if adorn then
					adorn:Destroy()
					adorns[id] = nil
				end
			end
		end

		for id in mesh.getVertices() do
			reconcile(id)
		end
		local conn = mesh.VertexChanged:Connect(reconcile)

		return function()
			conn:Disconnect()
			for _, adorn in adorns do
				adorn:Destroy()
			end
			adornsRef.current = nil
		end
	end, { props.Mesh } :: { any })

	-- A size change just rewrites the existing markers' radii -- no rebuild.
	React.useEffect(function()
		local adorns = adornsRef.current
		if adorns then
			local r = props.Size / 2
			for _, adorn in adorns do
				adorn.Radius = r
			end
		end
	end, { props.Size } :: { any })

	-- Toggle visibility as the selected/hovered set changes: only the markers whose hidden
	-- state flipped, so a hover sliding over the mesh touches at most a couple of markers,
	-- never all ~1000. The parent recomputes Hidden each render, so this catches in-place
	-- selection edits (shift-click) too, not just reassignments.
	React.useEffect(function()
		local newHidden = props.Hidden or {}
		local oldHidden = hiddenRef.current
		hiddenRef.current = newHidden
		local adorns = adornsRef.current
		if not adorns then
			return
		end
		for id in newHidden do
			if not oldHidden[id] then
				local adorn = adorns[id]
				if adorn then
					adorn.Visible = false
				end
			end
		end
		for id in oldHidden do
			if not newHidden[id] then
				local adorn = adorns[id]
				if adorn then
					adorn.Visible = true
				end
			end
		end
	end, { props.Hidden } :: { any })

	-- The pool is parented to this Folder imperatively; React only owns the Folder.
	return e("Folder", { ref = containerRef })
end

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
	-- "Show discovered vertices" setting), via an incrementally-updated child so a hover
	-- does no work for it. The selected/hovered vertices' discovered dots are hidden -- they
	-- have their own markers, and a fixed-world-size dot can peek out around a constant-size
	-- marker rather than being covered by it.
	if props.ShowDiscoveredVertices then
		local hidden: { [number]: boolean } = {}
		for id in selectedVertices do
			hidden[id] = true
		end
		if props.HoverVertexId then
			hidden[props.HoverVertexId] = true
		end
		children["Discovered"] = e(DiscoveredMarkers, {
			Mesh = mesh,
			Size = props.DiscoveredVertexSize or 0.4,
			Hidden = hidden,
		})
	end

	return e(React.Fragment, nil, children)
end

return VertexMarkers
