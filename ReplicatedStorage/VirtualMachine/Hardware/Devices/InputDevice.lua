--!native
--input glue is messy because roblox input is messy
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local bit32 = bit32
local InputDevice = {}

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function btnMask(userInputType)
	if userInputType == Enum.UserInputType.MouseButton1 then return 1 end
	if userInputType == Enum.UserInputType.MouseButton2 then return 2 end
	if userInputType == Enum.UserInputType.MouseButton3 then return 4 end
	if userInputType == Enum.UserInputType.Touch then return 1 end
	return 0
end

local function keycodeToAscii(keyCode, shift)
	local name = keyCode.Name

	--letters
	if #name == 1 and name >= "A" and name <= "Z" then
		local ch = shift and name or string.lower(name)
		return string.byte(ch)
	end

	--number row
	local numMap = {
		Zero= {"0", ")"}, One={"1","!"}, Two={"2","@"}, Three={"3","#"}, Four={"4","$"},
		Five={"5","%"}, Six={"6","^"}, Seven={"7","&"}, Eight={"8","*"}, Nine={"9","("},
	}
	local n = numMap[keyCode.Name]
	if n then
		return string.byte(shift and n[2] or n[1])
	end

	--boring keys
	if keyCode == Enum.KeyCode.Space then return 32 end
	if keyCode == Enum.KeyCode.Return then 
		--shift+enter = 10, plain enter = 13. yep both matter here.
		return shift and 10 or 13 
	end
	if keyCode == Enum.KeyCode.Backspace then return 8 end
	if keyCode == Enum.KeyCode.Tab then return 9 end
	if keyCode == Enum.KeyCode.Escape then return 27 end

	--punctuation.
	local punct = {
		Comma = {",", "<"},
		Period = {".", ">"},
		Slash = {"/", "?"},
		Semicolon = {";", ":"},
		Quote = {"'", "\""},
		LeftBracket = {"[", "{"},
		RightBracket = {"]", "}"},
		BackSlash = {"\\", "|"},
		Pipe = {"|", "|"},
		Minus = {"-", "_"},
		Equals = {"=", "+"},
		Backquote = {"`", "~"},
	}
	local p = punct[keyCode.Name]
	if p then
		return string.byte(shift and p[2] or p[1])
	end

	--arrow control codes
	if keyCode == Enum.KeyCode.Up then return 17 end
	if keyCode == Enum.KeyCode.Down then return 18 end
	if keyCode == Enum.KeyCode.Left then return 19 end
	if keyCode == Enum.KeyCode.Right then return 20 end

	return nil
end

local function keycodeToControlCode(keyCode)
	return keycodeToAscii(keyCode, false)
end

function InputDevice.attach(mem, screen, container, IO_BASE, options)
	IO_BASE = IO_BASE or 0x300000
	options = options or {}

	local state = {
		w = screen.width,
		h = screen.height,
		container = container,

		mouseX = 0,
		mouseY = 0,
		mouseBtns = 0,

		clickX = 0,
		clickY = 0,
		clickBtn = 0,
		clickSeq = 0,

		keyLast = 0,
		keySeq = 0,
		keysDown = {},
		controlDown = {},
		controlPressed = {},

		--actual fifo because weird queue ordering was driving me insane !
		q = {},
		qHead = 1,
		qTail = 0,
		qCount = 0,
	}

	local MAXQ = 512

	local function qPush(v)
		if state.qCount >= MAXQ then
			return --drop on overflow. missing a key is better than exploding lolol
		end
		state.qTail += 1
		state.q[state.qTail] = v
		state.qCount += 1
	end

	local function qPeek()
		if state.qCount <= 0 then return 0 end
		return state.q[state.qHead] or 0
	end

	local function qPop()
		if state.qCount <= 0 then return 0 end
		local v = state.q[state.qHead] or 0
		state.q[state.qHead] = nil
		state.qHead += 1
		state.qCount -= 1

		--when the queue empties, reset the counters so tail does not explode
		if state.qCount == 0 then
			state.qHead = 1
			state.qTail = 0
		elseif state.qHead > 256 then
			--256 felt like a solid "okay compact this junk" threshold
			local newQ = {}
			local j = 0
			for i = state.qHead, state.qTail do
				j += 1
				newQ[j] = state.q[i]
			end
			state.q = newQ
			state.qHead = 1
			state.qTail = j
		end

		return v
	end

	local function qClear()
		table.clear(state.q)
		table.clear(state.keysDown)
		table.clear(state.controlDown)
		table.clear(state.controlPressed)
		state.qHead = 1
		state.qTail = 0
		state.qCount = 0
	end
	local function onKey(actionName, inputState, input)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end

		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		local ascii = keycodeToAscii(input.KeyCode, shift)
		if ascii then
			qPush(ascii)
		end

		--eat the input so roblox does not also do something cute with it
		return Enum.ContextActionResult.Sink
	end

	local function updateMouseXY()
		local m = UserInputService:GetMouseLocation()
		local sx = m.X
		local sy = m.Y - GuiService:GetGuiInset().Y --mouse y comes in topbar space first

		--roblox gives mouse y with the topbar baked in
		--36-ish pixels on pc means 720 != 720 anymore
		--fix that before mapping into vm space or clicks go weird
		local c = state.container
		if not c then
			state.mouseX = clamp(math.floor(sx), 0, state.w - 1)
			state.mouseY = clamp(math.floor(sy), 0, state.h - 1)
			return
		end

		local pos = c.AbsolutePosition
		local size = c.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return end

		local rx = (sx - pos.X) / size.X
		local ry = (sy - pos.Y) / size.Y

		state.mouseX = clamp(math.floor(rx * state.w), 0, state.w - 1)
		state.mouseY = clamp(math.floor(ry * state.h), 0, state.h - 1)
	end

	--keep connections so reboot can tear them all down
	local conns = {}
	local function connect(sig, fn)
		local c = sig:Connect(fn)
		conns[#conns + 1] = c
		return c
	end

	--mmio window for mouse and key state
	mem:mapDevice(IO_BASE, 64,
		function(addr)
			local off = addr - IO_BASE

			if off == 0 then return state.mouseX end
			if off == 1 then return state.mouseY end
			if off == 2 then return state.mouseBtns end

			if off == 3 then return state.clickX end
			if off == 4 then return state.clickY end
			if off == 5 then return state.clickBtn end
			if off == 6 then return state.clickSeq end

			if off == 8 then return state.keyLast end
			if off == 9 then return state.keySeq end

			if off == 10 then return state.qCount end
			if off == 11 then return qPop() end
			if off == 12 then return qPeek() end
			

			return 0
		end,
		function(addr, _value)
			local off = addr - IO_BASE
			if off == 7 then
				state.clickBtn = 0
			elseif off == 13 then
				qClear()
			end
		end,
		true --user mode can read these regs
	)

	connect(UserInputService.InputChanged, function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			updateMouseXY()
		end
	end)

	local nextRepeatTime = {}

	local function handleKeyStroke(keyCode)
		state.keyLast = keyCode.Value
		state.keySeq += 1

		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)

		local ascii = keycodeToAscii(keyCode, shift)
		if ascii then
			if ctrl then
				if ascii >= 97 and ascii <= 122 then --a-z
					ascii = ascii - 96 --ctrl+a = 1 ctrl+b = 2 and so on
				elseif ascii >= 65 and ascii <= 90 then --a-z but loud
					ascii = ascii - 64
				elseif ascii == 91 then --[
					ascii = 27 --esc
				end
			end
			qPush(ascii)
		end
	end

	connect(UserInputService.InputBegan, function(input, gameProcessed)
		--keyboard still gets through even if studio already touched it
		if gameProcessed and input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end

		updateMouseXY()

		local bm = btnMask(input.UserInputType)
		if bm ~= 0 then
			state.mouseBtns = bit32.bor(state.mouseBtns, bm)
			state.clickX = state.mouseX
			state.clickY = state.mouseY
			state.clickBtn = bm
			state.clickSeq += 1
			return
		end

		if input.UserInputType == Enum.UserInputType.Keyboard then
			if state.keysDown[input.KeyCode] then
				return
			end
			state.keysDown[input.KeyCode] = true
			local controlCode = keycodeToControlCode(input.KeyCode)
			if controlCode then
				state.controlDown[controlCode] = true
				state.controlPressed[controlCode] = true
			end
			nextRepeatTime[input.KeyCode] = os.clock() + 0.4 --first repeat delay

			handleKeyStroke(input.KeyCode)
		end
	end)

	connect(game:GetService("RunService").Heartbeat, function()
		local now = os.clock()
		for keyCode, isDown in pairs(state.keysDown) do
			if isDown and nextRepeatTime[keyCode] and now >= nextRepeatTime[keyCode] then
				handleKeyStroke(keyCode)
				nextRepeatTime[keyCode] = now + 0.035 --repeat rate
			end
		end
	end)

	connect(UserInputService.InputEnded, function(input, gameProcessed)
		if gameProcessed and input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end

		local bm = btnMask(input.UserInputType)
		if bm ~= 0 then
			state.mouseBtns = bit32.band(state.mouseBtns, bit32.bnot(bm))
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local controlCode = keycodeToControlCode(input.KeyCode)
			if controlCode then
				state.controlDown[controlCode] = nil
			end
			state.keysDown[input.KeyCode] = nil
		end
	end)

	connect(UserInputService.WindowFocusReleased, function()
		qClear()
	end)

	connect(UserInputService.TextBoxFocused, function()
		qClear()
	end)

	connect(GuiService.MenuOpened, function()
		qClear()
	end)

	updateMouseXY()

	local handle = { State = state }

	function handle:IsControlDown(code)
		return state.controlDown[code] == true
	end

	function handle:ConsumeControlPressed(code)
		if state.controlPressed[code] then
			state.controlPressed[code] = nil
			return true
		end
		return false
	end

	function handle:ClearInput()
		qClear()
	end
	
	function handle:PushString(str)
		task.spawn(function()
			for i = 1, #str do
				while state.qCount >= MAXQ do
					task.wait()
				end
				if state.container == nil then break end --device got torn down mid paste :(
				
				local b = string.byte(str, i)
				if b == 10 then b = 13 end --vm wants carriage return here
				qPush(b)
			end
		end)
	end
	
	function handle:Destroy()
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
		state.container = nil
	end

	return handle
end

return InputDevice
