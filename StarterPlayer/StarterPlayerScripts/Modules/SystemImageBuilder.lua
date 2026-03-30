--!native
local SystemImageBuilder = {}
SystemImageBuilder.__index = SystemImageBuilder

--seeds the disk and compiles enough junk that first boot doesnt look abandoned
function SystemImageBuilder.new(config)
	local self = setmetatable({}, SystemImageBuilder)

	local getFilesystem = config.getFilesystem
	local ReplicatedStorage = config.ReplicatedStorage
	local CompileRequest = config.CompileRequest
	local Assembler = config.Assembler
	local serializeBinary = config.serializeBinary

	--tiny fs helpers so the boot seeding code below does not turn into sludge
	local function ensureDir(path)
		local filesystem = getFilesystem()
		local inode = filesystem:resolvePath(path)
		if inode then
			return true
		end
		local created = filesystem:createDirectory(path)
		return created ~= nil
	end

	local function ensureFile(path, data)
		local filesystem = getFilesystem()
		local inode = filesystem:resolvePath(path)
		if not inode then
			inode = filesystem:createFile(path, data or "")
			return inode ~= nil
		else
			return filesystem:writeFile(inode, data or "")
		end
	end

	local ROVM_MAGIC = 0x524F564D
	local ROVD_MAGIC = 0x524F5644
	local MIN_ROVM_HEADER_SIZE = 16
	local MIN_ROVD_HEADER_SIZE = 32

	--cheap sanity check only
	--rovm minimum is 4*4=16 bytes and rovd is 8*4=32 before payload
	local function readLeU32(data, offset)
		local b1 = string.byte(data, offset + 1) or 0
		local b2 = string.byte(data, offset + 2) or 0
		local b3 = string.byte(data, offset + 3) or 0
		local b4 = string.byte(data, offset + 4) or 0
		return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	end

	local function validateRovBinary(data)
		if type(data) ~= "string" then
			return false, "binary payload is not a string"
		end

		local size = #data
		if size < MIN_ROVM_HEADER_SIZE then
			return false, ("binary too small (%d bytes)"):format(size)
		end

		local magic = readLeU32(data, 0)
		if magic == ROVM_MAGIC then
			return true
		end
		if magic == ROVD_MAGIC then
			if size < MIN_ROVD_HEADER_SIZE then
				return false, ("ROVD binary too small (%d bytes)"):format(size)
			end
			return true
		end

		local rawMagic = data:sub(1, 4)
		return false, ("invalid binary magic %q"):format(rawMagic)
	end

	local function writeOrCreateFile(path, inode, data)
		local filesystem = getFilesystem()
		if inode then
			return filesystem:writeFile(inode, data)
		end
		return filesystem:createFile(path, data)
	end

	--big boot seeding pass lives here
	--yeah its a chonker, but at least all the default disk state is in one cave
	function self:ensureDefaultBloxOSFiles(bootCallbacks)
		local filesystem = getFilesystem()

		ensureDir("/boot")
		ensureDir("/bin")
		ensureDir("/dev")
		ensureDir("/os")
		ensureDir("/usr")
		ensureDir("/usr/include")
		ensureDir("/usr/lib")
		ensureDir("/usr/lib/cc")
		ensureDir("/usr/src")

		filesystem:createDevice("/dev/gpu", "gpu")
		filesystem:createDevice("/dev/tty", "tty")

		local CompilerFolder = ReplicatedStorage:FindFirstChild("Compiler")
		if CompilerFolder then
			local function inject(modName, fileName)
				local mod = CompilerFolder:FindFirstChild(modName)
				if mod then
					local content = require(mod)
					local path = "/usr/lib/cc/" .. fileName
					local inode = filesystem:resolvePath(path)
					if inode then
						filesystem:writeFile(inode, content)
					else
						filesystem:createFile(path, content)
					end
				end
			end
		end

		local badAppleMod = ReplicatedStorage:FindFirstChild("bad_apple")
		if badAppleMod then
			local content = require(badAppleMod)
			ensureFile("/usr/src/bad_apple.c", content)
		end

		local rovm_h = require(game.ReplicatedStorage.VirtualMachine.Software.Headers.rovm.rovm_h)
		local string_h = require(game.ReplicatedStorage.VirtualMachine.Software.Headers.libc.string_h)
		local stdlib_h = require(game.ReplicatedStorage.VirtualMachine.Software.Headers.libc.stdlib_h)
		local ctype_h = require(game.ReplicatedStorage.VirtualMachine.Software.Headers.libc.ctype_h)
		local stdio_h = require(game.ReplicatedStorage.VirtualMachine.Software.Headers.libc.stdio_h)
		local math_h = require(game.ReplicatedStorage.VirtualMachine.Software.Headers.libc.math_h)

		local cube_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Programs.cube_c)
		if not filesystem:resolvePath("/usr/src/cube.c") then
			filesystem:createFile("/usr/src/cube.c", cube_c)
		else
			filesystem:writeFile(filesystem:resolvePath("/usr/src/cube.c"), cube_c)
		end

		local poke_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Programs.poke_c)
		if not filesystem:resolvePath("/usr/src/poke.c") then
			filesystem:createFile("/usr/src/poke.c", poke_c)
		else
			filesystem:writeFile(filesystem:resolvePath("/usr/src/poke.c"), poke_c)
		end

		local doom_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Games.doom_c)
		ensureFile("/usr/src/doom.c", doom_c)

		local neofetch_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Programs.neofetch_c)
		ensureFile("/usr/src/neofetch.c", neofetch_c)

		local welcome_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Programs.welcome_c)
		ensureFile("/welcome.c", welcome_c)

		local benchmark_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Programs.benchmark_c)
		ensureFile("/usr/src/benchmark.c", benchmark_c)

		local calculator_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Programs.calculator_c)
		ensureFile("/usr/src/calculator.c", calculator_c)

		local python_runtime_h1 = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Python.python_runtime_h1)
		local python_runtime_h2 = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Python.python_runtime_h2)
		local python_runtime_h3 = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Python.python_runtime_h3)
		local python_runtime_h4 = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Python.python_runtime_h4)

		local python_runtime_h = python_runtime_h1 .. python_runtime_h2 .. python_runtime_h3 .. python_runtime_h4
		ensureFile("/usr/include/python_runtime.h", python_runtime_h)
		ensureFile("/usr/src/python_runtime.h", python_runtime_h)

		local python_wrapper_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Python.python_wrapper)
		local python_c = python_runtime_h .. python_wrapper_c
		ensureFile("/usr/src/python.c", python_c)

		local snake_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Games.snake_c)
		ensureFile("/usr/src/snake.c", snake_c)

		local tetris_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Games.tetris_c)
		ensureFile("/usr/src/tetris.c", tetris_c)

		local pong_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Games.pong_c)
		local space_defenders_c = require(game.ReplicatedStorage.VirtualMachine.Software.Applications.Games.space_defenders_c)

		ensureFile("/usr/src/pong.c", pong_c)
		ensureFile("/usr/src/space_defenders.c", space_defenders_c)
		if filesystem:resolvePath("/usr/src/atari.c") then
			filesystem:unlink("/usr/src/atari.c")
		end
		if filesystem:resolvePath("/usr/src/space_invaders.c") then
			filesystem:unlink("/usr/src/space_invaders.c")
		end

		ensureFile("/usr/include/rovm.h", rovm_h)
		ensureFile("/usr/src/doom.c", doom_c)

		ensureFile("/usr/include/rovm.h", rovm_h)
		ensureFile("/usr/include/string.h", string_h)
		ensureFile("/usr/include/stdlib.h", stdlib_h)
		ensureFile("/usr/include/ctype.h", ctype_h)
		ensureFile("/usr/include/stdio.h", stdio_h)
		ensureFile("/usr/include/math.h", math_h)

		--keeping this payload compressed in studio is way less gross than checking in one gigantic raw blob
		local function decode_bad_apple_huffman(data)
			if #data < 6 then
				return nil
			end

			if string.sub(data, 1, 4) ~= "BAH1" then
				return nil
			end

			local b1 = string.byte(data, 5)
			local b2 = string.byte(data, 6)
			local symbol_count = b1 + b2 * 256
			local pos = 7

			local symbols = table.create(symbol_count)
			local code_lengths = table.create(symbol_count)

			for i = 1, symbol_count do
				if pos + 2 > #data then
					return nil
				end
				local s1 = string.byte(data, pos)
				local s2 = string.byte(data, pos + 1)
				local sym = s1 + s2 * 256
				local length = string.byte(data, pos + 2)
				pos += 3
				symbols[i] = sym
				code_lengths[i] = length
			end

			local order = {}
			for i = 1, symbol_count do
				order[i] = { symbol = symbols[i], length = code_lengths[i] }
			end
			table.sort(order, function(a, b)
				if a.length == b.length then
					return a.symbol < b.symbol
				end
				return a.length < b.length
			end)

			local root = {}
			local code = 0
			local prev_len = order[1].length
			if prev_len < 1 then
				prev_len = 1
			end

			for i = 1, #order do
				local entry = order[i]
				local length = entry.length
				if length < 1 then
					length = 1
				end
				if length > prev_len then
					code = bit32.lshift(code, length - prev_len)
					prev_len = length
				end

				local node = root
				for bit_pos = length - 1, 0, -1 do
					local bit = bit32.band(bit32.rshift(code, bit_pos), 1)
					local child = node[bit]
					if child == nil then
						child = {}
						node[bit] = child
					end
					node = child
				end
				node.symbol = entry.symbol
				code = code + 1
			end

			local function next_bit()
				if pos > #data then
					return nil
				end
				local byte = string.byte(data, pos)
				local bit_index = bit32.band(bit32.rshift(byte, 7), 0xFF)
				data = string.char(bit32.band(byte * 2, 0xFF)) .. string.sub(data, pos + 1)
				if bit32.band(byte * 2, 0x100) ~= 0 then
				end
				return bit_index
			end

			local bit_pos = 0
			local current_byte = 0
			local function read_bit()
				if bit_pos == 0 then
					if pos > #data then
						return nil
					end
					current_byte = string.byte(data, pos)
					pos = pos + 1
					bit_pos = 8
				end
				local bit = bit32.band(bit32.rshift(current_byte, 7), 1)
				current_byte = bit32.lshift(current_byte, 1)
				bit_pos -= 1
				return bit
			end

			local runs = {}
			while true do
				local node = root
				while node and not node.symbol do
					local bit = read_bit()
					if bit == nil then
						node = nil
						break
					end
					node = node[bit]
				end
				if not node or not node.symbol then
					break
				end
				table.insert(runs, node.symbol)
			end

			local out = table.create(#runs * 2)
			for idx, len in ipairs(runs) do
				local value = len or 0
				local lo = value % 256
				local hi = (value // 256) % 256
				out[(idx - 1) * 2 + 1] = string.char(lo)
				out[(idx - 1) * 2 + 2] = string.char(hi)
			end
			return table.concat(out)
		end

		local function base64Decode(data)
			if type(data) ~= "string" then
				return nil
			end

			data = data:gsub("%s+", "")
			if data == "" or (#data % 4) ~= 0 then
				return nil
			end
			if data:find("[^%w%+/%=]") then
				return nil
			end

			local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
			local map = {}
			for i = 1, #alphabet do
				map[alphabet:sub(i, i)] = i - 1
			end

			local out = table.create(math.floor(#data * 3 / 4))
			local outLen = 0

			for i = 1, #data, 4 do
				local c1 = data:sub(i, i)
				local c2 = data:sub(i + 1, i + 1)
				local c3 = data:sub(i + 2, i + 2)
				local c4 = data:sub(i + 3, i + 3)
				local v1 = map[c1]
				local v2 = map[c2]
				if v1 == nil or v2 == nil then
					return nil
				end

				local v3 = (c3 == "=") and 0 or map[c3]
				local v4 = (c4 == "=") and 0 or map[c4]
				if v3 == nil or v4 == nil then
					return nil
				end

				local bits = bit32.lshift(v1, 18) + bit32.lshift(v2, 12) + bit32.lshift(v3, 6) + v4
				outLen += 1
				out[outLen] = string.char(bit32.band(bit32.rshift(bits, 16), 0xFF))
				if c3 ~= "=" then
					outLen += 1
					out[outLen] = string.char(bit32.band(bit32.rshift(bits, 8), 0xFF))
				end
				if c4 ~= "=" then
					outLen += 1
					out[outLen] = string.char(bit32.band(bits, 0xFF))
				end
			end

			return table.concat(out, "", 1, outLen)
		end

		local function readBadAppleChunkValue(value)
			if type(value) == "string" then
				return value, nil
			end

			if type(value) == "table" then
				if type(value.data) == "string" then
					return value.data, nil
				end
				if type(value.chunks) == "table" then
					value = value.chunks
				elseif #value == 0 then
					return nil, "unsupported chunk table"
				end

				local pieces = table.create(#value)
				for i = 1, #value do
					if type(value[i]) ~= "string" then
						return nil, ("chunk element %d is not a string"):format(i)
					end
					pieces[i] = value[i]
				end
				return table.concat(pieces), nil
			end

			return nil, ("unsupported chunk type: %s"):format(type(value))
		end

		local function readBadAppleChunkInstance(inst)
			if inst:IsA("ModuleScript") then
				local ok, value = pcall(require, inst)
				if not ok then
					return nil, value
				end
				return readBadAppleChunkValue(value)
			end
			if inst:IsA("StringValue") then
				return inst.Value or "", nil
			end
			return nil, ("unsupported chunk instance: %s"):format(inst.ClassName)
		end

		local function chunkSortKey(name)
			local n = tonumber((name or ""):match("(%d+)"))
			return n or math.huge
		end

		--payload might be split into chunks because giant roblox assets get weird fast
		local function collectBadAppleEncodedPayload()
			local chunkFolder = ReplicatedStorage:FindFirstChild("BadAppleChunks")
			if chunkFolder then
				local chunkNodes = {}
				for _, child in ipairs(chunkFolder:GetChildren()) do
					if child:IsA("ModuleScript") or child:IsA("StringValue") then
						chunkNodes[#chunkNodes + 1] = child
					end
				end
				if #chunkNodes > 0 then
					table.sort(chunkNodes, function(a, b)
						local ak = chunkSortKey(a.Name)
						local bk = chunkSortKey(b.Name)
						if ak == bk then
							return a.Name < b.Name
						end
						return ak < bk
					end)

					local pieces = table.create(#chunkNodes)
					for i, chunkNode in ipairs(chunkNodes) do
						local piece, err = readBadAppleChunkInstance(chunkNode)
						if type(piece) ~= "string" then
							return nil, ("failed to read %s: %s"):format(chunkNode.Name, tostring(err))
						end
						pieces[i] = piece
					end
					return table.concat(pieces), nil
				end
			end

			local badAppleData = ReplicatedStorage:FindFirstChild("BadAppleData")
			if badAppleData and badAppleData:IsA("ModuleScript") then
				return readBadAppleChunkInstance(badAppleData)
			end

			return nil, "BadAppleChunks/BadAppleData not found"
		end

		local function decodeBadApplePayload(payload)
			if type(payload) ~= "string" or payload == "" then
				return nil, "empty bad apple payload"
			end

			local decodedBase64 = base64Decode(payload)
			if decodedBase64 then
				payload = decodedBase64
			end

			if payload:sub(1, 4) == "BAH1" then
				local decodedHuffman = decode_bad_apple_huffman(payload)
				if not decodedHuffman then
					return nil, "failed to decode BAH1 payload"
				end
				payload = decodedHuffman
			end

			return payload, nil
		end

		local bootIniContent = "boot=/bin/sh.rov\n"
		local bootIniInode = filesystem:resolvePath("/boot/boot.ini")
		if bootIniInode then
			filesystem:writeFile(bootIniInode, bootIniContent)
		else
			filesystem:createFile("/boot/boot.ini", bootIniContent)
		end

		local shell_c = require(ReplicatedStorage.VirtualMachine.Software.Applications.Programs.shell_c)

		ensureFile("/usr/src/shell.c", shell_c)

		local bStatus = bootCallbacks and bootCallbacks.status
		local bSub = bootCallbacks and bootCallbacks.sub
		local bError = bootCallbacks and bootCallbacks.error

		local function formatBytes(n)
			if n >= 1048576 then
				return string.format("%.1f MB", n / 1048576)
			elseif n >= 1024 then
				return string.format("%.1f KB", n / 1024)
			else
				return tostring(n) .. " B"
			end
		end

		local includes = {
			["rovm.h"] = rovm_h,
			["string.h"] = string_h,
			["stdlib.h"] = stdlib_h,
			["ctype.h"] = ctype_h,
			["stdio.h"] = stdio_h,
			["math.h"] = math_h,
		}

		local badApplePayload, badApplePayloadErr = collectBadAppleEncodedPayload()
		if badApplePayload then
			local badAppleBin, decodeErr = decodeBadApplePayload(badApplePayload)
			if badAppleBin then
				ensureFile("/usr/src/badapple.bin", badAppleBin)
				ensureFile("/os/badapple.bin", badAppleBin)
				if bStatus then bStatus("Installing Bad Apple data", "ok") end
				if bSub then bSub("-> /usr/src/badapple.bin (" .. formatBytes(#badAppleBin) .. ")") end
			else
				if bStatus then bStatus("Installing Bad Apple data", "fail") end
				if bError then bError("Bad Apple decode failed: " .. tostring(decodeErr)) end
				warn("[kernel] Failed to decode Bad Apple payload:", decodeErr)
			end
		else
			if bStatus then bStatus("Installing Bad Apple data", "warn") end
			if bError then bError(tostring(badApplePayloadErr)) end
		end

		local badAppleCompressed = ReplicatedStorage:FindFirstChild("BadAppleCompressed")
		if badAppleCompressed then
			local vqModule = badAppleCompressed:FindFirstChild("BadAppleVQ")
			if vqModule and vqModule:IsA("ModuleScript") then
				local ok, vqData = pcall(require, vqModule)
				if ok and type(vqData) == "string" then
					ensureFile("/usr/src/badapple_vq.bin", vqData)
				end
			end
		end

		local shellBinPath = "/bin/sh.rov"
		--force this one because the shell changes a lot and stale caches waste time
		local forceRebuildShell = true
		local shellInode = filesystem:resolvePath(shellBinPath)
		if shellInode and not forceRebuildShell then
			local shellBin = filesystem:readFile(shellInode)
			local validShell, shellErr = validateRovBinary(shellBin)
			if validShell then
				if bStatus then bStatus("Compiling shell (/usr/src/shell.c)", "ok") end
				if bSub then bSub("-> using cached " .. shellBinPath .. " (" .. formatBytes(type(shellBin) == "string" and #shellBin or 0) .. ")") end
			else
				if bSub then bSub("-> rebuilding invalid cache " .. shellBinPath .. " (" .. tostring(shellErr) .. ")") end
				shellInode = nil
			end
		elseif forceRebuildShell and shellInode and bSub then
			bSub("-> rebuilding cached " .. shellBinPath .. " (runtime source updated)")
		end
		if not shellInode or forceRebuildShell then
			local ok, result = pcall(function()
				return CompileRequest:InvokeServer(shell_c, includes)
			end)

			if ok and result and result.success and typeof(result.output) == "string" then
				local asmSrc = result.output
				local assembleOk, code = pcall(Assembler.assemble, asmSrc)
				if assembleOk and code then
					local bin = serializeBinary(code, 0)
					writeOrCreateFile(shellBinPath, filesystem:resolvePath(shellBinPath), bin)
					if bStatus then bStatus("Compiling shell (/usr/src/shell.c)", "ok") end
					if bSub then bSub("-> " .. shellBinPath .. " (" .. formatBytes(#bin) .. ")") end
				else
					if bStatus then bStatus("Compiling shell (/usr/src/shell.c)", "fail") end
					if bError then bError("Assemble failed: " .. tostring(code)) end
					warn("[kernel] Failed to assemble shell.asm: ", tostring(code))
				end
			else
				if bStatus then bStatus("Compiling shell (/usr/src/shell.c)", "fail") end
				local errMsg = result and result.error or "Unknown error"
				if bError then bError("Compile failed: " .. errMsg) end
				warn("[kernel] Failed to compile shell.c: ", errMsg)
			end
		end

		ensureDir("/usr/bin")
		if filesystem:resolvePath("/usr/bin/atari.rov") then
			filesystem:unlink("/usr/bin/atari.rov")
		end
		if filesystem:resolvePath("/usr/bin/space_invaders.rov") then
			filesystem:unlink("/usr/bin/space_invaders.rov")
		end
		local userPrograms = {
			{ src = "/usr/src/doom.c", name = "doom" },
			{ src = "/usr/src/neofetch.c", name = "neofetch" },
			{ src = "/usr/src/cube.c", name = "cube" },
			{ src = "/usr/src/bad_apple.c", name = "bad_apple" },
			{ src = "/usr/src/benchmark.c", name = "benchmark" },
			{ src = "/usr/src/calculator.c", name = "calculator" },
			{ src = "/usr/src/python.c", name = "python", forceRebuild = true },
			{ src = "/usr/src/python.c", name = "py", forceRebuild = true },
			{ src = "/usr/src/snake.c", name = "snake" },
			{ src = "/usr/src/tetris.c", name = "tetris" },
			{ src = "/usr/src/pong.c", name = "pong" },
			{ src = "/usr/src/space_defenders.c", name = "space_defenders" },
		}
		--same compile path for the bundled apps
		--use the cache when it is valid, rebuild when the source is known to be twitchy
		for _, prog in ipairs(userPrograms) do
			local outPath = "/usr/bin/" .. prog.name .. ".rov"
			local existingInode = filesystem:resolvePath(outPath)
			if existingInode and not prog.forceRebuild then
				local existingBin = filesystem:readFile(existingInode)
				local validBinary, binaryErr = validateRovBinary(existingBin)
				if validBinary then
					if bStatus then bStatus("Compiling " .. prog.name .. " (" .. prog.src .. ")", "ok") end
					if bSub then bSub("-> using cached " .. outPath .. " (" .. formatBytes(type(existingBin) == "string" and #existingBin or 0) .. ")") end
					continue
				end
				if bSub then bSub("-> rebuilding invalid cache " .. outPath .. " (" .. tostring(binaryErr) .. ")") end
			elseif prog.forceRebuild and existingInode and bSub then
				bSub("-> rebuilding cached " .. outPath .. " (runtime source updated)")
			end

			local srcInode = filesystem:resolvePath(prog.src)
			if srcInode then
				local source = filesystem:readFile(srcInode)
				if source then
					local compileOk, compileResult = pcall(function()
						return CompileRequest:InvokeServer(source, includes)
					end)
					if compileOk and compileResult and compileResult.success and typeof(compileResult.output) == "string" then
						local assembleOk, code = pcall(Assembler.assemble, compileResult.output)
						if assembleOk and code then
							local bin = serializeBinary(code, 0)
							writeOrCreateFile(outPath, existingInode, bin)
							if bStatus then bStatus("Compiling " .. prog.name .. " (" .. prog.src .. ")", "ok") end
							if bSub then bSub("-> " .. outPath .. " (" .. formatBytes(#bin) .. ")") end
						else
							if bStatus then bStatus("Compiling " .. prog.name .. " (" .. prog.src .. ")", "fail") end
							if bError then bError("Assemble failed: " .. tostring(code)) end
							warn("[kernel] Failed to assemble " .. prog.name .. ": ", tostring(code))
						end
					else
						if bStatus then bStatus("Compiling " .. prog.name .. " (" .. prog.src .. ")", "fail") end
						local errMsg = compileResult and compileResult.error or "Unknown error"
						if bError then bError("Compile failed: " .. errMsg) end
						warn("[kernel] Failed to compile " .. prog.src .. ": ", errMsg)
					end
				end
			end
		end
	end

	return self
end

return SystemImageBuilder
