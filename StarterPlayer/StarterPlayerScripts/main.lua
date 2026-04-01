--!native

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local bit32 = bit32

local VM = ReplicatedStorage:WaitForChild("VirtualMachine")
local FilesystemRemote = ReplicatedStorage:WaitForChild("ROVM_Filesystem")
local CPU = require(VM.Hardware.Core.CPU)
local Assembler = require(VM.Hardware.Execution.Assembler)
local Screen = require(VM.Hardware.Devices.Screen)
local FramebufferDevice = require(VM.Hardware.Devices.FramebufferDevice)
local InputDevice = require(VM.Hardware.Devices.InputDevice)
local TextDevice = require(VM.Hardware.Devices.TextDevice)
local GPUDevice = require(VM.Hardware.Devices.GPUDevice)
local Process = require(VM.Hardware.System.Process)
local Scheduler = require(VM.Hardware.System.Scheduler)
local Filesystem = require(VM.Hardware.Storage.FileSystem)
local FileHandle = require(VM.Hardware.Storage.FileHandle)
local Memory = require(VM.Hardware.MemoryManagement.Memory)
local PhysicalMemoryAllocator = require(VM.Hardware.MemoryManagement.PhysicalMemoryAllocator)
local PageTable = require(VM.Hardware.MemoryManagement.PageTable)
local MMU = require(VM.Hardware.MemoryManagement.MMU)
local FramebufferPresenter = require(script:WaitForChild("FramebufferPresenter"))
local SystemImageBuilder = require(script:WaitForChild("SystemImageBuilder"))
local SyscallDispatcher = require(script:WaitForChild("SyscallDispatcher"))

local CompileRequest = ReplicatedStorage:WaitForChild("CompileRequest")

local player = Players.LocalPlayer

local ioDev = nil --kept so shutdown can kill old listeners
local kernelPrintScreen --filled in later so panic paths still yell

--vm sizing and mmio layout live together here
--4*1024=4096 so page math stays sane across the whole stack
local WIDTH, HEIGHT = 1280, 720
local PIX_BASE  = 0x100000
local CTRL_BASE = 0x200000
local IO_BASE   = 0x300000
local TEXT_BASE = 0x400000
local GPU_BASE  = 0x500000
local PIXEL_SIZE = 1
local SCALE = 1
local VM_PAGE_SIZE = 4096
local PROCESS_VIRTUAL_MEMORY_SIZE = 0x100000 --1 mb, stays below mmio space
local PROCESS_STACK_PAGES = 8
local EXEC_DATA_PAGES = 128
local PHYSICAL_MEMORY_SIZE = 0x400000 --4 mb

--one table because luau doesnt allow over 200 locals
local C = {
	["SC_WRITE_CHAR"] = 0, ["SC_READ_CHAR"] = 1, ["SC_FLUSH"] = 2, ["SC_EXIT"] = 3, ["SC_REBOOT"] = 4,
	["SC_FORK"] = 16, ["SC_EXEC"] = 17, ["SC_WAIT"] = 18, ["SC_GETPID"] = 19, ["SC_KILL"] = 20,
	["SC_OPEN"] = 32, ["SC_READ"] = 33, ["SC_WRITE"] = 34, ["SC_CLOSE"] = 35, ["SC_SEEK"] = 36,
	["SC_UNLINK"] = 37, ["SC_MKDIR"] = 38, ["SC_RMDIR"] = 39, ["SC_LISTDIR"] = 40, ["SC_STAT"] = 41,
	["SC_ASSEMBLE"] = 42, ["SC_COMPILE"] = 43, ["SC_EDIT"] = 44,
	["SYS_TEXT_WRITE"] = TEXT_BASE + 4, ["SYS_TEXT_CLEAR"] = TEXT_BASE + 5,
	["SYS_IO_AVAIL"] = IO_BASE + 0x0A, ["SYS_IO_READ"] = IO_BASE + 0x0B,
	["SYS_CTRL_FLUSH"] = CTRL_BASE + 1, ["SYS_CTRL_REBOOT"] = CTRL_BASE + 2,
	["SC_TEXT_CLEAR"] = 5, ["SC_TEXT_SET_CX"] = 6, ["SC_TEXT_SET_CY"] = 7, ["SC_TEXT_SET_FG"] = 8, ["SC_TEXT_SET_BG"] = 9,
	["SC_GPU_SET_VIEW"] = 55, ["SC_GPU_SET_XY"] = 56, ["SC_GPU_SET_COLOR"] = 57, ["SC_GPU_DRAW_BUFFER"] = 58,
	["SC_GPU_WAIT_FRAME"] = 59, ["SC_GPU_CLEAR_FRAME"] = 60, ["SC_GPU_DRAW_RLE"] = 61,
	["SC_GPU_GET_REMAINING_LEN"] = 62, ["SC_GPU_GET_BUFFER_ADDR"] = 63,
	["SC_GPU_PLAY_CHUNK"] = 66, ["SC_APP_WINDOW"] = 67, ["SC_APP_SET_TITLE"] = 68,
	["APP_TITLE_BAR_H"] = 24, ["APP_BORDER_W"] = 2, ["APP_CLOSE_SIZE"] = 20,
	["SC_MATH"] = 64, ["SC_SBRK"] = 65,
	["SC_FORMAT"] = 69, ["SC_CRASH"] = 70,
	["SC_PEEK_PHYS"] = 71, ["SC_POKE_PHYS"] = 72,
	["SC_LOAD_ROVD"] = 50, ["SC_GET_EXPORT"] = 51,
	["SC_SYSINFO"] = 73, ["SC_GPU_DRAW_RECTS_BATCH"] = 74,
	["SC_KEY_DOWN"] = 75, ["SC_KEY_PRESSED"] = 76, ["SC_READ_CHAR_NOWAIT"] = 77,
}

--boot uptime survives warm reboots unless the whole client reloads
_G.ROVM_BOOT_TIME = _G.ROVM_BOOT_TIME or os.clock()

--background is tweakable from the little settings panel
local BACKGROUND_IMAGE = "rbxassetid://113760701696213"

local CRT_LINE_HEIGHT = 2
local CRT_ON_EXPAND_TIME = 0.22
local CRT_ON_FADE_TIME   = 0.16
local CRT_OFF_COLLAPSE_TIME = 0.14
local CRT_OFF_FADE_TIME     = 0.10

local DEFAULT_CPU_MODE = CPU.MODE_USER

--monitor shell first, vm guts later
local CAS = game:GetService("ContextActionService")

local function swallow(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

CAS:BindActionAtPriority(
	"swallow_system_keys",
	swallow,
	false,
	Enum.ContextActionPriority.High.Value + 100,
	Enum.KeyCode.I,
	Enum.KeyCode.O,
	Enum.KeyCode.P,
	Enum.KeyCode.Period,
	Enum.KeyCode.Backquote,
	Enum.KeyCode.Slash,
	Enum.KeyCode.BackSlash,
	Enum.UserInputType.MouseWheel
)

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local background = Instance.new("ImageLabel")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.Position = UDim2.fromScale(0, 0)
background.Image = BACKGROUND_IMAGE
background.ScaleType = Enum.ScaleType.Crop
background.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
background.BorderSizePixel = 0
background.ZIndex = 0
background.Parent = gui

local monitor = Instance.new("Frame")
monitor.AnchorPoint = Vector2.new(0.5, 0.5)
monitor.Position = UDim2.fromScale(0.5, 0.5)
monitor.Size = UDim2.fromOffset(WIDTH + 34, HEIGHT + 110)
monitor.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
monitor.BorderSizePixel = 0
monitor.Parent = gui

do
	local outline = Instance.new("UIStroke")
	outline.Thickness = 2
	outline.Transparency = 0.35
	outline.Color = Color3.fromRGB(255,255,255)
	outline.Parent = monitor

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = monitor
end

local screenFrame = Instance.new("Frame")
screenFrame.Position = UDim2.fromOffset(17, 17)
screenFrame.Size = UDim2.fromOffset(WIDTH, HEIGHT)
screenFrame.BackgroundColor3 = Color3.fromRGB(0,0,0)
screenFrame.BorderSizePixel = 0
screenFrame.Parent = monitor

do
	local screenCorner = Instance.new("UICorner")
	screenCorner.CornerRadius = UDim.new(0, 10)
	screenCorner.Parent = screenFrame

	local screenStroke = Instance.new("UIStroke")
	screenStroke.Thickness = 2
	screenStroke.Transparency = 0.65
	screenStroke.Color = Color3.fromRGB(255,255,255)
	screenStroke.Parent = screenFrame
end

--overlay stays clipped so the crt wipe does not leak past the rounded corners
local overlayLayer = Instance.new("Frame")
overlayLayer.Name = "OverlayLayer"
overlayLayer.BackgroundTransparency = 1
overlayLayer.BorderSizePixel = 0
overlayLayer.Size = UDim2.fromScale(1, 1)
overlayLayer.Position = UDim2.fromScale(0, 0)
overlayLayer.ClipsDescendants = true
overlayLayer.ZIndex = 50
overlayLayer.Parent = screenFrame

do
	local overlayCorner = Instance.new("UICorner")
	overlayCorner.CornerRadius = UDim.new(0, 10)
	overlayCorner.Parent = overlayLayer
end

--framebuffer object survives. vm state around it doesnt.
local fb = Screen.new(WIDTH, HEIGHT, Color3.fromRGB(0,0,0))

local container = Instance.new("Frame")
container.Name = "Container"
container.AnchorPoint = Vector2.new(0.5, 0.5)
container.Position = UDim2.fromScale(0.5, 0.5)
container.Size = UDim2.fromOffset(WIDTH, HEIGHT)
container.BackgroundColor3 = fb.clearColor
container.BorderSizePixel = 0
container.ClipsDescendants = true
container.ZIndex = 1
container.Parent = screenFrame

local monitorScale = Instance.new("UIScale")
monitorScale.Name = "MonitorScale"
monitorScale.Scale = SCALE
monitorScale.Parent = monitor

--fallback draw layer for anything not going through editableimage tiles
local drawLayer = Instance.new("Folder")
drawLayer.Name = "DrawLayer"
drawLayer.Parent = container

--black sheet lives in overlayLayer so the crt squash doesnt resize it
local powerOverlay = Instance.new("Frame")
powerOverlay.Name = "PowerOverlay"
powerOverlay.Size = UDim2.fromScale(1, 1)
powerOverlay.Position = UDim2.fromScale(0, 0)
powerOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
powerOverlay.BackgroundTransparency = 1
powerOverlay.BorderSizePixel = 0
powerOverlay.ZIndex = 52
powerOverlay.Parent = overlayLayer

--white line for the dumb crt flare because the dumb crt flare looks good
local crtLine = Instance.new("Frame")
crtLine.Name = "CRTLine"
crtLine.AnchorPoint = Vector2.new(0.5, 0.5)
crtLine.Position = UDim2.fromScale(0.5, 0.5)
crtLine.Size = UDim2.new(1, 0, 0, CRT_LINE_HEIGHT)
crtLine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
crtLine.BackgroundTransparency = 1
crtLine.BorderSizePixel = 0
crtLine.ZIndex = 53
crtLine.Parent = overlayLayer

--buttons and little status
local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Font = Enum.Font.Code
info.TextSize = 16
info.TextColor3 = Color3.new(1,1,1)
info.TextXAlignment = Enum.TextXAlignment.Left
info.Position = UDim2.new(0, 18, 1, -40)
info.Size = UDim2.new(1, -220, 0, 24)
info.Parent = monitor

local onBtn = Instance.new("TextButton")
onBtn.Size = UDim2.fromOffset(80, 26)
onBtn.Position = UDim2.new(1, -190, 1, -44)
onBtn.Text = "on"
onBtn.Font = Enum.Font.Code
onBtn.TextSize = 16
onBtn.BackgroundColor3 = Color3.fromRGB(35, 120, 70)
onBtn.TextColor3 = Color3.new(1,1,1)
onBtn.Parent = monitor

local offBtn = Instance.new("TextButton")
offBtn.Size = UDim2.fromOffset(80, 26)
offBtn.Position = UDim2.new(1, -100, 1, -44)
offBtn.Text = "off"
offBtn.Font = Enum.Font.Code
offBtn.TextSize = 16
offBtn.BackgroundColor3 = Color3.fromRGB(40,40,55)
offBtn.TextColor3 = Color3.new(1,1,1)
offBtn.Parent = monitor

local pDot = Instance.new("Frame")
pDot.Size = UDim2.fromOffset(10, 10)
pDot.Position = UDim2.new(0, 18, 1, -70)
pDot.BackgroundColor3 = Color3.fromRGB(35, 220, 120)
pDot.BorderSizePixel = 0
pDot.Parent = monitor

local settingsBtn = Instance.new("ImageButton")
settingsBtn.Name = "SettingsButton"
settingsBtn.Size = UDim2.fromOffset(32, 32)
settingsBtn.Position = UDim2.new(1, -42, 0, 10)
settingsBtn.BackgroundTransparency = 1
settingsBtn.Image = "rbxassetid://1402032193"
settingsBtn.ImageColor3 = Color3.new(1, 1, 1)
settingsBtn.ZIndex = 1000
settingsBtn.Parent = gui

--settings ui
local settingsPanel = Instance.new("Frame")
settingsPanel.Name = "SettingsPanel"
settingsPanel.Size = UDim2.new(0, 260, 0, 340)
settingsPanel.Position = UDim2.new(1, -270, 0, 50)
settingsPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
settingsPanel.BackgroundTransparency = 0.05
settingsPanel.Visible = false
settingsPanel.Parent = gui

do
	local settingsCorner = Instance.new("UICorner")
	settingsCorner.CornerRadius = UDim.new(0, 8)
	settingsCorner.Parent = settingsPanel

	local settingsStroke = Instance.new("UIStroke")
	settingsStroke.Thickness = 1.5
	settingsStroke.Color = Color3.fromRGB(80, 80, 100)
	settingsStroke.Parent = settingsPanel
end

local settingsTitle = Instance.new("TextLabel")
settingsTitle.Size = UDim2.new(1, 0, 0, 40)
settingsTitle.BackgroundTransparency = 1
settingsTitle.Text = "SYSTEM CONFIG"
settingsTitle.Font = Enum.Font.Code
settingsTitle.TextSize = 20
settingsTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
settingsTitle.Parent = settingsPanel

--background image id
local bgLabel = Instance.new("TextLabel")
bgLabel.Size = UDim2.new(1, -20, 0, 20)
bgLabel.Position = UDim2.new(0, 10, 0, 40)
bgLabel.BackgroundTransparency = 1
bgLabel.Text = "Background Image ID:"
bgLabel.Font = Enum.Font.Code
bgLabel.TextSize = 14
bgLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
bgLabel.TextXAlignment = Enum.TextXAlignment.Left
bgLabel.Parent = settingsPanel

local bgInput = Instance.new("TextBox")
bgInput.Size = UDim2.new(1, -20, 0, 30)
bgInput.Position = UDim2.new(0, 10, 0, 65)
bgInput.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
bgInput.Text = BACKGROUND_IMAGE:match("%d+") or BACKGROUND_IMAGE
bgInput.Font = Enum.Font.Code
bgInput.TextSize = 14
bgInput.TextColor3 = Color3.new(1,1,1)
bgInput.ClearTextOnFocus = false
bgInput.Parent = settingsPanel

local bgInputCorner = Instance.new("UICorner")
bgInputCorner.CornerRadius = UDim.new(0, 4)
bgInputCorner.Parent = bgInput

--crt timing knob
local crtLabel = Instance.new("TextLabel")
crtLabel.Size = UDim2.new(1, -20, 0, 20)
crtLabel.Position = UDim2.new(0, 10, 0, 110)
crtLabel.BackgroundTransparency = 1
crtLabel.Text = "CRT Expand Time (s):"
crtLabel.Font = Enum.Font.Code
crtLabel.TextSize = 14
crtLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
crtLabel.TextXAlignment = Enum.TextXAlignment.Left
crtLabel.Parent = settingsPanel

local crtInput = Instance.new("TextBox")
crtInput.Size = UDim2.new(1, -20, 0, 30)
crtInput.Position = UDim2.new(0, 10, 0, 135)
crtInput.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
crtInput.Text = tostring(CRT_ON_EXPAND_TIME)
crtInput.Font = Enum.Font.Code
crtInput.TextSize = 14
crtInput.TextColor3 = Color3.new(1,1,1)
crtInput.Parent = settingsPanel

local crtInputCorner = Instance.new("UICorner")
crtInputCorner.CornerRadius = UDim.new(0, 4)
crtInputCorner.Parent = crtInput

--ui scale knob
local scaleLabel = Instance.new("TextLabel")
scaleLabel.Size = UDim2.new(1, -20, 0, 20)
scaleLabel.Position = UDim2.new(0, 10, 0, 180)
scaleLabel.BackgroundTransparency = 1
scaleLabel.Text = "System UI Scale:"
scaleLabel.Font = Enum.Font.Code
scaleLabel.TextSize = 14
scaleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
scaleLabel.TextXAlignment = Enum.TextXAlignment.Left
scaleLabel.Parent = settingsPanel

local scaleInput = Instance.new("TextBox")
scaleInput.Size = UDim2.new(1, -20, 0, 30)
scaleInput.Position = UDim2.new(0, 10, 0, 205)
scaleInput.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
scaleInput.Text = tostring(monitorScale.Scale)
scaleInput.Font = Enum.Font.Code
scaleInput.TextSize = 14
scaleInput.TextColor3 = Color3.new(1,1,1)
scaleInput.Parent = settingsPanel

local scaleInputCorner = Instance.new("UICorner")
scaleInputCorner.CornerRadius = UDim.new(0, 4)
scaleInputCorner.Parent = scaleInput

do
	local fpsToggleLabel = Instance.new("TextLabel")
	fpsToggleLabel.Size = UDim2.new(1, -20, 0, 20)
	fpsToggleLabel.Position = UDim2.new(0, 10, 0, 250)
	fpsToggleLabel.BackgroundTransparency = 1
	fpsToggleLabel.Text = "Show FPS Counter:"
	fpsToggleLabel.Font = Enum.Font.Code
	fpsToggleLabel.TextSize = 14
	fpsToggleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
	fpsToggleLabel.TextXAlignment = Enum.TextXAlignment.Left
	fpsToggleLabel.Parent = settingsPanel

	local fpsToggleButton = Instance.new("TextButton")
	fpsToggleButton.Name = "FPSToggleButton"
	fpsToggleButton.Size = UDim2.new(1, -20, 0, 30)
	fpsToggleButton.Position = UDim2.new(0, 10, 0, 275)
	fpsToggleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
	fpsToggleButton.TextColor3 = Color3.new(1, 1, 1)
	fpsToggleButton.Text = "Disabled"
	fpsToggleButton.Font = Enum.Font.Code
	fpsToggleButton.TextSize = 14
	fpsToggleButton.Parent = settingsPanel

	local fpsToggleCorner = Instance.new("UICorner")
	fpsToggleCorner.CornerRadius = UDim.new(0, 4)
	fpsToggleCorner.Parent = fpsToggleButton

	fpsToggleButton.MouseButton1Click:Connect(function()
		local label = overlayLayer:FindFirstChild("FPSLabel")
		if not label then
			return
		end
		local enabled = not label.Visible
		label.Visible = enabled
		fpsToggleButton.Text = enabled and "Enabled" or "Disabled"
		fpsToggleButton.BackgroundColor3 = enabled
			and Color3.fromRGB(35, 120, 70)
			or Color3.fromRGB(40, 40, 55)
	end)
end

bgInput.FocusLost:Connect(function(enterPressed)
	local id = bgInput.Text
	if id:match("^%d+$") then
		BACKGROUND_IMAGE = "rbxassetid://" .. id
	else
		BACKGROUND_IMAGE = id
	end
	background.Image = BACKGROUND_IMAGE
end)

crtInput.FocusLost:Connect(function(enterPressed)
	local val = tonumber(crtInput.Text)
	if val then
		CRT_ON_EXPAND_TIME = val
	end
end)

scaleInput.FocusLost:Connect(function(enterPressed)
	local val = tonumber(scaleInput.Text)
	if val then
		monitorScale.Scale = val
	end
end)

settingsBtn.MouseButton1Click:Connect(function()
	settingsPanel.Visible = not settingsPanel.Visible
end)

local pasteBtn = Instance.new("TextButton")
pasteBtn.Name = "PasteButton"
pasteBtn.Size = UDim2.fromOffset(60, 32)
pasteBtn.Position = UDim2.new(1, -112, 0, 10)
pasteBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
pasteBtn.TextColor3 = Color3.new(1,1,1)
pasteBtn.Text = "Paste"
pasteBtn.Font = Enum.Font.Code
pasteBtn.TextSize = 14
pasteBtn.ZIndex = 1000
pasteBtn.Parent = gui

do
	local pasteCorner = Instance.new("UICorner")
	pasteCorner.CornerRadius = UDim.new(0, 4)
	pasteCorner.Parent = pasteBtn
end

local pastePanel = Instance.new("Frame")
pastePanel.Name = "PastePanel"
pastePanel.Size = UDim2.new(0, 400, 0, 300)
pastePanel.Position = UDim2.new(0.5, -200, 0.5, -150)
pastePanel.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
pastePanel.Visible = false
pastePanel.ZIndex = 1100
pastePanel.Parent = gui

do
	local pastePanelCorner = Instance.new("UICorner")
	pastePanelCorner.CornerRadius = UDim.new(0, 8)
	pastePanelCorner.Parent = pastePanel
end

local pasteTitle = Instance.new("TextLabel")
pasteTitle.Size = UDim2.new(1, 0, 0, 40)
pasteTitle.BackgroundTransparency = 1
pasteTitle.Text = "PASTE CLIPBOARD"
pasteTitle.Font = Enum.Font.Code
pasteTitle.TextSize = 20
pasteTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
pasteTitle.Parent = pastePanel

local pasteInput = Instance.new("TextBox")
pasteInput.Size = UDim2.new(1, -20, 1, -90)
pasteInput.Position = UDim2.new(0, 10, 0, 40)
pasteInput.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
pasteInput.TextColor3 = Color3.fromRGB(200, 200, 200)
pasteInput.Text = ""
pasteInput.PlaceholderText = "Ctrl+V here..."
pasteInput.TextXAlignment = Enum.TextXAlignment.Left
pasteInput.TextYAlignment = Enum.TextYAlignment.Top
pasteInput.MultiLine = true
pasteInput.ClearTextOnFocus = false
pasteInput.Font = Enum.Font.Code
pasteInput.TextSize = 14
pasteInput.Parent = pastePanel

local pasteSubmit = Instance.new("TextButton")
pasteSubmit.Size = UDim2.new(0, 100, 0, 30)
pasteSubmit.Position = UDim2.new(0.5, -50, 1, -40)
pasteSubmit.BackgroundColor3 = Color3.fromRGB(35, 120, 70)
pasteSubmit.TextColor3 = Color3.new(1,1,1)
pasteSubmit.Text = "Send to VM"
pasteSubmit.Font = Enum.Font.Code
pasteSubmit.TextSize = 14
pasteSubmit.Parent = pastePanel

local pasteCancel = Instance.new("TextButton")
pasteCancel.Size = UDim2.new(0, 40, 0, 30)
pasteCancel.Position = UDim2.new(1, -50, 0, 5)
pasteCancel.BackgroundColor3 = Color3.fromRGB(120, 35, 35)
pasteCancel.TextColor3 = Color3.new(1,1,1)
pasteCancel.Text = "X"
pasteCancel.Font = Enum.Font.Code
pasteCancel.TextSize = 14
pasteCancel.Parent = pastePanel

pasteBtn.MouseButton1Click:Connect(function()
	pasteInput.Text = ""
	pastePanel.Visible = true
	pasteInput:CaptureFocus()
end)

pasteCancel.MouseButton1Click:Connect(function()
	pastePanel.Visible = false
end)

pasteSubmit.MouseButton1Click:Connect(function()
	local text = pasteInput.Text
	if ioDev and ioDev.PushString and #text > 0 then
		ioDev:PushString(text)
	end
	pastePanel.Visible = false
	pasteInput.Text = ""
end)

do
	local pDotCorner = Instance.new("UICorner")
	pDotCorner.CornerRadius = UDim.new(1, 0)
	pDotCorner.Parent = pDot
end

--bottom right overlay bits
local creditLabel = Instance.new("TextLabel")
creditLabel.Name = "CreditLabel"
creditLabel.BackgroundTransparency = 1
creditLabel.AnchorPoint = Vector2.new(1, 1)
creditLabel.Position = UDim2.new(1, -8, 1, -6)
creditLabel.Size = UDim2.fromOffset(180, 18)
creditLabel.Font = Enum.Font.Code
creditLabel.TextSize = 12
creditLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
creditLabel.TextStrokeTransparency = 0.5
creditLabel.TextXAlignment = Enum.TextXAlignment.Right
creditLabel.TextYAlignment = Enum.TextYAlignment.Bottom
creditLabel.Text = "Made by Plasmism"
creditLabel.ZIndex = 54
creditLabel.Parent = overlayLayer

local fpsLabel = Instance.new("TextLabel")
fpsLabel.Name = "FPSLabel"
fpsLabel.BackgroundTransparency = 1
fpsLabel.AnchorPoint = Vector2.new(1, 1)
fpsLabel.Position = UDim2.new(1, -8, 1, -6)
fpsLabel.Size = UDim2.fromOffset(90, 18)
fpsLabel.Font = Enum.Font.Code
fpsLabel.TextSize = 14
fpsLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
fpsLabel.TextStrokeTransparency = 0.5
fpsLabel.TextXAlignment = Enum.TextXAlignment.Right
fpsLabel.TextYAlignment = Enum.TextYAlignment.Bottom
fpsLabel.Text = "FPS: 0"
fpsLabel.Visible = false
fpsLabel.ZIndex = 54
fpsLabel.Parent = overlayLayer

do
	local fpsTimer = 0
	local fpsFrames = 0
	local lastFps = -1

	RunService.RenderStepped:Connect(function(dt)
		if not fpsLabel.Visible then
			fpsTimer = 0
			fpsFrames = 0
			lastFps = -1
			return
		end

		fpsTimer += dt
		fpsFrames += 1

		if fpsTimer >= 1.0 then
			local fps = math.floor(fpsFrames / fpsTimer + 0.5)
			if fps ~= lastFps then
				fpsLabel.Text = "FPS: " .. fps
				lastFps = fps
			end
			fpsTimer = 0
			fpsFrames = 0
		end
	end)
end

--small tween wrappers so i stop retyping tweeninfo nonsense
local function tween(obj, t, props, style, dir)
	local ti = TweenInfo.new(
		t,
		style or Enum.EasingStyle.Quad,
		dir or Enum.EasingDirection.Out
	)
	local tw = TweenService:Create(obj, ti, props)
	tw:Play()
	return tw
end

local function waitTween(tw)
	local ok = pcall(function() tw.Completed:Wait() end)
	return ok
end

--crt power anims. squash to line, expand back out.
local FULL_SIZE = UDim2.fromOffset(WIDTH, HEIGHT)
local LINE_SIZE = UDim2.fromOffset(WIDTH, CRT_LINE_HEIGHT)

local animToken = 0
local function nextAnimToken()
	animToken += 1
	return animToken
end
local function isAnim(tok) return tok == animToken end

local function playPowerOnAnim(tok)
	--start black with the bright center line
	powerOverlay.BackgroundTransparency = 0
	crtLine.BackgroundTransparency = 0.2
	container.Size = LINE_SIZE

	--clipping makes this read like an old tube turning on
	local twExpand = tween(container, CRT_ON_EXPAND_TIME, {Size = FULL_SIZE}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	--fade the line while the screen opens
	tween(crtLine, CRT_ON_EXPAND_TIME * 0.9, {BackgroundTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	waitTween(twExpand)
	if not isAnim(tok) then return end

	--then peel the black overlay away
	local twFade = tween(powerOverlay, CRT_ON_FADE_TIME, {BackgroundTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	waitTween(twFade)
end

local function playPowerOffAnim(tok)
	--leave overlay off so the collapse is actually visible
	powerOverlay.BackgroundTransparency = 1
	crtLine.BackgroundTransparency = 1
	container.Size = FULL_SIZE

	--squash back to the line
	local twCollapse = tween(container, CRT_OFF_COLLAPSE_TIME, {Size = LINE_SIZE}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	--little flash
	tween(crtLine, 0.05, {BackgroundTransparency = 0.15}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	waitTween(twCollapse)
	if not isAnim(tok) then return end

	--then snap to black and kill the line
	local twBlack = tween(powerOverlay, CRT_OFF_FADE_TIME, {BackgroundTransparency = 0}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tween(crtLine, CRT_OFF_FADE_TIME, {BackgroundTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	waitTween(twBlack)
end

--runtime vm state. reboot rebuilds this stuff.
local mem = nil
local cpu = nil  --legacy handle. scheduler owns the real process cpus now.
local fbCtrl = nil
local textDev = nil
local scheduler = nil  --process scheduler
local filesystem = nil  --virtual filesystem
local physicalAllocator = nil  --physical page allocator
local mmu = nil  --memory management unit
local presentIfRequested = nil --forward decl so boot and shutdown can both see it

local poweredOn = false
local runToken = 0 --bump this to cancel any older cpu loop immediately
local autoSaveTask = nil  --periodic auto-save task
local ttyDirty = false
local vmInstructionCount = 0
local vmMipsX100 = 0
local vmExecutionTime = 0

local framebufferPresenter = FramebufferPresenter.new({
	WIDTH = WIDTH,
	HEIGHT = HEIGHT,
	PIXEL_SIZE = PIXEL_SIZE,
	GPU_BASE = GPU_BASE,
	C = C,
	container = container,
	drawLayer = drawLayer,
	fb = fb,
	getScheduler = function()
		return scheduler
	end,
})
local editableImages = framebufferPresenter:getEditableImages()
local function clearAllDrawFrames()
	return framebufferPresenter.clearAllDrawFrames()
end
local function resetFramebufferTables()
	return framebufferPresenter.resetFramebufferTables()
end
local function flushPixelBuffer()
	return framebufferPresenter.flushPixelBuffer()
end
local function clearPixelBuffer(color)
	return framebufferPresenter.clearPixelBuffer(color)
end
presentIfRequested = function()
	return framebufferPresenter.presentIfRequested()
end

--crash supervisor so pid 1 cannot clown-car reboot forever
local procGen = 0                --bumps whenever a new user proc is born
local respawnQueued = false

local CRASH_WINDOW = 2.0         --seconds
local CRASH_MAX = 6              --max restarts per window
local crashWindowStart = 0
local crashCount = 0

local RESPAWN_BASE_DELAY = 0.15  --seconds
local RESPAWN_MAX_DELAY  = 2.0
local respawnDelay = RESPAWN_BASE_DELAY


--kernel read/write helpers below so faults stay loud
local function kread(addr)
	local v, f = mem:read(addr)
	if f then
		error(("KERNEL PANIC: mem read (%s) @ 0x%X"):format(f, addr))
	end
	return v
end

local function kwrite(addr, value)
	local ok, f = mem:write(addr, value)
	if f then
		error(("KERNEL PANIC: mem write (%s) @ 0x%X"):format(f, addr))
	end
	return ok
end

local function translateUser(addr, accessType)
	if not mmu then
		return addr, nil, nil
	end
	local prevKernelMode = mmu.kernelMode
	mmu:setKernelMode(false)
	local phys, fault, info = mmu:translate(addr, accessType)
	mmu:setKernelMode(prevKernelMode)
	return phys, fault, info
end

local function userReadWord(addr)
	local phys, fault, info = translateUser(addr, "read")
	if fault then
		return nil, fault, info
	end
	if phys < 0 or phys + 3 >= mem.size then
		return nil, "ram_oob_read"
	end
	return buffer.readu32(mem.buf, phys), nil
end

local function userWriteWord(addr, value)
	local phys, fault, info = translateUser(addr, "write")
	if fault then
		return nil, fault, info
	end
	if phys < 0 or phys + 3 >= mem.size then
		return nil, "ram_oob_write"
	end
	buffer.writeu32(mem.buf, phys, value)
	return true, nil
end

local function userReadByte(addr)
	local phys, fault, info = translateUser(addr, "read")
	if fault then
		return nil, fault, info
	end
	if phys < 0 or phys >= mem.size then
		return nil, "ram_oob_read"
	end
	return buffer.readu8(mem.buf, phys), nil
end

local function userWriteByte(addr, value)
	local phys, fault, info = translateUser(addr, "write")
	if fault then
		return nil, fault, info
	end
	if phys < 0 or phys >= mem.size then
		return nil, "ram_oob_write"
	end
	buffer.writeu8(mem.buf, phys, value)
	return true, nil
end

local function userReadWord(addr)
	local phys, fault, info = translateUser(addr, "read")
	if fault then return nil, fault, info end
	if phys < 0 or phys + 3 >= mem.size then return nil, "ram_oob_read" end
	return buffer.readu32(mem.buf, phys), nil
end

local function userWriteWord(addr, value)
	local phys, fault, info = translateUser(addr, "write")
	if fault then return nil, fault, info end
	if phys < 0 or phys + 3 >= mem.size then return nil, "ram_oob_write" end
	buffer.writeu32(mem.buf, phys, value)
	return true, nil
end

local function userReadString(addr, maxLen)
	maxLen = maxLen or 256
	local out = {}
	for i = 0, maxLen - 1 do
		local byte, fault = userReadByte(addr + i)
		if fault then
			return nil, fault
		end
		if byte == 0 then
			break
		end
		out[#out + 1] = string.char(byte)
	end
	return table.concat(out), nil
end

local function getProcessVirtualMemorySize(proc)
	if proc and proc.memoryRegion and proc.memoryRegion.size then
		return proc.memoryRegion.size
	end
	return PROCESS_VIRTUAL_MEMORY_SIZE
end

local function getProcessStackBase(proc)
	local virtualMemSize = getProcessVirtualMemorySize(proc)
	return math.max(0, virtualMemSize - (PROCESS_STACK_PAGES * VM_PAGE_SIZE))
end

local function ensureProcessRangeMapped(proc, startAddr, endAddrExclusive, permissions)
	if not proc or not proc.pageTable then
		return false, "no_page_table"
	end
	if endAddrExclusive <= startAddr then
		return true, nil
	end

	local virtualMemSize = getProcessVirtualMemorySize(proc)
	if startAddr < 0 or endAddrExclusive > virtualMemSize then
		return false, "address_out_of_range"
	end

	local firstPage = math.floor(startAddr / VM_PAGE_SIZE)
	local lastPage = math.floor((endAddrExclusive - 1) / VM_PAGE_SIZE)
	local mappedPages = {}

	for vp = firstPage, lastPage do
		if not proc.pageTable.entries[vp] then
			local ok, err = proc.pageTable:mapPage(vp, nil, permissions)
			if not ok then
				for i = #mappedPages, 1, -1 do
					proc.pageTable:unmapPage(mappedPages[i])
				end
				return false, err or "failed_to_map_page"
			end
			mappedPages[#mappedPages + 1] = vp
		end
	end

	return true, nil
end

local function kreadByte(addr)
	local v, f = mem:readByte(addr)
	if f then
		error(("KERNEL PANIC: mem readByte (%s) @ 0x%X"):format(f, addr))
	end
	return v
end

local function kwriteByte(addr, value)
	local ok, f = mem:writeByte(addr, value)
	if f then
		error(("KERNEL PANIC: mem writeByte (%s) @ 0x%X"):format(f, addr))
	end
	return ok
end

local function kreadString(addr, maxLen)
	maxLen = maxLen or 256
	local str = {}
	for i = 0, maxLen - 1 do
		local byte = kreadByte(addr + i)
		if byte == 0 then
			break
		end
		table.insert(str, string.char(byte))
	end
	return table.concat(str)
end

local function kwriteString(addr, str)
	for i = 1, #str do
		kwriteByte(addr + i - 1, string.byte(str, i))
	end
	kwriteByte(addr + #str, 0)
	return #str + 1
end

--binary format helpers
--binary image note
--rovm header is 4+4+4+4 bytes = 16
--that means magic entry text_size data_size, all little endian

local BINARY_MAGIC = 0x524F564D  --"ROVM"
local ROVD_MAGIC    = 0x524F5644  --"ROVD"
local ROVD_HEADER_SIZE = 32
local HEADER_SIZE = 16  --4+4+4+4

--assembler already packed the image, so serialization is just tostring
local function serializeBinary(codeBuf, entryPoint)
	--header is already baked in by the assembler
	return buffer.tostring(codeBuf)
end

--pull the header back apart and return image layout info too
local function deserializeBinary(binary)
	if #binary < HEADER_SIZE then
		return nil, "binary too small (need at least 16 bytes for header)"
	end

	local headerBuf = buffer.fromstring(binary:sub(1, ROVD_HEADER_SIZE))
	local magic = buffer.readu32(headerBuf, 0)

	if magic == ROVD_MAGIC then
		if #binary < ROVD_HEADER_SIZE then
			return nil, "ROVD binary too small"
		end
		local exportTableOffset = buffer.readu32(headerBuf, 4)
		local exportCount = buffer.readu32(headerBuf, 8)
		local textSize = buffer.readu32(headerBuf, 12)
		local dataSize = buffer.readu32(headerBuf, 16)
		local relocTableOffset = buffer.readu32(headerBuf, 20)
		local relocCount = buffer.readu32(headerBuf, 24)
		local imageSize = #binary
		local isSectioned = (dataSize > 0) and (ROVD_HEADER_SIZE + textSize + dataSize <= imageSize)
		if not isSectioned then
			textSize = math.max(0, imageSize - ROVD_HEADER_SIZE)
			dataSize = 0
		end

		local codeBuf = buffer.fromstring(binary)
		return codeBuf, nil, 0, {
			isRovd = true,
			headerSize = ROVD_HEADER_SIZE,
			exportTableOffset = exportTableOffset,
			exportCount = exportCount,
			textSize = textSize,
			dataSize = dataSize,
			relocTableOffset = relocTableOffset,
			relocCount = relocCount,
			imageSize = imageSize,
			isSectioned = isSectioned,
			legacyFlat = not isSectioned,
		}
	elseif magic == BINARY_MAGIC then
		local entryPoint = buffer.readu32(headerBuf, 4)
		local textSize = buffer.readu32(headerBuf, 8)
		local dataSize = buffer.readu32(headerBuf, 12)
		local imageSize = #binary
		local isSectioned = (dataSize > 0) and (HEADER_SIZE + textSize + dataSize <= imageSize)
		if not isSectioned then
			textSize = math.max(0, imageSize - HEADER_SIZE)
			dataSize = 0
		end
		local codeBuf = buffer.fromstring(binary)
		return codeBuf, nil, entryPoint, {
			isRovd = false,
			headerSize = HEADER_SIZE,
			textSize = textSize,
			dataSize = dataSize,
			imageSize = imageSize,
			isSectioned = isSectioned,
			legacyFlat = not isSectioned,
		}
	else
		return nil, "invalid magic number (not a ROVM binary)"
	end
end

local DECODE_WIDE_OPCODE = {
	[0x06] = true,
	[0x07] = true,
	[0x08] = true,
	[0x16] = true,
	[0x17] = true,
	[0x18] = true,
	[0x19] = true,
	[0x1A] = true,
	[0x1B] = true,
	[0x1C] = true,
	[0x22] = true,
}

local function signExtend16(value)
	if value >= 0x8000 then
		return value - 0x10000
	end
	return value
end

local function cloneDecodeSegments(segments)
	if not segments or #segments == 0 then
		return {}
	end
	local copy = table.create(#segments)
	for i = 1, #segments do
		copy[i] = segments[i]
	end
	return copy
end

local function buildDecodeSegmentFromBinary(codeBuf, loadBase, info)
	if not info or not info.isSectioned or (info.textSize or 0) <= 0 then
		return nil
	end

	local headerSize = info.headerSize or HEADER_SIZE
	local textOffset = headerSize
	local textSize = info.textSize
	local textEnd = textOffset + textSize
	local bufLen = buffer.len(codeBuf)
	if textEnd > bufLen then
		return nil
	end

	local entries = table.create(math.floor(textSize / 4))
	local pos = textOffset
	while pos < textEnd do
		if pos + 3 >= textEnd then
			return nil
		end
		local instr = buffer.readu32(codeBuf, pos)
		local opcode = bit32.rshift(instr, 24)
		local d = bit32.band(bit32.rshift(instr, 16), 0xFF)
		local a = bit32.band(bit32.rshift(instr, 8), 0xFF)
		local b = bit32.band(instr, 0xFF)
		local entry = {
			opcode = opcode,
			d = d,
			a = a,
			b = b,
			size = 4,
		}
		if DECODE_WIDE_OPCODE[opcode] then
			if pos + 7 >= textEnd then
				return nil
			end
			entry.size = 8
			entry.imm = buffer.readu32(codeBuf, pos + 4)
		elseif opcode >= 0x32 and opcode <= 0x37 then
			entry.imm = signExtend16(bit32.lshift(a, 8) + b)
		end
		entries[((pos - textOffset) / 4) + 1] = entry
		pos += entry.size
	end

	return {
		base = loadBase + textOffset,
		limit = loadBase + textOffset + textSize,
		entries = entries,
	}
end

local function copyBufferIntoProcess(pageTable, baseAddr, srcBuf)
	local length = buffer.len(srcBuf)
	local pageSize = VM_PAGE_SIZE
	local copied = 0
	while copied < length do
		local vAddr = baseAddr + copied
		local vPage = math.floor(vAddr / pageSize)
		local pageOff = vAddr % pageSize
		local chunk = math.min(pageSize - pageOff, length - copied)
		local physPage = pageTable:translate(vPage)
		if not physPage then
			return false, ("page not mapped for addr 0x%X"):format(vAddr)
		end
		local physAddr = physPage * pageSize + pageOff
		if physAddr < 0 or physAddr + chunk > mem.size then
			return false, ("physical write out of range @ 0x%X"):format(physAddr)
		end
		buffer.copy(mem.buf, physAddr, srcBuf, copied, chunk)
		copied += chunk
	end
	return true, nil
end

local function applyBinaryPermissions(pageTable, baseAddr, imageSize, info)
	local pageSize = VM_PAGE_SIZE
	local readPerm = PageTable.PERM_READ
	local writePerm = PageTable.PERM_WRITE
	local execPerm = PageTable.PERM_EXEC
	local imageEnd = baseAddr + imageSize

	if not info or not info.isSectioned then
		local firstPage = math.floor(baseAddr / pageSize)
		local lastPage = math.floor(math.max(baseAddr, imageEnd - 1) / pageSize)
		for vp = firstPage, lastPage do
			pageTable:setPermissions(vp, readPerm + writePerm + execPerm)
		end
		return
	end

	local textEnd = baseAddr + (info.headerSize or HEADER_SIZE) + (info.textSize or 0)
	local firstPage = math.floor(baseAddr / pageSize)
	local lastPage = math.floor(math.max(baseAddr, imageEnd - 1) / pageSize)
	for vp = firstPage, lastPage do
		local pageStart = vp * pageSize
		local pageEnd = pageStart + pageSize
		local perms = readPerm
		local overlapsText = pageStart < textEnd and pageEnd > baseAddr
		local overlapsWritable = pageStart < imageEnd and pageEnd > textEnd
		if overlapsText then
			perms += execPerm
		end
		if overlapsWritable then
			perms += writePerm
		end
		pageTable:setPermissions(vp, perms)
	end
end

local function installCpuImageLayout(targetCpu, imageBuf, info, loadBase, clearExisting)
	if clearExisting then
		targetCpu:clearDecodeSegments()
		targetCpu.strictExecute = false
	end
	if not info or not info.isSectioned then
		return
	end
	targetCpu.strictExecute = true
	local segment = buildDecodeSegmentFromBinary(imageBuf, loadBase or 0, info)
	if segment then
		targetCpu:addDecodeSegment(segment)
	end
end

--read a guest program image from fs and decode it
local function loadProgramFromFile(path)
	if not filesystem then
		return nil, "filesystem not initialized"
	end

	--grab the file first
	local inode, err = filesystem:resolvePath(path)
	if not inode then
		return nil, "file not found: " .. path
	end

	local data, readErr = filesystem:readFile(inode)
	if not data then
		return nil, "failed to read file: " .. (readErr or "unknown error")
	end

	--then crack the image header back open
	local code, deserializeErr, entryPoint, rovdInfo = deserializeBinary(data)
	if not code then
		return nil, "failed to parse binary: " .. (deserializeErr or "unknown error")
	end

	return code, nil, entryPoint, rovdInfo
end

local systemImageBuilder = SystemImageBuilder.new({
	getFilesystem = function()
		return filesystem
	end,
	ReplicatedStorage = ReplicatedStorage,
	CompileRequest = CompileRequest,
	Assembler = Assembler,
	serializeBinary = serializeBinary,
})

local function ensureDefaultBloxOSFiles(bootCallbacks)
	return systemImageBuilder:ensureDefaultBloxOSFiles(bootCallbacks)
end

local function normalizeBootPath(path)
	if not path then
		return nil
	end
	path = path:gsub("^%s+", ""):gsub("%s+$", "")
	if path:sub(1, 1) == "\"" and path:sub(-1) == "\"" then
		path = path:sub(2, -2)
	end
	path = path:gsub("\\", "/")
	path = path:gsub("^%a:/", "/")
	if path ~= "" and path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end
	return path
end

local function readBootIniPath()
	if not filesystem then
		return nil, "filesystem not initialized"
	end
	local inode = filesystem:resolvePath("/boot/boot.ini")
	if not inode then
		return nil, "boot.ini not found"
	end
	local data = filesystem:readFile(inode)
	if not data then
		return nil, "failed to read boot.ini"
	end
	for line in data:gmatch("[^\r\n]+") do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed ~= "" and not trimmed:match("^[#;]") then
			local key, value = trimmed:match("^(%w+)%s*=%s*(.+)$")
			if key then
				local lower = key:lower()
				if lower == "boot" or lower == "path" then
					return normalizeBootPath(value), nil
				end
			else
				return normalizeBootPath(trimmed), nil
			end
		end
	end
	return nil, "boot.ini has no path"
end

local BIOS_CONFIG_PATH = "/boot/bios.ini"
local BIOS_DEFAULTS = {
	boot_mode = "normal",
	verbose_boot = false,
	wait_for_key = true,
	auto_save = true,
	auto_save_interval = 30,
}
local BIOS_VALID_INTERVALS = {
	[15] = true,
	[30] = true,
	[60] = true,
	[120] = true,
}

local function cloneBiosConfig()
	return {
		boot_mode = BIOS_DEFAULTS.boot_mode,
		verbose_boot = BIOS_DEFAULTS.verbose_boot,
		wait_for_key = BIOS_DEFAULTS.wait_for_key,
		auto_save = BIOS_DEFAULTS.auto_save,
		auto_save_interval = BIOS_DEFAULTS.auto_save_interval,
	}
end

local function parseBool(value)
	if value == nil then
		return nil
	end
	local lowered = tostring(value):lower()
	if lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on" then
		return true
	end
	if lowered == "0" or lowered == "false" or lowered == "no" or lowered == "off" then
		return false
	end
	return nil
end

local function normalizeBiosConfig(config)
	local cfg = cloneBiosConfig()
	if type(config) == "table" then
		for key, value in pairs(config) do
			cfg[key] = value
		end
	end

	if cfg.boot_mode ~= "normal" and cfg.boot_mode ~= "recovery" then
		cfg.boot_mode = BIOS_DEFAULTS.boot_mode
	end

	local verboseBoot = parseBool(cfg.verbose_boot)
	if verboseBoot == nil then
		verboseBoot = BIOS_DEFAULTS.verbose_boot
	end
	cfg.verbose_boot = verboseBoot

	local waitForKey = parseBool(cfg.wait_for_key)
	if waitForKey == nil then
		waitForKey = BIOS_DEFAULTS.wait_for_key
	end
	cfg.wait_for_key = waitForKey

	local autoSave = parseBool(cfg.auto_save)
	if autoSave == nil then
		autoSave = BIOS_DEFAULTS.auto_save
	end
	cfg.auto_save = autoSave

	local interval = tonumber(cfg.auto_save_interval) or BIOS_DEFAULTS.auto_save_interval
	interval = math.floor(interval)
	if not BIOS_VALID_INTERVALS[interval] then
		interval = BIOS_DEFAULTS.auto_save_interval
	end
	cfg.auto_save_interval = interval

	return cfg
end

local function serializeBiosConfig(config)
	local cfg = normalizeBiosConfig(config)
	return table.concat({
		"boot_mode=" .. cfg.boot_mode,
		"verbose_boot=" .. (cfg.verbose_boot and "true" or "false"),
		"wait_for_key=" .. (cfg.wait_for_key and "true" or "false"),
		"auto_save=" .. (cfg.auto_save and "true" or "false"),
		"auto_save_interval=" .. tostring(cfg.auto_save_interval),
	}, "\n") .. "\n"
end

local function loadBiosConfig()
	local cfg = cloneBiosConfig()
	if not filesystem then
		return cfg, "filesystem not initialized"
	end

	local inode = filesystem:resolvePath(BIOS_CONFIG_PATH)
	if not inode then
		return cfg, "bios.ini not found"
	end

	local data = filesystem:readFile(inode)
	if not data then
		return cfg, "failed to read bios.ini"
	end

	for line in data:gmatch("[^\r\n]+") do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed ~= "" and not trimmed:match("^[#;]") then
			local key, value = trimmed:match("^([%w_]+)%s*=%s*(.+)$")
			if key then
				local lowered = key:lower()
				if lowered == "boot_mode" then
					cfg.boot_mode = tostring(value):lower()
				elseif lowered == "verbose_boot" then
					cfg.verbose_boot = value
				elseif lowered == "wait_for_key" then
					cfg.wait_for_key = value
				elseif lowered == "auto_save" then
					cfg.auto_save = value
				elseif lowered == "auto_save_interval" then
					cfg.auto_save_interval = value
				end
			end
		end
	end

	return normalizeBiosConfig(cfg), nil
end

local function saveBiosConfig(config)
	if not filesystem then
		return false, "filesystem not initialized"
	end

	local payload = serializeBiosConfig(config)
	local inode = filesystem:resolvePath(BIOS_CONFIG_PATH)
	if inode then
		return filesystem:writeFile(inode, payload)
	end

	local created = filesystem:createFile(BIOS_CONFIG_PATH, payload)
	if not created then
		return false, "failed to create bios.ini"
	end
	return true, nil
end

local function countFilesystemInodes()
	if not filesystem or not filesystem.inodes then
		return 0
	end
	local count = 0
	for _ in pairs(filesystem.inodes) do
		count += 1
	end
	return count
end

local function getEffectiveBootPath(biosConfig)
	local cfg = normalizeBiosConfig(biosConfig)
	if cfg.boot_mode == "recovery" then
		return "/bin/sh.rov", nil
	end
	local bootPath, bootErr = readBootIniPath()
	if not bootPath or bootPath == "" then
		return "/bin/sh.rov", bootErr
	end
	return bootPath, nil
end

local function getBiosBootFlags(config)
	local cfg = normalizeBiosConfig(config)
	local flags = {}
	flags[#flags + 1] = cfg.boot_mode == "recovery" and "recovery" or "normal"
	if cfg.verbose_boot then
		flags[#flags + 1] = "verbose"
	end
	if cfg.wait_for_key then
		flags[#flags + 1] = "waitkey"
	end
	if cfg.auto_save then
		flags[#flags + 1] = "autosave=" .. tostring(cfg.auto_save_interval) .. "s"
	else
		flags[#flags + 1] = "autosave=off"
	end
	return table.concat(flags, " ")
end

local activeBiosConfig = normalizeBiosConfig()

local function loadFilesystemFromServer()
	if not FilesystemRemote then
		return false, "filesystem remote missing"
	end

	local ok, result, err = pcall(function()
		return FilesystemRemote:InvokeServer("load")
	end)
	if not ok then
		return false, result
	end
	if result == false then
		return false, err or "server load failed"
	end
	if result then
		return filesystem:deserialize(result)
	end
	return true, nil
end

local function saveFilesystemToServer()
	if not FilesystemRemote then
		return false, "filesystem remote missing"
	end

	local payload = filesystem:serialize()
	local ok, result, err = pcall(function()
		return FilesystemRemote:InvokeServer("save", payload)
	end)
	if not ok then
		return false, result
	end
	if result ~= true then
		return false, err or "server save failed"
	end
	return true, nil
end

local function flushTTY()
	if ttyDirty then
		kwrite(C["SYS_CTRL_FLUSH"], 1)
		ttyDirty = false
	end
end

local function clearSharedInput()
	if ioDev and ioDev.ClearInput then
		ioDev:ClearInput()
	else
		kwrite(IO_BASE + 13, 1)
	end
end

local function requestFramebufferFlush()
	kwrite(C["SYS_CTRL_FLUSH"], 1)
end

local function toSigned32(value)
	if value == nil then
		return 0
	end
	if value >= 0x80000000 then
		return value - 0x100000000
	end
	return value
end

local function computeVmMipsX100()
	return vmMipsX100
end

local function calibrateVmMipsX100()
	local scratchMem = Memory.new(8192)
	local scratchCpu = CPU.new(scratchMem)
	scratchCpu.mode = CPU.MODE_USER
	scratchCpu.running = true
	scratchCpu.pc = 0

	local loopNops = 1023
	for i = 0, loopNops - 1 do
		buffer.writeu32(scratchMem.buf, i * 4, 0x00000000)
	end
	buffer.writeu32(scratchMem.buf, loopNops * 4, 0x06000000)
	buffer.writeu32(scratchMem.buf, loopNops * 4 + 4, 0)

	scratchCpu:runSlice(100000)
	scratchCpu.pc = 0
	scratchCpu.running = true
	scratchCpu.trap = nil

	local sampleInstructions = 1000000
	local started = os.clock()
	local executed = scratchCpu:runSlice(sampleInstructions)
	local elapsed = os.clock() - started
	if elapsed <= 0 or executed <= 0 then
		return 0
	end
	return math.floor((executed / elapsed) / 10000 + 0.5)
end

local syscallDispatcher = SyscallDispatcher.new({
	C = C,
	CPU = CPU,
	Process = Process,
	PageTable = PageTable,
	FileHandle = FileHandle,
	Filesystem = Filesystem,
	Assembler = Assembler,
	CompileRequest = CompileRequest,
	DEFAULT_CPU_MODE = DEFAULT_CPU_MODE,
	VM_PAGE_SIZE = VM_PAGE_SIZE,
	PROCESS_STACK_PAGES = PROCESS_STACK_PAGES,
	WIDTH = WIDTH,
	HEIGHT = HEIGHT,
	TEXT_BASE = TEXT_BASE,
	IO_BASE = IO_BASE,
	CTRL_BASE = CTRL_BASE,
	GPU_BASE = GPU_BASE,
	getScheduler = function()
		return scheduler
	end,
	getCpu = function()
		return cpu
	end,
	getMem = function()
		return mem
	end,
	getFilesystem = function()
		return filesystem
	end,
	setFilesystem = function(fs)
		filesystem = fs
	end,
	getIoDev = function()
		return ioDev
	end,
	getMMU = function()
		return mmu
	end,
	getTTYDirty = function()
		return ttyDirty
	end,
	setTTYDirty = function(value)
		ttyDirty = value
	end,
	getVmInstructionCount = function()
		return vmInstructionCount
	end,
	getUserId = function()
		return player.UserId
	end,
	isPoweredOn = function()
		return poweredOn
	end,
	presentIfRequested = presentIfRequested,
	kread = kread,
	kwrite = kwrite,
	userReadWord = userReadWord,
	userWriteWord = userWriteWord,
	userReadByte = userReadByte,
	userWriteByte = userWriteByte,
	userReadString = userReadString,
	getProcessVirtualMemorySize = getProcessVirtualMemorySize,
	getProcessStackBase = getProcessStackBase,
	ensureProcessRangeMapped = ensureProcessRangeMapped,
	loadProgramFromFile = loadProgramFromFile,
	copyBufferIntoProcess = copyBufferIntoProcess,
	applyBinaryPermissions = applyBinaryPermissions,
	installCpuImageLayout = installCpuImageLayout,
	cloneDecodeSegments = cloneDecodeSegments,
	serializeBinary = serializeBinary,
	saveFilesystemToServer = saveFilesystemToServer,
	ensureDefaultBloxOSFiles = ensureDefaultBloxOSFiles,
	flushTTY = flushTTY,
	clearSharedInput = clearSharedInput,
	requestFramebufferFlush = requestFramebufferFlush,
	toSigned32 = toSigned32,
	computeVmMipsX100 = computeVmMipsX100,
})

handleSyscall = function(trapInfo)
	return syscallDispatcher:handleSyscall(trapInfo)
end




--power and cpu thread plumbing starts here
local shutdownVM
local bootVM
local startCpuThread
local restartUserProcess
local cpuThreadOps = {}

function cpuThreadOps.selectCurrentProcessForCycle(myToken)
	--reap zombies first so waits resolve before the next slice
	scheduler:cleanupZombies()

	--either keep current proc or rotate to the next ready one
	if scheduler:shouldSwitch() then
		local scheduledProc = scheduler:getCurrentProcess()
		if scheduledProc then
			scheduledProc:saveState()
			scheduledProc.state = Process.STATE_READY
		end

		if not scheduler:scheduleNext() then
			if scheduler:getProcessCount() == 0 then
				task.defer(function()
					if poweredOn and myToken == runToken then
						restartUserProcess("no_processes")
					end
				end)
				return nil, "return"
			end

			task.wait(0.1)
			return nil, "continue"
		end

		--yield once per slice
		task.wait()
	end

	local currentProc = scheduler:getCurrentProcess()
	if not currentProc then
		task.wait(0.01)
		return nil, "continue"
	end

	return currentProc, nil
end

function cpuThreadOps.prepareCurrentProcessExecution(currentProc, currentCpu)
	--dead process? sweep it now
	if not currentProc:isAlive() or not currentCpu.running then
		currentProc:terminate(currentProc.exitCode or 1)
		currentProc:cleanup()
		scheduler:removeProcess(currentProc.pid)
		return false
	end

	--flip the mmu to this proc before any user memory touch
	if mmu and currentProc.pageTable then
		mmu:setPageTable(currentProc.pageTable)
		if mmu.currentPageTable and mmu.currentPageTable.pid ~= currentProc.pid then
			warn(("[kernel] MMU page table mismatch! Expected PID %d, got %d"):format(
				currentProc.pid, mmu.currentPageTable.pid))
		end
	end

	--guests always run in user mode
	if currentCpu.mode ~= CPU.MODE_USER then
		warn(("[kernel] Process %d was in %s mode, forcing to user mode"):format(
			currentProc.pid, currentCpu.mode))
		currentCpu.mode = CPU.MODE_USER
	end

	mem:setMode(currentCpu.mode)
	return true
end

function cpuThreadOps.updateCurrentProcessViewport(currentProc, currentCpu)
	--windowed apps remap gpu coords and steal drag/close clicks here
	if currentProc.appWindow then
		local aw = currentProc.appWindow
		if mem and ioDev and ioDev.State then
			local st = ioDev.State
			local mx, my = st.mouseX or 0, st.mouseY or 0
			local btn = st.mouseBtns or 0
			local seq = st.clickSeq or 0
			local lastSeq = currentProc._appWindowLastClickSeq or 0

			if btn == 0 then
				currentProc._appWindowDragging = false
			elseif currentProc._appWindowDragging then
				local lx = currentProc._appWindowLastMouseX or mx
				local ly = currentProc._appWindowLastMouseY or my
				local dx, dy = mx - lx, my - ly
				aw.winX = math.floor(aw.winX + dx)
				aw.winY = math.floor(aw.winY + dy)
				aw.winX = math.max(0, math.min(WIDTH - aw.winW, aw.winX))
				aw.winY = math.max(0, math.min(HEIGHT - aw.winH, aw.winY))
				aw.contentX = aw.winX + C["APP_BORDER_W"]
				aw.contentY = aw.winY + C["APP_TITLE_BAR_H"] + C["APP_BORDER_W"]
				aw.closeX1 = aw.winX + aw.winW - C["APP_BORDER_W"] - C["APP_CLOSE_SIZE"]
				aw.closeY1 = aw.winY + C["APP_BORDER_W"]
				aw.closeX2 = aw.winX + aw.winW - C["APP_BORDER_W"] - 1
				aw.closeY2 = aw.winY + C["APP_TITLE_BAR_H"] - C["APP_BORDER_W"] - 1
				currentProc._appWindowLastMouseX = mx
				currentProc._appWindowLastMouseY = my
			elseif seq ~= lastSeq and st.clickBtn ~= 0 then
				currentProc._appWindowLastClickSeq = seq
				local cx, cy = st.clickX or 0, st.clickY or 0
				if cx >= aw.closeX1 and cx <= aw.closeX2 and cy >= aw.closeY1 and cy <= aw.closeY2 then
					clearSharedInput()
					currentProc:terminate(0)
					currentCpu.trap = { kind = "halt", msg = "app window close", pc = currentCpu.pc }
					currentCpu.running = false
					scheduler:removeProcess(currentProc.pid)
					kwrite(TEXT_BASE + 9, 1)
					return true
				end

				local titleLeft = aw.winX + C["APP_BORDER_W"]
				local titleRight = aw.closeX1 - 1
				local titleTop = aw.winY + C["APP_BORDER_W"]
				local titleBottom = aw.winY + C["APP_TITLE_BAR_H"] - C["APP_BORDER_W"] - 1
				if cx >= titleLeft and cx <= titleRight and cy >= titleTop and cy <= titleBottom then
					currentProc._appWindowDragging = true
					currentProc._appWindowLastMouseX = cx
					currentProc._appWindowLastMouseY = cy
				end
			end
		end
		kwrite(GPU_BASE + 4, aw.contentX)
		kwrite(GPU_BASE + 8, aw.contentY)
		kwrite(GPU_BASE + 20, aw.contentW)
		kwrite(GPU_BASE + 24, aw.contentH)
	else
		--fullscreen proc just gets the whole viewport back
		kwrite(GPU_BASE + 4, 0)
		kwrite(GPU_BASE + 8, 0)
		kwrite(GPU_BASE + 20, WIDTH)
		kwrite(GPU_BASE + 24, HEIGHT)
	end

	return false
end

function cpuThreadOps.runCurrentProcessBatch(currentProc, currentCpu)
	--guard bad pcs early. bogus returns love landing past vm memory.
	if currentCpu.pc >= getProcessVirtualMemorySize(currentProc) then
		currentCpu.trap = {
			kind = "fault",
			type = "page_fault",
			msg = ("fetch from unmapped address 0x%X (bad return/jump?)"):format(currentCpu.pc),
			addr = currentCpu.pc,
			pc = currentCpu.pc,
			access = "execute",
			reason = "page_not_mapped",
			virtualPage = math.floor(currentCpu.pc / 4096),
		}
	end
	if currentCpu.trap then
		return
	end

	local BATCH_SIZE = 200000
	local sliceLeft = scheduler.timeSlice - scheduler.currentSlice
	local executeLimit = (sliceLeft < BATCH_SIZE) and sliceLeft or BATCH_SIZE

	if executeLimit > 0 then
		local stepsExecuted = 0
		local execStart = os.clock()
		stepsExecuted = currentCpu:runSlice(executeLimit)
		local execElapsed = os.clock() - execStart

		currentProc.cpuTime += stepsExecuted
		scheduler:consumeSlice(stepsExecuted)
		vmInstructionCount += stepsExecuted
		if execElapsed > 0 and stepsExecuted > 0 then
			vmExecutionTime += execElapsed
			--only recalculate MIPS periodically to reduce overhead
			if vmInstructionCount % 2000000 < stepsExecuted then
				vmMipsX100 = math.floor((vmInstructionCount / vmExecutionTime) / 10000 + 0.5)
			end
		end
	end
end

function cpuThreadOps.handleCurrentProcessSyscall(currentCpu)
	if not currentCpu.trap or currentCpu.trap.kind ~= "syscall" then
		return
	end

	local trapInfo = currentCpu.trap
	currentCpu.trap = nil

	local prevMode = currentCpu.mode
	currentCpu.mode = CPU.MODE_KERNEL
	mem:setMode(CPU.MODE_KERNEL)

	if mmu then
		mmu:setKernelMode(true)
	end

	handleSyscall(trapInfo)
	for i = 1, #currentCpu.reg do
		currentCpu.reg[i] = bit32.band(currentCpu.reg[i] or 0, 0xFFFFFFFF)
	end

	currentCpu.mode = (prevMode == CPU.MODE_KERNEL or prevMode == "kernel") and CPU.MODE_KERNEL or CPU.MODE_USER
	mem:setMode(currentCpu.mode)

	if mmu then
		mmu:setKernelMode(currentCpu.mode == CPU.MODE_KERNEL)
	end
end

function cpuThreadOps.handleCurrentProcessTrap(currentProc, currentCpu)
	if not currentCpu.trap then
		return nil
	end

	if currentCpu.trap.kind == "yield" then
		currentCpu.trap = nil
		if currentProc.state == Process.STATE_RUNNING then
			currentProc.state = Process.STATE_READY
		end
		scheduler.currentSlice = scheduler.timeSlice
		task.wait()
		return "continue"
	end

	if currentCpu.trap.kind == "fault" then
		local faultInfo = currentCpu.trap.type or "unknown_fault"
		local faultMsg = currentCpu.trap.msg or ("fault @ pc %d"):format(currentCpu.trap.pc or 0)
		local debugInfo = {}

		if currentCpu.trap.pc ~= nil then
			table.insert(debugInfo, ("pc=0x%X"):format(currentCpu.trap.pc))
		end
		if currentCpu.trap.addr then
			table.insert(debugInfo, ("addr=0x%X"):format(currentCpu.trap.addr))
		end
		if currentCpu.trap.virtualPage then
			table.insert(debugInfo, ("vpage=%d"):format(currentCpu.trap.virtualPage))
		end
		if currentCpu.trap.reason then
			table.insert(debugInfo, ("reason=%s"):format(currentCpu.trap.reason))
		end
		if currentCpu.trap.access then
			table.insert(debugInfo, ("access=%s"):format(currentCpu.trap.access))
		end

		local debugStr = ""
		if #debugInfo > 0 then
			debugStr = " (" .. table.concat(debugInfo, ", ") .. ")"
		end
		local imageSuffix = ""
		if currentProc.imagePath and currentProc.imagePath ~= "" then
			imageSuffix = " [" .. currentProc.imagePath .. "]"
		end

		print(("[kernel] process %d terminated: %s - %s%s"):format(
			currentProc.pid, faultInfo, faultMsg, debugStr) .. imageSuffix)
		kernelPrintScreen(("[kernel] process %d terminated: %s%s"):format(
			currentProc.pid, faultInfo, debugStr) .. imageSuffix)

		if currentProc.pageTable then
			local mappedPages = currentProc.pageTable:getAllMappedPages()
			print(("[kernel] process %d had %d mapped pages"):format(currentProc.pid, #mappedPages))
		end

		currentProc:terminate(1)
		clearSharedInput()
		currentProc:cleanup()
		scheduler:removeProcess(currentProc.pid)
		return "continue"
	end

	if currentCpu.trap.kind == "halt" then
		currentProc:terminate(0)
		clearSharedInput()
		currentProc:cleanup()
		scheduler:removeProcess(currentProc.pid)
		return "continue"
	end

	if currentCpu.trap.kind == "panic" then
		warn("[KERNEL PANIC]", currentCpu.trap.msg, "pc=", currentCpu.trap.pc)
		kernelPrintScreen("[KERNEL PANIC] " .. tostring(currentCpu.trap.msg))
		kernelPrintScreen("System halted. Power cycle to reboot.")
		return "return"
	end

	return nil
end

function cpuThreadOps.runCpuThreadLoop(myToken)
	local totalCycles = 0

	while poweredOn and (myToken == runToken) do
		local currentProc, cycleAction = cpuThreadOps.selectCurrentProcessForCycle(myToken)
		if cycleAction == "return" then
			return
		end
		if cycleAction == "continue" then
			continue
		end

		local currentCpu = currentProc.cpu
		if not cpuThreadOps.prepareCurrentProcessExecution(currentProc, currentCpu) then
			continue
		end
		if cpuThreadOps.updateCurrentProcessViewport(currentProc, currentCpu) then
			continue
		end
		cpuThreadOps.runCurrentProcessBatch(currentProc, currentCpu)
		cpuThreadOps.handleCurrentProcessSyscall(currentCpu)

		if ttyDirty then
			flushTTY()
		end

		presentIfRequested()

		local trapAction = cpuThreadOps.handleCurrentProcessTrap(currentProc, currentCpu)
		if trapAction == "return" then
			return
		end
		if trapAction == "continue" then
			continue
		end

		--real hardwareish reboot latch
		--leave alone pls
		if fbCtrl and fbCtrl.consumeReboot and fbCtrl.consumeReboot() then
			task.defer(function()
				shutdownVM()
				task.wait()
				if poweredOn then
					bootVM() --real cold boot on reboot latch
				end
			end)
			return
		end

		totalCycles += 1
	end

	--cancelled or powered off means bail without a dramatic exit
	if not poweredOn or (myToken ~= runToken) then
		return
	end

	--one last present so the final frame is not stale
	fb.flushRequested = true
	presentIfRequested()
end


startCpuThread = function()
	--new token nukes any older cpu loop
	runToken += 1
	local myToken = runToken

	task.spawn(cpuThreadOps.runCpuThreadLoop, myToken)
end



--pid 1 boot image setup
local function createInitProcess()
	if not mem or not scheduler or not physicalAllocator or not mmu then
		return nil
	end

	--fresh page table for init
	local pid = scheduler:allocatePid()
	local pageTable = PageTable.new(pid, physicalAllocator)

	--guest ram is page mapped. 4*1024=4096 bytes each page.
	local PAGE_SIZE = VM_PAGE_SIZE
	local VIRTUAL_MEMORY_SIZE = PROCESS_VIRTUAL_MEMORY_SIZE
	local numPages = math.ceil(VIRTUAL_MEMORY_SIZE / PAGE_SIZE)

	--start rw everywhere, then clamp text pages after load
	local allocatedPages = {}  --track mapped vpages so cleanup is not guesswork
	for i = 0, numPages - 1 do
		local virtualPage = i
		local perms = PageTable.PERM_READ + PageTable.PERM_WRITE

		--nil physicalPage means allocator gives us a fresh page with refcount 1
		local ok, err2 = pageTable:mapPage(virtualPage, nil, perms)
		if not ok then
			warn("[kernel] Failed to map page for init process: ", err2, " (allocated ", i, " of ", numPages, " pages)")
			--unwind anything we already mapped before returning sad
			for j = 0, i - 1 do
				local vp = allocatedPages[j]
				if vp then
					pageTable:unmapPage(vp)
				end
			end
			return nil
		end

		allocatedPages[i] = virtualPage
	end

	--brand new cpu for init
	local initCpu = CPU.new(mem)
	initCpu.pc = 0 --boot image entry rewrites this a few lines down
	initCpu.running = true
	initCpu.trap = nil
	for i = 1, #initCpu.reg do
		initCpu.reg[i] = 0
	end
	initCpu.mode = DEFAULT_CPU_MODE
	initCpu.reg[15 + 1] = VIRTUAL_MEMORY_SIZE  --stack top, grows down from the end of vm space

	--boot path defaults to /bin/sh.rov unless bios says otherwise
	local bootPath = getEffectiveBootPath(activeBiosConfig) or "/bin/sh.rov"
	local codeBuf, loadErr, entryPoint, imageInfo = loadProgramFromFile(bootPath)
	if not codeBuf then
		warn("[kernel] Failed to load boot program: ", bootPath, " â€” ", loadErr)
		--same cleanup dance as above because partial boots are bad
		for j = 0, numPages - 1 do
			local vp = allocatedPages[j]
			if vp then
				pageTable:unmapPage(vp)
			end
		end
		return nil
	end
	local codeLen = buffer.len(codeBuf)

	if entryPoint >= codeLen or entryPoint >= VIRTUAL_MEMORY_SIZE then
		warn("[kernel] Invalid boot program entry point: 0x", string.format("%X", entryPoint), " (code size ", codeLen, ", max ", VIRTUAL_MEMORY_SIZE, ")")
		--same story here. bad entry means tear it all back down.
		for j = 0, numPages - 1 do
			local vp = allocatedPages[j]
			if vp then
				pageTable:unmapPage(vp)
			end
		end
		return nil
	end

	initCpu.pc = entryPoint

	--copy through page translation so we prove the mappings actually work
	mem:setMode(CPU.MODE_KERNEL)
	mmu:setPageTable(pageTable)
	local codeLen = buffer.len(codeBuf)
	local copyOk, copyErr = copyBufferIntoProcess(pageTable, 0, codeBuf)
	if not copyOk then
		warn("[kernel] Failed to copy boot program image: ", copyErr)
		for j = 0, numPages - 1 do
			local vp = allocatedPages[j]
			if vp then
				pageTable:unmapPage(vp)
			end
		end
		return nil
	end
	applyBinaryPermissions(pageTable, 0, codeLen, imageInfo)
	installCpuImageLayout(initCpu, codeBuf, imageInfo, 0, true)
	mem:setMode(DEFAULT_CPU_MODE)

	--wrap it as a process and hand it to the scheduler
	local initProc = Process.new(pid, initCpu, {base = 0, size = VIRTUAL_MEMORY_SIZE}, pageTable)
	initProc.imagePath = bootPath
	initProc.state = Process.STATE_READY
	initProc._heapMinBreak = math.floor((codeLen + (VM_PAGE_SIZE - 1)) / VM_PAGE_SIZE) * VM_PAGE_SIZE
	initProc._heapBreak = initProc._heapMinBreak

	--leave the mmu pointed at pid 1 so first run starts clean
	mmu:setPageTable(pageTable)

	--queue it up
	scheduler:addProcess(initProc)

	return initProc
end

--panic path writes straight to the tty tiles in red
kernelPrintScreen = function(msg)
	if not fb or not fb.blitChar then return end
	local KCOLS = math.floor(WIDTH / 10)
	local KROWS = math.floor(HEIGHT / 10)
	local red = Color3.fromRGB(255, 60, 60)
	local black = Color3.fromRGB(0, 0, 0)

	--scroll first so the newest panic lands at the bottom
	fb:scrollUp(10)
	local row = KROWS - 1

	--draw char by char because the tty already thinks in cells
	for i = 1, math.min(#msg, KCOLS) do
		local ch = string.byte(msg, i)
		fb:blitChar(i - 1, row, ch, red, black)
	end
	--mark tiles dirty and shove it out now
	for _, tile in ipairs(editableImages) do
		tile.dirty = true
	end
	flushPixelBuffer()
end

restartUserProcess = function(reason)
	--only queue one respawn at a time or crash storms get stupid
	if respawnQueued then
		return
	end
	respawnQueued = true

	--crash loop guard. same idea as getty/systemd but way smaller.
	local now = os.clock()
	if (now - crashWindowStart) > CRASH_WINDOW then
		crashWindowStart = now
		crashCount = 0
	end
	crashCount += 1

	if crashCount > CRASH_MAX then
		respawnQueued = false
		warn(("[kernel] crash loop detected (reason=%s). Not respawning until manual reboot/power cycle."):format(tostring(reason)))
		kernelPrintScreen("[kernel] crash loop detected - not respawning")
		kernelPrintScreen("Power cycle to reboot.")
		--leave power on but stop auto-respawning
		return
	end

	--tiny backoff
	task.delay(respawnDelay, function()
		respawnQueued = false

		if not poweredOn or not mem or not scheduler then
			return
		end

		--kill any old cpu loop first
		runToken += 1

		--sweep leftover procs and pages
		for pid in pairs(scheduler.processes) do
			local proc = scheduler:getProcess(pid)
			if proc then
				proc:cleanup()  --free pages before removeProcess drops refs
			end
			scheduler:removeProcess(pid)
		end

		--spawn pid 1 again
		createInitProcess()

		--and restart execution
		startCpuThread()
	end)
end


bootVM = function()
	_G.ROVM_CRASH_EFFECT = false
	vmInstructionCount = 0
	vmMipsX100 = 0
	vmExecutionTime = 0

	--wipe visuals before rebuild
	clearAllDrawFrames()
	resetFramebufferTables()
	container.BackgroundColor3 = fb.clearColor

	--old io listeners survive reboots unless i kill them here
	if ioDev and ioDev.Destroy then
		ioDev:Destroy()
	end
	ioDev = nil

	--clear tiles before the power on expand or stale frames flash
	--4 bytes per pixel means alpha sits at every +3 byte
	for _, tile in ipairs(editableImages) do
		buffer.fill(tile.buffer, 0, 0)
		for px = 0, tile.w * tile.h - 1 do
			buffer.writeu8(tile.buffer, px * 4 + 3, 255)
		end
		tile.dirty = true
	end
	flushPixelBuffer()

	--play the crt open after the buffers are actually black
	local tok = nextAnimToken()
	playPowerOnAnim(tok)
	if not poweredOn then return end

	local biosConfig = cloneBiosConfig()
	local biosConfigStatus = "defaults"
	local storageLoadSuccess = false
	local storageLoadErr = nil
	local biosSetupRequested = false

	local prebootInputConn = UIS.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Delete then
			biosSetupRequested = true
		end
	end)

	filesystem = Filesystem.new()
	storageLoadSuccess, storageLoadErr = loadFilesystemFromServer()

	local rootInode = filesystem:resolvePath("/")
	if rootInode then
		local root = filesystem.inodes[rootInode]
		if root then
			if not root.children["bin"] then
				filesystem:createDirectory("/bin")
			end
			if not root.children["boot"] then
				filesystem:createDirectory("/boot")
			end
			if not root.children["tmp"] then
				filesystem:createDirectory("/tmp")
			end
			if not root.children["home"] then
				filesystem:createDirectory("/home")
			end
		end
	end

	local biosLoadErr
	biosConfig, biosLoadErr = loadBiosConfig()
	if biosLoadErr then
		local savedDefaults = saveBiosConfig(biosConfig)
		biosConfigStatus = savedDefaults and "defaults-created" or "defaults"
	else
		biosConfigStatus = "loaded"
	end
	activeBiosConfig = normalizeBiosConfig(biosConfig)

	--boot log renderer
	local bootRow = 0
	local BOOT_FG = Color3.fromRGB(50, 255, 50)      --bright green for ok paths
	local BOOT_DIM = Color3.fromRGB(30, 160, 30)      --dimmer green for branding
	local BOOT_BG = Color3.fromRGB(0, 0, 0)
	local BOOT_WHITE = Color3.fromRGB(200, 200, 210)   --main text
	local BOOT_CYAN = Color3.fromRGB(80, 200, 220)     --[boot] tags
	local BOOT_TAG_DIM = Color3.fromRGB(90, 90, 100)   --timestamps
	local BOOT_RED = Color3.fromRGB(255, 80, 80)       --errors
	local BOOT_YELLOW = Color3.fromRGB(220, 200, 60)   --warnings
	local COLS = math.floor(WIDTH / 10) --10 px per cell, so width/10 = text cols
	local ROWS = math.floor(HEIGHT / 10) --same deal for rows
	local bootStartTime = os.clock()

	--draw one colored chunk starting at startCol
	local function blitSegment(text, startCol, row, color)
		for i = 1, #text do
			local col = startCol + i - 1
			if col >= COLS then break end
			fb:blitChar(col, row, string.byte(text, i), color, BOOT_BG)
		end
		return startCol + #text
	end

	--force every tile dirty then push it out
	local function bootFlush()
		for _, tile in ipairs(editableImages) do
			tile.dirty = true
		end
		flushPixelBuffer()
		task.wait()
	end

	local function ensureBootRowsAvailable(lineCount)
		lineCount = math.max(1, math.floor(lineCount or 1))
		while bootRow + lineCount > ROWS do
			fb:scrollUp(10)
			bootRow -= 1
			if bootRow < 0 then
				bootRow = 0
			end
		end
	end

	--normal boot line: [0.01s] [boot] text
	local function bootLog(msg)
		if not poweredOn then return end
		ensureBootRowsAvailable(1)

		local col = 0
		--timestamp first so every line lines up
		local elapsed = os.clock() - bootStartTime
		local timestamp = string.format("[%05.2fs] ", elapsed)
		col = blitSegment(timestamp, col, bootRow, BOOT_TAG_DIM)

		--split [boot] from the message body so the colors stay readable
		local tag, rest = msg:match("^(%[%w+%])%s*(.*)")
		if tag then
			col = blitSegment(tag, col, bootRow, BOOT_CYAN)
			col = blitSegment(" ", col, bootRow, BOOT_BG)
			blitSegment(rest, col, bootRow, BOOT_WHITE)
		else
			--no tag, just print the whole thing
			blitSegment(msg, col, bootRow, BOOT_WHITE)
		end

		bootRow += 1
		bootFlush()
	end

	--status line variant with a right-aligned badge
	--status is "ok" "fail" or "warn"
	local function bootLogStatus(description, status)
		if not poweredOn then return end
		ensureBootRowsAvailable(1)

		local col = 0
		--same timestamp width every time
		local elapsed = os.clock() - bootStartTime
		local timestamp = string.format("[%05.2fs] ", elapsed)
		col = blitSegment(timestamp, col, bootRow, BOOT_TAG_DIM)

		--hardcoded [boot] tag color lives here
		col = blitSegment("[boot]", col, bootRow, BOOT_CYAN)
		col = blitSegment(" ", col, bootRow, BOOT_BG)

		--main description body
		col = blitSegment(description, col, bootRow, BOOT_WHITE)

		--badge on the right
		local badge, badgeColor
		if status == "ok" then
			badge = "[ OK ]"
			badgeColor = BOOT_FG
		elseif status == "fail" then
			badge = "[FAIL]"
			badgeColor = BOOT_RED
		elseif status == "warn" then
			badge = "[WARN]"
			badgeColor = BOOT_YELLOW
		else
			badge = "[    ]"
			badgeColor = BOOT_TAG_DIM
		end

		local badgeCol = COLS - #badge - 1
		--dotfill the gap
		if col < badgeCol - 1 then
			col = blitSegment(" ", col, bootRow, BOOT_BG)
			for dc = col, badgeCol - 1 do
				blitSegment(".", dc, bootRow, BOOT_TAG_DIM)
			end
		end
		blitSegment(badge, badgeCol, bootRow, badgeColor)

		bootRow += 1
		bootFlush()
	end

	--indented subline for file paths and extra boot noise
	local function bootLogSub(msg)
		if not poweredOn then return end
		ensureBootRowsAvailable(1)

		local col = 0
		--blank timestamp column so it still aligns
		col = blitSegment("          ", col, bootRow, BOOT_BG) --10 chars matches timestamp width
		--four spaces then the sub message
		col = blitSegment("    ", col, bootRow, BOOT_BG)
		blitSegment(msg, col, bootRow, BOOT_TAG_DIM)

		bootRow += 1
		bootFlush()
	end

	--same shape as sublines but red because something exploded
	local function bootLogError(msg)
		if not poweredOn then return end
		ensureBootRowsAvailable(1)

		local col = 0
		col = blitSegment("          ", col, bootRow, BOOT_BG)
		col = blitSegment("    ", col, bootRow, BOOT_BG)
		blitSegment(msg, col, bootRow, BOOT_RED)

		bootRow += 1
		bootFlush()
	end

	--boot splash text helpers
	local blankLine = string.rep(" ", COLS)
	local separatorLine = string.rep("-", COLS)

	local function clearBootTextScreen()
		for row = 0, ROWS - 1 do
			blitSegment(blankLine, 0, row, BOOT_BG)
		end
	end

	local function getBootModeLabel(config)
		local cfg = normalizeBiosConfig(config)
		if cfg.boot_mode == "recovery" then
			return "Recovery Shell"
		end
		return "Normal"
	end

	local function boolLabel(value)
		return value and "Enabled" or "Disabled"
	end

	local function renderFirmwareHeader(statusLine)
		local currentBootPath = getEffectiveBootPath(biosConfig) or "/bin/sh.rov"
		local cpuModeLabel = (DEFAULT_CPU_MODE == CPU.MODE_USER) and "user" or tostring(DEFAULT_CPU_MODE)
		local storageLabel = storageLoadSuccess and "DataStore loaded" or "Fresh filesystem"

		clearBootTextScreen()

		local banner = { --looks fucking sick
			"  ____  _            ____   _____ ",
			" |  _ \\| |          / __ \\ / ____|",
			" | |_) | | _____  _| |  | | (___  ",
			" |  _ <| |/ _ \\ \\/ / |  | |\\___ \\ ",
			" | |_) | | (_) >  <| |__| |____) |",
			" |____/|_|\\___/_/\\_\\\\____/|_____/ ",
		}

		local row = 1
		for _, line in ipairs(banner) do
			ensureBootRowsAvailable(1)
			blitSegment(line, 2, row, BOOT_DIM)
			row += 1
		end
		row += 1

		ensureBootRowsAvailable(10)
		blitSegment("Firmware : RoVM BIOS / BloxOS 2026", 2, row, BOOT_WHITE)
		row += 1
		blitSegment(("CPU      : RoVM VM CPU  | default mode=%s"):format(cpuModeLabel), 2, row, BOOT_WHITE)
		row += 1
		blitSegment(("Memory   : %d KB RAM  | page size=%d B"):format(math.floor(PHYSICAL_MEMORY_SIZE / 1024), VM_PAGE_SIZE), 2, row, BOOT_WHITE)
		row += 1
		blitSegment(("Display  : %dx%d framebuffer"):format(WIDTH, HEIGHT), 2, row, BOOT_WHITE)
		row += 1
		blitSegment(("Boot Mode: %s"):format(getBootModeLabel(biosConfig)), 2, row, BOOT_CYAN)
		row += 1
		blitSegment(("Flags    : %s"):format(getBiosBootFlags(biosConfig)), 2, row, BOOT_WHITE)
		row += 1
		blitSegment(("Target   : %s"):format(currentBootPath), 2, row, BOOT_WHITE)
		row += 1
		blitSegment(("Profile  : %s  |  Storage: %s"):format(biosConfigStatus, storageLabel), 2, row, BOOT_TAG_DIM)
		row += 2
		blitSegment(statusLine or "Press Del for Setup", 2, row, BOOT_YELLOW)
		row += 2
		blitSegment(separatorLine, 0, row, BOOT_TAG_DIM)
		row += 2

		bootRow = row
		bootFlush()
	end

	local function openBiosSetup()
		local working = normalizeBiosConfig(biosConfig)
		local selected = 1
		local pendingKey = nil
		local saved = false
		local footer = "Arrow keys navigate | Left/Right/Enter change | S save | Q cancel"
		local menuItems = {
			{
				label = "Boot Mode",
				key = "boot_mode",
				values = { "normal", "recovery" },
				format = function(value)
					return (value == "recovery") and "Recovery Shell" or "Normal"
				end,
			},
			{
				label = "Verbose Boot",
				key = "verbose_boot",
				values = { false, true },
				format = boolLabel,
			},
			{
				label = "Wait For Key",
				key = "wait_for_key",
				values = { false, true },
				format = boolLabel,
			},
			{
				label = "Auto Save",
				key = "auto_save",
				values = { false, true },
				format = boolLabel,
			},
			{
				label = "Auto Save Interval",
				key = "auto_save_interval",
				values = { 15, 30, 60, 120 },
				format = function(value)
					return tostring(value) .. " sec"
				end,
			},
		}

		local function cycleItem(item, direction)
			local current = working[item.key]
			local currentIndex = 1
			for i = 1, #item.values do
				if item.values[i] == current then
					currentIndex = i
					break
				end
			end
			currentIndex += direction
			if currentIndex < 1 then
				currentIndex = #item.values
			elseif currentIndex > #item.values then
				currentIndex = 1
			end
			working[item.key] = item.values[currentIndex]
		end

		local setupConn = UIS.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if input.UserInputType == Enum.UserInputType.Keyboard then
				pendingKey = input.KeyCode
			end
		end)

		while poweredOn do
			clearBootTextScreen()

			local row = 1
			ensureBootRowsAvailable(16)
			blitSegment("RoVM BIOS Setup Utility", 2, row, BOOT_CYAN)
			row += 1
			blitSegment("Persistent settings stored in /boot/bios.ini", 2, row, BOOT_TAG_DIM)
			row += 2

			for index, item in ipairs(menuItems) do
				local prefix = (index == selected) and ">" or " "
				local label = prefix .. " " .. item.label
				local value = item.format(working[item.key])
				blitSegment(label, 2, row, index == selected and BOOT_YELLOW or BOOT_WHITE)
				blitSegment(value, math.max(32, COLS - #value - 4), row, index == selected and BOOT_FG or BOOT_WHITE)
				row += 2
			end

			row += 1
			blitSegment(("Current flags : %s"):format(getBiosBootFlags(working)), 2, row, BOOT_TAG_DIM)
			row += 1
			blitSegment(("Boot target   : %s"):format(getEffectiveBootPath(working) or "/bin/sh.rov"), 2, row, BOOT_TAG_DIM)
			row += 2
			blitSegment(footer, 2, row, BOOT_YELLOW)
			bootFlush()

			local key = pendingKey
			pendingKey = nil
			if key == Enum.KeyCode.Up then
				selected -= 1
				if selected < 1 then
					selected = #menuItems
				end
			elseif key == Enum.KeyCode.Down then
				selected += 1
				if selected > #menuItems then
					selected = 1
				end
			elseif key == Enum.KeyCode.Left then
				cycleItem(menuItems[selected], -1)
			elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
				cycleItem(menuItems[selected], 1)
			elseif key == Enum.KeyCode.S then
				local saveOk, saveErr = saveBiosConfig(working)
				if saveOk then
					biosConfig = normalizeBiosConfig(working)
					activeBiosConfig = biosConfig
					local persistOk, persistErr = saveFilesystemToServer()
					saved = true
					footer = persistOk and "Settings saved. Continuing boot..." or ("Settings saved locally. DataStore save failed: " .. tostring(persistErr))
					bootFlush()
					task.wait(0.2)
					break
				else
					footer = "Save failed: " .. tostring(saveErr)
				end
			elseif key == Enum.KeyCode.Q then
				footer = "Setup cancelled. Continuing boot..."
				task.wait(0.1)
				break
			end

			task.wait(0.03)
		end

		setupConn:Disconnect()
		return saved, footer
	end

	renderFirmwareHeader("Press Del for BIOS Setup")
	local setupDeadline = os.clock() + 1.25
	while poweredOn and os.clock() < setupDeadline and not biosSetupRequested do
		task.wait(0.05)
	end
	if biosSetupRequested and poweredOn then
		local _, setupFooter = openBiosSetup()
		renderFirmwareHeader(setupFooter)
		task.wait(0.35)
	end
	prebootInputConn:Disconnect()
	bootStartTime = os.clock()

	--real boot sequence from here

	--1. memory
	bootLog(("[boot] Initializing memory... %d KB"):format(math.floor(PHYSICAL_MEMORY_SIZE / 1024)))
	mem = Memory.new(PHYSICAL_MEMORY_SIZE)
	cpu = CPU.new(mem)  --legacy reference, scheduler owns real process cpus now
	cpu.mode = DEFAULT_CPU_MODE
	mem:setMode("kernel") --kernel mode for device attach and boot work
	bootLogStatus(("Memory (%d KB)"):format(math.floor(PHYSICAL_MEMORY_SIZE / 1024)), "ok")
	if biosConfig.verbose_boot then
		bootLogSub(("page size=%d bytes, framebuffer=%dx%d"):format(VM_PAGE_SIZE, WIDTH, HEIGHT))
	end

	--2. allocator
	physicalAllocator = PhysicalMemoryAllocator.new(mem.size)
	bootLogStatus("Physical memory allocator", "ok")
	if biosConfig.verbose_boot then
		bootLogSub(("allocator tracks %d physical pages"):format(math.floor(mem.size / VM_PAGE_SIZE)))
	end

	--3. mmu
	mmu = MMU.new(physicalAllocator)
	mem:setMMU(mmu)
	bootLogStatus("MMU (Sv32 paging)", "ok")
	if biosConfig.verbose_boot then
		bootLogSub("kernel MMU attached to main memory bus")
	end

	--4. scheduler
	scheduler = Scheduler.new()
	bootLogStatus("Process scheduler", "ok")
	if biosConfig.verbose_boot then
		bootLogSub(("time slice=%d instructions"):format(scheduler.timeSlice))
	end

	--5. persistent storage
	if storageLoadSuccess then
		bootLogStatus("Persistent storage profile", "ok")
	else
		bootLogStatus("Persistent storage profile", "warn")
		bootLogError(tostring(storageLoadErr))
		warn("[kernel] Failed to load filesystem:", storageLoadErr)
	end
	bootLogSub(("filesystem inodes=%d"):format(countFilesystemInodes()))
	bootLogSub(("boot mode=%s, target=%s"):format(getBootModeLabel(biosConfig), getEffectiveBootPath(biosConfig) or "/bin/sh.rov"))
	bootLogSub(("flags=%s"):format(getBiosBootFlags(biosConfig)))

	--6. system files + compile pass
	bootLog("[boot] Injecting system files...")
	if not poweredOn then return end
	local bootCallbacks = {
		log = bootLog,
		status = bootLogStatus,
		sub = bootLogSub,
		error = bootLogError,
	}
	ensureDefaultBloxOSFiles(bootCallbacks)

	--7. devices
	if not poweredOn then return end
	fbCtrl = FramebufferDevice.attach(mem, fb, PIX_BASE, CTRL_BASE)
	assert(fbCtrl and fbCtrl.consumeReboot, "FramebufferDevice.attach did not return reboot handle")
	bootLogStatus("Framebuffer device", "ok")
	textDev = TextDevice.attach(mem, fb, TEXT_BASE)
	bootLogStatus("Text device (TTY)", "ok")
	local gpuDev = GPUDevice.attach(mem, fb, GPU_BASE, function() return editableImages end, WIDTH, HEIGHT)
	bootLogStatus("GPU device", "ok")
	if biosConfig.verbose_boot then
		bootLogSub(("display=%dx%d, tiles=%d"):format(WIDTH, HEIGHT, #editableImages))
	end

	--8. init process
	if not poweredOn then return end
	activeBiosConfig = normalizeBiosConfig(biosConfig)
	local bootPath = getEffectiveBootPath(activeBiosConfig) or "/bin/sh.rov"
	bootLog("[boot] Loading init process from " .. bootPath)
	createInitProcess()
	bootLogStatus("Init process (PID 1)", "ok")
	if biosConfig.verbose_boot then
		bootLogSub("boot profile applied to PID 1")
	end

	--9. input
	ioDev = InputDevice.attach(mem, fb, container, IO_BASE)
	bootLogStatus("Input device", "ok")

	--10. done
	bootLog("")
	bootLog("[boot] Boot complete.")
	bootLog(("[boot] Total boot time: %.2fs"):format(os.clock() - bootStartTime))
	bootLog("")

	--separator then optional wait-for-key prompt
	ensureBootRowsAvailable(2)
	blitSegment(separatorLine, 0, bootRow, BOOT_TAG_DIM)
	bootRow += 1
	if biosConfig.wait_for_key then
		blitSegment("System ready. Press any key to continue...", 0, bootRow, BOOT_WHITE)
		bootFlush()

		local keyConn
		local keyPressed = false
		keyConn = UIS.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then return end
			if input.UserInputType == Enum.UserInputType.Keyboard then
				keyPressed = true
			end
		end)
		while not keyPressed and poweredOn do
			task.wait()
		end
		if keyConn then keyConn:Disconnect() end
		if not poweredOn then return end
		if ioDev and ioDev.ClearInput then
			ioDev:ClearInput()
		end
	else
		blitSegment("System ready. Continuing automatically...", 0, bootRow, BOOT_WHITE)
		bootFlush()
		task.wait(0.35)
	end

	--kick the boot screen away and hand off to the shell
	clearPixelBuffer(Color3.fromRGB(0, 0, 0))
	flushPixelBuffer()

	--autosave loop. default interval is 30s unless bios says otherwise.
	if autoSaveTask then
		task.cancel(autoSaveTask)
	end
	autoSaveTask = nil
	if activeBiosConfig.auto_save then
		local interval = activeBiosConfig.auto_save_interval
		autoSaveTask = task.spawn(function()
			while poweredOn and filesystem do
				task.wait(interval)
				if poweredOn and filesystem then
					local saveSuccess, saveErr = saveFilesystemToServer()
					if not saveSuccess then
						warn("[kernel] Auto-save failed:", saveErr)
					end
				end
			end
		end)
	end

	startCpuThread()

end

shutdownVM = function()
	--invalidate any running cpu loop immediately
	runToken += 1

	--disconnect input first or reboot leaks listeners
	if ioDev and ioDev.Destroy then
		ioDev:Destroy()
	end
	ioDev = nil

	--kill procs and free pages before dropping refs
	if scheduler then
		for pid in pairs(scheduler.processes) do
			local proc = scheduler:getProcess(pid)
			if proc then
				proc:cleanup()  --free pages
			end
			scheduler:removeProcess(pid)
		end
	end

	--hard stop the legacy cpu handle too
	if cpu then
		cpu.running = false
	end

	--stop autosave worker
	if autoSaveTask then
		task.cancel(autoSaveTask)
		autoSaveTask = nil
	end

	--save async on shutdown. best effort, do not block the animation.
	if filesystem then
		task.spawn(function()
			local saveSuccess, saveErr = saveFilesystemToServer()
			if not saveSuccess then
				warn("[kernel] Failed to save filesystem:", saveErr)
			end
		end)
	end

	--run the poweroff squash while the last frame is still visible
	local tok = nextAnimToken()
	playPowerOffAnim(tok)

	--then drop draw state
	resetFramebufferTables()
	clearAllDrawFrames()

	--monitor-off look
	container.BackgroundColor3 = Color3.fromRGB(0,0,0)
	powerOverlay.BackgroundTransparency = 0
	container.Size = LINE_SIZE

	--drop vm refs so next boot is genuinely cold
	cpu = nil
	mem = nil
	textDev = nil
	scheduler = nil
	filesystem = nil
end

local function applyPowerUI()
	onBtn.BackgroundColor3  = poweredOn and Color3.fromRGB(35, 120, 70) or Color3.fromRGB(40,40,55)
	offBtn.BackgroundColor3 = (not poweredOn) and Color3.fromRGB(120, 45, 45) or Color3.fromRGB(40,40,55)
	pDot.BackgroundColor3 = poweredOn and Color3.fromRGB(35, 220, 120) or Color3.fromRGB(200, 80, 80)
end

UIS.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseWheel then
		return
	end
	if not poweredOn or not textDev or not textDev.scrollLines then
		return
	end
	if pastePanel.Visible or settingsPanel.Visible then
		return
	end

	local mousePos = UIS:GetMouseLocation()
	local framePos = screenFrame.AbsolutePosition
	local frameSize = screenFrame.AbsoluteSize
	if mousePos.X < framePos.X or mousePos.X > framePos.X + frameSize.X then
		return
	end
	if mousePos.Y < framePos.Y or mousePos.Y > framePos.Y + frameSize.Y then
		return
	end

	local wheelDelta = input.Position.Z
	if wheelDelta > 0 then
		textDev.scrollLines(3)
	elseif wheelDelta < 0 then
		textDev.scrollLines(-3)
	end
end)

onBtn.MouseButton1Click:Connect(function()
	if poweredOn then return end
	poweredOn = true
	applyPowerUI()
	bootVM()
end)

offBtn.MouseButton1Click:Connect(function()
	if not poweredOn then return end
	poweredOn = false
	applyPowerUI()
	shutdownVM()
end)

applyPowerUI()

--machine starts off until the button gets clicked
powerOverlay.BackgroundTransparency = 0
container.Size = LINE_SIZE

--tiny footer status
RunService.Heartbeat:Connect(function()
	if _G.ROVM_CRASH_EFFECT then
		flushPixelBuffer()
	end

	info.Text = string.format(
		"power: %s",
		poweredOn and "on" or "off"
	)
end)
