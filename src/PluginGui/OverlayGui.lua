--!strict
local UserInputService = game:GetService("UserInputService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)

local e = React.createElement

export type OverlayContext = {
	Overlay: {
		Source: Instance,
		Content: React.ReactElement<any, any>,
	}?,
	SetOverlay: (source: Instance?, content: React.ReactElement<any, any>?) -> (),
}

local OverlayContext = React.createContext((nil :: any) :: OverlayContext)

local OverlayGui = {}

function OverlayGui.use(): OverlayContext
	return React.useContext(OverlayContext)
end

function OverlayGui.Provider(props: {
	children: React.ReactElement<any, any>?,
})
	local overlay, setOverlay = React.useState(nil)

	local contextValue = React.useMemo(function()
		return {
			Overlay = overlay,
			SetOverlay = function(source: Instance?, element: React.ReactElement<any, any>?)
				if source == nil and element == nil then
					setOverlay(nil)
				else
					assert(source and element, "Should not have any one of source / element")
					setOverlay({
						Source = source,
						Content = element,
					} :: any)
				end
			end,
		}
	end, {
		overlay,
		setOverlay,
	} :: { any })

	return e(OverlayContext.Provider, {
		value = contextValue,
	}, props.children)
end

function OverlayGui.Display(_props: {})
	local overlayContext = OverlayGui.use()
	local frameRef = React.useRef(nil)

	-- Close the popup on Escape (mirrors the click-outside backdrop). The listener
	-- only exists while a popup is open.
	local hasOverlay = overlayContext.Overlay ~= nil
	local setOverlay = overlayContext.SetOverlay
	React.useEffect(function()
		if not hasOverlay then
			return
		end
		local conn = UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.KeyCode == Enum.KeyCode.Escape then
				setOverlay(nil)
			end
		end)
		return function()
			conn:Disconnect()
		end
	end, { hasOverlay, setOverlay } :: { any })

	if not overlayContext.Overlay then
		return e("Frame", {
			Size = UDim2.fromScale(1, 0),
			BackgroundTransparency = 1,
			ref = frameRef,
		})
	end

	-- Position overlay below the source element
	local offset = UDim2.new(0, 0, 0, 0)
	if frameRef.current and overlayContext.Overlay.Source then
		local source = overlayContext.Overlay.Source
		assert(source:IsA("GuiObject"))
		local offsetY = source.AbsolutePosition.Y + source.AbsoluteSize.Y - frameRef.current.AbsolutePosition.Y
		offset = UDim2.new(0, 0, 0, offsetY)
	end

	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		ZIndex = 10,
		ref = frameRef,
	}, {
		-- Invisible backdrop to catch clicks outside the overlay
		Backdrop = e("TextButton", {
			Text = "",
			Size = UDim2.new(1, 0, 0, 10000),
			Position = UDim2.new(0, 0, 0, -5000),
			BackgroundTransparency = 1,
			ZIndex = 10,
			[React.Event.MouseButton1Click] = function()
				overlayContext.SetOverlay(nil)
			end,
		}),
		Content = e("Frame", {
			Position = offset,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			ZIndex = 11,
		}, {
			Content = overlayContext.Overlay.Content,
		}),
	})
end

return OverlayGui
