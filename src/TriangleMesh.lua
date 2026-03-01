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

local function createTriangleMesh(): TriangleMesh
	local mTriangles = {} :: {[TriangleId]: Triangle}
	local mVertices = {} :: {[VertexId]: Vertex}
	local mEdges = {} :: {[EdgeId]: Edge}

	-- Head of linked list of Triangles for a given part
	local mPartToTriangles = {} :: {[BasePart]: TriangleId}

	-- Spatial hash mapping of verts
	local mSpatialHash = {} :: {[VertexHash]: VertexId}

	-- Lookup edges by verts
	local mEdgeLookup = {} :: {[vector]: EdgeId}

	-- TODO: Implement methods
end

return createTriangleMesh
