--!strict
-- Paths: parametric shapes the brush follows, resampled to evenly spaced stamp points.
-- Points are in a flat local frame: u = path right (+X), v = path forward (+Z), h = height.
-- Seen from above, a positive angle step turns clockwise (+X towards +Z).

local Paths = {}

Paths.Shapes = { "Freehand", "Line", "Circle", "Square", "Polygon", "Spiral" }

export type Params = {
	shape: string,
	radius: number, -- outer radius; half-length for Line, half-width for Square
	innerRadius: number, -- Spiral start radius
	turns: number, -- loops for Circle/Square/Polygon/Spiral
	sides: number, -- Polygon
	rise: number, -- total height gained from start to end (helix / ramp)
	angle: number, -- start angle / rotation in degrees
	clockwise: boolean,
}

export type Point = {
	u: number,
	v: number,
	h: number, -- 0..rise along the path
	tu: number, -- unit tangent (direction of travel)
	tv: number,
}

-- Dense polyline of the shape (no height). Returns points and whether it is a closed loop.
-- Perf: CPU Low (≤ a few thousand points, only when the path changes) | Memory Low
local function polyline(p: Params): ({ Vector2 }, boolean)
	local dir = if p.clockwise then 1 else -1
	local a0 = math.rad(p.angle)
	local R = math.max(p.radius, 0.1)
	local turns = math.max(p.turns, 0.05)
	local pts: { Vector2 } = {}

	if p.shape == "Line" then
		local d = Vector2.new(math.cos(a0), math.sin(a0)) * R * dir
		table.insert(pts, -d)
		table.insert(pts, d)
		return pts, false
	elseif p.shape == "Circle" or p.shape == "Spiral" then
		local spiral = p.shape == "Spiral"
		local r0 = if spiral then math.clamp(p.innerRadius, 0, R) else R
		local steps = math.max(24, math.ceil(96 * turns))
		for i = 0, steps do
			local t = i / steps
			local a = a0 + dir * 2 * math.pi * turns * t
			local r = r0 + (R - r0) * t
			table.insert(pts, Vector2.new(math.cos(a) * r, math.sin(a) * r))
		end
		return pts, not spiral and math.abs(turns - math.round(turns)) < 1e-3
	else -- Square / Polygon
		local sides = if p.shape == "Square" then 4 else math.clamp(math.round(p.sides), 3, 64)
		local radius = R
		local start = a0
		if p.shape == "Square" then
			radius = R * math.sqrt(2) -- radius = half-width
			start = a0 + math.pi / 4
		end
		local corners = math.max(1, math.round(sides * turns))
		for k = 0, corners do
			local a = start + dir * 2 * math.pi * k / sides
			table.insert(pts, Vector2.new(math.cos(a) * radius, math.sin(a) * radius))
		end
		return pts, corners % sides == 0
	end
end

-- Stamp points every `spacing` studs along the path, and whether they form a closed loop (the last
-- point leads back to the first).
-- Perf: CPU Low (linear in polyline length) | Memory Low
function Paths.generate(p: Params, spacing: number): ({ Point }, boolean)
	local pts, closed = polyline(p)
	spacing = math.max(spacing, 0.5)
	local total = 0
	for i = 2, #pts do
		total += (pts[i] - pts[i - 1]).Magnitude
	end
	local out: { Point } = {}
	if total <= 0 then
		return out, false
	end

	local function emit(pos: Vector2, tangent: Vector2, dist: number)
		table.insert(out, { u = pos.X, v = pos.Y, h = p.rise * dist / total, tu = tangent.X, tv = tangent.Y })
	end

	local nextAt = 0
	local walked = 0
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		local seg = (b - a).Magnitude
		if seg > 0 then
			local t = (b - a) / seg
			while nextAt <= walked + seg + 1e-6 do
				emit(a + t * (nextAt - walked), t, nextAt)
				nextAt += spacing
			end
			walked += seg
		end
	end
	-- Finish open paths exactly at their end; closed loops already meet their start.
	local last = out[#out]
	local endPos, endPrev = pts[#pts], pts[#pts - 1]
	local endDist = (Vector2.new(last.u, last.v) - endPos).Magnitude
	local loop = closed and math.abs(p.rise) < 1e-3
	if loop then
		if endDist < spacing * 0.5 and #out > 1 then
			table.remove(out) -- would overlap the first stamp
		end
	elseif endDist > spacing * 0.25 then
		emit(endPos, (endPos - endPrev).Unit, total)
	end
	return out, loop
end

return Paths
