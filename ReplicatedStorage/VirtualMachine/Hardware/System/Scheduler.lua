--!native
--round robin oh yeah
local Process = require(script.Parent.Process)

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
	local self = setmetatable({}, Scheduler)
	
	--core tables. fifo is fine here
	self.processes = {}  --[pid] = process
	self.processQueue = {}  --ready queue
	self.currentPid = nil  --currently running pid
	self.nextPid = 1
	
	--500000 instructions per slice (larger = less context switch overhead)
	self.timeSlice = 500000  --instructions per time slice
	self.currentSlice = 0
	
	return self
end

function Scheduler:allocatePid()
	local pid = self.nextPid
	self.nextPid += 1
	return pid
end

--ready processes go straight into fifo
function Scheduler:addProcess(process)
	local pid = process.pid
	self.processes[pid] = process
	if process.state == Process.STATE_READY then
		table.insert(self.processQueue, pid)
	end
end

--wake any waiter before the process disappears, or wait() starts getting silly
function Scheduler:removeProcess(pid)
	local proc = self.processes[pid]
	if proc then
		--hand the exit code over before we tear the process down
		if proc.waitingPid then
			local waiter = self.processes[proc.waitingPid]
			if waiter and waiter.state == Process.STATE_BLOCKED then
				--wait() returns through r0
				--dont even ask
				waiter.cpu.reg[1] = proc.exitCode or 0
				self:unblock(proc.waitingPid)
			end
		end

		--strip stale queue entries so the scheduler does not queue a corpse
		for i = #self.processQueue, 1, -1 do
			if self.processQueue[i] == pid then
				table.remove(self.processQueue, i)
			end
		end
		
		--pages and whatever else cleanup owns
		if proc.cleanup then
			proc:cleanup()
		end
		
		--drop it from the table last
		self.processes[pid] = nil
		
		--do not leave currentPid pointing into nowhere
		if self.currentPid == pid then
			self.currentPid = nil
		end
	end
end

function Scheduler:getCurrentProcess()
	if self.currentPid then
		return self.processes[self.currentPid]
	end
	return nil
end

function Scheduler:getProcess(pid)
	return self.processes[pid]
end

--requeue the current process if it is still runnable, then walk until something real shows up
function Scheduler:scheduleNext()
	--current ready process goes to the back. close enough to fair.
	if self.currentPid then
		local current = self.processes[self.currentPid]
		if current and current.state == Process.STATE_READY and current.cpu.running then
			table.insert(self.processQueue, self.currentPid)
		end
	end
	
	--print("[sched] queue", table.concat(self.processQueue, ","))
	--skip stale entries until something runnable survives inspection
	local nextPid = nil
	while #self.processQueue > 0 do
		nextPid = table.remove(self.processQueue, 1)
		local proc = self.processes[nextPid]
		
		if proc and proc:isAlive() and proc.state == Process.STATE_READY then
			break
		else
			nextPid = nil
		end
	end
	
	self.currentPid = nextPid
	self.currentSlice = 0
	
	if nextPid then
		local proc = self.processes[nextPid]
		if proc then
			proc.state = Process.STATE_RUNNING
			proc:restoreState()
			--main loop flips the mmu after this. 
			--moving it here was a short, educational mistake
		end
	end
	
	return self.currentPid ~= nil
end

--peek slice state without touching it
function Scheduler:isSliceExpired()
	if not self.currentPid then return true end
	return self.currentSlice >= self.timeSlice
end

--batch runner reports how many instructions vanished
function Scheduler:consumeSlice(count)
	self.currentSlice += count
end

function Scheduler:shouldSwitch()
	if not self.currentPid then return true end
	
	local proc = self.processes[self.currentPid]
	if not proc or not proc:isAlive() or proc.state ~= Process.STATE_RUNNING then
		return true
	end
	
	return self.currentSlice >= self.timeSlice
end

--blocked means hands off until io or wait says otherwise
function Scheduler:blockCurrent(reason)
	if self.currentPid then
		local proc = self.processes[self.currentPid]
		if proc then
			proc.state = Process.STATE_BLOCKED
			proc.blockReason = reason
			proc:saveState()
		end
		self.currentPid = nil
	end
end

--wake a blocked process and drop it back into fifo
function Scheduler:unblock(pid)
	local proc = self.processes[pid]
	if proc and proc.state == Process.STATE_BLOCKED then
		proc.state = Process.STATE_READY
		proc.blockReason = nil
		table.insert(self.processQueue, pid)
		return true
	end
	return false
end

--reap zombies here so the main loop gets one less problem
function Scheduler:cleanupZombies()
	local toRemove = {}
	for pid, proc in pairs(self.processes) do
		if proc.state == Process.STATE_ZOMBIE then
			--deliver the exit code before reaping
			if proc.waitingPid then
				local waiter = self.processes[proc.waitingPid]
				if waiter and waiter.state == Process.STATE_BLOCKED then
					waiter.cpu.reg[1] = proc.exitCode or 0
					self:unblock(proc.waitingPid)
				end
				table.insert(toRemove, pid)
			else
				--orphaned zombie. still needs sweeping.
				table.insert(toRemove, pid)
			end
		elseif proc.state == Process.STATE_DEAD then
			table.insert(toRemove, pid)
		end
	end
	for _, pid in ipairs(toRemove) do
		self:removeProcess(pid)
	end
end

function Scheduler:getProcessCount()
	local count = 0
	for _ in pairs(self.processes) do
		count += 1
	end
	return count
end

return Scheduler
