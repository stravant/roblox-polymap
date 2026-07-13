--!strict

local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local Colors = require("./PluginGui/Colors")

local e = React.createElement

local kToastWidth = 460
local kSlideInSeconds = 0.35

-- Toast shown at the bottom of the viewport when another user makes a PolyMap
-- edit while Multiuser Support is off: the in-memory mesh can't self-heal, so
-- the discovered data may no longer match the world. Portalled into its own
-- ScreenGui so it sits over the viewport whether the plugin UI is floating or
-- docked into a panel. Slides up from below the viewport edge on mount.
local function ConflictToast(props: {
	OnDismiss: () -> (),
})
	local frameRef = React.useRef(nil :: Frame?)

	React.useEffect(function()
		local frame = frameRef.current
		if frame then
			frame.Position = UDim2.new(0.5, 0, 1, 80)
			TweenService:Create(
				frame,
				TweenInfo.new(kSlideInSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Position = UDim2.new(0.5, 0, 1, -16) }
			):Play()
		end
		return function() end
	end, {})

	return ReactRoblox.createPortal(e("ScreenGui", {
		Name = "PolyMapConflictToast",
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, {
		Toast = e("Frame", {
			ref = frameRef,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 80),
			Size = UDim2.fromOffset(kToastWidth, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Colors.GREY,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 6),
			}),
			Stroke = e("UIStroke", {
				Color = Colors.WARNING_YELLOW,
				Thickness = 1,
				Transparency = 0.25,
			}),
			Padding = e("UIPadding", {
				PaddingTop = UDim.new(0, 10),
				PaddingBottom = UDim.new(0, 10),
				PaddingLeft = UDim.new(0, 12),
				PaddingRight = UDim.new(0, 34),
			}),
			Message = e("TextLabel", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				RichText = true,
				Text = "<b>PolyMap:</b> Another user is editing this place. Your discovered geometry"
					.. " may be out of date with their changes.<br />Reopen the plugin — or turn on"
					.. " <b>Multiuser support</b> in Settings — to work from fresh data.",
				TextColor3 = Colors.WHITE,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Font = Enum.Font.SourceSans,
				TextSize = 16,
			}),
			DismissButton = e("TextButton", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 26, 0, 0),
				Size = UDim2.fromOffset(20, 20),
				BackgroundTransparency = 1,
				Text = "×",
				TextColor3 = Colors.OFFWHITE,
				Font = Enum.Font.SourceSansBold,
				TextSize = 20,
				[React.Event.MouseButton1Click] = props.OnDismiss,
			}),
		}),
	}), CoreGui)
end

return ConflictToast
