--!strict

local Signal = require(script.Parent.Parent.Packages.Signal)
local Settings = require("./Settings")

local function createPolyMapSession(plugin: Plugin, currentSettings: Settings.PolyMapSettings)
	local session = {}
	local changeSignal = Signal.new()

	session.ChangeSignal = changeSignal
	session.Update = function()
		-- Settings may have changed
	end
	session.Destroy = function()
		-- Teardown
	end

	-- Accessors for UI
	session.GetSelectedVertexCount = function(): number
		return 0
	end
	session.GetMode = function(): string
		return currentSettings.Mode
	end

	return session
end

export type PolyMapSession = typeof(createPolyMapSession(...))

return createPolyMapSession
