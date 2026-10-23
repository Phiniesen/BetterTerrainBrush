--!strict
-- Library: brushes saved with the plugin (plugin settings), so they're available in every place.
-- A brush is stored as its voxel mask: run-length encoded, varint-packed and base64'd into a string.
-- The index (names and sizes) and each brush's data live under separate keys, so adding or
-- removing one brush never rewrites the others.

local HttpService = game:GetService("HttpService")

local Voxelizer = require(script.Parent.Voxelizer)
type Mask = Voxelizer.Mask

local Library = {}
Library.__index = Library

local INDEX_KEY = "TerrainBrushes_Library_v1"
local DATA_PREFIX = "TerrainBrushes_LibraryBrush_"

export type Entry = {
	id: string,
	name: string,
	nx: number,
	ny: number,
	nz: number,
	sx: number,
	sy: number,
	sz: number,
	filled: number,
}

export type Library = typeof(setmetatable({} :: {
	plugin: Plugin,
	entries: { Entry },
	cache: { [string]: Mask },
}, Library))

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_CHARS: { string } = {}
local B64_VALUES: { [number]: number } = {}
for i = 1, 64 do
	B64_CHARS[i - 1] = string.sub(B64, i, i)
	B64_VALUES[string.byte(B64, i)] = i - 1
end

-- Perf: CPU Low-Medium (linear in bytes) | Memory Low
local function toBase64(b: buffer, len: number): string
	local parts = table.create(math.ceil(len / 3))
	for i = 0, len - 1, 3 do
		local n = buffer.readu8(b, i) * 65536
		local rem = len - i
		if rem > 1 then
			n += buffer.readu8(b, i + 1) * 256
		end
		if rem > 2 then
			n += buffer.readu8(b, i + 2)
		end
		local c1, c2 = B64_CHARS[n // 262144], B64_CHARS[(n // 4096) % 64]
		local c3 = if rem > 1 then B64_CHARS[(n // 64) % 64] else "="
		local c4 = if rem > 2 then B64_CHARS[n % 64] else "="
		table.insert(parts, c1 .. c2 .. c3 .. c4)
	end
	return table.concat(parts)
end

-- Perf: CPU Low-Medium (linear in characters) | Memory Low
local function fromBase64(s: string): (buffer, number)
	local out = buffer.create(#s // 4 * 3)
	local len = 0
	for i = 1, #s - 3, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local va, vb = B64_VALUES[a], B64_VALUES[b]
		assert(va and vb, "Corrupt brush data")
		local vc, vd = B64_VALUES[c], B64_VALUES[d]
		local n = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
		buffer.writeu8(out, len, n // 65536)
		len += 1
		if vc then
			buffer.writeu8(out, len, (n // 256) % 256)
			len += 1
		end
		if vd then
			buffer.writeu8(out, len, n % 256)
			len += 1
		end
	end
	return out, len
end

-- Mask cells → alternating empty/solid run lengths (starting with empty) as LEB128 varints → base64.
-- Perf: CPU Medium (one pass over the cells, ~0.1 s at detail 96) | Memory Low
function Library.encode(mask: Mask): string
	local cells = mask.nx * mask.ny * mask.nz
	local out = buffer.create(cells + 16) -- a run of length L takes at most L bytes
	local len = 0
	local function put(n: number)
		while n >= 128 do
			buffer.writeu8(out, len, n % 128 + 128)
			len += 1
			n //= 128
		end
		buffer.writeu8(out, len, n)
		len += 1
	end
	local solid, run = false, 0
	for i = 0, cells - 1 do
		local v = buffer.readu8(mask.data, i) >= 128
		if v ~= solid then
			put(run)
			solid, run = v, 0
		end
		run += 1
	end
	put(run)
	return toBase64(out, len)
end

-- Perf: CPU Medium (one pass over the cells) | Memory Low
function Library.decode(s: string, nx: number, ny: number, nz: number): buffer
	local packed, len = fromBase64(s)
	local cells = nx * ny * nz
	local data = buffer.create(cells)
	local pos, cell, solid = 0, 0, false
	while pos < len do
		local n, shift = 0, 1
		repeat
			local byte = buffer.readu8(packed, pos)
			pos += 1
			n += (byte % 128) * shift
			shift *= 128
		until byte < 128 or pos >= len
		assert(cell + n <= cells, "Corrupt brush data")
		if solid and n > 0 then
			buffer.fill(data, cell, 255, n)
		end
		cell += n
		solid = not solid
	end
	assert(cell == cells, "Corrupt brush data")
	return data
end

-- Perf: CPU Low (reads the index setting) | Memory Low
function Library.new(plugin: Plugin): Library
	local entries: { Entry } = {}
	local ok, saved = pcall(function()
		return plugin:GetSetting(INDEX_KEY)
	end)
	if ok and type(saved) == "table" then
		for _, e in saved do
			if type(e) == "table" and type(e.id) == "string" and type(e.name) == "string" and type(e.nx) == "number" then
				table.insert(entries, e)
			end
		end
	end
	return setmetatable({ plugin = plugin, entries = entries, cache = {} }, Library)
end

function Library.saveIndex(self: Library)
	pcall(function()
		self.plugin:SetSetting(INDEX_KEY, self.entries)
	end)
end

function Library.find(self: Library, id: string): Entry?
	for _, e in self.entries do
		if e.id == id then
			return e
		end
	end
	return nil
end

-- A unique display name: "Rock", "Rock 2", …
function Library.uniqueName(self: Library, base: string): string
	local name, n = base, 1
	local function taken(s: string): boolean
		for _, e in self.entries do
			if e.name == s then
				return true
			end
		end
		return false
	end
	while taken(name) do
		n += 1
		name = base .. " " .. n
	end
	return name
end

-- Save a voxel mask as a new library brush.
-- Perf: CPU Medium (encode) | Memory Low
function Library.add(self: Library, name: string, mask: Mask): Entry
	assert(mask.kind == "Grid", "Only mesh brushes can be saved to the library")
	local entry: Entry = {
		id = (string.gsub(HttpService:GenerateGUID(false), "-", "")),
		name = self:uniqueName(name),
		nx = mask.nx,
		ny = mask.ny,
		nz = mask.nz,
		sx = mask.size.X,
		sy = mask.size.Y,
		sz = mask.size.Z,
		filled = mask.filled,
	}
	self.plugin:SetSetting(DATA_PREFIX .. entry.id, Library.encode(mask))
	table.insert(self.entries, entry)
	table.sort(self.entries, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	self:saveIndex()
	self.cache[entry.id] = mask
	return entry
end

-- Returns the name actually used (made unique), or nil if the brush doesn't exist.
function Library.rename(self: Library, id: string, name: string): string?
	local e = self:find(id)
	if not e then
		return nil
	end
	name = string.gsub(name, "^%s*(.-)%s*$", "%1")
	if name == "" or name == e.name then
		return e.name
	end
	e.name = "" -- so uniqueName doesn't count the brush's own old name
	e.name = self:uniqueName(name)
	table.sort(self.entries, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	self:saveIndex()
	return e.name
end

function Library.remove(self: Library, id: string)
	for i, e in self.entries do
		if e.id == id then
			table.remove(self.entries, i)
			break
		end
	end
	self.cache[id] = nil
	self:saveIndex()
	pcall(function()
		self.plugin:SetSetting(DATA_PREFIX .. id, nil)
	end)
end

-- The brush's mask (decoded once, then cached). Yields (distance field).
-- Perf: CPU Medium on first use (decode + distance field) else Low | Memory Low-Medium (detail³ × 5 bytes)
function Library.mask(self: Library, id: string): Mask
	local cached = self.cache[id]
	if cached then
		return cached
	end
	local e = self:find(id)
	assert(e, "Library brush not found")
	local s = self.plugin:GetSetting(DATA_PREFIX .. id)
	assert(type(s) == "string", "Library brush data is missing")
	local m: Mask = {
		kind = "Grid",
		nx = e.nx,
		ny = e.ny,
		nz = e.nz,
		size = Vector3.new(e.sx, e.sy, e.sz),
		data = Library.decode(s, e.nx, e.ny, e.nz),
		sdf = nil,
		filled = e.filled,
		frame = CFrame.identity,
	}
	Voxelizer.distanceField(m)
	self.cache[id] = m
	return m
end

return Library
