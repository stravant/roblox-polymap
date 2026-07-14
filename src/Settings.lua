--!strict

local InitialPosition = Vector2.new(24, 24)
local kSettingsKey = "polyMapState"

local PluginGuiTypes = require("./PluginGui/Types")

export type PolyMapSettings = PluginGuiTypes.PluginGuiSettings & {
	Mode: string,
	ShowDiscoveredVertices: boolean,
	DiscoveredVertexSize: number,
	MultiuserSupport: boolean,
	DeleteTarget: string,
	DeleteRadius: number,
	PaintRadius: number,
	Thickness: number,
	MatchThickness: boolean,
	AddNonSnapped: string,
	InfluenceRadius: number,
	InfluenceFalloff: string,
	GridType: string,
	GridWidth: number,
	GridHeight: number,
	GridSpacing: number,
	PaintColor: { number },
	PaintMaterial: string,
	PaintMaterialVariant: string,
	PaintStrength: number,
	PaintTarget: string,
	PaintEyedropper: string, -- "None" | "Color" | "Material"
	RelaxRadius: number,
	RelaxStrength: number,
	FlattenRadius: number,
	FlattenStrength: number,
	HealRadius: number,
	HealTolerance: number,
	HealSameColor: boolean,
	HealSameMaterial: boolean,
	ConvertTopShellOnly: boolean,
	ImportImageId: string,
	ImportWidth: number,
	ImportHeight: number,
	ImportSpacing: number,
	ImportMinY: number,
	ImportMaxY: number,
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

		Mode = raw.Mode or "Settings",
		ShowDiscoveredVertices = if raw.ShowDiscoveredVertices ~= nil then raw.ShowDiscoveredVertices else true,
		DiscoveredVertexSize = raw.DiscoveredVertexSize or 0.4,
		MultiuserSupport = if raw.MultiuserSupport ~= nil then raw.MultiuserSupport else false,
		DeleteTarget = raw.DeleteTarget or "Face",
		DeleteRadius = raw.DeleteRadius or 0,
		PaintRadius = raw.PaintRadius or 0,
		Thickness = raw.Thickness or 0.2,
		MatchThickness = if raw.MatchThickness ~= nil then raw.MatchThickness else true,
		AddNonSnapped = raw.AddNonSnapped or "Extend",
		InfluenceRadius = raw.InfluenceRadius or 10,
		InfluenceFalloff = raw.InfluenceFalloff or "Smooth",
		GridType = raw.GridType or "Square",
		GridWidth = raw.GridWidth or 16,
		GridHeight = raw.GridHeight or 16,
		GridSpacing = raw.GridSpacing or 8,
		PaintColor = raw.PaintColor or { 0.294, 0.592, 0.294 },
		PaintMaterial = raw.PaintMaterial or "Grass",
		PaintMaterialVariant = raw.PaintMaterialVariant or "",
		PaintStrength = raw.PaintStrength or 1.0,
		PaintTarget = raw.PaintTarget or "Both",
		PaintEyedropper = "None",
		RelaxRadius = raw.RelaxRadius or 5,
		RelaxStrength = raw.RelaxStrength or 0.5,
		FlattenRadius = raw.FlattenRadius or 5,
		FlattenStrength = raw.FlattenStrength or 0.5,
		HealRadius = raw.HealRadius or 5,
		HealTolerance = raw.HealTolerance or 1,
		HealSameColor = if raw.HealSameColor ~= nil then raw.HealSameColor else false,
		HealSameMaterial = if raw.HealSameMaterial ~= nil then raw.HealSameMaterial else false,
		ConvertTopShellOnly = if raw.ConvertTopShellOnly ~= nil then raw.ConvertTopShellOnly else true,
		ImportImageId = raw.ImportImageId or "",
		ImportWidth = raw.ImportWidth or 32,
		ImportHeight = raw.ImportHeight or 32,
		ImportSpacing = raw.ImportSpacing or 8,
		ImportMinY = raw.ImportMinY or 0,
		ImportMaxY = raw.ImportMaxY or 50,
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
		ShowDiscoveredVertices = settings.ShowDiscoveredVertices,
		DiscoveredVertexSize = settings.DiscoveredVertexSize,
		MultiuserSupport = settings.MultiuserSupport,
		DeleteTarget = settings.DeleteTarget,
		DeleteRadius = settings.DeleteRadius,
		PaintRadius = settings.PaintRadius,
		Thickness = settings.Thickness,
		MatchThickness = settings.MatchThickness,
		AddNonSnapped = settings.AddNonSnapped,
		InfluenceRadius = settings.InfluenceRadius,
		InfluenceFalloff = settings.InfluenceFalloff,
		GridType = settings.GridType,
		GridWidth = settings.GridWidth,
		GridHeight = settings.GridHeight,
		GridSpacing = settings.GridSpacing,
		PaintColor = settings.PaintColor,
		PaintMaterial = settings.PaintMaterial,
		PaintMaterialVariant = settings.PaintMaterialVariant,
		PaintStrength = settings.PaintStrength,
		PaintTarget = settings.PaintTarget,
		RelaxRadius = settings.RelaxRadius,
		RelaxStrength = settings.RelaxStrength,
		FlattenRadius = settings.FlattenRadius,
		FlattenStrength = settings.FlattenStrength,
		HealRadius = settings.HealRadius,
		HealTolerance = settings.HealTolerance,
		HealSameColor = settings.HealSameColor,
		HealSameMaterial = settings.HealSameMaterial,
		ConvertTopShellOnly = settings.ConvertTopShellOnly,
		ImportImageId = settings.ImportImageId,
		ImportWidth = settings.ImportWidth,
		ImportHeight = settings.ImportHeight,
		ImportSpacing = settings.ImportSpacing,
		ImportMinY = settings.ImportMinY,
		ImportMaxY = settings.ImportMaxY,
		RecentMaterials = settings.RecentMaterials,
		RecentColors = settings.RecentColors,
	})
end

-- Recent materials are stored as opaque keys so a (base material, variant) pair can
-- be a single history entry. A plain material name (no variant) is stored as-is, so
-- older saved histories of bare names still decode correctly.
local kRecentSeparator = "\31"
local function encodeRecentMaterial(material: string, variant: string): string
	return if variant ~= "" then material .. kRecentSeparator .. variant else material
end
local function decodeRecentMaterial(key: string): (string, string)
	local i = string.find(key, kRecentSeparator, 1, true)
	if i then
		return string.sub(key, 1, i - 1), string.sub(key, i + 1)
	end
	return key, ""
end

return {
	Load = loadSettings,
	Save = saveSettings,
	EncodeRecentMaterial = encodeRecentMaterial,
	DecodeRecentMaterial = decodeRecentMaterial,
}
