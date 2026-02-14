--!strict

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)

local PluginGui = require("./PluginGui/PluginGui")
local PluginGuiTypes = require("./PluginGui/Types")
local Settings = require("./Settings")
local createPolyMapSession = require("./createPolyMapSession")

local e = React.createElement

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
		-- Placeholder: will be filled in Phase 12
	})
end

return PolyMapGui
