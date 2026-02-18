--!strict

local fillTriangle = require("./fillTriangle")
local getWedgeVertices = require("./getWedgeVertices")

local SNAP_EPSILON = 0.01
local THIN_MAX_ABSOLUTE = 1.5
local THIN_MAX_RATIO = 0.3

local function isThinWedge(instance: Instance): BasePart?
	if instance:IsA("WedgePart") or (instance:IsA("Part") and (instance :: Part).Shape == Enum.PartType.Wedge) then
		local size = (instance :: BasePart).Size
		local minSize = math.min(size.X, size.Y, size.Z)
		local maxSize = math.max(size.X, size.Y, size.Z)
		-- Must be thin in absolute terms AND thin relative to the largest dimension.
		-- This rejects structural wedges (ramps, stairs) that happen to be small.
		if minSize < THIN_MAX_ABSOLUTE and (maxSize < 0.001 or minSize / maxSize < THIN_MAX_RATIO) then
			return instance :: BasePart
		end
	end
	return nil
end

export type Vertex = {
	id: number,
	position: Vector3,
	triangles: { number }, -- triangle ids
}

export type Triangle = {
	id: number,
	vertices: { number }, -- 3 vertex ids
	parts: { BasePart }, -- 1-2 wedge parts
	normal: Vector3,
}

export type Edge = {
	key: string,
	v1: number,
	v2: number,
	triangles: { number }, -- triangle ids sharing this edge
}

export type TriangleMesh = {
	-- Data access
	getVertices: () -> { [number]: Vertex },
	getTriangles: () -> { [number]: Triangle },
	getEdges: () -> { [string]: Edge },
	getVertex: (id: number) -> Vertex?,
	getTriangle: (id: number) -> Triangle?,

	-- Queries
	getBoundaryEdges: () -> { Edge },
	getVertexNeighbors: (vertexId: number) -> { number },
	findVertexNear: (position: Vector3, radius: number) -> number?,

	-- Mutations
	addTriangle: (v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?) -> number?,
	removeTriangle: (triangleId: number) -> (),
	moveVertex: (vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	moveVertices: (moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?) -> (),

	-- Queries (topology)
	getAdjacentTriangles: (triangleId: number) -> { number },
	findTrianglesInRadius: (center: Vector3, radius: number) -> { number },

	-- Discovery / Scanning
	discoverPart: (part: BasePart) -> number?,
	discoverRegion: (center: Vector3, radius: number) -> (),
	getPartTriangle: (part: BasePart) -> number?,
	scanWorkspace: (root: Instance?) -> (),
	refreshFromParts: () -> (),
	clear: () -> (),
}

local function snapPosition(position: Vector3, epsilon: number): Vector3
	local function snapComponent(v: number): number
		local rounded = math.round(v / epsilon) * epsilon
		return rounded
	end
	return Vector3.new(
		snapComponent(position.X),
		snapComponent(position.Y),
		snapComponent(position.Z)
	)
end

local function edgeKey(v1: number, v2: number): string
	local a, b = math.min(v1, v2), math.max(v1, v2)
	return `{a}_{b}`
end

local function createTriangleMesh(): TriangleMesh
	local mVertices: { [number]: Vertex } = {}
	local mTriangles: { [number]: Triangle } = {}
	local mEdges: { [string]: Edge } = {}
	local mNextVertexId = 1
	local mNextTriangleId = 1

	-- Spatial lookup: snapped position string -> vertex id
	local mPositionToVertex: { [string]: number } = {}

	-- Part -> triangle ID mapping for O(1) discovery cache
	local mPartToTriangle: { [BasePart]: number } = {}

	local function positionKey(pos: Vector3): string
		local snapped = snapPosition(pos, SNAP_EPSILON)
		return `{snapped.X}_{snapped.Y}_{snapped.Z}`
	end

	local function findOrCreateVertex(position: Vector3): number
		local key = positionKey(position)
		local existing = mPositionToVertex[key]
		if existing then
			return existing
		end

		local id = mNextVertexId
		mNextVertexId += 1
		local snapped = snapPosition(position, SNAP_EPSILON)
		mVertices[id] = {
			id = id,
			position = snapped,
			triangles = {},
		}
		mPositionToVertex[key] = id
		return id
	end

	local function addEdge(v1: number, v2: number, triangleId: number)
		local key = edgeKey(v1, v2)
		local edge = mEdges[key]
		if edge then
			table.insert(edge.triangles, triangleId)
		else
			mEdges[key] = {
				key = key,
				v1 = math.min(v1, v2),
				v2 = math.max(v1, v2),
				triangles = { triangleId },
			}
		end
	end

	local function removeEdge(v1: number, v2: number, triangleId: number)
		local key = edgeKey(v1, v2)
		local edge = mEdges[key]
		if edge then
			local idx = table.find(edge.triangles, triangleId)
			if idx then
				table.remove(edge.triangles, idx)
			end
			if #edge.triangles == 0 then
				mEdges[key] = nil
			end
		end
	end

	local function cleanupVertex(vertexId: number)
		local vertex = mVertices[vertexId]
		if vertex and #vertex.triangles == 0 then
			mPositionToVertex[positionKey(vertex.position)] = nil
			mVertices[vertexId] = nil
		end
	end

	local function computeNormal(v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3): Vector3
		local ab = v2Pos - v1Pos
		local ac = v3Pos - v1Pos
		local cross = ab:Cross(ac)
		if cross.Magnitude < 0.0001 then
			return Vector3.yAxis
		end
		return cross.Unit
	end

	local function registerTriangle(vertexIds: { number }, parts: { BasePart }): number
		local triangleId = mNextTriangleId
		mNextTriangleId += 1

		local v1Pos = mVertices[vertexIds[1]].position
		local v2Pos = mVertices[vertexIds[2]].position
		local v3Pos = mVertices[vertexIds[3]].position

		mTriangles[triangleId] = {
			id = triangleId,
			vertices = { vertexIds[1], vertexIds[2], vertexIds[3] },
			parts = parts,
			normal = computeNormal(v1Pos, v2Pos, v3Pos),
		}

		-- Add triangle reference to vertices
		for _, vid in vertexIds do
			table.insert(mVertices[vid].triangles, triangleId)
		end

		-- Add edges
		addEdge(vertexIds[1], vertexIds[2], triangleId)
		addEdge(vertexIds[2], vertexIds[3], triangleId)
		addEdge(vertexIds[3], vertexIds[1], triangleId)

		-- Track parts
		for _, part in parts do
			mPartToTriangle[part] = triangleId
		end

		return triangleId
	end

	local function unregisterTriangle(triangleId: number)
		local tri = mTriangles[triangleId]
		if not tri then
			return
		end

		-- Remove part tracking
		for _, part in tri.parts do
			mPartToTriangle[part] = nil
		end

		-- Remove from vertices
		for _, vid in tri.vertices do
			local vertex = mVertices[vid]
			if vertex then
				local idx = table.find(vertex.triangles, triangleId)
				if idx then
					table.remove(vertex.triangles, idx)
				end
			end
		end

		-- Remove edges
		removeEdge(tri.vertices[1], tri.vertices[2], triangleId)
		removeEdge(tri.vertices[2], tri.vertices[3], triangleId)
		removeEdge(tri.vertices[3], tri.vertices[1], triangleId)

		mTriangles[triangleId] = nil
	end

	local mesh: TriangleMesh = {} :: any

	mesh.getVertices = function()
		return mVertices
	end

	mesh.getTriangles = function()
		return mTriangles
	end

	mesh.getEdges = function()
		return mEdges
	end

	mesh.getVertex = function(id: number)
		return mVertices[id]
	end

	mesh.getTriangle = function(id: number)
		return mTriangles[id]
	end

	mesh.getBoundaryEdges = function(): { Edge }
		local boundary: { Edge } = {}
		for _, edge in mEdges do
			if #edge.triangles == 1 then
				table.insert(boundary, edge)
			end
		end
		return boundary
	end

	mesh.getVertexNeighbors = function(vertexId: number): { number }
		local neighbors: { [number]: boolean } = {}
		local vertex = mVertices[vertexId]
		if not vertex then
			return {}
		end
		for _, triId in vertex.triangles do
			local tri = mTriangles[triId]
			if tri then
				for _, vid in tri.vertices do
					if vid ~= vertexId then
						neighbors[vid] = true
					end
				end
			end
		end
		local result: { number } = {}
		for vid in neighbors do
			table.insert(result, vid)
		end
		return result
	end

	mesh.getAdjacentTriangles = function(triangleId: number): { number }
		local tri = mTriangles[triangleId]
		if not tri then
			return {}
		end
		local adjacent: { [number]: boolean } = {}
		local verts = tri.vertices
		-- Check all 3 edges of the triangle
		for i = 1, 3 do
			local v1 = verts[i]
			local v2 = verts[if i == 3 then 1 else i + 1]
			local key = edgeKey(v1, v2)
			local edge = mEdges[key]
			if edge then
				for _, otherTriId in edge.triangles do
					if otherTriId ~= triangleId then
						adjacent[otherTriId] = true
					end
				end
			end
		end
		local result: { number } = {}
		for triId in adjacent do
			table.insert(result, triId)
		end
		return result
	end

	mesh.findTrianglesInRadius = function(center: Vector3, radius: number): { number }
		local result: { number } = {}
		for triId, tri in mTriangles do
			-- Check if any vertex of the triangle is within the radius
			for _, vid in tri.vertices do
				local v = mVertices[vid]
				if v and (v.position - center).Magnitude <= radius then
					table.insert(result, triId)
					break
				end
			end
		end
		return result
	end

	mesh.findVertexNear = function(position: Vector3, radius: number): number?
		local bestId: number? = nil
		local bestDist = radius
		for _, vertex in mVertices do
			local dist = (vertex.position - position).Magnitude
			if dist < bestDist then
				bestDist = dist
				bestId = vertex.id
			end
		end
		return bestId
	end

	mesh.addTriangle = function(v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?): number?
		local vid1 = findOrCreateVertex(v1Pos)
		local vid2 = findOrCreateVertex(v2Pos)
		local vid3 = findOrCreateVertex(v3Pos)

		-- Don't create degenerate triangles
		if vid1 == vid2 or vid2 == vid3 or vid1 == vid3 then
			return nil
		end

		local parts = fillTriangle(
			mVertices[vid1].position,
			mVertices[vid2].position,
			mVertices[vid3].position,
			thickness, parent, props
		)

		if #parts == 0 then
			-- Clean up vertices that might have been created
			cleanupVertex(vid1)
			cleanupVertex(vid2)
			cleanupVertex(vid3)
			return nil
		end

		return registerTriangle({ vid1, vid2, vid3 }, parts)
	end

	mesh.removeTriangle = function(triangleId: number)
		local tri = mTriangles[triangleId]
		if not tri then
			return
		end

		-- Remove parts from workspace (Parent=nil instead of Destroy for undo compatibility)
		for _, part in tri.parts do
			part.Parent = nil
		end

		-- Save vertex ids before unregistering
		local vids = { tri.vertices[1], tri.vertices[2], tri.vertices[3] }

		unregisterTriangle(triangleId)

		-- Clean up orphaned vertices
		for _, vid in vids do
			cleanupVertex(vid)
		end
	end

	mesh.moveVertex = function(vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?)
		mesh.moveVertices({ [vertexId] = newPosition }, thickness, props)
	end

	mesh.moveVertices = function(moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?)
		-- 1. Collect all unique affected triangle IDs
		local affectedTriIds: { [number]: boolean } = {}
		for vid in moves do
			local vertex = mVertices[vid]
			if vertex then
				for _, triId in vertex.triangles do
					affectedTriIds[triId] = true
				end
			end
		end

		-- 2. Update all vertex positions at once
		for vid, newPosition in moves do
			local vertex = mVertices[vid]
			if vertex then
				local oldKey = positionKey(vertex.position)
				mPositionToVertex[oldKey] = nil
				vertex.position = snapPosition(newPosition, SNAP_EPSILON)
				local newKey = positionKey(vertex.position)
				mPositionToVertex[newKey] = vid
			end
		end

		-- 3. Update each affected triangle in-place
		for triId in affectedTriIds do
			local tri = mTriangles[triId]
			if tri then
				local v1 = mVertices[tri.vertices[1]]
				local v2 = mVertices[tri.vertices[2]]
				local v3 = mVertices[tri.vertices[3]]

				if v1 and v2 and v3 then
					local parent = tri.parts[1].Parent or workspace
					local newParts = fillTriangle(
						v1.position, v2.position, v3.position,
						thickness, parent, props, tri.parts
					)

					if #newParts > 0 then
						-- Update part tracking
						for _, oldPart in tri.parts do
							mPartToTriangle[oldPart] = nil
						end
						tri.parts = newParts
						for _, newPart in newParts do
							mPartToTriangle[newPart] = triId
						end
						tri.normal = computeNormal(v1.position, v2.position, v3.position)
					else
						-- Triangle became degenerate — parts already parented-out by fillTriangle
						local vids = { tri.vertices[1], tri.vertices[2], tri.vertices[3] }
						unregisterTriangle(triId)
						for _, vid in vids do
							cleanupVertex(vid)
						end
					end
				end
			end
		end
	end

	mesh.scanWorkspace = function(root: Instance?)
		mesh.clear()

		local scanRoot = root or workspace
		for _, desc in scanRoot:GetDescendants() do
			if not mPartToTriangle[desc] and isThinWedge(desc) then
				mesh.discoverPart(desc :: BasePart)
			end
		end
	end

	mesh.clear = function()
		mVertices = {}
		mTriangles = {}
		mEdges = {}
		mPositionToVertex = {}
		mPartToTriangle = {}
		mNextVertexId = 1
		mNextTriangleId = 1
	end

	-- Try to pair two sets of wedge vertices into a fillTriangle pair.
	-- Returns the 3 corner vertex positions if they form a pair, nil otherwise.
	local function tryPairWedges(verts1: { Vector3 }, verts2: { Vector3 }): { Vector3 }?
		-- Count shared vertices
		local sharedVerts: { Vector3 } = {}
		local uniqueFrom1: { Vector3 } = {}
		local uniqueFrom2: { Vector3 } = {}

		for _, va in verts1 do
			local isShared = false
			for _, vb in verts2 do
				if (va - vb).Magnitude < SNAP_EPSILON * 2 then
					isShared = true
					table.insert(sharedVerts, va)
					break
				end
			end
			if not isShared then
				table.insert(uniqueFrom1, va)
			end
		end
		for _, vb in verts2 do
			local isShared = false
			for _, shared in sharedVerts do
				if (vb - shared).Magnitude < SNAP_EPSILON * 2 then
					isShared = true
					break
				end
			end
			if not isShared then
				table.insert(uniqueFrom2, vb)
			end
		end

		-- Two wedges from fillTriangle share exactly 2 vertices
		if #sharedVerts ~= 2 or #uniqueFrom1 ~= 1 or #uniqueFrom2 ~= 1 then
			return nil
		end

		-- Check coplanarity
		local normal1 = computeNormal(sharedVerts[1], sharedVerts[2], uniqueFrom1[1])
		local toOther = uniqueFrom2[1] - sharedVerts[1]
		local planeDist = math.abs(toOther:Dot(normal1))
		if planeDist >= SNAP_EPSILON * 10 then
			return nil
		end

		-- Coplanar wedges sharing 2 vertices could be:
		-- (a) Two halves of the same fillTriangle (split point on line U1-U2)
		-- (b) Two separate triangles that share an edge
		local u1 = uniqueFrom1[1]
		local u2 = uniqueFrom2[1]
		local edgeDir = u2 - u1
		local edgeLen = edgeDir.Magnitude
		if edgeLen <= 0.001 then
			return nil
		end

		local edgeUnit = edgeDir / edgeLen
		local splitVertex: Vector3? = nil
		local cornerVertex: Vector3? = nil

		for _, sv in sharedVerts do
			local toSv = sv - u1
			local proj = toSv:Dot(edgeUnit)
			local perpDist = (toSv - edgeUnit * proj).Magnitude
			if perpDist < SNAP_EPSILON * 4 and proj > SNAP_EPSILON and proj < edgeLen - SNAP_EPSILON then
				splitVertex = sv
			else
				cornerVertex = sv
			end
		end

		if splitVertex and cornerVertex then
			-- Case (a): fillTriangle pair. Corners are U1, U2, cornerVertex.
			return { u1, u2, cornerVertex }
		end

		return nil
	end

	mesh.getPartTriangle = function(part: BasePart): number?
		return mPartToTriangle[part]
	end

	mesh.discoverPart = function(part: BasePart): number?
		-- Cache hit: already tracked
		local existing = mPartToTriangle[part]
		if existing then
			return existing
		end

		-- Must be a thin wedge
		if not isThinWedge(part) then
			return nil
		end

		local v1a, v1b, v1c = getWedgeVertices(part)
		local verts1 = { v1a, v1b, v1c }

		-- Spatial query to find candidate partners
		local maxDim = math.max(part.Size.X, part.Size.Y, part.Size.Z)
		local candidates = workspace:GetPartBoundsInRadius(part.CFrame.Position, maxDim * 2)

		for _, candidate in candidates do
			if candidate == part then continue end
			if not isThinWedge(candidate) then continue end

			-- Skip already-paired parts (part of a 2-wedge triangle)
			local candidateTriId = mPartToTriangle[candidate]
			if candidateTriId then
				local candidateTri = mTriangles[candidateTriId]
				if candidateTri and #candidateTri.parts == 2 then
					continue
				end
			end

			local v2a, v2b, v2c = getWedgeVertices(candidate)
			local verts2 = { v2a, v2b, v2c }

			local corners = tryPairWedges(verts1, verts2)
			if corners then
				-- If candidate was a single-wedge triangle, unregister it
				if candidateTriId then
					local oldTri = mTriangles[candidateTriId]
					if oldTri then
						local oldVids = { oldTri.vertices[1], oldTri.vertices[2], oldTri.vertices[3] }
						unregisterTriangle(candidateTriId)
						for _, vid in oldVids do
							cleanupVertex(vid)
						end
					end
				end

				local vid1 = findOrCreateVertex(corners[1])
				local vid2 = findOrCreateVertex(corners[2])
				local vid3 = findOrCreateVertex(corners[3])

				if vid1 ~= vid2 and vid2 ~= vid3 and vid1 ~= vid3 then
					return registerTriangle({ vid1, vid2, vid3 }, { part, candidate })
				end
			end
		end

		-- No partner found — register as single-wedge triangle
		local vid1 = findOrCreateVertex(v1a)
		local vid2 = findOrCreateVertex(v1b)
		local vid3 = findOrCreateVertex(v1c)

		if vid1 ~= vid2 and vid2 ~= vid3 and vid1 ~= vid3 then
			return registerTriangle({ vid1, vid2, vid3 }, { part })
		end

		return nil
	end

	mesh.discoverRegion = function(center: Vector3, radius: number)
		local candidates = workspace:GetPartBoundsInRadius(center, radius)
		for _, candidate in candidates do
			if not mPartToTriangle[candidate] and isThinWedge(candidate) then
				mesh.discoverPart(candidate)
			end
		end
	end

	mesh.refreshFromParts = function()
		local aliveParts: { BasePart } = {}
		for part in mPartToTriangle do
			if part.Parent then
				table.insert(aliveParts, part)
			end
		end

		mesh.clear()
		for _, part in aliveParts do
			if not mPartToTriangle[part] then
				mesh.discoverPart(part)
			end
		end
	end

	return mesh
end

return createTriangleMesh
