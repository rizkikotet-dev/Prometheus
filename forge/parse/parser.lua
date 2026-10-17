-- forge.parse.parser
-- Recursive-descent parser for the Lua 5.1 / Luau superset producing the
-- forge AST. Syntax annotations (:: type) are skipped; compound assignment
-- (+= etc.) is lowered to desugared form at parse time so downstream stages
-- see plain Lua semantics.

local Errors  = require("forge.core.errors")
local Lexer   = require("forge.lex.lexer")
local Ast     = require("forge.parse.ast")

local K, node = Ast.K, Ast.node
local TokenKind = Lexer.TokenKind

local Parser = {}
Parser.__index = Parser

function Parser.new(src, opts)
    opts = opts or {}
    local tokens = Lexer.tokenize(src, opts)
    return setmetatable({
        t = tokens, i = 1,
        luau = opts.luau ~= false,
        maxTokens = opts.maxTokens or 2000000,
    }, Parser)
end

local function err(self, msg, tok)
    tok = tok or self:tok()
    error(Errors.syntax(msg, { line = tok.line, col = tok.col }), 0)
end

function Parser:tok() return self.t[self.i] end
function Parser:next() local tk = self.t[self.i]; self.i = self.i + 1; return tk end
function Parser:is(kind, val)
    local tk = self:tok()
    return tk.kind == kind and (val == nil or tk.value == val)
end
function Parser:accept(kind, val)
    if self:is(kind, val) then self:next(); return true end
    return false
end
function Parser:expect(kind, val, msg)
    if not self:accept(kind, val) then
        local tk = self:tok()
        err(self, msg or string.format("expected %s but found %s",
            tostring(val or kind), tk.kind == TokenKind.Eof and "<eof>" or string.format("%q", tostring(tk.value))), tk)
    end
    return self.t[self.i - 1]
end

function Parser:isKeyword(w)
    local tk = self:tok()
    if tk.kind ~= TokenKind.Name then return false end
    if w == "continue" and not self.luau then return false end
    return tk.value == w
end

-- Statement-level block ---------------------------------------------------

local BLOCK_END_KWS = { "end", "else", "elseif", "until" }

function Parser:isBlockEnd()
    for _, kw in ipairs(BLOCK_END_KWS) do
        if self:isKeyword(kw) then return true end
    end
    if self:is(TokenKind.Eof) then return true end
    -- Luau type-syntax tokens that can never start a statement. They only
    -- appear while skipping annotations, so treating them as block terminators
    -- keeps the skipper from swallowing following statements.
    if self.luau and (self:is(TokenKind.Sym, ":") or self:is(TokenKind.Sym, "->")) then
        return true
    end
    return false
end

function Parser:block()
    local stats = {}
    while not self:isBlockEnd() do
        if self:accept(TokenKind.Sym, ";") then
            -- empty statement
        else
            stats[#stats + 1] = self:statement()
            if self:is(TokenKind.Eof) then break end
        end
    end
    return node(K.Block, self:tok().line, { stats = stats })
end

function Parser:statement()
    local tk = self:tok()
    if tk.kind == TokenKind.Name then
        local w = tk.value
        if w == "if" then return self:ifStat() end
        if w == "while" then return self:whileStat() end
        if w == "do" then return self:doStat() end
        if w == "for" then return self:forStat() end
        if w == "repeat" then return self:repeatStat() end
        if w == "function" then return self:functionStat() end
        if w == "local" then return self:localStat() end
        if w == "return" then return self:returnStat() end
        if w == "break" then self:next(); return node(K.Break, tk.line) end
        if w == "continue" and self.luau then self:next(); return node(K.Continue, tk.line) end
        if w == "goto" then
            self:next()
            local lbl = self:expect(TokenKind.Name, nil, "expected label name after goto")
            return node(K.Goto, tk.line, { label = lbl.value })
        end
    end
    -- labels ::name::
    if tk.kind == TokenKind.Sym and tk.value == "::" then
        self:next()
        local nm = self:expect(TokenKind.Name, nil, "expected label name")
        self:expect(TokenKind.Sym, "::", "expected '::' to close label")
        return node(K.Label, tk.line, { label = nm.value })
    end
    return self:exprStatement()
end

function Parser:parBlock()
    self:expect(TokenKind.Sym, "(")
    local b = self:block()
    self:expect(TokenKind.Sym, ")")
    return b
end

function Parser:ifStat()
    local tk = self:next()
    local clauses = {}
    local cond = self:expression()
    self:expectKeyword("then")
    clauses[#clauses + 1] = { cond = cond, body = self:block() }
    while true do
        if self:isKeyword("elseif") then
            self:next()
            local c = self:expression()
            self:expectKeyword("then")
            clauses[#clauses + 1] = { cond = c, body = self:block() }
        elseif self:isKeyword("else") then
            self:next()
            local elseBody = self:block()
            self:expectKeyword("end")
            return node(K.If, tk.line, { clauses = clauses, elseBody = elseBody })
        else
            self:expectKeyword("end")
            return node(K.If, tk.line, { clauses = clauses, elseBody = nil })
        end
    end
end

function Parser:expectKeyword(w)
    if not (self:is(TokenKind.Name) and self:tok().value == w) then
        err(self, string.format("expected '%s' near %s", w,
            self:tok().kind == TokenKind.Eof and "<eof>" or string.format("%q", tostring(self:tok().value))))
    end
    self:next()
end

function Parser:whileStat()
    local tk = self:next()
    local cond = self:expression()
    self:expectKeyword("do")
    local body = self:block()
    self:expectKeyword("end")
    return node(K.While, tk.line, { cond = cond, body = body })
end

function Parser:doStat()
    local tk = self:next()
    local body = self:block()
    self:expectKeyword("end")
    return node(K.Do, tk.line, { body = body })
end

function Parser:repeatStat()
    local tk = self:next()
    local body = self:block()
    self:expectKeyword("until")
    local cond = self:expression()
    return node(K.Repeat, tk.line, { body = body, cond = cond })
end

function Parser:forStat()
    local tk = self:next()
    local firstName = self:expect(TokenKind.Name, nil, "expected identifier in for loop")
    if self:accept(TokenKind.Sym, "=") then
        local start = self:expression()
        self:expect(TokenKind.Sym, ",")
        local limit = self:expression()
        local step
        if self:accept(TokenKind.Sym, ",") then step = self:expression() end
        self:expectKeyword("do")
        local body = self:block()
        self:expectKeyword("end")
        return node(K.NumFor, tk.line, { name = firstName.value, start = start, limit = limit, step = step, body = body })
    else
        local names = { firstName.value }
        while self:accept(TokenKind.Sym, ",") do
            names[#names + 1] = self:expect(TokenKind.Name, nil, "expected identifier").value
        end
        self:expectKeyword("in")
        local exprs = self:exprList()
        self:expectKeyword("do")
        local body = self:block()
        self:expectKeyword("end")
        return node(K.GenFor, tk.line, { names = names, exprs = exprs, body = body })
    end
end

-- funcdef shared between statements and expressions ------------------------
function Parser:funcbody(tk, isMethod, debugname)
    local params, vararg = {}, false
    self:expect(TokenKind.Sym, "(")
    if not self:is(TokenKind.Sym, ")") then
        while true do
            if self:_isVarargAhead() then
                self:next()
                vararg = true
            else
                local p = self:expect(TokenKind.Name, nil, "expected parameter name")
                params[#params + 1] = p.value
                -- Luau: optional `: type` annotation, and optional default value
                -- (treated as nil-defaulted parameter; we strip the default).
                if self.luau and self:accept(TokenKind.Sym, ":") then
                    self:_skipTypeAtom()
                end
                self:_skipAttr()
                if self.luau and self:is(TokenKind.Sym, "=") then
                    self:next()
                    self:expression() -- discard default value expression
                end
            end
            if not self:accept(TokenKind.Sym, ",") then break end
        end
    end
    self:expect(TokenKind.Sym, ")")
    if self.luau and self:isKeyword("return") then
        -- single-expression return body: `local f = (x) -> x * 2`
        self:next()
        local e = self:expression()
        return node(K.Function, tk.line, {
            isMethod = isMethod, params = params, vararg = vararg,
            body = node(K.Block, tk.line, { stats = { node(K.Return, tk.line, { exprs = { e } }) } }),
            debugname = debugname,
        })
    end
    local body = self:block()
    self:expectKeyword("end")
    return node(K.Function, tk.line, {
        isMethod = isMethod, params = params, vararg = vararg, body = body, debugname = debugname,
    })
end

function Parser:functionStat()
    local tk = self:next()
    local parts = { self:expect(TokenKind.Name, nil, "expected function name") }
    local isMethod = false
    while true do
        if self:accept(TokenKind.Sym, ".") then
            parts[#parts + 1] = self:expect(TokenKind.Name, nil, "expected name in function path")
        elseif self:accept(TokenKind.Sym, ":") then
            parts[#parts + 1] = self:expect(TokenKind.Name, nil, "expected method name")
            isMethod = true
        else
            break
        end
    end
    local fn = self:funcbody(tk, isMethod, table.concat((function() local s={} for _,p in ipairs(parts) do s[#s+1]=p.value end return s end)(), "."))
    -- build target expression a.b.c:d -> nested PropIndex
    local target = node(K.Name, parts[1].line, { text = parts[1].value })
    for i = 2, #parts do
        target = node(K.PropIndex, parts[i].line, { obj = target, key = parts[i].value })
    end
    return node(K.Assign, tk.line, { targets = { target }, values = { node(K.FuncLit, tk.line, { fn = fn }) }, funcNamePath = true })
end

function Parser:localStat()
    local tk = self:next()
    if self:accept(TokenKind.Name, "function") then
        local name = self:expect(TokenKind.Name, nil, "expected local function name")
        local fn = self:funcbody(tk, false, name.value)
        return node(K.LocalFunc, tk.line, { name = name.value, func = fn })
    end
    -- Luau type generic list: `local function<T>(...)` handled above only for
    -- non-generic; generics are rare in target code and rejected with a clear
    -- error rather than silently mis-parsed.
    local names, attrs = {}, {}
    repeat
        local nm = self:expect(TokenKind.Name, nil, "expected variable name")
        names[#names + 1] = nm.value
        attrs[#attrs + 1] = nil
        if self.luau and self:is(TokenKind.Sym, "::") then
            self:_skipAttr()
            attrs[#attrs] = "annotated"
        elseif self.luau and self:is(TokenKind.Sym, ":") then
            -- Luau syntax `local x: number` (single colon) — skip the type.
            self:next()
            self:_skipType()
            attrs[#attrs] = "annotated"
        end
    until not self:accept(TokenKind.Sym, ",")
    local exprs
    if self:accept(TokenKind.Sym, "=") then
        exprs = self:exprList()
    else
        exprs = {}
    end
    return node(K.LocalAssign, tk.line, { names = names, exprs = exprs })
end

function Parser:_skipAttr()
    -- Luau type annotation: `::` followed by a type expression we skip.
    if self.luau and self:is(TokenKind.Sym, "::") then
        self:next()
        self:_skipType()
    end
end

-- Skip a balanced bracketed group delimited by open/close symbol values.
function Parser:_skipBalanced(open, close)
    self:expect(TokenKind.Sym, open)
    local depth = 1
    while depth > 0 do
        if self:is(TokenKind.Eof) then err(self, "unterminated type " .. open) end
        if self:accept(TokenKind.Sym, open) then depth = depth + 1
        elseif self:accept(TokenKind.Sym, close) then depth = depth - 1
        else self:next() end
    end
end

-- One type atom: Name, dotted name, generic application, table/paren types,
-- string singleton types, nil/boolean keyword-ish names.
function Parser:_skipTypeAtom()
    local tk = self:tok()
    if tk.kind == TokenKind.Name then
        self:next()
        while self:accept(TokenKind.Sym, ".") do
            self:expect(TokenKind.Name, nil, "expected name in type path")
        end
        if self:is(TokenKind.Sym, "<") then -- generic args
            self:_skipBalanced("<", ">")
        end
    elseif tk.kind == TokenKind.String then
        self:next()
    elseif self:is(TokenKind.Sym, "{") then
        self:_skipBalanced("{", "}")
    elseif self:is(TokenKind.Sym, "(") then
        self:_skipBalanced("(", ")")
    else
        err(self, "unexpected symbol in type annotation", tk)
    end
end

function Parser:_skipType()
    -- Type grammar skipping: atoms, unions/intersections, function arrows,
    -- optional `?`. Terminates when the next token cannot continue a type.
    self:_skipTypeAtom()
    if self.luau and self:accept(TokenKind.Sym, "?") then end
    while true do
        if self:accept(TokenKind.Sym, "|") or self:accept(TokenKind.Sym, "&") then
            self:_skipTypeAtom()
            self:accept(TokenKind.Sym, "?")
        elseif self.luau and self:is(TokenKind.Sym, "->") then
            self:next()
            self:_skipTypeAtom()
            self:accept(TokenKind.Sym, "?")
        else
            break
        end
    end
end

function Parser:returnStat()
    local tk = self:next()
    local exprs = {}
    if not self:isBlockEnd() and not self:is(TokenKind.Sym, ";") then
        exprs = self:exprList()
    end
    self:accept(TokenKind.Sym, ";")
    return node(K.Return, tk.line, { exprs = exprs })
end

function Parser:exprStatement()
    local e = self:suffixedExpr()
    local tk = self:tok()
    if self:is(TokenKind.Sym, "=") or (self.luau and self:_isCompoundOp()) then
        local targets = { e }
        while self:accept(TokenKind.Sym, ",") do
            targets[#targets + 1] = self:suffixedExpr()
        end
        local op = nil
        if self:_isCompoundOp() then
            local sop = self:next()
            op = sop.value
        else
            self:expect(TokenKind.Sym, "=")
        end
        local values = self:exprList()
        if op then
            -- desugar a op= b  ->  a = a op b (single target only, per Luau)
            local binop = op:sub(1, -2)
            if binop == "//" or binop == ".." then binop = binop end
            values = { node(K.Binop, tk.line, { op = binop, lhs = targets[1], rhs = values[1] }) }
        end
        return node(K.Assign, e.line, { targets = targets, values = values })
    end
    if e.kind ~= K.CallExpr and e.kind ~= K.Invoke then
        err(self, "syntax error near " .. string.format("%q", tostring(tk.value)))
    end
    return node(K.ExprStat, e.line, { e = e })
end

function Parser:_isCompoundOp()
    if not self.luau then return false end
    local tk = self:tok()
    if tk.kind ~= TokenKind.Sym then return false end
    local v = tk.value
    return v == "+=" or v == "-=" or v == "*=" or v == "/=" or v == "%=" or v == "^="
        or v == ".." and false or v == "//=" or v == "|=" or v == "&=" or v == "<<=" or v == ">>="
end

function Parser:_isVarargAhead()
    local a = self.t[self.i]
    return a and a.kind == TokenKind.Sym and a.value == "..."
end

function Parser:exprList()
    local list = { self:expression() }
    while self:accept(TokenKind.Sym, ",") do
        list[#list + 1] = self:expression()
    end
    return list
end

-- Expression parsing (precedence climbing) ---------------------------------

function Parser:unaryExpr()
    local tk = self:tok()
    if self:accept(TokenKind.Sym, "-") then
        -- fold leading sign into numeric literals (matches Lua's own behaviour
        -- for constants like -1 in source text; keeps VM constant pool clean)
        local inner = self:unaryExpr()
        if inner.kind == K.Number then
            return node(K.Number, tk.line, { value = -inner.value, text = "-" .. tostring(inner.text) })
        end
        return node(K.Unop, tk.line, { op = "-", e = inner })
    elseif self:accept(TokenKind.Sym, "#") then
        return node(K.Unop, tk.line, { op = "#", e = self:unaryExpr() })
    elseif tk.kind == TokenKind.Name and tk.value == "not" then
        self:next()
        return node(K.Unop, tk.line, { op = "not", e = self:unaryExpr() })
    end
    return self:suffixedExpr()
end

function Parser:binopToken()
    local tk = self:tok()
    if tk.kind == TokenKind.Sym then
        local v = tk.value
        if v == "+" or v == "-" or v == "*" or v == "/" or v == "%" or v == "^"
           or v == "#" or v == ".." or v == "<" or v == ">" or v == "~=" or v == "=="
           or v == "//" or v == "<<" or v == ">>" or v == "&" or v == "|" or v == "~" then
            return v
        end
    elseif tk.kind == TokenKind.Name then
        if tk.value == "and" or tk.value == "or" then return tk.value end
    end
    return nil
end

function Parser:expression(limit)
    limit = limit or 0
    local lhs = self:unaryExpr()
    while true do
        local op = self:binopToken()
        if not op then break end
        local prec = Ast.BinPrec[op]
        if not prec or prec <= limit then break end
        self:next()
        local rhsLimit = Ast.BinRightAssoc[op] and (prec - 1) or prec
        local rhs = self:expression(rhsLimit)
        lhs = node(K.Binop, lhs.line, { op = op, lhs = lhs, rhs = rhs })
    end
    return lhs
end

-- primary / suffixed -------------------------------------------------------

function Parser:primaryExpr()
    local tk = self:tok()
    if tk.kind == TokenKind.Name then
        if tk.value == "nil" then self:next(); return node(K.Nil, tk.line) end
        if tk.value == "true" then self:next(); return node(K.True, tk.line) end
        if tk.value == "false" then self:next(); return node(K.False, tk.line) end
        self:next()
        return node(K.Name, tk.line, { text = tk.value })
    elseif tk.kind == TokenKind.Number then
        self:next()
        return node(K.Number, tk.line, { value = tk.value, text = tk.text })
    elseif tk.kind == TokenKind.String then
        self:next()
        return node(K.String, tk.line, { value = tk.value })
    elseif tk.kind == TokenKind.Sym and tk.value == "{" then
        return self:tableCons()
    elseif tk.kind == TokenKind.Sym and tk.value == "(" then
        self:next()
        local e = self:expression()
        self:expect(TokenKind.Sym, ")")
        return node(K.Parens, tk.line, { e = e })
    elseif self:_isVarargAhead() then
        self:next()
        return node(K.Vararg, tk.line)
    end
    err(self, string.format("unexpected symbol %q in expression", tostring(tk.value)))
end

function Parser:args()
    local tk = self:tok()
    if tk.kind == TokenKind.Sym and tk.value == "(" then
        self:next()
        local list = {}
        if not self:is(TokenKind.Sym, ")") then
            list = self:exprList()
        end
        self:expect(TokenKind.Sym, ")")
        return list, nil
    elseif tk.kind == TokenKind.String then
        self:next()
        return { node(K.String, tk.line, { value = tk.value }) }, nil
    elseif tk.kind == TokenKind.Sym and tk.value == "{" then
        local t = self:tableCons()
        return { t }, nil
    end
    err(self, "expected function arguments")
end

function Parser:suffixedExpr()
    local e = self:primaryExpr()
    while true do
        local tk = self:tok()
        if tk.kind == TokenKind.Sym then
            if tk.value == "." then
                self:next()
                local name = self:expect(TokenKind.Name, nil, "expected property name")
                e = node(K.PropIndex, tk.line, { obj = e, key = name.value })
            elseif tk.value == "[" then
                self:next()
                local k = self:expression()
                self:expect(TokenKind.Sym, "]")
                e = node(K.Index, tk.line, { obj = e, key = k })
            elseif tk.value == ":" then
                self:next()
                local name = self:expect(TokenKind.Name, nil, "expected method name")
                local args = self:args()
                e = node(K.Invoke, tk.line, { prefix = e, selfName = name.value, args = args })
            elseif tk.value == "(" or tk.value == "{" then
                local args = self:args()
                e = node(K.CallExpr, tk.line, { prefix = e, args = args })
            elseif tk.value == "::" and self.luau then
                -- cast expression `e :: T` — strip the cast
                self:next()
                self:_skipType()
            else
                break
            end
        elseif tk.kind == TokenKind.String then
            -- string-literal call:  print"hi"
            local strTok = self:next()
            e = node(K.CallExpr, strTok.line, { prefix = e,
                   args = { node(K.String, strTok.line, { value = strTok.value }) } })
        else
            break
        end
    end
    return e
end

function Parser:tableField()
    local tk = self:tok()
    if tk.kind == TokenKind.Sym and tk.value == "[" then
        self:next()
        local k = self:expression()
        self:expect(TokenKind.Sym, "]")
        self:expect(TokenKind.Sym, "=")
        local v = self:expression()
        return { kind = "keyexpr", k = k, v = v }
    elseif tk.kind == TokenKind.Name and self.t[self.i + 1]
       and self.t[self.i + 1].kind == TokenKind.Sym and self.t[self.i + 1].value == "=" then
        local name = self:next()
        self:next() -- '='
        local v = self:expression()
        return { kind = "keyname", k = name.value, v = v }
    else
        local v = self:expression()
        return { kind = "array", v = v }
    end
end

function Parser:tableCons()
    local tk = self:expect(TokenKind.Sym, "{")
    local array, keys = {}, {}
    while not self:accept(TokenKind.Sym, "}") do
        local f = self:tableField()
        if f.kind == "array" then
            array[#array + 1] = f.v
        elseif f.kind == "keyname" then
            keys[#keys + 1] = { k = node(K.String, tk.line, { value = f.k }), v = f.v, nameKey = true }
        else
            keys[#keys + 1] = { k = f.k, v = f.v }
        end
        if not (self:accept(TokenKind.Sym, ",") or self:accept(TokenKind.Sym, ";")) then
            self:expect(TokenKind.Sym, "}", "expected , or } in table constructor")
            break
        end
    end
    return node(K.Table, tk.line, { array = array, keys = keys })
end

local M = {}

-- entry point ---------------------------------------------------------------
function Parser:parse()
    local b = self:block()
    if not self:is(TokenKind.Eof) then
        err(self, "expected <eof> near " .. string.format("%q", tostring(self:tok().value)))
    end
    return b
end

M.Parser = Parser
M.parse = function(src, opts)
    local ok, res = pcall(function() return Parser.new(src, opts):parse() end)
    if ok then return true, res end
    if Errors.is(res) then return false, res end
    return false, Errors.internal("parser crashed: " .. tostring(res))
end

return M
