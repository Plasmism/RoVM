--!native
--mostly page math :D

local PageTable = require(script.Parent.PageTable)

local MMU = {}
MMU.__index = MMU

function MMU.new(physicalAllocator)
	local self = setmetatable({}, MMU)
	
	self.physicalAllocator = physicalAllocator
	self.pageSize = 4096  --4*1024 and every other file assumes the same number
	
	--scheduler swaps this on context switch
	self.currentPageTable = nil
	
	--kernel talks physical addresses directly
	self.kernelMode = false
	
	return self
end

function MMU:setPageTable(pageTable)
	self.currentPageTable = pageTable
end

function MMU:setKernelMode(enabled)
	self.kernelMode = enabled
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
	local virtualPage = self.currentPageTable:addressToPage(virtualAddr)
	local pageOffset = self.currentPageTable:getPageOffset(virtualAddr)
	
	--vpage -> ppage lookup
	local physicalPage, permissions, err = self.currentPageTable:translate(virtualPage)
	if not physicalPage then
		return nil, "page_fault", {
			addr = virtualAddr,
			virtualPage = virtualPage,
			access = accessType,
			reason = err or "page_not_mapped"
		}
	end
	
	--permission check lives here so memory reads and writes stay in sync
	local requiredPerm = 0
	if accessType == "read" then
		requiredPerm = PageTable.PERM_READ
	elseif accessType == "write" then
		requiredPerm = PageTable.PERM_WRITE
		--cow reads are fine. writes trip the fault on purpose.
		if self.currentPageTable:isCow(virtualPage) then
			--print(("[mmu] cow hit pid=%d vpage=%d addr=0x%X"):format(
			--self.currentPageTable.pid, virtualPage, virtualAddr))
			return nil, "cow_fault", {
				addr = virtualAddr,
				virtualPage = virtualPage,
				physicalPage = physicalPage,
				access = accessType
			}
		end
	elseif accessType == "execute" then
		requiredPerm = PageTable.PERM_EXEC
	end
	
	if not self.currentPageTable:checkPermission(virtualPage, requiredPerm) then
		return nil, "permission_fault", {
			addr = virtualAddr,
			virtualPage = virtualPage,
			access = accessType,
			required = requiredPerm,
			actual = permissions
		}
	end
	
	--ppage*4096 + pageOffset = final physical addr
	local physicalAddr = (physicalPage * self.pageSize) + pageOffset
	
	return physicalAddr, nil, nil
end

--split a shared page when somebody writes to it
function MMU:handleCowFault(virtualAddr, physicalMemory)
	if not self.currentPageTable then
		return false, "no_page_table"
	end
	
	local virtualPage = self.currentPageTable:addressToPage(virtualAddr)
	
	--find the old shared page first
	local oldPhysicalPage, _, _ = self.currentPageTable:translate(virtualPage)
	if not oldPhysicalPage then
		return false, "page_not_mapped"
	end
	
	--print(("[cow] fault pid=%d vpage=%d old=%d"):format(
	--self.currentPageTable.pid, virtualPage, oldPhysicalPage))
	
	--2 refs means two procs share it, 1 means oh no
	local oldRefCount = self.physicalAllocator:getRefCount(oldPhysicalPage)
	--print(("[cow] old refcount=%d"):format(oldRefCount))
	
	--grab a fresh page for the writer
	local newPhysicalPage, err = self.physicalAllocator:allocatePage(self.currentPageTable.pid)
	if not newPhysicalPage then
		--print(("[cow] alloc failed: %s"):format(err or "unknown"))
		return false, err or "failed_to_allocate_page"
	end
	
	--print(("[cow] new page=%d"):format(newPhysicalPage))
	
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
	local newRefCount, shouldFree = self.physicalAllocator:decrementRefCount(oldPhysicalPage, self.currentPageTable.pid)
	--print(("[cow] old refcount now=%d free=%s"):format(newRefCount, tostring(shouldFree)))
	
	--point the vpage at the fresh page and clear the cow bit
	local entry = self.currentPageTable.entries[virtualPage]
	if entry then
		entry.physicalPage = newPhysicalPage
		--write now owns this page outright
		entry.permissions = bit32.band(entry.permissions, bit32.bnot(PageTable.PERM_COW))
		--print(("[cow] remap vpage=%d phys=%d"):format(virtualPage, newPhysicalPage))
	end
	
	return true, nil
end

return MMU
