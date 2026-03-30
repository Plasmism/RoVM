--!native
local bit32 = bit32
local TextDevice = {}

--8x8 font blob lives here so boot text works before anything more fancier does
--bit order is mirrored on purpose or every glyph comes out backwards
local FONT={

	[32]={0,0,0,0,0,0,0,0},
	[33]={24,24,24,24,24,0,24,0},
	[34]={108,108,40,0,0,0,0,0},
	[35]={108,108,254,108,254,108,108,0},
	[36]={16,124,20,124,208,124,16,0},
	[37]={198,230,112,56,28,206,198,0},
	[38]={56,108,56,220,102,102,220,0},
	[39]={48,48,16,0,0,0,0,0},
	[40]={96,48,24,24,24,48,96,0},
	[41]={12,24,48,48,48,24,12,0},
	[42]={0,108,56,254,56,108,0,0},
	[43]={0,24,24,126,24,24,0,0},
	[44]={0,0,0,0,0,24,24,12},
	[45]={0,0,0,126,0,0,0,0},
	[46]={0,0,0,0,0,24,24,0},
	[47]={192,96,48,24,12,6,2,0},

	[48]={124,198,206,222,246,230,124,0},
	[49]={24,28,24,24,24,24,126,0},
	[50]={124,198,192,112,28,6,254,0},
	[51]={124,198,192,120,192,198,124,0},
	[52]={112,120,108,102,254,96,240,0},
	[53]={254,6,126,192,192,198,124,0},
	[54]={120,12,6,126,198,198,124,0},
	[55]={254,198,96,48,24,24,24,0},
	[56]={124,198,198,124,198,198,124,0},
	[57]={124,198,198,252,192,96,60,0},

	[58]={0,24,24,0,0,24,24,0},
	[59]={0,24,24,0,0,24,24,12},
	[60]={96,48,24,12,24,48,96,0},
	[61]={0,0,126,0,126,0,0,0},
	[62]={12,24,48,96,48,24,12,0},
	[63]={124,198,192,112,24,0,24,0},
	[64]={124,198,222,214,222,6,124,0},

	[65]={56,108,198,254,198,198,198,0},
	[66]={126,198,198,126,198,198,126,0},
	[67]={124,198,6,6,6,198,124,0},
	[68]={62,102,198,198,198,102,62,0},
	[69]={254,6,6,126,6,6,254,0},
	[70]={254,6,6,126,6,6,6,0},
	[71]={124,198,6,246,198,198,124,0},
	[72]={198,198,198,254,198,198,198,0},
	[73]={126,24,24,24,24,24,126,0},
	[74]={248,96,96,96,96,102,60,0},
	[75]={198,102,54,30,54,102,198,0},
	[76]={6,6,6,6,6,6,254,0},
	[77]={198,238,254,214,198,198,198,0},
	[78]={198,206,222,246,230,198,198,0},
	[79]={124,198,198,198,198,198,124,0},
	[80]={126,198,198,126,6,6,6,0},
	[81]={124,198,198,198,214,102,220,0},
	[82]={126,198,198,126,54,102,198,0},
	[83]={124,198,6,124,192,198,124,0},
	[84]={255,24,24,24,24,24,24,0},
	[85]={198,198,198,198,198,198,124,0},
	[86]={198,198,198,198,198,108,56,0},
	[87]={198,198,198,214,254,238,198,0},
	[88]={198,198,108,56,108,198,198,0},
	[89]={102,102,102,60,24,24,24,0},
	[90]={254,192,96,48,24,12,254,0},

	[91]={120,24,24,24,24,24,120,0},
	[92]={2,6,12,24,48,96,192,0},
	[93]={120,96,96,96,96,96,120,0},
	[94]={16,56,108,198,0,0,0,0},
	[95]={0,0,0,0,0,0,0,255},

	[96]={24,24,48,0,0,0,0,0},

	[97]={0,0,60,96,124,102,220,0},
	[98]={6,6,62,102,102,102,62,0},
	[99]={0,0,124,198,6,198,124,0},
	[100]={192,192,252,198,198,198,252,0},
	[101]={0,0,124,198,254,6,124,0},
	[102]={112,216,24,126,24,24,24,0},
	[103]={0,0,252,198,198,252,192,124},
	[104]={6,6,62,102,102,102,102,0},
	[105]={24,0,28,24,24,24,126,0},
	[106]={96,0,96,96,96,102,102,60},
	[107]={6,6,102,54,30,54,102,0},
	[108]={28,24,24,24,24,24,126,0},
	[109]={0,0,110,254,214,198,198,0},
	[110]={0,0,62,102,102,102,102,0},
	[111]={0,0,124,198,198,198,124,0},
	[112]={0,0,62,102,102,62,6,6},
	[113]={0,0,252,198,198,252,192,192},
	[114]={0,0,182,110,6,6,6,0},
	[115]={0,0,252,6,124,192,126,0},
	[116]={24,24,126,24,24,216,112,0},
	[117]={0,0,102,102,102,102,252,0},
	[118]={0,0,198,198,198,108,56,0},
	[119]={0,0,198,198,214,254,108,0},
	[120]={0,0,198,108,56,108,198,0},
	[121]={0,0,102,102,102,124,96,62},
	[122]={0,0,254,48,24,12,254,0},

	[123]={112,24,24,14,24,24,112,0},
	[124]={24,24,24,0,24,24,24,0},
	[125]={14,24,24,112,24,24,14,0},
	[126]={220,118,0,0,0,0,0,0},
	[127]={0,0,0,0,0,0,0,0},
	--so glad its over
}

local function intToColor3(rgb)
	local r = bit32.band(bit32.rshift(rgb, 16), 0xFF)
	local g = bit32.band(bit32.rshift(rgb, 8), 0xFF)
	local b = bit32.band(rgb, 0xFF)
	return Color3.fromRGB(r, g, b)
end

local function drawChar(screen, cellX, cellY, ch, fg, bg)
	--fast path if host gave us a direct blitter
	if screen and screen.blitChar and bg ~= nil then
		--nil bg means leave old pixels alone. host blitter path is opaque.
		screen:blitChar(cellX, cellY, ch, fg, bg)
		return
	end

	local glyph = FONT[ch] or FONT[63] --fallback to ? so bad bytes do not summon brainfuck
									   -- reminds me of something...
									   -- +++++++[>++++++++++++++<-]>.++++++++++++++++.-----------------.++++++++.+++++.--------.+++++++++++++++.------------------.++++++++.
	local px0 = cellX * 10
	local py0 = cellY * 10

	local function getBit(x, y)
		x, y = math.floor(x), math.floor(y)
		if x < 0 or x >= 8 or y < 0 or y >= 8 then return 0 end
		local bits = glyph[y + 1] or 0
		return (bit32.band(bits, bit32.lshift(1, x)) ~= 0) and 1 or 0
	end

	for dy = 0, 9 do
		local sy = (dy + 0.5) * 8 / 10 - 0.5
		local y0 = math.floor(sy)
		local y1 = y0 + 1
		local fy = sy - y0

		for dx = 0, 9 do
			local sx = (dx + 0.5) * 8 / 10 - 0.5
			local x0 = math.floor(sx)
			local x1 = x0 + 1
			local fx = sx - x0

			local v00 = getBit(x0, y0)
			local v10 = getBit(x1, y0)
			local v01 = getBit(x0, y1)
			local v11 = getBit(x1, y1)

			local v0 = v00 * (1 - fx) + v10 * fx
			local v1 = v01 * (1 - fx) + v11 * fx
			local v = v0 * (1 - fy) + v1 * fy

			if v > 0.05 then
				if not bg then
					screen:setPixel(px0 + dx, py0 + dy, fg)
				else
					local r = math.floor(bg.R * 255 * (1 - v) + fg.R * 255 * v)
					local g = math.floor(bg.G * 255 * (1 - v) + fg.G * 255 * v)
					local b = math.floor(bg.B * 255 * (1 - v) + fg.B * 255 * v)
					screen:setPixel(px0 + dx, py0 + dy, Color3.fromRGB(r, g, b))
				end
			elseif bg then
				screen:setPixel(px0 + dx, py0 + dy, bg)
			end
		end
	end
end

function TextDevice.attach(mem, screen, TEXT_BASE)
	TEXT_BASE = TEXT_BASE or 0x400000

	local cols = math.floor(screen.width / 10)
	local rows = math.floor(screen.height / 10)
	local buffer = {}
	local fgBuffer = {}
	local bgBuffer = {}
	local defaultFg = Color3.fromRGB(255, 255, 255)
	local defaultBg = Color3.fromRGB(0, 0, 0)
	local historyLimit = 2000
	local historyBuffer = {}
	local historyFgBuffer = {}
	local historyBgBuffer = {}
	local scrollOffset = 0
	local function makeEmptyRow()
		local r = table.create(cols, 32)
		return r
	end
	local function makeColorRow(color)
		local r = {}
		for i = 1, cols do r[i] = color end
		return r
	end
	for i = 1, rows do
		buffer[i] = makeEmptyRow()
		fgBuffer[i] = makeColorRow(defaultFg)
		bgBuffer[i] = makeColorRow(defaultBg)
	end

	local state = {
		cx = 0,
		cy = 0,
		fg = Color3.fromRGB(255, 255, 255),
		bg = Color3.fromRGB(0, 0, 0),
		bgEnabled = true,
	}

	local function cloneRow(src, fallback)
		local row = table.create(cols)
		for i = 1, cols do
			row[i] = (src and src[i]) or fallback
		end
		return row
	end

	local function getMaxScroll()
		return math.max(0, #historyBuffer)
	end

	local function clampScrollOffset()
		scrollOffset = math.clamp(scrollOffset, 0, getMaxScroll())
	end

	local function requestPresent()
		if screen and screen.markFlush then
			screen:markFlush()
		end
	end

	local function getViewportStartIndex()
		clampScrollOffset()
		local totalLines = #historyBuffer + rows
		return math.max(1, totalLines - rows - scrollOffset + 1)
	end

	local function getLineAt(globalIndex)
		if globalIndex <= #historyBuffer then
			return historyBuffer[globalIndex], historyFgBuffer[globalIndex], historyBgBuffer[globalIndex]
		end

		local liveIndex = globalIndex - #historyBuffer
		return buffer[liveIndex], fgBuffer[liveIndex], bgBuffer[liveIndex]
	end

	local function drawScreenRow(screenRow, rowData, rowFg, rowBg)
		for c = 0, cols - 1 do
			local ch = rowData and rowData[c + 1] or 32
			local fg = rowFg and rowFg[c + 1] or state.fg
			local bg = rowBg and rowBg[c + 1] or state.bg
			drawChar(screen, c, screenRow, ch, fg, state.bgEnabled and bg or nil)
		end
	end

	local function getVisibleScreenRowForLiveRow(liveRow)
		local startIndex = getViewportStartIndex()
		local globalIndex = #historyBuffer + liveRow
		local screenRow = globalIndex - startIndex
		if screenRow >= 0 and screenRow < rows then
			return screenRow
		end
		return nil
	end

	local function redrawLiveRowIfVisible(liveRow)
		local screenRow = getVisibleScreenRowForLiveRow(liveRow)
		if screenRow == nil then
			return false
		end
		drawScreenRow(screenRow, buffer[liveRow], fgBuffer[liveRow], bgBuffer[liveRow])
		requestPresent()
		return true
	end

	local function scrollViewportBy(deltaLines)
		deltaLines = math.floor(deltaLines or 0)
		if deltaLines == 0 then
			return true
		end

		local previousStart = getViewportStartIndex()
		scrollOffset += deltaLines
		clampScrollOffset()
		local newStart = getViewportStartIndex()
		local actualDelta = previousStart - newStart

		if actualDelta == 0 then
			return true
		end

		local exposedRows = math.abs(actualDelta)
		if exposedRows >= rows then
			return false
		end

		local pixelDelta = exposedRows * 10
		if actualDelta > 0 and screen and screen.scrollDown then
			screen:scrollDown(pixelDelta)
			for row = 0, exposedRows - 1 do
				local rowData, rowFg, rowBg = getLineAt(newStart + row)
				drawScreenRow(row, rowData, rowFg, rowBg)
			end
			requestPresent()
			return true
		end

		if actualDelta < 0 and screen and screen.scrollUp then
			screen:scrollUp(pixelDelta)
			for row = rows - exposedRows, rows - 1 do
				local rowData, rowFg, rowBg = getLineAt(newStart + row)
				drawScreenRow(row, rowData, rowFg, rowBg)
			end
			requestPresent()
			return true
		end

		return false
	end

	local function redrawVisible()
		local startIndex = getViewportStartIndex()
		for screenRow = 0, rows - 1 do
			local rowData, rowFg, rowBg = getLineAt(startIndex + screenRow)
			drawScreenRow(screenRow, rowData, rowFg, rowBg)
		end
		requestPresent()
	end

	local function pushHistoryRow()
		historyBuffer[#historyBuffer + 1] = cloneRow(buffer[1], 32)
		historyFgBuffer[#historyFgBuffer + 1] = cloneRow(fgBuffer[1], defaultFg)
		historyBgBuffer[#historyBgBuffer + 1] = cloneRow(bgBuffer[1], defaultBg)

		if #historyBuffer > historyLimit then
			table.remove(historyBuffer, 1)
			table.remove(historyFgBuffer, 1)
			table.remove(historyBgBuffer, 1)
		end

		if scrollOffset > 0 then
			scrollOffset = math.min(getMaxScroll(), scrollOffset + 1)
		end
	end

	local function newline()
		state.cx = 0
		state.cy += 1
		if state.cy >= rows then
			pushHistoryRow()

			--roll live rows upward after history grabs the top line
			table.remove(buffer, 1)
			table.remove(fgBuffer, 1)
			table.remove(bgBuffer, 1)
			buffer[rows] = makeEmptyRow()
			fgBuffer[rows] = makeColorRow(defaultFg)
			bgBuffer[rows] = makeColorRow(defaultBg)
			state.cy = rows - 1

			if scrollOffset == 0 and screen and screen.scrollUp then
				screen:scrollUp(10)
				drawScreenRow(rows - 1, buffer[rows], fgBuffer[rows], bgBuffer[rows])
			else
				if scrollOffset > 0 then
					requestPresent()
				else
					redrawVisible()
				end
			end
			else
				if buffer[state.cy + 1] then
					--clear the new live row in memory first
				for c = 1, cols do buffer[state.cy + 1][c] = 32 end
					--also clear it visually when we can. putChar usually handles it but usually is a liar.
				if screen and screen.drawRect then
					--fast rect clear would go here if i ever wire one in
					--TODO: do that maybe
				else
					--otherwise later glyph writes will cover it
				end
			end
			if scrollOffset > 0 then
				redrawLiveRowIfVisible(state.cy + 1)
			end
		end
	end

	local function putChar(byte)
		byte = bit32.band(byte or 0, 0xFF)

		if byte == 10 then --newline
			newline()
			return
		elseif byte == 13 then --carriage return
			state.cx = 0
			return
		elseif byte == 8 then --backspace
			if state.cx > 0 then
				state.cx -= 1
				local row = buffer[state.cy + 1]
				if row then row[state.cx + 1] = 32 end
			end
			if scrollOffset == 0 then
				drawChar(screen, state.cx, state.cy, 32, state.fg, state.bgEnabled and state.bg or nil)
			else
				local screenRow = getVisibleScreenRowForLiveRow(state.cy + 1)
				if screenRow ~= nil then
					drawChar(screen, state.cx, screenRow, 32, state.fg, state.bgEnabled and state.bg or nil)
					requestPresent()
				end
			end
			return
		end

		local row = buffer[state.cy + 1]
		if row then row[state.cx + 1] = byte end
		local fgRow = fgBuffer[state.cy + 1]
		if fgRow then fgRow[state.cx + 1] = state.fg end
		local bgRow = bgBuffer[state.cy + 1]
		if bgRow then bgRow[state.cx + 1] = state.bg end

		if scrollOffset == 0 then
			drawChar(screen, state.cx, state.cy, byte, state.fg, state.bgEnabled and state.bg or nil)
		else
			local screenRow = getVisibleScreenRowForLiveRow(state.cy + 1)
			if screenRow ~= nil then
				drawChar(screen, state.cx, screenRow, byte, state.fg, state.bgEnabled and state.bg or nil)
				requestPresent()
			end
		end

		state.cx += 1
		if state.cx >= cols then
			newline()
		end
	end

	state.getMaxScroll = function(_self)
		return getMaxScroll()
	end

	state.getScrollOffset = function(_self)
		return scrollOffset
	end

	state.scrollLines = function(selfOrLines, maybeLines)
		local lines = maybeLines
		if type(selfOrLines) == "number" and lines == nil then
			lines = selfOrLines
		end
		lines = math.floor(lines or 0)
		if lines == 0 then
			return scrollOffset
		end
		if not scrollViewportBy(lines) then
			redrawVisible()
		end
		return scrollOffset
	end

	state.scrollToBottom = function(_self)
		if scrollOffset ~= 0 then
			scrollOffset = 0
			redrawVisible()
		end
	end

	--text regs
	--+0 cursor_x in cells
	--+1 cursor_y in cells
	--+2 fg 0xRRGGBB
	--+3 bg 0xRRGGBB
	--+4 write_char
	--+5 clear
	--+6 cols
	--+7 rows
	--+8 bg_enable 0 or 1
	mem:mapDevice(TEXT_BASE, 64,
		function(addr) --read
			local off = addr - TEXT_BASE
			if off == 0 then return state.cx end
			if off == 1 then return state.cy end
			if off == 6 then return cols end
			if off == 7 then return rows end
			if off == 8 then return state.bgEnabled and 1 or 0 end
			return 0
		end,
		function(addr, value) --write
			local off = addr - TEXT_BASE
			if off == 0 then
				state.cx = math.clamp(math.floor(value or 0), 0, cols - 1)
			elseif off == 1 then
				state.cy = math.clamp(math.floor(value or 0), 0, rows - 1)
			elseif off == 2 then
				state.fg = intToColor3(value or 0)
			elseif off == 3 then
				state.bg = intToColor3(value or 0)
			elseif off == 4 then
				putChar(value or 0)
			elseif off == 5 then
				state.cy = 0
				state.cx = 0
				scrollOffset = 0
				table.clear(historyBuffer)
				table.clear(historyFgBuffer)
				table.clear(historyBgBuffer)
				for i = 1, rows do
					buffer[i] = makeEmptyRow()
					fgBuffer[i] = makeColorRow(defaultFg)
					bgBuffer[i] = makeColorRow(defaultBg)
				end
				--draw row 0 right away so the cursor area is not stale junk
				redrawVisible()
			elseif off == 8 then
				state.bgEnabled = (value ~= 0)
			elseif off == 9 then
				redrawVisible()
			end
		end,
		true  --user mode can write tty regs
	)

	return state
end

--host ui steals this for window titles n other schtuff
TextDevice.FONT = FONT

return TextDevice

