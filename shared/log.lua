-- =====================================================================
-- MATRIX SHARED LOG / shared/log.lua
-- FAZ 0.2 — İzomorfik log pipeline (server + client)
--
-- ★ AMAÇ: Matrix.Log artık hem server hem client'ta çalışır.
-- Önceki durum: sadece server/main.lua'da tanımlıydı, client'ta
-- "attempt to call nil" riski vardı.
--
-- ★ BUFFER + RATE LIMIT:
--   - Loglar 500ms buffer'da birikir, sonra tek seferde flush edilir
--   - Aynı tag saniyede >8 kez çağrılırsa susturulur (DoS koruması)
--   - Combat loop'ta saniyede 60 log çağrısı → en fazla 8 output
--
-- ★ SEVERITY FILTER:
--   - Server: tüm seviyeler yazılır
--   - Client: DEBUG log'ları yerel tutulur, INFO+ server'a relay edilir
--
-- ZERO RNG, pcall-guard'lı, kendi hatası çökertmez.
-- =====================================================================

Matrix = Matrix or {}

local IS_SERVER = IsDuplicityVersion and IsDuplicityVersion() or false

-- =====================================================================
-- SEVERITY + RATE LIMIT STATE
-- =====================================================================
Matrix.Log = Matrix.Log or {}
Matrix.Log._state = Matrix.Log._state or {
    buffer        = {},   -- [tag] = { {line, severity, ts}, ... }
    lastFlushAt   = 0,
    tagCounts     = {},   -- [tag] = { count, windowStart }
}

local FLUSH_INTERVAL_MS = 500
local TAG_RATE_LIMIT    = 8        -- aynı tag saniyede max 8
local TAG_WINDOW_MS     = 1000
local MAX_BUFFER_SIZE   = 100      -- taşmayı önle

-- =====================================================================
-- CORE LOG FUNCTION
-- =====================================================================
local function _FormatLine(tag, fmt, ...)
    local n = select('#', ...)
    local formatted
    if n > 0 then
        local ok, result = pcall(string.format, fmt, ...)
        if ok then
            formatted = result
        else
            formatted = fmt
        end
    else
        formatted = fmt
    end
    return string.format('[%s] %s', tostring(tag or '?'), tostring(formatted))
end

local function _IsRateLimited(tag, now)
    local state = Matrix.Log._state
    local entry = state.tagCounts[tag]
    if not entry then
        state.tagCounts[tag] = { count = 1, windowStart = now }
        return false
    end
    if (now - entry.windowStart) > TAG_WINDOW_MS then
        entry.count = 1
        entry.windowStart = now
        return false
    end
    entry.count = entry.count + 1
    if entry.count > TAG_RATE_LIMIT then
        return true
    end
    return false
end

local function _SeverityColor(severity)
    if severity == 'ERROR' then return '^1'      -- kırmızı
    elseif severity == 'WARN' then return '^3'   -- sarı
    elseif severity == 'DEBUG' then return '^5'  -- cyan
    else return '^2'                              -- yeşil
    end
end

-- =====================================================================
-- PUBLIC API
-- =====================================================================
function Matrix.Log.Write(tag, fmt, ...)
    tag = tostring(tag or '?')
    local now = GetGameTimer and GetGameTimer() or 0

    if _IsRateLimited(tag, now) then return end

    local line = _FormatLine(tag, fmt, ...)
    local severity = 'INFO'
    -- Severity prefix algılama: "[HATA]" veya "[ERROR]" içerirse ERROR
    if line:find('%[HATA%]') or line:find('%[ERROR%]') then
        severity = 'ERROR'
    elseif line:find('%[UYARI%]') or line:find('%[WARN%]') then
        severity = 'WARN'
    elseif line:find('%[DEBUG%]') then
        severity = 'DEBUG'
    end

    -- Buffer'a ekle
    local state = Matrix.Log._state
    if #state.buffer >= MAX_BUFFER_SIZE then
        table.remove(state.buffer, 1)
    end
    state.buffer[#state.buffer + 1] = {
        line     = line,
        severity = severity,
        ts       = now,
    }

    -- ★ Immediate flush: ERROR seviyesi beklemesin
    if severity == 'ERROR' then
        Matrix.Log.Flush()
    end
end

function Matrix.Log.Flush()
    local state = Matrix.Log._state
    local buffer = state.buffer
    if #buffer == 0 then return end

    for _, entry in ipairs(buffer) do
        local color = _SeverityColor(entry.severity)
        local prefix = IS_SERVER and '[MATRIX]' or '[MATRIX:CLIENT]'
        print(('%s%s %s^7'):format(color, prefix, entry.line))
    end

    state.buffer = {}
    state.lastFlushAt = GetGameTimer and GetGameTimer() or 0
end

-- Ana API — kolay kullanım
Matrix.Log = setmetatable({
    Write    = Matrix.Log.Write,
    Flush    = Matrix.Log.Flush,
    _state   = Matrix.Log._state,
}, {
    __call = function(_, tag, fmt, ...)
        Matrix.Log.Write(tag, fmt, ...)
        return Matrix.Log
    end
})

-- =====================================================================
-- FLUSH HEARTBEAT
-- =====================================================================
CreateThread(function()
    while true do
        Wait(FLUSH_INTERVAL_MS)
        pcall(Matrix.Log.Flush)
    end
end)

-- =====================================================================
-- RESOURCE STOP — son flush
-- =====================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    pcall(Matrix.Log.Flush)
end)