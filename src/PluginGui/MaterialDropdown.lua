--!strict
local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)

local Colors = require("./Colors")
local ChipForToggle = require("./ChipForToggle")

local e = React.createElement

-- All available materials with display labels
local kAllMaterials: { { name: string, label: string } } = {
	{ name = "Grass", label = "Grass" },
	{ name = "LeafyGrass", label = "Leafy G." },
	{ name = "Ground", label = "Ground" },
	{ name = "Sand", label = "Sand" },
	{ name = "Mud", label = "Mud" },
	{ name = "Rock", label = "Rock" },
	{ name = "Slate", label = "Slate" },
	{ name = "Basalt", label = "Basalt" },
	{ name = "Limestone", label = "Limestone" },
	{ name = "Sandstone", label = "Sandstone" },
	{ name = "Cobblestone", label = "Cobble" },
	{ name = "Brick", label = "Brick" },
	{ name = "Concrete", label = "Concrete" },
	{ name = "Asphalt", label = "Asphalt" },
	{ name = "Pavement", label = "Pavement" },
	{ name = "Plastic", label = "Plastic" },
	{ name = "SmoothPlastic", label = "Smooth P." },
	{ name = "Ice", label = "Ice" },
	{ name = "Snow", label = "Snow" },
	{ name = "Neon", label = "Neon" },
	{ name = "Wood", label = "Wood" },
}

local kMaterialLabelMap: { [string]: string } = {}
for _, mat in kAllMaterials do
	kMaterialLabelMap[mat.name] = mat.label
end

local kMaxRecent = 6

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

local kChipsPerRow = 2

-- Recent material chips only (no overlay/"..." button)
local function MaterialRecentChips(props: {
	Current: string,
	RecentMaterials: { string },
	OnSelect: (name: string) -> (),
	LayoutOrder: number?,
})
	-- Build the recent chips (in stored order, highlight current)
	local shownMaterials: { string } = {}
	for _, name in props.RecentMaterials do
		if #shownMaterials >= kMaxRecent then
			break
		end
		table.insert(shownMaterials, name)
	end

	-- Split chips into rows of kChipsPerRow
	local rows: { { [string]: React.ReactElement<any, any> } } = {}
	for i, name in shownMaterials do
		local rowIndex = math.ceil(i / kChipsPerRow)
		if not rows[rowIndex] then
			rows[rowIndex] = {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
			}
		end
		rows[rowIndex][name] = e(ChipForToggle, {
			Text = getLabelForMaterial(name),
			IsCurrent = name == props.Current,
			LayoutOrder = ((i - 1) % kChipsPerRow) + 1,
			OnClick = function()
				props.OnSelect(name)
			end,
		})
	end

	-- Build the row frames
	local children: { [string]: React.ReactElement<any, any> } = {
		ListLayout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	}
	for rowIndex, rowChildren in rows do
		children[`Row{rowIndex}`] = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = rowIndex,
		}, rowChildren)
	end

	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, children)
end

return {
	RecentChips = MaterialRecentChips,
	PopupContent = MaterialPopupContent,
	GetLabel = getLabelForMaterial,
}
