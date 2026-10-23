--!strict
-- Materials: terrain material slots. Slot 0 is Air, 1 is Water, 2-22 are the built-in materials and
-- 23-62 are custom MaterialVariant slots (Terrain:SetMaterialSlot). Every brush reads and writes the
-- SolidMaterialIndex voxel channel, so custom slots work wherever a material can be picked.

local MaterialService = game:GetService("MaterialService")

local Materials = {}

export type Slot = {
	index: number,
	name: string, -- picker name: the MaterialVariant's name for custom slots
	base: Enum.Material,
	variant: string?, -- custom slots only
	color: Color3, -- swatch colour
	image: string?, -- custom slots: the variant's colour map, shown as a thumbnail
	tint: Color3,
}

Materials.AIR = 0
Materials.WATER = 1
Materials.GRASS = 2
Materials.MAX_SLOT = 62

-- "LeafyGrass" → "Leafy Grass"
local function spaced(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

-- The MaterialVariant behind a custom slot: a direct MaterialService child first (that's what the
-- built-in picker uses), else any descendant with the same name and base.
local function findVariant(name: string, base: Enum.Material): MaterialVariant?
	local direct = MaterialService:FindFirstChild(name)
	if direct and direct:IsA("MaterialVariant") then
		return direct
	end
	for _, d in MaterialService:GetDescendants() do
		if d:IsA("MaterialVariant") and d.Name == name and d.BaseMaterial == base then
			return d
		end
	end
	return nil
end

-- Every usable slot except Air, in index order. Reads the live slot table, so call it again to refresh.
-- Perf: CPU Low (63 slot reads + a MaterialService lookup per custom slot) | Memory Low
function Materials.list(terrain: Terrain): { Slot }
	local out: { Slot } = {}
	for i = Materials.WATER, Materials.MAX_SLOT do
		local ok, base, variant, tint = pcall(function()
			return terrain:GetMaterialSlot(i)
		end)
		if not ok or typeof(base) ~= "EnumItem" then
			continue
		end
		local b = base :: Enum.Material
		if b == Enum.Material.Air then
			continue -- empty custom slot
		end
		local t = if typeof(tint) == "Color3" then tint else Color3.new(1, 1, 1)
		local v = if type(variant) == "string" and variant ~= "" then variant else nil
		local slot: Slot = {
			index = i,
			name = if v then v else spaced(b.Name),
			base = b,
			variant = v,
			color = Color3.new(0.5, 0.5, 0.5),
			image = nil,
			tint = t,
		}
		if i == Materials.WATER then
			slot.color = terrain.WaterColor
		else
			local okColor, c = pcall(function()
				return terrain:GetMaterialColor(b)
			end)
			if okColor then
				slot.color = c
			end
		end
		if v then
			local mv = findVariant(v, b)
			if mv then
				local okMap, map = pcall(function()
					return mv.ColorMap
				end)
				if okMap and type(map) == "string" and map ~= "" then
					slot.image = map
				end
			end
			slot.color = Color3.new(slot.color.R * t.R, slot.color.G * t.G, slot.color.B * t.B)
		end
		table.insert(out, slot)
	end
	return out
end

function Materials.find(slots: { Slot }, index: number): Slot?
	for _, s in slots do
		if s.index == index then
			return s
		end
	end
	return nil
end

return Materials
