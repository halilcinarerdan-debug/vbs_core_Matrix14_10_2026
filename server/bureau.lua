-- =====================================================================
-- MATRIX BUREAU / bureau.lua
-- Dirty-set persistence, ticker'da sıfır await, pattern cache,
-- ★ REVİZYON #2: BÜRO ↔ TOPTANCI İSTİHBARAT KÖPRÜSÜ
--
-- ★★★ YAMA 2 (BU SÜRÜM) — SEC-6 CRYPTO CAS + ASİMETRİK SABOTAJ KORUMASI ★★★
--   • [SEC-6] ProcessBribeCryptoTransaction artık Lua-seviyesi satır kilidi
--     + SELECT ... FOR UPDATE + DB CAS ile zırhlıdır. Kaybeden eşzamanlı
--     istek RAM önbelleğini KİRLETMEZ; yalnızca kazanan CAS RAM'e yazar.
--   • _BurnAndRaid KALDIRILDI; yerine _BurnAndRaidByHolder(holderIdentifier)
--     geldi. Ceza ve RAID tetikleyicisi, çağıranın gönderdiği
--     targetIdentifier'a DEĞİL, DB satır kilidinden okunan GERÇEK
--     wallet.holder_identifier değerine yönelir.
--   • [YAMA 5 KOD SAVUNMASI] _BurnAndRaidByHolder multi-match görürse
--     ikinci eşleşmeyi silmez, UYARI basar ve break eder. dna_id UNIQUE
--     KEY migration'ı uygulanınca bu dal hiç tetiklenmez.
--
-- ★★★ KATMAN 8 SIZDIRMAZ KANCA YAMASI (BU SÜRÜM — EN ÜST ÖNCELİK) ★★★
--   • RadioSpectrum alt tabloları (PushToTalkAccum/JamStrength/BreachAccum)
--     AYRI AYRI ilklendirilir; harici bir kod yolu tarafından kısmen
--     doldurulmuş olsa bile O(1) boş tablo ile tamamlanır.
--   • Livestream tick'indeki `cyberSkill` artık `ResolveLivestreamCyberSkill`
--     pcall+tip-guard katmanından geçer; Matrix.Kitchen yüklü DEĞİLSE veya
--     nil/NaN dönerse KESİN 1.0 taban değerine düşer (RNG YOK, determinizm
--     %100 korunur — eski kodun ORİJİNAL ilk değeri de 1.0'dı).
-- =====================================================================

Matrix.Bureau     = Matrix.Bureau     or {}
Matrix.TrapHouses = Matrix.TrapHouses or {}
Matrix.Supplier   = Matrix.Supplier   or {}
Matrix.Bureau.DropForensics = Matrix.Bureau.DropForensics or {}

local pairs, ipairs, next        = pairs, ipairs, next
local type, tostring, tonumber   = type, tostring, tonumber
local math, table                = math, table
local math_max, math_min         = math.max, math.min
local math_huge                  = math.huge
local math_floor                 = math.floor
local os_date                    = os.date
local os_time                    = os.time
local GetPlayerPed               = GetPlayerPed
local GetEntityCoords            = GetEntityCoords

local propagandaMomentum = 0.0
local cyberLeakHeatmap   = {}
local patternLog         = {}

local dirtyDecryption = {}
local dirtyIntel      = {}
local dirtyPatternLog  = {}
local patternLogFlushed = {}

local RaidLogIdByTrapHouse = {}
local LivestreamSessions   = {}

local DropForensicsByDropId = Matrix.Bureau.DropForensics
local WARNED_MISSING_SUPPLIER_HOOK = false

-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' and type(a) ~= 'vector3' and type(a) ~= 'vector4' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' and type(b) ~= 'vector3' and type(b) ~= 'vector4' then return math_huge end
    local ax, ay, az = a.x, a.y, a.z
    local bx, by, bz = b.x, b.y, b.z
    if type(ax) ~= 'number' or type(ay) ~= 'number' or type(az) ~= 'number' then return math_huge end
    if type(bx) ~= 'number' or type(by) ~= 'number' or type(bz) ~= 'number' then return math_huge end
    if ax ~= ax or ay ~= ay or az ~= az then return math_huge end
    if bx ~= bx or by ~= by or bz ~= bz then return math_huge end
    return #(a - b)
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end

-- =====================================================================
-- LOAD
-- =====================================================================
function Matrix.Bureau.LoadTrapHouses()
    local rows = MySQL.query.await('SELECT * FROM matrix_trap_houses', {}) or {}
    for _, row in ipairs(rows) do
        Matrix.TrapHouses[row.id] = {
            id                   = row.id,
            label                = row.label or ('Trap #' .. row.id),
            coords               = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0),
            decryption_confidence= Matrix.Clamp(tonumber(row.decryption_confidence) or 0.0, 0.0, 1.0),
             raid_ordered         = row.raid_ordered == 1,
            straw_buyer_citizenid = (type(row.straw_buyer_citizenid) == 'string' and row.straw_buyer_citizenid ~= '')
                                        and row.straw_buyer_citizenid or nil,
            structural_integrity  = Matrix.Clamp(tonumber(row.structural_integrity) or 1.0, 0.0, 1.0),
        }
        cyberLeakHeatmap[row.id] = Matrix.Clamp(tonumber(row.cyber_leak_intensity) or 0.0, 0.0, 999.0)
        patternLog[row.id]       = {}
    end
    Matrix.Log('BUREAU', '%d trap house yüklendi.', #rows)
end

CreateThread(function()
    Matrix.Bureau.LoadTrapHouses()
end)

function Matrix.Bureau.CreateTrapHouse(label, coords)
    if not IsValidCoords(coords) then return false, 'bad_coords' end
  -- ★ [FAZ 2.4] Sealed zone kontrolü — kilitli bölgede trap kurulamaz
    if Matrix.LSPD and Matrix.LSPD.IsZoneSealed then
        local ok, sealed, reason = pcall(Matrix.LSPD.IsZoneSealed, coords)
        if ok and sealed then
            Matrix.Log('BUREAU', '[SEALED ZONE] (%.1f,%.1f,%.1f) yasak bolge (%s) — trap kurulamaz.',
                coords.x, coords.y, coords.z, tostring(reason))
            return false, 'zone_sealed'
        end
    end
    label = (type(label) == 'string' and label ~= '') and label or 'Yeni Trap'

   MySQL.insert([[
        INSERT INTO matrix_trap_houses
            (label, coord_x, coord_y, coord_z, decryption_confidence, cyber_leak_intensity,
             raid_ordered, straw_buyer_citizenid, structural_integrity, created_at)
        VALUES (?, ?, ?, ?, 0.0, 0.0, 0, NULL, 1.00, NOW())
    ]], { label, coords.x, coords.y, coords.z },
    function(insertId)
        if not insertId then return end
        Matrix.TrapHouses[insertId] = {
            id = insertId, label = label, coords = vector3(coords.x, coords.y, coords.z),
            decryption_confidence = 0.0, raid_ordered = false,
            straw_buyer_citizenid = nil, structural_integrity = 1.00,
        }
        cyberLeakHeatmap[insertId] = 0.0
        patternLog[insertId] = {}
        Matrix.Log('BUREAU', 'Yeni trap house #%d (%s) oluşturuldu.', insertId, label)
    end)

    return true
end

-- =====================================================================
-- FIND NEAREST
-- =====================================================================
local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end

-- =====================================================================
-- PATTERN LOG (cache + async upsert)
-- =====================================================================
function Matrix.Bureau.LogPatternEvent(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return false end
    if not patternLog[trapHouseId] then patternLog[trapHouseId] = {} end

    local dt = os_date('*t')
    local key = ('%d_%d'):format(dt.wday, dt.hour)
    patternLog[trapHouseId][key] = (patternLog[trapHouseId][key] or 0) + 1

   dirtyPatternLog[trapHouseId] = true

    -- ★ [FAZ 2] Temiz döngü → dark lawyer fragment
    if Matrix.Bureau.IncrementDarkLawyerFragment then
        pcall(Matrix.Bureau.IncrementDarkLawyerFragment, trapHouseId)
    end
    return true
end

function Matrix.Bureau.FlushDirtyPatternLog()
    local queries = {}
    for trapHouseId in pairs(dirtyPatternLog) do
        local buckets = patternLog[trapHouseId]
        if buckets then
            local flushedSnap = patternLogFlushed[trapHouseId]
            if not flushedSnap then
                flushedSnap = {}
                patternLogFlushed[trapHouseId] = flushedSnap
            end
            for key, count in pairs(buckets) do
                local already = flushedSnap[key] or 0
                local delta = count - already
                if delta > 0 then
                    local wday, hour = key:match('^(%d+)_(%d+)$')
                    -- v6.6.5 Paket 2: FK parent guard -- trap house silinmisse
                    -- (Matrix.TrapHouses[trapHouseId] yok) INSERT denenmez.
                    if wday and hour and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId] then
                        queries[#queries + 1] = {
                            query = [[
                                INSERT INTO matrix_pattern_log (trap_house_id, day_of_week, hour_of_day, occurrence_count)
                                VALUES (?, ?, ?, ?)
                                ON DUPLICATE KEY UPDATE occurrence_count = occurrence_count + VALUES(occurrence_count)
                            ]],
                            values = { trapHouseId, tonumber(wday), tonumber(hour), delta }
                        }
                        flushedSnap[key] = count
                    end
                end
            end
        end
        dirtyPatternLog[trapHouseId] = nil
    end

    if #queries == 0 then return end

    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-5] FlushDirtyPatternLog transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

local function ComputePatternRegularity(trapHouseId)
    local buckets = patternLog[trapHouseId]
    if not buckets then return 0.0 end

    local total, maxBucket = 0, 0
    for _, count in pairs(buckets) do
        total = total + count
        if count > maxBucket then maxBucket = count end
    end
    if total == 0 then return 0.0 end
    return maxBucket / total
end

-- =====================================================================
-- DECRYPTION (dirty-set)
-- =====================================================================
function Matrix.Bureau.AdvanceDecryption(trapHouseId, amount)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    amount = tonumber(amount) or 0.0
    if amount ~= amount then amount = 0.0 end

    amount = amount * Matrix.Bureau.GetBureaucraticVelocity()

    house.decryption_confidence = Matrix.Clamp(house.decryption_confidence + amount, 0.0, 1.0)
    dirtyDecryption[trapHouseId] = true

    if house.decryption_confidence >= Config.Bureau.RaidDecryptionThreshold and not house.raid_ordered then
        Matrix.Bureau.IssueRaid(trapHouseId)
    end
end

function Matrix.Bureau.FlushDirtyDecryption()
    local queries = {}
    for id in pairs(dirtyDecryption) do
        local h = Matrix.TrapHouses[id]
        if h then
            queries[#queries + 1] = {
                query  = 'UPDATE matrix_trap_houses SET decryption_confidence = ? WHERE id = ?',
                values = { h.decryption_confidence, id }
            }
        end
        dirtyDecryption[id] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyDecryption transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

-- =====================================================================
-- COMMS TRIANGULATION (IDW)
-- =====================================================================
function Matrix.Bureau.OnUnencryptedComms(actorRef, coords)
    if not IsValidCoords(coords) then return nil end

    local actor = Matrix.ResolveActor(actorRef)

    local hitTowers = {}
    for _, tower in ipairs(Config.Bureau.CellTowers) do
        if VectorDistance(coords, tower.coords) <= Config.Bureau.TowerRange then
            hitTowers[#hitTowers + 1] = tower
        end
    end
    if #hitTowers == 0 then return nil end

    local sumX, sumY, sumZ, sumWeight = 0.0, 0.0, 0.0, 0.0
    for _, tower in ipairs(hitTowers) do
        local d = math_max(VectorDistance(coords, tower.coords), 1.0)
        local w = 1.0 / d
        sumX = sumX + (tower.coords.x * w)
        sumY = sumY + (tower.coords.y * w)
        sumZ = sumZ + (tower.coords.z * w)
        sumWeight = sumWeight + w
    end
    if sumWeight <= 0.0 then return nil end

    local estimate = vector3(sumX / sumWeight, sumY / sumWeight, sumZ / sumWeight)
    local narrowedRadius = Config.Bureau.BaseSearchRadius / #hitTowers

    local trapHouseId, distToTrap = FindNearestTrapHouse(estimate)
    if not trapHouseId or distToTrap > narrowedRadius then
        return { estimate = estimate, radius = narrowedRadius }
    end

    Matrix.Bureau.LogPatternEvent(trapHouseId)

    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end

    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local normRadius = math_max(narrowedRadius / Config.Bureau.BaseSearchRadius, 0.01)
    local gain = (Config.Bureau.TriangulationDecryptionGain / normRadius)
                 * (1.0 + heat)
                 / #hitTowers
    gain = Matrix.Clamp(gain, 0.0, 0.5)

    Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)
        -- ★ [FAZ 2] Dark Lawyer fragment akümülatörü
    if Matrix.Bureau.IncrementDarkLawyerFragment then
        pcall(Matrix.Bureau.IncrementDarkLawyerFragment, trapHouseId)
    end

    Matrix.Log('BUREAU', 'Üçgenleme (%s): %d istasyon, r=%.1fm, trap #%d kazanç=%.4f',
        (actor and actor.dna_id) or 'UNKNOWN', #hitTowers, narrowedRadius, trapHouseId, gain)

    return { estimate = estimate, radius = narrowedRadius, trap_house_id = trapHouseId, gain = gain }
end

-- =====================================================================
-- PROPAGANDA
-- =====================================================================
function Matrix.Bureau.TriggerPropaganda(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return 0.0, 0.0 end

    propagandaMomentum = math_min(
        (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor)
            + Config.Bureau.PropagandaMomentumIncrement,
        Config.Bureau.PropagandaMaxMomentum
    )

    local currentHeat = cyberLeakHeatmap[trapHouseId] or 0.0
    currentHeat = math_min(
        (currentHeat * Config.Bureau.CyberLeakGeometricFactor)
            + Config.Bureau.CyberLeakIncrement,
        Config.Bureau.CyberLeakMaxIntensity
    )
    cyberLeakHeatmap[trapHouseId] = currentHeat
    dirtyIntel[trapHouseId]       = true

    Matrix.Log('BUREAU', 'Propaganda: momentum=%.2f, trap #%d heat=%.2f',
        propagandaMomentum, trapHouseId, currentHeat)

    return propagandaMomentum, currentHeat
end

function Matrix.Bureau.GetPropagandaMomentum()
    return propagandaMomentum
end

function Matrix.Bureau.SetHeat(trapHouseId, newHeat)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return false end

    newHeat = Matrix.Clamp(
        tonumber(newHeat) or 0.0,
        0.0,
        (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
    )

    cyberLeakHeatmap[trapHouseId] = newHeat
    -- ★ HEAT PERSISTENCE FIX: DB'ye de yaz (restart'ta silinmesin)
    MySQL.prepare(
        'UPDATE matrix_trap_houses SET cyber_leak_intensity = ? WHERE id = ?',
        { newHeat, trapHouseId }
    )
    dirtyIntel[trapHouseId] = true

    return true
end

exports('SetHeat', function(trapHouseId, newHeat)
    return Matrix.Bureau.SetHeat(trapHouseId, newHeat)
end)
-- ★ [VETTING AUDIT FIX] Config.lua, debug_map.lua, hitsquad.lua ve main.lua
-- Matrix.Bureau.GetHeat'i mevcut bir salt-okunur getter olarak varsayıp
-- cagiriyordu (hepsi guard'li: 'Matrix.Bureau.GetHeat and ...'), ama bu
-- dosyada hicbir zaman tanimlanmamisti -- her cagri sessizce 0.0'a
-- dusuyordu. SetHeat/__SetHeatRaw ile simetrik salt-okunur getter.
function Matrix.Bureau.GetHeat(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return 0.0 end
    return cyberLeakHeatmap[trapHouseId] or 0.0
end

exports('GetHeat', function(trapHouseId)
    return Matrix.Bureau.GetHeat(trapHouseId)
end)

-- ★ [FAZ 2] Hitsquad counter-sting için heatmap zorlama köprüsü.
-- cyberLeakHeatmap bu dosyada `local`, dışarıdan erişemiyoruz — setter açıyoruz.
function Matrix.Bureau.__SetHeatRaw(trapHouseId, value)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    cyberLeakHeatmap[trapHouseId] = Matrix.Clamp(tonumber(value) or 0.0, 0.0, 999.0)
    dirtyIntel[trapHouseId] = true
end

-- =====================================================================
-- TICK
-- =====================================================================
function Matrix.Bureau.Tick()
    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        if not house.raid_ordered then
            local regularity = ComputePatternRegularity(trapHouseId)
            local heat       = cyberLeakHeatmap[trapHouseId] or 0.0
            local gain       = Config.Bureau.PatternAnalysisGain * regularity * (1.0 + heat)

            if gain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)
            end
        end
    end
end

-- =====================================================================
-- RAID
-- =====================================================================
local function ComputeRaidSquad(trapHouseId, house)
    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local squadSize = math_floor(Config.Bureau.RaidBaseSquadSize + (heat * Config.Bureau.RaidHeatSquadFactor) + 0.5)
    squadSize = math_max(Config.Bureau.RaidBaseSquadSize, math_min(squadSize, Config.Bureau.RaidMaxSquadSize))

    local breachMethod = (house.decryption_confidence >= Config.Bureau.RaidExplosiveBreachThreshold)
        and 'explosive' or 'ram'

    local escapeWindow = Config.Bureau.RaidBaseEscapeWindowSeconds
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(house.coords, zone.coords) <= zone.radius then
            escapeWindow = escapeWindow + Config.Bureau.RaidDeadZoneEscapeBonusSeconds
            break
        end
    end

    if Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachDelaySeconds then
        local ok, bonus = pcall(Matrix.DoorReinforcement.GetBreachDelaySeconds, trapHouseId)
        if ok and type(bonus) == 'number' and bonus == bonus and bonus > 0.0 then
            escapeWindow = escapeWindow + bonus
        end
    end

    return squadSize, breachMethod, escapeWindow
end

function Matrix.Bureau.IssueRaid(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end
    if house.raid_ordered then return end

    local decryptionAtRaid = house.decryption_confidence
    local squadSize, breachMethod, escapeWindow = ComputeRaidSquad(trapHouseId, house)

    house.raid_ordered          = true
    house.decryption_confidence = Config.Bureau.PostRaidDecryptionReset
    cyberLeakHeatmap[trapHouseId] = (cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.PostRaidHeatmapDecay
    patternLog[trapHouseId]     = {}
    patternLogFlushed[trapHouseId] = nil

    MySQL.prepare([[
        UPDATE matrix_trap_houses
        SET raid_ordered = 1, last_raid_at = NOW(),
            decryption_confidence = ?, cyber_leak_intensity = ?
        WHERE id = ?
    ]], {
        Config.Bureau.PostRaidDecryptionReset,
        cyberLeakHeatmap[trapHouseId],
        trapHouseId
    })

    MySQL.insert([[
        INSERT INTO matrix_raid_log (
            trap_house_id, squad_size, breach_method, decryption_confidence_at_raid,
            escape_window_seconds, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, 'pending', NOW())
    ]], { trapHouseId, squadSize, breachMethod, decryptionAtRaid, escapeWindow },
    function(insertId)
        if insertId then RaidLogIdByTrapHouse[trapHouseId] = insertId end
    end)

    TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId, house.coords, {
        squad_size    = squadSize,
        breach_method = breachMethod,
        escape_window = escapeWindow
    })

    TriggerEvent('matrix:internal:raidIssued', trapHouseId, escapeWindow, breachMethod, squadSize)

    if Matrix.Bureau.RecordPurityIntercepted then
        Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    end

    Matrix.Log('BUREAU', '[ŞAFAK BASKINI] Trap house #%d (%s): %d birim, breach=%s, kaçış=%ds.',
        trapHouseId, house.label, squadSize, breachMethod, escapeWindow)
end

local VALID_RAID_OUTCOMES = { captured = true, escaped = true, eliminated = true }

function Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
    if not VALID_RAID_OUTCOMES[outcome] then return false end
    local logId = RaidLogIdByTrapHouse[trapHouseId]
    if not logId then return false end

    MySQL.prepare('UPDATE matrix_raid_log SET outcome = ?, resolved_at = NOW() WHERE id = ?', { outcome, logId })

-- ★ [FAZ 2.4] raid başarılı → trap house bölge mührü
    if outcome == 'captured' or outcome == 'eliminated' then
        if Matrix.LSPD and Matrix.LSPD.SealTrapHouse then
            pcall(Matrix.LSPD.SealTrapHouse, trapHouseId, 'raid')
        end
    end

    TriggerEvent('matrix:internal:raidResolved', trapHouseId, outcome)

    Matrix.Log('BUREAU', 'Baskın (kayıt #%d, trap #%d) sonuçlandı: %s', logId, trapHouseId, outcome)
    return true
end

function Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local target = Config.Bureau.RaidDecryptionThreshold + 0.05
    if house.decryption_confidence < target then
        house.decryption_confidence = target
    end
    dirtyDecryption[trapHouseId] = true

    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end
end

-- =====================================================================
-- FLUSH LOOP
-- =====================================================================
CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        Matrix.Bureau.FlushDirtyDecryption()
        Matrix.Bureau.FlushDirtyIntel()
        Matrix.Bureau.FlushDirtyPatternLog()
    end
end)

-- =====================================================================
-- LİVESTREAM
-- =====================================================================
function Matrix.Bureau.StartLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    if LivestreamSessions[src] then return false end

    local searchOk, phoneCount = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', 'burner_phone')
    end)
    if not searchOk or (tonumber(phoneCount) or 0) <= 0 then
        Matrix.Log('BUREAU', '[YAYIN REDDEDILDI] src=%s ustunde aktif burner_phone yok.', tostring(src))
        return false
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    LivestreamSessions[src] = {
        started    = Matrix.Now(),
        citizenid  = state and state.citizenid,
        hype       = 1.0,
        heat_added = 0.0,
        trap_house_id = nil
    }
    Matrix.Log('BUREAU', '[CANLI YAYIN BAŞLADI] src=%d, IP çıkışı Büro siber taramasına açıldı.', src)
    return true
end

function Matrix.Bureau.StopLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local session = LivestreamSessions[src]
    if not session then return false end
    LivestreamSessions[src] = nil

    local duration = Matrix.Now() - session.started
    MySQL.prepare([[
        INSERT INTO matrix_livestream_events (citizenid, duration_seconds, hype_multiplier, heat_added, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { session.citizenid, duration, session.hype, session.heat_added, session.trap_house_id })

    Matrix.Log('BUREAU', '[CANLI YAYIN BİTTİ] src=%d, süre=%ds, son hype=%.2f, eklenen heat=%.2f',
        src, duration, session.hype, session.heat_added)
    return true
end

RegisterNetEvent('matrix:server:reportLivestreamStart', function()
    Matrix.Bureau.StartLivestream(source)
end)

RegisterNetEvent('matrix:server:reportLivestreamStop', function()
    Matrix.Bureau.StopLivestream(source)
end)

-- =====================================================================
-- ★ [SELF-HEALING FIX] cyberSkill RESOLUTION
--
-- ESKİ HATA: `cyberSkill = Matrix.Kitchen.GetEffectiveSkill(bot, 'skill_cyber')`
-- doğrudan çağrılıyordu. server/kitchen.lua henüz yüklenmemişse VEYA
-- fonksiyon nil/NaN döndürürse `math_max(nil, 0.1)` runtime hatası
-- fırlatıyor ve TÜM livestream tick döngüsü sessizce ölüyordu.
--
-- YENİ DİSİPLİN (RIGID STRUCTURAL FALLBACK):
--   1) Matrix.Kitchen VE GetEffectiveSkill tip kontrolü.
--   2) Çağrı pcall ile sarılır.
--   3) Dönüş değeri katı sayısal doğrulamadan geçer (nil/NaN/±inf reddedilir).
--   4) Herhangi bir aşama başarısız olursa → cyberSkill = 1.0 (eski kodun
--      ORİJİNAL ilk değeriyle BİREBİR AYNI, RNG YOK, determinizm %100).
--   5) En sonda math_max(cyberSkill, 0.1) alt sınırı yine uygulanır.
-- =====================================================================
local function ResolveLivestreamCyberSkill(trapHouseId)
    if not Matrix.Kitchen or type(Matrix.Kitchen.GetEffectiveSkill) ~= 'function' then
        return 1.0
    end

    local resolved = 1.0
    local botIter = Matrix.Bots
    if type(botIter) ~= 'table' then return resolved end

    for _, bot in pairs(botIter) do
        if bot and bot.state and bot.state.trap_house_id == trapHouseId then
            local okSkill, skillValue = pcall(Matrix.Kitchen.GetEffectiveSkill, bot, 'skill_cyber')
            if okSkill
                and type(skillValue) == 'number'
                and skillValue == skillValue
                and skillValue ~= math.huge
                and skillValue ~= -math.huge then
                resolved = skillValue
            end
            break
        end
    end

    if type(resolved) ~= 'number' or resolved ~= resolved
        or resolved == math.huge or resolved == -math.huge then
        resolved = 1.0
    end
    return resolved
end

CreateThread(function()
    while true do
        Wait(1000)
        for src, session in pairs(LivestreamSessions) do
            local ped = GetPlayerPed(src)
            local searchOk, phoneCount = pcall(function()
                return exports['ox_inventory']:Search(src, 'count', 'burner_phone')
            end)
            local hasBurnerPhone = searchOk and (tonumber(phoneCount) or 0) > 0

            if not ped or ped == 0 then
                LivestreamSessions[src] = nil
            elseif not hasBurnerPhone then
                Matrix.Log('BUREAU',
                    '[YAYIN ZORLA KESILDI] src=%d ustunde aktif burner_phone bulunamadi -- StopLivestream tetiklendi.', src)
                Matrix.Bureau.StopLivestream(src)
            else
                session.hype = math_min(
                    (session.hype * Config.Bureau.LivestreamHypeGeometricFactor) + Config.Bureau.LivestreamHypeIncrementPerTick,
                    Config.Bureau.PropagandaMaxMomentum
                )

                propagandaMomentum = math_min(
                    (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor) + Config.Bureau.PropagandaMomentumIncrement,
                    Config.Bureau.PropagandaMaxMomentum
                )

                local coords = GetEntityCoords(ped)
                local trapHouseId, dist = FindNearestTrapHouse(coords)
                if trapHouseId and dist <= Config.Bureau.BaseSearchRadius then
                    session.trap_house_id = trapHouseId

                    local silent = Matrix.RadioSilence and Matrix.RadioSilence.IsActive
                        and Matrix.RadioSilence.IsActive(session.citizenid)

                    if not silent then
                        -- ★ SELF-HEALING FIX: cyberSkill artık nil/NaN OLAMAZ.
                        local cyberSkill = ResolveLivestreamCyberSkill(trapHouseId)
                        cyberSkill = math_max(cyberSkill, 0.1)

                        local heatGain = Config.Bureau.LivestreamHeatIncrementPerTick * cyberSkill
                        cyberLeakHeatmap[trapHouseId] = math_min(
                            ((cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.CyberLeakGeometricFactor) + heatGain,
                            Config.Bureau.CyberLeakMaxIntensity
                        )
                        dirtyIntel[trapHouseId] = true
                        session.heat_added = session.heat_added + heatGain

                        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Bureau.LivestreamDecryptionGainPerTick * cyberSkill)

                        Matrix.Bureau.RecordLivestreamRadioLeak(trapHouseId, Config.Bureau.LivestreamRadioBreachMultiplier)
                    end
                end
            end
        end
    end
end)

-- =====================================================================
-- REVİZYON #2: DEAD DROP ADLİ ÖRNEK TOPLAYICI
-- =====================================================================
local function CfgBureau(key, default)
    local v = Config.Bureau[key]
    if v == nil then return default end
    return v
end

local function NowEpoch()
    return os_time()
end

function Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    dropId     = tonumber(dropId)
    supplierId = tonumber(supplierId)
    quality    = tonumber(quality) or 0.0
    if not dropId or not supplierId then return false end
    if quality ~= quality then quality = 0.0 end
    quality = Matrix.Clamp(quality, 0.0, 1.0)

    local rec = DropForensicsByDropId[dropId]
    if not rec then
        rec = {
            samples          = {},
            supplier_id      = supplierId,
            citizenid        = citizenid or 'UNKNOWN',
            leaked           = false,
            last_activity_at = NowEpoch()
        }
        DropForensicsByDropId[dropId] = rec
    end

    local maxSamples = CfgBureau('MaxDropSamplesForLeak', 8)
    rec.samples[#rec.samples + 1] = { quality = quality, at = NowEpoch() }
    while #rec.samples > maxSamples do
        table.remove(rec.samples, 1)
    end
    rec.last_activity_at = NowEpoch()

    Matrix.Log('BUREAU',
        '[ADLİ ÖRNEK] Drop #%d, kalite=%.3f (toplam örnek: %d, toptancı #%d)',
        dropId, quality, #rec.samples, rec.supplier_id)
    return true
end

local function ComputeDropForensicCertainty(dropId, rec)
    rec = rec or DropForensicsByDropId[dropId]
    if not rec or #rec.samples == 0 then return 0.0, 0.0, 0 end

    local decayRate  = CfgBureau('SampleDecayRate', 0.002)
    local now        = NowEpoch()
    local wSum, qSum = 0.0, 0.0
    for _, s in ipairs(rec.samples) do
        local ageMin = math_max((now - s.at) / 60.0, 0.0)
        local w      = math.exp(-ageMin * decayRate)
        qSum = qSum + (s.quality * w)
        wSum = wSum + w
    end
    if wSum <= 0.0 then return 0.0, 0.0, #rec.samples end

    local avgQ        = qSum / wSum
    local required    = CfgBureau('RequiredSamplesForLeak', 3)
    local volumeF     = math_min(1.0, #rec.samples / math_max(required, 1))
    local heat        = 0.0
    local dropCfg
    if Config.Supplier and Config.Supplier.DeadDrops then
        for _, d in ipairs(Config.Supplier.DeadDrops) do
            if d.id == dropId then dropCfg = d break end
        end
    end
    if dropCfg then
        local trapId, trapDist = FindNearestTrapHouse(dropCfg.coords)
        if trapId and trapDist <= Config.Bureau.BaseSearchRadius then
            heat = cyberLeakHeatmap[trapId] or 0.0
        end
    end
    local heatF       = 1.0 + math_min(heat, Config.Bureau.CyberLeakMaxIntensity) * 0.15
    local certainty   = Matrix.Clamp(avgQ * volumeF * heatF, 0.0, 1.0)
    return certainty, avgQ, #rec.samples
end

local function EmitSupplierIntelLeak(citizenid, supplierId, certainty, dropId)
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local basePen    = CfgBureau('BureauLeakTrustPenaltyBase', 0.15)
    local maxPen     = CfgBureau('BureauLeakTrustPenaltyMax',  0.45)
    local span       = math_max(1.0 - threshold, 0.001)
    local norm       = Matrix.Clamp((certainty - threshold) / span, 0.0, 1.0)
    local penalty    = basePen + (maxPen - basePen) * norm

    if Matrix.Supplier and Matrix.Supplier.ApplyBureauIntelLeak then
        pcall(Matrix.Supplier.ApplyBureauIntelLeak, citizenid, supplierId, penalty, dropId)
    else
        MySQL.prepare([[
            INSERT INTO matrix_supplier_trust
                (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
            VALUES (?, ?, 0.5, 0, 1, NOW(), NOW())
            ON DUPLICATE KEY UPDATE
                trust          = GREATEST(0.0, trust - ?),
                forensic_leaks = forensic_leaks + 1,
                updated_at     = NOW()
        ]], { citizenid, supplierId, penalty })

        if not WARNED_MISSING_SUPPLIER_HOOK then
            WARNED_MISSING_SUPPLIER_HOOK = true
            Matrix.Log('BUREAU',
                '[UYARI] Matrix.Supplier.ApplyBureauIntelLeak hooku tanimli degil; dogrudan DB yazimi kullanildi (logistics.lua guncellemesi onerilir).')
        end
    end

    Matrix.Log('BUREAU',
        '[İSTİHBARAT SIZINTISI] Drop #%d → Toptancı #%d | Kesinlik=%.3f | Penalty=%.3f | Mağdur=%s',
        dropId, supplierId, certainty, penalty, tostring(citizenid))
end

function Matrix.Bureau.TickDropForensics()
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local staleAfter = CfgBureau('DropForensicsStaleSeconds', 3600)

    local now = NowEpoch()
    local toRemove = {}

    for dropId, rec in pairs(DropForensicsByDropId) do
        if (now - (rec.last_activity_at or now)) > staleAfter then
            toRemove[#toRemove + 1] = dropId
        else
            local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)

            if not rec.leaked and certainty >= threshold then
                rec.leaked = true
                EmitSupplierIntelLeak(rec.citizenid, rec.supplier_id, certainty, dropId)
            end

            if N > 0 and N % 3 == 0 then
                Matrix.Log('BUREAU',
                    '[ADLİ TAKİP] Drop #%d | Örnek:%d | avgQ:%.3f | Kesinlik:%.3f (eşik:%.2f) | Sızdı:%s',
                    dropId, N, avgQ, certainty, threshold, tostring(rec.leaked))
            end
        end
    end

    for _, id in ipairs(toRemove) do
        DropForensicsByDropId[id] = nil
    end
end

CreateThread(function()
    local interval = CfgBureau('DropForensicsTickIntervalSeconds', 30) * 1000
    while true do
        Wait(interval)
        local ok, err = pcall(Matrix.Bureau.TickDropForensics)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] TickDropForensics hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

-- =====================================================================
-- EVENT BRIDGE
-- =====================================================================
RegisterNetEvent('matrix:server:reportUnencryptedComms', function(coords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not IsValidCoords(coords) then return end
    Matrix.Bureau.OnUnencryptedComms({ kind = 'player', source = src }, coords)
end)

RegisterNetEvent('matrix:server:triggerPropaganda', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.TriggerPropaganda(trapHouseId)
end)

RegisterNetEvent('matrix:server:reportLogisticsRun', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.LogPatternEvent(trapHouseId)
end)

-- src'nin bu trap house'ta gercekten bir operasyonu (bot handler'i) oldugunu
-- dogrular -- "dispatcher" burada trapHouseId'ye baglanmis botlarin
-- handler_citizenid'idir. Bu kontrol olmadan herhangi bir oyuncu kendi
-- baskinini sahte 'escaped' yapabilir veya rakip trap house'u sahte
-- 'captured' ile muhurleyebilir.
local function _IsRaidDispatcher(src, trapHouseId)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    for _, bot in pairs(Matrix.Bots or {}) do
        if bot.state and bot.state.trap_house_id == trapHouseId
            and bot.handler_citizenid == state.citizenid then
            return true
        end
    end
    return false
end

RegisterNetEvent('matrix:server:reportRaidOutcome', function(trapHouseId, outcome)
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        Matrix.Log('BUREAU', '[YETKI RED] reportRaidOutcome gecersiz src: %s', tostring(src))
        return
    end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    if not VALID_RAID_OUTCOMES[outcome] then
        Matrix.Log('BUREAU', '[YETKI RED] src=%d trap #%d icin gecersiz raid outcome: %s',
            src, trapHouseId, tostring(outcome))
        return
    end
    if not _IsRaidDispatcher(src, trapHouseId) then
        Matrix.Log('BUREAU', '[YETKI RED] src=%d trap #%d icin dispatcher degil -- raid sonucu bildirimi reddedildi.',
            src, trapHouseId)
        return
    end
    Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
end)

RegisterNetEvent('matrix:server:reportDeadDropForensic', function(dropId, quality, supplierId, citizenid)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('TriggerPropaganda',      function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms', function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',     function(t) return Matrix.Bureau.LogPatternEvent(t) end)
exports('ReceiveSnitchLeak',      function(t) return Matrix.Bureau.ReceiveSnitchLeak(t) end)
exports('IssueRaid',              function(t) return Matrix.Bureau.IssueRaid(t) end)
exports('ResolveRaidOutcome',     function(t, o) return Matrix.Bureau.ResolveRaidOutcome(t, o) end)

exports('OnDeadDropForensicPickup', function(dropId, quality, supplierId, citizenid)
    return Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)
exports('TickDropForensics', function()
    return Matrix.Bureau.TickDropForensics()
end)

-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[BUREAU]', msg } })
    else
        print(('[MATRIX:BUREAU:CONSOLE] %s'):format(msg))
    end
end

local function ParseCoordNumber(s)
    return tonumber((tostring(s or ''):gsub(',', '')))
end

-- ★ [SESSION 1 PURGE] /traphouseekle — text-command registration abolished.
-- Physical broker NPC at vector4(142.12, -1024.45, 29.3, 120.0) is the
-- sole asset-registration interface (ox_target, 1.8m lock).
RegisterCommand('traphouseekle', function(src)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[SESSION1]',
                'Asset registration moved to physical broker. Visit Paravan Estate node.' }
        })
    end
end, false)
RegisterCommand('traphousedurum', function(src, args)
    local id = tonumber(args[1])
    local house = id and Matrix.TrapHouses[id]
    if not house then Reply(src, 'Kullanim: /traphousedurum [id]'); return end

    Reply(src, ('#%d %s | Deşifre:%.4f/%.2f | Heat:%.3f | Düzenlilik:%.3f | Baskın:%s'):format(
        id, house.label, house.decryption_confidence, Config.Bureau.RaidDecryptionThreshold,
        cyberLeakHeatmap[id] or 0.0, ComputePatternRegularity(id), tostring(house.raid_ordered)))
end, false)

RegisterCommand('desifreekle', function(src, args)
    if type(src) == 'number' and src > 0 then
        local _s = Matrix.GetOrCreatePlayerState(src)
        if not _s or not _s.citizenid
            or not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority)
            or not Matrix.Hierarchy.HasCommandAuthority(_s.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local id = tonumber(args[1])
    local amount = tonumber(args[2])
    if not id or not Matrix.TrapHouses[id] or not amount then
        Reply(src, 'Kullanim: /desifreekle [id] [miktar]'); return
    end
    Matrix.Bureau.AdvanceDecryption(id, amount)
    Reply(src, ('Trap #%d deşifre: %.4f'):format(id, Matrix.TrapHouses[id].decryption_confidence))
end, false)

RegisterCommand('propagandatetikle', function(src, args)
    if type(src) == 'number' and src > 0 then
        local _s = Matrix.GetOrCreatePlayerState(src)
        if not _s or not _s.citizenid
            or not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority)
            or not Matrix.Hierarchy.HasCommandAuthority(_s.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /propagandatetikle [id]'); return end
    local momentum, heat = Matrix.Bureau.TriggerPropaganda(id)
    Reply(src, ('Momentum:%.3f Heat:%.3f'):format(momentum, heat))
end, false)

RegisterCommand('baskinzorla', function(src, args)
    if type(src) == 'number' and src > 0 then
        local _s = Matrix.GetOrCreatePlayerState(src)
        if not _s or not _s.citizenid
            or not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority)
            or not Matrix.Hierarchy.HasCommandAuthority(_s.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /baskinzorla [id]'); return end
    Matrix.Bureau.IssueRaid(id)
    Reply(src, ('Trap #%d için baskın ZORLA tetiklendi (test modu).'):format(id))
end, false)

RegisterCommand('baskinsonuclandir', function(src, args)
    if type(src) == 'number' and src > 0 then
        local _s = Matrix.GetOrCreatePlayerState(src)
        if not _s or not _s.citizenid
            or not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority)
            or not Matrix.Hierarchy.HasCommandAuthority(_s.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local id = tonumber(args[1])
    local outcome = args[2]
    if not id or not outcome then
        Reply(src, 'Kullanim: /baskinsonuclandir [id] [captured|escaped|eliminated]'); return
    end
    local ok = Matrix.Bureau.ResolveRaidOutcome(id, outcome)
    Reply(src, ok and 'Sonuç kaydedildi.' or 'Geçersiz sonuç veya aktif baskın kaydı yok.')
end, false)

RegisterCommand('yayinbaslat', function(src)
    local ok = Matrix.Bureau.StartLivestream(src)
    Reply(src, ok and 'Canlı yayın başlatıldı (test).' or 'Zaten yayında veya geçersiz src.')
end, false)

RegisterCommand('yayinbitir', function(src)
    local ok = Matrix.Bureau.StopLivestream(src)
    Reply(src, ok and 'Canlı yayın bitirildi (test).' or 'Aktif yayın bulunamadı.')
end, false)

RegisterCommand('momentumgoster', function(src)
    Reply(src, ('Propaganda momentum: %.4f'):format(propagandaMomentum))
end, false)

RegisterCommand('dropsizintiekle', function(src, args)
    local dropId     = tonumber(args[1])
    local quality    = tonumber(args[2])
    local supplierId = tonumber(args[3])
    local citizenid  = args[4] or 'TEST-CID'
    if not dropId or not quality or not supplierId then
        Reply(src, 'Kullanim: /dropsizintiekle [dropId] [kalite 0-1] [supplierId] [citizenid]'); return
    end
    local ok = Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    Reply(src, ok and ('Örnek eklendi. Toplam: %d'):format(#(DropForensicsByDropId[dropId] and DropForensicsByDropId[dropId].samples or {}))
              or 'Geçersiz parametre.')
end, false)

RegisterCommand('dropsizintidurum', function(src)
    local count = 0
    for dropId, rec in pairs(DropForensicsByDropId) do
        count = count + 1
        local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)
        Reply(src, ('Drop #%d → Toptancı #%d | Örnek:%d avgQ:%.3f Kesinlik:%.3f | Sızdı:%s | Mağdur:%s'):format(
            dropId, rec.supplier_id, N, avgQ, certainty,
            tostring(rec.leaked), tostring(rec.citizenid)))
    end
    Reply(src, ('--- Toplam %d drop adli kaydi ---'):format(count))
    Reply(src, ('BureauLeakCertaintyThreshold: %.2f'):format(CfgBureau('BureauLeakCertaintyThreshold', 0.65)))
end, false)

RegisterCommand('dropsizintisifirla', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropsizintisifirla [dropId]'); return end
    if DropForensicsByDropId[dropId] then
        DropForensicsByDropId[dropId] = nil
        Reply(src, ('Drop #%d adli toplayicisi sifirlandi.'):format(dropId))
    else
        Reply(src, 'Bu drop için aktif adli kayit yok.')
    end
end, false)

-- =====================================================================
-- KATMAN 7 [T4] FAZ 1: BÜRO KİLİDİ
-- =====================================================================
local learningCore      = {}
local dirtyLearningCore = {}

local function GetLearningState(trapHouseId)
    local state = learningCore[trapHouseId]
    if not state then
        state = {
            frequent_zones             = {},
            radio_breach_count         = 0,
            average_purity_intercepted = 0.0,
            lockdown_active            = false
        }
        learningCore[trapHouseId] = state
    end
    return state
end

function Matrix.Bureau.LoadLearningCore()
    local rows = MySQL.query.await('SELECT * FROM matrix_bureau_learning_core', {}) or {}
    for _, row in ipairs(rows) do
        local zones = {}
        if row.frequent_zones and row.frequent_zones ~= '' then
            local ok, decoded = pcall(json.decode, row.frequent_zones)
            if ok and type(decoded) == 'table' then zones = decoded end
        end
        learningCore[row.trap_house_id] = {
            frequent_zones             = zones,
            radio_breach_count         = tonumber(row.radio_breach_count) or 0,
            average_purity_intercepted = tonumber(row.average_purity_intercepted) or 0.0,
            purity_sample_count        = tonumber(row.purity_sample_count) or 0,
            lockdown_active            = row.lockdown_active == 1
        }
    end
    Matrix.Log('BUREAU', '[T4] %d ogrenme hafizasi kaydi RAM onbellege kilitlendi.', #rows)
end

CreateThread(function()
    Matrix.Bureau.LoadLearningCore()
end)

-- v6.6.5 Paket 2: trap house silindiginde (chaos/diagnostics fixture
-- teardown gibi yollarla) bu trap house'a bagli TUM RAM dirty-set
-- girdilerini temizler -- FlushDirty* tick'lerinin artik var olmayan
-- bir parent icin INSERT/UPDATE denemesini (FK constraint violation)
-- onler.
function Matrix.Bureau.ClearLearningState(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return false end
    learningCore[trapHouseId]      = nil
    dirtyLearningCore[trapHouseId] = nil
    dirtyIntel[trapHouseId]        = nil
    cyberLeakHeatmap[trapHouseId]  = nil
    patternLog[trapHouseId]        = nil
    dirtyPatternLog[trapHouseId]   = nil
    dirtyDecryption[trapHouseId]   = nil
    patternLogFlushed[trapHouseId] = nil
    return true
end

function Matrix.Bureau.FlushDirtyLearningCore()
    local queries = {}
    for trapHouseId in pairs(dirtyLearningCore) do
        local state = learningCore[trapHouseId]
        if state and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId] then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_bureau_learning_core
                        (trap_house_id, frequent_zones, radio_breach_count, average_purity_intercepted, purity_sample_count, lockdown_active, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        frequent_zones             = VALUES(frequent_zones),
                        radio_breach_count         = VALUES(radio_breach_count),
                        average_purity_intercepted = VALUES(average_purity_intercepted),
                        purity_sample_count        = VALUES(purity_sample_count),
                        lockdown_active            = VALUES(lockdown_active),
                        updated_at                 = NOW()
                ]],
                values = {
                    trapHouseId,
                    json.encode(state.frequent_zones),
                    state.radio_breach_count,
                    state.average_purity_intercepted,
                    state.purity_sample_count or 0,
                    state.lockdown_active and 1 or 0
                }
            }
        end
        dirtyLearningCore[trapHouseId] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyLearningCore transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        Matrix.Bureau.FlushDirtyLearningCore()
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    Matrix.Log('BUREAU', '[SEC-3] Sunucu kapaniyor -- dirty-set son kurtarma flush islemi baslatildi.')
    local ok, err = pcall(function()
        Matrix.Bureau.FlushDirtyDecryption()
        Matrix.Bureau.FlushDirtyIntel()
        Matrix.Bureau.FlushDirtyPatternLog()
        Matrix.Bureau.FlushDirtyLearningCore()
    end)
    if not ok then
        Matrix.Log('BUREAU', '[HATA][SEC-3] Kapanis flush islemi sirasinda hata (yutulmadi, log icin): %s', tostring(err))
    else
        Matrix.Log('BUREAU', '[SEC-3] Kapanis flush islemi tamamlandi.')
    end
end)

local PATTERN_DECAY_INTERVAL_MS = 24 * 60 * 60 * 1000
local PATTERN_DECAY_FACTOR      = 0.5

CreateThread(function()
    while true do
        Wait(PATTERN_DECAY_INTERVAL_MS)
        for trapHouseId, buckets in pairs(patternLog) do
            local changed = false
            for key, count in pairs(buckets) do
                local decayed = math_floor(count * PATTERN_DECAY_FACTOR)
                if decayed ~= count then
                    buckets[key] = decayed
                    changed = true
                end
            end
            if changed then
                dirtyPatternLog[trapHouseId] = true
            end
        end
        Matrix.Log('BUREAU', '[SEC-5] Pattern log tazelik rotini calisti (x%.2f decay).', PATTERN_DECAY_FACTOR)
    end
end)

local function ComputeLockdownCoefficient(trapHouseId)
    local state = GetLearningState(trapHouseId)
    local breachRatio = math_min(state.radio_breach_count / Config.Bureau.LockdownBreachCeiling, 1.0)
    local purityRatio = math_min(state.average_purity_intercepted, 1.0)
    return (breachRatio * Config.Bureau.LockdownBreachWeight) + (purityRatio * Config.Bureau.LockdownPurityWeight)
end

local function EvaluateLockdown(trapHouseId)
    local state       = GetLearningState(trapHouseId)
    local coefficient = ComputeLockdownCoefficient(trapHouseId)

    if coefficient >= Config.Bureau.LockdownEvidenceThreshold and not state.lockdown_active then
        Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    elseif coefficient < Config.Bureau.LockdownEvidenceThreshold and state.lockdown_active then
        Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    end

    return coefficient
end

local function MarkLearningZone(state, label)
    local zones = state.frequent_zones
    for i = 1, #zones do
        if zones[i] == label then return end
    end
    zones[#zones + 1] = label
end

function Matrix.Bureau.RecordRadioBreach(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.radio_breach_count = state.radio_breach_count + 1
    MarkLearningZone(state, house.label)

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end

function Matrix.Bureau.RecordLivestreamRadioLeak(trapHouseId, multiplier)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.livestream_leak_accumulator = (state.livestream_leak_accumulator or 0.0)
        + (Config.Bureau.LivestreamRadioLeakPerTick * (multiplier or 1.0))

    local wholeBreaches = math_floor(state.livestream_leak_accumulator)
    if wholeBreaches < 1 then return end

    state.livestream_leak_accumulator = state.livestream_leak_accumulator - wholeBreaches
    state.radio_breach_count = state.radio_breach_count + wholeBreaches
    MarkLearningZone(state, house.label)

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end

function Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    if not Matrix.TrapHouses[trapHouseId] then return end

    MySQL.query('SELECT output_purity FROM matrix_kitchen_batches WHERE trap_house_id = ? ORDER BY id DESC LIMIT 1',
        { trapHouseId },
        function(rows)
            local row = rows and rows[1]
            if not row or row.output_purity == nil then return end

            local state  = GetLearningState(trapHouseId)
            local sample = Matrix.Clamp(tonumber(row.output_purity) or 0.0, 0.0, 1.0)

            state.purity_sample_count = (state.purity_sample_count or 0) + 1
            local n = state.purity_sample_count
            state.average_purity_intercepted = state.average_purity_intercepted + ((sample - state.average_purity_intercepted) / n)

            dirtyLearningCore[trapHouseId] = true
            EvaluateLockdown(trapHouseId)
        end)
end

function Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = true
    dirtyLearningCore[trapHouseId] = true

    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, true)

    -- ★ [DIAGNOSTIC LOG SUPPRESS] State ve event zinciri korunur,
    -- yalnızca test sırasında log kalabalığı bastırılır.
    if Matrix.Diagnostics and Matrix.Diagnostics.IsRunning then return end

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) icin NUKLEER ABLUKA DEVREDE (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end

function Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = false
    dirtyLearningCore[trapHouseId] = true

    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, false)

    -- ★ [DIAGNOSTIC LOG SUPPRESS] bkz. TriggerLockdown üstündeki not.
    if Matrix.Diagnostics and Matrix.Diagnostics.IsRunning then return end

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) ablukasi kalkti (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end

function Matrix.Bureau.IsLockedDown(trapHouseId)
    local state = learningCore[trapHouseId]
    return state ~= nil and state.lockdown_active == true
end

function Matrix.Bureau.GetLockdownBulletin(trapHouseId)
    if not trapHouseId or not Matrix.Bureau.IsLockedDown(trapHouseId) then return nil end
    return '[ADLI ANOMALI: BURO KILIDI DEVREDE]', true
end

RegisterCommand('burokilitdurum', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitdurum [trapHouseId]'); return end

    local state       = GetLearningState(id)
    local coefficient = ComputeLockdownCoefficient(id)
    Reply(src, ('Trap #%d | Telsiz-Ihlali:%d Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
        id, state.radio_breach_count, state.average_purity_intercepted,
        coefficient, Config.Bureau.LockdownEvidenceThreshold, tostring(state.lockdown_active)))
end, false)

RegisterCommand('burokilitzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitzorla [trapHouseId]'); return end
    Matrix.Bureau.TriggerLockdown(id, ComputeLockdownCoefficient(id))
    Reply(src, ('Trap #%d icin BURO KILIDI ZORLA tetiklendi (test modu).'):format(id))
end, false)

lib.callback.register('matrix:callback:getLearningCoreReport', function(src)
    local entries = {}

    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        local state       = GetLearningState(trapHouseId)
        local coefficient = ComputeLockdownCoefficient(trapHouseId)

        local text = ('Trap #%d (%s) | Telsiz-Ihlali:%d | Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
            trapHouseId, house.label, state.radio_breach_count, state.average_purity_intercepted,
            coefficient, Config.Bureau.LockdownEvidenceThreshold, state.lockdown_active and 'DEVREDE' or 'kapali')

        entries[#entries + 1] = {
            trap_house_id              = trapHouseId,
            label                      = house.label,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            coefficient                = coefficient,
            threshold                  = Config.Bureau.LockdownEvidenceThreshold,
            lockdown_active            = state.lockdown_active,
            text                       = text
        }
    end

    table.sort(entries, function(a, b) return a.trap_house_id < b.trap_house_id end)
    return entries
end)

CreateThread(function()
    while true do
        Wait((Config.AI_Matrix_Brain.analysisIntervalMinutes or 60) * 60000)

        if Config.AI_Matrix_Brain.enabled then
            local ok, err = pcall(Matrix.Bureau.RunAIAdvisoryPass)
            if not ok then
                Matrix.Log('BUREAU', '[T4][AI] RunAIAdvisoryPass hata verdi (yutuldu): %s', tostring(err))
            end
        end
    end
end)

function Matrix.Bureau.RunAIAdvisoryPass()
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Matrix.Log('BUREAU', '[T4][AI] enabled=true fakat apiKey yapilandirilmamis, deterministik motor degismeden devam ediyor.')
        return
    end

    local payload = {}
    for trapHouseId, state in pairs(learningCore) do
        payload[#payload + 1] = {
            trap_house_id              = trapHouseId,
            frequent_zones             = state.frequent_zones,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            lockdown_active            = state.lockdown_active
        }
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a deterministic police-heat auditor for a GTA roleplay server. Summarize risk trends only, never invent data, never suggest a course of action.' },
            { role = 'user', content = json.encode(payload) }
        }
    })

    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            Matrix.Log('BUREAU', '[T4][AI] OpenAI istegi basarisiz (HTTP %s); fallbackToDeterministic=%s, ogrenme motoru degismeden calismaya devam ediyor.',
                tostring(statusCode), tostring(Config.AI_Matrix_Brain.fallbackToDeterministic))
            return
        end

        local ok, decoded = pcall(json.decode, response)
        if not ok then
            Matrix.Log('BUREAU', '[T4][AI] OpenAI yaniti cozumlenemedi, deterministik motor etkilenmedi.')
            return
        end

        TriggerEvent('matrix:internal:aiAdvisoryReceived', decoded)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey
    })
end

-- =====================================================================
-- [OPSEC FAZ 1] POLİS KİŞİLİK GENETİĞİ + RÜŞVET MOTORU
-- =====================================================================
local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end

local PolicePersonalityCache = {}

function Matrix.Bureau.GetPolicePersonality(citizenid, npcModelHash, npcCoords)
    local identityKey
    if type(citizenid) == 'string' and citizenid ~= '' then
        identityKey = citizenid
    elseif npcModelHash ~= nil and IsValidCoords(npcCoords) then
        identityKey = ('NPC#%s#%.2f#%.2f#%.2f'):format(tostring(npcModelHash), npcCoords.x, npcCoords.y, npcCoords.z)
    else
        return nil
    end

    local cached = PolicePersonalityCache[identityKey]
    if cached then return cached end

    local sum = ChecksumOf(identityKey, 89)
    local personality = {
        integrity = Matrix.Clamp((sum % 1000) / 1000.0, 0.0, 1.0),
        greed     = Matrix.Clamp((math_floor(sum / 1000) % 1000) / 1000.0, 0.0, 1.0)
    }
    PolicePersonalityCache[identityKey] = personality

    Matrix.Log('BUREAU', '[OPSEC][KISILIK GENETIGI] %s -> integrity=%.3f greed=%.3f (salt=89, deterministik)',
        identityKey, personality.integrity, personality.greed)
    return personality
end

local function ChargeSuspectCash(src, amount)
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false end

    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < amount then return false end

    local removeOk, removeResult = pcall(function() return player.Functions.RemoveMoney('cash', amount, 'bribe-offer') end)
    return removeOk and removeResult == true
end

local function PaySuspectCashToOfficer(officerSrc, amount)
    local ok, officer = pcall(function() return Matrix.QBX:GetPlayer(officerSrc) end)
    if not ok or not officer then return false end
    pcall(function() officer.Functions.AddMoney('cash', amount, 'bribe-accepted') end)
    return true
end

function Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount, caseId)
    if type(officerSrc) ~= 'number' or officerSrc <= 0 then return false, 'bad_officer' end
    if type(suspectSrc) ~= 'number' or suspectSrc <= 0 then return false, 'bad_suspect' end
    if officerSrc == suspectSrc then return false, 'officer_is_suspect' end
    -- ★ v6.6.4-A2d: memur gerçekten görevli-yetkili olmalı (fail-closed)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then
        return false, 'hierarchy_missing'
    end
    do
        local _oState = Matrix.GetOrCreatePlayerState(officerSrc)
        if not _oState or not _oState.citizenid
            or not Matrix.Hierarchy.HasCommandAuthority(_oState.citizenid) then
            return false, 'officer_unauthorized'
        end
    end
    moneyAmount = tonumber(moneyAmount) or 0.0
        if moneyAmount ~= moneyAmount or moneyAmount <= 0.0 then return false, 'bad_amount' end
    local officerState = Matrix.GetOrCreatePlayerState(officerSrc)
    local suspectState = Matrix.GetOrCreatePlayerState(suspectSrc)
    if not officerState or not officerState.citizenid then return false, 'officer_unresolved' end
    if not suspectState or not suspectState.citizenid then return false, 'suspect_unresolved' end

    local cortisol = Matrix.Clamp((suspectState.biology and suspectState.biology.cortisol_level) or 0.0, 0.0, 1.0)

    local suspectPed    = GetPlayerPed(suspectSrc)
    local suspectCoords = (suspectPed and suspectPed ~= 0) and GetEntityCoords(suspectPed) or nil
    local trapHouseId   = suspectCoords and FindNearestTrapHouse(suspectCoords)

    if cortisol > Config.Kitchen.SnitchThreshold then
        if trapHouseId and Matrix.Bureau.RecordRadioBreach then
            Matrix.Bureau.RecordRadioBreach(trapHouseId)
        end
        Matrix.Log('BUREAU',
            '[RUSVET REDDEDILDI: PANIK] Supheli %s kortizol krizinde (%.3f > %.2f) -- adli surec isliyor.',
            suspectState.citizenid, cortisol, Config.Kitchen.SnitchThreshold)
        return false, { reason = 'suspect_panicking', cortisol = cortisol }
    end

    local personality = Matrix.Bureau.GetPolicePersonality(officerState.citizenid)
    if not personality then return false, 'officer_personality_unresolved' end

    local refAmount   = Config.Bureau.BribeReferenceAmount
    local moneyFactor = Matrix.Clamp(moneyAmount / math_max(refAmount, 1.0), 0.0, Config.Bureau.BribeMoneyFactorCeiling)
        * Config.Bureau.BribeMoneyWeight

    local score =
        (personality.greed * Config.Bureau.BribeGreedWeight)
        - (personality.integrity * Config.Bureau.BribeIntegrityWeight)
        - (cortisol * Config.Bureau.BribeCortisolWeight)
        + moneyFactor

    local threshold = Config.Bureau.BribeSuccessThreshold
    local success    = score >= threshold

    if success then
        local charged = ChargeSuspectCash(suspectSrc, moneyAmount)
        if charged then
            PaySuspectCashToOfficer(officerSrc, moneyAmount)
        end

        local tamperedCaseId = nil
        if type(caseId) == 'string' and caseId ~= '' and Matrix.Forensics and Matrix.Forensics.TamperEvidenceLockup then
            local tOk = Matrix.Forensics.TamperEvidenceLockup(officerState.citizenid, caseId, true)
            if tOk then tamperedCaseId = caseId end
        end

        Matrix.Log('BUREAU',
            '[RUSVET BASARILI] Memur %s (greed=%.3f integrity=%.3f) <- Supheli %s $%.0f | skor=%.3f/%.2f | odeme:%s | sabote-edilen-vaka:%s',
            officerState.citizenid, personality.greed, personality.integrity,
            suspectState.citizenid, moneyAmount, score, threshold, tostring(charged), tostring(tamperedCaseId))

        return true, { score = score, threshold = threshold, charged = charged, tampered_case = tamperedCaseId }
    end

    if trapHouseId and Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end

    Matrix.Log('BUREAU',
        '[RUSVET REDDEDILDI] Memur %s (greed=%.3f integrity=%.3f) <- Supheli %s $%.0f | skor=%.3f/%.2f | adli surec isliyor',
        officerState.citizenid, personality.greed, personality.integrity,
        suspectState.citizenid, moneyAmount, score, threshold)

    return false, { score = score, threshold = threshold, reason = 'refused' }
end

RegisterNetEvent('matrix:server:bureau:offerBribe', function(officerSrc, moneyAmount, caseId)
    local suspectSrc = source
    if type(suspectSrc) ~= 'number' or suspectSrc <= 0 then return end
    officerSrc = tonumber(officerSrc)
    if not officerSrc then return end

    local ok, resultOrReason = Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount, caseId)
    local detail = (type(resultOrReason) == 'table' and resultOrReason.reason) or tostring(resultOrReason)

    TriggerClientEvent('matrix:client:actionNotify', suspectSrc, ok,
        ok and 'Memur rusveti kabul etti.' or ('Rusvet reddedildi: %s'):format(tostring(detail)))

    if officerSrc > 0 and officerSrc ~= suspectSrc then
        TriggerClientEvent('matrix:client:actionNotify', officerSrc, ok,
            ok and 'Bir supheli rusvet teklif etti ve kabul ettiniz.' or 'Bir supheli rusvet teklif etti, reddettiniz/panikledi.')
    end
end)

RegisterCommand('rusvetteklifi', function(src, args)
    local officerSrc  = tonumber(args[1])
    local moneyAmount = tonumber(args[2])
    local caseId      = args[3]
    if not officerSrc or not moneyAmount then
        Reply(src, 'Kullanim: /rusvetteklifi [memurSrc] [miktar] [caseId/ballisticId (opsiyonel)]'); return
    end

    local ok, resultOrReason = Matrix.Bureau.ProcessBribeOffer(officerSrc, src, moneyAmount, caseId)
    if ok then
        Reply(src, ('Rusvet KABUL EDILDI (skor:%.3f/%.2f)%s.'):format(
            resultOrReason.score, resultOrReason.threshold,
            resultOrReason.tampered_case and (' | Vaka #%s sabote edildi'):format(resultOrReason.tampered_case) or ''))
    else
        local detail = (type(resultOrReason) == 'table')
            and ('%s | skor:%.3f/%.2f'):format(tostring(resultOrReason.reason), resultOrReason.score or 0, resultOrReason.threshold or 0)
            or tostring(resultOrReason)
        Reply(src, ('Rusvet REDDEDILDI (%s).'):format(detail))
    end
end, false)

RegisterCommand('polisgenetigi', function(src, args)
    local citizenid = args[1]
    if type(citizenid) ~= 'string' then Reply(src, 'Kullanim: /polisgenetigi [citizenid]'); return end

    local personality = Matrix.Bureau.GetPolicePersonality(citizenid)
    if not personality then Reply(src, 'Kisilik hesaplanamadi.'); return end

    Reply(src, ('%s -> Integrity:%.3f Greed:%.3f'):format(citizenid, personality.integrity, personality.greed))
end, false)

exports('GetPolicePersonality', function(citizenid, npcModelHash, npcCoords)
    return Matrix.Bureau.GetPolicePersonality(citizenid, npcModelHash, npcCoords)
end)
exports('ProcessBribeOffer', function(officerSrc, suspectSrc, moneyAmount)
    return Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount)
end)

-- =====================================================================
-- [OPSEC FAZ 1 EK] FEAR COEFFICIENT
-- =====================================================================
local cachedFearCoefficient = 0.0
local cachedEliminatedCount = 0

local function RefreshFearCoefficient()
    local rows = MySQL.query.await("SELECT COUNT(*) AS n FROM matrix_raid_log WHERE outcome = 'eliminated'", {})
    local n = (rows and rows[1] and tonumber(rows[1].n)) or 0
    cachedEliminatedCount = n

    local ceiling = CfgBureau('FearCoefficientEliminationCeiling', 20)
    cachedFearCoefficient = Matrix.Clamp(n / math_max(ceiling, 1), 0.0, 1.0)
end

CreateThread(function()
    local ok, err = pcall(RefreshFearCoefficient)
    if not ok then
        Matrix.Log('BUREAU', '[HATA] RefreshFearCoefficient ilk yukleme basarisiz (yutuldu): %s', tostring(err))
    end
    while true do
        Wait(CfgBureau('FearCoefficientRefreshIntervalMs', 120000))
        local tickOk, tickErr = pcall(RefreshFearCoefficient)
        if not tickOk then
            Matrix.Log('BUREAU', '[HATA] RefreshFearCoefficient hata verdi (yutuldu): %s', tostring(tickErr))
        end
    end
end)

function Matrix.Bureau.GetFearCoefficient()
    return cachedFearCoefficient
end

function Matrix.Bureau.GetEffectiveSnitchThreshold()
    local base    = Config.Kitchen.SnitchThreshold
    local ceiling = CfgBureau('FearCoefficientSnitchCeiling', 0.95)
    local raised  = base + ((ceiling - base) * cachedFearCoefficient)
    return Matrix.Clamp(raised, base, ceiling)
end

RegisterCommand('korkudurum', function(src)
    Reply(src, ('Infaz-Sayisi:%d | FearCoefficient:%.3f | Taban-Esik:%.2f -> Efektif-Esik:%.3f (tavan:%.2f)'):format(
        cachedEliminatedCount, cachedFearCoefficient,
        Config.Kitchen.SnitchThreshold, Matrix.Bureau.GetEffectiveSnitchThreshold(),
        CfgBureau('FearCoefficientSnitchCeiling', 0.95)))
end, false)

exports('GetFearCoefficient', function() return Matrix.Bureau.GetFearCoefficient() end)
exports('GetEffectiveSnitchThreshold', function() return Matrix.Bureau.GetEffectiveSnitchThreshold() end)

-- =====================================================================
-- [GLOBAL CONVAR] GetBureaucraticVelocity
-- =====================================================================
function Matrix.Bureau.GetBureaucraticVelocity()
    local intensity = GetConvarFloat('matrix_bureau_intensity', 1.0)
    if type(intensity) ~= 'number' or intensity ~= intensity or intensity <= 0.0 then
        intensity = 1.0
    end
    return intensity
end

exports('GetBureaucraticVelocity', function() return Matrix.Bureau.GetBureaucraticVelocity() end)

-- =====================================================================
-- [ADLİ RPG] MAHKEME İFADE ZİNCİRİ
-- =====================================================================
local TrialSessions = {}

function Matrix.Bureau.RequestAITrialNarrative(officerSrc, session)
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Reply(officerSrc, '[ADLİ İFADE] enabled=true fakat apiKey yapılandırılmamış; deterministik veriler değişmeden gösteriliyor.')
        Reply(officerSrc, ('Sanık DNA:%s | Eşleşme: %%%.1f'):format(session.dna_id, session.match_certainty * 100.0))
        return
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a Turkish-speaking courtroom narrator for a fictional GTA roleplay server. Given deterministic forensic match data, write a short reasoned (gerekceli) verdict narrative in Turkish. Never invent data beyond what is given, never claim it is a real legal proceeding.' },
            { role = 'user', content = json.encode({
                dna_id          = session.dna_id,
                ballistic_id    = session.ballistic_id,
                match_certainty = session.match_certainty
            }) }
        }
    })

    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            Reply(officerSrc, ('[ADLİ İFADE] OpenAI istegi basarisiz (HTTP %s); deterministik motor degismeden devam ediyor.'):format(tostring(statusCode)))
            return
        end
        local ok, decoded = pcall(json.decode, response)
        if not ok or not decoded.choices or not decoded.choices[1] then
            Reply(officerSrc, '[ADLİ İFADE] OpenAI yaniti cozumlenemedi.')
            return
        end
        local narrative = decoded.choices[1].message and decoded.choices[1].message.content
        Reply(officerSrc, '[MAHKEME KARARI - AI GEREKCE]')
        Reply(officerSrc, tostring(narrative or 'Anlati uretilemedi.'))
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey
    })
end

function Matrix.Bureau.OpenTrial(officerSrc, defendantSrc, dnaId)
    -- ★ v6.6.4-A2d: memur yetki kapısı (fail-closed)
    officerSrc = tonumber(officerSrc)
    if not officerSrc or officerSrc <= 0 then return false, 'bad_officer_src' end
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then
        return false, 'hierarchy_missing'
    end
    do
        local _oState = Matrix.GetOrCreatePlayerState(officerSrc)
        if not _oState or not _oState.citizenid
            or not Matrix.Hierarchy.HasCommandAuthority(_oState.citizenid) then
            return false, 'officer_unauthorized'
        end
    end

    defendantSrc = tonumber(defendantSrc)
    if not defendantSrc or type(dnaId) ~= 'string' or dnaId == '' then return false, 'bad_args' end

    local defendantState = Matrix.GetOrCreatePlayerState(defendantSrc)
    if not defendantState or not defendantState.citizenid then return false, 'defendant_unresolved' end

    local rows = MySQL.query.await(
        'SELECT ballistic_id, match_certainty FROM matrix_forensic_evidence WHERE fingerprint_id = ? ORDER BY match_certainty DESC',
        { dnaId }) or {}

    local ballisticId, matchCertainty = nil, 0.0
    if rows[1] then
        ballisticId = rows[1].ballistic_id
        local total = 0.0
        for _, r in ipairs(rows) do total = total + (tonumber(r.match_certainty) or 0.0) end
        matchCertainty = total / #rows
    end

        -- ★ [FAZ 2] Paravan Liability Insulation
    local defendantPed    = GetPlayerPed(defendantSrc)
    local defendantCoords = (defendantPed and defendantPed ~= 0) and GetEntityCoords(defendantPed) or nil
    local parentTrapId
    if defendantCoords then
        parentTrapId = FindNearestTrapHouse(defendantCoords)
    end

    local liabilityCitizenid = defendantState.citizenid
    local paravanInsulated   = false
    if parentTrapId then
        liabilityCitizenid, paravanInsulated =
            Matrix.Bureau.ResolveParavanLiability(parentTrapId, defendantState.citizenid)
    end

    local session = {
        defendant_src            = defendantSrc,
        defendant_citizenid      = liabilityCitizenid,
        real_defendant_citizenid = defendantState.citizenid,
        paravan_insulated        = paravanInsulated,
        parent_trap_house_id     = parentTrapId,
        dna_id                   = dnaId,
        ballistic_id             = ballisticId,
        match_certainty          = matchCertainty,
        lie_count                = 0,
        conviction_weight        = matchCertainty,
        opened_at                = Matrix.Now()
    }
    TrialSessions[liabilityCitizenid] = session

    MySQL.insert([[
        INSERT INTO matrix_trial_records
            (defendant_citizenid, dna_id, ballistic_id, match_certainty, lie_count, conviction_weight, verdict, opened_at)
        VALUES (?, ?, ?, ?, 0, ?, 'pending', NOW())
    ]], { defendantState.citizenid, dnaId, ballisticId, matchCertainty, matchCertainty })

    if not Config.AI_Matrix_Brain.enabled then
        Reply(officerSrc,
            ('[ADLİ İFADE - FAZ 1] Sanik DNA:%s | Namlu izi eslesmesi: %%%.1f%s'):format(
                dnaId, matchCertainty * 100.0,
                ballisticId and (' (Balistik #%s)'):format(ballisticId) or ' (eslesen balistik kaydi yok)'))
        Reply(officerSrc,
            matchCertainty >= Config.Forensics.MatchCertaintyThreshold
                and 'Kanitlar saniği dogrudan isaret ediyor. /davasorgula ile ifadesini sorgulayin.'
                or 'Kanitlar zayif. Sanik makul bir itirazla temize cikabilir.')
    else
        Reply(officerSrc, '[ADLİ İFADE - FAZ 1] Dava dosyasi OpenAI analiz koprusune gonderildi, gerekceli karar hazirlaniyor...')
        pcall(Matrix.Bureau.RequestAITrialNarrative, officerSrc, session)
    end

    return true, session
end

function Matrix.Bureau.RecordTrialResponse(officerSrc, defendantSrc, responseKind)
    -- ★ v6.6.4-A2d: memur yetki + memur!=sanık zorunluluğu
    officerSrc = tonumber(officerSrc)
    defendantSrc = tonumber(defendantSrc)
    if not officerSrc or officerSrc <= 0 then return false, 'bad_officer_src' end
    if not defendantSrc then return false, 'bad_args' end
    if officerSrc == defendantSrc then return false, 'officer_is_defendant' end
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then
        return false, 'hierarchy_missing'
    end
    do
        local _oState = Matrix.GetOrCreatePlayerState(officerSrc)
        if not _oState or not _oState.citizenid
            or not Matrix.Hierarchy.HasCommandAuthority(_oState.citizenid) then
            return false, 'officer_unauthorized'
        end
    end

    local defendantState = Matrix.GetOrCreatePlayerState(defendantSrc)
    if not defendantState or not defendantState.citizenid then return false, 'defendant_unresolved' end

    local session = TrialSessions[defendantState.citizenid]
    if not session then return false, 'no_open_case' end

    responseKind = tostring(responseKind or ''):lower()
    local isLie       = (responseKind == 'yalan' or responseKind == 'inkar')
    local isConfession = (responseKind == 'itiraf' or responseKind == 'dogru')
    if not isLie and not isConfession then return false, 'bad_response_kind' end

    if isConfession then
        session.conviction_weight = 1.0
    else
        if session.match_certainty >= Config.Forensics.MatchCertaintyThreshold then
            session.lie_count = session.lie_count + 1
            session.conviction_weight = math_min(
                (session.conviction_weight * Config.Bureau.TrialConvictionGeometricFactor) + Config.Bureau.TrialConvictionIncrement,
                1.0
            )
        end
    end

    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET lie_count = ?, conviction_weight = ?
        WHERE defendant_citizenid = ? AND verdict = 'pending'
        ORDER BY opened_at DESC LIMIT 1
    ]], { session.lie_count, session.conviction_weight, session.defendant_citizenid })

    Reply(officerSrc, ('[ADLİ İFADE - FAZ 2] Yalan-Sayaci:%d | Mahkumiyet-Skoru:%%%.1f'):format(
        session.lie_count, session.conviction_weight * 100.0))

    if session.conviction_weight >= 1.0 then
        Matrix.Bureau.ExecuteVerdict(officerSrc, session)
        TrialSessions[session.defendant_citizenid] = nil
        return true, { verdict = 'imprisoned' }
    end

    return true, { verdict = 'pending' }
end

function Matrix.Bureau.ExecuteVerdict(officerSrc, session)
    local citizenid   = session.defendant_citizenid
    local defendantSrc = session.defendant_src

    MySQL.prepare('UPDATE matrix_player_state SET imprisoned = 1 WHERE citizenid = ?', { citizenid })
    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET verdict = 'imprisoned', lie_count = ?, conviction_weight = 1.0, closed_at = NOW()
        WHERE defendant_citizenid = ? AND verdict = 'pending'
    ]], { session.lie_count, citizenid })

    local dbOk, dbErr = pcall(function()
        return MySQL.query.await('UPDATE matrix_bots SET status = ? WHERE handler_citizenid = ?', { 'disbanded', citizenid })
    end)
    if not dbOk then
        Matrix.Log('BUREAU', '[HATA] ExecuteVerdict bulk-disband DB guncellemesi basarisiz: %s', tostring(dbErr))
    end

    local disbandedCount = 0
    for id, bot in pairs(Matrix.Bots) do
        if bot.handler_citizenid == citizenid then
            if Matrix.Dispatches and Matrix.Dispatches[id] then
                Matrix.DespawnDispatchEntity(id, Matrix.Dispatches[id])
                Matrix.Dispatches[id] = nil
            end
            Matrix.Bots[id] = nil
            disbandedCount = disbandedCount + 1
        end
    end

    Matrix.Log('BUREAU',
        '[KARAKTER WIPE - MAHKUM] %s -> imprisoned=1, %d bagli otonom bot disbanded moduna cekildi.',
        citizenid, disbandedCount)

    Reply(officerSrc, ('[MAHKEME KARARI] %s -> %%100 Mahkumiyet Skoru. Karakter kilitlendi ve sunucudan tekmelendi.'):format(citizenid))

        -- ★ [FAZ 2] Paravan insulation
    if session.paravan_insulated then
        Matrix.Log('BUREAU',
            '[PARAVAN_REAL_ESTATE_PHASE2] Wipe IZOLE: insan=%s korundu, paravan=%s infaz edildi.',
            tostring(session.real_defendant_citizenid), tostring(citizenid))
        if defendantSrc then
            pcall(function()
                TriggerClientEvent('matrix:client:actionNotify', defendantSrc, true,
                    'Paravan tapu sayesinde hukuki kimligin korundu.')
            end)
        end
    else
        if defendantSrc then
            pcall(function()
                DropPlayer(defendantSrc, 'MAHKUM EDILDINIZ: Adli surec sonucunda karakteriniz kalici olarak muhurlendi.')
            end)
        end
    end
end

RegisterCommand('davaac', function(src, args)
    local defendantSrc = tonumber(args[1])
    local dnaId = args[2]
    if not defendantSrc or type(dnaId) ~= 'string' then
        Reply(src, 'Kullanim: /davaac [defendantRef(src)] [dnaId]'); return
    end
    local ok, resultOrReason = Matrix.Bureau.OpenTrial(src, defendantSrc, dnaId)
    if not ok then
        Reply(src, ('Dava acilamadi: %s'):format(tostring(resultOrReason)))
    end
end, false)

RegisterCommand('davasorgula', function(src, args)
    local defendantSrc = tonumber(args[1])
    local responseKind = args[2]
    if not defendantSrc or not responseKind then
        Reply(src, 'Kullanim: /davasorgula [defendantRef(src)] [itiraf|yalan]'); return
    end
    local ok, resultOrReason = Matrix.Bureau.RecordTrialResponse(src, defendantSrc, responseKind)
    if not ok then
        Reply(src, ('Sorgu basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)

exports('OpenTrial', function(officerSrc, defendantSrc, dnaId) return Matrix.Bureau.OpenTrial(officerSrc, defendantSrc, dnaId) end)
exports('RecordTrialResponse', function(officerSrc, defendantSrc, responseKind) return Matrix.Bureau.RecordTrialResponse(officerSrc, defendantSrc, responseKind) end)

-- =====================================================================
-- [KOR NOKTA] /telefonuyoket — TELEFON HATTI ADLİ SABOTAJI
-- =====================================================================
function Matrix.Bureau.SabotagePhoneLine(src, dnaId)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end

    if type(dnaId) ~= 'string' or dnaId == '' then
        local state = Matrix.GetOrCreatePlayerState(src)
        dnaId = state and state.dna_id
    end
    if type(dnaId) ~= 'string' or dnaId == '' then return false, 'bad_dna' end

    local queries = {
        { query = 'DELETE FROM matrix_encrypted_messages WHERE dna_id = ?', values = { dnaId } },
        { query = "DELETE FROM matrix_forensic_evidence WHERE fingerprint_id = ? AND evidence_type = 'cyber' AND sealed_as_crime_weapon = 0", values = { dnaId } }
    }

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or result == false then
        Matrix.Log('BUREAU', '[HATA] SabotagePhoneLine transaction basarisiz: %s', tostring(result))
        return false, 'db_error'
    end

    Matrix.Log('BUREAU',
        '[TELEFON HATTI SABOTAJI] %s -> kriptolu mesajlar + kesinlesmemis siber deliller TEK atomik transaction ile kazindi.',
        dnaId)
    return true, { dna_id = dnaId }
end

RegisterCommand('telefonuyoket', function(src, args)
    local ok, resultOrReason = Matrix.Bureau.SabotagePhoneLine(src, args[1])
    if ok then
        Reply(src, ('[HAT SABOTAJI] %s hattina ait kriptolu mesajlar ve kesinlesmemis siber deliller kalici olarak kazindi.'):format(resultOrReason.dna_id))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)

exports('SabotagePhoneLine', function(src, dnaId) return Matrix.Bureau.SabotagePhoneLine(src, dnaId) end)

-- =====================================================================
-- [KOR NOKTA] KOMA MODU
-- =====================================================================
local ComaClock = {}

local function ProcessComaCycle()
    for botId, bot in pairs(Matrix.Bots) do
        if bot.status == 'active' and bot.biology and (bot.biology.withdrawal_index or 0.0) >= 1.0 then
            bot.status = 'comatose'
            Matrix.MarkBotDirty(botId)
            ComaClock[botId] = Matrix.Now()

            if Matrix.Dispatches and Matrix.Dispatches[botId] then
                Matrix.CompleteDispatch(botId, 'panic_recall')
            end

            Matrix.Log('CORE',
                '[KOMA MODU] Bot #%d withdrawal_index=%.3f -- sevk emirleri VE telsiz iletisimi TAMAMEN bloke edildi.',
                botId, bot.biology.withdrawal_index)
        elseif bot.status == 'comatose' then
            local since = ComaClock[botId]
            local ceilingHours = Config.Kitchen.ComaToDeceasedRealHours or 2
            if since and (Matrix.Now() - since) >= (ceilingHours * 3600) then
                ComaClock[botId] = nil
                Matrix.Log('CORE',
                    '[KOMA -> OLUM] Bot #%d %d saat mudahalesiz koma modunda kaldi, deceased arsivine dustu.',
                    botId, ceilingHours)
                Matrix.RemoveBot(botId, 'deceased')
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessComaCycle)
        if not ok then
            Matrix.Log('CORE', '[HATA] ProcessComaCycle hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

-- =====================================================================
-- [KOR NOKTA] SAATLİK MALİ DENETİM
-- =====================================================================
function Matrix.Bureau.RunHourlyFinancialAudit()
    local ok, result = pcall(function()
        return MySQL.query.await('DELETE FROM matrix_purchase_logs WHERE created_at < (NOW() - INTERVAL 24 HOUR)', {})
    end)
    if not ok then
        Matrix.Log('BUREAU', '[HATA] RunHourlyFinancialAudit budama basarisiz: %s', tostring(result))
        return
    end
    local affected = (type(result) == 'table' and (result.affectedRows or result.numAffected)) or 0
    Matrix.Log('BUREAU', '[SAATLIK MALI DENETIM] matrix_purchase_logs budandi (24 saatten eski %s satir silindi).', tostring(affected))
end

CreateThread(function()
    while true do
        Wait(3600000)
        local ok, err = pcall(Matrix.Bureau.RunHourlyFinancialAudit)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] RunHourlyFinancialAudit hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

exports('RunHourlyFinancialAudit', function() return Matrix.Bureau.RunHourlyFinancialAudit() end)

-- =====================================================================
-- ★★★ KATMAN 8 — CEPHE B: ANONİM KRİPTO CÜZDAN AĞLARI (SEC-6) ★★★
-- Rolling cipher mutasyon protokolü. shared/crypto.lua'nın saf Lua SHA-256
-- uygulaması (sha256.hex) ile 64-karakterlik deterministik hex üretimi
-- yapılır.
-- SIFIR RNG: math.random YOKTUR.
--
-- ★★★ YAMA 2 (BU SÜRÜM) ★★★
--   • _BurnAndRaid KALDIRILDI → _BurnAndRaidByHolder(holderIdentifier).
--     Ceza artık çağıranın targetIdentifier'ına DEĞİL, DB satır kilidinden
--     okunan GERÇEK holder'a yönelir. Asimetrik grief vector kapatıldı.
--   • ProcessBribeCryptoTransaction:
--       - Lua-seviyesi satır kilidi (Matrix.Bureau.__CryptoLocks).
--       - SELECT ... FOR UPDATE ile InnoDB satır kilidi.
--       - Context drift, holderIdentifier üzerinden (DB'den okunan) teyit.
--       - CAS UPDATE (WHERE rolling_cipher_key = oldKey).
--       - Yalnızca KAZANAN CAS RAM önbelleğine yazar.
--   • [YAMA 5 KOD SAVUNMASI] Multi-match uyarısı: dna_id UNIQUE KEY
--     migration eksikse bile ikinci eşleşme SİLİNMEZ.
-- =====================================================================

Matrix.Bureau.CryptoWallets = Matrix.Bureau.CryptoWallets or {}
Matrix.Bureau.__CryptoLocks = Matrix.Bureau.__CryptoLocks or {}

function Matrix.Bureau.GenerateWalletAddress(holderIdentifier, holderType)
    local seed = ('%s#%s#%s'):format(tostring(holderIdentifier), tostring(holderType), GetCurrentResourceName())
    return '0x' .. sha256.hex(seed):sub(1, 62)
end

local function _LoadCryptoWallet(walletAddress)
    local cached = Matrix.Bureau.CryptoWallets[walletAddress]
    if cached then return cached end
    local row = MySQL.single.await(
        'SELECT wallet_address, holder_identifier, holder_type, crypto_balance, rolling_cipher_key, tx_sequence FROM matrix_crypto_wallets WHERE wallet_address = ?',
        { walletAddress })
    if not row then return nil end
    cached = {
        wallet_address     = row.wallet_address,
        holder_identifier  = row.holder_identifier,
        holder_type        = row.holder_type,
        crypto_balance     = tonumber(row.crypto_balance) or 0.0,
        rolling_cipher_key = row.rolling_cipher_key,
        tx_sequence        = tonumber(row.tx_sequence) or 0,
    }
    Matrix.Bureau.CryptoWallets[walletAddress] = cached
    return cached
end

function Matrix.Bureau.EnsureCryptoWallet(holderIdentifier, holderType)
    if type(holderIdentifier) ~= 'string' or holderIdentifier == '' then return nil end
    holderType = (holderType == 'bot') and 'bot' or 'player'
    local addr = Matrix.Bureau.GenerateWalletAddress(holderIdentifier, holderType)
    local existing = _LoadCryptoWallet(addr)
    if existing then return existing end

    local initialKey = sha256.hex(('%s#%s#GENESIS'):format(addr, holderIdentifier))
    local rec = {
        wallet_address     = addr,
        holder_identifier  = holderIdentifier,
        holder_type        = holderType,
        crypto_balance     = 0.0,
        rolling_cipher_key = initialKey,
        tx_sequence        = 0,
    }
    MySQL.insert([[
        INSERT INTO matrix_crypto_wallets
            (wallet_address, holder_identifier, holder_type, crypto_balance, rolling_cipher_key, tx_sequence)
        VALUES (?, ?, ?, 0.0, ?, 0)
    ]], { addr, holderIdentifier, holderType, initialKey })
    Matrix.Bureau.CryptoWallets[addr] = rec
    return rec
end

--- ★ [YAMA 2 + YAMA 5] Burn + Raid — YALNIZCA DB'den okunan meşru
--- holder_identifier ile çağrılır. Çağıranın targetIdentifier'ına ASLA
--- güvenilmez. Multi-match görürse ikinci eşleşmeyi SİLMEZ, UYARI basar.
local function _BurnAndRaidByHolder(holderIdentifier)
    if type(holderIdentifier) ~= 'string' or holderIdentifier == '' then return end

    -- ★ [YAMA 5] Tek-eşleşme zorlaması (dna_id UNIQUE KEY migration'ı
    -- uygulanmamışsa belt-and-suspenders).
    local matchedBotId
    for id, bot in pairs(Matrix.Bots or {}) do
        if bot.dna_id == holderIdentifier then
            if matchedBotId then
                Matrix.Log('BUREAU',
                    '[YAMA 5][MULTI-MATCH] dna_id=%s id=%d ile id=%d arasinda cakisti -- UNIQUE KEY migration eksik. Ikinci SILINMEDI.',
                    holderIdentifier, matchedBotId, id)
                break
            end
            matchedBotId = id
        end
    end

    if matchedBotId then
        local bot = Matrix.Bots[matchedBotId]
        if bot and bot.status ~= 'burned' then
            bot.status = 'burned'
            Matrix.MarkBotDirty(matchedBotId)
        end
    end

    -- Trap house seçimi: EN KÜÇÜK id (deterministik, RNG yok).
    local firstTrapId
    for id in pairs(Matrix.TrapHouses or {}) do
        if not firstTrapId or id < firstTrapId then firstTrapId = id end
    end
    if firstTrapId and Matrix.Bureau.IssueRaid then
        pcall(Matrix.Bureau.IssueRaid, firstTrapId)
    end
end

--- ★ [SEC-6][YAMA 2] Rolling cipher mutasyon protokolü — Lua-seviyesi
--- satır kilidi + SELECT ... FOR UPDATE + DB CAS.
---
--- Akış:
---   1) __CryptoLocks[walletAddress] al (aynı cüzdana eşzamanlı giriş yasak).
---   2) SELECT ... FOR UPDATE (InnoDB satır kilidi, taze okuma).
---   3) Context drift kontrolü — DB holder ile target uyuşmuyorsa RED.
---   4) CAS UPDATE (WHERE rolling_cipher_key = oldKey).
---   5) Yalnızca affected == 1 ise RAM önbelleğine yaz.
---   6) Kilit HER durumda bırakılır (pcall/finally).
function Matrix.Bureau.ProcessBribeCryptoTransaction(walletAddress, amount, targetIdentifier)
    if type(walletAddress) ~= 'string' or walletAddress == '' then return false, 'bad_wallet' end
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount <= 0.0 then return false, 'bad_amount' end
    if type(targetIdentifier) ~= 'string' or targetIdentifier == '' then return false, 'bad_target' end

    -- ★ 1) Lua-seviyesi satır kilidi (aynı cüzdan için yarış serializasyonu).
    if Matrix.Bureau.__CryptoLocks[walletAddress] then
        return false, 'wallet_busy'
    end
    Matrix.Bureau.__CryptoLocks[walletAddress] = true

    local function _releaseLock()
        Matrix.Bureau.__CryptoLocks[walletAddress] = nil
    end

    -- ★ 2) SELECT ... FOR UPDATE (InnoDB satır kilidi).
    local selOk, selRows = pcall(function()
        return MySQL.query.await(
            'SELECT holder_identifier, holder_type, crypto_balance, rolling_cipher_key, tx_sequence FROM matrix_crypto_wallets WHERE wallet_address = ? FOR UPDATE',
            { walletAddress })
    end)
    if not selOk or type(selRows) ~= 'table' or not selRows[1] then
        _releaseLock()
        return false, 'wallet_not_found'
    end
    local row = selRows[1]
    local holderIdentifier = row.holder_identifier
    local balance          = tonumber(row.crypto_balance) or 0.0
    local oldKey           = row.rolling_cipher_key
    local oldSeq           = tonumber(row.tx_sequence) or 0

    -- ★ 3) Context drift: DB holder ile target uyuşmuyor.
    -- KURBAN KORUMASI: burn+raid DB'den okunan meşru holder üzerinde.
    if holderIdentifier ~= targetIdentifier then
        _releaseLock()
        Matrix.Bureau.CryptoWallets[walletAddress] = nil
        _BurnAndRaidByHolder(holderIdentifier)
        Matrix.Log('BUREAU',
            '[SEC-6][CONTEXT DRIFT] wallet=%s legit-holder=%s caller-target=%s -- ROLLBACK, burn+raid LEGIT holder uzerinde.',
            walletAddress, holderIdentifier, targetIdentifier)
        return false, 'context_drift'
    end

    if balance < amount then
        _releaseLock()
        return false, 'insufficient_balance'
    end

    -- ★ 4) Cipher mutasyonu (deterministik, RNG yok).
    local newSeq = oldSeq + 1
    local mutationInput = ('%s#%.4f#%s#%d'):format(oldKey, amount, holderIdentifier, newSeq)
    local newKey     = sha256.hex(mutationInput)
    local newBalance = balance - amount

    -- ★ 5) CAS UPDATE — WHERE rolling_cipher_key = oldKey.
    local updOk, affected = pcall(function()
        return MySQL.update.await([[
            UPDATE matrix_crypto_wallets
            SET crypto_balance = ?, rolling_cipher_key = ?, tx_sequence = ?, updated_at = NOW()
            WHERE wallet_address = ? AND rolling_cipher_key = ?
        ]], { newBalance, newKey, newSeq, walletAddress, oldKey })
    end)

    _releaseLock()

    if not updOk or type(affected) ~= 'number' or affected == 0 then
        -- CAS başarısız. RAM önbelleği SİLİNİR (lazy reload).
        -- ★ KURBAN KORUMASI: burn+raid DB'den okunan holder üzerinde.
        Matrix.Bureau.CryptoWallets[walletAddress] = nil
        _BurnAndRaidByHolder(holderIdentifier)
        Matrix.Log('BUREAU',
            '[SEC-6][CIPHER DRIFT / RACE] wallet=%s -- CAS reddedildi, burn+raid LEGIT holder (%s) uzerinde.',
            walletAddress, holderIdentifier)
        return false, 'cipher_drift'
    end

    -- ★ 6) Yalnızca KAZANAN CAS RAM önbelleğine yazar.
    Matrix.Bureau.CryptoWallets[walletAddress] = {
        wallet_address     = walletAddress,
        holder_identifier  = holderIdentifier,
        holder_type        = row.holder_type,
        crypto_balance     = newBalance,
        rolling_cipher_key = newKey,
        tx_sequence        = newSeq,
    }

    Matrix.Log('BUREAU',
        '[SEC-6][CRYPTO] wallet=%s -> $%.4f transfer, tx_seq=%d, cipher mutasyona ugradi.',
        walletAddress, amount, newSeq)
    return true, { tx_sequence = newSeq, balance = newBalance }
end

exports('ProcessBribeCryptoTransaction', function(walletAddress, amount, targetIdentifier)
    return Matrix.Bureau.ProcessBribeCryptoTransaction(walletAddress, amount, targetIdentifier)
end)
exports('EnsureCryptoWallet', function(holderIdentifier, holderType)
    return Matrix.Bureau.EnsureCryptoWallet(holderIdentifier, holderType)
end)
exports('GenerateWalletAddress', function(holderIdentifier, holderType)
    return Matrix.Bureau.GenerateWalletAddress(holderIdentifier, holderType)
end)


-- =====================================================================
-- ★ [FAZ 1] SEC-7 DİNAMİK PAROLA + OPSEC TAMPER LOG
-- Additive. Mevcut hiçbir fonksiyon gövdesi DEĞİŞTİRİLMEDİ.
-- =====================================================================

-- SHA256-benzeri checksum (shared/crypto.lua sha256.hex AILESINDEN AYRI,
-- kasitli olarak daha ucuz bir dogrulama katmani -- bkz. asagidaki not).
local function _OpsecChecksum(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end

local function _OpsecHash(passphrase)
    local input = tostring(passphrase or '')
    local out = {}
    for i = 1, 16 do
        local raw = ('OPSEC#%s#%d'):format(input, i)
        out[i] = ('%04X'):format(_OpsecChecksum(raw, 173 + i) % 0x10000)
    end
    return table.concat(out, '')
end
Matrix.Bureau.__OpsecHash = _OpsecHash

-- ---------------------------------------------------------------
-- Parola rotasyonu (oyun içi /opsecparola ile tetiklenir)
-- ---------------------------------------------------------------
function Matrix.Bureau.SetOpsecPassphrase(trapHouseId, rawPassphrase)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then
        return false, 'bad_trap_house'
    end

    if rawPassphrase == nil or rawPassphrase == '' then
        Matrix.TrapHouses[trapHouseId].opsec_passphrase = Config.Bureau.OpsecDefaultPassphrase
        pcall(function()
            MySQL.prepare('UPDATE matrix_trap_houses SET opsec_passphrase = ? WHERE id = ?',
                { Config.Bureau.OpsecDefaultPassphrase, trapHouseId })
        end)
        return true, 'default_restored'
    end

    if type(rawPassphrase) ~= 'string'
        or #rawPassphrase < (Config.Bureau.OpsecPassphraseMinLength or 4)
        or #rawPassphrase > (Config.Bureau.OpsecPassphraseMaxLength or 64) then
        return false, 'bad_passphrase'
    end

    local hash = _OpsecHash(rawPassphrase)
    Matrix.TrapHouses[trapHouseId].opsec_passphrase = hash
    pcall(function()
        MySQL.prepare('UPDATE matrix_trap_houses SET opsec_passphrase = ? WHERE id = ?', { hash, trapHouseId })
    end)

    Matrix.Log('BUREAU', '[SEC-7] Trap #%d parola rotasyona girdi.', trapHouseId)
    return true, 'set'
end

-- ---------------------------------------------------------------
-- Parola doğrulama (darkchat'ten tetiklenir)
-- ---------------------------------------------------------------
function Matrix.Bureau.VerifyOpsecPassphrase(trapHouseId, citizenid, rawPassphrase)
    trapHouseId = tonumber(trapHouseId)
    local house = trapHouseId and Matrix.TrapHouses[trapHouseId]
    if not house then return false, 'bad_trap_house' end

    local storedHash = house.opsec_passphrase
    if type(storedHash) ~= 'string' or storedHash == '' then
        storedHash = _OpsecHash(Config.Bureau.OpsecDefaultPassphrase)
    end

    local attemptHash = _OpsecHash(rawPassphrase)
    if attemptHash == storedHash then
        return true, 'match'
    end

    -- Yanlış parola → üssel adım + adli iz
    local step = tonumber(Config.Bureau.OpsecPassphraseGeometricStep) or 0.08
    pcall(Matrix.Bureau.AdvanceDecryption, trapHouseId, step)

    pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_opsec_tamper_log
                (trap_house_id, citizenid, attempted_passphrase_hash,
                 geometric_step, decryption_after, created_at)
            VALUES (?, ?, ?, ?, ?, NOW())
        ]], {
            trapHouseId, tostring(citizenid or 'UNKNOWN'), attemptHash,
            step, house.decryption_confidence or 0.0
        })
    end)

    Matrix.Log('BUREAU',
        '[SEC-7 IHLALI] Trap #%d yanlış parola (vatandaş=%s). Üssel adım=%.4f → yeni deşifre=%.4f',
        trapHouseId, tostring(citizenid or 'UNKNOWN'), step, house.decryption_confidence or 0.0)
    return false, 'passphrase_mismatch'
end

-- ---------------------------------------------------------------
-- RAM ön belleğe opsec_passphrase'i yükle (bureau.lua'nın mevcut
-- LoadTrapHouses'u bu kolonu okumuyor — tek seferlik tamamlayıcı).
-- ---------------------------------------------------------------
CreateThread(function()
    Wait(2500)
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT id, opsec_passphrase FROM matrix_trap_houses', {})
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('BUREAU', '[SEC-7] opsec_passphrase yüklenemedi (yutuldu).')
        return
    end
    local loaded = 0
    for _, row in ipairs(rows) do
        local house = Matrix.TrapHouses[row.id]
        if house and type(row.opsec_passphrase) == 'string' and row.opsec_passphrase ~= '' then
            house.opsec_passphrase = row.opsec_passphrase
            loaded = loaded + 1
        end
    end
    Matrix.Log('BUREAU', '[SEC-7] %d trap house için dinamik parola RAM ön belleğe alındı.', loaded)
end)

-- ---------------------------------------------------------------
-- Darkchat parola deneme kanalı
-- ---------------------------------------------------------------
RegisterNetEvent('matrix:server:darkchat:submitPassphrase', function(trapHouseId, rawPassphrase)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid

    local ok, reason = Matrix.Bureau.VerifyOpsecPassphrase(trapHouseId, citizenid, rawPassphrase)
    TriggerClientEvent('matrix:client:darkchat:passphraseResult', src, ok, reason, trapHouseId)
end)

RegisterCommand('opsecparola', function(src, args)
    local trapHouseId = tonumber(args[1])
    if not trapHouseId then
        Reply(src, 'Kullanım: /opsecparola [trapHouseId] [yeniParola|boş]'); return
    end
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local newPass = args[2] or ''
    local ok, reason = Matrix.Bureau.SetOpsecPassphrase(trapHouseId, newPass)
    Reply(src, ok and ('Parola: %s'):format(reason) or ('Başarısız: %s'):format(tostring(reason)))
end, false)

-- =====================================================================
-- ★ [FAZ 2] COMINT RADYO SPEKTRUM AKÜMÜLATÖRÜ
-- PushToTalkAccum + BreachAccum → deşifre tırmanması + statik parazit.
-- Mevcut RNG YASAK — her şey tick sayaçları ile deterministik.
-- Self-healing: Matrix.Kitchen nil dönerse cyberSkill=1.0 fallback.
-- =====================================================================

Matrix.Bureau.RadioSpectrum = Matrix.Bureau.RadioSpectrum or {}
Matrix.Bureau.RadioSpectrum.PushToTalkAccum = Matrix.Bureau.RadioSpectrum.PushToTalkAccum or {}
Matrix.Bureau.RadioSpectrum.JamStrength     = Matrix.Bureau.RadioSpectrum.JamStrength     or {}
Matrix.Bureau.RadioSpectrum.BreachAccum     = Matrix.Bureau.RadioSpectrum.BreachAccum     or {}

local _RADIO_TICK_MS = 1000

--- Self-healing skill resolver — Kitchen yoksa/nil dönerse 1.0.
local function _ResolveRadioCyberSkill(trapHouseId)
    if not Matrix.Kitchen or type(Matrix.Kitchen.GetEffectiveSkill) ~= 'function' then
        return 1.0
    end
    if type(Matrix.Bots) ~= 'table' then return 1.0 end

    local resolved = 1.0
    for _, bot in pairs(Matrix.Bots) do
        if bot and bot.state and bot.state.trap_house_id == trapHouseId then
            local ok, skill = pcall(Matrix.Kitchen.GetEffectiveSkill, bot, 'skill_cyber')
            if ok and type(skill) == 'number' and skill == skill
                and skill ~= math.huge and skill ~= -math.huge then
                resolved = skill
            end
            break
        end
    end
    if type(resolved) ~= 'number' or resolved ~= resolved then resolved = 1.0 end
    return resolved
end

--- Push-to-talk kaydı — client'ın telsiz bas-konuş event'i buraya bağlanır.
function Matrix.Bureau.RegisterPushToTalk(citizenid, durationSeconds)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    durationSeconds = tonumber(durationSeconds) or 0.0
    if durationSeconds ~= durationSeconds or durationSeconds <= 0.0 then return end

    local spectrum = Matrix.Bureau.RadioSpectrum
    if type(spectrum.PushToTalkAccum) ~= 'table' or type(spectrum.BreachAccum) ~= 'table' then
        return
    end

    local gain   = tonumber(spectrum.PushToTalkAccum[citizenid]) or 0.0
    local breach = tonumber(spectrum.BreachAccum[citizenid]) or 0.0

    spectrum.PushToTalkAccum[citizenid] = gain + (durationSeconds * (Config.Bureau.RadioAccumGainPerTick or 0.02))
    spectrum.BreachAccum[citizenid]     = breach + (durationSeconds * (Config.Bureau.RadioBreachGainPerTick or 0.01))
end

-- Radyo ticker — 1 sn, Wait(0) YOK.
CreateThread(function()
    while true do
        Wait(_RADIO_TICK_MS)

        local spectrum = Matrix.Bureau.RadioSpectrum
        if type(spectrum) ~= 'table' then goto continue end
        if type(spectrum.PushToTalkAccum) ~= 'table' then goto continue end
        if type(spectrum.JamStrength)     ~= 'table' then goto continue end
        if type(spectrum.BreachAccum)     ~= 'table' then goto continue end

        for citizenid, rawGain in pairs(spectrum.PushToTalkAccum) do
            local gain = tonumber(rawGain) or 0.0
            if gain ~= gain then gain = 0.0 end

            -- /sessizlik aktif mi?
            local silent = false
            if Matrix.RadioSilence and type(Matrix.RadioSilence.IsActive) == 'function' then
                local okSil, res = pcall(Matrix.RadioSilence.IsActive, citizenid)
                silent = okSil and res == true
            end

            if silent then
                -- Sessizlik: yavaş azalım
                local decayed = gain - (Config.Bureau.RadioDecayPerTick or 0.005)
                if decayed <= 0.0 then
                    spectrum.PushToTalkAccum[citizenid] = nil
                    spectrum.JamStrength[citizenid]     = nil
                    spectrum.BreachAccum[citizenid]     = nil
                else
                    spectrum.PushToTalkAccum[citizenid] = decayed
                end
            else
                -- Aktif: doğrusal tırmanma + statik parazit + deşifre kazancı
                local newGain = math.min(gain + (Config.Bureau.RadioAccumGainPerTick or 0.02),
                                          Config.Bureau.RadioAccumMaxGain or 1.0)
                spectrum.PushToTalkAccum[citizenid] = newGain

                local prevJam = tonumber(spectrum.JamStrength[citizenid]) or 0.0
                if prevJam ~= prevJam then prevJam = 0.0 end
                local maxStatic = Config.Bureau.RadioStaticMaxIntensity or 0.90
                local newJam = math.min(prevJam + (Config.Bureau.RadioStaticStep or 0.05), maxStatic)
                spectrum.JamStrength[citizenid] = newJam

                -- En yakın trap house (deterministik: en küçük id)
                local nearestTrapId
                for id in pairs(Matrix.TrapHouses or {}) do
                    if not nearestTrapId or id < nearestTrapId then nearestTrapId = id end
                end

                if nearestTrapId and Matrix.Bureau and type(Matrix.Bureau.AdvanceDecryption) == 'function'
                    and newGain > 0.01 then
                    local cyberSkill = _ResolveRadioCyberSkill(nearestTrapId)
                    cyberSkill = math.max(cyberSkill, 0.1)
                    local gainPerTick = (Config.Bureau.RadioBreachGainPerTick or 0.01) * cyberSkill
                    pcall(Matrix.Bureau.AdvanceDecryption, nearestTrapId, gainPerTick)
                end

                -- Statik parazit: kaynağı bul ve ApplyStatic çağır.
                if Matrix.PlayerSourceIndex and Matrix.Radio
                    and type(Matrix.Radio.ApplyStatic) == 'function' then
                    for src, cid in pairs(Matrix.PlayerSourceIndex) do
                        if cid == citizenid then
                            pcall(Matrix.Radio.ApplyStatic, src, newJam, 'radio_spectrum')
                        end
                    end
                end
            end
        end

        ::continue::
    end
end)

-- Client → server bas-konuş event
RegisterNetEvent('matrix:server:radio:pushToTalk', function(durationSeconds)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end
    Matrix.Bureau.RegisterPushToTalk(state.citizenid, durationSeconds)
end)

exports('RegisterPushToTalk', function(citizenid, durationSeconds)
    return Matrix.Bureau.RegisterPushToTalk(citizenid, durationSeconds)
end)

-- =====================================================================
-- ★★★ FAZ 2 — PARAVAN REAL ESTATE & DARK LAWYER BLACKMAIL MOTORU ★★★
-- [MATRIX:PARAVAN_REAL_ESTATE_PHASE2]
-- SIFIR RNG · SIFIR RESMON · TAM DETERMİNİZM
-- Gerçek şemaya uyumlu: matrix_fragmented_intel (citizenid + contact_type +
-- intel_fragments), matrix_cash_decay (trap_house_id PK + dirty_amount).
-- =====================================================================

Matrix.Bureau.FragmentedIntel            = Matrix.Bureau.FragmentedIntel            or {}
Matrix.Bureau.LaunderFreeze              = Matrix.Bureau.LaunderFreeze              or {}
Matrix.Bureau.HeatExtractionMultiplier   = Matrix.Bureau.HeatExtractionMultiplier   or {}
Matrix.Bureau.__RemoveBotWrapped         = Matrix.Bureau.__RemoveBotWrapped         or false
Matrix.Bureau.__LaunderWrapped           = Matrix.Bureau.__LaunderWrapped           or false

local DARK_LAWYER_FRAGMENT_PER_EVENT     = 0.05
local DARK_LAWYER_ACTIVATION_THRESHOLD   = 1.0
local PARAVAN_LOYALTY_THRESHOLD          = 0.85
local AVUKAT_LEVERAGE_THRESHOLD          = 0.20
local AVUKAT_BRIBE_REFERENCE             = 50000.0
local DARK_LAWYER_BUREAU_PREFIX          = 'BUREAU_T'

-- ---------------------------------------------------------------
-- Fragmented Intel yükleyici — sentetik citizenid 'BUREAU_T<trapId>'
-- ---------------------------------------------------------------
function Matrix.Bureau.LoadFragmentedIntel()
    local ok, rows = pcall(function()
        return MySQL.query.await(
            "SELECT citizenid, intel_fragments FROM matrix_fragmented_intel WHERE contact_type = 'dark_lawyer' AND citizenid LIKE 'BUREAU\\_T%'",
            {})
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('BUREAU', '[PARAVAN_REAL_ESTATE_PHASE2] Fragmented intel yuklenemedi (yutuldu).')
        return
    end
    local count = 0
    for _, row in ipairs(rows) do
        local trapIdStr = tostring(row.citizenid or ''):match('^BUREAU_T(%d+)$')
        local trapId = tonumber(trapIdStr)
        if trapId then
            local amt = Matrix.Clamp(tonumber(row.intel_fragments) or 0.0, 0.0, DARK_LAWYER_ACTIVATION_THRESHOLD)
            Matrix.Bureau.FragmentedIntel[trapId] = {
                dark_lawyer = amt,
                active      = amt >= DARK_LAWYER_ACTIVATION_THRESHOLD
            }
            count = count + 1
        end
    end
    Matrix.Log('BUREAU', '[PARAVAN_REAL_ESTATE_PHASE2] %d dark_lawyer fragment kaydi yuklendi.', count)
end

CreateThread(function()
    Wait(2000)
    local ok, err = pcall(Matrix.Bureau.LoadFragmentedIntel)
    if not ok then
        Matrix.Log('BUREAU', '[PARAVAN_REAL_ESTATE_PHASE2] LoadFragmentedIntel hata (yutuldu): %s', tostring(err))
    end
end)

-- ---------------------------------------------------------------
-- Fragment akümülatörü — 0.05/adım
-- ---------------------------------------------------------------
function Matrix.Bureau.IncrementDarkLawyerFragment(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return end

    local entry = Matrix.Bureau.FragmentedIntel[trapHouseId]
    if not entry then
        entry = { dark_lawyer = 0.0, active = false }
        Matrix.Bureau.FragmentedIntel[trapHouseId] = entry
    end
    if entry.active then return end

    entry.dark_lawyer = Matrix.Clamp(
        entry.dark_lawyer + DARK_LAWYER_FRAGMENT_PER_EVENT, 0.0, DARK_LAWYER_ACTIVATION_THRESHOLD)

    if entry.dark_lawyer >= DARK_LAWYER_ACTIVATION_THRESHOLD then
        entry.active = true
        Matrix.Log('BUREAU',
            '[PARAVAN_REAL_ESTATE_PHASE2] Trap #%d DARK LAWYER KESFEDILDI (frag=%.2f).',
            trapHouseId, entry.dark_lawyer)
    end

    local syntheticCid = DARK_LAWYER_BUREAU_PREFIX .. tostring(trapHouseId)
    pcall(function()
        MySQL.prepare([[
            INSERT INTO matrix_fragmented_intel
                (citizenid, contact_type, contact_ref, intel_fragments, discovered, compromised, updated_at)
            VALUES (?, 'dark_lawyer', NULL, ?, ?, 0, NOW())
            ON DUPLICATE KEY UPDATE
                intel_fragments = VALUES(intel_fragments),
                discovered      = VALUES(discovered),
                updated_at      = NOW()
        ]], {
            syntheticCid,
            entry.dark_lawyer,
            entry.active and 1 or 0
        })
    end)
end

-- ---------------------------------------------------------------
-- Paravan Liability çözücü
-- ---------------------------------------------------------------
function Matrix.Bureau.ResolveParavanLiability(trapHouseId, defendantCitizenid)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return defendantCitizenid, false end
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return defendantCitizenid, false end
    local sb = house.straw_buyer_citizenid
    if type(sb) ~= 'string' or sb == '' then return defendantCitizenid, false end
    return sb, true
end

-- ---------------------------------------------------------------
-- Straw Buyer ataması
-- ---------------------------------------------------------------
function Matrix.Bureau.AssignStrawBuyer(trapHouseId, botId, officerCitizenid)
    trapHouseId = tonumber(trapHouseId)
    botId       = tonumber(botId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false, 'bad_trap_house' end
    if not botId then return false, 'bad_bot_id' end

    if officerCitizenid and Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local ok, has = pcall(Matrix.Hierarchy.HasCommandAuthority, officerCitizenid)
        if not ok or not has then return false, 'unauthorized' end
    end

    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return false, 'bot_not_found' end

    local loyalty = (bot.psychology and tonumber(bot.psychology.loyalty_base)) or 0.0
    if loyalty ~= loyalty then loyalty = 0.0 end
    if loyalty <= PARAVAN_LOYALTY_THRESHOLD then return false, 'loyalty_too_low' end

    local handlerCid = bot.handler_citizenid
    if type(handlerCid) ~= 'string' or handlerCid == '' then
        handlerCid = 'PARAVAN_BOT_' .. tostring(botId)
    end

    local house = Matrix.TrapHouses[trapHouseId]
    house.straw_buyer_citizenid = handlerCid

    pcall(function()
        MySQL.prepare('UPDATE matrix_trap_houses SET straw_buyer_citizenid = ? WHERE id = ?',
            { handlerCid, trapHouseId })
    end)

    Matrix.Log('BUREAU',
        '[PARAVAN_REAL_ESTATE_PHASE2] Trap #%d <- paravan bot #%d (loyalty=%.3f) bagli. Handler=%s',
        trapHouseId, botId, loyalty, handlerCid)

    return true, { straw_buyer_citizenid = handlerCid, loyalty = loyalty, bot_id = botId }
end

RegisterCommand('paravantapu', function(src, args)
    local trapHouseId = tonumber(args[1])
    local botId       = tonumber(args[2])
    if not trapHouseId or not botId then
        Reply(src, 'Kullanim: /paravantapu [trapHouseId] [botId]'); return
    end
    local state = Matrix.GetOrCreatePlayerState(src)
    local cid   = state and state.citizenid
    local ok, result = Matrix.Bureau.AssignStrawBuyer(trapHouseId, botId, cid)
    if ok then
        Reply(src, ('Paravan tapu KURULDU: Trap #%d <- Bot #%d (loyalty=%.3f)'):format(
            trapHouseId, botId, result.loyalty))
    else
        Reply(src, ('Paravan tapu BASARISIZ: %s'):format(tostring(result)))
    end
end, false)

-- ---------------------------------------------------------------
-- Asset Seizure — paravan deceased/burned
-- ---------------------------------------------------------------
function Matrix.Bureau._HandleParavanSeizure(bot, reason)
    if type(bot) ~= 'table' then return end
    if reason ~= 'deceased' and reason ~= 'burned' then return end

    local handlerCid = bot.handler_citizenid
    if type(handlerCid) ~= 'string' or handlerCid == '' then return end

    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        if house.straw_buyer_citizenid == handlerCid then
            house.structural_integrity = 0.00
            Matrix.Bureau.LaunderFreeze[trapHouseId]            = true
            Matrix.Bureau.HeatExtractionMultiplier[trapHouseId] = 2.0

            pcall(function()
                MySQL.prepare('UPDATE matrix_trap_houses SET structural_integrity = 0.00 WHERE id = ?',
                    { trapHouseId })
            end)

            Matrix.Log('BUREAU',
                '[PARAVAN_REAL_ESTATE_PHASE2] EL KOYMA: Trap #%d | integrity=0.00 | Launder FREEZE | Heat x2 | reason=%s',
                trapHouseId, tostring(reason))
        end
    end
end

-- ★ [FAZ 0.1] Wrapper → Event-based Observer
-- Paravan seizure artık RemoveBot wrapper'ı DEĞİL, event subscriber'ı.
-- Yükleme sırası önemsiz, re-entrance güvenli, izole crash.
AddEventHandler('matrix:internal:botRemoving', function(botId, reason, snapshot)
    if not snapshot then return end
    local bot = {
        id = snapshot.id,
        handler_citizenid = snapshot.handler_citizenid,
        dna_id = snapshot.dna_id,
        role = snapshot.role,
    }
    pcall(Matrix.Bureau._HandleParavanSeizure, bot, reason)
end)
Matrix.Log('BUREAU', '[PARAVAN_REAL_ESTATE_PHASE2] botRemoving event subscriber aktif.')

-- ---------------------------------------------------------------
-- CashDecay.Launder freeze wrapper (market.lua'da amount<=0.0 erken döner)
-- ---------------------------------------------------------------
CreateThread(function()
    Wait(2500)
    if Matrix.CashDecay and type(Matrix.CashDecay.Launder) == 'function'
        and not Matrix.Bureau.__LaunderWrapped then
        Matrix.Bureau.__LaunderWrapped = true
        local origLaunder = Matrix.CashDecay.Launder
        Matrix.CashDecay.Launder = function(trapHouseId, amount, citizenid)
    trapHouseId = tonumber(trapHouseId)
    if trapHouseId and Matrix.Bureau.LaunderFreeze[trapHouseId] then
        return false, 'paravan_seizure_freeze'
    end
    return origLaunder(trapHouseId, amount, citizenid)
end
        Matrix.Log('BUREAU', '[PARAVAN_REAL_ESTATE_PHASE2] CashDecay.Launder freeze wrapper aktif.')
    end
end)

-- ---------------------------------------------------------------
-- Public query'ler
-- ---------------------------------------------------------------
function Matrix.Bureau.IsLaunderFrozen(trapHouseId)
    return Matrix.Bureau.LaunderFreeze[trapHouseId] == true
end

function Matrix.Bureau.GetHeatExtractionMultiplier(trapHouseId)
    return Matrix.Bureau.HeatExtractionMultiplier[trapHouseId] or 1.0
end

function Matrix.Bureau.FlushDirtyIntel()
    local queries = {}
    for id in pairs(dirtyIntel) do
        local heat = cyberLeakHeatmap[id] or 0.0
        -- v6.6.5 Paket 2: FK parent guard -- trap house silinmisse
        -- (Matrix.TrapHouses[id] yok) INSERT denenmez.
        if Matrix.TrapHouses and Matrix.TrapHouses[id] then
            queries[#queries + 1] = {
                query  = [[
                    INSERT INTO matrix_bureau_intel (trap_house_id, category, intensity, updated_at)
                    VALUES (?, 'cyber_leak', ?, NOW())
                    ON DUPLICATE KEY UPDATE intensity = VALUES(intensity), updated_at = NOW()
                ]],
                values = { id, heat }
            }
        end
        -- v6.6.5 Paket 2: FK parent guard -- ayni sebeple UPDATE de
        -- ayni Matrix.TrapHouses[id] kontrolune bagli.
        if Matrix.TrapHouses and Matrix.TrapHouses[id] then
            -- ★ HEAT PERSISTENCE FIX: trap_houses tablosuna da yaz (restart kalıcı)
            queries[#queries + 1] = {
                query  = 'UPDATE matrix_trap_houses SET cyber_leak_intensity = ? WHERE id = ?',
                values = { heat, id }
            }
        end
        dirtyIntel[id] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyIntel transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

function Matrix.Bureau.IsDarkLawyerActive(trapHouseId)
    local e = Matrix.Bureau.FragmentedIntel[trapHouseId]
    return e ~= nil and e.active == true
end

function Matrix.Bureau.GetDarkLawyerFragments(trapHouseId)
    local e = Matrix.Bureau.FragmentedIntel[trapHouseId]
    return (e and e.dark_lawyer) or 0.0
end

-- ---------------------------------------------------------------
-- Dark Lawyer talimatı
-- ---------------------------------------------------------------
function Matrix.Bureau.ExecuteDarkLawyerInstruction(trapHouseId, bribeAmount, suspectSrc)
    trapHouseId = tonumber(trapHouseId)
    bribeAmount = tonumber(bribeAmount)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false, 'bad_trap_house' end
    if not bribeAmount or bribeAmount ~= bribeAmount or bribeAmount < 0.0 then return false, 'bad_bribe' end

    local entry = Matrix.Bureau.FragmentedIntel[trapHouseId]
    if not entry or not entry.active then return false, 'dark_lawyer_inactive' end

    local velocity  = Matrix.Bureau.GetBureaucraticVelocity()
    local fragments = Matrix.Clamp(entry.dark_lawyer, 0.0, 1.0)

    local legal_leverage =
          (fragments          * 0.4)
        + ((bribeAmount / AVUKAT_BRIBE_REFERENCE) * 0.4)
        - (velocity * 0.2)

    legal_leverage = Matrix.Clamp(legal_leverage, 0.0, 1.0)

    local house = Matrix.TrapHouses[trapHouseId]

    if legal_leverage >= AVUKAT_LEVERAGE_THRESHOLD then
        local convictionReduction = legal_leverage * 0.50
        local breachDrop          = math_floor(legal_leverage * 5)

        pcall(function()
            MySQL.prepare([[
                UPDATE matrix_trial_records
                SET conviction_weight = GREATEST(0.0, conviction_weight - ?)
                WHERE verdict = 'pending'
                ORDER BY opened_at DESC LIMIT 1
            ]], { convictionReduction })
        end)

        local lc = learningCore[trapHouseId]
        if lc then
            lc.radio_breach_count = math.max(0, (lc.radio_breach_count or 0) - breachDrop)
            dirtyLearningCore[trapHouseId] = true
        end

        pcall(function()
            MySQL.prepare([[
                INSERT INTO matrix_cash_decay (trap_house_id, dirty_amount, deposited_at, updated_at)
                VALUES (?, 0.0, NOW(), NOW())
                ON DUPLICATE KEY UPDATE
                    dirty_amount = GREATEST(0.0, dirty_amount - ?),
                    updated_at   = NOW()
            ]], { trapHouseId, bribeAmount })
        end)

        Matrix.Log('BUREAU',
            '[PARAVAN_REAL_ESTATE_PHASE2][UZLASMA] Trap #%d | frag=%.3f | bribe=%.0f | leverage=%.4f/%.2f | conviction-=%0.4f | breach-=%d',
            trapHouseId, fragments, bribeAmount, legal_leverage, AVUKAT_LEVERAGE_THRESHOLD,
            convictionReduction, breachDrop)

        return true, {
            leverage              = legal_leverage,
            conviction_reduction  = convictionReduction,
            breach_drop           = breachDrop,
        }
    end

    -- ★ THE COUNTER-STING SPIRAL
    house.decryption_confidence = Matrix.Clamp(
        (house.decryption_confidence or 0.0) + 0.15, 0.0, 1.0)
    dirtyDecryption[trapHouseId] = true

    if suspectSrc and Matrix.TrapHouses[trapHouseId] then
        local ped = GetPlayerPed(suspectSrc)
        if ped and ped ~= 0 then
            local coords = GetEntityCoords(ped)
            local nearestId, nearestDist = trapHouseId, math.huge
            for id, h in pairs(Matrix.TrapHouses) do
                if h.coords then
                    local d = #(coords - h.coords)
                    if d < nearestDist then nearestId, nearestDist = id, d end
                end
            end
            if Matrix.Bureau.__SetHeatRaw then
                pcall(Matrix.Bureau.__SetHeatRaw, nearestId, Config.Bureau.CyberLeakMaxIntensity)
            end
        end
    end

    TriggerEvent('matrix:internal:darkLawyerCounterSting', trapHouseId, suspectSrc, legal_leverage)
    TriggerEvent('matrix:internal:hitSquadRequested', suspectSrc, 'dark_lawyer_counter_sting', 'maximum')

    Matrix.Log('BUREAU',
        '[PARAVAN_REAL_ESTATE_PHASE2][YENGEC KANONU] Trap #%d bribe REDDEDILDI | leverage=%.4f (<%.2f) | +0.15 desifre spike | heat spike -> hitsquad.',
        trapHouseId, legal_leverage, AVUKAT_LEVERAGE_THRESHOLD)

    return false, { leverage = legal_leverage, reason = 'counter_sting' }
end

RegisterCommand('avukattalimat', function(src, args)
    local trapHouseId = tonumber(args[1])
    local bribeAmount = tonumber(args[2])
    if not trapHouseId or not bribeAmount then
        Reply(src, 'Kullanim: /avukattalimat [trapHouseId] [bribe_amount]'); return
    end
    local ok, result = Matrix.Bureau.ExecuteDarkLawyerInstruction(trapHouseId, bribeAmount, src)
    if ok then
        Reply(src, ('[AVUKAT UZLASMASI] leverage=%.4f | conviction-dusum=%.4f | breach-dusum=%d'):format(
            result.leverage, result.conviction_reduction, result.breach_drop))
    elseif type(result) == 'table' and result.reason == 'counter_sting' then
        Reply(src, ('[YENGEC KANONU] leverage=%.4f cok DUSUK -- avukat ihanet etti. Karsi operasyon tetiklendi.'):format(
            result.leverage))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end, false)

RegisterCommand('paravandurum', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /paravandurum [trapHouseId]'); return end
    local h = Matrix.TrapHouses[id]
    local e = Matrix.Bureau.FragmentedIntel[id]
    Reply(src, ('Trap #%d | Paravan:%s | Integrity:%.2f | LaunderFreeze:%s | HeatMult:x%.1f | DarkLawyer:%s (frag=%.2f)'):format(
        id, tostring(h.straw_buyer_citizenid), h.structural_integrity,
        tostring(Matrix.Bureau.IsLaunderFrozen(id)),
        Matrix.Bureau.GetHeatExtractionMultiplier(id),
        tostring(e and e.active or false), (e and e.dark_lawyer) or 0.0))
end, false)

-- ---------------------------------------------------------------
-- EXPORTLAR
-- ---------------------------------------------------------------
exports('AssignStrawBuyer',            function(th, bot, cid) return Matrix.Bureau.AssignStrawBuyer(th, bot, cid) end)
exports('ExecuteDarkLawyerInstruction',function(th, amt, src) return Matrix.Bureau.ExecuteDarkLawyerInstruction(th, amt, src) end)
exports('IncrementDarkLawyerFragment', function(th)         return Matrix.Bureau.IncrementDarkLawyerFragment(th) end)
exports('IsLaunderFrozen',             function(th)         return Matrix.Bureau.IsLaunderFrozen(th) end)
exports('GetHeatExtractionMultiplier', function(th)         return Matrix.Bureau.GetHeatExtractionMultiplier(th) end)
exports('IsDarkLawyerActive',          function(th)         return Matrix.Bureau.IsDarkLawyerActive(th) end)
exports('GetDarkLawyerFragments',      function(th)         return Matrix.Bureau.GetDarkLawyerFragments(th) end)
exports('ResolveParavanLiability',     function(th, cid)    return Matrix.Bureau.ResolveParavanLiability(th, cid) end)