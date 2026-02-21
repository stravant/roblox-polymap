--!strict
local UserInputService = game:GetService("UserInputService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Colors = require("./Colors")

local function Slider(props: {
	Value: number,
	Min: number,
	Max: number,
	Step: number?,
	Label: string?,
	ValueChanged: (number) -> (),
	LayoutOrder: number?,
})
	local dragging, setDragging = React.useState(false)
	local trackRef = React.useRef(nil :: TextButton?)
	local trackVisualRef = React.useRef(nil :: Frame?)

	local min = props.Min
	local max = props.Max
	local step = props.Step
	local range = max - min

	local function clampAndStep(value: number): number
		if step and step > 0 then
			value = math.round((value - min) / step) * step + min
		end
		return math.clamp(value, min, max)
	end

	local function valueFromPosition(absX: number)
		local visual = trackVisualRef.current
		if not visual then return end
		local trackLeft = visual.AbsolutePosition.X
		local trackWidth = visual.AbsoluteSize.X
		if trackWidth <= 0 then return end
		local alpha = math.clamp((absX - trackLeft) / trackWidth, 0, 1)
		local newValue = clampAndStep(min + alpha * range)
		props.ValueChanged(newValue)
	end

	-- Track mouse movement while dragging
	React.useEffect(function()
		if not dragging then
			return
		end
		local moveConn = UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				valueFromPosition(input.Position.X)
			end
		end)
		local upConn = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setDragging(false)
			end
		end)
		return function()
			moveConn:Disconnect()
			upConn:Disconnect()
		end
	end, { dragging } :: { any })

	local alpha = if range > 0 then math.clamp((props.Value - min) / range, 0, 1) else 0
	local displayValue = string.format("%.2f", props.Value)

	local kHitOverlap = 10
	local labelWidth = if props.Label then 50 else 0
	local valueWidth = 36

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		ClipsDescendants = false,
	}, {
		Label = props.Label and e("TextLabel", {
			Text = props.Label,
			TextColor3 = Colors.WHITE,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.new(0, labelWidth, 1, 0),
			Font = Enum.Font.SourceSans,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		TrackVisual = e("Frame", {
			ref = trackVisualRef,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, labelWidth + 4, 0.5, 2),
			Size = UDim2.new(1, -(labelWidth + 4 + valueWidth + 4), 0, 8),
			BackgroundColor3 = Colors.GREY,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 4),
			}),
			Fill = e("Frame", {
				Size = UDim2.new(alpha, 0, 1, 0),
				BackgroundColor3 = Colors.ACTION_BLUE,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
			}),
			Thumb = e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(alpha, 0, 0.5, 0),
				Size = UDim2.fromOffset(12, 12),
				BackgroundColor3 = Colors.WHITE,
				ZIndex = 2,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0.5, 0),
				}),
			}),
		}),
		HitArea = e("TextButton", {
			Text = "",
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Position = UDim2.new(0, labelWidth + 4 - kHitOverlap, 0, 0),
			Size = UDim2.new(1, -(labelWidth + 4 + valueWidth + 4) + kHitOverlap * 2, 1, 0),
			ZIndex = 3,
			ref = trackRef,
			[React.Event.MouseButton1Down] = function(_self: TextButton, x: number, _y: number)
				valueFromPosition(x)
				setDragging(true)
			end,
		}),
		ValueLabel = e("TextLabel", {
			Text = displayValue,
			TextColor3 = Colors.WHITE,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0, valueWidth, 1, 0),
			Font = Enum.Font.RobotoMono,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	})
end

return Slider
