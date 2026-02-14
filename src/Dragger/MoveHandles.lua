local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)

local Colors = require(DraggerFramework.Utility.Colors)
local computeDraggedDistance = require(DraggerFramework.Utility.computeDraggedDistance)

local MoveHandleView = require(script.Parent.MoveHandleView)

local getEngineFeatureModelPivotVisual = require(DraggerFramework.Flags.getEngineFeatureModelPivotVisual)
local getFFlagFixDraggerMovingInWrongDirection = require(DraggerFramework.Flags.getFFlagFixDraggerMovingInWrongDirection)

local ALWAYS_ON_TOP = true

local MoveHandles = {}
MoveHandles.__index = MoveHandles

local MoveHandleDefinitions = {
	MinusZ = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0)),
		Color = Colors.Z_AXIS,
		LocalAxis = Vector3.zAxis,
	},
	PlusZ = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(1, 0, 0), Vector3.new(0, -1, 0)),
		Color = Colors.Z_AXIS,
		LocalAxis = Vector3.zAxis,
	},
	MinusY = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0)),
		Color = Colors.Y_AXIS,
		LocalAxis = Vector3.yAxis,
	},
	PlusY = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0)),
		Color = Colors.Y_AXIS,
		LocalAxis = Vector3.yAxis,
	},
	MinusX = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1)),
		Color = Colors.X_AXIS,
		LocalAxis = Vector3.xAxis,
	},
	PlusX = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 1, 0), Vector3.new(0, 0, -1)),
		Color = Colors.X_AXIS,
		LocalAxis = Vector3.xAxis,
	},
}

function MoveHandles.new(draggerContext, props)
	local self = {}
	self._handles = {}
	self._props = props
	self._draggerContext = draggerContext
	return setmetatable(self, MoveHandles)
end

function MoveHandles:update(draggerToolModel, selectionInfo)
	if not self._draggingHandleId then
		local cframe, offset, size = self._props.GetBoundingBox()
		self._basisOffset = CFrame.new(-offset)
		self._boundingBox = {
			Size = size,
			CFrame = cframe * CFrame.new(offset),
		}
		self._schema = draggerToolModel:getSchema()
		self._selectionInfo = selectionInfo
	end
	self:_updateHandles()
end

function MoveHandles:shouldBiasTowardsObjects()
	return false
end

function MoveHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestHandleDistance = nil, math.huge
	for handleId, handleProps in pairs(self._handles) do
		local distance = MoveHandleView.hitTest(handleProps, mouseRay)
		if distance and distance < closestHandleDistance then
			closestHandleDistance = distance
			closestHandleId = handleId
		end
	end
	return closestHandleId, closestHandleDistance, ALWAYS_ON_TOP
end

function MoveHandles:render(hoveredHandleId)
	local children = {}

	if self._draggingHandleId and self._handles[self._draggingHandleId] then
		local handleProps = self._handles[self._draggingHandleId]
		children[self._draggingHandleId] = Roact.createElement(MoveHandleView, {
			Axis = handleProps.Axis,
			Outset = handleProps.Outset,
			FixedOutset = handleProps.FixedOutset,
			Color = handleProps.Color,
			Scale = handleProps.Scale,
			AlwaysOnTop = ALWAYS_ON_TOP,
			Hovered = false,
		})
	else
		for handleId, handleProps in pairs(self._handles) do
			local color = handleProps.Color
			local hovered = (handleId == hoveredHandleId)
			if not hovered then
				color = Colors.makeDimmed(color)
			end
			children[handleId] = Roact.createElement(MoveHandleView, {
				Axis = handleProps.Axis,
				Outset = handleProps.Outset,
				FixedOutset = handleProps.FixedOutset,
				Color = color,
				Scale = handleProps.Scale,
				AlwaysOnTop = ALWAYS_ON_TOP,
				Hovered = hovered,
			})
		end
	end

	return Roact.createElement("Folder", {}, children)
end

function MoveHandles:mouseDown(mouseRay, handleId)
	self._draggingHandleId = handleId
	self._draggingOriginalBoundingBoxCFrame = self._boundingBox.CFrame

	local offset = MoveHandleDefinitions[handleId].Offset
	local axis = (self._boundingBox.CFrame * offset).LookVector
	self._axis = axis

	local hasDistance, distance = self:_getDistanceAlongAxis(mouseRay)
	if getFFlagFixDraggerMovingInWrongDirection() then
		self._startDistance = hasDistance and distance or 0.0
	else
		assert(hasDistance)
		self._startDistance = distance
	end

	self._props.StartTransform()
end

function MoveHandles:_getDistanceAlongAxis(mouseRay)
	if getFFlagFixDraggerMovingInWrongDirection() then
		local draggedFrame = self._draggingOriginalBoundingBoxCFrame
		if getEngineFeatureModelPivotVisual() then
			draggedFrame = draggedFrame * self._basisOffset
		end
		local dragStartPosition = draggedFrame.Position
		local dragDirection = self._axis.Unit
		return computeDraggedDistance(dragStartPosition, dragDirection, mouseRay)
	else
		if getEngineFeatureModelPivotVisual() then
			local Math = require(DraggerFramework.Utility.Math)
			return Math.intersectRayRay(
				(self._draggingOriginalBoundingBoxCFrame * self._basisOffset).Position, self._axis,
				mouseRay.Origin, mouseRay.Direction.Unit)
		else
			local Math = require(DraggerFramework.Utility.Math)
			return Math.intersectRayRay(
				self._draggingOriginalBoundingBoxCFrame.Position, self._axis,
				mouseRay.Origin, mouseRay.Direction.Unit)
		end
	end
end

function MoveHandles:mouseDrag(mouseRay)
	local hasDistance, distance = self:_getDistanceAlongAxis(mouseRay)
	if not hasDistance then
		return
	end

	if not self._handles[self._draggingHandleId] then
		return
	end

	local delta = distance - self._startDistance
	local snappedDelta = self._draggerContext:snapToGridSize(delta)

	local globalTransform = CFrame.new(self._axis * snappedDelta)

	self._boundingBox.CFrame = globalTransform * self._draggingOriginalBoundingBoxCFrame
	self._props.ApplyTransform(globalTransform)
end

function MoveHandles:mouseUp(mouseRay)
	self._draggingHandleId = nil
	self._schema.addUndoWaypoint(self._draggerContext, "Axis Move Selection")
	self._props.EndTransform()
end

function MoveHandles:_updateHandles()
	if self._selectionInfo:isEmpty() or (self._props.Visible and not self._props.Visible()) then
		self._handles = {}
	else
		for handleId, handleDef in MoveHandleDefinitions do
			local handleBaseCFrame =
				self._boundingBox.CFrame * self._basisOffset * handleDef.Offset
			self._handles[handleId] = {
				Outset = 0,
				FixedOutset = 0,
				Axis = handleBaseCFrame,
				Color = handleDef.Color,
				Scale = self._draggerContext:getHandleScale(handleBaseCFrame.Position),
				AlwaysOnTop = ALWAYS_ON_TOP,
				LocalAxis = handleDef.LocalAxis,
			}
		end
	end
end

return MoveHandles
