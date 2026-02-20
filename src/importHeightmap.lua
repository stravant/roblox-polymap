--!strict

local AssetService = game:GetService("AssetService")

local fillTriangle = require("./fillTriangle")

export type ImportParams = {
	ImageId: string,
	Width: number, -- number of cells wide
	Height: number, -- number of cells tall
	Spacing: number, -- distance between adjacent vertices
	HeightScale: number, -- max height from luminance
	Origin: CFrame, -- center CFrame of the grid
	Thickness: number,
	Parent: Instance,
	OnProgress: ((fraction: number) -> ())?,
}

local kYieldInterval = 5 -- yield every N rows of triangles

local function importHeightmap(params: ImportParams)
	local imageId = params.ImageId
	local cols = params.Width
	local rows = params.Height
	local spacing = params.Spacing
	local heightScale = params.HeightScale
	local origin = params.Origin
	local thickness = params.Thickness
	local parent = params.Parent
	local onProgress = params.OnProgress

	-- Load the image
	if onProgress then
		onProgress(0)
	end
	local editableImage = AssetService:CreateEditableImageAsync(Content.fromUri("rbxassetid://" .. imageId))
	local imageSize = editableImage.Size
	local imageW = imageSize.X
	local imageH = imageSize.Y

	-- Read all pixels into a buffer
	local pixelBuffer = editableImage:ReadPixelsBuffer(Vector2.zero, imageSize)

	-- Helper to sample a pixel at UV coordinates (0-1 range)
	-- Returns r, g, b as 0-1 floats
	local function samplePixel(u: number, v: number): (number, number, number)
		local px = math.clamp(math.floor(u * (imageW - 1) + 0.5), 0, imageW - 1)
		local py = math.clamp(math.floor(v * (imageH - 1) + 0.5), 0, imageH - 1)
		local offset = (py * imageW + px) * 4
		local r = buffer.readu8(pixelBuffer, offset) / 255
		local g = buffer.readu8(pixelBuffer, offset + 1) / 255
		local b = buffer.readu8(pixelBuffer, offset + 2) / 255
		return r, g, b
	end

	-- Grid is centered on origin
	local halfW = cols * spacing / 2
	local halfH = rows * spacing / 2

	-- Build (cols+1) x (rows+1) vertex grid with heights from image luminance
	local vertices: { { Vector3 } } = {}
	local vertexColors: { { { number } } } = {}
	for r = 0, rows do
		local row: { Vector3 } = {}
		local colorRow: { { number } } = {}
		local v = r / rows -- UV v coordinate
		for c = 0, cols do
			local u = c / cols -- UV u coordinate
			local pr, pg, pb = samplePixel(u, v)
			local luminance = 0.299 * pr + 0.587 * pg + 0.114 * pb
			local localPos = Vector3.new(c * spacing - halfW, luminance * heightScale, r * spacing - halfH)
			local worldPos = origin:PointToWorldSpace(localPos)
			table.insert(row, worldPos)
			table.insert(colorRow, { pr, pg, pb })
		end
		table.insert(vertices, row)
		table.insert(vertexColors, colorRow)
	end

	-- Each cell produces 2 triangles, colored by averaging vertex colors
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
			local props1: fillTriangle.TriangleProps = {
				Color = Color3.new(r1, g1, b1),
			}
			fillTriangle(tl, tr, bl, thickness, parent, props1)

			-- Triangle 2: tr, br, bl - average of 3 vertex colors
			local r2 = (ctrr[1] + cbrr[1] + cblr[1]) / 3
			local g2 = (ctrr[2] + cbrr[2] + cblr[2]) / 3
			local b2 = (ctrr[3] + cbrr[3] + cblr[3]) / 3
			local props2: fillTriangle.TriangleProps = {
				Color = Color3.new(r2, g2, b2),
			}
			fillTriangle(tr, br, bl, thickness, parent, props2)
		end

		-- Yield periodically to avoid hanging and report progress
		if r % kYieldInterval == 0 then
			if onProgress then
				onProgress(r / rows)
			end
			task.wait()
		end
	end

	if onProgress then
		onProgress(1)
	end

	-- Clean up the editable image
	editableImage:Destroy()
end

return importHeightmap
