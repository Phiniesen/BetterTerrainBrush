--!strict
-- Preview: the see-through brush "ghost" under the cursor, the dots of a path, the plane used by
-- Flatten / Plane lock and the rotation gizmo. The ghost lives in the camera with Archivable off, so
-- it is never saved or recorded; path dots, the plane and the gizmo are adornments in CoreGui.
--
-- Sphere / Cube / Cylinder show as a plain part. Mesh brushes and the other built-in shapes show the
-- surface of their voxel grid (SurfaceMesh), which stretches correctly with Height.

local CoreGui = game:GetService("CoreGui")

local Voxelizer = require(script.Parent.Voxelizer)
local SurfaceMesh = require(script.Parent.SurfaceMesh)
type Mask = Voxelizer.Mask

local Preview = {}
Preview.__index = Preview

type Surface = { part: MeshPart, mesh: EditableMesh, size: Vector3 }

export type Preview = typeof(setmetatable({} :: {
	folder: Folder,
	model: Model,
	highlight: Highlight,
	dots: Folder,
	pool: { SphereHandleAdornment },
	plane: BoxHandleAdornment,
	anchor: Part,
	handles: ArcHandles,
	ghost: BasePart?,
	kind: string,
	baseSize: Vector3,
	surfaces: { [Mask]: Surface },
}, Preview))

local PartShapes = Voxelizer.PartShapes

local function ghostify(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Archivable = false
	part.Color = Color3.fromRGB(200, 200, 200)
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0.6
end

function Preview.new(): Preview
	local folder = Instance.new("Folder")
	folder.Name = "TerrainBrushesPreview"
	folder.Archivable = false
	local model = Instance.new("Model")
	model.Name = "Ghost"
	model.Archivable = false
	model.Parent = folder
	local h = Instance.new("Highlight")
	h.FillTransparency = 0.8
	h.OutlineTransparency = 0.1
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Archivable = false
	h.Parent = model
	local dots = Instance.new("Folder")
	dots.Name = "TerrainBrushesPath"
	dots.Archivable = false
	dots.Parent = CoreGui
	local plane = Instance.new("BoxHandleAdornment")
	plane.Name = "Plane"
	plane.Adornee = workspace.Terrain
	plane.Transparency = 0.75
	plane.ZIndex = 0
	plane.AlwaysOnTop = false
	plane.Visible = false
	plane.Archivable = false
	plane.Parent = dots
	-- Rotation gizmo: arc handles on an invisible box that matches the brush, so the rings turn about
	-- the brush's own axes (the ghost part itself can be offset, e.g. cylinders run along X).
	local anchor = Instance.new("Part")
	anchor.Name = "RotateAnchor"
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Locked = true
	anchor.Archivable = false
	local handles = Instance.new("ArcHandles")
	handles.Name = "RotateHandles"
	handles.Adornee = anchor
	handles.Visible = false
	handles.Archivable = false
	handles.Parent = dots
	return setmetatable({
		folder = folder,
		model = model,
		highlight = h,
		dots = dots,
		pool = {},
		plane = plane,
		anchor = anchor,
		handles = handles,
		ghost = nil,
		kind = "",
		baseSize = Vector3.one,
		surfaces = {},
	}, Preview)
end

-- Build (once) the surface mesh a mesh brush's ghost needs. Yields the first time for each mask, so
-- callers can check the brush is still wanted before calling setBrush, which is then instant.
-- Perf: CPU Medium on a mesh brush's first use (SurfaceMesh.build) else Low | Memory Low-Medium (one EditableMesh per mesh brush used)
function Preview.prepare(self: Preview, mask: Mask)
	if PartShapes[mask.kind] or self.surfaces[mask] then
		return
	end
	local p, em = SurfaceMesh.build(mask)
	if self.surfaces[mask] then -- another call finished first
		p:Destroy()
		em:Destroy()
		return
	end
	ghostify(p)
	p.Name = "Brush"
	self.surfaces[mask] = { part = p, mesh = em, size = p.Size }
end

-- Show this brush from now on (calls prepare, so it can yield for an unprepared mesh brush).
-- Perf: CPU Low (built-in shapes, prepared meshes) | Memory Low
function Preview.setBrush(self: Preview, mask: Mask)
	local part: BasePart
	local baseSize = Vector3.one
	local meshed = not PartShapes[mask.kind]
	local s = if meshed then self.surfaces[mask] else nil
	if meshed and not s then
		local ok, err = pcall(self.prepare, self, mask)
		if not ok then
			warn("[Better Terrain Brush] Brush preview mesh failed, showing its bounding box: " .. tostring(err))
		end
		s = self.surfaces[mask]
	end
	if s then
		part = s.part
		baseSize = s.size
	elseif meshed then
		local p = Instance.new("Part")
		p.Name = "Brush"
		ghostify(p)
		part = p
		baseSize = mask.size
	else
		local p = Instance.new("Part")
		p.Name = "Brush"
		if mask.kind == "Sphere" then
			p.Shape = Enum.PartType.Ball
		elseif mask.kind == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		end
		ghostify(p)
		part = p
	end
	local old = self.ghost
	if old and old ~= part then
		if old:IsA("MeshPart") then
			old.Parent = nil -- cached surface, reused if this brush comes back
		else
			old:Destroy()
		end
	end
	part.Parent = self.model
	self.ghost = part
	self.kind = mask.kind
	self.baseSize = baseSize
end

-- Drop cached surface meshes (after brushes are rebuilt). Keeps the one on screen.
function Preview.clearCache(self: Preview)
	for mask, s in self.surfaces do
		if s.part ~= self.ghost then
			s.part:Destroy()
			s.mesh:Destroy()
			self.surfaces[mask] = nil
		end
	end
end

function Preview.setColor(self: Preview, color: Color3)
	self.highlight.OutlineColor = color
	self.highlight.FillColor = color
end

-- Place the ghost; nil hides it. `scale` multiplies the brush's unit size per axis.
-- Perf: CPU Low (one CFrame/Size write per frame) | Memory Low
function Preview.setGhost(self: Preview, cf: CFrame?, scale: Vector3)
	local ghost = self.ghost
	if not ghost or not cf then
		self.folder.Parent = nil
		return
	end
	if self.kind == "Cylinder" then
		-- Cylinder parts run along X; the brush's cylinder runs along Y.
		ghost.Size = Vector3.new(scale.Y, scale.X, scale.Z)
		ghost.CFrame = cf * CFrame.Angles(0, 0, math.pi / 2)
	else
		ghost.Size = self.baseSize * scale
		ghost.CFrame = cf
	end
	local camera = workspace.CurrentCamera
	if self.folder.Parent ~= camera then
		self.folder.Parent = camera
	end
end

-- Show the flatten / plane-lock plane as a thin plate; nil hides it.
function Preview.setPlane(self: Preview, cf: CFrame?, width: number, color: Color3?)
	local plane = self.plane
	if not cf then
		plane.Visible = false
		return
	end
	plane.CFrame = cf
	plane.Size = Vector3.new(width, 0.15, width)
	plane.Color3 = color or Color3.fromRGB(120, 200, 255)
	plane.Visible = true
end

-- Show path stamp points, coloured from green (start) to red (end).
-- Perf: CPU Low (reuses a pool of adornments) | Memory Low
function Preview.setPath(self: Preview, points: { Vector3 }?, dotRadius: number)
	local n = if points then #points else 0
	local start, finish = Color3.fromRGB(70, 220, 90), Color3.fromRGB(235, 70, 60)
	for i = 1, n do
		local dot = self.pool[i]
		if not dot then
			dot = Instance.new("SphereHandleAdornment")
			dot.AlwaysOnTop = true
			dot.ZIndex = 5
			dot.Transparency = 0.15
			dot.Adornee = workspace.Terrain
			dot.Archivable = false
			dot.Parent = self.dots
			self.pool[i] = dot
		end
		local t = if n > 1 then (i - 1) / (n - 1) else 0
		dot.Color3 = start:Lerp(finish, t)
		dot.Radius = if i == 1 then dotRadius * 1.8 else dotRadius
		dot.CFrame = CFrame.new((points :: { Vector3 })[i])
		dot.Visible = true
	end
	for i = n + 1, #self.pool do
		self.pool[i].Visible = false
	end
end

-- Show the rotation rings around a brush box (CFrame = the brush's, size in studs); nil hides them.
-- Perf: CPU Low | Memory Low
function Preview.setHandles(self: Preview, cf: CFrame?, size: Vector3?)
	local anchor, handles = self.anchor, self.handles
	if not cf or not size then
		handles.Visible = false
		anchor.Parent = nil
		return
	end
	anchor.Size = size:Max(Vector3.new(0.2, 0.2, 0.2))
	anchor.CFrame = cf
	anchor.Parent = self.folder
	handles.Visible = true
end

function Preview.hide(self: Preview)
	self:setGhost(nil, Vector3.one)
	self:setPath(nil, 1)
	self:setPlane(nil, 0)
	self:setHandles(nil)
end

function Preview.destroy(self: Preview)
	for _, s in self.surfaces do
		s.part:Destroy()
		s.mesh:Destroy()
	end
	table.clear(self.surfaces)
	self.anchor:Destroy()
	self.folder:Destroy()
	self.dots:Destroy()
end

return Preview
