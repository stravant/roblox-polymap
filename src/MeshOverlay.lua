--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

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

local WIREFRAME_COLOR = Color3.fromRGB(255, 0, 255)
local SELECTED_VERTEX_COLOR = Color3.fromRGB(255, 100, 50)
local HOVER_VERTEX_COLOR = Color3.fromRGB(100, 150, 255)
local HOVER_EDGE_COLOR = Color3.fromRGB(255, 100, 50)

local function MeshOverlay(props: {
	Mesh: TriangleMesh.TriangleMesh?,
	SelectedVertices: { [number]: boolean }?,
	HoverVertexId: number?,
	HoverEdgeKey: string?,
})
	local mesh = props.Mesh
	local wireRef = React.useRef(nil :: any)
	local hoverWireRef = React.useRef(nil :: any)

	-- Draw mesh edges via WireframeHandleAdornment:AddLine
	React.useEffect(function()
		local wire = wireRef.current :: WireframeHandleAdornment?
		if not wire or not mesh then
			return
		end
		wire:Clear()

		local edges = mesh.getEdges()
		for _, edge in edges do
			local v1 = mesh.getVertex(edge.v1)
			local v2 = mesh.getVertex(edge.v2)
			if v1 and v2 then
				wire:AddLine(v1.position, v2.position)
			end
		end

		return function()
			if wire then
				wire:Clear()
			end
		end
	end)

	-- Draw hovered edge highlight
	React.useEffect(function()
		local wire = hoverWireRef.current :: WireframeHandleAdornment?
		if not wire or not mesh then
			return
		end
		wire:Clear()

		if props.HoverEdgeKey then
			local edges = mesh.getEdges()
			local edge = edges[props.HoverEdgeKey]
			if edge then
				local v1 = mesh.getVertex(edge.v1)
				local v2 = mesh.getVertex(edge.v2)
				if v1 and v2 then
					wire:AddLine(v1.position, v2.position)
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
	local selectedVertices = props.SelectedVertices or {}

	-- Wireframe adornment for all mesh edges
	children.Wireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = WIREFRAME_COLOR,
		AlwaysOnTop = true,
		ref = wireRef,
	})

	-- Wireframe adornment for hovered edge
	children.HoverWireframe = e("WireframeHandleAdornment", {
		Adornee = workspace.Terrain,
		Color3 = HOVER_EDGE_COLOR,
		AlwaysOnTop = true,
		ref = hoverWireRef,
	})

	-- Render selected vertex markers
	for id in selectedVertices do
		local vertex = mesh.getVertex(id)
		if vertex then
			local scale = scaleForDepth(vertex.position)
			children["V_" .. tostring(id)] = e(VertexMarker, {
				Position = vertex.position,
				Color = SELECTED_VERTEX_COLOR,
				Radius = scale * SELECTED_VERTEX_RADIUS,
				ZIndexOffset = 5,
			})
		end
	end

	-- Render hovered vertex marker
	if props.HoverVertexId and not selectedVertices[props.HoverVertexId] then
		local vertex = mesh.getVertex(props.HoverVertexId)
		if vertex then
			local scale = scaleForDepth(vertex.position)
			children["V_hover"] = e(VertexMarker, {
				Position = vertex.position,
				Color = HOVER_VERTEX_COLOR,
				Radius = scale * HOVER_VERTEX_RADIUS,
				ZIndexOffset = 4,
			})
		end
	end

	return ReactRoblox.createPortal(e("Folder", {
		Name = "$PolyMapOverlay",
		Archivable = false,
	}, children), CoreGui)
end

return MeshOverlay
