--!native
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CompilerFolder = script.Parent:WaitForChild("Compiler")

local CCHost = require(CompilerFolder:WaitForChild("cc_host"))
local CCCodeGen = require(CompilerFolder:WaitForChild("cc_codegen"))

--remote lives in replicatedstorage so the client can ask for compiles without extra plumbing
local compileRemote = ReplicatedStorage:FindFirstChild("CompileRequest")
if not compileRemote then
	compileRemote = Instance.new("RemoteFunction")
	compileRemote.Name = "CompileRequest"
	compileRemote.Parent = ReplicatedStorage
end

local MAX_SOURCE_BYTES = 256 * 1024
local MAX_INCLUDE_COUNT = 128
local MAX_INCLUDE_NAME_BYTES = 256
local MAX_INCLUDE_TOTAL_BYTES = 2 * 1024 * 1024
local COMPILE_BURST = 24
local COMPILE_REFILL_PER_SEC = 2

local compileBuckets = {}
local compileInFlight = {}

local function takeCompileToken(userId)
	local now = time()
	local bucket = compileBuckets[userId]
	if not bucket then
		bucket = {
			tokens = COMPILE_BURST,
			lastUpdated = now,
		}
		compileBuckets[userId] = bucket
	end

	local elapsed = math.max(0, now - bucket.lastUpdated)
	bucket.lastUpdated = now
	bucket.tokens = math.min(COMPILE_BURST, bucket.tokens + elapsed * COMPILE_REFILL_PER_SEC)
	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

local function sanitizeIncludes(includes)
	if includes == nil then
		return {}, nil
	end
	if type(includes) ~= "table" then
		return nil, "includes must be a table"
	end

	local sanitized = {}
	local includeCount = 0
	local totalBytes = 0
	for name, contents in pairs(includes) do
		if type(name) ~= "string" or type(contents) ~= "string" then
			return nil, "includes must be a string map"
		end
		if #name == 0 or #name > MAX_INCLUDE_NAME_BYTES then
			return nil, "include name too long"
		end

		includeCount += 1
		if includeCount > MAX_INCLUDE_COUNT then
			return nil, "too many includes"
		end

		totalBytes += #contents
		if totalBytes > MAX_INCLUDE_TOTAL_BYTES then
			return nil, "includes too large"
		end

		sanitized[name] = contents
	end

	return sanitized, nil
end

compileRemote.OnServerInvoke = function(player, source, includes)
	if player == nil then
		return {success = false, error = "missing player"}
	end
	if type(source) ~= "string" then
		return {success = false, error = "source must be a string"}
	end
	if #source > MAX_SOURCE_BYTES then
		return {success = false, error = "source too large"}
	end

	local includeMap, includeErr = sanitizeIncludes(includes)
	if not includeMap then
		return {success = false, error = includeErr}
	end
	if compileInFlight[player.UserId] then
		return {success = false, error = "compile already in progress"}
	end
	if not takeCompileToken(player.UserId) then
		return {success = false, error = "compile rate limit exceeded"}
	end

	--print("[CompilerService] Compilation request from", player.Name)
	compileInFlight[player.UserId] = true

	local ok, result = pcall(function()
		local function resolveInclude(path)
			--include names show up as <x.h> or "x.h", so strip the wrappers first
			local clean = path:gsub('^[<"]', ''):gsub('[>"]$', '')
			return includeMap[clean]
		end

		--preprocess first
		local preprocessed = CCHost.preprocess(source, resolveInclude, nil, "main.c")

		--then split the mess into tokens
		local tokens = CCHost.tokenize(preprocessed)

		--then give the tokens structure
		local ast = CCHost.parse(tokens)

		--finally spit out asm
		local g = CCCodeGen.new()
		return g:genProgram(ast)
	end)

	compileInFlight[player.UserId] = nil

	if ok then
		return {success = true, output = result}
	else
		--best effort error unpacking
		--usual shape is file:line:col: error: whatever exploded
		local file, line, col, msg = result:match("([^:]+):(%d+):(%d+):%s*(.*)")
		if file and line and col then
			return {
				success = false,
				error = msg,
				file = file,
				line = tonumber(line),
				col = tonumber(col),
				full = result
			}
		else
			return {success = false, error = result}
		end
	end
end
