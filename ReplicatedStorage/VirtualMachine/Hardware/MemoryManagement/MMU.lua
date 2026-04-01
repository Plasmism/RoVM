--!native
--mostly page math :D

local PageTable = require(script.Parent.PageTable)

local bit32 = bit32
local band = bit32.band
local rshift = bit32.rshift

local MMU = {}
MMU.__index = MMU

--numeric access type constants for the hot path (no string comparisons)
MMU.ACCESS_READ = 1
MMU.ACCESS_WRITE = 2
MMU.ACCESS_EXEC = 4

local ACCESS_READ = 1
local ACCESS_WRITE = 2
local ACCESS_EXEC = 4

local PERM_READ  = PageTable.PERM_READ
local PERM_WRITE = PageTable.PERM_WRITE
local PERM_EXEC  = PageTable.PERM_EXEC
local PERM_COW   = PageTable.PERM_COW

local PAGE_SHIFT = 12
local PAGE_MASK  = 0xFFF

--tlb sizing. must be a power of 2
local TLB_SIZE = 256
local TLB_MASK = TLB_SIZE - 1

function MMU.new(physicalAllocator)
	local self = setmetatable({}, MMU)
	
	self.physicalAllocator = physicalAllocator
	self.pageSize = 4096  --4*1024 and every other file assumes the same number
	
	--scheduler swaps this on context switch
	self.currentPageTable = nil
	
	--kernel talks physical addresses directly
	self.kernelMode = false
	
	--direct-mapped TLB: virtual page -> physical page + permissions
	--indexed by band(virtualPage, TLB_MASK) + 1
	self.tlbSize = TLB_SIZE
	self.tlbMask = TLB_MASK
	self.tlbVPages = table.create(TLB_SIZE, -1)  --virtual page tag (-1 = invalid)
	self.tlbPPages = table.create(TLB_SIZE, 0)    --physical page number
	self.tlbPerms  = table.create(TLB_SIZE, 0)    --permission bitmask
	
	return self
end

function MMU:flushTLB()
	local v = self.tlbVPages
	for i = 1, TLB_SIZE do
		v[i] = -1
	end
end

function MMU:invalidateTLBPage(virtualPage)
	local slot = band(virtualPage, TLB_MASK) + 1
	if self.tlbVPages[slot] == virtualPage then
		self.tlbVPages[slot] = -1
	end
end

function MMU:setPageTable(pageTable)
	self.currentPageTable = pageTable
	--context switch invalidates entire TLB
	self:flushTLB()
end

function MMU:setKernelMode(enabled)
	self.kernelMode = enabled
end

--fast TLB-accelerated translation for the CPU hot loop
--returns physical address on success, nil on miss/fault
--accessType is numeric: ACCESS_READ=1, ACCESS_WRITE=2, ACCESS_EXEC=4
function MMU:translateFast(virtualAddr, accessType)
	if self.kernelMode then
		return virtualAddr
	end
	
	local pt = self.currentPageTable
	if not pt then
		return nil
	end
	
	local virtualPage = rshift(virtualAddr, PAGE_SHIFT)
	local slot = band(virtualPage, TLB_MASK) + 1
	
	local tlbVPages = self.tlbVPages
	if tlbVPages[slot] == virtualPage then
		--TLB hit! Check permissions inline
		local perms = self.tlbPerms[slot]
		
		--write to COW page must go through slow path
		if accessType == ACCESS_WRITE and band(perms, PERM_COW) ~= 0 then
			return nil
		end
		
		--permission check
		if band(perms, accessType) == 0 then
			return nil
		end
		
		return self.tlbPPages[slot] * 4096 + band(virtualAddr, PAGE_MASK)
	end
	
	--TLB miss: direct entries[] access is intentional for hot-path perf.
	--PageTable:translate() is a thin wrapper over entries[] with no side effects,
	--so bypassing it here is safe. If PageTable:translate() ever gains additional
	--logic (refcount, dirty bit, etc.) this site must be updated to match.
	local entry = pt.entries[virtualPage]
	if not entry then
		return nil
	end
	
	local perms = entry.permissions
	
	--write to COW page must go through slow path
	if accessType == ACCESS_WRITE and band(perms, PERM_COW) ~= 0 then
		return nil
	end
	
	--permission check
	if band(perms, accessType) == 0 then
		return nil
	end
	
	--populate TLB
	local physPage = entry.physicalPage
	tlbVPages[slot] = virtualPage
	self.tlbPPages[slot] = physPage
	self.tlbPerms[slot] = perms
	
	return physPage * 4096 + band(virtualAddr, PAGE_MASK)
end

--guest addr = page*4096 + offset
--4096 is 4*1024 so if that number drifts everything turns to shit
function MMU:translate(virtualAddr, accessType)
	--kernel path skips translation on purpose
	if self.kernelMode then
		return virtualAddr, nil, nil
	end
	
	--user mode with no page table is just a fancy panic
	if not self.currentPageTable then
		return nil, "no_page_table", {addr = virtualAddr, access = accessType}
	end
	
	--split address into page number + offset inside that page
	local virtualPage = rshift(virtualAddr, PAGE_SHIFT)
	local pageOffset = band(virtualAddr, PAGE_MASK)
	
	--Direct entries[] access matches original MMU behavior (pre-TLB).
	--PageTable:translate() is a thin getter with no side-effects;
	--if it ever gains logic beyond the raw lookup, update here too.
	local entry = self.currentPageTable.entries[virtualPage]
	if not entry then
		return nil, "page_fault", {
			addr = virtualAddr,
			virtualPage = virtualPage,
			access = accessType,
			reason = "page_not_mapped"
		}
	end
	
	local physicalPage = entry.physicalPage
	local permissions = entry.permissions
	
	--permission check lives here so memory reads and writes stay in sync
	local requiredPerm = 0
	if accessType == "read" or accessType == ACCESS_READ then
		requiredPerm = PERM_READ
	elseif accessType == "write" or accessType == ACCESS_WRITE then
		requiredPerm = PERM_WRITE
		--cow reads are fine. writes trip the fault on purpose.
		if band(permissions, PERM_COW) ~= 0 then
			return nil, "cow_fault", {
				addr = virtualAddr,
				virtualPage = virtualPage,
				physicalPage = physicalPage,
				access = accessType
			}
		end
	elseif accessType == "execute" or accessType == ACCESS_EXEC then
		requiredPerm = PERM_EXEC
	end
	
	if band(permissions, requiredPerm) == 0 then
		return nil, "permission_fault", {
			addr = virtualAddr,
			virtualPage = virtualPage,
			access = accessType,
			required = requiredPerm,
			actual = permissions
		}
	end
	
	--populate TLB on successful full translation
	local slot = band(virtualPage, TLB_MASK) + 1
	self.tlbVPages[slot] = virtualPage
	self.tlbPPages[slot] = physicalPage
	self.tlbPerms[slot] = permissions
	
	--ppage*4096 + pageOffset = final physical addr
	local physicalAddr = (physicalPage * self.pageSize) + pageOffset
	
	return physicalAddr, nil, nil
end

--split a shared page when somebody writes to it
function MMU:handleCowFault(virtualAddr, physicalMemory)
	if not self.currentPageTable then
		return false, "no_page_table"
	end
	
	local virtualPage = rshift(virtualAddr, PAGE_SHIFT)
	
	--find the old shared page first
	local entry = self.currentPageTable.entries[virtualPage]
	if not entry then
		return false, "page_not_mapped"
	end
	local oldPhysicalPage = entry.physicalPage
	
	--grab a fresh page for the writer
	local newPhysicalPage, err = self.physicalAllocator:allocatePage(self.currentPageTable.pid)
	if not newPhysicalPage then
		return false, err or "failed_to_allocate_page"
	end
	
	--copy a whole page. 4096 bytes unless we are kissing the end of ram.
	local oldAddr = self.physicalAllocator:pageToAddress(oldPhysicalPage)
	local newAddr = self.physicalAllocator:pageToAddress(newPhysicalPage)

	local copyLen = self.pageSize
	if oldAddr + copyLen > physicalMemory.size then
		copyLen = physicalMemory.size - oldAddr
	end
	if newAddr + copyLen > physicalMemory.size then
		copyLen = physicalMemory.size - newAddr
	end
	if copyLen > 0 then
		buffer.copy(physicalMemory.buf, newAddr, physicalMemory.buf, oldAddr, copyLen)
	end
	
	--drop this proc off the old shared page
	local _newRefCount, _shouldFree = self.physicalAllocator:decrementRefCount(oldPhysicalPage, self.currentPageTable.pid)
	
	--point the vpage at the fresh page and clear the cow bit
	if entry then
		entry.physicalPage = newPhysicalPage
		--write now owns this page outright
		entry.permissions = band(entry.permissions, bit32.bnot(PERM_COW))
	end
	
	--invalidate TLB for this page since mapping changed
	self:invalidateTLBPage(virtualPage)
	
	return true, nil
end

return MMU
