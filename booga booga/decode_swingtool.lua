-- Decode a captured ByteNet SwingTool payload.
-- Schema (from your source): SwingTool = array(uint32)
--
-- Notes:
-- - Many ByteNet builds encode arrays as: <len:uint16 LE> + <items:uint32 LE>...
-- - This script helps you verify the exact encoding your game is using.

local function bytesFromString(s)
    local out = table.create(#s)
    for i = 1, #s do
        out[i] = string.byte(s, i)
    end
    return out
end

local function u16le(b, i)
    return b[i] + b[i + 1] * 256
end

local function u32le(b, i)
    return b[i] + b[i + 1] * 256 + b[i + 2] * 65536 + b[i + 3] * 16777216
end

local function hex(b)
    return string.format("0x%02X", b)
end

-- Replace this with your intercepted payload bytes.
-- Example capture (from your message): \000\017\001\000n#\t\000
local payloadStr = "\000\017\001\000n#\t\000"

local b = bytesFromString(payloadStr)
print("Payload length:", #b)

if #b < 3 then
    warn("Payload too short.")
    return
end

-- Common header in your other packets: namespace byte + packetId byte.
local namespaceByte = b[1]
local packetIdByte = b[2]
print("Header:", "namespace=" .. namespaceByte, "packetId=" .. packetIdByte .. " (" .. hex(packetIdByte) .. ")")

-- Try two common array encodings:
-- A) len:uint8 at offset 3
-- B) len:uint16 LE at offset 3
local function tryLenU8()
    local len = b[3]
    local offset = 4
    local need = offset + len * 4 - 1
    if need > #b then
        return nil, "u8 length would require " .. need .. " bytes, have " .. #b
    end
    local items = {}
    for k = 1, len do
        items[k] = u32le(b, offset)
        offset += 4
    end
    return items, nil
end

local function tryLenU16()
    if #b < 4 then
        return nil, "need at least 4 bytes for u16 length"
    end
    local len = u16le(b, 3)
    local offset = 5
    local need = offset + len * 4 - 1
    if need > #b then
        return nil, "u16 length would require " .. need .. " bytes, have " .. #b
    end
    local items = {}
    for k = 1, len do
        items[k] = u32le(b, offset)
        offset += 4
    end
    return items, nil
end

local items8, err8 = tryLenU8()
local items16, err16 = tryLenU16()

print("---- Candidate decodes ----")
if items8 then
    print("As len:uint8, count=" .. #items8)
    for i, v in ipairs(items8) do
        print("  [" .. i .. "]", v)
    end
else
    print("As len:uint8: FAIL - " .. tostring(err8))
end

if items16 then
    print("As len:uint16 LE, count=" .. #items16)
    for i, v in ipairs(items16) do
        print("  [" .. i .. "]", v)
    end
else
    print("As len:uint16 LE: FAIL - " .. tostring(err16))
end

print("--------------------------------------------------")
print("If one decode yields sane IDs (e.g., entity IDs you can find in workspace), that's your format.")

