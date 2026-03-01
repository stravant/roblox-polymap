--!strict

local fillTriangle = require("./fillTriangle")

export type Vertex = {
	id: number,
	position: Vector3,
	triangles: { number }, -- triangle ids
}

export type Triangle = {
	id: number,
	thickness: number,
	vertices: { number }, -- 3 vertex ids
	parts: { BasePart }, -- 1-2 wedge parts
	normal: Vector3,
	invertedNormal: boolean, -- Does normal point the direction of (1->2) cross (2->3)?
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
	addTriangle: (v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?, hintPoint: Vector3) -> number?,
	removeTriangle: (triangleId: number) -> (),
	moveVertex: (vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	moveVertices: (moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?) -> (),

	-- Queries (topology)
	getAdjacentTriangles: (triangleId: number) -> { number },
	findTrianglesInRadius: (center: Vector3, radius: number) -> { number },
	walkSurface: (seedTriangleId: number, center: Vector3, radius: number) -> ({ number }, { number }),

	-- Discovery / Scanning
	discoverPart: (part: BasePart, hintPoint: Vector3) -> number?,
	discoverRegion: (seeds: { Vector3 }, radius: number) -> ({ number }, { number }),
	getPartTriangle: (part: BasePart, hintPoint: Vector3) -> number?,
	getPartTriangles: (part: BasePart) -> { number },
	clear: () -> (),
}

local function createTriangleMesh(): TriangleMesh
	-- TODO: Re-implement with better internals
	error("Not yet implemented")
end

return createTriangleMesh
