--!native
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local DATASTORE_NAME = "ROVM_Filesystem"
local REMOTE_NAME = "ROVM_Filesystem"

local function getRemote()
	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if remote then
		return remote
	end

	remote = Instance.new("RemoteFunction")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function readData(userId)
	local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
	return dataStore:GetAsync(tostring(userId))
end

local function writeData(userId, payload)
	local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
	local encoded = HttpService:JSONEncode(payload)
	dataStore:SetAsync(tostring(userId), encoded)
	return true
end

local remote = getRemote()

remote.OnServerInvoke = function(player, action, arg1, arg2)
	if player == nil then
		return false, "missing player"
	end

	--filesystem persistence is always bound to the authenticated caller
	--ignore any user id the client tries to send, even for old call sites
	local targetId = player.UserId
	if action == "load" then
		local ok, result = pcall(readData, targetId)
		if not ok then
			return false, result
		end
		if result == nil then
			return nil
		end
		if type(result) == "string" then
			local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, result)
			if not decodeOk then
				return false, decoded
			end
			return decoded
		end
		if type(result) == "table" then
			return result
		end
		return false, "invalid stored data"
	elseif action == "save" then
		local payload = (type(arg1) == "table") and arg1 or arg2
		if type(payload) ~= "table" then
			return false, "invalid payload"
		end
		local ok, result = pcall(writeData, targetId, payload)
		if not ok then
			return false, result
		end
		return result
	end

	return false, "unknown action"
end
