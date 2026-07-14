--!strict

local AssetService = game:GetService("AssetService")

local TestTypes = require("./TestTypes")
local meshFaceColors = require("./meshFaceColors")

-- A 2x1 image: left texel pure red, right texel pure blue.
local function makeTestImage(): EditableImage
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(2, 1) })
	local pixels = buffer.create(2 * 4)
	buffer.writeu8(pixels, 0, 255) -- left: R
	buffer.writeu8(pixels, 1, 0)
	buffer.writeu8(pixels, 2, 0)
	buffer.writeu8(pixels, 3, 255)
	buffer.writeu8(pixels, 4, 0) -- right: B
	buffer.writeu8(pixels, 5, 0)
	buffer.writeu8(pixels, 6, 255)
	buffer.writeu8(pixels, 7, 255)
	image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
	return image
end

-- One triangle whose three UVs average to `uv`.
local function addFaceAtUV(editableMesh: EditableMesh, uv: Vector2): number
	local v1 = editableMesh:AddVertex(Vector3.new(0, 0, 0))
	local v2 = editableMesh:AddVertex(Vector3.new(1, 0, 0))
	local v3 = editableMesh:AddVertex(Vector3.new(0, 0, 1))
	local faceId = editableMesh:AddTriangle(v1, v2, v3)
	local uvId = editableMesh:AddUV(uv)
	editableMesh:SetFaceUVs(faceId, { uvId, uvId, uvId })
	return faceId
end

return function(t: TestTypes.TestContext)
	t.test("samples each face's color at its UV centroid", function()
		local editableMesh = AssetService:CreateEditableMesh()
		local leftFace = addFaceAtUV(editableMesh, Vector2.new(0.25, 0.5))
		local rightFace = addFaceAtUV(editableMesh, Vector2.new(0.75, 0.5))
		local image = makeTestImage()

		local colors = meshFaceColors(editableMesh, image)
		t.expect(colors ~= nil).toBe(true)
		t.expect((colors :: any)[leftFace]).toBe(Color3.fromRGB(255, 0, 0))
		t.expect((colors :: any)[rightFace]).toBe(Color3.fromRGB(0, 0, 255))

		image:Destroy()
		editableMesh:Destroy()
	end)

	t.test("UVs outside [0, 1] wrap into tile space (tiling textures)", function()
		local editableMesh = AssetService:CreateEditableMesh()
		-- Same tile-space spots as the basic test, several tiles away, both signs.
		local leftFace = addFaceAtUV(editableMesh, Vector2.new(3.25, -1.5))
		local rightFace = addFaceAtUV(editableMesh, Vector2.new(-7.25, 2.5))
		local image = makeTestImage()

		local colors = meshFaceColors(editableMesh, image)
		t.expect(colors ~= nil).toBe(true)
		t.expect((colors :: any)[leftFace]).toBe(Color3.fromRGB(255, 0, 0))
		t.expect((colors :: any)[rightFace]).toBe(Color3.fromRGB(0, 0, 255))

		image:Destroy()
		editableMesh:Destroy()
	end)
end
