--!strict

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local Settings = require("./Settings")
local createTriangleMesh = require("./TriangleMesh")
local fillTriangle = require("./fillTriangle")

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

local function worldToScreen(point: Vector3): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local screenPoint, onScreen = camera:WorldToScreenPoint(point)
	if onScreen then
		return screenPoint
	end
	return nil
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

	-- Input connections
	local mIsOverUI = false

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

	-- Initial scan
	scanMesh()

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
		-- Use screen-space distance for better UX
		local camera = workspace.CurrentCamera
		if not camera then
			return mMesh.findVertexNear(worldPos, VERTEX_CLICK_RADIUS)
		end

		local mouseScreen = camera:WorldToScreenPoint(worldPos)
		local bestId: number? = nil
		local bestScreenDist = 20 -- max pixel radius

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
		local bestDist = 15 -- max pixel radius for edge selection

		for key, edge in mMesh.getEdges() do
			local v1 = mMesh.getVertex(edge.v1)
			local v2 = mMesh.getVertex(edge.v2)
			if not v1 or not v2 then continue end

			local s1, on1 = camera:WorldToScreenPoint(v1.position)
			local s2, on2 = camera:WorldToScreenPoint(v2.position)
			if not on1 or not on2 then continue end

			-- Point-to-line-segment distance in screen space
			local ax, ay = s1.X - mouseScreen.X, s1.Y - mouseScreen.Y
			local bx, by = s2.X - s1.X, s2.Y - s1.Y
			local lenSq = bx * bx + by * by
			if lenSq < 0.001 then continue end
			local t = math.clamp((ax * bx + ay * by) / lenSq, 0, 1)
			-- Negate since ax/ay is from mouse to s1, but we want projection along s1->s2
			-- Actually: ax = s1-mouse, bx = s2-s1. We want dot((mouse-s1), (s2-s1)) / |s2-s1|^2
			local px = mouseScreen.X - s1.X
			local py = mouseScreen.Y - s1.Y
			t = math.clamp((px * bx + py * by) / lenSq, 0, 1)
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
		if mIsOverUI then
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
			local mode = currentSettings.Mode
			if mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Delete" then
				newHoverVertex = findNearestVertex(result.Position)
			end
			if mode == "Add" then
				if mAddBoundaryEdge then
					-- In second click of add mode, hover vertex for placement
					newHoverVertex = findNearestVertex(result.Position)
				else
					-- In first click, hover edges
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
		local vid = findNearestVertex(worldPos)
		if vid then
			if isShiftHeld() then
				-- Toggle selection
				if mSelectedVertices[vid] then
					mSelectedVertices[vid] = nil
				else
					mSelectedVertices[vid] = true
				end
			else
				-- Replace selection
				mSelectedVertices = { [vid] = true }
			end
		else
			-- Click on nothing -> clear selection
			if not isShiftHeld() then
				mSelectedVertices = {}
			end
		end
		changeSignal:Fire()
	end

	local function handleAddClick(worldPos: Vector3)
		if not mAddBoundaryEdge then
			-- First click: select a boundary edge
			local edgeKey = findNearestEdge(worldPos)
			if edgeKey then
				local edge = mMesh.getEdges()[edgeKey]
				if edge and #edge.triangles == 1 then
					mAddBoundaryEdge = { v1 = edge.v1, v2 = edge.v2 }
					changeSignal:Fire()
				end
			end
		else
			-- Second click: place vertex and create triangle
			local recording = ChangeHistoryService:TryBeginRecording("PolyMap Add Triangle")

			local v1 = mMesh.getVertex(mAddBoundaryEdge.v1)
			local v2 = mMesh.getVertex(mAddBoundaryEdge.v2)
			if v1 and v2 then
				mMesh.addTriangle(
					v1.position, v2.position, worldPos,
					currentSettings.Thickness, workspace, getTriangleProps()
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
		local vid = findNearestVertex(worldPos)
		if vid then
			local vertex = mMesh.getVertex(vid)
			if vertex then
				local recording = ChangeHistoryService:TryBeginRecording("PolyMap Delete")

				-- Remove all adjacent triangles
				local triIds = table.clone(vertex.triangles)
				for _, triId in triIds do
					mMesh.removeTriangle(triId)
				end

				-- Remove from selection
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
		if result and result.Instance:IsA("WedgePart") then
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
		if mIsOverUI then
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

		local minX = math.min(mMarqueeStart.X, mMarqueeEnd.X)
		local maxX = math.max(mMarqueeStart.X, mMarqueeEnd.X)
		local minY = math.min(mMarqueeStart.Y, mMarqueeEnd.Y)
		local maxY = math.max(mMarqueeStart.Y, mMarqueeEnd.Y)

		if not isShiftHeld() then
			mSelectedVertices = {}
		end

		for id, vertex in mMesh.getVertices() do
			local screenPos, onScreen = camera:WorldToScreenPoint(vertex.position)
			if onScreen and screenPos.X >= minX and screenPos.X <= maxX and
				screenPos.Y >= minY and screenPos.Y <= maxY then
				mSelectedVertices[id] = true
			end
		end

		changeSignal:Fire()
	end

	-- Input connections
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
				if mode == "Select" then
					-- Start potential marquee
					local mousePos = UserInputService:GetMouseLocation()
					mMarqueeStart = mousePos
					mMarqueeEnd = nil
				end
				handleClick()
			end
		end)

		inputEndedCn = UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if mMarqueeStart and mMarqueeEnd then
					handleMarqueeSelect()
				end
				mMarqueeStart = nil
				mMarqueeEnd = nil
			end
		end)
	end)

	local cursorTargetTask = task.spawn(function()
		while true do
			updateHover()

			-- Update marquee end position
			if mMarqueeStart then
				local mousePos = UserInputService:GetMouseLocation()
				local dist = (mousePos - mMarqueeStart).Magnitude
				if dist > 5 then
					mMarqueeEnd = mousePos
				end
			end

			task.wait()
		end
	end)

	local function teardown()
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

	-- Public API
	session.ChangeSignal = changeSignal
	session.Update = function()
		-- Settings may have changed, nothing to do currently
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
	session.MoveSelectedVertices = function(delta: Vector3)
		if getSelectedVertexCount() == 0 then
			return
		end

		local recording = ChangeHistoryService:TryBeginRecording("PolyMap Move")

		for vid in mSelectedVertices do
			local v = mMesh.getVertex(vid)
			if v then
				mMesh.moveVertex(vid, v.position + delta, currentSettings.Thickness, getTriangleProps())
			end
		end

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	return session
end

export type PolyMapSession = typeof(createPolyMapSession(...))

return createPolyMapSession
