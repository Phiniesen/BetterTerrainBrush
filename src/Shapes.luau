--!strict
--!native
--!optimize 2
-- Shapes: the built-in brush shapes as signed distance functions (negative inside), in the same units
-- as the half extents passed in. Stamp evaluates them exactly in world studs; Voxelizer samples them
-- to build ghost previews. Flat shapes (Half Circle, U, V) are drawn in the brush's XY plane and run
-- along its Z axis, so with "Face along the stroke" a drag makes a continuous trough or ridge.

local Shapes = {}

Shapes.List = { "Sphere", "Cube", "Cylinder", "Donut", "Hollow Cylinder", "Half Circle", "Half Dome", "U", "V" }

-- How Size and Height map onto each shape:
--   uniform: Size only. height: Size × Height × Size. length: Size × Size × Length (Height slider).
Shapes.Scaling = {
	Sphere = "uniform",
	Donut = "uniform",
	["Half Dome"] = "uniform",
	Cube = "height",
	Cylinder = "height",
	["Hollow Cylinder"] = "height",
	["Half Circle"] = "length",
	U = "length",
	V = "length",
}

-- Shapes with a wall thickness (fraction of the outer radius / half width).
Shapes.Hollow = { Donut = true, ["Hollow Cylinder"] = true, U = true, V = true }

-- Bounding size at scale 1. `t` is the wall thickness.
function Shapes.unitSize(kind: string, t: number): Vector3
	if kind == "Donut" then
		return Vector3.new(1, 0.5 * t, 1) -- tube diameter = t × outer radius
	elseif kind == "Half Circle" or kind == "Half Dome" then
		return Vector3.new(1, 0.5, 1)
	end
	return Vector3.one
end

-- Ellipsoid distance estimate (exact for a sphere).
local function ellipsoid(x: number, y: number, z: number, a: number, b: number, c: number): number
	local qx, qy, qz = x / a, y / b, z / c
	local k0 = math.sqrt(qx * qx + qy * qy + qz * qz)
	if k0 < 1e-6 then
		return -math.min(a, b, c)
	end
	local k1 = math.sqrt((qx / a) ^ 2 + (qy / b) ^ 2 + (qz / c) ^ 2)
	return k0 * (k0 - 1) / k1
end

-- 2D ellipse distance estimate (exact for a circle).
local function ellipse(x: number, y: number, a: number, b: number): number
	local qx, qy = x / a, y / b
	local k0 = math.sqrt(qx * qx + qy * qy)
	if k0 < 1e-6 then
		return -math.min(a, b)
	end
	local k1 = math.sqrt((qx / a) ^ 2 + (qy / b) ^ 2)
	return k0 * (k0 - 1) / k1
end

-- Combine two distances as an intersection with exact outside corners (extrusions, capped cylinders).
local function intersect(a: number, b: number): number
	local oa, ob = math.max(a, 0), math.max(b, 0)
	return math.sqrt(oa * oa + ob * ob) + math.min(math.max(a, b), 0)
end

-- Distance from (px, py) to the segment a-b.
local function segment(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
	local abx, aby = bx - ax, by - ay
	local t = math.clamp(((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby), 0, 1)
	local dx, dy = px - ax - abx * t, py - ay - aby * t
	return math.sqrt(dx * dx + dy * dy)
end

-- Signed distance from a brush-local point to the shape filling the box with half extents (hx, hy, hz).
-- Perf: CPU Low per call (a few square roots) | Memory Low
function Shapes.distance(kind: string, x: number, y: number, z: number, hx: number, hy: number, hz: number, t: number): number
	if kind == "Sphere" then
		return ellipsoid(x, y, z, hx, hy, hz)
	elseif kind == "Cube" then
		local dx, dy, dz = math.abs(x) - hx, math.abs(y) - hy, math.abs(z) - hz
		local ox, oy, oz = math.max(dx, 0), math.max(dy, 0), math.max(dz, 0)
		return math.sqrt(ox * ox + oy * oy + oz * oz) + math.min(math.max(dx, dy, dz), 0)
	elseif kind == "Cylinder" then
		return intersect(ellipse(x, z, hx, hz), math.abs(y) - hy)
	elseif kind == "Hollow Cylinder" then
		local k = 1 - math.clamp(t, 0.02, 0.98)
		local shell = math.max(ellipse(x, z, hx, hz), -ellipse(x, z, hx * k, hz * k))
		return intersect(shell, math.abs(y) - hy)
	elseif kind == "Donut" then
		-- Tube radius = half height; the ring runs through the middle of the remaining width.
		local ring = (hx + hz) / 2 - hy
		local rho = math.sqrt(x * x + z * z)
		local dr = rho - ring
		return math.sqrt(dr * dr + y * y) - hy
	elseif kind == "Half Dome" then
		-- Top half of an ellipsoid centred on the bottom face.
		local yb = y + hy
		return math.max(ellipsoid(x, yb, z, hx, 2 * hy, hz), -yb)
	elseif kind == "Half Circle" then
		-- Half disc standing on the bottom face, extruded along Z.
		local yb = y + hy
		return intersect(math.max(ellipse(x, yb, hx, 2 * hy), -yb), math.abs(z) - hz)
	elseif kind == "U" then
		-- Distance to the U's centreline (bottom half circle + two upright bars), thickened, with a flat
		-- top, extruded along Z. Thickening one centreline (instead of joining a half ring and two bars)
		-- leaves no internal face, which terrain would draw as a crack at the joins.
		local w = math.clamp(t, 0.02, 0.98) * hx
		local rc = hx - w / 2 -- centreline radius of the bottom arc (and x of the bars)
		local yc = -hy + math.min(hx, 2 * hy) -- arc centre, so the arc's outside touches the bottom
		local ax, dy = math.abs(x), y - yc
		local line
		if dy <= 0 then
			line = math.abs(math.sqrt(ax * ax + dy * dy) - rc) -- nearest point is on the half circle
		else
			line = math.sqrt((ax - rc) ^ 2 + (dy - math.clamp(dy, 0, math.max(hy - yc, 0))) ^ 2) -- on a bar
		end
		return intersect(math.max(line - w / 2, y - hy), math.abs(z) - hz)
	elseif kind == "V" then
		-- Two slanted bars meeting at the bottom, flat on top, extruded along Z.
		local w = math.clamp(t, 0.02, 0.98) * hx
		local topX, tipY = hx - w / 2, -hy + w / 2
		local arms = math.min(segment(x, y, -topX, hy, 0, tipY), segment(x, y, topX, hy, 0, tipY)) - w / 2
		return intersect(math.max(arms, y - hy, math.abs(x) - hx), math.abs(z) - hz)
	end
	return math.huge
end

return Shapes
