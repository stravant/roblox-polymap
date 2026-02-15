--!strict

export type TriangleProps = {
	Color: Color3?,
	Material: Enum.Material?,
	Transparency: number?,
}

-- Fill a single triangle with 1-2 thin wedge Parts.
-- Normal is derived from vertex winding order (a, b, c counterclockwise).
-- Returns the created parts.
local function fillTriangle(
	a: Vector3, b: Vector3, c: Vector3,
	thickness: number,
	parent: Instance,
	props: TriangleProps?,
	existingParts: { BasePart }?
): { BasePart }
	--[[       edg1
		A ------|------>B  --.
		'\      |      /      \
		  \part1|part2/       |
		   \   cut   /       / Direction edges point in:
	   edg3 \       / edg2  /        (clockwise)
		     \     /      |/
		      \<- /       ¯¯
		       \ /
		        C
	--]]
	local ab, bc, ca = b - a, c - b, a - c
	local abm, bcm, cam = ab.Magnitude, bc.Magnitude, ca.Magnitude

	-- Degenerate check
	if abm < 0.001 or bcm < 0.001 or cam < 0.001 then
		if existingParts then
			for _, part in existingParts do
				part.Parent = nil
			end
		end
		return {}
	end

	-- Ensure thickness extends downward: flip winding if normal points down
	if ab:Cross(bc).Y < 0 then
		b, c = c, b
		ab, bc, ca = b - a, c - b, a - c
		abm, bcm, cam = ab.Magnitude, bc.Magnitude, ca.Magnitude
	end

	local e1, e2, e3 = ca:Dot(ab) / (abm * abm), ab:Dot(bc) / (bcm * bcm), bc:Dot(ca) / (cam * cam)
	local edg1 = math.abs(0.5 + e1)
	local edg2 = math.abs(0.5 + e2)
	local edg3 = math.abs(0.5 + e3)

	-- Find the edge onto which the vertex opposite that edge has the
	-- projection closest to 1/2 of the way along that edge. That is the
	-- edge we want to split on to avoid sliver triangles.
	if math.abs(e1) > 0.0001 and math.abs(e2) > 0.0001 and math.abs(e3) > 0.0001 then
		if edg1 < edg2 then
			if edg1 < edg3 then
				-- min is edg1: nothing to change
			else
				-- min is edg3
				a, b, c = c, a, b
				ab, bc, ca = ca, ab, bc
				abm = cam
			end
		else
			if edg2 < edg3 then
				-- min is edg2
				a, b, c = b, c, a
				ab, bc, ca = bc, ca, ab
				abm = bcm
			else
				-- min is edg3
				a, b, c = c, a, b
				ab, bc, ca = ca, ab, bc
				abm = cam
			end
		end
	else
		if math.abs(e1) <= 0.0001 then
			-- nothing to do
		elseif math.abs(e2) <= 0.0001 then
			a, b, c = b, c, a
			ab, bc, ca = bc, ca, ab
			abm = bcm
		else
			a, b, c = c, a, b
			ab, bc, ca = ca, ab, bc
			abm = cam
		end
	end

	-- Calculate lengths
	local len1 = -ca:Dot(ab) / abm
	local len2 = abm - len1
	local width = (ca + ab.Unit * len1).Magnitude

	-- Degenerate: zero-area triangle (e.g., collinear points)
	if width < 0.001 then
		if existingParts then
			for _, part in existingParts do
				part.Parent = nil
			end
		end
		return {}
	end

	-- Calculate "base" CFrame to position parts by
	local normal = ab:Cross(bc).Unit
	local maincf = CFrame.fromMatrix(a, normal:Cross(-ab.Unit), normal, -ab.Unit)

	local depth = thickness

	local createdParts: { BasePart } = {}

	-- Determine appearance: reused parts keep their appearance,
	-- new parts inherit from existingParts[1] or use props/defaults
	local color: Color3
	local material: Enum.Material
	local transparency: number
	if existingParts and existingParts[1] then
		color = existingParts[1].Color
		material = existingParts[1].Material
		transparency = existingParts[1].Transparency
	else
		color = if props and props.Color then props.Color else Color3.fromRGB(163, 162, 165)
		material = if props and props.Material then props.Material else Enum.Material.Plastic
		transparency = if props and props.Transparency then props.Transparency else 0
	end

	local partIndex = 0

	-- Make parts
	if len1 > 0.001 then
		partIndex += 1
		local part1: BasePart
		if existingParts and existingParts[partIndex] then
			part1 = existingParts[partIndex]
		else
			part1 = Instance.new("Part")
			part1.Shape = Enum.PartType.Wedge
			part1.TopSurface = Enum.SurfaceType.Smooth
			part1.BottomSurface = Enum.SurfaceType.Smooth
			part1.Anchored = true
			part1.Color = color
			part1.Material = material
			part1.Transparency = transparency
			part1.Parent = parent
		end
		part1.Size = Vector3.new(depth, width, len1)
		part1.CFrame = maincf * CFrame.Angles(math.pi, 0, math.pi / 2) * CFrame.new(depth / 2, width / 2, len1 / 2)
		part1:SetAttribute("_polyTopSign", -1)
		table.insert(createdParts, part1)
	end
	if len2 > 0.001 then
		partIndex += 1
		local part2: BasePart
		if existingParts and existingParts[partIndex] then
			part2 = existingParts[partIndex]
		else
			part2 = Instance.new("Part")
			part2.Shape = Enum.PartType.Wedge
			part2.TopSurface = Enum.SurfaceType.Smooth
			part2.BottomSurface = Enum.SurfaceType.Smooth
			part2.Anchored = true
			part2.Color = color
			part2.Material = material
			part2.Transparency = transparency
			part2.Parent = parent
		end
		part2.Size = Vector3.new(depth, width, len2)
		part2.CFrame = maincf * CFrame.Angles(math.pi, math.pi, -math.pi / 2) * CFrame.new(-depth / 2, width / 2, -len1 - len2 / 2)
		part2:SetAttribute("_polyTopSign", 1)
		table.insert(createdParts, part2)
	end

	-- Parent-out excess existing parts
	if existingParts then
		for i = partIndex + 1, #existingParts do
			existingParts[i].Parent = nil
		end
	end

	return createdParts
end

return fillTriangle
