--!native
--process state stays small on purpose
local FileHandle = require(script.Parent.Parent.Storage.FileHandle)

local Process = {}
Process.__index = Process

--string states make dumps readable
Process.STATE_RUNNING = "running"
Process.STATE_READY = "ready"
Process.STATE_BLOCKED = "blocked"
Process.STATE_ZOMBIE = "zombie"
Process.STATE_DEAD = "dead"

function Process.new(pid, cpu, memoryRegion, pageTable)
	local self = setmetatable({}, Process)
	self.pid = pid
	self.cpu = cpu
	self.memoryRegion = memoryRegion  --{base,size} in guest virtual space
	self.pageTable = pageTable  --per-process page table
	self.state = Process.STATE_READY
	self.parentPid = nil
	self.children = {}  --child pids
	self.exitCode = nil
	self.waitingPid = nil  --pid blocked in wait()

	--fd table lives here so scheduler does not get even more annoying
	self.files = FileHandle.new()

	--breadcrumbs for stats and postmortems later
	self.createdAt = os.clock()
	self.cpuTime = 0  --cpu time used so far
	self.imagePath = nil

	return self
end

--cpu already owns the real register state
--copying it here would just create two truths and one bug
--so this stays empty until snapshots stop being hypothetical
function Process:saveState()
end

--same story on restore. scheduler reads cpu.reg and cpu.pc directly.
function Process:restoreState()
end

--zombies count as dead here even if wait() can still peek at them
function Process:isAlive()
	return self.state ~= Process.STATE_DEAD and self.state ~= Process.STATE_ZOMBIE
end

--running procs become zombies first so wait() can steal the exit code
--everyone else can go straight to dead and stop hanging around
function Process:terminate(exitCode)
	self.exitCode = exitCode or 0
	if self.state == Process.STATE_RUNNING then
		self.state = Process.STATE_ZOMBIE
	else
		self.state = Process.STATE_DEAD
	end
	self.cpu.running = false

	--close fds first so dead procs stop leaking random junk
	if self.files then
		self.files:closeAll()
	end

	--page table cleanup happens later on final reap
	--that delay is intentional or the parent loses the zombie exit code. not ideal
end

--actual teardown lands here once the scheduler is done with the corpse
function Process:cleanup()
	if self.pageTable then
		self.pageTable:cleanup()
		self.pageTable = nil
	end
end

return Process
