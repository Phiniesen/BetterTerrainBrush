--!strict
--!optimize 2
-- Voxelizer: turns a brush into a Mask, a normalized occupancy grid that Stamp samples at any
-- position, rotation and scale. Built-in shapes (Sphere / Cube / Cylinder) aren't voxelized at all:
-- their Mask only names the shape and Stamp evaluates it exactly, so edges come out smooth.
--
-- Place brushes (Models / BaseParts) are voxelized with raycasts against a private WorldModel copy:
--  * Rays don't hit a convex piece they start inside, so a ray continued past each hit returns
--    every surface where it *enters* solid. Casting a column from both ends gives its upper and
--    lower boundaries; a cell is solid when the nearest boundary above is an upper one and the
--    nearest below is a lower one. All three axes vote and 2 of 3 wins, which hides grazing hits.
--  * MeshParts without PreciseConvexDecomposition collision are rebuilt with it, so concave
--    shapes (arches, rings) keep their holes.
--  * Bounds come from the collision geometry itself, because some meshes aren't centred on
--    their part (Size alone can't be trusted).
--
-- Uploaded mesh files are voxelized straight from their triangles: each column counts the signed
-- crossings (winding number) along it, so overlapping closed pieces still read as solid. The same
-- 2-of-3 axis vote hides holes in meshes that aren't perfectly closed.

local AssetService = game:GetService("AssetService")
local CoreGui = game:GetService("CoreGui")

local Shapes = require(script.Parent.Shapes)

local Voxelizer = {}

export type Mask = {
	kind: string, -- "Grid", or a built-in shape name that Stamp evaluates directly
	nx: number,
	ny: number,
	nz: number,
	size: Vector3, -- local bounding size in studs at scale 1
	data: buffer, -- u8 per cell (0 or 255), index x + y*nx + z*nx*ny (0-based); built-in shapes: preview only
	sdf: buffer?, -- Grid: f32 signed distance per cell in local studs (negative inside), see distanceField
	param: number?, -- built-in shapes: wall thickness (Shapes.Hollow)
	filled: number, -- fraction of the bounding box that is solid
	frame: CFrame, -- world bounding-box frame of the source brush (place brushes)
}

Voxelizer.Shapes = Shapes.List
-- Built-in shapes the ghost can show as a plain part; the rest get a sampled grid for a preview mesh.
Voxelizer.PartShapes = { Sphere = true, Cube = true, Cylinder = true }

local PRECISE = Enum.CollisionFidelity.PreciseConvexDecomposition
local EPS = 0.01 -- step past a hit before casting again
local MAX_HITS = 64
local TIE = 0.05 -- boundaries closer than this count as the same place (part/hull seams)
local EXTENT_RAYS = 32 -- per side, for measuring bounds

-- Parts that make up a brush: visible BaseParts only, so invisible hitboxes/roots don't fill the shape.
-- Perf: CPU Low (one descendant walk) | Memory Low
function Voxelizer.collectParts(source: Instance): { BasePart }
	local parts = {}
	if source:IsA("BasePart") then
		table.insert(parts, source)
	end
	for _, d in source:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			table.insert(parts, d)
		end
	end
	return parts
end

-- Grid dimensions: `detail` cells along the longest axis, near-cubic cells elsewhere.
local function dims(size: Vector3, detail: number): (number, number, number)
	local longest = math.max(size.X, size.Y, size.Z, 1e-3)
	local function n(s: number): number
		return math.max(2, math.round(detail * s / longest))
	end
	return n(size.X), n(size.Y), n(size.Z)
end

-- Copy of one part for the probe world, with precise collision where possible.
-- Perf: CPU Medium (CreateMeshPartAsync can take ~1 s per non-precise mesh, yields) | Memory Low
local function probeCopy(part: BasePart): BasePart?
	local copy: BasePart? = nil
	if part:IsA("MeshPart") and part.CollisionFidelity ~= PRECISE and part.MeshId ~= "" then
		local ok, result = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromUri(part.MeshId), { CollisionFidelity = PRECISE })
		end)
		if ok and result then
			copy = result
			result.Size = part.Size
		else
			warn("[Better Terrain Brush] Couldn't rebuild precise collision for " .. part:GetFullName() .. ", using its own collision: " .. tostring(result))
		end
	end
	if not copy then
		local archivable = part.Archivable
		part.Archivable = true
		local ok, result = pcall(function()
			return part:Clone()
		end)
		part.Archivable = archivable
		if not ok or not result then
			return nil
		end
		copy = result
		for _, child in result:GetChildren() do
			child:Destroy()
		end
	end
	local c = copy :: BasePart
	c.Anchored = true
	c.CanQuery = true
	return c
end

-- Distances along `dir` where a ray from `origin` enters solid, up to `length`.
-- Perf: CPU Low (one raycast per surface crossed) | Memory Low
local function entries(world: WorldModel, origin: Vector3, dir: Vector3, length: number): { number }
	local out = {}
	local travelled = 0
	while travelled < length and #out < MAX_HITS do
		local r = world:Raycast(origin + dir * travelled, dir * (length - travelled))
		if not r then
			break
		end
		local d = (r.Position - origin):Dot(dir)
		table.insert(out, d)
		travelled = math.max(d, travelled) + EPS
	end
	return out
end

local AXES = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
local function comp(v: Vector3, axis: number): number
	return if axis == 1 then v.X elseif axis == 2 then v.Y else v.Z
end

-- Tight bounds (in world-model space) of everything the rays can hit inside a search box.
-- Perf: CPU Low-Medium (6 × EXTENT_RAYS² raycasts) | Memory Low
local function measure(world: WorldModel, minS: Vector3, maxS: Vector3): (Vector3?, Vector3?)
	local inf = math.huge
	local lo, hi = Vector3.new(inf, inf, inf), Vector3.new(-inf, -inf, -inf)
	local any = false
	local size = maxS - minS
	for a = 1, 3 do
		local b, c = a % 3 + 1, (a + 1) % 3 + 1
		local dir = AXES[a]
		local len = comp(size, a) + 2
		for i = 0, EXTENT_RAYS - 1 do
			for j = 0, EXTENT_RAYS - 1 do
				local p = minS + AXES[b] * (comp(size, b) * (i + 0.5) / EXTENT_RAYS) + AXES[c] * (comp(size, c) * (j + 0.5) / EXTENT_RAYS)
				local startLo = p + dir * (comp(minS, a) - comp(p, a) - 1)
				local startHi = startLo + dir * len
				for _, s in { { startLo, dir }, { startHi, -dir } } do
					local r = world:Raycast(s[1], s[2] * len)
					if r then
						any = true
						lo = lo:Min(r.Position)
						hi = hi:Max(r.Position)
					end
				end
			end
		end
	end
	if not any then
		return nil, nil
	end
	return lo, hi
end

-- Signed distance field of a Grid mask, in mask-local studs (negative inside), stored as mask.sdf.
-- Terrain draws a voxel's surface 4 × occupancy studs out from its centre, so Stamp needs real
-- distances to put the terrain surface where the mesh surface is. Exact Euclidean distance transform
-- (Felzenszwalb & Huttenlocher): one pass per axis, once to the nearest solid cell and once to the
-- nearest empty cell; the surface sits half a cell between them.
-- Perf: CPU Medium (6 passes over the grid, ~0.3-1 s at detail 96, yields) | Memory Medium (two f64 grids while running, one f32 grid kept)
function Voxelizer.distanceField(mask: Mask)
	local nx, ny, nz = mask.nx, mask.ny, mask.nz
	local n = nx * ny * nz
	-- Work in units of the smallest cell edge so values stay small and well conditioned.
	local hx, hy, hz = mask.size.X / nx, mask.size.Y / ny, mask.size.Z / nz
	local unit = math.min(hx, hy, hz)
	local BIG = 1e8
	local maxN = math.max(nx, ny, nz)
	local f, v, z = table.create(maxN, 0), table.create(maxN, 0), table.create(maxN + 1, 0)

	-- Squared distance (units²) from every cell to the nearest cell whose solidity is `target`.
	local function transform(target: boolean): buffer
		local g = buffer.create(n * 8)
		for i = 0, n - 1 do
			buffer.writef64(g, i * 8, if (buffer.readu8(mask.data, i) >= 128) == target then 0 else BIG)
		end
		local passes = {
			{ len = nx, stride = 1, h = hx / unit, outer = ny * nz },
			{ len = ny, stride = nx, h = hy / unit, outer = nx * nz },
			{ len = nz, stride = nx * ny, h = hz / unit, outer = nx * ny },
		}
		for axis, pass in passes do
			local len, stride, h = pass.len, pass.stride, pass.h
			for r = 0, pass.outer - 1 do
				-- First cell of row r for this axis.
				local base
				if axis == 1 then
					base = r * nx
				elseif axis == 2 then
					base = (r % nx) + (r // nx) * nx * ny
				else
					base = r
				end
				for q = 0, len - 1 do
					f[q + 1] = buffer.readf64(g, (base + q * stride) * 8)
				end
				-- Lower envelope of parabolas rooted at each cell (1-based tables, 0-based positions).
				local k = 1
				v[1] = 0
				z[1] = -math.huge
				z[2] = math.huge
				for q = 1, len - 1 do
					local fq = f[q + 1] + (q * h) ^ 2
					local p = v[k]
					local s = (fq - (f[p + 1] + (p * h) ^ 2)) / (2 * h * h * (q - p))
					while s <= z[k] do
						k -= 1
						p = v[k]
						s = (fq - (f[p + 1] + (p * h) ^ 2)) / (2 * h * h * (q - p))
					end
					k += 1
					v[k] = q
					z[k] = s
					z[k + 1] = math.huge
				end
				k = 1
				for q = 0, len - 1 do
					while z[k + 1] < q do
						k += 1
					end
					local p = v[k]
					buffer.writef64(g, (base + q * stride) * 8, ((q - p) * h) ^ 2 + f[p + 1])
				end
				if r % 2048 == 2047 then
					task.wait()
				end
			end
		end
		return g
	end

	local toSolid = transform(true)
	local toEmpty = transform(false)
	local sdf = buffer.create(n * 4)
	for i = 0, n - 1 do
		local d
		if buffer.readu8(mask.data, i) >= 128 then
			d = -(math.sqrt(buffer.readf64(toEmpty, i * 8)) - 0.5)
		else
			d = math.sqrt(buffer.readf64(toSolid, i * 8)) - 0.5
		end
		buffer.writef32(sdf, i * 4, d * unit)
	end
	mask.sdf = sdf
end

-- Turns per-cell votes (one per axis that found the cell inside) into a Mask.
local function finish(votes: buffer, nx: number, ny: number, nz: number, size: Vector3, frame: CFrame): Mask
	local data = buffer.create(nx * ny * nz)
	local solid = 0
	for idx = 0, nx * ny * nz - 1 do
		if buffer.readu8(votes, idx) >= 2 then
			buffer.writeu8(data, idx, 255)
			solid += 1
		end
	end
	assert(solid > 0, "Brush has no solid volume")
	local mask: Mask = {
		kind = "Grid",
		nx = nx,
		ny = ny,
		nz = nz,
		size = size,
		data = data,
		sdf = nil,
		filled = solid / (nx * ny * nz),
		frame = frame,
	}
	Voxelizer.distanceField(mask)
	return mask
end

-- Voxelize a Model/BasePart. Yields. `onProgress(0..1)` is optional.
-- Perf: CPU Medium while it runs (~2·detail² columns per axis, a few raycasts each; 48 → well under 1 s, chunked with task.wait) | Memory Low (detail³ bytes)
function Voxelizer.fromInstance(source: Instance, detail: number, onProgress: ((number) -> ())?): Mask
	local parts = Voxelizer.collectParts(source)
	assert(#parts > 0, "Brush has no visible parts")
	local base: CFrame
	if source:IsA("BasePart") then
		base = source.CFrame
	else
		base = (source :: PVInstance):GetPivot()
	end

	-- Private world in CoreGui: queries work there and nothing touches the place or undo history.
	local world = Instance.new("WorldModel")
	world.Name = "TerrainBrushesProbe"
	world.Archivable = false
	local inf = math.huge
	local minS, maxS = Vector3.new(inf, inf, inf), Vector3.new(-inf, -inf, -inf)
	for _, p in parts do
		local c = probeCopy(p)
		if c then
			local cf = base:ToObjectSpace(p.CFrame)
			c.CFrame = cf
			c.Parent = world
			-- Search box: twice the part size, enough for meshes whose origin sits anywhere on them.
			local h = p.Size
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local w = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
						minS = minS:Min(w)
						maxS = maxS:Max(w)
					end
				end
			end
		end
	end
	world.Parent = CoreGui

	local ok, result = pcall(function(): Mask
		local lo, hi = measure(world, minS, maxS)
		assert(lo and hi, "Brush has no collision geometry (are its parts CanQuery?)")
		local pad = (hi - lo) * 0.01 + Vector3.new(0.02, 0.02, 0.02)
		lo -= pad
		hi += pad
		local size = hi - lo
		local nx, ny, nz = dims(size, detail)
		local n = { nx, ny, nz }
		local cell = Vector3.new(size.X / nx, size.Y / ny, size.Z / nz)
		local votes = buffer.create(nx * ny * nz)
		local function index(x: number, y: number, z: number): number
			return x + y * nx + z * nx * ny
		end

		local done, total = 0, nx * ny + ny * nz + nx * nz
		for a = 1, 3 do
			local b, c = a % 3 + 1, (a + 1) % 3 + 1
			local dir = AXES[a]
			local na, nb, nc = n[a], n[b], n[c]
			local cellA = comp(cell, a)
			local loA, len = comp(lo, a), comp(size, a)
			for i = 0, nb - 1 do
				for j = 0, nc - 1 do
					local p = lo + AXES[b] * (comp(cell, b) * (i + 0.5)) + AXES[c] * (comp(cell, c) * (j + 0.5))
					local startLo = p + dir * (loA - comp(p, a))
					-- Upper boundaries come from the ray cast down the axis, lower ones from the ray cast up it.
					local uppers = entries(world, startLo + dir * len, -dir, len)
					local lowers = entries(world, startLo, dir, len)
					if #uppers == 0 or #lowers == 0 then
						continue
					end
					for k, d in uppers do
						uppers[k] = len - d -- distance from the low end
					end
					for k = 0, na - 1 do
						local s = (k + 0.5) * cellA
						local aboveU, aboveL, belowU, belowL = inf, inf, -inf, -inf
						for _, u in uppers do
							if u >= s then
								aboveU = math.min(aboveU, u)
							else
								belowU = math.max(belowU, u)
							end
						end
						for _, l in lowers do
							if l <= s then
								belowL = math.max(belowL, l)
							else
								aboveL = math.min(aboveL, l)
							end
						end
						if aboveU < inf and aboveU <= aboveL + TIE and belowL > -inf and belowL >= belowU - TIE then
							local g = { 0, 0, 0 }
							g[a], g[b], g[c] = k, i, j
							local idx = index(g[1], g[2], g[3])
							buffer.writeu8(votes, idx, buffer.readu8(votes, idx) + 1)
						end
					end
				end
				done += nc
				if onProgress then
					onProgress(done / total)
				end
				if i % 4 == 3 then
					task.wait()
				end
			end
		end
		return finish(votes, nx, ny, nz, size, base * CFrame.new((lo + hi) / 2))
	end)
	world:Destroy()
	if not ok then
		error(result, 0)
	end
	return result
end

-- Voxelize a triangle mesh. `tris` holds 1-based vertex indices, three per triangle. Yields.
-- Perf: CPU Medium while it runs (each triangle is binned into the columns it covers, then each column
-- sorts its crossings; 100k triangles at detail 64 ≈ 1-3 s, chunked with task.wait) | Memory Medium (column bins)
function Voxelizer.fromTriangles(verts: { Vector3 }, tris: { number }, detail: number, onProgress: ((number) -> ())?): Mask
	local nt = #tris // 3
	assert(nt > 0, "Mesh has no triangles")
	local X, Y, Z = table.create(#verts), table.create(#verts), table.create(#verts)
	local inf = math.huge
	local lo, hi = Vector3.new(inf, inf, inf), Vector3.new(-inf, -inf, -inf)
	for i, v in verts do
		X[i], Y[i], Z[i] = v.X, v.Y, v.Z
	end
	for k = 1, nt * 3 do
		local v = verts[tris[k]]
		lo = lo:Min(v)
		hi = hi:Max(v)
	end
	local extent = hi - lo
	assert(math.min(extent.X, extent.Y, extent.Z) > 1e-6 * math.max(extent.X, extent.Y, extent.Z), "Mesh is flat, so it has no volume")
	local pad = extent * 0.01 + Vector3.new(1, 1, 1) * (math.max(extent.X, extent.Y, extent.Z) * 1e-4)
	lo -= pad
	hi += pad
	local size = hi - lo
	local nx, ny, nz = dims(size, detail)
	local n = { nx, ny, nz }
	local cellV = { size.X / nx, size.Y / ny, size.Z / nz }
	local loV = { lo.X, lo.Y, lo.Z }
	local coords = { X, Y, Z }
	local votes = buffer.create(nx * ny * nz)
	local strides = { 1, nx, nx * ny }
	-- Tiny irrational nudge so column lines never pass exactly through shared edges or vertices.
	local JB, JC = 1.234567e-4, 2.718281e-4

	for a = 1, 3 do
		local b, c = a % 3 + 1, (a + 1) % 3 + 1
		local A, B, C = coords[a], coords[b], coords[c]
		local na, nb, nc = n[a], n[b], n[c]
		local cellA, cellB, cellC = cellV[a], cellV[b], cellV[c]
		local loA, loB, loC = loV[a], loV[b], loV[c]
		local sa, sb, sc = strides[a], strides[b], strides[c]

		-- Bin each triangle into the columns its (b, c) footprint covers.
		local bins: { [number]: { number } } = {}
		for t = 0, nt - 1 do
			local i0, i1, i2 = tris[t * 3 + 1], tris[t * 3 + 2], tris[t * 3 + 3]
			local b0, b1, b2 = B[i0], B[i1], B[i2]
			local c0, c1, c2 = C[i0], C[i1], C[i2]
			local area = (b1 - b0) * (c2 - c0) - (b2 - b0) * (c1 - c0)
			if area == 0 then
				continue -- edge-on to this axis
			end
			local iLo = math.max(0, math.ceil((math.min(b0, b1, b2) - loB) / cellB - 0.5 - JB))
			local iHi = math.min(nb - 1, math.floor((math.max(b0, b1, b2) - loB) / cellB - 0.5 - JB))
			local jLo = math.max(0, math.ceil((math.min(c0, c1, c2) - loC) / cellC - 0.5 - JC))
			local jHi = math.min(nc - 1, math.floor((math.max(c0, c1, c2) - loC) / cellC - 0.5 - JC))
			for i = iLo, iHi do
				for j = jLo, jHi do
					local key = i + j * nb
					local bin = bins[key]
					if bin then
						table.insert(bin, t)
					else
						bins[key] = { t }
					end
				end
			end
			if t % 20000 == 19999 then
				task.wait()
			end
		end

		local columns = 0
		for key, bin in bins do
			local i, j = key % nb, key // nb
			local pb = loB + (i + 0.5 + JB) * cellB
			local pc = loC + (j + 0.5 + JC) * cellC
			-- Crossings along the column: position and +1 entering / -1 leaving.
			local hits: { { number } } = {}
			for _, t in bin do
				local i0, i1, i2 = tris[t * 3 + 1], tris[t * 3 + 2], tris[t * 3 + 3]
				local b0, c0 = B[i0], C[i0]
				local db1, dc1 = B[i1] - b0, C[i1] - c0
				local db2, dc2 = B[i2] - b0, C[i2] - c0
				local area = db1 * dc2 - db2 * dc1
				local pbr, pcr = pb - b0, pc - c0
				local w1 = (pbr * dc2 - db2 * pcr) / area
				local w2 = (db1 * pcr - pbr * dc1) / area
				local w0 = 1 - w1 - w2
				if w0 >= 0 and w1 >= 0 and w2 >= 0 then
					local pos = A[i0] * w0 + A[i1] * w1 + A[i2] * w2
					-- area is the normal's component along this axis (b × c = a): a CCW-front face whose
					-- normal points against the ray is where the ray enters solid.
					table.insert(hits, { pos, if area < 0 then 1 else -1 })
				end
			end
			if #hits >= 2 then
				table.sort(hits, function(p, q)
					return p[1] < q[1]
				end)
				local winding, h = 0, 1
				local base = i * sb + j * sc
				for k = 0, na - 1 do
					local s = loA + (k + 0.5) * cellA
					while h <= #hits and hits[h][1] < s do
						winding += hits[h][2]
						h += 1
					end
					if winding ~= 0 then
						local idx = base + k * sa
						buffer.writeu8(votes, idx, buffer.readu8(votes, idx) + 1)
					end
				end
			end
			columns += 1
			if columns % 2000 == 0 then
				if onProgress then
					onProgress(((a - 1) + columns / (nb * nc)) / 3)
				end
				task.wait()
			end
		end
		if onProgress then
			onProgress(a / 3)
		end
	end
	return finish(votes, nx, ny, nz, size, CFrame.new((lo + hi) / 2))
end

local PREVIEW_DETAIL = 32 -- cells along the longest axis of a built-in shape's preview grid

-- Built-in shapes at unit size (the brush size is the scale); Stamp evaluates them exactly through
-- Shapes.distance. Shapes a part can't show get a coarse sampled grid, only for the ghost mesh: cells
-- within half a cell of the shape count, so thin walls still show.
-- Perf: CPU Low (part shapes) / Low-Medium (≤ 32³ distance samples) | Memory Low
function Voxelizer.primitive(shape: string, thickness: number): Mask
	assert(table.find(Voxelizer.Shapes, shape), "Unknown shape " .. shape)
	local size = Shapes.unitSize(shape, thickness)
	local mask: Mask = {
		kind = shape,
		nx = 1,
		ny = 1,
		nz = 1,
		size = size,
		data = buffer.create(1),
		sdf = nil,
		param = thickness,
		filled = if shape == "Sphere" then math.pi / 6 elseif shape == "Cylinder" then math.pi / 4 else 1,
		frame = CFrame.identity,
	}
	if Voxelizer.PartShapes[shape] then
		return mask
	end
	local nx, ny, nz = dims(size, PREVIEW_DETAIL)
	local cx, cy, cz = size.X / nx, size.Y / ny, size.Z / nz
	local slack = math.min(cx, cy, cz) / 2
	local h = size / 2
	local data = buffer.create(nx * ny * nz)
	local solid = 0
	for z = 0, nz - 1 do
		for y = 0, ny - 1 do
			for x = 0, nx - 1 do
				local px, py, pz = (x + 0.5) * cx - h.X, (y + 0.5) * cy - h.Y, (z + 0.5) * cz - h.Z
				if Shapes.distance(shape, px, py, pz, h.X, h.Y, h.Z, thickness) <= slack then
					buffer.writeu8(data, x + y * nx + z * nx * ny, 255)
					solid += 1
				end
			end
		end
	end
	mask.nx, mask.ny, mask.nz, mask.data = nx, ny, nz, data
	mask.filled = solid / (nx * ny * nz)
	return mask
end

return Voxelizer
