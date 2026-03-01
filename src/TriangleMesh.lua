--!strict

local fillTriangle = require("./fillTriangle")

export type VertexId = number
export type TriangleId = number
export type EdgeId = number

-- Use Vector3 as a hash key for vertex positions, though this more granular
export type VertexHash = Vector3
export type EdgeHash = Vector3

export type Vertex = {
	id: VertexId,
	position: Vector3,
	triangles: { TriangleId },
}

export type Triangle = {
	id: TriangleId,

	-- Intrusive linked list of triangles associated with a particular part. Usually we
	-- only care about a single triangle per part and these will be empty. For
	-- a box part or a part we've explored both sides of there may be two or more.
	next: Triangle?,
	prev: Triangle?,

	-- Ordered such that (2 - 1) cross (3 - 2) is the outward normal
	vertices: { VertexId },
	normal: Vector3, -- Cached info, could be derived from vertices

	-- The parts making up this triangle
	parts: { BasePart },
	thickness: number,
	partsRequireUpgrade: boolean?, -- Actually a Block part that needs to be converted to Wedge parts
}

export type Edge = {
	id: EdgeId,

	triangles: { TriangleId },

	-- Order is not important
	v1: VertexId,
	v2: VertexId,
}

export type TriangleMesh = {
	-- Data access
	getVertices: () -> { [VertexId]: Vertex },
	getTriangles: () -> { [TriangleId]: Triangle },
	getEdges: () -> { [string]: Edge },
	getVertex: (id: VertexId) -> Vertex?,
	getTriangle: (id: TriangleId) -> Triangle?,

	-- Queries
	getBoundaryEdges: () -> { Edge },
	getVertexNeighbors: (vertexId: VertexId) -> { VertexId },
	findVertexNear: (position: Vector3, radius: number) -> VertexId?,

	-- Mutations
	addTriangle: (v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?, hintPoint: Vector3) -> number?,
	removeTriangle: (triangleId: number) -> (),
	moveVertex: (vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	moveVertices: (moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	setThicknessHint: (thickness: number) -> (),

	-- Queries (topology)
	getAdjacentTriangles: (triangleId: TriangleId) -> { TriangleId },
	findTrianglesInRadius: (center: Vector3, radius: number) -> { TriangleId },
	walkSurface: (seedTriangleId: TriangleId, center: Vector3, radius: number) -> ({ TriangleId }, { VertexId }),

	-- Discovery / Scanning
	discoverPart: (part: BasePart, hintPoint: Vector3) -> number?,
	discoverRegion: (seeds: { Vector3 }, radius: number) -> { TriangleId },
	getPartTriangle: (part: BasePart, hintPoint: Vector3) -> number?,
	getPartTriangles: (part: BasePart) -> { TriangleId },
	clear: () -> (),
}

local function hashVertex(position: Vector3): VertexHash
	local asVector = (position :: any) :: vector
	local result = (vector.floor((asVector / 0.01) + vector.one * 0.513456))
	return (result :: any) :: VertexHash
end

-- Order is not important, hashEdge(a, b) == hashEdge(b, a)
local function hashEdge(v1: Vector3, v2: Vector3): EdgeHash
	return hashVertex(v1) + hashVertex(v2)
end

local function createTriangleMesh(thicknessHint: number?): TriangleMesh
	thicknessHint = thicknessHint or 1.0

	local mTriangles = {} :: {[TriangleId]: Triangle}
	local mVertices = {} :: {[VertexId]: Vertex}
	local mEdges = {} :: {[EdgeId]: Edge}

	-- Head of linked list of Triangles for a given part
	local mPartToTriangles = {} :: {[BasePart]: TriangleId}

	-- Spatial hash mapping of verts
	local mSpatialHash = {} :: {[VertexHash]: VertexId}

	-- Lookup edges by verts
	local mEdgeLookup = {} :: {[vector]: EdgeId}

	local mNextVertexId = 1
	local mNextTriangleId = 1
	local mNextEdgeId = 1

	---------------------------------------------------------------------------
	-- Internal helpers
	---------------------------------------------------------------------------

	local function getOrCreateVertex(position: Vector3): VertexId
		local hash = hashVertex(position)
		local existing = mSpatialHash[hash]
		if existing then
			return existing
		end
		local id = mNextVertexId
		mNextVertexId += 1
		local vertex: Vertex = {
			id = id,
			position = position,
			triangles = {},
		}
		mVertices[id] = vertex
		mSpatialHash[hash] = id
		return id
	end

	local function getOrCreateEdge(v1Id: VertexId, v2Id: VertexId): EdgeId
		local v1 = mVertices[v1Id]
		local v2 = mVertices[v2Id]
		local hash = hashEdge(v1.position, v2.position)
		local existing = mEdgeLookup[hash]
		if existing then
			return existing
		end
		local id = mNextEdgeId
		mNextEdgeId += 1
		local edge: Edge = {
			id = id,
			triangles = {},
			v1 = v1Id,
			v2 = v2Id,
		}
		mEdges[id] = edge
		mEdgeLookup[hash] = id
		return id
	end

	local function computeNormal(v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3): Vector3
		local e1 = v2Pos - v1Pos
		local e2 = v3Pos - v2Pos
		local cross = e1:Cross(e2)
		local mag = cross.Magnitude
		if mag < 0.000001 then
			return Vector3.yAxis
		end
		return cross / mag
	end

	-- Link a triangle into the per-part linked list
	local function linkTriangleToPart(tri: Triangle, part: BasePart)
		local headId = mPartToTriangles[part]
		if headId then
			local head = mTriangles[headId]
			tri.next = head
			head.prev = tri
		end
		mPartToTriangles[part] = tri.id
	end

	-- Unlink a triangle from the per-part linked list
	local function unlinkTriangleFromPart(tri: Triangle, part: BasePart)
		if tri.prev then
			tri.prev.next = tri.next
		else
			-- This was the head
			if tri.next then
				mPartToTriangles[part] = tri.next.id
			else
				mPartToTriangles[part] = nil
			end
		end
		if tri.next then
			tri.next.prev = tri.prev
		end
		tri.prev = nil
		tri.next = nil
	end

	-- Remove edges that no longer have any triangles
	local function cleanupEdge(edgeId: EdgeId)
		local edge = mEdges[edgeId]
		if edge and #edge.triangles == 0 then
			local hash = hashEdge(mVertices[edge.v1].position, mVertices[edge.v2].position)
			mEdgeLookup[hash] = nil
			mEdges[edgeId] = nil
		end
	end

	-- Remove vertices that no longer belong to any triangles
	local function cleanupVertex(vertexId: VertexId)
		local vertex = mVertices[vertexId]
		if vertex and #vertex.triangles == 0 then
			local hash = hashVertex(vertex.position)
			mSpatialHash[hash] = nil
			mVertices[vertexId] = nil
		end
	end

	---------------------------------------------------------------------------
	-- Data access
	---------------------------------------------------------------------------

	local function getVertices(): {[VertexId]: Vertex}
		return mVertices
	end

	local function getTriangles(): {[TriangleId]: Triangle}
		return mTriangles
	end

	local function getEdges(): {[string]: Edge}
		return mEdges :: any
	end

	local function getVertex(id: VertexId): Vertex?
		return mVertices[id]
	end

	local function getTriangle(id: TriangleId): Triangle?
		return mTriangles[id]
	end

	---------------------------------------------------------------------------
	-- Queries
	---------------------------------------------------------------------------

	local function getBoundaryEdges(): {Edge}
		local result = {}
		for _, edge in mEdges do
			if #edge.triangles == 1 then
				table.insert(result, edge)
			end
		end
		return result
	end

	local function getVertexNeighbors(vertexId: VertexId): {VertexId}
		local seen = {} :: {[VertexId]: boolean}
		local result = {} :: {VertexId}
		local vertex = mVertices[vertexId]
		if not vertex then
			return result
		end
		for _, triId in vertex.triangles do
			local tri = mTriangles[triId]
			if tri then
				for _, vid in tri.vertices do
					if vid ~= vertexId and not seen[vid] then
						seen[vid] = true
						table.insert(result, vid)
					end
				end
			end
		end
		return result
	end

	local function findVertexNear(position: Vector3, radius: number): VertexId?
		local bestId: VertexId? = nil
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

	---------------------------------------------------------------------------
	-- Mutations
	---------------------------------------------------------------------------

	local function addTriangle(
		v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3,
		thickness: number, parent: Instance,
		props: fillTriangle.TriangleProps?, hintPoint: Vector3
	): number?
		-- Determine normal from winding, then check if we need to flip
		-- to face towards the hintPoint
		local natural = computeNormal(v1Pos, v2Pos, v3Pos)
		local centroid = (v1Pos + v2Pos + v3Pos) / 3
		local toHint = hintPoint - centroid
		local shouldInvert = natural:Dot(toHint) < 0

		-- Get or create vertices
		local v1Id = getOrCreateVertex(v1Pos)
		local v2Id = getOrCreateVertex(v2Pos)
		local v3Id = getOrCreateVertex(v3Pos)

		-- Determine vertex order for consistent normal direction
		local orderedVerts: {VertexId}
		local finalNormal: Vector3
		if shouldInvert then
			orderedVerts = {v1Id, v3Id, v2Id}
			finalNormal = -natural
		else
			orderedVerts = {v1Id, v2Id, v3Id}
			finalNormal = natural
		end

		-- Create the triangle parts via fillTriangle
		local invertNormal = shouldInvert
		local parts = fillTriangle(v1Pos, v2Pos, v3Pos, thickness, parent, props, nil, invertNormal)
		if #parts == 0 then
			return nil
		end

		-- Create triangle
		local triId = mNextTriangleId
		mNextTriangleId += 1
		local triangle: Triangle = {
			id = triId,
			vertices = orderedVerts,
			normal = finalNormal,
			parts = parts,
			thickness = thickness,
		}
		mTriangles[triId] = triangle

		-- Register triangle with vertices
		for _, vid in orderedVerts do
			table.insert(mVertices[vid].triangles, triId)
		end

		-- Create/update edges
		local vertPairs = {{orderedVerts[1], orderedVerts[2]}, {orderedVerts[2], orderedVerts[3]}, {orderedVerts[3], orderedVerts[1]}}
		for _, pair in vertPairs do
			local edgeId = getOrCreateEdge(pair[1], pair[2])
			table.insert(mEdges[edgeId].triangles, triId)
		end

		-- Link to parts
		for _, part in parts do
			linkTriangleToPart(triangle, part)
		end

		return triId
	end

	local function removeTriangle(triangleId: number)
		local tri = mTriangles[triangleId]
		if not tri then
			return
		end

		-- Unlink from parts and parent-out parts (not destroy)
		for _, part in tri.parts do
			unlinkTriangleFromPart(tri, part)
			-- Only parent-out if no other triangles reference this part
			if not mPartToTriangles[part] then
				part.Parent = nil
			end
		end

		-- Remove triangle from vertex lists
		for _, vid in tri.vertices do
			local vertex = mVertices[vid]
			if vertex then
				local idx = table.find(vertex.triangles, triangleId)
				if idx then
					table.remove(vertex.triangles, idx)
				end
			end
		end

		-- Remove triangle from edge lists and cleanup
		local verts = tri.vertices
		local vertPairs = {{verts[1], verts[2]}, {verts[2], verts[3]}, {verts[3], verts[1]}}
		for _, pair in vertPairs do
			local v1 = mVertices[pair[1]]
			local v2 = mVertices[pair[2]]
			if v1 and v2 then
				local hash = hashEdge(v1.position, v2.position)
				local edgeId = mEdgeLookup[hash]
				if edgeId then
					local edge = mEdges[edgeId]
					if edge then
						local idx = table.find(edge.triangles, triangleId)
						if idx then
							table.remove(edge.triangles, idx)
						end
						cleanupEdge(edgeId)
					end
				end
			end
		end

		-- Cleanup orphan vertices
		for _, vid in tri.vertices do
			cleanupVertex(vid)
		end

		mTriangles[triangleId] = nil
	end

	local function moveVertex(vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?)
		local vertex = mVertices[vertexId]
		if not vertex then
			return
		end

		-- Update spatial hash
		local oldHash = hashVertex(vertex.position)
		mSpatialHash[oldHash] = nil
		vertex.position = newPosition
		local newHash = hashVertex(newPosition)
		mSpatialHash[newHash] = vertexId

		-- Update edge hashes for all edges touching this vertex
		-- We need to remove old hashes and re-add with new position
		for _, triId in vertex.triangles do
			local tri = mTriangles[triId]
			if tri then
				local verts = tri.vertices
				local vertPairs = {{verts[1], verts[2]}, {verts[2], verts[3]}, {verts[3], verts[1]}}
				for _, pair in vertPairs do
					if pair[1] == vertexId or pair[2] == vertexId then
						local v1 = mVertices[pair[1]]
						local v2 = mVertices[pair[2]]
						if v1 and v2 then
							-- Old hash used old position for this vertex
							local otherVid = if pair[1] == vertexId then pair[2] else pair[1]
							local other = mVertices[otherVid]
							if other then
								local oldEdgeHash = hashEdge(vertex.position - (newPosition - vertex.position) + (newPosition - vertex.position), other.position)
								-- Actually we already changed vertex.position, so we need
								-- to compute what the old hash was. Let's just rebuild edges.
							end
						end
					end
				end
			end
		end

		-- Simpler approach: rebuild edge lookup for affected edges
		-- First collect all edge ids that touch this vertex
		local affectedEdges = {} :: {EdgeId}
		for edgeHash, edgeId in mEdgeLookup do
			local edge = mEdges[edgeId]
			if edge and (edge.v1 == vertexId or edge.v2 == vertexId) then
				table.insert(affectedEdges, edgeId)
				mEdgeLookup[edgeHash] = nil
			end
		end
		-- Re-insert with updated positions
		for _, edgeId in affectedEdges do
			local edge = mEdges[edgeId]
			if edge then
				local v1 = mVertices[edge.v1]
				local v2 = mVertices[edge.v2]
				if v1 and v2 then
					local newEdgeHash = hashEdge(v1.position, v2.position)
					mEdgeLookup[newEdgeHash] = edgeId
				end
			end
		end

		-- Rebuild all triangles touching this vertex
		for _, triId in vertex.triangles do
			local tri = mTriangles[triId]
			if tri then
				local v1 = mVertices[tri.vertices[1]]
				local v2 = mVertices[tri.vertices[2]]
				local v3 = mVertices[tri.vertices[3]]
				if v1 and v2 and v3 then
					-- Recompute normal
					tri.normal = computeNormal(v1.position, v2.position, v3.position)

					-- Determine if we need invertNormal for fillTriangle
					-- The natural normal from fillTriangle(a,b,c) points in the
					-- direction of (b-a):Cross(c-b). Our stored vertex order defines
					-- the desired normal. If the natural fillTriangle normal doesn't
					-- match our desired normal, we need invertNormal.
					local naturalNormal = computeNormal(v1.position, v2.position, v3.position)
					local shouldInvert = naturalNormal:Dot(tri.normal) < 0

					-- Rebuild parts in-place
					local parent = tri.parts[1].Parent
					local newParts = fillTriangle(
						v1.position, v2.position, v3.position,
						thickness, parent :: Instance, props, tri.parts, shouldInvert
					)
					tri.parts = newParts
					tri.thickness = thickness
				end
			end
		end
	end

	local function moveVertices(moves: {[number]: Vector3}, thickness: number, props: fillTriangle.TriangleProps?)
		for vertexId, newPosition in moves do
			moveVertex(vertexId, newPosition, thickness, props)
		end
	end

	local function setThicknessHint(thickness: number)
		thicknessHint = thickness
	end

	---------------------------------------------------------------------------
	-- Topology queries
	---------------------------------------------------------------------------

	local function getAdjacentTriangles(triangleId: TriangleId): {TriangleId}
		local tri = mTriangles[triangleId]
		if not tri then
			return {}
		end
		local result = {} :: {TriangleId}
		local seen = {[triangleId] = true}
		local verts = tri.vertices
		local vertPairs = {{verts[1], verts[2]}, {verts[2], verts[3]}, {verts[3], verts[1]}}
		for _, pair in vertPairs do
			local v1 = mVertices[pair[1]]
			local v2 = mVertices[pair[2]]
			if v1 and v2 then
				local hash = hashEdge(v1.position, v2.position)
				local edgeId = mEdgeLookup[hash]
				if edgeId then
					local edge = mEdges[edgeId]
					if edge then
						for _, adjTriId in edge.triangles do
							if not seen[adjTriId] then
								seen[adjTriId] = true
								table.insert(result, adjTriId)
							end
						end
					end
				end
			end
		end
		return result
	end

	local function findTrianglesInRadius(center: Vector3, radius: number): {TriangleId}
		local result = {} :: {TriangleId}
		local radiusSq = radius * radius
		for triId, tri in mTriangles do
			-- Check if any vertex is within radius
			for _, vid in tri.vertices do
				local v = mVertices[vid]
				if v and (v.position - center).Magnitude * (v.position - center).Magnitude <= radiusSq then
					table.insert(result, triId)
					break
				end
			end
		end
		return result
	end

	local function walkSurface(seedTriangleId: TriangleId, center: Vector3, radius: number): ({TriangleId}, {VertexId})
		local visitedTris = {[seedTriangleId] = true}
		local visitedVerts = {} :: {[VertexId]: boolean}
		local triResult = {seedTriangleId}
		local queue = {seedTriangleId}

		-- Collect vertices from seed
		local seedTri = mTriangles[seedTriangleId]
		if seedTri then
			for _, vid in seedTri.vertices do
				visitedVerts[vid] = true
			end
		end

		while #queue > 0 do
			local currentTriId = table.remove(queue, 1) :: TriangleId
			local adjacent = getAdjacentTriangles(currentTriId)
			for _, adjTriId in adjacent do
				if not visitedTris[adjTriId] then
					-- Check if any vertex of the adjacent triangle is within radius
					local adjTri = mTriangles[adjTriId]
					if adjTri then
						local inRadius = false
						for _, vid in adjTri.vertices do
							local v = mVertices[vid]
							if v and (v.position - center).Magnitude <= radius then
								inRadius = true
								break
							end
						end
						if inRadius then
							visitedTris[adjTriId] = true
							table.insert(triResult, adjTriId)
							table.insert(queue, adjTriId)
							for _, vid in adjTri.vertices do
								visitedVerts[vid] = true
							end
						end
					end
				end
			end
		end

		local vertResult = {} :: {VertexId}
		for vid in visitedVerts do
			table.insert(vertResult, vid)
		end

		return triResult, vertResult
	end

	---------------------------------------------------------------------------
	-- Discovery / Scanning
	---------------------------------------------------------------------------

	local getWedgeVertices = require("./getWedgeVertices")

	local function getPartTriangle(part: BasePart, hintPoint: Vector3): number?
		local headId = mPartToTriangles[part]
		if not headId then
			return nil
		end
		-- Walk the linked list finding the triangle whose normal best matches hintPoint
		local bestTriId: number? = nil
		local bestDot = -math.huge
		local currentTri: Triangle? = mTriangles[headId]
		while currentTri do
			local centroid = Vector3.zero
			for _, vid in currentTri.vertices do
				local v = mVertices[vid]
				if v then
					centroid += v.position
				end
			end
			centroid /= #currentTri.vertices
			local toHint = (hintPoint - centroid).Unit
			local dot = currentTri.normal:Dot(toHint)
			if dot > bestDot then
				bestDot = dot
				bestTriId = currentTri.id
			end
			currentTri = currentTri.next
		end
		return bestTriId
	end

	local function getPartTriangles(part: BasePart): {TriangleId}
		local result = {} :: {TriangleId}
		local headId = mPartToTriangles[part]
		if not headId then
			return result
		end
		local currentTri: Triangle? = mTriangles[headId]
		while currentTri do
			table.insert(result, currentTri.id)
			currentTri = currentTri.next
		end
		return result
	end

	local function discoverPart(part: BasePart, hintPoint: Vector3): number?
		-- Check if already discovered for this face
		local existing = getPartTriangle(part, hintPoint)
		if existing then
			return existing
		end

		if (part :: Part).Shape == Enum.PartType.Wedge then
			-- Get the triangle vertices from the wedge. Try both faces and
			-- prefer the one that shares more vertices with existing geometry
			-- (helps when hintPoint is ambiguous, e.g. on the surface plane).
			local hintA = part.CFrame.Position + part.CFrame.RightVector
			local hintB = part.CFrame.Position - part.CFrame.RightVector
			local v1a, v2a, v3a, thicknessA = getWedgeVertices(part, hintA)
			local v1b, v2b, v3b, thicknessB = getWedgeVertices(part, hintB)
			local matchA, matchB = 0, 0
			for _, vp in {v1a, v2a, v3a} do
				if mSpatialHash[hashVertex(vp)] then matchA += 1 end
			end
			for _, vp in {v1b, v2b, v3b} do
				if mSpatialHash[hashVertex(vp)] then matchB += 1 end
			end

			local v1, v2, v3, wedgeThickness
			if matchA > matchB then
				v1, v2, v3, wedgeThickness = v1a, v2a, v3a, thicknessA
			elseif matchB > matchA then
				v1, v2, v3, wedgeThickness = v1b, v2b, v3b, thicknessB
			else
				-- Tie: use hintPoint to decide
				v1, v2, v3, wedgeThickness = getWedgeVertices(part, hintPoint)
			end

			local natural = computeNormal(v1, v2, v3)
			local centroid = (v1 + v2 + v3) / 3
			local toHint = hintPoint - centroid
			local shouldInvert = natural:Dot(toHint) < 0

			local v1Id = getOrCreateVertex(v1)
			local v2Id = getOrCreateVertex(v2)
			local v3Id = getOrCreateVertex(v3)

			local orderedVerts: {VertexId}
			local finalNormal: Vector3
			if shouldInvert then
				orderedVerts = {v1Id, v3Id, v2Id}
				finalNormal = -natural
			else
				orderedVerts = {v1Id, v2Id, v3Id}
				finalNormal = natural
			end

			local triId = mNextTriangleId
			mNextTriangleId += 1
			local triangle: Triangle = {
				id = triId,
				vertices = orderedVerts,
				normal = finalNormal,
				parts = {part},
				thickness = wedgeThickness,
			}
			mTriangles[triId] = triangle

			-- Register with vertices
			for _, vid in orderedVerts do
				table.insert(mVertices[vid].triangles, triId)
			end

			-- Create edges
			local vertPairs = {{orderedVerts[1], orderedVerts[2]}, {orderedVerts[2], orderedVerts[3]}, {orderedVerts[3], orderedVerts[1]}}
			for _, pair in vertPairs do
				local edgeId = getOrCreateEdge(pair[1], pair[2])
				table.insert(mEdges[edgeId].triangles, triId)
			end

			-- Link to part
			linkTriangleToPart(triangle, part)

			-- Try to find an adjacent co-planar wedge to merge with
			-- Search near each vertex for other wedge parts
			local searchRadius = math.max(part.Size.X, part.Size.Y, part.Size.Z) * 1.5
			for _, vid in orderedVerts do
				local v = mVertices[vid]
				if not v then
					continue
				end
				local nearbyParts = workspace:GetPartBoundsInRadius(v.position, searchRadius)
				for _, nearPart in nearbyParts do
					if nearPart == part then
						continue
					end
					if not nearPart:IsA("Part") or (nearPart :: Part).Shape ~= Enum.PartType.Wedge then
						continue
					end
					-- Already discovered?
					if mPartToTriangles[nearPart] then
						continue
					end
					-- Check if this wedge shares exactly 2 vertices with THIS triangle.
					-- Try both faces of the neighbor and pick the one sharing more.
					-- Only count vertices shared with the current triangle, not all mesh vertices.
					local currentVertHashes = {} :: {[VertexHash]: boolean}
					for _, ovid in orderedVerts do
						local ov = mVertices[ovid]
						if ov then
							currentVertHashes[hashVertex(ov.position)] = true
						end
					end
					local hintA = nearPart.CFrame.Position + nearPart.CFrame.RightVector
					local hintB = nearPart.CFrame.Position - nearPart.CFrame.RightVector
					local nv1a, nv2a, nv3a = getWedgeVertices(nearPart, hintA)
					local nv1b, nv2b, nv3b = getWedgeVertices(nearPart, hintB)
					local sharedA, sharedB = 0, 0
					for _, nv in {nv1a, nv2a, nv3a} do
						if currentVertHashes[hashVertex(nv)] then sharedA += 1 end
					end
					for _, nv in {nv1b, nv2b, nv3b} do
						if currentVertHashes[hashVertex(nv)] then sharedB += 1 end
					end
					local nv1, nv2, nv3
					if sharedA >= sharedB then
						nv1, nv2, nv3 = nv1a, nv2a, nv3a
					else
						nv1, nv2, nv3 = nv1b, nv2b, nv3b
					end
					local neighborVerts = {nv1, nv2, nv3}
					local sharedCount = math.max(sharedA, sharedB)
					local unsharedNeighborVert: Vector3? = nil
					for _, nv in neighborVerts do
						local hash = hashVertex(nv)
						if not currentVertHashes[hash] then
							unsharedNeighborVert = nv
						end
					end
					if sharedCount == 2 and unsharedNeighborVert then
						-- Check co-planarity
						local neighborNormal = computeNormal(nv1, nv2, nv3)
						-- Co-planar if normals are parallel (or anti-parallel, they face same way from hint)
						if math.abs(finalNormal:Dot(neighborNormal)) > 0.99 then
							-- This is a co-planar wedge pair forming one triangle
							-- Merge: add the neighbor part to this triangle, extend with unshared vertex
							-- Actually, we need to replace the triangle with one that has all the right vertices
							-- The merged triangle uses the 2 shared verts + the unshared vert from this tri + unshared from neighbor
							-- Wait - two co-planar wedges with 2 shared vertices form a single larger triangle
							-- using: the unshared vertex from each + one of the shared vertices
							-- Actually no: two co-planar right-angle wedges sharing their hypotenuse
							-- form a single triangle whose vertices are the 3 non-shared vertices + shared ones
							-- Since each wedge is a right-angle triangle and they share 2 verts,
							-- the combined shape is a larger triangle with vertices = 3 unique vertices total

							-- Find the unshared vertex from our original triangle
							local ourUnsharedVert: Vector3? = nil
							for _, ovid in orderedVerts do
								local ov = mVertices[ovid]
								if ov then
									local isShared = false
									for _, nv in neighborVerts do
										if hashVertex(ov.position) == hashVertex(nv) then
											isShared = true
											break
										end
									end
									if not isShared then
										ourUnsharedVert = ov.position
										break
									end
								end
							end

							if ourUnsharedVert and unsharedNeighborVert then
								-- Two co-planar wedges from fillTriangle: they share 2 vertices
								-- (the cut point and C) and have 2 unshared (A and B).
								-- Total unique positions = 4. The cut point lies on edge AB
								-- and should be discarded, leaving 3 triangle vertices.

								-- Collect all unique vertex positions
								local allPositions = {} :: {Vector3}
								local posHashes = {} :: {[VertexHash]: boolean}
								local allVerts = {v1, v2, v3, nv1, nv2, nv3}
								for _, pos in allVerts do
									local h = hashVertex(pos)
									if not posHashes[h] then
										posHashes[h] = true
										table.insert(allPositions, pos)
									end
								end

								-- If 4 unique positions, find and remove the collinear one
								if #allPositions == 4 then
									-- Check each point for collinearity with each pair of others
									local removeIdx: number? = nil
									for i = 1, 4 do
										local pi = allPositions[i]
										for j = 1, 4 do
											if j == i then continue end
											for k = j + 1, 4 do
												if k == i then continue end
												local pj = allPositions[j]
												local pk = allPositions[k]
												local edge = pk - pj
												local edgeLen = edge.Magnitude
												if edgeLen < 0.001 then continue end
												local toP = pi - pj
												local cross = edge:Cross(toP)
												if cross.Magnitude / edgeLen < 0.01 then
													-- pi is collinear with pj-pk
													-- Check pi is BETWEEN pj and pk
													local t = toP:Dot(edge) / (edgeLen * edgeLen)
													if t > 0.001 and t < 0.999 then
														removeIdx = i
														break
													end
												end
											end
											if removeIdx then break end
										end
										if removeIdx then break end
									end
									if removeIdx then
										table.remove(allPositions, removeIdx)
									end
								end

								if #allPositions == 3 then
									-- Perfect - this is a single triangle made of 2 wedges
									-- Remove the current single-wedge triangle
									-- and re-create with both parts
									-- First, remove existing triangle data
									for _, ovid in orderedVerts do
										local ov = mVertices[ovid]
										if ov then
											local idx = table.find(ov.triangles, triId)
											if idx then
												table.remove(ov.triangles, idx)
											end
										end
									end
									local ePairs = {{orderedVerts[1], orderedVerts[2]}, {orderedVerts[2], orderedVerts[3]}, {orderedVerts[3], orderedVerts[1]}}
									for _, pair in ePairs do
										local ev1 = mVertices[pair[1]]
										local ev2 = mVertices[pair[2]]
										if ev1 and ev2 then
											local hash = hashEdge(ev1.position, ev2.position)
											local eid = mEdgeLookup[hash]
											if eid then
												local edge = mEdges[eid]
												local idx = table.find(edge.triangles, triId)
												if idx then
													table.remove(edge.triangles, idx)
												end
												cleanupEdge(eid)
											end
										end
									end
									unlinkTriangleFromPart(triangle, part)

									-- Cleanup orphan vertices from old triangle
									for _, ovid in orderedVerts do
										cleanupVertex(ovid)
									end

									-- Re-create merged triangle
									local mv1Id = getOrCreateVertex(allPositions[1])
									local mv2Id = getOrCreateVertex(allPositions[2])
									local mv3Id = getOrCreateVertex(allPositions[3])

									local mergedNatural = computeNormal(allPositions[1], allPositions[2], allPositions[3])
									local mergedCentroid = (allPositions[1] + allPositions[2] + allPositions[3]) / 3
									local mergedToHint = hintPoint - mergedCentroid
									local mergedInvert = mergedNatural:Dot(mergedToHint) < 0

									local mergedVerts: {VertexId}
									local mergedNormal: Vector3
									if mergedInvert then
										mergedVerts = {mv1Id, mv3Id, mv2Id}
										mergedNormal = -mergedNatural
									else
										mergedVerts = {mv1Id, mv2Id, mv3Id}
										mergedNormal = mergedNatural
									end

									triangle.vertices = mergedVerts
									triangle.normal = mergedNormal
									triangle.parts = {part, nearPart}

									mTriangles[triId] = triangle

									for _, vid in mergedVerts do
										table.insert(mVertices[vid].triangles, triId)
									end

									local mePairs = {{mergedVerts[1], mergedVerts[2]}, {mergedVerts[2], mergedVerts[3]}, {mergedVerts[3], mergedVerts[1]}}
									for _, pair in mePairs do
										local eid = getOrCreateEdge(pair[1], pair[2])
										table.insert(mEdges[eid].triangles, triId)
									end

									linkTriangleToPart(triangle, part)
									linkTriangleToPart(triangle, nearPart)

									return triId
								end
							end
						end
					end
				end
			end

			return triId

		elseif (part :: Part).Shape == Enum.PartType.Block then
			-- Thin block: treat as two triangles (a quad split into 2 tris)
			local size = part.Size
			local cf = part.CFrame

			-- Find the thin dimension
			local dims = {size.X, size.Y, size.Z}
			local axes = {cf.RightVector, cf.UpVector, cf.LookVector}
			local minDim = math.huge
			local minIdx = 1
			for i, d in dims do
				if d < minDim then
					minDim = d
					minIdx = i
				end
			end

			local thinThickness = dims[minIdx]
			local localHint = cf:PointToObjectSpace(hintPoint)

			-- Get the quad corners on the face closest to hintPoint
			local halfSize = size / 2
			local corners: {Vector3}
			if minIdx == 1 then
				-- Thin along X
				local sign = if localHint.X >= 0 then 1 else -1
				local x = halfSize.X * sign
				corners = {
					cf:PointToWorldSpace(Vector3.new(x, -halfSize.Y, -halfSize.Z)),
					cf:PointToWorldSpace(Vector3.new(x, -halfSize.Y,  halfSize.Z)),
					cf:PointToWorldSpace(Vector3.new(x,  halfSize.Y,  halfSize.Z)),
					cf:PointToWorldSpace(Vector3.new(x,  halfSize.Y, -halfSize.Z)),
				}
			elseif minIdx == 2 then
				-- Thin along Y
				local sign = if localHint.Y >= 0 then 1 else -1
				local y = halfSize.Y * sign
				corners = {
					cf:PointToWorldSpace(Vector3.new(-halfSize.X, y, -halfSize.Z)),
					cf:PointToWorldSpace(Vector3.new( halfSize.X, y, -halfSize.Z)),
					cf:PointToWorldSpace(Vector3.new( halfSize.X, y,  halfSize.Z)),
					cf:PointToWorldSpace(Vector3.new(-halfSize.X, y,  halfSize.Z)),
				}
			else
				-- Thin along Z
				local sign = if localHint.Z >= 0 then 1 else -1
				local z = halfSize.Z * sign
				corners = {
					cf:PointToWorldSpace(Vector3.new(-halfSize.X, -halfSize.Y, z)),
					cf:PointToWorldSpace(Vector3.new( halfSize.X, -halfSize.Y, z)),
					cf:PointToWorldSpace(Vector3.new( halfSize.X,  halfSize.Y, z)),
					cf:PointToWorldSpace(Vector3.new(-halfSize.X,  halfSize.Y, z)),
				}
			end

			-- Create 2 triangles from the quad (split along diagonal 1-3)
			local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]

			-- Triangle 1: c1, c2, c3
			local v1Id = getOrCreateVertex(c1)
			local v2Id = getOrCreateVertex(c2)
			local v3Id = getOrCreateVertex(c3)
			local v4Id = getOrCreateVertex(c4)

			local faceNormal = computeNormal(c1, c2, c3)
			local faceCentroid = (c1 + c2 + c3 + c4) / 4
			local faceToHint = hintPoint - faceCentroid
			if faceNormal:Dot(faceToHint) < 0 then
				faceNormal = -faceNormal
			end

			-- Triangle 1
			local tri1Verts = {v1Id, v2Id, v3Id}
			local tri1Natural = computeNormal(c1, c2, c3)
			if tri1Natural:Dot(faceToHint) < 0 then
				tri1Verts = {v1Id, v3Id, v2Id}
				tri1Natural = -tri1Natural
			end
			local tri1Id = mNextTriangleId
			mNextTriangleId += 1
			local tri1: Triangle = {
				id = tri1Id,
				vertices = tri1Verts,
				normal = tri1Natural,
				parts = {part},
				thickness = thinThickness,
				partsRequireUpgrade = true,
			}
			mTriangles[tri1Id] = tri1
			for _, vid in tri1Verts do
				table.insert(mVertices[vid].triangles, tri1Id)
			end
			local e1Pairs = {{tri1Verts[1], tri1Verts[2]}, {tri1Verts[2], tri1Verts[3]}, {tri1Verts[3], tri1Verts[1]}}
			for _, pair in e1Pairs do
				local eid = getOrCreateEdge(pair[1], pair[2])
				table.insert(mEdges[eid].triangles, tri1Id)
			end
			linkTriangleToPart(tri1, part)

			-- Triangle 2
			local tri2Verts = {v1Id, v3Id, v4Id}
			local tri2Natural = computeNormal(c1, c3, c4)
			if tri2Natural:Dot(faceToHint) < 0 then
				tri2Verts = {v1Id, v4Id, v3Id}
				tri2Natural = -tri2Natural
			end
			local tri2Id = mNextTriangleId
			mNextTriangleId += 1
			local tri2: Triangle = {
				id = tri2Id,
				vertices = tri2Verts,
				normal = tri2Natural,
				parts = {part},
				thickness = thinThickness,
				partsRequireUpgrade = true,
			}
			mTriangles[tri2Id] = tri2
			for _, vid in tri2Verts do
				table.insert(mVertices[vid].triangles, tri2Id)
			end
			local e2Pairs = {{tri2Verts[1], tri2Verts[2]}, {tri2Verts[2], tri2Verts[3]}, {tri2Verts[3], tri2Verts[1]}}
			for _, pair in e2Pairs do
				local eid = getOrCreateEdge(pair[1], pair[2])
				table.insert(mEdges[eid].triangles, tri2Id)
			end
			linkTriangleToPart(tri2, part)

			return tri1Id
		end

		return nil
	end

	local function discoverRegion(seeds: {Vector3}, radius: number): {TriangleId}
		local discovered = {} :: {[TriangleId]: boolean}
		local result = {} :: {TriangleId}

		-- For each seed, find nearby parts and discover them
		for _, seed in seeds do
			local nearbyParts = workspace:GetPartBoundsInRadius(seed, radius)
			for _, part in nearbyParts do
				if not part:IsA("BasePart") then
					continue
				end
				-- Skip already-fully-discovered parts
				if mPartToTriangles[part] then
					-- Still add to results
					local triId = mPartToTriangles[part]
					local tri: Triangle? = mTriangles[triId]
					while tri do
						if not discovered[tri.id] then
							discovered[tri.id] = true
							table.insert(result, tri.id)
						end
						tri = tri.next
					end
					continue
				end

				-- Try to discover this part
				-- Use the seed as the hintPoint direction
				local triId = discoverPart(part, seed)
				if triId and not discovered[triId] then
					discovered[triId] = true
					table.insert(result, triId)
					-- If discovering the part created additional triangles (e.g., block),
					-- add those too
					local tri: Triangle? = mTriangles[triId]
					while tri do
						if not discovered[tri.id] then
							discovered[tri.id] = true
							table.insert(result, tri.id)
						end
						tri = tri.next
					end
				end
			end
		end

		-- Walk outward from discovered triangles along edges to find connected
		-- triangles that are also within radius
		local queue = table.clone(result)
		while #queue > 0 do
			local currentTriId = table.remove(queue, 1) :: TriangleId
			local adj = getAdjacentTriangles(currentTriId)
			for _, adjTriId in adj do
				if not discovered[adjTriId] then
					-- Check if any vertex is within radius of any seed
					local adjTri = mTriangles[adjTriId]
					if adjTri then
						local inRadius = false
						for _, vid in adjTri.vertices do
							local v = mVertices[vid]
							if v then
								for _, seed in seeds do
									if (v.position - seed).Magnitude <= radius then
										inRadius = true
										break
									end
								end
								if inRadius then
									break
								end
							end
						end
						if inRadius then
							discovered[adjTriId] = true
							table.insert(result, adjTriId)
							table.insert(queue, adjTriId)
						end
					end
				end
			end
		end

		return result
	end

	local function clear()
		table.clear(mTriangles)
		table.clear(mVertices)
		table.clear(mEdges)
		table.clear(mPartToTriangles)
		table.clear(mSpatialHash)
		table.clear(mEdgeLookup)
		mNextVertexId = 1
		mNextTriangleId = 1
		mNextEdgeId = 1
	end

	---------------------------------------------------------------------------
	-- Return the mesh interface
	---------------------------------------------------------------------------

	return {
		-- Data access
		getVertices = getVertices,
		getTriangles = getTriangles,
		getEdges = getEdges,
		getVertex = getVertex,
		getTriangle = getTriangle,

		-- Queries
		getBoundaryEdges = getBoundaryEdges,
		getVertexNeighbors = getVertexNeighbors,
		findVertexNear = findVertexNear,

		-- Mutations
		addTriangle = addTriangle,
		removeTriangle = removeTriangle,
		moveVertex = moveVertex,
		moveVertices = moveVertices,
		setThicknessHint = setThicknessHint,

		-- Topology queries
		getAdjacentTriangles = getAdjacentTriangles,
		findTrianglesInRadius = findTrianglesInRadius,
		walkSurface = walkSurface,

		-- Discovery / Scanning
		discoverPart = discoverPart,
		discoverRegion = discoverRegion,
		getPartTriangle = getPartTriangle,
		getPartTriangles = getPartTriangles,
		clear = clear,
	} :: TriangleMesh
end

return createTriangleMesh
