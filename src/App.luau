--!strict
-- App: Better Terrain Brush!. The built-in Terrain Editor's brush tools (Draw, Sculpt, Smooth,
-- Flatten, Paint) with any brush shape: the built-in shapes (Shapes.List), Models or MeshParts kept in
-- ServerStorage.TerrainBrushes, or mesh files uploaded into the plugin's own library (every place).
-- Brushes can be turned freely with a rotation gizmo. Strokes can be freehand or follow a parametric
-- path (line, circle, square, polygon, spiral).
--
-- `host` overrides the Studio pieces (widget, mouse, keys, file prompt) so tests can drive the tool.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")
local StudioService = game:GetService("StudioService")
local UserInputService = game:GetService("UserInputService")

local Voxelizer = require(script.Parent.Voxelizer)
local Shapes = require(script.Parent.Shapes)
local Stamp = require(script.Parent.Stamp)
local Paths = require(script.Parent.Paths)
local Preview = require(script.Parent.Preview)
local Ui = require(script.Parent.Ui)
local Materials = require(script.Parent.Materials)
local Library = require(script.Parent.Library)
local MeshImport = require(script.Parent.MeshImport)

type Mask = Voxelizer.Mask

local App = {}

export type Host = {
	container: Instance?, -- replaces the dock widget
	mousePosition: (() -> Vector2)?, -- cursor relative to the container
	mouse: any?, -- replaces plugin:GetMouse(): UnitRay, X, Button1Down, Button1Up
	keyDown: ((Enum.KeyCode) -> boolean)?,
	promptFile: (() -> any)?, -- returns something with Name and GetBinaryContents, or nil
}

local TOOLS = { "Draw", "Sculpt", "Smooth", "Flatten", "Paint" }
local OP_COLORS = {
	Add = Color3.fromRGB(80, 200, 120),
	Subtract = Color3.fromRGB(235, 80, 70),
	Grow = Color3.fromRGB(240, 170, 60),
	Erode = Color3.fromRGB(200, 110, 230),
	Smooth = Color3.fromRGB(90, 210, 230),
	Flatten = Color3.fromRGB(240, 220, 80),
	Paint = Color3.fromRGB(80, 160, 240),
	Replace = Color3.fromRGB(150, 120, 250),
}
-- Ops that keep working while the mouse is held still, like the built-in Sculpt / Smooth / Flatten.
local CONTINUOUS = { Grow = true, Erode = true, Smooth = true, Flatten = true }
local PIVOTS = { Bottom = 1, Center = 0, Top = -1 }
local SETTINGS_KEY = "TerrainBrushes_v1"
local PLUGIN_NAME = "Better Terrain Brush!"
local PLUGIN_ID = "BetterTerrainBrush" -- toolbar button and dock widget ids
local PLUGIN_ICON = "rbxassetid://106169132634497" -- painted paper-card icon (64 px); must be Open Use so everyone can load it
local FOLDER_NAME = "TerrainBrushes" -- place brushes live in ServerStorage.TerrainBrushes
local RES = 4
local REPEAT = 0.08 -- seconds between stamps while held still
local MAX_FILL = 8 -- stamps per frame when a fast stroke leaves a gap
local PLANE_STEP = math.pi / 4 -- Auto plane lock turns to face the camera in 45° steps

local DEFAULTS: { [string]: any } = {
	tool = "Draw",
	drawMode = "Add",
	sculptMode = "Grow",
	flattenMode = "Both",
	paintMode = "Paint",
	brush = "Sphere",
	detail = 48,
	thicken = 1,
	material = Materials.GRASS,
	source = 8, -- Rock
	autoMaterial = false,
	replaceMaterial = false,
	strength = 0.3,
	size = 24,
	height = 24,
	keepProportions = true,
	pivot = "Center",
	nudge = 0,
	snap = false,
	planeLock = "Off",
	planeNormal = "Up",
	manualPlane = {}, -- { x, y, z, nx, ny, nz } once picked
	fixedPlane = false,
	ignoreWater = false,
	ignoreParts = false,
	thickness = 0.4, -- wall thickness of Donut / Hollow Cylinder / U / V (fraction of the outer radius)
	rotX = 0, -- brush rotation in degrees (XYZ Euler, applied in the brush's own frame)
	rotY = 0,
	rotZ = 0,
	rotateSnap = true, -- gizmo snaps to Studio's rotate increment
	randomRotation = false,
	autoRotate = false, -- turn the brush on its own while dragging
	tiltToSurface = true, -- (auto-rotate) brush up follows the surface normal
	facePath = true, -- (auto-rotate) brush front (-Z) follows the stroke / path direction
	spacing = 0.5,
	shape = "Freehand",
	radius = 40,
	innerRadius = 8,
	turns = 1,
	sides = 6,
	rise = 0,
	angle = 0,
	clockwise = true,
	followGround = false, -- paths drape over the terrain under them; off = the exact shape at the placed height
	wholePath = false, -- true: one click stamps the whole path; false: place the path, then drag along it
	speed = 2,
	uploadZUp = false,
	pickerOpen = true,
	sourceOpen = false,
}

type Hit = { pos: Vector3, normal: Vector3 }
type Plane = { point: Vector3, normal: Vector3 }
type PathStamp = { pos: Vector3, normal: Vector3, tangent: Vector3 }

-- Perf: CPU Low idle (one raycast + ghost move per frame while active); Medium-High while stamping (see Stamp.apply) | Memory Low-Medium (brush masks + ghost meshes)
function App.start(plugin: Plugin, host: Host?)
	local h: Host = host or {}
	local terrain = workspace.Terrain

	-- Settings (persisted per user) ----------------------------------------------------------------
	local S: { [string]: any } = table.clone(DEFAULTS)
	do
		local ok, saved = pcall(function()
			return plugin:GetSetting(SETTINGS_KEY)
		end)
		if ok and type(saved) == "table" then
			for k, v in saved do
				if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then
					S[k] = v
				end
			end
		end
		if not table.find(TOOLS, S.tool) then
			S.tool = "Draw"
		end
	end

	local saveQueued = false
	-- Perf: CPU Low (debounced disk write) | Memory Low
	local function save()
		if saveQueued then
			return
		end
		saveQueued = true
		task.delay(0.5, function()
			saveQueued = false
			pcall(function()
				plugin:SetSetting(SETTINGS_KEY, S)
			end)
		end)
	end

	local updateVisibility: () -> () = function() end
	local function setter(key: string, after: (() -> ())?)
		return function(v: any)
			S[key] = v
			save()
			if after then
				after()
			end
			updateVisibility()
		end
	end

	-- Brushes -------------------------------------------------------------------------------------
	local library = Library.new(plugin)
	local primitives: { [string]: Mask } = {}
	for _, shape in Voxelizer.Shapes do
		primitives[shape] = Voxelizer.primitive(shape, S.thickness)
	end
	local placeMasks: { [Instance]: Mask } = {}
	local mask: Mask? = nil -- current brush's mask (nil while building)
	local buildToken = 0
	local preview = Preview.new()
	local statusLabel: TextLabel? = nil
	local refreshBrushList: () -> () = function() end

	local function setStatus(text: string)
		if statusLabel then
			statusLabel.Text = text
		end
	end

	local function brushFolder(): Folder?
		local f = ServerStorage:FindFirstChild(FOLDER_NAME)
		return if f and f:IsA("Folder") then f else nil
	end

	local function brushSource(name: string): Instance?
		local f = brushFolder()
		local inst = f and f:FindFirstChild(name)
		if inst and (inst:IsA("Model") or inst:IsA("BasePart")) then
			return inst
		end
		return nil
	end

	-- "Sphere" → primitive; "place:Rock" → ServerStorage brush; "lib:<id>" → library brush.
	-- Bare names come from the previous version's settings and mean place brushes.
	local function brushKind(key: string): (string, string)
		if primitives[key] then
			return "primitive", key
		end
		local place = string.match(key, "^place:(.+)$")
		if place then
			return "place", place
		end
		local id = string.match(key, "^lib:(.+)$")
		if id then
			return "lib", id
		end
		return "place", key
	end

	local function brushLabel(key: string): string
		local kind, name = brushKind(key)
		if kind == "lib" then
			local e = library:find(name)
			return if e then e.name else name
		end
		return name
	end

	-- Shape the visibility rules care about: a primitive name, or "Grid" for any mesh brush.
	local function currentShape(): string
		local kind, name = brushKind(S.brush)
		return if kind == "primitive" then name else "Grid"
	end

	local function describe(label: string, m: Mask): string
		if m.kind ~= "Grid" then
			return "Brush: " .. label
		end
		return string.format("Brush: %s (%d×%d×%d, %d%% solid)", label, m.nx, m.ny, m.nz, math.round(m.filled * 100))
	end

	-- Make `m` the active brush once its ghost is ready, unless another brush was picked meanwhile.
	local function useMask(m: Mask, label: string, token: number)
		task.spawn(function()
			local ok, err = pcall(preview.prepare, preview, m)
			if token ~= buildToken then
				return
			end
			if not ok then
				warn("[Better Terrain Brush] Couldn't build the preview for " .. label .. ": " .. tostring(err))
			end
			pcall(preview.setBrush, preview, m)
			mask = m
			setStatus(describe(label, m))
			updateVisibility()
		end)
	end

	-- Select S.brush and build (or reuse) its mask.
	-- Perf: CPU High once per new place brush (voxelization, yields) else Low | Memory Low
	local function loadBrush(force: boolean?)
		buildToken += 1
		local token = buildToken
		local kind, name = brushKind(S.brush)
		local function fallBack(why: string)
			setStatus(why)
			S.brush = "Sphere"
			save()
			refreshBrushList()
			useMask(primitives.Sphere, "Sphere", token)
		end
		if kind == "primitive" then
			useMask(primitives[name], name, token)
		elseif kind == "lib" then
			local e = library:find(name)
			if not e then
				fallBack("That library brush is gone.")
				return
			end
			mask = nil
			setStatus("Loading " .. e.name .. "…")
			task.spawn(function()
				local ok, result = pcall(library.mask, library, name)
				if token ~= buildToken then
					return
				end
				if ok then
					useMask(result, e.name, token)
				else
					fallBack("Couldn't load " .. e.name .. ": " .. tostring(result))
				end
			end)
		else
			local source = brushSource(name)
			if not source then
				fallBack("Brush " .. name .. " is no longer in ServerStorage." .. FOLDER_NAME .. ".")
				return
			end
			if force then
				placeMasks[source] = nil
			end
			local cached = placeMasks[source]
			if cached then
				useMask(cached, name, token)
				return
			end
			mask = nil
			setStatus("Building " .. name .. "…")
			task.spawn(function()
				local ok, result = pcall(Voxelizer.fromInstance, source, S.detail, function(t: number)
					if token == buildToken then
						setStatus(string.format("Building %s… %d%%", name, math.floor(t * 100)))
					end
				end)
				if token ~= buildToken then
					return
				end
				if ok then
					placeMasks[source] = result
					useMask(result, name, token)
				else
					setStatus("Couldn't build " .. name .. ": " .. tostring(result))
					warn("[Better Terrain Brush] " .. tostring(result))
				end
			end)
		end
	end

	local function selectBrush(key: string)
		S.brush = key
		save()
		refreshBrushList()
		loadBrush()
	end

	-- Copy selected Models/BaseParts into ServerStorage.TerrainBrushes.
	-- Perf: CPU Low | Memory Low (one clone per selected object)
	local function addSelected()
		local picked = {}
		for _, inst in Selection:Get() do
			if inst:IsA("Model") or inst:IsA("BasePart") then
				table.insert(picked, inst)
			end
		end
		if #picked == 0 then
			setStatus("Select a Model or MeshPart first.")
			return
		end
		local rec = ChangeHistoryService:TryBeginRecording("TerrainBrushesAdd", "Add terrain brush")
		local folder = brushFolder()
		if not folder then
			local f = Instance.new("Folder")
			f.Name = FOLDER_NAME
			f.Parent = ServerStorage
			folder = f
		end
		local lastName: string? = nil
		for _, inst in picked do
			local archivable = inst.Archivable
			inst.Archivable = true
			local copy = inst:Clone()
			inst.Archivable = archivable
			if copy then
				local base, n = inst.Name, 1
				local name = base
				while (folder :: Folder):FindFirstChild(name) do
					n += 1
					name = base .. " " .. n
				end
				copy.Name = name
				copy.Parent = folder
				lastName = name
			end
		end
		if rec then
			ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
		end
		if lastName then
			selectBrush("place:" .. lastName)
		end
	end

	-- Upload a mesh file (.obj / .stl) straight into the library.
	-- Perf: CPU Medium-High while it runs (parse + triangle voxelization, yields) | Memory Medium (the file's vertices)
	local uploading = false
	local function uploadMesh()
		if uploading then
			return
		end
		uploading = true
		task.spawn(function()
			local ok, err = pcall(function()
				local file: any
				if h.promptFile then
					file = h.promptFile()
				else
					file = StudioService:PromptImportFileAsync(MeshImport.Extensions)
				end
				if not file then
					setStatus("Upload cancelled.")
					return
				end
				local fileName = tostring(file.Name)
				setStatus("Reading " .. fileName .. "…")
				local mesh = MeshImport.parse(fileName, file:GetBinaryContents(), S.uploadZUp)
				setStatus(string.format("Voxelizing %s (%d triangles)…", fileName, #mesh.tris // 3))
				local m = Voxelizer.fromTriangles(mesh.verts, mesh.tris, S.detail, function(t: number)
					setStatus(string.format("Voxelizing %s… %d%%", fileName, math.floor(t * 100)))
				end)
				local entry = library:add(MeshImport.baseName(fileName), m)
				selectBrush("lib:" .. entry.id)
			end)
			uploading = false
			if not ok then
				setStatus("Upload failed: " .. tostring(err))
				warn("[Better Terrain Brush] Upload failed: " .. tostring(err))
			end
		end)
	end

	local function saveToLibrary()
		local kind, name = brushKind(S.brush)
		local m = mask
		if kind ~= "place" or not m or m.kind ~= "Grid" then
			setStatus("Pick a brush from this place first (and wait for it to build).")
			return
		end
		local ok, result = pcall(library.add, library, name, m)
		if ok then
			setStatus("Saved " .. result.name .. " to the library: it's in every place now.")
			refreshBrushList()
		else
			setStatus("Couldn't save: " .. tostring(result))
		end
	end

	local function deleteBrush()
		local kind, name = brushKind(S.brush)
		if kind == "lib" then
			local e = library:find(name)
			library:remove(name)
			setStatus("Deleted " .. (if e then e.name else name) .. " from the library.")
		elseif kind == "place" then
			local source = brushSource(name)
			if source then
				local rec = ChangeHistoryService:TryBeginRecording("TerrainBrushesDelete", "Delete terrain brush")
				source.Parent = nil
				if rec then
					ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
				end
				placeMasks[source] = nil
				setStatus("Deleted " .. name .. " (Ctrl+Z brings it back).")
			end
		else
			return
		end
		selectBrush("Sphere")
	end

	-- Placement -------------------------------------------------------------------------------------
	-- Per-axis scale from unit mask size to studs.
	local function brushScale(m: Mask): Vector3
		local scaling = Shapes.Scaling[m.kind]
		if scaling == "uniform" then
			return Vector3.one * S.size
		elseif scaling == "height" then
			return Vector3.new(S.size, S.height, S.size)
		elseif scaling == "length" then
			return Vector3.new(S.size, S.size, S.height)
		end
		local k = S.size / math.max(m.size.X, m.size.Y, m.size.Z)
		return Vector3.new(k, if S.keepProportions then k else S.height / m.size.Y, k)
	end

	-- The brush's own rotation (rotation tool / sliders), applied in its local frame.
	local function userRotation(): CFrame
		return CFrame.fromEulerAnglesXYZ(math.rad(S.rotX), math.rad(S.rotY), math.rad(S.rotZ))
	end

	-- Snap a brush centre so its faces land where terrain draws full voxels' faces: on voxel centres
	-- (4k + 2), e.g. flat ground made of whole voxels. Even voxel spans centre on 4k + 2, odd on 4k.
	local function snapCentre(centre: Vector3, rot: CFrame, size: Vector3): Vector3
		local half = size / 2
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rot:GetComponents()
		local ext = {
			math.abs(r00) * half.X + math.abs(r01) * half.Y + math.abs(r02) * half.Z,
			math.abs(r10) * half.X + math.abs(r11) * half.Y + math.abs(r12) * half.Z,
			math.abs(r20) * half.X + math.abs(r21) * half.Y + math.abs(r22) * half.Z,
		}
		local c = { centre.X, centre.Y, centre.Z }
		for i = 1, 3 do
			local span = math.max(1, math.round(ext[i] * 2 / RES))
			local offset = if span % 2 == 0 then RES / 2 else 0
			c[i] = math.round((c[i] - offset) / RES) * RES + offset
		end
		return Vector3.new(c[1], c[2], c[3])
	end

	-- Brush CFrame at a surface point. `tangent` is the direction of travel (stroke or path). With
	-- Auto-rotate off the brush keeps world up and a fixed facing, so only its own rotation applies.
	-- Perf: CPU Low | Memory Low
	local function brushCFrame(m: Mask, scale: Vector3, pos: Vector3, normal: Vector3, tangent: Vector3?, yaw: number): CFrame
		local auto = S.autoRotate
		local up = if auto and S.tiltToSurface then normal.Unit else Vector3.yAxis
		local fwd = if auto and S.facePath and tangent and tangent.Magnitude > 1e-4 then tangent else -Vector3.zAxis
		fwd -= up * fwd:Dot(up)
		if fwd.Magnitude < 1e-3 then
			fwd = Vector3.xAxis - up * up.X
		end
		fwd = fwd.Unit
		local right = fwd:Cross(up).Unit
		local turn = CFrame.Angles(0, math.rad(yaw), 0) * userRotation()
		local rot = CFrame.fromMatrix(Vector3.zero, right, up) * turn
		local sculpt = S.tool == "Sculpt"
		local pivot = if sculpt then 0 else (PIVOTS[S.pivot] or 0)
		local size = m.size * scale
		-- Half the rotated brush's extent along `up`, so Pivot Bottom / Top rest the turned shape on the surface.
		local _, _, _, _, _, _, u10, u11, u12 = turn:GetComponents()
		local halfUp = (math.abs(u10) * size.X + math.abs(u11) * size.Y + math.abs(u12) * size.Z) / 2
		local centre = pos + up * (pivot * halfUp + S.nudge)
		if S.snap and not sculpt then
			centre = snapCentre(centre, rot, size)
		end
		return rot + centre
	end

	local function keyDown(key: Enum.KeyCode): boolean
		if h.keyDown then
			return h.keyDown(key)
		end
		return UserInputService:IsKeyDown(key)
	end
	local function shiftDown(): boolean
		return keyDown(Enum.KeyCode.LeftShift) or keyDown(Enum.KeyCode.RightShift)
	end
	local function ctrlDown(): boolean
		return keyDown(Enum.KeyCode.LeftControl) or keyDown(Enum.KeyCode.RightControl)
	end
	local function altDown(): boolean
		return keyDown(Enum.KeyCode.LeftAlt) or keyDown(Enum.KeyCode.RightAlt)
	end

	-- The operation a stamp does right now, with the built-in modifiers: Ctrl flips Draw / Sculpt to
	-- subtract / erode (and back), Shift turns Draw / Sculpt into Smooth while held.
	local function currentOp(): string
		local tool = S.tool
		if tool == "Draw" or tool == "Sculpt" then
			if shiftDown() then
				return "Smooth"
			end
			local flip = ctrlDown()
			if tool == "Draw" then
				return if (S.drawMode == "Subtract") ~= flip then "Subtract" else "Add"
			end
			return if (S.sculptMode == "Erode") ~= flip then "Erode" else "Grow"
		elseif tool == "Smooth" then
			return "Smooth"
		elseif tool == "Flatten" then
			return "Flatten"
		end
		return if S.paintMode == "Replace" then "Replace" else "Paint"
	end

	local function randomYaw(): number
		return if S.randomRotation then math.random() * 360 else 0
	end

	local function stampAt(m: Mask, cf: CFrame, scale: Vector3, op: string, planeY: number, changed: { [number]: number }?)
		local ok, err = pcall(Stamp.apply, terrain, m, cf, scale, {
			op = op,
			material = S.material,
			source = S.source,
			strength = S.strength,
			autoMaterial = S.autoMaterial,
			replaceMaterial = S.replaceMaterial and op == "Add",
			ignoreWater = S.ignoreWater,
			flattenMode = S.flattenMode,
			planeY = planeY,
			thicken = S.thicken,
			changed = changed,
		})
		if not ok then
			warn("[Better Terrain Brush] Stamp failed: " .. tostring(err))
		end
	end

	-- Tool state ------------------------------------------------------------------------------------
	local mouse: any = h.mouse or plugin:GetMouse()
	local active = false
	local recording: string? = nil
	local rayParams = RaycastParams.new()
	rayParams.IgnoreWater = true
	local lastHitY = 0
	local pickingPlane = false

	local function manualPlane(): Plane?
		local p = S.manualPlane
		if type(p) == "table" and #p == 6 then
			return { point = Vector3.new(p[1], p[2], p[3]), normal = Vector3.new(p[4], p[5], p[6]).Unit }
		end
		return nil
	end

	-- Surface under the cursor (or on `plane`); off the terrain it falls back to a flat plane at the
	-- last hit height so you can draw into empty space.
	-- Perf: CPU Low (one raycast per frame while active) | Memory Low
	local function cursorHit(plane: Plane?): Hit?
		local ray = mouse.UnitRay
		if plane then
			local denom = ray.Direction:Dot(plane.normal)
			if math.abs(denom) < 1e-4 then
				return nil
			end
			local t = (plane.point - ray.Origin):Dot(plane.normal) / denom
			if t <= 0 or t > 20000 then
				return nil
			end
			return { pos = ray.Origin + ray.Direction * t, normal = plane.normal }
		end
		if S.ignoreParts then
			rayParams.FilterType = Enum.RaycastFilterType.Include
			rayParams.FilterDescendantsInstances = { terrain }
		else
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { preview.folder }
		end
		rayParams.IgnoreWater = S.ignoreWater
		local result = workspace:Raycast(ray.Origin, ray.Direction * 10000, rayParams)
		if result then
			lastHitY = result.Position.Y
			return { pos = result.Position, normal = result.Normal }
		end
		if math.abs(ray.Direction.Y) > 1e-4 then
			local t = (lastHitY - ray.Origin.Y) / ray.Direction.Y
			if t > 0 and t < 10000 then
				return { pos = ray.Origin + ray.Direction * t, normal = Vector3.yAxis }
			end
		end
		return nil
	end

	-- Auto plane lock: the plane through the stroke's start, facing the camera in 45° steps of tilt and
	-- of turn: seen from above it is flat, from in between tilted 45°, from in front upright (and the
	-- same for the sides and diagonals).
	local function autoPlane(hit: Hit): Plane
		local toCamera = mouse.UnitRay.Origin - hit.pos
		if toCamera.Magnitude < 1e-3 then
			return { point = hit.pos, normal = Vector3.yAxis }
		end
		toCamera = toCamera.Unit
		local tilt = math.round(math.asin(math.clamp(toCamera.Y, -1, 1)) / PLANE_STEP) * PLANE_STEP
		local turn = math.round(math.atan2(toCamera.Z, toCamera.X) / PLANE_STEP) * PLANE_STEP
		local level = math.cos(tilt)
		return { point = hit.pos, normal = Vector3.new(level * math.cos(turn), math.sin(tilt), level * math.sin(turn)) }
	end

	-- The plane "Set plane" picks at a cursor hit.
	local function pickedPlane(hit: Hit): Plane
		return { point = hit.pos, normal = if S.planeNormal == "Surface" then hit.normal else Vector3.yAxis }
	end

	-- Frame the plane's grid is drawn in: Y is the normal, X runs level along the plane (world X on flat
	-- planes) and the origin is the world origin projected onto the plane, so grid lines stay put on it
	-- (on voxel boundaries for flat planes and upright ones facing an axis).
	local function gridFrame(plane: Plane): CFrame
		local normal = plane.normal
		local right = Vector3.yAxis:Cross(normal)
		if right.Magnitude < 1e-3 then
			right = Vector3.xAxis
		end
		return CFrame.fromMatrix(normal * normal:Dot(plane.point), right.Unit, normal)
	end

	local function beginRecording()
		if not recording then
			recording = ChangeHistoryService:TryBeginRecording("TerrainBrushStroke", "Terrain brush stroke")
		end
	end

	local function finishRecording()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			recording = nil
		end
	end

	-- Stroke state. `changed` maps voxel keys to their occupancy before the stroke touched them;
	-- `surface` is the last cursor hit on terrain the stroke hadn't changed. Strokes dragged along a
	-- placed path have `pathIndex`, the last path stamp drawn.
	local stroke: {
		last: Vector3?,
		lastTime: number,
		plane: Plane?,
		planeY: number?,
		changed: { [number]: number },
		surface: Plane?,
		pathIndex: number?,
	}? = nil
	local pathHover: number? = nil -- path stamp under the cursor (keeps the pick steady where turns overlap)
	-- Path job state: stamps waiting to be applied
	local job: { stamps: { PathStamp }, i: number, op: string, planeY: number? }? = nil
	local pathCache: { key: string, stamps: { PathStamp }, loop: boolean }? = nil
	-- "Drag along the path": where the placed path is centred (nil until the first click places it).
	local pathAnchor: Vector3? = nil
	-- B held: dragging left/right changes size (Ctrl: height, Shift: strength)
	local adjust: { key: string, startX: number, start: number, hit: Hit }? = nil
	-- Rotation tool: the ghost stays at `hit` with arc handles to turn it. While a ring is being dragged,
	-- `start` is the rotation it started from and `centre` holds the brush still.
	local rotating: { hit: Hit, start: CFrame?, centre: Vector3? }? = nil
	local hoveredRings: { [Enum.Axis]: boolean } = {}
	local lastHit: Hit? = nil -- where the ghost was last shown under the cursor
	local controls: { [string]: Ui.Control } = {}

	-- Is the cursor hit on terrain this stroke added (just inside the surface) or next to terrain it
	-- removed (just outside)?
	local function ownTerrain(changed: { [number]: number }, hit: Hit): boolean
		if next(changed) == nil then
			return false
		end
		for _, k in { 1, 3 } do
			local inside = changed[Stamp.voxelKey(hit.pos - hit.normal * k)]
			if inside ~= nil and inside < 0.5 then
				return true
			end
			local outside = changed[Stamp.voxelKey(hit.pos + hit.normal * k)]
			if outside ~= nil and outside >= 0.5 then
				return true
			end
		end
		return false
	end

	local function activePlane(): Plane?
		if stroke and stroke.plane then
			return stroke.plane
		end
		if S.planeLock == "Manual" then
			return manualPlane()
		end
		return nil
	end

	-- Studs between stamps: Spacing × the brush's footprint.
	local function stampSpacing(m: Mask): number
		local size = m.size * brushScale(m)
		return math.max(1, math.max(size.X, size.Z) * S.spacing)
	end

	-- Follow the ground only ever looks at terrain, so parts (and the ghost) under a path don't bend it.
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	groundParams.FilterDescendantsInstances = { terrain }

	-- World-space stamps of the current path centred at `centre`, and whether it is a closed loop. By
	-- default the path is exactly its shape: flat at the centre's height, plus Rise. Nothing under it
	-- moves it unless Follow the ground is on.
	-- Perf: CPU Low (recomputed only when the cursor or a path setting changes; one raycast per point with Follow the ground) | Memory Low
	local function pathStamps(centre: Vector3, m: Mask): ({ PathStamp }, boolean)
		local size = m.size * brushScale(m)
		local spacing = stampSpacing(m)
		local key = string.format("%.1f,%.1f,%.1f|%s|%g|%g|%g|%g|%g|%g|%g|%s|%s|%s", centre.X, centre.Y, centre.Z, S.shape, S.radius,
			S.innerRadius, S.turns, S.sides, S.rise, S.angle, spacing, tostring(S.clockwise), tostring(S.followGround),
			tostring(S.ignoreWater))
		if pathCache and pathCache.key == key then
			return pathCache.stamps, pathCache.loop
		end
		local points, loop = Paths.generate({
			shape = S.shape,
			radius = S.radius,
			innerRadius = S.innerRadius,
			turns = S.turns,
			sides = S.sides,
			rise = S.rise,
			angle = S.angle,
			clockwise = S.clockwise,
		}, spacing)
		local stamps: { PathStamp } = {}
		local reach = math.max(200, S.radius + math.abs(S.rise) + math.max(size.X, size.Y, size.Z))
		for _, p in points do
			local base = centre + Vector3.new(p.u, 0, p.v)
			local pos, normal = base + Vector3.new(0, p.h, 0), Vector3.yAxis
			if S.followGround then
				groundParams.IgnoreWater = S.ignoreWater
				local r = workspace:Raycast(base + Vector3.new(0, reach, 0), Vector3.new(0, -2 * reach, 0), groundParams)
				if r then
					pos, normal = r.Position + Vector3.new(0, p.h, 0), r.Normal
				end
			end
			table.insert(stamps, { pos = pos, normal = normal, tangent = Vector3.new(p.tu, 0, p.tv) })
		end
		pathCache = { key = key, stamps = stamps, loop = loop }
		return stamps, loop
	end

	-- Steps between two stamps along the path (the short way round a closed loop).
	local function pathGap(a: number, b: number, n: number, loop: boolean): number
		local d = math.abs(a - b)
		return if loop then math.min(d, n - d) else d
	end

	-- Index of the path stamp nearest the mouse ray. Where turns overlap on screen (spirals, helixes),
	-- points about as near as the best one go to the one closest in path order to `prefer`.
	-- Perf: CPU Low (one pass over the path's stamps) | Memory Low
	local function nearestStamp(stamps: { PathStamp }, loop: boolean, ray: Ray, prefer: number?, spacing: number): number?
		local origin, dir = ray.Origin, ray.Direction.Unit
		local dists = table.create(#stamps)
		local best = math.huge
		for i, s in stamps do
			local v = s.pos - origin
			local along = v:Dot(dir)
			local d = if along > 0 then (v - dir * along).Magnitude else math.huge
			dists[i] = d
			best = math.min(best, d)
		end
		if best == math.huge then
			return nil
		end
		local pick, pickGap = nil, math.huge
		for i, d in dists do
			if d <= best + spacing * 0.5 then
				local gap = if prefer then pathGap(i, prefer, #stamps, loop) else d
				if gap < pickGap then
					pick, pickGap = i, gap
				end
			end
		end
		return pick
	end

	local function planeWidth(m: Mask, scale: Vector3): number
		local size = m.size * scale
		return math.max(size.X, size.Z, 8) * 1.6
	end

	local ADJUST_RANGES = { size = { 1, 800 }, height = { 1, 800 }, strength = { 0.05, 1 } }

	-- Per-frame update while the tool is active: preview, freehand stamping, path jobs.
	-- Perf: CPU Low idle (one raycast + ghost move); Medium-High while stamping (see Stamp.apply) | Memory Low
	local function step()
		local m = mask
		if not active or not m then
			preview:hide()
			return
		end
		local op = currentOp()
		preview:setColor(OP_COLORS[op])

		-- Rotation tool: ghost and rings stay put; the rings do the work (see the handle events).
		if rotating then
			local r = rotating
			local scale = brushScale(m)
			local cf = brushCFrame(m, scale, r.hit.pos, r.hit.normal, nil, 0)
			if r.centre then
				cf = cf.Rotation + r.centre
			end
			preview:setGhost(cf, scale)
			preview:setHandles(cf, m.size * scale)
			preview:setPath(nil, 1)
			preview:setPlane(nil, 0)
			preview:setGrid(nil, Vector3.zero, 0)
			return
		end
		preview:setHandles(nil)

		-- B + drag: resize in place.
		if adjust then
			local a = adjust
			local dx = mouse.X - a.startX
			local range = ADJUST_RANGES[a.key]
			local v
			if a.key == "strength" then
				v = math.round((a.start + dx * 0.004) * 100) / 100
			else
				v = math.round(a.start * 1.01 ^ dx)
			end
			v = math.clamp(v, range[1], range[2])
			if v ~= S[a.key] then
				S[a.key] = v
				local c = controls[a.key]
				if c then
					c.set(v)
				end
				pathCache = nil
			end
			setStatus(string.format("%s: %s", a.key:sub(1, 1):upper() .. a.key:sub(2), tostring(v)))
			local scale = brushScale(m)
			preview:setGhost(brushCFrame(m, scale, a.hit.pos, a.hit.normal, nil, 0), scale)
			return
		end

		local scale = brushScale(m)

		-- Path being applied: a few stamps per frame so Studio stays responsive.
		if job then
			local j = job
			for _ = 1, S.speed do
				local s = j.stamps[j.i]
				if not s then
					break
				end
				stampAt(m, brushCFrame(m, scale, s.pos, s.normal, s.tangent, randomYaw()), scale, j.op, j.planeY or s.pos.Y)
				j.i += 1
			end
			local s = j.stamps[math.min(j.i, #j.stamps)]
			if s then
				preview:setGhost(brushCFrame(m, scale, s.pos, s.normal, s.tangent, 0), scale)
			end
			setStatus(string.format("Applying path… %d / %d", j.i - 1, #j.stamps))
			if j.i > #j.stamps then
				job = nil
				finishRecording()
				setStatus("Path applied (Ctrl+Z to undo).")
			end
			return
		end

		-- Picking a plane aims at the terrain, where the click picks it, not at the current plane.
		local plane = if pickingPlane then nil else activePlane()
		local hit = cursorHit(plane)
		if not hit then
			preview:hide()
			return
		end
		-- Draw strokes stay on the terrain as it was before the stroke, so a slow drag doesn't stack its
		-- own stamps into a tower (Add) or dig itself down (Subtract).
		local cur = stroke
		if cur and not plane and (op == "Add" or op == "Subtract") then
			if cur.surface and ownTerrain(cur.changed, hit) then
				hit = cursorHit(cur.surface) or hit
			else
				cur.surface = { point = hit.pos, normal = hit.normal }
			end
		end
		lastHit = hit

		if S.tool == "Flatten" then
			local y = if stroke and stroke.planeY then stroke.planeY else hit.pos.Y
			preview:setPlane(CFrame.new(hit.pos.X, y, hit.pos.Z), planeWidth(m, scale), OP_COLORS.Flatten)
		else
			preview:setPlane(nil, 0)
		end
		-- Plane lock grid: the plane in use, else the one a click here would lock (a freehand stroke
		-- under Auto, or Set plane). It turns more opaque once a stroke is painting.
		local lock = plane
		if pickingPlane then
			lock = pickedPlane(hit)
		elseif not lock and S.planeLock == "Auto" and S.shape == "Freehand" then
			lock = autoPlane(hit)
		end
		if lock then
			preview:setGrid(gridFrame(lock), hit.pos, planeWidth(m, scale), stroke ~= nil)
		else
			preview:setGrid(nil, Vector3.zero, 0)
		end

		if S.shape ~= "Freehand" then
			-- The path follows the cursor until it's placed (drag mode) or for the whole-path click.
			local placed = if S.wholePath then nil else pathAnchor
			local stamps, loop = pathStamps(placed or hit.pos, m)
			local pts = table.create(#stamps)
			for i, s in stamps do
				pts[i] = s.pos
			end
			preview:setPath(pts, math.clamp(math.max(scale.X * m.size.X, scale.Z * m.size.Z) * 0.06, 0.4, 4))
			if not placed then
				pathHover = nil
				local first = stamps[1]
				if first then
					preview:setGhost(brushCFrame(m, scale, first.pos, first.normal, first.tangent, 0), scale)
				else
					preview:setGhost(nil, scale)
				end
				return
			end

			-- Drag along the placed path: the brush sits on the path stamp nearest the cursor, and a drag
			-- walks the path from stamp to stamp towards it (a few per frame, so nothing is skipped).
			local st = stroke
			local n = #stamps
			local index = if st and st.pathIndex then st.pathIndex else pathHover
			local target = nearestStamp(stamps, loop, mouse.UnitRay, index, stampSpacing(m))
			if not target then
				preview:setGhost(nil, scale)
				return
			end
			if not st or not st.pathIndex then
				pathHover = target
				local s = stamps[target]
				preview:setGhost(brushCFrame(m, scale, s.pos, s.normal, s.tangent, 0), scale)
				if S.tool == "Flatten" then
					preview:setPlane(CFrame.new(s.pos), planeWidth(m, scale), OP_COLORS.Flatten)
				end
				return
			end
			local at = st.pathIndex :: number
			local now = os.clock()
			if target ~= at then
				local dir = if target > at then 1 else -1
				local steps = math.abs(target - at)
				if loop and n - steps < steps then -- the short way round wraps past the start
					dir, steps = -dir, n - steps
				end
				for _ = 1, math.min(steps, math.max(S.speed, 4)) do
					at = (at - 1 + dir) % n + 1
					local s = stamps[at]
					stampAt(m, brushCFrame(m, scale, s.pos, s.normal, s.tangent, randomYaw()), scale, op, st.planeY or s.pos.Y, st.changed)
				end
				st.pathIndex, st.lastTime = at, now
			elseif CONTINUOUS[op] and now - st.lastTime > REPEAT then
				local s = stamps[at]
				stampAt(m, brushCFrame(m, scale, s.pos, s.normal, s.tangent, randomYaw()), scale, op, st.planeY or s.pos.Y, st.changed)
				st.lastTime = now
			end
			pathHover = at
			local s = stamps[at]
			preview:setGhost(brushCFrame(m, scale, s.pos, s.normal, s.tangent, 0), scale)
			if S.tool == "Flatten" then
				preview:setPlane(CFrame.new(s.pos.X, st.planeY or s.pos.Y, s.pos.Z), planeWidth(m, scale), OP_COLORS.Flatten)
			end
			return
		end

		preview:setPath(nil, 1)
		local st = stroke
		local tangent = if st and st.last then hit.pos - st.last else nil
		preview:setGhost(brushCFrame(m, scale, hit.pos, hit.normal, tangent, 0), scale)
		if not st then
			return
		end
		local spacing = math.max(1, math.max(m.size.X * scale.X, m.size.Z * scale.Z) * S.spacing)
		local now = os.clock()
		local function planeYAt(pos: Vector3): number
			return if st.planeY then st.planeY else pos.Y
		end
		if not st.last then
			stampAt(m, brushCFrame(m, scale, hit.pos, hit.normal, nil, randomYaw()), scale, op, planeYAt(hit.pos), st.changed)
			st.last, st.lastTime = hit.pos, now
			return
		end
		local from = st.last :: Vector3
		local delta = hit.pos - from
		local dist = delta.Magnitude
		if dist >= spacing then
			-- Fill the gap with evenly spaced stamps (capped so a fast flick can't stall Studio).
			local dir = delta / dist
			local n = math.min(math.floor(dist / spacing), MAX_FILL)
			for k = 1, n do
				local pos = if k == n then hit.pos else from + dir * spacing * k
				stampAt(m, brushCFrame(m, scale, pos, hit.normal, dir, randomYaw()), scale, op, planeYAt(pos), st.changed)
			end
			st.last, st.lastTime = hit.pos, now
		elseif CONTINUOUS[op] and now - st.lastTime > REPEAT then
			-- Holding still keeps working, like the built-in tools.
			stampAt(m, brushCFrame(m, scale, from, hit.normal, nil, randomYaw()), scale, op, planeYAt(from), st.changed)
			st.lastTime = now
		end
	end

	-- Mouse ----------------------------------------------------------------------------------------
	local pickerControl: Ui.Picker? = nil
	local slots = Materials.list(terrain)
	local setRotating: (boolean) -> () = function() end

	local function onButton1Down()
		if not active or not mask or job or adjust then
			return
		end
		if rotating then
			-- Clicking off the rings finishes rotating (and doesn't paint).
			if not next(hoveredRings) and not rotating.start then
				setRotating(false)
			end
			return
		end
		local m = mask :: Mask
		if pickingPlane then
			local hit = cursorHit(nil)
			if hit then
				local n = pickedPlane(hit).normal
				S.manualPlane = { hit.pos.X, hit.pos.Y, hit.pos.Z, n.X, n.Y, n.Z }
				save()
				local c = controls.planeHeight
				if c then
					c.set(math.round(hit.pos.Y * 10) / 10)
				end
				setStatus(string.format("Plane set at height %.1f.", hit.pos.Y))
			end
			pickingPlane = false
			return
		end
		if altDown() then
			-- Eyedropper: pick up the material under the cursor.
			local hit = cursorHit(nil)
			local slot = hit and Stamp.materialAt(terrain, hit.pos, hit.normal)
			if slot then
				S.material = slot
				save()
				if pickerControl then
					pickerControl.set(slot)
				end
				local info = Materials.find(slots, slot)
				setStatus("Picked " .. (if info then info.name else "slot " .. slot) .. ".")
			end
			return
		end
		local hit = cursorHit(activePlane())
		if not hit then
			return
		end
		local planeY = if S.fixedPlane and S.tool == "Flatten" then hit.pos.Y else nil
		if S.shape == "Freehand" then
			beginRecording()
			stroke = {
				last = nil,
				lastTime = 0,
				plane = if S.planeLock == "Auto" then autoPlane(hit) else nil,
				planeY = planeY,
				changed = {},
				surface = nil,
			}
		elseif S.wholePath then
			local stamps = pathStamps(hit.pos, m)
			if #stamps == 0 then
				return
			end
			beginRecording()
			job = { stamps = table.clone(stamps), i = 1, op = currentOp(), planeY = planeY }
		elseif not pathAnchor then
			-- First click places the path; drags after that draw along it.
			pathAnchor = hit.pos
			pathHover = nil
			setStatus("Path placed: drag along it to draw as much as you want. \"Place path again\" moves it.")
		else
			local stamps, loop = pathStamps(pathAnchor, m)
			local index = nearestStamp(stamps, loop, mouse.UnitRay, pathHover, stampSpacing(m))
			if not index then
				return
			end
			local s = stamps[index]
			local scale = brushScale(m)
			local op = currentOp()
			local fixedY = if S.fixedPlane and S.tool == "Flatten" then s.pos.Y else nil
			local changed = {}
			beginRecording()
			stroke = {
				last = nil,
				lastTime = os.clock(),
				plane = nil,
				planeY = fixedY,
				changed = changed,
				surface = nil,
				pathIndex = index,
			}
			stampAt(m, brushCFrame(m, scale, s.pos, s.normal, s.tangent, randomYaw()), scale, op, fixedY or s.pos.Y, changed)
		end
	end

	local function onButton1Up()
		if stroke then
			stroke = nil
			finishRecording()
		end
	end

	local mouseConns: { RBXScriptConnection } = {
		mouse.Button1Down:Connect(onButton1Down),
		mouse.Button1Up:Connect(onButton1Up),
	}

	-- UI --------------------------------------------------------------------------------------------
	local toolbar = plugin:CreateToolbar(PLUGIN_NAME)
	local toolButton = toolbar:CreateButton(PLUGIN_ID, "Terrain brushes with custom mesh shapes, rotation and paths", PLUGIN_ICON, "Terrain Brush")
	toolButton.ClickableWhenViewportHidden = true

	local container: Instance
	local widget: DockWidgetPluginGui? = nil
	local mousePosition: () -> Vector2
	if h.container then
		container = h.container
		mousePosition = h.mousePosition or function()
			return UserInputService:GetMouseLocation()
		end
	else
		local w = plugin:CreateDockWidgetPluginGuiAsync(
			PLUGIN_ID,
			DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 330, 680, 270, 300)
		)
		w.Title = PLUGIN_NAME
		w.Name = PLUGIN_ID
		widget = w
		container = w
		mousePosition = function()
			return w:GetRelativeMousePosition()
		end
	end

	local ui = Ui.new(container, mousePosition)
	local activeButton: TextButton? = nil
	local visRules: { { frame: GuiObject, show: () -> boolean } } = {}
	local function showWhen(frame: GuiObject, show: () -> boolean)
		table.insert(visRules, { frame = frame, show = show })
	end
	updateVisibility = function()
		for _, r in visRules do
			r.frame.Visible = r.show()
		end
	end

	local function setActive(on: boolean)
		if on == active then
			return
		end
		active = on
		if on then
			plugin:Activate(true)
		else
			stroke = nil
			adjust = nil
			pickingPlane = false
			setRotating(false)
			if job then
				job = nil
				setStatus("Path stopped part-way.")
			end
			finishRecording()
			preview:hide()
			if plugin:IsActivated() then
				plugin:Deactivate()
			end
		end
		toolButton:SetActive(on)
		if activeButton then
			activeButton.Text = if on then "Stop (or click any Studio tool)" else "Start painting"
		end
	end

	-- Rotation tool -------------------------------------------------------------------------------------
	local rotateButton: TextButton? = nil

	-- Store a brush rotation (from the rings or Reset) and show it on the sliders.
	local function setRotation(cf: CFrame)
		local rx, ry, rz = cf:ToEulerAnglesXYZ()
		S.rotX = math.round(math.deg(rx) * 100) / 100
		S.rotY = math.round(math.deg(ry) * 100) / 100
		S.rotZ = math.round(math.deg(rz) * 100) / 100
		for _, key in { "rotX", "rotY", "rotZ" } do
			local c = controls[key]
			if c then
				c.set(S[key])
			end
		end
	end

	-- Enter / leave the rotation tool. The ghost freezes where it was last shown, with rings around it.
	setRotating = function(on: boolean)
		if on then
			setActive(true)
			local hit = lastHit
			if not mask or not hit then
				setStatus("Point the brush at the terrain first, then press R (or the button).")
				return
			end
			stroke = nil
			finishRecording()
			rotating = { hit = hit, start = nil, centre = nil }
			table.clear(hoveredRings)
			setStatus("Drag the rings to turn the brush. Press R or Enter, or click off the rings, when done.")
		elseif rotating then
			rotating = nil
			table.clear(hoveredRings)
			preview:setHandles(nil)
			save()
			if mask then
				setStatus(describe(brushLabel(S.brush), mask))
			end
		end
		if rotateButton then
			rotateButton.Text = if rotating then "Done rotating (R)" else "Rotate with handles (R)"
		end
	end

	local function isTool(...: string): () -> boolean
		local list = { ... }
		return function()
			return table.find(list, S.tool) ~= nil
		end
	end

	do
		-- Tool
		local top = ui:section(PLUGIN_NAME)
		ui:choice(top, TOOLS, S.tool, 5, function(v)
			S.tool = v
			save()
			updateVisibility()
			setActive(true)
		end)
		local modes = {
			{ "Draw", "drawMode", { "Add", "Subtract" } },
			{ "Sculpt", "sculptMode", { "Grow", "Erode" } },
			{ "Flatten", "flattenMode", { "Erode", "Both", "Grow" } },
			{ "Paint", "paintMode", { "Paint", "Replace" } },
		}
		for _, mode in modes do
			local tool, key, options = mode[1], mode[2], mode[3]
			local c = ui:choice(top, options, S[key], #options, setter(key))
			showWhen(c.frame, isTool(tool))
		end
		showWhen(ui:note(top, "Flatten: Erode lowers terrain above the plane, Grow fills below it, Both does both."), isTool("Flatten"))
		activeButton = ui:button(top, "Start painting", function()
			setActive(not active)
		end, true)
		statusLabel = ui:note(top, "")
		ui:note(top, "Ctrl: subtract / erode · Shift: smooth (Draw, Sculpt) · B + drag: size (Ctrl+B height, Shift+B strength) · Alt+click: pick up a material · Ctrl+Z undoes a whole stroke or path.")

		-- Brush list
		local brushSec = ui:section("Brush")
		local groups: { { label: TextLabel, grid: Frame } } = {}
		local function brushGroup(title: string)
			local l = ui:label(brushSec, title)
			l.TextSize = 13
			local grid = Instance.new("Frame")
			grid.BackgroundTransparency = 1
			grid.Size = UDim2.new(1, 0, 0, 0)
			grid.AutomaticSize = Enum.AutomaticSize.Y
			grid.LayoutOrder = ui:nextOrder()
			local layout = Instance.new("UIGridLayout")
			layout.CellSize = UDim2.new(1 / 3, -3, 0, 24)
			layout.CellPadding = UDim2.fromOffset(3, 3)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = grid
			grid.Parent = brushSec
			table.insert(groups, { label = l, grid = grid })
		end
		brushGroup("Built-in")
		brushGroup("This place (ServerStorage." .. FOLDER_NAME .. ")")
		brushGroup("Library (every place)")
		local brushButtons: { [string]: TextButton } = {}
		local C = Enum.StudioStyleGuideColor
		local function paintBrushes()
			for key, b in brushButtons do
				local on = key == S.brush
				b.BackgroundColor3 = Ui.color(if on then C.DialogMainButton else C.Button)
				b.TextColor3 = Ui.color(if on then C.DialogMainButtonText else C.ButtonText)
			end
		end
		ui:paint(paintBrushes)
		-- Perf: CPU Low (rebuilds a few buttons when the brush folder or library changes) | Memory Low
		refreshBrushList = function()
			for _, b in brushButtons do
				b:Destroy()
			end
			table.clear(brushButtons)
			local place = {}
			local folder = brushFolder()
			if folder then
				for _, c in folder:GetChildren() do
					if c:IsA("Model") or c:IsA("BasePart") then
						table.insert(place, c.Name)
					end
				end
				table.sort(place)
			end
			local lists: { { { key: string, text: string } } } = { {}, {}, {} }
			for _, shape in Voxelizer.Shapes do
				table.insert(lists[1], { key = shape, text = shape })
			end
			for _, name in place do
				table.insert(lists[2], { key = "place:" .. name, text = name })
			end
			for _, e in library.entries do
				table.insert(lists[3], { key = "lib:" .. e.id, text = e.name })
			end
			-- Old settings stored a bare place-brush name.
			local kind, name = brushKind(S.brush)
			if kind == "place" and not string.find(S.brush, "^place:") then
				S.brush = "place:" .. name
			end
			for g, items in lists do
				local group = groups[g]
				group.label.Visible = g == 1 or #items > 0
				for i, item in items do
					if brushButtons[item.key] then
						continue
					end
					local b = Instance.new("TextButton")
					b.Name = "Brush_" .. item.text
					b.LayoutOrder = i
					b.Font = Enum.Font.SourceSans
					b.TextSize = 13
					b.Text = item.text
					b.TextTruncate = Enum.TextTruncate.AtEnd
					b.BorderSizePixel = 0
					local corner = Instance.new("UICorner")
					corner.CornerRadius = UDim.new(0, 3)
					corner.Parent = b
					b.Parent = group.grid
					brushButtons[item.key] = b
					b.Activated:Connect(function()
						selectBrush(item.key)
					end)
				end
			end
			paintBrushes()
			updateVisibility()
		end
		ui:buttonRow(brushSec, {
			{ text = "Add selected", onClick = addSelected },
			{ text = "Upload mesh file…", onClick = uploadMesh },
		})
		ui:choiceRow(brushSec, "File up axis", { "Y up", "Z up" }, if S.uploadZUp then "Z up" else "Y up", function(v)
			S.uploadZUp = v == "Z up"
			save()
		end)
		ui:note(brushSec, "Add selected copies Models / MeshParts into ServerStorage." .. FOLDER_NAME .. " (this place only). Upload takes an .obj or .stl file into the library, which every place shares. Blender exports OBJ as Y up and STL as Z up by default.")

		local function isKind(kind: string): () -> boolean
			return function()
				return (brushKind(S.brush)) == kind
			end
		end
		local nameBox = ui:textBox(brushSec, "Name", "", function(text)
			local kind, id = brushKind(S.brush)
			if kind == "lib" then
				local name = library:rename(id, text)
				refreshBrushList()
				if name then
					controls.name.set(name)
					setStatus("Renamed to " .. name .. ".")
				end
			end
		end)
		controls.name = nameBox
		showWhen(nameBox.frame, function()
			local kind = brushKind(S.brush)
			if kind == "lib" then
				nameBox.set(brushLabel(S.brush))
				return true
			end
			return false
		end)

		-- Delete needs a second click within 3 s.
		local armed: string? = nil
		local deleteButtons: { TextButton } = {}
		local function deleteClicked()
			if armed == S.brush then
				armed = nil
				for _, b in deleteButtons do
					b.Text = "Delete brush"
				end
				deleteBrush()
				return
			end
			armed = S.brush
			for _, b in deleteButtons do
				b.Text = "Click again to delete"
			end
			local key = S.brush
			task.delay(3, function()
				if armed == key then
					armed = nil
					for _, b in deleteButtons do
						b.Text = "Delete brush"
					end
				end
			end)
		end
		local placeRow = ui:buttonRow(brushSec, {
			{ text = "Save to library", onClick = saveToLibrary },
			{ text = "Rebuild shape", onClick = function()
				loadBrush(true)
			end },
			{ text = "Delete brush", onClick = deleteClicked },
		})
		table.insert(deleteButtons, placeRow[3])
		showWhen(placeRow[1].Parent :: GuiObject, isKind("place"))
		local libRow = ui:buttonRow(brushSec, { { text = "Delete brush", onClick = deleteClicked } })
		table.insert(deleteButtons, libRow[1])
		showWhen(libRow[1].Parent :: GuiObject, isKind("lib"))

		local detail = ui:slider(brushSec, "Detail", S.detail, 16, 96, 4, function(v)
			S.detail = v
			save()
			table.clear(placeMasks)
			preview:clearCache()
			if (brushKind(S.brush)) == "place" then
				loadBrush()
			end
		end)
		showWhen(detail.frame, function()
			return (brushKind(S.brush)) ~= "primitive"
		end)
		local thicken = ui:slider(brushSec, "Thicken", S.thicken, 0, 6, 0.5, setter("thicken"))
		showWhen(thicken.frame, function()
			return currentShape() == "Grid"
		end)
		showWhen(ui:note(brushSec, "Detail is the voxel grid used to read a mesh (place brushes rebuild; uploads use it when uploaded). Terrain voxels are 4 studs, so fine mesh detail needs a big brush size. Thicken grows a mesh brush by that many studs so thin parts don't vanish (2 keeps any sheet)."), function()
			return (brushKind(S.brush)) ~= "primitive"
		end)

		-- Brush settings
		local setSec = ui:section("Brush settings")
		local function invalidatePath()
			pathCache = nil
		end
		controls.size = ui:slider(setSec, "Size", S.size, 1, 200, 1, setter("size", invalidatePath), 800)
		controls.height = ui:slider(setSec, "Height", S.height, 1, 200, 1, setter("height", invalidatePath), 800)
		showWhen(controls.height.frame, function()
			local shape = currentShape()
			local scaling = Shapes.Scaling[shape]
			local label = controls.height.label
			if label then
				-- Flat shapes (Half Circle, U, V) use it for how far they run along the brush's Z axis.
				label.Text = if scaling == "length" then "Length" else "Height"
			end
			return scaling == "height" or scaling == "length" or (shape == "Grid" and not S.keepProportions)
		end)
		-- Changing the wall rebuilds the hollow shapes once the slider settles (their ghosts are meshes).
		local thicknessToken = 0
		controls.thickness = ui:slider(setSec, "Wall thickness", S.thickness, 0.05, 0.95, 0.05, function(v)
			S.thickness = v
			save()
			thicknessToken += 1
			local token = thicknessToken
			task.delay(0.2, function()
				if token ~= thicknessToken then
					return
				end
				for shape in Shapes.Hollow do
					primitives[shape] = Voxelizer.primitive(shape, v)
				end
				preview:clearCache()
				if Shapes.Hollow[S.brush] then
					loadBrush()
				end
			end)
		end)
		showWhen(controls.thickness.frame, function()
			return Shapes.Hollow[currentShape()] == true
		end)
		local keep = ui:toggle(setSec, "Keep mesh proportions", S.keepProportions, setter("keepProportions", invalidatePath))
		showWhen(keep.frame, function()
			return currentShape() == "Grid"
		end)
		controls.strength = ui:slider(setSec, "Strength", S.strength, 0.05, 1, 0.05, setter("strength"))
		showWhen(controls.strength.frame, function()
			return S.tool == "Sculpt" or S.tool == "Smooth" or S.tool == "Flatten" or S.tool == "Draw"
		end)
		showWhen(ui:note(setSec, "In Draw, Strength only affects Shift-smoothing."), isTool("Draw"))
		local pivot = ui:choiceRow(setSec, "Pivot", { "Bottom", "Center", "Top" }, S.pivot, setter("pivot"))
		showWhen(pivot.frame, function()
			return S.tool ~= "Sculpt"
		end)
		ui:slider(setSec, "Height offset", S.nudge, -50, 50, 0.5, setter("nudge"), 400)
		local snap = ui:toggle(setSec, "Snap to voxels", S.snap, setter("snap"))
		showWhen(snap.frame, function()
			return S.tool ~= "Sculpt"
		end)
		ui:choiceRow(setSec, "Plane lock", { "Off", "Auto", "Manual" }, S.planeLock, setter("planeLock", function()
			pickingPlane = false
		end))
		local manualGroup = ui:group(setSec)
		showWhen(manualGroup, function()
			return S.planeLock == "Manual"
		end)
		ui:choiceRow(manualGroup, "Plane faces", { "Up", "Surface" }, S.planeNormal, setter("planeNormal"))
		ui:button(manualGroup, "Set plane: click the terrain", function()
			setActive(true)
			pickingPlane = true
			setStatus("Click where the plane should go.")
		end)
		local mp = manualPlane()
		controls.planeHeight = ui:slider(manualGroup, "Plane height", if mp then mp.point.Y else 0, -500, 1000, 0.5, function(v)
			local p = manualPlane()
			if p then
				S.manualPlane = { p.point.X, v, p.point.Z, p.normal.X, p.normal.Y, p.normal.Z }
			else
				S.manualPlane = { 0, v, 0, 0, 1, 0 }
			end
			save()
		end, 10000)
		ui:note(setSec, "Plane lock keeps the brush on a plane: Auto uses a plane through where the stroke starts, facing the camera in 45° steps (flat seen from above, tilted from in between, upright from the front or side); Manual uses the plane you set.")
		local fixed = ui:toggle(setSec, "Fixed flatten plane", S.fixedPlane, setter("fixedPlane"))
		showWhen(fixed.frame, isTool("Flatten"))
		ui:toggle(setSec, "Ignore water", S.ignoreWater, setter("ignoreWater", invalidatePath))
		ui:toggle(setSec, "Ignore parts", S.ignoreParts, setter("ignoreParts", invalidatePath))
		-- Rotation
		ui:label(setSec, "Rotation")
		rotateButton = ui:button(setSec, "Rotate with handles (R)", function()
			setRotating(not rotating)
		end)
		for _, axis in { "X", "Y", "Z" } do
			local key = "rot" .. axis
			controls[key] = ui:slider(setSec, "Rotation " .. axis, S[key], -180, 180, 1, setter(key), 360, -360)
		end
		ui:buttonRow(setSec, {
			{ text = "Reset rotation", onClick = function()
				setRotation(CFrame.identity)
				save()
			end },
		})
		ui:toggle(setSec, "Rings snap to Studio's rotate increment", S.rotateSnap, setter("rotateSnap"))
		ui:toggle(setSec, "Random rotation per stamp", S.randomRotation, setter("randomRotation"))
		ui:toggle(setSec, "Auto-rotate while dragging", S.autoRotate, setter("autoRotate"))
		local autoGroup = ui:group(setSec)
		showWhen(autoGroup, function()
			return S.autoRotate
		end)
		ui:toggle(autoGroup, "Tilt to the surface", S.tiltToSurface, setter("tiltToSurface"))
		ui:toggle(autoGroup, "Face along the stroke / path", S.facePath, setter("facePath"))
		ui:note(setSec, "The rings turn the brush about its own axes, like Studio's Rotate tool. Auto-rotate is off by default, so the brush keeps its rotation while you drag; turned on, it tilts with the surface and/or turns its front (-Z) along the stroke.")
		ui:slider(setSec, "Spacing", S.spacing, 0.1, 2, 0.05, setter("spacing", invalidatePath))

		-- Material
		local matSec = ui:section("Material")
		showWhen(matSec, function()
			return S.tool ~= "Smooth"
		end)
		local auto = ui:toggle(matSec, "Auto material (copy nearby terrain)", S.autoMaterial, setter("autoMaterial"))
		showWhen(auto.frame, isTool("Draw", "Sculpt", "Flatten"))
		local replace = ui:toggle(matSec, "Draw repaints terrain inside the brush", S.replaceMaterial, setter("replaceMaterial"))
		showWhen(replace.frame, isTool("Draw"))
		local source = ui:materialPicker(matSec, "Replace", slots, S.source, S.sourceOpen, setter("source"), setter("sourceOpen"))
		showWhen(source.frame, function()
			return S.tool == "Paint" and S.paintMode == "Replace"
		end)
		local picker = ui:materialPicker(matSec, "Material", slots, S.material, S.pickerOpen, setter("material"), setter("pickerOpen"))
		pickerControl = picker
		showWhen(ui:note(matSec, "Water works with Draw and Sculpt (and Flatten's Grow uses nearby terrain for it). Custom slots come from Terrain material slots 23-62."), isTool("Draw", "Sculpt", "Flatten"))
		ui:button(matSec, "Refresh material list", function()
			slots = Materials.list(terrain)
			picker.refresh(slots)
			source.refresh(slots)
			setStatus(#slots .. " materials.")
		end)

		-- Path
		local pathSec = ui:section("Path")
		ui:choice(pathSec, Paths.Shapes, S.shape, 3, setter("shape", invalidatePath))
		local pathGroup = ui:group(pathSec)
		showWhen(pathGroup, function()
			return S.shape ~= "Freehand"
		end)
		ui:toggle(pathGroup, "Apply the whole path in one click", S.wholePath, setter("wholePath", function()
			pathAnchor = nil
			pathHover = nil
		end))
		local placeAgain = ui:button(pathGroup, "Place path again", function()
			pathAnchor = nil
			pathHover = nil
			setActive(true)
			setStatus("Click where the path should go.")
		end)
		showWhen(placeAgain, function()
			return not S.wholePath
		end)
		showWhen(ui:note(pathGroup, "Click once to place the path, then drag along it: the brush stays on the path and only draws the part you drag over (each drag is one undo). Green dot = start."), function()
			return not S.wholePath
		end)
		showWhen(ui:note(pathGroup, "Click to apply the whole path centred on the cursor. Green dot = start."), function()
			return S.wholePath
		end)
		ui:choice(pathGroup, { "Clockwise", "Counter-clockwise" }, if S.clockwise then "Clockwise" else "Counter-clockwise", 2, function(v)
			S.clockwise = v == "Clockwise"
			save()
			invalidatePath()
		end)
		ui:slider(pathGroup, "Radius", S.radius, 4, 400, 1, setter("radius", invalidatePath), 1600)
		local inner = ui:slider(pathGroup, "Inner radius", S.innerRadius, 0, 400, 1, setter("innerRadius", invalidatePath), 1600)
		showWhen(inner.frame, function()
			return S.shape == "Spiral"
		end)
		local turns = ui:slider(pathGroup, "Turns", S.turns, 0.25, 20, 0.25, setter("turns", invalidatePath))
		showWhen(turns.frame, function()
			return S.shape ~= "Line"
		end)
		local sides = ui:slider(pathGroup, "Sides", S.sides, 3, 12, 1, setter("sides", invalidatePath), 64)
		showWhen(sides.frame, function()
			return S.shape == "Polygon"
		end)
		ui:slider(pathGroup, "Rise", S.rise, -200, 200, 1, setter("rise", invalidatePath), 2000)
		ui:slider(pathGroup, "Start angle", S.angle, 0, 360, 5, setter("angle", invalidatePath))
		ui:toggle(pathGroup, "Follow the ground (drape over terrain)", S.followGround, setter("followGround", invalidatePath))
		ui:slider(pathGroup, "Stamps per frame", S.speed, 1, 20, 1, setter("speed"))
		ui:note(pathGroup, "Rise climbs from start to end (helix / ramp). Stamps per frame sets how fast a whole path (or a fast drag) is filled in.")
	end

	refreshBrushList()
	loadBrush()
	updateVisibility()

	-- Keep the brush list in sync with the folder.
	local folderConns: { RBXScriptConnection } = {}
	local function watchFolder()
		for _, c in folderConns do
			c:Disconnect()
		end
		table.clear(folderConns)
		local folder = brushFolder()
		if folder then
			local function changed()
				refreshBrushList()
				local kind, name = brushKind(S.brush)
				if kind == "place" and not brushSource(name) then
					loadBrush()
				end
			end
			table.insert(folderConns, folder.ChildAdded:Connect(changed))
			table.insert(folderConns, folder.ChildRemoved:Connect(changed))
		end
		refreshBrushList()
	end
	watchFolder()
	local conns: { RBXScriptConnection } = {}
	table.insert(conns, ServerStorage.ChildAdded:Connect(function(c)
		if c.Name == FOLDER_NAME then
			watchFolder()
		end
	end))
	table.insert(conns, ServerStorage.ChildRemoved:Connect(function(c)
		if c.Name == FOLDER_NAME then
			watchFolder()
		end
	end))

	-- Keyboard: R toggles the rotation tool (Enter / Esc finish it); B + drag adjusts size / height / strength.
	table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.R and active and not ctrlDown() and not altDown() and not stroke and not job then
			setRotating(not rotating)
			return
		end
		if rotating and (key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter or key == Enum.KeyCode.Escape) then
			setRotating(false)
			return
		end
		if key == Enum.KeyCode.B and active and mask and not stroke and not job and not rotating then
			local setting = if ctrlDown() then "height" elseif shiftDown() then "strength" else "size"
			local hit = cursorHit(activePlane())
			if hit then
				adjust = { key = setting, startX = mouse.X, start = S[setting], hit = hit }
			end
		end
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.B and adjust then
			adjust = nil
			save()
			updateVisibility()
			if mask then
				setStatus(describe(brushLabel(S.brush), mask))
			end
		end
	end))

	-- Rotation rings: turn the brush about the ring's axis (its own local axis), snapping like Studio's
	-- Rotate tool. The brush centre holds still while a ring is dragged.
	local handles = preview.handles
	table.insert(conns, handles.MouseEnter:Connect(function(axis)
		hoveredRings[axis] = true
	end))
	table.insert(conns, handles.MouseLeave:Connect(function(axis)
		hoveredRings[axis] = nil
	end))
	table.insert(conns, handles.MouseButton1Down:Connect(function()
		local r, m = rotating, mask
		if r and m then
			local scale = brushScale(m)
			r.start = userRotation()
			r.centre = brushCFrame(m, scale, r.hit.pos, r.hit.normal, nil, 0).Position
		end
	end))
	table.insert(conns, handles.MouseDrag:Connect(function(axis, relativeAngle)
		local r = rotating
		if not r or not r.start then
			return
		end
		local angle = relativeAngle
		if S.rotateSnap then
			local ok, inc = pcall(function()
				return StudioService.RotateIncrement
			end)
			if ok and type(inc) == "number" and inc > 0 then
				local snap = math.rad(inc)
				angle = math.round(angle / snap) * snap
			end
		end
		setRotation(r.start * CFrame.fromAxisAngle(Vector3.FromAxis(axis), angle))
		setStatus(string.format("Rotation X %.1f°  Y %.1f°  Z %.1f°", S.rotX, S.rotY, S.rotZ))
	end))
	table.insert(conns, handles.MouseButton1Up:Connect(function()
		local r = rotating
		if r then
			r.start = nil
			r.centre = nil
			save()
		end
	end))

	table.insert(conns, toolButton.Click:Connect(function()
		if widget then
			if widget.Enabled and active then
				setActive(false)
				widget.Enabled = false
			else
				widget.Enabled = true
				setActive(true)
			end
		else
			setActive(not active)
		end
	end))
	if widget then
		table.insert(conns, widget:GetPropertyChangedSignal("Enabled"):Connect(function()
			if not widget.Enabled then
				setActive(false)
			end
		end))
	end
	table.insert(conns, plugin.Deactivation:Connect(function()
		-- Another tool took the mouse.
		setActive(false)
	end))

	table.insert(conns, RunService.Heartbeat:Connect(step))

	local function destroy()
		for _, c in conns do
			c:Disconnect()
		end
		for _, c in folderConns do
			c:Disconnect()
		end
		for _, c in mouseConns do
			c:Disconnect()
		end
		finishRecording()
		preview:destroy()
		ui:destroy()
	end
	plugin.Unloading:Connect(destroy)

	-- Handle for tests.
	return {
		S = S,
		library = library,
		preview = preview,
		ui = ui,
		step = step,
		currentOp = currentOp,
		brushScale = brushScale,
		brushCFrame = brushCFrame,
		setActive = setActive,
		selectBrush = selectBrush,
		setRotating = setRotating,
		setRotation = setRotation,
		userRotation = userRotation,
		isRotating = function(): boolean
			return rotating ~= nil
		end,
		addSelected = addSelected,
		uploadMesh = uploadMesh,
		saveToLibrary = saveToLibrary,
		deleteBrush = deleteBrush,
		getMask = function(): Mask?
			return mask
		end,
		status = function(): string
			return if statusLabel then statusLabel.Text else ""
		end,
		destroy = destroy,
	}
end

return App
