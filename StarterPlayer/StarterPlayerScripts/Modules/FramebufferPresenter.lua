--!native

local TextDevice = require(game:GetService("ReplicatedStorage").VirtualMachine.Hardware.Devices.TextDevice)

local FramebufferPresenter = {}
FramebufferPresenter.__index = FramebufferPresenter

function FramebufferPresenter.new(config)
	local self = setmetatable({}, FramebufferPresenter)

	local WIDTH = config.WIDTH
	local HEIGHT = config.HEIGHT
	local PIXEL_SIZE = config.PIXEL_SIZE
	local GPU_BASE = config.GPU_BASE
	local C = config.C
	local container = config.container
	local drawLayer = config.drawLayer
	local fb = config.fb
	local getScheduler = config.getScheduler

	local pixelFrames = {}
	local pixelFrameCount = 0
	local pixelsLastFlush = 0
	local pixelsPerSecond = 0

	local editableImages = {}
	local useEditableImage = false
	local TILE_SIZE = 1024

	local batchedFrames = {}
	local batchedFrameCount = 0

	local function clearAllDrawFrames()
		for _, inst in ipairs(drawLayer:GetChildren()) do
			inst:Destroy()
		end
		table.clear(pixelFrames)
		pixelFrameCount = 0
	end

	local function resetFramebufferTables()
		if typeof(fb.pixels) == "table" then
			table.clear(fb.pixels)
		end
		if typeof(fb.dirtyPixels) == "table" then
			table.clear(fb.dirtyPixels)
		end
		fb.dirty = false
		fb.flushRequested = false

		table.clear(pixelFrames)
		pixelFrameCount = 0
		pixelsLastFlush = 0
	end

	local function resetBatchedFrames()
		table.clear(batchedFrames)
		batchedFrameCount = 0
	end

	--editableimage tiles dodge texture limits and keep dirty uploads local
	--1024*1024*4 = 4194304 bytes per tile buffer already, so making them bigger would be dumb
	local function initEditableImage()
		local AssetService = game:GetService("AssetService")
		local tilesX = math.ceil(WIDTH / TILE_SIZE)
		local tilesY = math.ceil(HEIGHT / TILE_SIZE)
		local allSuccess = true

		for ty = 0, tilesY - 1 do
			for tx = 0, tilesX - 1 do
				local tileX = tx * TILE_SIZE
				local tileY = ty * TILE_SIZE
				local tileW = math.min(TILE_SIZE, WIDTH - tileX)
				local tileH = math.min(TILE_SIZE, HEIGHT - tileY)

				local success, result = pcall(function()
					return AssetService:CreateEditableImage({ Size = Vector2.new(tileW, tileH) })
				end)

				if not success or not result then
					warn("[Framebuffer] EditableImage tile error:", result or "creation returned nil")
					allSuccess = false
					break
				end

				local label = Instance.new("ImageLabel")
				label.Name = string.format("FramebufferTile_%d_%d", tx, ty)
				label.Size = UDim2.fromOffset(tileW * PIXEL_SIZE, tileH * PIXEL_SIZE)
				label.Position = UDim2.fromOffset(tileX * PIXEL_SIZE, tileY * PIXEL_SIZE)
				label.BackgroundTransparency = 1
				label.BorderSizePixel = 0
				label.ScaleType = Enum.ScaleType.Stretch
				label.Parent = container
				label.ImageContent = Content.fromObject(result)

				local buf = buffer.create(tileW * tileH * 4)
				for i = 0, tileW * tileH - 1 do
					local offset = i * 4
					buffer.writeu8(buf, offset, 0)
					buffer.writeu8(buf, offset + 1, 0)
					buffer.writeu8(buf, offset + 2, 0)
					buffer.writeu8(buf, offset + 3, 255)
				end

				result:WritePixelsBuffer(Vector2.zero, Vector2.new(tileW, tileH), buf)

				table.insert(editableImages, {
					image = result,
					label = label,
					buffer = buf,
					x = tileX,
					y = tileY,
					w = tileW,
					h = tileH,
					dirty = false,
				})
			end

			if not allSuccess then
				break
			end
		end

		if not allSuccess or #editableImages == 0 then
			for _, tile in ipairs(editableImages) do
				if tile.label then
					tile.label:Destroy()
				end
			end
			editableImages = {}
			print("[Framebuffer] EditableImage not available, using fallback renderer")
			return false
		end

		useEditableImage = true
		return true
	end

	local function getTileForPixel(x, y)
		for _, tile in ipairs(editableImages) do
			if x >= tile.x and x < tile.x + tile.w and y >= tile.y and y < tile.y + tile.h then
				return tile
			end
		end
		return nil
	end

	local markTileDirtyRect

	do
		--tty glyphs get cached as 10x10 rgba blobs so we stop redrawing the same little letter forever
		fb._glyphCache = fb._glyphCache or {}

		local function rgbKey(c)
			local r = math.floor(c.R * 255)
			local g = math.floor(c.G * 255)
			local b = math.floor(c.B * 255)
			return r, g, b, r * 65536 + g * 256 + b
		end

		function fb:blitChar(cellX, cellY, ch, fg, bg)
			if not useEditableImage or #editableImages == 0 then
				return
			end

			cellX = math.floor(cellX or 0)
			cellY = math.floor(cellY or 0)
			local px0 = cellX * 10
			local py0 = cellY * 10
			if px0 + 9 < 0 or py0 + 9 < 0 or px0 >= WIDTH or py0 >= HEIGHT then
				return
			end

			local fr, fg_, fb_, fkey = rgbKey(fg)
			local br, bg_, bb_, bkey = rgbKey(bg)
			local key = tostring(ch) .. "|" .. tostring(fkey) .. "|" .. tostring(bkey)
			local glyphBuf = fb._glyphCache[key]
			if not glyphBuf then
				glyphBuf = buffer.create(10 * 10 * 4)
				local glyph = TextDevice.FONT[ch] or TextDevice.FONT[63]
				local o = 0

				local function getBit(x, y)
					x = math.floor(x)
					y = math.floor(y)
					if x < 0 or x >= 8 or y < 0 or y >= 8 then
						return 0
					end
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

						local tr = math.floor(br * (1 - v) + fr * v)
						local tg = math.floor(bg_ * (1 - v) + fg_ * v)
						local tb = math.floor(bb_ * (1 - v) + fb_ * v)

						buffer.writeu8(glyphBuf, o, tr)
						buffer.writeu8(glyphBuf, o + 1, tg)
						buffer.writeu8(glyphBuf, o + 2, tb)
						buffer.writeu8(glyphBuf, o + 3, 255)
						o += 4
					end
				end
				fb._glyphCache[key] = glyphBuf
			end

			local affectedTiles = {}
			for row = 0, 9 do
				local y = py0 + row
				if y >= 0 and y < HEIGHT then
					local remaining = 10
					local destX = px0
					local srcOff = row * 40

					while remaining > 0 do
						if destX >= WIDTH then
							break
						end
						if destX < 0 then
							local skip = math.min(remaining, -destX)
							destX += skip
							srcOff += skip * 4
							remaining -= skip
							continue
						end

						local tile = getTileForPixel(destX, y)
						if not tile then
							break
						end

						local localX = destX - tile.x
						local localY = y - tile.y
						local maxPixels = tile.w - localX
						if maxPixels <= 0 then
							break
						end

						local copyPixels = math.min(remaining, maxPixels)
						local copyBytes = copyPixels * 4
						local destOff = (localY * tile.w + localX) * 4

						buffer.copy(tile.buffer, destOff, glyphBuf, srcOff, copyBytes)
						tile.dirty = true

						local info = affectedTiles[tile]
						if not info then
							info = { x1 = localX, y1 = localY, x2 = localX + copyPixels - 1, y2 = localY }
							affectedTiles[tile] = info
						else
							if localX < info.x1 then
								info.x1 = localX
							end
							if localY < info.y1 then
								info.y1 = localY
							end
							if (localX + copyPixels - 1) > info.x2 then
								info.x2 = localX + copyPixels - 1
							end
							if localY > info.y2 then
								info.y2 = localY
							end
						end

						destX += copyPixels
						srcOff += copyBytes
						remaining -= copyPixels
					end
				end
			end

			for tile, info in pairs(affectedTiles) do
				markTileDirtyRect(tile, info.x1, info.y1, info.x2 - info.x1 + 1, info.y2 - info.y1 + 1)
			end
		end

		function fb:scrollUp(pixels)
			if not useEditableImage or #editableImages == 0 then
				return
			end
			pixels = math.floor(pixels or 0)
			if pixels <= 0 then
				return
			end

			for _, tile in ipairs(editableImages) do
				local tileRowBytes = tile.w * 4
				local tilePixels = math.min(pixels, tile.h)
				local moveRows = tile.h - tilePixels
				local scratch = tile._scrollScratch
				if not scratch or buffer.len(scratch) ~= tileRowBytes then
					scratch = buffer.create(tileRowBytes)
					tile._scrollScratch = scratch
				end

				for row = 0, moveRows - 1 do
					local dstOff = row * tileRowBytes
					local srcOff = (row + tilePixels) * tileRowBytes
					buffer.copy(scratch, 0, tile.buffer, srcOff, tileRowBytes)
					buffer.copy(tile.buffer, dstOff, scratch, 0, tileRowBytes)
				end

				if tilePixels > 0 then
					local clearStart = moveRows * tileRowBytes
					local clearBytes = tilePixels * tileRowBytes
					buffer.fill(tile.buffer, clearStart, 0, clearBytes)
					for i = 0, (clearBytes / 4) - 1 do
						buffer.writeu8(tile.buffer, clearStart + i * 4 + 3, 255)
					end
				end

				tile.dirty = true
				tile.dirtyRect = nil
				tile.fullDirty = true
			end
		end

		function fb:scrollDown(pixels)
			if not useEditableImage or #editableImages == 0 then
				return
			end
			pixels = math.floor(pixels or 0)
			if pixels <= 0 then
				return
			end

			for _, tile in ipairs(editableImages) do
				local tileRowBytes = tile.w * 4
				local tilePixels = math.min(pixels, tile.h)
				local moveRows = tile.h - tilePixels
				local scratch = tile._scrollScratch
				if not scratch or buffer.len(scratch) ~= tileRowBytes then
					scratch = buffer.create(tileRowBytes)
					tile._scrollScratch = scratch
				end

				for row = moveRows - 1, 0, -1 do
					local dstOff = (row + tilePixels) * tileRowBytes
					local srcOff = row * tileRowBytes
					buffer.copy(scratch, 0, tile.buffer, srcOff, tileRowBytes)
					buffer.copy(tile.buffer, dstOff, scratch, 0, tileRowBytes)
				end

				if tilePixels > 0 then
					local clearBytes = tilePixels * tileRowBytes
					buffer.fill(tile.buffer, 0, 0, clearBytes)
					for i = 0, (clearBytes / 4) - 1 do
						buffer.writeu8(tile.buffer, i * 4 + 3, 255)
					end
				end

				tile.dirty = true
				tile.dirtyRect = nil
				tile.fullDirty = true
			end
		end
	end

	--editableimage path patches tile buffers directly
	--fallback path batches same color horizontal runs into frames. better but still ehhh
	local function renderIncremental()
		local count = 0

		if useEditableImage and #editableImages > 0 then
			if fb.fullRedraw then
				fb.fullRedraw = false
				table.clear(fb.dirtyPixels)
			else
				for i in pairs(fb.dirtyPixels) do
					local color = fb.pixels[i]
					if color then
						local pixelIndex = i - 1
						local x = pixelIndex % WIDTH
						local y = math.floor(pixelIndex / WIDTH)

						local tile = getTileForPixel(x, y)
						if tile then
							local localX = x - tile.x
							local localY = y - tile.y
							local localIndex = localY * tile.w + localX
							local offset = localIndex * 4

							buffer.writeu8(tile.buffer, offset, math.floor(color.R * 255))
							buffer.writeu8(tile.buffer, offset + 1, math.floor(color.G * 255))
							buffer.writeu8(tile.buffer, offset + 2, math.floor(color.B * 255))
							buffer.writeu8(tile.buffer, offset + 3, 255)

							tile.dirty = true
							count += 1
						end
					end
				end
				table.clear(fb.dirtyPixels)
			end

			fb.dirty = false
			return count
		end

		local dirtyRows = {}
		for i in pairs(fb.dirtyPixels) do
			local x = (i - 1) % WIDTH
			local y = math.floor((i - 1) / WIDTH)
			if not dirtyRows[y] then
				dirtyRows[y] = {}
			end
			dirtyRows[y][x] = true
		end

		for y, xSet in pairs(dirtyRows) do
			local xList = {}
			for x in pairs(xSet) do
				table.insert(xList, x)
			end
			table.sort(xList)

			local runStart = nil
			local runColor = nil
			local runEnd = nil

			for _, x in ipairs(xList) do
				local i = y * WIDTH + x + 1
				local color = fb.pixels[i]

				if runStart == nil then
					runStart = x
					runEnd = x
					runColor = color
				elseif x == runEnd + 1 and color == runColor then
					runEnd = x
				else
					local runWidth = runEnd - runStart + 1
					local batchKey = string.format("%d_%d_%d", y, runStart, runEnd)

					for px = runStart, runEnd do
						local pi = y * WIDTH + px + 1
						local oldFrame = pixelFrames[pi]
						if oldFrame then
							oldFrame:Destroy()
							pixelFrames[pi] = nil
							pixelFrameCount -= 1
						end
					end

					local frame = batchedFrames[batchKey]
					if not frame then
						frame = Instance.new("Frame")
						frame.BorderSizePixel = 0
						frame.Position = UDim2.fromOffset(runStart * PIXEL_SIZE, y * PIXEL_SIZE)
						frame.Size = UDim2.fromOffset(runWidth * PIXEL_SIZE, PIXEL_SIZE)
						frame.Parent = drawLayer
						batchedFrames[batchKey] = frame
						batchedFrameCount += 1
					end
					frame.BackgroundColor3 = runColor
					count += runWidth

					runStart = x
					runEnd = x
					runColor = color
				end
			end

			if runStart ~= nil then
				local runWidth = runEnd - runStart + 1
				local batchKey = string.format("%d_%d_%d", y, runStart, runEnd)

				for px = runStart, runEnd do
					local pi = y * WIDTH + px + 1
					local oldFrame = pixelFrames[pi]
					if oldFrame then
						oldFrame:Destroy()
						pixelFrames[pi] = nil
						pixelFrameCount -= 1
					end
				end

				local frame = batchedFrames[batchKey]
				if not frame then
					frame = Instance.new("Frame")
					frame.BorderSizePixel = 0
					frame.Position = UDim2.fromOffset(runStart * PIXEL_SIZE, y * PIXEL_SIZE)
					frame.Size = UDim2.fromOffset(runWidth * PIXEL_SIZE, PIXEL_SIZE)
					frame.Parent = drawLayer
					batchedFrames[batchKey] = frame
					batchedFrameCount += 1
				end
				frame.BackgroundColor3 = runColor
				count += runWidth
			end
		end

		table.clear(fb.dirtyPixels)
		fb.dirty = false
		return count
	end

	--dirty rect uploads matter a lot here
	--without them one pixel change would rewrite a whole damn tile
	local function flushPixelBuffer()
		if useEditableImage then
			if _G.ROVM_CRASH_EFFECT then
				for _, tile in ipairs(editableImages) do
					local buf = tile.buffer
					local bLen = buffer.len(buf)
					for i = 0, bLen - 4, 4 do
						buffer.writeu32(buf, i, math.random(0, 0x7FFFFFFF))
					end
					tile.dirty = true
				end
			end

			local pendingCount = 0
			for _, tile in ipairs(editableImages) do
				if tile.dirty then
					pendingCount += 1
				end
			end

			if pendingCount > 1 then
				for _, tile in ipairs(editableImages) do
					if tile.dirty then
						task.spawn(function()
							local dr = tile.dirtyRect
							if tile.fullDirty then
								tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.w, tile.h), tile.buffer)
								tile.fullDirty = false
								tile.dirtyRect = nil
							elseif dr then
								local x1, y1, x2, y2 = dr[1], dr[2], dr[3], dr[4]
								local w = x2 - x1 + 1
								local h = y2 - y1 + 1
								if w > 0 and h > 0 and w <= tile.w and h <= tile.h then
									local bytes = w * h * 4
									local scratch = tile._scratch
									if not scratch or buffer.len(scratch) ~= bytes then
										scratch = buffer.create(bytes)
										tile._scratch = scratch
									end
									local copyBytes = w * 4
									for ry = 0, h - 1 do
										local srcOff = ((y1 + ry) * tile.w + x1) * 4
										local dstOff = ry * copyBytes
										buffer.copy(scratch, dstOff, tile.buffer, srcOff, copyBytes)
									end
									tile.image:WritePixelsBuffer(Vector2.new(x1, y1), Vector2.new(w, h), scratch)
								else
									tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.w, tile.h), tile.buffer)
								end
								tile.dirtyRect = nil
							else
								tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.w, tile.h), tile.buffer)
							end
							tile.dirty = false
						end)
					end
				end
			else
				for _, tile in ipairs(editableImages) do
					if tile.dirty then
						local dr = tile.dirtyRect
						if tile.fullDirty then
							tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.w, tile.h), tile.buffer)
							tile.fullDirty = false
							tile.dirtyRect = nil
						elseif dr then
							local x1, y1, x2, y2 = dr[1], dr[2], dr[3], dr[4]
							local w = x2 - x1 + 1
							local h = y2 - y1 + 1
							if w > 0 and h > 0 and w <= tile.w and h <= tile.h then
								local bytes = w * h * 4
								local scratch = tile._scratch
								if not scratch or buffer.len(scratch) ~= bytes then
									scratch = buffer.create(bytes)
									tile._scratch = scratch
								end
								local copyBytes = w * 4
								for ry = 0, h - 1 do
									local srcOff = ((y1 + ry) * tile.w + x1) * 4
									local dstOff = ry * copyBytes
									buffer.copy(scratch, dstOff, tile.buffer, srcOff, copyBytes)
								end
								tile.image:WritePixelsBuffer(Vector2.new(x1, y1), Vector2.new(w, h), scratch)
							else
								tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.w, tile.h), tile.buffer)
							end
							tile.dirtyRect = nil
						else
							tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.w, tile.h), tile.buffer)
						end
						tile.dirty = false
					end
				end
			end
		end
	end

	--fill once, then copy the bytes across the whole tile
	local function clearPixelBuffer(color)
		if useEditableImage then
			local r = math.floor(color.R * 255)
			local g = math.floor(color.G * 255)
			local b = math.floor(color.B * 255)
			local rgba = r + g * 256 + b * 65536 + 0xFF000000

			for _, tile in ipairs(editableImages) do
				local pixelCount = tile.w * tile.h
				local totalBytes = pixelCount * 4
				buffer.writeu32(tile.buffer, 0, rgba)

				local written = 4
				while written < totalBytes do
					local copyLen = math.min(written, totalBytes - written)
					buffer.copy(tile.buffer, written, tile.buffer, 0, copyLen)
					written += copyLen
				end

				tile.dirty = true
			end
		end
	end

	--dirty rects merge until flush so nearby writes do not spam uploads
	markTileDirtyRect = function(tile, x, y, w, h)
		if not tile then
			return
		end
		if tile.fullDirty then
			return
		end
		x = math.floor(x or 0)
		y = math.floor(y or 0)
		w = math.floor(w or 0)
		h = math.floor(h or 0)
		if w <= 0 or h <= 0 then
			return
		end
		local x2 = x + w - 1
		local y2 = y + h - 1
		if x < 0 then x = 0 end
		if y < 0 then y = 0 end
		if x2 >= tile.w then x2 = tile.w - 1 end
		if y2 >= tile.h then y2 = tile.h - 1 end

		local dr = tile.dirtyRect
		if not dr then
			tile.dirtyRect = { x, y, x2, y2 }
		else
			if x < dr[1] then dr[1] = x end
			if y < dr[2] then dr[2] = y end
			if x2 > dr[3] then dr[3] = x2 end
			if y2 > dr[4] then dr[4] = y2 end
		end
	end

	local function intToColor3(rgb)
		local r = bit32.band(bit32.rshift(rgb, 16), 0xFF) / 255
		local g = bit32.band(bit32.rshift(rgb, 8), 0xFF) / 255
		local b = bit32.band(rgb, 0xFF) / 255
		return Color3.new(r, g, b)
	end

	local function clearScreenRect(screen, rx, ry, rw, rh, color)
		if rx <= 0 and ry <= 0 and rx + rw >= WIDTH and ry + rh >= HEIGHT then
			screen:clear(color)
			return
		end
		for y = ry, ry + rh - 1 do
			if y >= 0 and y < HEIGHT then
				for x = rx, rx + rw - 1 do
					if x >= 0 and x < WIDTH then
						screen:setPixel(x, y, color)
					end
				end
			end
		end
	end

	local function drawTitleString(screen, px, py, str, color)
		local font = TextDevice.FONT
		if not font then
			return
		end
		local fallback = font[63]
		for i = 1, #str do
			local ch = string.byte(str, i)
			local glyph = font[ch] or fallback
			if glyph then
				for row = 0, 7 do
					local bits = glyph[row + 1] or 0
					for col = 0, 7 do
						if bit32.band(bits, bit32.lshift(1, col)) ~= 0 then
							local x = px + (i - 1) * 9 + col
							local y = py + row
							if x >= 0 and x < screen.width and y >= 0 and y < screen.height then
								screen:setPixel(x, y, color)
							end
						end
					end
				end
			end
		end
	end

	local function drawAppWindowChrome(screen, aw)
		local borderColor = Color3.fromRGB(180, 180, 180)
		local titleColor = Color3.fromRGB(60, 60, 65)
		local titleTextColor = Color3.fromRGB(220, 220, 220)
		local closeBgColor = Color3.fromRGB(200, 60, 50)
		local closeFgColor = Color3.fromRGB(255, 255, 255)
		local wx, wy = aw.winX, aw.winY
		local ww, wh = aw.winW, aw.winH

		for x = wx, wx + ww - 1 do
			screen:setPixel(x, wy, borderColor)
			screen:setPixel(x, wy + 1, borderColor)
			screen:setPixel(x, wy + wh - 2, borderColor)
			screen:setPixel(x, wy + wh - 1, borderColor)
		end
		for y = wy, wy + wh - 1 do
			screen:setPixel(wx, y, borderColor)
			screen:setPixel(wx + 1, y, borderColor)
			screen:setPixel(wx + ww - 2, y, borderColor)
			screen:setPixel(wx + ww - 1, y, borderColor)
		end

		for y = wy + C["APP_BORDER_W"], wy + C["APP_TITLE_BAR_H"] do
			for x = wx + C["APP_BORDER_W"], wx + ww - C["APP_BORDER_W"] - 1 do
				screen:setPixel(x, y, titleColor)
			end
		end

		if aw.title and #aw.title > 0 then
			local tx = wx + C["APP_BORDER_W"] + 4
			local ty = wy + C["APP_BORDER_W"] + math.floor((C["APP_TITLE_BAR_H"] - C["APP_BORDER_W"] * 2 - 8) / 2)
			drawTitleString(screen, tx, ty, aw.title, titleTextColor)
		end

		for y = aw.closeY1, aw.closeY2 do
			for x = aw.closeX1, aw.closeX2 do
				screen:setPixel(x, y, closeBgColor)
			end
		end

		local dx = aw.closeX2 - aw.closeX1
		local dy = aw.closeY2 - aw.closeY1
		for i = 0, math.max(dx, dy) do
			local t = (dx > 0) and (i / dx) or 0
			local px1 = math.floor(aw.closeX1 + t * dx)
			local py1 = math.floor(aw.closeY1 + t * dy)
			local px2 = math.floor(aw.closeX2 - t * dx)
			local py2 = math.floor(aw.closeY1 + t * dy)
			if px1 >= aw.closeX1 and px1 <= aw.closeX2 and py1 >= aw.closeY1 and py1 <= aw.closeY2 then
				screen:setPixel(px1, py1, closeFgColor)
			end
			if px2 >= aw.closeX1 and px2 <= aw.closeX2 and py2 >= aw.closeY1 and py2 <= aw.closeY2 and (px2 ~= px1 or py2 ~= py1) then
				screen:setPixel(px2, py2, closeFgColor)
			end
		end
	end

	local function presentIfRequested()
		if fb.flushRequested then
			fb.flushRequested = false

			if fb.fullClear then
				fb.fullClear = false

				if useEditableImage then
					clearPixelBuffer(fb.clearColor)
					flushPixelBuffer()
				else
					for _, inst in ipairs(drawLayer:GetChildren()) do
						inst:Destroy()
					end
					table.clear(pixelFrames)
					pixelFrameCount = 0
					resetBatchedFrames()
				end
				container.BackgroundColor3 = fb.clearColor
			end

			pixelsLastFlush += renderIncremental()

			local scheduler = getScheduler and getScheduler()
			if scheduler then
				local currentProc = scheduler:getCurrentProcess()
				if currentProc and currentProc.appWindow then
					local aw = currentProc.appWindow
					if aw.prevWinX ~= aw.winX or aw.prevWinY ~= aw.winY then
						clearScreenRect(fb, aw.prevWinX, aw.prevWinY, aw.winW, aw.winH, fb.clearColor or Color3.new(0.06, 0.06, 0.07))
					end
					drawAppWindowChrome(fb, aw)
					aw.prevWinX = aw.winX
					aw.prevWinY = aw.winY
					pixelsLastFlush += renderIncremental()
				end
			end

			if useEditableImage then
				flushPixelBuffer()
			end
		end
	end

	local function compactFramebuffer()
		if useEditableImage then
			print("compactFramebuffer: skipping (using EditableImage)")
			return
		end

		print("compacting framebuffer...")

		clearAllDrawFrames()
		table.clear(pixelFrames)
		pixelFrameCount = 0
		resetBatchedFrames()

		local visited = {}
		local function idx(x, y)
			return y * WIDTH + x + 1
		end

		for y = 0, HEIGHT - 1 do
			for x = 0, WIDTH - 1 do
				local i = idx(x, y)
				if not visited[i] then
					local color = fb.pixels[i] or fb.clearColor

					local w = 1
					while x + w < WIDTH do
						local ni = idx(x + w, y)
						if visited[ni] or (fb.pixels[ni] or fb.clearColor) ~= color then
							break
						end
						w += 1
					end

					local h = 1
					local ok = true
					while ok and y + h < HEIGHT do
						for dx = 0, w - 1 do
							local ni = idx(x + dx, y + h)
							if visited[ni] or (fb.pixels[ni] or fb.clearColor) ~= color then
								ok = false
								break
							end
						end
						if ok then
							h += 1
						end
					end

					for dy = 0, h - 1 do
						for dx = 0, w - 1 do
							visited[idx(x + dx, y + dy)] = true
						end
					end

					local frame = Instance.new("Frame")
					frame.BorderSizePixel = 0
					frame.BackgroundColor3 = color
					frame.Position = UDim2.fromOffset(x * PIXEL_SIZE, y * PIXEL_SIZE)
					frame.Size = UDim2.fromOffset(w * PIXEL_SIZE, h * PIXEL_SIZE)
					frame.Parent = drawLayer
					pixelFrameCount += 1
				end
			end
		end

		print("compaction done, ui frames:", pixelFrameCount)
	end

	initEditableImage()

	task.spawn(function()
		while true do
			local v = pixelsLastFlush
			task.wait(1)
			pixelsPerSecond = v
			pixelsLastFlush = 0
		end
	end)

	self.clearAllDrawFrames = clearAllDrawFrames
	self.resetFramebufferTables = resetFramebufferTables
	self.flushPixelBuffer = flushPixelBuffer
	self.clearPixelBuffer = clearPixelBuffer
	self.presentIfRequested = presentIfRequested
	self.compactFramebuffer = compactFramebuffer
	self.getEditableImages = function()
		return editableImages
	end
	self.getUseEditableImage = function()
		return useEditableImage
	end
	self.intToColor3 = intToColor3

	return self
end

return FramebufferPresenter
