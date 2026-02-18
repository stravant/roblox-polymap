--!strict

local fillTriangle = require("./fillTriangle")

export type GridParams = {
	GridType: string, -- "Square" or "Triangular"
	Width: number, -- number of cells wide
	Height: number, -- number of cells tall
	Spacing: number, -- distance between adjacent vertices
	Origin: CFrame, -- center CFrame of the grid
	Thickness: number,
	Parent: Instance,
	Props: fillTriangle.TriangleProps?,
}

local function generateSquareGrid(params: GridParams)
	local cols = params.Width
	local rows = params.Height
	local spacing = params.Spacing
	local origin = params.Origin

	-- Grid is centered on origin
	local halfW = cols * spacing / 2
	local halfH = rows * spacing / 2

	-- Generate vertices in a (cols+1) x (rows+1) grid
	local vertices: { { Vector3 } } = {}
	for r = 0, rows do
		local row: { Vector3 } = {}
		for c = 0, cols do
			local localPos = Vector3.new(c * spacing - halfW, 0, r * spacing - halfH)
			local worldPos = origin:PointToWorldSpace(localPos)
			table.insert(row, worldPos)
		end
		table.insert(vertices, row)
	end

	-- Each cell produces 2 triangles
	for r = 1, rows do
		for c = 1, cols do
			local tl = vertices[r][c]
			local tr = vertices[r][c + 1]
			local bl = vertices[r + 1][c]
			local br = vertices[r + 1][c + 1]

			-- Triangle 1: tl, tr, bl
			fillTriangle(tl, tr, bl, params.Thickness, params.Parent, params.Props)
			-- Triangle 2: tr, br, bl
			fillTriangle(tr, br, bl, params.Thickness, params.Parent, params.Props)
		end
	end
end

local function generateTriangularGrid(params: GridParams)
	local cols = params.Width
	local rows = params.Height
	local spacing = params.Spacing
	local origin = params.Origin

	-- Equilateral triangle layout: row height = spacing * sqrt(3)/2
	local rowHeight = spacing * math.sqrt(3) / 2

	local halfW = cols * spacing / 2
	local halfH = rows * rowHeight / 2

	-- Generate vertices: odd rows offset by spacing/2
	local vertices: { { Vector3 } } = {}
	for r = 0, rows do
		local row: { Vector3 } = {}
		local xOffset = if r % 2 == 1 then spacing / 2 else 0
		for c = 0, cols do
			local localPos = Vector3.new(c * spacing + xOffset - halfW, 0, r * rowHeight - halfH)
			local worldPos = origin:PointToWorldSpace(localPos)
			table.insert(row, worldPos)
		end
		table.insert(vertices, row)
	end

	-- Connect triangles between rows
	for r = 1, rows do
		local isOddRow = (r % 2 == 1)
		for c = 1, cols do
			local top = vertices[r][c]
			local topRight = vertices[r][c + 1]
			local bottom = vertices[r + 1][c]
			local bottomRight = vertices[r + 1][c + 1]

			if isOddRow then
				-- Odd row is shifted right, so connect:
				-- Vertex order is rotated so that the split edge (CA for
				-- equilateral) is NOT the shared diagonal (top ↔ bottomRight).
				-- upward triangle: split along top→bottom (left edge)
				fillTriangle(bottom, bottomRight, top, params.Thickness, params.Parent, params.Props)
				-- downward triangle: split along top→topRight (top edge)
				fillTriangle(topRight, bottomRight, top, params.Thickness, params.Parent, params.Props)
			else
				-- Even row connects:
				-- Vertex order rotated to avoid splitting on the shared
				-- diagonal (topRight ↔ bottom).
				-- downward triangle: split along bottom→top (left edge) — already correct
				fillTriangle(top, topRight, bottom, params.Thickness, params.Parent, params.Props)
				-- upward triangle: split along topRight→bottomRight (right edge)
				fillTriangle(bottomRight, bottom, topRight, params.Thickness, params.Parent, params.Props)
			end
		end
	end
end

local function generateGrid(params: GridParams)
	if params.GridType == "Triangular" then
		generateTriangularGrid(params)
	else
		generateSquareGrid(params)
	end
end

return generateGrid
