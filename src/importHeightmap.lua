--!strict

local AssetService = game:GetService("AssetService")

local buildHeightmapMesh = require("./buildHeightmapMesh")

export type ImportParams = {
	ImageId: string,
	Width: number, -- number of cells wide
	Height: number, -- number of cells tall
	Spacing: number, -- distance between adjacent vertices
	MinY: number, -- local Y at luminance 0 (black)
	MaxY: number, -- local Y at luminance 1 (white)
	Origin: CFrame, -- center CFrame of the grid
	Thickness: number,
	Parent: Instance,
	OnProgress: ((fraction: number) -> ())?,
}

local function importHeightmap(params: ImportParams)
	local imageId = params.ImageId
	local cols = params.Width
	local rows = params.Height
	local spacing = params.Spacing
	local minY = params.MinY
	local maxY = params.MaxY
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
			local localPos = Vector3.new(c * spacing - halfW, minY + luminance * (maxY - minY), r * spacing - halfH)
			local worldPos = origin:PointToWorldSpace(localPos)
			table.insert(row, worldPos)
			table.insert(colorRow, { pr, pg, pb })
		end
		table.insert(vertices, row)
		table.insert(vertexColors, colorRow)
	end

	-- Each cell produces 2 triangles, colored by averaging vertex colors. Generated
	-- facing up (smooth surface on top, thickness hanging below).
	buildHeightmapMesh(vertices, vertexColors, thickness, parent, onProgress)

	if onProgress then
		onProgress(1)
	end

	-- Clean up the editable image
	editableImage:Destroy()
end

return importHeightmap
