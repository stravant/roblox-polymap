--!strict

local InitialPosition = Vector2.new(24, 24)
local kSettingsKey = "polyMapState"

local PluginGuiTypes = require("./PluginGui/Types")

export type PolyMapSettings = PluginGuiTypes.PluginGuiSettings & {
	Mode: string,
	Thickness: number,
	InfluenceRadius: number,
	InfluenceFalloff: string,
	GridType: string,
	GridWidth: number,
	GridHeight: number,
	GridSpacing: number,
	PaintColor: { number },
	PaintMaterial: string,
}

local function loadSettings(plugin: Plugin): PolyMapSettings
	local raw = plugin:GetSetting(kSettingsKey) or {}
	return {
		WindowPosition = Vector2.new(
			raw.WindowPositionX or InitialPosition.X,
			raw.WindowPositionY or InitialPosition.Y
		),
		WindowAnchor = Vector2.new(
			raw.WindowAnchorX or 0,
			raw.WindowAnchorY or 0
		),
		WindowHeightDelta = if raw.WindowHeightDelta ~= nil then raw.WindowHeightDelta else 0,
		HaveHelp = if raw.HaveHelp ~= nil then raw.HaveHelp else true,
		DoneTutorial = if raw.DoneTutorial ~= nil then raw.DoneTutorial else false,

		Mode = raw.Mode or "Select",
		Thickness = raw.Thickness or 0.2,
		InfluenceRadius = raw.InfluenceRadius or 10,
		InfluenceFalloff = raw.InfluenceFalloff or "Smooth",
		GridType = raw.GridType or "Square",
		GridWidth = raw.GridWidth or 10,
		GridHeight = raw.GridHeight or 10,
		GridSpacing = raw.GridSpacing or 4,
		PaintColor = raw.PaintColor or { 0.294, 0.592, 0.294 },
		PaintMaterial = raw.PaintMaterial or "Grass",
	}
end

local function saveSettings(plugin: Plugin, settings: PolyMapSettings)
	plugin:SetSetting(kSettingsKey, {
		WindowPositionX = settings.WindowPosition.X,
		WindowPositionY = settings.WindowPosition.Y,
		WindowAnchorX = settings.WindowAnchor.X,
		WindowAnchorY = settings.WindowAnchor.Y,
		WindowHeightDelta = settings.WindowHeightDelta,
		HaveHelp = settings.HaveHelp,
		DoneTutorial = settings.DoneTutorial,

		Mode = settings.Mode,
		Thickness = settings.Thickness,
		InfluenceRadius = settings.InfluenceRadius,
		InfluenceFalloff = settings.InfluenceFalloff,
		GridType = settings.GridType,
		GridWidth = settings.GridWidth,
		GridHeight = settings.GridHeight,
		GridSpacing = settings.GridSpacing,
		PaintColor = settings.PaintColor,
		PaintMaterial = settings.PaintMaterial,
	})
end

return {
	Load = loadSettings,
	Save = saveSettings,
}
