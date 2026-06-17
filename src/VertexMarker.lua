--!strict

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)

local e = React.createElement

local function VertexMarker(props: {
	Position: Vector3,
	Color: Color3,
	Radius: any, -- number, or a React binding<number> (so it can resize on camera move)
	ZIndexOffset: number?,
	Transparency: number?,
	AlwaysOnTop: boolean?,
})
	return e("SphereHandleAdornment", {
		CFrame = CFrame.new(props.Position),
		Adornee = workspace.Terrain,
		ZIndex = 0 + (props.ZIndexOffset or 0),
		Radius = props.Radius,
		Color3 = props.Color,
		Transparency = props.Transparency or 0,
		AlwaysOnTop = if props.AlwaysOnTop ~= nil then props.AlwaysOnTop else true,
	})
end

return VertexMarker
