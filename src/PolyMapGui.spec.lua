--!strict

local CoreGui = game:GetService("CoreGui")

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local ConflictToast = require("./ConflictToast")
local PolyMapGui = require("./PolyMapGui")
local Settings = require("./Settings")
local TestTypes = require("./TestTypes")

local e = React.createElement

local ALL_MODES = { "Settings", "Move", "Rotate", "Add", "Delete", "Paint", "Generate", "Import", "Relax", "Flatten", "Heal" }

local function makeSettings(mode: string): Settings.PolyMapSettings
	return {
		WindowPosition = Vector2.new(24, 24),
		WindowAnchor = Vector2.zero,
		WindowHeightDelta = 0,
		HaveHelp = true,
		DoneTutorial = true,

		Mode = mode,
		ShowDiscoveredVertices = false,
		DiscoveredVertexSize = 0.4,
		MultiuserSupport = false,
		DeleteTarget = "Face",
		DeleteRadius = 0,
		PaintRadius = 0,
		Thickness = 0.2,
		MatchThickness = true,
		AddNonSnapped = "Extend",
		InfluenceRadius = 10,
		InfluenceFalloff = "Smooth",
		GridType = "Square",
		GridWidth = 10,
		GridHeight = 10,
		GridSpacing = 4,
		PaintColor = { 0.5, 0.5, 0.5 },
		PaintMaterial = "Plastic",
		PaintMaterialVariant = "",
		PaintStrength = 1.0,
		PaintEyedropper = "None",
		RelaxRadius = 5,
		RelaxStrength = 0.5,
		FlattenRadius = 5,
		FlattenStrength = 0.5,
		HealRadius = 5,
		HealTolerance = 1,
		HealSameColor = false,
		HealSameMaterial = false,
		ImportImageId = "",
		ImportWidth = 50,
		ImportHeight = 50,
		ImportSpacing = 4,
		ImportMinY = 0,
		ImportMaxY = 50,
		RecentMaterials = { "Plastic", "Grass", "Concrete", "Rock", "Sand", "Brick", "Wood" },
		RecentColors = { { 0.5, 0.5, 0.5 } },
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

	t.test("conflict toast mounts into CoreGui and unmounts cleanly", function()
		local screen = Instance.new("ScreenGui")
		screen.Name = "$PolyMapToastTest"
		screen.Parent = CoreGui

		local root = ReactRoblox.createRoot(screen)
		local ok, err = pcall(function()
			ReactRoblox.act(function()
				root:render(e(ConflictToast, {
					OnDismiss = function() end,
				}))
			end)

			-- The toast portals into its own ScreenGui over the viewport, with the
			-- message and dismiss affordance present.
			local toastGui = CoreGui:FindFirstChild("PolyMapConflictToast")
			t.expect(toastGui ~= nil).toBe(true)
			local frame = (toastGui :: Instance):FindFirstChild("Toast")
			t.expect(frame ~= nil).toBe(true)
			t.expect((frame :: Instance):FindFirstChild("Message") ~= nil).toBe(true)
			t.expect((frame :: Instance):FindFirstChild("DismissButton") ~= nil).toBe(true)
		end)

		ReactRoblox.act(function()
			root:unmount()
		end)
		screen:Destroy()

		if not ok then
			error(err)
		end
		t.expect(CoreGui:FindFirstChild("PolyMapConflictToast")).toBe(nil)
	end)
end
