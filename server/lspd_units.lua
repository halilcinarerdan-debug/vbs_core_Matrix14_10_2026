-- =====================================================================
-- MATRIX LSPD UNITS / server/lspd_units.lua — v1 (FAZ 2.4)
-- Aranma sistemi + kalıcı bölge mührü + 5 birim iskelet
--
-- TASARIM KARARLARI (Şef onayı):
--   1. Tetikleyici: raid VEYA 3+ tanıklı cinayet (ikisi de)
--   2. Sealed zone: 75m yarıçap, 7 gün, max 10 zone, koordinat ölümü
--   3. 5 birim: Asayis + Narkotik + Mali + Siber + Istihbarat
--   4. İkisi de: oyuncu + AI simetri
--
-- 0 RNG. Deterministik.
-- =====================================================================

Matrix.LSPD = Matrix.LSPD or {}

-- ── Config default (Config.LSPD varsa oradan okur) ──
local CFG = (Config and Config.LSPD) or {}
local SEAL_RADIUS_M      = CFG.SealRadiusMeters or 75.0
local SEAL_DURATION_DAYS = CFG.SealDurationDays or 7
local MAX_SEALED_ZONES   = CFG.MaxSealedZones or 10
local RAID_SEAL_RADIUS_M = CFG.RaidSealRadiusMeters or 100.0
local WANTED_MIN_WITNESS = CFG.WantedMinWitnesses or 3
local WANTED_MIN_CONF    = CFG.WantedMinConfidence or 0.85

-- RAM caches
Matrix.LSPD.SealedZones      = {}  -- [zoneId] = {...}
Matrix.LSPD.WantedByPerson   = {}  -- [kind:person_id] = {...}
Matrix.LSPD.ZoneCheckTicker  = 0

local SECONDS_PER_DAY = 86400

-- =====================================================================
-- UTILITY
-- =====================================================================
local function _NowEpoch() return os.time() end

local function _DistSq(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return dx*dx + dy*dy + dz*dz
end

local function _PersonKey(kind, id)
    return tostring(kind or '?') .. ':' .. tostring(id or '?')
end

-- =====================================================================
-- ★ YÜKLEME — boot'ta sealed zone + wanted listesi RAM'e
-- =====================================================================
function Matrix.LSPD.LoadFromDB()
    -- Süresi geçmiş zone'ları pasifleştir
    local nowEpoch = _NowEpoch()
    pcall(function()
        MySQL.query.await(
            'UPDATE matrix_sealed_zones SET active = 0 WHERE active = 1 AND sealed_until_epoch <= ?',
            { nowEpoch })
    end)

    -- Aktif zone'ları RAM'e al
    local zones = {}
    pcall(function()
        zones = MySQL.query.await([[
            SELECT id, coord_x, coord_y, coord_z, radius_m, reason,
                   source_trap_id, source_crime_id,
                   sealed_at, sealed_until_epoch
            FROM matrix_sealed_zones WHERE active = 1
        ]], {}) or {}
    end)

    for _, row in ipairs(zones) do
        Matrix.LSPD.SealedZones[tonumber(row.id)] = {
            id          = tonumber(row.id),
            coords      = vector3(tonumber(row.coord_x) or 0.0,
                                  tonumber(row.coord_y) or 0.0,
                                  tonumber(row.coord_z) or 0.0),
            radius_m    = tonumber(row.radius_m) or SEAL_RADIUS_M,
            reason      = row.reason,
            trap_id     = row.source_trap_id and tonumber(row.source_trap_id) or nil,
            crime_id    = row.source_crime_id and tonumber(row.source_crime_id) or nil,
            until_epoch = tonumber(row.sealed_until_epoch) or 0,
        }
    end

    -- Aktif wanted listesini RAM'e al
    local wanted = {}
    pcall(function()
        wanted = MySQL.query.await([[
            SELECT id, person_kind, person_id, person_dna, person_citizenid,
                   heat_level, reason, issued_by_unit, issued_at
            FROM matrix_wanted_persons WHERE cleared = 0
        ]], {}) or {}
    end)

    for _, row in ipairs(wanted) do
        local key = _PersonKey(row.person_kind, row.person_id)
        Matrix.LSPD.WantedByPerson[key] = {
            id         = tonumber(row.id),
            kind       = row.person_kind,
            person_id  = row.person_id,
            dna        = row.person_dna,
            citizenid  = row.person_citizenid,
            heat       = tonumber(row.heat_level) or 1,
            reason     = row.reason,
            unit       = row.issued_by_unit,
        }
    end

    Matrix.Log('LSPD',
        '%d aktif bolge muhru + %d aranan kisi RAM onbellege alindi.',
        #zones, #wanted)
end

CreateThread(function()
    Wait(2000)
    pcall(Matrix.LSPD.LoadFromDB)
end)

-- =====================================================================
-- ★ BÖLGE MÜHRÜ — SealTrapHouse
-- =====================================================================
function Matrix.LSPD.SealTrapHouse(trapId, reason)
    trapId = tonumber(trapId)
    if not trapId then return false, 'bad_trap_id' end
    if type(reason) ~= 'string' or reason == '' then reason = 'raid' end

    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapId]
    if not house then return false, 'trap_missing' end

    -- Max zone cap
    local activeCount = 0
    for _ in pairs(Matrix.LSPD.SealedZones) do activeCount = activeCount + 1 end
    if activeCount >= MAX_SEALED_ZONES then
        Matrix.Log('LSPD', '[CAP] Max sealed zone sayisina ulasildi (%d), yeni seal reddedildi.', MAX_SEALED_ZONES)
        return false, 'max_zones_reached'
    end

    local nowEpoch = _NowEpoch()
    local untilEpoch = nowEpoch + (SEAL_DURATION_DAYS * SECONDS_PER_DAY)
    local coords = house.coords

    -- Sebep: raid → 100m, cinayet → 75m
    local radius = (reason == 'raid') and RAID_SEAL_RADIUS_M or SEAL_RADIUS_M

    local zoneId = nil
    pcall(function()
        zoneId = MySQL.insert.await([[
            INSERT INTO matrix_sealed_zones
                (coord_x, coord_y, coord_z, radius_m, reason,
                 source_trap_id, sealed_at, sealed_until_epoch, active)
            VALUES (?, ?, ?, ?, ?, ?, NOW(), ?, 1)
        ]], {
            coords.x, coords.y, coords.z, radius,
            reason, trapId, untilEpoch,
        })
    end)

    if not zoneId then
        Matrix.Log('LSPD', '[HATA] sealed_zone INSERT basarisiz (trap#%d)', trapId)
        return false, 'db_error'
    end

    -- RAM'e ekle
    Matrix.LSPD.SealedZones[zoneId] = {
        id          = zoneId,
        coords      = vector3(coords.x, coords.y, coords.z),
        radius_m    = radius,
        reason      = reason,
        trap_id     = trapId,
        until_epoch = untilEpoch,
    }

    -- Trap house'u sealed işaretle
    house.sealed             = true
    house.sealed_at_epoch    = nowEpoch
    house.sealed_until_epoch = untilEpoch
    house.sealed_reason      = reason
    house.sealed_zone_id     = zoneId

    pcall(function()
        MySQL.prepare([[
            UPDATE matrix_trap_houses
            SET sealed = 1, sealed_at_epoch = ?, sealed_until_epoch = ?,
                sealed_reason = ?, sealed_zone_id = ?
            WHERE id = ?
        ]], { nowEpoch, untilEpoch, reason, zoneId, trapId })
    end)

    -- LSPD log
    pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_lspd_activity_log
                (unit_code, action, target_kind, target_id,
                 coord_x, coord_y, coord_z, detail, created_at)
            VALUES ('istihbarat', 'zone_sealed', 'trap', ?, ?, ?, ?, ?, NOW())
        ]], {
            tostring(trapId), coords.x, coords.y, coords.z,
            ('reason=%s radius=%.0fm duration=%dd'):format(reason, radius, SEAL_DURATION_DAYS),
        })
    end)

    Matrix.Log('LSPD',
        '[BOLGE MUHRU] Trap #%d (%.1f,%.1f,%.1f) kilitlendi: %s, r=%.0fm, %d gun.',
        trapId, coords.x, coords.y, coords.z, reason, radius, SEAL_DURATION_DAYS)

    return true, { zone_id = zoneId, until_epoch = untilEpoch, radius_m = radius }
end

-- =====================================================================
-- ★ BÖLGE KONTROLÜ — IsZoneSealed
-- =====================================================================
function Matrix.LSPD.IsZoneSealed(coords)
    if not coords then return false, nil end
    local nowEpoch = _NowEpoch()

    for zoneId, zone in pairs(Matrix.LSPD.SealedZones) do
        if zone.until_epoch > nowEpoch then
            local dSq  = _DistSq(coords, zone.coords)
            local rSq  = zone.radius_m * zone.radius_m
            if dSq <= rSq then
                return true, zone.reason, zoneId, zone.until_epoch
            end
        end
    end
    return false, nil
end

-- =====================================================================
-- ★ ARANMA — IssueWantedForCrime (cinayet zincirinden çağrılır)
-- =====================================================================
function Matrix.LSPD.IssueWantedForCrime(crimeInfo)
    if type(crimeInfo) ~= 'table' then return false, 'bad_args' end

    local killerKind = crimeInfo.killer_kind
    local killerId   = crimeInfo.killer_id
    local killerDna  = crimeInfo.killer_dna
    local killerCid  = crimeInfo.killer_citizenid

    -- Self/environment cinayeti aranma açmaz
    if not killerKind or killerKind == 'self_or_environment'
       or killerKind == 'unknown' or not killerId then
        return false, 'no_killer'
    end

    -- Eşik kontrolü (deterministik)
    local wcount = tonumber(crimeInfo.witness_count) or 0
    local conf   = tonumber(crimeInfo.confidence) or 0.0
    if wcount < WANTED_MIN_WITNESS or conf < WANTED_MIN_CONF then
        return false, 'threshold_not_met'
    end

    local key = _PersonKey(killerKind, killerId)
    local existing = Matrix.LSPD.WantedByPerson[key]

    -- Zaten aranıyorsa heat_level'i artır (max 5)
    if existing then
        existing.heat = math.min(5, (existing.heat or 1) + 1)
        pcall(function()
            MySQL.prepare(
                'UPDATE matrix_wanted_persons SET heat_level = ? WHERE id = ?',
                { existing.heat, existing.id })
        end)
        Matrix.Log('LSPD',
            '[ARANMA] %s heat %d yildiza yukseldi (mevcut kayit)', key, existing.heat)
        return true, { id = existing.id, heat = existing.heat, updated = true }
    end

    -- Yeni kayıt
    local crimeIdsJson = '[]'
    if crimeInfo.crime_ids then
        local ok, encoded = pcall(json.encode, crimeInfo.crime_ids)
        if ok then crimeIdsJson = encoded end
    end

    local unitCode = 'istihbarat'  -- Cinayet → İstihbarat birimi
    local issuedId = nil

    pcall(function()
        issuedId = MySQL.insert.await([[
            INSERT INTO matrix_wanted_persons
                (person_kind, person_id, person_dna, person_citizenid,
                 crime_ids, heat_level, reason, issued_by_unit, issued_at, cleared)
            VALUES (?, ?, ?, ?, ?, 3, 'murder', ?, NOW(), 0)
        ]], {
            killerKind, tostring(killerId), killerDna, killerCid,
            crimeIdsJson, unitCode,
        })
    end)

    if not issuedId then
        Matrix.Log('LSPD', '[HATA] wanted INSERT basarisiz (%s)', key)
        return false, 'db_error'
    end

    Matrix.LSPD.WantedByPerson[key] = {
        id        = issuedId,
        kind      = killerKind,
        person_id = tostring(killerId),
        dna       = killerDna,
        citizenid = killerCid,
        heat      = 3,
        reason    = 'murder',
        unit      = unitCode,
    }

    pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_lspd_activity_log
                (unit_code, action, target_kind, target_id, target_dna, detail, created_at)
            VALUES (?, 'wanted_issued', ?, ?, ?, ?, NOW())
        ]], {
            unitCode, killerKind, tostring(killerId), killerDna,
            ('witness=%d conf=%.3f'):format(wcount, conf),
        })
    end)

    Matrix.Log('LSPD',
        '[ARANMA] %s (dna=%s) ARANIYOR -- unit=%s heat=3 witness=%d conf=%.3f',
        key, tostring(killerDna), unitCode, wcount, conf)

    return true, { id = issuedId, heat = 3, updated = false }
end

-- =====================================================================
-- ★ ARANMA TEMİZLEME — ClearWanted
-- =====================================================================
function Matrix.LSPD.ClearWanted(kind, id, reason)
    local key = _PersonKey(kind, id)
    local rec = Matrix.LSPD.WantedByPerson[key]
    if not rec then return false, 'not_wanted' end

    pcall(function()
        MySQL.prepare([[
            UPDATE matrix_wanted_persons
            SET cleared = 1, cleared_at = NOW(), cleared_reason = ?
            WHERE id = ?
        ]], { tostring(reason or 'unknown'), rec.id })
    end)

    pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_lspd_activity_log
                (unit_code, action, target_kind, target_id, target_dna, detail, created_at)
            VALUES (?, 'wanted_cleared', ?, ?, ?, ?, NOW())
        ]], {
            rec.unit or 'istihbarat', kind, tostring(id), rec.dna,
            ('reason=%s'):format(tostring(reason or 'unknown')),
        })
    end)

    Matrix.LSPD.WantedByPerson[key] = nil
    Matrix.Log('LSPD', '[TEMIZLENDI] %s aranmasi kaldirildi (sebep=%s)',
        key, tostring(reason or 'unknown'))

    return true
end

-- =====================================================================
-- ★ ARANMA KONTROL — IsWanted
-- =====================================================================
function Matrix.LSPD.IsWanted(kind, id)
    local key = _PersonKey(kind, id)
    local rec = Matrix.LSPD.WantedByPerson[key]
    if rec then return true, rec.heat or 1 end
    return false, 0
end

-- =====================================================================
-- ★ TICK — Süresi geçmiş zone'ları pasifleştir (30 sn)
-- =====================================================================
CreateThread(function()
    while true do
        Wait(30000)
        local nowEpoch = _NowEpoch()
        local toRemove = {}

        for zoneId, zone in pairs(Matrix.LSPD.SealedZones) do
            if zone.until_epoch <= nowEpoch then
                toRemove[#toRemove + 1] = zoneId
            end
        end

        for _, zoneId in ipairs(toRemove) do
            local zone = Matrix.LSPD.SealedZones[zoneId]
            Matrix.LSPD.SealedZones[zoneId] = nil

            pcall(function()
                MySQL.prepare(
                    'UPDATE matrix_sealed_zones SET active = 0 WHERE id = ?',
                    { zoneId })
            end)

            if zone and zone.trap_id then
                local house = Matrix.TrapHouses and Matrix.TrapHouses[zone.trap_id]
                if house then
                    house.sealed = false
                    pcall(function()
                        MySQL.prepare([[
                            UPDATE matrix_trap_houses
                            SET sealed = 0, sealed_until_epoch = NULL
                            WHERE id = ?
                        ]], { zone.trap_id })
                    end)
                end
            end

            Matrix.Log('LSPD', '[MUHR KALKTI] Zone #%d suresi doldu.', zoneId)
        end
    end
end)

-- =====================================================================
-- CHAOS + DIAGNOSTICS
-- =====================================================================
CreateThread(function()
    local waited = 0
    while waited < 5000 do
        if Matrix.Chaos and Matrix.Chaos.RegisterModule
           and Matrix.Diagnostics and Matrix.Diagnostics.RegisterCheck then
            break
        end
        Wait(200); waited = waited + 200
    end

    if Matrix.Chaos and Matrix.Chaos.RegisterModule then

        -- ── Chaos: lspd_seal_test ──
        Matrix.Chaos.RegisterModule('lspd_seal_test',
            'FAZ 2.4 — Bolge muhru + IsZoneSealed kontrolu', function()

            local A = Matrix.Chaos.Assert
            A.SetContext('lspd_seal_test', 'server/lspd_units.lua')

            A.NotNil(Matrix.LSPD,                       'lspd_module')
            A.NotNil(Matrix.LSPD.SealTrapHouse,         'seal_api')
            A.NotNil(Matrix.LSPD.IsZoneSealed,          'is_sealed_api')
            A.NotNil(Matrix.LSPD.SealedZones,           'sealed_zones_ram')

            -- Trap house al
            local trapId
            for id in pairs(Matrix.TrapHouses or {}) do trapId = id; break end
            if not trapId then
                Matrix.Chaos.Report('MEDIUM', 'lspd_seal_test: trap yok', { impact = 'Atlandi' })
                return
            end

            local house = Matrix.TrapHouses[trapId]
            local beforeCount = 0
            for _ in pairs(Matrix.LSPD.SealedZones) do beforeCount = beforeCount + 1 end

            -- Seal uygula
            local ok, result = Matrix.LSPD.SealTrapHouse(trapId, 'raid')
            A.Equal(ok, true, 0, 'seal_success')

            Wait(300)

            -- Zone sayısı arttı mı?
            local afterCount = 0
            for _ in pairs(Matrix.LSPD.SealedZones) do afterCount = afterCount + 1 end
            A.Equal(afterCount, beforeCount + 1, 0, 'zone_count_increased')

            -- IsZoneSealed aynı koordinatta true dönmeli
            local sealed, reason, zoneId = Matrix.LSPD.IsZoneSealed(house.coords)
            A.Equal(sealed, true, 0, 'zone_sealed_positive')
            print(('[CHAOS][lspd_seal] KANIT: seal(trap#%d) -> zone#%s reason=%s radius=%.0fm'):format(
                trapId, tostring(zoneId), tostring(reason), result and result.radius_m or 0))

            -- Uzak koordinat false dönmeli (1000m öte)
            local farCoord = vector3(house.coords.x + 1000.0, house.coords.y + 1000.0, house.coords.z)
            local farSealed = Matrix.LSPD.IsZoneSealed(farCoord)
            A.Equal(farSealed, false, 0, 'zone_sealed_negative')

            -- Temizlik
            if zoneId then
                Matrix.LSPD.SealedZones[zoneId] = nil
                pcall(function()
                    MySQL.prepare('UPDATE matrix_sealed_zones SET active = 0 WHERE id = ?', { zoneId })
                end)
            end
            house.sealed = false
            pcall(function()
                MySQL.prepare(
                    'UPDATE matrix_trap_houses SET sealed = 0, sealed_zone_id = NULL WHERE id = ?',
                    { trapId })
            end)

            Matrix.Chaos.Report('INFO', 'lspd_seal_test tamamlandi', {
                attack = 'SealTrapHouse + IsZoneSealed pozitif/negatif',
                impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
            })
        end)

        -- ── Chaos: lspd_wanted_test ──
        Matrix.Chaos.RegisterModule('lspd_wanted_test',
            'FAZ 2.4 — Aranma listesi + esik kontrolu', function()

            local A = Matrix.Chaos.Assert
            A.SetContext('lspd_wanted_test', 'server/lspd_units.lua')

            A.NotNil(Matrix.LSPD.IssueWantedForCrime, 'issue_wanted_api')
            A.NotNil(Matrix.LSPD.IsWanted,            'is_wanted_api')
            A.NotNil(Matrix.LSPD.ClearWanted,         'clear_wanted_api')

            -- ── TEST 1: eşik altı → reddedilmeli
            local fakeKillerId = 'CHAOS-WANTED-TEST-1'
            local ok1, reason1 = Matrix.LSPD.IssueWantedForCrime({
                killer_kind     = 'bot',
                killer_id       = fakeKillerId,
                killer_dna      = 'DNA-CHAOS-W1',
                witness_count   = 2,    -- eşik 3
                confidence      = 0.90,
            })
            A.Equal(ok1, false, 0, 'under_threshold_rejected')
            print(('[CHAOS][lspd_wanted] Esik alti reddedildi: %s'):format(tostring(reason1)))

            -- ── TEST 2: eşik üstü → kabul
            local ok2, result2 = Matrix.LSPD.IssueWantedForCrime({
                killer_kind     = 'bot',
                killer_id       = fakeKillerId,
                killer_dna      = 'DNA-CHAOS-W1',
                witness_count   = 3,
                confidence      = 0.90,
            })
            A.Equal(ok2, true, 0, 'over_threshold_accepted')

            Wait(300)

            -- ── TEST 3: IsWanted pozitif
            local wanted, heat = Matrix.LSPD.IsWanted('bot', fakeKillerId)
            A.Equal(wanted, true, 0, 'is_wanted_positive')
            A.GreaterThan(heat, 0, 'heat_positive')
            print(('[CHAOS][lspd_wanted] KANIT: %s ARANIYOR heat=%d'):format(fakeKillerId, heat))

            -- ── TEST 4: heat artışı (aynı kişi tekrar)
            local ok3 = Matrix.LSPD.IssueWantedForCrime({
                killer_kind     = 'bot',
                killer_id       = fakeKillerId,
                killer_dna      = 'DNA-CHAOS-W1',
                witness_count   = 3,
                confidence      = 0.90,
            })
            A.Equal(ok3, true, 0, 'repeat_accepted')
            local _, heat2 = Matrix.LSPD.IsWanted('bot', fakeKillerId)
            A.GreaterThan(heat2, heat, 'heat_increased')
            print(('[CHAOS][lspd_wanted] Heat artisi: %d -> %d'):format(heat, heat2))

            -- ── TEST 5: self_or_environment reddedilmeli
            local ok4, reason4 = Matrix.LSPD.IssueWantedForCrime({
                killer_kind     = 'self_or_environment',
                killer_id       = nil,
                witness_count   = 3,
                confidence      = 0.90,
            })
            A.Equal(ok4, false, 0, 'self_env_rejected')
            print(('[CHAOS][lspd_wanted] Self/env reddedildi: %s'):format(tostring(reason4)))

            -- ── TEST 6: ClearWanted
            local ok5 = Matrix.LSPD.ClearWanted('bot', fakeKillerId, 'test_cleanup')
            A.Equal(ok5, true, 0, 'clear_success')

            local wantedAfter = Matrix.LSPD.IsWanted('bot', fakeKillerId)
            A.Equal(wantedAfter, false, 0, 'is_wanted_after_clear')

            Matrix.Chaos.Report('INFO', 'lspd_wanted_test tamamlandi', {
                attack = 'Aranma esik + heat + temizleme',
                impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
            })
        end)

        print('[LSPD] Chaos modulleri kayit edildi (lspd_seal_test, lspd_wanted_test)')
    end

    if Matrix.Diagnostics and type(Matrix.Diagnostics.RegisterCheck) == 'function' then

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.4] LSPD modulu yuklendi', function()
            if type(Matrix.LSPD) ~= 'table' then return false, 'tablo degil' end
            if type(Matrix.LSPD.SealTrapHouse) ~= 'function' then return false, 'SealTrapHouse yok' end
            if type(Matrix.LSPD.IsZoneSealed) ~= 'function' then return false, 'IsZoneSealed yok' end
            if type(Matrix.LSPD.IssueWantedForCrime) ~= 'function' then return false, 'IssueWantedForCrime yok' end
            if type(Matrix.LSPD.ClearWanted) ~= 'function' then return false, 'ClearWanted yok' end
            return true, ('seal_radius=%.0fm duration=%dd max=%d'):format(
                SEAL_RADIUS_M, SEAL_DURATION_DAYS, MAX_SEALED_ZONES)
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.4] LSPD math.random YOK', function()
            local src = LoadResourceFile(GetCurrentResourceName(), 'server/lspd_units.lua')
            if type(src) ~= 'string' then return false, 'okunamadi' end
            for line in src:gmatch('[^\n]*') do
                local c = line:match('^([^%-]*)') or ''
                if c:find('math%.random%s*%(') then
                    return false, ('math.random: %s'):format(line:sub(1, 60))
                end
            end
            return true, 'temiz'
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.4] LSPD tablolari mevcut', function()
            if type(MySQL) ~= 'table' then return false, 'MySQL yok' end

            local tables = { 'matrix_sealed_zones', 'matrix_wanted_persons',
                             'matrix_lspd_units', 'matrix_lspd_activity_log' }
            for _, t in ipairs(tables) do
                local ok, rows = pcall(function()
                    return MySQL.query.await([[
                        SELECT COLUMN_NAME FROM information_schema.columns
                        WHERE table_schema = DATABASE() AND table_name = ?
                    ]], { t })
                end)
                if not ok or type(rows) ~= 'table' or #rows == 0 then
                    return false, ('tablo eksik: %s (MASTER.sql FAZ 2.4 blogu calistirildi mi?)'):format(t)
                end
            end
            return true, '4 tablo mevcut'
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.4] LSPD 5 birim seed', function()
            local ok, row = pcall(function()
                return MySQL.single.await(
                    'SELECT COUNT(*) AS c FROM matrix_lspd_units WHERE active = 1', {})
            end)
            if not ok or not row then return false, 'sorgu hatasi' end
            local n = tonumber(row.c) or 0
            if n ~= 5 then
                return false, ('5 birim beklenirken %d bulundu'):format(n)
            end
            return true, 'Asayis+Narkotik+Mali+Siber+Istihbarat aktif'
        end)
    end
end)

print('[LSPD] FAZ 2.4 armed — aranma + bolge muhru + 5 birim.')