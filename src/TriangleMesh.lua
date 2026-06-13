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

-- Distance under which two positions are treated as the same vertex. Must stay
-- well below any part thickness so the two faces of a thin wedge never collapse.
local kVertexMergeTolerance = 0.02

local function hashVertex(position: Vector3): VertexHash
	local asVector = (position :: any) :: vector
	local result = (vector.floor((asVector / 0.01) + vector.one * 0.513456))
	return (result :: any) :: VertexHash
end

-- Order is not important, hashEdge(a, b) == hashEdge(b, a)
local function hashEdge(v1: Vector3, v2: Vector3): EdgeHash
	return hashVertex(v1) + hashVertex(v2)
end

-- The three edges of a triangle as ordered vertex-id pairs (1-2, 2-3, 3-1).
local function triangleEdgePairs(verts: { VertexId }): { { VertexId } }
	return {
		{ verts[1], verts[2] },
		{ verts[2], verts[3] },
		{ verts[3], verts[1] },
	}
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
		-- A position that should be the same vertex can land in a neighbouring
		-- hash cell when it sits on a cell boundary (two wedges meeting at an edge
		-- reconstruct the shared corner with tiny FP differences). Check adjacent
		-- cells for a near-duplicate before creating a new vertex.
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local nvid = mSpatialHash[hash + Vector3.new(dx, dy, dz)]
					if nvid then
						local nv = mVertices[nvid]
						if nv and (nv.position - position).Magnitude < kVertexMergeTolerance then
							mSpatialHash[hash] = nvid
							return nvid
						end
					end
				end
			end
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

	-- Upgrade a Block-backed triangle to use Wedge parts via fillTriangle.
	-- This replaces the block part with 1-2 wedge parts and clears the upgrade flag.
	-- If the block has other triangles linked (sibling quads), they are upgraded too.
	local function upgradeBlockTriangles(tri: Triangle, thickness: number, props: fillTriangle.TriangleProps?)
		local block = tri.parts[1]
		local parent = block.Parent

		-- Collect all triangles backed by this block
		local blockTriangles = {} :: {Triangle}
		local headId = mPartToTriangles[block]
		if headId then
			local current: Triangle? = mTriangles[headId]
			while current do
				table.insert(blockTriangles, current)
				current = current.next
			end
		end

		-- Upgrade each triangle
		for _, blockTri in blockTriangles do
			-- Unlink from the block
			unlinkTriangleFromPart(blockTri, block)

			-- Get vertex positions
			local v1 = mVertices[blockTri.vertices[1]]
			local v2 = mVertices[blockTri.vertices[2]]
			local v3 = mVertices[blockTri.vertices[3]]
			if not (v1 and v2 and v3) then
				continue
			end

			-- Determine if fillTriangle needs invertNormal
			local naturalNormal = computeNormal(v1.position, v2.position, v3.position)
			local shouldInvert = naturalNormal:Dot(blockTri.normal) < 0

			-- Create new wedge parts
			local newParts = fillTriangle(
				v1.position, v2.position, v3.position,
				thickness, parent :: Instance, props, nil, shouldInvert
			)

			-- Update triangle
			blockTri.parts = newParts
			blockTri.thickness = thickness
			blockTri.partsRequireUpgrade = nil

			-- Link new parts to this triangle
			for _, newPart in newParts do
				linkTriangleToPart(blockTri, newPart)
			end
		end

		-- Remove the block
		block.Parent = nil
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

	-- Returns edges keyed by "minVertexId_maxVertexId" -- the form callers build
	-- when they want to look up the edge between two known vertices (e.g.
	-- findNearestBoundaryEdge, Add-mode edge snapping). The internal mEdges table
	-- is keyed by numeric EdgeId, which those string lookups would never match.
	local function getEdges(): {[string]: Edge}
		local result = {} :: {[string]: Edge}
		for _, edge in mEdges do
			local key = tostring(math.min(edge.v1, edge.v2)) .. "_" .. tostring(math.max(edge.v1, edge.v2))
			result[key] = edge
		end
		return result
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
		local vertPairs = triangleEdgePairs(orderedVerts)
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

		-- If this is a Block-backed triangle, upgrade all siblings first
		-- so the remaining triangles get proper Wedge parts
		if tri.partsRequireUpgrade then
			upgradeBlockTriangles(tri, tri.thickness)
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
		local vertPairs = triangleEdgePairs(verts)
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

		-- Rebuild edge lookup for affected edges
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

		-- Upgrade any Block-backed triangles before rebuilding
		local triIds = table.clone(vertex.triangles)
		for _, triId in triIds do
			local tri = mTriangles[triId]
			if tri and tri.partsRequireUpgrade then
				upgradeBlockTriangles(tri, thickness, props)
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
		local vertPairs = triangleEdgePairs(verts)
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
		-- Only return if hintPoint is on the normal side of the triangle.
		-- Use a small negative tolerance to handle hints that are in the
		-- triangle's plane (dot ≈ 0) but have tiny floating point error.
		if bestDot >= -0.01 then
			return bestTriId
		end
		return nil
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

	-- Make every connected component consistently oriented: BFS the triangle
	-- adjacency graph and flip any neighbour whose winding disagrees (two
	-- consistently-oriented triangles traverse their shared edge in opposite
	-- directions). Per-hint orientation gets each triangle's outward side right
	-- but, with split wedges and incremental discovery, can disagree between
	-- neighbours; this pass reconciles them. The first triangle of each component
	-- (oriented toward the clicked side) sets that component's global direction.
	local function orientConsistently()
		local visited = {} :: {[TriangleId]: boolean}
		for startId in mTriangles do
			if visited[startId] then
				continue
			end
			visited[startId] = true
			local queue = { startId }
			local qh = 1
			while qh <= #queue do
				local tid = queue[qh]
				qh += 1
				local tri = mTriangles[tid]
				if not tri then
					continue
				end
				local verts = tri.vertices
				for i = 1, 3 do
					local j = if i == 3 then 1 else i + 1
					local va, vb = verts[i], verts[j]
					local pva, pvb = mVertices[va], mVertices[vb]
					if not (pva and pvb) then
						continue
					end
					local eid = mEdgeLookup[hashEdge(pva.position, pvb.position)]
					local edge = if eid then mEdges[eid] else nil
					if not edge then
						continue
					end
					for _, ntid in edge.triangles do
						local nt = mTriangles[ntid]
						if ntid ~= tid and nt and not visited[ntid] then
							visited[ntid] = true
							-- Inconsistent if the neighbour also traverses va -> vb.
							local sameDir = false
							for k = 1, 3 do
								local l = if k == 3 then 1 else k + 1
								if nt.vertices[k] == va and nt.vertices[l] == vb then
									sameDir = true
									break
								end
							end
							if sameDir then
								nt.vertices = { nt.vertices[1], nt.vertices[3], nt.vertices[2] }
								nt.normal = -nt.normal
							end
							table.insert(queue, ntid)
						end
					end
				end
			end
		end
	end

	local function discoverPart(part: BasePart, hintPoint: Vector3): number?
		-- Check if already discovered for this face
		local existing = getPartTriangle(part, hintPoint)
		if existing then
			return existing
		end

		if (part :: Part).Shape == Enum.PartType.Wedge then
			-- Get the triangle vertices from the wedge.
			-- If this part already has a discovered face, use hintPoint directly
			-- (we're discovering the other face). Otherwise, try both faces and
			-- prefer the one sharing more vertices with existing geometry.
			local v1, v2, v3, wedgeThickness
			if mPartToTriangles[part] then
				-- Part already has a face — use hintPoint to pick the other face
				v1, v2, v3, wedgeThickness = getWedgeVertices(part, hintPoint)
			else
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
				if matchA > matchB then
					v1, v2, v3, wedgeThickness = v1a, v2a, v3a, thicknessA
				elseif matchB > matchA then
					v1, v2, v3, wedgeThickness = v1b, v2b, v3b, thicknessB
				else
					v1, v2, v3, wedgeThickness = getWedgeVertices(part, hintPoint)
				end
			end

			local natural = computeNormal(v1, v2, v3)
			-- Orient the face normal toward the hint, measured from the PART
			-- CENTRE rather than the (coplanar) face centroid. A hint -- the click
			-- point, or an adjacent already-discovered vertex as the walk expands --
			-- lies in the face plane, so measuring from the centroid gives ~0 and a
			-- coin-flip orientation (the source of the "some go one way, some the
			-- other" flipping). The part centre sits half a thickness off the face,
			-- so hint - partCentre has a clean sign toward the clicked surface side,
			-- which then propagates outward through the walk.
			local toHint = hintPoint - part.Position
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
			local vertPairs = triangleEdgePairs(orderedVerts)
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
					-- Match coincident corners by DISTANCE, not exact hash. On a
					-- curved surface the two wedges' shared front corners differ by
					-- tiny FP amounts that can straddle hash cells, which mis-picked
					-- the neighbour's face and landed its corner on the back face.
					local currentPositions = {} :: {Vector3}
					for _, ovid in orderedVerts do
						local ov = mVertices[ovid]
						if ov then
							table.insert(currentPositions, ov.position)
						end
					end
					local function sharedWithCurrent(p: Vector3): boolean
						for _, cp in currentPositions do
							if (cp - p).Magnitude < kVertexMergeTolerance then
								return true
							end
						end
						return false
					end
					local hintA = nearPart.CFrame.Position + nearPart.CFrame.RightVector
					local hintB = nearPart.CFrame.Position - nearPart.CFrame.RightVector
					local nv1a, nv2a, nv3a = getWedgeVertices(nearPart, hintA)
					local nv1b, nv2b, nv3b = getWedgeVertices(nearPart, hintB)
					local sharedA, sharedB = 0, 0
					for _, nv in {nv1a, nv2a, nv3a} do
						if sharedWithCurrent(nv) then sharedA += 1 end
					end
					for _, nv in {nv1b, nv2b, nv3b} do
						if sharedWithCurrent(nv) then sharedB += 1 end
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
						if not sharedWithCurrent(nv) then
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
										if (ov.position - nv).Magnitude < kVertexMergeTolerance then
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
									-- Inherit orientation from the single-wedge triangle we just
									-- oriented (finalNormal). mergedNatural is a different winding
									-- than the single wedge, so re-deriving from the hint can flip
									-- the merged face relative to its neighbours.
									local mergedInvert = mergedNatural:Dot(finalNormal) < 0

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

		-- Track explored positions to avoid re-processing
		local explored = {} :: {[VertexHash]: boolean}

		-- Queue of positions to explore incrementally
		local exploreQueue = {} :: {Vector3}

		-- Helper: add a triangle to results and queue its unexplored vertices
		local function collectTriangle(triId: TriangleId)
			if discovered[triId] then return end
			discovered[triId] = true
			table.insert(result, triId)
			local tri = mTriangles[triId]
			if tri then
				for _, vid in tri.vertices do
					local v = mVertices[vid]
					if v then
						local h = hashVertex(v.position)
						if not explored[h] then
							table.insert(exploreQueue, v.position)
						end
					end
				end
			end
		end

		-- Helper: check if a vertex lies on a boundary edge (has an edge with < 2 triangles)
		local function isVertexOnBoundary(vertId: VertexId): boolean
			local vert = mVertices[vertId]
			if not vert then return false end
			for _, triId in vert.triangles do
				local tri = mTriangles[triId]
				if not tri then continue end
				local verts = tri.vertices
				for i = 1, 3 do
					local j = if i == 3 then 1 else i + 1
					if verts[i] == vertId or verts[j] == vertId then
						local ev1 = mVertices[verts[i]]
						local ev2 = mVertices[verts[j]]
						if ev1 and ev2 then
							local edgeHash = hashEdge(ev1.position, ev2.position)
							local edgeId = mEdgeLookup[edgeHash]
							if edgeId then
								local edge = mEdges[edgeId]
								if edge and #edge.triangles < 2 then
									return true
								end
							end
						end
					end
				end
			end
			return false
		end

		-- Helper: get adaptive search radius from a vertex's known parts
		local function getSearchRadius(vertId: VertexId?): number
			local kDefaultSearchRadius = 4.0
			local searchRadius = kDefaultSearchRadius
			if vertId then
				local vert = mVertices[vertId]
				if vert then
					for _, triId in vert.triangles do
						local tri = mTriangles[triId]
						if tri then
							for _, part in tri.parts do
								local maxSize = math.max(part.Size.X, part.Size.Y, part.Size.Z)
								searchRadius = math.max(searchRadius, maxSize * 1.5)
							end
						end
					end
				end
			end
			return searchRadius
		end

		-- Seed the queue with starting positions
		for _, seed in seeds do
			table.insert(exploreQueue, seed)
		end

		while #exploreQueue > 0 do
			local pos = table.remove(exploreQueue, 1) :: Vector3
			local posHash = hashVertex(pos)
			if explored[posHash] then continue end
			explored[posHash] = true

			-- Skip if outside radius of all seeds
			local withinRadius = false
			for _, seed in seeds do
				if (pos - seed).Magnitude <= radius then
					withinRadius = true
					break
				end
			end
			if not withinRadius then continue end

			-- Check if this is an already-known vertex
			local vertId = mSpatialHash[posHash]

			-- Walk existing topology from this vertex (cheap, no workspace query)
			if vertId then
				local vert = mVertices[vertId]
				if vert then
					for _, triId in vert.triangles do
						collectTriangle(triId)
					end
				end
			end

			-- Only do a workspace query if this is an unknown position (bootstrap)
			-- or a boundary vertex (may have undiscovered adjacent parts)
			if not vertId or isVertexOnBoundary(vertId) then
				-- Cap search radius so we don't discover parts beyond the requested region
				local distToClosestSeed = math.huge
				for _, seed in seeds do
					distToClosestSeed = math.min(distToClosestSeed, (pos - seed).Magnitude)
				end
				local remainingRadius = radius - distToClosestSeed
				local searchRadius = math.min(getSearchRadius(vertId), math.max(remainingRadius, 0))
				local nearbyParts = workspace:GetPartBoundsInRadius(pos, searchRadius)
				for _, part in nearbyParts do
					if not part:IsA("BasePart") then continue end
					-- Discover the part's face only if it has none yet. A region walk
					-- builds one coherent surface, so we must NOT create a part's
					-- second (back) face just because this explore point happens to
					-- sit behind a tilted wedge -- that is what cracked curved meshes.
					if not mPartToTriangles[part] then
						discoverPart(part, pos)
					end
					-- Collect the part's discovered face(s) (e.g. a Block's two tris).
					local headId = mPartToTriangles[part]
					if headId then
						local tri: Triangle? = mTriangles[headId]
						while tri do
							collectTriangle(tri.id)
							tri = tri.next
						end
					end
				end
			end
		end

		orientConsistently()
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
