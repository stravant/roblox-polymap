local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)

local Colors = require(DraggerFramework.Utility.Colors)
local Math = require(DraggerFramework.Utility.Math)
local roundRotation = require(DraggerFramework.Utility.roundRotation)

local PartialRotateHandleView = require(script.Parent.PartialRotateHandleView)
local RotateHandleView = require(DraggerFramework.Components.RotateHandleView)

local getEngineFeatureModelPivotVisual = require(DraggerFramework.Flags.getEngineFeatureModelPivotVisual)

local MIN_ROTATE_INCREMENT = 5.0

-- Shrinks the Y ring relative to the base handle radius (4.5). Negative so the Y
-- ring reads as the inner control sitting inside the larger X/Z arcs.
local Y_RING_RADIUS_OFFSET = -1.5

local RIGHT_ANGLE = math.pi / 2
local RIGHT_ANGLE_EXACT_THRESHOLD = 0.001

local RotateHandles = {}
RotateHandles.__index = RotateHandles

local RotateHandleDefinitions = {
	XAxis = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1)),
		Color = Colors.X_AXIS,
		RadiusOffset = 0.00,
		View = PartialRotateHandleView,
		AngleOffset = math.rad(90),
		LocalAxis = Vector3.xAxis,
	},
	-- Y is the primary heading rotation: a full ring, drawn smaller so it reads as
	-- the inner control inside the X/Z arcs.
	YAxis = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0)),
		Color = Colors.Y_AXIS,
		RadiusOffset = Y_RING_RADIUS_OFFSET,
		View = RotateHandleView,
		AngleOffset = 0,
		LocalAxis = Vector3.yAxis,
	},
	ZAxis = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0)),
		Color = Colors.Z_AXIS,
		RadiusOffset = 0.02,
		View = PartialRotateHandleView,
		AngleOffset = math.rad(90),
		LocalAxis = Vector3.zAxis,
	},
}

local function isRightAngle(angleDelta)
	local snappedTo90 = math.floor((angleDelta / RIGHT_ANGLE) + 0.5) * RIGHT_ANGLE
	return math.abs(snappedTo90 - angleDelta) < RIGHT_ANGLE_EXACT_THRESHOLD
end

local function getRotationTransform(mainCFrame, axisVector, delta, rotateIncrement)
	local localAxis = mainCFrame:VectorToObjectSpace(axisVector)
	local rotationCFrame = CFrame.fromAxisAngle(localAxis, delta)

	if rotateIncrement > 0 and isRightAngle(delta) then
		rotationCFrame = roundRotation(rotationCFrame)
	end

	return mainCFrame * rotationCFrame * mainCFrame:Inverse()
end

local function rotationAngleFromRay(cframe, unitRay)
	local t = Math.intersectRayPlane(unitRay.Origin, unitRay.Direction, cframe.Position, cframe.RightVector)
	if t >= 0 then
		local mouseWorld = unitRay.Origin + unitRay.Direction * t
		local direction = (mouseWorld - cframe.Position).Unit
		local rx = cframe.LookVector:Dot(direction)
		local ry = cframe.UpVector:Dot(direction)

		local theta = math.atan2(ry, rx)
		if theta < 0 then
			return 2 * math.pi + theta
		else
			return theta
		end
	end
	return nil
end

local function snapToRotateIncrementIfNeeded(angle, rotateIncrement)
	if rotateIncrement > 0 then
		local angleIncrement = math.rad(rotateIncrement)
		local snappedAngle = math.floor(angle / angleIncrement + 0.5) * angleIncrement
		local deltaFromCompleteRotation = math.abs(angle - math.pi * 2)
		local deltaFromSnapPoint = math.abs(angle - snappedAngle)
		if deltaFromCompleteRotation < deltaFromSnapPoint then
			return 0
		else
			return snappedAngle
		end
	else
		return angle
	end
end

function RotateHandles.new(draggerContext, props)
	local self = {}
	self._draggerContext = draggerContext
	self._handles = {}
	self._props = props
	return setmetatable(self, RotateHandles)
end

function RotateHandles:update(draggerToolModel, selectionInfo)
	if not self._draggingHandleId then
		local cframe, offset, size = self._props.GetBoundingBox()
		self._boundingBox = {
			Size = size,
			CFrame = cframe * CFrame.new(offset),
		}
		self._basisOffset = CFrame.new(-offset)
		self._selectionInfo = selectionInfo
		self._schema = draggerToolModel:getSchema()
		if getEngineFeatureModelPivotVisual() then
			self._scale = self._draggerContext:getHandleScale((self._boundingBox.CFrame * self._basisOffset).Position)
		else
			self._scale = self._draggerContext:getHandleScale(self._boundingBox.CFrame.Position)
		end
	end
	self:_updateHandles()
end

function RotateHandles:shouldBiasTowardsObjects()
	return false
end

function RotateHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestHandleDistance = nil, math.huge
	for handleId, handleProps in pairs(self._handles) do
		local distance = handleProps.View.hitTest(handleProps, mouseRay)
		if distance and distance < closestHandleDistance then
			closestHandleDistance = distance
			closestHandleId = handleId
		end
	end

	local alwaysOnTop = true
	return closestHandleId, closestHandleDistance, alwaysOnTop
end

function RotateHandles:render(hoveredHandleId)
	local children = {}

	local increment = self._draggerContext:getRotateIncrement()
	local tickAngle
	if increment >= MIN_ROTATE_INCREMENT then
		tickAngle = math.rad(increment)
	end

	if self._draggingHandleId and self._handles[self._draggingHandleId] then
		local handleProps = self._handles[self._draggingHandleId]
		local HALF_PI = math.pi / 2
		local snapStartAngle = math.floor(self._startAngle / HALF_PI + 0.5) * HALF_PI
		local startAngle = snapStartAngle - self._draggingLastGoodDelta
		local endAngle = snapStartAngle
		children[self._draggingHandleId] = Roact.createElement(handleProps.View, {
			HandleCFrame = handleProps.HandleCFrame,
			Color = handleProps.Color,
			AngleOffset = handleProps.AngleOffset,
			StartAngle = startAngle,
			EndAngle = endAngle,
			Scale = handleProps.Scale,
			Hovered = false,
			RadiusOffset = handleProps.RadiusOffset,
			TickAngle = tickAngle,
		})
	else
		for handleId, handleProps in pairs(self._handles) do
			local color = handleProps.Color
			local hovered = (handleId == hoveredHandleId)
			local tickAngleToUse
			if hovered then
				tickAngleToUse = tickAngle
			else
				color = Colors.makeDimmed(color)
			end
			children[handleId] = Roact.createElement(handleProps.View, {
				HandleCFrame = handleProps.HandleCFrame,
				Color = color,
				Scale = handleProps.Scale,
				Hovered = hovered,
				RadiusOffset = handleProps.RadiusOffset,
				TickAngle = tickAngleToUse,
				AngleOffset = handleProps.AngleOffset,
			})
		end
	end

	return Roact.createElement("Folder", {}, children)
end

function RotateHandles:mouseDown(mouseRay, handleId)
	if not self._handles[handleId] then
		return
	end

	local handleCFrame
	if getEngineFeatureModelPivotVisual() then
		handleCFrame = self._handles[handleId].HandleCFrame
	else
		local offset = RotateHandleDefinitions[handleId].Offset
		handleCFrame = self._boundingBox.CFrame * offset
	end
	local angle = rotationAngleFromRay(handleCFrame, mouseRay.Unit)
	if not angle then
		return
	end

	self._draggingHandleId = handleId
	self._handleCFrame = handleCFrame
	self._lastGlobalTransformForRender = CFrame.new()
	self._draggingLastGoodDelta = 0
	self._originalBoundingBoxCFrame = self._boundingBox.CFrame
	self._startAngle = snapToRotateIncrementIfNeeded(
		angle, self._draggerContext:getRotateIncrement())

	self._props.StartTransform()
end

function RotateHandles:mouseDrag(mouseRay)
	if not self._handles[self._draggingHandleId] then
		return
	end

	local angle = rotationAngleFromRay(self._handleCFrame, mouseRay.Unit)
	if not angle then
		return
	end
	local snappedAngle =
		snapToRotateIncrementIfNeeded(angle, self._draggerContext:getRotateIncrement())

	local snappedDelta = snappedAngle - self._startAngle
	local candidateGlobalTransform = getRotationTransform(
		self._handleCFrame,
		self._handleCFrame.RightVector,
		snappedDelta,
		self._draggerContext:getRotateIncrement())

	self._boundingBox.CFrame = candidateGlobalTransform * self._originalBoundingBoxCFrame

	local localRotation = self._originalBoundingBoxCFrame:ToObjectSpace(self._boundingBox.CFrame)
	self._props.ApplyTransform(localRotation)

	self._lastGlobalTransformForRender = candidateGlobalTransform

	local rotatedAxis = candidateGlobalTransform:VectorToObjectSpace(self._handleCFrame.LookVector)
	local ry = self._handleCFrame.UpVector:Dot(rotatedAxis)
	local rx = self._handleCFrame.LookVector:Dot(rotatedAxis)
	self._draggingLastGoodDelta = -math.atan2(ry, rx)
end

function RotateHandles:mouseUp(mouseRay)
	if not self._draggingHandleId then
		return
	end

	self._draggingHandleId = nil
	self._schema.addUndoWaypoint(self._draggerContext, "Axis Rotate Selection")
	self._props.EndTransform()
end

function RotateHandles:_updateHandles()
	if self._selectionInfo:isEmpty() or (self._props.Visible and not self._props.Visible()) then
		self._handles = {}
	else
		for handleId, handleDefinition in pairs(RotateHandleDefinitions) do
			self._handles[handleId] = {
				HandleCFrame =
					self._boundingBox.CFrame *
					self._basisOffset * handleDefinition.Offset,
				Color = handleDefinition.Color,
				RadiusOffset = handleDefinition.RadiusOffset,
				Scale = self._scale,
				View = handleDefinition.View,
				AngleOffset = handleDefinition.AngleOffset,
			}
		end
	end
end

return RotateHandles
