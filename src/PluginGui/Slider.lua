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
		local track = trackRef.current
		if not track then return end
		local trackLeft = track.AbsolutePosition.X
		local trackWidth = track.AbsoluteSize.X
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

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 4),
		}),
		Label = props.Label and e("TextLabel", {
			Text = props.Label,
			TextColor3 = Colors.WHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 0, 0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Enum.Font.SourceSans,
			TextSize = 18,
			LayoutOrder = 1,
		}),
		Track = e("TextButton", {
			Text = "",
			Size = UDim2.new(0, 0, 0, 24),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			LayoutOrder = 2,
			ref = trackRef,
			[React.Event.MouseButton1Down] = function(_self: TextButton, x: number, _y: number)
				valueFromPosition(x)
				setDragging(true)
			end,
		}, {
			Flex = e("UIFlexItem", {
				FlexMode = Enum.UIFlexMode.Grow,
			}),
			TrackVisual = e("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 0, 0.5, 2),
				Size = UDim2.new(1, 0, 0, 8),
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
		}),
		ValueLabel = e("TextLabel", {
			Text = displayValue,
			TextColor3 = Colors.WHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 32, 0, 24),
			Font = Enum.Font.RobotoMono,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Right,
			LayoutOrder = 3,
		}),
	})
end

return Slider
