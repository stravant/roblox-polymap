--!strict

local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)

local getWedgeVertices = require("./getWedgeVertices")

local e = React.createElement

-- Render a right-angle triangle using two ConeHandleAdornments.
-- B must be the vertex at the right angle.
local function RightAngleTriangleAdornment(props: {
	A: Vector3,
	B: Vector3,
	C: Vector3,
	Transparency: number,
	ZIndexOffset: number?,
	Color: Color3,
})
	local ab = (props.B - props.A)
	local bc = (props.C - props.B)
	local normal = ab:Cross(bc)
	if normal.Magnitude < 0.0001 then
		return nil
	end
	normal = normal.Unit
	local mid = (props.A + props.C) * 0.5
	local abmid = (props.A + 0.5 * ab)
	local bcmid = (props.B + 0.5 * bc)

	return e(React.Fragment, nil, {
		A = e("ConeHandleAdornment", {
			Adornee = workspace.Terrain,
			Height = (mid - abmid).Magnitude,
			Radius = ab.Magnitude / 2,
			CFrame = CFrame.fromMatrix(abmid, ab.Unit, Vector3.zero, ab.Unit:Cross(normal).Unit),
			ZIndex = 1 + (props.ZIndexOffset or 0),
			AlwaysOnTop = true,
			Transparency = props.Transparency,
			Color3 = props.Color,
		}),
		B = e("ConeHandleAdornment", {
			Adornee = workspace.Terrain,
			Height = (mid - bcmid).Magnitude,
			Radius = bc.Magnitude / 2,
			CFrame = CFrame.fromMatrix(bcmid, ab.Unit:Cross(normal).Unit, Vector3.zero, ab.Unit),
			ZIndex = 1 + (props.ZIndexOffset or 0),
			AlwaysOnTop = true,
			Transparency = props.Transparency,
			Color3 = props.Color,
		}),
	})
end

-- Highlight a mesh triangle by rendering its wedge parts as right-angle triangles.
local function TriangleHighlight(props: {
	Parts: { BasePart },
	Color: Color3,
	Transparency: number,
	ZIndexOffset: number?,
})
	local children: { [string]: any } = {}
	for i, part in props.Parts do
		-- v1 is the right-angle vertex from getWedgeVertices
		local v1, v2, v3 = getWedgeVertices(part)
		children["P" .. tostring(i)] = e(RightAngleTriangleAdornment, {
			A = v2,
			B = v1,
			C = v3,
			Color = props.Color,
			Transparency = props.Transparency,
			ZIndexOffset = props.ZIndexOffset,
		})
	end
	return e(React.Fragment, nil, children)
end

return TriangleHighlight
