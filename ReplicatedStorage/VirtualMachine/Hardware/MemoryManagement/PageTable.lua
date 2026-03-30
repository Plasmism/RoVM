--!native
--plain vpage -> ppage map

local PageTable = {}
PageTable.__index = PageTable

--perm bits. cow piggybacks here because one more table was not happening
PageTable.PERM_READ = 1
PageTable.PERM_WRITE = 2
PageTable.PERM_EXEC = 4
PageTable.PERM_COW = 8  --copy-on-write flag

local PAGE_SIZE = 4096 --4*1024 bytes, same number everywhere or hell breaks loose

function PageTable.new(pid, physicalAllocator)
	local self = setmetatable({}, PageTable)
	
	self.pid = pid
	self.physicalAllocator = physicalAllocator
	
	--entry shape reminder
	--entries[vpage] = { physicalPage = ppage, permissions = bitmask }
	self.entries = {}
	
	return self
end

--nil physicalPage means allocate
--existing physicalPage means share and bump the refcount
function PageTable:mapPage(virtualPage, physicalPage, permissions)
	if virtualPage < 0 then
		return false, "invalid_virtual_page"
	end
	
	--fresh page if caller did not hand one in
	if not physicalPage then
		local allocPage, allocErr = self.physicalAllocator:allocatePage(self.pid)
		if not allocPage then
			return false, allocErr or "failed_to_allocate_page"
		end
		physicalPage = allocPage
	else
		--shared mapping, so bump refs and move on
		self.physicalAllocator:incrementRefCount(physicalPage, self.pid)
	end
	
	self.entries[virtualPage] = {
		physicalPage = physicalPage,
		permissions = permissions or (PageTable.PERM_READ + PageTable.PERM_WRITE),
	}
	
	return true, nil
end

function PageTable:unmapPage(virtualPage)
	local entry = self.entries[virtualPage]
	if not entry then
		return false, "page_not_mapped"
	end
	
	local physicalPage = entry.physicalPage
	local refCount, shouldFree = self.physicalAllocator:decrementRefCount(physicalPage, self.pid)
	
	--if refs hit 0 the allocator can finally have the page back
	if shouldFree then
		self.physicalAllocator:freePage(physicalPage)
	end
	
	self.entries[virtualPage] = nil
	return true, nil
end

function PageTable:translate(virtualPage)
	local entry = self.entries[virtualPage]
	if not entry then
		return nil, nil, "page_not_mapped"
	end
	
	return entry.physicalPage, entry.permissions, nil
end

function PageTable:checkPermission(virtualPage, requiredPerm)
	local entry = self.entries[virtualPage]
	if not entry then
		return false
	end
	
	return (bit32.band(entry.permissions, requiredPerm) ~= 0)
end

function PageTable:setPermissions(virtualPage, permissions)
	local entry = self.entries[virtualPage]
	if not entry then
		return false, "page_not_mapped"
	end
	
	entry.permissions = permissions
	return true, nil
end

function PageTable:markCow(virtualPage)
	local entry = self.entries[virtualPage]
	if not entry then
		return false, "page_not_mapped"
	end
	
	entry.permissions = bit32.bor(entry.permissions, PageTable.PERM_COW)
	return true, nil
end

function PageTable:clearCow(virtualPage)
	local entry = self.entries[virtualPage]
	if not entry then
		return false, "page_not_mapped"
	end
	
	entry.permissions = bit32.band(entry.permissions, bit32.bnot(PageTable.PERM_COW))
	return true, nil
end

function PageTable:isCow(virtualPage)
	local entry = self.entries[virtualPage]
	if not entry then
		return false
	end
	
	return (bit32.band(entry.permissions, PageTable.PERM_COW) ~= 0)
end

--fork shares pages first and lets the first write pay for the copy later
function PageTable:fork(newPid)
	local newTable = PageTable.new(newPid, self.physicalAllocator)
	
	--same physical pages in both tables. parent + child means 2 refs now.
	for virtualPage, entry in pairs(self.entries) do
		local physicalPage = entry.physicalPage
		local permissions = entry.permissions
		
		--both sides get the cow bit
		permissions = bit32.bor(permissions, PageTable.PERM_COW)
		self.entries[virtualPage].permissions = permissions
		
		--child sees the same physical page for now
		newTable.entries[virtualPage] = {
			physicalPage = physicalPage,
			permissions = permissions,
		}
		
		--and the allocator gets told about the extra owner
		self.physicalAllocator:incrementRefCount(physicalPage, newPid)
	end
	
	return newTable
end

function PageTable:addressToPage(addr)
	return math.floor(addr / PAGE_SIZE)
end

function PageTable:getPageOffset(addr)
	return addr % PAGE_SIZE
end

function PageTable:getAllMappedPages()
	local pages = {}
	for virtualPage, entry in pairs(self.entries) do
		table.insert(pages, {
			virtual = virtualPage,
			physical = entry.physicalPage,
		})
	end
	return pages
end

--copy keys first because unmap mutates the table and lua gets funky about that
function PageTable:cleanup()
	local pages = {}
	for virtualPage in pairs(self.entries) do
		table.insert(pages, virtualPage)
	end
	for _, virtualPage in ipairs(pages) do
		self:unmapPage(virtualPage)
	end
end

return PageTable
