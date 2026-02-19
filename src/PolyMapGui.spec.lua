--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local PolyMapGui = require("./PolyMapGui")
local Settings = require("./Settings")
local TestTypes = require("./TestTypes")

local e = React.createElement

local ALL_MODES = { "Select", "Move", "Rotate", "Add", "Delete", "Paint", "Generate", "Subdivide", "Simplify", "Relax", "Flatten" }

local function makeSettings(mode: string): Settings.PolyMapSettings
	return {
		WindowPosition = Vector2.new(24, 24),
		WindowAnchor = Vector2.zero,
		WindowHeightDelta = 0,
		HaveHelp = true,
		DoneTutorial = true,

		Mode = mode,
		DeleteTarget = "Face",
		DeleteRadius = 0,
		PaintRadius = 0,
		Thickness = 0.2,
		InfluenceRadius = 10,
		InfluenceFalloff = "Smooth",
		GridType = "Square",
		GridWidth = 10,
		GridHeight = 10,
		GridSpacing = 4,
		PaintColor = { 0.5, 0.5, 0.5 },
		PaintMaterial = "Plastic",
		PaintStrength = 1.0,
		PaintEyedropper = false,
		RelaxRadius = 5,
		RelaxStrength = 0.5,
		FlattenRadius = 5,
		FlattenStrength = 0.5,
	}
end

return function(t: TestTypes.TestContext)
	for _, mode in ALL_MODES do
		t.test(`renders without error in {mode} mode`, function()
			local screen = Instance.new("ScreenGui")
			screen.Name = "$PolyMapGuiTest"
			screen.Parent = CoreGui

			local settings = makeSettings(mode)
			local root = ReactRoblox.createRoot(screen)

			-- This will throw if the element tree is malformed
			local ok, err = pcall(function()
				ReactRoblox.act(function()
					root:render(e(PolyMapGui, {
						GuiState = "active" :: any,
						CurrentSettings = settings,
						UpdatedSettings = function() end,
						HandleAction = function() end,
						Panelized = false,
						Session = nil,
					}))
				end)
			end)

			-- Clean up before asserting so we don't leak on failure
			ReactRoblox.act(function()
				root:unmount()
			end)
			screen:Destroy()

			t.expect(ok).toBe(true)
		end)
	end
end
