--!native
--byte addressed RAM!!!1!1
local Memory = {}
Memory.__index = Memory

local buffer_readu8 = buffer.readu8
local buffer_writeu8 = buffer.writeu8
local buffer_readu16 = buffer.readu16
local buffer_writeu16 = buffer.writeu16
local buffer_readu32 = buffer.readu32
local buffer_writeu32 = buffer.writeu32

function Memory.new(sizeInBytes)
	local self = setmetatable({}, Memory)
	self.size = sizeInBytes
	self.buf = buffer.create(sizeInBytes)
	self.devices = {} --{base,limit,onRead,onWrite}
	self.mode = "kernel"
	self.mmu = nil
	return self
end

function Memory:setMMU(mmu)
	self.mmu = mmu
end

function Memory:setMode(mode)
	if mode == 1 or mode == "user" then
		self.mode = "user"
	elseif mode == 0 or mode == "kernel" then
		self.mode = "kernel"
	else
		error("bad memory mode")
	end
	if self.mmu then
		self.mmu:setKernelMode(self.mode == "kernel")
	end
end

function Memory:mapDevice(baseAddr, length, onRead, onWrite, userAccessible)
	assert(type(baseAddr) == "number" and baseAddr >= 0, "bad baseAddr")
	assert(type(length) == "number" and length > 0, "bad length")

	self.devices[#self.devices + 1] = {
		base = baseAddr,
		limit = baseAddr + length - 1,
		onRead = onRead,
		onWrite = onWrite,
		userAccessible = userAccessible or false,
	}
end

local function findDevice(self, addr)
	for i = 1, #self.devices do
		local d = self.devices[i]
		if addr >= d.base and addr <= d.limit then
			return d
		end
	end
	return nil
end

--keep translation in one place or read, write, and exec start disagreeing and then it is my problem
local function translateAddr(self, addr, accessType)
	local physicalAddr = addr
	if self.mmu and self.mode == "user" then
		local fault, faultInfo
		physicalAddr, fault, faultInfo = self.mmu:translate(addr, accessType)
		if fault then
			if fault == "cow_fault" then
				local ok, err = self.mmu:handleCowFault(addr, self)
				if not ok then
					return nil, "cow_fault_handle_failed"
				end
				physicalAddr, fault, faultInfo = self.mmu:translate(addr, accessType)
				if fault then
					return nil, fault, faultInfo
				end
			else
				return nil, fault, faultInfo
			end
		end
		if physicalAddr == nil then
			return nil, "translate_returned_nil", {addr = addr, access = accessType}
		end
	end
	return physicalAddr, nil, nil
end

--4-byte little-endian read. plain, boring, good 🤑
function Memory:read(addr)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_read_denied"
		end
		if dev.onRead then
			local ok, v = pcall(dev.onRead, addr)
			if not ok then
				return nil, "device_read_error"
			end
			return v, nil
		end
		return 0, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "read")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr + 3 >= self.size then
		return nil, "ram_oob_read"
	end

	return buffer_readu32(self.buf, physicalAddr), nil
end

--exec fetch stays separate because strict execute mode gets picky
function Memory:readExec(addr)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_exec_denied"
		end
		if dev.onRead then
			local ok, v = pcall(dev.onRead, addr)
			if not ok then
				return nil, "device_read_error"
			end
			return v, nil
		end
		return 0, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "execute")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr + 3 >= self.size then
		return nil, "ram_oob_read"
	end

	return buffer_readu32(self.buf, physicalAddr), nil
end

--4-byte little-endian write. same deal.
function Memory:write(addr, value)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_write_denied"
		end
		if dev.onWrite then
			local ok = pcall(dev.onWrite, addr, value)
			if not ok then
				return nil, "device_write_error"
			end
		end
		return true, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "write")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr + 3 >= self.size then
		return nil, "ram_oob_write"
	end

	buffer_writeu32(self.buf, physicalAddr, value)
	return true, nil
end

--single-byte helper because libc keeps asking for one byte at a time
function Memory:readByte(addr)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_read_denied"
		end
		if dev.onRead then
			local ok, v = pcall(dev.onRead, addr)
			if not ok then return nil, "device_read_error" end
			return v, nil
		end
		return 0, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "read")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr >= self.size then
		return nil, "ram_oob_read"
	end

	return buffer_readu8(self.buf, physicalAddr), nil
end

function Memory:writeByte(addr, value)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_write_denied"
		end
		if dev.onWrite then
			local ok = pcall(dev.onWrite, addr, value)
			if not ok then return nil, "device_write_error" end
		end
		return true, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "write")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr >= self.size then
		return nil, "ram_oob_write"
	end

	buffer_writeu8(self.buf, physicalAddr, value)
	return true, nil
end

--2-byte read, zero extended on the way out
function Memory:readU16(addr)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_read_denied"
		end
		if dev.onRead then
			local ok, v = pcall(dev.onRead, addr)
			if not ok then return nil, "device_read_error" end
			return v, nil
		end
		return 0, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "read")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr + 1 >= self.size then
		return nil, "ram_oob_read"
	end

	return buffer_readu16(self.buf, physicalAddr), nil
end

--2-byte write. yep just 2 bytes. smoll little guy
function Memory:writeU16(addr, value)
	assert(type(addr) == "number", "addr must be number")

	local dev = findDevice(self, addr)
	if dev then
		if self.mode == "user" and not dev.userAccessible then
			return nil, "mmio_write_denied"
		end
		if dev.onWrite then
			local ok = pcall(dev.onWrite, addr, value)
			if not ok then return nil, "device_write_error" end
		end
		return true, nil
	end

	local physicalAddr, fault, faultInfo = translateAddr(self, addr, "write")
	if fault then return nil, fault, faultInfo end

	if physicalAddr < 0 or physicalAddr + 1 >= self.size then
		return nil, "ram_oob_write"
	end

	buffer_writeu16(self.buf, physicalAddr, value)
	return true, nil
end

return Memory
