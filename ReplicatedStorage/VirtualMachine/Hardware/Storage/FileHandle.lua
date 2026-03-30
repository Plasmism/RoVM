--!native
--trivial file handling
local FileHandle = {}
FileHandle.__index = FileHandle

--bit flags so open modes stay cheap
FileHandle.MODE_READ = 1
FileHandle.MODE_WRITE = 2
FileHandle.MODE_APPEND = 4
FileHandle.MODE_CREATE = 8

function FileHandle.new()
	local self = setmetatable({}, FileHandle)
	
	--fd 0, 1, 2 stay reserved for stdio
	self.fds = {}
	self.nextFd = 3  --start after stdio
	
	return self
end

function FileHandle:open(inode, mode)
	local fd = self.nextFd
	self.nextFd += 1
	
	self.fds[fd] = {
		inode = inode,
		mode = mode,
		position = 0,  --byte offset in file
	}
	
	return fd, nil
end

function FileHandle:close(fd)
	if self.fds[fd] then
		self.fds[fd] = nil
		return true, nil
	end
	return nil, "invalid file descriptor"
end

function FileHandle:get(fd)
	return self.fds[fd]
end

function FileHandle:seek(fd, position)
	local handle = self.fds[fd]
	if not handle then
		return nil, "invalid file descriptor"
	end
	
	handle.position = position
	return position, nil
end

function FileHandle:tell(fd)
	local handle = self.fds[fd]
	if not handle then
		return nil, "invalid file descriptor"
	end
	
	return handle.position, nil
end

--dead proc means close everything and start counting from 3 again
function FileHandle:closeAll()
	self.fds = {}
	self.nextFd = 3
end

return FileHandle
