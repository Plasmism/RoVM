--!native

local RunService = game:GetService("RunService")

local SyscallDispatcher = {}
SyscallDispatcher.__index = SyscallDispatcher

--one giant syscall switch on purpose so process/memory bugs have fewer caves to hide in
function SyscallDispatcher.new(deps)
	local self = setmetatable({}, SyscallDispatcher)

	local C = deps.C
	local CPU = deps.CPU
	local Process = deps.Process
	local PageTable = deps.PageTable
	local FileHandle = deps.FileHandle
	local Filesystem = deps.Filesystem
	local Assembler = deps.Assembler
	local CompileRequest = deps.CompileRequest
	local DEFAULT_CPU_MODE = deps.DEFAULT_CPU_MODE
	local VM_PAGE_SIZE = deps.VM_PAGE_SIZE
	local PROCESS_STACK_PAGES = deps.PROCESS_STACK_PAGES
	local WIDTH = deps.WIDTH
	local HEIGHT = deps.HEIGHT
	local TEXT_BASE = deps.TEXT_BASE
	local IO_BASE = deps.IO_BASE
	local CTRL_BASE = deps.CTRL_BASE
	local GPU_BASE = deps.GPU_BASE

	--tty writes stay tiny and dumb
	--newline flushes immediately because of interactive stuff
	local function writeTTYByte(ch)
		deps.kwrite(C["SYS_TEXT_WRITE"], ch)
		deps.setTTYDirty(true)
		if ch == 10 then
			deps.flushTTY()
		end
	end

	local function writeTTYString(str)
		for i = 1, #str do
			writeTTYByte(string.byte(str, i))
		end
	end

	--grab live deps each call because reboot swaps half this state out from under us
	function self:handleSyscall(trapInfo)
		local scheduler = deps.getScheduler()
		local cpu = deps.getCpu()
		local mem = deps.getMem()
		local filesystem = deps.getFilesystem()
		local ioDev = deps.getIoDev()
		local mmu = deps.getMMU()
		local presentIfRequested = deps.presentIfRequested

		local n = trapInfo.n
		local currentProc = scheduler:getCurrentProcess()
		local currentCpu = currentProc and currentProc.cpu or cpu

		if not mem then
			return
		end

		if n == C["SC_WRITE_CHAR"] then
			local ch = currentCpu.reg[1] or 0
			writeTTYByte(ch)
			return

		elseif n == C["SC_READ_CHAR"] then
			deps.flushTTY()
			local avail = deps.kread(C["SYS_IO_AVAIL"])
			while avail == 0 do
				task.wait()
				if not deps.isPoweredOn() or not deps.getMem() or currentCpu.trap then
					currentCpu.reg[1] = 0
					return
				end
				avail = deps.kread(C["SYS_IO_AVAIL"])
			end
			currentCpu.reg[1] = deps.kread(C["SYS_IO_READ"])
			return

		elseif n == C["SC_READ_CHAR_NOWAIT"] then
			local avail = deps.kread(C["SYS_IO_AVAIL"])
			if avail > 0 then
				currentCpu.reg[1] = deps.kread(C["SYS_IO_READ"])
			else
				currentCpu.reg[1] = 0
			end
			return

		elseif n == C["SC_KEY_DOWN"] then
			local code = bit32.band(currentCpu.reg[1] or 0, 0xFF)
			if ioDev and ioDev.IsControlDown and ioDev:IsControlDown(code) then
				currentCpu.reg[1] = 1
			else
				currentCpu.reg[1] = 0
			end
			return

		elseif n == C["SC_KEY_PRESSED"] then
			local code = bit32.band(currentCpu.reg[1] or 0, 0xFF)
			if ioDev and ioDev.ConsumeControlPressed and ioDev:ConsumeControlPressed(code) then
				currentCpu.reg[1] = 1
			else
				currentCpu.reg[1] = 0
			end
			return

		elseif n == C["SC_FLUSH"] then
			if deps.getTTYDirty() then
				deps.flushTTY()
			else
				deps.requestFramebufferFlush()
			end
			return

		elseif n == C["SC_EXIT"] then
			deps.flushTTY()
			deps.clearSharedInput()
			local exitCode = currentCpu.reg[1] or 0
			if currentProc then
				currentProc:terminate(exitCode)
				currentCpu.trap = { kind = "halt", msg = "exit syscall", pc = trapInfo.pc }
				if currentProc.waitingPid then
					local parent = scheduler:getProcess(currentProc.waitingPid)
					if parent then
						parent.cpu.reg[1] = exitCode
						scheduler:unblock(currentProc.waitingPid)
					end
				end
			else
				currentCpu.trap = { kind = "halt", msg = "exit syscall", pc = trapInfo.pc }
				currentCpu.running = false
			end
			return

		elseif n == C["SC_REBOOT"] then
			deps.flushTTY()
			deps.kwrite(C["SYS_CTRL_REBOOT"], 1)
			return

		elseif n == C["SC_TEXT_CLEAR"] then
			deps.kwrite(TEXT_BASE + 0, 0)
			deps.kwrite(TEXT_BASE + 1, 0)
			deps.kwrite(TEXT_BASE + 5, 1)
			deps.setTTYDirty(false)
			deps.kwrite(CTRL_BASE + 1, 1)
			return

		elseif n == C["SC_TEXT_SET_CX"] then
			deps.kwrite(TEXT_BASE + 0, currentCpu.reg[1] or 0)
			return

		elseif n == C["SC_TEXT_SET_CY"] then
			deps.kwrite(TEXT_BASE + 1, currentCpu.reg[1] or 0)
			return

		elseif n == C["SC_TEXT_SET_FG"] then
			deps.kwrite(TEXT_BASE + 2, currentCpu.reg[1] or 0)
			return

		elseif n == C["SC_TEXT_SET_BG"] then
			deps.kwrite(TEXT_BASE + 3, currentCpu.reg[1] or 0)
			return

		elseif n == C["SC_GETPID"] then
			if currentProc then
				currentCpu.reg[1] = currentProc.pid
			else
				currentCpu.reg[1] = 0
			end
			return

		elseif n == C["SC_FORK"] then
			if not currentProc or not currentProc.pageTable then
				currentCpu.trap = {
					kind = "fault",
					type = "bad_syscall",
					msg = "FORK: no current process or page table",
				}
				currentCpu.running = false
				return
			end

			local newPid = scheduler:allocatePid()
			local newCpu = CPU.new(mem)

			for i = 1, #currentCpu.reg do
				newCpu.reg[i] = currentCpu.reg[i]
			end
			newCpu.pc = currentCpu.pc
			newCpu.mode = DEFAULT_CPU_MODE
			newCpu.running = true
			newCpu.strictExecute = currentCpu.strictExecute
			newCpu:setDecodeSegments(deps.cloneDecodeSegments(currentCpu.decodeSegments))

			local newPageTable = currentProc.pageTable:fork(newPid)
			local newProc = Process.new(newPid, newCpu, currentProc.memoryRegion, newPageTable)
			newProc.parentPid = currentProc.pid
			newProc.imagePath = currentProc.imagePath
			newProc._heapBreak = currentProc._heapBreak
			newProc._heapMinBreak = currentProc._heapMinBreak
			if currentProc._loadedRovds then
				newProc._loadedRovds = {}
				for path, info in pairs(currentProc._loadedRovds) do
					newProc._loadedRovds[path] = info
				end
			end
			table.insert(currentProc.children, newPid)

			scheduler:addProcess(newProc)

			currentCpu.reg[1] = newPid
			newCpu.reg[1] = 0
			currentCpu.mode = DEFAULT_CPU_MODE
			newCpu.mode = DEFAULT_CPU_MODE

			return

		elseif n == C["SC_EXEC"] then
			--exec is the rude one: keep the pid, throw out the old image, rebuild the stack, pretend nothing ever happened
			if not filesystem or not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local argvPtr = currentCpu.reg[2] or 0
			local envpPtr = currentCpu.reg[3] or 0
			local path = deps.userReadString(pathPtr)

			if not path or path == "" then
				warn("[kernel] EXEC failed: empty path")
				currentCpu.reg[1] = -1
				return
			end

			local code, err, entryPoint, imageInfo = deps.loadProgramFromFile(path)
			if not code then
				warn("[kernel] EXEC failed for ", path, ": ", err)
				currentCpu.reg[1] = -1
				return
			end
			currentProc.imagePath = path
			entryPoint = entryPoint or 0
			local codeLenForEntry = buffer.len(code)
			local execVirtualMemSize = deps.getProcessVirtualMemorySize(currentProc)
			if entryPoint >= codeLenForEntry or entryPoint >= execVirtualMemSize then
				warn("[kernel] EXEC failed for ", path, ": invalid entry point ", entryPoint, " (code size ", codeLenForEntry, ")")
				currentCpu.reg[1] = -1
				return
			end

			local argvStrings = {}
			local envStrings = {}
			local argc = 0

			if argvPtr == 0 then
				argvStrings[1] = path
				argc = 1
			else
				for i = 0, 31 do
					local argPtr, fault = deps.userReadWord(argvPtr + i * 4)
					if fault then
						currentCpu.reg[1] = -1
						return
					end
					if argPtr == 0 then
						break
					end
					local argStr = deps.userReadString(argPtr)
					if not argStr then
						currentCpu.reg[1] = -1
						return
					end
					argvStrings[#argvStrings + 1] = argStr
				end
				argc = #argvStrings
				if argc == 0 then
					argvStrings[1] = path
					argc = 1
				end
			end

			if envpPtr ~= 0 then
				for i = 0, 31 do
					local envPtr, fault = deps.userReadWord(envpPtr + i * 4)
					if fault then
						currentCpu.reg[1] = -1
						return
					end
					if envPtr == 0 then
						break
					end
					local envStr = deps.userReadString(envPtr)
					if not envStr then
						currentCpu.reg[1] = -1
						return
					end
					envStrings[#envStrings + 1] = envStr
				end
			end

			currentProc.appWindow = nil
			currentProc._appWindowLastClickSeq = nil
			currentProc._appWindowDragging = nil
			currentProc._appWindowLastMouseX = nil
			currentProc._appWindowLastMouseY = nil
			currentProc._loadedRovds = nil

			mem:setMode(CPU.MODE_KERNEL)
			local oldMode = currentCpu.mode
			currentCpu.mode = CPU.MODE_KERNEL

			if not currentProc.pageTable then
				mem:setMode(oldMode)
				currentCpu.reg[1] = -1
				return
			end

			mmu:setPageTable(currentProc.pageTable)

			local virtualMemSize = deps.getProcessVirtualMemorySize(currentProc)
			local pageSize = VM_PAGE_SIZE
			local codeLen = buffer.len(code)
			local numProgramPages = math.ceil(codeLen / pageSize)
			local totalVPages = math.floor(virtualMemSize / pageSize)
			local cowPagesToResolve = {}
			--code pages plus stack pages need private backing first or forked state gets weird
			for vp = 0, numProgramPages - 1 do
				cowPagesToResolve[vp] = true
			end
			for vp = math.max(0, totalVPages - PROCESS_STACK_PAGES), totalVPages - 1 do
				cowPagesToResolve[vp] = true
			end

			for vp in pairs(cowPagesToResolve) do
				if currentProc.pageTable.entries[vp] and currentProc.pageTable:isCow(vp) then
					local ok, err2 = mmu:handleCowFault(vp * pageSize, mem)
					if not ok then
						warn("[kernel] EXEC: Failed to resolve COW on page ", vp, ": ", err2)
						mem:setMode(oldMode)
						currentCpu.reg[1] = -1
						return
					end
				end
			end

			local pagesToUnmap = {}
			for vp in pairs(currentProc.pageTable.entries) do
				if not cowPagesToResolve[vp] then
					table.insert(pagesToUnmap, vp)
				end
			end
			for _, vp in ipairs(pagesToUnmap) do
				currentProc.pageTable:unmapPage(vp)
			end

			local perms = PageTable.PERM_READ + PageTable.PERM_WRITE
			local dataEndPage = totalVPages - PROCESS_STACK_PAGES
			for vp = numProgramPages, dataEndPage - 1 do
				if not currentProc.pageTable.entries[vp] then
					local ok = currentProc.pageTable:mapPage(vp, nil, perms)
					if not ok then
						break
					end
				end
			end
			for vp = math.max(0, totalVPages - PROCESS_STACK_PAGES), totalVPages - 1 do
				if not currentProc.pageTable.entries[vp] then
					local ok = currentProc.pageTable:mapPage(vp, nil, perms)
					if not ok then
						break
					end
				end
			end

			if codeLen > virtualMemSize then
				warn("[kernel] EXEC failed for ", path, ": program too large to load (", codeLen, " bytes > ", virtualMemSize, ")")
				mem:setMode(oldMode)
				currentCpu.reg[1] = -1
				return
			end

			local copyOk, copyErr = deps.copyBufferIntoProcess(currentProc.pageTable, 0, code)
			if not copyOk then
				warn("[kernel] EXEC failed for ", path, ": failed to copy image: ", copyErr)
				mem:setMode(oldMode)
				currentCpu.reg[1] = -1
				return
			end
			deps.applyBinaryPermissions(currentProc.pageTable, 0, codeLen, imageInfo)
			currentCpu.mode = DEFAULT_CPU_MODE
			mem:setMode(DEFAULT_CPU_MODE)

			local sp = virtualMemSize
			local argvAddrs = {}
			local envAddrs = {}

			--strings go on first, then pointer tables, then we align back to 4 because 3*4=12 and words matter
			local function pushString(str)
				local bytes = { string.byte(str, 1, #str) }
				sp -= (#bytes + 1)
				for i = 1, #bytes do
					local ok, fault = deps.userWriteByte(sp + i - 1, bytes[i])
					if not ok then
						return nil, fault
					end
				end
				local ok, fault = deps.userWriteByte(sp + #bytes, 0)
				if not ok then
					return nil, fault
				end
				return sp, nil
			end

			for i = #envStrings, 1, -1 do
				local addr = pushString(envStrings[i])
				if not addr then
					currentCpu.reg[1] = -1
					return
				end
				envAddrs[i] = addr
			end

			for i = #argvStrings, 1, -1 do
				local addr = pushString(argvStrings[i])
				if not addr then
					currentCpu.reg[1] = -1
					return
				end
				argvAddrs[i] = addr
			end

			sp = bit32.band(sp, 0xFFFFFFFC)

			sp -= (#envAddrs + 1) * 4
			local envpOut = sp
			for i = 1, #envAddrs do
				local ok = deps.userWriteWord(envpOut + (i - 1) * 4, envAddrs[i])
				if not ok then
					currentCpu.reg[1] = -1
					return
				end
			end
			deps.userWriteWord(envpOut + #envAddrs * 4, 0)

			sp -= (#argvAddrs + 1) * 4
			local argvOut = sp
			for i = 1, #argvAddrs do
				local ok = deps.userWriteWord(argvOut + (i - 1) * 4, argvAddrs[i])
				if not ok then
					currentCpu.reg[1] = -1
					return
				end
			end
			deps.userWriteWord(argvOut + #argvAddrs * 4, 0)

			currentCpu.pc = entryPoint
			currentCpu.running = true
			for i = 1, #currentCpu.reg do
				currentCpu.reg[i] = 0
			end
			currentCpu.reg[1] = argc
			currentCpu.reg[2] = argvOut
			currentCpu.reg[3] = envpOut
			currentCpu.reg[15 + 1] = sp
			currentCpu.mode = DEFAULT_CPU_MODE
			currentCpu.trap = nil
			deps.installCpuImageLayout(currentCpu, code, imageInfo, 0, true)
			currentProc._heapMinBreak = math.floor((codeLen + (VM_PAGE_SIZE - 1)) / VM_PAGE_SIZE) * VM_PAGE_SIZE
			currentProc._heapBreak = currentProc._heapMinBreak

			mem:setMode(currentCpu.mode)
			if ioDev and ioDev.ClearInput then
				ioDev:ClearInput()
			end
			return

		elseif n == C["SC_WAIT"] then
			--reap zombies first so the parent does not go to sleep for no reason
			if not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local zombieChild = nil
			for _, childPid in ipairs(currentProc.children) do
				local child = scheduler:getProcess(childPid)
				if child and child.state == Process.STATE_ZOMBIE then
					zombieChild = child
					break
				end
			end

			if zombieChild then
				currentCpu.reg[1] = zombieChild.exitCode or 0
				scheduler:removeProcess(zombieChild.pid)
				for i = #currentProc.children, 1, -1 do
					if currentProc.children[i] == zombieChild.pid then
						table.remove(currentProc.children, i)
					end
				end
			else
				if #currentProc.children > 0 then
					scheduler:blockCurrent("waiting_for_child")
					for _, childPid in ipairs(currentProc.children) do
						local child = scheduler:getProcess(childPid)
						if child then
							child.waitingPid = currentProc.pid
						end
					end
				else
					currentCpu.reg[1] = -1
				end
			end
			return

		elseif n == C["SC_KILL"] then
			local targetPid = currentCpu.reg[1] or 0
			local targetProc = scheduler:getProcess(targetPid)

			if not targetProc then
				currentCpu.reg[1] = -1
				return
			end

			targetProc:terminate(1)
			if targetProc.state == Process.STATE_BLOCKED then
				scheduler:unblock(targetPid)
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_OPEN"] then
			if not filesystem or not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local mode = currentCpu.reg[2] or 0

			local path, pathFault = deps.userReadString(pathPtr)
			if pathFault then
				currentCpu.reg[1] = -1
				return
			end
			if path == "" then
				currentCpu.reg[1] = -1
				return
			end

			local inode, err = filesystem:resolvePath(path)
			if not inode then
				if bit32.band(mode, FileHandle.MODE_CREATE) ~= 0 then
					inode = filesystem:createFile(path, "")
					if not inode then
						currentCpu.reg[1] = -1
						return
					end
				else
					currentCpu.reg[1] = -1
					return
				end
			end

			local stat = filesystem:stat(inode)
			if stat and stat.type == Filesystem.TYPE_DIR then
				currentCpu.reg[1] = -1
				return
			end

			local fd = currentProc.files:open(inode, mode)
			if not fd then
				currentCpu.reg[1] = -1
				return
			end

			currentCpu.reg[1] = fd
			return

		elseif n == C["SC_READ"] then
			--device fds short circuit here, normal files fall back to string backed inode reads
			if not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local fd = currentCpu.reg[1] or 0
			local bufPtr = currentCpu.reg[2] or 0
			local count = currentCpu.reg[3] or 0

			local handle = currentProc.files:get(fd)
			if not handle then
				currentCpu.reg[1] = -1
				return
			end

			local inodeData = filesystem.inodes[handle.inode]
			if inodeData and inodeData.type == Filesystem.TYPE_DEV then
				local devId = inodeData.data
				if devId == "tty" then
					local avail = deps.kread(C["SYS_IO_AVAIL"])
					if avail <= 0 then
						currentCpu.reg[1] = 0
						return
					end
					local byte = deps.kread(C["SYS_IO_READ"])
					local ok, wfault = deps.userWriteByte(bufPtr, byte)
					if not ok then
						if wfault == "cow_fault" then
							local cowOk = mmu:handleCowFault(bufPtr, mem)
							if cowOk then
								deps.userWriteByte(bufPtr, byte)
							end
						end
					end
					currentCpu.reg[1] = 1
					return
				end
				currentCpu.reg[1] = 0
				return
			end

			local data = filesystem:readFile(handle.inode)
			if not data then
				currentCpu.reg[1] = -1
				return
			end

			local startPos = handle.position + 1
			local endPos = math.min(startPos + count - 1, #data)
			local bytesRead = math.max(0, endPos - startPos + 1)

			if bytesRead > 0 then
				local chunk = data:sub(startPos, endPos)
				for i = 1, #chunk do
					local ok, wfault = deps.userWriteByte(bufPtr + i - 1, string.byte(chunk, i))
					if not ok then
						if wfault == "cow_fault" then
							local cowOk = mmu:handleCowFault(bufPtr + i - 1, mem)
							if cowOk then
								deps.userWriteByte(bufPtr + i - 1, string.byte(chunk, i))
							end
						end
					end
				end
				handle.position = endPos
			end

			currentCpu.reg[1] = bytesRead
			return

		elseif n == C["SC_WRITE"] then
			--stdout stderr and tty all collapse into the same text path here
			--gpu writes are handled somewhere else
			if not filesystem or not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local fdRaw = currentCpu.reg[1] or 0
			local fd = deps.toSigned32(fdRaw)
			local bufPtr = currentCpu.reg[2] or 0
			local count = currentCpu.reg[3] or 0

			local data = {}
			for i = 0, count - 1 do
				local byte, fault = deps.userReadByte(bufPtr + i)
				if fault then
					currentCpu.reg[1] = -1
					return
				end
				data[#data + 1] = string.char(byte)
			end
			local writeData = table.concat(data)

			if fd == -2 or fd == -3 then
				writeTTYString(writeData)
				currentCpu.reg[1] = #writeData
				return
			end

			local handle = currentProc.files:get(fd)
			if not handle then
				currentCpu.reg[1] = -1
				return
			end

			local inodeData = filesystem.inodes[handle.inode]
			if inodeData and inodeData.type == Filesystem.TYPE_DEV then
				local devId = inodeData.data
				if devId == "tty" then
					writeTTYString(writeData)
					currentCpu.reg[1] = #writeData
					return
				elseif devId == "gpu" then
					currentCpu.reg[1] = #writeData
					return
				end
				currentCpu.reg[1] = #writeData
				return
			end

			local currentData = filesystem:readFile(handle.inode)
			if not currentData then
				currentCpu.reg[1] = -1
				return
			end

			if bit32.band(handle.mode, FileHandle.MODE_APPEND) ~= 0 then
				currentData = currentData .. writeData
				handle.position = #currentData
			else
				local before = currentData:sub(1, handle.position)
				local after = currentData:sub(handle.position + #writeData + 1)
				currentData = before .. writeData .. after
				handle.position = handle.position + #writeData
			end

			local ok, err = filesystem:writeFile(handle.inode, currentData)
			if not ok then
				print("[WRITE DEBUG] writeFile failed:", err)
				currentCpu.reg[1] = -1
				return
			end

			local verifyData, verifyErr = filesystem:readFile(handle.inode)
			if not verifyData then
				print("[WRITE DEBUG] Could not verify file contents:", verifyErr)
			end

			currentCpu.reg[1] = #writeData
			return

		elseif n == C["SC_CLOSE"] then
			if not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local fd = deps.toSigned32(currentCpu.reg[1] or 0)
			local ok = currentProc.files:close(fd)
			if not ok then
				currentCpu.reg[1] = -1
				return
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_SEEK"] then
			if not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local fd = deps.toSigned32(currentCpu.reg[1] or 0)
			local offset = deps.toSigned32(currentCpu.reg[2] or 0)
			local whence = currentCpu.reg[3] or 0

			local handle = currentProc.files:get(fd)
			if not handle then
				currentCpu.reg[1] = -1
				return
			end

			local data = filesystem:readFile(handle.inode)
			if not data then
				currentCpu.reg[1] = -1
				return
			end

			local newPos = 0
			if whence == 0 then
				newPos = offset
			elseif whence == 1 then
				newPos = handle.position + offset
			elseif whence == 2 then
				newPos = #data + offset
			end

			newPos = math.max(0, math.min(newPos, #data))
			handle.position = newPos
			currentCpu.reg[1] = newPos
			return

		elseif n == C["SC_UNLINK"] then
			if not filesystem then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local path = deps.userReadString(pathPtr)
			if not path or path == "" then
				currentCpu.reg[1] = -1
				return
			end

			local ok = filesystem:unlink(path)
			if not ok then
				currentCpu.reg[1] = -1
				return
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_MKDIR"] then
			if not filesystem then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local path = deps.userReadString(pathPtr)
			if not path or path == "" then
				currentCpu.reg[1] = -1
				return
			end

			local inode = filesystem:createDirectory(path)
			if not inode then
				currentCpu.reg[1] = -1
				return
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_RMDIR"] then
			if not filesystem then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local path = deps.userReadString(pathPtr)
			if not path or path == "" then
				currentCpu.reg[1] = -1
				return
			end

			local inode = filesystem:resolvePath(path)
			if not inode then
				currentCpu.reg[1] = -1
				return
			end

			local stat = filesystem:stat(inode)
			if not stat or stat.type ~= Filesystem.TYPE_DIR then
				currentCpu.reg[1] = -1
				return
			end

			local ok = filesystem:unlink(path)
			if not ok then
				currentCpu.reg[1] = -1
				return
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_LISTDIR"] then
			if not filesystem then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local bufPtr = currentCpu.reg[2] or 0
			local bufSize = currentCpu.reg[3] or 0

			local path = deps.userReadString(pathPtr)
			if not path or path == "" then
				path = "/"
			end

			local inode = filesystem:resolvePath(path)
			if not inode then
				currentCpu.reg[1] = -1
				return
			end

			local entries = filesystem:listDirectory(inode)
			if not entries then
				currentCpu.reg[1] = -1
				return
			end

			local written = 0
			local pos = bufPtr

			local function safeWriteByte(vaddr, b)
				local ok, wfault = deps.userWriteByte(vaddr, b)
				if not ok and wfault == "cow_fault" then
					if mmu:handleCowFault(vaddr, mem) then
						deps.userWriteByte(vaddr, b)
					end
				end
			end

			for i = 0, bufSize - 1 do
				safeWriteByte(bufPtr + i, 0)
			end

			for _, entry in ipairs(entries) do
				local name = entry.name
				if entry.type == Filesystem.TYPE_DIR then
					name = name .. "/"
				end

				if pos + #name + 2 > bufPtr + bufSize then
					break
				end

				for i = 1, #name do
					safeWriteByte(pos, string.byte(name, i))
					pos += 1
				end
				safeWriteByte(pos, 10)
				pos += 1
				written += 1
			end

			safeWriteByte(pos, 0)
			currentCpu.reg[1] = written
			return

		elseif n == C["SC_STAT"] then
			if not filesystem then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local statBufPtr = currentCpu.reg[2] or 0

			local path = deps.userReadString(pathPtr)
			if not path or path == "" then
				currentCpu.reg[1] = -1
				return
			end
			local inode = filesystem:resolvePath(path)
			if not inode then
				currentCpu.reg[1] = -1
				return
			end

			local stat = filesystem:stat(inode)
			if not stat then
				currentCpu.reg[1] = -1
				return
			end

			local function writeUser32(vaddr, val)
				for i = 0, 3 do
					local b = bit32.band(bit32.rshift(val, i * 8), 0xFF)
					local ok, wfault = deps.userWriteByte(vaddr + i, b)
					if not ok and wfault == "cow_fault" then
						if mmu:handleCowFault(vaddr + i, mem) then
							deps.userWriteByte(vaddr + i, b)
						end
					end
				end
			end

			writeUser32(statBufPtr, stat.inode)
			writeUser32(statBufPtr + 4, stat.type)
			writeUser32(statBufPtr + 8, stat.size)
			writeUser32(statBufPtr + 12, stat.permissions)

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_ASSEMBLE"] then
			if not filesystem or not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local srcPtr = currentCpu.reg[1] or 0
			local outPtr = currentCpu.reg[2] or 0
			local srcPath, srcFault = deps.userReadString(srcPtr)
			if srcFault or not srcPath or srcPath == "" then
				currentCpu.reg[1] = -1
				return
			end

			local outPath = nil
			if outPtr ~= 0 then
				local outFault = nil
				outPath, outFault = deps.userReadString(outPtr)
				if outFault then
					currentCpu.reg[1] = -1
					return
				end
				if outPath == "" then
					outPath = nil
				end
			end
			if not outPath then
				if srcPath:sub(-4) == ".asm" then
					outPath = srcPath:sub(1, -5) .. ".rov"
				else
					outPath = srcPath .. ".rov"
				end
			end

			local inode = filesystem:resolvePath(srcPath)
			if not inode then
				currentCpu.reg[1] = -1
				return
			end
			local data = filesystem:readFile(inode)
			if not data then
				currentCpu.reg[1] = -1
				return
			end

			local function includeCallback(path)
				local isSystem = path:sub(1, 1) == "<"
				local cleanPath = path:sub(2, -2)
				local incInode

				if isSystem then
					incInode = filesystem:resolvePath("/usr/include/" .. cleanPath)
				else
					local dir = srcPath:match("(.*/)") or ""
					incInode = filesystem:resolvePath(dir .. cleanPath)
					if not incInode then
						incInode = filesystem:resolvePath("/usr/include/" .. cleanPath)
					end
				end

				if not incInode then
					error("file not found: " .. path)
				end
				local incData = filesystem:readFile(incInode)
				if not incData then
					error("read failed: " .. path)
				end
				return incData
			end

			local ok, codeOrErr = pcall(Assembler.assemble, data, includeCallback)
			if not ok or not codeOrErr then
				warn("[kernel] ASSEMBLE failed: ", codeOrErr)
				currentCpu.reg[1] = -1
				return
			end

			local binary = deps.serializeBinary(codeOrErr, 0)
			local outInode = filesystem:resolvePath(outPath)
			if not outInode then
				outInode = filesystem:createFile(outPath, "")
				if not outInode then
					currentCpu.reg[1] = -1
					return
				end
			end
			local writeOk = filesystem:writeFile(outInode, binary)
			if not writeOk then
				currentCpu.reg[1] = -1
				return
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_COMPILE"] then
			if not filesystem or not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local srcPtr = currentCpu.reg[1] or 0
			local outPtr = currentCpu.reg[2] or 0
			local srcPath = deps.userReadString(srcPtr)
			if not srcPath or srcPath == "" then
				currentCpu.reg[1] = -1
				return
			end

			local outPath = nil
			if outPtr ~= 0 then
				outPath = deps.userReadString(outPtr)
			end
			if not outPath or outPath == "" then
				if srcPath:sub(-2) == ".c" then
					outPath = srcPath:sub(1, -3) .. ".asm"
				else
					outPath = srcPath .. ".asm"
				end
			end

			local srcInode = filesystem:resolvePath(srcPath)
			if not srcInode then currentCpu.reg[1] = -1; return end
			local source = filesystem:readFile(srcInode)
			if not source then currentCpu.reg[1] = -1; return end

			local includes = {}
			local function bundle(path)
				local inode = filesystem:resolvePath(path)
				if not inode or includes[path] then return end
				local data = filesystem:readFile(inode)
				if not data then return end
				includes[path] = data

				for incPath in data:gmatch('#include%s+["<]([^">]+)[">]') do
					local fullPath
					if data:find('#include%s+<' .. incPath .. '>') then
						fullPath = "/usr/include/" .. incPath
					else
						local dir = path:match("(.*/)") or ""
						fullPath = dir .. incPath
						if not filesystem:resolvePath(fullPath) then
							fullPath = "/usr/include/" .. incPath
						end
					end
					bundle(fullPath)
				end
			end

			local function collectIncludes(content, currentFilePath)
				for style, incPath in content:gmatch('#include%s+([<"])([^">]+)[">]') do
					local fullPath
					if style == "<" then
						fullPath = "/usr/include/" .. incPath
					else
						local dir = currentFilePath:match("(.*/)") or ""
						fullPath = dir .. incPath
						if not filesystem:resolvePath(fullPath) then
							fullPath = "/usr/include/" .. incPath
						end
					end

					if not includes[incPath] then
						local inode = filesystem:resolvePath(fullPath)
						if inode then
							local data = filesystem:readFile(inode)
							if data then
								includes[incPath] = data
								collectIncludes(data, fullPath)
							end
						end
					end
				end
			end

			collectIncludes(source, srcPath)

			local response = CompileRequest:InvokeServer(source, includes)
			if response and response.success and typeof(response.output) == "string" then
				local outInode = filesystem:resolvePath(outPath)
				if not outInode then
					outInode = filesystem:createFile(outPath, "")
				end
				if outInode then
					filesystem:writeFile(outInode, response.output)
					currentCpu.reg[1] = 0
				else
					currentCpu.reg[1] = -1
				end
			else
				local msg = response and (response.error or "Invalid output") or "Unknown error"
				if response and response.file then
					msg = string.format("%s:%d:%d: error: %s", response.file, response.line, response.col, response.error)
				end

				local fullMsg = "cc: " .. msg .. "\n"
				writeTTYString(fullMsg)
				deps.flushTTY()

				warn("[kernel] COMPILE failed: ", msg)
				currentCpu.reg[1] = -1
			end
			return

		elseif n == C["SC_EDIT"] then
			if not filesystem or not currentProc then
				currentCpu.reg[1] = -1
				return
			end

			local pathPtr = currentCpu.reg[1] or 0
			local path, pathFault = deps.userReadString(pathPtr)
			if pathFault or not path or path == "" then
				currentCpu.reg[1] = -1
				return
			end

			local lines = { "" }
			local cursorR, cursorC = 1, 1
			local scrollY = 0
			local mode = "NORMAL"
			local commandBuf = ""
			local statusMsg = ""
			local dirty = false
			local running = true
			local mouseEnabled = true
			local lastKey = 0
			local prevKey = 0
			local yankBuf = ""
			local undoBuf = {}
			local redoBuf = {}
			local lastClickSeq = deps.kread(IO_BASE + 6)
			local termW, termH = math.floor(WIDTH / 10), math.floor(HEIGHT / 10)
			local isDraggingScroll = false
			local autoScrollTimer = 0
			local selStartR, selStartC = nil, nil
			local selEndR, selEndC = nil, nil
			local isDraggingText = false

			local function cloneLines()
				local t = {}
				for i, v in ipairs(lines) do t[i] = v end
				return t
			end

			local function snapshot()
				table.insert(undoBuf, cloneLines())
				if #undoBuf > 50 then table.remove(undoBuf, 1) end
				table.clear(redoBuf)
			end

			local function performUndo()
				if #undoBuf > 0 then
					table.insert(redoBuf, cloneLines())
					lines = table.remove(undoBuf, #undoBuf)
					cursorR = math.min(cursorR, #lines)
					cursorC = math.min(cursorC, #lines[cursorR] + 1)
					dirty = true
					statusMsg = "Undo"
					return true
				end
				statusMsg = "Already at oldest change"
				return false
			end

			local function performRedo()
				if #redoBuf > 0 then
					table.insert(undoBuf, cloneLines())
					lines = table.remove(redoBuf, #redoBuf)
					cursorR = math.min(cursorR, #lines)
					cursorC = math.min(cursorC, #lines[cursorR] + 1)
					dirty = true
					statusMsg = "Redo"
					return true
				end
				statusMsg = "Already at newest change"
				return false
			end

			local function clearSelection()
				selStartR, selStartC = nil, nil
				selEndR, selEndC = nil, nil
			end

			local function getSelection()
				if not selStartR or not selEndR then return nil end
				local sR, sC = selStartR, selStartC
				local eR, eC = selEndR, selEndC
				if sR > eR or (sR == eR and sC > eC) then
					return eR, eC, sR, sC
				else
					return sR, sC, eR, eC
				end
			end

			local function isSelected(r, c)
				local sR, sC, eR, eC = getSelection()
				if not sR then return false end
				if r < sR or r > eR then return false end
				if r > sR and r < eR then return true end
				if sR == eR then return c >= sC and c < eC end
				if r == sR then return c >= sC end
				if r == eR then return c < eC end
				return false
			end

			local function deleteSelection()
				local sR, sC, eR, eC = getSelection()
				if not sR or (sR == eR and sC == eC) then return false end

				snapshot()
				local startLine = lines[sR]
				local endLine = lines[eR]

				local prefix = startLine:sub(1, sC - 1)
				local suffix = endLine:sub(eC)

				for i = eR, sR + 1, -1 do
					table.remove(lines, i)
				end
				lines[sR] = prefix .. suffix

				cursorR = sR
				cursorC = sC
				clearSelection()
				dirty = true
				return true
			end

			local function getLNW() return math.max(4, #tostring(#lines)) + 1 end

			deps.kwrite(IO_BASE + 13, 1)

			local inode = filesystem:resolvePath(path)
			if inode then
				local data = filesystem:readFile(inode)
				if data then
					lines = {}
					for line in (data .. "\n"):gmatch("([^\n]*)\n") do
						table.insert(lines, line)
					end
					if #lines == 0 then table.insert(lines, "") end
				end
			end

			local function setCursor(r, c)
				deps.kwrite(TEXT_BASE + 0, c - 1)
				deps.kwrite(TEXT_BASE + 1, r - 1)
			end

			local function setColor(fg, bg)
				deps.kwrite(TEXT_BASE + 2, fg or 0x000000)
				deps.kwrite(TEXT_BASE + 3, bg or 0x000000)
			end

			local function findMatchingBracket(r, c)
				local line = lines[r]
				if not line then return nil, nil end
				local char = line:sub(c, c)

				local pairs = { ["("] = ")", ["["] = "]", ["{"] = "}", [")"] = "(", ["]"] = "[", ["}"] = "{" }
				local target = pairs[char]
				if not target then return nil, nil end

				local dir = (char == "(" or char == "[" or char == "{") and 1 or -1
				local level = 0
				local currR, currC = r, c

				while true do
					local currLine = lines[currR]
					if dir == 1 then
						currC = currC + 1
						if currC > #currLine then
							currR = currR + 1
							currC = 1
							if currR > #lines then break end
							currLine = lines[currR]
						end
					else
						currC = currC - 1
						if currC < 1 then
							currR = currR - 1
							if currR < 1 then break end
							currLine = lines[currR]
							currC = #currLine
						end
					end

					local check = currLine:sub(currC, currC)
					if check == char then
						level = level + 1
					elseif check == target:sub(1, 1) then
						if level == 0 then
							return currR, currC
						end
						level = level - 1
					end
				end
				return nil, nil
			end

			local function printz_local(str)
				for i = 1, #str do
					deps.kwrite(C["SYS_TEXT_WRITE"], string.byte(str, i))
				end
			end

			local keywords = {
				["int"] = 0x4EC9B0, ["char"] = 0x4EC9B0, ["void"] = 0x4EC9B0, ["long"] = 0x4EC9B0,
				["double"] = 0x4EC9B0, ["float"] = 0x4EC9B0, ["short"] = 0x4EC9B0, ["unsigned"] = 0x4EC9B0,
				["signed"] = 0x4EC9B0, ["struct"] = 0x4EC9B0, ["union"] = 0x4EC9B0, ["enum"] = 0x4EC9B0,
				["typedef"] = 0x4EC9B0, ["size_t"] = 0x4EC9B0, ["bool"] = 0x4EC9B0,
				["if"] = 0xC586C0, ["else"] = 0xC586C0, ["while"] = 0xC586C0, ["for"] = 0xC586C0,
				["do"] = 0xC586C0, ["switch"] = 0xC586C0, ["case"] = 0xC586C0, ["default"] = 0xC586C0,
				["break"] = 0xC586C0, ["continue"] = 0xC586C0, ["return"] = 0xC586C0, ["goto"] = 0xC586C0,
				["sizeof"] = 0xC586C0, ["static"] = 0xC586C0, ["extern"] = 0xC586C0, ["const"] = 0xC586C0,
				["volatile"] = 0xC586C0, ["inline"] = 0xC586C0, ["#define"] = 0xC586C0, ["#include"] = 0xC586C0,
				["#ifdef"] = 0xC586C0, ["#ifndef"] = 0xC586C0, ["#endif"] = 0xC586C0, ["#else"] = 0xC586C0,
			}

			local function highlightLine(line, row, matchC, lineBg)
				local pos = 1
				while pos <= #line do
					local char = line:sub(pos, pos)
					local nextChar = line:sub(pos + 1, pos + 1)

					local function setC(fg)
						local bg = (pos == matchC) and 0x333333 or lineBg
						if isSelected(row, pos) then bg = 0x264F78 end
						setColor(fg, bg)
					end

					if char == "/" and nextChar == "/" then
						for i = pos, #line do
							local bg = (i == matchC) and 0x333333 or lineBg
							if isSelected(row, i) then bg = 0x264F78 end
							setColor(0x6A9955, bg)
							printz_local(line:sub(i, i))
						end
						break
					elseif char == "\"" then
						setC(0xCE9178)
						local endPos = line:find("\"", pos + 1) or #line
						for i = pos, endPos do
							local bg = (i == matchC) and 0x333333 or lineBg
							if isSelected(row, i) then bg = 0x264F78 end
							setColor(0xCE9178, bg)
							printz_local(line:sub(i, i))
						end
						pos = endPos + 1
					elseif char == "'" then
						setC(0xCE9178)
						local endPos = line:find("'", pos + 1) or #line
						for i = pos, endPos do
							local bg = (i == matchC) and 0x333333 or lineBg
							if isSelected(row, i) then bg = 0x264F78 end
							setColor(0xCE9178, bg)
							printz_local(line:sub(i, i))
						end
						pos = endPos + 1
					elseif char == "#" then
						setC(0xC586C0)
						local word = line:match("([#%a%d_]+)", pos)
						if word then
							for i = pos, pos + #word - 1 do
								local bg = (i == matchC) and 0x333333 or lineBg
								if isSelected(row, i) then bg = 0x264F78 end
								setColor(0xC586C0, bg)
								printz_local(line:sub(i, i))
							end
							pos = pos + #word
						else
							printz_local(char)
							pos = pos + 1
						end
					elseif char:match("%d") or (char == "0" and nextChar == "x") then
						setC(0xB5CEA8)
						local num = line:match("([%x%.x]+)", pos)
						if num then
							for i = pos, pos + #num - 1 do
								local bg = (i == matchC) and 0x333333 or lineBg
								if isSelected(row, i) then bg = 0x264F78 end
								setColor(0xB5CEA8, bg)
								printz_local(line:sub(i, i))
							end
							pos = pos + #num
						else
							printz_local(char)
							pos = pos + 1
						end
					elseif char:match("[%a_]") then
						local word = line:match("([%a%d_]+)", pos)
						if word then
							local after = line:match("^%s*%(", pos + #word)
							local color = 0x9CDCFE

							if keywords[word] then
								color = keywords[word]
							elseif after then
								color = 0xDCDCAA
							elseif word:match("^[A-Z_][A-Z0-9_]*$") and #word > 1 then
								color = 0xBD93F9
							end

							for i = pos, pos + #word - 1 do
								local bg = (i == matchC) and 0x333333 or lineBg
								if isSelected(row, i) then bg = 0x264F78 end
								setColor(color, bg)
								printz_local(line:sub(i, i))
							end
							pos = pos + #word
						else
							setC(0xFFFFFF)
							printz_local(char)
							pos = pos + 1
						end
					elseif char == "." or (char == "-" and nextChar == ">") then
						setC(0xD4D4D4)
						local len = (char == ".") and 1 or 2
						printz_local(line:sub(pos, pos + len - 1))
						pos = pos + len

						local member = line:match("^%s*([%a_][%a%d_]*)", pos)
						if member then
							local ws = line:match("^(%s*)", pos)
							if #ws > 0 then
								for i = pos, pos + #ws - 1 do
									local bg = (i == matchC) and 0x333333 or lineBg
									if isSelected(row, i) then bg = 0x264F78 end
									setColor(0xFFFFFF, bg)
									printz_local(" ")
								end
								pos = pos + #ws
							end
							for i = pos, pos + #member - 1 do
								local bg = (i == matchC) and 0x333333 or lineBg
								if isSelected(row, i) then bg = 0x264F78 end
								setColor(0x4EC9B0, bg)
								printz_local(line:sub(i, i))
							end
							pos = pos + #member
						end
					else
						if char:match("[%+%-*/=<>!&|%^~%%]") then
							setC(0xD4D4D4)
						else
							setC(0xFFFFFF)
						end
						printz_local(char)
						pos = pos + 1
					end
				end
			end

			local function draw()
				setColor(0xFFFFFF, 0x000000)
				deps.kwrite(TEXT_BASE + 5, 1)
				local matchR, matchC = findMatchingBracket(cursorR, cursorC)

				for i = 1, termH - 2 do
					local lineIdx = i + scrollY
					setCursor(i, 1)

					local isCursorLine = (lineIdx == cursorR)
					local lineBg = isCursorLine and 0x151515 or 0x000000

					if lineIdx <= #lines then
						setColor(0xBBBBBB, lineBg)
						local fmt = "%" .. (getLNW() - 1) .. "d "
						printz_local(string.format(fmt, lineIdx))
						highlightLine(lines[lineIdx], lineIdx, (lineIdx == matchR and matchC or nil), lineBg)
					else
						setColor(0x3B3B3B, 0x000000)
						printz_local("~")
					end

					setCursor(i, termW)
					local totalLines = #lines
					local viewH = termH - 2
					local sbSize = math.max(1, math.floor((viewH / math.max(viewH, totalLines)) * viewH))
					local sbPos = math.floor((scrollY / math.max(1, totalLines - viewH)) * (viewH - sbSize)) + 1

					if totalLines > viewH then
						if i >= sbPos and i < sbPos + sbSize then
							setColor(0x888888, 0x444444)
							printz_local(" ")
						else
							setColor(0x222222, 0x000000)
							printz_local("â”‚")
						end
					end
				end

				setCursor(termH - 1, 1)
				setColor(0x000000, 0x007ACC)
				local status = string.format(" %s %s -- %s -- L:%d C:%d [K:%d] %s",
					mode, path, dirty and "[+]" or "", cursorR, cursorC, lastKey, statusMsg)
				printz_local(status .. string.rep(" ", termW - #status))

				setCursor(termH, 1)
				setColor(0xFFFFFF, 0x000000)
				if mode == "COMMAND" then
					printz_local(":" .. commandBuf)
				end

				setCursor(cursorR - scrollY, cursorC + getLNW())
				local charAtCursor = (lines[cursorR] or ""):sub(cursorC, cursorC)
				if charAtCursor == "" then charAtCursor = " " end

				if mode == "NORMAL" then
					setColor(0x000000, 0xFFFFFF)
					printz_local(charAtCursor)
				elseif mode == "INSERT" then
					setColor(0xFFFFFF, 0x888888)
					printz_local(charAtCursor)
				end

				setCursor(cursorR - scrollY, cursorC + getLNW())
				deps.kwrite(C["SYS_CTRL_FLUSH"], 1)
			end

			local function save()
				local data = table.concat(lines, "\n")
				local inode2 = filesystem:resolvePath(path)
				if not inode2 then
					inode2 = filesystem:createFile(path, data)
				else
					filesystem:writeFile(inode2, data)
				end
				dirty = false
				statusMsg = "Saved."
			end

			local forceDraw = true
			while running do
				if not deps.isPoweredOn() or not deps.getMem() then running = false break end

				local avail = deps.kread(C["SYS_IO_AVAIL"])

				if avail == 0 or forceDraw then
					draw()
					presentIfRequested()
					forceDraw = false
				end

				while avail == 0 do
					task.wait(0.01)
					avail = deps.kread(C["SYS_IO_AVAIL"])
					if not deps.isPoweredOn() or not deps.getMem() then running = false break end

					local mbtns = deps.kread(IO_BASE + 2)
					local isLMBDown = (bit32.band(mbtns, 1) ~= 0)

					if isLMBDown and isDraggingScroll then
						local mx = deps.kread(IO_BASE + 0)
						local my = deps.kread(IO_BASE + 1)
						local clickX_cell = math.floor(mx / 10) + 1
						local clickY_cell = math.floor(my / 10) + 1
						local totalLines = #lines
						local viewH = termH - 2

						local changed = false
						if totalLines > viewH then
							if clickY_cell <= 1 then
								autoScrollTimer = autoScrollTimer + 1
								if autoScrollTimer >= 3 then
									if scrollY > 0 then scrollY = scrollY - 1 changed = true end
									autoScrollTimer = 0
								end
							elseif clickY_cell >= viewH then
								autoScrollTimer = autoScrollTimer + 1
								if autoScrollTimer >= 3 then
									if scrollY < totalLines - viewH then scrollY = scrollY + 1 changed = true end
									autoScrollTimer = 0
								end
							else
								autoScrollTimer = 0
								local pct = (clickY_cell - 1) / math.max(1, viewH - 1)
								local targetY = math.floor(pct * (totalLines - viewH))
								if targetY ~= scrollY then
									scrollY = targetY
									changed = true
								end
							end

							if changed then
								scrollY = math.max(0, math.min(totalLines - viewH, scrollY))
								if cursorR < scrollY + 1 or cursorR > scrollY + viewH then
									cursorR = math.max(1, math.min(totalLines, scrollY + math.floor(viewH / 2)))
									cursorC = math.min(cursorC, #(lines[cursorR] or "") + 1)
								end
								forceDraw = true
								break
							end
						end
					elseif isLMBDown and isDraggingText then
						local mx = deps.kread(IO_BASE + 0)
						local my = deps.kread(IO_BASE + 1)
						local clickX_cell = math.floor(mx / 10) + 1
						local clickY_cell = math.floor(my / 10) + 1
						local totalLines = #lines
						local viewH = termH - 2

						if clickY_cell <= 1 and scrollY > 0 then
							scrollY = scrollY - 1
						elseif clickY_cell >= viewH and scrollY < totalLines - viewH then
							scrollY = scrollY + 1
						end

						selEndR = math.max(1, math.min(totalLines, clickY_cell + scrollY))
						selEndC = math.max(1, math.min(#(lines[selEndR] or "") + 1, clickX_cell - getLNW()))
						cursorR, cursorC = selEndR, selEndC
						forceDraw = true
						break
					elseif not isLMBDown then
						isDraggingScroll = false
						isDraggingText = false
					end

					if deps.kread(IO_BASE + 6) ~= lastClickSeq then break end
				end
				if not running then break end

				local currentClickSeq = deps.kread(IO_BASE + 6)
				if currentClickSeq ~= lastClickSeq then
					lastClickSeq = currentClickSeq
					local mx = deps.kread(IO_BASE + 3)
					local my = deps.kread(IO_BASE + 4)
					local btn = deps.kread(IO_BASE + 5)
					if btn == 1 then
						local clickX_cell = math.floor(mx / 10) + 1
						local clickY_cell = math.floor(my / 10) + 1

						if clickX_cell >= termW - 2 then
							isDraggingScroll = true
							local totalLines = #lines
							local viewH = termH - 2
							if totalLines > viewH then
								local pct = (clickY_cell - 1) / math.max(1, viewH - 1)
								scrollY = math.floor(pct * (totalLines - viewH))
								scrollY = math.max(0, math.min(totalLines - viewH, scrollY))
								cursorR = math.max(1, math.min(totalLines, scrollY + math.floor(viewH / 2)))
								cursorC = math.min(cursorC, #(lines[cursorR] or "") + 1)
							end
						elseif mouseEnabled then
							if clickY_cell >= 1 and clickY_cell <= termH - 2 then
								local clickR = clickY_cell + scrollY
								local clickC = clickX_cell - getLNW()
								if clickC < 1 then clickC = 1 end

								cursorR = math.max(1, math.min(#lines, clickR))
								cursorC = math.max(1, math.min(#lines[cursorR] + 1, clickC))

								selStartR, selStartC = cursorR, cursorC
								selEndR, selEndC = cursorR, cursorC
								isDraggingText = true
							end
						end
					end
				end

				local key = deps.kread(C["SYS_IO_READ"])
				if key ~= 0 then
					lastKey = key
					if key ~= string.byte("x") and key ~= 8 then
						clearSelection()
					end
				end

				if mode == "NORMAL" and key ~= 0 then
					if key == string.byte("i") then snapshot() mode = "INSERT" statusMsg = ""
					elseif key == string.byte("A") then
						snapshot()
						cursorC = #lines[cursorR] + 1
						mode = "INSERT"
						statusMsg = ""
					elseif key == string.byte(":") then mode = "COMMAND" commandBuf = ""
					elseif key == string.byte("h") or key == 19 then cursorC = math.max(1, cursorC - 1)
					elseif key == string.byte("l") or key == 20 then cursorC = math.min(#lines[cursorR] + 1, cursorC + 1)
					elseif key == string.byte("k") or key == 17 then
						cursorR = math.max(1, cursorR - 1)
						cursorC = math.min(cursorC, #lines[cursorR] + 1)
					elseif key == string.byte("j") or key == 18 then
						cursorR = math.min(#lines, cursorR + 1)
						cursorC = math.min(cursorC, #lines[cursorR] + 1)
					elseif key == string.byte("x") then
						if not deleteSelection() then
							snapshot()
							local line = lines[cursorR]
							lines[cursorR] = line:sub(1, cursorC - 1) .. line:sub(cursorC + 1)
							dirty = true
						end
					elseif key == string.byte("o") then
						snapshot()
						table.insert(lines, cursorR + 1, "")
						cursorR = cursorR + 1
						cursorC = 1
						mode = "INSERT"
						dirty = true
					elseif key == string.byte("O") then
						snapshot()
						table.insert(lines, cursorR, "")
						cursorC = 1
						mode = "INSERT"
						dirty = true
					elseif key == string.byte("d") then
						if prevKey == string.byte("d") then
							snapshot()
							yankBuf = lines[cursorR] .. "\n"
							table.remove(lines, cursorR)
							if #lines == 0 then lines = { "" } end
							cursorR = math.min(cursorR, #lines)
							cursorC = 1
							dirty = true
							key = 0
						end
					elseif key == string.byte("y") then
						if prevKey == string.byte("y") then
							yankBuf = lines[cursorR] .. "\n"
							statusMsg = "1 line yanked"
							key = 0
						end
					elseif key == string.byte("p") then
						snapshot()
						if yankBuf:sub(-1) == "\n" then
							table.insert(lines, cursorR + 1, yankBuf:sub(1, -2))
							cursorR = cursorR + 1
							cursorC = 1
						else
							local line = lines[cursorR]
							lines[cursorR] = line:sub(1, cursorC - 1) .. yankBuf .. line:sub(cursorC)
							cursorC = cursorC + #yankBuf
						end
						dirty = true
					elseif key == string.byte("u") or key == 26 then
						performUndo()
					elseif key == 25 then
						performRedo()
					elseif key == string.byte("$") then
						cursorC = #lines[cursorR] + 1
					elseif key == string.byte("0") then
						cursorC = 1
					elseif key == string.byte("g") then
						if prevKey == string.byte("g") then
							cursorR = 1
							cursorC = 1
							key = 0
						end
					elseif key == string.byte("G") then
						cursorR = #lines
						cursorC = 1
					elseif key == string.byte("w") then
						local s = lines[cursorR]:find("%W%w", cursorC)
						if s then cursorC = s + 1
						elseif cursorR < #lines then
							cursorR = cursorR + 1
							cursorC = lines[cursorR]:find("%S") or 1
						else cursorC = #lines[cursorR] + 1 end
					elseif key == string.byte("b") then
						local c = cursorC - 1
						while c > 0 do
							if lines[cursorR]:sub(c, c):match("%w") and (c == 1 or lines[cursorR]:sub(c - 1, c - 1):match("%W")) then
								cursorC = c
								break
							end
							c = c - 1
						end
						if c <= 0 and cursorR > 1 then
							cursorR = cursorR - 1
							cursorC = #lines[cursorR]
						end
					end

					if key ~= 0 then prevKey = key end
					if cursorR - scrollY > termH - 2 then scrollY = cursorR - (termH - 2) end
					if cursorR - scrollY < 1 then scrollY = cursorR - 1 end

				elseif mode == "INSERT" and key ~= 0 then
					if key == 27 or key == 3 then mode = "NORMAL"
					elseif key == 26 then
						performUndo()
					elseif key == 25 then
						performRedo()
					elseif key == 13 then
						local line = lines[cursorR]
						local indent = line:match("^%s*") or ""
						local isPasting = deps.kread(C["SYS_IO_AVAIL"]) > 0

						if not isPasting and line:sub(cursorC - 1, cursorC) == "{}" then
							lines[cursorR] = line:sub(1, cursorC - 1)
							table.insert(lines, cursorR + 1, indent .. "  ")
							table.insert(lines, cursorR + 2, indent .. "}")
							cursorR = cursorR + 1
							cursorC = #indent + 3
						else
							if not isPasting and line:sub(cursorC - 1, cursorC - 1) == "{" then indent = indent .. "  " end
							lines[cursorR] = line:sub(1, cursorC - 1)
							if isPasting then indent = "" end
							table.insert(lines, cursorR + 1, indent .. line:sub(cursorC))
							cursorR = cursorR + 1
							cursorC = #indent + 1
						end
						dirty = true
					elseif key == 8 then
						if deleteSelection() then
						elseif cursorC > 1 then
							local line = lines[cursorR]
							local leftChar = line:sub(cursorC - 1, cursorC - 1)
							local rightChar = line:sub(cursorC, cursorC)
							local isPair = (leftChar == "(" and rightChar == ")") or
								(leftChar == "{" and rightChar == "}") or
								(leftChar == "[" and rightChar == "]") or
								(leftChar == "\"" and rightChar == "\"") or
								(leftChar == "'" and rightChar == "'")

							if isPair then
								lines[cursorR] = line:sub(1, cursorC - 2) .. line:sub(cursorC + 1)
							else
								lines[cursorR] = line:sub(1, cursorC - 2) .. line:sub(cursorC)
							end
							cursorC = cursorC - 1
							dirty = true
						elseif cursorR > 1 then
							cursorC = #lines[cursorR - 1] + 1
							lines[cursorR - 1] = lines[cursorR - 1] .. lines[cursorR]
							table.remove(lines, cursorR)
							cursorR = cursorR - 1
							dirty = true
						end
					elseif key == 17 then
						cursorR = math.max(1, cursorR - 1)
						cursorC = math.min(cursorC, #lines[cursorR] + 1)
					elseif key == 18 then
						cursorR = math.min(#lines, cursorR + 1)
						cursorC = math.min(cursorC, #lines[cursorR] + 1)
					elseif key == 19 then
						cursorC = math.max(1, cursorC - 1)
					elseif key == 20 then
						cursorC = math.min(#lines[cursorR] + 1, cursorC + 1)
					elseif key == 9 then
						local line = lines[cursorR]
						lines[cursorR] = line:sub(1, cursorC - 1) .. "  " .. line:sub(cursorC)
						cursorC = cursorC + 2
						dirty = true
					elseif key >= 32 and key <= 126 then
						local line = lines[cursorR]
						local char = string.char(key)
						local isPasting = deps.kread(C["SYS_IO_AVAIL"]) > 0

						local pairs = { ["("] = ")", ["{"] = "}", ["["] = "]", ["\""] = "\"", ["'"] = "'" }
						local closeChar = pairs[char]

						local rightChar = line:sub(cursorC, cursorC)

						if not isPasting and rightChar == char and (char == ")" or char == "}" or char == "]" or char == "\"" or char == "'") then
							cursorC = cursorC + 1
						elseif not isPasting and closeChar then
							lines[cursorR] = line:sub(1, cursorC - 1) .. char .. closeChar .. line:sub(cursorC)
							cursorC = cursorC + 1
							dirty = true
						else
							lines[cursorR] = line:sub(1, cursorC - 1) .. char .. line:sub(cursorC)
							cursorC = cursorC + 1
							dirty = true
						end
					end
					if cursorR - scrollY > termH - 2 then scrollY = cursorR - (termH - 2) end
					if cursorR - scrollY < 1 then scrollY = cursorR - 1 end

				elseif mode == "COMMAND" and key ~= 0 then
					if key == 13 then
						if commandBuf == "w" then save()
						elseif commandBuf == "q" then
							if dirty then statusMsg = "Unsaved changes! (use :q!)"
							else running = false end
						elseif commandBuf == "wq" then save() running = false
						elseif commandBuf == "q!" then running = false
						elseif commandBuf == "set mouse=a" then mouseEnabled = true statusMsg = "mouse=a"
						elseif commandBuf == "set mouse=" then mouseEnabled = false statusMsg = "mouse="
						end
						mode = "NORMAL"
					elseif key == 8 then commandBuf = commandBuf:sub(1, -2)
					elseif key == 27 or key == 3 then mode = "NORMAL"
					elseif key >= 32 and key <= 126 then commandBuf = commandBuf .. string.char(key)
					end
				end
			end

			setColor(0xFFFFFF, 0x000000)
			deps.kwrite(TEXT_BASE + 5, 1)
			setCursor(1, 1)
			deps.kwrite(C["SYS_CTRL_FLUSH"], 1)
			currentCpu.reg[1] = 0
			return

		elseif n == 48 then
			local targetFPS = currentCpu.reg[1] or 30
			if targetFPS < 1 then targetFPS = 1 end
			if targetFPS > 60 then targetFPS = 60 end
			local frameInterval = 1.0 / targetFPS

			if not _G.ROVM_VSYNC_LAST then
				_G.ROVM_VSYNC_LAST = os.clock()
				task.wait()
				_G.ROVM_VSYNC_LAST = os.clock()
				currentCpu.reg[1] = targetFPS
				return
			end

			local now = os.clock()
			local elapsed = now - _G.ROVM_VSYNC_LAST

			if elapsed < frameInterval then
				while elapsed < frameInterval - 0.001 do
					RunService.Heartbeat:Wait()
					now = os.clock()
					elapsed = now - _G.ROVM_VSYNC_LAST
				end
			else
				task.wait()
			end

			local actualElapsed = os.clock() - _G.ROVM_VSYNC_LAST
			local actualFPS = targetFPS
			if actualElapsed > 0 then
				actualFPS = math.floor(1.0 / actualElapsed + 0.5)
			end

			_G.ROVM_VSYNC_LAST = os.clock()
			currentCpu.reg[1] = actualFPS
			return

		elseif n == C["SC_FORMAT"] then
			print("[kernel] FORMAT: Wiping filesystem...")
			filesystem = Filesystem.new()
			deps.setFilesystem(filesystem)
			deps.ensureDefaultBloxOSFiles()
			deps.saveFilesystemToServer(deps.getUserId())
			deps.kwrite(C["SYS_CTRL_REBOOT"], 1)
			return

		elseif n == C["SC_CRASH"] then
			_G.ROVM_CRASH_EFFECT = true
			warn("[kernel] system crash triggered")

			if cpu then cpu.running = false end

			if scheduler then
				for pid, proc in pairs(scheduler.processes) do
					proc:cleanup()
					scheduler:removeProcess(pid)
				end
			end

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_PEEK_PHYS"] then
			local addr = currentCpu.reg[1] or 0
			local oldMode = mem.mode
			mem:setMode("kernel")
			local val, err = mem:read(addr)
			mem:setMode(oldMode)
			if err then
				currentCpu.reg[1] = -1
			else
				currentCpu.reg[1] = val
			end
			return

		elseif n == C["SC_POKE_PHYS"] then
			local addr = currentCpu.reg[1] or 0
			local val = currentCpu.reg[2] or 0
			local oldMode = mem.mode
			mem:setMode("kernel")
			local ok = mem:write(addr, val)
			mem:setMode(oldMode)
			if not ok then
				currentCpu.reg[1] = -1
			else
				currentCpu.reg[1] = 0
			end
			return

		elseif n == C["SC_GPU_SET_VIEW"] then
			local ox = deps.toSigned32(currentCpu.reg[1] or 0)
			local oy = deps.toSigned32(currentCpu.reg[2] or 0)
			local packed = currentCpu.reg[3] or 0
			local wrapW = math.floor(packed / 65536)
			local wrapH = bit32.band(packed, 65535)
			deps.kwrite(GPU_BASE + 4, ox)
			deps.kwrite(GPU_BASE + 8, oy)
			deps.kwrite(GPU_BASE + 20, wrapW)
			deps.kwrite(GPU_BASE + 24, wrapH)
			return
		elseif n == C["SC_GPU_SET_XY"] then
			deps.kwrite(GPU_BASE + 12, deps.toSigned32(currentCpu.reg[1] or 0))
			deps.kwrite(GPU_BASE + 16, deps.toSigned32(currentCpu.reg[2] or 0))
			return
		elseif n == C["SC_GPU_SET_COLOR"] then
			deps.kwrite(GPU_BASE + 32, currentCpu.reg[1] or 0)
			return
		elseif n == C["SC_GPU_DRAW_BUFFER"] then
			local bufAddr = currentCpu.reg[1] or 0
			local bufLen = currentCpu.reg[2] or 0
			if bufLen > 0 and currentProc and currentProc.pageTable then
				deps.kwrite(GPU_BASE + 40, bufAddr)
				deps.kwrite(GPU_BASE + 44, bufLen)
				mem:setMode("user")
				deps.kwrite(GPU_BASE + 0, 2)
				mem:setMode("kernel")
			end
			return
		elseif n == C["SC_GPU_WAIT_FRAME"] then
			while true do
				if not deps.isPoweredOn() or not deps.getMem() then
					currentCpu.reg[1] = 0
					return
				end
				local fc = deps.kread(GPU_BASE + 36) or 0
				if fc and fc > 0 then
					deps.kwrite(GPU_BASE + 36, 0)
					currentCpu.reg[1] = fc
					return
				end
				local remaining = deps.kread(GPU_BASE + 44) or 0
				if remaining == 0 then
					currentCpu.reg[1] = 0
					return
				end
				task.wait()
			end
		elseif n == C["SC_GPU_CLEAR_FRAME"] then
			deps.kwrite(GPU_BASE + 36, 0)
			return
		elseif n == C["SC_GPU_DRAW_RLE"] then
			local length = currentCpu.reg[1] or 0
			deps.kwrite(GPU_BASE + 12, 0)
			deps.kwrite(GPU_BASE + 16, 0)
			deps.kwrite(GPU_BASE + 32, 0)
			deps.kwrite(GPU_BASE + 28, length)
			deps.kwrite(GPU_BASE + 0, 1)
			return
		elseif n == C["SC_GPU_GET_REMAINING_LEN"] then
			currentCpu.reg[1] = deps.kread(GPU_BASE + 44) or 0
			return
		elseif n == C["SC_GPU_GET_BUFFER_ADDR"] then
			currentCpu.reg[1] = deps.kread(GPU_BASE + 40) or 0
			return

		elseif n == C["SC_GPU_PLAY_CHUNK"] then
			local bufAddr = currentCpu.reg[1] or 0
			local bufLen = currentCpu.reg[2] or 0
			local targetFPS = currentCpu.reg[3] or 12
			if targetFPS < 1 then targetFPS = 1 end
			if targetFPS > 60 then targetFPS = 60 end
			local frameInterval = 1.0 / targetFPS

			if not _G.ROVM_VSYNC_LAST then
				_G.ROVM_VSYNC_LAST = os.clock()
			end

			if bufLen <= 0 or not currentProc or not currentProc.pageTable then
				currentCpu.reg[1] = 0
				return
			end

			deps.kwrite(GPU_BASE + 40, bufAddr)
			deps.kwrite(GPU_BASE + 44, bufLen)

			while true do
				if not deps.isPoweredOn() or not deps.getMem() then
					currentCpu.reg[1] = 0
					return
				end

				local remaining = deps.kread(GPU_BASE + 44) or 0
				if remaining <= 0 then
					currentCpu.reg[1] = 0
					return
				end

				mem:setMode("user")
				deps.kwrite(GPU_BASE + 0, 2)
				mem:setMode("kernel")

				local fc = deps.kread(GPU_BASE + 36) or 0
				if fc > 0 then
					deps.kwrite(C["SYS_CTRL_FLUSH"], 1)
					deps.kwrite(GPU_BASE + 36, 0)

					if presentIfRequested then presentIfRequested() end

					local now = os.clock()
					local elapsed = now - _G.ROVM_VSYNC_LAST
					if elapsed < frameInterval then
						while elapsed < frameInterval - 0.001 do
							task.wait()
							now = os.clock()
							elapsed = now - _G.ROVM_VSYNC_LAST
						end
					else
						task.wait()
					end
					_G.ROVM_VSYNC_LAST = os.clock()
				else
					currentCpu.reg[1] = 0
					return
				end
			end

		elseif n == C["SC_APP_WINDOW"] then
			local cw = deps.toSigned32(currentCpu.reg[1] or 0)
			local ch = deps.toSigned32(currentCpu.reg[2] or 0)
			if cw <= 0 or ch <= 0 or cw > WIDTH or ch > HEIGHT then
				currentCpu.reg[1] = -1
				return
			end
			local winW = cw + 2 * C["APP_BORDER_W"]
			local winH = ch + C["APP_TITLE_BAR_H"] + 2 * C["APP_BORDER_W"]
			local winX = math.floor((WIDTH - winW) / 2)
			local winY = math.floor((HEIGHT - winH) / 2)
			if winX < 0 then winX = 0 end
			if winY < 0 then winY = 0 end
			local contentX = winX + C["APP_BORDER_W"]
			local contentY = winY + C["APP_TITLE_BAR_H"] + C["APP_BORDER_W"]
			local closeX1 = winX + winW - C["APP_BORDER_W"] - C["APP_CLOSE_SIZE"]
			local closeY1 = winY + C["APP_BORDER_W"]
			local closeX2 = winX + winW - C["APP_BORDER_W"] - 1
			local closeY2 = winY + C["APP_TITLE_BAR_H"] - C["APP_BORDER_W"] - 1
			currentProc.appWindow = {
				contentW = cw,
				contentH = ch,
				winX = winX,
				winY = winY,
				winW = winW,
				winH = winH,
				contentX = contentX,
				contentY = contentY,
				closeX1 = closeX1,
				closeY1 = closeY1,
				closeX2 = closeX2,
				closeY2 = closeY2,
				prevWinX = winX,
				prevWinY = winY,
				title = nil,
			}

			deps.kwrite(GPU_BASE + 4, contentX)
			deps.kwrite(GPU_BASE + 8, contentY)
			deps.kwrite(GPU_BASE + 20, cw)
			deps.kwrite(GPU_BASE + 24, ch)

			currentCpu.reg[1] = 0
			return

		elseif n == C["SC_APP_SET_TITLE"] then
			local titlePtr = currentCpu.reg[1]
			if not titlePtr or titlePtr == 0 then
				if currentProc.appWindow then
					currentProc.appWindow.title = nil
				end
				return
			end
			local title, fault = deps.userReadString(titlePtr, 64)
			if fault then
				currentCpu.reg[1] = -1
				return
			end
			if currentProc.appWindow then
				currentProc.appWindow.title = (title and #title > 0) and title or nil
			end
			return

		elseif n == 21 then
			local x = deps.toSigned32(currentCpu.reg[1] or 0)
			local y = deps.toSigned32(currentCpu.reg[2] or 0)
			local packed = currentCpu.reg[3] or 0
			local color = currentCpu.reg[4]
			local w = math.floor(packed / 65536)
			local h = bit32.band(packed, 65535)

			if color then
				deps.kwrite(GPU_BASE + 32, color)
			end

			deps.kwrite(GPU_BASE + 48, x)
			deps.kwrite(GPU_BASE + 52, y)
			deps.kwrite(GPU_BASE + 56, w)
			deps.kwrite(GPU_BASE + 60, h)
			deps.kwrite(GPU_BASE + 0, 3)
			return

		elseif n == 22 then
			local x0 = deps.toSigned32(currentCpu.reg[1] or 0)
			local y0 = deps.toSigned32(currentCpu.reg[2] or 0)
			local x1 = deps.toSigned32(currentCpu.reg[3] or 0)
			local y1 = deps.toSigned32(currentCpu.reg[4] or 0)

			deps.kwrite(GPU_BASE + 48, x0)
			deps.kwrite(GPU_BASE + 52, y0)
			deps.kwrite(GPU_BASE + 56, x1)
			deps.kwrite(GPU_BASE + 60, y1)
			deps.kwrite(GPU_BASE + 0, 4)
			return

		elseif n == 64 then
			local op = currentCpu.reg[1] or 0
			local arg1 = currentCpu.reg[2] or 0
			local arg2 = currentCpu.reg[3] or 0

			if arg1 >= 0x80000000 then arg1 = arg1 - 0x100000000 end
			if arg2 >= 0x80000000 then arg2 = arg2 - 0x100000000 end

			local SCALE = 65536
			local farg1 = arg1 / SCALE
			local farg2 = arg2 / SCALE
			local result = 0

			if op == 0 then result = math.sin(farg1)
			elseif op == 1 then result = math.cos(farg1)
			elseif op == 2 then result = math.tan(farg1)
			elseif op == 3 then result = math.sqrt(math.max(0, farg1))
			elseif op == 4 then result = math.atan2(farg1, farg2)
			elseif op == 5 then result = math.floor(farg1)
			elseif op == 6 then result = math.ceil(farg1)
			elseif op == 7 then result = math.abs(farg1)
			elseif op == 10 then result = farg1 * farg2
			elseif op == 11 then
				if farg2 == 0 then result = 0 else result = farg1 / farg2 end
			end

			local scaled = result * SCALE
			local intResult
			if scaled >= 0 then
				intResult = math.floor(scaled + 0.5)
			else
				intResult = math.ceil(scaled - 0.5)
			end
			currentCpu.reg[1] = bit32.band(intResult, 0xFFFFFFFF)
			return

		elseif n == C["SC_SBRK"] then
			local incr = deps.toSigned32(currentCpu.reg[1] or 0)
			if not currentProc or not currentProc.pageTable then
				currentCpu.reg[1] = -1
				return
			end
			if not currentProc._heapMinBreak then
				currentProc._heapMinBreak = currentProc._heapBreak or 32768
			end
			if not currentProc._heapBreak then
				currentProc._heapBreak = currentProc._heapMinBreak
			end
			local virtualMemSize = deps.getProcessVirtualMemorySize(currentProc)
			local stackBase = deps.getProcessStackBase(currentProc)
			local prev = currentProc._heapBreak
			local newBreak = prev + incr
			if newBreak < currentProc._heapMinBreak or newBreak > virtualMemSize or newBreak > stackBase then
				currentCpu.reg[1] = -1
				return
			end
			if newBreak > prev then
				local ok = deps.ensureProcessRangeMapped(
					currentProc,
					prev,
					newBreak,
					PageTable.PERM_READ + PageTable.PERM_WRITE
				)
				if not ok then
					currentCpu.reg[1] = -1
					return
				end
			end
			currentProc._heapBreak = newBreak
			currentCpu.reg[1] = prev
			return

		elseif n == C["SC_LOAD_ROVD"] then
			if not currentProc or not currentProc.pageTable then currentCpu.reg[1] = -1; return end
			local pathPtr = currentCpu.reg[1]
			local path = deps.userReadString(pathPtr)
			if not path then currentCpu.reg[1] = -1; return end

			local code, err, _, rovdInfo = deps.loadProgramFromFile(path)
			if not code then
				print("[kernel] SC_LOAD_ROVD: failed to read/parse " .. path .. ": " .. (err or "unknown error"))
				currentCpu.reg[1] = -1
				return
			end

			if not rovdInfo or not rovdInfo.isRovd then
				print("[kernel] SC_LOAD_ROVD: file " .. path .. " is not a ROVD (missing ROVD magic)")
				currentCpu.reg[1] = -1
				return
			end

			local codeLen = buffer.len(code)
			local loadBase = math.floor((currentProc._heapBreak + 4095) / 4096) * 4096

			if not currentProc._loadedRovds then currentProc._loadedRovds = {} end

			if currentProc._loadedRovds[path] then
				currentCpu.reg[1] = currentProc._loadedRovds[path].base
				return
			end

			local numPages = math.ceil(codeLen / 4096)
			local initialPerms = PageTable.PERM_READ + PageTable.PERM_WRITE
			for i = 0, numPages - 1 do
				local ok = currentProc.pageTable:mapPage(loadBase / 4096 + i, nil, initialPerms)
				if not ok then currentCpu.reg[1] = -1; return end
			end

			mem:setMode(CPU.MODE_KERNEL)
			local copyOk, copyErr = deps.copyBufferIntoProcess(currentProc.pageTable, loadBase, code)
			if not copyOk then
				print("[kernel] SC_LOAD_ROVD: copy failed for " .. path .. ": " .. tostring(copyErr))
				currentCpu.reg[1] = -1
				return
			end

			if rovdInfo.relocCount and rovdInfo.relocCount > 0 then
				print("[kernel] SC_LOAD_ROVD: applying " .. rovdInfo.relocCount .. " relocations for " .. path)
				for i = 0, rovdInfo.relocCount - 1 do
					local relocPos = rovdInfo.relocTableOffset + (i * 4)
					local patchOffset = buffer.readu32(code, relocPos)
					local patchVAddr = loadBase + patchOffset

					local vPage = math.floor(patchVAddr / 4096)
					local pOff = patchVAddr % 4096
					local pPage = currentProc.pageTable:translate(vPage)
					if pPage then
						local phys = (pPage * 4096) + pOff
						local oldVal = buffer.readi32(mem.buf, phys)
						buffer.writei32(mem.buf, phys, bit32.band(oldVal + loadBase, 0xFFFFFFFF))
					end
				end
			end

			print("[kernel] SC_LOAD_ROVD: Library has " .. rovdInfo.exportCount .. " exports:")
			for i = 0, rovdInfo.exportCount - 1 do
				local entryOff = rovdInfo.exportTableOffset + i * 32
				local name = ""
				for j = 0, 27 do
					local b = buffer.readu8(code, entryOff + j)
					if b == 0 then break end
					name = name .. string.char(b)
				end
				local off = buffer.readu32(code, entryOff + 28)
				print("[kernel]   export '" .. name .. "' -> offset 0x" .. string.format("%X", off))
			end

			deps.applyBinaryPermissions(currentProc.pageTable, loadBase, codeLen, rovdInfo)
			deps.installCpuImageLayout(currentCpu, code, rovdInfo, loadBase, false)

			mem:setMode(DEFAULT_CPU_MODE)

			currentProc._heapBreak = loadBase + numPages * 4096
			currentProc._loadedRovds[path] = { base = loadBase, info = rovdInfo }
			currentCpu.reg[1] = loadBase
			return

		elseif n == C["SC_GET_EXPORT"] then
			if not currentProc then currentCpu.reg[1] = 0; return end
			local base = currentCpu.reg[1]
			local namePtr = currentCpu.reg[2]
			local name = deps.userReadString(namePtr)
			if not name or name == "" then
				currentCpu.reg[1] = 0; return
			end

			local rovd = nil
			if currentProc._loadedRovds then
				for _, d in pairs(currentProc._loadedRovds) do
					if d.base == base then rovd = d; break end
				end
			end
			if not rovd then currentCpu.reg[1] = 0; return end

			local info = rovd.info
			local tableOffset = info.exportTableOffset
			local count = info.exportCount

			for i = 0, count - 1 do
				local entryOff = tableOffset + i * 32
				local symName = ""
				for j = 0, 27 do
					local b, fault = deps.userReadByte(base + entryOff + j)
					if fault then break end
					if b == 0 then break end
					symName = symName .. string.char(b)
				end

				if symName == name then
					local off, fault = deps.userReadWord(base + entryOff + 28)
					if not fault then
						print("[kernel] SC_GET_EXPORT: resolved '" .. name .. "' to 0x" .. string.format("%X", base + off))
						currentCpu.reg[1] = base + off
						return
					end
				end
			end
			currentCpu.reg[1] = 0
			return
		elseif n == C["SC_SYSINFO"] then
			local sel = currentCpu.reg[1] or 0
			if sel == 0 then
				local uptime = math.floor(os.clock() - (_G.ROVM_BOOT_TIME or os.clock()))
				currentCpu.reg[1] = uptime
			elseif sel == 6 then
				local uptime_ms = math.floor((os.clock() - (_G.ROVM_BOOT_TIME or os.clock())) * 1000)
				currentCpu.reg[1] = uptime_ms
			elseif sel == 7 then
				currentCpu.reg[1] = bit32.band(deps.getVmInstructionCount(), 0xFFFFFFFF)
			elseif sel == 8 then
				currentCpu.reg[1] = deps.computeVmMipsX100()
			elseif sel == 1 then
				currentCpu.reg[1] = currentProc and currentProc._heapBreak or 0
			elseif sel == 2 then
				local count = 0
				if scheduler and scheduler.processes then
					for _ in pairs(scheduler.processes) do count = count + 1 end
				end
				currentCpu.reg[1] = count
			elseif sel == 3 then
				currentCpu.reg[1] = mem and buffer.len(mem.buf) or 1048576
			elseif sel == 4 then
				currentCpu.reg[1] = WIDTH
			elseif sel == 5 then
				currentCpu.reg[1] = HEIGHT
			else
				currentCpu.reg[1] = 0
			end
			return
		elseif n == C["SC_GPU_DRAW_RECTS_BATCH"] then
			local bufAddr = currentCpu.reg[1] or 0
			local rectCount = currentCpu.reg[2] or 0
			if rectCount <= 0 or rectCount > 1024 then return end

			local totalBytes = rectCount * 20
			local PAGE_SIZE = 4096
			local localBuf = buffer.create(totalBytes)
			local isUser = mem.mmu ~= nil
			local mmuRef = mem.mmu
			local memBuf = mem.buf
			local memSize = mem.size

			mem:setMode("user")
			local bytesRead = 0
			while bytesRead < totalBytes do
				local addr = bufAddr + bytesRead
				local vPage = math.floor(addr / PAGE_SIZE)
				local pageOff = addr - vPage * PAGE_SIZE
				local chunk = math.min(PAGE_SIZE - pageOff, totalBytes - bytesRead)
				local physBase
				if isUser and mmuRef then
					physBase = mmuRef:translate(vPage * PAGE_SIZE, "read")
					if not physBase then break end
				else
					physBase = vPage * PAGE_SIZE
				end
				local pa = physBase + pageOff
				if pa >= 0 and pa + chunk <= memSize then
					buffer.copy(localBuf, bytesRead, memBuf, pa, chunk)
				end
				bytesRead += chunk
			end
			mem:setMode("kernel")

			for i = 0, rectCount - 1 do
				local off = i * 20
				local rx = buffer.readi32(localBuf, off)
				local ry = buffer.readi32(localBuf, off + 4)
				local rw = buffer.readi32(localBuf, off + 8)
				local rh = buffer.readi32(localBuf, off + 12)
				local rc = buffer.readi32(localBuf, off + 16)

				deps.kwrite(GPU_BASE + 32, rc)
				deps.kwrite(GPU_BASE + 48, rx)
				deps.kwrite(GPU_BASE + 52, ry)
				deps.kwrite(GPU_BASE + 56, rw)
				deps.kwrite(GPU_BASE + 60, rh)
				deps.kwrite(GPU_BASE + 0, 3)
			end
			return
		end
		currentCpu.trap = {
			kind = "fault",
			type = "bad_syscall",
			n = n,
			pc = trapInfo.pc,
			msg = ("unknown syscall %d"):format(n),
		}
		currentCpu.running = false
	end

	return self
end

return SyscallDispatcher
