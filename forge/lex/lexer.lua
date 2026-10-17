-- forge.lex.lexer
-- Hand-written lexer for the Lua 5.1 / Luau superset.
-- Produces a flat token array; comments and whitespace are skipped, but
-- line/column info is tracked on every token for precise diagnostics.

local Errors = require("forge.core.errors")

local M = {}

local TokenKind = {
    Name   = "Name",     -- identifier or keyword (keywords checked by parser)
    Number = "Number",
    String = "String",
    Sym    = "Sym",      -- operators / punctuation
    Eof    = "Eof",
}
M.TokenKind = TokenKind

local KEYWORDS = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
    ["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["goto"]=true,
    ["if"]=true, ["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true,
    ["or"]=true, ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
    ["until"]=true, ["while"]=true,
    -- Luau extras treated as keywords when luau=true (parser decides)
    ["continue"]="luau",
}
M.KEYWORDS = KEYWORDS

-- Ordered longest-first symbol table
local SYMBOLS3 = { "//=" }
local SYMBOLS2 = {
    "==", "~=", "<=", ">=", "..", "::", "+=", "-=", "*=", "/=", "%=", "^=",
    "//", "<<", ">>", "|=", "&=", "->",
}
local SYMBOLS1 = {
    "+", "-", "*", "/", "%", "^", "#", "=", "(", ")", "{", "}",
    "[", "]", ";", ":", ",", ".", "<", ">", "~", "&", "|", "'", "\"",
}

local function is_name_start(c)
    return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
end
local function is_name_cont(c)
    return is_name_start(c) or (c >= "0" and c <= "9")
end
local function is_digit(c)
    return c >= "0" and c <= "9"
end

local Lexer = {}
Lexer.__index = Lexer

function Lexer.new(src, opts)
    opts = opts or {}
    return setmetatable({
        src = src,
        n = #src,
        i = 1,
        line = 1,
        col = 1,
        luau = opts.luau ~= false,   -- accept Luau syntax by default
        tokens = {},
    }, Lexer)
end

local function err(self, msg)
    error(Errors.lexical(msg, { line = self.line, col = self.col }), 0)
end

local function peek(self, off)
    return self.src:sub((self.i + (off or 0)), (self.i + (off or 0)))
end

local function advance(self)
    local c = peek(self)
    self.i = self.i + 1
    if c == "\n" then
        self.line = self.line + 1
        self.col = 1
    else
        self.col = self.col + 1
    end
    return c
end

function Lexer:_emit(kind, value, sline, scol)
    self.tokens[#self.tokens + 1] = {
        kind = kind, value = value, line = sline, col = scol,
        endLine = self.line, endCol = self.col,
    }
end

-- skip whitespace + comments; returns false at EOF
function Lexer:_skip()
    while true do
        local c = peek(self)
        if c == "" then return false end
        if c == " " or c == "\t" or c == "\r" or c == "\n" then
            advance(self)
        elseif c == "-" and peek(self, 1) == "-" then
            advance(self); advance(self)
            if peek(self) == "[" then
                -- possible long comment: "[[" or "[=[ ... ]=]" (level >= 0)
                local saveI, saveLine, saveCol = self.i, self.line, self.col
                advance(self)
                local level = 0
                while peek(self) == "=" do advance(self); level = level + 1 end
                if peek(self) ~= "[" then
                    -- not a long bracket after all; rewind to just after "--"
                    self.i, self.line, self.col = saveI, saveLine, saveCol
                else
                    local close = "]" .. string.rep("=", level) .. "]"
                    advance(self)
                    while true do
                        if self.i > self.n then
                            err(self, "unterminated long comment")
                        end
                        if self.src:sub(self.i, self.i + #close - 1) == close then
                            for _ = 1, #close do advance(self) end
                            break
                        end
                        advance(self)
                    end
                end
            else
                while true do
                    local cc = peek(self)
                    if cc == "" or cc == "\n" then break end
                    advance(self)
                end
            end
        else
            return true
        end
    end
end

local ESCAPES = { a="\a", b="\b", f="\f", n="\n", r="\r", t="\t", v="\v", ["\\"]="\\", ['"']='"', ["'"]="'", ["/"]="/" }

function Lexer:_read_escape(out)
    local c = advance(self)
    if c == "" then err(self, "unfinished escape sequence") end
    if ESCAPES[c] then
        out[#out + 1] = ESCAPES[c]
    elseif c == "x" then
        local h = self.src:sub(self.i, self.i + 1)
        if not h:match("^%x%x$") then err(self, "invalid \\x escape") end
        out[#out + 1] = string.char(tonumber(h, 16))
        advance(self); advance(self)
    elseif c == "u" then
        if peek(self) ~= "{" then err(self, "expected { after \\u") end
        advance(self)
        local h = {}
        while peek(self) ~= "}" do
            local cc = advance(self)
            if cc == "" then err(self, "unfinished \\u escape") end
            h[#h + 1] = cc
        end
        advance(self)
        local code = tonumber(table.concat(h), 16)
        if not code then err(self, "invalid \\u escape") end
        -- encode UTF-8 manually (works on 5.1 too)
        if code < 0x80 then
            out[#out + 1] = string.char(code)
        elseif code < 0x800 then
            out[#out + 1] = string.char(0xC0 + code // 0x40, 0x80 + code % 0x40)
        elseif code < 0x10000 then
            out[#out + 1] = string.char(0xE0 + code // 0x1000, 0x80 + (code // 0x40) % 0x40, 0x80 + code % 0x40)
        else
            out[#out + 1] = string.char(0xF0 + code // 0x40000, 0x80 + (code // 0x1000) % 0x40,
                                        0x80 + (code // 0x40) % 0x40, 0x80 + code % 0x40)
        end
    elseif c:match("%d") then
        local digits = { c }
        while #digits < 3 and peek(self):match("%d") do
            digits[#digits + 1] = advance(self)
        end
        local v = tonumber(table.concat(digits))
        if v and v >= 0 and v <= 255 then
            out[#out + 1] = string.char(v)
        else
            err(self, "decimal escape out of range")
        end
    else
        err(self, "invalid escape sequence '\\" .. c .. "'")
    end
end

function Lexer:_read_quoted(quote)
    local sline, scol = self.line, self.col
    advance(self) -- opening quote
    local out = {}
    while true do
        local c = peek(self)
        if c == "" or c == "\n" then
            err(self, "unfinished string")
        end
        if c == quote then
            advance(self)
            break
        end
        if c == "\\" then
            advance(self)
            self:_read_escape(out)
        else
            out[#out + 1] = advance(self)
        end
    end
    self:_emit(TokenKind.String, table.concat(out), sline, scol)
end

function Lexer:_read_long()
    local sline, scol = self.line, self.col
    advance(self) -- opening [
    local level = 0
    while peek(self) == "=" do advance(self); level = level + 1 end
    if peek(self) ~= "[" then err(self, "malformed long string opening") end
    advance(self)
    if peek(self) == "\n" then advance(self) end -- first newline trimmed per spec
    local stop = "]" .. string.rep("=", level) .. "]"
    local startI = self.i
    while true do
        if self.i > self.n then err(self, "unterminated long string") end
        if self.src:sub(self.i, self.i + #stop - 1) == stop then
            local s = self.src:sub(startI, self.i - 1)
            for _ in s:gmatch("\n") do self.line = self.line + 1 end
            self.i = self.i + #stop
            self.col = 1
            self:_emit(TokenKind.String, s, sline, scol)
            return
        end
        advance(self)
    end
end

function Lexer:_read_number()
    local sline, scol = self.line, self.col
    local startI = self.i
    if peek(self) == "0" and (peek(self, 1) == "x" or peek(self, 1) == "X") then
        advance(self); advance(self)
        while peek(self):match("[%x]") or peek(self) == "_" do advance(self) end
        -- hex float: 0x1.8p2 (Luau / 5.3+)
        if peek(self) == "." then
            advance(self)
            while peek(self):match("%x") or peek(self) == "_" do advance(self) end
        end
        if peek(self):match("[pP]") then
            advance(self)
            if peek(self):match("[+-]") then advance(self) end
            while peek(self):match("%d") or peek(self) == "_" do advance(self) end
        end
        -- binary literals 0b1010 are NOT supported by tonumber in any target
        -- version we emit for, and are extremely rare in real code; treat a
        -- trailing b/B as a malformed number error rather than silently
        -- producing wrong values.
    else
        while true do
            local c = peek(self)
            if c:match("%d") or c == "_" then
                advance(self)
            elseif c == "." then
                local prev = self.src:sub(self.i - 1, self.i - 1)
                if prev == "." then break end
                advance(self)
            elseif c == "e" or c == "E" then
                -- only part of the number if followed by digits or sign+digits
                local nxt = self.src:sub(self.i + 1, self.i + 2)
                if nxt:match("^[+-]?%d") then
                    advance(self)
                    if peek(self):match("[+-]") then advance(self) end
                else
                    break
                end
            elseif is_name_cont(c) then
                err(self, "malformed number near '" .. self.src:sub(startI, self.i) .. "'")
            else
                break
            end
        end
    end
    local text = self.src:sub(startI, self.i - 1)
    -- Luau digit separators are accepted by the lexer but not by tonumber;
    -- strip them before evaluating the literal value.
    local numericText = text:gsub("_", "")
    local value = tonumber(numericText)
    if not value then err(self, "malformed number near '" .. text .. "'") end
    self:_emit(TokenKind.Number, value, sline, scol)
    self.tokens[#self.tokens].text = text
end

-- Long-bracket opener detector used for rewind-safe disambiguation of "["
-- followed by "=" (e.g. a[= is an index with unary minus, not a long string).
local function looks_like_long_open(src, i)
    -- src:sub(i,i) == "["
    local j = i + 1
    while src:sub(j, j) == "=" do j = j + 1 end
    return src:sub(j, j) == "["
end

function Lexer:tokenize()
    while self:_skip() do
        local sline, scol = self.line, self.col
        local c = peek(self)
        if is_name_start(c) then
            local startI = self.i
            while is_name_cont(peek(self)) do advance(self) end
            local name = self.src:sub(startI, self.i - 1)
            self:_emit(TokenKind.Name, name, sline, scol)
        elseif is_digit(c) or (c == "." and is_digit(peek(self, 1))) then
            self:_read_number()
        elseif c == '"' or c == "'" then
            self:_read_quoted(c)
        elseif c == "[" and looks_like_long_open(self.src, self.i) then
            self:_read_long()
        else
            local two = self.src:sub(self.i, self.i + 1)
            local three = self.src:sub(self.i, self.i + 2)
            local sym
            for _, s in ipairs(SYMBOLS3) do if three == s then sym = s break end end
            if not sym then
                for _, s in ipairs(SYMBOLS2) do if two == s then sym = s break end end
            end
            if not sym and c == "." then sym = "." end -- only when not part of '..'
            if not sym then
                for _, s in ipairs(SYMBOLS1) do if c == s then sym = s break end end
            end
            if not sym then err(self, "unexpected symbol near '" .. c .. "'") end
            if sym == ".." and peek(self, 2) == "." and not peek(self, 3):match("^[%w_%.]") then
                -- "..." is the vararg token; but "...." must stay '..' + '...'
                sym = "..."
            end
            for _ = 1, #sym do advance(self) end
            self:_emit(TokenKind.Sym, sym, sline, scol)
        end
    end
    self:_emit(TokenKind.Eof, "<eof>", self.line, self.col)
    return self.tokens
end

M.Lexer = Lexer
M.tokenize = function(src, opts)
    return Lexer.new(src, opts):tokenize()
end

return M
