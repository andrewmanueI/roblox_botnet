-- Packet Decoder for "CreateProjectile" (179)
-- Analyzes the user's working manual firing string to find exact offsets.

local raw = "\000\179\000\000\128?C\146QC\204\204\164A\003x\166\195/;Z=\019\187o\160\254ruc\218A$\000DA463884-18D1-43A6-90D6-6A68B3B41320$\000\189\002\000"
local b = buffer.fromstring(raw)
local len = buffer.len(b)

print("--- Packet 179 Analysis ---")
print("Total Length:", len)
print("0: Namespace ->", buffer.readu8(b, 0))
print("1: ID ->", buffer.readu8(b, 1))

-- Try to find the 1.0 drawStrength (00 00 80 3F)
for i = 0, len - 4 do
    local f = buffer.readf32(b, i)
    if f == 1.0 then
        print(i .. ": Found Float32 1.0 (drawStrength?)")
    end
end

-- Try to find any other Float32s (Coordinates)
for i = 0, len - 4 do
    local f = buffer.readf32(b, i)
    if math.abs(f) > 1 and math.abs(f) < 100000 then
        -- print(i .. ": Float32 ->", f)
    end
end

-- Try to find the Float64 Timestamp
for i = 0, len - 8 do
    local f = buffer.readf64(b, i)
    if f > 1.7e9 then -- Roughly current Unix timestamp
        print(i .. ": Found Float64 Timestamp ->", f)
    end
end

-- Try to find the GUID string
for i = 0, len - 2 do
    local strLen = buffer.readu16(b, i)
    if strLen == 36 then
        print(i .. ": Found String Length 36 (GUID?)")
        local s = ""
        pcall(function() s = buffer.readstring(b, i + 2, 36) end)
        print("   Body:", s)
    end
end

print("---------------------------")
