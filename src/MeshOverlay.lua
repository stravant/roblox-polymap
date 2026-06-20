--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local VertexMarkers = require("./VertexMarkers")
local TriangleMesh = require("./TriangleMesh")

local e = React.createElement

local OUTLINE_COLOR = Color3.fromRGB(255, 200, 50)
local HOVER_OUTLINE_COLOR = Color3.fromRGB(100, 150, 255)
local MARQUEE_BORDER_COLOR = Color3.fromRGB(100, 150, 255)
local ADD_EDGE_COLOR = Color3.fromRGB(50, 255, 50)
local ADD_PREVIEW_COLOR = Color3.fromRGB(50, 200, 50)
local GRID_PREVIEW_COLOR = Color3.fromRGB(80, 200, 255)

local function drawBoundaryEdges(wire: WireframeHandleAdornment, mesh: TriangleMesh.TriangleMesh, triangleIds: { number })
	-- getSetBoundaryEdges walks only the set's own edges (O(set)); the old approach scanned
	-- every edge in the mesh, which made dragging a selection slow once a lot of unrelated
	-- geometry had been discovered.
	for _, edge in mesh.getSetBoundaryEdges(triangleIds) do
		local v1 = mesh.getVertex(edge.v1)
		local v2 = mesh.getVertex(edge.v2)
		if v1 and v2 then
			wire:AddLine(v1.position, v2.position)
		end
	end
end

local function MeshOverlay(props: {
	Mesh: TriangleMesh.TriangleMesh?,
	SelectedVertices: { [number]: boolean }?,
	HoverVertexId: number?,
	HoverVertexIsDelete: boolean?,
	OutlineTriangleIds: { number }?,
	HoverOutlineTriangleIds: { number }?,
	MarqueeStart: Vector2?,
	MarqueeEnd: Vector2?,
	AddHighlightEdge: { v1Pos: Vector3, v2Pos: Vector3 }?,
	AddPreviewTriangles: { { Vector3 } }?,
	AddPreviewPolyline: { Vector3 }?,
	GridPreviewLines: { { Vector3 } }?,
	ShowDiscoveredVertices: boolean?,
	DiscoveredVertexSize: number?,
})
	local mesh = props.Mesh
	local outlineRef = React.useRef(nil :: any)
	local influenceRef = React.useRef(nil :: any)
	local addEdgeRef = React.useRef(nil :: any)
	local addPreviewRef = React.useRef(nil :: any)
	local gridPreviewRef = React.useRef(nil :: any)

	-- Draw outline around outlined triangle set (boundary edges only)
	local outlineTriangleIds = props.OutlineTriangleIds or {}
	React.useEffect(function()
		local wire = outlineRef.current :: WireframeHandleAdornment?
		if not wire or not mesh then
			return
		end
		wire:Clear()

		if #outlineTriangleIds > 0 then
			drawBoundaryEdges(wire, mesh, outlineTriangleIds)
		end

		return function()
			if wire then
				wire:Clear()
			end
		end
	end)

	-- Draw hover vertex outline (boundary edges only)
	local hoverOutlineTriangleIds = props.HoverOutlineTriangleIds or {}
	React.useEffect(function()
		local wire = influenceRef.current :: WireframeHandleAdornment?
		if not wire or not mesh then
			return
		end
		wire:Clear()

		if #hoverOutlineTriangleIds > 0 then
			drawBoundaryEdges(wire, mesh, hoverOutlineTriangleIds)
		end

		return function()
			if wire then
				wire:Clear()
			end
		end
	end)

	-- Draw Add mode edge highlight
	local addHighlightEdge = props.AddHighlightEdge
	React.useEffect(function()
		local wire = addEdgeRef.current :: WireframeHandleAdornment?
		if not wire then
			return
		end
		wire:Clear()

		if addHighlightEdge then
			wire:AddLine(addHighlightEdge.v1Pos, addHighlightEdge.v2Pos)
		end

		return function()
			if wire then
				wire:Clear()
			end
		end
	end)

	-- Draw Add mode preview triangles and the in-progress fresh-point polyline
	local addPreviewTriangles = props.AddPreviewTriangles
	local addPreviewPolyline = props.AddPreviewPolyline
	React.useEffect(function()
		local wire = addPreviewRef.current :: WireframeHandleAdornment?
		if not wire then
			return
		end
		wire:Clear()

		if addPreviewTriangles then
			for _, tri in addPreviewTriangles do
				if #tri >= 3 then
					wire:AddLine(tri[1], tri[2])
					wire:AddLine(tri[2], tri[3])
					wire:AddLine(tri[3], tri[1])
				end
			end
		end

		-- Fresh-point path: a small cross at each placed/hover corner, plus lines
		-- connecting them (closing into a triangle once there are three).
		if addPreviewPolyline and #addPreviewPolyline > 0 then
			local pts = addPreviewPolyline
			local s = 0.4
			for _, p in pts do
				wire:AddLine(p - Vector3.new(s, 0, 0), p + Vector3.new(s, 0, 0))
				wire:AddLine(p - Vector3.new(0, s, 0), p + Vector3.new(0, s, 0))
				wire:AddLine(p - Vector3.new(0, 0, s), p + Vector3.new(0, 0, s))
			end
			for i = 1, #pts - 1 do
				wire:AddLine(pts[i], pts[i + 1])
			end
			if #pts >= 3 then
				wire:AddLine(pts[#pts], pts[1])
			end
		end

		return function()
			if wire then
				wire:Clear()
			end
		end
	end)

	-- Draw the interactive grid-placement preview (corner crosses + cell lines).
	local gridPreviewLines = props.GridPreviewLines
	React.useEffect(function()
		local wire = gridPreviewRef.current :: WireframeHandleAdornment?
		if not wire then
			return
		end
		wire:Clear()
		if gridPreviewLines then
			for _, seg in gridPreviewLines do
				if #seg >= 2 then
					wire:AddLine(seg[1], seg[2])
				end
			end
		end
		return function()
			if wire then
				wire:Clear()
			end
		end
	end)

	if not mesh then
		return nil
	end

	local children: { [string]: any } = {}

	-- Wireframe adornment for outline of active triangle set
	children.OutlineWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = OUTLINE_COLOR,
		AlwaysOnTop = true,
		ref = outlineRef,
	})

	-- Wireframe adornment for hover vertex outline
	children.HoverWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = HOVER_OUTLINE_COLOR,
		AlwaysOnTop = true,
		ref = influenceRef,
	})

	-- Wireframe adornment for Add mode edge highlight
	children.AddEdgeWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = ADD_EDGE_COLOR,
		AlwaysOnTop = true,
		ref = addEdgeRef,
	})

	-- Wireframe adornment for Add mode preview triangles
	children.AddPreviewWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = ADD_PREVIEW_COLOR,
		AlwaysOnTop = true,
		ref = addPreviewRef,
	})

	-- Wireframe adornment for the interactive grid-placement preview
	children.GridPreviewWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = GRID_PREVIEW_COLOR,
		AlwaysOnTop = true,
		ref = gridPreviewRef,
	})

	-- Vertex markers (selected / hovered / discovered) render in their own
	-- component so they can resize on camera movement without re-running the
	-- wireframe-drawing effects above every frame.
	children.VertexMarkers = e(VertexMarkers, {
		Mesh = mesh,
		SelectedVertices = props.SelectedVertices,
		HoverVertexId = props.HoverVertexId,
		HoverVertexIsDelete = props.HoverVertexIsDelete,
		ShowDiscoveredVertices = props.ShowDiscoveredVertices,
		DiscoveredVertexSize = props.DiscoveredVertexSize,
	})

	-- Marquee selection rectangle
	if props.MarqueeStart and props.MarqueeEnd then
		local minX = math.min(props.MarqueeStart.X, props.MarqueeEnd.X)
		local minY = math.min(props.MarqueeStart.Y, props.MarqueeEnd.Y)
		local maxX = math.max(props.MarqueeStart.X, props.MarqueeEnd.X)
		local maxY = math.max(props.MarqueeStart.Y, props.MarqueeEnd.Y)

		children.MarqueeGui = e("ScreenGui", {
			Name = "$PolyMapMarquee",
			IgnoreGuiInset = true,
			DisplayOrder = 100,
		}, {
			Outline = e("Frame", {
				Position = UDim2.fromOffset(minX, minY),
				Size = UDim2.fromOffset(maxX - minX, maxY - minY),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, {
				Border = e("UIStroke", {
					Color = MARQUEE_BORDER_COLOR,
					Thickness = 1,
				}),
			}),
		})
	end

	return ReactRoblox.createPortal(e("Folder", {
		Name = "$PolyMapOverlay",
		Archivable = false,
	}, children), CoreGui)
end

return MeshOverlay
