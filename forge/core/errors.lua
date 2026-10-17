-- forge.core.errors
-- Unified, typed error system for the entire Forge pipeline.
-- Every stage raises errors through this module so callers can distinguish
-- parse failures from compile failures, integrity failures, or usage errors.

local Error = {}

Error.Kind = {
    USAGE      = "usage",       -- bad CLI / API input (paths, options)
    LEXICAL    = "lexical",     -- tokenizer error
    SYNTAX     = "syntax",      -- parser error
    SEMANTIC   = "semantic",     -- resolver / unsupported feature
    COMPILE    = "compile",      -- VM codegen error
    ENCODE     = "encode",       -- packer / cipher error
    INTEGRITY  = "integrity",    -- runtime tamper detection
    INTERNAL   = "internal",     -- a bug in the obfuscator itself
}

-- Base class: ForgeError carries kind, message and optional position info.
local ForgeError = {}
ForgeError.__index = ForgeError

function ForgeError.new(kind, message, pos)
    return setmetatable({
        kind = kind,
        message = message,
        line = pos and pos.line,
        col = pos and pos.col,
    }, ForgeError)
end

function ForgeError:__tostring()
    local where = ""
    if self.line then
        where = string.format(" [%d:%d]", self.line, self.col or 0)
    end
    return string.format("forge %s error%s: %s", self.kind, where, self.message)
end

function Error.is(e)
    return type(e) == "table" and getmetatable(e) == ForgeError
end

-- Convenience constructors per kind --------------------------------------
for _, k in pairs({"USAGE","LEXICAL","SYNTAX","SEMANTIC","COMPILE","ENCODE","INTEGRITY","INTERNAL"}) do
    Error[k:lower()] = function(msg, pos) return ForgeError.new(Error.Kind[k], msg, pos) end
end

Error.raise = function(err) error(tostring(err), 0) end

-- Guard helper: wraps a call, converting raw Lua errors into typed ones.
function Error.guard(kind, fn)
    return function(...)
        local ok, a, b = pcall(fn, ...)
        if not ok then
            if Error.is(a) then error(a, 0) end
            error(ForgeError.new(Error.Kind[kind] or kind, tostring(a)), 0)
        end
        return a, b
    end
end

Error.ForgeError = ForgeError
return Error
