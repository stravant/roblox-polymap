--!strict

local fillTriangle = require("./fillTriangle")

local kYieldCellInterval = 200 -- yield every N cells (2 triangles each)

-- Build the wedge mesh for a (rows+1) x (cols+1) grid of world-space vertices,
-- colouring each triangle by the average of its three vertex colours.
--
-- Triangles are generated facing UP: the heightmap surface (the input vertices)
-- is the smooth top face and the wedge thickness hangs BELOW it. fillTriangle
-- puts the wedges on the opposite side of the triangle normal, and the natural
-- winding here (tl, tr, bl) yields a downward normal -- which would push the
-- thickness up and leave the gappy underside facing the camera. invertNormal
-- flips that so the surface reads correctly when viewed from above.
local function buildHeightmapMesh(
	vertices: { { Vector3 } },
	vertexColors: { { { number } } },
	thickness: number,
	parent: Instance,
	onProgress: ((fraction: number) -> ())?
)
	local rows = #vertices - 1
	local cols = #vertices[1] - 1
	local totalCells = rows * cols
	local cellsDone = 0
	local cellsSinceYield = 0

	for r = 1, rows do
		for c = 1, cols do
			local tl = vertices[r][c]
			local tr = vertices[r][c + 1]
			local bl = vertices[r + 1][c]
			local br = vertices[r + 1][c + 1]

			local ctlr = vertexColors[r][c]
			local ctrr = vertexColors[r][c + 1]
			local cblr = vertexColors[r + 1][c]
			local cbrr = vertexColors[r + 1][c + 1]

			-- Triangle 1: tl, tr, bl - average of 3 vertex colors
			local r1 = (ctlr[1] + ctrr[1] + cblr[1]) / 3
			local g1 = (ctlr[2] + ctrr[2] + cblr[2]) / 3
			local b1 = (ctlr[3] + ctrr[3] + cblr[3]) / 3
			fillTriangle(tl, tr, bl, thickness, parent, { Color = Color3.new(r1, g1, b1) }, nil, true)

			-- Triangle 2: tr, br, bl - average of 3 vertex colors
			local r2 = (ctrr[1] + cbrr[1] + cblr[1]) / 3
			local g2 = (ctrr[2] + cbrr[2] + cblr[2]) / 3
			local b2 = (ctrr[3] + cbrr[3] + cblr[3]) / 3
			fillTriangle(tr, br, bl, thickness, parent, { Color = Color3.new(r2, g2, b2) }, nil, true)

			cellsDone += 1
			cellsSinceYield += 1
			if cellsSinceYield >= kYieldCellInterval then
				cellsSinceYield = 0
				if onProgress then
					onProgress(cellsDone / totalCells)
				end
				task.wait()
			end
		end
	end
end

return buildHeightmapMesh
