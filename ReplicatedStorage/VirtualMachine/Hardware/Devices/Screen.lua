--!native
--sparse screen state because 1280*720 = 921600
local Screen = {}
Screen.__index = Screen

local function idx(x, y, w)
	return y * w + x + 1
end

function Screen.new(width, height, clearColor)
	local self = setmetatable({}, Screen)
	self.width = width
	self.height = height
	self.clearColor = clearColor or Color3.new(0, 0, 0)

	--only touched pixels live here
	self.pixels = {}

	--presenter decides how expensive redraw needs to be
	self.dirty = false
	self.flushRequested = false

	--per pixel dirt when a full redraw would be extra for no reason
	self.dirtyPixels = {}

	return self
end

function Screen:setPixel(x, y, color)
	if x < 0 or y < 0 or x >= self.width or y >= self.height then
		return
	end

	local i = idx(x, y, self.width)
	self.pixels[i] = color
	self.dirtyPixels[i] = true
	self.dirty = true
end

function Screen:clear(color)
	self.pixels = {}
	self.dirtyPixels = {}
	self.clearColor = color or self.clearColor
	self.dirty = true
	self.flushRequested = true
	self.fullClear = true --presenter checks this on full wipes. pls do not "clean it up"
						  -- it IS important
end


function Screen:markFlush()
	self.flushRequested = true
end

function Screen:drawRleRun(offsetX, offsetY, logicalX, logicalY, wrapWidth, wrapHeight, length, colorInt)
	local lx = logicalX
	local ly = logicalY
	local framesCompleted = 0

	--do the wrap math once here instead of pretending a per pixel loop is fine
	local totalPixels = length
	
	--pixels left before lx wraps
	local rowRemaining = wrapWidth - lx
	
	if totalPixels <= rowRemaining then
		--easy case. whole run fits in one row. WOOOHOO!!
		lx = lx + totalPixels
		if lx >= wrapWidth then
			lx = 0
			ly = ly + 1
			if ly >= wrapHeight then
				ly = 0
				framesCompleted = framesCompleted + 1
			end
		end
	else
		--spills into more rows, so do the arithmetic once and keep moving
		totalPixels = totalPixels - rowRemaining  --eat the tail of the current row first
		ly = ly + 1
		if ly >= wrapHeight then
			ly = 0
			framesCompleted = framesCompleted + 1
		end
		
		--fullRows*wrapWidth + leftover = whatever is still left
		local fullRows = math.floor(totalPixels / wrapWidth)
		local leftover = totalPixels - fullRows * wrapWidth
		
		--if we cross the remaining rows, congrats, that wrapped a frame too
		local rowsUntilWrap = wrapHeight - ly
		if fullRows >= rowsUntilWrap then
			--wrapped at least once
			local totalRows = fullRows
			framesCompleted = framesCompleted + math.floor((totalRows + (wrapHeight - rowsUntilWrap)) / wrapHeight)
			ly = (ly + fullRows) % wrapHeight
		else
			ly = ly + fullRows
		end
		
		lx = leftover
		if lx >= wrapWidth then
			lx = lx - wrapWidth
			ly = ly + 1
			if ly >= wrapHeight then
				ly = 0
				framesCompleted = framesCompleted + 1
			end
		end
	end

	self.dirty = true
	self.fullRedraw = true
	return lx, ly, framesCompleted
end

return Screen
