-- forge.core.hash
-- Pure-Lua, cross-version (5.1 / 5.4 / Luau) 32-bit hash + checksum helpers.
-- Used for integrity canaries and for the artifact header checksum.
-- FNV-1a variant with an extra mixing round; deterministic across versions
-- because it only uses integer ops expressible without native bitwise ops.

local M = {}

local band, bxor, lshift

if bit then            -- Lua 5.1 + luabitop / lua-bitop
    band, bxor, lshift = bit.band, bit.bxor, bit.lshift
elseif bit32 then      -- Lua 5.2
    band, bxor, lshift = bit32.band, bit32.bxor, bit32.lshift
else
    local ok, b = pcall(require, "bit")   -- try common module names
    if ok and b then
        band, bxor, lshift = b.band, b.bxor, b.lshift
    else
        local ok2, b32 = pcall(require, "bit32")
        if ok2 and b32 then
            band, bxor, lshift = b32.band, b32.bxor, b32.lshift
        else
            -- Native operators (Lua 5.4 / Luau)
            band = function(a, b) return a & b end
            bxor = function(a, b) return a ~ b end
            lshift = function(a, n) return (a * (2 ^ n)) % (2 ^ 32) end
        end
    end
end

M.band, M.bxor, M.lshift = band, bxor, lshift

-- FNV-1a 32-bit over a byte string.
function M.fnv1a(str, seed)
    local h = seed or 2166136261
    for i = 1, #str do
        h = bxor(h, str:byte(i))
        h = (h * 16777619) % 0x100000000
    end
    return h
end

-- avalanche mix (MurmurHash3 finalizer, 32-bit)
function M.mix(h)
    h = h % 0x100000000
    h = bxor(h, h // 0x10000)
    h = (h * 0x2543F6A9) % 0x100000000
    h = bxor(h, h // 0x2000)
    h = (h * 0x1B873593) % 0x100000000
    return bxor(h, h // 0x10000)
end

-- Rolling checksum over a sequence of numbers/strings, order sensitive.
function M.checksum(parts, seed)
    local h = seed or 0x9E3779B9
    for _, p in ipairs(parts) do
        if type(p) == "number" then
            h = bxor(h, (p // 0x10000) % 0x10000)
            h = (h * 31 + (p % 0x10000)) % 0x100000000
        elseif type(p) == "string" then
            h = M.mix(bxor(h, M.fnv1a(p, h)))
        end
    end
    return h % 0x100000000
end

return M
