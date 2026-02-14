--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local VertexMarker = require("./VertexMarker")
local WireframeEdge = require("./WireframeEdge")
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

local VERTEX_RADIUS = 1.5
local SELECTED_VERTEX_RADIUS = 2.5
local HOVER_VERTEX_RADIUS = 2.0
local WIRE_RADIUS = 0.5
local BOUNDARY_WIRE_RADIUS = 0.75

local VERTEX_COLOR = Color3.fromRGB(200, 200, 200)
local SELECTED_VERTEX_COLOR = Color3.fromRGB(255, 100, 50)
local HOVER_VERTEX_COLOR = Color3.fromRGB(100, 150, 255)
local EDGE_COLOR = Color3.fromRGB(120, 120, 120)
local BOUNDARY_EDGE_COLOR = Color3.fromRGB(200, 200, 50)
local SELECTED_EDGE_COLOR = Color3.fromRGB(255, 100, 50)

local function MeshOverlay(props: {
	Mesh: TriangleMesh.TriangleMesh?,
	SelectedVertices: { [number]: boolean }?,
	HoverVertexId: number?,
	HoverEdgeKey: string?,
	ShowVertices: boolean?,
	ShowEdges: boolean?,
	ShowBoundary: boolean?,
})
	local mesh = props.Mesh
	if not mesh then
		return nil
	end

	local children: { [string]: any } = {}
	local selectedVertices = props.SelectedVertices or {}
	local showVertices = if props.ShowVertices ~= nil then props.ShowVertices else true
	local showEdges = if props.ShowEdges ~= nil then props.ShowEdges else true
	local showBoundary = if props.ShowBoundary ~= nil then props.ShowBoundary else true

	-- Render edges
	if showEdges then
		local edges = mesh.getEdges()
		local boundaryEdgeKeys: { [string]: boolean } = {}
		if showBoundary then
			for _, edge in mesh.getBoundaryEdges() do
				boundaryEdgeKeys[edge.key] = true
			end
		end

		for key, edge in edges do
			local v1 = mesh.getVertex(edge.v1)
			local v2 = mesh.getVertex(edge.v2)
			if v1 and v2 then
				local midpoint = (v1.position + v2.position) / 2
				local scale = scaleForDepth(midpoint)
				local isBoundary = boundaryEdgeKeys[key]
				local isHovered = props.HoverEdgeKey == key

				local color = if isHovered then SELECTED_EDGE_COLOR
					elseif isBoundary then BOUNDARY_EDGE_COLOR
					else EDGE_COLOR
				local radius = if isBoundary then scale * BOUNDARY_WIRE_RADIUS else scale * WIRE_RADIUS

				children["E_" .. key] = e(WireframeEdge, {
					From = v1.position,
					To = v2.position,
					Color = color,
					Radius = radius,
					ZIndexOffset = if isHovered then 3 else 1,
				})
			end
		end
	end

	-- Render vertices
	if showVertices then
		for id, vertex in mesh.getVertices() do
			local isSelected = selectedVertices[id] == true
			local isHovered = props.HoverVertexId == id
			local scale = scaleForDepth(vertex.position)

			local color = if isSelected then SELECTED_VERTEX_COLOR
				elseif isHovered then HOVER_VERTEX_COLOR
				else VERTEX_COLOR
			local radius = if isSelected then scale * SELECTED_VERTEX_RADIUS
				elseif isHovered then scale * HOVER_VERTEX_RADIUS
				else scale * VERTEX_RADIUS

			children["V_" .. tostring(id)] = e(VertexMarker, {
				Position = vertex.position,
				Color = color,
				Radius = radius,
				ZIndexOffset = if isSelected then 5 elseif isHovered then 4 else 2,
			})
		end
	end

	return ReactRoblox.createPortal(e("Folder", {
		Name = "$PolyMapOverlay",
		Archivable = false,
	}, children), CoreGui)
end

return MeshOverlay
