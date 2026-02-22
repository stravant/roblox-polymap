--!strict

local fillTriangle = require("./fillTriangle")
local getWedgeVertices = require("./getWedgeVertices")
local getBlockVertices = require("./getBlockVertices")

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

local function isThinBlock(instance: Instance): BasePart?
	if instance:IsA("Part") and (instance :: Part).Shape == Enum.PartType.Block then
		local size = (instance :: BasePart).Size
		local minSize = math.min(size.X, size.Y, size.Z)
		local maxSize = math.max(size.X, size.Y, size.Z)
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
	invertNormal: boolean,
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
	addTriangle: (v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?, invertNormal: boolean?) -> number?,
	removeTriangle: (triangleId: number) -> (),
	moveVertex: (vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	moveVertices: (moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?) -> (),

	-- Queries (topology)
	getAdjacentTriangles: (triangleId: number) -> { number },
	findTrianglesInRadius: (center: Vector3, radius: number) -> { number },
	walkSurface: (seedTriangleId: number, center: Vector3, radius: number) -> ({ number }, { number }),

	-- Discovery / Scanning
	discoverPart: (part: BasePart, hitNormal: Vector3?) -> number?,
	discoverRegion: (center: Vector3, radius: number) -> (),
	getPartTriangle: (part: BasePart, hitNormal: Vector3?) -> number?,
	scanWorkspace: (root: Instance?) -> (),
	refreshFromParts: () -> (),
	clear: () -> (),
}

local function snapPosition(position: Vector3, epsilon: number): Vector3
	local function snapComponent(v: number): number
		local rounded = math.round(v / epsilon) * epsilon
		if rounded == 0 then
			return 0
		end
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

-- Pick a consistent sign for a direction vector to select which face of a
-- wedge part to use. This is an odd function: f(-dir) = -f(dir), which
-- ensures both parts of a fillTriangle pair extract from the same face
-- even though their thin axes point in opposite directions.
-- Y is checked first because fillTriangle guarantees normal.Y > 0, so the
-- thin axis direction always has a nonzero Y component for non-vertical
-- triangles. For vertical walls (Y ≈ 0), Z then X break the tie.
local function consistentSign(dir: Vector3): number
	if dir.Y > 0.0001 then
		return 1
	elseif dir.Y < -0.0001 then
		return -1
	elseif dir.Z > 0.0001 then
		return 1
	elseif dir.Z < -0.0001 then
		return -1
	elseif dir.X > 0.0001 then
		return 1
	else
		return -1
	end
end

local function getThinAxisDir(part: BasePart): Vector3
	local size = part.Size
	local cf = part.CFrame
	if size.X <= size.Y and size.X <= size.Z then
		return cf.RightVector
	elseif size.Y <= size.X and size.Y <= size.Z then
		return cf.UpVector
	else
		return -cf.LookVector
	end
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

	-- Part -> triangle ID for the opposite (back) face of the wedge
	local mPartToTriangleBack: { [BasePart]: number } = {}

	-- Block part -> pair of triangle IDs (for Block parts that represent 2 triangles)
	local mBlockParts: { [BasePart]: { number } } = {}

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

	local function registerTriangle(vertexIds: { number }, parts: { BasePart }, isBackFace: boolean?, invertNormal: boolean?): number
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
			invertNormal = invertNormal or false,
		}

		-- Add triangle reference to vertices
		for _, vid in vertexIds do
			table.insert(mVertices[vid].triangles, triangleId)
		end

		-- Add edges
		addEdge(vertexIds[1], vertexIds[2], triangleId)
		addEdge(vertexIds[2], vertexIds[3], triangleId)
		addEdge(vertexIds[3], vertexIds[1], triangleId)

		-- Track parts in front or back face mapping
		local mapping = if isBackFace then mPartToTriangleBack else mPartToTriangle
		for _, part in parts do
			mapping[part] = triangleId
		end

		return triangleId
	end

	local function unregisterTriangle(triangleId: number)
		local tri = mTriangles[triangleId]
		if not tri then
			return
		end

		-- Remove part tracking (only if this triangle owns the mapping)
		for _, part in tri.parts do
			if mPartToTriangle[part] == triangleId then
				mPartToTriangle[part] = nil
			end
			if mPartToTriangleBack[part] == triangleId then
				mPartToTriangleBack[part] = nil
			end
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

	-- Walk the mesh surface starting from a seed triangle, discovering adjacent
	-- parts via small per-vertex spatial queries. Returns only geometry reachable
	-- by walking connectivity, so it stays on the intended surface.
	mesh.walkSurface = function(seedTriangleId: number, center: Vector3, radius: number): ({ number }, { number })
		local seedTri = mTriangles[seedTriangleId]
		if not seedTri then
			return {}, {}
		end

		local visitedVertices: { [number]: boolean } = {}
		local visitedTriangles: { [number]: boolean } = {}
		local queue: { number } = {} -- vertex id queue
		local queueHead = 1

		-- Seed with the seed triangle's vertices
		for _, vid in seedTri.vertices do
			if not visitedVertices[vid] then
				visitedVertices[vid] = true
				table.insert(queue, vid)
			end
		end
		visitedTriangles[seedTriangleId] = true

		-- BFS over vertices
		while queueHead <= #queue do
			local vid = queue[queueHead]
			queueHead += 1

			local vertex = mVertices[vid]
			if not vertex then continue end

			-- Discover undiscovered adjacent parts via small spatial query
			local candidates = workspace:GetPartBoundsInRadius(vertex.position, 5)
			for _, candidate in candidates do
				if not mPartToTriangle[candidate] and (isThinWedge(candidate) or isThinBlock(candidate)) then
					mesh.discoverPart(candidate)
				end
			end

			-- Visit all triangles touching this vertex
			for _, triId in vertex.triangles do
				if visitedTriangles[triId] then continue end
				visitedTriangles[triId] = true

				local tri = mTriangles[triId]
				if not tri then continue end

				-- Enqueue unvisited vertices from this triangle if within extended radius
				for _, triVid in tri.vertices do
					if not visitedVertices[triVid] then
						local triVertex = mVertices[triVid]
						if triVertex and (triVertex.position - center).Magnitude <= radius + 5 then
							visitedVertices[triVid] = true
							table.insert(queue, triVid)
						end
					end
				end
			end
		end

		-- Final filter: only include triangles with at least one vertex within radius,
		-- and only vertices within radius
		local resultTriangles: { number } = {}
		local resultVertices: { number } = {}
		local vertexInRadius: { [number]: boolean } = {}

		for vid in visitedVertices do
			local vertex = mVertices[vid]
			if vertex and (vertex.position - center).Magnitude <= radius then
				vertexInRadius[vid] = true
				table.insert(resultVertices, vid)
			end
		end

		for triId in visitedTriangles do
			local tri = mTriangles[triId]
			if tri then
				for _, vid in tri.vertices do
					if vertexInRadius[vid] then
						table.insert(resultTriangles, triId)
						break
					end
				end
			end
		end

		return resultTriangles, resultVertices
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

	mesh.addTriangle = function(v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?, invertNormal: boolean?): number?
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
			thickness, parent, props, nil, invertNormal
		)

		if #parts == 0 then
			-- Clean up vertices that might have been created
			cleanupVertex(vid1)
			cleanupVertex(vid2)
			cleanupVertex(vid3)
			return nil
		end

		return registerTriangle({ vid1, vid2, vid3 }, parts, nil, invertNormal)
	end

	mesh.removeTriangle = function(triangleId: number)
		local tri = mTriangles[triangleId]
		if not tri then
			return
		end

		-- If this triangle is part of a Block pair, upgrade the sibling to Wedges
		for _, part in tri.parts do
			local blockPair = mBlockParts[part]
			if blockPair then
				local siblingTriId = if blockPair[1] == triangleId then blockPair[2] else blockPair[1]
				local siblingTri = mTriangles[siblingTriId]

				if siblingTri then
					-- Capture appearance from the block before it's destroyed
					local parent = part.Parent or workspace
					local blockThickness = math.min(part.Size.X, part.Size.Y, part.Size.Z)
					local blockProps: fillTriangle.TriangleProps = {
						Color = part.Color,
						Material = part.Material,
						Transparency = part.Transparency,
					}

					local sv1 = mVertices[siblingTri.vertices[1]]
					local sv2 = mVertices[siblingTri.vertices[2]]
					local sv3 = mVertices[siblingTri.vertices[3]]
					if sv1 and sv2 and sv3 then
						local newParts = fillTriangle(
							sv1.position, sv2.position, sv3.position,
							blockThickness, parent, blockProps, nil, siblingTri.invertNormal
						)
						-- Update sibling's part tracking
						for _, oldPart in siblingTri.parts do
							if mPartToTriangle[oldPart] == siblingTriId then
								mPartToTriangle[oldPart] = nil
							end
							mPartToTriangleBack[oldPart] = nil
						end
						siblingTri.parts = newParts
						for _, newPart in newParts do
							mPartToTriangle[newPart] = siblingTriId
						end
					end
				end

				mBlockParts[part] = nil
				break -- A triangle has at most one block part
			end
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

		-- 2.5. Upgrade any Block parts to Wedges before the main update loop
		local upgradedTriIds: { [number]: boolean } = {}
		local blocksProcessed: { [BasePart]: boolean } = {}
		for triId in affectedTriIds do
			local tri = mTriangles[triId]
			if tri then
				for _, part in tri.parts do
					if mBlockParts[part] and not blocksProcessed[part] then
						blocksProcessed[part] = true
						local pairTriIds = mBlockParts[part]
						local parent = part.Parent or workspace
						local blockProps: fillTriangle.TriangleProps = {
							Color = part.Color,
							Material = part.Material,
							Transparency = part.Transparency,
						}

						-- Preserve the block's thickness
						local blockThickness = math.min(part.Size.X, part.Size.Y, part.Size.Z)

						-- Destroy the block part
						part.Parent = nil

						-- Create wedges for each triangle in the pair
						for _, pairTriId in pairTriIds do
							local pairTri = mTriangles[pairTriId]
							if pairTri then
								local pv1 = mVertices[pairTri.vertices[1]]
								local pv2 = mVertices[pairTri.vertices[2]]
								local pv3 = mVertices[pairTri.vertices[3]]
								if pv1 and pv2 and pv3 then
									local newParts = fillTriangle(
										pv1.position, pv2.position, pv3.position,
										blockThickness, parent, blockProps, nil, pairTri.invertNormal
									)
									-- Update part tracking
									for _, oldPart in pairTri.parts do
										if mPartToTriangle[oldPart] == pairTriId then
											mPartToTriangle[oldPart] = nil
										end
										mPartToTriangleBack[oldPart] = nil
									end
									pairTri.parts = newParts
									for _, newPart in newParts do
										mPartToTriangle[newPart] = pairTriId
									end
									pairTri.normal = computeNormal(pv1.position, pv2.position, pv3.position)
								end
							end
							upgradedTriIds[pairTriId] = true
						end

						mBlockParts[part] = nil
					end
				end
			end
		end

		-- 3. Update each affected triangle in-place (skip already-upgraded ones)
		for triId in affectedTriIds do
			if upgradedTriIds[triId] then continue end
			local tri = mTriangles[triId]
			if tri then
				local v1 = mVertices[tri.vertices[1]]
				local v2 = mVertices[tri.vertices[2]]
				local v3 = mVertices[tri.vertices[3]]

				if v1 and v2 and v3 then
					local parent = tri.parts[1].Parent or workspace
					local existingThickness = math.min(tri.parts[1].Size.X, tri.parts[1].Size.Y, tri.parts[1].Size.Z)
					local newParts = fillTriangle(
						v1.position, v2.position, v3.position,
						existingThickness, parent, props, tri.parts, tri.invertNormal
					)

					if #newParts > 0 then
						-- Update part tracking
						for _, oldPart in tri.parts do
							if mPartToTriangle[oldPart] == triId then
								mPartToTriangle[oldPart] = nil
							end
							mPartToTriangleBack[oldPart] = nil
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
			if not mPartToTriangle[desc] and (isThinWedge(desc) or isThinBlock(desc)) then
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
		mPartToTriangleBack = {}
		mBlockParts = {}
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

	mesh.getPartTriangle = function(part: BasePart, hitNormal: Vector3?): number?
		local frontTriId = mPartToTriangle[part]
		if not frontTriId or not hitNormal then
			return frontTriId
		end

		if not isThinWedge(part) then
			return frontTriId
		end

		-- Determine which face the hitNormal aligns with by checking the
		-- part's thin axis direction directly (not the stored triangle normal).
		local size = part.Size
		local cf = part.CFrame
		local thinAxisDir: Vector3
		if size.X <= size.Y and size.X <= size.Z then
			thinAxisDir = cf.RightVector
		elseif size.Y <= size.X and size.Y <= size.Z then
			thinAxisDir = cf.UpVector
		else
			thinAxisDir = -cf.LookVector
		end

		-- The front face was discovered using consistentSign (same as getWedgeVertices default).
		local frontSign = consistentSign(thinAxisDir)

		-- hitNormal aligns with +thinAxisDir means sign=+1, else sign=-1
		local hitSign = if hitNormal:Dot(thinAxisDir) > 0 then 1 else -1

		-- If the hit selects the same face as the front, return front
		if hitSign == frontSign then
			return frontTriId
		end

		-- Want the back face
		local backTriId = mPartToTriangleBack[part]
		if backTriId then
			return backTriId
		end

		-- Lazily create the back face triangle using hitNormal to select opposite face
		local bv1, bv2, bv3 = getWedgeVertices(part, hitNormal)
		local bvid1 = findOrCreateVertex(bv1)
		local bvid2 = findOrCreateVertex(bv2)
		local bvid3 = findOrCreateVertex(bv3)
		if bvid1 ~= bvid2 and bvid2 ~= bvid3 and bvid1 ~= bvid3 then
			backTriId = registerTriangle({ bvid1, bvid2, bvid3 }, { part }, true, true)
			return backTriId
		end

		return frontTriId
	end

	mesh.discoverPart = function(part: BasePart, hitNormal: Vector3?): number?
		-- Cache hit: already tracked
		local existing = mPartToTriangle[part]
		if existing then
			-- If hitNormal provided, delegate to getPartTriangle for face selection
			if hitNormal then
				return mesh.getPartTriangle(part, hitNormal)
			end
			return existing
		end

		-- Thin Block: split into 2 triangles sharing the same Block part
		if isThinBlock(part) then
			local va, vb, vc, vd = getBlockVertices(part)
			local vid1 = findOrCreateVertex(va)
			local vid2 = findOrCreateVertex(vb)
			local vid3 = findOrCreateVertex(vc)
			local vid4 = findOrCreateVertex(vd)

			-- Check for degenerate cases
			if vid1 == vid2 or vid2 == vid3 or vid3 == vid4 or vid4 == vid1
				or vid1 == vid3 or vid2 == vid4 then
				cleanupVertex(vid1)
				cleanupVertex(vid2)
				cleanupVertex(vid3)
				cleanupVertex(vid4)
				return nil
			end

			-- Register two triangles: diagonal split (v1,v2,v3) and (v1,v3,v4)
			local triId1 = registerTriangle({ vid1, vid2, vid3 }, { part })
			local triId2 = registerTriangle({ vid1, vid3, vid4 }, { part })
			mBlockParts[part] = { triId1, triId2 }
			return triId1
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
				-- If not all corners snap to existing vertices, try the
				-- opposite face. This handles adjacent vertical wall triangles
				-- with opposite normals, where the heuristic picks different
				-- faces for the two triangles.
				if next(mVertices) then
					local snapCount = 0
					for _, c in corners do
						if mPositionToVertex[positionKey(c)] then
							snapCount += 1
						end
					end
					if snapCount < 3 then
						local dir1 = getThinAxisDir(part)
						local dir2 = getThinAxisDir(candidate)
						local altV1a, altV1b, altV1c = getWedgeVertices(part, dir1 * -consistentSign(dir1))
						local altV2a, altV2b, altV2c = getWedgeVertices(candidate, dir2 * -consistentSign(dir2))
						local altCorners = tryPairWedges(
							{ altV1a, altV1b, altV1c },
							{ altV2a, altV2b, altV2c }
						)
						if altCorners then
							local altSnapCount = 0
							for _, c in altCorners do
								if mPositionToVertex[positionKey(c)] then
									altSnapCount += 1
								end
							end
							if altSnapCount > snapCount then
								corners = altCorners
							end
						end
					end
				end

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
			if not mPartToTriangle[candidate] and (isThinWedge(candidate) or isThinBlock(candidate)) then
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
