--!strict
--!native
--!optimize 2
-- Stamp: applies one brush to terrain at a CFrame and per-axis scale.
-- Reads the covered voxels once, works out every change against that snapshot, then writes once.
-- Materials are slot indices (the SolidMaterialIndex channel), so custom material slots work too.
--
-- Terrain draws a voxel's surface 4 × occupancy studs out from the voxel's centre (occupancy 0.5 sits
-- on the voxel boundary, a full voxel next to air reaches its neighbour's centre). So every brush
-- works from the signed distance d (studs, negative inside) between a voxel centre and the brush
-- surface: filling to clamp(-d / 4) puts the terrain surface exactly on the brush surface.

local Voxelizer = require(script.Parent.Voxelizer)
local Shapes = require(script.Parent.Shapes)
type Mask = Voxelizer.Mask

local Stamp = {}

export type Params = {
	op: string, -- "Add" | "Subtract" | "Grow" | "Erode" | "Smooth" | "Flatten" | "Paint" | "Replace"
	material: number, -- slot index; Water (1) adds/removes water instead of solid terrain
	source: number, -- Replace: the slot that gets swapped for `material`
	strength: number, -- 0..2: Grow, Erode, Smooth, Flatten
	autoMaterial: boolean, -- Add / Grow / Flatten: new terrain copies the material next to it
	replaceMaterial: boolean, -- Add: also repaint solid terrain inside the brush
	ignoreWater: boolean, -- leave water alone
	flattenMode: string, -- "Erode" (lower only) | "Grow" (raise only) | "Both"
	planeY: number, -- Flatten: world height of the ground surface to flatten to
	thicken: number, -- mesh brushes: studs added all round so thin details survive 4-stud voxels
	changed: { [number]: number }?, -- if given: voxel key → occupancy before this stroke first changed it
}

local RES = 4
local MAX_VOXELS = 4_000_000 -- ReadVoxelChannels limit is 4,194,304
local CHANNELS = { "SolidMaterialIndex", "SolidOccupancy", "LiquidOccupancy" }
local AIR, WATER = 0, 1
local MIN_OCC = 1 / 255 -- terrain stores occupancy in 8 bits; anything smaller is empty
local SEAM = 0.1 -- enough occupancy to close the crack between touching solids (0.05 already does)
local KEY_OFFSET, KEY_BASE = 16384, 32768

-- Key of the voxel containing a world point (see Params.changed).
function Stamp.voxelKey(pos: Vector3): number
	local vx, vy, vz = math.floor(pos.X / RES), math.floor(pos.Y / RES), math.floor(pos.Z / RES)
	return ((vx + KEY_OFFSET) * KEY_BASE + (vy + KEY_OFFSET)) * KEY_BASE + (vz + KEY_OFFSET)
end

-- Sculpt neighbours, in material-source preference order: below, sides, above.
local NEIGHBOURS = { { 0, -1, 0 }, { -1, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 }, { 0, 0, 1 }, { 0, 1, 0 } }

-- Slot of a voxel if it is at least half solid, else nil (also nil outside the read box).
local function solidAt(mats: any, occs: any, sx: number, sy: number, sz: number, x: number, y: number, z: number): number?
	if x < 1 or y < 1 or z < 1 or x > sx or y > sy or z > sz then
		return nil
	end
	if occs[x][y][z] >= 0.5 then
		local m = mats[x][y][z]
		return if m ~= AIR then m else nil
	end
	return nil
end

-- World-space box a stamp covers, snapped to the voxel grid. Nil if it's too big to read.
-- Perf: CPU Low | Memory Low
function Stamp.region(mask: Mask, cf: CFrame, scale: Vector3, pad: number): Region3?
	local h = mask.size * scale / 2
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local ext = Vector3.new(
		math.abs(r00) * h.X + math.abs(r01) * h.Y + math.abs(r02) * h.Z,
		math.abs(r10) * h.X + math.abs(r11) * h.Y + math.abs(r12) * h.Z,
		math.abs(r20) * h.X + math.abs(r21) * h.Y + math.abs(r22) * h.Z
	) + Vector3.new(pad, pad, pad)
	local region = Region3.new(cf.Position - ext, cf.Position + ext):ExpandToGrid(RES)
	local n = region.Size / RES
	if n.X * n.Y * n.Z > MAX_VOXELS then
		return nil
	end
	return region
end

-- Apply one stamp. Returns true if any voxel changed.
-- Perf: CPU Medium-High per call (voxels × distance test; a 40-stud brush ≈ 2k voxels ≈ 1-3 ms, 200 studs ≈ 0.3 s;
-- Smooth reads 27 neighbours per voxel) | Memory Medium (voxel arrays of the stamp box)
function Stamp.apply(terrain: Terrain, mask: Mask, cf: CFrame, scale: Vector3, p: Params): boolean
	local op = p.op
	local water = p.material == WATER
	local grid = mask.kind == "Grid"
	local thicken = if grid then math.max(p.thicken, 0) else 0
	-- Smooth looks two voxels out (neighbours of neighbours), everything else one.
	local region = Stamp.region(mask, cf, scale, (if op == "Smooth" then 2 * RES else RES) + thicken)
	if not region then
		warn("[Better Terrain Brush] Brush too large for one stamp, make it smaller")
		return false
	end
	local ch = terrain:ReadVoxelChannels(region, RES, CHANNELS)
	local mats, occs, liqs = ch.SolidMaterialIndex, ch.SolidOccupancy, ch.LiquidOccupancy
	local count = ch.Size :: Vector3
	local sx, sy, sz = count.X, count.Y, count.Z
	local minCorner = region.CFrame.Position - region.Size / 2

	local px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local h = mask.size * scale / 2
	local hx, hy, hz = h.X, h.Y, h.Z
	local reach = RES + thicken + 1
	local reachX, reachY, reachZ = hx + reach, hy + reach, hz + reach
	local kind = mask.kind
	local thickness = mask.param or 0.4

	-- Grid brushes: brush-local studs → mask grid coordinates (cell i's centre at i).
	local nx, ny, nz = mask.nx, mask.ny, mask.nz
	local sdf = mask.sdf
	if grid and not sdf then
		Voxelizer.distanceField(mask)
		sdf = mask.sdf
	end
	local ux, uy, uz = mask.size.X / nx, mask.size.Y / ny, mask.size.Z / nz -- mask-local studs per cell
	local gxs, gys, gzs = 1 / (ux * scale.X), 1 / (uy * scale.Y), 1 / (uz * scale.Z)
	local ox, oy, oz = nx / 2 - 0.5, ny / 2 - 0.5, nz / 2 - 0.5
	local sxs, sys, szs = scale.X, scale.Y, scale.Z
	local minScale = math.min(sxs, sys, szs)

	local function cell(x: number, y: number, z: number): number
		return buffer.readf32(sdf :: buffer, (x + y * nx + z * nx * ny) * 4)
	end

	-- Signed distance (world studs, negative inside) from a brush-local point to the brush surface.
	-- Perf: CPU Low per call (built-in shapes) / Low-Medium (grid: 8 reads + gradient) | Memory Low
	local function distance(lx: number, ly: number, lz: number): number
		if not grid then
			return Shapes.distance(kind, lx, ly, lz, hx, hy, hz, thickness)
		end
		-- Grid: trilinear signed distance from the mask's distance field, clamped to the grid; points
		-- outside the grid add their distance to it.
		local gx, gy, gz = lx * gxs + ox, ly * gys + oy, lz * gzs + oz
		local cx, cy, cz = math.clamp(gx, 0, nx - 1), math.clamp(gy, 0, ny - 1), math.clamp(gz, 0, nz - 1)
		local outside = 0
		if cx ~= gx or cy ~= gy or cz ~= gz then
			local ex, ey, ez = (gx - cx) * ux * sxs, (gy - cy) * uy * sys, (gz - cz) * uz * szs
			outside = math.sqrt(ex * ex + ey * ey + ez * ez)
		end
		local x0, y0, z0 = math.min(math.floor(cx), nx - 2), math.min(math.floor(cy), ny - 2), math.min(math.floor(cz), nz - 2)
		local fx, fy, fz = cx - x0, cy - y0, cz - z0
		local c000, c100 = cell(x0, y0, z0), cell(x0 + 1, y0, z0)
		local c010, c110 = cell(x0, y0 + 1, z0), cell(x0 + 1, y0 + 1, z0)
		local c001, c101 = cell(x0, y0, z0 + 1), cell(x0 + 1, y0, z0 + 1)
		local c011, c111 = cell(x0, y0 + 1, z0 + 1), cell(x0 + 1, y0 + 1, z0 + 1)
		local c00, c10 = c000 + (c100 - c000) * fx, c010 + (c110 - c010) * fx
		local c01, c11 = c001 + (c101 - c001) * fx, c011 + (c111 - c011) * fx
		local c0, c1 = c00 + (c10 - c00) * fy, c01 + (c11 - c01) * fy
		local d = c0 + (c1 - c0) * fz -- mask-local studs
		-- Gradient (per local stud) turns the local distance into world studs under non-uniform scale.
		local dx = ((c100 - c000) * (1 - fy) + (c110 - c010) * fy) * (1 - fz) + ((c101 - c001) * (1 - fy) + (c111 - c011) * fy) * fz
		local dy = (c10 - c00) * (1 - fz) + (c11 - c01) * fz
		local dz = c1 - c0
		dx, dy, dz = dx / ux / sxs, dy / uy / sys, dz / uz / szs
		local g = math.sqrt(dx * dx + dy * dy + dz * dz)
		local world = if g > 0.3 / minScale then d / g else d * minScale
		return world + outside - thicken
	end

	-- Fallback material for new terrain with no solid neighbour. Water and Smooth always pick from the
	-- terrain around them, and so does Auto material: whatever is most common in the stamp box (so a
	-- brush dragged into the air next to a cliff matches the cliff).
	local fallback = p.material
	if p.autoMaterial or water or op == "Smooth" then
		local tally: { [number]: number } = {}
		local best, bestN = -1, 0
		for ix = 1, sx do
			for iy = 1, sy do
				for iz = 1, sz do
					if occs[ix][iy][iz] >= 0.5 then
						local m = mats[ix][iy][iz]
						if m ~= AIR then
							local n = (tally[m] or 0) + 1
							tally[m] = n
							if n > bestN then
								best, bestN = m, n
							end
						end
					end
				end
			end
		end
		if best >= 0 then
			fallback = best
		end
	end
	if fallback == WATER or fallback == AIR then
		fallback = 2 -- Grass: solid terrain needs a solid material
	end

	-- Material for a voxel that is becoming solid: a solid neighbour's (Auto material) or the brush's.
	local function newMaterial(ix: number, iy: number, iz: number, auto: boolean): number
		if auto then
			for _, n in NEIGHBOURS do
				local nm = solidAt(mats, occs, sx, sy, sz, ix + n[1], iy + n[2], iz + n[3])
				if nm then
					return nm
				end
			end
			return fallback
		end
		return if water then fallback else p.material
	end

	-- Smooth works on each voxel's signed distance to the surface (studs, positive inside) instead of
	-- raw occupancy: blurring occupancy would grow every surface, since an empty voxel next to the
	-- surface gaining any occupancy pushes the surface out. A partial voxel's distance is 4 × occupancy;
	-- full and empty voxels extend their neighbours' values by one voxel (clamped to the band that
	-- matters), which keeps flat ground exactly flat.
	local dist: { { { number } } }? = nil
	if op == "Smooth" then
		local field = table.create(sx)
		for ix = 1, sx do
			local fX = table.create(sy)
			for iy = 1, sy do
				local fY = table.create(sz)
				for iz = 1, sz do
					local o = occs[ix][iy][iz]
					local s
					if o > 0 and o < 1 then
						s = RES * o
					elseif o >= 1 then
						s = 2 * RES
						for _, n in NEIGHBOURS do
							local oX = occs[ix + n[1]]
							local oY = oX and oX[iy + n[2]]
							local on = oY and oY[iz + n[3]]
							if on and on < 1 then
								s = math.min(s, RES * on + RES)
							end
						end
					else
						s = -RES
						for _, n in NEIGHBOURS do
							local oX = occs[ix + n[1]]
							local oY = oX and oX[iy + n[2]]
							local on = oY and oY[iz + n[3]]
							if on and on > 0 then
								s = math.max(s, RES * on - RES)
							end
						end
					end
					fY[iz] = s
				end
				fX[iy] = fY
			end
			field[ix] = fX
		end
		dist = field
	end

	local strength = math.clamp(p.strength, 0, 2)
	local autoMat = p.autoMaterial or water
	local ignoreWater = p.ignoreWater
	local flattenMode, planeY = p.flattenMode, p.planeY
	-- Changes are collected first so neighbour checks (Grow, Smooth, Auto material) see the original terrain.
	local changes: { any } = {}

	for ix = 1, sx do
		local dx = minCorner.X + (ix - 0.5) * RES - px
		local matX, occX, liqX = mats[ix], occs[ix], liqs[ix]
		for iy = 1, sy do
			local wy = minCorner.Y + (iy - 0.5) * RES
			local dy = wy - py
			local matY, occY, liqY = matX[iy], occX[iy], liqX[iy]
			for iz = 1, sz do
				local dz = minCorner.Z + (iz - 0.5) * RES - pz
				local lx = dx * r00 + dy * r10 + dz * r20
				local ly = dx * r01 + dy * r11 + dz * r21
				local lz = dx * r02 + dy * r12 + dz * r22
				if math.abs(lx) > reachX or math.abs(ly) > reachY or math.abs(lz) > reachZ then
					continue
				end
				local d = distance(lx, ly, lz)
				if d >= RES then
					continue -- no op changes anything a whole voxel outside the brush
				end
				local fillIn = math.clamp(-d / RES, 0, 1) -- occupancy that puts the surface on the brush
				local fillOut = math.clamp(d / RES, 0, 1) -- same, for everything outside the brush
				local w = math.clamp(0.5 - d / RES, 0, 1) -- brush weight for gradual ops (0.5 on the surface)

				local occ, mat, liq = occY[iz], matY[iz], liqY[iz]
				local newOcc, newMat, newLiq = occ, mat, liq
				local empty = occ < MIN_OCC or mat == AIR

				if op == "Add" then
					if water then
						if occ < 1 then
							newLiq = math.max(liq, fillIn)
						end
					else
						newOcc = math.max(occ, fillIn)
						if newOcc <= 0 and d < 1 then
							-- The brush touches solid terrain through this voxel, brush on one side and terrain
							-- on the other (e.g. a brush resting on the ground): left empty, terrain draws a
							-- hairline crack between them.
							for _, n in NEIGHBOURS do
								local oX = occs[ix + n[1]]
								local oY = oX and oX[iy + n[2]]
								local on = oY and oY[iz + n[3]]
								if on and on >= 0.75 then
									local ex, ey, ez = -n[1] * RES, -n[2] * RES, -n[3] * RES -- world step to the opposite voxel
									local opposite = distance(
										lx + ex * r00 + ey * r10 + ez * r20,
										ly + ex * r01 + ey * r11 + ez * r21,
										lz + ex * r02 + ey * r12 + ez * r22
									)
									if opposite < 0 then
										newOcc = SEAM
										break
									end
								end
							end
						end
						if newOcc > occ and empty then
							newMat = newMaterial(ix, iy, iz, autoMat)
						end
						if p.replaceMaterial and not empty and d <= 0 then
							newMat = p.material
						end
					end
				elseif op == "Subtract" then
					if water then
						newLiq = math.min(liq, fillOut)
					else
						newOcc = math.min(occ, fillOut)
						if not ignoreWater then
							newLiq = math.min(liq, fillOut)
						end
					end
				elseif op == "Grow" then
					if water then
						if occ < 1 then
							newLiq = math.min(1, liq + w * strength)
						end
					else
						-- Only grow next to existing terrain, like the built-in Sculpt.
						local grow = not empty
						if not grow then
							for _, n in NEIGHBOURS do
								if solidAt(mats, occs, sx, sy, sz, ix + n[1], iy + n[2], iz + n[3]) then
									grow = true
									break
								end
							end
						end
						if grow then
							newOcc = math.min(1, occ + w * strength)
							if empty then
								newMat = newMaterial(ix, iy, iz, autoMat)
							end
						end
					end
				elseif op == "Erode" then
					if water then
						newLiq = math.max(0, liq - w * strength)
					else
						-- Only erode terrain open to the air, like the built-in Sculpt. Eroding buried voxels too
						-- hollows them out unseen until the whole brush caves in at once.
						local exposed = false
						if occ > 0 then
							for _, n in NEIGHBOURS do
								if not solidAt(mats, occs, sx, sy, sz, ix + n[1], iy + n[2], iz + n[3]) then
									exposed = true
									break
								end
							end
						end
						if exposed then
							newOcc = math.max(0, occ - w * strength)
						end
						if not ignoreWater then
							newLiq = math.max(0, liq - w * strength)
						end
					end
				elseif op == "Smooth" then
					-- Blend the distance towards its 3×3×3 average; voxels outside the read box count as this one.
					local field = dist :: { { { number } } }
					local own = field[ix][iy][iz]
					local sum = 0
					for ax = ix - 1, ix + 1 do
						local fX = field[ax]
						for ay = iy - 1, iy + 1 do
							local fY = fX and fX[ay]
							for az = iz - 1, iz + 1 do
								local v = fY and fY[az]
								sum += if v then v else own
							end
						end
					end
					-- Blend capped at 1: past the average would overshoot and ripple.
					newOcc = math.clamp((own + (sum / 27 - own) * math.min(w * strength, 1)) / RES, 0, 1)
					if newOcc > occ and empty then
						newMat = newMaterial(ix, iy, iz, true)
					end
				elseif op == "Flatten" then
					-- How full this voxel must be for the ground surface to sit on the plane.
					local target = math.clamp((planeY - wy) / RES, 0, 1)
					local t = math.min(w * strength, 1) -- past 1 would overshoot the plane
					if target < occ and flattenMode ~= "Grow" then
						newOcc = occ + (target - occ) * t
					elseif target > occ and flattenMode ~= "Erode" then
						newOcc = occ + (target - occ) * t
						if empty then
							newMat = newMaterial(ix, iy, iz, autoMat)
						end
					end
					if not ignoreWater and flattenMode ~= "Grow" and liq > target then
						newLiq = liq + (target - liq) * t
					end
				elseif op == "Paint" then
					if not empty and d <= 0 and not water then
						newMat = p.material
					end
				elseif op == "Replace" then
					if not empty and d <= 0 and mat == p.source and not water then
						newMat = p.material
					end
				end

				if newOcc < MIN_OCC then
					newOcc = 0
					newMat = AIR
				elseif newMat == AIR then
					newMat = fallback
				end
				if newLiq < MIN_OCC then
					newLiq = 0
				end
				if newOcc ~= occ or newMat ~= mat or newLiq ~= liq then
					table.insert(changes, { ix, iy, iz, newOcc, newMat, newLiq, occ })
				end
			end
		end
	end

	if #changes == 0 then
		return false
	end
	local record = p.changed
	local vx0, vy0, vz0 = math.round(minCorner.X / RES), math.round(minCorner.Y / RES), math.round(minCorner.Z / RES)
	for _, c in changes do
		local x, y, z = c[1], c[2], c[3]
		occs[x][y][z] = c[4]
		mats[x][y][z] = c[5]
		liqs[x][y][z] = c[6]
		if record then
			local key = ((vx0 + x - 1 + KEY_OFFSET) * KEY_BASE + (vy0 + y - 1 + KEY_OFFSET)) * KEY_BASE + (vz0 + z - 1 + KEY_OFFSET)
			if record[key] == nil then
				record[key] = c[7]
			end
		end
	end
	terrain:WriteVoxelChannels(region, RES, {
		SolidMaterialIndex = mats,
		SolidOccupancy = occs,
		LiquidOccupancy = liqs,
	})
	return true
end

-- Slot of the terrain under a surface hit, or nil. The surface can sit up to a voxel past the
-- voxel that makes it, so this looks 1, 3 and 5 studs in.
-- Perf: CPU Low (up to three 1-voxel reads) | Memory Low
function Stamp.materialAt(terrain: Terrain, pos: Vector3, normal: Vector3): number?
	for _, depth in { 1, 3, 5 } do
		local p = pos - normal * depth
		local cell = Vector3.new(math.floor(p.X / RES), math.floor(p.Y / RES), math.floor(p.Z / RES)) * RES
		local ch = terrain:ReadVoxelChannels(Region3.new(cell, cell + Vector3.one * RES), RES, { "SolidMaterialIndex", "SolidOccupancy", "LiquidOccupancy" })
		local m, o, l = ch.SolidMaterialIndex[1][1][1], ch.SolidOccupancy[1][1][1], ch.LiquidOccupancy[1][1][1]
		if o > 0 and m ~= AIR then
			return m
		elseif l > 0 then
			return WATER
		end
	end
	return nil
end

return Stamp
