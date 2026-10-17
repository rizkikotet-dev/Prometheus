-- forge.core.rng
-- Deterministic, seedable PRNG (xorshift128+) used for every random decision
-- in the pipeline: name mangling, opcode permutation, seeding of encoders.
-- Everything is derived from a single 64-bit-ish seed so builds are fully
-- reproducible given the same seed.

local M = {}

local MOD = 2 ^ 32

local Rng = {}
Rng.__index = Rng

function Rng.new(seed)
    seed = tonumber(seed) or 0
    -- Splitmix-style initialization to spread weak seeds well.
    local s = seed % MOD
    local a = (s * 2654435761 + 1013904223) % MOD
    local b = (s * 40503 + 12345) % MOD
    local c = ((a * 2246822519) // 7 + b) % MOD
    local d = ((b * 3266489917) // 13 + c) % MOD
    if a == 0 and b == 0 and c == 0 and d == 0 then
        a, b, c, d = 2654435761, 40503, 2246822519, 3266489917
    end
    return setmetatable({ a = a, b = b, c = c, d = d }, Rng)
end

-- xorshift128: fast, decent period (2^128-1), fine for obfuscation decisions.
function Rng:next()
    local a, b, c, d = self.a, self.b, self.c, self.d
    local t = a ~ (a * 0x1B) % MOD -- keep mixing inside 32 bits via xor on masked values
    a, b, c = b, c, d
    d = (d ~ (d // 0x21)) ~ (t ~ (t // 0x3))
    d = d % MOD
    self.a, self.b, self.c, self.d = a, b, c, d
    return d
end

function Rng:float()
    return self:next() / MOD
end

-- inclusive integer range [lo, hi]
function Rng:int(lo, hi)
    if hi == nil then lo, hi = 1, lo end
    return lo + self:next() % (hi - lo + 1)
end

function Rng:bool(p)
    return self:float() < (p or 0.5)
end

function Rng:pick(list)
    assert(#list > 0, "cannot pick from empty list")
    return list[self:int(1, #list)]
end

-- Fisher-Yates shuffle (in place, returns list)
function Rng:shuffle(list)
    for i = #list, 2, -1 do
        local j = self:int(1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local B58 = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

function Rng:hex(nbytes)
    local out = {}
    for _ = 1, nbytes do
        out[#out + 1] = string.format("%02x", self:int(0, 255))
    end
    return table.concat(out)
end

function Rng:base58(nchars)
    local out = {}
    for _ = 1, nchars do
        out[#out + 1] = B58:sub(self:int(1, 58), self:int(1, 58))
    end
    return table.concat(out)
end

-- Identifier-safe alphanumeric string (starts with a letter).
function Rng:ident(len)
    len = len or self:int(6, 12)
    local first = ("abcdefghijklmnopqrstuvwxyz"):sub(self:int(1, 26), self:int(1, 26))
    local out = { first }
    for _ = 2, len do
        local n = self:int(1, 36)
        if n <= 26 then
            out[#out + 1] = ("abcdefghijklmnopqrstuvwxyz"):sub(n, n)
        else
            out[#out + 1] = tostring(n - 27)
        end
    end
    return table.concat(out)
end

M.Rng = Rng
M.new = Rng.new
return M
