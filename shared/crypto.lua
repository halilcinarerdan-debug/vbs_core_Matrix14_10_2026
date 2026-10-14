-- =====================================================================
-- shared/crypto.lua -- SAF LUA 5.4 SHA-256 UYGULAMASI
--
-- FiveM server/client Lua ortamında yerleşik bir SHA-256 bulunmadığından,
-- bu dosya standart FIPS 180-4 SHA-256 algoritmasını, Lua 5.4'ün YERLEŞİK
-- bit işleçleriyle (&, |, ~, >>, <<) SAF Lua olarak uygular.
--
-- SIFIR RNG: math.random YOK. Tamamen deterministik.
--
-- Kullanım:
--   sha256.hex('merhaba')  -> 64 karakterlik küçük harf hex digest
-- =====================================================================

local sha256 = {}

-- Lua 5.4'ün yerleşik bit işleçleri (`&`, `|`, `~`, `>>`, `<<`) doğrudan
-- kullanılır; ayrı bir bit kütüphanesine gerek yoktur.

local MASK32 = 0xFFFFFFFF

local function ROTR(x, n)
    x = x & MASK32
    return ((x >> n) | (x << (32 - n))) & MASK32
end

local function SHR(x, n)
    return (x & MASK32) >> n
end

-- İlk 64 asal sayının küp köklerinin ondalık kısımlarının ilk 32 biti (K)
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

-- İlk 8 asal sayının kare köklerinin ondalık kısımlarının ilk 32 biti (H0)
local H0 = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
}

--- Girdiyi FIPS 180-4 padding kurallarına göre 512-bit (64 byte) bloklara
--- tamamlar ve byte dizisi (string) olarak döner.
local function PadMessage(msg)
    local msgLen = #msg
    local bitLen = msgLen * 8

    local padded = { msg, '\128' }
    local padLen = (56 - ((msgLen + 1) % 64)) % 64
    if padLen > 0 then
        padded[#padded + 1] = string.rep('\0', padLen)
    end

    -- 64-bit büyük-endian uzunluk alanı (biz 53-bit güvenli tam sayı
    -- sınırının çok altında kalırız; üst 32 bit her zaman 0'dır).
    local lenHigh = 0
    local lenLow  = bitLen & MASK32
    local lenBytes = {}
    for i = 1, 4 do
        lenBytes[i] = string.char((lenHigh >> ((4 - i) * 8)) & 0xFF)
    end
    for i = 1, 4 do
        lenBytes[4 + i] = string.char((lenLow >> ((4 - i) * 8)) & 0xFF)
    end
    padded[#padded + 1] = table.concat(lenBytes)

    return table.concat(padded)
end

--- Ham (binary) 32-byte SHA-256 digest üretir.
local function RawDigest(msg)
    msg = tostring(msg or '')
    local padded = PadMessage(msg)
    local numBlocks = #padded // 64

    local h0, h1, h2, h3, h4, h5, h6, h7 =
        H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8]

    local w = {}

    for blockIdx = 0, numBlocks - 1 do
        local blockStart = blockIdx * 64

        for t = 0, 15 do
            local o = blockStart + (t * 4)
            local b1, b2, b3, b4 = padded:byte(o + 1, o + 4)
            w[t + 1] = ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4) & MASK32
        end

        for t = 17, 64 do
            local w15 = w[t - 15]
            local w2  = w[t - 2]
            local s0 = ROTR(w15, 7) ~ ROTR(w15, 18) ~ SHR(w15, 3)
            local s1 = ROTR(w2, 17) ~ ROTR(w2, 19) ~ SHR(w2, 10)
            w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & MASK32
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

        for t = 1, 64 do
            local S1 = ROTR(e, 6) ~ ROTR(e, 11) ~ ROTR(e, 25)
            local ch = (e & f) ~ ((~e & MASK32) & g)
            local temp1 = (h + S1 + ch + K[t] + w[t]) & MASK32
            local S0 = ROTR(a, 2) ~ ROTR(a, 13) ~ ROTR(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local temp2 = (S0 + maj) & MASK32

            h = g
            g = f
            f = e
            e = (d + temp1) & MASK32
            d = c
            c = b
            b = a
            a = (temp1 + temp2) & MASK32
        end

        h0 = (h0 + a) & MASK32
        h1 = (h1 + b) & MASK32
        h2 = (h2 + c) & MASK32
        h3 = (h3 + d) & MASK32
        h4 = (h4 + e) & MASK32
        h5 = (h5 + f) & MASK32
        h6 = (h6 + g) & MASK32
        h7 = (h7 + h) & MASK32
    end

    return h0, h1, h2, h3, h4, h5, h6, h7
end

--- Girdinin küçük harf 64-karakter hex SHA-256 digest'ini döner.
function sha256.hex(str)
    local h0, h1, h2, h3, h4, h5, h6, h7 = RawDigest(str)
    return ('%08x%08x%08x%08x%08x%08x%08x%08x'):format(h0, h1, h2, h3, h4, h5, h6, h7)
end

_G.sha256 = sha256

return sha256
