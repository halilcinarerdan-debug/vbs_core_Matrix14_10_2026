-- =====================================================================
-- MATRIX WANTED BRIDGE / server/wanted_bridge.lua
-- [FAZ 1.5 — ARCADE TEMİZLİĞİ]
--
-- Client'tan gelen yıldız bilgisini OKUR ve büro/zone/pattern
-- tablolarına bağlar.
--
-- Akış:
--   1) Client 5sn'de bir yıldız sayısını bildirir
--   2) Server en yakın trap house + zone bulur
--   3) Yıldız → Bureau.AdvanceDecryption (heat artışı)
--   4) Yıldız → matrix_zone_ledger.audit_anomaly_rate
--   5) Yıldız >= 3 → pattern log (cinayet tespiti)
--
-- FELSEFE: Oyuncu ne yapıyorsa AI'lar aynı yapabilir. Bu köprü
-- oyuncu suçunu BÜRO'ya öğretir — tıpkı AI suçunun öğretildiği gibi.
-- =====================================================================

if not Config.Features or Config.Features.WantedBridge == false then
    print('[WANTED_BRIDGE:SERVER] Devre disi (Config.Features.WantedBridge = false)')
    return
end

local RATE_LIMIT_MS       = 3000   -- src başına minimum rapor aralığı
local HEAT_PER_STAR       = 0.002  -- yıldız başına heat artışı
local ANOMALY_PER_STAR    = 0.01   -- yıldız başına anomaly rate artışı
local CINEMA_PATTERN_STAR = 3      -- bu yıldız ve üstü cinayet pattern log tetikler

local _lastReportAt = {}  -- [src] = GetGameTimer()

local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math.huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        if house.coords then
            local dx = house.coords.x - coords.x
            local dy = house.coords.y - coords.y
            local dz = house.coords.z - coords.z
            local d  = math.sqrt(dx*dx + dy*dy + dz*dz)
            if d < nearestDist then nearestId, nearestDist = id, d end
        end
    end
    return nearestId, nearestDist
end

RegisterNetEvent('matrix:server:wantedBridge:report', function(wantedLevel, coordsPayload)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    wantedLevel = tonumber(wantedLevel)
    if not wantedLevel or wantedLevel ~= wantedLevel then return end
    if wantedLevel < 0 then wantedLevel = 0 end
    if wantedLevel > 5 then wantedLevel = 5 end

    -- Rate limit (src başına)
    local now  = GetGameTimer()
    local last = _lastReportAt[src] or 0
    if (now - last) < RATE_LIMIT_MS then return end
    _lastReportAt[src] = now

    if wantedLevel == 0 then return end

    -- Konum: server-authoritative ped koordinatı
    local ped = GetPlayerPed(src)
    local realCoords = nil
    if ped and ped ~= 0 then
        local c = GetEntityCoords(ped)
        realCoords = { x = c.x, y = c.y, z = c.z }
    elseif type(coordsPayload) == 'table' then
        realCoords = coordsPayload
    end
    if not realCoords then return end

    local vec = vector3(realCoords.x, realCoords.y, realCoords.z)

    -- En yakın trap house (500m içindeyse kayıt düş)
    local houseId, houseDist = FindNearestTrapHouse(vec)
    if not houseId or houseDist > 500.0 then return end

    -- 1) Heat artışı
    if Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        pcall(Matrix.Bureau.AdvanceDecryption, houseId, wantedLevel * HEAT_PER_STAR)
    end

    -- 2) Zone anomaly rate
    local zoneId = Matrix.Market and Matrix.Market.FindNearestZone
        and Matrix.Market.FindNearestZone(vec)
    if zoneId then
        local gain = wantedLevel * ANOMALY_PER_STAR
        pcall(function()
            MySQL.prepare([[
                INSERT INTO matrix_zone_ledger (zone_id, audit_anomaly_rate, updated_at)
                VALUES (?, ?, NOW())
                ON DUPLICATE KEY UPDATE
                    audit_anomaly_rate = audit_anomaly_rate + ?,
                    updated_at         = NOW()
            ]], { zoneId, gain, gain })
        end)
    end

    -- 3) Cinayet pattern log
    if wantedLevel >= CINEMA_PATTERN_STAR and Matrix.Bureau
        and Matrix.Bureau.LogPatternEvent then
        pcall(Matrix.Bureau.LogPatternEvent, houseId)
    end

    Matrix.Log('WANTED_BRIDGE',
        '[OGRENME] src=%d yildiz=%d trap=#%d (%.1fm) zone=%s heat=+%.4f anomaly=+%.4f',
        src, wantedLevel, houseId, houseDist, tostring(zoneId or '-'),
        wantedLevel * HEAT_PER_STAR, wantedLevel * ANOMALY_PER_STAR)
end)

AddEventHandler('playerDropped', function()
    local src = source
    _lastReportAt[src] = nil
end)

print('[WANTED_BRIDGE:SERVER] Yildiz ogrenme kopru aktif.')