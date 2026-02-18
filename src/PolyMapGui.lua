--!strict

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)

local Colors = require("./PluginGui/Colors")
local SubPanel = require("./PluginGui/SubPanel")
local PluginGui = require("./PluginGui/PluginGui")
local OperationButton = require("./PluginGui/OperationButton")
local ChipForToggle = require("./PluginGui/ChipForToggle")
local NumberInput = require("./PluginGui/NumberInput")
local HelpGui = require("./PluginGui/HelpGui")
local Settings = require("./Settings")
local PluginGuiTypes = require("./PluginGui/Types")
local MeshOverlay = require("./MeshOverlay")
local createPolyMapSession = require("./createPolyMapSession")

local e = React.createElement

local kColorPresets: { { Name: string, Color: { number } } } = {
	{ Name = "Grass", Color = { 0.30, 0.59, 0.30 } },
	{ Name = "Dirt", Color = { 0.55, 0.37, 0.22 } },
	{ Name = "Rock", Color = { 0.50, 0.50, 0.50 } },
	{ Name = "Sand", Color = { 0.84, 0.77, 0.55 } },
	{ Name = "Snow", Color = { 0.92, 0.92, 0.95 } },
	{ Name = "Water", Color = { 0.20, 0.45, 0.70 } },
	{ Name = "Forest", Color = { 0.15, 0.35, 0.15 } },
	{ Name = "Grey", Color = { 0.63, 0.63, 0.63 } },
}

local function createNextOrder()
	local order = 0
	return function()
		order += 1
		return order
	end
end

local function colorsMatch(a: { number }, b: { number }): boolean
	return math.abs(a[1] - b[1]) < 0.01
		and math.abs(a[2] - b[2]) < 0.01
		and math.abs(a[3] - b[3]) < 0.01
end

local function getStatusText(mode: string, settings: Settings.PolyMapSettings, session: createPolyMapSession.PolyMapSession?): string
	if not session then
		return ""
	end
	local count = session.GetSelectedVertexCount()
	if mode == "Select" then
		if count == 0 then
			return "Click vertices to select. Shift+click to toggle. Drag to marquee select."
		end
		return `{count} selected. Shift+click to toggle. Drag to marquee select.`
	elseif mode == "Move" then
		if count == 0 then
			return "Select vertices first, then drag the move handles."
		end
		return `{count} selected. Drag handles to move.`
	elseif mode == "Rotate" then
		if count == 0 then
			return "Select vertices first, then drag the rotation rings."
		end
		return `{count} selected. Drag rings to rotate.`
	elseif mode == "Add" then
		if session.GetAddBoundaryEdge() then
			return "Click to place the new triangle vertex."
		end
		return "Click a boundary edge to start adding a triangle."
	elseif mode == "Delete" then
		if settings.DeleteTarget == "Vertex" then
			return "Click a vertex to delete all its adjacent triangles."
		end
		return "Click a triangle to delete it."
	elseif mode == "Paint" then
		return "Click on triangles to apply color and material."
	elseif mode == "Generate" then
		return "Configure grid settings and click Generate."
	end
	return ""
end

local function StatusText(props: {
	Settings: Settings.PolyMapSettings,
	Session: createPolyMapSession.PolyMapSession?,
	LayoutOrder: number?,
})
	if not props.Settings.HaveHelp then
		return nil
	end
	local text = getStatusText(props.Settings.Mode, props.Settings, props.Session)
	if text == "" then
		return nil
	end
	return e("TextLabel", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0,
		BackgroundColor3 = Colors.GREY,
		BorderSizePixel = 0,
		Font = Enum.Font.SourceSans,
		TextSize = 18,
		TextColor3 = Colors.WHITE,
		RichText = true,
		Text = `<i>{text}</i>`,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = props.LayoutOrder,
	}, {
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 2),
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 4),
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	})
end

local function ModePanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local current = props.Settings.Mode
	return e(SubPanel, {
		Title = "Mode",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		Row1 = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 1,
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Select = e(ChipForToggle, {
				Text = "Select",
				IsCurrent = current == "Select",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.Mode = "Select"
					props.UpdatedSettings()
				end,
			}),
			Move = e(ChipForToggle, {
				Text = "Move",
				IsCurrent = current == "Move",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.Mode = "Move"
					props.UpdatedSettings()
				end,
			}),
			Rotate = e(ChipForToggle, {
				Text = "Rotate",
				IsCurrent = current == "Rotate",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.Mode = "Rotate"
					props.UpdatedSettings()
				end,
			}),
		}),
		Row2 = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Add = e(ChipForToggle, {
				Text = "Add",
				IsCurrent = current == "Add",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.Mode = "Add"
					props.UpdatedSettings()
				end,
			}),
			Delete = e(ChipForToggle, {
				Text = "Delete",
				IsCurrent = current == "Delete",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.Mode = "Delete"
					props.UpdatedSettings()
				end,
			}),
			Paint = e(ChipForToggle, {
				Text = "Paint",
				IsCurrent = current == "Paint",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.Mode = "Paint"
					props.UpdatedSettings()
				end,
			}),
			Generate = e(ChipForToggle, {
				Text = "Gen",
				IsCurrent = current == "Generate",
				LayoutOrder = 4,
				OnClick = function()
					props.Settings.Mode = "Generate"
					props.UpdatedSettings()
				end,
			}),
		}),
	})
end


local function GridPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	Session: createPolyMapSession.PolyMapSession?,
	LayoutOrder: number?,
})
	local currentType = props.Settings.GridType
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Generate Grid",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		TypeRow = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Square = e(ChipForToggle, {
				Text = "Square",
				IsCurrent = currentType == "Square",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.GridType = "Square"
					props.UpdatedSettings()
				end,
			}),
			Triangular = e(ChipForToggle, {
				Text = "Triangular",
				IsCurrent = currentType == "Triangular",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.GridType = "Triangular"
					props.UpdatedSettings()
				end,
			}),
		}),
		Width = e(NumberInput, {
			Label = "Width",
			Value = props.Settings.GridWidth,
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue >= 1 and newValue == math.floor(newValue) then
					props.Settings.GridWidth = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		Height = e(NumberInput, {
			Label = "Height",
			Value = props.Settings.GridHeight,
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue >= 1 and newValue == math.floor(newValue) then
					props.Settings.GridHeight = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		Spacing = e(NumberInput, {
			Label = "Spacing",
			Value = props.Settings.GridSpacing,
			Unit = " studs",
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue > 0 then
					props.Settings.GridSpacing = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		GenerateButton = e(OperationButton, {
			Text = "Generate",
			Color = Colors.ACTION_BLUE,
			Disabled = props.Session == nil,
			Height = 30,
			LayoutOrder = nextOrder(),
			OnClick = function()
				if props.Session then
					props.Session.GenerateGrid()
				end
			end,
		}),
	})
end

local function ThicknessPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "Thickness",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		ThicknessInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 1,
			Subject = e(NumberInput, {
				Label = "Thickness",
				Value = props.Settings.Thickness,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue > 0 then
						props.Settings.Thickness = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Thickness of the wedge parts forming the mesh.",
			}),
		}),
	})
end

local function InfluencePanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local currentFalloff = props.Settings.InfluenceFalloff
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Influence",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		RadiusInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Radius",
				Value = props.Settings.InfluenceRadius,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue >= 0 then
						props.Settings.InfluenceRadius = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How far from the selection vertices are affected. 0 = no falloff.",
			}),
		}),
		FalloffRow = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e("Frame", {
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
				Linear = e(ChipForToggle, {
					Text = "Linear",
					IsCurrent = currentFalloff == "Linear",
					LayoutOrder = 1,
					OnClick = function()
						props.Settings.InfluenceFalloff = "Linear"
						props.UpdatedSettings()
					end,
				}),
				Smooth = e(ChipForToggle, {
					Text = "Smooth",
					IsCurrent = currentFalloff == "Smooth",
					LayoutOrder = 2,
					OnClick = function()
						props.Settings.InfluenceFalloff = "Smooth"
						props.UpdatedSettings()
					end,
				}),
				Sharp = e(ChipForToggle, {
					Text = "Sharp",
					IsCurrent = currentFalloff == "Sharp",
					LayoutOrder = 3,
					OnClick = function()
						props.Settings.InfluenceFalloff = "Sharp"
						props.UpdatedSettings()
					end,
				}),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How influence decreases with distance.",
			}),
		}),
	})
end

local function PaintPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local c = props.Settings.PaintColor
	local currentColor = Color3.new(c[1], c[2], c[3])
	local currentMaterial = props.Settings.PaintMaterial
	local nextOrder = createNextOrder()

	-- Build preset swatch children
	local presetChildren: { [string]: React.ReactElement<any, any> } = {
		GridLayout = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(20, 20),
			CellPadding = UDim2.fromOffset(4, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, preset in kColorPresets do
		local isSelected = colorsMatch(c, preset.Color)
		presetChildren[preset.Name] = e("TextButton", {
			Text = "",
			BackgroundColor3 = Color3.new(preset.Color[1], preset.Color[2], preset.Color[3]),
			LayoutOrder = i,
			[React.Event.Activated] = function()
				props.Settings.PaintColor = { preset.Color[1], preset.Color[2], preset.Color[3] }
				props.UpdatedSettings()
			end,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 4),
			}),
			Border = isSelected and e("UIStroke", {
				Color = Colors.WHITE,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
		})
	end

	return e(SubPanel, {
		Title = "Paint",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		ColorPreview = e("Frame", {
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundColor3 = currentColor,
			LayoutOrder = nextOrder(),
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 4),
			}),
		}),
		PresetSwatches = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, presetChildren),
		RGBRow = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
			}),
			RedInput = e(NumberInput, {
				Value = math.round(c[1] * 255),
				Grow = true,
				ChipColor = Color3.fromRGB(255, 0, 0),
				LayoutOrder = 1,
				ValueEntered = function(newValue: number)
					local v = math.clamp(math.round(newValue), 0, 255)
					props.Settings.PaintColor = { v / 255, c[2], c[3] }
					props.UpdatedSettings()
					return v
				end,
			}),
			GreenInput = e(NumberInput, {
				Value = math.round(c[2] * 255),
				Grow = true,
				ChipColor = Color3.fromRGB(0, 255, 0),
				LayoutOrder = 2,
				ValueEntered = function(newValue: number)
					local v = math.clamp(math.round(newValue), 0, 255)
					props.Settings.PaintColor = { c[1], v / 255, c[3] }
					props.UpdatedSettings()
					return v
				end,
			}),
			BlueInput = e(NumberInput, {
				Value = math.round(c[3] * 255),
				Grow = true,
				ChipColor = Color3.fromRGB(0, 0, 255),
				LayoutOrder = 3,
				ValueEntered = function(newValue: number)
					local v = math.clamp(math.round(newValue), 0, 255)
					props.Settings.PaintColor = { c[1], c[2], v / 255 }
					props.UpdatedSettings()
					return v
				end,
			}),
		}),
		MaterialRow1 = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Plastic = e(ChipForToggle, {
				Text = "Plastic",
				IsCurrent = currentMaterial == "Plastic",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.PaintMaterial = "Plastic"
					props.UpdatedSettings()
				end,
			}),
			SmoothPlastic = e(ChipForToggle, {
				Text = "Smooth",
				IsCurrent = currentMaterial == "SmoothPlastic",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.PaintMaterial = "SmoothPlastic"
					props.UpdatedSettings()
				end,
			}),
			Slate = e(ChipForToggle, {
				Text = "Slate",
				IsCurrent = currentMaterial == "Slate",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.PaintMaterial = "Slate"
					props.UpdatedSettings()
				end,
			}),
		}),
		MaterialRow2 = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Concrete = e(ChipForToggle, {
				Text = "Concrete",
				IsCurrent = currentMaterial == "Concrete",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.PaintMaterial = "Concrete"
					props.UpdatedSettings()
				end,
			}),
			Grass = e(ChipForToggle, {
				Text = "Grass",
				IsCurrent = currentMaterial == "Grass",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.PaintMaterial = "Grass"
					props.UpdatedSettings()
				end,
			}),
			Neon = e(ChipForToggle, {
				Text = "Neon",
				IsCurrent = currentMaterial == "Neon",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.PaintMaterial = "Neon"
					props.UpdatedSettings()
				end,
			}),
		}),
		PaintRadius = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Radius",
				Value = props.Settings.PaintRadius,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue >= 0 then
						props.Settings.PaintRadius = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Paint within this radius. 0 = single triangle.",
			}),
		}),
	})
end

local function DeletePanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local current = props.Settings.DeleteTarget
	return e(SubPanel, {
		Title = "Delete",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		Row = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 1,
			Subject = e("Frame", {
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
				Face = e(ChipForToggle, {
					Text = "Face",
					IsCurrent = current == "Face",
					LayoutOrder = 1,
					OnClick = function()
						props.Settings.DeleteTarget = "Face"
						props.UpdatedSettings()
					end,
				}),
				Vertex = e(ChipForToggle, {
					Text = "Vertex",
					IsCurrent = current == "Vertex",
					LayoutOrder = 2,
					OnClick = function()
						props.Settings.DeleteTarget = "Vertex"
						props.UpdatedSettings()
					end,
				}),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Face deletes one triangle. Vertex deletes a vertex and all adjacent triangles.",
			}),
		}),
		Radius = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 2,
			Subject = e(NumberInput, {
				Label = "Radius",
				Value = props.Settings.DeleteRadius,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue >= 0 then
						props.Settings.DeleteRadius = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Delete within this radius. 0 = single click.",
			}),
		}),
	})
end

local function SelectionActionsPanel(props: {
	Session: createPolyMapSession.PolyMapSession?,
	LayoutOrder: number?,
})
	local session = props.Session
	local nextOrder = createNextOrder()

	return e(SubPanel, {
		Title = "Selection",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		SelectAll = e(OperationButton, {
			Text = "Select All",
			Color = Colors.GREY,
			Disabled = session == nil,
			Height = 26,
			LayoutOrder = nextOrder(),
			OnClick = function()
				if session then
					session.SelectAll()
				end
			end,
		}),
		ClearSelection = e(OperationButton, {
			Text = "Clear Selection",
			Color = Colors.GREY,
			Disabled = session == nil,
			Height = 26,
			LayoutOrder = nextOrder(),
			OnClick = function()
				if session then
					session.ClearSelection()
				end
			end,
		}),
		ScanMesh = e(OperationButton, {
			Text = "Rescan Mesh",
			Color = Colors.GREY,
			Disabled = session == nil,
			Height = 26,
			LayoutOrder = nextOrder(),
			OnClick = function()
				if session then
					session.ScanMesh()
				end
			end,
		}),
	})
end

local function CloseButton(props: {
	HandleAction: (string) -> (),
	LayoutOrder: number?,
})
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		CancelButton = e(OperationButton, {
			Text = "Close <i>PolyMap</i>",
			Color = Colors.DARK_RED,
			Disabled = false,
			Height = 30,
			OnClick = function()
				props.HandleAction("cancel")
			end,
		}),
	})
end

local POLYMAP_CONFIG: PluginGuiTypes.PluginGuiConfig = {
	PluginName = "PolyMap",
	PendingText = "Click the toolbar button to activate PolyMap.",
	TutorialElement = nil,
}

local function PolyMapGui(props: {
	GuiState: PluginGuiTypes.PluginGuiMode,
	CurrentSettings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	HandleAction: (string) -> (),
	Panelized: boolean,
	Session: createPolyMapSession.PolyMapSession?,
})
	local currentSettings = props.CurrentSettings
	local session = props.Session
	local mode = currentSettings.Mode
	local nextOrder = createNextOrder()
	local showSelection = mode == "Select" or mode == "Move" or mode == "Rotate"
	local showInfluence = mode == "Move" or mode == "Rotate"
	local showDelete = mode == "Delete"
	local showPaint = mode == "Paint"
	local showGrid = mode == "Generate"

	return e(PluginGui, {
		Config = POLYMAP_CONFIG,
		State = {
			Mode = props.GuiState,
			Settings = currentSettings,
			UpdatedSettings = props.UpdatedSettings,
			HandleAction = props.HandleAction,
			Panelized = props.Panelized,
		},
	}, {
		Overlay = session and e(MeshOverlay, {
			Mesh = session.GetMesh(),
			SelectedVertices = session.GetSelectedVertices(),
			HoverVertexId = session.GetHoverVertexId(),
			OutlineTriangleIds = session.GetOutlineTriangleIds(),
			HoverOutlineTriangleIds = session.GetHoverOutlineTriangleIds(),
			MarqueeStart = session.GetMarquee(),
			MarqueeEnd = select(2, session.GetMarquee()),
		}),
		Content = e(React.Fragment, nil, {
			ModePanel = e(ModePanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			GridPanel = showGrid and e(GridPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			ThicknessPanel = e(ThicknessPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			InfluencePanel = showInfluence and e(InfluencePanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			DeletePanel = showDelete and e(DeletePanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			PaintPanel = showPaint and e(PaintPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			SelectionActionsPanel = mode == "Select" and e(SelectionActionsPanel, {
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			StatusText = e(StatusText, {
				Settings = currentSettings,
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			CloseButton = e(CloseButton, {
				HandleAction = props.HandleAction,
				LayoutOrder = nextOrder(),
			}),
		}),
	})
end

return PolyMapGui
