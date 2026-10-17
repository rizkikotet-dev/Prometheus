-- forge.parse.ast
-- AST node kinds + constructors. Nodes are plain tables: { kind = ..., ... }
-- with a shared `line` field for diagnostics. Kept intentionally minimal and
-- serialisable so passes can deep-copy / diff them cheaply.

local M = {}

M.K = {
    -- statements
    Block        = "Block",         -- body: { stats = {}, locvars = {} }
    Assign       = "Assign",        -- targets, values
    LocalAssign  = "LocalAssign",   -- names, exprs, attr
    Function     = "Function",      -- isMethod, params, vararg, body
    Call         = "Call",          -- prefix, args (statement-level wrapper uses ExprStat)
    LocalFunc    = "LocalFunc",     -- name, func
    If           = "If",            -- clauses: { {cond, body}, ... }, elseBody
    While        = "While",         -- cond, body
    Repeat       = "Repeat",        -- body, cond
    NumFor       = "NumFor",        -- name, start, limit, step, body
    GenFor       = "GenFor",        -- names, exprs, body
    Return       = "Return",        -- exprs
    Break        = "Break",
    Continue     = "Continue",      -- Luau
    Goto         = "Goto",          -- label
    Label        = "Label",         -- name
    Do           = "Do",            -- body
    ExprStat     = "ExprStat",      -- e (a call used as statement)

    -- expressions
    Nil          = "Nil",
    True         = "True",
    False        = "False",
    Vararg       = "Vararg",        -- ...
    Number       = "Number",        -- value
    String       = "String",        -- value
    Interp     = "Interp",        -- Luau `$"..."` lowered to concat of parts
    Name         = "Name",          -- text; resolved by semantic pass -> .res
    Index        = "Index",         -- obj, key(expr)
    PropIndex    = "PropIndex",     -- obj, name(string)
    CallExpr     = "CallExpr",      -- prefix, args, selfName|nil
    Invoke       = "Invoke",        -- prefix, selfName, args   (obj:m(...))
    FuncLit      = "FuncLit",       -- fn (Function node)
    Table        = "Table",         -- array: {expr,...}, keys: {{k=exprNode,v=expr},...}
    Binop        = "Binop",         -- op, lhs, rhs
    Unop         = "Unop",          -- op, e
    Parens       = "Parens",        -- e  (adjusts to exactly one value)
    Attr         = "Attr",          -- Luau :: type — stripped by parser but preserved flag
}

M.BinPrec = {
    ["or"] = 1, ["and"] = 2,
    ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
    ["|"] = 4, ["~"] = 4, ["&"] = 5,
    ["<<"] = 6, [">>"] = 6,
    [".."] = 9,          -- right assoc
    ["+"] = 10, ["-"] = 10,
    ["*"] = 11, ["/"] = 11, ["//"] = 11, ["%"] = 11,
    ["^"] = 14,          -- right assoc
}
M.BinRightAssoc = { [".."] = true, ["^"] = true }
M.UnaryPrecedence = 12

function M.node(kind, line, tbl)
    local n = tbl or {}
    n.kind = kind
    n.line = line or 0
    return n
end

return M
