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

local function mouseRaycast(): RaycastResult?
	local mouseLocation = UserInputService:GetMouseLocation()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	return workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
end

-- Raycast with a spherecast fallback for modes that want loose targeting
local function mouseRaycastLoose(): RaycastResult?
	local mouseLocation = UserInputService:GetMouseLocation()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local result = workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	if result then
		return result
	end
	return workspace:Spherecast(ray.Origin, kSpherecastRadius, ray.Direction * 1000, params)
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
	local mAddPlanePoint: Vector3? = nil
	local mAddPlaneNormal: Vector3? = nil
	local mAddHoverTarget: { type: string, vertexId: number?, edgeKey: string?, position: Vector3? }? = nil
	local mAddTriangleProps: fillTriangle.TriangleProps? = nil

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
		}
	end

	local function clearAddState()
		mAddBoundaryEdge = nil
		mAddPoints = {}
		mAddPlanePoint = nil
		mAddPlaneNormal = nil
		mAddHoverTarget = nil
		mAddTriangleProps = nil
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
	-- points over empty space where the raycast misses. Plane = the selected edge's
	-- surface (extend it flat), a horizontal plane through the first placed fresh
	-- point, or the ground (Y=0) for the very first point.
	local function addProjectedPos(): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local mouseLocation = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		local planePoint: Vector3
		local planeNormal: Vector3
		if mAddBoundaryEdge and mAddPlanePoint and mAddPlaneNormal then
			planePoint, planeNormal = mAddPlanePoint, mAddPlaneNormal
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
		return mMesh.discoverPart(part, hitPoint, cameraViewPoint())
	end
	local function discoverRegionViewed(seeds: { Vector3 }, radius: number)
		return mMesh.discoverRegion(seeds, radius, cameraViewPoint())
	end

	local function discoverAndWalkSurface(seedTriangleId: number, worldPos: Vector3, radius: number)
		discoverRegionViewed({ worldPos }, radius)
		return mMesh.walkSurface(seedTriangleId, worldPos, radius)
	end

	local function updateHover()
		-- Leaving Add mode abandons any in-progress triangle (edge grab or fresh
		-- points), so stale state doesn't reappear on returning to Add.
		if currentSettings.Mode ~= "Add" and (mAddBoundaryEdge or #mAddPoints > 0) then
			clearAddState()
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

		-- Use loose targeting (spherecast fallback) for selection/add modes
		local mode = currentSettings.Mode
		local useLoose = mode == "Move" or mode == "Rotate" or mode == "Add"
		local result = if useLoose then mouseRaycastLoose() else mouseRaycast()
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
				local mouseLocation = UserInputService:GetMouseLocation()
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
					newHoverVertex = findNearestVertex(worldPos, hitTriangleId)
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
			-- Phase 1 / fresh-point start. Only try to grab a boundary edge before any
			-- fresh point has been placed and only when actually over geometry.
			local grabbedEdge: string? = nil
			if worldPos and #mAddPoints == 0 and result and result.Instance:IsA("BasePart") then
				-- Discover neighbors so we can tell which edges are truly boundary
				local hitPart = result.Instance :: BasePart
				local size = hitPart.Size
				local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
				discoverRegionViewed({worldPos}, extent)
				-- Hover the nearest boundary edge of the hit face. Filter to triangles
				-- facing the same way as the hit normal so we don't pick a back face.
				local partTriIds = mMesh.getPartTriangles(hitPart)
				local filtered = {}
				for _, triId in partTriIds do
					local tri = mMesh.getTriangle(triId)
					if tri and tri.normal:Dot(result.Normal) > 0 then
						table.insert(filtered, triId)
					end
				end
				grabbedEdge = findNearestBoundaryEdge(worldPos, if #filtered > 0 then filtered else partTriIds, nil)
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
		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Add Triangle")
		-- A disconnected triangle has nothing to match, so hint it to face up.
		local centroid = (p1 + p2 + p3) / 3
		mMesh.addTriangle(
			p1, p2, p3,
			currentSettings.Thickness, workspace.Terrain, getTriangleProps(), centroid + Vector3.yAxis
		)
		clearAddState()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	-- Place one fresh corner (snapped to a nearby vertex). The third corner commits
	-- the triangle.
	local function placeFreshPoint(worldPos: Vector3)
		local p = snapAddPoint(worldPos)
		table.insert(mAddPoints, p)
		if #mAddPoints >= 3 then
			commitFreshTriangle()
		else
			changeSignal:Fire()
		end
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
			-- No edge selected yet. Place a fresh point when over empty space, or once
			-- the fresh-point path has started; otherwise grab a boundary edge below.
			if not hitPart or #mAddPoints > 0 then
				placeFreshPoint(worldPos)
				return
			end
			-- Discover neighbors so we can tell which edges are truly boundary
			local size = hitPart.Size
			local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
			discoverRegionViewed({worldPos}, extent)
			-- Filter to triangles facing the same way as the hit normal
			local partTriIds = mMesh.getPartTriangles(hitPart)
			if hitNormal then
				local filtered = {}
				for _, triId in partTriIds do
					local tri = mMesh.getTriangle(triId)
					if tri and tri.normal:Dot(hitNormal) > 0 then
						table.insert(filtered, triId)
					end
				end
				if #filtered > 0 then
					partTriIds = filtered
				end
			end
			local edgeKey = findNearestBoundaryEdge(worldPos, partTriIds, nil)
			if edgeKey then
				local edge = mMesh.getEdges()[edgeKey]
				if edge then
					mAddBoundaryEdge = { v1 = edge.v1, v2 = edge.v2 }
					-- Store plane and properties from the parent triangle
					local parentTriId = edge.triangles[1]
					if parentTriId then
						local tri = mMesh.getTriangle(parentTriId)
						if tri then
							local tv = mMesh.getVertex(tri.vertices[1])
							if tv then
								mAddPlanePoint = tv.position
							end
							mAddPlaneNormal = tri.normal
							local part = tri.parts[1]
							if part then
								mAddTriangleProps = {
									Color = part.Color,
									Material = part.Material,
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
							currentSettings.Thickness, workspace.Terrain, addProps, addHintPoint
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
								currentSettings.Thickness, workspace.Terrain, addProps, addHintPoint
							)
							mMesh.addTriangle(
								v2.position, tb.position, ta.position,
								currentSettings.Thickness, workspace.Terrain, addProps, addHintPoint
							)
						end
					end
				elseif target.type == "plane" and target.position then
					mMesh.addTriangle(
						v1.position, v2.position, target.position,
						currentSettings.Thickness, workspace.Terrain, addProps, addHintPoint
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

	local function applyDeleteAtCursor()
		local result = mouseRaycast()
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
				changeSignal:Fire()
			end
		end
	end

	local function applyPaintAtCursor()
		local result = mouseRaycast()
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

			-- Collect all parts to paint
			local partsToPaint: { BasePart } = { result.Instance :: BasePart }
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

	local function endStroke()
		if mStrokeRecording then
			ChangeHistoryService:FinishRecording(mStrokeRecording, Enum.FinishRecordingOperation.Commit)
			mStrokeRecording = nil
		end
		mStrokeDragging = false
		mStrokePlanePoint = nil
		mStrokePlaneNormal = nil
		mStrokeSeedTriangleId = nil
		mPaintOriginalColors = {}
		mBrushSavedPositions = {}
		mBrushAmounts = {}
	end

	local function handleClick()
		if mIsOverUI or mIsDraggingHandle then
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
				currentSettings.PaintMaterial = matName
				-- Add to recents if not already present
				if not table.find(currentSettings.RecentMaterials, matName) then
					table.insert(currentSettings.RecentMaterials, 1, matName)
					while #currentSettings.RecentMaterials > 4 do
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
			-- Escape cancels an in-progress Add (now that empty clicks place points).
			if input.KeyCode == Enum.KeyCode.Escape and not gameProcessed then
				if currentSettings.Mode == "Add" and (mAddBoundaryEdge or #mAddPoints > 0) then
					clearAddState()
					changeSignal:Fire()
				end
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

	local function handleUndo(waypointName: string)
		if not string.find(waypointName, "PolyMap") then
			return
		end
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
		mSavedVertexPositions = {}
		clearAddState()
		Selection:Set({})
		changeSignal:Fire()
	end

	local function handleRedo(waypointName: string)
		if not string.find(waypointName, "PolyMap") then
			return
		end
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
		mSavedVertexPositions = {}
		clearAddState()
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
	-- preview and tests).
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

		runUndoableOperation("PolyMap Generate Grid", function(): boolean
			generateGrid({
				GridType = currentSettings.GridType,
				Width = currentSettings.GridWidth,
				Height = currentSettings.GridHeight,
				Spacing = currentSettings.GridSpacing,
				Origin = origin,
				Thickness = currentSettings.Thickness,
				Parent = workspace.Terrain,
				Props = getTriangleProps(),
			})
			return true
		end)

		-- Discover the generated grid parts instead of full rescan
		local gridExtent = math.max(currentSettings.GridWidth, currentSettings.GridHeight)
			* currentSettings.GridSpacing / 2 + currentSettings.GridSpacing
		-- TODO: Do we need a discover here? We could discover on demand
		discoverRegionViewed({origin.Position}, gridExtent)
		changeSignal:Fire()
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
					Parent = workspace.Terrain,
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
				currentSettings.Thickness, workspace.Terrain, getTriangleProps(), hintPoint
			)
			return triId ~= nil
		end)
		changeSignal:Fire()
		return triId
	end

	-- Paint the triangle under worldPos (plus PaintRadius walk) using the current
	-- paint settings. Mirrors applyPaintAtCursor's colour/material application.
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
