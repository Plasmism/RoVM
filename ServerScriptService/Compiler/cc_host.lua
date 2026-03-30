--!native
local CCHost = {}

--preprocessor first
local function evalPPExpr(expr, macros)
	expr = expr:match("^%s*(.-)%s*$")

	--handle both defined(x) and defined x
	local d = expr:match("^defined%s*%(([%w_]+)%)$")
	if d then return macros[d] ~= nil end
	d = expr:match("^!%s*defined%s*%(([%w_]+)%)$")
	if d then return macros[d] == nil end
	d = expr:match("^defined%s+([%w_]+)$")
	if d then return macros[d] ~= nil end

	--object macros get expanded before the expression test or #if math starts lying
	for mn, m in pairs(macros) do
		if m.type == "obj" then
			local mv = m.val
			expr = expr:gsub("([^%w_])" .. mn .. "([^%w_])", "%1" .. mv .. "%2")
			expr = expr:gsub("^" .. mn .. "([^%w_])", mv .. "%1")
			expr = expr:gsub("([^%w_])" .. mn .. "$", "%1" .. mv)
			if expr == mn then expr = mv end
		end
	end

	--anything still looking like an identifier becomes 0. rude, but close enough to c
	expr = expr:gsub("[%a_][%w_]*", "0")

	local n = tonumber(expr)
	if n then return n ~= 0 end

	return false
end

function CCHost.preprocess(source, resolveInclude, macros, filename)
	filename = filename or "main.c"
	macros = macros or {}
	local result = { ("#line 1 %q"):format(filename) }

	--condstack entries are {taken=bool, outerskip=bool}
	--blank lines below are deliberate so diagnostics still point at the original source lines
	local condStack = {}
	local skipLevel = 0
	local lineNum = 0

	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		lineNum = lineNum + 1
		local trimmed = line:match("^%s*(.-)%s*$")

		--keep #if #ifdef and #ifndef on one path
		local ifExpr = trimmed:match("^#if%s+(.+)")
		local ifdefName = trimmed:match("^#ifdef%s+([%w_]+)")
		local ifndefName = trimmed:match("^#ifndef%s+([%w_]+)")

		if ifExpr or ifdefName or ifndefName then
			if skipLevel > 0 then
				skipLevel = skipLevel + 1
				table.insert(condStack, {taken=false, outerSkip=true})
			else
				local cond = false
				if ifdefName then
					cond = macros[ifdefName] ~= nil
				elseif ifndefName then
					cond = macros[ifndefName] == nil
				else
					cond = evalPPExpr(ifExpr, macros)
				end
				table.insert(condStack, {taken=cond, outerSkip=false})
				if not cond then skipLevel = 1 end
			end
			table.insert(result, "")

		elseif trimmed:match("^#elif%s+(.+)") then
			if #condStack > 0 then
				local entry = condStack[#condStack]
				if entry.outerSkip then
					--nested inside a skipped block. ignore it and keep walking.
				elseif entry.taken then
					if skipLevel == 0 then skipLevel = 1 end
				else
					local cond = evalPPExpr(trimmed:match("^#elif%s+(.+)"), macros)
					if cond then
						skipLevel = 0
						entry.taken = true
					end
				end
			end
			table.insert(result, "")

		elseif trimmed:match("^#else") then
			if #condStack > 0 then
				local entry = condStack[#condStack]
				if entry.outerSkip then
					--nested. ignore it.
				elseif entry.taken then
					if skipLevel == 0 then skipLevel = 1 end
				else
					skipLevel = 0
					entry.taken = true
				end
			end
			table.insert(result, "")

		elseif trimmed:match("^#endif") then
			if #condStack > 0 then
				local entry = table.remove(condStack)
				if entry.outerSkip then
					skipLevel = skipLevel - 1
				else
					skipLevel = 0
				end
			end
			table.insert(result, "")

		elseif skipLevel == 0 then
			if trimmed:match("^#define%s+([%w_]+)%(([^)]*)%)%s*(.*)") then
				local name, argstr, val = trimmed:match("^#define%s+([%w_]+)%(([^)]*)%)%s*(.*)")
				local args = {}
				for a in argstr:gmatch("([%w_]+)") do table.insert(args, a) end
				macros[name] = {type="func", args=args, val=val}
				table.insert(result, "")
			elseif trimmed:match("^#define%s+([%w_]+)%s*(.*)") then
				local name, val = trimmed:match("^#define%s+([%w_]+)%s*(.*)")
				macros[name] = {type="obj", val=val}
				table.insert(result, "")
			elseif trimmed:match("^#undef%s+([%w_]+)") then
				local name = trimmed:match("^#undef%s+([%w_]+)")
				macros[name] = nil
				table.insert(result, "")
			elseif trimmed:match('^#include%s*([<"][^">]+[">])') then
				local inc = trimmed:match('^#include%s*([<"][^">]+[">])')
				if resolveInclude then
					local content = resolveInclude(inc)
					if content then
						--strip delimiters so the fake filename looks normal again
						local cleanInc = inc:gsub('^[<"]', ''):gsub('[>"]$', '')
						table.insert(result, CCHost.preprocess(content, resolveInclude, macros, cleanInc))
						--jump back to the parent file and the next real line after the include
						table.insert(result, ("#line %d %q"):format(lineNum + 1, filename))
					else
						error(string.format("%s:%d: error: missing include: %s", filename, lineNum, inc))
					end
				else
					table.insert(result, "")
				end
			elseif trimmed:match("^#") then
				--ignore other directives for now. not ideal, still survivable.
				table.insert(result, "")
			else
				local out = line
				local changed = true
				local pass = 0
				while changed and pass < 8 do
					changed = false
					pass = pass + 1
					--object macros first
					for mn, m in pairs(macros) do
						if m.type == "obj" then
							local old = out
							local mv = m.val
							out = out:gsub("([^%w_])" .. mn .. "([^%w_])", "%1" .. mv .. "%2")
							out = out:gsub("^" .. mn .. "([^%w_])", mv .. "%1")
							out = out:gsub("([^%w_])" .. mn .. "$", "%1" .. mv)
							if out == mn then out = mv end
							if out ~= old then changed = true end
						end
					end
					--function macros after that. yeah this is a lot.
					for mn, m in pairs(macros) do
						if m.type == "func" then
							local startSearch = 1
							while true do
								local ms, me = out:find("([^%w_])" .. mn .. "%s*%(", startSearch)
								local nameStart = ms and ms + 1 or nil
								if not ms then
									ms, me = out:find("^" .. mn .. "%s*%(", startSearch)
									nameStart = ms
								end
								if not ms then break end
								
								local openPos = out:find("%(", me - 1)
								local level = 0
								local closePos = nil
								for i = openPos + 1, #out do
									local c = out:sub(i,i)
									if c == "(" then level = level + 1
									elseif c == ")" then
										if level == 0 then closePos = i; break end
										level = level - 1
									end
								end
								
								if closePos then
									local argstr = out:sub(openPos + 1, closePos - 1)
									local args = {}
									local curr = ""
									local argL = 0
									for i = 1, #argstr do
										local c = argstr:sub(i,i)
										if c == "(" then argL = argL + 1; curr = curr .. c
										elseif c == ")" then argL = argL - 1; curr = curr .. c
										elseif c == "," and argL == 0 then
											table.insert(args, curr:match("^%s*(.-)%s*$"))
											curr = ""
										else curr = curr .. c end
									end
									table.insert(args, curr:match("^%s*(.-)%s*$"))
									
									local ev = m.val
									for i, an in ipairs(m.args) do
										local val = args[i] or ""
										ev = ev:gsub("([^%w_])" .. an .. "([^%w_])", "%1" .. val .. "%2")
										ev = ev:gsub("^" .. an .. "([^%w_])", val .. "%1")
										ev = ev:gsub("([^%w_])" .. an .. "$", "%1" .. val)
										if ev == an then ev = val end
									end
									
									out = out:sub(1, nameStart - 1) .. ev .. out:sub(closePos + 1)
									changed = true
									startSearch = nameStart + #ev
								else
									startSearch = me + 1
								end
							end
						end
					end
				end
				table.insert(result, out)
			end
		else
			--still skipping, so emit a blank line and move on
			table.insert(result, "")
		end
	end
	return table.concat(result, "\n")
end

--lexer pass
local KEYWORDS = {
	["int"]=true,["char"]=true,["void"]=true,["struct"]=true,["union"]=true,
	["if"]=true,["else"]=true,["while"]=true,["for"]=true,["do"]=true,
	["return"]=true,["break"]=true,["continue"]=true,
	["switch"]=true,["case"]=true,["default"]=true,["goto"]=true,
	["sizeof"]=true,["enum"]=true,["typedef"]=true,
	["const"]=true,["unsigned"]=true,["signed"]=true,["long"]=true,["short"]=true,
	["static"]=true,["extern"]=true,["export"]=true
}
local TWO_CHAR = {
	["=="]=true,["!="]=true,["<="]=true,[">="]=true,
	["&&"]=true,["||"]=true,["->"]=true,["++"]=true,
	["--"]=true,["+="]=true,["-="]=true,["*="]=true,["/="]=true,
	["%="]=true,["&="]=true,["|="]=true,["^="]=true,
	["<<"]=true,[">>"]=true
}
local THREE_CHAR = {
	["<<="]=true, [">>="]=true, ["..."]=true
}

function CCHost.tokenize(source)
	local tokens = {}
	local pos, line, col = 1, 1, 1
	local file = "main.c"
	local len = #source
	while pos <= len do
		local c = source:sub(pos,pos)
		
		--handle #line markers before normal lexing kicks in
		if col == 1 and c == "#" then
			local lNum, lFile = source:sub(pos, pos + 200):match("^#line%s+(%d+)%s+\"([^\"]+)\"")
			if lNum and lFile then
				line = tonumber(lNum)
				file = lFile
				--skip to newline and carry on
				local nextNL = source:find("\n", pos)
				if nextNL then
					pos = nextNL + 1
				else
					pos = len + 1
				end
				continue
			end
		end

		if c == "\n" then
			pos=pos+1; line=line+1; col=1
		elseif c:match("%s") then
			pos=pos+1; col=col+1
		elseif source:sub(pos,pos+1) == "//" then
			while pos<=len and source:sub(pos,pos)~="\n" do pos=pos+1 end
		elseif source:sub(pos,pos+1) == "/*" then
			pos=pos+2
			while pos<=len and source:sub(pos,pos+1)~="*/" do
				if source:sub(pos,pos)=="\n" then line=line+1; col=1 else col=col+1 end
				pos=pos+1
			end
			pos=pos+2; col=col+2
		elseif THREE_CHAR[source:sub(pos,pos+2)] then
			table.insert(tokens,{type="Punct",value=source:sub(pos,pos+2),line=line,col=col,file=file})
			pos=pos+3; col=col+3
		elseif TWO_CHAR[source:sub(pos,pos+1)] then
			table.insert(tokens,{type="Punct",value=source:sub(pos,pos+1),line=line,col=col,file=file})
			pos=pos+2; col=col+2
		elseif c:match("[%+%-%*/%%=<>!&|;,:%?%(%)%{%}%[%]%.^~]") then
			table.insert(tokens,{type="Punct",value=c,line=line,col=col,file=file})
			pos=pos+1; col=col+1
		elseif c:match("[%a_]") then
			local s=pos
			while pos<=len and source:sub(pos,pos):match("[%w_]") do pos=pos+1 end
			local w=source:sub(s,pos-1)
			table.insert(tokens,{type=KEYWORDS[w] and "Keyword" or "Ident",value=w,line=line,col=col,file=file})
			col=col+(pos-s)
		elseif c:match("%d") then
			local s=pos
			if source:sub(pos,pos+1):match("0[xX]") then
				pos=pos+2
				while pos<=len and source:sub(pos,pos):match("[%da-fA-F]") do pos=pos+1 end
			else
				while pos<=len and source:sub(pos,pos):match("%d") do pos=pos+1 end
			end
			--eat the optional number suffix too
			while pos<=len and source:sub(pos,pos):match("[uUlL]") do pos=pos+1 end
			local numStr = source:sub(s,pos-1):gsub("[uUlL]+$","")
			local val
			if numStr:sub(1,2):lower() == "0x" then
				val = tonumber(numStr:sub(3), 16)
			else
				val = tonumber(numStr)
			end
			if val == nil then val = 0 end
			table.insert(tokens,{type="Number",value=val,line=line,col=col,file=file})
			col=col+(pos-s)
		elseif c=="'" then
			local startCol = col
			pos=pos+1; col=col+1
			local ch
			if source:sub(pos,pos)=="\\" then
				pos=pos+1; col=col+1; local e=source:sub(pos,pos)
				ch=e=="n" and 10 or e=="t" and 9 or e=="r" and 13 or e=="0" and 0 or e=="\\" and 92 or e=="'" and 39 or string.byte(e)
			else ch=string.byte(source:sub(pos,pos)) end
			pos=pos+1; col=col+1
			if source:sub(pos,pos)=="'" then pos=pos+1; col=col+1 end
			table.insert(tokens,{type="Number",value=ch,line=line,col=startCol,file=file})
		elseif c=='"' then
			local startCol = col
			pos=pos+1; col=col+1
			local parts={}
			while pos<=len and source:sub(pos,pos)~='"' do
				local sc=source:sub(pos,pos)
				if sc=="\\" then
					pos=pos+1; col=col+1; sc=source:sub(pos,pos)
					if sc=="n" then sc="\n" elseif sc=="t" then sc="\t"
					elseif sc=="r" then sc="\r" elseif sc=="0" then sc="\0"
					elseif sc=="\\" then sc="\\" elseif sc=='"' then sc='"'
					end
				end
				table.insert(parts,sc); pos=pos+1; col=col+1
			end
			pos=pos+1; col=col+1
			table.insert(tokens,{type="String",value=table.concat(parts),line=line,col=startCol,file=file})
		else
			error(string.format("%s:%d:%d: Unexpected '%s'", file, line, col, c))
		end
	end
	table.insert(tokens,{type="EOF",value="",line=line,col=col,file=file})
	return tokens
end

--parser pass
local TYPE_KEYWORDS = {
	int=true, char=true, void=true, struct=true, union=true, enum=true,
	const=true, unsigned=true, signed=true, long=true, short=true,
	static=true, extern=true, export=true
}

function CCHost.parse(tokens)
	local p={tokens=tokens,pos=1,typedefs={}}
	function p:cur() return self.tokens[self.pos] end
	function p:adv() local t=self.tokens[self.pos]; self.pos=self.pos+1; return t end
	function p:peek(off) return self.tokens[self.pos + (off or 1)] end
	function p:expect(tp,val)
		local t=self:cur()
		if t.type~=tp or (val and t.value~=val) then
			error(string.format("%s:%d:%d: Expected %s '%s' got %s '%s'", t.file or "main.c", t.line, t.col, tp, val or"?", t.type, tostring(t.value)))
		end
		return self:adv()
	end
	function p:node(data)
		local t = self:cur()
		data.line = t.line
		data.col = t.col
		data.file = t.file
		return data
	end
	function p:match(tp,val)
		local t=self:cur()
		if t.type==tp and (not val or t.value==val) then return self:adv() end
	end
	function p:isType()
		local t=self:cur()
		return (t.type=="Keyword" and TYPE_KEYWORDS[t.value]) or (self.typedefs[t.value] ~= nil)
	end

	function p:parseType()
		local isStatic, isExtern, isConst, isExport = false, false, false, false
		local isUnsigned, isSigned = false, false
		local isShort, isLong = false, false
		local base = nil
		local ptr = 0

		--collect all specifiers first. c lets them show up in almost any order
		local consumed = false
		while true do
			local t = self:cur()
			if t.type ~= "Keyword" then break end
			local v = t.value
			if v == "static" then isStatic = true; self:adv(); consumed = true
			elseif v == "extern" then isExtern = true; self:adv(); consumed = true
			elseif v == "export" then isExport = true; self:adv(); consumed = true
			elseif v == "const" then isConst = true; self:adv(); consumed = true
			elseif v == "unsigned" then isUnsigned = true; self:adv(); consumed = true
			elseif v == "signed" then isSigned = true; self:adv(); consumed = true
			elseif v == "short" then isShort = true; self:adv(); consumed = true
			elseif v == "long" then isLong = true; self:adv(); consumed = true
			elseif v == "int" then base = "int"; self:adv(); consumed = true; break
			elseif v == "char" then base = "char"; self:adv(); consumed = true; break
			elseif v == "void" then base = "void"; self:adv(); consumed = true; break
			elseif v == "struct" then
				self:adv()
				if self:cur().type == "Ident" then
					base = "struct:" .. self:adv().value
				elseif self:cur().value == "{" then
					base = "struct:__anon_" .. self.pos
				end
				consumed = true; break
			elseif v == "union" then
				self:adv()
				if self:cur().type == "Ident" then
					base = "union:" .. self:adv().value
				elseif self:cur().value == "{" then
					base = "union:__anon_" .. self.pos
				end
				consumed = true; break
			elseif v == "enum" then
				self:adv(); if self:cur().type=="Ident" then self:adv() end
				base = "int"; consumed = true; break
			else break end
		end

		--eat extra type keywords that trail after the base
		while self:cur().type == "Keyword" do
			local v = self:cur().value
			if v == "int" then base = base or "int"; self:adv()
			elseif v == "long" then isLong = true; self:adv()
			elseif v == "short" then isShort = true; self:adv()
			elseif v == "unsigned" then isUnsigned = true; self:adv()
			elseif v == "signed" then isSigned = true; self:adv()
			elseif v == "const" then isConst = true; self:adv()
			else break end
		end

		--typedef names get resolved here
		if not base and not consumed then
			local t = self:cur()
			if t.type == "Ident" and self.typedefs[t.value] then
				local td = self.typedefs[self:adv().value]
				base = td.base
				ptr = td.ptr or 0
			else
				if isShort or isLong or isUnsigned or isSigned then
					base = "int"
				else
					return nil
				end
			end
		end

		--collapse the modifier soup into one final base type
		if not base then
			if isShort then base = "short"
			elseif isLong then base = "long"
			else base = "int" end
		else
			if isShort and base == "int" then base = "short"
			elseif isLong and base == "int" then base = "long" end
		end

		--trailing const still counts
		while self:cur().type=="Keyword" and self:cur().value=="const" do self:adv() end

		--pointer levels
		while self:match("Punct","*") do
			ptr = ptr + 1
			while self:cur().type=="Keyword" and (self:cur().value=="const" or self:cur().value=="volatile") do self:adv() end
		end

		return {base=base, ptr=ptr, isStatic=isStatic, isExtern=isExtern, isExport=isExport}
	end

	--array dim helpers. supports multi dim and empty []
	function p:evalConstExpr(expr)
		if not expr then return nil end
		if expr.tag == "Num" then
			return expr.value
		end
		if expr.tag == "UnaryOp" then
			local value = self:evalConstExpr(expr.expr)
			if value == nil then return nil end
			if expr.op == "+" then return value end
			if expr.op == "-" then return -value end
			if expr.op == "~" then return bit32.bnot(value) end
			return nil
		end
		if expr.tag == "BinOp" then
			local left = self:evalConstExpr(expr.left)
			local right = self:evalConstExpr(expr.right)
			if left == nil or right == nil then return nil end
			if expr.op == "+" then return left + right end
			if expr.op == "-" then return left - right end
			if expr.op == "*" then return left * right end
			if expr.op == "/" then
				if right == 0 then return nil end
				return math.floor(left / right)
			end
			if expr.op == "%" then
				if right == 0 then return nil end
				return left % right
			end
			if expr.op == "<<" then return bit32.lshift(left, right) end
			if expr.op == ">>" then return bit32.arshift(left, right) end
			if expr.op == "&" then return bit32.band(left, right) end
			if expr.op == "|" then return bit32.bor(left, right) end
			if expr.op == "^" then return bit32.bxor(left, right) end
			return nil
		end
		return nil
	end

	function p:parseArrayDims()
		local arr = nil
		while self:cur().value == "[" do
			self:adv()
			if self:cur().value == "]" then
				arr = arr or -1
				self:adv()
			else
				local dim = self:parseExpr()
				local dimVal = self:evalConstExpr(dim)
				if dimVal == nil then
					local t = self:cur()
					error(string.format("%s:%d:%d: array size must be an integer constant expression", t.file or "main.c", t.line, t.col))
				end
				if dimVal <= 0 then
					local t = self:cur()
					error(string.format("%s:%d:%d: array size must be positive", t.file or "main.c", t.line, t.col))
				end
				arr = (arr and arr > 0) and (arr * dimVal) or dimVal
				self:expect("Punct", "]")
			end
		end
		return arr
	end

	--turn char array string init into a byte initlist now so codegen has less drama later
	function p:resolveArrayInit(typ, arr, init)
		if arr and init and init.tag == "Str" and typ.base == "char" and typ.ptr == 0 then
			local items = {}
			for i = 1, #init.value do
				items[#items+1] = {tag="Num", value=string.byte(init.value, i)}
			end
			items[#items+1] = {tag="Num", value=0}
			init = {tag="InitList", items=items}
			if arr == -1 then arr = #items end
		end
		if arr == -1 and init and init.tag == "InitList" then
			arr = #init.items
		end
		if arr == -1 then arr = 1 end
		return arr, init
	end

	--top level parse loop
	function p:parseProgram()
		local decls={}
		local function addDecl(d)
			if d.tag == "MultiDecl" then
				for _, v in ipairs(d.decls) do table.insert(decls, v) end
			else
				table.insert(decls, d)
			end
		end

		while self:cur().type~="EOF" do
			local cv = self:cur().value

			if cv=="struct" or cv=="union" then
				local saved=self.pos
				local isUnion = cv == "union"
				self:adv()
				if self:cur().type == "Ident" then
					local nm = self:adv().value
					if self:cur().value=="{" then
						self.pos=saved; addDecl(self:parseStructDef())
					elseif self:cur().value==";" then
						self:adv() --forward declaration, eat the ; and move on
					else
						self.pos=saved; addDecl(self:parseFuncOrGlobal())
					end
				elseif self:cur().value == "{" then
					self.pos=saved; addDecl(self:parseStructDef())
				else
					self.pos=saved; addDecl(self:parseFuncOrGlobal())
				end
			elseif cv=="enum" then
				local saved=self.pos; self:adv()
				if self:cur().type=="Ident" then self:adv() end
				if self:cur().value=="{" then
					self.pos=saved; addDecl(self:parseEnumDef())
				else self.pos=saved; addDecl(self:parseFuncOrGlobal()) end
			elseif cv=="typedef" then
				self:parseTypedef()
			else addDecl(self:parseFuncOrGlobal()) end
		end
		return {tag="Program",decls=decls}
	end

	function p:parseStructDef()
		local isUnion = self:cur().value == "union"
		self:adv() --eat struct or union
		local name
		if self:cur().type == "Ident" then name = self:adv().value end
		self:expect("Punct","{")
		local fields={}
		while not self:match("Punct","}") do
			--anonymous nested struct or union
			if self:cur().value == "struct" or self:cur().value == "union" then
				local saved = self.pos
				local nestedUnion = self:cur().value == "union"
				self:adv()
				if self:cur().value == "{" or (self:cur().type == "Ident" and self:peek().value == "{") then
					self.pos = saved
					local nested = self:parseStructDef()
					--no field name means it is anonymous, so flatten the fields
					if self:cur().value == ";" then
						self:adv()
						--tag it so codegen can deal with it later
						table.insert(fields, {name="__anon", type={base=(nestedUnion and "union:" or "struct:") .. (nested.name or ("__anon_"..#fields)), ptr=0}, nested=nested})
					else
						local fn = self:expect("Ident").value
						local arr = self:parseArrayDims()
						self:expect("Punct",";")
						table.insert(fields, {name=fn, type={base=(nestedUnion and "union:" or "struct:") .. (nested.name or ("__anon_"..#fields)), ptr=0}, arr=arr, nested=nested})
					end
					continue
				else
					self.pos = saved
				end
			end

			local ft=self:parseType()
			local fn=self:expect("Ident").value
			local arr = self:parseArrayDims()
			--bitfield: parse it, ignore width for now, keep moving
			if self:match("Punct",":") then
				self:expect("Number") --eat width
			end
			self:expect("Punct",";")
			table.insert(fields,{name=fn,type=ft,arr=arr})
		end
		--optional ; after the closing brace. top level defs have it, nested ones get flaky.
		self:match("Punct",";")
		return {tag="StructDef",name=name or ("__anon_"..self.pos),fields=fields,isUnion=isUnion}
	end

	function p:parseEnumDef()
		self:expect("Keyword","enum"); local name
		if self:cur().type=="Ident" then name=self:adv().value end
		self:expect("Punct","{"); local items={}
		local nextVal = 0
		while not self:match("Punct","}") do
			local iname = self:expect("Ident").value
			local val = nextVal
			if self:match("Punct","=") then
				local expr = self:parseExpr()
				items[iname] = expr
				val = nil
			else
				items[iname] = {tag="Num", value=val}
				nextVal = nextVal + 1
			end
			if not self:match("Punct",",") then
				self:expect("Punct","}")
				break
			end
		end
		self:expect("Punct",";")
		return {tag="EnumDef", name=name, items=items}
	end

	function p:parseTypedef()
		self:expect("Keyword","typedef")

		--handle typedef struct { ... } Name;
		if self:cur().value == "struct" or self:cur().value == "union" then
			local saved = self.pos
			local isU = self:cur().value == "union"
			self:adv()
			if self:cur().type == "Ident" and self:peek().value == "{" then
				self.pos = saved
				local sd = self:parseStructDef()
				local tdName = self:expect("Ident").value
				self:expect("Punct", ";")
				self.typedefs[tdName] = {base=(isU and "union:" or "struct:")..sd.name, ptr=0}
				return
			elseif self:cur().value == "{" then
				self.pos = saved
				local sd = self:parseStructDef()
				local tdName = self:expect("Ident").value
				self:expect("Punct", ";")
				self.typedefs[tdName] = {base=(isU and "union:" or "struct:")..sd.name, ptr=0}
				return
			else
				self.pos = saved
			end
		end

		local typ = self:parseType()
		local name = self:expect("Ident").value
		self:expect("Punct",";")
		self.typedefs[name] = typ
	end

	function p:parseFuncOrGlobal()
		local typ=self:parseType()
		if not typ then
			local t = self:cur()
			error(string.format("%s:%d:%d: Expected type specifier got %s '%s'", t.file or "main.c", t.line, t.col, t.type, tostring(t.value)))
		end
		local name

		if self:match("Punct","(") and self:match("Punct","*") then
			name=self:expect("Ident").value
			self:expect("Punct",")"); self:expect("Punct","(")
			while not self:match("Punct",")") do self:adv() end
			typ.ptr = (typ.ptr or 0) + 1
		else
			name=self:expect("Ident").value
		end
		if self:match("Punct","(") then
			local params={}
			local isVariadic = false
			if not self:match("Punct",")") then
				repeat
					--check for variadic ... before normal params
					if self:cur().value == "..." then
						self:adv()
						isVariadic = true
						break
					end
					local pt=self:parseType()
					if not pt then break end
					--void as the only parameter means no params.
					if pt.base == "void" and pt.ptr == 0 and self:cur().value == ")" then break end
					local pn
					if self:match("Punct","(") and self:match("Punct","*") then
						pn=self:expect("Ident").value
						self:expect("Punct",")"); self:expect("Punct","(")
						while not self:match("Punct",")") do self:adv() end
						pt.ptr = (pt.ptr or 0) + 1
					else
						if self:cur().type == "Ident" then
							pn=self:adv().value
						else
							pn = "_p" .. #params
						end
					end
					--eat array dims on params so int arr[] doesnt get silly
					if self:cur().value == "[" then
						while self:match("Punct","[") do
							while self:cur().value ~= "]" do self:adv() end
							self:expect("Punct","]")
						end
						pt.ptr = (pt.ptr or 0) + 1
					end
					table.insert(params,{name=pn,type=pt})
				until not self:match("Punct",",")
				self:expect("Punct",")")
			end
			if self:match("Punct",";") then
				return {tag="FuncDecl",name=name,retType=typ,params=params,isStatic=typ.isStatic,isExport=typ.isExport,isVariadic=isVariadic}
			end
			return {tag="FuncDef",name=name,retType=typ,params=params,body=self:parseBlock(),isStatic=typ.isStatic,isExport=typ.isExport,isVariadic=isVariadic}
		end

		--variable declarations, maybe several at once
		local decls = {}
		while true do
			local arr = self:parseArrayDims()
			local init; if self:match("Punct","=") then
				if self:cur().value=="{" then init=self:parseInitList() else init=self:parseExpr() end
			end
			arr, init = self:resolveArrayInit(typ, arr, init)
			table.insert(decls, {tag="VarDecl",name=name,type=typ,arr=arr,init=init,global=true,isStatic=typ.isStatic,isExtern=typ.isExtern})

			if self:match("Punct",",") then
				if self:match("Punct","(") and self:match("Punct","*") then
					name=self:expect("Ident").value
					self:expect("Punct",")"); self:expect("Punct","(")
					while not self:match("Punct",")") do self:adv() end
					typ = {base=typ.base, ptr=(typ.ptr or 0)+1, isStatic=typ.isStatic, isExtern=typ.isExtern}
				else
					--reset pointer level for the next declarator
					local ptr = 0
					while self:match("Punct","*") do ptr = ptr + 1 end
					name=self:expect("Ident").value
					if ptr > 0 then
						typ = {base=typ.base, ptr=ptr, isStatic=typ.isStatic, isExtern=typ.isExtern}
					end
				end
			else
				break
			end
		end
		self:expect("Punct",";")

		if #decls == 1 then return decls[1] end
		return {tag="MultiDecl",decls=decls}
	end

	function p:parseInitList()
		self:expect("Punct","{"); local items={}
		if not self:match("Punct","}") then
			repeat
				--designated initializer: .field = value
				if self:cur().value == "." and self:peek().type == "Ident" then
					self:adv() --eat .
					local field = self:expect("Ident").value
					self:expect("Punct","=")
					local val
					if self:cur().value == "{" then val = self:parseInitList()
					else val = self:parseAssign() end
					table.insert(items, {tag="DesignatedInit", field=field, value=val})
					--array designator [n] = value. parse the index, then ignore it for now.
				elseif self:cur().value == "[" then
					self:adv()
					local idx = self:parseExpr()
					self:expect("Punct","]")
					self:expect("Punct","=")
					local val
					if self:cur().value == "{" then val = self:parseInitList()
					else val = self:parseAssign() end
					table.insert(items, val) --still ignoring the explicit index for now
				else
					if self:cur().value == "{" then
						table.insert(items, self:parseInitList())
					else
						table.insert(items, self:parseAssign())
					end
				end
			until not self:match("Punct",",")
			self:match("Punct","}") --allow trailing comma
		end
		return {tag="InitList",items=items}
	end

	--statements
	function p:parseBlock()
		self:expect("Punct","{"); local stmts={}
		while not self:match("Punct","}") do table.insert(stmts,self:parseStmt()) end
		return {tag="Block",stmts=stmts}
	end
	function p:parseStmt()
		local t=self:cur()
		if t.value==";" then self:adv(); return self:node({tag="Empty"}) end
		if t.value=="{" then return self:parseBlock() end
		if t.value=="return" then
			local start = self:node({})
			self:adv(); local e; if self:cur().value~=";" then e=self:parseExpr() end
			self:expect("Punct",";")
			start.tag = "Return"
			start.expr = e
			return start
		end
		if t.value=="if" then
			local start = self:node({})
			self:adv(); self:expect("Punct","("); local c=self:parseExpr(); self:expect("Punct",")")
			local th=self:parseStmt(); local el; if self:match("Keyword","else") then el=self:parseStmt() end
			start.tag = "If"
			start.cond = c
			start.thenB = th
			start.elseB = el
			return start
		end
		if t.value=="while" then
			local start = self:node({})
			self:adv(); self:expect("Punct","("); local c=self:parseExpr(); self:expect("Punct",")")
			start.tag = "While"
			start.cond = c
			start.body = self:parseStmt()
			return start
		end
		if t.value=="do" then
			local start = self:node({})
			self:adv(); local b=self:parseStmt()
			self:expect("Keyword","while"); self:expect("Punct","("); local c=self:parseExpr(); self:expect("Punct",")"); self:expect("Punct",";")
			start.tag = "DoWhile"
			start.cond = c
			start.body = b
			return start
		end
		if t.value=="for" then
			local start = self:node({})
			self:adv(); self:expect("Punct","(")
			local init; if self:cur().value~=";" then
				if self:isType() then init=self:parseLocalDecl() else init=self:parseExpr(); self:expect("Punct",";") end
			else self:adv(); init=self:node({tag="Empty"}) end
			local cond; if self:cur().value~=";" then cond=self:parseExpr() end; self:expect("Punct",";")
			local upd; if self:cur().value~=")" then upd=self:parseExpr() end; self:expect("Punct",")")
			start.tag = "Block"
			start.stmts = {init, self:node({tag="For",init=self:node({tag="Empty"}),cond=cond,upd=upd,body=self:parseStmt()})}
			return start
		end
		if t.value=="switch" then
			local start = self:node({})
			self:adv(); self:expect("Punct","("); local c=self:parseExpr(); self:expect("Punct",")")
			start.tag = "Switch"
			start.cond = c
			start.body = self:parseStmt()
			return start
		end
		if t.value=="case" then
			local start = self:node({})
			self:adv(); local val=self:parseExpr(); self:expect("Punct",":")
			start.tag = "Case"
			start.val = val
			return start
		end
		if t.value=="default" then
			local start = self:node({tag="Default"})
			self:adv(); self:expect("Punct",":")
			return start
		end
		if t.value=="typedef" then
			self:parseTypedef()
			return self:node({tag="Empty"})
		end
		if t.value=="enum" then
			local saved=self.pos; self:adv()
			if self:cur().type=="Ident" then self:adv() end
			if self:cur().value=="{" then
				self.pos=saved; return self:parseEnumDef()
			else self.pos=saved end
		end
		if t.value=="break" then 
			local start = self:node({tag="Break"})
			self:adv(); self:expect("Punct",";")
			return start
		end
		if t.value=="continue" then
			local start = self:node({tag="Continue"})
			self:adv(); self:expect("Punct",";")
			return start
		end
		if t.value=="goto" then
			local start = self:node({})
			self:adv(); local lbl=self:expect("Ident").value; self:expect("Punct",";")
			start.tag = "Goto"
			start.label = lbl
			return start
		end

		--label: ident :
		if t.type == "Ident" and self:peek() and self:peek().value == ":" then
			local start = self:node({})
			local lbl = self:adv().value
			self:adv()
			start.tag = "Label"
			start.name = lbl
			return start
		end

		--struct or union definition inside a function body
		if t.value == "struct" or t.value == "union" then
			local saved = self.pos
			self:adv()
			if self:cur().type == "Ident" then self:adv() end
			if self:cur().value == "{" then
				self.pos = saved; local sd = self:parseStructDef(); self:match("Punct",";"); return sd
			else
				self.pos = saved
			end
		end

		if self:isType() then return self:parseLocalDecl() end
		local start = self:node({})
		local e=self:parseExpr(); self:expect("Punct",";")
		start.tag = "ExprStmt"
		start.expr = e
		return start
	end

	function p:parseLocalDecl()
		local typ=self:parseType()
		local decls = {}
		while true do
			local name
			if self:match("Punct","(") and self:match("Punct","*") then
				name=self:expect("Ident").value
				self:expect("Punct",")"); self:expect("Punct","(")
				while not self:match("Punct",")") do self:adv() end
				typ = {base=typ.base, ptr=(typ.ptr or 0)+1, isStatic=typ.isStatic, isExtern=typ.isExtern}
			else
				name=self:expect("Ident").value
			end
			local arr = self:parseArrayDims()
			local init; if self:match("Punct","=") then
				if self:cur().value=="{" then init=self:parseInitList() else init=self:parseExpr() end
			end
			arr, init = self:resolveArrayInit(typ, arr, init)
			table.insert(decls, {tag="VarDecl",name=name,type=typ,arr=arr,init=init,global=false,isStatic=typ.isStatic})

			if not self:match("Punct",",") then break end
		end
		self:expect("Punct",";")

		if #decls == 1 then return decls[1] end
		return {tag="MultiDecl",decls=decls}
	end

	--expressions via precedence climbing. one more staircase woohoo
	function p:parseExpr() return self:parseComma() end
	function p:parseComma()
		local l=self:parseAssign()
		while self:match("Punct",",") do 
			local start = self:node({})
			start.tag = "Comma"
			start.left = l
			start.right = self:parseAssign()
			l = start
		end
		return l
	end
	function p:parseAssign()
		local l=self:parseTernary()
		local t=self:cur()
		if t.type=="Punct" and (t.value=="=" or t.value=="+=" or t.value=="-=" or t.value=="*=" or t.value=="/=" or t.value=="%=" or t.value=="&=" or t.value=="|=" or t.value=="^=" or t.value=="<<=" or t.value==">>=") then
			local start = self:node({})
			local op=self:adv().value; local r=self:parseAssign()
			if op=="=" then 
				start.tag = "Assign"
				start.target = l
				start.value = r
			else 
				start.tag = "Assign"
				start.target = l
				start.value = self:node({tag="BinOp",op=op:sub(1,-2),left=l,right=r})
			end
			return start
		end
		return l
	end
	function p:parseTernary()
		local cond=self:parseOr()
		if self:match("Punct","?") then
			local start = self:node({})
			local th=self:parseExpr(); self:expect("Punct",":")
			local el=self:parseTernary()
			start.tag = "Ternary"
			start.cond = cond
			start.thenB = th
			start.elseB = el
			return start
		end
		return cond
	end
	function p:parseOr()
		local l=self:parseAnd()
		while self:match("Punct","||") do
			local start = self:node({})
			start.tag = "BinOp"
			start.op = "||"
			start.left = l
			start.right = self:parseAnd()
			l = start
		end
		return l
	end
	function p:parseAnd()
		local l=self:parseBitOr()
		while self:match("Punct","&&") do
			local start = self:node({})
			start.tag = "BinOp"
			start.op = "&&"
			start.left = l
			start.right = self:parseBitOr()
			l = start
		end
		return l
	end
	function p:parseBitOr()
		local l=self:parseBitXor()
		while self:match("Punct","|") do
			local start = self:node({})
			local r = self:parseBitXor()
			start.tag = "BinOp"
			start.op = "|"
			start.left = l
			start.right = r
			l = start
		end
		return l
	end
	function p:parseBitXor()
		local l=self:parseBitAnd()
		while self:match("Punct","^") do
			local start = self:node({})
			local r = self:parseBitAnd()
			start.tag = "BinOp"
			start.op = "^"
			start.left = l
			start.right = r
			l = start
		end
		return l
	end
	function p:parseBitAnd()
		local l=self:parseEq()
		while self:match("Punct","&") do
			local start = self:node({})
			local r = self:parseEq()
			start.tag = "BinOp"
			start.op = "&"
			start.left = l
			start.right = r
			l = start
		end
		return l
	end
	function p:parseEq()
		local l=self:parseRel()
		while true do
			local start = self:node({})
			if self:match("Punct","==") then
				local r = self:parseRel()
				start.tag = "BinOp"
				start.op = "=="
				start.left = l
				start.right = r
				l = start
			elseif self:match("Punct","!=") then
				local r = self:parseRel()
				start.tag = "BinOp"
				start.op = "!="
				start.left = l
				start.right = r
				l = start
			else break end
		end; return l
	end
	function p:parseRel()
		local l=self:parseShift()
		while true do
			local start = self:node({})
			local t=self:cur()
			if t.type=="Punct" and (t.value=="<" or t.value==">" or t.value=="<=" or t.value==">=") then
				local op=self:adv().value
				local r = self:parseShift()
				start.tag = "BinOp"
				start.op = op
				start.left = l
				start.right = r
				l = start
			else break end
		end; return l
	end
	function p:parseShift()
		local l=self:parseAdd()
		while true do
			local start = self:node({})
			local t=self:cur()
			if t.type=="Punct" and (t.value=="<<" or t.value==">>") then
				local op=self:adv().value
				local r = self:parseAdd()
				start.tag = "BinOp"
				start.op = op
				start.left = l
				start.right = r
				l = start
			else break end
		end; return l
	end
	function p:parseAdd()
		local l=self:parseMul()
		while true do
			local start = self:node({})
			local t=self:cur()
			if t.type=="Punct" and (t.value=="+" or t.value=="-") then
				local op=self:adv().value
				local r = self:parseMul()
				start.tag = "BinOp"
				start.op = op
				start.left = l
				start.right = r
				l = start
			else break end
		end; return l
	end
	function p:parseMul()
		local l=self:parseUnary()
		while true do
			local start = self:node({})
			local t=self:cur()
			if t.type=="Punct" and (t.value=="*" or t.value=="/" or t.value=="%") then
				local op=self:adv().value
				local r = self:parseUnary()
				start.tag = "BinOp"
				start.op = op
				start.left = l
				start.right = r
				l = start
			else break end
		end; return l
	end

	function p:parseUnary()
		local t=self:cur()
		local start = self:node({})

		--sizeof
		if t.value=="sizeof" then
			self:adv()
			if self:cur().value=="(" then
				local nextTok = self:peek(1)
				if nextTok and ((nextTok.type=="Keyword" and TYPE_KEYWORDS[nextTok.value]) or self.typedefs[nextTok.value]) then
					self:expect("Punct","(")
					local typ = self:parseType()
					self:expect("Punct",")")
					start.tag = "SizeOfType"
					start.type = typ
					return start
				end
			end
			start.tag = "SizeOfExpr"
			start.expr = self:parseUnary()
			return start
		end

		--cast or compound literal: (type)expr or (type){...}
		if t.value=="(" then
			local nextTok = self:peek(1)
			if nextTok and ((nextTok.type=="Keyword" and TYPE_KEYWORDS[nextTok.value]) or self.typedefs[nextTok.value]) then
				local saved = self.pos
				self:adv() --eat (
				local typ = self:parseType()
				if typ and self:cur().value == ")" then
					self:adv() --eat )
					if self:cur().value == "{" then
						start.tag = "CompoundLiteral"
						start.type = typ
						start.init = self:parseInitList()
						return start
					end
					start.tag = "Cast"
					start.type = typ
					start.expr = self:parseUnary()
					return start
				else
					self.pos = saved --backtrack
				end
			end
		end

		if t.value=="-" then self:adv(); start.tag="UnaryOp"; start.op="-"; start.expr=self:parseUnary(); return start end
		if t.value=="!" then self:adv(); start.tag="UnaryOp"; start.op="!"; start.expr=self:parseUnary(); return start end
		if t.value=="~" then self:adv(); start.tag="UnaryOp"; start.op="~"; start.expr=self:parseUnary(); return start end
		if t.value=="*" then self:adv(); start.tag="Deref";    start.expr=self:parseUnary(); return start end
		if t.value=="&" then self:adv(); start.tag="AddrOf";   start.expr=self:parseUnary(); return start end
		if t.value=="++" then self:adv(); start.tag="PreInc";  start.expr=self:parseUnary(); return start end
		if t.value=="--" then self:adv(); start.tag="PreDec";  start.expr=self:parseUnary(); return start end
		return self:parsePostfix()
	end

	function p:parsePostfix()
		local e=self:parsePrimary()
		while true do
			local start = self:node({})
			if self:cur().value=="(" then
				self:adv(); local args={}
				if not self:match("Punct",")") then
					repeat table.insert(args,self:parseAssign()) until not self:match("Punct",",")
					self:expect("Punct",")")
				end
				start.tag = "Call"
				start.func = e
				start.args = args
				e = start
			elseif self:cur().value=="[" then
				self:adv(); local idx=self:parseExpr(); self:expect("Punct","]")
				start.tag = "Index"
				start.base = e
				start.index = idx
				e = start
			elseif self:cur().value=="." then
				self:adv()
				start.tag = "Member"
				start.base = e
				start.field = self:expect("Ident").value
				e = start
			elseif self:match("Punct","->") then
				start.tag = "Arrow"
				start.base = e
				start.field = self:expect("Ident").value
				e = start
			elseif self:cur().value=="++" then 
				self:adv()
				start.tag = "PostInc"
				start.expr = e
				e = start
			elseif self:cur().value=="--" then 
				self:adv()
				start.tag = "PostDec"
				start.expr = e
				e = start
			else break end
		end; return e
	end

	function p:parsePrimary()
		local t=self:cur()
		if t.type=="Number" then 
			local start = self:node({tag="Num", value=t.value})
			self:adv()
			return start
		end
		if t.type=="String" then
			local start = self:node({})
			local val = self:adv().value
			while self:cur().type == "String" do
				val = val .. self:adv().value
			end
			start.tag = "Str"
			start.value = val
			return start
		end
		if t.type=="Ident" then 
			local start = self:node({tag="Ident", name=t.value})
			self:adv()
			return start
		end
		if t.value=="(" then self:adv(); local e=self:parseExpr(); self:expect("Punct",")"); return e end
		error(string.format("%s:%d:%d: Unexpected %s '%s'", t.file or "main.c", t.line, t.col, t.type, tostring(t.value)))
	end

	return p:parseProgram()
end

return CCHost
