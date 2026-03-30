--!native
local CodeGen = {}
CodeGen.__index = CodeGen

function CodeGen.new()
	local g = setmetatable({}, CodeGen)
	g.out = {}
	g.lbl = 0
	--compiler state buckets
	g.structs = {}
	g.enums = {}
	g.globals = {}
	g.statics = {}
	g.funcs = {}
	g.scopes = {}
	g.localOff = 0
	g.staticCount = 0
	g.breakLbl = nil
	g.contLbl = nil
	g.strings = {}
	return g
end

function CodeGen:emit(s) table.insert(self.out, s) end
function CodeGen:emitf(...) table.insert(self.out, string.format(...)) end
function CodeGen:label() self.lbl=self.lbl+1; return "L"..self.lbl end
function CodeGen:err(node, fmt, ...)
	local msg = string.format(fmt, ...)
	if node and node.line then
		msg = string.format("%s:%d:%d: error: %s", node.file or "main.c", node.line, node.col, msg)
	end
	error(msg)
end

--type helpers are mostly size and alignment paperwork
--annoying, yes, but if this lies everything else lies too
local INT_TYPE = {base="int", ptr=0}
local CHAR_PTR_TYPE = {base="char", ptr=1}

local function alignUp(value, alignment)
	local mask = alignment - 1
	return bit32.band(value + mask, bit32.bnot(mask))
end

function CodeGen:isComposite(typ)
	if not typ or (typ.ptr and typ.ptr ~= 0) then return false end
	local b = typ.base
	return b:sub(1,7) == "struct:" or b:sub(1,6) == "union:"
end

function CodeGen:compositeKey(typ)
	local b = typ.base
	if b:sub(1,7) == "struct:" then return b:sub(8)
	elseif b:sub(1,6) == "union:" then return b:sub(7) end
	return nil
end

function CodeGen:sizeOf(typ)
	if not typ then return 4 end
	if typ.ptr and typ.ptr > 0 then return 4 end
	local b = typ.base
	if b == "int" or b == "long" then return 4
	elseif b == "char" then return 1
	elseif b == "short" then return 2
	elseif b == "void" then return 1
	end
	local key = self:compositeKey(typ)
	if key then
		local sd = self.structs[key]
		return sd and sd.size or 4
	end
	return 4
end

function CodeGen:alignOfType(typ)
	if not typ then return 4 end
	if typ.ptr and typ.ptr > 0 then return 4 end
	local b = typ.base
	if b == "int" or b == "long" then return 4
	elseif b == "char" then return 1
	elseif b == "short" then return 2
	end
	local key = self:compositeKey(typ)
	if key then
		local sd = self.structs[key]
		if sd then
			local maxA = 1
			for _,f in ipairs(sd.fields) do
				local a = self:alignOfType(f.type)
				if a > maxA then maxA = a end
			end
			return maxA
		end
		return 4
	end
	return 4
end

function CodeGen:loadInsnForType(typ)
	if not typ or (typ.ptr and typ.ptr > 0) then return "LOAD" end
	if typ.base == "char" then return "LOADB" end
	if typ.base == "short" then return "LOADH" end
	return "LOAD"
end

function CodeGen:storeInsnForType(typ)
	if not typ or (typ.ptr and typ.ptr > 0) then return "STORE" end
	if typ.base == "char" then return "STOREB" end
	if typ.base == "short" then return "STOREH" end
	return "STORE"
end

function CodeGen:emitZero(reg)
	self:emitf("XOR %s, %s, %s", reg, reg, reg)
end

function CodeGen:emitMove(dst, src)
	if dst ~= src then
		self:emitf("MOV %s, %s", dst, src)
	end
end

function CodeGen:emitLoadImm(reg, imm)
	if imm == 0 then
		self:emitZero(reg)
	elseif imm >= -32768 and imm <= 32767 then
		self:emitf("LOADI16 %s, %d", reg, imm)
	else
		self:emitf("LOADI %s, %d", reg, imm)
	end
end

function CodeGen:emitAddImm(dst, src, imm)
	if imm == 0 then
		self:emitMove(dst, src)
	elseif imm < 0 then
		self:emitSubImm(dst, src, -imm)
	elseif dst == src and imm == 1 then
		self:emitf("INC %s", dst)
	elseif dst == src and imm <= 32767 then
		self:emitf("ADDI16 %s, %d", dst, imm)
	else
		self:emitf("ADDI %s, %s, %d", dst, src, imm)
	end
end

function CodeGen:emitSubImm(dst, src, imm)
	if imm == 0 then
		self:emitMove(dst, src)
	elseif imm < 0 then
		self:emitAddImm(dst, src, -imm)
	elseif dst == src and imm == 1 then
		self:emitf("DEC %s", dst)
	elseif dst == src and imm <= 32767 then
		self:emitf("SUBI16 %s, %d", dst, imm)
	else
		self:emitf("SUBI %s, %s, %d", dst, src, imm)
	end
end

function CodeGen:emitFrameAddress(dst, base, offset)
	if offset < 0 then
		self:emitSubImm(dst, base, -offset)
	elseif offset > 0 then
		self:emitAddImm(dst, base, offset)
	else
		self:emitMove(dst, base)
	end
end

function CodeGen:emitRestoreSP(targetOff)
	if targetOff == 0 then
		self:emit("MOV r15, r14")
	else
		self:emitSubImm("r15", "r14", targetOff)
	end
end

--scope bookkeeping. mostly offsets stacks
function CodeGen:pushScope() table.insert(self.scopes, {vars={}}) end
function CodeGen:popScope() table.remove(self.scopes) end

function CodeGen:addLocal(name, typ, arr, isStatic)
	if isStatic then
		self.staticCount = self.staticCount + 1
		local slbl = "S_" .. name .. "_" .. self.staticCount
		self.scopes[#self.scopes].vars[name] = {type=typ, staticLabel=slbl, arr=arr}
		return slbl
	end

	local elemSize = self:sizeOf(typ)
	local totalBytes = (arr or 1) * elemSize
	totalBytes = math.max(4, alignUp(totalBytes, 4))

	self.localOff = self.localOff + totalBytes
	self.scopes[#self.scopes].vars[name] = {type=typ, offset=-self.localOff, arr=arr}
	return nil
end

function CodeGen:lookup(name)
	for i=#self.scopes, 1, -1 do
		if self.scopes[i].vars[name] then return self.scopes[i].vars[name], false end
	end
	if self.globals[name] then return self.globals[name], true end
	return nil, nil
end

function CodeGen:fieldInfo(node, sname, fname)
	local sd = self.structs[sname]
	if not sd then self:err(node, "Unknown struct: %s", sname) end
	for _,f in ipairs(sd.fields) do
		if f.name == fname then return f.offset, f.type, f.arr end
	end
	self:err(node, "Unknown field %s in %s", fname, sname)
end

--top level sweep
function CodeGen:genProgram(ast)
	for _,d in ipairs(ast.decls) do
		if d.tag == "StructDef" then self:regStruct(d)
		elseif d.tag == "EnumDef" then
			for k,v in pairs(d.items) do
				if v.tag == "Num" then
					self.enums[k] = v.value
				elseif v.tag == "Ident" and self.enums[v.name] then
					self.enums[k] = self.enums[v.name]
				else
					self.enums[k] = 0
				end
			end
		elseif d.tag == "FuncDef" then self.funcs[d.name]={retType=d.retType,params=d.params}
		elseif d.tag == "FuncDecl" then
			if not self.funcs[d.name] then
				self.funcs[d.name]={retType=d.retType,params=d.params}
			end
		elseif d.tag == "VarDecl" and d.global then
			if not (d.type and d.type.isExtern) then
				self.globals[d.name]={type=d.type,arr=d.arr,init=d.init}
			end
		elseif d.tag == "MultiDecl" then
			for _,sub in ipairs(d.decls) do
				if sub.tag == "VarDecl" and sub.global and not (sub.type and sub.type.isExtern) then
					self.globals[sub.name]={type=sub.type,arr=sub.arr,init=sub.init}
				end
			end
		end
	end

	local isLibrary = false
	for _,d in ipairs(ast.decls) do
		if d.tag == "FuncDef" and d.retType and d.retType.isExport then
			isLibrary = true
			break
		end
	end
	self.isLibrary = isLibrary

	self:emit("; Generated by ROVM CC (byte-addressable)")
	if isLibrary then
		self:emit(".ROVD")
	else
		self:emit(".TEXT")
		--sc_exec already builds the first user stack, so dont do that twice
		self:emit("CALL main")
		self:emit("SYSCALL 3")
		self:emit("")
	end
	if isLibrary then
		self:emit(".TEXT")
	end

	for _,d in ipairs(ast.decls) do
		if d.tag == "FuncDef" then self:genFunc(d) end
	end

	--if pc lands in data because return or call went sideways, halt
	self:emit("; === DATA ===")
	self:emit(".DATA")
	self:emit("_data_guard:")
	self:emit("HALT")
	for name, info in pairs(self.globals) do
		self:emitDataVar(name, info)
	end
	for slbl, info in pairs(self.statics) do
		self:emitDataVar(slbl, info)
	end

	for _,sl in ipairs(self.strings) do
		self:emitf("%s:", sl.label)
		local parts = {}
		for i=1,#sl.value do parts[#parts+1] = tostring(string.byte(sl.value,i)) end
		parts[#parts+1] = "0"
		self:emitf(".BYTE %s", table.concat(parts, ", "))
	end

	return table.concat(self.out, "\n")
end

function CodeGen:emitDataVar(label, info)
	self:emitf("%s:", label)
	local isChar = info.type and info.type.ptr == 0 and info.type.base == "char"
	local isShort = info.type and info.type.ptr == 0 and info.type.base == "short"
	local sz = info.arr or 1

	if info.init and info.init.tag == "InitList" then
		--designated init items need the actual values peeled out first
		local items = {}
		for _, item in ipairs(info.init.items) do
			if item.tag == "DesignatedInit" then
				items[#items+1] = item.value
			else
				items[#items+1] = item
			end
		end

		if isChar then
			local parts = {}
			for _,item in ipairs(items) do
				parts[#parts+1] = tostring(item.tag=="Num" and item.value or 0)
			end
			for i=#items+1, sz do parts[#parts+1] = "0" end
			self:emitf(".BYTE %s", table.concat(parts, ", "))
		elseif isShort then
			for _,item in ipairs(items) do
				self:emitf(".BYTE %d, %d", bit32.band(item.tag=="Num" and item.value or 0, 0xFF),
					bit32.rshift(bit32.band(item.tag=="Num" and item.value or 0, 0xFF00), 8))
			end
			for i=#items+1, sz do self:emit(".BYTE 0, 0") end
		else
			for _,item in ipairs(items) do
				self:emitf(".WORD %d", item.tag=="Num" and item.value or 0)
			end
			for i=#items+1, sz do self:emit(".WORD 0") end
		end
	elseif info.init and info.init.tag == "Num" then
		if isChar then
			self:emitf(".BYTE %d", info.init.value)
		elseif isShort then
			self:emitf(".BYTE %d, %d", bit32.band(info.init.value, 0xFF), bit32.rshift(bit32.band(info.init.value, 0xFF00), 8))
		else
			self:emitf(".WORD %d", info.init.value)
		end
	else
		if isChar then
			local parts = {}
			for i=1, sz do parts[#parts+1] = "0" end
			self:emitf(".BYTE %s", table.concat(parts, ", "))
		elseif isShort then
			for i=1,sz do self:emit(".BYTE 0, 0") end
		else
			for i=1,sz do self:emit(".WORD 0") end
		end
	end
end

function CodeGen:regStruct(d)
	local fields, off = {}, 0
	local maxAlign = 1
	local isUnion = d.isUnion or false

	--register nested struct and union defs first or offsets start lying
	for _,f in ipairs(d.fields) do
		if f.nested then
			self:regStruct(f.nested)
		end
	end

	for _,f in ipairs(d.fields) do
		local fAlign = self:alignOfType(f.type)
		if f.type.ptr and f.type.ptr > 0 then fAlign = 4 end
		if fAlign > maxAlign then maxAlign = fAlign end

		if not isUnion then
			off = alignUp(off, fAlign)
		end

		local elemSize = self:sizeOf(f.type)
		local fsz = (f.arr or 1) * elemSize
		table.insert(fields,{name=f.name,type=f.type,offset=isUnion and 0 or off,arr=f.arr})

		if isUnion then
			if fsz > off then off = fsz end
		else
			off = off + fsz
		end
	end
	off = alignUp(off, maxAlign)
	self.structs[d.name]={fields=fields,size=off,isUnion=isUnion}
end

--function prologue epilogue and the stack tax collector live here
function CodeGen:genFunc(d)
	if d.retType and d.retType.isExport then
		self:emitf(".EXPORT %s", d.name)
	end
	self:emitf("%s:", d.name)
	self:emit("PUSH r14, r15")
	self:emit("MOV r14, r15")
	self:pushScope()
	self.localOff = 0

	for i, param in ipairs(d.params) do
		self:addLocal(param.name, param.type, nil)
		if i <= 8 then
			self:emitf("PUSH r%d, r15", i-1)
		else
			--params 9+ need real stack calling convention work. eight is the current limit for me
			self:emitZero("r0")
			self:emit("PUSH r0, r15")
		end
	end

	self:genStmt(d.body)

	self:emit("MOV r15, r14")
	self:emit("POP r14, r15")
	self:emit("RET")
	self:emit("")
	self:popScope()
end

--statement lowering. this is where control flow starts making demands
function CodeGen:genStmt(s)
	if s.tag == "Empty" then
		return
	elseif s.tag == "StructDef" then
		self:regStruct(s)
		return
	elseif s.tag == "MultiDecl" then
		for _,sub in ipairs(s.decls) do
			self:genStmt(sub)
		end
		return
	elseif s.tag == "EnumDef" then
		for k,v in pairs(s.items) do
			if v.tag == "Num" then self.enums[k] = v.value
			elseif v.tag == "Ident" and self.enums[v.name] then self.enums[k] = self.enums[v.name]
			else self.enums[k] = 0 end
		end
		return
	elseif s.tag == "StructDef" then
		self:regStruct(s)
		return
	elseif s.tag == "Block" then
		local savedOff = self.localOff
		self:pushScope()
		for _,st in ipairs(s.stmts) do self:genStmt(st) end
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		self:popScope()

	elseif s.tag == "MultiDecl" then
		for _,st in ipairs(s.decls) do
			if st.tag == "VarDecl" then self:genVarDecl(st) else self:genStmt(st) end
		end

	elseif s.tag == "Return" then
		if s.expr then self:genExpr(s.expr) end
		self:emit("MOV r15, r14")
		self:emit("POP r14, r15")
		self:emit("RET")

	elseif s.tag == "If" then
		local elL, endL = self:label(), self:label()
		self:genExpr(s.cond)
		self:emitf("JZ r0, %s", s.elseB and elL or endL)
		self:genStmt(s.thenB)
		if s.elseB then
			self:emitf("JMP %s", endL)
			self:emitf("%s:", elL)
			self:genStmt(s.elseB)
		end
		self:emitf("%s:", endL)

	elseif s.tag == "While" then
		local topL, endL, contL = self:label(), self:label(), self:label()
		local pb, pc = self.breakLbl, self.contLbl
		self.breakLbl, self.contLbl = endL, contL
		local savedOff = self.localOff
		self:emitf("%s:", topL)
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		self:genExpr(s.cond)
		self:emitf("JZ r0, %s", endL)
		self:genStmt(s.body)
		self:emitf("%s:", contL)
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		self:emitf("JMP %s", topL)
		self:emitf("%s:", endL)
		self.localOff = savedOff
		self.breakLbl, self.contLbl = pb, pc

	elseif s.tag == "DoWhile" then
		local topL, condL, endL = self:label(), self:label(), self:label()
		local pb, pc = self.breakLbl, self.contLbl
		self.breakLbl, self.contLbl = endL, condL
		local savedOff = self.localOff
		self:emitf("%s:", topL)
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		self:genStmt(s.body)
		self:emitf("%s:", condL)
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		self:genExpr(s.cond)
		self:emitf("JZ r0, %s", endL)
		self:emitf("JMP %s", topL)
		self:emitf("%s:", endL)
		self.localOff = savedOff
		self.breakLbl, self.contLbl = pb, pc

	elseif s.tag == "For" then
		local topL, updL, endL, contL = self:label(), self:label(), self:label(), self:label()
		local pb, pc = self.breakLbl, self.contLbl
		self.breakLbl, self.contLbl = endL, contL
		if s.init then
			if s.init.tag=="VarDecl" then self:genVarDecl(s.init)
			elseif s.init.tag=="MultiDecl" then self:genStmt(s.init)
			elseif s.init.tag~="Empty" then self:genExpr(s.init) end
		end
		local savedOff = self.localOff
		self:emitf("%s:", topL)
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		if s.cond then self:genExpr(s.cond); self:emitf("JZ r0, %s", endL) end
		self:genStmt(s.body)
		self:emitf("%s:", contL)
		self:emitRestoreSP(savedOff)
		self.localOff = savedOff
		self:emitf("%s:", updL)
		if s.upd then self:genExpr(s.upd) end
		self:emitf("JMP %s", topL)
		self:emitf("%s:", endL)
		self.localOff = savedOff
		self.breakLbl, self.contLbl = pb, pc

	elseif s.tag == "Switch" then
		self:genExpr(s.cond)
		self:emit("PUSH r0, r15")

		local endL = self:label()
		local pb = self.breakLbl
		self.breakLbl = endL

		local cases = {}
		local defaultLbl = nil
		local function findCases(node)
			if not node then return end
			if node.tag == "Case" then
				node.lbl = self:label()
				table.insert(cases, node)
			elseif node.tag == "Default" then
				node.lbl = self:label()
				defaultLbl = node.lbl
			elseif node.tag == "Block" then
				for _, stmt in ipairs(node.stmts) do findCases(stmt) end
			elseif node.thenB or node.elseB then
				findCases(node.thenB)
				findCases(node.elseB)
			elseif node.body then
				findCases(node.body)
			end
		end
		findCases(s.body)

		for _, c in ipairs(cases) do
			self:genExpr(c.val)
			self:emit("LOAD r1, r15")
			self:emit("CMPEQ r0, r1, r0")
			local skipL = self:label()
			self:emitf("JZ r0, %s", skipL)
			self:emit("POP r0, r15")
			self:emitf("JMP %s", c.lbl)
			self:emitf("%s:", skipL)
		end

		self:emit("POP r0, r15")
		if defaultLbl then
			self:emitf("JMP %s", defaultLbl)
		else
			self:emitf("JMP %s", endL)
		end

		self:genStmt(s.body)
		self:emitf("%s:", endL)
		self.breakLbl = pb

	elseif s.tag == "Case" then
		if s.lbl then self:emitf("%s:", s.lbl) end

	elseif s.tag == "Default" then
		if s.lbl then self:emitf("%s:", s.lbl) end

	elseif s.tag == "Break" then
		if self.breakLbl then self:emitf("JMP %s", self.breakLbl) end

	elseif s.tag == "Continue" then
		if self.contLbl then self:emitf("JMP %s", self.contLbl) end

	elseif s.tag == "Goto" then
		self:emitf("JMP %s", s.label)

	elseif s.tag == "Label" then
		self:emitf("%s:", s.name)

	elseif s.tag == "VarDecl" then
		self:genVarDecl(s)

	elseif s.tag == "ExprStmt" then
		self:genExpr(s.expr)
	end
end

function CodeGen:genVarDecl(d)
	if d.isStatic then
		local slbl = self:addLocal(d.name, d.type, d.arr, true)
		self.statics[slbl] = {type=d.type, arr=d.arr, init=d.init}
		return
	end

	local elemSize = self:sizeOf(d.type)
	local isStruct = self:isComposite(d.type)
	local isScalar = not d.arr and not isStruct

	if isScalar then
		if d.init and d.init.tag~="InitList" then self:genExpr(d.init) else self:emitZero("r0") end
		self:emit("PUSH r0, r15")
		self:addLocal(d.name, d.type, d.arr)
	else
		local totalBytes = (d.arr or 1) * elemSize
		totalBytes = math.max(4, alignUp(totalBytes, 4))

		self:emitSubImm("r15", "r15", totalBytes)
		if d.init and d.init.tag=="InitList" then
			if isStruct and not d.arr then
				local sd = self.structs[self:compositeKey(d.type)]
				if sd then
					local fieldIdx = 1
					for _, item in ipairs(d.init.items) do
						local fld, val
						if item.tag == "DesignatedInit" then
							val = item.value
							for j, f in ipairs(sd.fields) do
								if f.name == item.field then fld = f; fieldIdx = j + 1; break end
							end
						else
							fld = sd.fields[fieldIdx]
							val = item
							fieldIdx = fieldIdx + 1
						end
						if fld then
							self:genExpr(val)
							local offset = self.localOff + totalBytes - fld.offset
							self:emitFrameAddress("r1", "r14", -offset)
							self:emit(self:storeInsnForType(fld.type) .. " r1, r0")
						end
					end
				end
			else
				for i,item in ipairs(d.init.items) do
					self:genExpr(item)
					local offset = self.localOff + totalBytes - (i - 1) * elemSize
					self:emitFrameAddress("r1", "r14", -offset)
					self:emit(self:storeInsnForType(d.type) .. " r1, r0")
				end
			end
		end
		self:addLocal(d.name, d.type, d.arr)
	end
end

--expressions all orbit r0
function CodeGen:genExprTyped(e)
	if e.tag == "Num" then
		self:emitLoadImm("r0", e.value)
		return INT_TYPE

	elseif e.tag == "Str" then
		local lbl = self:label()
		table.insert(self.strings, {label=lbl, value=e.value})
		if self.isLibrary then
			self:emit("GETPC r0")
			self:emitf("LOADI r1, %s - . + 4", lbl)
			self:emit("ADD r0, r0, r1")
		else
			self:emitf("LOADI r0, %s", lbl)
		end
		return CHAR_PTR_TYPE

	elseif e.tag == "Ident" then
		if self.enums[e.name] ~= nil then
			self:emitLoadImm("r0", self.enums[e.name])
			return INT_TYPE
		end

		if self.funcs[e.name] ~= nil then
			if self.isLibrary then
				self:emit("GETPC r0")
				self:emitf("LOADI r1, %s - . + 4", e.name)
				self:emit("ADD r0, r0, r1")
			else
				self:emitf("LOADI r0, %s", e.name)
			end
			local t = self.funcs[e.name].retType or INT_TYPE
			return {base=t.base, ptr=(t.ptr or 0)+1}
		end

		local info, isG = self:lookup(e.name)
		if not info then self:emitf("LOADI r0, %s", e.name); return INT_TYPE end
		if isG then
			if self.isLibrary then
				self:emit("GETPC r0")
				self:emitf("LOADI r1, %s - . + 4", e.name)
				self:emit("ADD r0, r0, r1")
			else
				self:emitf("LOADI r0, %s", e.name)
			end
			local isStruct = self:isComposite(info.type)
			if not info.arr and not isStruct then
				self:emit(self:loadInsnForType(info.type) .. " r0, r0")
			end
		else
			if info.staticLabel then
				if self.isLibrary then
					self:emit("GETPC r0")
					self:emitf("LOADI r1, %s - . + 4", info.staticLabel)
					self:emit("ADD r0, r0, r1")
				else
					self:emitf("LOADI r0, %s", info.staticLabel)
				end
			elseif info.offset < 0 then
				self:emitFrameAddress("r0", "r14", info.offset)
			else
				self:emitFrameAddress("r0", "r14", info.offset)
			end
			local isStruct = self:isComposite(info.type)
			if not info.arr and not isStruct then
				self:emit(self:loadInsnForType(info.type) .. " r0, r0")
			end
		end
		if info.arr then
			return {base=info.type.base, ptr=(info.type.ptr or 0)+1}
		end
		return info.type or INT_TYPE

	elseif e.tag == "Assign" then
		local vt = self:genExprTyped(e.value)
		self:emit("PUSH r0, r15")
		local tt = self:genLValTyped(e.target)
		self:emit("POP r1, r15")

		local assignType = tt or vt
		if self:isComposite(assignType) then
			local key = self:compositeKey(assignType)
			local sd = self.structs[key]
			if not sd then self:err(e, "Unknown type: %s", key or "unknown") end
			if sd and sd.size > 0 then
				self:emitStructCopy(sd.size)
				self:emit("MOV r0, r1")
				return assignType
			end
		end

		self:emit(self:storeInsnForType(tt) .. " r0, r1")
		self:emit("MOV r0, r1")
		return vt

	elseif e.tag == "BinOp" then
		return self:genBinOp(e)

	elseif e.tag == "UnaryOp" then
		local t = self:genExprTyped(e.expr)
		if e.op == "-" then self:emitZero("r1"); self:emit("SUB r0, r1, r0")
		elseif e.op == "!" then
			local tL,eL=self:label(),self:label()
			self:emitf("JZ r0, %s",tL); self:emitZero("r0"); self:emitf("JMP %s",eL)
			self:emitf("%s:",tL); self:emitLoadImm("r0", 1); self:emitf("%s:",eL)
		elseif e.op == "~" then
			self:emit("NOT r0, r0")
		end
		return (e.op == "!" or e.op == "~") and INT_TYPE or t

	elseif e.tag == "Deref" then
		local t = self:genExprTyped(e.expr)
		local pointeeType = INT_TYPE
		if t and t.ptr and t.ptr > 0 then
			pointeeType = {base=t.base, ptr=t.ptr-1}
		end
		self:emit(self:loadInsnForType(pointeeType) .. " r0, r0")
		return pointeeType

	elseif e.tag == "AddrOf" then
		self:genLVal(e.expr)
		local info = self:lookup(e.expr.name)
		if info then
			return {base=(info.type or INT_TYPE).base, ptr=((info.type or INT_TYPE).ptr or 0)+1}
		end
		return {base="int", ptr=1}

	elseif e.tag == "Call" then
		local isSyscall = false
		local sysN = 0
		if e.func.tag == "Ident" then
			local fn = e.func.name
			if fn == "syscall" or fn == "syscall0" or fn == "syscall1" or fn == "syscall2" or 
				fn == "syscall3" or fn == "syscall4" or fn == "syscall5" or fn == "syscall6" then
				isSyscall = true
				sysN = e.args[1] and e.args[1].tag == "Num" and e.args[1].value or 0
			end
		end

		if isSyscall then
			for i=2,#e.args do
				self:genCallArgTyped(e.args[i])
				self:emit("PUSH r0, r15")
			end
			for i=#e.args, 2, -1 do
				self:emitf("POP r%d, r15", i-2)
			end
			self:emitf("SYSCALL %d", sysN)
		else
			if e.func.tag == "Ident" and self.funcs[e.func.name] then
				for i=1,#e.args do
					self:genCallArgTyped(e.args[i])
					self:emit("PUSH r0, r15")
				end
				for i=#e.args, 1, -1 do
					if i <= 8 then self:emitf("POP r%d, r15", i-1)
					else self:emit("POP r0, r15") end
				end
				if self.isLibrary then
					self:emit("GETPC r10")
					self:emitf("LOADI r9, %s - . + 4", e.func.name)
					self:emit("ADD r10, r10, r9")
					self:emit("CALLR r10")
				else
					self:emitf("CALL %s", e.func.name)
				end
			else
				self:genExpr(e.func)
				self:emit("PUSH r0, r15")

				for i=1,#e.args do
					self:genCallArgTyped(e.args[i])
					self:emit("PUSH r0, r15")
				end

				for i=#e.args, 1, -1 do
					if i <= 8 then self:emitf("POP r%d, r15", i-1)
					else self:emit("POP r0, r15") end
				end

				self:emit("POP r4, r15")
				self:emit("CALLR r4")
			end
		end
		if e.func.tag == "Ident" and self.funcs[e.func.name] then
			return self.funcs[e.func.name].retType or INT_TYPE
		end
		return INT_TYPE

	elseif e.tag == "Index" then
		self:genExpr(e.index)
		self:emit("PUSH r0, r15")
		local bt = self:genExprTyped(e.base)
		self:emit("POP r1, r15")
		if bt and bt.ptr and bt.ptr > 0 then
			local bsize = self:sizeOf({base=bt.base, ptr=bt.ptr-1})
			if bsize > 1 then
				self:emitLoadImm("r2", bsize)
				self:emit("MUL r1, r2, r1")
			end
		end
		self:emit("ADD r0, r0, r1")
		local elemType = INT_TYPE
		if bt and bt.ptr and bt.ptr > 0 then
			elemType = {base=bt.base, ptr=bt.ptr-1}
		end
		self:emit(self:loadInsnForType(elemType) .. " r0, r0")
		return elemType

	elseif e.tag == "Member" then
		local bt = self:genLValTyped(e)
		if self:isComposite(bt) or (bt and bt.arrDecay) then
			return bt
		end
		self:emit(self:loadInsnForType(bt) .. " r0, r0")
		return bt or INT_TYPE

	elseif e.tag == "Arrow" then
		local bt = self:genLValTyped(e)
		if self:isComposite(bt) or (bt and bt.arrDecay) then
			return bt
		end
		self:emit(self:loadInsnForType(bt) .. " r0, r0")
		return bt or INT_TYPE

	elseif e.tag == "PreInc" then
		local t = self:genLValTyped(e.expr)
		self:emit(self:loadInsnForType(t) .. " r1, r0")
		local incr = 1
		if t and t.ptr and t.ptr > 0 then
			incr = self:sizeOf({base=t.base, ptr=t.ptr-1})
		end
		self:emitAddImm("r1", "r1", incr)
		self:emit(self:storeInsnForType(t) .. " r0, r1")
		self:emit("MOV r0, r1")
		return t or INT_TYPE

	elseif e.tag == "PreDec" then
		local t = self:genLValTyped(e.expr)
		self:emit(self:loadInsnForType(t) .. " r1, r0")
		local decr = 1
		if t and t.ptr and t.ptr > 0 then
			decr = self:sizeOf({base=t.base, ptr=t.ptr-1})
		end
		self:emitSubImm("r1", "r1", decr)
		self:emit(self:storeInsnForType(t) .. " r0, r1")
		self:emit("MOV r0, r1")
		return t or INT_TYPE

	elseif e.tag == "PostInc" then
		local t = self:genLValTyped(e.expr)
		self:emit(self:loadInsnForType(t) .. " r1, r0")
		local incr = 1
		if t and t.ptr and t.ptr > 0 then
			incr = self:sizeOf({base=t.base, ptr=t.ptr-1})
		end
		self:emitAddImm("r2", "r1", incr)
		self:emit(self:storeInsnForType(t) .. " r0, r2")
		self:emit("MOV r0, r1")
		return t or INT_TYPE

	elseif e.tag == "PostDec" then
		local t = self:genLValTyped(e.expr)
		self:emit(self:loadInsnForType(t) .. " r1, r0")
		local decr = 1
		if t and t.ptr and t.ptr > 0 then
			decr = self:sizeOf({base=t.base, ptr=t.ptr-1})
		end
		self:emitSubImm("r2", "r1", decr)
		self:emit(self:storeInsnForType(t) .. " r0, r2")
		self:emit("MOV r0, r1")
		return t or INT_TYPE

	elseif e.tag == "SizeOfType" then
		self:emitLoadImm("r0", self:sizeOf(e.type))
		return INT_TYPE

	elseif e.tag == "SizeOfExpr" then
		local t = self:genExprTyped(e.expr)
		self:emitLoadImm("r0", self:sizeOf(t))
		return INT_TYPE

	elseif e.tag == "Cast" then
		self:genExprTyped(e.expr)
		return e.type or INT_TYPE

	elseif e.tag == "CompoundLiteral" then
		local typ = e.type
		local sz = self:sizeOf(typ)
		local totalBytes = math.max(4, alignUp(sz, 4))
		self:emitSubImm("r15", "r15", totalBytes)

		if self:isComposite(typ) then
			local sd = self.structs[self:compositeKey(typ)]
			if sd then
				local fieldIdx = 1
				for _, item in ipairs(e.init.items) do
					local fld, val
					if item.tag == "DesignatedInit" then
						val = item.value
						for j, f in ipairs(sd.fields) do
							if f.name == item.field then fld = f; fieldIdx = j + 1; break end
						end
					else
						fld = sd.fields[fieldIdx]
						val = item
						fieldIdx = fieldIdx + 1
					end
					if fld then
						self:genExpr(val)
						if fld.offset > 0 then
							self:emitAddImm("r1", "r15", fld.offset)
						else
							self:emit("MOV r1, r15")
						end
						self:emit(self:storeInsnForType(fld.type) .. " r1, r0")
					end
				end
			end
		else
			for i, item in ipairs(e.init.items) do
				self:genExpr(item)
				self:emitAddImm("r1", "r15", totalBytes - i + 1)
				self:emit("STORE r1, r0")
			end
		end
		self:emit("MOV r0, r15")
		return typ or INT_TYPE

	elseif e.tag == "Ternary" then
		local tL, eL = self:label(), self:label()
		self:genExprTyped(e.cond)
		self:emitf("JZ r0, %s", tL)
		local retType = self:genExprTyped(e.thenB)
		self:emitf("JMP %s", eL)
		self:emitf("%s:", tL)
		self:genExprTyped(e.elseB)
		self:emitf("%s:", eL)
		return retType

	elseif e.tag == "Comma" then
		self:genExpr(e.left)
		return self:genExprTyped(e.right)
	end
	return INT_TYPE
end

function CodeGen:genExpr(e)
	self:genExprTyped(e)
end

function CodeGen:genCallArgTyped(e)
	if e.tag == "Ident" then
		local info = self:lookup(e.name)
		if info and info.arr then
			self:genLValTyped(e)
			return {base=info.type.base, ptr=(info.type.ptr or 0) + 1}
		end
	end
	return self:genExprTyped(e)
end

--lvalue path leaves an address in r0
function CodeGen:genLVal(e)
	self:genLValTyped(e)
end

function CodeGen:genLValTyped(e)
	if e.tag == "Ident" then
		local info, isG = self:lookup(e.name)
		if not info then self:err(e, "Undefined: %s", e.name) end
		if isG then 
			if self.isLibrary then
				self:emit("GETPC r0")
				self:emitf("LOADI r1, %s - . + 4", e.name)
				self:emit("ADD r0, r0, r1")
			else
				self:emitf("LOADI r0, %s", e.name)
			end
		else
			if info.staticLabel then
				if self.isLibrary then
					self:emit("GETPC r0")
					self:emitf("LOADI r1, %s - . + 4", info.staticLabel)
					self:emit("ADD r0, r0, r1")
				else
					self:emitf("LOADI r0, %s", info.staticLabel)
				end
			elseif info.offset < 0 then
				self:emitFrameAddress("r0", "r14", info.offset)
			else
				self:emitFrameAddress("r0", "r14", info.offset)
			end
		end
		return info.type or INT_TYPE
	elseif e.tag == "Deref" then
		local t = self:genExprTyped(e.expr)
		if t and t.ptr and t.ptr > 0 then
			return {base=t.base, ptr=t.ptr-1}
		end
		return INT_TYPE
	elseif e.tag == "Index" then
		self:genExpr(e.index); self:emit("PUSH r0, r15")
		local bt = self:genExprTyped(e.base); self:emit("POP r1, r15")
		if bt and bt.ptr and bt.ptr > 0 then
			local bsize = self:sizeOf({base=bt.base, ptr=bt.ptr-1})
			if bsize > 1 then
				self:emitLoadImm("r2", bsize)
				self:emit("MUL r1, r2, r1")
			end
		end
		self:emit("ADD r0, r0, r1")
		if bt and bt.ptr and bt.ptr > 0 then
			return {base=bt.base, ptr=bt.ptr-1}
		end
		return INT_TYPE
	elseif e.tag == "Member" then
		local baseType = self:genLValTyped(e.base)
		if self:isComposite(baseType) then
			local sname = self:compositeKey(baseType)
			local off, ftype, farr = self:fieldInfo(e, sname, e.field)
			if off > 0 then
				self:emitAddImm("r0", "r0", off)
			end
			if farr then
				return {base=ftype.base, ptr=(ftype.ptr or 0) + 1, arrDecay=true}
			end
			return ftype or INT_TYPE
		else
			self:err(e, ".field: unknown struct type")
			return INT_TYPE
		end
	elseif e.tag == "Arrow" then
		local ptrType = self:genExprTyped(e.base)
		local key = ptrType and self:compositeKey(ptrType)
		if key and ptrType.ptr and ptrType.ptr > 0 then
			local off, ftype, farr = self:fieldInfo(e, key, e.field)
			if off > 0 then
				self:emitAddImm("r0", "r0", off)
			end
			if farr then
				return {base=ftype.base, ptr=(ftype.ptr or 0) + 1, arrDecay=true}
			end
			return ftype or INT_TYPE
		else
			self:err(e, "->field: unknown struct type or not a pointer")
			return INT_TYPE
		end
	else self:err(e, "Not an lvalue: %s", e.tag) end
end

--struct copies stay dumb on purpose
--whole words first, trailing bytes after, nothing fancy
function CodeGen:emitStructCopy(sizeBytes)
	local fullWords = math.floor(sizeBytes / 4)
	local remaining = sizeBytes % 4
	for i = 0, fullWords - 1 do
		local off = i * 4
		if off > 0 then
			self:emitAddImm("r2", "r1", off)
			self:emit("LOAD r3, r2")
			self:emitAddImm("r2", "r0", off)
			self:emit("STORE r2, r3")
		else
			self:emit("LOAD r3, r1")
			self:emit("STORE r0, r3")
		end
	end
	for j = 0, remaining - 1 do
		local off = fullWords * 4 + j
		self:emitAddImm("r2", "r1", off)
		self:emit("LOADB r3, r2")
		self:emitAddImm("r2", "r0", off)
		self:emit("STOREB r2, r3")
	end
end

--binary ops
function CodeGen:genBinOp(e)
	if e.op == "&&" then
		local fL,eL=self:label(),self:label()
		self:genExpr(e.left); self:emitf("JZ r0, %s",fL)
		self:genExpr(e.right); self:emitf("JZ r0, %s",fL)
		self:emitLoadImm("r0", 1); self:emitf("JMP %s",eL)
		self:emitf("%s:",fL); self:emitZero("r0"); self:emitf("%s:",eL)
		return INT_TYPE
	elseif e.op == "||" then
		local cR,eL=self:label(),self:label()
		self:genExpr(e.left); self:emitf("JZ r0, %s",cR)
		self:emitLoadImm("r0", 1); self:emitf("JMP %s",eL)
		self:emitf("%s:",cR); self:genExpr(e.right)
		self:emitf("JZ r0, %s", eL)
		self:emitLoadImm("r0", 1)
		self:emitf("%s:",eL)
		return INT_TYPE
	end

	local lt = self:genExprTyped(e.left); self:emit("PUSH r0, r15")
	local rt = self:genExprTyped(e.right); self:emit("POP r1, r15")

	if e.op=="+" then
		if lt and lt.ptr and lt.ptr > 0 and (not rt or not rt.ptr or rt.ptr == 0) then
			local sz = self:sizeOf({base=lt.base, ptr=lt.ptr-1})
			if sz > 1 then
				self:emitLoadImm("r2", sz)
				self:emit("MUL r0, r2, r0")
			end
		elseif rt and rt.ptr and rt.ptr > 0 and (not lt or not lt.ptr or lt.ptr == 0) then
			local sz = self:sizeOf({base=rt.base, ptr=rt.ptr-1})
			if sz > 1 then
				self:emitLoadImm("r2", sz)
				self:emit("MUL r1, r2, r1")
			end
			lt = rt
		end
		self:emit("ADD r0, r1, r0")
		return lt or INT_TYPE
	elseif e.op=="-" then
		if lt and lt.ptr and lt.ptr > 0 and (not rt or not rt.ptr or rt.ptr == 0) then
			local sz = self:sizeOf({base=lt.base, ptr=lt.ptr-1})
			if sz > 1 then
				self:emitLoadImm("r2", sz)
				self:emit("MUL r0, r2, r0")
			end
			self:emit("SUB r0, r1, r0")
			return lt
		elseif lt and lt.ptr and lt.ptr > 0 and rt and rt.ptr and rt.ptr > 0 then
			self:emit("SUB r0, r1, r0")
			local sz = self:sizeOf({base=lt.base, ptr=lt.ptr-1})
			if sz > 1 then
				self:emitLoadImm("r2", sz)
				self:emit("DIV r0, r0, r2")
			end
			return INT_TYPE
		end
		self:emit("SUB r0, r1, r0")
		return lt or INT_TYPE
	elseif e.op=="*" then self:emit("MUL r0, r1, r0"); return INT_TYPE
	elseif e.op=="/" then self:emit("DIV r0, r1, r0"); return INT_TYPE
	elseif e.op=="%" then self:emit("MOD r0, r1, r0"); return INT_TYPE
	elseif e.op=="&" then self:emit("AND r0, r1, r0"); return INT_TYPE
	elseif e.op=="|" then self:emit("OR r0, r1, r0"); return INT_TYPE
	elseif e.op=="^" then self:emit("XOR r0, r1, r0"); return INT_TYPE
	elseif e.op=="<<" then self:emit("SHL r0, r1, r0"); return INT_TYPE
	elseif e.op==">>" then self:emit("ASHR r0, r1, r0"); return INT_TYPE
	elseif e.op=="==" then self:emit("CMPEQ r0, r1, r0"); return INT_TYPE
	elseif e.op=="!=" then
		self:emit("CMPEQ r0, r1, r0")
		local tL,dL=self:label(),self:label()
		self:emitf("JZ r0, %s",tL); self:emitZero("r0"); self:emitf("JMP %s",dL)
		self:emitf("%s:",tL); self:emitLoadImm("r0", 1); self:emitf("%s:",dL)
	elseif e.op=="<" then self:emit("CMPLT r0, r1, r0")
	elseif e.op==">" then self:emit("CMPGT r0, r1, r0")
	elseif e.op=="<=" then
		self:emit("CMPGT r0, r1, r0")
		local tL,dL=self:label(),self:label()
		self:emitf("JZ r0, %s",tL); self:emitZero("r0"); self:emitf("JMP %s",dL)
		self:emitf("%s:",tL); self:emitLoadImm("r0", 1); self:emitf("%s:",dL)
	elseif e.op==">=" then
		self:emit("CMPLT r0, r1, r0")
		local tL,dL=self:label(),self:label()
		self:emitf("JZ r0, %s",tL); self:emitZero("r0"); self:emitf("JMP %s",dL)
		self:emitf("%s:",tL); self:emitLoadImm("r0", 1); self:emitf("%s:",dL)
	end
end

return CodeGen
