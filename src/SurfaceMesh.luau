--!strict
--!optimize 2
-- SurfaceMesh: builds a see-through preview mesh from a voxel Mask's grid (surface nets), for mesh
-- brushes and the built-in shapes a plain part can't show (Donut, U, ...). The mesh shows the shape
-- that gets stamped. It's centred on the mask, in mask units (scale 1), so the ghost part's Size is
-- its initial Size times the brush scale.

local AssetService = game:GetService("AssetService")

local Voxelizer = require(script.Parent.Voxelizer)
type Mask = Voxelizer.Mask

local SurfaceMesh = {}

local MAX_QUADS = 9500 -- EditableMesh allows 20,000 triangles
local SMOOTH_PASSES = 2

-- Perf: CPU Medium (a few passes over the mask, ~0.1-0.5 s at detail 96, yields) | Memory Medium (vertex tables, one EditableMesh)
function SurfaceMesh.build(mask: Mask): (MeshPart, EditableMesh)
	local nx, ny, nz = mask.nx, mask.ny, mask.nz
	assert(nx > 1 and buffer.len(mask.data) == nx * ny * nz, "Brush has no voxel grid to preview")
	local data = mask.data

	-- Coarser grid (majority of each f³ block) until the surface fits the triangle limit.
	local f, cx, cy, cz, cells = 1, nx, ny, nz, data
	local function coarse(factor: number): (number, number, number, buffer)
		local ax, ay, az = math.ceil(nx / factor), math.ceil(ny / factor), math.ceil(nz / factor)
		if factor == 1 then
			return ax, ay, az, data
		end
		local out = buffer.create(ax * ay * az)
		for z = 0, az - 1 do
			for y = 0, ay - 1 do
				for x = 0, ax - 1 do
					local solid, total = 0, 0
					for fz = z * factor, math.min((z + 1) * factor, nz) - 1 do
						for fy = y * factor, math.min((y + 1) * factor, ny) - 1 do
							for fx = x * factor, math.min((x + 1) * factor, nx) - 1 do
								total += 1
								if buffer.readu8(data, fx + fy * nx + fz * nx * ny) >= 128 then
									solid += 1
								end
							end
						end
					end
					if solid * 2 >= total then
						buffer.writeu8(out, x + y * ax + z * ax * ay, 255)
					end
				end
			end
			if z % 8 == 7 then
				task.wait()
			end
		end
		return ax, ay, az, out
	end
	local function solidAt(b: buffer, ax: number, ay: number, az: number, x: number, y: number, z: number): boolean
		if x < 0 or y < 0 or z < 0 or x >= ax or y >= ay or z >= az then
			return false
		end
		return buffer.readu8(b, x + y * ax + z * ax * ay) >= 128
	end
	local function countFaces(b: buffer, ax: number, ay: number, az: number): number
		local count = 0
		for z = -1, az - 1 do
			for y = -1, ay - 1 do
				for x = -1, ax - 1 do
					local v = solidAt(b, ax, ay, az, x, y, z)
					if v ~= solidAt(b, ax, ay, az, x + 1, y, z) then
						count += 1
					end
					if v ~= solidAt(b, ax, ay, az, x, y + 1, z) then
						count += 1
					end
					if v ~= solidAt(b, ax, ay, az, x, y, z + 1) then
						count += 1
					end
				end
			end
		end
		return count
	end
	while true do
		cx, cy, cz, cells = coarse(f)
		local faces = countFaces(cells, cx, cy, cz)
		if faces <= MAX_QUADS then
			break
		end
		-- Face count shrinks about with f²; jump close to the target and refine.
		f = math.max(f + 1, math.floor(f * math.sqrt(faces / MAX_QUADS)))
		task.wait()
	end

	-- One vertex per dual cube (corners = 8 cell centres) that straddles the surface, at the average of
	-- its crossing edges' midpoints. Coordinates are in coarse cell-centre units.
	local sx1, sxy1 = cx + 1, (cx + 1) * (cy + 1)
	local function key(x: number, y: number, z: number): number
		return (x + 1) + (y + 1) * sx1 + (z + 1) * sxy1
	end
	local vertexOf: { [number]: number } = {}
	local px, py, pz = {}, {}, {}
	local function vertex(x: number, y: number, z: number): number
		local k = key(x, y, z)
		local v = vertexOf[k]
		if v then
			return v
		end
		local sumX, sumY, sumZ, n = 0, 0, 0, 0
		-- 12 cube edges: 4 along each axis
		for a = 0, 1 do
			for b = 0, 1 do
				if solidAt(cells, cx, cy, cz, x, y + a, z + b) ~= solidAt(cells, cx, cy, cz, x + 1, y + a, z + b) then
					sumX += x + 0.5
					sumY += y + a
					sumZ += z + b
					n += 1
				end
				if solidAt(cells, cx, cy, cz, x + a, y, z + b) ~= solidAt(cells, cx, cy, cz, x + a, y + 1, z + b) then
					sumX += x + a
					sumY += y + 0.5
					sumZ += z + b
					n += 1
				end
				if solidAt(cells, cx, cy, cz, x + a, y + b, z) ~= solidAt(cells, cx, cy, cz, x + a, y + b, z + 1) then
					sumX += x + a
					sumY += y + b
					sumZ += z + 0.5
					n += 1
				end
			end
		end
		table.insert(px, sumX / n)
		table.insert(py, sumY / n)
		table.insert(pz, sumZ / n)
		v = #px
		vertexOf[k] = v
		return v
	end

	-- One quad per face between a solid and an empty cell, joining the 4 dual cubes around that face.
	-- Offsets are in the face's (b, c) plane with b × c = a, so this order faces +a.
	local quads: { number } = {}
	local OFFSETS = { { -1, -1 }, { 0, -1 }, { 0, 0 }, { -1, 0 } }
	for z = -1, cz - 1 do
		for y = -1, cy - 1 do
			for x = -1, cx - 1 do
				local v = solidAt(cells, cx, cy, cz, x, y, z)
				for a = 1, 3 do
					local nxt = if a == 1 then solidAt(cells, cx, cy, cz, x + 1, y, z)
						elseif a == 2 then solidAt(cells, cx, cy, cz, x, y + 1, z)
						else solidAt(cells, cx, cy, cz, x, y, z + 1)
					if v == nxt then
						continue
					end
					local ids = table.create(4)
					for i, o in OFFSETS do
						local ob, oc = o[1], o[2]
						local id
						if a == 1 then
							id = vertex(x, y + ob, z + oc) -- b = Y, c = Z
						elseif a == 2 then
							id = vertex(x + oc, y, z + ob) -- b = Z, c = X
						else
							id = vertex(x + ob, y + oc, z) -- b = X, c = Y
						end
						ids[i] = id
					end
					if v then -- solid on the low side: the surface faces +a
						table.insert(quads, ids[1])
						table.insert(quads, ids[2])
						table.insert(quads, ids[3])
						table.insert(quads, ids[4])
					else
						table.insert(quads, ids[4])
						table.insert(quads, ids[3])
						table.insert(quads, ids[2])
						table.insert(quads, ids[1])
					end
				end
			end
		end
		if z % 8 == 7 then
			task.wait()
		end
	end

	-- Laplacian smoothing over the quad edges takes the stair-steps off.
	local nv = #px
	local neighbours: { { number } } = table.create(nv)
	for i = 1, nv do
		neighbours[i] = {}
	end
	for q = 1, #quads, 4 do
		for e = 0, 3 do
			local a, b = quads[q + e], quads[q + (e + 1) % 4]
			if not table.find(neighbours[a], b) then
				table.insert(neighbours[a], b)
				table.insert(neighbours[b], a)
			end
		end
	end
	for _ = 1, SMOOTH_PASSES do
		local qx, qy, qz = table.create(nv), table.create(nv), table.create(nv)
		for i = 1, nv do
			local list = neighbours[i]
			local ax, ay, az = 0, 0, 0
			for _, j in list do
				ax += px[j]
				ay += py[j]
				az += pz[j]
			end
			local k = #list
			if k > 0 then
				qx[i] = px[i] * 0.5 + ax / k * 0.5
				qy[i] = py[i] * 0.5 + ay / k * 0.5
				qz[i] = pz[i] * 0.5 + az / k * 0.5
			else
				qx[i], qy[i], qz[i] = px[i], py[i], pz[i]
			end
		end
		px, py, pz = qx, qy, qz
	end

	-- Coarse cell-centre units → studs, centred on the mask.
	local size = mask.size
	local kx, ky, kz = f * size.X / nx, f * size.Y / ny, f * size.Z / nz
	local em = AssetService:CreateEditableMesh({})
	local ids = table.create(nv)
	for i = 1, nv do
		ids[i] = em:AddVertex(Vector3.new((px[i] + 0.5) * kx - size.X / 2, (py[i] + 0.5) * ky - size.Y / 2, (pz[i] + 0.5) * kz - size.Z / 2))
	end
	for q = 1, #quads, 4 do
		local a, b, c, d = ids[quads[q]], ids[quads[q + 1]], ids[quads[q + 2]], ids[quads[q + 3]]
		em:AddTriangle(a, b, c)
		em:AddTriangle(a, c, d)
	end
	local part = AssetService:CreateMeshPartAsync(Content.fromObject(em))
	return part, em
end

return SurfaceMesh
