--!strict

local fillTriangle = require("./fillTriangle")
local getWedgeVertices = require("./getWedgeVertices")

local SNAP_EPSILON = 0.01
local THIN_THRESHOLD = 0.5

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

	-- Scanning
	scanWorkspace: (root: Instance?) -> (),
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

		return triangleId
	end

	local function unregisterTriangle(triangleId: number)
		local tri = mTriangles[triangleId]
		if not tri then
			return
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

		-- Destroy the parts
		for _, part in tri.parts do
			part:Destroy()
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
		local vertex = mVertices[vertexId]
		if not vertex then
			return
		end

		-- Collect all affected triangles
		local affectedTriIds = table.clone(vertex.triangles)

		-- Collect triangle data before destroying
		local triData: { { vids: { number }, parent: Instance } } = {}
		for _, triId in affectedTriIds do
			local tri = mTriangles[triId]
			if tri then
				local parent = tri.parts[1].Parent or workspace
				table.insert(triData, {
					vids = { tri.vertices[1], tri.vertices[2], tri.vertices[3] },
					parent = parent,
				})

				-- Destroy old parts
				for _, part in tri.parts do
					part:Destroy()
				end

				unregisterTriangle(triId)
			end
		end

		-- Update vertex position
		local oldKey = positionKey(vertex.position)
		mPositionToVertex[oldKey] = nil
		vertex.position = snapPosition(newPosition, SNAP_EPSILON)
		local newKey = positionKey(vertex.position)
		mPositionToVertex[newKey] = vertexId

		-- Recreate triangles with new geometry
		for _, data in triData do
			local positions = {}
			for _, vid in data.vids do
				local v = mVertices[vid]
				if v then
					table.insert(positions, v.position)
				end
			end

			if #positions == 3 then
				local parts = fillTriangle(positions[1], positions[2], positions[3], thickness, data.parent, props)
				if #parts > 0 then
					registerTriangle(data.vids, parts)
				end
			end
		end

		-- Clean up orphaned vertices (not the moved one)
		for _, data in triData do
			for _, vid in data.vids do
				if vid ~= vertexId then
					cleanupVertex(vid)
				end
			end
		end
	end

	mesh.moveVertices = function(moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?)
		-- Collect ALL unique affected triangles across all moved vertices
		local affectedTriIds: { [number]: boolean } = {}
		for vid in moves do
			local vertex = mVertices[vid]
			if vertex then
				for _, triId in vertex.triangles do
					affectedTriIds[triId] = true
				end
			end
		end

		-- Save triangle data before destroying
		local triData: { { vids: { number }, parent: Instance } } = {}
		for triId in affectedTriIds do
			local tri = mTriangles[triId]
			if tri then
				local parent = tri.parts[1].Parent or workspace
				table.insert(triData, {
					vids = { tri.vertices[1], tri.vertices[2], tri.vertices[3] },
					parent = parent,
				})

				for _, part in tri.parts do
					part:Destroy()
				end

				unregisterTriangle(triId)
			end
		end

		-- Update ALL vertex positions at once
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

		-- Recreate all triangles with updated positions
		for _, data in triData do
			local positions = {}
			for _, vid in data.vids do
				local v = mVertices[vid]
				if v then
					table.insert(positions, v.position)
				end
			end

			if #positions == 3 then
				local parts = fillTriangle(positions[1], positions[2], positions[3], thickness, data.parent, props)
				if #parts > 0 then
					registerTriangle(data.vids, parts)
				end
			end
		end

		-- Clean up orphaned vertices (not moved ones)
		local cleanedUp: { [number]: boolean } = {}
		for _, data in triData do
			for _, vid in data.vids do
				if not moves[vid] and not cleanedUp[vid] then
					cleanedUp[vid] = true
					cleanupVertex(vid)
				end
			end
		end
	end

	mesh.scanWorkspace = function(root: Instance?)
		mesh.clear()

		local scanRoot = root or workspace
		local wedgeParts: { BasePart } = {}

		-- Find all thin WedgeParts
		for _, desc in workspace:QueryDescendants("BasePart") :: {BasePart} do
			if desc:IsA("WedgePart") or (desc:IsA("Part") and desc.Shape == Enum.PartType.Wedge) then
				local size = desc.Size
				local minSize = math.min(size.X, size.Y, size.Z)
				if minSize < THIN_THRESHOLD then
					table.insert(wedgeParts, desc)
				end
			end
		end

		-- Group wedge parts into triangles by finding pairs that share 2 vertices
		-- and are coplanar (part of the same logical triangle from fillTriangle)
		local paired: { [BasePart]: boolean } = {}

		for i, wedge1 in wedgeParts do
			if paired[wedge1] then continue end

			local v1a, v1b, v1c = getWedgeVertices(wedge1)
			local verts1 = { v1a, v1b, v1c }

			-- Try to find a partner wedge
			local foundPartner = false
			for j = i + 1, #wedgeParts do
				local wedge2 = wedgeParts[j]
				if paired[wedge2] then continue end

				local v2a, v2b, v2c = getWedgeVertices(wedge2)
				local verts2 = { v2a, v2b, v2c }

				-- Count shared vertices
				local sharedCount = 0
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
				sharedCount = #sharedVerts

				-- Two wedges from fillTriangle share exactly 2 vertices
				if sharedCount == 2 and #uniqueFrom1 == 1 and #uniqueFrom2 == 1 then
					-- Check coplanarity
					local triVerts = { sharedVerts[1], sharedVerts[2], uniqueFrom1[1] }
					local normal1 = computeNormal(triVerts[1], triVerts[2], triVerts[3])
					local toOther = (uniqueFrom2[1] - sharedVerts[1])
					local planeDist = math.abs(toOther:Dot(normal1))

					if planeDist < SNAP_EPSILON * 10 then
						-- Coplanar wedges sharing 2 vertices could be:
						-- (a) Two halves of the same fillTriangle (split point on line U1-U2)
						-- (b) Two separate triangles that share an edge
						-- For case (a), one shared vertex is the split point D that lies
						-- on the segment between U1 and U2. The triangle corners are
						-- U1, U2, and the other shared vertex.
						local u1 = uniqueFrom1[1]
						local u2 = uniqueFrom2[1]
						local edgeDir = u2 - u1
						local edgeLen = edgeDir.Magnitude
						local splitVertex: Vector3? = nil
						local cornerVertex: Vector3? = nil

						if edgeLen > 0.001 then
							local edgeUnit = edgeDir / edgeLen
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
						end

						if splitVertex and cornerVertex then
							-- Case (a): fillTriangle pair. Corners are U1, U2, cornerVertex.
							local vid1 = findOrCreateVertex(u1)
							local vid2 = findOrCreateVertex(u2)
							local vid3 = findOrCreateVertex(cornerVertex)

							if vid1 ~= vid2 and vid2 ~= vid3 and vid1 ~= vid3 then
								registerTriangle({ vid1, vid2, vid3 }, { wedge1, wedge2 })
								paired[wedge1] = true
								paired[wedge2] = true
								foundPartner = true
								break
							end
						end
						-- Case (b): separate triangles sharing an edge, don't pair
					end
				end
			end

			-- If no partner found, register as a single-wedge triangle
			if not foundPartner and not paired[wedge1] then
				local vid1 = findOrCreateVertex(v1a)
				local vid2 = findOrCreateVertex(v1b)
				local vid3 = findOrCreateVertex(v1c)

				if vid1 ~= vid2 and vid2 ~= vid3 and vid1 ~= vid3 then
					registerTriangle({ vid1, vid2, vid3 }, { wedge1 })
				end
				paired[wedge1] = true
			end
		end
	end

	mesh.clear = function()
		mVertices = {}
		mTriangles = {}
		mEdges = {}
		mPositionToVertex = {}
		mNextVertexId = 1
		mNextTriangleId = 1
	end

	return mesh
end

return createTriangleMesh
