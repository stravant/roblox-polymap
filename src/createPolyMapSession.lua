--!strict

local CoreGui = game:GetService("CoreGui")
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

	local function scanMesh()
		mMesh.scanWorkspace()
		mSelectedVertices = {}
		mHoverVertexId = nil
		mHoverEdgeKey = nil
		clearAddState()
		changeSignal:Fire()
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

	local function findNearestVertex(worldPos: Vector3): number?
		local camera = workspace.CurrentCamera
		if not camera then
			return mMesh.findVertexNear(worldPos, VERTEX_CLICK_RADIUS)
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestId: number? = nil
		local bestScreenDist = VERTEX_SCREEN_RADIUS

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

	local function findNearestEdge(worldPos: Vector3): string?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestKey: string? = nil
		local bestDist = 15

		for key, edge in mMesh.getEdges() do
			local v1 = mMesh.getVertex(edge.v1)
			local v2 = mMesh.getVertex(edge.v2)
			if not v1 or not v2 then continue end

			local s1, on1 = camera:WorldToScreenPoint(v1.position)
			local s2, on2 = camera:WorldToScreenPoint(v2.position)
			if not on1 or not on2 then continue end

			local bx, by = s2.X - s1.X, s2.Y - s1.Y
			local lenSq = bx * bx + by * by
			if lenSq < 0.001 then continue end
			local px = mouseScreen.X - s1.X
			local py = mouseScreen.Y - s1.Y
			local t = math.clamp((px * bx + py * by) / lenSq, 0, 1)
			local closestX = s1.X + t * bx
			local closestY = s1.Y + t * by
			local dist = math.sqrt((mouseScreen.X - closestX) ^ 2 + (mouseScreen.Y - closestY) ^ 2)

			if dist < bestDist then
				bestDist = dist
				bestKey = key
			end
		end

		return bestKey
	end

	local function findNearestBoundaryEdge(worldPos: Vector3, skipEdgeKey: string?): string?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestKey: string? = nil
		local bestDist = 15

		for key, edge in mMesh.getEdges() do
			if #edge.triangles ~= 1 then continue end
			if key == skipEdgeKey then continue end
			local v1 = mMesh.getVertex(edge.v1)
			local v2 = mMesh.getVertex(edge.v2)
			if not v1 or not v2 then continue end

			local s1, on1 = camera:WorldToScreenPoint(v1.position)
			local s2, on2 = camera:WorldToScreenPoint(v2.position)
			if not on1 or not on2 then continue end

			local bx, by = s2.X - s1.X, s2.Y - s1.Y
			local lenSq = bx * bx + by * by
			if lenSq < 0.001 then continue end
			local px = mouseScreen.X - s1.X
			local py = mouseScreen.Y - s1.Y
			local t = math.clamp((px * bx + py * by) / lenSq, 0, 1)
			local closestX = s1.X + t * bx
			local closestY = s1.Y + t * by
			local dist = math.sqrt((mouseScreen.X - closestX) ^ 2 + (mouseScreen.Y - closestY) ^ 2)

			if dist < bestDist then
				bestDist = dist
				bestKey = key
			end
		end

		return bestKey
	end

	local function findNearestVertexScreenRadius(worldPos: Vector3, skipVids: { [number]: boolean }?): number?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestId: number? = nil
		local bestScreenDist = 15

		for id, vertex in mMesh.getVertices() do
			if skipVids and skipVids[id] then continue end
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

		local result = mouseRaycast()
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

		if result and result.Instance:IsA("BasePart") then
			-- Discover the part under the cursor (O(1) for already-tracked parts)
			mMesh.discoverPart(result.Instance)
		end

		if worldPos then
			local mode = currentSettings.Mode
			if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify" then
				newHoverVertex = findNearestVertex(worldPos)
			end
			if mode == "Delete" then
				if currentSettings.DeleteTarget == "Vertex" then
					newHoverVertex = findNearestVertex(worldPos)
				else
					-- Face mode: hover the triangle(s) that would be affected
					local radius = currentSettings.DeleteRadius
					if radius > 0 then
						mMesh.discoverRegion(worldPos, radius + 5)
						newHoverTriangles = mMesh.findTrianglesInRadius(worldPos, radius)
					elseif result and result.Instance:IsA("BasePart") then
						local triId = mMesh.getPartTriangle(result.Instance :: BasePart)
						if triId then
							newHoverTriangles = { triId }
						end
					end
				end
			end
			if mode == "Paint" then
				local radius = currentSettings.PaintRadius
				if radius > 0 then
					mMesh.discoverRegion(worldPos, radius + 5)
					newHoverTriangles = mMesh.findTrianglesInRadius(worldPos, radius)
				elseif result and result.Instance:IsA("BasePart") then
					local triId = mMesh.getPartTriangle(result.Instance :: BasePart)
					if triId then
						newHoverTriangles = { triId }
					end
				end
			end
			if mode == "Add" and not mAddBoundaryEdge then
				-- Phase 1: hover boundary edges only
				newHoverEdge = findNearestBoundaryEdge(worldPos)
			end
		end

		-- Add mode phase 2 runs even without a raycast hit (plane projection)
		if currentSettings.Mode == "Add" and mAddBoundaryEdge then
			local camera = workspace.CurrentCamera
			if camera then
				local mouseLocation = UserInputService:GetMouseLocation()
				local mouseScreenPos = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
				-- Use screen pos from the viewport ray origin projected to screen
				local mouseScreen = Vector3.new(mouseLocation.X, mouseLocation.Y, 0)

				-- Tier 1: vertex snap (15px screen radius)
				local skipVids = { [mAddBoundaryEdge.v1] = true, [mAddBoundaryEdge.v2] = true }
				local bestVid: number? = nil
				local bestVidDist = 15
				for id, vertex in mMesh.getVertices() do
					if skipVids[id] then continue end
					local screenPos, onScreen = camera:WorldToScreenPoint(vertex.position)
					if onScreen then
						local dx = screenPos.X - mouseScreen.X
						local dy = screenPos.Y - mouseScreen.Y
						local dist = math.sqrt(dx * dx + dy * dy)
						if dist < bestVidDist then
							bestVidDist = dist
							bestVid = id
						end
					end
				end

				if bestVid then
					newHoverVertex = bestVid
					mAddHoverTarget = { type = "vertex", vertexId = bestVid }
				else
					-- Tier 2: edge snap (15px screen radius, boundary only)
					local storedKey = tostring(math.min(mAddBoundaryEdge.v1, mAddBoundaryEdge.v2))
						.. "_" .. tostring(math.max(mAddBoundaryEdge.v1, mAddBoundaryEdge.v2))
					local bestEdgeKey: string? = nil
					local bestEdgeDist = 15
					for key, edge in mMesh.getEdges() do
						if #edge.triangles ~= 1 then continue end
						if key == storedKey then continue end
						local v1 = mMesh.getVertex(edge.v1)
						local v2 = mMesh.getVertex(edge.v2)
						if not v1 or not v2 then continue end
						local s1, on1 = camera:WorldToScreenPoint(v1.position)
						local s2, on2 = camera:WorldToScreenPoint(v2.position)
						if not on1 or not on2 then continue end
						local bx, by = s2.X - s1.X, s2.Y - s1.Y
						local lenSq = bx * bx + by * by
						if lenSq < 0.001 then continue end
						local px = mouseScreen.X - s1.X
						local py = mouseScreen.Y - s1.Y
						local t = math.clamp((px * bx + py * by) / lenSq, 0, 1)
						local closestX = s1.X + t * bx
						local closestY = s1.Y + t * by
						local dist = math.sqrt((mouseScreen.X - closestX) ^ 2 + (mouseScreen.Y - closestY) ^ 2)
						if dist < bestEdgeDist then
							bestEdgeDist = dist
							bestEdgeKey = key
						end
					end

					if bestEdgeKey then
						newHoverEdge = bestEdgeKey
						mAddHoverTarget = { type = "edge", edgeKey = bestEdgeKey }
					elseif mAddPlanePoint and mAddPlaneNormal then
						-- Tier 3: plane projection
						local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
						local denom = ray.Direction:Dot(mAddPlaneNormal)
						if math.abs(denom) > 0.0001 then
							local hitT = (mAddPlanePoint - ray.Origin):Dot(mAddPlaneNormal) / denom
							if hitT > 0 then
								mAddHoverTarget = { type = "plane", position = ray.Origin + ray.Direction * hitT }
							end
						end
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

	local function handleSelectClick(worldPos: Vector3)
		mMesh.discoverRegion(worldPos, 15)
		local vid = findNearestVertex(worldPos)
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

	local function handleAddClick(worldPos: Vector3)
		mMesh.discoverRegion(worldPos, 15)
		if not mAddBoundaryEdge then
			-- Phase 1: select a boundary edge
			local edgeKey = findNearestBoundaryEdge(worldPos)
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
				if target.type == "vertex" and target.vertexId then
					local tv = mMesh.getVertex(target.vertexId)
					if tv then
						mMesh.addTriangle(
							v1.position, v2.position, tv.position,
							currentSettings.Thickness, workspace.Terrain, addProps
						)
					end
				elseif target.type == "edge" and target.edgeKey then
					local targetEdge = mMesh.getEdges()[target.edgeKey]
					if targetEdge then
						local tv1 = mMesh.getVertex(targetEdge.v1)
						local tv2 = mMesh.getVertex(targetEdge.v2)
						if tv1 and tv2 then
							mMesh.addTriangle(
								v1.position, v2.position, tv1.position,
								currentSettings.Thickness, workspace.Terrain, addProps
							)
							mMesh.addTriangle(
								v2.position, tv2.position, tv1.position,
								currentSettings.Thickness, workspace.Terrain, addProps
							)
						end
					end
				elseif target.type == "plane" and target.position then
					mMesh.addTriangle(
						v1.position, v2.position, target.position,
						currentSettings.Thickness, workspace.Terrain, addProps
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
	local function getStrokeWorldPos(): Vector3?
		local result = mouseRaycast()
		if result then
			mStrokePlanePoint = result.Position
			mStrokePlaneNormal = result.Normal
			return result.Position
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
						return ray.Origin + ray.Direction * t
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
			worldPos = getStrokeWorldPos()
		end
		if not worldPos then return end

		if currentSettings.DeleteTarget == "Vertex" then
			mMesh.discoverRegion(worldPos, 15)
			local vid = findNearestVertex(worldPos)
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
		else
			-- Face mode
			local radius = currentSettings.DeleteRadius
			local toRemove: { number }
			if radius > 0 then
				mMesh.discoverRegion(worldPos, radius + 5)
				toRemove = mMesh.findTrianglesInRadius(worldPos, radius)
			else
				-- Zero radius: use exact part mapping (no plane fallback)
				if result and result.Instance:IsA("BasePart") then
					local triId = mMesh.getPartTriangle(result.Instance :: BasePart)
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
			local c = currentSettings.PaintColor
			local color = Color3.new(c[1], c[2], c[3])
			local mat = (Enum.Material :: any)[currentSettings.PaintMaterial]

			-- Collect all parts to paint
			local partsToPaint: { BasePart } = { result.Instance :: BasePart }
			local radius = currentSettings.PaintRadius
			if radius > 0 then
				mMesh.discoverRegion(result.Position, radius + 5)
				for _, nearTriId in mMesh.findTrianglesInRadius(result.Position, radius) do
					local tri = mMesh.getTriangle(nearTriId)
					if tri then
						for _, part in tri.parts do
							table.insert(partsToPaint, part)
						end
					end
				end
			end

			for _, part in partsToPaint do
				part.Color = color
				if mat then
					part.Material = mat
				end
			end
			changeSignal:Fire()
		end
	end

	local function startStroke()
		local mode = currentSettings.Mode
		if mode == "Delete" then
			pushUndoSnapshot()
			mStrokeRecording = ChangeHistoryService:TryBeginRecording("PolyMap Delete")
		elseif mode == "Paint" then
			mStrokeRecording = ChangeHistoryService:TryBeginRecording("PolyMap Paint")
		end
		mStrokeDragging = true
	end

	local function applyStrokeAtCursor()
		local mode = currentSettings.Mode
		if mode == "Delete" then
			applyDeleteAtCursor()
		elseif mode == "Paint" then
			applyPaintAtCursor()
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
	end

	local function handleClick()
		if mIsOverUI or mIsDraggingHandle then
			return
		end

		local result = mouseRaycast()
		if not result then
			local mode = currentSettings.Mode
			if (mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify") and not isShiftHeld() then
				mSelectedVertices = {}
				changeSignal:Fire()
			end
			if mode == "Add" then
				if mAddBoundaryEdge and mAddHoverTarget then
					-- Phase 2 with a hover target (e.g., plane) — proceed
					handleAddClick(Vector3.zero) -- worldPos unused, target comes from mAddHoverTarget
				elseif mAddBoundaryEdge then
					clearAddState()
					changeSignal:Fire()
				end
			end
			return
		end

		local mode = currentSettings.Mode
		if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify" then
			handleSelectClick(result.Position)
		elseif mode == "Add" then
			handleAddClick(result.Position)
		elseif mode == "Delete" or mode == "Paint" then
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
			mMesh.discoverRegion(centerHit.Position, halfDiag + 10)
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

		-- Discover nearby geometry so unselected vertices within influence are found
		for _, origPos in mSavedVertexPositions do
			mMesh.discoverRegion(origPos, radius + 5)
		end

		for vid, vertex in mMesh.getVertices() do
			if mSelectedVertices[vid] then
				continue
			end

			-- Find minimum X/Z distance to any selected vertex
			local minDist = math.huge
			for _, origPos in mSavedVertexPositions do
				local delta = vertex.position - origPos
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
						position = vertex.position,
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
		if #mUndoSelections > 0 then
			restoreSelectionFromPositions(table.remove(mUndoSelections))
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
		if #mRedoSelections > 0 then
			restoreSelectionFromPositions(table.remove(mRedoSelections))
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
	-- During a drag, uses saved positions to prevent flicker.
	local function getExpandedTriangleIds(seedVids: { [number]: boolean }): { number }
		if not next(seedVids) then
			return {}
		end

		local radius = currentSettings.InfluenceRadius
		local affectedVids: { [number]: boolean } = {}
		for vid in seedVids do
			affectedVids[vid] = true
		end

		if radius > 0 then
			-- Get seed positions (use saved positions during drags)
			local seedPositions: { Vector3 } = {}
			if mIsDraggingHandle and next(mSavedVertexPositions) then
				for vid in seedVids do
					local pos = mSavedVertexPositions[vid]
					if pos then
						table.insert(seedPositions, pos)
					end
				end
			else
				for vid in seedVids do
					local v = mMesh.getVertex(vid)
					if v then
						table.insert(seedPositions, v.position)
					end
				end
			end

			-- Expand by influence radius
			for vid, vertex in mMesh.getVertices() do
				if not affectedVids[vid] then
					for _, selPos in seedPositions do
						local delta = vertex.position - selPos
						if Vector3.new(delta.X, 0, delta.Z).Magnitude < radius then
							affectedVids[vid] = true
							break
						end
					end
				end
			end
		end

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
		if mode == "Delete" or mode == "Paint" then
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
	session.ScanMesh = function()
		scanMesh()
	end
	session.SelectAll = function()
		for id in mMesh.getVertices() do
			mSelectedVertices[id] = true
		end
		changeSignal:Fire()
	end
	session.ClearSelection = function()
		mSelectedVertices = {}
		changeSignal:Fire()
	end
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
		mMesh.discoverRegion(origin.Position, gridExtent)
		changeSignal:Fire()
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

		-- Snapshot each triangle
		local snapshots: { { positions: { Vector3 }, color: Color3, material: Enum.Material } } = {}
		for triId in affectedTriIds do
			local tri = mMesh.getTriangle(triId)
			if tri then
				local positions: { Vector3 } = {}
				for _, vid in tri.vertices do
					local v = mMesh.getVertex(vid)
					if v then
						table.insert(positions, v.position)
					end
				end
				if #positions == 3 then
					local part = tri.parts[1]
					table.insert(snapshots, {
						positions = positions,
						color = part.Color,
						material = part.Material,
					})
				end
			end
		end

		-- Remove all affected triangles
		for triId in affectedTriIds do
			mMesh.removeTriangle(triId)
		end

		-- Add subdivided triangles (4 per original)
		local newMidpoints: { Vector3 } = {}
		for _, snap in snapshots do
			local a, b, c = snap.positions[1], snap.positions[2], snap.positions[3]
			local mab = (a + b) / 2
			local mbc = (b + c) / 2
			local mca = (c + a) / 2

			table.insert(newMidpoints, mab)
			table.insert(newMidpoints, mbc)
			table.insert(newMidpoints, mca)

			local props: fillTriangle.TriangleProps = {
				Color = snap.color,
				Material = snap.material,
			}
			mMesh.addTriangle(a, mab, mca, currentSettings.Thickness, workspace.Terrain, props)
			mMesh.addTriangle(mab, b, mbc, currentSettings.Thickness, workspace.Terrain, props)
			mMesh.addTriangle(mca, mbc, c, currentSettings.Thickness, workspace.Terrain, props)
			mMesh.addTriangle(mab, mbc, mca, currentSettings.Thickness, workspace.Terrain, props)
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
			local snapshots: { { positions: { Vector3 }, color: Color3, material: Enum.Material } } = {}
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
						table.insert(snapshots, {
							positions = positions,
							color = part.Color,
							material = part.Material,
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
					currentSettings.Thickness, workspace.Terrain, props
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
