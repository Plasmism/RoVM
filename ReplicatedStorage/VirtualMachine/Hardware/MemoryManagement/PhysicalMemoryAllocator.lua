--!native

local PhysicalMemoryAllocator = {}
PhysicalMemoryAllocator.__index = PhysicalMemoryAllocator

local PAGE_SIZE = 4096 --4*1024 bytes

function PhysicalMemoryAllocator.new(totalMemorySize)
	local self = setmetatable({}, PhysicalMemoryAllocator)
	
	self.totalSize = totalMemorySize
	self.pageSize = PAGE_SIZE
	self.totalPages = math.floor(totalMemorySize / PAGE_SIZE)
	
	--true means free. tables and booleans fight enough already.
	self.freePages = {}
	for i = 0, self.totalPages - 1 do
		self.freePages[i] = true
	end
	
	--refcount > 1 means cow has roommates on that page
	self.pageRefCounts = {}
	
	--mostly for cleanup and postmortem blame later
	--pageOwners[page] = {pid1,pid2,...}
	self.pageOwners = {}
	
	return self
end

--first free page wins. no allocator fanfiction today.
function PhysicalMemoryAllocator:allocatePage(pid)
	for i = 0, self.totalPages - 1 do
		if self.freePages[i] then
			self.freePages[i] = false
			self.pageRefCounts[i] = 1
			self.pageOwners[i] = {pid}
			return i, nil
		end
	end
	return nil, "out_of_memory"
end

function PhysicalMemoryAllocator:freePage(pageIndex)
	if pageIndex < 0 or pageIndex >= self.totalPages then
		return false, "invalid_page"
	end
	
	if self.freePages[pageIndex] then
		return false, "page_already_free"
	end
	
	self.freePages[pageIndex] = true
	self.pageRefCounts[pageIndex] = nil
	self.pageOwners[pageIndex] = nil
	return true, nil
end

function PhysicalMemoryAllocator:incrementRefCount(pageIndex, pid)
	if not self.pageRefCounts[pageIndex] then
		self.pageRefCounts[pageIndex] = 0
	end
	self.pageRefCounts[pageIndex] = self.pageRefCounts[pageIndex] + 1
	
	if not self.pageOwners[pageIndex] then
		self.pageOwners[pageIndex] = {}
	end
	table.insert(self.pageOwners[pageIndex], pid)
end

--walk owner list backwards so remove does not skip anything dumb
function PhysicalMemoryAllocator:decrementRefCount(pageIndex, pid)
	if not self.pageRefCounts[pageIndex] then
		return 0, false
	end
	
	self.pageRefCounts[pageIndex] = self.pageRefCounts[pageIndex] - 1
	
	--drop this pid from the owner list
	if self.pageOwners[pageIndex] then
		for i = #self.pageOwners[pageIndex], 1, -1 do
			if self.pageOwners[pageIndex][i] == pid then
				table.remove(self.pageOwners[pageIndex], i)
			end
		end
	end
	
	local newCount = self.pageRefCounts[pageIndex]
	if newCount <= 0 then
		self.pageRefCounts[pageIndex] = nil
		self.pageOwners[pageIndex] = nil
		return 0, true
	end
	
	return newCount, false
end

function PhysicalMemoryAllocator:getRefCount(pageIndex)
	return self.pageRefCounts[pageIndex] or 0
end

function PhysicalMemoryAllocator:isShared(pageIndex)
	return (self.pageRefCounts[pageIndex] or 0) > 1
end

function PhysicalMemoryAllocator:pageToAddress(pageIndex)
	return pageIndex * self.pageSize
end

function PhysicalMemoryAllocator:addressToPage(addr)
	return math.floor(addr / self.pageSize)
end

function PhysicalMemoryAllocator:getPageOffset(addr)
	return addr % self.pageSize
end

function PhysicalMemoryAllocator:getFreePageCount()
	local count = 0
	for _ in pairs(self.freePages) do
		count = count + 1
	end
	return count
end

function PhysicalMemoryAllocator:getAllocatedPageCount()
	return self.totalPages - self:getFreePageCount()
end

return PhysicalMemoryAllocator
