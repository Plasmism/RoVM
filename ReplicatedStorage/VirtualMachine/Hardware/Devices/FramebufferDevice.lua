--!native
--flat framebuffer mmio. one address per pixel.
--very few moving parts = good
local bit32 = bit32
local FramebufferDevice = {}

local function intToColor3(rgb)
	local r = bit32.band(bit32.rshift(rgb, 16), 0xFF)
	local g = bit32.band(bit32.rshift(rgb, 8), 0xFF)
	local b = bit32.band(rgb, 0xFF)
	return Color3.fromRGB(r, g, b)
end

local function color3ToInt(c)
	local r = math.floor(c.R * 255 + 0.5)
	local g = math.floor(c.G * 255 + 0.5)
	local b = math.floor(c.B * 255 + 0.5)
	return bit32.lshift(r, 16) + bit32.lshift(g, 8) + b
end

--control regs sit on the side band next to the pixel range
local CTRL_CLEAR  = 0
local CTRL_FLUSH  = 1
local CTRL_REBOOT = 2
local CTRL_WIDTH  = 3
local CTRL_HEIGHT = 4

function FramebufferDevice.attach(mem, screen, PIX_BASE, CTRL_BASE)
	local w, h = screen.width, screen.height
	local pixelCount = w * h

	--real hardwareish reboot latch
	--probably leave alone !
	local rebootRequested = false

	--pixel window is linear memory; i = y*w + x
	mem:mapDevice(PIX_BASE, pixelCount,
		function(addr) --read
			local i = addr - PIX_BASE
			local x = i % w
			local y = math.floor(i / w)
			local c = screen.pixels[y * w + x + 1] or screen.clearColor
			return color3ToInt(c)
		end,
		function(addr, value) --write
			local i = addr - PIX_BASE
			local x = i % w
			local y = math.floor(i / w)
			screen:setPixel(x, y, intToColor3(value))
		end,
		true  --user mode can draw pixels
	)

	--small control window for clear, flush, reboot, and size reads
	mem:mapDevice(CTRL_BASE, 16,
		function(addr) --read
			local off = addr - CTRL_BASE
			if off == CTRL_WIDTH  then return w end
			if off == CTRL_HEIGHT then return h end
			if off == CTRL_REBOOT then
				return rebootRequested and 1 or 0
			end
			return 0
		end,
		function(addr, value) --write
			local off = addr - CTRL_BASE

			if off == CTRL_CLEAR then
				screen:clear(intToColor3(value))

			elseif off == CTRL_FLUSH then
				screen:markFlush()

			elseif off == CTRL_REBOOT then
				if value ~= 0 then
					rebootRequested = true
				end
			end
		end,
		true  -- user mode can poke ctrl regs too
	)

	--host side reads and clears the reboot latch here
	return {
		consumeReboot = function()
			if rebootRequested then
				rebootRequested = false
				return true
			end
			return false
		end
	}
end

return FramebufferDevice
