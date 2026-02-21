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
local Slider = require("./PluginGui/Slider")
local HelpGui = require("./PluginGui/HelpGui")
local OverlayGui = require("./PluginGui/OverlayGui")
local MaterialDropdown = require("./PluginGui/MaterialDropdown")
local Settings = require("./Settings")
local PluginGuiTypes = require("./PluginGui/Types")
local MeshOverlay = require("./MeshOverlay")
local createPolyMapSession = require("./createPolyMapSession")

local e = React.createElement

-- 60-swatch color palette: 10 grayscale + 5 rows of 10 hues
local kColorPalette: { { number } } = (function()
	local palette: { { number } } = {}
	-- Row 0: grayscale (10 swatches, black to white)
	for i = 0, 9 do
		local v = i / 9
		table.insert(palette, { v, v, v })
	end
	-- Rows 1-5: hues at varying saturation/value
	local rows = {
		{ s = 1.0, v = 1.0 },  -- vivid
		{ s = 0.5, v = 1.0 },  -- pastel
		{ s = 1.0, v = 0.6 },  -- dark
		{ s = 0.7, v = 0.8 },  -- medium
		{ s = 1.0, v = 0.35 }, -- very dark
	}
	for _, row in rows do
		for i = 0, 9 do
			local h = i / 10
			local c3 = Color3.fromHSV(h, row.s, row.v)
			table.insert(palette, { c3.R, c3.G, c3.B })
		end
	end
	return palette
end)()

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
			return "Click a vertex, edge, or empty space to place triangle(s). Click empty to cancel."
		end
		return "Hover a boundary edge and click to select it."
	elseif mode == "Delete" then
		if settings.DeleteTarget == "Vertex" then
			return "Click a vertex to delete all its adjacent triangles."
		end
		return "Click a triangle to delete it."
	elseif mode == "Paint" then
		return "Click on triangles to apply color and material."
	elseif mode == "Generate" then
		return "Configure grid settings and click Generate."
	elseif mode == "Import" then
		return "Enter an image asset ID, configure settings, and click Import."
	elseif mode == "Subdivide" then
		if count == 0 then
			return "Select vertices, then click Subdivide to split each triangle into 4."
		end
		return `{count} selected. Click Subdivide to split adjacent triangles.`
	elseif mode == "Simplify" then
		if count < 2 then
			return "Select at least 2 vertices, then click Collapse to merge the shortest edge."
		end
		return `{count} selected. Click Collapse to merge the shortest edge.`
	elseif mode == "Relax" then
		return "Click and drag to regularize mesh topology within the brush radius."
	elseif mode == "Flatten" then
		return "Click and drag to smooth surface normals within the brush radius."
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
				Text = "Add Poly",
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
		}),
		Row3 = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 3,
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Generate = e(ChipForToggle, {
				Text = "Add Grid",
				IsCurrent = current == "Generate",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.Mode = "Generate"
					props.UpdatedSettings()
				end,
			}),
			Import = e(ChipForToggle, {
				Text = "Import",
				IsCurrent = current == "Import",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.Mode = "Import"
					props.UpdatedSettings()
				end,
			}),
			Subdivide = e(ChipForToggle, {
				Text = "Subdiv",
				IsCurrent = current == "Subdivide",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.Mode = "Subdivide"
					props.UpdatedSettings()
				end,
			}),
		}),
		Row4 = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 4,
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Simplify = e(ChipForToggle, {
				Text = "Simplify",
				IsCurrent = current == "Simplify",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.Mode = "Simplify"
					props.UpdatedSettings()
				end,
			}),
			Relax = e(ChipForToggle, {
				Text = "Relax",
				IsCurrent = current == "Relax",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.Mode = "Relax"
					props.UpdatedSettings()
				end,
			}),
			Flatten = e(ChipForToggle, {
				Text = "Flatten",
				IsCurrent = current == "Flatten",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.Mode = "Flatten"
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
		TypeRow = e(HelpGui.WithHelpIcon, {
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
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Square: 2 tris per cell. Triangular: equilateral triangle grid.",
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
		Spacing = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Spacing",
				Value = props.Settings.GridSpacing,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue > 0 then
						props.Settings.GridSpacing = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Distance between grid vertices in studs.",
			}),
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

local function ImportPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	Session: createPolyMapSession.PolyMapSession?,
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Import Heightmap",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		ImageIdRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),
			Label = e("TextLabel", {
				Size = UDim2.new(0, 60, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.SourceSans,
				TextSize = 18,
				TextColor3 = Colors.WHITE,
				Text = "Image ID",
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 1,
			}),
			TextBox = e("TextBox", {
				Size = UDim2.new(1, -64, 1, 0),
				BackgroundColor3 = Colors.GREY,
				BorderSizePixel = 0,
				Font = Enum.Font.SourceSans,
				TextSize = 18,
				TextColor3 = Colors.WHITE,
				PlaceholderText = "Asset ID...",
				PlaceholderColor3 = Color3.fromRGB(128, 128, 128),
				Text = props.Settings.ImportImageId,
				TextXAlignment = Enum.TextXAlignment.Left,
				ClearTextOnFocus = false,
				LayoutOrder = 2,
				[React.Event.FocusLost] = function(rbx: TextBox)
					props.Settings.ImportImageId = rbx.Text
					props.UpdatedSettings()
				end,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, 4),
					PaddingRight = UDim.new(0, 4),
				}),
			}),
		}),
		Width = e(NumberInput, {
			Label = "Width",
			Value = props.Settings.ImportWidth,
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue >= 1 and newValue == math.floor(newValue) then
					props.Settings.ImportWidth = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		Height = e(NumberInput, {
			Label = "Height",
			Value = props.Settings.ImportHeight,
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue >= 1 and newValue == math.floor(newValue) then
					props.Settings.ImportHeight = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		Spacing = e(NumberInput, {
			Label = "Spacing",
			Value = props.Settings.ImportSpacing,
			Unit = " studs",
			LayoutOrder = nextOrder(),
			ValueEntered = function(newValue: number)
				if newValue > 0 then
					props.Settings.ImportSpacing = newValue
					props.UpdatedSettings()
					return newValue
				end
				return nil
			end,
		}),
		HeightScale = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Height",
				Value = props.Settings.ImportHeightScale,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue >= 0 then
						props.Settings.ImportHeightScale = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Maximum vertex height. Pixel brightness maps to height: white = full height, black = 0.",
			}),
		}),
		ImportButton = (function()
			local session = props.Session
			local progress = if session then session.GetImportProgress() else nil
			local importing = progress ~= nil
			local buttonOrder = nextOrder()
			if importing then
				local pct = math.floor((progress :: number) * 100)
				return e("Frame", {
					Size = UDim2.new(1, 0, 0, 30),
					BackgroundColor3 = Colors.GREY,
					LayoutOrder = buttonOrder,
				}, {
					Corner = e("UICorner", {
						CornerRadius = UDim.new(0, 4),
					}),
					Fill = e("Frame", {
						Size = UDim2.new(progress :: number, 0, 1, 0),
						BackgroundColor3 = Colors.ACTION_BLUE,
						BorderSizePixel = 0,
					}, {
						Corner = e("UICorner", {
							CornerRadius = UDim.new(0, 4),
						}),
					}),
					Label = e("TextLabel", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Font = Enum.Font.SourceSansBold,
						TextSize = 18,
						TextColor3 = Colors.WHITE,
						Text = `Importing... {pct}%`,
						ZIndex = 2,
					}),
				})
			end
			return e(OperationButton, {
				Text = "Import",
				Color = Colors.ACTION_BLUE,
				Disabled = session == nil or props.Settings.ImportImageId == "",
				Height = 30,
				LayoutOrder = buttonOrder,
				OnClick = function()
					if session then
						session.ImportHeightmap()
					end
				end,
			})
		end)(),
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

local function ColorPalettePopup(props: {
	Current: { number },
	OnSelect: (color: { number }) -> (),
})
	local paletteChildren: { [string]: React.ReactElement<any, any> } = {
		GridLayout = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(16, 16),
			CellPadding = UDim2.fromOffset(2, 2),
			FillDirectionMaxCells = 10,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, swatch in kColorPalette do
		local isSelected = colorsMatch(props.Current, swatch)
		paletteChildren[`Swatch{i}`] = e("TextButton", {
			Text = "",
			BackgroundColor3 = Color3.new(swatch[1], swatch[2], swatch[3]),
			LayoutOrder = i,
			ZIndex = 12,
			[React.Event.Activated] = function()
				props.OnSelect({ swatch[1], swatch[2], swatch[3] })
			end,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 3),
			}),
			Border = isSelected and e("UIStroke", {
				Color = Colors.WHITE,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
		})
	end

	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.BLACK,
		BorderSizePixel = 0,
		ZIndex = 12,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
		Stroke = e("UIStroke", {
			Color = Colors.OFFWHITE,
			Thickness = 1,
		}),
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 4),
		}),
		Content = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			ZIndex = 12,
		}, paletteChildren),
	})
end

local kMaxRecentColors = 8

local function updateRecentColors(settings: Settings.PolyMapSettings, color: { number })
	local recent = table.clone(settings.RecentColors)
	-- Remove if already present
	for i = #recent, 1, -1 do
		if colorsMatch(recent[i], color) then
			table.remove(recent, i)
		end
	end
	table.insert(recent, 1, color)
	while #recent > kMaxRecentColors do
		table.remove(recent)
	end
	settings.RecentColors = recent
end

local function ColorPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local c = props.Settings.PaintColor
	local currentColor = Color3.new(c[1], c[2], c[3])
	local nextOrder = createNextOrder()
	local overlayContext = OverlayGui.use()
	local colorTriggerRef = React.useRef(nil)

	local function setColor(color: { number })
		props.Settings.PaintColor = color
		props.UpdatedSettings()
	end

	local function selectColorFromPicker(color: { number })
		props.Settings.PaintColor = color
		updateRecentColors(props.Settings, color)
		props.UpdatedSettings()
	end

	local function openColorPalette()
		if colorTriggerRef.current then
			overlayContext.SetOverlay(colorTriggerRef.current, e(ColorPalettePopup, {
				Current = c,
				OnSelect = function(color: { number })
					overlayContext.SetOverlay(nil)
					selectColorFromPicker(color)
				end,
			}))
		end
	end

	-- Build recent color swatches (in stored order, highlight current)
	local shownColors: { { number } } = {}
	for _, color in props.Settings.RecentColors do
		if #shownColors >= kMaxRecentColors then
			break
		end
		table.insert(shownColors, color)
	end

	local recentChildren: { [string]: React.ReactElement<any, any> } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	}
	for i, color in shownColors do
		local isCurrent = colorsMatch(color, c)
		recentChildren[`Color{i}`] = e("TextButton", {
			Size = UDim2.fromOffset(22, 22),
			BackgroundColor3 = Color3.new(color[1], color[2], color[3]),
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = i,
			[React.Event.MouseButton1Click] = function()
				setColor(color)
			end,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 3),
			}),
			Border = isCurrent and e("UIStroke", {
				Color = Colors.WHITE,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
		})
	end

	return e(SubPanel, {
		Title = "Color",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		HeroRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			ColorPreview = e("TextButton", {
				Size = UDim2.new(1, -84, 0, 24),
				BackgroundColor3 = currentColor,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = 1,
				[React.Event.MouseButton1Click] = openColorPalette,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Flex = e("UIFlexItem", {
					FlexMode = Enum.UIFlexMode.Fill,
				}),
				DarkBorder = (c[1] + c[2] + c[3] < 0.6) and e("UIStroke", {
					Color = Colors.OFFWHITE,
					Thickness = 1,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}) or nil,
			}),
			PickButton = e("TextButton", {
				Size = UDim2.fromOffset(48, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "Pick",
				Font = if props.Settings.PaintEyedropper == "Color" then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
				TextSize = if props.Settings.PaintEyedropper == "Color" then 20 else 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = props.Settings.PaintEyedropper ~= "Color",
				LayoutOrder = 2,
				[React.Event.MouseButton1Click] = function()
					props.Settings.PaintEyedropper = if props.Settings.PaintEyedropper == "Color" then "None" else "Color"
					props.UpdatedSettings()
				end,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Border = (props.Settings.PaintEyedropper == "Color") and e("UIStroke", {
					Color = Colors.WHITE,
					Thickness = 2,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
			}),
			MoreButton = e("TextButton", {
				Size = UDim2.fromOffset(28, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "...",
				Font = Enum.Font.SourceSansBold,
				TextSize = 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = true,
				LayoutOrder = 3,
				ref = colorTriggerRef,
				[React.Event.MouseButton1Click] = openColorPalette,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
			}),
		}),
		RecentRow = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, recentChildren),
	})
end

local function MaterialPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	local overlayContext = OverlayGui.use()
	local materialTriggerRef = React.useRef(nil)

	local function setMaterial(name: string)
		props.Settings.PaintMaterial = name
		props.UpdatedSettings()
	end

	local function selectMaterialFromPicker(name: string)
		props.Settings.PaintMaterial = name
		-- Update recent materials: move selected to front, cap at 6
		local recent = table.clone(props.Settings.RecentMaterials)
		for i = #recent, 1, -1 do
			if recent[i] == name then
				table.remove(recent, i)
			end
		end
		table.insert(recent, 1, name)
		while #recent > 4 do
			table.remove(recent)
		end
		props.Settings.RecentMaterials = recent
		props.UpdatedSettings()
	end

	local function openMaterialPopup()
		if materialTriggerRef.current then
			overlayContext.SetOverlay(materialTriggerRef.current, e(MaterialDropdown.PopupContent, {
				Current = props.Settings.PaintMaterial,
				OnSelect = function(name: string)
					overlayContext.SetOverlay(nil)
					selectMaterialFromPicker(name)
				end,
			}))
		end
	end

	return e(SubPanel, {
		Title = "Material",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		HeroRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			MaterialPreview = e("TextButton", {
				Size = UDim2.new(1, -84, 0, 24),
				BackgroundTransparency = 1,
				Text = "",
				LayoutOrder = 1,
				[React.Event.MouseButton1Click] = openMaterialPopup,
			}, {
				Flex = e("UIFlexItem", {
					FlexMode = Enum.UIFlexMode.Fill,
				}),
				Viewport = e("ViewportFrame", {
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Colors.BLACK,
				}, {
					Corner = e("UICorner", {
						CornerRadius = UDim.new(0, 4),
					}),
					PreviewPart = e("Part", {
						Size = Vector3.new(100, 100, 0.1),
						Position = Vector3.new(0, 0, 0),
						Material = (Enum.Material :: any)[props.Settings.PaintMaterial] or Enum.Material.Plastic,
						Color = Color3.new(
							props.Settings.PaintColor[1],
							props.Settings.PaintColor[2],
							props.Settings.PaintColor[3]
						),
						Anchored = true,
					}),
					PreviewCamera = e("Camera", {
						CFrame = CFrame.new(Vector3.new(0, 0, 3), Vector3.new(0, 0, 0)),
						FieldOfView = 5,
						ref = function(camera: Camera?)
							if camera then
								local vf = camera.Parent :: ViewportFrame?
								if vf then
									vf.CurrentCamera = camera
								end
							end
						end,
					}),
				}),
			}),
			PickButton = e("TextButton", {
				Size = UDim2.fromOffset(48, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "Pick",
				Font = if props.Settings.PaintEyedropper == "Material" then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
				TextSize = if props.Settings.PaintEyedropper == "Material" then 20 else 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = props.Settings.PaintEyedropper ~= "Material",
				LayoutOrder = 2,
				[React.Event.MouseButton1Click] = function()
					props.Settings.PaintEyedropper = if props.Settings.PaintEyedropper == "Material" then "None" else "Material"
					props.UpdatedSettings()
				end,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Border = (props.Settings.PaintEyedropper == "Material") and e("UIStroke", {
					Color = Colors.WHITE,
					Thickness = 2,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
			}),
			MoreButton = e("TextButton", {
				Size = UDim2.fromOffset(28, 24),
				BackgroundColor3 = Colors.ACTION_BLUE,
				Text = "...",
				Font = Enum.Font.SourceSansBold,
				TextSize = 18,
				TextColor3 = Colors.WHITE,
				AutoButtonColor = true,
				LayoutOrder = 3,
				ref = materialTriggerRef,
				[React.Event.MouseButton1Click] = openMaterialPopup,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
			}),
		}),
		RecentChips = e(MaterialDropdown.RecentChips, {
			Current = props.Settings.PaintMaterial,
			RecentMaterials = props.Settings.RecentMaterials,
			OnSelect = setMaterial,
			LayoutOrder = nextOrder(),
		}),
	})
end

local function BrushPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()

	local currentTarget = props.Settings.PaintTarget

	return e(SubPanel, {
		Title = "Brush",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		TargetRow = e("Frame", {
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
			ColorChip = e(ChipForToggle, {
				Text = "Color",
				IsCurrent = currentTarget == "Color",
				LayoutOrder = 1,
				OnClick = function()
					props.Settings.PaintTarget = "Color"
					props.UpdatedSettings()
				end,
			}),
			MaterialChip = e(ChipForToggle, {
				Text = "Material",
				IsCurrent = currentTarget == "Material",
				LayoutOrder = 2,
				OnClick = function()
					props.Settings.PaintTarget = "Material"
					props.UpdatedSettings()
				end,
			}),
			BothChip = e(ChipForToggle, {
				Text = "Both",
				IsCurrent = currentTarget == "Both",
				LayoutOrder = 3,
				OnClick = function()
					props.Settings.PaintTarget = "Both"
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
		PaintStrength = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Slider, {
				Label = "Strength",
				Value = props.Settings.PaintStrength,
				Min = 0,
				Max = 1,
				Step = 0.01,
				ValueChanged = function(newValue: number)
					props.Settings.PaintStrength = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Color blend strength. 1 = full replace, lower values blend with existing color.",
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

local function SubdividePanel(props: {
	Session: createPolyMapSession.PolyMapSession?,
	LayoutOrder: number?,
})
	local session = props.Session
	local count = if session then session.GetSelectedVertexCount() else 0
	return e(SubPanel, {
		Title = "Subdivide",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		SubdivideButton = e(OperationButton, {
			Text = "Subdivide Selected",
			SubText = if count > 0 then `{count} vertices` else nil,
			Color = Colors.ACTION_BLUE,
			Disabled = session == nil or count == 0,
			Height = 30,
			LayoutOrder = 1,
			OnClick = function()
				if session then
					session.Subdivide()
				end
			end,
		}),
	})
end

local function SimplifyPanel(props: {
	Session: createPolyMapSession.PolyMapSession?,
	LayoutOrder: number?,
})
	local session = props.Session
	local count = if session then session.GetSelectedVertexCount() else 0
	return e(SubPanel, {
		Title = "Simplify",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		SimplifyButton = e(OperationButton, {
			Text = "Collapse Shortest Edge",
			SubText = if count > 0 then `{count} vertices` else nil,
			Color = Colors.ACTION_BLUE,
			Disabled = session == nil or count < 2,
			Height = 30,
			LayoutOrder = 1,
			OnClick = function()
				if session then
					session.Simplify(1)
				end
			end,
		}),
	})
end

local function RelaxPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Relax",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		RadiusInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Radius",
				Value = props.Settings.RelaxRadius,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue > 0 then
						props.Settings.RelaxRadius = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Radius of the relax brush.",
			}),
		}),
		StrengthInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Strength",
				Value = props.Settings.RelaxStrength,
				ValueEntered = function(newValue: number)
					if newValue >= 0 and newValue <= 1 then
						props.Settings.RelaxStrength = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How strongly to flatten per stroke. 1 = fully flat in one pass.",
			}),
		}),
	})
end

local function FlattenPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Flatten",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		RadiusInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Radius",
				Value = props.Settings.FlattenRadius,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue > 0 then
						props.Settings.FlattenRadius = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Radius of the flatten brush.",
			}),
		}),
		StrengthInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Strength",
				Value = props.Settings.FlattenStrength,
				ValueEntered = function(newValue: number)
					if newValue >= 0 and newValue <= 1 then
						props.Settings.FlattenStrength = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How strongly to smooth normals per stroke. 1 = fully smooth in one pass.",
			}),
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
	local showInfluence = mode == "Move" or mode == "Rotate"
	local showDelete = mode == "Delete"
	local showPaint = mode == "Paint"
	local showGrid = mode == "Generate"
	local showImport = mode == "Import"
	local showThickness = mode == "Add" or mode == "Generate" or mode == "Import"
	local showSubdivide = mode == "Subdivide"
	local showSimplify = mode == "Simplify"
	local showRelax = mode == "Relax"
	local showFlatten = mode == "Flatten"

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
		Overlay = session and e(MeshOverlay, (function()
			local mesh = session.GetMesh()
			local showSelection = mode == "Select" or mode == "Move" or mode == "Rotate" or mode == "Subdivide" or mode == "Simplify"
			local overlayProps: { [string]: any } = {
				Mesh = mesh,
				SelectedVertices = if showSelection then session.GetSelectedVertices() else nil,
				HoverVertexId = if showSelection then session.GetHoverVertexId() else nil,
				OutlineTriangleIds = session.GetOutlineTriangleIds(),
				HoverOutlineTriangleIds = session.GetHoverOutlineTriangleIds(),
				MarqueeStart = session.GetMarquee(),
				MarqueeEnd = select(2, session.GetMarquee()),
			}

			-- Compute Add mode overlay props
			if mode == "Add" then
				local boundaryEdge = session.GetAddBoundaryEdge()
				if boundaryEdge then
					-- Phase 2: highlight the selected boundary edge
					local v1 = mesh.getVertex(boundaryEdge.v1)
					local v2 = mesh.getVertex(boundaryEdge.v2)
					if v1 and v2 then
						overlayProps.AddHighlightEdge = { v1Pos = v1.position, v2Pos = v2.position }

						-- Compute preview triangles from hover target
						local target = session.GetAddHoverTarget()
						if target then
							local previewTris: { { Vector3 } } = {}
							if target.type == "vertex" and target.vertexId then
								local tv = mesh.getVertex(target.vertexId)
								if tv then
									table.insert(previewTris, { v1.position, v2.position, tv.position })
								end
							elseif target.type == "edge" and target.edgeKey then
								local edges = mesh.getEdges()
								local targetEdge = edges[target.edgeKey]
								if targetEdge then
									local tv1 = mesh.getVertex(targetEdge.v1)
									local tv2 = mesh.getVertex(targetEdge.v2)
									if tv1 and tv2 then
										-- Pick the pairing that doesn't cross
										local ta, tb = tv1, tv2
										local distStraight = (v1.position - ta.position).Magnitude + (v2.position - tb.position).Magnitude
										local distCrossed = (v1.position - tb.position).Magnitude + (v2.position - ta.position).Magnitude
										if distCrossed < distStraight then
											ta, tb = tv2, tv1
										end
										table.insert(previewTris, { v1.position, v2.position, ta.position })
										table.insert(previewTris, { v2.position, tb.position, ta.position })
									end
								end
							elseif target.type == "plane" and target.position then
								table.insert(previewTris, { v1.position, v2.position, target.position })
							end
							overlayProps.AddPreviewTriangles = previewTris
						end
					end
				else
					-- Phase 1: highlight the hovered boundary edge
					local hoverKey = session.GetHoverEdgeKey()
					if hoverKey then
						local edges = mesh.getEdges()
						local edge = edges[hoverKey]
						if edge then
							local v1 = mesh.getVertex(edge.v1)
							local v2 = mesh.getVertex(edge.v2)
							if v1 and v2 then
								overlayProps.AddHighlightEdge = { v1Pos = v1.position, v2Pos = v2.position }
							end
						end
					end
				end
			end

			return overlayProps
		end)()),
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
			ImportPanel = showImport and e(ImportPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			ThicknessPanel = showThickness and e(ThicknessPanel, {
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
			BrushPanel = showPaint and e(BrushPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			ColorPanel = showPaint and e(ColorPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			MaterialPanel = showPaint and e(MaterialPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			SubdividePanel = showSubdivide and e(SubdividePanel, {
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			SimplifyPanel = showSimplify and e(SimplifyPanel, {
				Session = session,
				LayoutOrder = nextOrder(),
			}),
			RelaxPanel = showRelax and e(RelaxPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			FlattenPanel = showFlatten and e(FlattenPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
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
