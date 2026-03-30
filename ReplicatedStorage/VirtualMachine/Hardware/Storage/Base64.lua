--!native
--base64 is here because datastores hate raw binary. very cool.
--it always finds a way into projects dont it?

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local LOOKUP = {}
for i = 1, 64 do
	LOOKUP[string.sub(ALPHABET, i, i)] = i - 1
end

function Base64.encode(str)
	local b = buffer.fromstring(str)
	local len = buffer.len(b)
	local outLen = math.ceil(len / 3) * 4
	local out = buffer.create(outLen)
	
	local i = 0
	local o = 0
	while i < len do
		local b1 = buffer.readu8(b, i)
		local b2 = i + 1 < len and buffer.readu8(b, i + 1) or 0
		local b3 = i + 2 < len and buffer.readu8(b, i + 2) or 0
		
		local n = bit32.bor(bit32.lshift(b1, 16), bit32.lshift(b2, 8), b3)
		
		buffer.writeu8(out, o, string.byte(ALPHABET, bit32.band(bit32.rshift(n, 18), 0x3F) + 1))
		buffer.writeu8(out, o + 1, string.byte(ALPHABET, bit32.band(bit32.rshift(n, 12), 0x3F) + 1))
		
		if i + 1 < len then
			buffer.writeu8(out, o + 2, string.byte(ALPHABET, bit32.band(bit32.rshift(n, 6), 0x3F) + 1))
		else
			buffer.writeu8(out, o + 2, 61) --padding
		end
		
		if i + 2 < len then
			buffer.writeu8(out, o + 3, string.byte(ALPHABET, bit32.band(n, 0x3F) + 1))
		else
			buffer.writeu8(out, o + 3, 61) --padding
		end
		
		i = i + 3
		o = o + 4
	end
	
	return buffer.tostring(out)
end

function Base64.decode(str)
	--copied blobs come back crusty sometimes, so strip whitespace first
	str = string.gsub(str, "[%s\n\r]", "")
	local len = #str
	if len == 0 then return "" end
	if len % 4 ~= 0 then return nil, "Invalid length" end
	
	local b = buffer.fromstring(str)
	local outMax = (len / 4) * 3
	local out = buffer.create(outMax)
	
	local i = 0
	local o = 0
	while i < len do
		local c1 = LOOKUP[string.char(buffer.readu8(b, i))]
		local c2 = LOOKUP[string.char(buffer.readu8(b, i + 1))]
		local c3Raw = buffer.readu8(b, i + 2)
		local c4Raw = buffer.readu8(b, i + 3)
		
		local c3 = c3Raw == 61 and 0 or LOOKUP[string.char(c3Raw)]
		local c4 = c4Raw == 61 and 0 or LOOKUP[string.char(c4Raw)]
		
		if not c1 or not c2 or not c3 or not c4 then
			return nil, "Invalid character"
		end
		
		local n = bit32.bor(
			bit32.lshift(c1, 18),
			bit32.lshift(c2, 12),
			bit32.lshift(c3, 6),
			c4
		)
		
		buffer.writeu8(out, o, bit32.band(bit32.rshift(n, 16), 0xFF))
		o = o + 1
		
		if c3Raw ~= 61 then
			buffer.writeu8(out, o, bit32.band(bit32.rshift(n, 8), 0xFF))
			o = o + 1
		end
		
		if c4Raw ~= 61 then
			buffer.writeu8(out, o, bit32.band(n, 0xFF))
			o = o + 1
		end
		
		i = i + 4
	end
	
	return string.sub(buffer.tostring(out), 1, o)
end

return Base64
