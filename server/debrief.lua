-- =====================================================================
-- MATRIX COMBAT LOG DEBRIEF — server/debrief.lua
-- Oyuncu quit → ortam değerlendirmesi → deterministik tehdit skoru → DB
-- CEZALANDIRMA YOK. Sadece farkındalık.
--
-- ★ Determinizm: jitter bile RNG DEĞİL — citizenid + son olay + severity
--   kombinasyonundan checksum ile türetilir. Aynı girdi → aynı çıktı.
--   Chaos "math.random taraması" temiz kalır.
-- =====================================================================

Matrix.Debrief = Matrix.Debrief or {}

local DECAY_WINDOW_SECONDS = 60
local COOLDOWN_MS          = 30000  -- aynı oyuncu 30sn throttle

local LastDebriefByCitizen = {}

-- ---------------------------------------------------------------------
-- Deterministik jitter — ±10 sınırı, RNG yok
-- ---------------------------------------------------------------------
function Matrix.Debrief.__ComputeJitter(citizenid, seedInt)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    if type(seedInt) ~= 'number' then seedInt = 0 end
    local raw = ('%s#%d#DEBRIEF'):format(citizenid, math.floor(seedInt))
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + 173))) % 0x7FFFFFFF
    end
    return (sum % 21) - 10   -- -10..+10
end

-- ---------------------------------------------------------------------
-- Son 60sn cinayet sayımı + ortalama confidence
-- ---------------------------------------------------------------------
local function QueryRecentCrimes(citizenid)
    local ok, row = pcall(function()
        return MySQL.single.await([[
            SELECT COUNT(*) AS n,
                   COALESCE(AVG(confidence_final), 0.0) AS avg_conf,
                   MAX(id) AS last_id
            FROM matrix_crime_log
            WHERE killer_citizenid = ?
              AND occurred_at >= (NOW() - INTERVAL ? SECOND)
        ]], { citizenid, DECAY_WINDOW_SECONDS })
    end)
    if not ok or type(row) ~= 'table' then
        return 0, 0.0, nil
    end
    return tonumber(row.n) or 0, tonumber(row.avg_conf) or 0.0, tonumber(row.last_id)
end

-- ---------------------------------------------------------------------
-- Yakın oyuncu sayımı (100m içindeki diğer oyuncular — tanık baskısı)
-- ---------------------------------------------------------------------
local function CountNearbyPlayers(coords)
    if not coords then return 0 end
    local count = 0
    for _, plySrc in ipairs(GetPlayers()) do
        local plyId = tonumber(plySrc)
        if plyId and plyId > 0 then
            local ped = GetPlayerPed(plyId)
            if ped and ped ~= 0 then
                local pcoords = GetEntityCoords(ped)
                if #(pcoords - coords) <= 100.0 then
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- ---------------------------------------------------------------------
-- Ana değerlendirme
-- ---------------------------------------------------------------------
function Matrix.Debrief.Evaluate(citizenid, coords, wantedLevel)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    -- ★ [DEFENSIVE] DB şeması VARCHAR(50); SQL data-too-long spam'ini önle.
    if #citizenid > 50 then return nil end

    -- Throttle (spam koruması)
    local now = GetGameTimer()
    local last = LastDebriefByCitizen[citizenid]
    if last and (now - last) < COOLDOWN_MS then return nil end
    LastDebriefByCitizen[citizenid] = now

    -- Faktörler
    wantedLevel = math.max(0, math.min(5, tonumber(wantedLevel) or 0))
    local crimes60s, avgConf, lastCrimeId = QueryRecentCrimes(citizenid)
    local nearbyPlayers = CountNearbyPlayers(coords)

    -- Ham tehdit skoru (0.0 - 1.0), kitaptaki 3 faktör
    local f_wanted = (wantedLevel / 5.0) * 0.40
    local f_crimes = math.min(crimes60s / 3.0, 1.0) * 0.35
    local f_police = math.min(nearbyPlayers / 3.0, 1.0) * 0.25
    local raw = (f_wanted + f_crimes + f_police) * 100.0
    raw = math.max(0.0, math.min(100.0, raw))

    -- Deterministik jitter
    local seedInt = (lastCrimeId or 0) * 1000 + crimes60s * 100 + math.floor(avgConf * 100)
    local jitter = Matrix.Debrief.__ComputeJitter(citizenid, seedInt)

    local final = math.floor(raw + jitter + 0.5)
    final = math.max(0, math.min(100, final))

        -- DB kayıt
    local insertOk, insertErr = pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_debrief_log
                (citizenid, final_score, raw_score, jitter,
                 wanted_level, crimes_60s, nearby_police, avg_crime_conf, last_crime_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], {
            citizenid, final, raw, jitter,
            wantedLevel, crimes60s, nearbyPlayers, avgConf, lastCrimeId
        })
    end)
    if not insertOk then
        Matrix.Log('DEBRIEF', '[HATA] insert basarisiz: %s', tostring(insertErr))
    end

    Matrix.Log('DEBRIEF',
        '[TANI] %s -> skor=%d (ham=%.1f jitter=%+d) | wanted=%d cinayet60=%d yakin=%d conf=%.3f',
        citizenid, final, raw, jitter, wantedLevel, crimes60s, nearbyPlayers, avgConf)

    return {
        score          = final,
        raw_score      = raw,
        jitter         = jitter,
        wanted_level   = wantedLevel,
        crimes_60s     = crimes60s,
        nearby_police  = nearbyPlayers,
        avg_crime_conf = avgConf,
    }
end

-- ---------------------------------------------------------------------
-- playerDropped hook — oyuncu quit atınca değerlendir
-- ---------------------------------------------------------------------
AddEventHandler('playerDropped', function(reason)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local ped = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil

    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src) or nil
    local citizenid = state and state.citizenid
    if not citizenid then return end

    -- wanted_level (QBCore metadata)
    local wantedLevel = 0
    pcall(function()
        local player = Matrix.QBX:GetPlayer(src)
        if player and player.PlayerData and player.PlayerData.metadata then
            wantedLevel = tonumber(player.PlayerData.metadata.wanted_level) or 0
        end
    end)

    -- Deferred evaluation — ped hâlâ geçerli olabilir, main thread bloklamasın
    CreateThread(function()
        pcall(Matrix.Debrief.Evaluate, citizenid, coords, wantedLevel)
    end)
end)

-- ---------------------------------------------------------------------
-- /debrief — son değerlendirmeyi gör
-- ---------------------------------------------------------------------
RegisterCommand('debrief', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    -- ★ [FIX] Guard pattern (tutarlılık — playerDropped ile aynı)
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src) or nil
    local citizenid = state and state.citizenid
    if not citizenid then return end

    local ok, row = pcall(function()
        return MySQL.single.await([[
            SELECT * FROM matrix_debrief_log
            WHERE citizenid = ?
            ORDER BY evaluated_at DESC LIMIT 1
        ]], { citizenid })
    end)
    if not ok then
        Matrix.Log('DEBRIEF', '[HATA] /debrief sorgu basarisiz: %s', tostring(row))
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[DEBRIEF]', 'Sorgu hatasi — tekrar deneyin.' }
        })
        return
    end

    TriggerClientEvent('chat:addMessage', src, {
        args = { '[DEBRIEF]',
            ('Tehdit Skoru: %d/100 (ham=%.1f jitter=%+d) | wanted=%d cinayet60=%d yakin=%d')
                :format(row.final_score, row.raw_score, row.jitter,
                        row.wanted_level, row.crimes_60s, row.nearby_police) }
    })
end, false)

-- Test/chaos için throttle resetleyici
function Matrix.Debrief.__ResetThrottle(citizenid)
    if type(citizenid) == 'string' then
        LastDebriefByCitizen[citizenid] = nil
    end
end

Matrix.Log('DEBRIEF', '[BOOT] Combat Log Debrief armed (deterministik jitter, 0 RNG).')