--!strict
--!optimize 2
-- MeshImport: reads uploaded mesh files (.obj, .stl ASCII or binary) into a vertex list and
-- triangle index list for Voxelizer.fromTriangles. Materials, UVs and normals are ignored: a brush
-- only needs the shape.

local MeshImport = {}

MeshImport.Extensions = { "obj", "stl" }

export type Mesh = {
	verts: { Vector3 },
	tris: { number }, -- 1-based vertex indices, three per triangle
}

-- Perf: CPU Medium (one pass over the file text; ~1 s per 50 MB) | Memory Medium (one Vector3 per vertex)
local function parseObj(text: string): Mesh
	local verts: { Vector3 } = {}
	local tris: { number } = {}
	local face: { number } = {}
	local lines = 0
	for line in string.gmatch(text, "[^\r\n]+") do
		local tag, rest = string.match(line, "^%s*(%S+)%s*(.*)$")
		if tag == "v" and rest then
			local x, y, z = string.match(rest, "^(%S+)%s+(%S+)%s+(%S+)")
			local nx, ny, nz = tonumber(x), tonumber(y), tonumber(z)
			if nx and ny and nz then
				table.insert(verts, Vector3.new(nx, ny, nz))
			else
				table.insert(verts, Vector3.zero) -- keep later indices lined up
			end
		elseif tag == "f" and rest then
			table.clear(face)
			for token in string.gmatch(rest, "%S+") do
				local i = tonumber(string.match(token, "^(-?%d+)"))
				if not i then
					break
				end
				if i < 0 then
					i = #verts + 1 + i -- relative index
				end
				table.insert(face, i)
			end
			local valid = #face >= 3
			for _, i in face do
				if i < 1 or i > #verts then
					valid = false
				end
			end
			if valid then
				-- Fan triangulation (faces are convex in practice).
				for k = 2, #face - 1 do
					table.insert(tris, face[1])
					table.insert(tris, face[k])
					table.insert(tris, face[k + 1])
				end
			end
		end
		lines += 1
		if lines % 50000 == 0 then
			task.wait()
		end
	end
	return { verts = verts, tris = tris }
end

-- Perf: CPU Medium (one pass) | Memory Medium (three Vector3 per triangle; STL has no shared vertices)
local function parseStl(data: string): Mesh
	local verts: { Vector3 } = {}
	local tris: { number } = {}
	local binary = false
	if #data >= 84 then
		local count = string.unpack("<I4", data, 81)
		binary = 84 + count * 50 == #data
	end
	if binary then
		local count = string.unpack("<I4", data, 81)
		local pos = 85
		for t = 1, count do
			local x1, y1, z1, x2, y2, z2, x3, y3, z3 = string.unpack("<fffffffff", data, pos + 12)
			table.insert(verts, Vector3.new(x1, y1, z1))
			table.insert(verts, Vector3.new(x2, y2, z2))
			table.insert(verts, Vector3.new(x3, y3, z3))
			local n = #verts
			table.insert(tris, n - 2)
			table.insert(tris, n - 1)
			table.insert(tris, n)
			pos += 50
			if t % 50000 == 0 then
				task.wait()
			end
		end
	else
		local pending = 0
		for x, y, z in string.gmatch(data, "vertex%s+(%S+)%s+(%S+)%s+(%S+)") do
			local nx, ny, nz = tonumber(x), tonumber(y), tonumber(z)
			if not (nx and ny and nz) then
				error("Bad vertex in STL file", 0)
			end
			table.insert(verts, Vector3.new(nx, ny, nz))
			pending += 1
			if pending == 3 then
				local n = #verts
				table.insert(tris, n - 2)
				table.insert(tris, n - 1)
				table.insert(tris, n)
				pending = 0
			end
		end
	end
	return { verts = verts, tris = tris }
end

-- "obj", "stl" or nil, from the extension, else from the contents.
local function format(fileName: string, data: string): string?
	local ext = string.lower(string.match(fileName, "%.([^%.]+)$") or "")
	if ext == "obj" or ext == "stl" then
		return ext
	end
	if #data >= 84 and 84 + string.unpack("<I4", data, 81) * 50 == #data then
		return "stl"
	end
	local head = string.sub(data, 1, 4096)
	if string.find(head, "^%s*solid") and string.find(data, "facet", 1, true) then
		return "stl"
	end
	if string.find(head, "^v%s") or string.find(head, "\nv%s") then
		return "obj"
	end
	return nil
end

-- Parse an .obj or .stl file. `zUp` converts from Z-up (most STL / CAD exports) to Roblox's Y-up.
-- Perf: CPU Medium (see the parsers) | Memory Medium
function MeshImport.parse(fileName: string, data: string, zUp: boolean): Mesh
	local kind = format(fileName, data)
	local mesh: Mesh
	if kind == "obj" then
		mesh = parseObj(data)
	elseif kind == "stl" then
		mesh = parseStl(data)
	else
		error(fileName .. " isn't an .obj or .stl mesh", 0)
	end
	if #mesh.tris == 0 then
		error("No triangles found in " .. fileName, 0)
	end
	if zUp then
		-- (x, y, z) Z-up → (x, z, -y) Y-up. A proper rotation, so face winding is kept.
		for i, v in mesh.verts do
			mesh.verts[i] = Vector3.new(v.X, v.Z, -v.Y)
		end
	end
	return mesh
end

-- Brush name from a file name: "Rock_Arch.obj" → "Rock_Arch".
function MeshImport.baseName(fileName: string): string
	local name = string.match(fileName, "([^/\\]+)$") or fileName
	return (string.gsub(name, "%.[^%.]*$", ""))
end

return MeshImport
