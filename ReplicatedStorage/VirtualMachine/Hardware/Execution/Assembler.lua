--!native
--all packing rules live here

local bit32 = bit32

local buffer_create = buffer.create
local buffer_writeu8 = buffer.writeu8
local buffer_writeu32 = buffer.writeu32

local band = bit32.band
local lshift = bit32.lshift

local Assembler = {}

local ROVM_MAGIC = 0x524F564D
local ROVD_MAGIC = 0x524F5644
local ROVM_HEADER_SIZE = 16
local ROVD_HEADER_SIZE = 32
local EXPORT_ENTRY_SIZE = 32

local REG_MAP = {
	sp = 15,
	fp = 14,
	bp = 14,
}

for i = 0, 15 do
	REG_MAP["r" .. i] = i
end

--builtins mirror the fake hardware map so handwritten asm does not turn into address hell
local BUILTIN_LABELS = {
	PIX_BASE = 0x100000,
	CTRL_BASE = 0x200000,
	IO_BASE = 0x300000,
	TEXT_BASE = 0x400000,
	GPU_BASE = 0x500000,

	SYS_TEXT_CX = 0x400000,
	SYS_TEXT_CY = 0x400001,
	SYS_TEXT_FG = 0x400002,
	SYS_TEXT_BG = 0x400003,
	SYS_TEXT_WRITE = 0x400004,
	SYS_TEXT_CLEAR = 0x400005,
	SYS_CTRL_FLUSH = 0x200001,
	SYS_CTRL_REBOOT = 0x200002,
	SYS_IO_AVAIL = 0x30000A,
	SYS_IO_READ = 0x30000B,

	SC_WRITE_CHAR = 0,
	SC_READ_CHAR = 1,
	SC_FLUSH = 2,
	SC_EXIT = 3,
	SC_REBOOT = 4,
	SC_TEXT_CLEAR = 5,
	SC_TEXT_SET_CX = 6,
	SC_TEXT_SET_CY = 7,
	SC_TEXT_SET_FG = 8,
	SC_TEXT_SET_BG = 9,

	SC_FORK = 16,
	SC_EXEC = 17,
	SC_WAIT = 18,
	SC_GETPID = 19,
	SC_KILL = 20,

	SC_OPEN = 32,
	SC_READ = 33,
	SC_WRITE = 34,
	SC_CLOSE = 35,
	SC_SEEK = 36,
	SC_UNLINK = 37,
	SC_MKDIR = 38,
	SC_RMDIR = 39,
	SC_LISTDIR = 40,
	SC_STAT = 41,
	SC_ASSEMBLE = 42,
	SC_COMPILE = 43,
	SC_EDIT = 44,
	SC_LOAD_ROVD = 50,
	SC_GET_EXPORT = 51,
	SC_GPU_SET_VIEW = 55,
	SC_GPU_SET_XY = 56,
	SC_GPU_SET_COLOR = 57,
	SC_GPU_DRAW_BUFFER = 58,
	SC_GPU_WAIT_FRAME = 59,
	SC_GPU_CLEAR_FRAME = 60,
	SC_GPU_DRAW_RLE = 61,
	SC_GPU_GET_REMAINING_LEN = 62,
	SC_GPU_GET_BUFFER_ADDR = 63,
	SC_MATH = 64,
	SC_SBRK = 65,
	SC_GPU_PLAY_CHUNK = 66,
	SC_APP_WINDOW = 67,
	SC_APP_SET_TITLE = 68,
	SC_FORMAT = 69,
	SC_MELTDOWN = 70,
	SC_PEEK_PHYS = 71,
	SC_POKE_PHYS = 72,
	SC_SYSINFO = 73,
	SC_GPU_DRAW_RECTS_BATCH = 74,
	SC_KEY_DOWN = 75,
	SC_KEY_PRESSED = 76,
	SC_READ_CHAR_NOWAIT = 77,

	KEY_ENTER = 13,
	KEY_UP = 17,
	KEY_DOWN = 18,
	KEY_LEFT = 19,
	KEY_RIGHT = 20,
	KEY_ESC = 27,
	KEY_SPACE = 32,
}

local OPCODES = {
	NOP = 0x00,
	HALT = 0x01,
	LOAD = 0x02,
	STORE = 0x03,
	ADD = 0x04,
	SUB = 0x05,
	JMP = 0x06,
	JZ = 0x07,
	LOADI = 0x08,
	MUL = 0x09,
	DIV = 0x0A,
	MOD = 0x0B,
	AND = 0x0C,
	OR = 0x0D,
	XOR = 0x0E,
	NOT = 0x0F,
	SHL = 0x10,
	SHR = 0x11,
	MOV = 0x12,
	CMPEQ = 0x13,
	CMPLT = 0x14,
	CMPGT = 0x15,
	ADDI = 0x16,
	SUBI = 0x17,
	MULI = 0x18,
	ANDI = 0x19,
	ORI = 0x1A,
	XORI = 0x1B,
	JNZ = 0x1C,
	SAR = 0x1D,
	ASHR = 0x1D,
	FLUSH = 0x20,
	SLEEP = 0x21,
	CALL = 0x22,
	RET = 0x23,
	PUSH = 0x24,
	POP = 0x25,
	CALLR = 0x26,
	LOADB = 0x27,
	STOREB = 0x28,
	LOADH = 0x29,
	STOREH = 0x2A,
	LOADBS = 0x2B,
	LOADHS = 0x2C,
	SYSCALL = 0x30,
	GETPC = 0x31,
	LOADI16 = 0x32,
	ADDI16 = 0x33,
	SUBI16 = 0x34,
	JMPREL16 = 0x35,
	JZREL16 = 0x36,
	JNZREL16 = 0x37,
	INC = 0x38,
	DEC = 0x39,
}

local WIDE_MNEMONIC = {
	JMP = true,
	JZ = true,
	LOADI = true,
	ADDI = true,
	SUBI = true,
	MULI = true,
	ANDI = true,
	ORI = true,
	XORI = true,
	JNZ = true,
	CALL = true,
}

--both .text and text show up in source, so this table ends that conversation early
local DIRECTIVE_ALIASES = {
	[".TEXT"] = "TEXT",
	[".DATA"] = "DATA",
	[".ROVM"] = "ROVM",
	[".ROVD"] = "ROVD",
	[".GLOBAL"] = "GLOBAL",
	[".GLOBL"] = "GLOBAL",
	[".EXPORT"] = "EXPORT",
	[".ENTRY"] = "ENTRY",
	[".SECTION"] = "SECTION",
	[".BYTE"] = "BYTE",
	[".WORD"] = "WORD",
	[".STRING"] = "STRING",
	[".ASCIIZ"] = "STRING",
	[".ALIGN"] = "ALIGN",
	[".INCLUDE"] = "INCLUDE",
}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function alignUp(value, alignment)
	if alignment <= 1 then
		return value
	end
	local remainder = value % alignment
	if remainder == 0 then
		return value
	end
	return value + (alignment - remainder)
end

local function normalizeSection(name)
	local lowered = trim(name):lower()
	if lowered == ".text" or lowered == "text" then
		return "text"
	end
	if lowered == ".data" or lowered == "data" then
		return "data"
	end
	error(("unknown section '%s'"):format(name))
end

local function parseRegister(token)
	local reg = REG_MAP[trim(token):lower()]
	if reg == nil then
		error(("invalid register '%s'"):format(token))
	end
	return reg
end

local function unescapeChar(ch)
	if ch == "n" then
		return 10
	elseif ch == "r" then
		return 13
	elseif ch == "t" then
		return 9
	elseif ch == "0" then
		return 0
	elseif ch == "\\" then
		return 92
	elseif ch == "'" then
		return 39
	elseif ch == "\"" then
		return 34
	end
	return string.byte(ch)
end

local function decodeStringLiteral(token)
	local text = trim(token)
	if #text < 2 or text:sub(1, 1) ~= "\"" or text:sub(-1) ~= "\"" then
		error(("expected string literal, got '%s'"):format(token))
	end
	local out = table.create(#text)
	local i = 2
	local stop = #text - 1
	while i <= stop do
		local ch = text:sub(i, i)
		if ch == "\\" then
			if i == stop then
				error(("bad escape in string literal '%s'"):format(token))
			end
			out[#out + 1] = string.char(unescapeChar(text:sub(i + 1, i + 1)))
			i += 2
		else
			out[#out + 1] = ch
			i += 1
		end
	end
	return table.concat(out)
end

--; starts a comment unless it is hiding inside quotes
--this used to get that wrong, which was a very long hour 0_0
local function stripComment(line)
	if not string.find(line, ";", 1, true) then
		return line
	end
	if not string.find(line, "\"", 1, true) and not string.find(line, "'", 1, true) then
		return line:match("^(.-);") or line
	end

	local quote = nil
	local escaped = false
	for i = 1, #line do
		local ch = line:sub(i, i)
		if escaped then
			escaped = false
		elseif ch == "\\" and quote ~= nil then
			escaped = true
		elseif quote ~= nil then
			if ch == quote then
				quote = nil
			end
		elseif ch == "\"" or ch == "'" then
			quote = ch
		elseif ch == ";" then
			return line:sub(1, i - 1)
		end
	end

	return line
end

local function splitOperands(text)
	local items = {}
	local current = {}
	local quote = nil
	local escaped = false
	for i = 1, #text do
		local ch = text:sub(i, i)
		if escaped then
			current[#current + 1] = ch
			escaped = false
		elseif ch == "\\" and quote ~= nil then
			current[#current + 1] = ch
			escaped = true
		elseif quote ~= nil then
			current[#current + 1] = ch
			if ch == quote then
				quote = nil
			end
		elseif ch == "\"" or ch == "'" then
			current[#current + 1] = ch
			quote = ch
		elseif ch == "," then
			items[#items + 1] = trim(table.concat(current))
			current = {}
		else
			current[#current + 1] = ch
		end
	end

	local tail = trim(table.concat(current))
	if tail ~= "" then
		items[#items + 1] = tail
	end
	return items
end

--expression grammar stays intentionally small: numbers, labels, dot, and +/-
--every extra idea here becomes relocation paperwork later
local function parseExpression(text)
	local source = trim(text)
	if source == "" then
		error("expected expression")
	end

	local terms = {}
	local i = 1
	local sign = 1
	local expectingValue = true

	while i <= #source do
		while i <= #source and source:sub(i, i):match("%s") do
			i += 1
		end
		if i > #source then
			break
		end

		local ch = source:sub(i, i)
		if ch == "+" then
			sign = 1
			expectingValue = true
			i += 1
		elseif ch == "-" then
			sign = -1
			expectingValue = true
			i += 1
		else
			if not expectingValue then
				error(("unexpected token near '%s'"):format(source:sub(i)))
			end

			if ch == "'" then
				local j = i + 1
				local escaped = false
				while j <= #source do
					local c = source:sub(j, j)
					if escaped then
						escaped = false
					elseif c == "\\" then
						escaped = true
					elseif c == "'" then
						break
					end
					j += 1
				end
				if j > #source or source:sub(j, j) ~= "'" then
					error(("unterminated char literal in '%s'"):format(source))
				end
				local literal = source:sub(i + 1, j - 1)
				local value
				if literal:sub(1, 1) == "\\" then
					value = unescapeChar(literal:sub(2, 2))
				else
					value = string.byte(literal)
				end
				terms[#terms + 1] = { kind = "number", sign = sign, value = value }
				i = j + 1
			elseif ch == "." and (i == #source or not source:sub(i + 1, i + 1):match("[%w_]")) then
				terms[#terms + 1] = { kind = "dot", sign = sign }
				i += 1
			else
				local j = i
				while j <= #source do
					local c = source:sub(j, j)
					if c == "+" or c == "-" then
						break
					end
					j += 1
				end
				local token = trim(source:sub(i, j - 1))
				if token == "" then
					error(("bad expression '%s'"):format(source))
				end
				local value = tonumber(token)
				if value == nil then
					if token:sub(1, 2):lower() == "0x" then
						value = tonumber(token:sub(3), 16)
					end
				end
				if value ~= nil then
					terms[#terms + 1] = { kind = "number", sign = sign, value = value }
				else
					terms[#terms + 1] = { kind = "label", sign = sign, name = token }
				end
				i = j
			end

			sign = 1
			expectingValue = false
		end
	end

	if #terms == 0 then
		error(("empty expression '%s'"):format(text))
	end

	return {
		source = source,
		terms = terms,
	}
end

--ROVD relocation only tolerates one positive symbol and no dot math
local function evalExpression(expr, labels, currentAbs, isRovd)
	local total = 0
	local sawDot = false
	local positiveLabels = 0
	local negativeLabels = 0

	for _, term in ipairs(expr.terms) do
		if term.kind == "number" then
			total += term.sign * term.value
		elseif term.kind == "dot" then
			total += term.sign * currentAbs
			sawDot = true
		else
			local sym = labels[term.name]
			local value
			if sym ~= nil then
				if type(sym) == "table" then
					value = sym.address
				else
					value = sym
				end
				if term.sign > 0 then
					positiveLabels += 1
				else
					negativeLabels += 1
				end
			else
				value = BUILTIN_LABELS[term.name]
			end
			if value == nil then
				error(("unknown symbol '%s' in expression '%s'"):format(term.name, expr.source))
			end
			total += term.sign * value
		end
	end

	local relocatable = false
	if isRovd and not sawDot and positiveLabels == 1 and negativeLabels == 0 then
		relocatable = true
	end

	return total, relocatable
end

--turn text into a normalized node first
--bytes can wait until the labels finish wandering
local function parseInstruction(mnemonic, operands, lineInfo)
	local upper = mnemonic:upper()
	local opcode = OPCODES[upper]
	if opcode == nil then
		error(("%s:%d: unknown instruction '%s'"):format(lineInfo.source, lineInfo.line, mnemonic))
	end

	local node = {
		kind = "instruction",
		mnemonic = upper,
		opcode = opcode,
		line = lineInfo.line,
		source = lineInfo.source,
		size = WIDE_MNEMONIC[upper] and 8 or 4,
	}

	local count = #operands
	if upper == "NOP" or upper == "HALT" or upper == "RET" or upper == "FLUSH" or upper == "SLEEP" then
		if count ~= 0 then
			error(("%s:%d: %s takes no operands"):format(lineInfo.source, lineInfo.line, upper))
		end
	elseif upper == "JMP" or upper == "CALL" then
		if count ~= 1 then
			error(("%s:%d: %s takes one operand"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.imm = parseExpression(operands[1])
	elseif upper == "JMPREL16" then
		if count ~= 1 then
			error(("%s:%d: JMPREL16 takes one operand"):format(lineInfo.source, lineInfo.line))
		end
		node.imm = parseExpression(operands[1])
	elseif upper == "JZ" or upper == "JNZ" then
		if count ~= 2 then
			error(("%s:%d: %s takes a register and a target"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		node.imm = parseExpression(operands[2])
	elseif upper == "JZREL16" or upper == "JNZREL16" then
		if count ~= 2 then
			error(("%s:%d: %s takes a register and a target"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		node.imm = parseExpression(operands[2])
	elseif upper == "LOADI" or upper == "LOADI16" then
		if count ~= 2 then
			error(("%s:%d: %s takes a register and an immediate"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		node.imm = parseExpression(operands[2])
	elseif upper == "ADDI16" or upper == "SUBI16" then
		if count ~= 2 and count ~= 3 then
			error(("%s:%d: %s takes reg, imm or reg, reg, imm"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		if count == 3 then
			local sourceReg = parseRegister(operands[2])
			if sourceReg ~= node.d then
				error(("%s:%d: %s compact form requires matching source/dest registers"):format(lineInfo.source, lineInfo.line, upper))
			end
			node.imm = parseExpression(operands[3])
		else
			node.imm = parseExpression(operands[2])
		end
	elseif upper == "ADDI" or upper == "SUBI" or upper == "MULI" or upper == "ANDI" or upper == "ORI" or upper == "XORI" then
		if count ~= 3 then
			error(("%s:%d: %s takes reg, reg, imm"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		node.a = parseRegister(operands[2])
		node.imm = parseExpression(operands[3])
	elseif upper == "SYSCALL" then
		if count ~= 1 then
			error(("%s:%d: SYSCALL takes one immediate operand"):format(lineInfo.source, lineInfo.line))
		end
		node.imm = parseExpression(operands[1])
	elseif upper == "CALLR" or upper == "GETPC" or upper == "INC" or upper == "DEC" then
		if count ~= 1 then
			error(("%s:%d: %s takes one register operand"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
	elseif upper == "MOV" or upper == "NOT" or upper == "LOAD" or upper == "STORE" or upper == "PUSH" or upper == "POP"
		or upper == "LOADB" or upper == "STOREB" or upper == "LOADH" or upper == "STOREH" or upper == "LOADBS" or upper == "LOADHS" then
		if count ~= 2 then
			error(("%s:%d: %s takes two register operands"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		node.a = parseRegister(operands[2])
	else
		if count ~= 3 then
			error(("%s:%d: %s takes three register operands"):format(lineInfo.source, lineInfo.line, upper))
		end
		node.d = parseRegister(operands[1])
		node.a = parseRegister(operands[2])
		node.b = parseRegister(operands[3])
	end

	return node
end

--directives become nodes too so pass 1 can count size before touching the buffer
local function parseDirective(name, args, lineInfo)
	local directive = DIRECTIVE_ALIASES[name:upper()]
	if directive == nil then
		error(("%s:%d: unknown directive '%s'"):format(lineInfo.source, lineInfo.line, name))
	end

	if directive == "TEXT" or directive == "DATA" or directive == "ROVM" or directive == "ROVD" then
		return {
			kind = "mode",
			mode = directive,
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "SECTION" then
		return {
			kind = "mode",
			mode = "SECTION",
			section = normalizeSection(args),
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "GLOBAL" or directive == "EXPORT" or directive == "ENTRY" then
		local items = splitOperands(args)
		if #items == 0 then
			error(("%s:%d: %s requires at least one symbol"):format(lineInfo.source, lineInfo.line, name))
		end
		return {
			kind = directive:lower(),
			names = items,
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "BYTE" then
		local items = splitOperands(args)
		if #items == 0 then
			error(("%s:%d: .BYTE requires at least one value"):format(lineInfo.source, lineInfo.line))
		end
		local values = table.create(#items)
		for i = 1, #items do
			values[i] = parseExpression(items[i])
		end
		return {
			kind = "data",
			dataType = "byte",
			values = values,
			size = #values,
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "WORD" then
		local items = splitOperands(args)
		if #items == 0 then
			error(("%s:%d: .WORD requires at least one value"):format(lineInfo.source, lineInfo.line))
		end
		local values = table.create(#items)
		for i = 1, #items do
			values[i] = parseExpression(items[i])
		end
		return {
			kind = "data",
			dataType = "word",
			values = values,
			size = #values * 4,
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "STRING" then
		local value = decodeStringLiteral(args)
		return {
			kind = "data",
			dataType = "string",
			value = value,
			size = #value + 1,
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "ALIGN" then
		local value = parseExpression(args)
		return {
			kind = "align",
			value = value,
			line = lineInfo.line,
			source = lineInfo.source,
		}
	elseif directive == "INCLUDE" then
		return {
			kind = "include",
			path = decodeStringLiteral(args),
			line = lineInfo.line,
			source = lineInfo.source,
		}
	end

	error(("%s:%d: unsupported directive '%s'"):format(lineInfo.source, lineInfo.line, name))
end

--flatten includes first
local function loadSourceLines(source, includeLoader, sourceName, seen, outLines)
	sourceName = sourceName or "<main>"
	seen = seen or {}
	outLines = outLines or {}

	if seen[sourceName] then
		error(("recursive include detected for '%s'"):format(sourceName))
	end
	seen[sourceName] = true

	local lineNo = 0
	for rawLine in (source .. "\n"):gmatch("(.-)\n") do
		lineNo += 1
		local commentFree = trim(stripComment(rawLine))
		local includeArg = commentFree:match("^%.INCLUDE%s+(.+)$")
		if includeArg ~= nil then
			if includeLoader == nil then
				error(("%s:%d: .INCLUDE requires an include loader"):format(sourceName, lineNo))
			end
			local includePath = decodeStringLiteral(includeArg)
			local ok, includeSource = pcall(includeLoader, includePath)
			if not ok or type(includeSource) ~= "string" then
				error(("%s:%d: include failed for '%s': %s"):format(
					sourceName,
					lineNo,
					includePath,
					tostring(includeSource)
				))
			end
			loadSourceLines(includeSource, includeLoader, includePath, seen, outLines)
		else
			outLines[#outLines + 1] = {
				source = sourceName,
				line = lineNo,
				text = rawLine,
			}
		end
	end

	seen[sourceName] = nil
	return outLines
end

--pass 1 just counts bytes and pins labels down
--normal ops are 4 bytes, wide ops are 8. enough for now lol
local function parseLines(lines)
	local state = {
		format = "ROVM",
		section = "text",
		nodes = {},
		labels = {},
		textSize = 0,
		dataSize = 0,
		entryLabel = nil,
		firstTextLabel = nil,
		exports = {},
		exportSet = {},
	}

	local sectionOffsets = {
		text = 0,
		data = 0,
	}

	for _, lineInfo in ipairs(lines) do
		local work = trim(stripComment(lineInfo.text))
		if work == "" then
			continue
		end

		while true do
			local label, rest = work:match("^([%a_][%w_]*):%s*(.*)$")
			if label == nil then
				break
			end
			if state.labels[label] ~= nil then
				error(("%s:%d: duplicate label '%s'"):format(lineInfo.source, lineInfo.line, label))
			end
			local offset = sectionOffsets[state.section]
			state.labels[label] = {
				section = state.section,
				offset = offset,
				line = lineInfo.line,
				source = lineInfo.source,
			}
			if state.section == "text" and state.firstTextLabel == nil then
				state.firstTextLabel = label
			end
			work = rest
			if work == "" then
				break
			end
		end

		if work == "" then
			continue
		end

		local node
		if work:sub(1, 1) == "." then
			local dirName, args = work:match("^(%S+)%s*(.-)%s*$")
			node = parseDirective(dirName, args or "", lineInfo)
		else
			local mnemonic, operandText = work:match("^(%S+)%s*(.-)%s*$")
			local operands = {}
			if operandText ~= nil and trim(operandText) ~= "" then
				operands = splitOperands(operandText)
			end
			node = parseInstruction(mnemonic, operands, lineInfo)
		end

		if node.kind == "mode" then
			if node.mode == "TEXT" then
				state.section = "text"
			elseif node.mode == "DATA" then
				state.section = "data"
			elseif node.mode == "SECTION" then
				state.section = node.section
			elseif node.mode == "ROVD" then
				state.format = "ROVD"
			elseif node.mode == "ROVM" then
				state.format = "ROVM"
			end
		elseif node.kind == "global" then
			if state.entryLabel == nil then
				state.entryLabel = node.names[1]
			end
		elseif node.kind == "entry" then
			state.entryLabel = node.names[1]
		elseif node.kind == "export" then
			for _, name in ipairs(node.names) do
				if not state.exportSet[name] then
					state.exportSet[name] = true
					state.exports[#state.exports + 1] = name
				end
			end
		elseif node.kind ~= "include" then
			node.section = state.section
			node.offset = sectionOffsets[state.section]
			if node.kind == "align" then
				local alignValue, reloc = evalExpression(node.value, {}, 0, false)
				if reloc or alignValue <= 0 then
					error(("%s:%d: .ALIGN requires a positive constant"):format(lineInfo.source, lineInfo.line))
				end
				node.alignment = alignValue
				node.size = alignUp(node.offset, alignValue) - node.offset
			end

			sectionOffsets[state.section] += node.size
			state.nodes[#state.nodes + 1] = node
		end
	end

	state.textSize = sectionOffsets.text
	state.dataSize = sectionOffsets.data

	local headerSize = (state.format == "ROVD") and ROVD_HEADER_SIZE or ROVM_HEADER_SIZE
	local dataBase = headerSize + state.textSize
	for _, sym in pairs(state.labels) do
		if sym.section == "text" then
			sym.address = headerSize + sym.offset
		else
			sym.address = dataBase + sym.offset
		end
	end

	if state.format == "ROVM" then
		if state.entryLabel == nil and state.labels._start ~= nil then
			state.entryLabel = "_start"
		end
	end

	return state
end

local function instructionAddress(state, node)
	local headerSize = (state.format == "ROVD") and ROVD_HEADER_SIZE or ROVM_HEADER_SIZE
	if node.section == "text" then
		return headerSize + node.offset
	end
	return headerSize + state.textSize + node.offset
end

--ROVD keeps absolute 32-bit patch points for the loader
--wide instructions stash the real address in the second word, naturally
local function collectRelocations(state)
	if state.format ~= "ROVD" then
		return {}
	end

	local relocs = {}
	for _, node in ipairs(state.nodes) do
		local currentAbs = instructionAddress(state, node)
		if node.kind == "instruction" then
			if node.imm ~= nil then
				local _, relocatable = evalExpression(node.imm, state.labels, currentAbs, true)
				if relocatable then
					if node.size ~= 8 then
						error(("%s:%d: %s cannot use absolute relocation in compact form"):format(
							node.source,
							node.line,
							node.mnemonic
						))
					end
					relocs[#relocs + 1] = currentAbs + 4
				end
			end
		elseif node.kind == "data" and node.dataType == "word" then
			for index, expr in ipairs(node.values) do
				local patchAbs = currentAbs + ((index - 1) * 4)
				local _, relocatable = evalExpression(expr, state.labels, patchAbs, true)
				if relocatable then
					relocs[#relocs + 1] = patchAbs
				end
			end
		end
	end
	return relocs
end

local function encodeRRR(opcode, d, a, b)
	return band(lshift(opcode, 24) + lshift(d or 0, 16) + lshift(a or 0, 8) + (b or 0), 0xFFFFFFFF)
end

--pass 2 writes bytes once the label addresses stop moving
--if an immediate does not fit here, fail now instead of shipping a pipe bomb
local function emitInstruction(buf, pos, state, node)
	local currentAbs = instructionAddress(state, node)
	local opcode = node.opcode

	if node.mnemonic == "NOP" or node.mnemonic == "HALT" or node.mnemonic == "RET" or node.mnemonic == "FLUSH" or node.mnemonic == "SLEEP" then
		buffer_writeu32(buf, pos, encodeRRR(opcode, 0, 0, 0))
		return
	end

	if node.mnemonic == "LOAD" or node.mnemonic == "STORE" or node.mnemonic == "MOV" or node.mnemonic == "NOT"
		or node.mnemonic == "PUSH" or node.mnemonic == "POP" or node.mnemonic == "CALLR"
		or node.mnemonic == "LOADB" or node.mnemonic == "STOREB" or node.mnemonic == "LOADH"
		or node.mnemonic == "STOREH" or node.mnemonic == "LOADBS" or node.mnemonic == "LOADHS"
		or node.mnemonic == "GETPC" or node.mnemonic == "INC" or node.mnemonic == "DEC" then
		buffer_writeu32(buf, pos, encodeRRR(opcode, node.d or 0, node.a or 0, 0))
		return
	end

	if node.mnemonic == "ADD" or node.mnemonic == "SUB" or node.mnemonic == "MUL" or node.mnemonic == "DIV"
		or node.mnemonic == "MOD" or node.mnemonic == "AND" or node.mnemonic == "OR" or node.mnemonic == "XOR"
		or node.mnemonic == "SHL" or node.mnemonic == "SHR" or node.mnemonic == "CMPEQ" or node.mnemonic == "CMPLT"
		or node.mnemonic == "CMPGT" or node.mnemonic == "SAR" or node.mnemonic == "ASHR" then
		buffer_writeu32(buf, pos, encodeRRR(opcode, node.d or 0, node.a or 0, node.b or 0))
		return
	end

	if node.mnemonic == "SYSCALL" then
		local value, relocatable = evalExpression(node.imm, state.labels, currentAbs, state.format == "ROVD")
		if relocatable then
			error(("%s:%d: SYSCALL cannot use relocatable immediates"):format(node.source, node.line))
		end
		if value < 0 or value > 0xFF then
			error(("%s:%d: syscall number out of range: %s"):format(node.source, node.line, node.imm.source))
		end
		buffer_writeu32(buf, pos, encodeRRR(opcode, 0, 0, value))
		return
	end

	if node.mnemonic == "LOADI16" or node.mnemonic == "ADDI16" or node.mnemonic == "SUBI16" then
		local value, relocatable = evalExpression(node.imm, state.labels, currentAbs, state.format == "ROVD")
		if relocatable then
			error(("%s:%d: %s cannot use relocatable immediates"):format(node.source, node.line, node.mnemonic))
		end
		if value < -0x8000 or value > 0x7FFF then
			error(("%s:%d: %s immediate out of 16-bit range: %s"):format(node.source, node.line, node.mnemonic, node.imm.source))
		end
		local imm16 = band(value, 0xFFFF)
		buffer_writeu32(buf, pos, encodeRRR(opcode, node.d, band(bit32.rshift(imm16, 8), 0xFF), band(imm16, 0xFF)))
		return
	end

	if node.mnemonic == "JMPREL16" or node.mnemonic == "JZREL16" or node.mnemonic == "JNZREL16" then
		local target, relocatable = evalExpression(node.imm, state.labels, currentAbs, state.format == "ROVD")
		if relocatable then
			error(("%s:%d: %s requires a relative target, not an absolute relocatable symbol"):format(node.source, node.line, node.mnemonic))
		end
		local rel = target - (currentAbs + 4)
		if rel < -0x8000 or rel > 0x7FFF then
			error(("%s:%d: %s target out of 16-bit relative range: %s"):format(node.source, node.line, node.mnemonic, node.imm.source))
		end
		local imm16 = band(rel, 0xFFFF)
		buffer_writeu32(buf, pos, encodeRRR(opcode, node.d or 0, band(bit32.rshift(imm16, 8), 0xFF), band(imm16, 0xFF)))
		return
	end

	if node.imm ~= nil then
		--wide form is opcode word, then imm word. two words. no mysteriousness.
		local immValue = evalExpression(node.imm, state.labels, currentAbs, state.format == "ROVD")
		buffer_writeu32(buf, pos, encodeRRR(opcode, node.d or 0, node.a or 0, 0))
		buffer_writeu32(buf, pos + 4, band(immValue, 0xFFFFFFFF))
		return
	end

	error(("%s:%d: failed to encode instruction %s"):format(node.source, node.line, node.mnemonic))
end

--ROVM header is 4 u32s: 16 bytes, plain and unremarkable
--ROVD brings export and reloc baggage, so that one lands at 32
local function writeHeader(buf, state, exportTableOffset, relocTableOffset, relocCount)
	if state.format == "ROVD" then
		buffer_writeu32(buf, 0, ROVD_MAGIC)
		buffer_writeu32(buf, 4, exportTableOffset)
		buffer_writeu32(buf, 8, #state.exports)
		buffer_writeu32(buf, 12, state.textSize)
		buffer_writeu32(buf, 16, state.dataSize)
		buffer_writeu32(buf, 20, relocTableOffset)
		buffer_writeu32(buf, 24, relocCount)
		buffer_writeu32(buf, 28, 0)
	else
		local entryPoint
		if state.entryLabel ~= nil then
			local entry = state.labels[state.entryLabel]
			if entry == nil then
				error(("entry label '%s' is not defined"):format(state.entryLabel))
			end
			entryPoint = entry.address
		else
			entryPoint = ROVM_HEADER_SIZE
		end
		buffer_writeu32(buf, 0, ROVM_MAGIC)
		buffer_writeu32(buf, 4, entryPoint)
		buffer_writeu32(buf, 8, state.textSize)
		buffer_writeu32(buf, 12, state.dataSize)
	end
end

--flow is: flatten includes, parse and size, collect relocs, then write bytes
function Assembler.assemble(source, includeLoader)
	assert(type(source) == "string", "source must be a string")

	local lines = loadSourceLines(source, includeLoader)
	local state = parseLines(lines)
	local headerSize = (state.format == "ROVD") and ROVD_HEADER_SIZE or ROVM_HEADER_SIZE
	local relocs = collectRelocations(state)
	local exportTableOffset = headerSize + state.textSize + state.dataSize
	local relocTableOffset = exportTableOffset + (#state.exports * EXPORT_ENTRY_SIZE)
	local totalSize = relocTableOffset + (#relocs * 4)
	local buf = buffer_create(totalSize)

	writeHeader(buf, state, exportTableOffset, relocTableOffset, #relocs)

	for _, node in ipairs(state.nodes) do
		local pos = instructionAddress(state, node)
		if node.kind == "instruction" then
			emitInstruction(buf, pos, state, node)
		elseif node.kind == "data" then
			if node.dataType == "byte" then
				for index, expr in ipairs(node.values) do
					local value, relocatable = evalExpression(expr, state.labels, pos + index - 1, state.format == "ROVD")
					if relocatable then
						error(("%s:%d: .BYTE cannot use relocatable addresses"):format(node.source, node.line))
					end
					buffer_writeu8(buf, pos + index - 1, band(value, 0xFF))
				end
			elseif node.dataType == "word" then
				for index, expr in ipairs(node.values) do
					local value = evalExpression(expr, state.labels, pos + ((index - 1) * 4), state.format == "ROVD")
					buffer_writeu32(buf, pos + ((index - 1) * 4), band(value, 0xFFFFFFFF))
				end
			elseif node.dataType == "string" then
				for i = 1, #node.value do
					buffer_writeu8(buf, pos + i - 1, string.byte(node.value, i))
				end
				buffer_writeu8(buf, pos + #node.value, 0)
			end
		end
	end

	if state.format == "ROVD" then
		for index, name in ipairs(state.exports) do
			local symbol = state.labels[name]
			if symbol == nil then
				error(("exported symbol '%s' is not defined"):format(name))
			end
			local entryPos = exportTableOffset + ((index - 1) * EXPORT_ENTRY_SIZE)
			for i = 1, math.min(#name, 28) do
				buffer_writeu8(buf, entryPos + i - 1, string.byte(name, i))
			end
			buffer_writeu32(buf, entryPos + 28, symbol.address)
		end

		for index, relocPos in ipairs(relocs) do
			buffer_writeu32(buf, relocTableOffset + ((index - 1) * 4), relocPos)
		end
	end

	return buf
end

return Assembler
