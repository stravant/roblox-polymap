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

	local mMesh = createTriangleMesh()

	-- Selection state
	local mSelectedVertices: { [number]: boolean } = {}
	local mHoverVertexId: number? = nil
	local mHoverEdgeKey: string? = nil
	local mHoverTriangleIds: { number } = {}

	-- Add mode state
	local mAddBoundaryEdge: { v1: number, v2: number }? = nil
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
				tostring(math.min(verts[1], verts[2])) .. "_" .. tostring(math.max(verts[1], verts[2])),
				tostring(math.min(verts[2], verts[3])) .. "_" .. tostring(math.max(verts[2], verts[3])),
				tostring(math.min(verts[1], verts[3])) .. "_" .. tostring(math.max(verts[1], verts[3])),
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

	local function updateHover()
		if mIsOverUI or mIsDraggingHandle then
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
		local useLoose = mode == "Select" or mode == "Move" or mode == "Rotate"
			or mode == "Subdivide" or mode == "Simplify" or mode == "Add"
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

		local hitTriangleId: number? = nil
		if result and result.Instance:IsA("BasePart") then
			-- Discover the part under the cursor (O(1) for already-tracked parts)
			mMesh.discoverPart(result.Instance, result.Position)
			hitTriangleId = mMesh.getPartTriangle(result.Instance :: BasePart, result.Position)
		end

		if worldPos then
			if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify" then
				newHoverVertex = findNearestVertex(worldPos, hitTriangleId)
			end
			if mode == "Delete" then
				if currentSettings.DeleteTarget == "Vertex" then
					newHoverVertex = findNearestVertex(worldPos, hitTriangleId)
				else
					-- Face mode: hover the triangle(s) that would be affected
					local radius = currentSettings.DeleteRadius
					if radius > 0 and hitTriangleId then
						newHoverTriangles = mMesh.walkSurface(hitTriangleId, worldPos, radius)
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
					newHoverTriangles = mMesh.walkSurface(hitTriangleId, worldPos, radius)
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
					newHoverTriangles = mMesh.walkSurface(hitTriangleId, worldPos, radius)
				end
			end
			if mode == "Flatten" then
				local radius = currentSettings.FlattenRadius
				if radius > 0 and hitTriangleId then
					newHoverTriangles = mMesh.walkSurface(hitTriangleId, worldPos, radius)
				end
			end
		end

		if mode == "Add" and worldPos and not mAddBoundaryEdge and result and result.Instance:IsA("BasePart") then
			-- Discover neighbors so we can tell which edges are truly boundary
			local hitPart = result.Instance :: BasePart
			local size = hitPart.Size
			local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
			mMesh.discoverRegion({worldPos}, extent)
			-- Phase 1: hover the nearest boundary edge of the hit part's triangles
			local partTriIds = mMesh.getPartTriangles(hitPart)
			newHoverEdge = findNearestBoundaryEdge(worldPos, partTriIds, nil)
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
					local storedKey = tostring(math.min(mAddBoundaryEdge.v1, mAddBoundaryEdge.v2))
						.. "_" .. tostring(math.max(mAddBoundaryEdge.v1, mAddBoundaryEdge.v2))
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
									local ek = tostring(math.min(va, vb)) .. "_" .. tostring(math.max(va, vb))
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
												local ek = tostring(math.min(va, vb)) .. "_" .. tostring(math.max(va, vb))
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
		mMesh.discoverRegion({worldPos}, 15)
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
		changeSignal:Fire()
	end

	local function handleAddClick(worldPos: Vector3, hitPart: BasePart?)
		mMesh.discoverRegion({worldPos}, 15)
		if not mAddBoundaryEdge then
			-- Phase 1: select a boundary edge of the hit part
			if not hitPart then return end
			mMesh.discoverPart(hitPart, worldPos)
			-- Discover neighbors so we can tell which edges are truly boundary
			local size = hitPart.Size
			local extent = math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
			mMesh.discoverRegion({worldPos}, extent)
			local partTriIds = mMesh.getPartTriangles(hitPart)
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
				end
			end
		else
			-- Phase 2: place triangle(s) based on hover target
			local target = mAddHoverTarget
			if not target then
				-- Empty click: cancel
				clearAddState()
				changeSignal:Fire()
				return
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
				mMesh.discoverPart(result.Instance :: BasePart, result.Position)
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
			mMesh.discoverPart(result.Instance :: BasePart, result.Position)
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
				mMesh.discoverRegion({worldPos}, 15)
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
				toRemove = mMesh.walkSurface(mStrokeSeedTriangleId, worldPos, radius)
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
			mMesh.discoverPart(result.Instance :: BasePart, result.Position)
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
				for _, nearTriId in mMesh.walkSurface(mStrokeSeedTriangleId, result.Position, radius) do
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
			_, walkVertexIds = mMesh.walkSurface(mStrokeSeedTriangleId, worldPos.hit, radius)
		else
			mMesh.discoverRegion({worldPos.hit}, radius + 5)
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
			_, walkVertexIds = mMesh.walkSurface(mStrokeSeedTriangleId, worldPos.hit, radius)
		else
			mMesh.discoverRegion({worldPos.hit}, radius + 5)
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
		local useLoose = mode == "Select" or mode == "Move" or mode == "Rotate"
			or mode == "Subdivide" or mode == "Simplify" or mode == "Add"
		local result = if useLoose then mouseRaycastLoose() else mouseRaycast()
		if not result then
			if (mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify") and not isShiftHeld() then
				mSelectedVertices = {}
				changeSignal:Fire()
			end
			if mode == "Add" and mAddBoundaryEdge then
				clearAddState()
				changeSignal:Fire()
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

		if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify" then
			handleSelectClick(result.Position, hitPart)
		elseif mode == "Add" then
			handleAddClick(result.Position, hitPart)
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
			mMesh.discoverRegion({centerHit.Position}, halfDiag + 10)
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

		-- Discover nearby geometry and walk topology in a single call
		local seedPositions: { Vector3 } = {}
		for _, origPos in mSavedVertexPositions do
			table.insert(seedPositions, origPos)
		end
		local _, discoveredVids = mMesh.discoverRegion(seedPositions, radius)

		-- Compute falloff for returned non-selected vertices using XZ distance
		for _, vid in discoveredVids do
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
				if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify" then
					local mousePos = UserInputService:GetMouseLocation()
					mMarqueeStart = mousePos
					mMarqueeEnd = nil
					mPreMarqueeSelection = if isShiftHeld() then table.clone(mSelectedVertices) else {}
				end
				handleClick()
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

	local function handleUndo(waypointName: string)
		if not string.find(waypointName, "PolyMap") then
			return
		end
		-- Save current selection positions for redo
		table.insert(mRedoSelections, captureSelectionPositions())
		-- Rescan mesh from the reverted parts
		mMesh.refreshFromParts()
		-- Restore selection from saved positions
		local undoSelection = table.remove(mUndoSelections)
		if undoSelection then
			restoreSelectionFromPositions(undoSelection)
		else
			mSelectedVertices = {}
		end
		mHoverVertexId = nil
		mHoverEdgeKey = nil
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
		-- Rescan mesh from the re-applied parts
		mMesh.refreshFromParts()
		-- Restore selection from saved positions
		local redoSelection = table.remove(mRedoSelections)
		if redoSelection then
			restoreSelectionFromPositions(redoSelection)
		else
			mSelectedVertices = {}
		end
		mHoverVertexId = nil
		mHoverEdgeKey = nil
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
		if radius <= 0 then
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

		-- Collect current positions as seeds for topology walk
		local seedPositions: { Vector3 } = {}
		for vid in seedVids do
			local v = mMesh.getVertex(vid)
			if v then
				table.insert(seedPositions, v.position)
			end
		end
		if #seedPositions == 0 then
			return {}
		end

		-- Discover region and walk topology
		local _, discoveredVids = mMesh.discoverRegion(seedPositions, radius)

		-- For XZ distance filtering, use saved positions during drags
		local filterPositions: { Vector3 }
		if mIsDraggingHandle and next(mSavedVertexPositions) then
			filterPositions = {}
			for vid in seedVids do
				local pos = mSavedVertexPositions[vid]
				if pos then
					table.insert(filterPositions, pos)
				end
			end
			if #filterPositions == 0 then
				filterPositions = seedPositions
			end
		else
			filterPositions = seedPositions
		end

		-- Re-filter returned vertices by XZ distance and include seed vertices
		local affectedVids: { [number]: boolean } = {}
		for vid in seedVids do
			affectedVids[vid] = true
		end
		for _, vid in discoveredVids do
			if affectedVids[vid] then continue end
			local neighbor = mMesh.getVertex(vid)
			if not neighbor then continue end
			for _, seedPos in filterPositions do
				local delta = neighbor.position - seedPos
				if Vector3.new(delta.X, 0, delta.Z).Magnitude < radius then
					affectedVids[vid] = true
					break
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
		if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify" then
			return getExpandedTriangleIds(mSelectedVertices)
		end
		return {}
	end
	session.GetHoverOutlineTriangleIds = function(): { number }
		local mode = currentSettings.Mode
		if mode ~= "Select" and mode ~= "Move" and mode ~= "Rotate" and mode ~= "Subdivide" and mode ~= "Simplify" then
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
		local camera = workspace.CurrentCamera
		local origin = CFrame.identity
		if camera then
			-- Place grid in front of camera, on the ground plane
			local look = camera.CFrame.LookVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			if flatLook.Magnitude > 0.01 then
				flatLook = flatLook.Unit
			else
				flatLook = Vector3.zAxis
			end
			local pos = camera.CFrame.Position + flatLook * 20
			pos = Vector3.new(pos.X, 0, pos.Z) -- project onto ground
			if currentSettings.GridType == "Square" then
				-- Align to world axes so grid edges are axis-aligned
				origin = CFrame.new(pos)
			else
				origin = CFrame.lookAlong(pos, flatLook)
			end
		end

		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Generate Grid")

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

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end

		-- Discover the generated grid parts instead of full rescan
		local gridExtent = math.max(currentSettings.GridWidth, currentSettings.GridHeight)
			* currentSettings.GridSpacing / 2 + currentSettings.GridSpacing
		-- TODO: Do we need a discover here? We could discover on demand
		mMesh.discoverRegion({origin.Position}, gridExtent)
		changeSignal:Fire()
	end
	session.ImportHeightmap = function()
		if mImportProgress then
			return -- already importing
		end

		local camera = workspace.CurrentCamera
		local origin = CFrame.identity
		if camera then
			local look = camera.CFrame.LookVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			if flatLook.Magnitude > 0.01 then
				flatLook = flatLook.Unit
			else
				flatLook = Vector3.zAxis
			end
			local pos = camera.CFrame.Position + flatLook * 20
			pos = Vector3.new(pos.X, 0, pos.Z)
			origin = CFrame.new(pos)
		end

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
				mMesh.discoverRegion({origin.Position}, gridExtent)
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

		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Move")

		local moves: { [number]: Vector3 } = {}
		for vid in mSelectedVertices do
			local v = mMesh.getVertex(vid)
			if v then
				moves[vid] = v.position + delta
			end
		end
		mMesh.moveVertices(moves, currentSettings.Thickness, getTriangleProps())

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end
	session.Subdivide = function()
		if getSelectedVertexCount() == 0 then
			return
		end

		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Subdivide")

		-- Collect all triangle IDs touching any selected vertex
		local affectedTriIds: { [number]: boolean } = {}
		for vid in mSelectedVertices do
			local v = mMesh.getVertex(vid)
			if v then
				for _, triId in v.triangles do
					affectedTriIds[triId] = true
				end
			end
		end

		-- Snapshot each triangle with per-edge split info.
		-- An edge is split only if both its endpoints are selected,
		-- so boundary edges of the selection stay intact and topology is preserved.
		type TriSnapshot = {
			p: { Vector3 },
			vids: { number },
			splits: { boolean },
			color: Color3,
			material: Enum.Material,
			hintPoint: Vector3,
		}
		local snapshots: { TriSnapshot } = {}
		for triId in affectedTriIds do
			local tri = mMesh.getTriangle(triId)
			if tri then
				local positions: { Vector3 } = {}
				local vids: { number } = {}
				for _, vid in tri.vertices do
					local v = mMesh.getVertex(vid)
					if v then
						table.insert(positions, v.position)
						table.insert(vids, vid)
					end
				end
				if #positions == 3 then
					local part = tri.parts[1]
					table.insert(snapshots, {
						p = positions,
						vids = vids,
						splits = {
							(mSelectedVertices[vids[1]] and mSelectedVertices[vids[2]]) == true,
							(mSelectedVertices[vids[2]] and mSelectedVertices[vids[3]]) == true,
							(mSelectedVertices[vids[3]] and mSelectedVertices[vids[1]]) == true,
						},
						color = part.Color,
						material = part.Material,
						hintPoint = (positions[1] + positions[2] + positions[3]) / 3 + tri.normal * 0.1,
					})
				end
			end
		end

		-- Remove all affected triangles
		for triId in affectedTriIds do
			mMesh.removeTriangle(triId)
		end

		-- Re-add with adaptive subdivision
		local newMidpoints: { Vector3 } = {}
		local thickness = currentSettings.Thickness
		local parent = workspace.Terrain
		for _, snap in snapshots do
			local p = snap.p
			local s = snap.splits
			local props: fillTriangle.TriangleProps = {
				Color = snap.color,
				Material = snap.material,
			}
			local splitCount = (if s[1] then 1 else 0) + (if s[2] then 1 else 0) + (if s[3] then 1 else 0)

			local hint = snap.hintPoint
			if splitCount == 0 then
				-- No edges split — re-add as-is
				mMesh.addTriangle(p[1], p[2], p[3], thickness, parent, props, hint)
			elseif splitCount == 3 then
				-- All edges split — standard 4-way subdivision
				local m12 = (p[1] + p[2]) / 2
				local m23 = (p[2] + p[3]) / 2
				local m31 = (p[3] + p[1]) / 2
				table.insert(newMidpoints, m12)
				table.insert(newMidpoints, m23)
				table.insert(newMidpoints, m31)
				mMesh.addTriangle(p[1], m12, m31, thickness, parent, props, hint)
				mMesh.addTriangle(m12, p[2], m23, thickness, parent, props, hint)
				mMesh.addTriangle(m31, m23, p[3], thickness, parent, props, hint)
				mMesh.addTriangle(m12, m23, m31, thickness, parent, props, hint)
			elseif splitCount == 1 then
				-- One edge split — rotate so split edge is 1-2, then bisect
				local rp = p
				if s[2] then
					rp = { p[2], p[3], p[1] }
				elseif s[3] then
					rp = { p[3], p[1], p[2] }
				end
				local m = (rp[1] + rp[2]) / 2
				table.insert(newMidpoints, m)
				mMesh.addTriangle(rp[1], m, rp[3], thickness, parent, props, hint)
				mMesh.addTriangle(m, rp[2], rp[3], thickness, parent, props, hint)
			else -- splitCount == 2
				-- Two edges split — rotate so unsplit edge is 1-2, apex is vertex 3
				local rp = p
				if not s[1] then
					-- edge 1-2 unsplit, already canonical
				elseif not s[2] then
					rp = { p[2], p[3], p[1] }
				else
					rp = { p[3], p[1], p[2] }
				end
				-- Split edges: rp2-rp3 and rp3-rp1
				local m23 = (rp[2] + rp[3]) / 2
				local m31 = (rp[3] + rp[1]) / 2
				table.insert(newMidpoints, m23)
				table.insert(newMidpoints, m31)
				mMesh.addTriangle(rp[3], m31, m23, thickness, parent, props, hint)
				mMesh.addTriangle(rp[1], rp[2], m23, thickness, parent, props, hint)
				mMesh.addTriangle(rp[1], m23, m31, thickness, parent, props, hint)
			end
		end

		-- Update selection: keep original selected vids that still exist, add midpoint vids
		local newSelection: { [number]: boolean } = {}
		for vid in mSelectedVertices do
			if mMesh.getVertex(vid) then
				newSelection[vid] = true
			end
		end
		for _, midPos in newMidpoints do
			local vid = mMesh.findVertexNear(midPos, 0.1)
			if vid then
				newSelection[vid] = true
			end
		end
		mSelectedVertices = newSelection

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end
	session.Simplify = function(count: number)
		if getSelectedVertexCount() < 2 then
			return
		end

		pushUndoSnapshot()
		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Simplify")
		local performed = 0

		for _ = 1, count do
			-- Find shortest edge (XZ distance) where both endpoints are selected
			local bestEdgeKey: string? = nil
			local bestDist = math.huge
			for key, edge in mMesh.getEdges() do
				if not mSelectedVertices[edge.v1] or not mSelectedVertices[edge.v2] then
					continue
				end
				local v1 = mMesh.getVertex(edge.v1)
				local v2 = mMesh.getVertex(edge.v2)
				if not v1 or not v2 then continue end
				local delta = v1.position - v2.position
				local dist = Vector3.new(delta.X, 0, delta.Z).Magnitude
				if dist < bestDist then
					bestDist = dist
					bestEdgeKey = key
				end
			end

			if not bestEdgeKey then
				break
			end

			local edge = mMesh.getEdges()[bestEdgeKey]
			if not edge then break end

			local v1 = mMesh.getVertex(edge.v1)
			local v2 = mMesh.getVertex(edge.v2)
			if not v1 or not v2 then break end

			local midpoint = (v1.position + v2.position) / 2

			-- Collect all triangles touching either endpoint
			local affectedTriIds: { [number]: boolean } = {}
			for _, triId in v1.triangles do
				affectedTriIds[triId] = true
			end
			for _, triId in v2.triangles do
				affectedTriIds[triId] = true
			end

			-- Snapshot each triangle, replacing either endpoint with midpoint
			local snapshots: { { positions: { Vector3 }, color: Color3, material: Enum.Material, hintPoint: Vector3 } } = {}
			for triId in affectedTriIds do
				local tri = mMesh.getTriangle(triId)
				if tri then
					local positions: { Vector3 } = {}
					for _, vid in tri.vertices do
						local vtx = mMesh.getVertex(vid)
						if vtx then
							if vid == edge.v1 or vid == edge.v2 then
								table.insert(positions, midpoint)
							else
								table.insert(positions, vtx.position)
							end
						end
					end
					if #positions == 3 then
						local part = tri.parts[1]
						local origVerts: { Vector3 } = {}
						for _, vid in tri.vertices do
							local vtx = mMesh.getVertex(vid)
							if vtx then table.insert(origVerts, vtx.position) end
						end
						local centroid = if #origVerts == 3
							then (origVerts[1] + origVerts[2] + origVerts[3]) / 3
							else positions[1]
						table.insert(snapshots, {
							positions = positions,
							color = part.Color,
							material = part.Material,
							hintPoint = centroid + tri.normal * 0.1,
						})
					end
				end
			end

			-- Remove old vertex IDs from selection
			local oldV1 = edge.v1
			local oldV2 = edge.v2
			mSelectedVertices[oldV1] = nil
			mSelectedVertices[oldV2] = nil

			-- Remove all affected triangles
			for triId in affectedTriIds do
				mMesh.removeTriangle(triId)
			end

			-- Recreate triangles with merged vertex (degenerate ones auto-skip)
			for _, snap in snapshots do
				local props: fillTriangle.TriangleProps = {
					Color = snap.color,
					Material = snap.material,
				}
				mMesh.addTriangle(
					snap.positions[1], snap.positions[2], snap.positions[3],
					currentSettings.Thickness, workspace.Terrain, props, snap.hintPoint
				)
			end

			-- Add merged vertex to selection
			local mergedVid = mMesh.findVertexNear(midpoint, 0.1)
			if mergedVid then
				mSelectedVertices[mergedVid] = true
			end

			performed += 1
		end

		if recording then
			if performed > 0 then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			else
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
			end
		end
		changeSignal:Fire()
	end

	return session
end

export type PolyMapSession = typeof(createPolyMapSession(...))

return createPolyMapSession
