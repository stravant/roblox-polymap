--!strict

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local DraggerFramework = require(Packages.DraggerFramework)
local DraggerSchemaCore = require(Packages.DraggerSchemaCore)
local Roact = require(Packages.Roact)
local Signal = require(Packages.Signal)

local DraggerContext_PluginImpl = (require :: any)(DraggerFramework.Implementation.DraggerContext_PluginImpl)
local DraggerToolComponent = (require :: any)(DraggerFramework.DraggerTools.DraggerToolComponent)
local MoveHandles = require("./Dragger/MoveHandles")
local RotateHandles = require("./Dragger/RotateHandles")

local Settings = require("./Settings")
local createTriangleMesh = require("./TriangleMesh")
local fillTriangle = require("./fillTriangle")
local generateGrid = require("./generateGrid")
local importHeightmap = require("./importHeightmap")

local kSpherecastRadius = 2

-- Minimum on-screen cursor travel (pixels) between successive deletions within one
-- Delete stroke. Without it, a cursor lingering over a spot chews straight back
-- through the parts behind the one just deleted (the raycast re-hits whatever is
-- newly frontmost each frame). Requiring movement keeps a click to the single part
-- under it while still letting a drag sweep across the surface.
local kDeleteMinDragPixels = 10

-- A new hit sitting more than this far BEHIND the surface being deleted (measured
-- along that surface's normal) is treated as a separate layer -- e.g. the far wall
-- of a cave once the near wall is gone -- and skipped. This catches what the
-- movement guard misses: a drag that sweeps over a hole and onto the surface
-- behind. The tolerance scales with view distance (bigger features when zoomed out)
-- with a floor for close-up work.
local kDeleteDepthFloor = 4
local kDeleteDepthFraction = 0.25

-- Key for the edge between two vertex ids, matching how TriangleMesh.getEdges()
-- keys its result so an edge can be looked up by its endpoints.
local function edgeKey(a: number, b: number): string
	return tostring(math.min(a, b)) .. "_" .. tostring(math.max(a, b))
end

-- A point on the ground plane ~20 studs in front of the camera, plus the
-- flattened (horizontal) look direction. Used to place generated geometry
-- (grids, heightmaps) in front of the user; falls back to the world origin.
local function groundPointAhead(): (Vector3, Vector3)
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector3.zero, Vector3.zAxis
	end
	local look = camera.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = if flatLook.Magnitude > 0.01 then flatLook.Unit else Vector3.zAxis
	local pos = camera.CFrame.Position + flatLook * 20
	return Vector3.new(pos.X, 0, pos.Z), flatLook
end

-- The template baseplate is skipped by the cursor (and discovery) across every
-- tool, so it's never targeted or turned into mesh. People keep terrain Locked, so
-- we filter this one part by name rather than ignoring all Locked parts.
local kIgnoredPartName = "Baseplate"

-- Run a cast, skipping any hit on an ignored part by excluding it and re-casting,
-- so the part behind it (or empty space) is returned instead. Bounded in case
-- several ignored parts stack.
local function castSkippingIgnored(cast: (RaycastParams) -> RaycastResult?): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	params.FilterDescendantsInstances = exclude
	for _ = 1, 8 do
		local result = cast(params)
		if not result or result.Instance.Name ~= kIgnoredPartName then
			return result
		end
		table.insert(exclude, result.Instance)
		params.FilterDescendantsInstances = exclude
	end
	return nil
end

local function mouseRaycast(screenPos: Vector2?): RaycastResult?
	local mouseLocation = screenPos or UserInputService:GetMouseLocation()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return castSkippingIgnored(function(params)
		return workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	end)
end

-- Raycast with a spherecast fallback for modes that want loose targeting
local function mouseRaycastLoose(screenPos: Vector2?): RaycastResult?
	local mouseLocation = screenPos or UserInputService:GetMouseLocation()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	local result = castSkippingIgnored(function(params)
		return workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	end)
	if result then
		return result
	end
	return castSkippingIgnored(function(params)
		return workspace:Spherecast(ray.Origin, kSpherecastRadius, ray.Direction * 1000, params)
	end)
end

local function createCFrameDraggerSchema(isEmptyFunc, getBoundingBoxFunc)
	local schema = table.clone(DraggerSchemaCore)
	schema.getMouseTarget = function()
		return nil
	end
	schema.addUndoWaypoint = function()
		-- Noop: we manage undo recording ourselves
	end
	schema.SelectionInfo = {
		new = function(_context, _selection)
			return {
				isEmpty = function(_self)
					return isEmptyFunc()
				end,
				getBoundingBox = function(_self)
					return getBoundingBoxFunc()
				end,
				getAllAttachments = function(_self)
					return {}
				end,
				getObjectsToTransform = function(_self)
					return {}, {}, {}
				end,
				getBasisObject = function(_self)
					return nil
				end,
				getOriginalCFrameMap = function(_self)
					return {}
				end,
				getTransformedCopy = function(_self, _globalTransform)
					return _self
				end,
			}
		end,
	} :: any
	return schema
end

local function createFixedSelection()
	local selectionChangedSignal = Signal.new()
	return {
		Get = function()
			return { workspace.Terrain }
		end,
		Set = function(_newSelection, _hint)
			task.defer(function()
				selectionChangedSignal:Fire()
			end)
		end,
		SelectionChanged = selectionChangedSignal,
	}
end

local function createPolyMapSession(plugin: Plugin, currentSettings: Settings.PolyMapSettings)
	local session = {}
	local changeSignal = Signal.new()

	local mMesh = createTriangleMesh(currentSettings.Thickness)

	-- Selection state
	local mSelectedVertices: { [number]: boolean } = {}
	local mHoverVertexId: number? = nil
	local mHoverEdgeKey: string? = nil
	local mHoverTriangleIds: { number } = {}

	-- Add mode state
	local mAddBoundaryEdge: { v1: number, v2: number }? = nil
	-- Fresh corner positions placed in empty space (the build-from-clicks path).
	-- An edge grab uses mAddBoundaryEdge instead; the two are mutually exclusive
	-- within one in-progress triangle.
	local mAddPoints: { Vector3 } = {}
	-- Whether any placed corner snapped onto an existing vertex. A fully-disconnected
	-- fresh triangle is lifted a thickness so it rests ABOVE where it was placed; one
	-- that snapped stays put to connect flush ("below").
	local mAddSnappedAny = false
	-- Thickness of the existing geometry this triangle snaps onto (a snapped corner's
	-- triangle, or a grabbed/closed boundary edge's). With MatchThickness on it is used
	-- in place of the Thickness setting so the new triangle matches what it connects to.
	local mAddSnappedThickness: number? = nil
	-- Plane (a point on the snapped geometry and its triangle normal) of the first
	-- corner that snapped. With AddNonSnapped == "Extend" the remaining non-snapped
	-- corners are projected onto this plane so the new triangle stays coplanar with
	-- what it connects to; "Flat" ignores the normal and keeps them horizontal.
	local mAddSnappedPoint: Vector3? = nil
	local mAddSnappedNormal: Vector3? = nil
	-- Container (folder) of the geometry a fresh polygon snapped onto, if any; new
	-- parts join it so connected geometry stays together (else a fresh folder).
	local mAddSnappedParent: Instance? = nil
	local mAddPlanePoint: Vector3? = nil
	local mAddPlaneNormal: Vector3? = nil
	local mAddHoverTarget: { type: string, vertexId: number?, edgeKey: string?, position: Vector3? }? = nil
	local mAddTriangleProps: fillTriangle.TriangleProps? = nil
	-- Container (folder) of the boundary edge grabbed in Add phase 1.
	local mAddBoundaryFolder: Instance? = nil

	-- Interactive "Place grid" state (the Place... button in the Generate panel):
	-- the user clicks two opposite corners; the grid spans the rectangle between
	-- them, with those points as its diagonal. Picking mirrors the Add poly tool.
	local mGridPlacing = false
	local mGridFirstPoint: Vector3? = nil
	local mGridHoverPoint: Vector3? = nil
	-- Whether the first corner snapped onto an existing mesh vertex. If so the grid is
	-- placed a thickness lower so its discovered vertices land ON that vertex (aligning
	-- with the existing mesh) rather than a thickness above it (sitting on top).
	local mGridFirstSnapped = false
	-- The vertex a placed grid's corner snapped onto, if any; its container becomes
	-- the new grid's folder (else a fresh one is made).
	local mGridFirstSnapVid: number? = nil

	-- Marquee state
	local mMarqueeStart: Vector2? = nil
	local mMarqueeEnd: Vector2? = nil
	local mPreMarqueeSelection: { [number]: boolean } = {}

	-- Input connections
	local mIsOverUI = false

	-- Dragger state
	local mIsDraggingHandle = false
	-- Assigned once the move/rotate handles exist (far below). Reports whether the
	-- cursor is currently over a handle, so the hover outline can hide -- mirroring
	-- how the dragger's own HoverTracker suppresses surface hover over a handle.
	local queryMouseOverHandle: (() -> boolean)? = nil
	local mDragRecording: string? = nil
	local mSavedVertexPositions: { [number]: Vector3 } = {}
	local mInfluencedVertices: { [number]: { position: Vector3, factor: number } } = {}
	local mDragCentroid: Vector3? = nil

	-- Delete/Paint drag state
	local mStrokeDragging = false
	local mStrokeRecording: string? = nil
	-- Screen position of the last deletion this stroke; gates the drill guard.
	local mDeleteLastScreenPos: Vector2? = nil
	-- Hit point + surface normal of the last deletion; gate the depth guard.
	local mDeleteLastHitPoint: Vector3? = nil
	local mDeleteLastHitNormal: Vector3? = nil
	local mStrokePlanePoint: Vector3? = nil
	local mStrokePlaneNormal: Vector3? = nil

	-- Surface-walk seed: the triangle under the cursor at stroke start, persists
	-- during a stroke so plane-fallback frames still have a seed to walk from.
	local mStrokeSeedTriangleId: number? = nil

	-- Paint: original colors at stroke start so partial strength applies correctly.
	local mPaintOriginalColors: { [BasePart]: Color3 } = {}

	-- Brush tools (Flatten/Relax): snapshot of vertex positions at stroke start,
	-- and per-vertex accumulated amount (0 to 1) for progressive application.
	local mBrushSavedPositions: { [number]: Vector3 } = {}
	local mBrushAmounts: { [number]: number } = {}

	-- Import progress: nil when idle, 0-1 when importing
	local mImportProgress: number? = nil

	-- Undo/redo: save selected vertex positions so selection survives rescan
	local mUndoSelections: { { Vector3 } } = {}
	local mRedoSelections: { { Vector3 } } = {}

	-- Most recent non-empty rediscovery seeds. Lets redoing a creation after it
	-- was fully undone (current mesh empty, so nothing to seed from) still
	-- re-find the restored parts.
	local mLastRediscoverSeeds: { Vector3 } = {}

	local function captureSelectionPositions(): { Vector3 }
		local positions: { Vector3 } = {}
		for vid in mSelectedVertices do
			local v = mMesh.getVertex(vid)
			if v then
				table.insert(positions, v.position)
			end
		end
		return positions
	end

	local function restoreSelectionFromPositions(positions: { Vector3 })
		mSelectedVertices = {}
		for _, pos in positions do
			local vid = mMesh.findVertexNear(pos, 0.1)
			if vid then
				mSelectedVertices[vid] = true
			end
		end
	end

	local function pushUndoSnapshot()
		table.insert(mUndoSelections, captureSelectionPositions())
		mRedoSelections = {}
	end

	-- Run a one-shot mesh edit inside a ChangeHistory recording. The pre-op
	-- selection snapshot is committed to the undo stack iff body() reports it
	-- actually changed something -- keeping the undo/redo selection stacks
	-- balanced with the committed waypoints so undo restores the right
	-- selection (and no-ops/failed recordings don't desync them). Returns
	-- whether a change was made.
	local function runUndoableOperation(name: string, body: () -> boolean): boolean
		local snapshot = captureSelectionPositions()
		local recording = ChangeHistoryService:TryBeginRecording(name)
		local changed = body()
		if changed then
			table.insert(mUndoSelections, snapshot)
			mRedoSelections = {}
			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			else
				ChangeHistoryService:SetWaypoint(name)
			end
		elseif recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
		end
		return changed
	end

	local VERTEX_CLICK_RADIUS = 3.0 -- world-space radius to find vertex

	local function getTriangleProps(): fillTriangle.TriangleProps
		local c = currentSettings.PaintColor
		return {
			Color = Color3.new(c[1], c[2], c[3]),
			Material = (Enum.Material :: any)[currentSettings.PaintMaterial] or Enum.Material.Plastic,
			MaterialVariant = currentSettings.PaintMaterialVariant,
		}
	end

	local function clearAddState()
		mAddBoundaryEdge = nil
		mAddPoints = {}
		mAddSnappedAny = false
		mAddSnappedThickness = nil
		mAddSnappedPoint = nil
		mAddSnappedNormal = nil
		mAddPlanePoint = nil
		mAddPlaneNormal = nil
		mAddHoverTarget = nil
		mAddTriangleProps = nil
		mAddSnappedParent = nil
		mAddBoundaryFolder = nil
	end

	-- New mesh parts are organised into Folders under workspace: a fresh
	-- (non-snapped) grid or polygon gets its own new folder, while geometry added
	-- onto existing content joins that content's container so a connected piece
	-- stays together. These resolve the container of already-built geometry.
	local function parentForTriangle(tid: number?): Instance?
		if not tid then
			return nil
		end
		local tri = mMesh.getTriangle(tid)
		if not tri then
			return nil
		end
		for _, part in tri.parts do
			if part.Parent then
				return part.Parent
			end
		end
		return nil
	end
	local function parentForVertex(vid: number?): Instance?
		if not vid then
			return nil
		end
		local vertex = mMesh.getVertex(vid)
		if not vertex then
			return nil
		end
		for _, tid in vertex.triangles do
			local p = parentForTriangle(tid)
			if p then
				return p
			end
		end
		return nil
	end
	-- The colour/material of the geometry a snapped vertex belongs to, so new content
	-- can match it instead of the current paint settings.
	local function propsForVertex(vid: number?): fillTriangle.TriangleProps?
		if not vid then
			return nil
		end
		local vertex = mMesh.getVertex(vid)
		if not vertex then
			return nil
		end
		for _, tid in vertex.triangles do
			local tri = mMesh.getTriangle(tid)
			local part = if tri then tri.parts[1] else nil
			if part then
				return { Color = part.Color, Material = part.Material, MaterialVariant = part.MaterialVariant }
			end
		end
		return nil
	end
	local function newMeshFolder(): Folder
		local folder = Instance.new("Folder")
		folder.Name = "PolyMapMesh"
		folder.Parent = workspace
		return folder
	end
	-- Where new parts go: the snapped content's container, or a fresh folder.
	local function resolveNewParent(snappedParent: Instance?): Instance
		return snappedParent or newMeshFolder()
	end

	-- No initial scan — mesh starts empty, discovery happens on demand

	local function isShiftHeld(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end

	local function getSelectedVertexCount(): number
		local count = 0
		for _ in mSelectedVertices do
			count += 1
		end
		return count
	end

	local function getSelectedVertexIds(): { number }
		local ids: { number } = {}
		for id in mSelectedVertices do
			table.insert(ids, id)
		end
		return ids
	end

	local function getSelectionCentroid(): Vector3?
		local ids = getSelectedVertexIds()
		if #ids == 0 then
			return nil
		end
		local sum = Vector3.zero
		for _, id in ids do
			local v = mMesh.getVertex(id)
			if v then
				sum += v.position
			end
		end
		return sum / #ids
	end

	local VERTEX_SCREEN_RADIUS = 10000 -- max screen-space pixels to find a vertex

	local function findNearestVertex(worldPos: Vector3, hitTriangleId: number?): number?
		local camera = workspace.CurrentCamera
		if not camera then
			return mMesh.findVertexNear(worldPos, VERTEX_CLICK_RADIUS)
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestId: number? = nil
		local bestScreenDist = VERTEX_SCREEN_RADIUS

		-- When we know which triangle the cursor hit, only consider that
		-- triangle's vertices so we never select through the mesh.
		if hitTriangleId then
			local tri = mMesh.getTriangle(hitTriangleId)
			if tri then
				for _, vid in tri.vertices do
					local vertex = mMesh.getVertex(vid)
					if not vertex then continue end
					local screenPos, onScreen = camera:WorldToScreenPoint(vertex.position)
					if onScreen then
						local dx = screenPos.X - mouseScreen.X
						local dy = screenPos.Y - mouseScreen.Y
						local dist = math.sqrt(dx * dx + dy * dy)
						if dist < bestScreenDist then
							bestScreenDist = dist
							bestId = vid
						end
					end
				end
				return bestId
			end
		end

		for id, vertex in mMesh.getVertices() do
			local screenPos, onScreen = camera:WorldToScreenPoint(vertex.position)
			if onScreen then
				local dx = screenPos.X - mouseScreen.X
				local dy = screenPos.Y - mouseScreen.Y
				local dist = math.sqrt(dx * dx + dy * dy)
				if dist < bestScreenDist then
					bestScreenDist = dist
					bestId = id
				end
			end
		end

		return bestId
	end

	local function findNearestBoundaryEdge(worldPos: Vector3, triangleIds: { number }, skipEdgeKey: string?): string?
		local bestKey: string? = nil
		local bestDist = math.huge

		-- Collect candidate edge keys from all given triangles
		local seen: { [string]: boolean } = {}
		local edges = mMesh.getEdges()
		for _, triId in triangleIds do
			local tri = mMesh.getTriangle(triId)
			if not tri then continue end
			local verts = tri.vertices
			local keys = {
				edgeKey(verts[1], verts[2]),
				edgeKey(verts[2], verts[3]),
				edgeKey(verts[1], verts[3]),
			}
			for _, key in keys do
				if seen[key] then continue end
				seen[key] = true
				local edge = edges[key]
				if not edge then continue end
				if #edge.triangles ~= 1 then continue end
				if key == skipEdgeKey then continue end
				local v1 = mMesh.getVertex(edge.v1)
				local v2 = mMesh.getVertex(edge.v2)
				if not v1 or not v2 then continue end

				local seg = v2.position - v1.position
				local lenSq = seg:Dot(seg)
				local t = if lenSq < 0.001 then 0 else math.clamp((worldPos - v1.position):Dot(seg) / lenSq, 0, 1)
				local closest = v1.position + seg * t
				local dist = (worldPos - closest).Magnitude

				if dist < bestDist then
					bestDist = dist
					bestKey = key
				end
			end
		end

		return bestKey
	end

	-- The cursor's world position projected onto a sensible plane, so Add can place
	-- points over empty space where the raycast misses. When the new triangle has
	-- connected to existing geometry (a grabbed edge or a snapped corner), the
	-- AddNonSnapped setting picks the plane: "Extend" lays it in the snapped surface's
	-- plane (its normal), "Flat" keeps it horizontal. Unconnected points fall back to a
	-- horizontal plane through the first point, or the ground for the very first point.
	local function addProjectedPos(): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local mouseLocation = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		local extend = currentSettings.AddNonSnapped == "Extend"
		local planePoint: Vector3
		local planeNormal: Vector3
		if mAddBoundaryEdge and mAddPlanePoint and mAddPlaneNormal then
			planePoint = mAddPlanePoint
			planeNormal = if extend then mAddPlaneNormal else Vector3.yAxis
		elseif mAddSnappedPoint then
			planePoint = mAddSnappedPoint
			planeNormal = if extend and mAddSnappedNormal then mAddSnappedNormal else Vector3.yAxis
		elseif #mAddPoints > 0 then
			planePoint, planeNormal = mAddPoints[1], Vector3.yAxis
		else
			planePoint, planeNormal = (groundPointAhead()), Vector3.yAxis
		end
		local denom = ray.Direction:Dot(planeNormal)
		if math.abs(denom) < 1e-4 then
			return nil
		end
		local t = (planePoint - ray.Origin):Dot(planeNormal) / denom
		if t <= 0 then
			return nil
		end
		return ray.Origin + ray.Direction * t
	end

	-- Snap an Add point to a nearby existing vertex so fresh geometry can connect to
	-- the mesh; returns the (possibly snapped) position and that vertex id, or the
	-- original position and nil.
	local kAddSnapRadius = 2.0
	local function snapAddPoint(worldPos: Vector3): (Vector3, number?)
		local bestVid: number? = nil
		local bestDist = kAddSnapRadius
		for id, vertex in mMesh.getVertices() do
			local dist = (vertex.position - worldPos).Magnitude
			if dist < bestDist then
				bestDist = dist
				bestVid = id
			end
		end
		if bestVid then
			local v = mMesh.getVertex(bestVid)
			if v then
				return v.position, bestVid
			end
		end
		return worldPos, nil
	end

	-- The lift applied to a fresh (unconnected) triangle so it rests a thickness ABOVE
	-- where it was placed: its face-up wedge hangs down from the corners, so without
	-- this the body would sit below the click plane / sink into the clicked surface.
	local function freshLift(): Vector3
		return Vector3.yAxis * currentSettings.Thickness
	end

	-- Thickness of a triangle the given vertex belongs to, or nil if it is loose.
	local function vertexThickness(vertexId: number): number?
		local v = mMesh.getVertex(vertexId)
		if v then
			for _, triId in v.triangles do
				local tri = mMesh.getTriangle(triId)
				if tri then
					return tri.thickness
				end
			end
		end
		return nil
	end

	-- Normal of a triangle the given vertex belongs to, or nil if it is loose.
	local function vertexNormal(vertexId: number): Vector3?
		local v = mMesh.getVertex(vertexId)
		if v then
			for _, triId in v.triangles do
				local tri = mMesh.getTriangle(triId)
				if tri then
					return tri.normal
				end
			end
		end
		return nil
	end

	-- The thickness to build an Add triangle with: the snapped/connected geometry's
	-- thickness when MatchThickness is on and we connected to something, else the
	-- Thickness setting.
	local function resolveAddThickness(connectedThickness: number?): number
		if currentSettings.MatchThickness and connectedThickness then
			return connectedThickness
		end
		return currentSettings.Thickness
	end

	-- Walk the surface within radius of worldPos, discovering it first. walkSurface
	-- only traverses ALREADY-discovered triangles, and on a freshly opened tool only
	-- the single part directly under the cursor has been discovered -- so the brush
	-- tools (and their hover preview) would find an empty/incomplete region. The
	-- Move tool's influence drag already discovers-then-walks the same way; this
	-- gives the brush tools the same. discoverRegion is incremental, so repeated
	-- calls as the cursor moves only discover newly-entered geometry.
	-- The camera eye, used as the face-disambiguation viewpoint for discovery: a thin
	-- Block adopts the face the user is looking at rather than the side the cursor
	-- crossed (or, on a baseplate, the bottom plane the region scan's seed sits on).
	-- For wedges the viewpoint is ignored.
	local function cameraViewPoint(): Vector3?
		local camera = workspace.CurrentCamera
		return if camera then camera.CFrame.Position else nil
	end
	local function discoverPartViewed(part: BasePart, hitPoint: Vector3): number?
		-- refuseAwayFace = true: a single interactive hover/click must not START a
		-- part's discovery on the far (back) face the cursor grazes at its thin edge;
		-- it waits until the cursor is genuinely over the camera-facing side.
		return mMesh.discoverPart(part, hitPoint, cameraViewPoint(), nil, true)
	end
	local function discoverRegionViewed(seeds: { Vector3 }, radius: number)
		return mMesh.discoverRegion(seeds, radius, cameraViewPoint())
	end

	local function discoverAndWalkSurface(seedTriangleId: number, worldPos: Vector3, radius: number)
		discoverRegionViewed({ worldPos }, radius)
		return mMesh.walkSurface(seedTriangleId, worldPos, radius)
	end

	-- The nearest boundary edge of the part under the cursor, or nil. Discovers the
	-- part's neighbours first (so interior edges aren't mistaken for boundary) and,
	-- given a hit normal, prefers edges of the camera-facing face over a back face.
	-- Shared by the Add tool's edge-grab (edge first) and edge-close (apex first).
	local function boundaryEdgeAt(worldPos: Vector3, hitPart: BasePart, normal: Vector3?): string?
		local size = hitPart.Size
		local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
		discoverRegionViewed({ worldPos }, extent)
		local partTriIds = mMesh.getPartTriangles(hitPart)
		if normal then
			local filtered = {}
			for _, triId in partTriIds do
				local tri = mMesh.getTriangle(triId)
				if tri and tri.normal:Dot(normal) > 0 then
					table.insert(filtered, triId)
				end
			end
			if #filtered > 0 then
				partTriIds = filtered
			end
		end
		return findNearestBoundaryEdge(worldPos, partTriIds, nil)
	end

	----------------------------------------------------------------------
	-- Interactive grid placement (the Place... button)
	----------------------------------------------------------------------
	local function clearGridPlacement()
		mGridPlacing = false
		mGridFirstPoint = nil
		mGridHoverPoint = nil
		mGridFirstSnapped = false
		mGridFirstSnapVid = nil
	end

	-- Generate a cols x rows cell grid (cells cellW x cellH) centred on origin, then
	-- discover it from the camera-facing surface. Shared by GenerateGrid (settings-
	-- sized, centred ahead) and the Place tool (spanning two clicked corners).
	local function generateGridWithParams(origin: CFrame, cols: number, rows: number, cellW: number, cellH: number, snapVid: number?)
		runUndoableOperation("PolyMap Generate Grid", function(): boolean
			-- Snapped onto an existing vertex -> share its folder; otherwise a fresh
			-- folder. Resolved inside the recording so an undo removes the folder too.
			local parent = resolveNewParent(parentForVertex(snapVid))
			-- Snapped onto existing geometry -> match its colour/material; else use the
			-- current paint settings.
			local props = propsForVertex(snapVid) or getTriangleProps()
			generateGrid({
				GridType = currentSettings.GridType,
				Width = cols,
				Height = rows,
				Spacing = currentSettings.GridSpacing,
				CellWidth = cellW,
				CellHeight = cellH,
				Origin = origin,
				Thickness = currentSettings.Thickness,
				Parent = parent,
				Props = props,
			})
			return true
		end)

		-- Seed from the camera-facing surface (origin sits on the wedges' back plane;
		-- a raycast onto the visible front face gives the right side). The radius
		-- reaches the far corner from the centre.
		local gridW, gridH = cols * cellW, rows * cellH
		local gridExtent = math.sqrt(gridW * gridW + gridH * gridH) / 2
			+ math.max(cellW, cellH, currentSettings.GridSpacing) + 1
		local seedPoint = origin.Position
		local camera = workspace.CurrentCamera
		if camera then
			local toGrid = origin.Position - camera.CFrame.Position
			local hit = workspace:Raycast(camera.CFrame.Position, toGrid * 1.5)
			if hit then
				seedPoint = hit.Position
			end
		end
		discoverRegionViewed({ seedPoint }, gridExtent)
		changeSignal:Fire()
	end

	-- Centre, cell counts and per-axis cell sizes for a grid whose diagonal is
	-- p1->p2. The count snaps to the spacing (round) and the cell size then stretches
	-- so the corners land exactly on p1/p2. Shared by the commit and its preview.
	local function gridLayoutFromCorners(p1: Vector3, p2: Vector3): (Vector3, number, number, number, number)
		local spacing = math.max(currentSettings.GridSpacing, 0.1)
		local dx, dz = math.abs(p2.X - p1.X), math.abs(p2.Z - p1.Z)
		local cols = math.max(1, math.round(dx / spacing))
		local rows = math.max(1, math.round(dz / spacing))
		local cellW = if dx > 0.01 then dx / cols else spacing
		local cellH = if dz > 0.01 then dz / rows else spacing
		local center = Vector3.new((p1.X + p2.X) / 2, p1.Y, (p1.Z + p2.Z) / 2)
		return center, cols, rows, cellW, cellH
	end

	local function generateGridBetween(p1: Vector3, p2: Vector3, firstSnapped: boolean, snapVid: number?)
		local center, cols, rows, cellW, cellH = gridLayoutFromCorners(p1, p2)
		-- Discovered vertices land a thickness above the generation plane. When the
		-- first corner snapped to an existing vertex, lower the plane by that thickness
		-- so the new vertices land ON the existing one (aligned) instead of on top of
		-- it. When it did not snap (e.g. on the baseplate) keep the plane so the grid
		-- sits on top of whatever surface was clicked.
		if firstSnapped then
			center -= Vector3.new(0, currentSettings.Thickness, 0)
		end
		generateGridWithParams(CFrame.new(center), cols, rows, cellW, cellH, snapVid)
	end

	-- The cursor projected onto the placement plane: a horizontal plane through the
	-- first corner once set, else the ground ahead of the camera. Mirrors the Add
	-- tool so the two corners stay coplanar (a flat grid).
	local function gridProjectedPos(): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local mouseLocation = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		local planePoint = if mGridFirstPoint then mGridFirstPoint else (groundPointAhead())
		local denom = ray.Direction:Dot(Vector3.yAxis)
		if math.abs(denom) < 1e-4 then
			return nil
		end
		local t = (planePoint - ray.Origin):Dot(Vector3.yAxis) / denom
		if t <= 0 then
			return nil
		end
		return ray.Origin + ray.Direction * t
	end

	-- Where the next corner would land, and whether it snapped onto an existing vertex.
	-- The FIRST corner snaps onto hit geometry (so a grid can sit on a surface); the
	-- second projects onto the first corner's plane. Either corner then snaps to a
	-- nearby existing vertex so a placed grid lines up with the mesh (same snap used by
	-- the Add poly tool).
	local function gridPlacementPos(): (Vector3?, number?)
		local result = mouseRaycastLoose()
		-- Discover the part under the cursor (and its neighbours) so there are real
		-- vertices to snap to, exactly as the Add poly tool does before snapAddPoint.
		-- Without this we could only snap to parts that some earlier action already
		-- discovered; discoverRegion is incremental so re-running it as the cursor
		-- moves only costs for newly entered geometry.
		if result and result.Instance:IsA("BasePart") then
			local hitPart = result.Instance :: BasePart
			local size = hitPart.Size
			local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
			discoverRegionViewed({ result.Position }, extent)
		end
		local pos: Vector3?
		if not mGridFirstPoint then
			pos = if result then result.Position else gridProjectedPos()
		else
			pos = gridProjectedPos()
		end
		if not pos then
			return nil, false
		end
		local snapped, snapVid = snapAddPoint(pos)
		return snapped, snapVid
	end

	local function updateGridPlaceHover()
		local newHover = gridPlacementPos()
		if newHover ~= mGridHoverPoint then
			mGridHoverPoint = newHover
			changeSignal:Fire()
		end
	end

	-- First click anchors a corner; the second generates the grid and ends placement.
	local function handleGridPlaceClick()
		local pos, snapVid = gridPlacementPos()
		if not pos then
			return
		end
		if not mGridFirstPoint then
			mGridFirstPoint = pos
			mGridFirstSnapped = snapVid ~= nil
			mGridFirstSnapVid = snapVid
			mGridHoverPoint = pos
			changeSignal:Fire()
		else
			local p1 = mGridFirstPoint
			local firstSnapped = mGridFirstSnapped
			-- Either corner snapping is enough to join that geometry's folder.
			local snap = mGridFirstSnapVid or snapVid
			clearGridPlacement()
			generateGridBetween(p1, pos, firstSnapped, snap)
		end
	end

	local function updateHover(screenPosOverride: Vector2?)
		-- Leaving Add mode abandons any in-progress triangle (edge grab or fresh
		-- points), so stale state doesn't reappear on returning to Add.
		if currentSettings.Mode ~= "Add" and (mAddBoundaryEdge or #mAddPoints > 0) then
			clearAddState()
			changeSignal:Fire()
		end
		-- Leaving the Generate panel abandons an in-progress grid placement.
		if currentSettings.Mode ~= "Generate" and mGridPlacing then
			clearGridPlacement()
			changeSignal:Fire()
		end
		-- Hide all hover feedback when the cursor is over the panel, mid-drag, or
		-- over a Move/Rotate handle (the dragger hovers the handle, not the surface).
		if mIsOverUI or mIsDraggingHandle or (queryMouseOverHandle ~= nil and queryMouseOverHandle()) then
			if mHoverVertexId ~= nil or mHoverEdgeKey ~= nil or #mHoverTriangleIds > 0 or mAddHoverTarget ~= nil then
				mHoverVertexId = nil
				mHoverEdgeKey = nil
				mHoverTriangleIds = {}
				mAddHoverTarget = nil
				changeSignal:Fire()
			end
			return
		end

		-- While placing a grid, the cursor only updates the placement preview.
		if mGridPlacing then
			updateGridPlaceHover()
			return
		end

		-- Use loose targeting (spherecast fallback) for selection/add modes
		local mode = currentSettings.Mode
		local useLoose = mode == "Move" or mode == "Rotate" or mode == "Add"
		local result = if useLoose then mouseRaycastLoose(screenPosOverride) else mouseRaycast(screenPosOverride)
		local newHoverVertex: number? = nil
		local newHoverEdge: string? = nil
		local newHoverTriangles: { number } = {}
		local oldAddHoverTarget = mAddHoverTarget
		mAddHoverTarget = nil

		-- Compute world position: use raycast hit, or stroke plane fallback during drag
		local worldPos: Vector3? = if result then result.Position else nil
		if not worldPos and mStrokeDragging and mStrokePlanePoint and mStrokePlaneNormal then
			local camera = workspace.CurrentCamera
			if camera then
				local mouseLocation = screenPosOverride or UserInputService:GetMouseLocation()
				local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
				local denom = ray.Direction:Dot(mStrokePlaneNormal)
				if math.abs(denom) > 0.0001 then
					local t = (mStrokePlanePoint - ray.Origin):Dot(mStrokePlaneNormal) / denom
					if t > 0 then
						worldPos = ray.Origin + ray.Direction * t
					end
				end
			end
		end
		-- Add mode places points over empty space: when nothing was hit, project the
		-- cursor onto the appropriate plane so hover (and the click) have a position.
		if not worldPos and mode == "Add" then
			worldPos = addProjectedPos()
		end

		local hitTriangleId: number? = nil
		if result and result.Instance:IsA("BasePart") then
			-- Discover the part under the cursor (O(1) for already-tracked parts)
			discoverPartViewed(result.Instance, result.Position)
			hitTriangleId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
		end

		if worldPos then
			if mode == "Move" or mode == "Rotate" then
				newHoverVertex = findNearestVertex(worldPos, hitTriangleId)
			end
			if mode == "Delete" then
				if currentSettings.DeleteTarget == "Vertex" then
					-- Mark the vertex under the cursor (the marker pinpoints it) and
					-- outline the fan of triangles deleting it would remove, so the
					-- affected area reads the same way Face mode's hovered triangle does.
					-- Discover the neighbourhood first, exactly as the click does: a bare
					-- hover only discovered the single part under the cursor, so the
					-- vertex's fan was missing faces from adjacent not-yet-discovered
					-- parts -- the outline under-reported what a click would actually
					-- remove.
					if hitTriangleId then
						discoverRegionViewed({ worldPos }, 15)
					end
					newHoverVertex = findNearestVertex(worldPos, hitTriangleId)
					if newHoverVertex then
						local vertex = mMesh.getVertex(newHoverVertex)
						if vertex then
							newHoverTriangles = table.clone(vertex.triangles)
						end
					end
				else
					-- Face mode: hover the triangle(s) that would be affected
					local radius = currentSettings.DeleteRadius
					if radius > 0 and hitTriangleId then
						newHoverTriangles = discoverAndWalkSurface(hitTriangleId, worldPos, radius)
					elseif result and result.Instance:IsA("BasePart") then
						local triId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
						if triId then
							newHoverTriangles = { triId }
						end
					end
				end
			end
			if mode == "Paint" then
				local radius = if currentSettings.PaintEyedropper ~= "None" then 0 else currentSettings.PaintRadius
				if radius > 0 and hitTriangleId then
					newHoverTriangles = discoverAndWalkSurface(hitTriangleId, worldPos, radius)
				elseif result and result.Instance:IsA("BasePart") then
					local triId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
					if triId then
						newHoverTriangles = { triId }
					end
				end
			end
			if mode == "Relax" then
				local radius = currentSettings.RelaxRadius
				if radius > 0 and hitTriangleId then
					newHoverTriangles = discoverAndWalkSurface(hitTriangleId, worldPos, radius)
				end
			end
			if mode == "Flatten" then
				local radius = currentSettings.FlattenRadius
				if radius > 0 and hitTriangleId then
					newHoverTriangles = discoverAndWalkSurface(hitTriangleId, worldPos, radius)
				end
			end
		end

		if mode == "Add" and not mAddBoundaryEdge then
			-- Phase 1: highlight a boundary edge of geometry under the cursor. With no
			-- fresh point yet a click would grab it (build from the edge); with one
			-- placed a click would close the apex onto it (extend the edge). Either way
			-- show the highlight so both build orders read the same.
			local grabbedEdge: string? = nil
			if worldPos and #mAddPoints <= 1 and result and result.Instance:IsA("BasePart") then
				grabbedEdge = boundaryEdgeAt(worldPos, result.Instance :: BasePart, result.Normal)
			end
			if grabbedEdge then
				newHoverEdge = grabbedEdge
			elseif worldPos then
				-- No edge nearby: offer fresh vertex placement (snap to a near vertex).
				local snapped, snapVid = snapAddPoint(worldPos)
				if snapVid then
					newHoverVertex = snapVid
				end
				mAddHoverTarget = { type = "freshVertex", position = snapped }
			end
		end

		-- Add mode phase 2: world-space vertex/edge snapping
		if currentSettings.Mode == "Add" and mAddBoundaryEdge and worldPos then
			local v1 = mMesh.getVertex(mAddBoundaryEdge.v1)
			local v2 = mMesh.getVertex(mAddBoundaryEdge.v2)
			if v1 and v2 then
				local edgeLength = (v2.position - v1.position).Magnitude
				local snapRadius = edgeLength * 0.3

				-- Tier 1: vertex snap (world-space distance)
				local skipVids = { [mAddBoundaryEdge.v1] = true, [mAddBoundaryEdge.v2] = true }
				local bestVid: number? = nil
				local bestVidDist = snapRadius
				for id, vertex in mMesh.getVertices() do
					if skipVids[id] then continue end
					local dist = (vertex.position - worldPos).Magnitude
					if dist < bestVidDist then
						bestVidDist = dist
						bestVid = id
					end
				end

				if bestVid then
					newHoverVertex = bestVid
					mAddHoverTarget = { type = "vertex", vertexId = bestVid }
				else
					-- Tier 2: boundary edge snap (world-space distance)
					-- Skip all edges belonging to the parent triangle or its
					-- sibling (back face of same part), so hovering near the
					-- selected edge doesn't snap to the other face's edge.
					local skipEdgeKeys: { [string]: boolean } = {}
					local storedKey = edgeKey(mAddBoundaryEdge.v1, mAddBoundaryEdge.v2)
					skipEdgeKeys[storedKey] = true
					local storedEdge = mMesh.getEdges()[storedKey]
					if storedEdge then
						for _, parentTriId in storedEdge.triangles do
							local parentTri = mMesh.getTriangle(parentTriId)
							if parentTri then
								-- Skip edges of parent triangle
								for i = 1, 3 do
									local va = parentTri.vertices[i]
									local vb = parentTri.vertices[if i < 3 then i + 1 else 1]
									local ek = edgeKey(va, vb)
									skipEdgeKeys[ek] = true
								end
								-- Skip edges of sibling triangles (other face of same parts)
								for _, part in parentTri.parts do
									for _, sibTriId in mMesh.getPartTriangles(part) do
										local sibTri = mMesh.getTriangle(sibTriId)
										if sibTri then
											for i = 1, 3 do
												local va = sibTri.vertices[i]
												local vb = sibTri.vertices[if i < 3 then i + 1 else 1]
												local ek = edgeKey(va, vb)
												skipEdgeKeys[ek] = true
											end
										end
									end
								end
							end
						end
					end
					local bestEdgeKey: string? = nil
					local bestEdgeDist = snapRadius
					for key, edge in mMesh.getEdges() do
						if #edge.triangles ~= 1 then continue end
						if skipEdgeKeys[key] then continue end
						local ev1 = mMesh.getVertex(edge.v1)
						local ev2 = mMesh.getVertex(edge.v2)
						if not ev1 or not ev2 then continue end
						local seg = ev2.position - ev1.position
						local lenSq = seg:Dot(seg)
						local t = if lenSq < 0.001 then 0 else math.clamp((worldPos - ev1.position):Dot(seg) / lenSq, 0, 1)
						local closest = ev1.position + seg * t
						local dist = (worldPos - closest).Magnitude
						if dist < bestEdgeDist then
							bestEdgeDist = dist
							bestEdgeKey = key
						end
					end

					if bestEdgeKey then
						newHoverEdge = bestEdgeKey
						mAddHoverTarget = { type = "edge", edgeKey = bestEdgeKey }
					else
						-- No snap: use world hit position directly
						mAddHoverTarget = { type = "plane", position = worldPos }
					end
				end
			end
		end

		-- Check if hover state actually changed
		local trianglesChanged = #newHoverTriangles ~= #mHoverTriangleIds
		if not trianglesChanged then
			for i, id in newHoverTriangles do
				if mHoverTriangleIds[i] ~= id then
					trianglesChanged = true
					break
				end
			end
		end

		local addHoverChanged = mAddHoverTarget ~= oldAddHoverTarget
		if newHoverVertex ~= mHoverVertexId or newHoverEdge ~= mHoverEdgeKey or trianglesChanged or addHoverChanged then
			mHoverVertexId = newHoverVertex
			mHoverEdgeKey = newHoverEdge
			mHoverTriangleIds = newHoverTriangles
			changeSignal:Fire()
		end
	end

	local function handleSelectClick(worldPos: Vector3, hitPart: BasePart?)
		discoverRegionViewed({worldPos}, 15)
		local hitTriangleId = if hitPart then mMesh.getPartTriangle(hitPart, worldPos) else nil
		local vid = findNearestVertex(worldPos, hitTriangleId)
		if vid then
			if isShiftHeld() then
				if mSelectedVertices[vid] then
					mSelectedVertices[vid] = nil
				else
					mSelectedVertices[vid] = true
				end
			else
				mSelectedVertices = { [vid] = true }
			end
		else
			if not isShiftHeld() then
				mSelectedVertices = {}
			end
		end
		mSavedVertexPositions = {}
		changeSignal:Fire()
	end

	local function commitFreshTriangle()
		if #mAddPoints < 3 then
			return
		end
		local p1, p2, p3 = mAddPoints[1], mAddPoints[2], mAddPoints[3]
		-- If nothing snapped onto existing geometry, lift the whole triangle a
		-- thickness so it rests above where it was placed rather than sinking below it
		-- (mirrors the Add Grid place tool). A snapped corner stays put to connect
		-- flush, so lifting it would tear the connection -- hence all-or-nothing.
		if not mAddSnappedAny then
			local lift = freshLift()
			p1, p2, p3 = p1 + lift, p2 + lift, p3 + lift
		end
		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Add Triangle")
		-- A disconnected triangle has nothing to match, so hint it to face up.
		local centroid = (p1 + p2 + p3) / 3
		-- Snapped onto existing geometry -> its folder; a fresh triangle -> a new one.
		local parent = resolveNewParent(mAddSnappedParent)
		mMesh.addTriangle(
			p1, p2, p3,
			resolveAddThickness(mAddSnappedThickness), parent, getTriangleProps(), centroid + Vector3.yAxis
		)
		clearAddState()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	-- Place one fresh corner, snapped to a nearby vertex if there is one. The corners
	-- are stored where they were placed; commitFreshTriangle lifts the whole triangle
	-- afterwards unless one of them snapped. The third corner commits.
	local function placeFreshPoint(worldPos: Vector3)
		local snapped, vid = snapAddPoint(worldPos)
		if vid then
			mAddSnappedAny = true
			if not mAddSnappedParent then
				mAddSnappedParent = parentForVertex(vid)
			end
			if not mAddSnappedThickness then
				mAddSnappedThickness = vertexThickness(vid)
			end
			if not mAddSnappedNormal then
				mAddSnappedNormal = vertexNormal(vid)
				mAddSnappedPoint = snapped
			end
		end
		table.insert(mAddPoints, snapped)
		if #mAddPoints >= 3 then
			commitFreshTriangle()
		else
			changeSignal:Fire()
		end
	end

	-- Vertically project a point onto a triangle's plane (keeping its X/Z), so a fresh
	-- apex closed onto an existing edge lands coplanar with that triangle.
	local function projectOntoTriPlane(p: Vector3, tri: createTriangleMesh.Triangle): Vector3
		local v = mMesh.getVertex(tri.vertices[1])
		if not v or math.abs(tri.normal.Y) < 1e-4 then
			return p
		end
		local n, o = tri.normal, v.position
		local y = o.Y - (n.X * (p.X - o.X) + n.Z * (p.Z - o.Z)) / n.Y
		return Vector3.new(p.X, y, p.Z)
	end

	-- Close the single placed fresh apex onto an existing boundary edge, building one
	-- triangle that extends the existing surface (the reverse order of grabbing the
	-- edge first). The apex is dropped onto the edge's plane so the result is coplanar,
	-- and addTriangle matches the neighbour's winding so the thickness lines up.
	local function closeFreshOntoEdge(edgeKey: string)
		local edge = mMesh.getEdges()[edgeKey]
		if not edge then
			return
		end
		local a = mMesh.getVertex(edge.v1)
		local b = mMesh.getVertex(edge.v2)
		if not a or not b then
			return
		end
		local apex = mAddPoints[#mAddPoints]
		local edgeMid = (a.position + b.position) / 2
		local hint = edgeMid + Vector3.yAxis
		local props = getTriangleProps()
		local snappedParent: Instance? = nil
		local parentTri = if edge.triangles[1] then mMesh.getTriangle(edge.triangles[1]) else nil
		if parentTri then
			local part = parentTri.parts[1]
			if part then
				props = { Color = part.Color, Material = part.Material, MaterialVariant = part.MaterialVariant }
				snappedParent = part.Parent
			end
		end
		-- Place the apex in the edge triangle's plane (Extend) so the surface stays
		-- smooth, or on a horizontal plane through the edge (Flat) so it stays level.
		if currentSettings.AddNonSnapped == "Extend" and parentTri then
			apex = projectOntoTriPlane(apex, parentTri)
			hint = edgeMid + parentTri.normal * 0.5
		else
			apex = Vector3.new(apex.X, edgeMid.Y, apex.Z)
		end
		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Add Triangle")
		local thickness = resolveAddThickness(if parentTri then parentTri.thickness else nil)
		mMesh.addTriangle(apex, a.position, b.position, thickness, resolveNewParent(snappedParent), props, hint)
		clearAddState()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	local function handleAddClick(worldPos: Vector3, hitPart: BasePart?, hitNormal: Vector3?)
		-- Discover the clicked part with the camera viewpoint BEFORE the region scan
		-- below. That scan (discoverRegion) has no viewpoint and is seeded at the click
		-- point, which on a thin box often lies on the back side -- discovering it
		-- there first would lock the wrong (back) face. Pinning the hit part to its
		-- camera-facing face first makes the scan a no-op for it.
		if hitPart then
			discoverPartViewed(hitPart, worldPos)
		end
		discoverRegionViewed({worldPos}, 15)
		if not mAddBoundaryEdge then
			-- A single fresh apex placed and now clicking an existing boundary edge:
			-- close the triangle onto that edge to extend the surface (the reverse of
			-- grabbing the edge first, which is just as common a way to build).
			if #mAddPoints == 1 and hitPart then
				local closeKey = boundaryEdgeAt(worldPos, hitPart, hitNormal)
				if closeKey then
					closeFreshOntoEdge(closeKey)
					return
				end
			end
			-- Otherwise place a fresh point when over empty space, or once the fresh-
			-- point path has started; else grab a boundary edge to build from.
			if not hitPart or #mAddPoints > 0 then
				placeFreshPoint(worldPos)
				return
			end
			local edgeKey = boundaryEdgeAt(worldPos, hitPart, hitNormal)
			if edgeKey then
				local edge = mMesh.getEdges()[edgeKey]
				if edge then
					mAddBoundaryEdge = { v1 = edge.v1, v2 = edge.v2 }
					-- Store plane and properties from the parent triangle
					local parentTriId = edge.triangles[1]
					-- New triangles built from this edge join its folder.
					mAddBoundaryFolder = parentForTriangle(parentTriId)
					if parentTriId then
						local tri = mMesh.getTriangle(parentTriId)
						if tri then
							local tv = mMesh.getVertex(tri.vertices[1])
							if tv then
								mAddPlanePoint = tv.position
							end
							mAddPlaneNormal = tri.normal
							mAddSnappedThickness = tri.thickness
							local part = tri.parts[1]
							if part then
								mAddTriangleProps = {
									Color = part.Color,
									Material = part.Material,
									MaterialVariant = part.MaterialVariant,
								}
							end
						end
					end
					changeSignal:Fire()
				else
					placeFreshPoint(worldPos)
				end
			else
				placeFreshPoint(worldPos)
			end
		else
			-- Phase 2: place triangle(s) based on hover target
			local target = mAddHoverTarget
			if not target then
				-- No hover target (empty-space click, or programmatic use): place the
				-- apex on the projected plane at worldPos.
				target = { type = "plane", position = worldPos }
			end

			pushUndoSnapshot()
			local recording = ChangeHistoryService:TryBeginRecording("PolyMap Add Triangle")

			local addProps = mAddTriangleProps or getTriangleProps()
			local parent = resolveNewParent(mAddBoundaryFolder)
			local v1 = mMesh.getVertex(mAddBoundaryEdge.v1)
			local v2 = mMesh.getVertex(mAddBoundaryEdge.v2)
			if v1 and v2 then
				-- Derive hintPoint from the parent triangle's normal so new
				-- triangles face the same direction. Using worldPos is unreliable:
				-- it's coplanar with the surface (ambiguous) or Vector3.zero when
				-- the raycast misses (wrong side entirely).
				local edgeMid = (v1.position + v2.position) / 2
				local addHintPoint = if mAddPlaneNormal
					then edgeMid + mAddPlaneNormal * 0.5
					else worldPos

				if target.type == "vertex" and target.vertexId then
					local tv = mMesh.getVertex(target.vertexId)
					if tv then
						mMesh.addTriangle(
							v1.position, v2.position, tv.position,
							resolveAddThickness(mAddSnappedThickness), parent, addProps, addHintPoint
						)
					end
				elseif target.type == "edge" and target.edgeKey then
					local targetEdge = mMesh.getEdges()[target.edgeKey]
					if targetEdge then
						local tv1 = mMesh.getVertex(targetEdge.v1)
						local tv2 = mMesh.getVertex(targetEdge.v2)
						if tv1 and tv2 then
							-- Pick the pairing that doesn't cross (smaller diagonal sum)
							local ta, tb = tv1, tv2
							local distStraight = (v1.position - ta.position).Magnitude + (v2.position - tb.position).Magnitude
							local distCrossed = (v1.position - tb.position).Magnitude + (v2.position - ta.position).Magnitude
							if distCrossed < distStraight then
								ta, tb = tv2, tv1
							end
							mMesh.addTriangle(
								v1.position, v2.position, ta.position,
								resolveAddThickness(mAddSnappedThickness), parent, addProps, addHintPoint
							)
							mMesh.addTriangle(
								v2.position, tb.position, ta.position,
								resolveAddThickness(mAddSnappedThickness), parent, addProps, addHintPoint
							)
						end
					end
				elseif target.type == "plane" and target.position then
					mMesh.addTriangle(
						v1.position, v2.position, target.position,
						resolveAddThickness(mAddSnappedThickness), parent, addProps, addHintPoint
					)
				end
			end

			clearAddState()

			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
			changeSignal:Fire()
		end
	end

	-- Get world position for stroke operations. Uses raycast when it hits,
	-- falls back to projecting onto the last-hit plane when geometry is gone.
	local function getStrokeWorldPos(): { hit: Vector3, normal: Vector3 }?
		local result = mouseRaycast()
		if result then
			mStrokePlanePoint = result.Position
			mStrokePlaneNormal = result.Normal
			-- Track seed triangle for surface walking
			if result.Instance:IsA("BasePart") then
				discoverPartViewed(result.Instance :: BasePart, result.Position)
				local hitTriId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
				if hitTriId then
					mStrokeSeedTriangleId = hitTriId
				end
			end
			return { hit = result.Position, normal = result.Normal }
		end
		-- Raycast missed — project onto the remembered stroke plane
		if mStrokePlanePoint and mStrokePlaneNormal then
			local camera = workspace.CurrentCamera
			if camera then
				local mouseLocation = UserInputService:GetMouseLocation()
				local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
				local denom = ray.Direction:Dot(mStrokePlaneNormal)
				if math.abs(denom) > 0.0001 then
					local t = (mStrokePlanePoint - ray.Origin):Dot(mStrokePlaneNormal) / denom
					if t > 0 then
						return { hit = ray.Origin + ray.Direction * t, normal = mStrokePlaneNormal }
					end
				end
			end
		end
		return nil
	end

	local function applyDeleteAtCursor(screenPosOverride: Vector2?)
		local screenPos = screenPosOverride or UserInputService:GetMouseLocation()
		-- Drill guard: once we've deleted at a spot, don't keep deleting the parts
		-- revealed behind it while the cursor lingers. Only delete again after the
		-- cursor has moved far enough -- a deliberate drag. (To delete a part that was
		-- behind another, move the cursor off it and back on.)
		if mDeleteLastScreenPos and (screenPos - mDeleteLastScreenPos).Magnitude < kDeleteMinDragPixels then
			return
		end

		local result = mouseRaycast(screenPos)
		local worldPos: Vector3?
		if result then
			mStrokePlanePoint = result.Position
			mStrokePlaneNormal = result.Normal
			worldPos = result.Position
		else
			local hit = getStrokeWorldPos()
			worldPos = if hit then hit.hit else nil
		end
		if not worldPos then return end

		-- Depth-discontinuity guard: skip a hit sitting well behind the surface we've
		-- been deleting, along that surface's normal -- e.g. the far wall of a cave
		-- revealed once the near wall is gone. Following one surface only steps a
		-- little off its plane each frame; punching to the layer behind is a big jump.
		-- (Measuring along the surface normal, not camera depth, keeps grazing-angle
		-- drags -- which barely change the offset -- from being blocked.)
		if result and mDeleteLastHitPoint and mDeleteLastHitNormal then
			local camera = workspace.CurrentCamera
			local camPos = if camera then camera.CFrame.Position else mDeleteLastHitPoint
			local tolerance =
				math.max(kDeleteDepthFloor, (mDeleteLastHitPoint - camPos).Magnitude * kDeleteDepthFraction)
			local behind = -(result.Position - mDeleteLastHitPoint):Dot(mDeleteLastHitNormal)
			if behind > tolerance then
				return
			end
		end

		-- Anchor a successful deletion for the guards above.
		local function recordDelete()
			mDeleteLastScreenPos = screenPos
			if result then
				mDeleteLastHitPoint = result.Position
				mDeleteLastHitNormal = result.Normal
			end
		end

		-- Track seed triangle for surface walking
		if result and result.Instance:IsA("BasePart") then
			discoverPartViewed(result.Instance :: BasePart, result.Position)
			local hitTriId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
			if hitTriId then
				mStrokeSeedTriangleId = hitTriId
			end
		end

		if currentSettings.DeleteTarget == "Vertex" then
			-- Only delete a vertex if the cursor directly hits one of its triangles,
			-- preventing the delete from "spreading out" during a drag stroke.
			local hitTriangleId = if result and result.Instance:IsA("BasePart")
				then mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
				else nil
			if hitTriangleId then
				discoverRegionViewed({worldPos}, 15)
				local vid = findNearestVertex(worldPos, hitTriangleId)
				if vid then
					local vertex = mMesh.getVertex(vid)
					if vertex then
						local triIds = table.clone(vertex.triangles)
						for _, triId in triIds do
							mMesh.removeTriangle(triId)
						end
						mSelectedVertices[vid] = nil
						recordDelete()
						changeSignal:Fire()
					end
				end
			end
		else
			-- Face mode
			local radius = currentSettings.DeleteRadius
			local toRemove: { number }
			if radius > 0 and mStrokeSeedTriangleId then
				toRemove = discoverAndWalkSurface(mStrokeSeedTriangleId, worldPos, radius)
			else
				-- Zero radius: use exact part mapping (no plane fallback)
				if result and result.Instance:IsA("BasePart") then
					local triId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
					toRemove = if triId then { triId } else {}
				else
					toRemove = {}
				end
			end
			for _, removeId in toRemove do
				mMesh.removeTriangle(removeId)
			end
			if #toRemove > 0 then
				recordDelete()
				changeSignal:Fire()
			end
		end
	end

	local function applyPaintAtCursor(screenPosOverride: Vector2?)
		local result = mouseRaycast(screenPosOverride)
		if result and result.Instance:IsA("BasePart") then
			-- Track seed triangle for surface walking
			discoverPartViewed(result.Instance :: BasePart, result.Position)
			local hitTriId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
			if hitTriId then
				mStrokeSeedTriangleId = hitTriId
			end

			local c = currentSettings.PaintColor
			local color = Color3.new(c[1], c[2], c[3])
			local mat = (Enum.Material :: any)[currentSettings.PaintMaterial]

			-- Collect all parts to paint: the whole hit triangle (1-2 wedges), not just
			-- the single wedge the cursor's ray happened to land on.
			local partsToPaint: { BasePart } = {}
			local hitTri = if hitTriId then mMesh.getTriangle(hitTriId) else nil
			if hitTri then
				for _, part in hitTri.parts do
					table.insert(partsToPaint, part)
				end
			else
				table.insert(partsToPaint, result.Instance :: BasePart)
			end
			local radius = currentSettings.PaintRadius
			if radius > 0 and mStrokeSeedTriangleId then
				for _, nearTriId in discoverAndWalkSurface(mStrokeSeedTriangleId, result.Position, radius) do
					local tri = mMesh.getTriangle(nearTriId)
					if tri then
						for _, part in tri.parts do
							table.insert(partsToPaint, part)
						end
					end
				end
			end

			local paintStrength = currentSettings.PaintStrength
			local paintTarget = currentSettings.PaintTarget
			local doColor = paintTarget ~= "Material"
			local doMaterial = paintTarget ~= "Color"
			for _, part in partsToPaint do
				if doColor then
					if paintStrength >= 1.0 then
						part.Color = color
					else
						-- Save original color on first touch so strength applies correctly
						if not mPaintOriginalColors[part] then
							mPaintOriginalColors[part] = part.Color
						end
						part.Color = mPaintOriginalColors[part]:Lerp(color, paintStrength)
					end
				end
				if doMaterial and mat then
					part.Material = mat
					part.MaterialVariant = currentSettings.PaintMaterialVariant
				end
			end
			changeSignal:Fire()
		end
	end

	local function applyRelaxAtCursor()
		local worldPos = getStrokeWorldPos()
		if not worldPos then return end

		local radius = currentSettings.RelaxRadius
		local strength = currentSettings.RelaxStrength
		if radius <= 0 or strength <= 0 then return end

		-- Use surface walk if we have a seed, otherwise discover region
		local walkVertexIds: { number }?
		if mStrokeSeedTriangleId then
			local _
			_, walkVertexIds = discoverAndWalkSurface(mStrokeSeedTriangleId, worldPos.hit, radius)
		else
			discoverRegionViewed({worldPos.hit}, radius + 5)
		end

		-- Save vertex positions on first encounter during this stroke
		if walkVertexIds then
			for _, vid in walkVertexIds do
				if not mBrushSavedPositions[vid] then
					local vertex = mMesh.getVertex(vid)
					if vertex then
						mBrushSavedPositions[vid] = vertex.position
					end
				end
			end
		else
			for vid, vertex in mMesh.getVertices() do
				if not mBrushSavedPositions[vid] then
					mBrushSavedPositions[vid] = vertex.position
				end
			end
		end

		-- Find all vertices within radius using saved positions
		local verticesInRadius: { { id: number, savedPos: Vector3, dist: number } } = {}
		local vidsToCheck = walkVertexIds or ({} :: { number})
		if walkVertexIds then
			for _, vid in vidsToCheck do
				local savedPos = mBrushSavedPositions[vid]
				if not savedPos then continue end
				local dist = (savedPos - worldPos.hit).Magnitude
				if dist <= radius then
					table.insert(verticesInRadius, { id = vid, savedPos = savedPos, dist = dist })
				end
			end
		else
			for vid in mMesh.getVertices() do
				local savedPos = mBrushSavedPositions[vid]
				if not savedPos then continue end
				local dist = (savedPos - worldPos.hit).Magnitude
				if dist <= radius then
					table.insert(verticesInRadius, { id = vid, savedPos = savedPos, dist = dist })
				end
			end
		end
		if #verticesInRadius == 0 then return end

		-- Build set of boundary vertices (on edges with only 1 triangle) to pin them
		local boundaryVids: { [number]: boolean } = {}
		for _, edge in mMesh.getEdges() do
			if #edge.triangles == 1 then
				boundaryVids[edge.v1] = true
				boundaryVids[edge.v2] = true
			end
		end

		-- Laplacian XZ smoothing: move each vertex toward the average XZ of its neighbors
		local moves: { [number]: Vector3 } = {}
		for _, entry in verticesInRadius do
			if boundaryVids[entry.id] then continue end
			local neighbors = mMesh.getVertexNeighbors(entry.id)
			if #neighbors == 0 then continue end

			-- Average XZ of saved neighbor positions
			local avgX, avgZ = 0, 0
			local nCount = 0
			for _, nid in neighbors do
				local npos = mBrushSavedPositions[nid]
				if not npos then
					local nv = mMesh.getVertex(nid)
					if nv then
						npos = nv.position
					end
				end
				if npos then
					avgX += npos.X
					avgZ += npos.Z
					nCount += 1
				end
			end
			if nCount == 0 then continue end
			avgX /= nCount
			avgZ /= nCount

			local t = entry.dist / radius
			local falloff = (1 + math.cos(t * math.pi)) / 2
			local amount = mBrushAmounts[entry.id] or 0
			amount = math.min(amount + strength * falloff, 1)
			mBrushAmounts[entry.id] = amount

			local newX = entry.savedPos.X + (avgX - entry.savedPos.X) * amount
			local newZ = entry.savedPos.Z + (avgZ - entry.savedPos.Z) * amount
			moves[entry.id] = Vector3.new(newX, entry.savedPos.Y, newZ)
		end

		mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())
		changeSignal:Fire()
	end

	local function applyFlattenAtCursor()
		local worldPos = getStrokeWorldPos()
		if not worldPos then return end

		local radius = currentSettings.FlattenRadius
		local strength = currentSettings.FlattenStrength
		if radius <= 0 or strength <= 0 then return end

		-- Use surface walk if we have a seed, otherwise discover region
		local walkVertexIds: { number }?
		if mStrokeSeedTriangleId then
			local _
			_, walkVertexIds = discoverAndWalkSurface(mStrokeSeedTriangleId, worldPos.hit, radius)
		else
			discoverRegionViewed({worldPos.hit}, radius + 5)
		end

		-- Find all vertices within radius using current positions
		local verticesInRadius: { { id: number, pos: Vector3, dist: number } } = {}
		if walkVertexIds then
			for _, vid in walkVertexIds do
				local vertex = mMesh.getVertex(vid)
				if vertex then
					local dist = (vertex.position - worldPos.hit).Magnitude
					if dist <= radius then
						table.insert(verticesInRadius, { id = vid, pos = vertex.position, dist = dist })
					end
				end
			end
		else
			for vid, vertex in mMesh.getVertices() do
				local dist = (vertex.position - worldPos.hit).Magnitude
				if dist <= radius then
					table.insert(verticesInRadius, { id = vid, pos = vertex.position, dist = dist })
				end
			end
		end
		if #verticesInRadius == 0 then return end

		-- Incremental Y-only Laplacian: move each vertex's Y toward
		-- the average Y of its neighbors, leaving XZ untouched.
		local moves: { [number]: Vector3 } = {}
		for _, entry in verticesInRadius do
			local neighbors = mMesh.getVertexNeighbors(entry.id)
			if #neighbors == 0 then continue end

			local avgY = 0
			local nCount = 0
			for _, nid in neighbors do
				local nv = mMesh.getVertex(nid)
				if nv then
					avgY += nv.position.Y
					nCount += 1
				end
			end
			if nCount == 0 then continue end
			avgY /= nCount

			local t = entry.dist / radius
			local falloff = (1 + math.cos(t * math.pi)) / 2
			local deltaY = (avgY - entry.pos.Y) * strength * falloff

			moves[entry.id] = Vector3.new(entry.pos.X, entry.pos.Y + deltaY, entry.pos.Z)
		end

		mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())
		changeSignal:Fire()
	end

	local function startStroke()
		local mode = currentSettings.Mode
		mDeleteLastScreenPos = nil
		mDeleteLastHitPoint = nil
		mDeleteLastHitNormal = nil
		if mode == "Delete" then
			pushUndoSnapshot()
			mStrokeRecording = ChangeHistoryService:TryBeginRecording("PolyMap Delete")
		elseif mode == "Paint" then
			-- Push a snapshot like the other stroke modes do: Paint still commits
			-- a "PolyMap Paint" waypoint, and handleUndo pops the selection stack
			-- for every PolyMap waypoint, so skipping the push here desyncs the
			-- undo/redo selection stacks for all later operations.
			pushUndoSnapshot()
			mStrokeRecording = ChangeHistoryService:TryBeginRecording("PolyMap Paint")
		elseif mode == "Relax" then
			pushUndoSnapshot()
			mBrushSavedPositions = {}
			mBrushAmounts = {}
			mStrokeRecording = ChangeHistoryService:TryBeginRecording("PolyMap Relax")
		elseif mode == "Flatten" then
			pushUndoSnapshot()
			mStrokeRecording = ChangeHistoryService:TryBeginRecording("PolyMap Flatten")
		end
		mStrokeDragging = true
	end

	local function applyStrokeAtCursor()
		local mode = currentSettings.Mode
		if mode == "Delete" then
			applyDeleteAtCursor()
		elseif mode == "Paint" then
			applyPaintAtCursor()
		elseif mode == "Relax" then
			applyRelaxAtCursor()
		elseif mode == "Flatten" then
			applyFlattenAtCursor()
		end
	end

	local function endStroke(cancel: boolean?)
		if mStrokeRecording then
			local op = if cancel
				then Enum.FinishRecordingOperation.Cancel
				else Enum.FinishRecordingOperation.Commit
			-- pcall: when an undo cancels a stroke mid-stride the recording may already
			-- have been closed by the undo itself, so finishing it again would throw.
			pcall(function()
				ChangeHistoryService:FinishRecording(mStrokeRecording, op)
			end)
			mStrokeRecording = nil
		end
		mStrokeDragging = false
		mStrokePlanePoint = nil
		mStrokePlaneNormal = nil
		mStrokeSeedTriangleId = nil
		mDeleteLastScreenPos = nil
		mDeleteLastHitPoint = nil
		mDeleteLastHitNormal = nil
		mPaintOriginalColors = {}
		mBrushSavedPositions = {}
		mBrushAmounts = {}
	end

	local function handleClick()
		if mIsOverUI or mIsDraggingHandle then
			return
		end

		-- Placing a grid intercepts clicks to drop its two corners.
		if mGridPlacing then
			handleGridPlaceClick()
			return
		end

		-- Use loose targeting (spherecast fallback) for selection/add modes
		local mode = currentSettings.Mode
		local useLoose = mode == "Move" or mode == "Rotate" or mode == "Add"
		local result = if useLoose then mouseRaycastLoose() else mouseRaycast()
		if not result then
			if (mode == "Move" or mode == "Rotate") and not isShiftHeld() then
				mSelectedVertices = {}
				mSavedVertexPositions = {}
				changeSignal:Fire()
			end
			if mode == "Add" then
				-- A miss is empty space: place an Add point there (apex or fresh point)
				-- by projecting onto the working plane, instead of cancelling.
				local p = addProjectedPos()
				if p then
					handleAddClick(p, nil, nil)
				end
			end
			return
		end

		local hitPart = if result.Instance:IsA("BasePart") then result.Instance :: BasePart else nil

		-- Eyedropper intercept: sample color or material from clicked part
		if mode == "Paint" and currentSettings.PaintEyedropper ~= "None" and hitPart then
			if currentSettings.PaintEyedropper == "Color" then
				local col = hitPart.Color
				local picked = { col.R, col.G, col.B }
				currentSettings.PaintColor = picked
				-- Add to recents if not already present
				local found = false
				for _, rc in currentSettings.RecentColors do
					if math.abs(rc[1] - picked[1]) < 0.001
						and math.abs(rc[2] - picked[2]) < 0.001
						and math.abs(rc[3] - picked[3]) < 0.001 then
						found = true
						break
					end
				end
				if not found then
					table.insert(currentSettings.RecentColors, 1, picked)
					while #currentSettings.RecentColors > 8 do
						table.remove(currentSettings.RecentColors)
					end
				end
			elseif currentSettings.PaintEyedropper == "Material" then
				local matName = hitPart.Material.Name
				local variant = hitPart.MaterialVariant
				currentSettings.PaintMaterial = matName
				currentSettings.PaintMaterialVariant = variant
				-- Add to recents (keyed by material + variant) if not already present.
				local recentKey = Settings.EncodeRecentMaterial(matName, variant)
				if not table.find(currentSettings.RecentMaterials, recentKey) then
					table.insert(currentSettings.RecentMaterials, 1, recentKey)
					while #currentSettings.RecentMaterials > 6 do
						table.remove(currentSettings.RecentMaterials)
					end
				end
			end
			currentSettings.PaintEyedropper = "None"
			changeSignal:Fire()
			return
		end

		if mode == "Move" or mode == "Rotate" then
			handleSelectClick(result.Position, hitPart)
		elseif mode == "Add" then
			handleAddClick(result.Position, hitPart, result.Normal)
		elseif mode == "Delete" or mode == "Paint" or mode == "Relax" or mode == "Flatten" then
			startStroke()
			applyStrokeAtCursor()
		end
	end

	-- Marquee selection
	local function handleMarqueeSelect()
		if not mMarqueeStart or not mMarqueeEnd then
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		-- Discover geometry under the marquee region
		local centerX = (mMarqueeStart.X + mMarqueeEnd.X) / 2
		local centerY = (mMarqueeStart.Y + mMarqueeEnd.Y) / 2
		local centerRay = camera:ViewportPointToRay(centerX, centerY)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {}
		local centerHit = workspace:Raycast(centerRay.Origin, centerRay.Direction * 10000, params)
		if centerHit then
			-- Estimate world-space extent from a corner of the marquee
			local cornerRay = camera:ViewportPointToRay(mMarqueeEnd.X, mMarqueeEnd.Y)
			local depth = (centerHit.Position - camera.CFrame.Position).Magnitude
			local cornerWorld = cornerRay.Origin + cornerRay.Direction * depth
			local halfDiag = (cornerWorld - centerHit.Position).Magnitude
			discoverRegionViewed({centerHit.Position}, halfDiag + 10)
		end

		local minX = math.min(mMarqueeStart.X, mMarqueeEnd.X)
		local maxX = math.max(mMarqueeStart.X, mMarqueeEnd.X)
		local minY = math.min(mMarqueeStart.Y, mMarqueeEnd.Y)
		local maxY = math.max(mMarqueeStart.Y, mMarqueeEnd.Y)

		-- Start from the pre-marquee selection (handles shift correctly)
		mSelectedVertices = table.clone(mPreMarqueeSelection)

		for id, vertex in mMesh.getVertices() do
			local screenPos, onScreen = camera:WorldToScreenPoint(vertex.position)
			if onScreen and screenPos.X >= minX and screenPos.X <= maxX and
				screenPos.Y >= minY and screenPos.Y <= maxY then
				mSelectedVertices[id] = true
			end
		end

		mSavedVertexPositions = {}
		changeSignal:Fire()
	end

	----------------------------------------------------------------------
	-- DraggerFramework integration
	----------------------------------------------------------------------

	local fixedSelection = createFixedSelection()

	local draggerContext = DraggerContext_PluginImpl.new(
		plugin,
		game,
		settings(),
		fixedSelection
	)
	draggerContext.SetDraggingFunction = function(_isDragging: boolean)
	end
	draggerContext.DragUpdatedSignal = Signal.new()

	local function computeFalloff(t: number): number
		local falloff = currentSettings.InfluenceFalloff
		if falloff == "Linear" then
			return 1 - t
		elseif falloff == "Smooth" then
			return (1 + math.cos(t * math.pi)) / 2
		elseif falloff == "Sharp" then
			return (1 - t) ^ 2
		end
		return 1 - t
	end

	local function saveVertexPositions()
		mSavedVertexPositions = {}
		mInfluencedVertices = {}

		for vid in mSelectedVertices do
			local v = mMesh.getVertex(vid)
			if v then
				mSavedVertexPositions[vid] = v.position
			end
		end

		-- Compute influenced (unselected) vertices within InfluenceRadius
		local radius = currentSettings.InfluenceRadius
		if radius <= 0 then
			return
		end

		-- Discover geometry out to the influence radius. This runs at drag
		-- start (before movement), so seeds are at correct surface positions.
		local seedPositions: { Vector3 } = {}
		for _, origPos in mSavedVertexPositions do
			table.insert(seedPositions, origPos)
		end
		if #seedPositions > 0 then
			discoverRegionViewed(seedPositions, radius)
		end

		-- Walk already-discovered topology outward from selected vertices,
		-- filtering by XZ distance.

		local visited: { [number]: boolean } = {}
		local queue: { number } = {}
		local queueHead = 1
		for vid in mSelectedVertices do
			visited[vid] = true
			table.insert(queue, vid)
		end

		while queueHead <= #queue do
			local vid = queue[queueHead]
			queueHead += 1

			local v = mMesh.getVertex(vid)
			if not v then continue end

			for _, triId in v.triangles do
				local tri = mMesh.getTriangle(triId)
				if not tri then continue end
				for _, neighborVid in tri.vertices do
					if visited[neighborVid] then continue end
					visited[neighborVid] = true

					local neighbor = mMesh.getVertex(neighborVid)
					if not neighbor then continue end

					local withinRadius = false
					for _, seedPos in seedPositions do
						local delta = neighbor.position - seedPos
						if Vector3.new(delta.X, 0, delta.Z).Magnitude < radius then
							withinRadius = true
							break
						end
					end
					if withinRadius then
						table.insert(queue, neighborVid)
					end
				end
			end
		end

		-- Compute falloff for non-selected vertices within radius
		for vid in visited do
			if mSelectedVertices[vid] then continue end
			local neighbor = mMesh.getVertex(vid)
			if not neighbor then continue end
			local minDist = math.huge
			for _, origPos in mSavedVertexPositions do
				local delta = neighbor.position - origPos
				local dist = Vector3.new(delta.X, 0, delta.Z).Magnitude
				if dist < minDist then
					minDist = dist
				end
			end
			if minDist < radius then
				local t = minDist / radius
				local factor = computeFalloff(t)
				if factor > 0.001 then
					mInfluencedVertices[vid] = {
						position = neighbor.position,
						factor = factor,
					}
				end
			end
		end
	end

	local schema = createCFrameDraggerSchema(
		function(): boolean
			return getSelectedVertexCount() == 0
		end,
		function(): (CFrame, Vector3, Vector3)
			local centroid = getSelectionCentroid()
			if centroid then
				return CFrame.new(centroid), Vector3.zero, Vector3.zero
			end
			return CFrame.identity, Vector3.zero, Vector3.zero
		end
	)

	-- Move handle callbacks
	local function startMove()
		mIsDraggingHandle = true
		mMarqueeStart = nil
		mMarqueeEnd = nil
		pushUndoSnapshot()
		saveVertexPositions()
		mDragRecording = ChangeHistoryService:TryBeginRecording("PolyMap Move")
	end

	local function applyMove(globalTransform: CFrame)
		local delta = globalTransform.Position
		local moves: { [number]: Vector3 } = {}
		for vid, origPos in mSavedVertexPositions do
			moves[vid] = origPos + delta
		end
		for vid, info in mInfluencedVertices do
			moves[vid] = info.position + delta * info.factor
		end
		mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())
		changeSignal:Fire()
	end

	local function endMove()
		if mDragRecording then
			ChangeHistoryService:FinishRecording(mDragRecording, Enum.FinishRecordingOperation.Commit)
			mDragRecording = nil
		end
		mIsDraggingHandle = false
		changeSignal:Fire()
	end

	-- Rotate handle callbacks
	local function startRotate()
		mIsDraggingHandle = true
		mMarqueeStart = nil
		mMarqueeEnd = nil
		pushUndoSnapshot()
		saveVertexPositions()
		mDragCentroid = getSelectionCentroid()
		mDragRecording = ChangeHistoryService:TryBeginRecording("PolyMap Rotate")
	end

	local function applyRotate(localRotation: CFrame)
		if not mDragCentroid then return end
		local moves: { [number]: Vector3 } = {}
		for vid, origPos in mSavedVertexPositions do
			local offset = origPos - mDragCentroid
			local rotatedOffset = localRotation:VectorToWorldSpace(offset)
			moves[vid] = mDragCentroid + rotatedOffset
		end
		for vid, info in mInfluencedVertices do
			local offset = info.position - mDragCentroid
			local rotatedOffset = localRotation:VectorToWorldSpace(offset)
			local fullNewPos = mDragCentroid + rotatedOffset
			moves[vid] = info.position:Lerp(fullNewPos, info.factor)
		end
		mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())
		changeSignal:Fire()
	end

	local function endRotate()
		if mDragRecording then
			ChangeHistoryService:FinishRecording(mDragRecording, Enum.FinishRecordingOperation.Commit)
			mDragRecording = nil
		end
		mIsDraggingHandle = false
		mDragCentroid = nil
		changeSignal:Fire()
	end

	local moveHandles = MoveHandles.new(draggerContext, {
		GetBoundingBox = function()
			local centroid = getSelectionCentroid()
			if centroid then
				return CFrame.new(centroid), Vector3.zero, Vector3.zero
			end
			return CFrame.identity, Vector3.zero, Vector3.zero
		end,
		StartTransform = startMove,
		ApplyTransform = applyMove,
		EndTransform = endMove,
		Visible = function()
			return currentSettings.Mode == "Move" and getSelectedVertexCount() > 0 and not mMarqueeEnd
		end,
	})

	local rotateHandles = RotateHandles.new(draggerContext, {
		GetBoundingBox = function()
			local centroid = getSelectionCentroid()
			if centroid then
				return CFrame.new(centroid), Vector3.zero, Vector3.zero
			end
			return CFrame.identity, Vector3.zero, Vector3.zero
		end,
		StartTransform = startRotate,
		ApplyTransform = applyRotate,
		EndTransform = endRotate,
		Visible = function()
			return currentSettings.Mode == "Rotate" and getSelectedVertexCount() > 0 and not mMarqueeEnd
		end,
	})

	-- Now that the handles exist, wire up the over-handle query used by updateHover.
	-- Replicates the dragger's HoverTracker check (handles:hitTest with the same
	-- args), so the surface hover outline hides exactly when the dragger is hovering
	-- a handle instead of the surface. The handles are alwaysOnTop and don't bias
	-- towards parts, so a non-nil hitTest is an unambiguous "over a handle".
	queryMouseOverHandle = function(): boolean
		local mode = currentSettings.Mode
		if mode == "Move" then
			return (moveHandles:hitTest(draggerContext:getMouseRay(), false)) ~= nil
		elseif mode == "Rotate" then
			return (rotateHandles:hitTest(draggerContext:getMouseRay(), false)) ~= nil
		end
		return false
	end

	local rootElement = Roact.createElement(DraggerToolComponent, {
		Mouse = plugin:GetMouse(),
		DraggerContext = draggerContext,
		DraggerSchema = schema,
		DraggerSettings = {
			AllowDragSelect = false,
			AnalyticsName = "PolyMap",
			HandlesList = {
				rotateHandles,
				moveHandles,
			},
		},
	})

	local draggerHandle = Roact.mount(rootElement)

	-- Trigger dragger updates when session state changes (but not during
	-- drags, where the dragger framework already manages its own updates
	-- and re-entrancy would cause an infinite loop)
	changeSignal:Connect(function()
		if not mIsDraggingHandle then
			task.defer(function()
				fixedSelection.SelectionChanged:Fire()
			end)
		end
	end)

	----------------------------------------------------------------------
	-- Input connections
	----------------------------------------------------------------------

	local inputChangedCn = UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			mIsOverUI = gameProcessed
		end
	end)

	-- Escape cancels the current in-progress interaction: an unfinished Add (edge grab
	-- or placed points), an interactive grid placement, or an active Paint eyedropper.
	local function handleEscape()
		if currentSettings.Mode == "Add" and (mAddBoundaryEdge or #mAddPoints > 0) then
			clearAddState()
			changeSignal:Fire()
		end
		if mGridPlacing then
			clearGridPlacement()
			changeSignal:Fire()
		end
		-- Cancel an active Paint eyedropper (Pick Colour / Pick Material), returning to
		-- normal painting without sampling anything.
		if currentSettings.Mode == "Paint" and currentSettings.PaintEyedropper ~= "None" then
			currentSettings.PaintEyedropper = "None"
			changeSignal:Fire()
		end
	end

	local inputBeganCn: RBXScriptConnection? = nil
	local inputEndedCn: RBXScriptConnection? = nil
	local delayedBeginCn = task.delay(0, function()
		inputBeganCn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessed then
				local mode = currentSettings.Mode
				if mode == "Move" or mode == "Rotate" then
					local mousePos = UserInputService:GetMouseLocation()
					mMarqueeStart = mousePos
					mMarqueeEnd = nil
					mPreMarqueeSelection = if isShiftHeld() then table.clone(mSelectedVertices) else {}
				end
				handleClick()
			end
			-- Escape cancels the current in-progress interaction (Add, grid place, Pick).
			if input.KeyCode == Enum.KeyCode.Escape and not gameProcessed then
				handleEscape()
			end
		end)

		inputEndedCn = UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				mMarqueeStart = nil
				mMarqueeEnd = nil
				if mStrokeDragging then
					endStroke()
				end
			end
		end)
	end)

	local cursorTargetTask = task.spawn(function()
		while true do
			updateHover()

			if mStrokeDragging then
				applyStrokeAtCursor()
			elseif mMarqueeStart and not mIsDraggingHandle then
				local mousePos = UserInputService:GetMouseLocation()
				local dist = (mousePos - mMarqueeStart).Magnitude
				if dist > 5 then
					mMarqueeEnd = mousePos
					-- Live marquee selection
					handleMarqueeSelect()
				end
			end

			task.wait()
		end
	end)

	local function rediscoverMesh(extraSeeds: { Vector3 }?)
		-- Collect all known vertex positions before clearing, then clear and
		-- rediscover from scratch. After an undo/redo the parts have been
		-- reverted (moved, or deleted-then-restored, etc.), so we must rebuild
		-- the *whole* connected mesh. A fixed radius would leave restored
		-- geometry further out -- e.g. undoing a large Delete -- as untracked
		-- stale state. discoverRegion walks vertex-to-vertex through
		-- the actual parts, so an unbounded radius still stays bounded to the
		-- real connected geometry rather than scanning the whole world.
		local seeds: { Vector3 } = {}
		-- Seed from the restored snapshot FIRST. Those positions match the reverted
		-- world exactly, so the (FIFO) walk discovers the connected mesh correctly
		-- from them before any stale post-op live position is processed. After an
		-- undo the in-memory mesh still holds POST-op positions (e.g. a moved-down
		-- region) while the parts have reverted, so a stale seed now floats off the
		-- parts; processing it first could bootstrap a part from the wrong side (a
		-- back face). Ordering the good seeds ahead means by the time a stale seed
		-- is reached, its region is already discovered and it is a no-op.
		if extraSeeds then
			for _, p in extraSeeds do
				table.insert(seeds, p)
			end
		end
		-- Then the in-memory positions, for full coverage (e.g. an op with no
		-- selection snapshot, or geometry the snapshot's component doesn't reach).
		for _, vertex in mMesh.getVertices() do
			table.insert(seeds, vertex.position)
		end
		-- When there is still nothing to seed from -- e.g. redoing a creation after
		-- it was fully undone -- fall back to the most recent known positions.
		if #seeds > 0 then
			mLastRediscoverSeeds = seeds
		else
			seeds = mLastRediscoverSeeds
		end
		mMesh.clear()
		if #seeds > 0 then
			mMesh.discoverRegion(seeds, math.huge)
		end
	end

	-- Abandon any transient in-progress action when an undo/redo interrupts it, so its
	-- stale state and open recording can't corrupt the reverted mesh (e.g. continuing a
	-- handle drag whose saved positions no longer match the world, or an endMove that
	-- commits a recording the undo already invalidated). A half-done drag, brush stroke,
	-- marquee, grid placement, or Add triangle is simply discarded; the user restarts it.
	local function cancelTransientActions()
		-- Move/Rotate handle drag: drop its open recording and drag state.
		if mDragRecording then
			pcall(function()
				ChangeHistoryService:FinishRecording(mDragRecording, Enum.FinishRecordingOperation.Cancel)
			end)
			mDragRecording = nil
		end
		mIsDraggingHandle = false
		mDragCentroid = nil
		mInfluencedVertices = {}
		-- Brush stroke (Delete/Paint/Relax/Flatten).
		if mStrokeDragging or mStrokeRecording then
			endStroke(true)
		end
		-- Marquee, grid placement, half-placed Add triangle, saved drag positions.
		mMarqueeStart = nil
		mMarqueeEnd = nil
		if mGridPlacing then
			clearGridPlacement()
		end
		clearAddState()
		mSavedVertexPositions = {}
	end

	local function handleUndo(waypointName: string)
		if not string.find(waypointName, "PolyMap") then
			return
		end
		-- An undo mid-action interrupts it; discard the transient state first.
		cancelTransientActions()
		-- Save current selection positions for redo
		table.insert(mRedoSelections, captureSelectionPositions())
		-- The undo snapshot holds the pre-op positions, which match the reverted
		-- world -- seed rediscovery from them so a fully-moved region isn't lost.
		local undoSelection = table.remove(mUndoSelections)
		rediscoverMesh(undoSelection)
		-- Restore selection from saved positions
		if undoSelection then
			restoreSelectionFromPositions(undoSelection)
		else
			mSelectedVertices = {}
		end
		mHoverVertexId = nil
		mHoverEdgeKey = nil
		Selection:Set({})
		changeSignal:Fire()
	end

	local function handleRedo(waypointName: string)
		if not string.find(waypointName, "PolyMap") then
			return
		end
		cancelTransientActions()
		-- Save current selection positions for undo
		table.insert(mUndoSelections, captureSelectionPositions())
		-- The redo snapshot holds the post-op positions, which match the re-applied
		-- world -- seed rediscovery from them for the same reason as undo.
		local redoSelection = table.remove(mRedoSelections)
		rediscoverMesh(redoSelection)
		-- Restore selection from saved positions
		if redoSelection then
			restoreSelectionFromPositions(redoSelection)
		else
			mSelectedVertices = {}
		end
		mHoverVertexId = nil
		mHoverEdgeKey = nil
		Selection:Set({})
		changeSignal:Fire()
	end

	local undoCn = ChangeHistoryService.OnUndo:Connect(handleUndo)
	local redoCn = ChangeHistoryService.OnRedo:Connect(handleRedo)

	local function teardown()
		if mStrokeDragging then
			endStroke()
		end
		Roact.unmount(draggerHandle)
		inputChangedCn:Disconnect()
		undoCn:Disconnect()
		redoCn:Disconnect()
		if inputBeganCn then
			inputBeganCn:Disconnect()
		end
		if inputEndedCn then
			inputEndedCn:Disconnect()
		end
		task.cancel(delayedBeginCn)
		task.cancel(cursorTargetTask)
	end

	----------------------------------------------------------------------
	-- Public API
	----------------------------------------------------------------------

	session.ChangeSignal = changeSignal
	session.Update = function()
		fixedSelection.SelectionChanged:Fire()
		mMesh.setThicknessHint(currentSettings.Thickness)
	end
	session.Destroy = function()
		teardown()
	end

	-- Accessors for UI/overlay
	session.GetMesh = function(): createTriangleMesh.TriangleMesh
		return mMesh
	end
	session.GetSelectedVertices = function(): { [number]: boolean }
		return mSelectedVertices
	end
	session.GetSelectedVertexCount = function(): number
		return getSelectedVertexCount()
	end
	session.GetSelectedVertexIds = function(): { number }
		return getSelectedVertexIds()
	end
	session.GetSelectionCentroid = function(): Vector3?
		return getSelectionCentroid()
	end
	session.GetHoverVertexId = function(): number?
		return mHoverVertexId
	end
	session.GetHoverEdgeKey = function(): string?
		return mHoverEdgeKey
	end
	-- Collect triangles from seed vertices expanded by the influence radius.
	-- During a drag, uses saved positions for XZ distance filtering.
	local function getExpandedTriangleIds(seedVids: { [number]: boolean }): { number }
		if not next(seedVids) then
			return {}
		end

		local radius = currentSettings.InfluenceRadius

		-- Collect seed positions for XZ distance filtering.
		-- During/after a drag, use saved (pre-drag) positions so the
		-- influence area stays stable as vertices move.
		local seedPositions: { Vector3 } = {}
		if next(mSavedVertexPositions) then
			for vid in seedVids do
				local pos = mSavedVertexPositions[vid]
				if pos then
					table.insert(seedPositions, pos)
				end
			end
		end
		if #seedPositions == 0 then
			for vid in seedVids do
				local v = mMesh.getVertex(vid)
				if v then
					table.insert(seedPositions, v.position)
				end
			end
		end

		if radius <= 0 or #seedPositions == 0 then
			-- Just return triangles touching the seed vertices
			local triSet: { [number]: boolean } = {}
			for vid in seedVids do
				local v = mMesh.getVertex(vid)
				if v then
					for _, triId in v.triangles do
						triSet[triId] = true
					end
				end
			end
			local result: { number } = {}
			for triId in triSet do
				table.insert(result, triId)
			end
			return result
		end

		-- Discover the influence region first (discoverRegion is incremental, so it
		-- is cheap once an area is discovered), then walk the topology outward from
		-- the seed vertices, filtering by XZ distance. This is the same
		-- discover-then-walk the move drag and the brush tools use, so the hover /
		-- selection outline is correct even on a freshly opened mesh.
		discoverRegionViewed(seedPositions, radius)

		local affectedVids: { [number]: boolean } = {}
		for vid in seedVids do
			affectedVids[vid] = true
		end

		local visited: { [number]: boolean } = {}
		local queue: { number } = {}
		local queueHead = 1
		for vid in seedVids do
			visited[vid] = true
			table.insert(queue, vid)
		end

		while queueHead <= #queue do
			local vid = queue[queueHead]
			queueHead += 1

			local v = mMesh.getVertex(vid)
			if not v then continue end

			-- Walk through triangles to find neighbor vertices
			for _, triId in v.triangles do
				local tri = mMesh.getTriangle(triId)
				if not tri then continue end
				for _, neighborVid in tri.vertices do
					if visited[neighborVid] then continue end
					visited[neighborVid] = true

					local neighbor = mMesh.getVertex(neighborVid)
					if not neighbor then continue end

					-- Check XZ distance to any seed
					local withinRadius = false
					for _, seedPos in seedPositions do
						local delta = neighbor.position - seedPos
						if Vector3.new(delta.X, 0, delta.Z).Magnitude < radius then
							withinRadius = true
							break
						end
					end
					if withinRadius then
						affectedVids[neighborVid] = true
						table.insert(queue, neighborVid)
					end
				end
			end
		end

		-- Collect triangles from affected vertices
		local triSet: { [number]: boolean } = {}
		for vid in affectedVids do
			local v = mMesh.getVertex(vid)
			if v then
				for _, triId in v.triangles do
					triSet[triId] = true
				end
			end
		end
		local result: { number } = {}
		for triId in triSet do
			table.insert(result, triId)
		end
		return result
	end

	session.GetOutlineTriangleIds = function(): { number }
		local mode = currentSettings.Mode
		if mode == "Delete" or mode == "Paint" or mode == "Relax" or mode == "Flatten" then
			return mHoverTriangleIds
		end
		if mode == "Move" or mode == "Rotate" then
			return getExpandedTriangleIds(mSelectedVertices)
		end
		return {}
	end
	session.GetHoverOutlineTriangleIds = function(): { number }
		local mode = currentSettings.Mode
		if mode ~= "Move" and mode ~= "Rotate" then
			return {}
		end
		if not mHoverVertexId then
			return {}
		end
		return getExpandedTriangleIds({ [mHoverVertexId] = true })
	end
	session.GetMode = function(): string
		return currentSettings.Mode
	end
	-- Fresh corner positions placed so far in the empty-space Add path (overlay
	-- preview and tests). These are where the cursor placed them; the lift a
	-- disconnected triangle gets is applied at commit, not shown in the preview.
	session.GetAddPoints = function(): { Vector3 }
		return table.clone(mAddPoints)
	end
	-- Drive one Add click at a world position, as if the cursor were there. Pass
	-- hitPart when the click is on existing geometry (to grab its boundary edge),
	-- or nil for an empty-space click. Lets tests exercise the click flow without
	-- the mouse.
	session.AddClickAt = function(worldPos: Vector3, hitPart: BasePart?)
		handleAddClick(worldPos, hitPart, nil)
	end
	session.GetAddBoundaryEdge = function(): { v1: number, v2: number }?
		return mAddBoundaryEdge
	end
	session.GetAddHoverTarget = function(): { type: string, vertexId: number?, edgeKey: string?, position: Vector3? }?
		return mAddHoverTarget
	end
	session.GetMarquee = function(): (Vector2?, Vector2?)
		return mMarqueeStart, mMarqueeEnd
	end

	-- Actions
	session.GenerateGrid = function()
		local pos, flatLook = groundPointAhead()
		-- Square grids align to world axes; triangular grids face the camera.
		local origin = if currentSettings.GridType == "Square"
			then CFrame.new(pos)
			else CFrame.lookAlong(pos, flatLook)
		local spacing = currentSettings.GridSpacing
		generateGridWithParams(origin, currentSettings.GridWidth, currentSettings.GridHeight, spacing, spacing)
	end

	-- Enter the interactive "Place grid" tool: the next two clicks pick the grid's
	-- diagonal corners (Escape cancels). Triggered by the Place... button.
	session.StartGridPlacement = function()
		clearAddState()
		mGridPlacing = true
		mGridFirstPoint = nil
		mGridHoverPoint = nil
		changeSignal:Fire()
	end
	session.IsPlacingGrid = function(): boolean
		return mGridPlacing
	end
	-- Drive placement clicks at explicit world positions (for tests, as the mouse-
	-- driven path uses gridPlacementPos): first call anchors a corner, second commits.
	session.PlaceGridClickAt = function(worldPos: Vector3, hitPart: BasePart?)
		if not mGridPlacing then
			return
		end
		-- Mirror gridPlacementPos: discover the clicked part (and its neighbours) so a
		-- corner can snap to freshly-discovered vertices, not only pre-discovered ones.
		if hitPart then
			local size = hitPart.Size
			local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
			discoverRegionViewed({ worldPos }, extent)
		end
		local pos, snapVid = snapAddPoint(worldPos)
		if not mGridFirstPoint then
			mGridFirstPoint = pos
			mGridFirstSnapped = snapVid ~= nil
			mGridFirstSnapVid = snapVid
			mGridHoverPoint = pos
			changeSignal:Fire()
		else
			local p1 = mGridFirstPoint
			local firstSnapped = mGridFirstSnapped
			local snap = mGridFirstSnapVid or snapVid
			clearGridPlacement()
			generateGridBetween(p1, pos, firstSnapped, snap)
		end
	end
	-- Move the second (hover) corner without committing, so tests can inspect the
	-- live placement preview spanning a rectangle.
	session.SetGridHover = function(worldPos: Vector3)
		mGridHoverPoint = worldPos
		changeSignal:Fire()
	end
	-- World-space line segments ({p1, p2}) previewing the grid being placed: corner
	-- crosses, plus the full cell grid once the first corner is down. nil when idle.
	session.GetGridPreviewLines = function(): { { Vector3 } }?
		if not mGridPlacing then
			return nil
		end
		local lines: { { Vector3 } } = {}
		local function cross(p: Vector3)
			local s = 0.6
			table.insert(lines, { p - Vector3.new(s, 0, 0), p + Vector3.new(s, 0, 0) })
			table.insert(lines, { p - Vector3.new(0, 0, s), p + Vector3.new(0, 0, s) })
		end
		if not mGridFirstPoint then
			if mGridHoverPoint then
				cross(mGridHoverPoint)
			end
			return lines
		end
		cross(mGridFirstPoint)
		local hover = mGridHoverPoint
		if not hover then
			return lines
		end
		local center, cols, rows, cellW, cellH = gridLayoutFromCorners(mGridFirstPoint, hover)
		local halfW, halfH = cols * cellW / 2, rows * cellH / 2
		-- Always the outline; the internal cell lines too unless the grid is huge.
		local drawCells = cols <= 40 and rows <= 40
		local x0, x1 = center.X - halfW, center.X + halfW
		local z0, z1 = center.Z - halfH, center.Z + halfH
		local y = center.Y
		-- Triangular grids use uniform spacing and offset rows, so preview the actual
		-- triangle edges rather than square cells (which is what was shown before).
		if currentSettings.GridType == "Triangular" then
			local spacing = math.max(currentSettings.GridSpacing, 0.1)
			local rh = spacing * math.sqrt(3) / 2
			local tHalfW, tHalfH = cols * spacing / 2, rows * rh / 2
			local function vpos(rr: number, cc: number): Vector3
				local off = if rr % 2 == 1 then spacing / 2 else 0
				return Vector3.new(center.X + cc * spacing + off - tHalfW, y, center.Z + rr * rh - tHalfH)
			end
			if drawCells then
				for rr = 0, rows do -- horizontal edges of every vertex row
					for cc = 0, cols - 1 do
						table.insert(lines, { vpos(rr, cc), vpos(rr, cc + 1) })
					end
				end
				for r = 1, rows do -- slanted sides + the split diagonal, per the generator
					local oddRow = (r % 2 == 1)
					for c = 1, cols do
						local top, topRight = vpos(r - 1, c - 1), vpos(r - 1, c)
						local bottom, bottomRight = vpos(r, c - 1), vpos(r, c)
						table.insert(lines, { top, bottom })
						table.insert(lines, { topRight, bottomRight })
						table.insert(lines, if oddRow then { top, bottomRight } else { topRight, bottom })
					end
				end
			else
				local x0t, x1t = center.X - tHalfW, center.X + tHalfW
				local z0t, z1t = center.Z - tHalfH, center.Z + tHalfH
				table.insert(lines, { Vector3.new(x0t, y, z0t), Vector3.new(x1t, y, z0t) })
				table.insert(lines, { Vector3.new(x0t, y, z1t), Vector3.new(x1t, y, z1t) })
				table.insert(lines, { Vector3.new(x0t, y, z0t), Vector3.new(x0t, y, z1t) })
				table.insert(lines, { Vector3.new(x1t, y, z0t), Vector3.new(x1t, y, z1t) })
			end
			return lines
		end
		for j = 0, rows do
			if drawCells or j == 0 or j == rows then
				local z = z0 + j * cellH
				table.insert(lines, { Vector3.new(x0, y, z), Vector3.new(x1, y, z) })
			end
		end
		for i = 0, cols do
			if drawCells or i == 0 or i == cols then
				local x = x0 + i * cellW
				table.insert(lines, { Vector3.new(x, y, z0), Vector3.new(x, y, z1) })
			end
		end
		return lines
	end
	session.ImportHeightmap = function()
		if mImportProgress then
			return -- already importing
		end

		local origin = CFrame.new((groundPointAhead()))

		-- Snapshot settings before spawning so they can't change mid-import
		local importWidth = currentSettings.ImportWidth
		local importHeight = currentSettings.ImportHeight
		local importSpacing = currentSettings.ImportSpacing

		mImportProgress = 0
		changeSignal:Fire()

		task.spawn(function()
			pushUndoSnapshot()
			local recording = ChangeHistoryService:TryBeginRecording("PolyMap Import Heightmap")

			local ok, err = pcall(function()
				importHeightmap({
					ImageId = currentSettings.ImportImageId,
					Width = importWidth,
					Height = importHeight,
					Spacing = importSpacing,
					HeightScale = currentSettings.ImportHeightScale,
					Origin = origin,
					Thickness = currentSettings.Thickness,
					-- An imported heightmap is its own fresh piece -> its own folder.
					Parent = newMeshFolder(),
					OnProgress = function(fraction: number)
						mImportProgress = fraction
						changeSignal:Fire()
					end,
				})
			end)

			if recording then
				if ok then
					ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
				else
					ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
				end
			elseif ok then
				ChangeHistoryService:SetWaypoint("PolyMap Import Heightmap")
			end

			if ok then
				local gridExtent = math.max(importWidth, importHeight)
					* importSpacing / 2 + importSpacing
				-- TODO: Do we need a discover here? We could discover on demand
				discoverRegionViewed({origin.Position}, gridExtent)
			else
				warn("PolyMap Import failed: " .. tostring(err))
			end

			mImportProgress = nil
			changeSignal:Fire()
		end)
	end
	session.GetImportProgress = function(): number?
		return mImportProgress
	end
	session.MoveSelectedVertices = function(delta: Vector3)
		if getSelectedVertexCount() == 0 then
			return
		end

		runUndoableOperation("PolyMap Move", function(): boolean
			local moves: { [number]: Vector3 } = {}
			for vid in mSelectedVertices do
				local v = mMesh.getVertex(vid)
				if v then
					moves[vid] = v.position + delta
				end
			end
			mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())
			return true
		end)
		changeSignal:Fire()
	end

	----------------------------------------------------------------------
	-- Programmatic actions
	--
	-- These drive the same mesh mutations and undo machinery as the
	-- mouse-driven handlers above, but parameterized by explicit world
	-- positions instead of the live cursor. They let the editor be scripted
	-- and, in particular, let workflow.spec.lua exercise full editing
	-- sequences (add / adjust / paint) with undo/redo end-to-end.
	----------------------------------------------------------------------

	-- Replace the selection with the vertices nearest each given world position.
	session.SelectVerticesNear = function(positions: { Vector3 })
		local newSelection: { [number]: boolean } = {}
		for _, pos in positions do
			local vid = mMesh.findVertexNear(pos, 0.5)
			if vid then
				newSelection[vid] = true
			end
		end
		mSelectedVertices = newSelection
		mSavedVertexPositions = {}
		changeSignal:Fire()
	end

	-- Drag the selected vertices by delta WITH influence falloff, exactly as the
	-- interactive Move handle does (start/apply/end): the undo snapshot captures
	-- only the selected vertices, but the move also shifts unselected vertices
	-- within InfluenceRadius. Lets workflow.spec exercise the move tool's real
	-- behaviour (a single drag moves a whole region) end-to-end with undo.
	session.MoveSelectedWithInfluence = function(delta: Vector3)
		if getSelectedVertexCount() == 0 then
			return
		end
		saveVertexPositions()
		runUndoableOperation("PolyMap Move", function(): boolean
			local moves: { [number]: Vector3 } = {}
			for vid, origPos in mSavedVertexPositions do
				moves[vid] = origPos + delta
			end
			for vid, info in mInfluencedVertices do
				moves[vid] = info.position + delta * info.factor
			end
			mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())
			return true
		end)
		changeSignal:Fire()
	end

	-- Drive the interactive Move handle drag in phases (start / apply / end), as the
	-- 3D dragger does live, so tests can interrupt a drag mid-stride -- e.g. fire an
	-- undo before EndHandleDrag -- and confirm the transient state is cleaned up.
	session.StartHandleDrag = function()
		startMove()
	end
	session.ApplyHandleDrag = function(delta: Vector3)
		applyMove(CFrame.new(delta))
	end
	session.EndHandleDrag = function()
		endMove()
	end
	session.IsHandleDragging = function(): boolean
		return mIsDraggingHandle
	end

	-- Add a triangle off the boundary edge nearest nearEdgeWorldPos, with its
	-- third corner at apexWorldPos. Mirrors handleAddClick's "plane" placement;
	-- finds the edge directly via getBoundaryEdges() so it stays independent of
	-- the hit-part / hover state the interactive Add path threads through.
	session.AddTriangleOffEdge = function(nearEdgeWorldPos: Vector3, apexWorldPos: Vector3): number?
		discoverRegionViewed({ nearEdgeWorldPos }, 15)
		local edge: any = nil
		local bestDist = math.huge
		for _, candidate in mMesh.getBoundaryEdges() do
			local cv1 = mMesh.getVertex(candidate.v1)
			local cv2 = mMesh.getVertex(candidate.v2)
			if cv1 and cv2 then
				local mid = (cv1.position + cv2.position) / 2
				local dist = (mid - nearEdgeWorldPos).Magnitude
				if dist < bestDist then
					bestDist = dist
					edge = candidate
				end
			end
		end
		if not edge then
			return nil
		end
		local v1 = mMesh.getVertex(edge.v1)
		local v2 = mMesh.getVertex(edge.v2)
		if not (v1 and v2) then
			return nil
		end

		-- Face the new triangle the same way as the edge's parent, deriving the
		-- hint from the parent normal rather than the apex (as handleAddClick does).
		local hintPoint = apexWorldPos
		local parentTriId = edge.triangles[1]
		if parentTriId then
			local parentTri = mMesh.getTriangle(parentTriId)
			if parentTri then
				local edgeMid = (v1.position + v2.position) / 2
				hintPoint = edgeMid + parentTri.normal * 0.5
			end
		end

		local triId: number? = nil
		runUndoableOperation("PolyMap Add Triangle", function(): boolean
			triId = mMesh.addTriangle(
				v1.position, v2.position, apexWorldPos,
				currentSettings.Thickness, resolveNewParent(parentForTriangle(parentTriId)), getTriangleProps(), hintPoint
			)
			return triId ~= nil
		end)
		changeSignal:Fire()
		return triId
	end

	-- Paint the triangle under worldPos (plus PaintRadius walk) using the current
	-- paint settings. Mirrors applyPaintAtCursor's colour/material application.
	-- Test hook: run a Delete stroke that visits the given screen positions in order
	-- (one per frame, like the cursor task), so the drill guard can be exercised.
	session.DebugDeleteStroke = function(screenPositions: { Vector2 })
		startStroke()
		for _, pos in screenPositions do
			applyDeleteAtCursor(pos)
		end
		endStroke()
	end

	-- Test hook: run a Paint stroke that visits the given screen positions in order,
	-- exercising the real applyPaintAtCursor (raycast -> hit triangle -> its wedges).
	session.DebugPaintStroke = function(screenPositions: { Vector2 })
		startStroke()
		for _, pos in screenPositions do
			applyPaintAtCursor(pos)
		end
		endStroke()
	end

	-- Test hook: run the real hover update as if the cursor were at screenPos, so the
	-- hover feedback (mHoverVertexId / mHoverTriangleIds) can be asserted without a mouse.
	session.DebugHoverAt = function(screenPos: Vector2)
		updateHover(screenPos)
	end

	-- Test hook: run the real Escape handler (cancels in-progress Add / grid / Pick).
	session.DebugEscape = function()
		handleEscape()
	end

	session.PaintAt = function(worldPos: Vector3)
		local hitPart: BasePart? = nil
		for _, p in workspace:GetPartBoundsInRadius(worldPos, 1) do
			if p:IsA("BasePart") then
				hitPart = p :: BasePart
				break
			end
		end
		if not hitPart then
			return
		end
		-- Mirror applyPaintAtCursor's discovery: discover the hit part, then the
		-- radius region just before walking it (see discoverAndWalkSurface).
		discoverPartViewed(hitPart, worldPos)

		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Paint")

		local partsToPaint: { BasePart } = {}
		local triId = mMesh.getPartTriangle(hitPart, worldPos)
		if triId then
			local tri = mMesh.getTriangle(triId)
			if tri then
				for _, part in tri.parts do
					table.insert(partsToPaint, part)
				end
			end
			local radius = currentSettings.PaintRadius
			if radius > 0 then
				for _, nearTriId in discoverAndWalkSurface(triId, worldPos, radius) do
					local nearTri = mMesh.getTriangle(nearTriId)
					if nearTri then
						for _, part in nearTri.parts do
							table.insert(partsToPaint, part)
						end
					end
				end
			end
		else
			table.insert(partsToPaint, hitPart)
		end

		local c = currentSettings.PaintColor
		local color = Color3.new(c[1], c[2], c[3])
		local mat = (Enum.Material :: any)[currentSettings.PaintMaterial]
		local paintStrength = currentSettings.PaintStrength
		local paintTarget = currentSettings.PaintTarget
		local doColor = paintTarget ~= "Material"
		local doMaterial = paintTarget ~= "Color"
		for _, part in partsToPaint do
			if doColor then
				if paintStrength >= 1.0 then
					part.Color = color
				else
					part.Color = part.Color:Lerp(color, paintStrength)
				end
			end
			if doMaterial and mat then
				part.Material = mat
				part.MaterialVariant = currentSettings.PaintMaterialVariant
			end
		end

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		else
			ChangeHistoryService:SetWaypoint("PolyMap Paint")
		end
		changeSignal:Fire()
	end

	return session
end

export type PolyMapSession = typeof(createPolyMapSession(...))

return createPolyMapSession
