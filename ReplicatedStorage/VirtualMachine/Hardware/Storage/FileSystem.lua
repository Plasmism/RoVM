--!native

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Filesystem = {}
Filesystem.__index = Filesystem

--per player key
local DATASTORE_NAME = "ROVM_Filesystem"

--inode types. thrilling stuff
local TYPE_FILE = 1
local TYPE_DIR = 2
local TYPE_DEV = 3

Filesystem.TYPE_FILE = TYPE_FILE
Filesystem.TYPE_DIR = TYPE_DIR
Filesystem.TYPE_DEV = TYPE_DEV

--permission bits stay simple on purpose
Filesystem.PERM_READ = 1
Filesystem.PERM_WRITE = 2
Filesystem.PERM_EXEC = 4

local Base64 = require(script.Parent:WaitForChild("Base64"))

local function base64Encode(data)
	return Base64.encode(data)
end

local function base64Decode(data)
	return Base64.decode(data)
end

--inode reminder
--type size data parent children permissions createdAt modifiedAt

function Filesystem.new()
	local self = setmetatable({}, Filesystem)
	
	--inode 0 stays empty. root is 1 because 0 is a liar
	self.inodes = {}
	self.nextInode = 2
	
	--root inode
	self.inodes[1] = {
		type = Filesystem.TYPE_DIR,
		size = 0,
		data = {},
		parent = 1,  --root points at itself so .. from / does not get cute
		children = {},
		permissions = Filesystem.PERM_READ + Filesystem.PERM_WRITE + Filesystem.PERM_EXEC,
		createdAt = os.clock(),
		modifiedAt = os.clock(),
	}
	
	--kept around for root lookups even if it feels a bit redundant
	self.rootNames = {}  --{"/" = 1}
	
	return self
end

function Filesystem:allocateInode()
	local inode = self.nextInode
	self.nextInode += 1
	return inode
end

--print("[fs] resolve", path)
function Filesystem:resolvePath(path)
	if not path or path == "" then
		return nil, "empty path"
	end
	
	--collapse // before walking or path parsing starts acting up
	path = path:gsub("//+", "/")  --// is just / with attitude
	if path:sub(1, 1) ~= "/" then
		--relative paths still get shoved under / for now
		path = "/" .. path
	end
	
	--turn /a/b/c into {"a","b","c"}
	local parts = {}
	for part in path:gmatch("([^/]+)") do
		if part ~= "" and part ~= "." then
			if part == ".." then
				table.remove(parts)
			else
				table.insert(parts, part)
			end
		end
	end
	
	--walk from root every time. not fancy, but it does not lie much.
	local currentInode = 1
	local current = self.inodes[currentInode]
	
	--follow each child pointer until the path ends or something breaks
	for _, part in ipairs(parts) do
		if current.type ~= Filesystem.TYPE_DIR then
			return nil, "not a directory"
		end
		
		local childInode = current.children[part]
		if not childInode then
			return nil, "not found"
		end
		
		currentInode = childInode
		current = self.inodes[currentInode]
		if not current then
			return nil, "invalid inode"
		end
	end
	
	return currentInode, nil
end

function Filesystem:splitPath(path)
	local lastSlash = path:match("^.*()/")
	if not lastSlash then
		return "/", path  --no slash means dump it in root and move on
	end
	
	local dirPath = path:sub(1, lastSlash - 1)
	if dirPath == "" then
		dirPath = "/"
	end
	local filename = path:sub(lastSlash + 1)
	
	return dirPath, filename
end

function Filesystem:createFile(path, data)
	data = data or ""
	
	local dirPath, filename = self:splitPath(path)
	local parentInode, err = self:resolvePath(dirPath)
	if not parentInode then
		return nil, err or "parent not found"
	end
	
	local parent = self.inodes[parentInode]
	if parent.type ~= Filesystem.TYPE_DIR then
		return nil, "parent is not a directory"
	end
	
	--do not silently clobber. that path always sucks.
	if parent.children[filename] then
		return nil, "file already exists"
	end
	
	--new inode. same boring shape as usual.
	local inode = self:allocateInode()
	self.inodes[inode] = {
		type = Filesystem.TYPE_FILE,
		size = #data,
		data = data,
		parent = parentInode,
		permissions = Filesystem.PERM_READ + Filesystem.PERM_WRITE,
		createdAt = os.clock(),
		modifiedAt = os.clock(),
	}
	
	--link child into parent directory
	parent.children[filename] = inode
	parent.modifiedAt = os.clock()
	
	return inode, nil
end

function Filesystem:createDirectory(path)
	local dirPath, dirname = self:splitPath(path)
	local parentInode, err = self:resolvePath(dirPath)
	if not parentInode then
		return nil, err or "parent not found"
	end
	
	local parent = self.inodes[parentInode]
	if parent.type ~= Filesystem.TYPE_DIR then
		return nil, "parent is not a directory"
	end
	
	--same deal here. no surprise overwrites.
	if parent.children[dirname] then
		return nil, "directory already exists"
	end
	
	--dir inode gets its own child table
	local inode = self:allocateInode()
	self.inodes[inode] = {
		type = Filesystem.TYPE_DIR,
		size = 0,
		data = {},
		parent = parentInode,
		children = {},
		permissions = Filesystem.PERM_READ + Filesystem.PERM_WRITE + Filesystem.PERM_EXEC,
		createdAt = os.clock(),
		modifiedAt = os.clock(),
	}
	
	--hook it into the parent dir
	parent.children[dirname] = inode
	parent.modifiedAt = os.clock()
	
	return inode, nil
end

function Filesystem:createDevice(path, deviceId)
	local dirPath, filename = self:splitPath(path)
	local parentInode, err = self:resolvePath(dirPath)
	if not parentInode then
		return nil, err or "parent not found"
	end
	
	local parent = self.inodes[parentInode]
	if parent.type ~= TYPE_DIR then
		return nil, "parent is not a directory"
	end
	
	--do not stomp an existing path
	if parent.children[filename] then
		return nil, "entry already exists"
	end
	
	--device nodes just store the device id as data. easy.
	local inode = self:allocateInode()
	self.inodes[inode] = {
		type = TYPE_DEV,
		size = 0,
		data = deviceId, --"gpu" "tty" etc
		parent = parentInode,
		permissions = Filesystem.PERM_READ + Filesystem.PERM_WRITE,
		createdAt = os.clock(),
		modifiedAt = os.clock(),
	}
	
	--plug it into the parent dir
	parent.children[filename] = inode
	parent.modifiedAt = os.clock()
	
	return inode, nil
end

function Filesystem:readFile(inode)
	local node = self.inodes[inode]
	if not node then
		return nil, "inode not found"
	end
	
	if node.type ~= Filesystem.TYPE_FILE then
		return nil, "not a file"
	end
	
	return node.data, nil
end

function Filesystem:writeFile(inode, data)
	local node = self.inodes[inode]
	if not node then
		return nil, "inode not found"
	end
	
	if node.type ~= Filesystem.TYPE_FILE then
		return nil, "not a file"
	end
	
	node.data = data
	node.size = #data
	node.modifiedAt = os.clock()
	
	return true, nil
end

function Filesystem:unlink(path)
	local inode, err = self:resolvePath(path)
	if not inode then
		return nil, err
	end
	
	local node = self.inodes[inode]
	if not node then
		return nil, "inode not found"
	end
	
	--root stays. i am not debugging that mess lol.
	if inode == 1 then
		return nil, "cannot delete root"
	end
	
	--no recursive delete hiding in here
	if node.type == Filesystem.TYPE_DIR and next(node.children) then
		return nil, "directory not empty"
	end
	
	--unlink from parent first
	local parent = self.inodes[node.parent]
	if parent then
		for name, childInode in pairs(parent.children) do
			if childInode == inode then
				parent.children[name] = nil
				parent.modifiedAt = os.clock()
				break
			end
		end
	end
	
	--then drop the inode itself
	self.inodes[inode] = nil
	
	return true, nil
end

function Filesystem:listDirectory(inode)
	local node = self.inodes[inode]
	if not node then
		return nil, "inode not found"
	end
	
	if node.type ~= Filesystem.TYPE_DIR then
		return nil, "not a directory"
	end
	
	local entries = {}
	for name, childInode in pairs(node.children) do
		local child = self.inodes[childInode]
		if child then
			table.insert(entries, {
				name = name,
				inode = childInode,
				type = child.type,
				size = child.size,
			})
		end
	end
	
	return entries, nil
end

function Filesystem:stat(inode)
	local node = self.inodes[inode]
	if not node then
		return nil, "inode not found"
	end
	
	return {
		inode = inode,
		type = node.type,
		size = node.size,
		permissions = node.permissions,
		createdAt = node.createdAt,
		modifiedAt = node.modifiedAt,
	}, nil
end

--datastore wants json-safe strings, so binary goes through base64
function Filesystem:serialize()
	local data = {
		inodes = {},
		nextInode = self.nextInode,
		version = 1,  --save format version in case future me gets ideas
	}
	
	--print("[fs] serialize inode", inode, node.type, node.size)
	--walk every inode into a plain save table
	for inode, node in pairs(self.inodes) do
		local serialized = {
			type = node.type,
			size = node.size,
			parent = node.parent,
			permissions = node.permissions,
			createdAt = node.createdAt,
			modifiedAt = node.modifiedAt,
		}
		
		if node.type == TYPE_FILE then
			--datastore has a 4mb cap and big files are big
			--100*1024 = 102400, so bigger blobs get marked rebuildable instead
			--regenerated stuff can come back on boot, so no need to save the whole circus
			local raw = node.data
			if type(raw) ~= "string" then
				--coerce weird bufferish data back into a string before save
				if raw and buffer and buffer.tostring then
					local ok, s = pcall(buffer.tostring, raw)
					if ok and type(s) == "string" then raw = s else raw = "" end
				else
					raw = ""
				end
				if type(raw) ~= "string" then
					warn("Filesystem:serialize - node " .. tostring(inode) .. " (type " .. tostring(node.type) .. ") has non-string data! Resetting to prevent crash.")
					raw = ""
				end
				node.data = raw
			end
			if #raw > 102400 then
				serialized.data = ""
				serialized.dataEncoding = "b64"
				serialized.transient = true  --skip persistence for this one
			else
				serialized.data = base64Encode(raw)
				serialized.dataEncoding = "b64"
			end
		elseif node.type == TYPE_DEV then
			--devices only need their id string
			serialized.data = node.data or ""
		elseif node.type == TYPE_DIR then
			--dirs just serialize the child name -> inode map
			serialized.children = {}
			if node.children then
				for name, childInode in pairs(node.children) do
					serialized.children[name] = childInode
				end
			end
		end
		
		data.inodes[tostring(inode)] = serialized
	end
	
	return data
end

--load the save table back into live inode state
function Filesystem:deserialize(data)
	if not data or not data.inodes then
		return false, "invalid data format"
	end
	
	--start clean so stale inodes do not haunt the new image
	self.inodes = {}
	self.nextInode = data.nextInode or 2
	
	--rebuild each inode from the save payload
	for inodeStr, serialized in pairs(data.inodes) do
		local inode = tonumber(inodeStr)
		if not inode then
			continue
		end
		
		local node = {
			type = serialized.type,
			size = serialized.size or 0,
			parent = serialized.parent,
			permissions = serialized.permissions or (Filesystem.PERM_READ + Filesystem.PERM_WRITE),
			createdAt = serialized.createdAt or os.clock(),
			modifiedAt = serialized.modifiedAt or os.clock(),
		}
		
		if serialized.type == TYPE_FILE then
			--base64 first, then legacy plain string if an old save did that
			local raw = serialized.data or ""
			if serialized.dataEncoding == "b64" then
				local decoded = base64Decode(raw)
				if decoded then
					raw = decoded
				end
			end
			node.data = raw
			node.size = #node.data
		elseif serialized.type == TYPE_DEV then
			--device node just restores its id
			node.data = serialized.data or ""
			node.size = 0
		elseif serialized.type == TYPE_DIR then
			--dir children come back as a plain mapping
			node.data = {}
			node.children = {}
			if serialized.children then
				for name, childInode in pairs(serialized.children) do
					node.children[name] = childInode
				end
			end
		end
		
		self.inodes[inode] = node
	end
	
	--if the save is busted, at least make sure / still exists
	if not self.inodes[1] then
		self.inodes[1] = {
			type = Filesystem.TYPE_DIR,
			size = 0,
			data = {},
			parent = 1,
			children = {},
			permissions = Filesystem.PERM_READ + Filesystem.PERM_WRITE + Filesystem.PERM_EXEC,
			createdAt = os.clock(),
			modifiedAt = os.clock(),
		}
	end
	
	return true, nil
end

function Filesystem:saveAsync(userId)
	local success, result = pcall(function()
		local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
		local serialized = self:serialize()
		dataStore:SetAsync(tostring(userId), serialized)
		return true
	end)
	
	if success then
		return true, nil
	else
		return false, result
	end
end

function Filesystem:loadAsync(userId)
	local success, result = pcall(function()
		local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
		local data = dataStore:GetAsync(tostring(userId))
		
		if data then
			local ok, err = self:deserialize(data)
			if not ok then
				return false, err
			end
			return true, nil
		else
			--no save yet, just boot with a fresh fs
			return true, nil
		end
	end)
	
	if success then
		return result, nil
	else
		return false, result
	end
end

return Filesystem
