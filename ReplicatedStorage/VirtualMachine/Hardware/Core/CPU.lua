--!native
--byte-addressed cpu. pc still walks in 4-byte steps unless a wide op drags an extra word behind it.
local bit32 = bit32

local buffer_readu8 = buffer.readu8
local buffer_writeu8 = buffer.writeu8
local buffer_readu16 = buffer.readu16
local buffer_writeu16 = buffer.writeu16
local buffer_readu32 = buffer.readu32
local buffer_writeu32 = buffer.writeu32

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift
local arshift = bit32.arshift

local CPU = {}
CPU.__index = CPU

CPU.MODE_KERNEL = 0
CPU.MODE_USER = 1

local REG_COUNT = 16
local CTRL_FLUSH_ADDR = 0x200001
local SP_REG = 15
local FAST_USER_RAM_LIMIT = 0x100000

local DEBUG = false
local DEBUG_EVERY = 500
local DEBUG_MAX = 200
local debugCounter = 0
local debugPrinted = 0
local BREAK_PC = nil

local DEBUG_OPS = {
	[0x01] = true, --halt
	[0x06] = true, --jmp
	[0x07] = true, --jz
	[0x20] = true, --flush
	[0x22] = true, --call
	[0x23] = true, --ret
	[0x26] = true, --callr
	[0x30] = true, --syscall
}

local WIDE_OPCODE = {
	[0x06] = true, --jmp
	[0x07] = true, --jz
	[0x08] = true, --loadi
	[0x16] = true, --addi
	[0x17] = true, --subi
	[0x18] = true, --muli
	[0x19] = true, --andi
	[0x1A] = true, --ori
	[0x1B] = true, --xori
	[0x1C] = true, --jnz
	[0x22] = true, --call
}

local function normalizeMode(mode)
	if mode == CPU.MODE_USER or mode == "user" then
		return CPU.MODE_USER
	end
	return CPU.MODE_KERNEL
end

local function isUserMode(mode)
	return normalizeMode(mode) == CPU.MODE_USER
end

local function modeName(mode)
	return isUserMode(mode) and "user" or "kernel"
end

local function signed32(v)
	if v >= 0x80000000 then
		return v - 0x100000000
	end
	return v
end

local function signExtend16(v)
	if v >= 0x8000 then
		return v - 0x10000
	end
	return v
end

local function dumpRegs(reg)
	local t = {}
	for i = 1, #reg do
		t[#t + 1] = ("r%d=%d"):format(i - 1, reg[i])
	end
	return table.concat(t, " ")
end

function CPU:setDebug(on)
	DEBUG = on
	debugCounter = 0
	debugPrinted = 0
end

function CPU:setBreakPC(pc)
	BREAK_PC = pc
end

--all stop/fault bookkeeping funnels through here so opcode handlers can fail without spamming
local function setTrap(self, kind, info, pc)
	local trapInfo = { kind = kind, pc = pc or self.pc }
	if type(info) == "table" then
		for k, v in pairs(info) do
			trapInfo[k] = v
		end
	else
		trapInfo.msg = info
	end
	self.trap = trapInfo
	if kind ~= "syscall" and kind ~= "yield" then
		self.running = false
	end
end

local function trapUserFault(self, faultType, addr, access, extraMsg, pc)
	local trapInfo = {
		type = faultType,
		addr = addr,
		access = access,
	}

	if type(extraMsg) == "table" then
		for k, v in pairs(extraMsg) do
			trapInfo[k] = v
		end
		if not trapInfo.msg then
			trapInfo.msg = (("%s (%s) @ 0x%X"):format(tostring(faultType), tostring(access), addr or 0))
		end
	else
		trapInfo.msg = extraMsg or (("%s (%s) @ 0x%X"):format(tostring(faultType), tostring(access), addr or 0))
	end

	setTrap(self, "fault", trapInfo, pc)
end

local function trapKernelPanic(self, faultType, addr, access, extraMsg, pc)
	setTrap(self, "panic", {
		type = faultType,
		addr = addr,
		access = access,
		msg = extraMsg or (("KERNEL: %s (%s) @ 0x%X"):format(tostring(faultType), tostring(access), addr or 0)),
	}, pc)
end

local function raiseFault(self, mode, faultType, addr, access, extraMsg, pc)
	if mode == CPU.MODE_USER then
		trapUserFault(self, faultType, addr, access, extraMsg, pc)
	else
		trapKernelPanic(self, faultType, addr, access, extraMsg, pc)
	end
end

--slow helpers keep the fully checked path around for step, debug, and mmio
--the hot loop skips them on plain user ram because a million tiny calls is not too good i think
local function memReadSlow(self, addr, access, pc)
	local v, f, faultInfo = self.mem:read(addr)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "read", faultInfo, pc)
		return 0, true
	end
	return v, false
end

local function memReadExecSlow(self, addr, access, pc)
	local reader = self.strictExecute and self.mem.readExec or self.mem.read
	local v, f, faultInfo = reader(self.mem, addr)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "execute", faultInfo, pc)
		return 0, true
	end
	return v, false
end

local function memWriteSlow(self, addr, value, access, pc)
	local ok, f, faultInfo = self.mem:write(addr, value)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "write", faultInfo, pc)
		return false, true
	end
	return ok, false
end

local function memReadByteSlow(self, addr, access, pc)
	local v, f, faultInfo = self.mem:readByte(addr)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "read", faultInfo, pc)
		return 0, true
	end
	return v, false
end

local function memWriteByteSlow(self, addr, value, access, pc)
	local ok, f, faultInfo = self.mem:writeByte(addr, value)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "write", faultInfo, pc)
		return false, true
	end
	return ok, false
end

local function memReadU16Slow(self, addr, access, pc)
	local v, f, faultInfo = self.mem:readU16(addr)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "read", faultInfo, pc)
		return 0, true
	end
	return v, false
end

local function memWriteU16Slow(self, addr, value, access, pc)
	local ok, f, faultInfo = self.mem:writeU16(addr, value)
	if f then
		raiseFault(self, normalizeMode(self.mode), f, addr, access or "write", faultInfo, pc)
		return false, true
	end
	return ok, false
end

local function stackFault(self, msg, pc)
	if isUserMode(self.mode) then
		setTrap(self, "fault", { type = "stack_fault", msg = msg, sp = self.reg[SP_REG + 1] }, pc)
	else
		setTrap(self, "panic", { type = "stack_fault", msg = msg, sp = self.reg[SP_REG + 1] }, pc)
	end
end

--plain dispatch table on purpose
--ive tried fancy stuff before; wasnt pretty
local OPCODES = {}

OPCODES[0x00] = function(self)
	self.pc += 4
end

OPCODES[0x01] = function(self)
	if isUserMode(self.mode) then
		setTrap(self, "fault", {
			type = "privileged_instruction",
			instruction = "HALT",
			msg = ("privileged instruction HALT executed in user mode @ pc 0x%X"):format(self.pc),
		})
		return
	end
	local nextPc = self.pc + 4
	setTrap(self, "halt", "HALT", self.pc)
	self.pc = nextPc
end

OPCODES[0x02] = function(self, d, a)
	local addr = self.reg[a + 1]
	local v, bad = memReadSlow(self, addr, "LOAD", self.pc)
	if bad then return end
	self.reg[d + 1] = v
	self.pc += 4
end

OPCODES[0x03] = function(self, d, a)
	local addr = self.reg[d + 1]
	local _, bad = memWriteSlow(self, addr, self.reg[a + 1], "STORE", self.pc)
	if bad then return end
	self.pc += 4
end

OPCODES[0x04] = function(self, d, a, b)
	self.reg[d + 1] = band(self.reg[a + 1] + self.reg[b + 1], 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x05] = function(self, d, a, b)
	self.reg[d + 1] = band(self.reg[a + 1] - self.reg[b + 1], 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x06] = function(self)
	local tgt, bad = memReadSlow(self, self.pc + 4, "JMP_IMM", self.pc)
	if bad then return end
	self.pc = tgt
end

OPCODES[0x07] = function(self, d)
	local tgt, bad = memReadSlow(self, self.pc + 4, "JZ_IMM", self.pc)
	if bad then return end
	if self.reg[d + 1] == 0 then
		self.pc = tgt
	else
		self.pc += 8
	end
end

OPCODES[0x08] = function(self, d)
	local imm, bad = memReadSlow(self, self.pc + 4, "LOADI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = band(imm, 0xFFFFFFFF)
	self.pc += 8
end

OPCODES[0x09] = function(self, d, a, b)
	self.reg[d + 1] = band(self.reg[a + 1] * self.reg[b + 1], 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x0A] = function(self, d, a, b)
	local divisor = self.reg[b + 1]
	if divisor == 0 then
		self.reg[d + 1] = 0
	else
		local result = signed32(self.reg[a + 1]) / signed32(divisor)
		result = (result >= 0) and math.floor(result) or math.ceil(result)
		self.reg[d + 1] = band(result, 0xFFFFFFFF)
	end
	self.pc += 4
end

OPCODES[0x0B] = function(self, d, a, b)
	local divisor = self.reg[b + 1]
	if divisor == 0 then
		self.reg[d + 1] = 0
	else
		local va = signed32(self.reg[a + 1])
		local vb = signed32(divisor)
		local div = va / vb
		div = (div >= 0) and math.floor(div) or math.ceil(div)
		self.reg[d + 1] = band(va - div * vb, 0xFFFFFFFF)
	end
	self.pc += 4
end

OPCODES[0x0C] = function(self, d, a, b)
	self.reg[d + 1] = band(self.reg[a + 1], self.reg[b + 1])
	self.pc += 4
end

OPCODES[0x0D] = function(self, d, a, b)
	self.reg[d + 1] = bor(self.reg[a + 1], self.reg[b + 1])
	self.pc += 4
end

OPCODES[0x0E] = function(self, d, a, b)
	self.reg[d + 1] = bxor(self.reg[a + 1], self.reg[b + 1])
	self.pc += 4
end

OPCODES[0x0F] = function(self, d, a)
	self.reg[d + 1] = bnot(self.reg[a + 1])
	self.pc += 4
end

OPCODES[0x10] = function(self, d, a, b)
	self.reg[d + 1] = lshift(self.reg[a + 1], self.reg[b + 1])
	self.pc += 4
end

OPCODES[0x11] = function(self, d, a, b)
	self.reg[d + 1] = rshift(self.reg[a + 1], self.reg[b + 1])
	self.pc += 4
end

OPCODES[0x12] = function(self, d, a)
	self.reg[d + 1] = self.reg[a + 1]
	self.pc += 4
end

OPCODES[0x13] = function(self, d, a, b)
	self.reg[d + 1] = (self.reg[a + 1] == self.reg[b + 1]) and 1 or 0
	self.pc += 4
end

OPCODES[0x14] = function(self, d, a, b)
	self.reg[d + 1] = (signed32(self.reg[a + 1]) < signed32(self.reg[b + 1])) and 1 or 0
	self.pc += 4
end

OPCODES[0x15] = function(self, d, a, b)
	self.reg[d + 1] = (signed32(self.reg[a + 1]) > signed32(self.reg[b + 1])) and 1 or 0
	self.pc += 4
end

OPCODES[0x16] = function(self, d, a)
	local imm, bad = memReadSlow(self, self.pc + 4, "ADDI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = band(self.reg[a + 1] + band(imm, 0xFFFFFFFF), 0xFFFFFFFF)
	self.pc += 8
end

OPCODES[0x17] = function(self, d, a)
	local imm, bad = memReadSlow(self, self.pc + 4, "SUBI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = band(self.reg[a + 1] - band(imm, 0xFFFFFFFF), 0xFFFFFFFF)
	self.pc += 8
end

OPCODES[0x18] = function(self, d, a)
	local imm, bad = memReadSlow(self, self.pc + 4, "MULI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = band(self.reg[a + 1] * band(imm, 0xFFFFFFFF), 0xFFFFFFFF)
	self.pc += 8
end

OPCODES[0x19] = function(self, d, a)
	local imm, bad = memReadSlow(self, self.pc + 4, "ANDI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = band(self.reg[a + 1], band(imm, 0xFFFFFFFF))
	self.pc += 8
end

OPCODES[0x1A] = function(self, d, a)
	local imm, bad = memReadSlow(self, self.pc + 4, "ORI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = bor(self.reg[a + 1], band(imm, 0xFFFFFFFF))
	self.pc += 8
end

OPCODES[0x1B] = function(self, d, a)
	local imm, bad = memReadSlow(self, self.pc + 4, "XORI_IMM", self.pc)
	if bad then return end
	self.reg[d + 1] = bxor(self.reg[a + 1], band(imm, 0xFFFFFFFF))
	self.pc += 8
end

OPCODES[0x1C] = function(self, d)
	local tgt, bad = memReadSlow(self, self.pc + 4, "JNZ_IMM", self.pc)
	if bad then return end
	if self.reg[d + 1] ~= 0 then
		self.pc = tgt
	else
		self.pc += 8
	end
end

OPCODES[0x1D] = function(self, d, a, b)
	self.reg[d + 1] = arshift(self.reg[a + 1], self.reg[b + 1])
	self.pc += 4
end

OPCODES[0x20] = function(self)
	if isUserMode(self.mode) then
		setTrap(self, "fault", {
			type = "privileged_instruction",
			instruction = "FLUSH",
			msg = ("privileged instruction FLUSH executed in user mode @ pc 0x%X"):format(self.pc),
		})
		return
	end
	local _, bad = memWriteSlow(self, CTRL_FLUSH_ADDR, 1, "FLUSH_MMIO", self.pc)
	if bad then return end
	self.pc += 4
end

OPCODES[0x21] = function(self)
	self.pc += 4
	self.trap = {
		kind = "yield",
		reason = "sleep",
		pc = self.pc,
	}
end

OPCODES[0x22] = function(self)
	local tgt, bad = memReadSlow(self, self.pc + 4, "CALL_IMM", self.pc)
	if bad then return end
	local spIndex = SP_REG + 1
	local sp = self.reg[spIndex] - 4
	if sp < 0 then
		stackFault(self, ("stack underflow on CALL @ pc 0x%X"):format(self.pc), self.pc)
		return
	end
	local _, bad2 = memWriteSlow(self, sp, self.pc + 8, "CALL_PUSH_RET", self.pc)
	if bad2 then return end
	self.reg[spIndex] = sp
	self.pc = tgt
end

OPCODES[0x23] = function(self)
	local spIndex = SP_REG + 1
	local sp = self.reg[spIndex]
	local ret, bad = memReadSlow(self, sp, "RET_POP", self.pc)
	if bad then return end
	self.reg[spIndex] = sp + 4
	self.pc = ret
end

OPCODES[0x24] = function(self, d, a)
	local sp = self.reg[a + 1] - 4
	if sp < 0 then
		stackFault(self, ("stack underflow on PUSH @ pc 0x%X"):format(self.pc), self.pc)
		return
	end
	local _, bad = memWriteSlow(self, sp, self.reg[d + 1], "PUSH_STORE", self.pc)
	if bad then return end
	self.reg[a + 1] = sp
	self.pc += 4
end

OPCODES[0x25] = function(self, d, a)
	local sp = self.reg[a + 1]
	local v, bad = memReadSlow(self, sp, "POP_LOAD", self.pc)
	if bad then return end
	self.reg[d + 1] = v
	self.reg[a + 1] = sp + 4
	self.pc += 4
end

OPCODES[0x26] = function(self, d)
	local tgt = self.reg[d + 1]
	local spIndex = SP_REG + 1
	local sp = self.reg[spIndex] - 4
	if sp < 0 then
		stackFault(self, ("stack underflow on CALLR @ pc 0x%X"):format(self.pc), self.pc)
		return
	end
	local _, bad = memWriteSlow(self, sp, self.pc + 4, "CALLR_PUSH_RET", self.pc)
	if bad then return end
	self.reg[spIndex] = sp
	self.pc = tgt
end

OPCODES[0x27] = function(self, d, a)
	local v, bad = memReadByteSlow(self, self.reg[a + 1], "LOADB", self.pc)
	if bad then return end
	self.reg[d + 1] = v
	self.pc += 4
end

OPCODES[0x28] = function(self, d, a)
	local _, bad = memWriteByteSlow(self, self.reg[d + 1], band(self.reg[a + 1], 0xFF), "STOREB", self.pc)
	if bad then return end
	self.pc += 4
end

OPCODES[0x29] = function(self, d, a)
	local v, bad = memReadU16Slow(self, self.reg[a + 1], "LOADH", self.pc)
	if bad then return end
	self.reg[d + 1] = v
	self.pc += 4
end

OPCODES[0x2A] = function(self, d, a)
	local _, bad = memWriteU16Slow(self, self.reg[d + 1], band(self.reg[a + 1], 0xFFFF), "STOREH", self.pc)
	if bad then return end
	self.pc += 4
end

OPCODES[0x2B] = function(self, d, a)
	local v, bad = memReadByteSlow(self, self.reg[a + 1], "LOADBS", self.pc)
	if bad then return end
	if v >= 0x80 then
		v = v + 0xFFFFFF00
	end
	self.reg[d + 1] = v
	self.pc += 4
end

OPCODES[0x2C] = function(self, d, a)
	local v, bad = memReadU16Slow(self, self.reg[a + 1], "LOADHS", self.pc)
	if bad then return end
	if v >= 0x8000 then
		v = v + 0xFFFF0000
	end
	self.reg[d + 1] = v
	self.pc += 4
end

OPCODES[0x30] = function(self, _, _, b)
	self.trap = {
		kind = "syscall",
		n = b,
		pc = self.pc,
	}
	self.pc += 4
end

OPCODES[0x31] = function(self, d)
	self.reg[d + 1] = self.pc
	self.pc += 4
end

OPCODES[0x32] = function(self, d, a, b)
	self.reg[d + 1] = band(signExtend16(lshift(a, 8) + b), 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x33] = function(self, d, a, b)
	self.reg[d + 1] = band(self.reg[d + 1] + signExtend16(lshift(a, 8) + b), 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x34] = function(self, d, a, b)
	self.reg[d + 1] = band(self.reg[d + 1] - signExtend16(lshift(a, 8) + b), 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x35] = function(self, _, a, b)
	self.pc = band(self.pc + 4 + signExtend16(lshift(a, 8) + b), 0xFFFFFFFF)
end

OPCODES[0x36] = function(self, d, a, b)
	if self.reg[d + 1] == 0 then
		self.pc = band(self.pc + 4 + signExtend16(lshift(a, 8) + b), 0xFFFFFFFF)
	else
		self.pc += 4
	end
end

OPCODES[0x37] = function(self, d, a, b)
	if self.reg[d + 1] ~= 0 then
		self.pc = band(self.pc + 4 + signExtend16(lshift(a, 8) + b), 0xFFFFFFFF)
	else
		self.pc += 4
	end
end

OPCODES[0x38] = function(self, d)
	self.reg[d + 1] = band(self.reg[d + 1] + 1, 0xFFFFFFFF)
	self.pc += 4
end

OPCODES[0x39] = function(self, d)
	self.reg[d + 1] = band(self.reg[d + 1] - 1, 0xFFFFFFFF)
	self.pc += 4
end

function CPU.new(memory)
	local self = setmetatable({}, CPU)
	self.mem = memory
	self.reg = table.create(REG_COUNT, 0)
	self.pc = 0
	self.running = true
	self.trap = nil
	self.mode = CPU.MODE_KERNEL
	self.strictExecute = false
	self.fastUserRamLimit = math.min(FAST_USER_RAM_LIMIT, memory.size or FAST_USER_RAM_LIMIT)
	self.decodeSegments = {}
	return self
end

function CPU:setDecodeSegments(segments)
	self.decodeSegments = segments or {}
end

function CPU:addDecodeSegment(segment)
	local segments = self.decodeSegments
	segments[#segments + 1] = segment
end

function CPU:clearDecodeSegments()
	self.decodeSegments = {}
end

--single step path stays readable for debug
--same rules as the hot loop
function CPU:step()
	self.mode = normalizeMode(self.mode)
	if DEBUG and BREAK_PC and self.pc == BREAK_PC then
		print("=== BREAK @ PC", self.pc, "===")
		print(dumpRegs(self.reg))
		self.running = false
		return
	end

	local instr, bad = memReadExecSlow(self, self.pc, "FETCH", self.pc)
	if bad then return end

	local opcode = rshift(instr, 24)
	local d = band(rshift(instr, 16), 0xFF)
	local a = band(rshift(instr, 8), 0xFF)
	local b = band(instr, 0xFF)

	if DEBUG and DEBUG_OPS[opcode] then
		debugCounter += 1
		if debugCounter % DEBUG_EVERY == 0 and debugPrinted < DEBUG_MAX then
			print(("[pc=0x%X] op=0x%02X | %s"):format(self.pc, opcode, dumpRegs(self.reg)))
			debugPrinted += 1
		end
	end

	local fn = OPCODES[opcode]
	if not fn then
		raiseFault(self, self.mode, "invalid_opcode", self.pc, "execute", ("invalid opcode %d @ pc 0x%X"):format(opcode, self.pc), self.pc)
		return
	end

	fn(self, d, a, b)
end

--pc - seg.base is bytes, /4 turns that into slots, +1 pays lua's indexing tax
--decoded entries still live on 4-byte boundaries even when the real instruction later eats 8
local function findDecodedInstruction(segments, pc)
	for i = 1, #segments do
		local seg = segments[i]
		if pc >= seg.base and pc < seg.limit then
			local idx = ((pc - seg.base) / 4) + 1
			local entry = seg.entries[idx]
			return entry, seg
		end
	end
	return nil, nil
end

--hot loop: TLB-accelerated, cached decode segments, minimal overhead
function CPU:runSlice(max)
	max = max or 1_000_000
	if not self.running then
		return 0
	end

	local mem = self.mem
	local mmu = mem.mmu
	local memBuf = mem.buf
	local memSize = mem.size
	local reg = self.reg
	local pc = self.pc
	local mode = normalizeMode(self.mode)
	local running = self.running
	local fastUserRamLimit = self.fastUserRamLimit or FAST_USER_RAM_LIMIT
	local strictExecute = self.strictExecute
	local decodeSegments = self.decodeSegments or {}
	local steps = 0
	local trapInfo = self.trap

	--TLB arrays pulled into locals for maximum speed
	local hasTLB = (mmu ~= nil and mode == CPU.MODE_USER)
	local tlbVPages = hasTLB and mmu.tlbVPages or nil
	local tlbPPages = hasTLB and mmu.tlbPPages or nil
	local tlbPerms  = hasTLB and mmu.tlbPerms or nil
	local tlbMask   = hasTLB and mmu.tlbMask or 0
	local PAGE_SHIFT = 12
	local PAGE_MASK  = 0xFFF
	--permission bitmask constants matching PageTable.PERM_*
	local PERM_READ_BIT  = 1  --PageTable.PERM_READ
	local PERM_WRITE_BIT = 2  --PageTable.PERM_WRITE
	local PERM_EXEC_BIT  = 4  --PageTable.PERM_EXEC
	local PERM_COW_BIT   = 8  --PageTable.PERM_COW

	--cached decode segment: avoids per-instruction linear scan
	local cachedSeg = nil
	local cachedSegBase = 0
	local cachedSegLimit = 0
	local cachedSegEntries = nil

	local function setTrapLocal(kind, info, trapPc, stopRunning)
		local t = { kind = kind, pc = trapPc or pc }
		if type(info) == "table" then
			for k, v in pairs(info) do
				t[k] = v
			end
		else
			t.msg = info
		end
		trapInfo = t
		if stopRunning ~= false then
			running = false
		end
	end

	local function raiseFaultLocal(faultType, addr, access, extraMsg, trapPc)
		if mode == CPU.MODE_USER then
			local t = {
				type = faultType,
				addr = addr,
				access = access,
			}
			if type(extraMsg) == "table" then
				for k, v in pairs(extraMsg) do
					t[k] = v
				end
				if not t.msg then
					t.msg = (("%s (%s) @ 0x%X"):format(tostring(faultType), tostring(access), addr or 0))
				end
			else
				t.msg = extraMsg or (("%s (%s) @ 0x%X"):format(tostring(faultType), tostring(access), addr or 0))
			end
			setTrapLocal("fault", t, trapPc)
		else
			setTrapLocal("panic", {
				type = faultType,
				addr = addr,
				access = access,
				msg = extraMsg or (("KERNEL: %s (%s) @ 0x%X"):format(tostring(faultType), tostring(access), addr or 0)),
			}, trapPc)
		end
	end

	--full translate path (TLB miss, or kernel mode).
	--accessType is a string ("read", "write", "execute") for the MMU fault system.
	local function translateUserSlow(addr, accessType)
		if mmu then
			local phys, fault, faultInfo = mmu:translate(addr, accessType)
			if fault then
				if fault == "cow_fault" then
					local ok, err = mmu:handleCowFault(addr, mem)
					if not ok then
						raiseFaultLocal("cow_fault_handle_failed", addr, accessType, err or "cow fault handler failed", pc)
						return nil
					end
					--TLB was invalidated in-place by invalidateTLBPage; the local array
					--references are still valid since tables are mutated, not replaced.
					--The next translate() below will repopulate the slot with the new mapping.
					phys, fault, faultInfo = mmu:translate(addr, accessType)
				end
				if fault then
					raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
					return nil
				end
			end
			if phys == nil then
				raiseFaultLocal("translate_returned_nil", addr, accessType, { addr = addr, access = accessType }, pc)
				return nil
			end
			return phys
		end
		return addr
	end

	--TLB-accelerated translateUser: tries TLB first, falls back to slow path.
	--accessPerm is the PageTable permission bit required: PERM_READ_BIT, PERM_WRITE_BIT, or PERM_EXEC_BIT.
	--Using a numeric bit lets the TLB check the correct permission without string comparisons.
	local function translateUser(addr, accessPerm)
		if hasTLB then
			local vpage = rshift(addr, PAGE_SHIFT)
			local slot = band(vpage, tlbMask) + 1
			if tlbVPages[slot] == vpage then
				local perms = tlbPerms[slot]
				--write to a COW page must resolve the fault first
				if accessPerm == PERM_WRITE_BIT and band(perms, PERM_COW_BIT) ~= 0 then
					return translateUserSlow(addr, "write")
				end
				--check the specific permission bit (READ, WRITE, or EXEC)
				if band(perms, accessPerm) == 0 then
					local accessStr = accessPerm == PERM_WRITE_BIT and "write"
						or accessPerm == PERM_EXEC_BIT and "execute"
						or "read"
					return translateUserSlow(addr, accessStr)
				end
				return tlbPPages[slot] * 4096 + band(addr, PAGE_MASK)
			end
			--TLB miss: fall through to full translate
			local accessStr = accessPerm == PERM_WRITE_BIT and "write"
				or accessPerm == PERM_EXEC_BIT and "execute"
				or "read"
			return translateUserSlow(addr, accessStr)
		end
		local accessStr = accessPerm == PERM_WRITE_BIT and "write"
			or accessPerm == PERM_EXEC_BIT and "execute"
			or "read"
		return translateUserSlow(addr, accessStr)
	end

	local function readWord(addr, accessType)
		if mode == CPU.MODE_USER and addr >= 0 and addr + 3 < fastUserRamLimit then
			--instruction fetch checks EXEC permission; data reads check READ permission
			local perm = (accessType == "execute" and strictExecute) and PERM_EXEC_BIT or PERM_READ_BIT
			local phys = translateUser(addr, perm)
			if phys == nil then return 0, true end
			if phys < 0 or phys + 3 >= memSize then
				raiseFaultLocal("ram_oob_read", addr, accessType or "read", nil, pc)
				return 0, true
			end
			return buffer_readu32(memBuf, phys), false
		end

		local reader = (accessType == "execute" and strictExecute) and mem.readExec or mem.read
		local value, fault, faultInfo = reader(mem, addr)
		if fault then
			raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
			return 0, true
		end
		return value, false
	end

	local function writeWord(addr, value, accessType)
		if mode == CPU.MODE_USER and addr >= 0 and addr + 3 < fastUserRamLimit then
			local phys = translateUser(addr, PERM_WRITE_BIT)
			if phys == nil then return true end
			if phys < 0 or phys + 3 >= memSize then
				raiseFaultLocal("ram_oob_write", addr, accessType or "write", nil, pc)
				return true
			end
			buffer_writeu32(memBuf, phys, value)
			return false
		end

		local _, fault, faultInfo = mem:write(addr, value)
		if fault then
			raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
			return true
		end
		return false
	end

	local function readByte(addr, accessType)
		if mode == CPU.MODE_USER and addr >= 0 and addr < fastUserRamLimit then
			local phys = translateUser(addr, PERM_READ_BIT)
			if phys == nil then return 0, true end
			if phys < 0 or phys >= memSize then
				raiseFaultLocal("ram_oob_read", addr, accessType or "read", nil, pc)
				return 0, true
			end
			return buffer_readu8(memBuf, phys), false
		end

		local value, fault, faultInfo = mem:readByte(addr)
		if fault then
			raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
			return 0, true
		end
		return value, false
	end

	local function writeByte(addr, value, accessType)
		if mode == CPU.MODE_USER and addr >= 0 and addr < fastUserRamLimit then
			local phys = translateUser(addr, PERM_WRITE_BIT)
			if phys == nil then return true end
			if phys < 0 or phys >= memSize then
				raiseFaultLocal("ram_oob_write", addr, accessType or "write", nil, pc)
				return true
			end
			buffer_writeu8(memBuf, phys, value)
			return false
		end

		local _, fault, faultInfo = mem:writeByte(addr, value)
		if fault then
			raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
			return true
		end
		return false
	end

	local function readU16(addr, accessType)
		if mode == CPU.MODE_USER and addr >= 0 and addr + 1 < fastUserRamLimit then
			local phys = translateUser(addr, PERM_READ_BIT)
			if phys == nil then return 0, true end
			if phys < 0 or phys + 1 >= memSize then
				raiseFaultLocal("ram_oob_read", addr, accessType or "read", nil, pc)
				return 0, true
			end
			return buffer_readu16(memBuf, phys), false
		end

		local value, fault, faultInfo = mem:readU16(addr)
		if fault then
			raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
			return 0, true
		end
		return value, false
	end

	local function writeU16(addr, value, accessType)
		if mode == CPU.MODE_USER and addr >= 0 and addr + 1 < fastUserRamLimit then
			local phys = translateUser(addr, PERM_WRITE_BIT)
			if phys == nil then return true end
			if phys < 0 or phys + 1 >= memSize then
				raiseFaultLocal("ram_oob_write", addr, accessType or "write", nil, pc)
				return true
			end
			buffer_writeu16(memBuf, phys, value)
			return false
		end

		local _, fault, faultInfo = mem:writeU16(addr, value)
		if fault then
			raiseFaultLocal(fault, addr, accessType, faultInfo, pc)
			return true
		end
		return false
	end

	--each turn is fetch, decode, maybe grab the immediate, then badabam badabap
	while running and steps < max and not trapInfo do
		local opcode
		local d
		local a
		local b
		local imm
		local size

		--try cached segment first to avoid linear scan on every instruction
		local decoded
		if pc >= cachedSegBase and pc < cachedSegLimit then
			local idx = rshift(pc - cachedSegBase, 2) + 1
			decoded = cachedSegEntries[idx]
			if not decoded then
				raiseFaultLocal("invalid_opcode", pc, "execute", ("invalid instruction boundary @ pc 0x%X"):format(pc), pc)
				break
			end
			opcode = decoded.opcode
			d = decoded.d or 0
			a = decoded.a or 0
			b = decoded.b or 0
			imm = decoded.imm
			size = decoded.size or 4
		else
			--segment miss: scan for matching segment and cache it
			local seg = nil
			for i = 1, #decodeSegments do
				local s = decodeSegments[i]
				if pc >= s.base and pc < s.limit then
					seg = s
					break
				end
			end
			if seg ~= nil then
				cachedSeg = seg
				cachedSegBase = seg.base
				cachedSegLimit = seg.limit
				cachedSegEntries = seg.entries
				local idx = rshift(pc - cachedSegBase, 2) + 1
				decoded = cachedSegEntries[idx]
				if not decoded then
					raiseFaultLocal("invalid_opcode", pc, "execute", ("invalid instruction boundary @ pc 0x%X"):format(pc), pc)
					break
				end
				opcode = decoded.opcode
				d = decoded.d or 0
				a = decoded.a or 0
				b = decoded.b or 0
				imm = decoded.imm
				size = decoded.size or 4
			else
				decoded = nil
				--raw path reads the opcode word and, for wide ops, the second word behind it
				local instr, bad = readWord(pc, strictExecute and "execute" or "read")
				if bad then break end
				opcode = rshift(instr, 24)
				d = band(rshift(instr, 16), 0xFF)
				a = band(rshift(instr, 8), 0xFF)
				b = band(instr, 0xFF)
				size = WIDE_OPCODE[opcode] and 8 or 4
				if WIDE_OPCODE[opcode] then
					local nextImm, immBad = readWord(pc + 4, "read")
					if immBad then break end
					imm = nextImm
				elseif opcode >= 0x32 and opcode <= 0x37 then
					imm = signExtend16(lshift(a, 8) + b)
				end
			end
		end

		if opcode == 0x00 then
			pc += 4

		elseif opcode == 0x01 then
			if mode == CPU.MODE_USER then
				setTrapLocal("fault", {
					type = "privileged_instruction",
					instruction = "HALT",
					msg = ("privileged instruction HALT executed in user mode @ pc 0x%X"):format(pc),
				}, pc)
			else
				local nextPc = pc + 4
				setTrapLocal("halt", "HALT", pc)
				pc = nextPc
			end

		elseif opcode == 0x02 then
			local value, bad = readWord(reg[a + 1], "read")
			if bad then break end
			reg[d + 1] = value
			pc += 4

		elseif opcode == 0x03 then
			if writeWord(reg[d + 1], reg[a + 1], "write") then break end
			pc += 4

		elseif opcode == 0x04 then
			reg[d + 1] = band(reg[a + 1] + reg[b + 1], 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x05 then
			reg[d + 1] = band(reg[a + 1] - reg[b + 1], 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x06 then
			pc = imm

		elseif opcode == 0x07 then
			if reg[d + 1] == 0 then
				pc = imm
			else
				pc += size
			end

		elseif opcode == 0x08 then
			reg[d + 1] = band(imm, 0xFFFFFFFF)
			pc += size

		elseif opcode == 0x09 then
			reg[d + 1] = band(reg[a + 1] * reg[b + 1], 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x0A then
			local divisor = reg[b + 1]
			if divisor == 0 then
				reg[d + 1] = 0
			else
				local result = signed32(reg[a + 1]) / signed32(divisor)
				result = (result >= 0) and math.floor(result) or math.ceil(result)
				reg[d + 1] = band(result, 0xFFFFFFFF)
			end
			pc += 4

		elseif opcode == 0x0B then
			local divisor = reg[b + 1]
			if divisor == 0 then
				reg[d + 1] = 0
			else
				local va = signed32(reg[a + 1])
				local vb = signed32(divisor)
				local div = va / vb
				div = (div >= 0) and math.floor(div) or math.ceil(div)
				reg[d + 1] = band(va - div * vb, 0xFFFFFFFF)
			end
			pc += 4

		elseif opcode == 0x0C then
			reg[d + 1] = band(reg[a + 1], reg[b + 1])
			pc += 4

		elseif opcode == 0x0D then
			reg[d + 1] = bor(reg[a + 1], reg[b + 1])
			pc += 4

		elseif opcode == 0x0E then
			reg[d + 1] = bxor(reg[a + 1], reg[b + 1])
			pc += 4

		elseif opcode == 0x0F then
			reg[d + 1] = bnot(reg[a + 1])
			pc += 4

		elseif opcode == 0x10 then
			reg[d + 1] = lshift(reg[a + 1], reg[b + 1])
			pc += 4

		elseif opcode == 0x11 then
			reg[d + 1] = rshift(reg[a + 1], reg[b + 1])
			pc += 4

		elseif opcode == 0x12 then
			reg[d + 1] = reg[a + 1]
			pc += 4

		elseif opcode == 0x13 then
			reg[d + 1] = (reg[a + 1] == reg[b + 1]) and 1 or 0
			pc += 4

		elseif opcode == 0x14 then
			reg[d + 1] = (signed32(reg[a + 1]) < signed32(reg[b + 1])) and 1 or 0
			pc += 4

		elseif opcode == 0x15 then
			reg[d + 1] = (signed32(reg[a + 1]) > signed32(reg[b + 1])) and 1 or 0
			pc += 4

		elseif opcode == 0x16 then
			reg[d + 1] = band(reg[a + 1] + band(imm, 0xFFFFFFFF), 0xFFFFFFFF)
			pc += size

		elseif opcode == 0x17 then
			reg[d + 1] = band(reg[a + 1] - band(imm, 0xFFFFFFFF), 0xFFFFFFFF)
			pc += size

		elseif opcode == 0x18 then
			reg[d + 1] = band(reg[a + 1] * band(imm, 0xFFFFFFFF), 0xFFFFFFFF)
			pc += size

		elseif opcode == 0x19 then
			reg[d + 1] = band(reg[a + 1], band(imm, 0xFFFFFFFF))
			pc += size

		elseif opcode == 0x1A then
			reg[d + 1] = bor(reg[a + 1], band(imm, 0xFFFFFFFF))
			pc += size

		elseif opcode == 0x1B then
			reg[d + 1] = bxor(reg[a + 1], band(imm, 0xFFFFFFFF))
			pc += size

		elseif opcode == 0x1C then
			if reg[d + 1] ~= 0 then
				pc = imm
			else
				pc += size
			end

		elseif opcode == 0x1D then
			reg[d + 1] = arshift(reg[a + 1], reg[b + 1])
			pc += 4

		elseif opcode == 0x20 then
			if mode == CPU.MODE_USER then
				setTrapLocal("fault", {
					type = "privileged_instruction",
					instruction = "FLUSH",
					msg = ("privileged instruction FLUSH executed in user mode @ pc 0x%X"):format(pc),
				}, pc)
			else
				if writeWord(CTRL_FLUSH_ADDR, 1, "write") then break end
				pc += 4
			end

		elseif opcode == 0x21 then
			pc += 4
			setTrapLocal("yield", { reason = "sleep" }, pc, false)

		elseif opcode == 0x22 then
			local spIndex = SP_REG + 1
			local sp = reg[spIndex] - 4
			if sp < 0 then
				if mode == CPU.MODE_USER then
					setTrapLocal("fault", { type = "stack_fault", msg = ("stack underflow on CALL @ pc 0x%X"):format(pc), sp = reg[spIndex] }, pc)
				else
					setTrapLocal("panic", { type = "stack_fault", msg = ("stack underflow on CALL @ pc 0x%X"):format(pc), sp = reg[spIndex] }, pc)
				end
				break
			end
			if writeWord(sp, pc + size, "write") then break end
			reg[spIndex] = sp
			pc = imm

		elseif opcode == 0x23 then
			local spIndex = SP_REG + 1
			local sp = reg[spIndex]
			local ret, bad = readWord(sp, "read")
			if bad then break end
			reg[spIndex] = sp + 4
			pc = ret

		elseif opcode == 0x24 then
			local sp = reg[a + 1] - 4
			if sp < 0 then
				if mode == CPU.MODE_USER then
					setTrapLocal("fault", { type = "stack_fault", msg = ("stack underflow on PUSH @ pc 0x%X"):format(pc), sp = reg[a + 1] }, pc)
				else
					setTrapLocal("panic", { type = "stack_fault", msg = ("stack underflow on PUSH @ pc 0x%X"):format(pc), sp = reg[a + 1] }, pc)
				end
				break
			end
			if writeWord(sp, reg[d + 1], "write") then break end
			reg[a + 1] = sp
			pc += 4

		elseif opcode == 0x25 then
			local sp = reg[a + 1]
			local value, bad = readWord(sp, "read")
			if bad then break end
			reg[d + 1] = value
			reg[a + 1] = sp + 4
			pc += 4

		elseif opcode == 0x26 then
			local spIndex = SP_REG + 1
			local sp = reg[spIndex] - 4
			if sp < 0 then
				if mode == CPU.MODE_USER then
					setTrapLocal("fault", { type = "stack_fault", msg = ("stack underflow on CALLR @ pc 0x%X"):format(pc), sp = reg[spIndex] }, pc)
				else
					setTrapLocal("panic", { type = "stack_fault", msg = ("stack underflow on CALLR @ pc 0x%X"):format(pc), sp = reg[spIndex] }, pc)
				end
				break
			end
			if writeWord(sp, pc + 4, "write") then break end
			reg[spIndex] = sp
			pc = reg[d + 1]

		elseif opcode == 0x27 then
			local value, bad = readByte(reg[a + 1], "read")
			if bad then break end
			reg[d + 1] = value
			pc += 4

		elseif opcode == 0x28 then
			if writeByte(reg[d + 1], band(reg[a + 1], 0xFF), "write") then break end
			pc += 4

		elseif opcode == 0x29 then
			local value, bad = readU16(reg[a + 1], "read")
			if bad then break end
			reg[d + 1] = value
			pc += 4

		elseif opcode == 0x2A then
			if writeU16(reg[d + 1], band(reg[a + 1], 0xFFFF), "write") then break end
			pc += 4

		elseif opcode == 0x2B then
			local value, bad = readByte(reg[a + 1], "read")
			if bad then break end
			if value >= 0x80 then
				value = value + 0xFFFFFF00
			end
			reg[d + 1] = value
			pc += 4

		elseif opcode == 0x2C then
			local value, bad = readU16(reg[a + 1], "read")
			if bad then break end
			if value >= 0x8000 then
				value = value + 0xFFFF0000
			end
			reg[d + 1] = value
			pc += 4

		elseif opcode == 0x30 then
			setTrapLocal("syscall", { n = b }, pc, false)
			pc += 4

		elseif opcode == 0x31 then
			reg[d + 1] = pc
			pc += 4

		elseif opcode == 0x32 then
			reg[d + 1] = band(imm, 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x33 then
			reg[d + 1] = band(reg[d + 1] + imm, 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x34 then
			reg[d + 1] = band(reg[d + 1] - imm, 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x35 then
			pc = band(pc + 4 + imm, 0xFFFFFFFF)

		elseif opcode == 0x36 then
			if reg[d + 1] == 0 then
				pc = band(pc + 4 + imm, 0xFFFFFFFF)
			else
				pc += 4
			end

		elseif opcode == 0x37 then
			if reg[d + 1] ~= 0 then
				pc = band(pc + 4 + imm, 0xFFFFFFFF)
			else
				pc += 4
			end

		elseif opcode == 0x38 then
			reg[d + 1] = band(reg[d + 1] + 1, 0xFFFFFFFF)
			pc += 4

		elseif opcode == 0x39 then
			reg[d + 1] = band(reg[d + 1] - 1, 0xFFFFFFFF)
			pc += 4

		else
			raiseFaultLocal("invalid_opcode", pc, "execute", ("invalid opcode %d @ pc 0x%X"):format(opcode, pc), pc)
		end

		steps += 1
	end

	self.pc = pc
	self.mode = mode
	self.running = running
	self.trap = trapInfo
	return steps
end

function CPU:run(max)
	return self:runSlice(max)
end

return CPU
