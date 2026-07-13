--!strict

local RunService = game:GetService("RunService")

local fillTriangle = require("./fillTriangle")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local Signal = require(Packages.Signal)

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
	VertexChanged: typeof(Signal.new()),
	getTriangles: () -> { [TriangleId]: Triangle },
	getEdges: () -> { [string]: Edge },
	getVertex: (id: VertexId) -> Vertex?,
	getTriangle: (id: TriangleId) -> Triangle?,
	getGeneration: () -> number,
	getTopologyGeneration: () -> number,

	-- Queries
	getBoundaryEdges: () -> { Edge },
	getSetBoundaryEdges: (triangleIds: { TriangleId }) -> { Edge },
	getVertexNeighbors: (vertexId: VertexId) -> { VertexId },
	findVertexNear: (position: Vector3, radius: number) -> VertexId?,

	-- Mutations
	addTriangle: (v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3, thickness: number, parent: Instance, props: fillTriangle.TriangleProps?, hintPoint: Vector3) -> number?,
	removeTriangle: (triangleId: number, keepParts: boolean?) -> (),
	moveVertex: (vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	moveVertices: (moves: { [number]: Vector3 }, thickness: number, props: fillTriangle.TriangleProps?) -> (),
	mergeVertices: (survivorId: number, mergedId: number, position: Vector3, props: fillTriangle.TriangleProps?) -> boolean,
	mergeWedgeTriangles: (triId1: number, triId2: number, maxFootOffset: number, props: fillTriangle.TriangleProps?) -> boolean,
	setThicknessHint: (thickness: number) -> (),

	-- Queries (topology)
	getAdjacentTriangles: (triangleId: TriangleId) -> { TriangleId },
	findTrianglesInRadius: (center: Vector3, radius: number) -> { TriangleId },
	walkSurface: (seedTriangleId: TriangleId, center: Vector3, radius: number) -> ({ TriangleId }, { VertexId }),

	-- Discovery / Scanning
	discoverPart: (part: BasePart, hintPoint: Vector3, viewPoint: Vector3?, nearbyResolver: ((Vector3, number) -> { Instance })?) -> number?,
	discoverRegion: (seeds: { Vector3 }, radius: number, viewPoint: Vector3?) -> { TriangleId },
	getPartTriangle: (part: BasePart, hintPoint: Vector3) -> number?,
	getPartTriangles: (part: BasePart) -> { TriangleId },
	clear: () -> (),
	notifyVerticesChanged: (ids: { number }) -> (),

	-- External-change watching (Team Create staleness)
	PartsExternallyChanged: typeof(Signal.new()),
	markPartsEdited: (parts: { BasePart }) -> (),
	setWatchEnabled: (enabled: boolean) -> (),
	debugGetWatchStats: () -> WatchStats,
	destroy: () -> (),
}

export type WatchStats = {
	watchedParts: number,
	connects: number,
	disconnects: number,
	events: number,
	selfDropped: number,
	externalParts: number,
}

-- Distance under which two positions are treated as the same vertex. Must stay
-- well below any part thickness so the two faces of a thin wedge never collapse.
local kVertexMergeTolerance = 0.02

-- The eight unit sign vectors of a box's local corners, for indexing non-wedge
-- parts by their bounding-box corners during a bulk rebuild.
local BOX_CORNER_SIGNS = {
	Vector3.new(1, 1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, -1, -1),
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

-- The three edges of a triangle as ordered vertex-id pairs (1-2, 2-3, 3-1).
local function triangleEdgePairs(verts: { VertexId }): { { VertexId } }
	return {
		{ verts[1], verts[2] },
		{ verts[2], verts[3] },
		{ verts[3], verts[1] },
	}
end

-- A wedge-shaped part backing one triangle. PolyMap generates `Part`s with Shape == Wedge,
-- but the legacy `WedgePart` class has byte-for-byte identical wedge geometry (its triangular
-- faces are the +/-X faces, same slope), so getWedgeVertices reads either and fillTriangle can
-- resize/reposition either in place. We adopt both. CornerWedgePart/MeshPart are NOT wedges and
-- IsA("WedgePart") is false for them, so this stays exact.
local function isWedgePart(part: BasePart): boolean
	return part:IsA("WedgePart") or (part:IsA("Part") and (part :: Part).Shape == Enum.PartType.Wedge)
end

-- A thin Block part, adopted as a quad (two triangles) and upgraded to wedges on first edit.
local function isBlockPart(part: BasePart): boolean
	return part:IsA("Part") and (part :: Part).Shape == Enum.PartType.Block
end

-- watchParts (default true) connects a Changed listener to every part the mesh tracks,
-- so edits made by something OTHER than this plugin (another Team Create user, another
-- plugin, a manual property edit) can flush that part's stale discovery. Pass false to
-- measure the overhead of that watching, or for throwaway meshes that never live long
-- enough for external edits to matter.
local function createTriangleMesh(thicknessHint: number?, watchParts: boolean?): TriangleMesh
	thicknessHint = thicknessHint or 1.0
	local mWatchParts = watchParts ~= false

	local mTriangles = {} :: {[TriangleId]: Triangle}
	local mVertices = {} :: {[VertexId]: Vertex}
	local mEdges = {} :: {[EdgeId]: Edge}

	-- Head of linked list of Triangles for a given part
	local mPartToTriangles = {} :: {[BasePart]: TriangleId}

	-- Spatial hash mapping of verts
	local mSpatialHash = {} :: {[VertexHash]: VertexId}

	-- Lookup edges by verts
	local mEdgeLookup = {} :: {[vector]: EdgeId}

	-- Adjacency: the set of edges incident to each vertex. Maintained alongside mEdges
	-- (every edge is created in getOrCreateEdge and removed in cleanupEdge), so moveVertex
	-- can re-key just one vertex's edges in O(degree) instead of scanning all of them.
	local mVertexEdges = {} :: {[VertexId]: {[EdgeId]: boolean}}
	local function addVertexEdge(vertexId: VertexId, edgeId: EdgeId)
		local set = mVertexEdges[vertexId]
		if not set then
			set = {}
			mVertexEdges[vertexId] = set
		end
		set[edgeId] = true
	end

	-- Fired with a VertexId whenever that vertex is added, moved, or removed. The
	-- overlay's discovered-vertex display listens and updates just that one marker, so
	-- discovering or editing a few vertices never costs a rebuild of all of them.
	local mVertexChanged = Signal.new()

	-- Change counters, so callers can cache derived data (e.g. the session's influence
	-- outline) and recompute only when the mesh actually changed. The topology counter
	-- ticks when the vertex/triangle SET changes (add/remove/merge/discover/clear); the
	-- general counter also ticks on pure position moves. A handle drag moves vertices
	-- every frame without changing topology, so drag-stable caches key on the topology
	-- counter alone.
	local mGeneration = 0
	local mTopologyGeneration = 0

	-- Vertex-hash cells discoverRegion has probed against the workspace since the last
	-- mesh change, finding nothing new to adopt. While the mesh (and so the world
	-- geometry it manages) is unchanged, re-probing the same spot every hover frame is
	-- pure workspace-query overhead; any mesh change clears the memo.
	local mProbedClean = {} :: { [VertexHash]: boolean }

	local function bumpPositions()
		mGeneration += 1
		if next(mProbedClean) ~= nil then
			table.clear(mProbedClean)
		end
	end
	local function bumpTopology()
		mTopologyGeneration += 1
		bumpPositions()
	end

	local mNextVertexId = 1
	local mNextTriangleId = 1
	local mNextEdgeId = 1

	---------------------------------------------------------------------------
	-- External-change watching (Team Create staleness)
	---------------------------------------------------------------------------
	-- Every tracked part gets one part.Changed connection. The plugin's OWN writes fire
	-- that same signal, so parts the mesh is about to mutate are stamped in mSelfTouched
	-- and the handler drops their events; anything unstamped is an external edit (another
	-- Team Create user, another plugin, a manual property edit) and is queued for a
	-- once-per-Heartbeat batch that fires PartsExternallyChanged so the session can
	-- flush that part's discovery.
	--
	-- Stamps expire after two sweep frames: long enough to outlive the same frame's
	-- deferred Changed events (and immediate ones, which run synchronously inside the
	-- write), short enough that a later genuine external edit still gets through. The
	-- cost of the window: an external edit landing within ~2 frames of our own edit to
	-- the SAME part is treated as ours -- with two users editing the same part in the
	-- same instant, discovery is stale either way until one of them touches it again.
	--
	-- Disconnects are deferred to the sweep instead of happening inside
	-- unlinkTriangleFromPart: a drag rebuilds triangles every frame via
	-- relink (unlink + link of the SAME part), and eagerly disconnecting would
	-- reconnect every part's listener every frame.
	local mPartConnections = {} :: { [BasePart]: RBXScriptConnection }
	local mSelfTouched = {} :: { [BasePart]: number }
	local mPendingExternal = {} :: { [BasePart]: boolean }
	local mPendingDisconnect = {} :: { [BasePart]: boolean }
	local mSweepFrame = 0
	local mSweepScheduled = false
	local mPartsExternallyChanged = Signal.new()
	local mWatchStats: WatchStats = {
		watchedParts = 0,
		connects = 0,
		disconnects = 0,
		events = 0,
		selfDropped = 0,
		externalParts = 0,
	}

	local scheduleSweep: () -> ()

	local function watchSweep()
		mSweepScheduled = false
		mSweepFrame += 1
		for part in mPendingDisconnect do
			if not mPartToTriangles[part] then
				local cn = mPartConnections[part]
				if cn then
					cn:Disconnect()
					mPartConnections[part] = nil
					mWatchStats.watchedParts -= 1
					mWatchStats.disconnects += 1
				end
			end
		end
		table.clear(mPendingDisconnect)
		for part, stamp in mSelfTouched do
			if mSweepFrame - stamp >= 2 then
				mSelfTouched[part] = nil
			end
		end
		local external: { BasePart } = {}
		for part in mPendingExternal do
			-- A part that got untracked (or re-touched by us) since its event was queued
			-- is no longer stale from the mesh's point of view.
			if mPartToTriangles[part] and not mSelfTouched[part] then
				table.insert(external, part)
			end
		end
		table.clear(mPendingExternal)
		-- Keep sweeping while stamps remain so they eventually expire, even when the
		-- mesh goes quiet. Idle meshes have no stamps and schedule nothing.
		if next(mSelfTouched) ~= nil then
			scheduleSweep()
		end
		if #external > 0 then
			mWatchStats.externalParts += #external
			mPartsExternallyChanged:Fire(external)
		end
	end

	scheduleSweep = function()
		if not mSweepScheduled then
			mSweepScheduled = true
			RunService.Heartbeat:Once(watchSweep)
		end
	end

	-- Stamp parts the mesh (or the session, e.g. Paint) is about to write to, so their
	-- Changed events read as our own. Must be called BEFORE the writes: with immediate
	-- signal behavior the handler runs inside the write itself.
	local function markPartsEdited(parts: { BasePart })
		if not mWatchParts then
			return
		end
		for _, part in parts do
			mSelfTouched[part] = mSweepFrame
		end
		scheduleSweep()
	end

	local function watchPart(part: BasePart)
		if not mWatchParts or mPartConnections[part] then
			return
		end
		mWatchStats.watchedParts += 1
		mWatchStats.connects += 1
		mPartConnections[part] = part.Changed:Connect(function()
			mWatchStats.events += 1
			if mSelfTouched[part] then
				mWatchStats.selfDropped += 1
				return
			end
			mPendingExternal[part] = true
			scheduleSweep()
		end)
	end

	local function unwatchAllParts()
		for _, cn in mPartConnections do
			cn:Disconnect()
		end
		table.clear(mPartConnections)
		table.clear(mSelfTouched)
		table.clear(mPendingExternal)
		table.clear(mPendingDisconnect)
		mWatchStats.disconnects += mWatchStats.watchedParts
		mWatchStats.watchedParts = 0
	end

	-- Turn part watching on or off mid-session (the Multiuser Support toggle).
	-- Enabling attaches listeners to everything already tracked (stamped, so any
	-- in-flight events of our own don't read as external); disabling drops them all.
	local function setWatchEnabled(enabled: boolean)
		if mWatchParts == enabled then
			return
		end
		mWatchParts = enabled
		if enabled then
			for part in mPartToTriangles do
				mSelfTouched[part] = mSweepFrame
				watchPart(part)
			end
			scheduleSweep()
		else
			unwatchAllParts()
		end
	end

	---------------------------------------------------------------------------
	-- Internal helpers
	---------------------------------------------------------------------------

	local function getOrCreateVertex(position: Vector3): VertexId
		local hash = hashVertex(position)
		local existing = mSpatialHash[hash]
		if existing then
			if mVertices[existing] then
				return existing
			end
			-- Stale entry: a re-pointed neighbour cell (see the dedup below) can outlive the
			-- vertex it referenced, because cleanupVertex only clears the vertex's own cell.
			-- A full rediscover wipes the whole hash so this never surfaces, but a local
			-- re-discovery (undo) leaves the rest of the hash intact. Drop it and fall
			-- through rather than handing back a removed vertex id.
			mSpatialHash[hash] = nil
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
		bumpTopology()
		mVertexChanged:Fire(id)
		return id
	end

	-- Read-only tolerant lookup: the id of an existing vertex within
	-- kVertexMergeTolerance of position, or nil. Mirrors getOrCreateVertex's
	-- neighbour-cell search. Face-matching during discovery must use this rather
	-- than an exact mSpatialHash[hashVertex(p)] lookup: a tilted wedge reconstructs
	-- its shared corners with tiny FP error, so a corner that should coincide with
	-- an existing vertex can fall a hair into an adjacent hash cell. An exact miss
	-- there undercounts the surface face, ties the front/back vote, and lets
	-- discovery pick the back face -- which lands the corner a full thickness off
	-- its neighbours and cracks the mesh.
	local function findExistingVertexNear(position: Vector3): VertexId?
		local hash = hashVertex(position)
		local existing = mSpatialHash[hash]
		if existing then
			if mVertices[existing] then
				return existing
			end
			-- Drop a stale re-pointed cell rather than reporting a removed vertex (see
			-- getOrCreateVertex for why these can linger after a local re-discovery).
			mSpatialHash[hash] = nil
		end
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local nvid = mSpatialHash[hash + Vector3.new(dx, dy, dz)]
					if nvid then
						local nv = mVertices[nvid]
						if nv and (nv.position - position).Magnitude < kVertexMergeTolerance then
							return nvid
						end
					end
				end
			end
		end
		return nil
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
		addVertexEdge(v1Id, id)
		addVertexEdge(v2Id, id)
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
		if mWatchParts and not headId then
			-- Newly tracked. Adoption is our own doing, so stamp the part and drop any
			-- event already queued for it: after an undo, ChangeHistory's property
			-- reverts fire Changed BEFORE the undo handler re-discovers the region and
			-- re-adopts these same parts, and those events must not read as external.
			mSelfTouched[part] = mSweepFrame
			mPendingExternal[part] = nil
			watchPart(part)
			scheduleSweep()
		end
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
		if mWatchParts and not mPartToTriangles[part] then
			mPendingDisconnect[part] = true
			scheduleSweep()
		end
	end

	-- Reassign a triangle's parts, keeping mPartToTriangles in sync: unlink the
	-- old parts and link the new ones. A tilting triangle can change wedge count
	-- (1 <-> 2 wedges), and an unlinked new wedge would be rediscovered as a
	-- duplicate triangle on the next hover.
	local function relinkTriangleParts(tri: Triangle, newParts: { BasePart }): { BasePart }
		for _, oldPart in tri.parts do
			unlinkTriangleFromPart(tri, oldPart)
		end
		for _, newPart in newParts do
			linkTriangleToPart(tri, newPart)
		end
		return newParts
	end

	-- Remove edges that no longer have any triangles
	local function cleanupEdge(edgeId: EdgeId)
		local edge = mEdges[edgeId]
		if edge and #edge.triangles == 0 then
			local hash = hashEdge(mVertices[edge.v1].position, mVertices[edge.v2].position)
			mEdgeLookup[hash] = nil
			mEdges[edgeId] = nil
			local e1 = mVertexEdges[edge.v1]
			if e1 then
				e1[edgeId] = nil
			end
			local e2 = mVertexEdges[edge.v2]
			if e2 then
				e2[edgeId] = nil
			end
		end
	end

	-- Remove vertices that no longer belong to any triangles
	local function cleanupVertex(vertexId: VertexId)
		local vertex = mVertices[vertexId]
		if vertex and #vertex.triangles == 0 then
			local hash = hashVertex(vertex.position)
			mSpatialHash[hash] = nil
			mVertices[vertexId] = nil
			mVertexEdges[vertexId] = nil
			bumpTopology()
			mVertexChanged:Fire(vertexId)
		end
	end

	-- Upgrade a Block-backed triangle to use Wedge parts via fillTriangle.
	-- This replaces the block part with 1-2 wedge parts and clears the upgrade flag.
	-- If the block has other triangles linked (sibling quads), they are upgraded too.
	local function upgradeBlockTriangles(tri: Triangle, thickness: number)
		local block = tri.parts[1]
		local parent = block.Parent

		-- The generated wedges inherit the block's appearance, so converting a box
		-- to triangles is visually seamless rather than snapping to the default grey.
		local blockProps: fillTriangle.TriangleProps = {
			Color = block.Color,
			Material = block.Material,
			MaterialVariant = block.MaterialVariant,
			Transparency = block.Transparency,
		}

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
				thickness, parent :: Instance, blockProps, nil, shouldInvert
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

		-- Remove the block (our own edit: the block's Changed listener may still be
		-- live until the deferred-disconnect sweep runs)
		markPartsEdited({ block })
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

	-- Boundary edges of a SUBSET of triangles: an edge with at least one, but not all, of
	-- its incident triangles in the set (or a mesh-boundary edge that is in the set). Walks
	-- only the set's own edges via the position lookup, so it is O(set) -- the overlay
	-- calls this every frame while a selection is being dragged, so it must not scan every
	-- edge in the mesh.
	local function getSetBoundaryEdges(triangleIds: { TriangleId }): { Edge }
		local triSet: { [TriangleId]: boolean } = {}
		for _, triId in triangleIds do
			triSet[triId] = true
		end
		local result: { Edge } = {}
		local seen: { [EdgeId]: boolean } = {}
		for _, triId in triangleIds do
			local tri = mTriangles[triId]
			if tri then
				for _, pair in triangleEdgePairs(tri.vertices) do
					local pa = mVertices[pair[1]]
					local pb = mVertices[pair[2]]
					if pa and pb then
						local edgeId = mEdgeLookup[hashEdge(pa.position, pb.position)]
						if edgeId and not seen[edgeId] then
							seen[edgeId] = true
							local edge = mEdges[edgeId]
							if edge then
								local insideCount = 0
								for _, tid in edge.triangles do
									if triSet[tid] then
										insideCount += 1
									end
								end
								if (insideCount > 0 and insideCount < #edge.triangles) or (#edge.triangles == 1 and insideCount == 1) then
									table.insert(result, edge)
								end
							end
						end
					end
				end
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
		-- Fast path: a vertex within the merge tolerance of the position, via the
		-- spatial hash. Distinct live vertices are kept at least the merge tolerance
		-- apart, so such a match is THE nearest vertex. This is the common case for
		-- undo/redo seed resolution -- thousands of exact-position lookups that made
		-- the linear scan below quadratic on a large mesh.
		if radius >= kVertexMergeTolerance then
			local exact = findExistingVertexNear(position)
			if exact then
				return exact
			end
		end
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

	-- If a proposed triangle wound (a, b, c) already shares an edge with an
	-- existing triangle, return the invert flag that makes it wind CONSISTENTLY
	-- with that neighbour: two consistently-oriented triangles traverse their
	-- shared edge in opposite directions, so if the neighbour also traverses the
	-- edge a->b the proposal is backwards and must invert. Returns nil when the
	-- triangle is isolated (nothing to match -- caller falls back to a hint).
	local function invertToMatchNeighbor(aId: VertexId, bId: VertexId, cId: VertexId): boolean?
		local proposed = { aId, bId, cId }
		for i = 1, 3 do
			local j = i % 3 + 1
			local p, q = proposed[i], proposed[j]
			local pv, qv = mVertices[p], mVertices[q]
			if not (pv and qv) then
				continue
			end
			local edgeId = mEdgeLookup[hashEdge(pv.position, qv.position)]
			if not edgeId then
				continue
			end
			local edge = mEdges[edgeId]
			if not edge then
				continue
			end
			for _, tid in edge.triangles do
				local tri = mTriangles[tid]
				if not tri then
					continue
				end
				local tv = tri.vertices
				for k = 1, 3 do
					local l = k % 3 + 1
					if tv[k] == p and tv[l] == q then
						-- Neighbour also goes p->q: same direction -> inconsistent.
						return true
					elseif tv[k] == q and tv[l] == p then
						-- Neighbour goes q->p: opposite direction -> consistent.
						return false
					end
				end
			end
		end
		return nil
	end

	local function addTriangle(
		v1Pos: Vector3, v2Pos: Vector3, v3Pos: Vector3,
		thickness: number, parent: Instance,
		props: fillTriangle.TriangleProps?, hintPoint: Vector3
	): number?
		-- Determine normal from winding, then choose the winding.
		local natural = computeNormal(v1Pos, v2Pos, v3Pos)

		-- Get or create vertices
		local v1Id = getOrCreateVertex(v1Pos)
		local v2Id = getOrCreateVertex(v2Pos)
		local v3Id = getOrCreateVertex(v3Pos)

		-- Prefer matching an existing neighbour on a shared edge so the surface
		-- stays consistently wound; fall back to facing the hint for an isolated
		-- triangle. The hint-only test flipped triangles added onto a tilted/curved
		-- edge, where the new triangle's natural normal and the neighbour's normal
		-- point far enough apart that the dot-product picked the wrong winding.
		local shouldInvert: boolean
		local neighborInvert = invertToMatchNeighbor(v1Id, v2Id, v3Id)
		if neighborInvert ~= nil then
			shouldInvert = neighborInvert
		else
			local centroid = (v1Pos + v2Pos + v3Pos) / 3
			shouldInvert = natural:Dot(hintPoint - centroid) < 0
		end

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

		bumpTopology()
		return triId
	end

	-- keepParts leaves the parts in the world (just forgets the triangle in-memory) so an
	-- undo can locally re-discover them after ChangeHistory has reverted them, instead of
	-- rebuilding the whole mesh. The Delete path leaves it nil/false to parent the parts out.
	local function removeTriangle(triangleId: number, keepParts: boolean?)
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
			if not keepParts and not mPartToTriangles[part] then
				-- Our own edit: the part's Changed listener stays live until the
				-- deferred-disconnect sweep runs.
				markPartsEdited({ part })
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
		bumpTopology()
	end

	-- Reshape a triangle's parts in place to match its vertices' current positions,
	-- preserving its winding and its own recorded thickness. Shared by moveVertex and
	-- mergeVertices so the two stay consistent.
	local function rebuildTriangleGeometry(tri: Triangle, props: fillTriangle.TriangleProps?)
		local v1 = mVertices[tri.vertices[1]]
		local v2 = mVertices[tri.vertices[2]]
		local v3 = mVertices[tri.vertices[3]]
		if not (v1 and v2 and v3) then
			return
		end
		-- Recompute normal. The stored vertex order is kept wound so its natural
		-- normal IS the outward normal, so fillTriangle never needs invertNormal.
		tri.normal = computeNormal(v1.position, v2.position, v3.position)

		-- Rebuild parts in-place at THIS triangle's own thickness (recorded at
		-- discovery / creation) rather than snapping to the global value, so editing a
		-- vertex regenerates parts as thick as they already were.
		-- fillTriangle writes Size/CFrame to the reused parts (and parents-out any
		-- excess one), so stamp them as our own edit first.
		markPartsEdited(tri.parts)
		local parent = tri.parts[1].Parent
		local newParts = fillTriangle(
			v1.position, v2.position, v3.position,
			tri.thickness, parent :: Instance, props, tri.parts, false
		)
		tri.parts = relinkTriangleParts(tri, newParts)
	end

	local function moveVertices(moves: {[number]: Vector3}, thickness: number, props: fillTriangle.TriangleProps?)
		-- Collect the affected edges and triangles ONCE across the whole batch: an
		-- edge between two moved vertices is re-keyed exactly once, and a triangle
		-- is rebuilt exactly once even when all three of its corners moved. (Moving
		-- the vertices one at a time rebuilt each shared triangle per corner --
		-- three fillTriangle part reshapes where one suffices -- which dominated
		-- the per-frame cost of dragging a large influence region.)
		local affectedEdges: { [EdgeId]: boolean } = {}
		local affectedTris: { [TriangleId]: boolean } = {}
		local anyMoved = false
		for vertexId in moves do
			local vertex = mVertices[vertexId]
			if vertex then
				anyMoved = true
				local incidentEdges = mVertexEdges[vertexId]
				if incidentEdges then
					for edgeId in incidentEdges do
						affectedEdges[edgeId] = true
					end
				end
				for _, triId in vertex.triangles do
					affectedTris[triId] = true
				end
			end
		end
		if not anyMoved then
			return
		end

		-- The affected edges have position-keyed entries in mEdgeLookup that go stale
		-- when their vertices move. Drop them all while every vertex is still at its
		-- old position (so the hashes still match), move the vertices, then re-insert
		-- at the new hashes.
		for edgeId in affectedEdges do
			local edge = mEdges[edgeId]
			if edge then
				local v1 = mVertices[edge.v1]
				local v2 = mVertices[edge.v2]
				if v1 and v2 then
					mEdgeLookup[hashEdge(v1.position, v2.position)] = nil
				end
			end
		end

		-- Move the vertices (and their spatial-hash entries). All removals happen
		-- before any insertion so a vertex moving into a cell another vertex just
		-- left can't have its fresh entry deleted.
		for vertexId in moves do
			local vertex = mVertices[vertexId]
			if vertex then
				mSpatialHash[hashVertex(vertex.position)] = nil
			end
		end
		for vertexId, newPosition in moves do
			local vertex = mVertices[vertexId]
			if vertex then
				vertex.position = newPosition
				mSpatialHash[hashVertex(newPosition)] = vertexId
			end
		end

		-- Re-insert the affected edges at their new positions.
		for edgeId in affectedEdges do
			local edge = mEdges[edgeId]
			if edge then
				local v1 = mVertices[edge.v1]
				local v2 = mVertices[edge.v2]
				if v1 and v2 then
					mEdgeLookup[hashEdge(v1.position, v2.position)] = edgeId
				end
			end
		end

		-- Upgrade any Block-backed triangles before rebuilding
		for triId in affectedTris do
			local tri = mTriangles[triId]
			if tri and tri.partsRequireUpgrade then
				upgradeBlockTriangles(tri, tri.thickness)
			end
		end

		-- Rebuild each affected triangle exactly once
		for triId in affectedTris do
			local tri = mTriangles[triId]
			if tri then
				rebuildTriangleGeometry(tri, props)
			end
		end

		bumpPositions()
		for vertexId in moves do
			if mVertices[vertexId] then
				mVertexChanged:Fire(vertexId)
			end
		end
	end

	local function moveVertex(vertexId: number, newPosition: Vector3, thickness: number, props: fillTriangle.TriangleProps?)
		moveVertices({ [vertexId] = newPosition }, thickness, props)
	end

	-- Merge `mergedId` into `survivorId`, placing the unified vertex at `position`.
	-- Every triangle that referenced mergedId is re-pointed onto survivorId, the edges
	-- of the affected triangles are torn down and rebuilt at the new positions (so two
	-- coincident "torn" edges combine into one shared edge, closing the seam), and the
	-- parts are reshaped to the new corner. Returns false (a no-op) if either vertex is
	-- missing, they are the same vertex, or they share a triangle -- merging corners of
	-- one triangle would collapse it to a degenerate sliver.
	local function mergeVertices(survivorId: number, mergedId: number, position: Vector3, props: fillTriangle.TriangleProps?): boolean
		if survivorId == mergedId then
			return false
		end
		local survivor = mVertices[survivorId]
		local merged = mVertices[mergedId]
		if not survivor or not merged then
			return false
		end
		for _, triId in merged.triangles do
			local tri = mTriangles[triId]
			if tri and table.find(tri.vertices, survivorId) then
				return false
			end
		end

		-- Every triangle touching either vertex -- these are the only ones whose edges
		-- or geometry change.
		local affected: { TriangleId } = {}
		local seen: { [TriangleId]: boolean } = {}
		for _, triId in survivor.triangles do
			if not seen[triId] then
				seen[triId] = true
				table.insert(affected, triId)
			end
		end
		for _, triId in merged.triangles do
			if not seen[triId] then
				seen[triId] = true
				table.insert(affected, triId)
			end
		end

		-- Block-backed triangles must become wedges before we reshape corners.
		for _, triId in affected do
			local tri = mTriangles[triId]
			if tri and tri.partsRequireUpgrade then
				upgradeBlockTriangles(tri, tri.thickness)
			end
		end

		-- 1) Detach the affected triangles from their current edges (keyed by current
		--    positions), cleaning up any that empty out.
		for _, triId in affected do
			local tri = mTriangles[triId]
			if tri then
				for _, pair in triangleEdgePairs(tri.vertices) do
					local pa = mVertices[pair[1]]
					local pb = mVertices[pair[2]]
					if pa and pb then
						local edgeId = mEdgeLookup[hashEdge(pa.position, pb.position)]
						if edgeId then
							local edge = mEdges[edgeId]
							if edge then
								local idx = table.find(edge.triangles, triId)
								if idx then
									table.remove(edge.triangles, idx)
								end
								cleanupEdge(edgeId)
							end
						end
					end
				end
			end
		end

		-- 2) Re-point merged -> survivor in every triangle, and adopt those triangles.
		for _, triId in merged.triangles do
			local tri = mTriangles[triId]
			if tri then
				for i, vid in tri.vertices do
					if vid == mergedId then
						tri.vertices[i] = survivorId
					end
				end
				table.insert(survivor.triangles, triId)
			end
		end
		merged.triangles = {}

		-- 3) Delete the merged vertex and move the survivor to the merge position.
		local mergedHash = hashVertex(merged.position)
		if mSpatialHash[mergedHash] == mergedId then
			mSpatialHash[mergedHash] = nil
		end
		mVertices[mergedId] = nil

		local survivorOldHash = hashVertex(survivor.position)
		if mSpatialHash[survivorOldHash] == survivorId then
			mSpatialHash[survivorOldHash] = nil
		end
		survivor.position = position
		mSpatialHash[hashVertex(position)] = survivorId

		-- 4) Rebuild edges at the new positions. getOrCreateEdge keys by position, so
		--    two formerly-separate torn edges now resolve to one shared edge.
		for _, triId in affected do
			local tri = mTriangles[triId]
			if tri then
				for _, pair in triangleEdgePairs(tri.vertices) do
					local edgeId = getOrCreateEdge(pair[1], pair[2])
					table.insert(mEdges[edgeId].triangles, triId)
				end
			end
		end

		-- 5) Reshape the parts of every affected triangle to the moved corner.
		for _, triId in affected do
			local tri = mTriangles[triId]
			if tri then
				rebuildTriangleGeometry(tri, props)
			end
		end

		-- mergeVertices moves the survivor and removes the merged vertex directly (not
		-- via moveVertex / cleanupVertex), so notify for both.
		bumpTopology()
		mVertexChanged:Fire(mergedId)
		mVertexChanged:Fire(survivorId)
		return true
	end

	-- Fold two coplanar wedge triangles that share an edge back into one logical
	-- triangle. After a tear nudges one wedge of a 2-wedge triangle, discovery leaves
	-- the two wedges as separate single-wedge triangles whose shared "foot" vertex sits
	-- just off the straight outer edge between the two outer corners. We snap that foot
	-- exactly onto the outer edge (so the parts tile a clean triangle), then rebuild the
	-- pair as one triangle carrying both parts and drop the now-interior foot vertex --
	-- which also rejoins the outer edge with any neighbour across it, clearing the
	-- T-junction. Returns false unless the two triangles share exactly one edge, face the
	-- same way, and a shared vertex lies within `maxFootOffset` of the straight outer
	-- edge between the outer corners.
	local function mergeWedgeTriangles(triId1: number, triId2: number, maxFootOffset: number, props: fillTriangle.TriangleProps?): boolean
		if triId1 == triId2 then
			return false
		end
		local t1 = mTriangles[triId1]
		local t2 = mTriangles[triId2]
		if not t1 or not t2 then
			return false
		end
		-- Same-facing only -- a back-to-back pair (the two faces of a slab) shares an
		-- edge too but must never be folded together.
		if t1.normal:Dot(t2.normal) < 0.99 then
			return false
		end

		-- They must share exactly one edge (two vertices).
		local shared: { VertexId } = {}
		for _, vid in t1.vertices do
			if table.find(t2.vertices, vid) then
				table.insert(shared, vid)
			end
		end
		if #shared ~= 2 then
			return false
		end
		local function outerOf(tri: Triangle): VertexId?
			for _, vid in tri.vertices do
				if vid ~= shared[1] and vid ~= shared[2] then
					return vid
				end
			end
			return nil
		end
		local r1 = outerOf(t1)
		local r2 = outerOf(t2)
		if not r1 or not r2 then
			return false
		end
		local vr1 = mVertices[r1]
		local vr2 = mVertices[r2]
		local vsa = mVertices[shared[1]]
		local vsb = mVertices[shared[2]]
		if not (vr1 and vr2 and vsa and vsb) then
			return false
		end

		-- The foot is the shared vertex sitting between the outer corners (the cut point
		-- to discard); the other shared vertex is the apex that stays.
		local seg = vr2.position - vr1.position
		local segLenSq = seg:Dot(seg)
		if segLenSq < 1e-6 then
			return false
		end
		local function project(p: Vector3): (number, number, Vector3)
			local tt = (p - vr1.position):Dot(seg) / segLenSq
			local proj = vr1.position + seg * tt
			return tt, (p - proj).Magnitude, proj
		end
		local ta, perpA, projA = project(vsa.position)
		local tb, perpB, projB = project(vsb.position)
		local aInside = ta > 0.001 and ta < 0.999
		local bInside = tb > 0.001 and tb < 0.999
		local footId: VertexId
		local apexId: VertexId
		local footProj: Vector3
		local footPerp: number
		if aInside and (not bInside or perpA <= perpB) then
			footId, apexId, footProj, footPerp = shared[1], shared[2], projA, perpA
		elseif bInside then
			footId, apexId, footProj, footPerp = shared[2], shared[1], projB, perpB
		else
			return false
		end
		if footPerp > maxFootOffset then
			return false
		end

		-- The triangle we'd form (r1, apex, r2) must be non-degenerate.
		local apexV = mVertices[apexId]
		if not apexV then
			return false
		end
		local area2 = (apexV.position - vr1.position):Cross(vr2.position - vr1.position).Magnitude
		if area2 < 1e-3 then
			return false
		end

		-- Snap the foot exactly onto the outer edge so the parts tile a clean triangle.
		moveVertex(footId, footProj, t1.thickness, props)

		-- Detach both triangles from their vertices and edges (positions now snapped).
		local function detach(tri: Triangle)
			for _, vid in tri.vertices do
				local v = mVertices[vid]
				if v then
					local idx = table.find(v.triangles, tri.id)
					if idx then
						table.remove(v.triangles, idx)
					end
				end
			end
			for _, pair in triangleEdgePairs(tri.vertices) do
				local a = mVertices[pair[1]]
				local b = mVertices[pair[2]]
				if a and b then
					local eid = mEdgeLookup[hashEdge(a.position, b.position)]
					if eid then
						local edge = mEdges[eid]
						if edge then
							local idx = table.find(edge.triangles, tri.id)
							if idx then
								table.remove(edge.triangles, idx)
							end
							cleanupEdge(eid)
						end
					end
				end
			end
		end
		detach(t1)
		detach(t2)

		-- Move t2's parts onto t1 and drop t2.
		local mergedParts: { BasePart } = {}
		for _, p in t1.parts do
			table.insert(mergedParts, p)
		end
		for _, p in t2.parts do
			unlinkTriangleFromPart(t2, p)
			linkTriangleToPart(t1, p)
			table.insert(mergedParts, p)
		end
		mTriangles[triId2] = nil

		-- Rebuild t1 as the merged triangle (r1, apex, r2), inheriting t1's facing.
		local mergedNatural = computeNormal(vr1.position, apexV.position, vr2.position)
		if mergedNatural:Dot(t1.normal) < 0 then
			t1.vertices = { r1, r2, apexId }
			t1.normal = -mergedNatural
		else
			t1.vertices = { r1, apexId, r2 }
			t1.normal = mergedNatural
		end
		t1.parts = mergedParts

		for _, vid in t1.vertices do
			table.insert(mVertices[vid].triangles, triId1)
		end
		for _, pair in triangleEdgePairs(t1.vertices) do
			local eid = getOrCreateEdge(pair[1], pair[2])
			table.insert(mEdges[eid].triangles, triId1)
		end

		-- The foot is now interior to the merged outer edge: drop it.
		cleanupVertex(footId)

		bumpTopology()
		return true
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

		-- Dequeue via a moving head index: table.remove(queue, 1) shifts the whole
		-- queue on every pop, which made a large-radius walk quadratic.
		local queueHead = 1
		while queueHead <= #queue do
			local currentTriId = queue[queueHead]
			queueHead += 1
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
		-- A wedge part backs exactly one single-sided triangle, so return it
		-- regardless of which face the hint is on. Terrain grids are generated
		-- back-facing, so the camera usually hovers the side opposite the triangle
		-- normal; rejecting "back side" hints would make Paint/Delete/Relax/Flatten
		-- (which look the hovered triangle up through here) find nothing from the
		-- natural viewing angle. The hint still selects the best-aligned triangle
		-- if a part ever carries more than one.
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

	-- Make every connected component consistently oriented: BFS the triangle
	-- adjacency graph and flip any neighbour whose winding disagrees (two
	-- consistently-oriented triangles traverse their shared edge in opposite
	-- directions). Per-hint orientation gets each triangle's outward side right
	-- but, with split wedges and incremental discovery, can disagree between
	-- neighbours; this pass reconciles them. The first triangle of each component
	-- (oriented toward the clicked side) sets that component's global direction.
	-- restrictTriangles limits re-orientation to those triangles, anchoring on their
	-- already-correct neighbours just outside the set (an undo's region re-discovery), so it
	-- costs O(region) not O(mesh). nil re-orients every triangle (a full rediscover).
	local function orientConsistently(restrictTriangles: { [TriangleId]: boolean }?)
		local visited = {} :: {[TriangleId]: boolean}
		local queue = {} :: { TriangleId }
		local qh = 1

		-- Flip a queued triangle's not-yet-visited, in-scope neighbours to match it. Anchors
		-- (already-visited triangles outside the restricted set) are read but never flipped.
		local function process(tid: TriangleId)
			local tri = mTriangles[tid]
			if not tri then
				return
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
					if ntid ~= tid and nt and not visited[ntid] and (restrictTriangles == nil or restrictTriangles[ntid]) then
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

		local function drain()
			while qh <= #queue do
				local tid = queue[qh]
				qh += 1
				process(tid)
			end
		end

		if restrictTriangles then
			-- Seed from anchors: oriented neighbours just outside the restricted set, so the
			-- restricted triangles line up with the rest of the mesh.
			for triId in restrictTriangles do
				local tri = mTriangles[triId]
				if tri then
					for i = 1, 3 do
						local j = if i == 3 then 1 else i + 1
						local pva = mVertices[tri.vertices[i]]
						local pvb = mVertices[tri.vertices[j]]
						if pva and pvb then
							local eid = mEdgeLookup[hashEdge(pva.position, pvb.position)]
							local edge = if eid then mEdges[eid] else nil
							if edge then
								for _, ntid in edge.triangles do
									if not restrictTriangles[ntid] and not visited[ntid] and mTriangles[ntid] then
										visited[ntid] = true -- anchor: trusted, never flipped
										table.insert(queue, ntid)
									end
								end
							end
						end
					end
				end
			end
			drain()
			-- Restricted triangles with no anchor (an isolated new component): orient each
			-- such component from an arbitrary member, as for a fresh mesh.
			for triId in restrictTriangles do
				if not visited[triId] and mTriangles[triId] then
					visited[triId] = true
					table.insert(queue, triId)
					drain()
				end
			end
		else
			for startId in mTriangles do
				if not visited[startId] then
					visited[startId] = true
					table.insert(queue, startId)
					drain()
				end
			end
		end
	end

	-- nearbyResolver, when supplied, replaces the per-vertex
	-- workspace:GetPartBoundsInRadius merge search with an in-memory lookup. The
	-- unbounded rebuild (discoverRegion at radius == math.huge) passes one backed
	-- by a prebuilt corner index, turning thousands of workspace queries per undo
	-- into in-memory probes. Interactive callers omit it and keep the live query.
	-- viewPoint (the camera eye, when an interactive caller supplies it) disambiguates
	-- which face of a thin Block to adopt: the one facing the viewer, rather than the
	-- side the cursor happened to cross first. Falls back to hintPoint when absent
	-- (the rebuild and tests), and is ignored for wedges.
	local function discoverPart(part: BasePart, hintPoint: Vector3, viewPoint: Vector3?, nearbyResolver: ((Vector3, number) -> { Instance })?, refuseAwayFace: boolean?): number?
		-- The mesh is built only from wedge/block parts. A region scan or raycast can also
		-- surface other BaseParts -- most importantly Terrain in a place with voxel terrain,
		-- or MeshParts -- which we ignore rather than error on `.Shape`. WedgePart (the legacy
		-- class) is a wedge too, with identical geometry, not just Part with Shape == Wedge.
		local partIsWedge = isWedgePart(part)
		local partIsBlock = isBlockPart(part)
		if not partIsWedge and not partIsBlock then
			return nil
		end
		-- Never adopt the template baseplate as mesh, even when a seed point lands on
		-- it (the region scan bootstraps any part the point sits inside). People keep
		-- terrain Locked, so this filters the baseplate by name, not by Locked.
		if part.Name == "Baseplate" then
			return nil
		end
		-- A wedge part backs exactly one single-sided triangle. Once it is
		-- discovered, return that triangle regardless of which face the hint is on.
		-- Crucially we must NOT spawn a second triangle on the opposite face: grids
		-- are generated back-facing, so the camera almost always hovers the side
		-- opposite the discovered normal, and treating that as "the other face"
		-- doubled the mesh with phantom triangles (breaking selection/discovery).
		-- The hint only orients the FIRST discovery of a part; after that the
		-- part->triangle link is the single source of truth.
		local headId = mPartToTriangles[part]
		if headId then
			return getPartTriangle(part, hintPoint) or headId
		end

		if partIsWedge then
			-- First discovery of this wedge: try both faces and prefer the one
			-- sharing more vertices with existing geometry, so its shared corners
			-- land on the same vertices as already-discovered neighbours.
			local v1, v2, v3, wedgeThickness
			do
				local hintA = part.CFrame.Position + part.CFrame.RightVector
				local hintB = part.CFrame.Position - part.CFrame.RightVector
				local v1a, v2a, v3a, thicknessA = getWedgeVertices(part, hintA)
				local v1b, v2b, v3b, thicknessB = getWedgeVertices(part, hintB)
				local matchA, matchB = 0, 0
				for _, vp in {v1a, v2a, v3a} do
					if findExistingVertexNear(vp) then matchA += 1 end
				end
				for _, vp in {v1b, v2b, v3b} do
					if findExistingVertexNear(vp) then matchB += 1 end
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

			-- Refuse to START a fresh surface on the wedge's FAR thin face -- the one on
			-- the opposite side of the slab from the camera. That is the back face the
			-- cursor locks onto when it first grazes a part's thin edge before reaching
			-- the front. We compare the chosen face's SIDE (its thin-axis offset from the
			-- part centre) to the camera, not its normal: grids are generated back-facing,
			-- so the front face's normal already points away from the camera and a
			-- normal test would wrongly reject the whole mesh. This only blocks the START
			-- -- a face sharing a vertex with already-discovered geometry (a topology-walk
			-- continuation) is allowed to face any way, so curved surfaces still discover
			-- fully. Opt-in (refuseAwayFace): only the interactive single-part hover sets
			-- it; region scans and rebuilds must adopt whatever side their seed sits on.
			if refuseAwayFace and viewPoint then
				local right = part.CFrame.RightVector -- the thin axis for our wedges
				local centroid = (v1 + v2 + v3) / 3
				local faceSide = (centroid - part.Position):Dot(right)
				local cameraSide = (viewPoint - part.Position):Dot(right)
				local sharesExisting = findExistingVertexNear(v1)
					or findExistingVertexNear(v2)
					or findExistingVertexNear(v3)
				if not sharesExisting and faceSide * cameraSide < 0 then
					return nil
				end
			end

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
			bumpTopology()

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
				local nearbyParts = if nearbyResolver
					then nearbyResolver(v.position, searchRadius)
					else workspace:GetPartBoundsInRadius(v.position, searchRadius)
				for _, nearPart in nearbyParts do
					if nearPart == part then
						continue
					end
					if not isWedgePart(nearPart) then
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

		elseif partIsBlock then
			-- Thin block: treat as two triangles (a quad split into 2 tris)
			local size = part.Size
			local cf = part.CFrame

			-- Choose the face by the viewer's position when we have it, so the quad we
			-- adopt is the one facing the camera -- not whichever side of the thin slab
			-- the cursor first grazed (which is usually the back). Without a viewpoint
			-- (rebuild/tests) fall back to the hit point, the original behaviour.
			local faceHint = viewPoint or hintPoint

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
			local localHint = cf:PointToObjectSpace(faceHint)

			-- Get the quad corners on the face the viewer is looking at
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

			-- Orient each adopted-face triangle's normal along the face's OUTWARD
			-- direction: the thin axis, on the side the face was chosen for. Orienting
			-- toward the hint point instead is ill-conditioned when the hint lies in the
			-- face plane -- e.g. a rebuild (no viewpoint) seeded from a face corner --
			-- where (hint - faceCentroid) is nearly perpendicular to the normal, so the
			-- sign is decided by floating-point noise and the wedge side after an upgrade
			-- flips at random. The outward direction is well-defined either way.
			local localAxis = ({ localHint.X, localHint.Y, localHint.Z })[minIdx]
			local faceOutward = axes[minIdx] * (if localAxis >= 0 then 1 else -1)

			-- Triangle 1
			local tri1Verts = {v1Id, v2Id, v3Id}
			local tri1Natural = computeNormal(c1, c2, c3)
			if tri1Natural:Dot(faceOutward) < 0 then
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
			if tri2Natural:Dot(faceOutward) < 0 then
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

			bumpTopology()
			return tri1Id
		end

		return nil
	end

	-- Remove a triangle from all bookkeeping but LEAVE its world parts intact and
	-- unlinked, so the caller can re-link them to a replacement triangle. (Unlike
	-- removeTriangle, which parents the parts out of the world.)
	local function detachTriangleKeepParts(tri: Triangle)
		for _, part in tri.parts do
			unlinkTriangleFromPart(tri, part)
		end
		for _, vid in tri.vertices do
			local v = mVertices[vid]
			if v then
				local idx = table.find(v.triangles, tri.id)
				if idx then
					table.remove(v.triangles, idx)
				end
			end
		end
		for _, pair in triangleEdgePairs(tri.vertices) do
			local v1 = mVertices[pair[1]]
			local v2 = mVertices[pair[2]]
			if v1 and v2 then
				local eid = mEdgeLookup[hashEdge(v1.position, v2.position)]
				if eid then
					local edge = mEdges[eid]
					if edge then
						local idx = table.find(edge.triangles, tri.id)
						if idx then
							table.remove(edge.triangles, idx)
						end
						cleanupEdge(eid)
					end
				end
			end
		end
		mTriangles[tri.id] = nil
		bumpTopology()
		for _, vid in tri.vertices do
			cleanupVertex(vid)
		end
	end

	-- Re-fuse any fillTriangle two-wedge split that was left as two separate
	-- single-part triangles. discoverPart's per-wedge merge only fires when the
	-- partner wedge is still undiscovered, so depending on walk order both halves
	-- can be discovered independently and neither merges -- leaving the altitude
	-- foot as a phantom vertex and an extra triangle (so a fresh rediscovery, e.g.
	-- on undo, disagrees with the live mesh). This order-independent pass scans
	-- interior edges shared by exactly two coplanar single-part triangles; if one
	-- of the shared-edge endpoints sits collinear strictly between the two far
	-- vertices (the foot on the original base), the pair is a split and is fused.
	-- restrictTriangles limits the scan to those triangles' edges (a local coalesce, e.g.
	-- an undo's region re-discovery); nil scans the whole mesh (a full rediscover). Edges
	-- are processed in a deterministic geometry order so a local coalesce and a full one --
	-- which would otherwise see edges in different hash orders -- pick the SAME merges; a
	-- mismatch there is what let a local rebuild drift a triangle from a fresh rediscovery.
	local function coalesceWedgePairs(restrictTriangles: { [TriangleId]: boolean }?)
		local function collinearBetween(p: Vector3, a: Vector3, b: Vector3): boolean
			local d = b - a
			local dl = d.Magnitude
			if dl < 1e-4 then
				return false
			end
			local toP = p - a
			if d:Cross(toP).Magnitude / dl > 0.01 then
				return false
			end
			local s = toP:Dot(d) / (dl * dl)
			return s > 0.001 and s < 0.999
		end

		local function lexLess(a: Vector3, b: Vector3): boolean
			if a.X ~= b.X then
				return a.X < b.X
			end
			if a.Y ~= b.Y then
				return a.Y < b.Y
			end
			return a.Z < b.Z
		end
		type Cand = { eid: EdgeId, lo: Vector3, hi: Vector3 }
		local cands: { Cand } = {}
		local function addCand(eid: EdgeId)
			local edge = mEdges[eid]
			if not edge then
				return
			end
			local a, b = mVertices[edge.v1], mVertices[edge.v2]
			if not (a and b) then
				return
			end
			if lexLess(b.position, a.position) then
				table.insert(cands, { eid = eid, lo = b.position, hi = a.position })
			else
				table.insert(cands, { eid = eid, lo = a.position, hi = b.position })
			end
		end
		if restrictTriangles then
			local seen: { [EdgeId]: boolean } = {}
			for triId in restrictTriangles do
				local tri = mTriangles[triId]
				if tri then
					for _, pair in triangleEdgePairs(tri.vertices) do
						local pva, pvb = mVertices[pair[1]], mVertices[pair[2]]
						if pva and pvb then
							local eid = mEdgeLookup[hashEdge(pva.position, pvb.position)]
							if eid and not seen[eid] then
								seen[eid] = true
								addCand(eid)
							end
						end
					end
				end
			end
		else
			for eid in mEdges do
				addCand(eid)
			end
		end
		table.sort(cands, function(m: Cand, n: Cand): boolean
			if m.lo ~= n.lo then
				return lexLess(m.lo, n.lo)
			end
			return lexLess(m.hi, n.hi)
		end)
		for _, cand in cands do
			local eid = cand.eid
			local edge = mEdges[eid]
			if not edge or #edge.triangles ~= 2 then
				continue
			end
			local t1 = mTriangles[edge.triangles[1]]
			local t2 = mTriangles[edge.triangles[2]]
			if not (t1 and t2) or t1 == t2 then
				continue
			end
			if #t1.parts ~= 1 or #t2.parts ~= 1 then
				continue
			end
			-- Coplanar (faces parallel within ~8 degrees)?
			if math.abs(t1.normal:Dot(t2.normal)) < 0.99 then
				continue
			end
			local s1Id, s2Id = edge.v1, edge.v2
			local function thirdOf(tri: Triangle): VertexId?
				for _, vid in tri.vertices do
					if vid ~= s1Id and vid ~= s2Id then
						return vid
					end
				end
				return nil
			end
			local u1Id = thirdOf(t1)
			local u2Id = thirdOf(t2)
			if not (u1Id and u2Id) or u1Id == u2Id then
				continue
			end
			local s1, s2 = mVertices[s1Id], mVertices[s2Id]
			local u1, u2 = mVertices[u1Id], mVertices[u2Id]
			if not (s1 and s2 and u1 and u2) then
				continue
			end
			local apexPos: Vector3
			if collinearBetween(s1.position, u1.position, u2.position) then
				apexPos = s2.position
			elseif collinearBetween(s2.position, u1.position, u2.position) then
				apexPos = s1.position
			else
				continue
			end

			-- Fuse: replace t1 + t2 with one triangle {apex, u1, u2} spanning both
			-- parts, inheriting t1's facing so the merged winding stays consistent.
			local u1Pos, u2Pos = u1.position, u2.position
			local p1, p2 = t1.parts[1], t2.parts[1]
			local thick = t1.thickness
			local mergedNatural = computeNormal(apexPos, u1Pos, u2Pos)
			local mergedInvert = mergedNatural:Dot(t1.normal) < 0
			detachTriangleKeepParts(t1)
			detachTriangleKeepParts(t2)

			local aId = getOrCreateVertex(apexPos)
			local bId = getOrCreateVertex(u1Pos)
			local cId = getOrCreateVertex(u2Pos)
			local verts: { VertexId }
			local normal: Vector3
			if mergedInvert then
				verts = { aId, cId, bId }
				normal = -mergedNatural
			else
				verts = { aId, bId, cId }
				normal = mergedNatural
			end
			local triId = mNextTriangleId
			mNextTriangleId += 1
			local merged: Triangle = {
				id = triId,
				vertices = verts,
				normal = normal,
				parts = { p1, p2 },
				thickness = thick,
			}
			mTriangles[triId] = merged
			for _, vid in verts do
				table.insert(mVertices[vid].triangles, triId)
			end
			for _, pair in triangleEdgePairs(verts) do
				local e = getOrCreateEdge(pair[1], pair[2])
				table.insert(mEdges[e].triangles, triId)
			end
			linkTriangleToPart(merged, p1)
			linkTriangleToPart(merged, p2)
		end
	end

	-- viewPoint (the camera eye, from interactive callers) disambiguates which face
	-- of a thin Block to adopt when this region scan bootstraps one -- e.g. a box
	-- sitting on a baseplate, where the seed point lands on the box's bottom plane
	-- and would otherwise lock the back face. Threaded down to discoverPart; nil for
	-- the rebuild (radius == math.huge, where boxes resolve from their own corners).
	local function discoverRegion(seeds: {Vector3}, radius: number, viewPoint: Vector3?): {TriangleId}
		local discovered = {} :: {[TriangleId]: boolean}
		local result = {} :: {TriangleId}

		-- Track explored positions to avoid re-processing
		local explored = {} :: {[VertexHash]: boolean}

		-- Two queues so each seed's walk finishes before the next seed is touched.
		-- walkQueue (positions reached by the topology walk) drains BEFORE the next
		-- initial seed in seedQueue. This matters on the undo rebuild: a few good
		-- seeds (the reverted snapshot) must fully discover the connected mesh first,
		-- so that the many stale seeds (post-op positions, some landing a thickness
		-- off on a back-face plane) then find every part already tracked and become
		-- no-ops instead of corner-matching and adopting the back face.
		local seedQueue = {} :: {Vector3}
		local walkQueue = {} :: {Vector3}

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
							table.insert(walkQueue, v.position)
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

		-- Build a corner -> {parts} spatial index from ONE bulk query covering all
		-- seeds (grown by `margin`). Feeds discoverPart's merge resolver below: on
		-- an adoption-heavy pass (an undo's region re-discovery, a fresh region
		-- walk) discoverPart otherwise runs three GetPartBoundsInRadius queries per
		-- part to find a coplanar partner wedge to fuse -- thousands of workspace
		-- queries on a large region, the dominant cost. A merge partner shares an
		-- edge (two corners) with the part, so keying each candidate part by the
		-- hash of each of its corners turns that search into an in-memory 27-cell
		-- probe. (Enumeration -- which undiscovered parts discoverRegion ADOPTS --
		-- deliberately stays on the workspace query: a corner-only index there would
		-- skip the bootstrap-by-containment case and change the discovered set.)
		local function buildCornerIndex(seedList: { Vector3 }, margin: number): ({ [VertexHash]: { BasePart } }, Vector3, Vector3)
			local lo, hi = seedList[1], seedList[1]
			for _, s in seedList do
				lo = lo:Min(s)
				hi = hi:Max(s)
			end
			-- Everything the walk can adopt has its corners within the discovery
			-- radius of a seed (the caller passes that as the margin; for the
			-- unbounded rebuild every corner IS a seed and the margin only guards
			-- FP at the boundary).
			lo -= Vector3.one * margin
			hi += Vector3.one * margin
			local center = (lo + hi) / 2
			local size = hi - lo
			local params = OverlapParams.new()
			params.MaxParts = 1000000

			local index: { [VertexHash]: { BasePart } } = {}
			local function add(corner: Vector3, part: BasePart)
				local h = hashVertex(corner)
				local bucket = index[h]
				if bucket then
					table.insert(bucket, part)
				else
					index[h] = { part }
				end
			end
			for _, part in workspace:GetPartBoundsInBox(CFrame.new(center), size, params) do
				-- Only wedge/block parts carry mesh geometry; this skips Terrain (a BasePart
				-- with no Shape) in voxel-terrain places and other shapes discoverPart ignores.
				if mPartToTriangles[part] then
					continue
				end
				if isWedgePart(part) then
					local hintA = part.CFrame.Position + part.CFrame.RightVector
					local hintB = part.CFrame.Position - part.CFrame.RightVector
					local a1, a2, a3 = getWedgeVertices(part, hintA)
					local b1, b2, b3 = getWedgeVertices(part, hintB)
					add(a1, part)
					add(a2, part)
					add(a3, part)
					add(b1, part)
					add(b2, part)
					add(b3, part)
				elseif isBlockPart(part) then
					-- Block: key by its eight bounding-box corners.
					local cf, hs = part.CFrame, part.Size / 2
					for _, sgn in BOX_CORNER_SIGNS do
						add(cf:PointToWorldSpace(hs * sgn), part)
					end
				end
			end
			return index, lo, hi
		end

		-- Candidate parts with a corner at pos, gathered from the corner index's 27
		-- neighbour cells (a superset; discoverPart's merge check does the exact
		-- two-shared-vertex test). Mirrors the neighbour-cell search
		-- getOrCreateVertex uses for tolerant vertex merging.
		local function nearbyPartsFromCornerIndex(index: { [VertexHash]: { BasePart } }, pos: Vector3): { Instance }
			local hash = hashVertex(pos)
			local out: { Instance } = {}
			local seen: { [BasePart]: boolean } = {}
			for dx = -1, 1 do
				for dy = -1, 1 do
					for dz = -1, 1 do
						local bucket = index[hash + Vector3.new(dx, dy, dz)]
						if bucket then
							for _, part in bucket do
								if not seen[part] then
									seen[part] = true
									table.insert(out, part)
								end
							end
						end
					end
				end
			end
			return out
		end

		-- Does this wedge have a triangular-face corner coincident with pos? During a
		-- region walk we only adopt an undiscovered part when the explore point is
		-- genuinely one of its corners -- that shared corner gives discoverPart a real
		-- vertex to orient its face against. Adopting a part from a nearby-but-unshared
		-- point (a wedge whose bounds merely reach pos) leaves discoverPart guessing the
		-- face, and on a curved surface it picks the back one: a thickness-offset crack.
		--
		-- The corner reconstruction (property reads + CFrame math) is memoised for this
		-- pass: it runs for every candidate part at every explored position, and in a
		-- dense region the same part is re-examined from each of its neighbouring
		-- vertices, which dominated the undo re-discovery. Parts don't move during a
		-- pass, so the corners are computed once each.
		local partCornersCache: { [BasePart]: { Vector3 } } = {}
		local function hasCornerNearCached(part: BasePart, pos: Vector3): boolean
			if not isWedgePart(part) then
				-- Non-wedge (Terrain, MeshParts, Blocks): keep the radius-based behaviour;
				-- discoverPart adopts blocks by containment and rejects everything else anyway.
				return true
			end
			local corners = partCornersCache[part]
			if not corners then
				local hintA = part.CFrame.Position + part.CFrame.RightVector
				local hintB = part.CFrame.Position - part.CFrame.RightVector
				local a1, a2, a3 = getWedgeVertices(part, hintA)
				local b1, b2, b3 = getWedgeVertices(part, hintB)
				corners = { a1, a2, a3, b1, b2, b3 }
				partCornersCache[part] = corners
			end
			for _, corner in corners do
				if (corner - pos).Magnitude < kVertexMergeTolerance then
					return true
				end
			end
			return false
		end

		-- Seed the (low-priority) seed queue with starting positions
		for _, seed in seeds do
			table.insert(seedQueue, seed)
		end

		-- Built LAZILY, on discoverPart's first merge lookup: a pass that adopts
		-- nothing (the common already-discovered hover frame) never pays for the
		-- bulk query, while an adoption-heavy pass (undo re-discovery, fresh region
		-- walk) builds it once and serves every subsequent merge search in memory.
		local cornerIndex: { [VertexHash]: { BasePart } }? = nil
		local cornerIndexBuilt = false
		local regionLo, regionHi = Vector3.zero, Vector3.zero
		local function ensureCornerIndex()
			if cornerIndexBuilt then
				return
			end
			cornerIndexBuilt = true
			if #seeds == 0 then
				return
			end
			-- Bounded walks can adopt parts anywhere within the discovery radius of
			-- a seed; the unbounded rebuild seeds from every corner, so a small FP
			-- guard suffices there.
			local margin = if radius == math.huge then 2 else radius + 2
			cornerIndex, regionLo, regionHi = buildCornerIndex(seeds, margin)
		end

		-- Hand discoverPart an in-memory resolver so its coplanar-merge search skips
		-- its three-per-part workspace queries. The index is only COMPLETE inside the
		-- region the bulk query covered: a part with a corner there was guaranteed
		-- returned. Outside it -- e.g. an unbounded walk that reaches far past a
		-- sparse seed set -- fall back to the live query so the merge still finds
		-- its partner.
		local nearbyResolver = function(p: Vector3, fallbackRadius: number): { Instance }
			ensureCornerIndex()
			local idx = cornerIndex
			if idx
				and p.X >= regionLo.X and p.X <= regionHi.X
				and p.Y >= regionLo.Y and p.Y <= regionHi.Y
				and p.Z >= regionLo.Z and p.Z <= regionHi.Z
			then
				return nearbyPartsFromCornerIndex(idx, p)
			end
			return workspace:GetPartBoundsInRadius(p, fallbackRadius)
		end

		-- Dequeue via moving head indices, not table.remove(queue, 1): the latter
		-- shifts every remaining element on each pop, making a full rebuild O(n^2).
		-- Always drain walkQueue first (a seed's full walk) before the next seed.
		--
		-- The seed-distance filter remembers which seed matched last: BFS neighbours
		-- almost always match the same seed, so the scan is O(1) amortized rather
		-- than O(seeds) per position (which made a many-seed pass -- an undo
		-- re-discovery, the influence outline of a large selection -- quadratic).
		local lastSeedHit = 1
		-- Whether this pass adopted anything new. When it didn't, the discovered set
		-- was already normalised by whichever earlier passes discovered it, so the
		-- coalesce/orient sweeps below would be O(region) no-ops -- skip them.
		local startTopologyGeneration = mTopologyGeneration
		local seedHead, walkHead = 1, 1
		while walkHead <= #walkQueue or seedHead <= #seedQueue do
			local pos: Vector3
			if walkHead <= #walkQueue then
				pos = walkQueue[walkHead]
				walkHead += 1
			else
				pos = seedQueue[seedHead]
				seedHead += 1
			end
			local posHash = hashVertex(pos)
			if explored[posHash] then continue end
			explored[posHash] = true

			-- Skip if outside radius of all seeds
			local withinRadius = false
			local seedCount = #seeds
			for k = 0, seedCount - 1 do
				local i = lastSeedHit + k
				if i > seedCount then
					i -= seedCount
				end
				if (pos - seeds[i]).Magnitude <= radius then
					withinRadius = true
					lastSeedHit = i
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
			-- or a boundary vertex (may have undiscovered adjacent parts). A known
			-- vertex probed clean since the last mesh change needs neither.
			if vertId and mProbedClean[posHash] then
				-- No workspace work needed here until the mesh changes.
			elseif vertId and not isVertexOnBoundary(vertId) then
				-- Interior vertex: every adjacent part is already tracked.
				mProbedClean[posHash] = true
			else
				-- Cap search radius so we don't discover parts beyond the requested
				-- region. For an unbounded rebuild the cap is moot (remainingRadius is
				-- infinite), so skip the O(seeds) distance scan -- on a full rebuild
				-- that scan is O(vertices * seeds), pure overhead the result discards.
				local uncappedSearchRadius = getSearchRadius(vertId)
				local searchRadius
				if radius == math.huge then
					searchRadius = uncappedSearchRadius
				else
					local distToClosestSeed = math.huge
					for _, seed in seeds do
						distToClosestSeed = math.min(distToClosestSeed, (pos - seed).Magnitude)
					end
					local remainingRadius = radius - distToClosestSeed
					searchRadius = math.min(uncappedSearchRadius, math.max(remainingRadius, 0))
				end
				local genBeforeProbe = mTopologyGeneration
				local nearbyParts = workspace:GetPartBoundsInRadius(pos, searchRadius)
				-- pos is an already-discovered vertex when vertId is set; nil means we
				-- are bootstrapping from a fresh seed with nothing yet to share.
				local posKnown = vertId ~= nil

				-- Does any undiscovered nearby wedge actually have a corner at pos? If
				-- so, those shared corners let discoverPart orient reliably and we adopt
				-- only them. Discovering a part from a point that is NOT its corner
				-- leaves discoverPart guessing the face and, on a curved surface, picking
				-- the back one -- a thickness-offset crack.
				local haveCornerMatch = false
				for _, part in nearbyParts do
					if
						part:IsA("BasePart")
						and not mPartToTriangles[part]
						and hasCornerNearCached(part :: BasePart, pos)
					then
						haveCornerMatch = true
						break
					end
				end

				-- Arbitrary-point bootstrap: a seed that is a surface point but not a
				-- corner (a triangle centroid, a paint/add click) on an as-yet
				-- undiscovered surface. There is no shared corner to key off, so adopt
				-- just the single closest part the point actually sits ON -- the seed
				-- must lie inside that part's (slightly grown) box.
				--
				-- Disabled for the unbounded rebuild (radius == math.huge, the undo/redo
				-- rediscovery). There, every seed is either a corner (handled by the
				-- corner match above) or a STALE post-op position. The old "a stale seed
				-- floats inside no part" assumption fails under a large influence drag:
				-- a vertex moved only slightly (small falloff near the radius edge) lands
				-- a fraction off the reverted surface, still inside this part's grown
				-- box, and bootstraps it from the wrong side -- a thickness-offset back
				-- face. The connected mesh is fully recovered from the corner seeds via
				-- the corner-matched walk, so containment bootstrap is pure risk here.
				local bootstrapPart: BasePart? = nil
				if not posKnown and not haveCornerMatch and radius ~= math.huge then
					local bestD = math.huge
					for _, part in nearbyParts do
						if part:IsA("BasePart") and not mPartToTriangles[part] then
							local lp = part.CFrame:PointToObjectSpace(pos)
							local hs = (part :: BasePart).Size / 2
							if
								math.abs(lp.X) <= hs.X + 0.3
								and math.abs(lp.Y) <= hs.Y + 0.3
								and math.abs(lp.Z) <= hs.Z + 0.3
							then
								local d = (part.Position - pos).Magnitude
								if d < bestD then
									bestD = d
									bootstrapPart = part :: BasePart
								end
							end
						end
					end
				end

				for _, part in nearbyParts do
					if not part:IsA("BasePart") then continue end
					if not mPartToTriangles[part] then
						if hasCornerNearCached(part, pos) or part == bootstrapPart then
							-- Pass the region's viewPoint so a bootstrapped Block adopts its
							-- camera-facing face (nil on the rebuild, where pos is a corner).
							discoverPart(part, pos, viewPoint, nearbyResolver)
						end
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

				-- A known boundary vertex whose FULL-radius probe adopted nothing:
				-- nothing new to find here until the mesh changes, so later passes can
				-- skip the query. A radius-capped probe (near the region edge) proves
				-- nothing -- a later pass with more reach could still adopt here, so
				-- it must not be memoised. (The mesh-change bump clears the memo,
				-- including a bump this very probe caused elsewhere -- that just means
				-- one extra re-probe.)
				if vertId and searchRadius >= uncappedSearchRadius and mTopologyGeneration == genBeforeProbe then
					mProbedClean[posHash] = true
				end
			end
		end

		-- Only normalise what this call discovered. For a full rediscover that's everything;
		-- for a local region re-discovery (undo, brush) it keeps the cost O(region), and --
		-- combined with the deterministic edge order -- makes a local rebuild coalesce
		-- identically to a full one. A pass that adopted nothing discovered only triangles
		-- earlier passes already normalised, so skip the (O(region)) sweeps outright.
		if mTopologyGeneration ~= startTopologyGeneration then
			coalesceWedgePairs(discovered)
			orientConsistently(discovered)
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
		table.clear(mVertexEdges)
		unwatchAllParts()
		mNextVertexId = 1
		mNextTriangleId = 1
		mNextEdgeId = 1
		bumpTopology()
	end

	-- Fire VertexChanged for each of the given ids without otherwise touching the mesh. After
	-- a full rediscovery (clear + rebuild) the caller passes the pre-clear ids so listeners --
	-- the discovered-vertex markers -- reconcile them: an id the rebuild recreated still has a
	-- vertex (its marker is kept/repositioned), while one it didn't (e.g. geometry removed by
	-- undoing a grid generation) now resolves to nil, so its stale marker is dropped. clear()
	-- stays silent so the rebuild can reuse the markers it does recreate, no instance churn.
	local function notifyVerticesChanged(ids: { number })
		for _, id in ids do
			mVertexChanged:Fire(id)
		end
	end

	---------------------------------------------------------------------------
	-- Return the mesh interface
	---------------------------------------------------------------------------

	return {
		-- Data access
		getVertices = getVertices,
		VertexChanged = mVertexChanged,
		getTriangles = getTriangles,
		getEdges = getEdges,
		getVertex = getVertex,
		getTriangle = getTriangle,
		getGeneration = function(): number
			return mGeneration
		end,
		getTopologyGeneration = function(): number
			return mTopologyGeneration
		end,

		-- Queries
		getBoundaryEdges = getBoundaryEdges,
		getSetBoundaryEdges = getSetBoundaryEdges,
		getVertexNeighbors = getVertexNeighbors,
		findVertexNear = findVertexNear,

		-- Mutations
		addTriangle = addTriangle,
		removeTriangle = removeTriangle,
		moveVertex = moveVertex,
		moveVertices = moveVertices,
		mergeVertices = mergeVertices,
		mergeWedgeTriangles = mergeWedgeTriangles,
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
		notifyVerticesChanged = notifyVerticesChanged,

		-- External-change watching (Team Create staleness)
		PartsExternallyChanged = mPartsExternallyChanged,
		markPartsEdited = markPartsEdited,
		setWatchEnabled = setWatchEnabled,
		debugGetWatchStats = function(): WatchStats
			return table.clone(mWatchStats)
		end,
		-- Drop all part listeners. Call when the session owning the mesh goes away;
		-- the mesh is unusable for watching afterwards (tracked parts stay tracked
		-- but external edits to them go unseen).
		destroy = unwatchAllParts,
	} :: TriangleMesh
end

return createTriangleMesh
