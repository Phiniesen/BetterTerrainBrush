--!strict
-- Ui: small widget kit for the dock panel (sections, choices, sliders, toggles, buttons, material picker).
-- Every control registers a painter, so a Studio theme change repaints everything, and returns a
-- Control whose `frame` the panel can hide when a setting doesn't apply to the current tool.

local Materials = require(script.Parent.Materials)
type Slot = Materials.Slot

local Ui = {}
Ui.__index = Ui

local C = Enum.StudioStyleGuideColor
local M = Enum.StudioStyleGuideModifier

local ROW = 24
local FONT = Enum.Font.SourceSans
local FONT_BOLD = Enum.Font.SourceSansBold

export type Control = {
	frame: GuiObject,
	set: (any) -> (),
	label: TextLabel?, -- rows with a label on the left
}

export type Ui = typeof(setmetatable({} :: {
	container: Instance,
	mousePosition: () -> Vector2,
	root: ScrollingFrame,
	painters: { () -> () },
	order: number,
	connections: { RBXScriptConnection },
}, Ui))

local function color(c: Enum.StudioStyleGuideColor, m: Enum.StudioStyleGuideModifier?): Color3
	return settings().Studio.Theme:GetColor(c, m or M.Default)
end
Ui.color = color

local function corner(parent: Instance, r: number)
	local u = Instance.new("UICorner")
	u.CornerRadius = UDim.new(0, r)
	u.Parent = parent
end

local function list(parent: Instance, padding: number): UIListLayout
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, padding)
	l.Parent = parent
	return l
end

-- `container` is the dock widget (or a test frame); `mousePosition` gives the cursor relative to it.
-- Perf: CPU Low (builds once) | Memory Low
function Ui.new(container: Instance, mousePosition: () -> Vector2): Ui
	local root = Instance.new("ScrollingFrame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BorderSizePixel = 0
	root.ScrollBarThickness = 6
	root.AutomaticCanvasSize = Enum.AutomaticSize.Y
	root.CanvasSize = UDim2.new()
	root.ScrollingDirection = Enum.ScrollingDirection.Y
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 12)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = root
	list(root, 6)
	root.Parent = container

	local self = setmetatable({
		container = container,
		mousePosition = mousePosition,
		root = root,
		painters = {},
		order = 0,
		connections = {},
	}, Ui)
	self:paint(function()
		root.BackgroundColor3 = color(C.MainBackground)
		root.ScrollBarImageColor3 = color(C.ScrollBar)
	end)
	table.insert(self.connections, settings().Studio.ThemeChanged:Connect(function()
		for _, p in self.painters do
			p()
		end
	end))
	return self
end

function Ui.destroy(self: Ui)
	for _, c in self.connections do
		c:Disconnect()
	end
	self.root:Destroy()
end

function Ui.paint(self: Ui, fn: () -> ())
	table.insert(self.painters, fn)
	fn()
end

function Ui.nextOrder(self: Ui): number
	self.order += 1
	return self.order
end

local function textLabel(text: string, bold: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = if bold then FONT_BOLD else FONT
	l.TextSize = if bold then 16 else 15
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	return l
end

-- Titled group. Returns its content frame.
function Ui.section(self: Ui, title: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = title
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BorderSizePixel = 0
	frame.LayoutOrder = self:nextOrder()
	corner(frame, 4)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 4), UDim.new(0, 6)
	pad.Parent = frame
	list(frame, 4)
	local header = textLabel(title, true)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 20)
	header.LayoutOrder = 0
	header.Parent = frame
	self:paint(function()
		frame.BackgroundColor3 = color(C.Titlebar)
		header.TextColor3 = color(C.MainText)
	end)
	frame.Parent = self.root
	return frame
end

-- Invisible full-width holder for grouping controls (so they can be hidden together).
function Ui.group(self: Ui, parent: Instance): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder = self:nextOrder()
	list(f, 4)
	f.Parent = parent
	return f
end

-- Label on the left, content on the right. Returns the row, the content holder and the label.
function Ui.row(self: Ui, parent: Instance, label: string, height: number?): (Frame, Frame, TextLabel)
	local row = Instance.new("Frame")
	row.Name = "Row_" .. label
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, height or ROW)
	row.LayoutOrder = self:nextOrder()
	local l = textLabel(label)
	l.Size = UDim2.new(0.36, -4, 1, 0)
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = row
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromScale(0.36, 0)
	holder.Size = UDim2.fromScale(0.64, 1)
	holder.Parent = row
	row.Parent = parent
	self:paint(function()
		l.TextColor3 = color(C.MainText)
	end)
	return row, holder, l
end

-- Plain full-width label.
function Ui.label(self: Ui, parent: Instance, text: string): TextLabel
	local l = textLabel(text)
	l.Size = UDim2.new(1, 0, 0, 18)
	l.LayoutOrder = self:nextOrder()
	l.Parent = parent
	self:paint(function()
		l.TextColor3 = color(C.MainText)
	end)
	return l
end

-- Small grey help text.
function Ui.note(self: Ui, parent: Instance, text: string): TextLabel
	local l = textLabel(text)
	l.TextSize = 13
	l.TextWrapped = true
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = self:nextOrder()
	l.Parent = parent
	self:paint(function()
		l.TextColor3 = color(C.DimmedText)
	end)
	return l
end

function Ui.button(self: Ui, parent: Instance, text: string, onClick: () -> (), primary: boolean?): TextButton
	local b = Instance.new("TextButton")
	b.Name = "Button_" .. text
	b.AutoButtonColor = true
	b.Size = UDim2.new(1, 0, 0, ROW)
	b.Font = FONT
	b.TextSize = 15
	b.Text = text
	b.TextTruncate = Enum.TextTruncate.AtEnd
	b.BorderSizePixel = 0
	b.LayoutOrder = self:nextOrder()
	corner(b, 3)
	b.Parent = parent
	b.Activated:Connect(onClick)
	self:paint(function()
		b.BackgroundColor3 = color(if primary then C.DialogMainButton else C.Button)
		b.TextColor3 = color(if primary then C.DialogMainButtonText else C.ButtonText)
	end)
	return b
end

-- Buttons side by side in one row.
function Ui.buttonRow(self: Ui, parent: Instance, items: { { text: string, onClick: () -> () } }): { TextButton }
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, ROW)
	holder.LayoutOrder = self:nextOrder()
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / #items, -3, 0, ROW)
	grid.CellPadding = UDim2.fromOffset(3, 0)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = holder
	local out = {}
	for i, item in items do
		local b = self:button(holder, item.text, item.onClick)
		b.LayoutOrder = i
		table.insert(out, b)
	end
	holder.Parent = parent
	return out
end

-- Segmented choice.
-- Perf: CPU Low (repaints its buttons on change) | Memory Low
function Ui.choice(self: Ui, parent: Instance, options: { string }, value: string, perRow: number, onChange: (string) -> ()): Control
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	local rows = math.ceil(#options / perRow)
	holder.Size = UDim2.new(1, 0, 0, rows * ROW + (rows - 1) * 3)
	holder.LayoutOrder = self:nextOrder()
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / perRow, -3, 0, ROW)
	grid.CellPadding = UDim2.fromOffset(3, 3)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = holder
	local buttons: { [string]: TextButton } = {}
	local current = value
	local function repaint()
		for name, b in buttons do
			local on = name == current
			b.BackgroundColor3 = color(if on then C.DialogMainButton else C.Button)
			b.TextColor3 = color(if on then C.DialogMainButtonText else C.ButtonText)
		end
	end
	for i, name in options do
		local b = Instance.new("TextButton")
		b.Name = "Option_" .. name
		b.LayoutOrder = i
		b.Font = FONT
		b.TextSize = 15
		b.Text = name
		b.TextTruncate = Enum.TextTruncate.AtEnd
		b.BorderSizePixel = 0
		corner(b, 3)
		b.Parent = holder
		buttons[name] = b
		b.Activated:Connect(function()
			current = name
			repaint()
			onChange(name)
		end)
	end
	holder.Parent = parent
	self:paint(repaint)
	return {
		frame = holder,
		set = function(v: any)
			current = v
			repaint()
		end,
	}
end

-- Label + segmented choice in one row.
function Ui.choiceRow(self: Ui, parent: Instance, label: string, options: { string }, value: string, onChange: (string) -> ()): Control
	local row, holder = self:row(parent, label)
	local c = self:choice(holder, options, value, #options, onChange)
	c.frame.Size = UDim2.fromScale(1, 1)
	return { frame = row, set = c.set }
end

-- Checkbox row.
function Ui.toggle(self: Ui, parent: Instance, label: string, value: boolean, onChange: (boolean) -> ()): Control
	local b = Instance.new("TextButton")
	b.Name = "Toggle_" .. label
	b.BackgroundTransparency = 1
	b.Size = UDim2.new(1, 0, 0, ROW)
	b.Text = ""
	b.LayoutOrder = self:nextOrder()
	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(16, 16)
	box.Position = UDim2.new(0, 0, 0.5, -8)
	box.BorderSizePixel = 0
	corner(box, 3)
	box.Parent = b
	local tick = textLabel("✓", true)
	tick.Size = UDim2.fromScale(1, 1)
	tick.TextXAlignment = Enum.TextXAlignment.Center
	tick.TextSize = 14
	tick.Parent = box
	local l = textLabel(label)
	l.Position = UDim2.fromOffset(24, 0)
	l.Size = UDim2.new(1, -24, 1, 0)
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = b
	b.Parent = parent
	local current = value
	local function repaint()
		box.BackgroundColor3 = color(if current then C.DialogMainButton else C.InputFieldBackground)
		tick.TextColor3 = color(C.DialogMainButtonText)
		tick.Visible = current
		l.TextColor3 = color(C.MainText)
	end
	b.Activated:Connect(function()
		current = not current
		repaint()
		onChange(current)
	end)
	self:paint(repaint)
	return {
		frame = b,
		set = function(v: any)
			current = v
			repaint()
		end,
	}
end

-- Slider + number box. Typed values may go past the slider's range, down to `typedMin` / up to `typedMax`.
-- Perf: CPU Low (updates only while dragging) | Memory Low
function Ui.slider(self: Ui, parent: Instance, label: string, value: number, min: number, max: number, step: number, onChange: (number) -> (), typedMax: number?, typedMin: number?): Control
	local row, holder, labelText = self:row(parent, label)
	local bar = Instance.new("TextButton")
	bar.Text = ""
	bar.AutoButtonColor = false
	bar.BorderSizePixel = 0
	bar.Position = UDim2.new(0, 0, 0.5, -3)
	bar.Size = UDim2.new(1, -56, 0, 6)
	corner(bar, 3)
	bar.Parent = holder
	local fill = Instance.new("Frame")
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	corner(fill, 3)
	fill.Parent = bar
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(12, 12)
	knob.Position = UDim2.fromScale(0, 0.5)
	knob.BorderSizePixel = 0
	corner(knob, 6)
	knob.Parent = bar
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0, 50, 1, -4)
	box.Position = UDim2.new(1, -50, 0, 2)
	box.Font = FONT
	box.TextSize = 15
	box.ClearTextOnFocus = false
	box.BorderSizePixel = 0
	corner(box, 3)
	box.Parent = holder

	local current = value
	local decimals = if step < 1 then math.max(1, math.ceil(-math.log10(step) - 1e-9)) else 0
	local function show()
		local t = if max > min then math.clamp((current - min) / (max - min), 0, 1) else 0
		fill.Size = UDim2.fromScale(t, 1)
		knob.Position = UDim2.fromScale(t, 0.5)
		box.Text = string.format("%." .. decimals .. "f", current)
	end
	local function set(v: number, fire: boolean)
		v = math.clamp(math.round(v / step) * step, min, max)
		if v ~= current then
			current = v
			if fire then
				onChange(v)
			end
		end
		show()
	end
	local function fromMouse()
		local x = self.mousePosition().X
		local t = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		set(min + t * (max - min), true)
	end

	-- While dragging, a full-panel overlay keeps receiving mouse moves after the cursor leaves the bar.
	-- The release goes to whichever object the press started on (the bar), not the overlay, so every
	-- way the button can come up ends the drag, and moves only count while the press is still held.
	local overlay: TextButton? = nil
	local press: InputObject? = nil
	local dragConns: { RBXScriptConnection } = {}
	local function stopDrag()
		press = nil
		for _, c in dragConns do
			c:Disconnect()
		end
		table.clear(dragConns)
		if overlay then
			overlay:Destroy()
			overlay = nil
		end
	end
	local function held(): boolean
		local p = press
		return p ~= nil and p.UserInputState ~= Enum.UserInputState.End and p.UserInputState ~= Enum.UserInputState.Cancel
	end
	local function onMove(i: InputObject)
		if i.UserInputType ~= Enum.UserInputType.MouseMovement or not press then
			return
		end
		if held() then
			fromMouse()
		else
			stopDrag()
		end
	end
	local function onRelease(i: InputObject)
		if i.UserInputType == Enum.UserInputType.MouseButton1 then
			stopDrag()
		end
	end
	bar.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		stopDrag()
		press = input
		fromMouse()
		table.insert(dragConns, input:GetPropertyChangedSignal("UserInputState"):Connect(function()
			if not held() then
				stopDrag()
			end
		end))
		local o = Instance.new("TextButton")
		o.Name = "SliderDrag"
		o.Text = ""
		o.BackgroundTransparency = 1
		o.AutoButtonColor = false
		o.Size = UDim2.fromScale(1, 1)
		o.ZIndex = 100
		o.InputChanged:Connect(onMove)
		o.InputBegan:Connect(function(i)
			if i ~= press then
				onRelease(i) -- a new click while still "dragging" just ends it
			end
		end)
		o.InputEnded:Connect(onRelease)
		o.MouseButton1Up:Connect(stopDrag)
		o.MouseLeave:Connect(stopDrag)
		o.Parent = self.container
		overlay = o
	end)
	bar.InputChanged:Connect(onMove)
	bar.InputEnded:Connect(onRelease)
	bar.MouseButton1Up:Connect(stopDrag)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			local v = math.clamp(math.round(n / step) * step, typedMin or min, typedMax or max)
			if v ~= current then
				current = v
				onChange(v)
			end
		end
		show()
	end)

	self:paint(function()
		bar.BackgroundColor3 = color(C.InputFieldBackground)
		fill.BackgroundColor3 = color(C.DialogMainButton)
		knob.BackgroundColor3 = color(C.MainText)
		box.BackgroundColor3 = color(C.InputFieldBackground)
		box.TextColor3 = color(C.MainText)
	end)
	show()
	return {
		frame = row,
		set = function(v: any)
			current = v
			show()
		end,
		label = labelText,
	}
end

-- Single-line text box row. Calls onChange with the text when focus is lost.
function Ui.textBox(self: Ui, parent: Instance, label: string, value: string, onChange: (string) -> ()): Control
	local row, holder = self:row(parent, label)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 1, -4)
	box.Position = UDim2.fromOffset(0, 2)
	box.Font = FONT
	box.TextSize = 15
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.BorderSizePixel = 0
	box.Text = value
	corner(box, 3)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.Parent = box
	box.Parent = holder
	box.FocusLost:Connect(function()
		onChange(box.Text)
	end)
	self:paint(function()
		box.BackgroundColor3 = color(C.InputFieldBackground)
		box.TextColor3 = color(C.MainText)
	end)
	return {
		frame = row,
		set = function(v: any)
			box.Text = v
		end,
	}
end

-- Swatch for a material slot: the custom variant's texture, else the material colour.
local function swatch(parent: Instance, slot: Slot?, size: number): Frame
	local sw = Instance.new("Frame")
	sw.Name = "Swatch"
	sw.Size = UDim2.fromOffset(size, size)
	sw.BorderSizePixel = 0
	sw.BackgroundColor3 = if slot then slot.color else Color3.new(0.5, 0.5, 0.5)
	corner(sw, 3)
	if slot and slot.image then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		img.Image = slot.image
		img.ImageColor3 = slot.tint
		img.ScaleType = Enum.ScaleType.Crop
		corner(img, 3)
		img.Parent = sw
	end
	sw.Parent = parent
	return sw
end

export type Picker = Control & {
	refresh: (slots: { Slot }) -> (),
	setOpen: (open: boolean) -> (),
}

-- Collapsible material picker: a header showing the current slot, and a two-column grid of the given
-- slots (thumbnails for custom slots). `refresh` swaps in a new slot list, e.g. without Water for Paint.
-- Perf: CPU Low (one button per slot, rebuilt only on refresh) | Memory Low
function Ui.materialPicker(self: Ui, parent: Instance, label: string, slots: { Slot }, value: number, open: boolean, onChange: (number) -> (), onToggle: ((boolean) -> ())?): Picker
	local holder = Instance.new("Frame")
	holder.Name = "Picker_" .. label
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.LayoutOrder = self:nextOrder()
	list(holder, 3)

	local header = Instance.new("TextButton")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, ROW + 4)
	header.Text = ""
	header.BorderSizePixel = 0
	header.LayoutOrder = 1
	corner(header, 3)
	header.Parent = holder
	local headerSwatch: Frame? = nil
	local headerText = textLabel("")
	headerText.Position = UDim2.fromOffset(30, 0)
	headerText.Size = UDim2.new(1, -84, 1, 0)
	headerText.TextTruncate = Enum.TextTruncate.AtEnd
	headerText.Parent = header
	local hint = textLabel("")
	hint.TextSize = 13
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Position = UDim2.new(1, -56, 0, 0)
	hint.Size = UDim2.new(0, 50, 1, 0)
	hint.Parent = header

	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 2
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.5, -2, 0, 22)
	layout.CellPadding = UDim2.fromOffset(3, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	grid.Parent = holder

	local current = value
	local isOpen = open
	local currentSlots = slots
	local cells: { [number]: { button: TextButton, stroke: UIStroke } } = {}

	local function repaint()
		header.BackgroundColor3 = color(C.Button)
		headerText.TextColor3 = color(C.ButtonText)
		hint.TextColor3 = color(C.DimmedText)
		for index, c in cells do
			c.stroke.Enabled = index == current
			c.stroke.Color = color(C.DialogMainButton)
			c.button.BackgroundColor3 = color(C.Button)
			c.button.TextColor3 = color(C.ButtonText)
		end
	end
	local function showHeader()
		if headerSwatch then
			headerSwatch:Destroy()
		end
		local slot = Materials.find(currentSlots, current)
		local sw = swatch(header, slot, 20)
		sw.Position = UDim2.new(0, 5, 0.5, -10)
		headerSwatch = sw
		headerText.Text = string.format("%s: %s", label, if slot then slot.name else "slot " .. current)
		hint.Text = if isOpen then "hide" else "change"
		grid.Visible = isOpen
	end
	local function build()
		for _, c in cells do
			c.button:Destroy()
		end
		table.clear(cells)
		for i, slot in currentSlots do
			local b = Instance.new("TextButton")
			b.Name = "Slot_" .. slot.index
			b.LayoutOrder = i
			b.Font = FONT
			b.TextSize = 13
			b.Text = slot.name
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.TextTruncate = Enum.TextTruncate.AtEnd
			b.BorderSizePixel = 0
			b.AutoButtonColor = true
			corner(b, 3)
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 22)
			pad.Parent = b
			local sw = swatch(b, slot, 16)
			sw.Position = UDim2.new(0, -18, 0.5, -8)
			local stroke = Instance.new("UIStroke")
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Thickness = 2
			stroke.Parent = b
			b.Parent = grid
			cells[slot.index] = { button = b, stroke = stroke }
			b.Activated:Connect(function()
				current = slot.index
				showHeader()
				repaint()
				onChange(slot.index)
			end)
		end
		showHeader()
		repaint()
	end
	header.Activated:Connect(function()
		isOpen = not isOpen
		showHeader()
		if onToggle then
			onToggle(isOpen)
		end
	end)
	holder.Parent = parent
	build()
	self:paint(repaint)
	return {
		frame = holder,
		set = function(v: any)
			current = v
			showHeader()
			repaint()
		end,
		refresh = function(newSlots: { Slot })
			currentSlots = newSlots
			build()
		end,
		setOpen = function(o: boolean)
			isOpen = o
			showHeader()
		end,
	}
end

return Ui
