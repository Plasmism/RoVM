--!native
--gpu writes straight into tile buffers
local bit32 = bit32
local math_min = math.min
local math_max = math.max
local math_floor = math.floor
local buffer_writeu32 = buffer.writeu32
local buffer_copy = buffer.copy
local GPUDevice = {}

local REG_CMD = 0 * 4
local REG_OFFSET_X = 1 * 4
local REG_OFFSET_Y = 2 * 4
local REG_LOGICAL_X = 3 * 4
local REG_LOGICAL_Y = 4 * 4
local REG_WRAP_WIDTH = 5 * 4
local REG_WRAP_HEIGHT = 6 * 4
local REG_LENGTH = 7 * 4
local REG_COLOR = 8 * 4
local REG_FRAMES_COMPLETED = 9 * 4
local REG_BUFFER_ADDR = 10 * 4
local REG_BUFFER_LEN = 11 * 4
local REG_X0 = 12 * 4
local REG_Y0 = 13 * 4
local REG_X1 = 14 * 4
local REG_Y1 = 15 * 4

local CMD_DRAW_RLE = 1
local CMD_DRAW_BUFFER = 2
local CMD_DRAW_RECT = 3
local CMD_DRAW_LINE = 4

function GPUDevice.attach(mem, screen, GPU_BASE, getTiles, screenWidth, screenHeight)
	local registers = {
		[REG_CMD] = 0,
		[REG_OFFSET_X] = 0,
		[REG_OFFSET_Y] = 0,
		[REG_LOGICAL_X] = 0,
		[REG_LOGICAL_Y] = 0,
		[REG_WRAP_WIDTH] = 0,
		[REG_WRAP_HEIGHT] = 0,
		[REG_LENGTH] = 0,
		[REG_COLOR] = 0,
		[REG_FRAMES_COMPLETED] = 0,
		[REG_BUFFER_ADDR] = 0,
		[REG_BUFFER_LEN] = 0,
		[REG_X0] = 0,
		[REG_Y0] = 0,
		[REG_X1] = 0,
		[REG_Y1] = 0,
	}

	local W = screenWidth or 1280
	local H = screenHeight or 720

	--cache x -> tile once; repeated tile scans = not good
	local tileForX = {}  --built lazily on first draw

	local function buildTileLookup()
		local tiles = getTiles()
		if #tiles == 0 then return end
		for x = 0, W - 1 do
			for _, tile in ipairs(tiles) do
				if x >= tile.x and x < tile.x + tile.w then
					tileForX[x] = tile
					break
				end
			end
		end
	end

	--rle fast path: batch by row and fill with copy-doubling. looks weird but hey it works !
	local function drawRleDirect()
		local offsetX = registers[REG_OFFSET_X]
		local offsetY = registers[REG_OFFSET_Y]
		local lx = registers[REG_LOGICAL_X]
		local ly = registers[REG_LOGICAL_Y]
		local wrapW = registers[REG_WRAP_WIDTH]
		local wrapH = registers[REG_WRAP_HEIGHT]
		local length = registers[REG_LENGTH]
		local colorInt = registers[REG_COLOR]

		--pack rgba into one u32. little-endian puts r in byte 0 and a in byte 3.
		local r = bit32.band(bit32.rshift(colorInt, 16), 0xFF)
		local g = bit32.band(bit32.rshift(colorInt, 8), 0xFF)
		local b = bit32.band(colorInt, 0xFF)
		local rgba = r + g * 256 + b * 65536 + 4278190080 --0xff000000 so alpha stays solid

		--build the lookup on first draw instead of during attach
		if not tileForX[0] then
			buildTileLookup()
		end

		local framesCompleted = 0
		local remaining = length

		while remaining > 0 do
			--pixels left before lx wraps
			local rowRemaining = wrapW - lx
			local batchLen = math_min(remaining, rowRemaining)

			--screen y for this chunk
			local py = offsetY + ly

			--offscreen rows get ignored and everyone moves on
			if py >= 0 and py < H then
				local startPx = offsetX + lx
				local endPx = startPx + batchLen - 1

				--clip x so negative offsets do not write into nothing
				local clampStart = math_max(startPx, 0)
				local clampEnd = math_min(endPx, W - 1)

				if clampStart <= clampEnd then
					local numPixels = clampEnd - clampStart + 1
					local tile = tileForX[clampStart]

					if tile then
						--best case: the whole run stays inside one tile
						local tileEndX = tile.x + tile.w
						if clampEnd < tileEndX then
							--write one pixel, then keep doubling the copied span until the run is full
							local localX = clampStart - tile.x
							local localY = py - tile.y
							local startOffset = (localY * tile.w + localX) * 4

							--seed pixel
							buffer_writeu32(tile.buffer, startOffset, rgba)

							--copy what is already there; still cheaper than touching every pixel by hand :)
							local totalBytes = numPixels * 4
							local written = 4
							while written < totalBytes do
								local copyLen = math_min(written, totalBytes - written)
								buffer_copy(tile.buffer, startOffset + written, tile.buffer, startOffset, copyLen)
								written += copyLen
							end

							tile.dirty = true
						else
							--run crossed a tile boundary. annoying, but whatever.
							for px = clampStart, clampEnd do
								local t = tileForX[px]
								if t then
									local lxl = px - t.x
									local lyl = py - t.y
									buffer_writeu32(t.buffer, (lyl * t.w + lxl) * 4, rgba)
									t.dirty = true
								end
							end
						end
					end
				end
			end

			--advance the guest cursor
			remaining -= batchLen
			lx += batchLen

			--x wraps before y because guest code expects that order
			if lx >= wrapW then
				lx = 0
				ly += 1
				if ly >= wrapH then
					ly = 0
					framesCompleted += 1
				end
			end
		end

		registers[REG_LOGICAL_X] = lx
		registers[REG_LOGICAL_Y] = ly
		registers[REG_FRAMES_COMPLETED] = framesCompleted
	end

	--buffer variant so the guest can hand over a chunk of runs in one go
	local function drawBufferDirect()
		local bufferAddr = registers[REG_BUFFER_ADDR]
		local bufferLen = registers[REG_BUFFER_LEN]
		
		local offsetX = registers[REG_OFFSET_X]
		local offsetY = registers[REG_OFFSET_Y]
		local lx = registers[REG_LOGICAL_X]
		local ly = registers[REG_LOGICAL_Y]
		local wrapW = registers[REG_WRAP_WIDTH]
		local wrapH = registers[REG_WRAP_HEIGHT]
		local colorState = registers[REG_COLOR]
		
		if not tileForX[0] then
			buildTileLookup()
		end
		
		--read guest memory a page at a time. much better than byte by byte
		local memBuf = mem.buf
		local memSize = mem.size
		local mmuRef = mem.mmu
		local isUser = (mem.mode == "user") and mmuRef ~= nil
		local PAGE_SIZE = 4096

		--one local buffer is easier on lua than a giant table of bytes !
		local localBufRaw = buffer.create(bufferLen)
		local buffer_readu8 = buffer.readu8
		local buffer_readu16 = buffer.readu16

		--copy page sized chunks whenever translation lets us
		local bytesRead = 0
		while bytesRead < bufferLen do
			local addr = bufferAddr + bytesRead
			local vPage = math_floor(addr / PAGE_SIZE)
			local pageOffset = addr - vPage * PAGE_SIZE
			local bytesInPage = math_min(PAGE_SIZE - pageOffset, bufferLen - bytesRead)

			local physBase
			if isUser then
				physBase = mmuRef:translate(vPage * PAGE_SIZE, "read")
				if not physBase then break end
			else
				physBase = vPage * PAGE_SIZE
			end

			local physAddr = physBase + pageOffset
			if physAddr >= 0 and physAddr + bytesInPage <= memSize then
				buffer.copy(localBufRaw, bytesRead, memBuf, physAddr, bytesInPage)
			end
			bytesRead += bytesInPage
		end
		
		local rgba0 = 4278190080 --black + alpha
		local rgba1 = 4294967295 --white + alpha
		local currentColor = colorState == 0 and rgba0 or rgba1
		
		local framesCompleted = 0
		local bytesConsumed = 0
		
		for i = 0, bufferLen - 2, 2 do
			--stop after one frame so guest code can flush or vsync
			if framesCompleted > 0 then
				bytesConsumed = i
				break
			end
			
			--u16 run lengths, one read and done
			local length = buffer_readu16(localBufRaw, i)
			
			if length == 0 then
				colorState = 1 - colorState
				currentColor = colorState == 0 and rgba0 or rgba1
				bytesConsumed = i + 2
				continue
			end
			
			--same row batched draw logic as the direct rle path. 
			--TODO: de dupe this maybe.
			local remaining = length
			while remaining > 0 do
				local rowRemaining = wrapW - lx
				local batchLen = math_min(remaining, rowRemaining)

				local py = offsetY + ly

				if py >= 0 and py < H then
					local startPx = offsetX + lx
					local endPx = startPx + batchLen - 1
					local clampStart = math_max(startPx, 0)
					local clampEnd = math_min(endPx, W - 1)

					if clampStart <= clampEnd then
						local numPixels = clampEnd - clampStart + 1
						local tile = tileForX[clampStart]

						if tile then
							local tileEndX = tile.x + tile.w
							if clampEnd < tileEndX then
								local localX = clampStart - tile.x
								local localY = py - tile.y
								local startOffset = (localY * tile.w + localX) * 4

								buffer_writeu32(tile.buffer, startOffset, currentColor)

								local totalBytes = numPixels * 4
								local written = 4
								while written < totalBytes do
									local copyLen = math_min(written, totalBytes - written)
									buffer_copy(tile.buffer, startOffset + written, tile.buffer, startOffset, copyLen)
									written += copyLen
								end

								tile.dirty = true
							else
								for px = clampStart, clampEnd do
									local t = tileForX[px]
									if t then
										buffer_writeu32(t.buffer, ((py - t.y) * t.w + (px - t.x)) * 4, currentColor)
										t.dirty = true
									end
								end
							end
						end
					end
				end

				remaining -= batchLen
				lx += batchLen

				if lx >= wrapW then
					lx = 0
					ly += 1
					if ly >= wrapH then
						ly = 0
						framesCompleted += 1
					end
				end
			end
			
			colorState = 1 - colorState
			currentColor = colorState == 0 and rgba0 or rgba1
			bytesConsumed = i + 2
		end
		
		registers[REG_LOGICAL_X] = lx
		registers[REG_LOGICAL_Y] = ly
		registers[REG_COLOR] = colorState
		registers[REG_FRAMES_COMPLETED] = framesCompleted
		registers[REG_BUFFER_LEN] = bufferLen - bytesConsumed  --guest can resume from the unread tail
		registers[REG_BUFFER_ADDR] = bufferAddr + bytesConsumed  --advance pointer aswell
	end

	local function drawRectDirect()
		local ox = registers[REG_OFFSET_X] or 0
		local oy = registers[REG_OFFSET_Y] or 0
		local x = registers[REG_X0] + ox
		local y = registers[REG_Y0] + oy
		local w = registers[REG_X1]
		local h = registers[REG_Y1]
		local colorInt = registers[REG_COLOR]
		local r = bit32.band(bit32.rshift(colorInt, 16), 0xFF)
		local g = bit32.band(bit32.rshift(colorInt, 8), 0xFF)
		local b = bit32.band(colorInt, 0xFF)
		local rgba = r + g * 256 + b * 65536 + 4278190080

		--same lazy lookup here; attach has enough going on already
		if not tileForX[0] then
			buildTileLookup()
		end
		if w <= 0 or h <= 0 or w > 4096 or h > 4096 then return end

		--clip the rect to the visible screen
		local clampX = math_max(x, 0)
		local clampY = math_max(y, 0)
		local clampEndX = math_min(x + w - 1, W - 1)
		local clampEndY = math_min(y + h - 1, H - 1)
		if clampX > clampEndX or clampY > clampEndY then return end

		--fill the first row once, then copy it downward. repetition is for buffers.
		local py = clampY
		local firstRowOffsets = {}  --tile -> {startOffset,totalBytes}

		--first row becomes the template
		local px = clampX
		while px <= clampEndX do
			local tile = tileForX[px]
			if tile and py >= tile.y and py < tile.y + tile.h then
				local localX = px - tile.x
				local localY = py - tile.y
				local pixelsInTile = math_min(clampEndX - px + 1, tile.w - localX)
				local startOffset = (localY * tile.w + localX) * 4

				--same copy-doubling fill as the rle path
				buffer_writeu32(tile.buffer, startOffset, rgba)
				local totalBytes = pixelsInTile * 4
				local written = 4
				while written < totalBytes do
					local copyLen = math_min(written, totalBytes - written)
					buffer_copy(tile.buffer, startOffset + written, tile.buffer, startOffset, copyLen)
					written += copyLen
				end

				firstRowOffsets[tile] = {localX, totalBytes}
				tile.dirty = true
				px += pixelsInTile
			else
				px += 1
			end
		end

		--copy the first row down instead of repainting every pixel again
		for ry = clampY + 1, clampEndY do
			for tile, info in pairs(firstRowOffsets) do
				if ry >= tile.y and ry < tile.y + tile.h then
					local localX = info[1]
					local totalBytes = info[2]
					local firstY = clampY - tile.y
					local srcOffset = (firstY * tile.w + localX) * 4
					local dstOffset = ((ry - tile.y) * tile.w + localX) * 4
					buffer_copy(tile.buffer, dstOffset, tile.buffer, srcOffset, totalBytes)
				end
			end
		end
	end

	local function drawLineDirect()
		local ox = registers[REG_OFFSET_X] or 0
		local oy = registers[REG_OFFSET_Y] or 0
		local x0 = registers[REG_X0] + ox
		local y0 = registers[REG_Y0] + oy
		local x1 = registers[REG_X1] + ox
		local y1 = registers[REG_Y1] + oy
		local colorInt = registers[REG_COLOR]
		local r = bit32.band(bit32.rshift(colorInt, 16), 0xFF)
		local g = bit32.band(bit32.rshift(colorInt, 8), 0xFF)
		local b = bit32.band(colorInt, 0xFF)
		local rgba = r + g * 256 + b * 65536 + 4278190080

		local tiles = getTiles()
		if #tiles == 0 then return end

		local dx = math.abs(x1 - x0)
		local dy = math.abs(y1 - y0)
		if dx > 4096 or dy > 4096 then return end
		local sx = x0 < x1 and 1 or -1
		local sy = y0 < y1 and 1 or -1
		local err = dx - dy

		local cachedTile = nil
		local cachedXMin, cachedXMax, cachedYMin, cachedYMax = -1, -1, -1, -1

		while true do
			if x0 >= 0 and x0 < W and y0 >= 0 and y0 < H then
				--cache the current tile so long lines do not keep rescanning tiles
				if not (x0 >= cachedXMin and x0 <= cachedXMax and y0 >= cachedYMin and y0 <= cachedYMax) then
					cachedTile = nil
					for _, t in ipairs(tiles) do
						if x0 >= t.x and x0 < t.x + t.w and y0 >= t.y and y0 < t.y + t.h then
							cachedTile = t
							cachedXMin, cachedXMax = t.x, t.x + t.w - 1
							cachedYMin, cachedYMax = t.y, t.y + t.h - 1
							break
						end
					end
				end

				if cachedTile then
					local lx = x0 - cachedTile.x
					local ly = y0 - cachedTile.y
					buffer_writeu32(cachedTile.buffer, (ly * cachedTile.w + lx) * 4, rgba)
					cachedTile.dirty = true
				end
			end
			if x0 == x1 and y0 == y1 then break end
			local e2 = 2 * err
			if e2 > -dy then err = err - dy; x0 = x0 + sx end
			if e2 < dx then err = err + dx; y0 = y0 + sy end
		end
	end

	mem:mapDevice(GPU_BASE, 64,
		function(addr) --read
			local reg = addr - GPU_BASE
			return registers[reg] or 0
		end,
		function(addr, value) --write
			local reg = addr - GPU_BASE
			if reg == REG_CMD then
				if value == CMD_DRAW_RLE then
					--print("[gpu] draw_rle len=" .. registers[REG_LENGTH])
					drawRleDirect()
				elseif value == CMD_DRAW_BUFFER then
					--print("[gpu] draw_buffer addr=" .. registers[REG_BUFFER_ADDR] .. " len=" .. registers[REG_BUFFER_LEN])
					drawBufferDirect()
				elseif value == CMD_DRAW_RECT then
					--print("[gpu] draw_rect (" .. registers[REG_X0] .. "," .. registers[REG_Y0] .. ") " .. registers[REG_X1] .. "x" .. registers[REG_Y1] .. " color=" .. registers[REG_COLOR])
					drawRectDirect()
				elseif value == CMD_DRAW_LINE then
					--print("[gpu] draw_line (" .. registers[REG_X0] .. "," .. registers[REG_Y0] .. ") to (" .. registers[REG_X1] .. "," .. registers[REG_Y1] .. ") color=" .. registers[REG_COLOR])
					drawLineDirect()
				end
				registers[REG_CMD] = 0
			elseif registers[reg] ~= nil then
				--if reg ~= REG_FRAMES_COMPLETED then
				--print("[gpu] reg_write " .. reg .. " = " .. value)
				--end
				registers[reg] = value
			end
		end,
		true --user mode can hit the gpu regs
	)
end

return GPUDevice
