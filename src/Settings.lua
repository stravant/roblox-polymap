--!strict

local InitialPosition = Vector2.new(24, 24)
local kSettingsKey = "polyMapState"

local PluginGuiTypes = require("./PluginGui/Types")

export type PolyMapSettings = PluginGuiTypes.PluginGuiSettings & {
	Mode: string,
	DeleteTarget: string,
	DeleteRadius: number,
	PaintRadius: number,
	Thickness: number,
	InfluenceRadius: number,
	InfluenceFalloff: string,
	GridType: string,
	GridWidth: number,
	GridHeight: number,
	GridSpacing: number,
	PaintColor: { number },
	PaintMaterial: string,
	PaintStrength: number,
	PaintTarget: string,
	PaintEyedropper: boolean,
	RelaxRadius: number,
	RelaxStrength: number,
	FlattenRadius: number,
	FlattenStrength: number,
	ImportImageId: string,
	ImportWidth: number,
	ImportHeight: number,
	ImportSpacing: number,
	ImportHeightScale: number,
	RecentMaterials: { string },
	RecentColors: { { number } },
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
		DeleteTarget = raw.DeleteTarget or "Face",
		DeleteRadius = raw.DeleteRadius or 0,
		PaintRadius = raw.PaintRadius or 0,
		Thickness = raw.Thickness or 0.2,
		InfluenceRadius = raw.InfluenceRadius or 10,
		InfluenceFalloff = raw.InfluenceFalloff or "Smooth",
		GridType = raw.GridType or "Square",
		GridWidth = raw.GridWidth or 10,
		GridHeight = raw.GridHeight or 10,
		GridSpacing = raw.GridSpacing or 4,
		PaintColor = raw.PaintColor or { 0.294, 0.592, 0.294 },
		PaintMaterial = raw.PaintMaterial or "Grass",
		PaintStrength = raw.PaintStrength or 1.0,
		PaintTarget = raw.PaintTarget or "Both",
		PaintEyedropper = false,
		RelaxRadius = raw.RelaxRadius or 5,
		RelaxStrength = raw.RelaxStrength or 0.5,
		FlattenRadius = raw.FlattenRadius or 5,
		FlattenStrength = raw.FlattenStrength or 0.5,
		ImportImageId = raw.ImportImageId or "",
		ImportWidth = raw.ImportWidth or 50,
		ImportHeight = raw.ImportHeight or 50,
		ImportSpacing = raw.ImportSpacing or 4,
		ImportHeightScale = raw.ImportHeightScale or 50,
		RecentMaterials = raw.RecentMaterials or { "Grass", "Plastic", "Concrete" },
		RecentColors = raw.RecentColors or { { 0.294, 0.592, 0.294 } },
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
		DeleteTarget = settings.DeleteTarget,
		DeleteRadius = settings.DeleteRadius,
		PaintRadius = settings.PaintRadius,
		Thickness = settings.Thickness,
		InfluenceRadius = settings.InfluenceRadius,
		InfluenceFalloff = settings.InfluenceFalloff,
		GridType = settings.GridType,
		GridWidth = settings.GridWidth,
		GridHeight = settings.GridHeight,
		GridSpacing = settings.GridSpacing,
		PaintColor = settings.PaintColor,
		PaintMaterial = settings.PaintMaterial,
		PaintStrength = settings.PaintStrength,
		PaintTarget = settings.PaintTarget,
		RelaxRadius = settings.RelaxRadius,
		RelaxStrength = settings.RelaxStrength,
		FlattenRadius = settings.FlattenRadius,
		FlattenStrength = settings.FlattenStrength,
		ImportImageId = settings.ImportImageId,
		ImportWidth = settings.ImportWidth,
		ImportHeight = settings.ImportHeight,
		ImportSpacing = settings.ImportSpacing,
		ImportHeightScale = settings.ImportHeightScale,
		RecentMaterials = settings.RecentMaterials,
		RecentColors = settings.RecentColors,
	})
end

return {
	Load = loadSettings,
	Save = saveSettings,
}
