--!strict
local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)

local Colors = require("./Colors")
local ChipForToggle = require("./ChipForToggle")
local OverlayGui = require("./OverlayGui")

local e = React.createElement

-- All available materials with display labels
local kAllMaterials: { { name: string, label: string } } = {
	{ name = "Grass", label = "Grass" },
	{ name = "LeafyGrass", label = "Leafy Grass" },
	{ name = "Ground", label = "Ground" },
	{ name = "Sand", label = "Sand" },
	{ name = "Mud", label = "Mud" },
	{ name = "Rock", label = "Rock" },
	{ name = "Slate", label = "Slate" },
	{ name = "Basalt", label = "Basalt" },
	{ name = "Limestone", label = "Limestone" },
	{ name = "Sandstone", label = "Sandstone" },
	{ name = "Cobblestone", label = "Cobblestone" },
	{ name = "Brick", label = "Brick" },
	{ name = "Concrete", label = "Concrete" },
	{ name = "Asphalt", label = "Asphalt" },
	{ name = "Pavement", label = "Pavement" },
	{ name = "Plastic", label = "Plastic" },
	{ name = "SmoothPlastic", label = "Smooth Plastic" },
	{ name = "Ice", label = "Ice" },
	{ name = "Snow", label = "Snow" },
	{ name = "Neon", label = "Neon" },
	{ name = "Wood", label = "Wood" },
}

local kMaterialLabelMap: { [string]: string } = {}
for _, mat in kAllMaterials do
	kMaterialLabelMap[mat.name] = mat.label
end

local kMaxRecent = 4

local function getLabelForMaterial(name: string): string
	return kMaterialLabelMap[name] or name
end

-- The popup content that appears in the overlay
local function MaterialPopupContent(props: {
	Current: string,
	OnSelect: (name: string) -> (),
})
	local children: { [string]: React.ReactElement<any, any> } = {
		ListLayout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 1),
		}),
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
		}),
	}

	for i, mat in kAllMaterials do
		local isCurrent = props.Current == mat.name
		children[mat.name] = e("TextButton", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundColor3 = if isCurrent then Colors.ACTION_BLUE else Colors.GREY,
			BackgroundTransparency = if isCurrent then 0 else 0.3,
			BorderSizePixel = 0,
			Text = mat.label,
			Font = if isCurrent then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
			TextSize = 18,
			TextColor3 = Colors.WHITE,
			TextXAlignment = Enum.TextXAlignment.Left,
			AutoButtonColor = true,
			LayoutOrder = i,
			ZIndex = 12,
			[React.Event.MouseButton1Click] = function()
				props.OnSelect(mat.name)
			end,
		}, {
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
			}),
		})
	end

	return e("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, math.min(#kAllMaterials * 23 + 8, 200)),
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.BLACK,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.OFFWHITE,
		ZIndex = 12,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
		Stroke = e("UIStroke", {
			Color = Colors.OFFWHITE,
			Thickness = 1,
		}),
		Content = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			ZIndex = 12,
		}, children),
	})
end

local function MaterialDropdown(props: {
	Current: string,
	RecentMaterials: { string },
	OnSelect: (name: string) -> (),
	LayoutOrder: number?,
})
	local overlayContext = OverlayGui.use()
	local triggerRef = React.useRef(nil)

	local function openDropdown()
		if triggerRef.current then
			overlayContext.SetOverlay(triggerRef.current, e(MaterialPopupContent, {
				Current = props.Current,
				OnSelect = function(name: string)
					overlayContext.SetOverlay(nil)
					props.OnSelect(name)
				end,
			}))
		end
	end

	-- Build the recent chips: current material first, then recents (deduped), capped at kMaxRecent
	local shownMaterials: { string } = { props.Current }
	local shownSet: { [string]: boolean } = { [props.Current] = true }
	for _, name in props.RecentMaterials do
		if #shownMaterials >= kMaxRecent then
			break
		end
		if not shownSet[name] then
			table.insert(shownMaterials, name)
			shownSet[name] = true
		end
	end

	local chipChildren: { [string]: React.ReactElement<any, any> } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	}

	for i, name in shownMaterials do
		chipChildren[name] = e(ChipForToggle, {
			Text = getLabelForMaterial(name),
			IsCurrent = name == props.Current,
			LayoutOrder = i,
			OnClick = function()
				props.OnSelect(name)
			end,
		})
	end

	-- Dropdown trigger button
	chipChildren.DropdownTrigger = e("TextButton", {
		Size = UDim2.new(0, 28, 0, 24),
		BackgroundColor3 = Colors.ACTION_BLUE,
		Text = "...",
		Font = Enum.Font.SourceSansBold,
		TextSize = 18,
		TextColor3 = Colors.WHITE,
		AutoButtonColor = true,
		LayoutOrder = kMaxRecent + 1,
		ref = triggerRef,
		[React.Event.MouseButton1Click] = openDropdown,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	})

	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, chipChildren)
end

return MaterialDropdown
