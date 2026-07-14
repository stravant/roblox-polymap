--!strict

-- Per-face flat colors for an EditableMesh, sampled from a texture: each face
-- gets the texel under its UV centroid. Mesh UVs commonly run outside [0, 1]
-- to tile the texture (the sampler wraps them into tile space, matching how
-- the renderer repeats it). Returns nil when the pixels can't be read or the
-- mesh's UV data is unusable, so callers can fall back to a flat color.
local function meshFaceColors(editableMesh: EditableMesh, image: EditableImage): { [number]: Color3 }?
	local size = image.Size
	local width, height = size.X, size.Y
	if width < 1 or height < 1 then
		return nil
	end

	local okRead, pixels = pcall(function()
		return image:ReadPixelsBuffer(Vector2.zero, size)
	end)
	if not okRead then
		return nil
	end

	local result: { [number]: Color3 } = {}
	local okSample = pcall(function()
		for _, faceId in editableMesh:GetFaces() do
			local uvIds = editableMesh:GetFaceUVs(faceId)
			if #uvIds == 0 then
				continue
			end
			local uvSum = Vector2.zero
			for _, uvId in uvIds do
				uvSum += editableMesh:GetUV(uvId)
			end
			local uv = uvSum / #uvIds
			-- Wrap into [0, 1) tile space; UV (0, 0) is the texture's top-left,
			-- matching pixel row 0.
			local u = uv.X - math.floor(uv.X)
			local v = uv.Y - math.floor(uv.Y)
			local x = math.clamp(math.floor(u * width), 0, width - 1)
			local y = math.clamp(math.floor(v * height), 0, height - 1)
			local offset = (y * width + x) * 4
			result[faceId] = Color3.fromRGB(
				buffer.readu8(pixels, offset),
				buffer.readu8(pixels, offset + 1),
				buffer.readu8(pixels, offset + 2)
			)
		end
	end)
	if not okSample then
		return nil
	end
	return result
end

return meshFaceColors
