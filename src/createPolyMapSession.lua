--!strict

local CoreGui = game:GetService("CoreGui")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
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
	local mHoverTriangleId: number? = nil

	-- Add mode state
	local mAddBoundaryEdge: { v1: number, v2: number }? = nil

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

	local VERTEX_CLICK_RADIUS = 3.0 -- world-space radius to find vertex

	local function getTriangleProps(): fillTriangle.TriangleProps
		local c = currentSettings.PaintColor
		return {
			Color = Color3.new(c[1], c[2], c[3]),
			Material = (Enum.Material :: any)[currentSettings.PaintMaterial] or Enum.Material.Plastic,
		}
	end

	local function scanMesh()
		mMesh.scanWorkspace()
		mSelectedVertices = {}
		mHoverVertexId = nil
		mHoverEdgeKey = nil
		mAddBoundaryEdge = nil
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

	local function findNearestVertex(worldPos: Vector3): number?
		local camera = workspace.CurrentCamera
		if not camera then
			return mMesh.findVertexNear(worldPos, VERTEX_CLICK_RADIUS)
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestId: number? = nil
		local bestScreenDist = math.huge

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

	local function updateHover()
		if mIsOverUI or mIsDraggingHandle then
			if mHoverVertexId ~= nil or mHoverEdgeKey ~= nil then
				mHoverVertexId = nil
				mHoverEdgeKey = nil
				mHoverTriangleId = nil
				changeSignal:Fire()
			end
			return
		end

		local result = mouseRaycast()
		local newHoverVertex: number? = nil
		local newHoverEdge: string? = nil

		if result then
			-- Discover the part under the cursor (O(1) for already-tracked parts)
			if result.Instance:IsA("BasePart") then
				mMesh.discoverPart(result.Instance)
			end

			local mode = currentSettings.Mode
			if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Delete" then
				newHoverVertex = findNearestVertex(result.Position)
			end
			if mode == "Add" then
				if mAddBoundaryEdge then
					newHoverVertex = findNearestVertex(result.Position)
				else
					newHoverEdge = findNearestEdge(result.Position)
				end
			end
			if mode == "Paint" then
				-- TODO: hover triangle
			end
		end

		if newHoverVertex ~= mHoverVertexId or newHoverEdge ~= mHoverEdgeKey then
			mHoverVertexId = newHoverVertex
			mHoverEdgeKey = newHoverEdge
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
			local edgeKey = findNearestEdge(worldPos)
			if edgeKey then
				local edge = mMesh.getEdges()[edgeKey]
				if edge and #edge.triangles == 1 then
					mAddBoundaryEdge = { v1 = edge.v1, v2 = edge.v2 }
					changeSignal:Fire()
				end
			end
		else
			local recording = ChangeHistoryService:TryBeginRecording("PolyMap Add Triangle")

			local v1 = mMesh.getVertex(mAddBoundaryEdge.v1)
			local v2 = mMesh.getVertex(mAddBoundaryEdge.v2)
			if v1 and v2 then
				mMesh.addTriangle(
					v1.position, v2.position, worldPos,
					currentSettings.Thickness, workspace.Terrain, getTriangleProps()
				)
			end

			mAddBoundaryEdge = nil

			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
			changeSignal:Fire()
		end
	end

	local function handleDeleteClick(worldPos: Vector3)
		mMesh.discoverRegion(worldPos, 15)
		local vid = findNearestVertex(worldPos)
		if vid then
			local vertex = mMesh.getVertex(vid)
			if vertex then
				local recording = ChangeHistoryService:TryBeginRecording("PolyMap Delete")

				local triIds = table.clone(vertex.triangles)
				for _, triId in triIds do
					mMesh.removeTriangle(triId)
				end

				mSelectedVertices[vid] = nil

				if recording then
					ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
				end
				changeSignal:Fire()
			end
		end
	end

	local function handlePaintClick(worldPos: Vector3)
		local result = mouseRaycast()
		if result and result.Instance:IsA("BasePart") then
			local recording = ChangeHistoryService:TryBeginRecording("PolyMap Paint")

			local c = currentSettings.PaintColor
			result.Instance.Color = Color3.new(c[1], c[2], c[3])
			local mat = (Enum.Material :: any)[currentSettings.PaintMaterial]
			if mat then
				result.Instance.Material = mat
			end

			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
			changeSignal:Fire()
		end
	end

	local function handleClick()
		if mIsOverUI or mIsDraggingHandle then
			return
		end

		local result = mouseRaycast()
		if not result then
			if currentSettings.Mode == "Select" and not isShiftHeld() then
				mSelectedVertices = {}
				changeSignal:Fire()
			end
			if currentSettings.Mode == "Add" and mAddBoundaryEdge then
				mAddBoundaryEdge = nil
				changeSignal:Fire()
			end
			return
		end

		local mode = currentSettings.Mode
		if mode == "Select" or mode == "Move" or mode == "Rotate" then
			handleSelectClick(result.Position)
		elseif mode == "Add" then
			handleAddClick(result.Position)
		elseif mode == "Delete" then
			handleDeleteClick(result.Position)
		elseif mode == "Paint" then
			handlePaintClick(result.Position)
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

			-- Find minimum distance to any selected vertex
			local minDist = math.huge
			for _, origPos in mSavedVertexPositions do
				local dist = (vertex.position - origPos).Magnitude
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
			return currentSettings.Mode == "Move" and getSelectedVertexCount() > 0
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
			return currentSettings.Mode == "Rotate" and getSelectedVertexCount() > 0
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
				if mode == "Select" or mode == "Move" or mode == "Rotate" then
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
			end
		end)
	end)

	local cursorTargetTask = task.spawn(function()
		while true do
			updateHover()

			if mMarqueeStart then
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

	local function teardown()
		Roact.unmount(draggerHandle)
		inputChangedCn:Disconnect()
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
	session.GetMode = function(): string
		return currentSettings.Mode
	end
	session.GetAddBoundaryEdge = function(): { v1: number, v2: number }?
		return mAddBoundaryEdge
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

	return session
end

export type PolyMapSession = typeof(createPolyMapSession(...))

return createPolyMapSession
