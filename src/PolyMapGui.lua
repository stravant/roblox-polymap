--!strict

local MaterialService = game:GetService("MaterialService")

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
local Checkbox = require("./PluginGui/Checkbox")
local Settings = require("./Settings")
local PluginGuiTypes = require("./PluginGui/Types")
local Toast = require("./Toast")
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

-- The classic Studio BrickColor picker: BrickColor.palette(0..126) laid out as a
-- hexagonal honeycomb (row widths 7..13..7 = 127 cells), plus a bottom strip of the
-- neutral greys. Extracted cell-for-cell from the Studio picker, then driven live off
-- BrickColor.palette so the colours always match the engine's.
local kBrickHexRows: { { { idx: number, color: { number } } } } = (function()
	local widths = { 7, 8, 9, 10, 11, 12, 13, 12, 11, 10, 9, 8, 7 }
	local rows = {}
	local idx = 0
	for _, w in widths do
		local row = {}
		for _ = 1, w do
			local col = BrickColor.palette(idx).Color
			table.insert(row, { idx = idx, color = { col.R, col.G, col.B } })
			idx += 1
		end
		table.insert(rows, row)
	end
	return rows
end)()

local kBrickStrip: { { idx: number, color: { number } } } = (function()
	local indices = { 127, 122, 123, 108, 49, 97, 3, 10, 29, 50, 75, 86 }
	local strip = {}
	for _, i in indices do
		local col = BrickColor.palette(i).Color
		table.insert(strip, { idx = i, color = { col.R, col.G, col.B } })
	end
	return strip
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
	if mode == "Move" then
		if count == 0 then
			return "Click vertices to select (Shift+click toggles, drag to marquee), then drag the move handles."
		end
		return `{count} selected. Drag handles to move.`
	elseif mode == "Rotate" then
		if count == 0 then
			return "Select vertices first, then drag the rotation rings."
		end
		return `{count} selected. Drag rings to rotate.`
	elseif mode == "Add" then
		local points = #session.GetAddPoints()
		if points > 0 then
			return `Placing a fresh triangle: {points} of 3 corners. Esc to cancel.`
		end
		if session.GetAddBoundaryEdge() then
			return "Click to place the apex — a vertex, edge, or empty space. Esc to cancel."
		end
		return "Hover a boundary edge to build from it, or click empty space to place a fresh vertex."
	elseif mode == "Delete" then
		if settings.DeleteTarget == "Vertex" then
			return "Click a vertex to delete all its adjacent triangles."
		end
		return "Click a triangle to delete it."
	elseif mode == "Paint" then
		return "Click on triangles to apply color and material."
	elseif mode == "Generate" then
		return "Click Generate to place a grid in front of the camera or Place... to select two points to place a grid between."
	elseif mode == "Import" then
		return "Enter an image asset ID, configure settings, and click Import."
	elseif mode == "Relax" then
		return "Click and drag to regularize mesh topology within the brush radius."
	elseif mode == "Flatten" then
		return "Click and drag to smooth surface normals within the brush radius."
	elseif mode == "Heal" then
		return "Brush over a torn seam to merge nearby vertices and close the gap."
	elseif mode == "Convert" then
		return "Click a MeshPart (or a Part with a SpecialMesh) to convert it into PolyMap polygons."
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
	-- Inset the grey background from the container edges so it lines up with the
	-- panels' bordered boxes (SubPanel insets its box by 6px a side) rather than
	-- bleeding to the very edges. A transparent full-width frame supplies the inset;
	-- the label fills what's left.
	local INSET = 6
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, INSET),
			PaddingRight = UDim.new(0, INSET),
		}),
		Label = e("TextLabel", {
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
		}),
	})
end

local function ModePanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local current = props.Settings.Mode

	local function modeChip(text: string, modeValue: string, order: number)
		return e(ChipForToggle, {
			Text = text,
			IsCurrent = current == modeValue,
			LayoutOrder = order,
			OnClick = function()
				props.Settings.Mode = modeValue
				props.UpdatedSettings()
			end,
		})
	end

	-- A blank 1/3-width slot so a row's remaining chips stay column-aligned. The
	-- two trailing spots are reserved for future modes.
	local function emptySlot(order: number)
		return e("Frame", {
			Size = UDim2.new(0, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, {
			Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
		})
	end

	local function row(order: number, children: { [string]: any })
		children.ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		})
		return e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, children)
	end

	return e(SubPanel, {
		Title = "Mode",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		Row1 = row(1, {
			Settings = modeChip("Settings", "Settings", 1),
			Move = modeChip("Move", "Move", 2),
			Rotate = modeChip("Rotate", "Rotate", 3),
		}),
		Row2 = row(2, {
			Add = modeChip("Add Poly", "Add", 1),
			Delete = modeChip("Delete", "Delete", 2),
			Paint = modeChip("Paint", "Paint", 3),
		}),
		Row3 = row(3, {
			Generate = modeChip("Add Grid", "Generate", 1),
			Import = modeChip("Import", "Import", 2),
			Relax = modeChip("Relax", "Relax", 3),
		}),
		Row4 = row(4, {
			Flatten = modeChip("Flatten", "Flatten", 1),
			Heal = modeChip("Heal", "Heal", 2),
			Convert = modeChip("Convert", "Convert", 3),
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
	-- While the interactive "Place..." tool is choosing its two corners, the button shows
	-- "Placing" with a highlight border (and the viewport shows a crosshair cursor). The
	-- panel re-renders on the session's change signal, which placement start/commit/cancel
	-- all fire, so this stays in sync.
	local placing = props.Session ~= nil and props.Session.IsPlacingGrid()
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
				HelpRichText = "The grid's tiling:<br />• <b>Square</b> — square cells, two triangles each<br />• <b>Triangular</b> — rows of equilateral triangles",
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
			Label = "Length",
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
				HelpRichText = "Spacing between grid vertices, in studs — the size of one cell.",
			}),
		}),
		Buttons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			-- OperationButton fills its parent's width, so each sits in a 50% wrapper.
			GenerateWrap = e("Frame", {
				Size = UDim2.new(0.5, -2, 1, 0),
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Button = e(OperationButton, {
					Text = "Generate",
					Color = Colors.ACTION_BLUE,
					Disabled = props.Session == nil,
					Height = 30,
					OnClick = function()
						if props.Session then
							props.Session.GenerateGrid()
						end
					end,
				}),
			}),
			PlaceWrap = e("Frame", {
				Size = UDim2.new(0.5, -2, 1, 0),
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, {
				-- The border is on this wrapper (OperationButton takes no border prop); a
				-- matching UICorner rounds the stroke to the button's corners. Both appear
				-- only while placing.
				Corner = placing and e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
				Border = placing and e("UIStroke", {
					Color = Colors.WHITE,
					Thickness = 2,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}),
				Button = e(OperationButton, {
					Text = if placing then "Placing" else "Place...",
					Color = Colors.ACTION_BLUE,
					Disabled = props.Session == nil,
					Height = 30,
					OnClick = function()
						if props.Session then
							props.Session.StartGridPlacement()
						end
					end,
				}),
			}),
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
		ImageIdRow = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundTransparency = 1,
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
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Asset ID of the image to import. A pixel's brightness becomes its vertex height (between <b>Min Y</b> and <b>Max Y</b>) and its color tints the surface. Grayscale heightmaps work best.",
			}),
		}),
		Width = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Width",
				Value = props.Settings.ImportWidth,
				ValueEntered = function(newValue: number)
					if newValue >= 1 and newValue == math.floor(newValue) then
						props.Settings.ImportWidth = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How many cells wide the imported grid is. The image is stretched across it, so a higher value samples it more finely.",
			}),
		}),
		Height = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Length",
				Value = props.Settings.ImportHeight,
				ValueEntered = function(newValue: number)
					if newValue >= 1 and newValue == math.floor(newValue) then
						props.Settings.ImportHeight = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How many cells long the imported grid is — its resolution, <i>not</i> the surface height (that's <b>Min Y</b> / <b>Max Y</b>).",
			}),
		}),
		Spacing = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Spacing",
				Value = props.Settings.ImportSpacing,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue > 0 then
						props.Settings.ImportSpacing = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Distance between neighboring vertices, in studs. With Width and Height, this sets the mesh's overall footprint.",
			}),
		}),
		MinY = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Min Y",
				Value = props.Settings.ImportMinY,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					props.Settings.ImportMinY = newValue
					props.UpdatedSettings()
					return newValue
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Height (Y) given to fully black pixels, in studs. May be negative.",
			}),
		}),
		MaxY = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Max Y",
				Value = props.Settings.ImportMaxY,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					props.Settings.ImportMaxY = newValue
					props.UpdatedSettings()
					return newValue
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Height (Y) given to fully white pixels, in studs. A pixel's brightness blends its vertex between <b>Min Y</b> and <b>Max Y</b>.",
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
	ShowMatchThickness: boolean?,
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
				HelpRichText = "How thick the wedge Parts that form the mesh are, in studs.",
			}),
		}),
		-- Add mode only: match the thickness of geometry the new triangle snaps to.
		MatchThickness = props.ShowMatchThickness and e(HelpGui.WithHelpIcon, {
			LayoutOrder = 2,
			Subject = e(Checkbox, {
				Label = "Match Thickness",
				Checked = props.Settings.MatchThickness,
				Changed = function(checked: boolean)
					props.Settings.MatchThickness = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "When a new triangle snaps onto existing geometry, match that geometry's thickness instead of the value above.",
			}),
		}),
	})
end

-- Add mode: how the corners of a new triangle that DON'T snap onto existing
-- geometry are oriented. Flat keeps the triangle as horizontal as possible; Extend
-- lays it in the plane of whatever it snapped to (matching that surface's normal).
local function FreePointsPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local current = props.Settings.AddNonSnapped
	return e(SubPanel, {
		Title = "Free Points",
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
				Flat = e(ChipForToggle, {
					Text = "Flat",
					IsCurrent = current == "Flat",
					LayoutOrder = 1,
					OnClick = function()
						props.Settings.AddNonSnapped = "Flat"
						props.UpdatedSettings()
					end,
				}),
				Extend = e(ChipForToggle, {
					Text = "Extend",
					IsCurrent = current == "Extend",
					LayoutOrder = 2,
					OnClick = function()
						props.Settings.AddNonSnapped = "Extend"
						props.UpdatedSettings()
					end,
				}),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Where the corners of a new triangle that <i>don't</i> snap onto geometry are placed:<br />• <b>Flat</b> — as close to horizontal as possible<br />• <b>Extend</b> — in the plane of the snapped triangle, following its normal",
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
				HelpRichText = "How the drag's pull fades from the selected vertices out to the influence radius:<br />• <b>Linear</b> — even, straight-line falloff<br />• <b>Smooth</b> — soft, eases in and out<br />• <b>Sharp</b> — drops off fast, concentrating the effect near the selection",
			}),
		}),
		RadiusInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Slider, {
				Label = "Radius",
				Value = props.Settings.InfluenceRadius,
				Min = 0,
				Max = 100,
				Step = 1,
				ValueChanged = function(newValue: number)
					props.Settings.InfluenceRadius = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How far a drag reaches past the selected vertices — nearby vertices follow along, fading out over this distance. At zero, only the selected vertices move.",
			}),
		}),
	})
end

local kSelectRing = Color3.fromRGB(255, 170, 0)

local function colorToHex(c: { number }): string
	return string.format("%02X%02X%02X", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local function hexToColor(s: string): { number }?
	local clean = (s:gsub("[#%s]", ""))
	if #clean ~= 6 or clean:match("[^0-9a-fA-F]") then
		return nil
	end
	return {
		(tonumber(clean:sub(1, 2), 16) or 0) / 255,
		(tonumber(clean:sub(3, 4), 16) or 0) / 255,
		(tonumber(clean:sub(5, 6), 16) or 0) / 255,
	}
end

-- One colour cell. In a UIGridLayout the grid overrides the size; in a UIListLayout
-- (the honeycomb rows) the 15px size is kept.
local function colorCell(color: { number }, isSel: boolean, order: number, onClick: () -> ()): React.ReactElement<any, any>
	return e("TextButton", {
		Size = UDim2.fromOffset(15, 15),
		BackgroundColor3 = Color3.new(color[1], color[2], color[3]),
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 12,
		[React.Event.MouseButton1Click] = onClick,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 3) }),
		Ring = isSel and e("UIStroke", {
			Color = kSelectRing,
			Thickness = 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			ZIndex = 13,
		}),
	})
end

-- A single centered honeycomb row of cells; consecutive rows differ in count, so
-- centering offsets them by half a cell into the classic honeycomb.
local function honeyRow(cells: { { idx: number, color: { number } } }, order: number, current: { number }, onSelect: (color: { number }, close: boolean) -> ()): React.ReactElement<any, any>
	local kids: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 1),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for c, cell in cells do
		kids["C" .. c] = colorCell(cell.color, colorsMatch(current, cell.color), c, function()
			onSelect(cell.color, true)
		end)
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 15),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 12,
	}, kids)
end

local function BrickColorTab(current: { number }, onSelect: (color: { number }, close: boolean) -> ()): React.ReactElement<any, any>
	local kids: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 1),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
	}
	for r, row in kBrickHexRows do
		kids["R" .. r] = honeyRow(row, r, current, onSelect)
	end
	kids["Gap"] = e("Frame", { Size = UDim2.new(1, 0, 0, 6), BackgroundTransparency = 1, LayoutOrder = 50 })
	kids["Strip"] = honeyRow(kBrickStrip, 51, current, onSelect)
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
	}, kids)
end

local function SwatchesTab(current: { number }, onSelect: (color: { number }, close: boolean) -> ()): React.ReactElement<any, any>
	local kids: { [string]: any } = {
		GridLayout = e("UIGridLayout", {
			CellSize = UDim2.fromOffset(16, 16),
			CellPadding = UDim2.fromOffset(2, 2),
			FillDirectionMaxCells = 10,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, swatch in kColorPalette do
		kids["S" .. i] = colorCell(swatch, colorsMatch(current, swatch), i, function()
			onSelect(swatch, true)
		end)
	end
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
	}, kids)
end

local function CustomTab(color: { number }, onChange: (color: { number }) -> (), onConfirm: () -> ()): React.ReactElement<any, any>
	local function setChannel(i: number, v255: number)
		local nc = { color[1], color[2], color[3] }
		nc[i] = math.clamp(v255 / 255, 0, 1)
		onChange(nc)
	end
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
	}, {
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		Preview = e("Frame", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = Color3.new(color[1], color[2], color[3]),
			LayoutOrder = 1,
			ZIndex = 12,
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }) }),
		HexRow = e("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			ZIndex = 12,
		}, {
			Layout = e("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
			Label = e("TextLabel", { Size = UDim2.fromOffset(28, 22), BackgroundTransparency = 1, Text = "Hex", TextColor3 = Colors.WHITE, Font = Enum.Font.SourceSans, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, ZIndex = 12 }),
			Box = e("TextBox", {
				Size = UDim2.new(1, -32, 1, 0),
				BackgroundColor3 = Colors.GREY,
				BorderSizePixel = 0,
				Text = colorToHex(color),
				PlaceholderText = "RRGGBB",
				Font = Enum.Font.SourceSans,
				TextSize = 16,
				TextColor3 = Colors.WHITE,
				ClearTextOnFocus = false,
				LayoutOrder = 2,
				ZIndex = 12,
				[React.Event.FocusLost] = function(rbx: TextBox)
					local parsed = hexToColor(rbx.Text)
					if parsed then
						onChange(parsed)
					else
						rbx.Text = colorToHex(color)
					end
				end,
			}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }), Padding = e("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) }),
		}),
		R = e(Slider, { Label = "R", Value = math.floor(color[1] * 255 + 0.5), Min = 0, Max = 255, Step = 1, LayoutOrder = 3, ValueChanged = function(v: number) setChannel(1, v) end }),
		G = e(Slider, { Label = "G", Value = math.floor(color[2] * 255 + 0.5), Min = 0, Max = 255, Step = 1, LayoutOrder = 4, ValueChanged = function(v: number) setChannel(2, v) end }),
		B = e(Slider, { Label = "B", Value = math.floor(color[3] * 255 + 0.5), Min = 0, Max = 255, Step = 1, LayoutOrder = 5, ValueChanged = function(v: number) setChannel(3, v) end }),
		-- The Custom tab applies live as you drag, so there's no swatch click to record
		-- the colour. This button commits the current colour to the recents (and closes).
		Confirm = e("TextButton", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = Colors.ACTION_BLUE,
			Text = "Add to Recents",
			Font = Enum.Font.SourceSansBold,
			TextSize = 16,
			TextColor3 = Colors.WHITE,
			AutoButtonColor = true,
			LayoutOrder = 6,
			ZIndex = 12,
			[React.Event.MouseButton1Click] = onConfirm,
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }) }),
	})
end

-- Remembers the last-viewed picker tab for the rest of the Studio session, so reopening
-- the popup returns to where you left off.
local gColorPickerTab = "BrickColor"

local function ColorPickerPopup(props: {
	Current: { number },
	OnSelect: (color: { number }, close: boolean) -> (),
})
	local tab, setTab = React.useState(gColorPickerTab)
	local customColor, setCustomColor = React.useState(props.Current)

	local function customChange(c: { number })
		setCustomColor(c)
		props.OnSelect(c, false)
	end
	local function confirmCustom()
		props.OnSelect(customColor, true)
	end

	local body: React.ReactElement<any, any>
	if tab == "Swatches" then
		body = SwatchesTab(props.Current, props.OnSelect)
	elseif tab == "Custom" then
		body = CustomTab(customColor, customChange, confirmCustom)
	else
		body = BrickColorTab(props.Current, props.OnSelect)
	end

	local function tabBtn(name: string, order: number)
		local active = tab == name
		return e("TextButton", {
			Size = UDim2.new(1 / 3, -2, 1, 0),
			BackgroundColor3 = if active then Colors.ACTION_BLUE else Colors.GREY,
			BackgroundTransparency = if active then 0 else 0.35,
			Text = name,
			Font = if active then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
			TextSize = 14,
			TextColor3 = Colors.WHITE,
			AutoButtonColor = not active,
			LayoutOrder = order,
			ZIndex = 12,
			[React.Event.MouseButton1Click] = function()
				setTab(name)
				gColorPickerTab = name
			end,
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }) })
	end

	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.BLACK,
		BorderSizePixel = 0,
		ZIndex = 12,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
		Stroke = e("UIStroke", { Color = Colors.OFFWHITE, Thickness = 1 }),
		Padding = e("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		TabBar = e("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			ZIndex = 12,
		}, {
			Layout = e("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
			BrickColor = tabBtn("BrickColor", 1),
			Swatches = tabBtn("Swatches", 2),
			Custom = tabBtn("Custom", 3),
		}),
		Body = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			ZIndex = 12,
		}, { Content = body }),
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

	local function openColorPalette()
		if colorTriggerRef.current then
			overlayContext.SetOverlay(colorTriggerRef.current, e(ColorPickerPopup, {
				Current = c,
				OnSelect = function(color: { number }, close: boolean)
					-- BrickColor/Swatches commit (close=true); the Custom tab live-updates
					-- as you drag (close=false) and stays open until you click away.
					props.Settings.PaintColor = color
					if close then
						updateRecentColors(props.Settings, color)
						overlayContext.SetOverlay(nil)
					end
					props.UpdatedSettings()
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

	-- Move a recent key (an encoded material+variant) to the front of the history.
	local function addRecent(key: string)
		local recent = table.clone(props.Settings.RecentMaterials)
		for i = #recent, 1, -1 do
			if recent[i] == key then
				table.remove(recent, i)
			end
		end
		table.insert(recent, 1, key)
		while #recent > 6 do -- two rows of three
			table.remove(recent)
		end
		props.Settings.RecentMaterials = recent
	end

	-- Pick a base material from the popup: clears any variant.
	local function selectMaterialFromPicker(name: string)
		props.Settings.PaintMaterial = name
		props.Settings.PaintMaterialVariant = ""
		addRecent(Settings.EncodeRecentMaterial(name, ""))
		props.UpdatedSettings()
	end

	-- Re-apply a recent (material + variant) history entry.
	local function selectRecent(key: string)
		local material, variant = Settings.DecodeRecentMaterial(key)
		props.Settings.PaintMaterial = material
		props.Settings.PaintMaterialVariant = variant
		addRecent(key)
		props.UpdatedSettings()
	end

	-- Apply a typed variant name. If a MaterialVariant by that name exists, switch the
	-- base material to its BaseMaterial so the variant actually shows; if no such
	-- variant exists, clear the field back to empty.
	local function applyVariant(typed: string)
		if typed == "" then
			props.Settings.PaintMaterialVariant = ""
			props.UpdatedSettings()
			return
		end
		local found: MaterialVariant? = nil
		for _, child in MaterialService:GetChildren() do
			if child:IsA("MaterialVariant") and child.Name == typed then
				found = child :: MaterialVariant
				break
			end
		end
		if found then
			props.Settings.PaintMaterialVariant = typed
			props.Settings.PaintMaterial = found.BaseMaterial.Name
			-- A valid, entered variant joins the history, like an eyedropped one.
			addRecent(Settings.EncodeRecentMaterial(found.BaseMaterial.Name, typed))
		else
			props.Settings.PaintMaterialVariant = ""
		end
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
		RecentChips = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, (function()
			-- Lay the recents out three per row (two rows of three) so material names
			-- aren't cramped. The last row is padded with blank slots so its chips keep
			-- the one-third width of a full row.
			local perRow = 3
			local recents = props.Settings.RecentMaterials
			local rowCount = math.max(1, math.ceil(#recents / perRow))
			local rows: { [string]: any } = {
				ListLayout = e("UIListLayout", {
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
			}
			for r = 1, rowCount do
				local rowKids: { [string]: any } = {
					ListLayout = e("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 4),
					}),
				}
				for c = 1, perRow do
					local key = recents[(r - 1) * perRow + c]
					if key then
						local material, variant = Settings.DecodeRecentMaterial(key)
						rowKids["Chip" .. tostring(c)] = e(ChipForToggle, {
							-- Show the variant's own name when there is one; otherwise the
							-- dropdown's abbreviated material label (e.g. "Smooth P."),
							-- falling back to the raw material name when it has no label.
							-- ChipForToggle clips a long label to its own edge.
							Text = if variant ~= "" then variant else MaterialDropdown.GetLabel(material),
							IsCurrent = material == props.Settings.PaintMaterial
								and variant == props.Settings.PaintMaterialVariant,
							LayoutOrder = c,
							OnClick = function()
								selectRecent(key)
							end,
						})
					else
						rowKids["Empty" .. tostring(c)] = e("Frame", {
							Size = UDim2.new(0, 0, 0, 24),
							BackgroundTransparency = 1,
							LayoutOrder = c,
						}, {
							Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
						})
					end
				end
				rows["Row" .. tostring(r)] = e("Frame", {
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					LayoutOrder = r,
				}, rowKids)
			end
			return rows
		end)()),
		-- The Variant field sits below the recents.
		VariantRow = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundTransparency = 1,
			}, {
				ListLayout = e("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 4),
				}),
				Label = e("TextLabel", {
					Text = "Variant",
					TextColor3 = Colors.WHITE,
					BackgroundTransparency = 1,
					Size = UDim2.new(0, 0, 0, 24),
					AutomaticSize = Enum.AutomaticSize.X,
					Font = Enum.Font.SourceSans,
					TextSize = 18,
					TextXAlignment = Enum.TextXAlignment.Left,
					LayoutOrder = 1,
				}),
				Box = e("TextBox", {
					Text = props.Settings.PaintMaterialVariant,
					PlaceholderText = "(none)",
					PlaceholderColor3 = Color3.fromRGB(170, 170, 170),
					TextColor3 = Colors.WHITE,
					BackgroundColor3 = Colors.GREY,
					Size = UDim2.new(0, 0, 0, 24),
					Font = Enum.Font.SourceSans,
					TextSize = 18,
					TextXAlignment = Enum.TextXAlignment.Left,
					ClearTextOnFocus = false,
					LayoutOrder = 2,
					[React.Event.FocusLost] = function(rbx: TextBox)
						applyVariant(rbx.Text)
						-- Reflect the resolved value even when it didn't change (so no
						-- Text update was rendered) -- e.g. an invalid entry cleared to "".
						rbx.Text = props.Settings.PaintMaterialVariant
					end,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
					Padding = e("UIPadding", {
						PaddingLeft = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					}),
					Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
				}),
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Paint a <b>MaterialVariant</b> on top of the base material.<br />Type its name, or eyedrop a part that already has one. A valid name also switches the base material to match it, and is saved to the recents.<br />• unknown name — clears the field<br />• empty — no variant",
			}),
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
			Subject = e(Slider, {
				Label = "Radius",
				Value = props.Settings.PaintRadius,
				Min = 0,
				Max = 60,
				Step = 1,
				ValueChanged = function(newValue: number)
					props.Settings.PaintRadius = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Brush radius for painting. At zero, only the triangle under the cursor is painted.",
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
				HelpRichText = "How strongly each stroke blends the new color over what's there:<br />• <b>1</b> — full replace<br />• lower — tint toward it<br />(Material is always applied fully.)",
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
				HelpRichText = "What a click removes:<br />• <b>Face</b> — the single triangle under the cursor<br />• <b>Vertex</b> — a vertex and every triangle touching it",
			}),
		}),
		Radius = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 2,
			Subject = e(Slider, {
				Label = "Radius",
				Value = props.Settings.DeleteRadius,
				Min = 0,
				Max = 60,
				Step = 1,
				ValueChanged = function(newValue: number)
					props.Settings.DeleteRadius = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Brush radius for deleting faces. At zero, each click removes a single triangle. (Applies to <b>Face</b> only.)",
			}),
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
			Subject = e(Slider, {
				Label = "Radius",
				Value = props.Settings.RelaxRadius,
				Min = 1,
				Max = 60,
				Step = 1,
				ValueChanged = function(newValue: number)
					props.Settings.RelaxRadius = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "<b>Relax</b> slides vertices toward the average position of their neighbors to even out triangle spacing — heights stay put, and mesh edges stay pinned.<br /><br />This sets the brush radius, in studs.",
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
				HelpRichText = "How far each vertex slides toward its neighbors' average per stroke:<br />• <b>1</b> — all the way in one pass<br />• lower — a gentler nudge each pass",
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
			Subject = e(Slider, {
				Label = "Radius",
				Value = props.Settings.FlattenRadius,
				Min = 1,
				Max = 60,
				Step = 1,
				ValueChanged = function(newValue: number)
					props.Settings.FlattenRadius = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "<b>Flatten</b> smooths the surface by easing each vertex's height toward the average of its neighbors — left/right position stays put.<br /><br />This sets the brush radius, in studs.",
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
				HelpRichText = "How far each vertex's height moves toward its neighbors' average per stroke:<br />• <b>1</b> — fully smoothed in one pass<br />• lower — a gentler pass",
			}),
		}),
	})
end

local function HealPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Heal",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		RadiusInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Slider, {
				Label = "Radius",
				Value = props.Settings.HealRadius,
				Min = 1,
				Max = 60,
				Step = 1,
				ValueChanged = function(newValue: number)
					props.Settings.HealRadius = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "<b>Heal</b> repairs <i>tears</i> in the brushed area — where adjacent parts no longer line up. It merges loose vertices back together and folds split wedges back into whole triangles, restoring a continuous surface.<br /><br />This sets the brush radius, in studs.",
			}),
		}),
		ToleranceInput = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Tolerance",
				Value = props.Settings.HealTolerance,
				Unit = " studs",
				ValueEntered = function(newValue: number)
					if newValue > 0 then
						props.Settings.HealTolerance = newValue
						props.UpdatedSettings()
						return newValue
					end
					return nil
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "The largest gap that counts as a tear — two loose vertices closer than this get merged.<br />Raise it to close bigger tears; lower it to avoid merging things that should stay apart.",
			}),
		}),
	})
end

local function ConvertPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "Convert",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		TopShell = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 1,
			Subject = e(Checkbox, {
				Label = "Only use top shell",
				Checked = props.Settings.ConvertTopShellOnly,
				Changed = function(checked: boolean)
					props.Settings.ConvertTopShellOnly = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Only convert polygons whose normal faces at least somewhat upward"
					.. " — the walkable top surface of a terrain-like mesh — skipping its sides"
					.. " and underside.",
			}),
		}),
		DeleteOriginal = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 2,
			Subject = e(Checkbox, {
				Label = "Delete original",
				Checked = props.Settings.ConvertDeleteOriginal,
				Changed = function(checked: boolean)
					props.Settings.ConvertDeleteOriginal = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Remove the MeshPart after converting it, leaving just the generated"
					.. " polygons in its place. Undo brings it back.",
			}),
		}),
	})
end

-- Heal mode: optional limits that keep Heal from fusing geometry that merely
-- sits close together but was never meant to be contiguous.
local function HealLimitsPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Limitations",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, {
		SameColor = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Only Heal Same Color",
				Checked = props.Settings.HealSameColor,
				Changed = function(checked: boolean)
					props.Settings.HealSameColor = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Only stitch a tear when the parts on both sides share a <b>color</b>, so differently-colored geometry that just sits close together doesn't get fused.",
			}),
		}),
		SameMaterial = e(HelpGui.WithHelpIcon, {
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Only Heal Same Material",
				Checked = props.Settings.HealSameMaterial,
				Changed = function(checked: boolean)
					props.Settings.HealSameMaterial = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Only stitch a tear when the parts on both sides share a <b>material</b>, so differently-textured geometry that just sits close together doesn't get fused.",
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

-- The global Settings tab: a short how-to (Instructions), plus options that aren't
-- tied to any single editing mode (Settings).
local function InstructionsPanel(props: {
	LayoutOrder: number?,
})
	local function paragraph(order: number, text: string)
		return e("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			RichText = true,
			LayoutOrder = order,
			Text = text,
			TextColor3 = Colors.WHITE,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Font = Enum.Font.SourceSans,
			TextSize = 16,
		})
	end
	return e(SubPanel, {
		Title = "Instructions",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 3),
	}, {
		Intro = paragraph(1,
			"PolyMap lets you edit the Parts in your place by vertex, as though they formed a triangle mesh."),
		GetStarted = paragraph(2,
			"• To get started, pick <b>Move</b> or <b>Rotate</b>, click a vertex of one of your parts, and drag the handles."),
		Next = paragraph(3,
			"• Next, try adding new geometry with <b>Add Poly</b> or <b>Add Grid</b>."),
	})
end

local function SettingsPanel(props: {
	Settings: Settings.PolyMapSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "Settings",
		LayoutOrder = props.LayoutOrder,
		Padding = UDim.new(0, 8),
	}, {
		ShowVertices = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 1,
			Subject = e(Checkbox, {
				Label = "Show discovered vertices",
				Checked = props.Settings.ShowDiscoveredVertices,
				Changed = function(checked: boolean)
					props.Settings.ShowDiscoveredVertices = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Draw a faint dot on every vertex PolyMap has found, even unselected ones — handy for seeing the mesh's structure as you work.",
			}),
		}),
		VertexSize = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 2,
			Subject = e(Slider, {
				Label = "Vertex size",
				Value = props.Settings.DiscoveredVertexSize,
				Min = 0.1,
				Max = 2,
				Step = 0.05,
				ValueChanged = function(newValue: number)
					props.Settings.DiscoveredVertexSize = newValue
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Diameter of the discovered-vertex dots, in studs. They are a fixed world size, so distant ones look smaller.",
			}),
		}),
		Multiuser = e(HelpGui.WithHelpIcon, {
			LayoutOrder = 3,
			Subject = e(Checkbox, {
				Label = "Multiuser support (slow)",
				Checked = props.Settings.MultiuserSupport,
				Changed = function(checked: boolean)
					props.Settings.MultiuserSupport = checked
					props.UpdatedSettings()
				end,
			}),
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Watch every discovered part for edits made by other Team Create users, and refresh"
					.. " PolyMap's data for parts they change.<br /><br />Makes editing roughly 30% slower,"
					.. " so leave it off when working alone. When off, PolyMap instead shows a warning if"
					.. " another user edits while you work.",
			}),
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
	local showSettings = mode == "Settings"
	local showInfluence = mode == "Move" or mode == "Rotate"
	local showDelete = mode == "Delete"
	local showPaint = mode == "Paint"
	local showGrid = mode == "Generate"
	local showImport = mode == "Import"
	local showThickness = mode == "Add" or mode == "Generate" or mode == "Import" or mode == "Convert"
	local showRelax = mode == "Relax"
	local showFlatten = mode == "Flatten"
	local showHeal = mode == "Heal"
	local showConvert = mode == "Convert"

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
			local showSelection = mode == "Move" or mode == "Rotate"
			-- In Delete/Vertex mode, surface the hovered vertex so the overlay can mark
			-- which vertex a click would delete (the triangle fan is shown via the outline).
			local isDeleteVertex = mode == "Delete" and currentSettings.DeleteTarget == "Vertex"
			local overlayProps: { [string]: any } = {
				Mesh = mesh,
				SelectedVertices = if showSelection then session.GetSelectedVertices() else nil,
				HoverVertexId = if showSelection or isDeleteVertex then session.GetHoverVertexId() else nil,
				HoverVertexIsDelete = isDeleteVertex,
				OutlineTriangleIds = session.GetOutlineTriangleIds(),
				HoverOutlineTriangleIds = session.GetHoverOutlineTriangleIds(),
				MarqueeStart = session.GetMarquee(),
				MarqueeEnd = select(2, session.GetMarquee()),
				ShowDiscoveredVertices = currentSettings.ShowDiscoveredVertices,
				DiscoveredVertexSize = currentSettings.DiscoveredVertexSize,
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
					-- Phase 1: highlight the hovered boundary edge...
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

					-- ...or, for empty-space placement, preview the fresh corners
					-- placed so far plus the current hover point (a triangle outline
					-- once three corners are present).
					local points = session.GetAddPoints()
					local target = session.GetAddHoverTarget()
					if target and target.type == "freshVertex" and target.position then
						table.insert(points, target.position)
					end
					if #points > 0 then
						overlayProps.AddPreviewPolyline = points
					end
				end
			end

			-- Grid placement preview (independent of mode; only set while placing).
			overlayProps.GridPreviewLines = session.GetGridPreviewLines()

			return overlayProps
		end)()),
		Content = e(React.Fragment, nil, {
			ModePanel = e(ModePanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			InstructionsPanel = showSettings and e(InstructionsPanel, {
				LayoutOrder = nextOrder(),
			}),
			SettingsPanel = showSettings and e(SettingsPanel, {
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
				ShowMatchThickness = mode == "Add",
			}),
			FreePointsPanel = (mode == "Add") and e(FreePointsPanel, {
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
			HealPanel = showHeal and e(HealPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			HealLimitsPanel = showHeal and e(HealLimitsPanel, {
				Settings = currentSettings,
				UpdatedSettings = props.UpdatedSettings,
				LayoutOrder = nextOrder(),
			}),
			ConvertPanel = showConvert and e(ConvertPanel, {
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
			-- One toast at a time: a fresh error outranks the standing conflict warning.
			Toast = session and (function()
				local errorText = session.GetErrorToast()
				if errorText then
					return e(Toast, {
						Text = errorText,
						AccentColor = Colors.DARK_RED,
						OnDismiss = session.DismissErrorToast,
					})
				end
				if session.GetConflictWarning() then
					return e(Toast, {
						Text = "<b>PolyMap:</b> Another user just edited this place with PolyMap. If you both"
							.. " edit the same polygons this may lead to poor results.<br />Reopen PolyMap to"
							.. " refresh the data or turn on <b>Multiuser Support</b> in the Settings to"
							.. " automatically avoid conflicts at some perf cost.",
						AccentColor = Colors.WARNING_YELLOW,
						OnDismiss = session.DismissConflictWarning,
					})
				end
				return nil
			end)() or nil,
		}),
	})
end

return PolyMapGui
