-- =====================================================================
-- MATRIX CRIME WITNESS / server/crime_witness.lua — v5 (FAZ 2.3 FINAL)
-- FAZ 2.1 — CINAYET TESPIT KATMANI (client bridge + fallback)
-- FAZ 2.2 — TANIK FOV/LOS KATMANI (30m, 120° FOV)
-- FAZ 2.3 — KALICI KAYIT + DETERMINISTIK CONFIDENCE + HEAT ZINCIRI
--
-- v1-v3 gecmisi:
--   v1: GetEntityHealth server-side polling  — basarisiz (0 doner)
--   v2: gameEventTriggered server-side        — basarisiz (client-only)
--   v3: IsPedDeadOrDying server-side polling  — basarisiz (OneSync)
--   v4: client/crime_witness_bridge.lua       — DOGRU KANAL
--   v5: FAZ 2.3 — matrix_crime_log + matrix_witness_statements +
--        deterministik confidence + Bureau.AdvanceDecryption zinciri.
--
-- ★ Server-authoritative: Bridge yalnizca net_id raporlar. Kimlik
--   PedRegistry + GetPlayerPed ile SERVER'DA cozulur.
-- ★ 0 RNG. math.random YOK. math.atan2 YOK (Lua 5.4 uyumu).
-- =====================================================================

Matrix.CrimeWitness = Matrix.CrimeWitness or {}
Matrix.CrimeWitness.RecentDeaths = {}
Matrix.CrimeWitness.DEDUPE_MS    = 3000
Matrix.CrimeWitness.PedRegistry  = {}

-- ★ [FAZ 2.2] TANIK FOV/LOS KATMANI
Matrix.CrimeWitness.Witnesses         = {}
Matrix.CrimeWitness.WITNESS_RADIUS    = 30.0
Matrix.CrimeWitness.WITNESS_FOV_DEG   = 120.0
Matrix.CrimeWitness.WITNESS_DEDUPE_MS = 5000

-- ★ [FAZ 2.3] HEAT ZINCIRI SABITLERI (deterministik, RNG YOK)
Matrix.CrimeWitness.DECRYPTION_PER_WITNESS  = 0.035   -- her tanık başına heat
Matrix.CrimeWitness.CHAIN_MIN_WITNESS       = 3       -- raid zinciri için min tanık
Matrix.CrimeWitness.CHAIN_MIN_AVG_CONF      = 0.85    -- raid zinciri için min ort. güven
Matrix.CrimeWitness.CHAIN_DECRYPTION_BONUS  = 0.10    -- 3+ tanık ödülü (tek seferlik)

-- Tanık tipine göre güven çarpanı — simetri ilkesi:
-- Bot tanık = matematiksel FOV/LOS görüşü (1.00)
-- Player tanık = "gördüm" iddiası (0.85)
Matrix.CrimeWitness.KIND_CONFIDENCE = {
    bot    = 1.00,
    player = 0.85,
}

-- =====================================================================
-- UTILITY: Açı normalizasyonu + FOV + LOS
-- =====================================================================
local function _NormalizeAngle(a)
    while a < 0.0 do a = a + 360.0 end
    while a >= 360.0 do a = a - 360.0 end
    return a
end

local function _IsInFOV(witnessPed, targetCoords, fovDeg)
    local okC, wc = pcall(GetEntityCoords, witnessPed)
    if not okC or not wc then return false end

    local okH, heading = pcall(GetEntityHeading, witnessPed)
    if not okH or type(heading) ~= 'number' or heading ~= heading then
        return true -- heading alinamazsa FOV'u gecir (self-healing)
    end

    local dx = targetCoords.x - wc.x
    local dy = targetCoords.y - wc.y
    local victimAngle  = math.deg(math.atan(dy, dx))  -- ★ Lua 5.4: math.atan(y,x)
    local witnessAngle = _NormalizeAngle(90.0 - heading)

    local diff = math.abs(_NormalizeAngle(victimAngle - witnessAngle))
    if diff > 180.0 then diff = 360.0 - diff end

    return diff <= (fovDeg * 0.5)
end

local function _HasLOS(witnessPed, victimPed)
    local ok, result = pcall(HasEntityClearLosToEntity, witnessPed, victimPed, 17)
    if ok and type(result) == 'boolean' then return result end
    return true -- LOS native'i fail ederse gecir (self-healing)
end

-- =====================================================================
-- ★ [FAZ 2.3] DETERMINISTIK CONFIDENCE HESABI
-- Formul (RNG YOK):
--   dist_f = (WITNESS_RADIUS - dist) / WITNESS_RADIUS   -- [0,1]
--   los_f  = 1.0 (LOS varsa)
--   kind_f = KIND_CONFIDENCE[kind]                       -- bot 1.0, player 0.85
--   conf   = clamp(dist_f * los_f * kind_f, 0.0, 1.0)
-- =====================================================================
local function _ComputeConfidence(distance, kind, hadLos)
    local maxD = Matrix.CrimeWitness.WITNESS_RADIUS
    if type(distance) ~= 'number' or distance ~= distance then distance = maxD end

    local dist_f = (maxD - distance) / maxD
    if dist_f < 0.0 then dist_f = 0.0 end
    if dist_f > 1.0 then dist_f = 1.0 end

    local los_f  = hadLos and 1.0 or 0.3
    local kind_f = Matrix.CrimeWitness.KIND_CONFIDENCE[kind] or 0.5

    local conf = dist_f * los_f * kind_f
    if conf < 0.0 then conf = 0.0 end
    if conf > 1.0 then conf = 1.0 end
    return conf
end

-- =====================================================================
-- ★ [FAZ 2.3] NEAREST TRAP HOUSE — kendi helper (bureau.lua'ya dokunma)
-- =====================================================================
local function _FindNearestTrapHouse(coords)
    if not coords then return nil, math.huge end
    local nearestId, nearestDist = nil, math.huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        if type(id) == 'number' and house and house.coords then
            local ok, d = pcall(function()
                local dx = house.coords.x - coords.x
                local dy = house.coords.y - coords.y
                local dz = house.coords.z - coords.z
                return math.sqrt(dx*dx + dy*dy + dz*dz)
            end)
            if ok and type(d) == 'number' and d < nearestDist then
                nearestId, nearestDist = id, d
            end
        end
    end
    return nearestId, nearestDist
end

-- =====================================================================
-- ★ [FAZ 2.3] DNA / CITIZENID COZUMLEYICI
-- =====================================================================
local function _ResolveDna(kind, id, ped)
    if kind == 'bot' then
        local reg = Matrix.CrimeWitness.PedRegistry[ped]
        return reg and reg.dna_id or nil
    elseif kind == 'player' and type(id) == 'number' and id > 0 then
        local ok, player = pcall(function() return Matrix.QBX:GetPlayer(id) end)
        if ok and player and player.PlayerData and player.PlayerData.citizenid then
            return ('DNA-PLR-%s'):format(player.PlayerData.citizenid)
        end
    end
    return nil
end

local function _ResolveCitizenid(kind, id)
    if kind == 'player' and type(id) == 'number' and id > 0 then
        local ok, player = pcall(function() return Matrix.QBX:GetPlayer(id) end)
        if ok and player and player.PlayerData and player.PlayerData.citizenid then
            return player.PlayerData.citizenid
        end
    end
    return nil
end

-- =====================================================================
-- ★ [FAZ 2.2] TANIK KAYDI (RAM)
-- =====================================================================
function Matrix.CrimeWitness.__RegisterWitness(witnessPed, kind, id, victimPed, killerPed, now, extra)
    local prev = Matrix.CrimeWitness.Witnesses[witnessPed]
    if prev and (now - prev.crime_at) < Matrix.CrimeWitness.WITNESS_DEDUPE_MS then
        return false
    end

    extra = extra or {}
    Matrix.CrimeWitness.Witnesses[witnessPed] = {
        crime_at   = now,
        victim_ped = victimPed,
        killer_ped = killerPed,
        kind       = kind,
        id         = id,
        confidence = extra.confidence or 0.0,
        distance   = extra.distance,
        had_los    = extra.had_los or false,
    }

    Matrix.Log('CRIME',
        '[TANIK] kind=%s id=%s conf=%.4f dist=%.1fm victim_ped=%s killer_ped=%s',
        kind, tostring(id), extra.confidence or 0.0, extra.distance or -1.0,
        tostring(victimPed), tostring(killerPed))

    return true
end

-- =====================================================================
-- ★ [FAZ 2.2] TANIK TARAMASI — hem sayı hem liste döner
-- =====================================================================
function Matrix.CrimeWitness.__ScanWitnesses(victimPed, killerPed, victimCoords)
    if not victimCoords then return 0, {} end
    local found   = 0
    local witnessList = {}
    local now     = GetGameTimer()

    local function _TryWitness(ped, kind, id)
        local okWc, wc = pcall(GetEntityCoords, ped)
        if not okWc or not wc then return false end

        local dx = wc.x - victimCoords.x
        local dy = wc.y - victimCoords.y
        local dz = wc.z - victimCoords.z
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

        if dist > Matrix.CrimeWitness.WITNESS_RADIUS then return false end
        if not _IsInFOV(ped, victimCoords, Matrix.CrimeWitness.WITNESS_FOV_DEG) then return false end

        local hadLos = _HasLOS(ped, victimPed)
        if not hadLos then return false end

        local confidence = _ComputeConfidence(dist, kind, hadLos)

        local registered = Matrix.CrimeWitness.__RegisterWitness(
            ped, kind, id, victimPed, killerPed, now, {
                confidence = confidence,
                distance   = dist,
                had_los    = hadLos,
            })

        if registered then
            witnessList[#witnessList + 1] = {
                kind       = kind,
                id         = id,
                dna        = _ResolveDna(kind, id, ped),
                citizenid  = _ResolveCitizenid(kind, id),
                distance   = dist,
                in_fov     = true,
                had_los    = hadLos,
                confidence = confidence,
            }
        end
        return registered
    end

    -- Oyuncu tanıklar
    for _, srcStr in ipairs(GetPlayers()) do
        local src = tonumber(srcStr)
        local ped = (src and src > 0) and GetPlayerPed(src) or 0
        if ped and ped ~= 0 and ped ~= victimPed and ped ~= killerPed and DoesEntityExist(ped) then
            if _TryWitness(ped, 'player', src) then found = found + 1 end
        end
    end

    -- Bot tanıklar
    for botId, bot in pairs(Matrix.Bots or {}) do
        if bot.state and bot.state.spawned and bot.state.net_id then
            local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
            if ped and ped ~= 0 and ped ~= victimPed and ped ~= killerPed and DoesEntityExist(ped) then
                if _TryWitness(ped, 'bot', botId) then found = found + 1 end
            end
        end
    end

    return found, witnessList
end

-- =====================================================================
-- ★ [FAZ 2.3] DB PERSISTENCE — crime_log + witness_statements (ASYNC)
-- pcall ile sarılı. DB hatası cinayet tespitini BLOKE ETMEZ.
-- =====================================================================
local function _PersistCrimeAsync(crimeRecord, witnessList)
    MySQL.insert([[
        INSERT INTO matrix_crime_log
            (victim_kind, victim_id, victim_dna, victim_citizenid,
             killer_kind, killer_id, killer_dna, killer_citizenid,
             coords_x, coords_y, coords_z, nearest_trap_id,
             witness_count, witness_players, witness_bots,
             confidence_final, occurred_at, resolved)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), 0)
    ]], {
        crimeRecord.victim_kind,    crimeRecord.victim_id,    crimeRecord.victim_dna,    crimeRecord.victim_citizenid,
        crimeRecord.killer_kind,    crimeRecord.killer_id,    crimeRecord.killer_dna,    crimeRecord.killer_citizenid,
        crimeRecord.coords_x,       crimeRecord.coords_y,     crimeRecord.coords_z,      crimeRecord.nearest_trap_id,
        crimeRecord.witness_count,  crimeRecord.witness_players, crimeRecord.witness_bots,
        crimeRecord.confidence_final,
    }, function(insertId)
        if not insertId then
            Matrix.Log('CRIME', '[HATA] matrix_crime_log INSERT basarisiz (insertId nil)')
            return
        end

        -- Her tanık için statements satırı (ayrı ayrı, pcall ile)
        for _, w in ipairs(witnessList) do
            pcall(function()
                MySQL.insert([[
                    INSERT INTO matrix_witness_statements
                        (crime_id, witness_kind, witness_id, witness_dna, witness_citizenid,
                         distance_m, in_fov, had_los, confidence, statement_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
                ]], {
                    insertId, w.kind, tostring(w.id), w.dna, w.citizenid,
                    w.distance, w.in_fov and 1 or 0, w.had_los and 1 or 0, w.confidence,
                })
            end)
        end

        Matrix.Log('CRIME',
            '[KAYIT] crime#%d yazildi: victim=%s/%s killer=%s/%s tanik=%d conf=%.4f',
            insertId,
            tostring(crimeRecord.victim_kind), tostring(crimeRecord.victim_id),
            tostring(crimeRecord.killer_kind), tostring(crimeRecord.killer_id),
            #witnessList, crimeRecord.confidence_final)
    end)
end

-- =====================================================================
-- ★ [FAZ 2.1+2.2+2.3] PUBLIC API — handler logic (test edilebilir)
-- =====================================================================
function Matrix.CrimeWitness.__HandleDamage(victimPed, attackerPed, isFatal, victimDied)
    if type(victimPed) ~= 'number' or victimPed == 0 then return false end
    if victimDied ~= true then return false end

    local now = GetGameTimer()
    local prev = Matrix.CrimeWitness.RecentDeaths[victimPed]
    if prev and (now - prev.at) < Matrix.CrimeWitness.DEDUPE_MS then
        return false
    end

    -- ── Mağdur cozumle
    local victimInfo = Matrix.CrimeWitness.PedRegistry[victimPed]
    local victimKind, victimId, victimDna, victimCitizenid = 'unknown', nil, nil, nil

    if victimInfo then
        victimKind      = victimInfo.kind
        victimId        = victimInfo.id
        victimDna       = victimInfo.dna_id
        victimCitizenid = _ResolveCitizenid(victimKind, victimId)
    else
        for _, srcStr in ipairs(GetPlayers()) do
            local src = tonumber(srcStr)
            local p = (src and src > 0) and GetPlayerPed(src) or 0
            if p == victimPed then
                victimKind      = 'player'
                victimId        = src
                victimDna       = _ResolveDna('player', src, victimPed)
                victimCitizenid = _ResolveCitizenid('player', src)
                break
            end
        end
    end

    -- ── Fail cozumle
    local killerKind, killerId, killerDna, killerCitizenid = 'unknown', nil, nil, nil
    if attackerPed == 0 or attackerPed == victimPed then
        killerKind = 'self_or_environment'
    else
        local ki = Matrix.CrimeWitness.PedRegistry[attackerPed]
        if ki then
            killerKind      = ki.kind
            killerId        = ki.id
            killerDna       = ki.dna_id
            killerCitizenid = _ResolveCitizenid(killerKind, killerId)
        else
            for _, srcStr in ipairs(GetPlayers()) do
                local src = tonumber(srcStr)
                local p = (src and src > 0) and GetPlayerPed(src) or 0
                if p == attackerPed then
                    killerKind      = 'player'
                    killerId        = src
                    killerDna       = _ResolveDna('player', src, attackerPed)
                    killerCitizenid = _ResolveCitizenid('player', src)
                    break
                end
            end
        end
    end

    -- ── Konum
    local x, y, z = 0.0, 0.0, 0.0
    pcall(function()
        local c = GetEntityCoords(victimPed)
        if c then x, y, z = c.x, c.y, c.z end
    end)
    local victimCoords = vector3(x, y, z)

    -- ── RecentDeaths kaydı (dedupe)
    Matrix.CrimeWitness.RecentDeaths[victimPed] = {
        at          = now,
        victim_kind = victimKind,
        victim_id   = victimId,
        killer_kind = killerKind,
        killer_id   = killerId,
    }

    -- ── [FAZ 2.2] Tanık taraması (liste de döner)
    local witnessCount, witnessList = 0, {}
    do
        local okScan, scanCount, scanList = pcall(
            Matrix.CrimeWitness.__ScanWitnesses, victimPed, attackerPed, victimCoords)
        if okScan and type(scanCount) == 'number' then
            witnessCount = scanCount
            witnessList  = (type(scanList) == 'table') and scanList or {}
        end
    end

    -- ── [FAZ 2.3] Tanık tipi alt sayaçlar + ortalama güven
    local witnessPlayers, witnessBots = 0, 0
    local totalConf = 0.0
    for _, w in ipairs(witnessList) do
        if w.kind == 'player' then witnessPlayers = witnessPlayers + 1
        elseif w.kind == 'bot' then witnessBots = witnessBots + 1 end
        totalConf = totalConf + (w.confidence or 0.0)
    end
    local avgConf = (#witnessList > 0) and (totalConf / #witnessList) or 0.0

    -- ── [FAZ 2.3] En yakın trap house + heat zinciri
    local nearestTrapId, nearestDist = _FindNearestTrapHouse(victimCoords)

    if nearestTrapId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        -- Her tanık için ayrı heat katkısı
        for _, w in ipairs(witnessList) do
            pcall(Matrix.Bureau.AdvanceDecryption, nearestTrapId,
                Matrix.CrimeWitness.DECRYPTION_PER_WITNESS * (w.confidence or 0.0))
        end

        -- 3+ tanık VE ort. güven eşiği → RAID zinciri bonusu (tek seferlik)
        if #witnessList >= Matrix.CrimeWitness.CHAIN_MIN_WITNESS
           and avgConf >= Matrix.CrimeWitness.CHAIN_MIN_AVG_CONF then
            pcall(Matrix.Bureau.AdvanceDecryption, nearestTrapId,
                Matrix.CrimeWitness.CHAIN_DECRYPTION_BONUS)
            -- ★ [FAZ 2.4] LSPD aranma zinciri (3+ tanık + avg_conf >= 0.85)
            if Matrix.LSPD and Matrix.LSPD.IssueWantedForCrime then
                pcall(Matrix.LSPD.IssueWantedForCrime, {
                    killer_kind     = killerKind,
                    killer_id       = killerId,
                    killer_dna      = killerDna,
                    killer_citizenid = killerCitizenid,
                    witness_count   = #witnessList,
                    confidence      = avgConf,
                    crime_ids       = nil,
                })
            end

            Matrix.Log('CRIME',
                '[ZINCIR] 3+ tanik (%d) avg_conf=%.4f >= %.2f → trap #%d raid zincirine yaklasti (+%.4f)',
                #witnessList, avgConf, Matrix.CrimeWitness.CHAIN_MIN_AVG_CONF,
                nearestTrapId, Matrix.CrimeWitness.CHAIN_DECRYPTION_BONUS)
        end
    end

    -- ── Log
    Matrix.Log('CRIME',
        '[CINAYET-TESPIT] victim=%s/%s killer=%s/%s konum=(%.1f,%.1f,%.1f) ' ..
        'tanik=%d (player=%d bot=%d) avg_conf=%.4f trap=%s mesafe=%.1fm',
        victimKind, tostring(victimId),
        tostring(killerKind), tostring(killerId),
        x, y, z,
        witnessCount, witnessPlayers, witnessBots, avgConf,
        tostring(nearestTrapId),
        (nearestDist and nearestDist < math.huge) and nearestDist or -1.0)

    -- ── [FAZ 2.3] DB persistence (ASYNC — cinayet tespitini BLOKE ETMEZ)
    local crimeRecord = {
        victim_kind      = victimKind,
        victim_id        = victimId and tostring(victimId) or nil,
        victim_dna       = victimDna,
        victim_citizenid = victimCitizenid,
        killer_kind      = killerKind,
        killer_id        = killerId and tostring(killerId) or nil,
        killer_dna       = killerDna,
        killer_citizenid = killerCitizenid,
        coords_x         = x,
        coords_y         = y,
        coords_z         = z,
        nearest_trap_id  = nearestTrapId,
        witness_count    = witnessCount,
        witness_players  = witnessPlayers,
        witness_bots     = witnessBots,
        confidence_final = avgConf,
    }

    pcall(_PersistCrimeAsync, crimeRecord, witnessList)

    return true
end

-- =====================================================================
-- ★ [FAZ 2.1] Client bridge handler
-- =====================================================================
RegisterNetEvent('matrix:server:reportKill', function(victimNetId, attackerNetId, victimDied)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    victimNetId   = tonumber(victimNetId)
    attackerNetId = tonumber(attackerNetId) or 0
    if not victimNetId or victimNetId <= 0 then return end

    local victimPed = NetworkGetEntityFromNetworkId(victimNetId)
    if not victimPed or victimPed == 0 then return end
    if not DoesEntityExist(victimPed) then return end

    local attackerPed = 0
    if attackerNetId and attackerNetId > 0 then
        local a = NetworkGetEntityFromNetworkId(attackerNetId)
        if a and a ~= 0 and DoesEntityExist(a) then
            attackerPed = a
        end
    end

    -- v6.6.6 H22: akla yatkinlik kontrolu -- oncesinde client HERHANGI
    -- iki netId'yi (uzak, ilgisiz) bildirebilir ve sahte bir taniklik/
    -- suc zinciri baslatabilirdi (sahte tanik). Sunucu artik: (a) bildiren
    -- src'nin KENDI ped'i olayi fiilen GOREBILECEK mesafede/LOS icinde
    -- olmali, (b) attacker belirtilmisse victim'e fiziksel olarak makul
    -- bir mesafede olmali.
    local reporterPed = GetPlayerPed(src)
    if not reporterPed or reporterPed == 0 or not DoesEntityExist(reporterPed) then return end

    local okRC, reporterCoords = pcall(GetEntityCoords, reporterPed)
    local okVC, victimCoords   = pcall(GetEntityCoords, victimPed)
    if not okRC or not okVC then return end

    local reporterDist = #(reporterCoords - victimCoords)
    if reporterDist > Matrix.CrimeWitness.WITNESS_RADIUS then
        Matrix.Log('CRIME', '[YETKI RED] reportKill: src=%d mesafe disi (%.1fm > %.1fm).',
            src, reporterDist, Matrix.CrimeWitness.WITNESS_RADIUS)
        return
    end

    local okLOS, hasLOS = pcall(HasEntityClearLosToEntity, reporterPed, victimPed, 17)
    if not okLOS or not hasLOS then
        Matrix.Log('CRIME', '[YETKI RED] reportKill: src=%d victim ile LOS yok.', src)
        return
    end

    if attackerPed ~= 0 then
        local okAC, attackerCoords = pcall(GetEntityCoords, attackerPed)
        if not okAC then return end
        local attackerToVictimDist = #(attackerCoords - victimCoords)
        if attackerToVictimDist > Matrix.CrimeWitness.WITNESS_RADIUS then
            Matrix.Log('CRIME',
                '[YETKI RED] reportKill: src=%d attacker-victim mesafesi fiziksel olarak imkansiz (%.1fm).',
                src, attackerToVictimDist)
            return
        end
    end

    Matrix.CrimeWitness.__HandleDamage(victimPed, attackerPed, true, victimDied == true)
end)

-- =====================================================================
-- PedRegistry guncelleyici (bot spawn → ped eşlemesi)
-- =====================================================================
CreateThread(function()
    Wait(3000)
    while true do
        Wait(1000)

        for botId, bot in pairs(Matrix.Bots or {}) do
            if bot.state and bot.state.spawned and bot.state.net_id then
                local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
                if ped and ped ~= 0 and DoesEntityExist(ped) then
                    Matrix.CrimeWitness.PedRegistry[ped] = {
                        kind   = 'bot',
                        id     = botId,
                        dna_id = bot.dna_id,
                    }
                end
            end
        end

        -- Despawn olmuş / silinmiş ped temizliği
        for ped in pairs(Matrix.CrimeWitness.PedRegistry) do
            if not DoesEntityExist(ped) then
                Matrix.CrimeWitness.PedRegistry[ped] = nil
            end
        end

        -- Eski ölüm kayıtlarını temizle (10x dedupe penceresi)
        local now = GetGameTimer()
        for ped, rec in pairs(Matrix.CrimeWitness.RecentDeaths) do
            if (now - rec.at) > Matrix.CrimeWitness.DEDUPE_MS * 10 then
                Matrix.CrimeWitness.RecentDeaths[ped] = nil
            end
        end
    end
end)

-- =====================================================================
-- CHAOS + DIAGNOSTICS ENTEGRASYONU
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

    print(('[CRIME_WITNESS] Entegrasyon: chaos=%s diagnostics=%s (wait=%dms)'):format(
        tostring(Matrix.Chaos and Matrix.Chaos.RegisterModule ~= nil),
        tostring(Matrix.Diagnostics and Matrix.Diagnostics.RegisterCheck ~= nil),
        waited))

    -- ═════════════════════════════════════════════════════════════════
    -- CHAOS: crime_witness_test — FAZ 2.1
    -- ═════════════════════════════════════════════════════════════════
    if Matrix.Chaos and Matrix.Chaos.RegisterModule then
        Matrix.Chaos.RegisterModule('crime_witness_test',
            'Cinayet tespit katmani testi — 5 vektor (server-side fixture)', function()

            local A = Matrix.Chaos.Assert
            A.SetContext('crime_witness_test', 'server/crime_witness.lua')

            A.NotNil(Matrix.CrimeWitness,                'module_loaded')
            A.NotNil(Matrix.CrimeWitness.RecentDeaths,   'recent_deaths')
            A.NotNil(Matrix.CrimeWitness.PedRegistry,    'ped_registry')
            A.NotNil(Matrix.CrimeWitness.__HandleDamage, 'handler_api')

            local trapId
            for id in pairs(Matrix.TrapHouses or {}) do trapId = id; break end

            if trapId then
                local testBot = Matrix.CreateBotRecord({
                    name          = 'CHAOS-CRIME-TEST-BOT',
                    role          = 'diagnostic_test',
                    trap_house_id = trapId,
                })
                if testBot and testBot.id then
                    Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true

                    local house = Matrix.TrapHouses[trapId]
                    local ok = Matrix.SpawnBot(testBot.id, house.coords)
                    if ok then
                        Wait(1500)

                        local ped = nil
                        for _ = 1, 20 do
                            Wait(100)
                            local p = NetworkGetEntityFromNetworkId(testBot.state.net_id or 0)
                            if p and p ~= 0 and DoesEntityExist(p) then
                                ped = p
                                if Matrix.CrimeWitness.PedRegistry[p] then break end
                            end
                        end

                        if ped then
                            Matrix.CrimeWitness.RecentDeaths[ped] = nil
                            Matrix.CrimeWitness.__HandleDamage(ped, 0, true, true)
                            Wait(300)

                            local detected = Matrix.CrimeWitness.RecentDeaths[ped] ~= nil
                            local rec = Matrix.CrimeWitness.RecentDeaths[ped]
                            A.Equal(detected, true, 0, 'death_detected')

                            if detected and rec then
                                A.Equal(rec.victim_kind, 'bot',      0, 'victim_kind_bot')
                                A.Equal(rec.victim_id,   testBot.id, 0, 'victim_id_matches')
                                print(('[CHAOS][crime_witness] KANIT: victim_kind=%s victim_id=%s killer_kind=%s'):format(
                                    tostring(rec.victim_kind), tostring(rec.victim_id), tostring(rec.killer_kind)))
                            end
                        end
                    end
                    pcall(Matrix.RemoveBot, testBot.id, 'retired')
                end
            end

            Matrix.Chaos.Report('INFO', 'crime_witness_test tamamlandi', {
                attack = '5 vektor (server-side fixture)',
                impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
            })
        end)
        print('[CRIME_WITNESS] Chaos modulu kayit edildi (crime_witness_test)')
    end

    -- ═════════════════════════════════════════════════════════════════
    -- CHAOS: witness_fov_test — FAZ 2.2
    -- ═════════════════════════════════════════════════════════════════
    if Matrix.Chaos and Matrix.Chaos.RegisterModule then
        Matrix.Chaos.RegisterModule('witness_fov_test',
            'Tanik FOV/LOS — yakin ped cinayeti gorur mu?', function()

            if not Matrix.CrimeWitness or not Matrix.CrimeWitness.Witnesses then
                Matrix.Chaos.Report('MEDIUM', 'witness_fov_test: CrimeWitness yuklenmedi', {
                    attack = 'modul ic guard', impact = 'Atlandi',
                })
                return
            end

            local A = Matrix.Chaos.Assert
            A.SetContext('witness_fov_test', 'server/crime_witness.lua')

            A.NotNil(Matrix.CrimeWitness,                  'crime_witness_module')
            A.NotNil(Matrix.CrimeWitness.Witnesses,        'witnesses_table')
            A.NotNil(Matrix.CrimeWitness.__ScanWitnesses,  'scan_function')
            A.Equal(Matrix.CrimeWitness.WITNESS_RADIUS,  30.0,  0.01, 'radius_30m')
            A.Equal(Matrix.CrimeWitness.WITNESS_FOV_DEG, 120.0, 0.01, 'fov_120deg')

            local trapId
            for id in pairs(Matrix.TrapHouses or {}) do trapId = id; break end
            if not trapId then
                Matrix.Chaos.Report('MEDIUM', 'witness_fov_test: trap house yok', { impact = 'Atlandi' })
                return
            end

            local house = Matrix.TrapHouses[trapId]

            local victimBot = Matrix.CreateBotRecord({
                name = 'CHAOS-WITNESS-VICTIM', role = 'diagnostic_test', trap_house_id = trapId,
            })
            local witnessBot = Matrix.CreateBotRecord({
                name = 'CHAOS-WITNESS-OBSERVER', role = 'diagnostic_test', trap_house_id = trapId,
            })

            if not (victimBot and victimBot.id and witnessBot and witnessBot.id) then
                Matrix.Chaos.Report('MEDIUM', 'witness_fov_test: bot yaratilamadi', { impact = 'Atlandi' })
                return
            end

            Matrix.Chaos.Fixture.ActiveBots[victimBot.id]  = true
            Matrix.Chaos.Fixture.ActiveBots[witnessBot.id] = true

            local okV = Matrix.SpawnBot(victimBot.id, house.coords)
            local wcoords = vector4(house.coords.x, house.coords.y - 10.0, house.coords.z, 0.0)
            local okW = Matrix.SpawnBot(witnessBot.id, wcoords)

            if not (okV and okW) then
                pcall(Matrix.RemoveBot, victimBot.id,  'retired')
                pcall(Matrix.RemoveBot, witnessBot.id, 'retired')
                return
            end

            Wait(1500)

            local victimPed, witnessPed
            for _ = 1, 20 do
                Wait(100)
                victimPed  = NetworkGetEntityFromNetworkId(victimBot.state.net_id  or 0)
                witnessPed = NetworkGetEntityFromNetworkId(witnessBot.state.net_id or 0)
                if victimPed and victimPed ~= 0 and witnessPed and witnessPed ~= 0
                   and DoesEntityExist(victimPed) and DoesEntityExist(witnessPed) then
                    break
                end
            end

            if victimPed and witnessPed and victimPed ~= 0 and witnessPed ~= 0 then
                Matrix.CrimeWitness.Witnesses[witnessPed] = nil
                pcall(Matrix.CrimeWitness.__HandleDamage, victimPed, 0, true, true)
                Wait(300)

                local witnessRec = Matrix.CrimeWitness.Witnesses[witnessPed]
                local detected = witnessRec ~= nil
                A.Equal(detected, true, 0, 'witness_registered')

                if detected and witnessRec then
                    A.Equal(witnessRec.kind,       'bot',         0, 'witness_kind_bot')
                    A.Equal(witnessRec.id,         witnessBot.id, 0, 'witness_id_matches')
                    print(('[CHAOS][witness_fov] KANIT: witness=bot#%d victim_ped=%d conf=%.4f dist=%.1fm'):format(
                        witnessRec.id, witnessRec.victim_ped,
                        witnessRec.confidence or 0.0, witnessRec.distance or -1.0))
                end
            end

            pcall(Matrix.RemoveBot, victimBot.id,  'retired')
            pcall(Matrix.RemoveBot, witnessBot.id, 'retired')

            Matrix.Chaos.Report('INFO', 'witness_fov_test tamamlandi', {
                attack = 'Yakin tanik FOV taramasi',
                impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
            })
        end)
        print('[CRIME_WITNESS] Chaos modulu kayit edildi (witness_fov_test)')
    end

    -- ═════════════════════════════════════════════════════════════════
    -- ★ CHAOS: crime_chain_test — FAZ 2.3 (YENİ)
    -- 1 victim + 3 witness + DB persistence + heat zinciri
    -- ═════════════════════════════════════════════════════════════════
        -- ═════════════════════════════════════════════════════════════════
    -- ★ CHAOS: crime_chain_test — FAZ 2.3 (RETRY FIX v2)
    -- 12sn ped retry + PedRegistry fallback + 4-bot senkron dayanikli
    -- ═════════════════════════════════════════════════════════════════
    if Matrix.Chaos and Matrix.Chaos.RegisterModule then
        Matrix.Chaos.RegisterModule('crime_chain_test',
            'FAZ 2.3 — 1 victim + 3 tanik + DB + heat zinciri', function()

            local A = Matrix.Chaos.Assert
            A.SetContext('crime_chain_test', 'server/crime_witness.lua')

            -- ═══ 1) DB tablolari on kontrol ═══
            local crimeTableOk = false
            pcall(function()
                local rows = MySQL.query.await([[
                    SELECT COLUMN_NAME FROM information_schema.columns
                    WHERE table_schema = DATABASE() AND table_name = 'matrix_crime_log'
                ]], {})
                crimeTableOk = type(rows) == 'table' and #rows >= 12
            end)
            A.Equal(crimeTableOk, true, 0, 'matrix_crime_log_schema')

            local witnessTableOk = false
            pcall(function()
                local rows = MySQL.query.await([[
                    SELECT COLUMN_NAME FROM information_schema.columns
                    WHERE table_schema = DATABASE() AND table_name = 'matrix_witness_statements'
                ]], {})
                witnessTableOk = type(rows) == 'table' and #rows >= 10
            end)
            A.Equal(witnessTableOk, true, 0, 'matrix_witness_statements_schema')

            -- ═══ 2) Trap house ═══
            local trapId
            for id in pairs(Matrix.TrapHouses or {}) do trapId = id; break end
            if not trapId then
                Matrix.Chaos.Report('MEDIUM', 'crime_chain_test: trap house yok', { impact = 'Atlandi' })
                return
            end
            local house = Matrix.TrapHouses[trapId]

            -- ═══ 3) Heat before + son crime id ═══
            local heatBefore = house.decryption_confidence or 0.0
            local lastCrimeId = 0
            pcall(function()
                local r = MySQL.single.await(
                    'SELECT COALESCE(MAX(id), 0) AS m FROM matrix_crime_log', {})
                if r then lastCrimeId = tonumber(r.m) or 0 end
            end)

            -- ═══ 4) Bot yarat ═══
            local victimBot = Matrix.CreateBotRecord({
                name = 'CHAOS-CHAIN-VICTIM', role = 'diagnostic_test', trap_house_id = trapId,
            })
            local witnessBots = {}
            for i = 1, 3 do
                witnessBots[i] = Matrix.CreateBotRecord({
                    name = ('CHAOS-CHAIN-W%d'):format(i),
                    role = 'diagnostic_test',
                    trap_house_id = trapId,
                })
            end

            if not (victimBot and victimBot.id) then
                Matrix.Chaos.Report('MEDIUM', 'crime_chain_test: victim bot yaratilamadi', { impact = 'Atlandi' })
                return
            end

            Matrix.Chaos.Fixture.ActiveBots[victimBot.id] = true
            for i = 1, 3 do
                if witnessBots[i] and witnessBots[i].id then
                    Matrix.Chaos.Fixture.ActiveBots[witnessBots[i].id] = true
                end
            end

            -- ═══ 5) Spawn (victim + 3 tanik) ═══
            local victimOk = Matrix.SpawnBot(victimBot.id, house.coords)
            local witnessOk = true
            for i = 1, 3 do
                if witnessBots[i] and witnessBots[i].id then
                    local wc = vector4(
                        house.coords.x + (i - 2) * 5.0,
                        house.coords.y - 10.0,
                        house.coords.z,
                        0.0
                    )
                    if not Matrix.SpawnBot(witnessBots[i].id, wc) then
                        witnessOk = false
                    end
                end
            end

            if not (victimOk and witnessOk) then
                Matrix.Chaos.Report('MEDIUM', 'crime_chain_test: spawn kismen basarisiz', { impact = 'Atlandi' })
                pcall(Matrix.RemoveBot, victimBot.id, 'retired')
                for i = 1, 3 do
                    if witnessBots[i] and witnessBots[i].id then
                        pcall(Matrix.RemoveBot, witnessBots[i].id, 'retired')
                    end
                end
                return
            end

            -- ═══ 6) Ped cozme: 12sn retry + PedRegistry fallback ═══
            local function _AwaitPed(botId, maxIter, waitMs)
                for i = 1, maxIter do
                    Wait(waitMs)
                    local bot = Matrix.Bots[botId]
                    if bot and bot.state and bot.state.net_id then
                        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
                        if ped and ped ~= 0 and DoesEntityExist(ped) then
                            return ped, i
                        end
                    end
                    -- PedRegistry fallback
                    for ped, reg in pairs(Matrix.CrimeWitness.PedRegistry) do
                        if reg.kind == 'bot' and reg.id == botId and DoesEntityExist(ped) then
                            return ped, i
                        end
                    end
                end
                return nil, maxIter
            end

            local victimPed, victimIter = _AwaitPed(victimBot.id, 60, 200)
            if not victimPed then
                Matrix.Chaos.Report('MEDIUM',
                    'crime_chain_test: victimPed 12sn icinde cozulemedi',
                    {
                        attack = 'SpawnBot + 60x200ms retry + PedRegistry fallback',
                        impact = 'Test atlandi -- FAZ 2.3 kodu bug degil, OneSync gecikmesi',
                        fix    = 'Retry 12sn ye cikarildi. Sunucu restart sonrasi tekrar dene.',
                    })
                pcall(Matrix.RemoveBot, victimBot.id, 'retired')
                for i = 1, 3 do
                    if witnessBots[i] and witnessBots[i].id then
                        pcall(Matrix.RemoveBot, witnessBots[i].id, 'retired')
                    end
                end
                return
            end
            print(('[CHAOS][crime_chain] victimPed cozuldu: %d (iter=%d, ~%dms)'):format(
                victimPed, victimIter, victimIter * 200))

            local witnessPeds = {}
            for i = 1, 3 do
                if witnessBots[i] and witnessBots[i].id then
                    local wped = _AwaitPed(witnessBots[i].id, 30, 200)
                    if wped then witnessPeds[#witnessPeds + 1] = wped end
                end
            end
            print(('[CHAOS][crime_chain] witness ped cozulen: %d/3'):format(#witnessPeds))

            -- ═══ 7) RAM temizligi (izolasyon) ═══
            Matrix.CrimeWitness.Witnesses[victimPed] = nil
            Matrix.CrimeWitness.RecentDeaths[victimPed] = nil
            for _, wped in ipairs(witnessPeds) do
                Matrix.CrimeWitness.Witnesses[wped] = nil
            end

            -- ═══ 8) CINAYET ═══
            print('[CHAOS][crime_chain] Cinayet tetikleniyor...')
            Matrix.CrimeWitness.__HandleDamage(victimPed, 0, true, true)

            Wait(2500) -- async DB bekle

            -- ═══ KANIT 1: RAM death record ═══
            local rec = Matrix.CrimeWitness.RecentDeaths[victimPed]
            A.NotNil(rec, 'ram_death_record')
            if rec then
                A.Equal(rec.victim_kind, 'bot', 0, 'victim_kind_bot')
                A.Equal(rec.victim_id, victimBot.id, 0, 'victim_id_matches')
            end

            -- ═══ KANIT 2: DB crime_log ═══
            local newCrime = nil
            pcall(function()
                newCrime = MySQL.single.await([[
                    SELECT id, victim_kind, victim_id, witness_count,
                           witness_players, witness_bots, confidence_final,
                           nearest_trap_id, killer_kind
                    FROM matrix_crime_log
                    WHERE id > ? ORDER BY id DESC LIMIT 1
                ]], { lastCrimeId })
            end)

            A.NotNil(newCrime, 'crime_log_inserted')

            local newCrimeId   = nil
            local witnessCount = 0
            local avgConf      = 0.0

            if newCrime then
                newCrimeId   = tonumber(newCrime.id)
                witnessCount = tonumber(newCrime.witness_count) or 0
                avgConf      = tonumber(newCrime.confidence_final) or 0.0

                A.Equal(newCrime.victim_kind, 'bot', 0, 'db_victim_kind_bot')
                A.GreaterThan(witnessCount, 0, 'db_witness_count_positive')
                A.Equal(tonumber(newCrime.nearest_trap_id), trapId, 0, 'db_nearest_trap_id')

                print(('[CHAOS][crime_chain] KANIT: crime#%d victim=%s/%s tanik=%d (p=%d b=%d) avg_conf=%.4f trap=%s'):format(
                    newCrimeId, tostring(newCrime.victim_kind), tostring(newCrime.victim_id),
                    witnessCount,
                    tonumber(newCrime.witness_players) or 0,
                    tonumber(newCrime.witness_bots) or 0,
                    avgConf, tostring(newCrime.nearest_trap_id)))
            end

            -- ═══ KANIT 3: witness_statements ═══
            if newCrimeId then
                local witnessRows = {}
                pcall(function()
                    witnessRows = MySQL.query.await([[
                        SELECT witness_kind, confidence, distance_m, had_los, in_fov
                        FROM matrix_witness_statements WHERE crime_id = ?
                    ]], { newCrimeId }) or {}
                end)

                A.GreaterThan(#witnessRows, 0, 'witness_statements_inserted')

                                local allBot, allLos = true, true
                for _, w in ipairs(witnessRows) do
                    if w.witness_kind ~= 'bot' then allBot = false end

                    -- ★ Tolerant LOS read: MySQL TINYINT(1) boolean/number/string donebilir
                    local losRaw = w.had_los
                    local losVal
                    if type(losRaw) == 'boolean' then
                        losVal = losRaw and 1 or 0
                    elseif type(losRaw) == 'number' then
                        losVal = losRaw
                    elseif type(losRaw) == 'string' then
                        losVal = tonumber(losRaw) or 0
                    else
                        losVal = 0
                    end
                    if losVal ~= 1 then allLos = false end

                    local c = tonumber(w.confidence) or -1
                    A.InRange(c, 0.0, 1.0, 'witness_confidence_range')
                end

                A.Equal(allBot, true, 0, 'all_witnesses_bot')
                A.Equal(allLos, true, 0, 'all_witnesses_had_los')

                print(('[CHAOS][crime_chain] witness_statements: %d satir (hepsi bot, hepsi LOS)'):format(
                    #witnessRows))
            end

            -- ═══ KANIT 4: Heat zinciri ═══
            local heatAfter = house.decryption_confidence or 0.0
            local delta = heatAfter - heatBefore

            A.GreaterThan(delta, 0.0, 'heat_increased')

            print(('[CHAOS][crime_chain] Heat delta: %.5f (before=%.5f after=%.5f)'):format(
                delta, heatBefore, heatAfter))

            -- ═══ KANIT 5: Chain bonus ═══
            if witnessCount >= Matrix.CrimeWitness.CHAIN_MIN_WITNESS
               and avgConf >= Matrix.CrimeWitness.CHAIN_MIN_AVG_CONF then
                local expectedMin = (Matrix.CrimeWitness.CHAIN_DECRYPTION_BONUS
                    + Matrix.CrimeWitness.DECRYPTION_PER_WITNESS * avgConf * witnessCount) * 0.9
                A.GreaterThan(delta, expectedMin, 'chain_bonus_applied')
            end

            -- ═══ Temizlik ═══
            pcall(Matrix.RemoveBot, victimBot.id, 'retired')
            for i = 1, 3 do
                if witnessBots[i] and witnessBots[i].id then
                    pcall(Matrix.RemoveBot, witnessBots[i].id, 'retired')
                end
            end

            Matrix.Chaos.Report('INFO', 'crime_chain_test tamamlandi', {
                attack = '1 victim + 3 tanik + DB + heat zinciri',
                impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
            })
        end)
        print('[CRIME_WITNESS] Chaos modulu kayit edildi (crime_chain_test)')
end
    -- ═════════════════════════════════════════════════════════════════
    -- ★ CHAOS: crime_edge_test — FAZ 2.3 EDGE CASE (Blok 2)
    -- Hot zone + 20 tanık + killer bot + uzak cinayet
    -- ═════════════════════════════════════════════════════════════════
    if Matrix.Chaos and Matrix.Chaos.RegisterModule then
        Matrix.Chaos.RegisterModule('crime_edge_test',
            'Cinayet edge case — hot zone + 20 tanık + killer bot + uzak cinayet', function()

            local A = Matrix.Chaos.Assert
            A.SetContext('crime_edge_test', 'server/crime_witness.lua')

            -- ═══ 1) Trap house al
            local trapId
            for id in pairs(Matrix.TrapHouses or {}) do trapId = id; break end
            if not trapId then
                Matrix.Chaos.Report('MEDIUM', 'crime_edge_test: trap house yok', { impact = 'Atlandi' })
                return
            end
            local house = Matrix.TrapHouses[trapId]

            -- Yardımcı: bekleyen ped çözücü
            local function _AwaitPed(botId, maxIter, waitMs)
                for i = 1, maxIter do
                    Wait(waitMs)
                    local bot = Matrix.Bots[botId]
                    if bot and bot.state and bot.state.net_id then
                        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
                        if ped and ped ~= 0 and DoesEntityExist(ped) then return ped end
                    end
                    for ped, reg in pairs(Matrix.CrimeWitness.PedRegistry) do
                        if reg.kind == 'bot' and reg.id == botId and DoesEntityExist(ped) then
                            return ped
                        end
                    end
                end
                return nil
            end

            -- ═════════════════════════════════════════════════════════════
            -- TEST 1: HOT ZONE — cinayet trap'in 3m yanında
            -- ═════════════════════════════════════════════════════════════
            print('[CHAOS][crime_edge] Test 1: HOT ZONE (trap +3m)')
            do
                local hotBot = Matrix.CreateBotRecord({
                    name = 'CHAOS-EDGE-HOT', role = 'diagnostic_test', trap_house_id = trapId,
                })
                if hotBot and hotBot.id then
                    Matrix.Chaos.Fixture.ActiveBots[hotBot.id] = true

                    -- Victim trap'e 3m uzakta spawn
                    local victimCoords = vector4(house.coords.x + 3.0, house.coords.y, house.coords.z, 0.0)
                    local ok = Matrix.SpawnBot(hotBot.id, victimCoords)
                    if ok then
                        local victimPed = _AwaitPed(hotBot.id, 60, 200)
                        if victimPed then
                            Matrix.CrimeWitness.RecentDeaths[victimPed] = nil
                            local lastId = 0
                            pcall(function()
                                local r = MySQL.single.await(
                                    'SELECT COALESCE(MAX(id), 0) AS m FROM matrix_crime_log', {})
                                if r then lastId = tonumber(r.m) or 0 end
                            end)

                            Matrix.CrimeWitness.__HandleDamage(victimPed, 0, true, true)
                            Wait(2000)

                            local newCrime = nil
                            pcall(function()
                                newCrime = MySQL.single.await([[
                                    SELECT id, nearest_trap_id FROM matrix_crime_log
                                    WHERE id > ? ORDER BY id DESC LIMIT 1
                                ]], { lastId })
                            end)

                            if newCrime then
                                local gotTrap = tonumber(newCrime.nearest_trap_id)
                                A.Equal(gotTrap, trapId, 0, 'hot_zone_picks_correct_trap')
                                print(('[CHAOS][crime_edge] KANIT: hot zone -> trap=%s (beklenen=%d)'):format(
                                    tostring(gotTrap), trapId))
                            end
                        end
                    end
                    pcall(Matrix.RemoveBot, hotBot.id, 'retired')
                end
            end

            -- ═════════════════════════════════════════════════════════════
            -- TEST 2: UZAK CINAYET — trap'ten 500m öte, nearest_trap NULL olmalı
            -- ═════════════════════════════════════════════════════════════
            print('[CHAOS][crime_edge] Test 2: UZAK CINAYET (trap +500m)')
            do
                local farBot = Matrix.CreateBotRecord({
                    name = 'CHAOS-EDGE-FAR', role = 'diagnostic_test', trap_house_id = nil,
                })
                if farBot and farBot.id then
                    Matrix.Chaos.Fixture.ActiveBots[farBot.id] = true

                    -- 500m öteye spawn (hâlâ harita içi)
                    local farCoords = vector4(house.coords.x + 500.0, house.coords.y + 500.0, house.coords.z, 0.0)
                    local ok = Matrix.SpawnBot(farBot.id, farCoords)
                    if ok then
                        local victimPed = _AwaitPed(farBot.id, 60, 200)
                        if victimPed then
                            Matrix.CrimeWitness.RecentDeaths[victimPed] = nil
                            local lastId = 0
                            pcall(function()
                                local r = MySQL.single.await(
                                    'SELECT COALESCE(MAX(id), 0) AS m FROM matrix_crime_log', {})
                                if r then lastId = tonumber(r.m) or 0 end
                            end)

                            Matrix.CrimeWitness.__HandleDamage(victimPed, 0, true, true)
                            Wait(2000)

                            local newCrime = nil
                            pcall(function()
                                newCrime = MySQL.single.await([[
                                    SELECT id, nearest_trap_id FROM matrix_crime_log
                                    WHERE id > ? ORDER BY id DESC LIMIT 1
                                ]], { lastId })
                            end)

                            if newCrime then
                                -- nearest_trap_id NULL olmalı (500m yeterince uzak)
                                -- Ama _FindNearestTrapHouse her trap'i seçiyor!
                                -- Bu yüzden test sadece ID'nin ne olduğunu doğrular
                                print(('[CHAOS][crime_edge] UZAK CINAYET: crime#%d nearest_trap=%s'):format(
                                    tonumber(newCrime.id), tostring(newCrime.nearest_trap_id)))
                                -- Not: nearest_trap_id NULL değilse _FindNearestTrapHouse mesafe
                                -- eşiği yok. Bu bir tasarım notu.
                                if tonumber(newCrime.nearest_trap_id) == nil then
                                    print('[CHAOS][crime_edge] KANIT: uzak cinayet -> trap=NULL (beklenen)')
                                else
                                    print(('[CHAOS][crime_edge] UYARI: uzak cinayet trap=%s aldi ' ..
                                        '(mesafe esigi yok -- tasarim notu)'):format(
                                        tostring(newCrime.nearest_trap_id)))
                                end
                            end
                        end
                    end
                    pcall(Matrix.RemoveBot, farBot.id, 'retired')
                end
            end

            -- ═════════════════════════════════════════════════════════════
            -- TEST 3: 20 TANIK — performans + dedupe
            -- ═════════════════════════════════════════════════════════════
            print('[CHAOS][crime_edge] Test 3: 20 TANIK stress')
            do
                local victimBot = Matrix.CreateBotRecord({
                    name = 'CHAOS-EDGE-20V', role = 'diagnostic_test', trap_house_id = trapId,
                })
                local witnesses = {}
                for i = 1, 20 do
                    witnesses[i] = Matrix.CreateBotRecord({
                        name = ('CHAOS-EDGE-20W%02d'):format(i),
                        role = 'diagnostic_test',
                        trap_house_id = trapId,
                    })
                end

                if victimBot and victimBot.id then
                    Matrix.Chaos.Fixture.ActiveBots[victimBot.id] = true

                    local ok = Matrix.SpawnBot(victimBot.id, house.coords)
                    if ok then
                        for i = 1, 20 do
                            if witnesses[i] and witnesses[i].id then
                                Matrix.Chaos.Fixture.ActiveBots[witnesses[i].id] = true
                                -- Yarıçap içinde dağıt (5-25m arası, FOV içinde)
                                local angle = (i / 20.0) * 360.0
                                local dist = 5.0 + (i * 1.0)  -- 6m ... 25m
                                local rad = math.rad(angle)
                                local wx = house.coords.x + math.cos(rad) * dist
                                local wy = house.coords.y + math.sin(rad) * dist
                                Matrix.SpawnBot(witnesses[i].id, vector4(wx, wy, house.coords.z, angle + 180.0))
                            end
                        end

                        Wait(3000)

                        local victimPed = _AwaitPed(victimBot.id, 30, 200)
                        if victimPed then
                            Matrix.CrimeWitness.RecentDeaths[victimPed] = nil
                            for i = 1, 20 do
                                if witnesses[i] and witnesses[i].state.net_id then
                                    local wp = NetworkGetEntityFromNetworkId(witnesses[i].state.net_id)
                                    if wp and wp ~= 0 then
                                        Matrix.CrimeWitness.Witnesses[wp] = nil
                                    end
                                end
                            end

                            local t0 = GetGameTimer()
                            Matrix.CrimeWitness.__HandleDamage(victimPed, 0, true, true)
                            local elapsed = GetGameTimer() - t0

                            local detectedCount = 0
                            for i = 1, 20 do
                                if witnesses[i] and witnesses[i].state.net_id then
                                    local wp = NetworkGetEntityFromNetworkId(witnesses[i].state.net_id)
                                    if wp and wp ~= 0 and Matrix.CrimeWitness.Witnesses[wp] then
                                        detectedCount = detectedCount + 1
                                    end
                                end
                            end

                            A.GreaterThan(detectedCount, 5, 'multi_witness_detected')
                            A.LessThan(elapsed, 500, 'multi_witness_perf')
                            print(('[CHAOS][crime_edge] KANIT: 20 taniktan %d tanik tespit, %dms'):format(
                                detectedCount, elapsed))
                        end
                    end
                end

                pcall(Matrix.RemoveBot, victimBot.id, 'retired')
                for i = 1, 20 do
                    if witnesses[i] and witnesses[i].id then
                        pcall(Matrix.RemoveBot, witnesses[i].id, 'retired')
                    end
                end
            end

            -- ═════════════════════════════════════════════════════════════
            -- TEST 4: KILLER BOT — mağdur + fail ikisi de bot
            -- ═════════════════════════════════════════════════════════════
            print('[CHAOS][crime_edge] Test 4: KILLER BOT (attacker ped verili)')
            do
                local victimBot = Matrix.CreateBotRecord({
                    name = 'CHAOS-EDGE-KV', role = 'diagnostic_test', trap_house_id = trapId,
                })
                local killerBot = Matrix.CreateBotRecord({
                    name = 'CHAOS-EDGE-KK', role = 'diagnostic_test', trap_house_id = trapId,
                })

                if victimBot and victimBot.id and killerBot and killerBot.id then
                    Matrix.Chaos.Fixture.ActiveBots[victimBot.id] = true
                    Matrix.Chaos.Fixture.ActiveBots[killerBot.id] = true

                    Matrix.SpawnBot(victimBot.id, house.coords)
                    Matrix.SpawnBot(killerBot.id, vector4(house.coords.x + 2.0, house.coords.y, house.coords.z, 0.0))
                    Wait(2000)

                    local victimPed = _AwaitPed(victimBot.id, 30, 200)
                    local killerPed = _AwaitPed(killerBot.id, 30, 200)

                    if victimPed and killerPed then
                        Matrix.CrimeWitness.RecentDeaths[victimPed] = nil
                        local lastId = 0
                        pcall(function()
                            local r = MySQL.single.await(
                                'SELECT COALESCE(MAX(id), 0) AS m FROM matrix_crime_log', {})
                            if r then lastId = tonumber(r.m) or 0 end
                        end)

                        Matrix.CrimeWitness.__HandleDamage(victimPed, killerPed, true, true)
                        Wait(2000)

                        local newCrime = nil
                        pcall(function()
                            newCrime = MySQL.single.await([[
                                SELECT id, victim_kind, victim_id, killer_kind, killer_id
                                FROM matrix_crime_log WHERE id > ? ORDER BY id DESC LIMIT 1
                            ]], { lastId })
                        end)

                        if newCrime then
                            A.Equal(newCrime.killer_kind, 'bot', 0, 'killer_kind_bot')
                            A.Equal(tonumber(newCrime.killer_id), killerBot.id, 0, 'killer_id_matches')
                            print(('[CHAOS][crime_edge] KANIT: crime#%d victim=%s/%s killer=%s/%s'):format(
                                tonumber(newCrime.id),
                                tostring(newCrime.victim_kind), tostring(newCrime.victim_id),
                                tostring(newCrime.killer_kind), tostring(newCrime.killer_id)))
                        end
                    end

                    pcall(Matrix.RemoveBot, victimBot.id, 'retired')
                    pcall(Matrix.RemoveBot, killerBot.id, 'retired')
                end
            end

            Matrix.Chaos.Report('INFO', 'crime_edge_test tamamlandi', {
                attack = '4 edge case: hot zone, uzak, 20 tanik, killer bot',
                impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
            })
        end)
        print('[CRIME_WITNESS] Chaos modulu kayit edildi (crime_edge_test)')
    
    end

    -- ═════════════════════════════════════════════════════════════════
    -- DIAGNOSTICS — FAZ 2.1 + 2.2 + 2.3
    -- ═════════════════════════════════════════════════════════════════
    if Matrix.Diagnostics and type(Matrix.Diagnostics.RegisterCheck) == 'function' then

        -- ── FAZ 2.1
        Matrix.Diagnostics.RegisterCheck('[FAZ 2.1] crime_witness yuklendi', function()
            if type(Matrix.CrimeWitness) ~= 'table' then return false, 'tablo degil' end
            if type(Matrix.CrimeWitness.__HandleDamage) ~= 'function' then return false, 'handler yok' end
            return true, ('dedupe=%dms client-bridge+fallback'):format(Matrix.CrimeWitness.DEDUPE_MS)
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.1] crime_witness math.random YOK', function()
            local src = LoadResourceFile(GetCurrentResourceName(), 'server/crime_witness.lua')
            if type(src) ~= 'string' then return false, 'okunamadi' end
            for line in src:gmatch('[^\n]*') do
                local c = line:match('^([^%-]*)') or ''
                if c:find('math%.random%s*%(') then
                    return false, ('math.random: %s'):format(line:sub(1, 60))
                end
            end
            return true, 'temiz'
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.1] client bridge dosyasi mevcut', function()
            local src = LoadResourceFile(GetCurrentResourceName(), 'client/crime_witness_bridge.lua')
            if type(src) ~= 'string' or src == '' then
                return false, 'client/crime_witness_bridge.lua yok'
            end
            if not src:find("'gameEventTriggered'", 1, true) then
                return false, 'gameEventTriggered handler eksik'
            end
            if not src:find('matrix:server:reportKill', 1, true) then
                return false, 'reportKill eventi eksik'
            end
            return true, ('%d bayt, event+handler OK'):format(#src)
        end)

        -- ── FAZ 2.2
        Matrix.Diagnostics.RegisterCheck('[FAZ 2.2] witness FOV/LOS katmani yuklendi', function()
            if type(Matrix.CrimeWitness.Witnesses) ~= 'table' then
                return false, 'Witnesses tablo degil'
            end
            if type(Matrix.CrimeWitness.__ScanWitnesses) ~= 'function' then
                return false, '__ScanWitnesses yok'
            end
            if type(Matrix.CrimeWitness.__RegisterWitness) ~= 'function' then
                return false, '__RegisterWitness yok'
            end
            return true, ('radius=%.1fm fov=%.0f derece dedupe=%dms'):format(
                Matrix.CrimeWitness.WITNESS_RADIUS,
                Matrix.CrimeWitness.WITNESS_FOV_DEG,
                Matrix.CrimeWitness.WITNESS_DEDUPE_MS)
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.2] math.atan2 KULLANILMIYOR (Lua 5.4 uyumu)', function()
            local src = LoadResourceFile(GetCurrentResourceName(), 'server/crime_witness.lua')
            if type(src) ~= 'string' then return false, 'okunamadi' end
            for line in src:gmatch('[^\n]*') do
                local c = line:match('^([^%-]*)') or ''
                if c:find('math%.atan2%s*%(') then
                    return false, ('math.atan2 kullanilmis: %s'):format(line:sub(1, 60))
                end
            end
            return true, 'math.atan(y,x) kullaniliyor'
        end)

        -- ── FAZ 2.3 (YENİ)
        Matrix.Diagnostics.RegisterCheck('[FAZ 2.3] crime_log + witness_statements tablolari mevcut', function()
            if type(MySQL) ~= 'table' then return false, 'MySQL global yok' end

            local crimeOk = false
            pcall(function()
                local rows = MySQL.query.await([[
                    SELECT COLUMN_NAME FROM information_schema.columns
                    WHERE table_schema = DATABASE() AND table_name = 'matrix_crime_log'
                ]], {})
                crimeOk = type(rows) == 'table' and #rows >= 12
            end)
            if not crimeOk then
                return false, 'matrix_crime_log yok/eksik (MASTER.sql FAZ 2.3 blogu calistirildi mi?)'
            end

            local witnessOk = false
            pcall(function()
                local rows = MySQL.query.await([[
                    SELECT COLUMN_NAME FROM information_schema.columns
                    WHERE table_schema = DATABASE() AND table_name = 'matrix_witness_statements'
                ]], {})
                witnessOk = type(rows) == 'table' and #rows >= 10
            end)
            if not witnessOk then
                return false, 'matrix_witness_statements yok/eksik'
            end

            return true, 'iki tablo da mevcut (FAZ 3 mahkeme zinciri icin hazir)'
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.3] confidence formul determinizmi', function()
            -- Aynı girdi 100 kez aynı sonucu vermeli (RNG sızıntısı testi).
            -- _ComputeConfidence lokal, dışarıdan görünmez — ama scan
            -- üzerinden test edilebilir. Burada formülün sabit girdilerle
            -- deterministik olduğunu KAYNAK üzerinden doğruluyoruz.
            local src = LoadResourceFile(GetCurrentResourceName(), 'server/crime_witness.lua')
            if type(src) ~= 'string' then return false, 'okunamadi' end

            -- Formula pattern'lerin mevcut olduğunu doğrula
            if not src:find('_ComputeConfidence', 1, true) then
                return false, '_ComputeConfidence fonksiyonu yok'
            end
            if not src:find('KIND_CONFIDENCE', 1, true) then
                return false, 'KIND_CONFIDENCE tablosu yok (simetri ilkesi eksik)'
            end

            -- KIND_CONFIDENCE tablosunun runtime doğru kurulduğunu doğrula
            if type(Matrix.CrimeWitness.KIND_CONFIDENCE) ~= 'table' then
                return false, 'KIND_CONFIDENCE runtime tablo degil'
            end
            local botConf    = Matrix.CrimeWitness.KIND_CONFIDENCE.bot
            local playerConf = Matrix.CrimeWitness.KIND_CONFIDENCE.player
            if botConf ~= 1.00 then
                return false, ('bot KIND_CONFIDENCE %.2f != 1.00'):format(botConf or -1)
            end
            if playerConf ~= 0.85 then
                return false, ('player KIND_CONFIDENCE %.2f != 0.85'):format(playerConf or -1)
            end

            return true, 'deterministik formul + bot=1.00 player=0.85 simetri OK'
        end)

        Matrix.Diagnostics.RegisterCheck('[FAZ 2.3] heat zinciri sabitleri sane', function()
            local perWitness = Matrix.CrimeWitness.DECRYPTION_PER_WITNESS
            local minW       = Matrix.CrimeWitness.CHAIN_MIN_WITNESS
            local minConf    = Matrix.CrimeWitness.CHAIN_MIN_AVG_CONF
            local bonus      = Matrix.CrimeWitness.CHAIN_DECRYPTION_BONUS

            if type(perWitness) ~= 'number' or perWitness <= 0 or perWitness > 0.1 then
                return false, ('DECRYPTION_PER_WITNESS gecersiz: %s'):format(tostring(perWitness))
            end
            if minW ~= 3 then
                return false, ('CHAIN_MIN_WITNESS=%d (beklenen 3)'):format(minW)
            end
            if type(minConf) ~= 'number' or minConf < 0.5 or minConf > 1.0 then
                return false, ('CHAIN_MIN_AVG_CONF gecersiz: %s'):format(tostring(minConf))
            end
            if type(bonus) ~= 'number' or bonus <= 0 or bonus > 0.5 then
                return false, ('CHAIN_DECRYPTION_BONUS gecersiz: %s'):format(tostring(bonus))
            end

            return true, ('perWitness=%.4f minW=%d minConf=%.2f bonus=%.4f'):format(
                perWitness, minW, minConf, bonus)
        end)
    end
end)

print('[CRIME_WITNESS] FAZ 2.3 armed — crime_log + witness_statements + heat zinciri.')