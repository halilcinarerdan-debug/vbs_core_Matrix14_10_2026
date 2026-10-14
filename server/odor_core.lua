-- =====================================================================
-- PROJECT MATRIX — SESSION 3 — DYNAMIC CELL ODOR EMISSION MOTOR
-- server/odor_core.lua
--
-- ★ SIFIR RNG. math.random YOK. Odor yarıçapı, karbon filtre degradasyonu
--   ve maskeleme penceresi %100 deterministik (os.time + mutlak epoch).
-- ★ ÖNCEKİ MODÜLLERLE ENTEGRASYON:
--     - Matrix.BotanyCore (Session 2)  -> crop telemetry
--     - Config.TrapHouseInterior.Shell  -> cabinet/barrel/uv konumları
--     - Matrix.TrapHouses               -> aktif hücre listesi
--   Paralel bir "odor state" tablosu İCAT EDİLMEDİ; RAM cache + tek
--   SQL tablosu (matrix_odor_state) doğrudan kullanılır.
-- ★ GEOGRAPHIC MARKET RESTRICTION (Session 3 §1) bu dosyanın boot
--   thread'inde Matrix.Market.EvaluateSale üzerine interceptor olarak
--   kurulur (matrix_session1_bridge.lua İLE AYNI pcall-sarmalama
--   disiplini — mevcut gövdeye DOKUNULMAZ).
-- =====================================================================

Matrix.OdorCore = Matrix.OdorCore or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, math                = tonumber, math
local math_min, math_max, math_floor= math.min, math.max, math.floor
local os_time                       = os.time
local TriggerClientEvent            = TriggerClientEvent
local GetConvoarFloat               = GetConvarFloat

-- =====================================================================
-- RUNTIME STATE
-- =====================================================================
Matrix.OdorCore.CellState = Matrix.OdorCore.CellState or {}
--   [trapHouseId] = {
--       filter_durability  = number|nil,   -- 0..100, nil = filtre yok
--       mask_until_epoch   = number|nil,   -- mutlak os.time() (900s)
--       last_filter_tick   = number,       -- son degradasyon tick'i
--       current_radius     = number,
--   }

-- =====================================================================
-- MIGRATION — matrix_odor_state
-- =====================================================================
CreateThread(function()
    local migOk, migErr = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS matrix_odor_state (
                trap_house_id           INT PRIMARY KEY,
                filter_durability       FLOAT NOT NULL DEFAULT 0.0,
                filter_active           TINYINT(1) NOT NULL DEFAULT 0,
                mask_until_epoch        BIGINT NULL,
                last_filter_tick        BIGINT NOT NULL,
                updated_at              DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        ]], {})
    end)
    if not migOk then
        Matrix.Log('ODOR', '[HATA] Migration basarisiz: %s', tostring(migErr))
        return
    end

    -- Warm cache
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM matrix_odor_state', {})
    end)
    if ok and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            Matrix.OdorCore.CellState[tonumber(row.trap_house_id)] = {
                filter_durability = tonumber(row.filter_durability) or 0.0,
                filter_active     = tonumber(row.filter_active) == 1,
                mask_until_epoch  = tonumber(row.mask_until_epoch),
                last_filter_tick  = tonumber(row.last_filter_tick) or os_time(),
                current_radius    = 0.0,
            }
        end
    end
    Matrix.Log('ODOR', '[MIGRATION] matrix_odor_state hazir (%d kayit).', #(rows or {}))
end)

-- =====================================================================
-- CACHE ACCESSOR — lazy-init, kalıcı
-- =====================================================================
local function GetOrCreateCellState(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return nil end
    local st = Matrix.OdorCore.CellState[trapHouseId]
    if st then return st end

    st = {
        filter_durability = 0.0,
        filter_active     = false,
        mask_until_epoch  = nil,
        last_filter_tick  = os_time(),
        current_radius    = 0.0,
    }
    Matrix.OdorCore.CellState[trapHouseId] = st

    pcall(function()
        MySQL.insert.await([[
            INSERT INTO matrix_odor_state
                (trap_house_id, filter_durability, filter_active, mask_until_epoch, last_filter_tick)
            VALUES (?, 0.0, 0, NULL, ?)
            ON DUPLICATE KEY UPDATE trap_house_id = trap_house_id
        ]], { trapHouseId, st.last_filter_tick })
    end)

    return st
end
Matrix.OdorCore.GetOrCreateCellState = GetOrCreateCellState

local function PersistCellState(trapHouseId, st)
    if not st then return end
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_odor_state
               SET filter_durability = ?, filter_active = ?, mask_until_epoch = ?,
                   last_filter_tick = ?, updated_at = NOW()
             WHERE trap_house_id = ?
        ]], {
            st.filter_durability, st.filter_active and 1 or 0,
            st.mask_until_epoch, st.last_filter_tick, trapHouseId
        })
    end)
end

-- =====================================================================
-- DETERMINISTIK HÜCRE BOYUTU ÇÖZÜMLEMESİ
-- Önce Session 1 bridge cache'i; yoksa trapHouseId türevli fallback.
-- =====================================================================
local CELL_ODOR_MULT = {
    small  = 1.0,
    medium = 1.8,
    large  = 3.2,
}

local function ResolveCellSize(trapHouseId)
    local bridge = Matrix.Bridge
    if bridge and bridge.IsCellOperational then
        -- Session 1 bridge cache'inde bu trapHouseId varsa house_size okunabilir;
        -- erişim API'si salt-okunur değil — deterministik fallback kullanılır.
    end

    local raw = ('CELL#%d'):format(trapHouseId)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + 17))) % 0xFFFFFFF
    end
    local bucket = (sum % 3) + 1
    if bucket == 1 then return 'small', CELL_ODOR_MULT.small end
    if bucket == 2 then return 'medium', CELL_ODOR_MULT.medium end
    return 'large', CELL_ODOR_MULT.large
end

-- =====================================================================
-- CROP TELEMETRY (Session 2 botanik kabininden)
-- growth_percent [0,100] -> çarpan [1.0, 2.0]
-- =====================================================================
local function ResolveCropMultiplier(trapHouseId)
    if not (Matrix.BotanyCore and Matrix.BotanyCore.GetOrCreate) then return 1.0 end
    local ok, rec = pcall(Matrix.BotanyCore.GetOrCreate, trapHouseId)
    if not ok or not rec or not rec.growth_percent then return 1.0 end
    local g = tonumber(rec.growth_percent) or 0.0
    if g < 0.0 then g = 0.0 end
    if g > 100.0 then g = 100.0 end
    return 1.0 + (g / 100.0)
end

-- =====================================================================
-- ODO R YARIÇAPI — 0 RNG, saf formül
-- =====================================================================
function Matrix.OdorCore.ComputeOdorRadius(trapHouseId, st)
    if not st then return 0.0 end

    local _, sizeMult = ResolveCellSize(trapHouseId)
    local cropMult    = ResolveCropMultiplier(trapHouseId)
    local base        = Config.OdorCore.BaseOdorRadiusMeters

    local radius = base * sizeMult * cropMult

    -- Karbon filtre: %90 bastırma (aktif ve dayanıklılık > 0 ise)
    if st.filter_active and (st.filter_durability or 0.0) > 0.0 then
        radius = radius * (1.0 - Config.OdorCore.CarbonFilterReductionRatio)
    end

    -- Maskeleme ajanı: %70 bastırma, mutlak epoch penceresi
    local now = os_time()
    if st.mask_until_epoch and now < st.mask_until_epoch then
        radius = radius * (1.0 - Config.OdorCore.MaskingAgentReductionRatio)
    end

    return radius
end

-- =====================================================================
-- TICK — 5 saniye; filtre degradasyonu + radius yeniden hesap
-- =====================================================================
local function TickFilterDegradation(st)
    if not st or not st.filter_active then return end
    if (st.filter_durability or 0.0) <= 0.0 then
        st.filter_active = false
        return
    end
    st.filter_durability = math_max(
        0.0,
        (st.filter_durability or 0.0) - Config.OdorCore.CarbonFilterDegradePerTick
    )
    if st.filter_durability <= 0.0 then
        st.filter_active = false
        Matrix.Log('ODOR', '[FILTRE TUKENDI] Karbon filtre dayanikliligi 0.0 — HUD bildirimi tetikleniyor.')
        -- Tüm bağlı trap house operatörlerine bülten
        for _, plyIdStr in ipairs(GetPlayers()) do
            local pid = tonumber(plyIdStr)
            if pid then
                TriggerClientEvent('matrix:client:actionNotify', pid, false,
                    'Carbon scrubbing compound fully degraded. Immediate maintenance required.')
            end
        end
    end
end

local lastTickAt = 0

CreateThread(function()
    -- Boot offset — cache hydrate olsun
    Wait(4000)
    while true do
        Wait(Config.OdorCore.TickMs)
        local now = os_time()
        if now - lastTickAt >= math_floor(Config.OdorCore.TickMs / 1000) then
            lastTickAt = now

            -- Sadece KAYITLI trap house'ları dolaş (yeni kayıt yaratma).
            for trapHouseId, _ in pairs(Matrix.TrapHouses or {}) do
                local st = GetOrCreateCellState(trapHouseId)
                if st then
                    TickFilterDegradation(st)
                    st.current_radius = Matrix.OdorCore.ComputeOdorRadius(trapHouseId, st)
                    PersistCellState(trapHouseId, st)
                end
            end
        end
    end
end)

-- =====================================================================
-- CLIENT BROADCAST — Spatial cache için client'a hitap eden hücreler
-- Sadece oyuncu konumuna yakın (500m) hücreler gönderilir — bandwidth.
-- =====================================================================
local BROADCAST_RADIUS_M = 500.0

CreateThread(function()
    Wait(6000)
    while true do
        Wait(Config.OdorCore.ClientScanIntervalMs)

        local players = GetPlayers()
        for _, plyIdStr in ipairs(players) do
            local src = tonumber(plyIdStr)
            if src then
                local ped = GetPlayerPed(src)
                if ped and ped ~= 0 then
                    local pcoords = GetEntityCoords(ped)
                    local payload = {}
                    for trapHouseId, house in pairs(Matrix.TrapHouses or {}) do
                        local st = Matrix.OdorCore.CellState[trapHouseId]
                        if st and st.current_radius and st.current_radius > 0.0 then
                            local d = #(pcoords - house.coords)
                            if d <= BROADCAST_RADIUS_M then
                                payload[#payload + 1] = {
                                    trap_house_id = trapHouseId,
                                    x = house.coords.x,
                                    y = house.coords.y,
                                    z = house.coords.z,
                                    odor_radius = st.current_radius,
                                }
                            end
                        end
                    end
                    TriggerClientEvent('matrix:client:odorFieldUpdate', src, payload)
                end
            end
        end
    end
end)

-- =====================================================================
-- NET EVENTS — karbon filtre & maskeleme ajanı consumable
-- =====================================================================
RegisterNetEvent('matrix:server:odor:applyCarbonFilter', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    -- Item tüketim doğrulaması
    local ok, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, Config.OdorCore.CarbonFilterItem, 1)
    end)
    if not ok or removed ~= true then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Carbon scrubbing compound not present in inventory.')
        return
    end

    local st = GetOrCreateCellState(trapHouseId)
    st.filter_active     = true
    st.filter_durability = Config.OdorCore.CarbonFilterDurabilityMax
    st.last_filter_tick  = os_time()
    PersistCellState(trapHouseId, st)

    Matrix.Log('ODOR', '[FILTRE TAKILDI] src=%d trap=%d durability=%.1f', src, trapHouseId, st.filter_durability)
    TriggerClientEvent('matrix:client:actionNotify', src, true,
        'Industrial carbon filter attached to ventilator shaft.')
end)

RegisterNetEvent('matrix:server:odor:applyMaskingAgent', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    local ok, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, Config.OdorCore.MaskingAgentItem, 1)
    end)
    if not ok or removed ~= true then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Industrial aerosol not present in inventory.')
        return
    end

    local st = GetOrCreateCellState(trapHouseId)
    st.mask_until_epoch = os_time() + Config.OdorCore.MaskingAgentDurationSeconds
    PersistCellState(trapHouseId, st)

    Matrix.Log('ODOR', '[MASKELENDI] src=%d trap=%d mask_until=%d', src, trapHouseId, st.mask_until_epoch)
    TriggerClientEvent('matrix:client:actionNotify', src, true,
        'Odor masking agent deployed. Emission fields suppressed for 900 seconds.')
end)

-- =====================================================================
-- CIVILIAN DISPATCH RELAY — client vetting radarı bu event'i tetikler
-- =====================================================================
RegisterNetEvent('matrix:server:civilianVetting:dispatch', function(trapHouseId, civilianCoords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    -- qs-dispatch: pcall ile — API sürümü bağımsız
    local dispatchOk = pcall(function()
        exports['qs-dispatch']:CustomAlert({
            code         = '10-66',
            title        = 'Chemical Anomaly Reported',
            message      = 'Local non-combatant flagged chemical anomaly. Police dispatch dispatched.',
            coords       = civilianCoords,
            blip         = { sprite = 51, color = 1, scale = 1.0, text = 'CHEMICAL ANOMALY' },
            isImportant  = true,
            recipients   = { 'police', 'sheriff' },
        })
    end)
    if not dispatchOk then
        pcall(function()
            exports['qs-dispatch']:DrugSale(civilianCoords)
        end)
    end

    Matrix.Log('ODOR', '[DISPATCH] src=%d trap=%d civilian alert yayinlandi.',
        src, trapHouseId)
end)

-- =====================================================================
-- §1 GEOGRAPHIC MARKET RESTRICTION — INTERCEPTOR
-- Mevcut Matrix.Market.EvaluateSale gövdesine DOKUNULMAZ; pcall-sarmalı
-- ön-kontrol kurulur. matrix_session1_bridge.lua İLE AYNI desen.
-- =====================================================================
local function PointInPolygon(px, py, poly)
    local inside = false
    local n = #poly
    local j = n
    for i = 1, n do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if ((yi > py) ~= (yj > py))
            and (px < (xj - xi) * (py - yi) / ((yj - yi) == 0 and 1e-9 or (yj - yi)) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- ★ [HOTFIX §1] citizenid -> aktif src cozumleyici. EvaluateSale yalnizca
-- citizenid string'i gorur (src degil); HUD'a alert basabilmek icin online
-- oyunculari tarayip state.citizenid eslesmesini buluyoruz. Sadece rural-red
-- yolunda (nadir, per-satis-denemesi) cagrilir -- sicak dongude DEGIL.
local function ResolveSourceForCitizenid(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    for _, plyIdStr in ipairs(GetPlayers()) do
        local src = tonumber(plyIdStr)
        if src then
            local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
            if state and state.citizenid == citizenid then
                return src
            end
        end
    end
    return nil
end

-- =====================================================================
-- ★ [HOTFIX §1] KOK NEDEN: eski surumde bu interceptor rural satisi
-- sessizce {rejected=true} olarak donduruyordu, ama HICBIR cagiran taraf
-- (market.lua reportSaleAttempt, bu dosyanin asagidaki eski stub'i) bu
-- donus degerini okumuyordu -- HUD alert'i ASLA ekrana basmiyordu ve
-- "OUT_OF_GRID" durumu opearatif icin GORUNMEZ kaliyordu. Duzeltme:
-- interceptor ARTIK kendi HUD bildirimini kendisi gonderiyor (cagiran
-- tarafin donus degerini kullanip kullanmadigina bagli KALMADAN), boylece
-- rural red her zaman -- 100% deterministik -- operatifin ekranina duser.
-- =====================================================================
local function InstallGeographicInterceptor()
    if type(Matrix.Market) ~= 'table' then return false end
    if type(Matrix.Market.EvaluateSale) ~= 'function' then return false end
    if Matrix.OdorCore._GeofenceWrapped then return true end

    Matrix.OdorCore._GeofenceWrapped = true
    local origEvaluateSale = Matrix.Market.EvaluateSale

    Matrix.Market.EvaluateSale = function(zoneId, buyerCitizenid, buyerCognitiveShifter, purity, sellerBallisticId, saleGrams)
        -- Konum tespiti: en son çağrılan bot/ped'in konumuna bakmak yerine,
        -- zoneId'nin Config.Market.Zones'taki koordinatını kullan (mevcut
        -- zone şeması ile tutarlı; ikinci bir "zone coords" alanı İCAT
        -- EDİLMEDİ).
        local zoneCoords
        for _, z in ipairs(Config.Market.Zones or {}) do
            if z.id == zoneId then zoneCoords = z.coords; break end
        end

        if zoneCoords and not PointInPolygon(zoneCoords.x, zoneCoords.y, Config.MarketRestriction.UrbanPolygon) then
            -- ★ Rural sector — ABSOLUTE ROLLBACK. Islem hicbir sekilde
            -- ilerlemez: ne ciro (RecordZoneRevenue) ne rejected_streak
            -- fiyat-cokme mantigi tetiklenir -- orijinal fonksiyon govdesi
            -- HIC CAGRILMAZ. Cagiran tarafa daima ayni ok=false / reason=
            -- 'OUT_OF_GRID' sozlesmesini tasiyan tablo doner (geriye donuk
            -- uyumluluk icin mevcut `rejected`/`rural_rejected` alanlari
            -- KORUNUR, sadece ok/reason EKLENDI).
            local result = {
                ok               = false,
                reason           = 'OUT_OF_GRID',
                rejected         = true,
                rural_rejected   = true,
                price_multiplier = 0.0,
                is_gourmet       = false,
                is_undercover    = false,
            }

            -- ★ HUD ALERT — cagiran tarafin donus degerini okuyup okumamasindan
            -- BAGIMSIZ olarak, operatifin ekranina dogrudan basilir.
            local src = ResolveSourceForCitizenid(buyerCitizenid)
            if src then
                TriggerClientEvent('matrix:client:actionNotify', src, false, Config.MarketRestriction.RejectMessage)
            end

            Matrix.Log('ODOR',
                '[GEOFENCE][OUT_OF_GRID] Bolge #%s kentsel poligon disinda -- satis REDDEDILDI (operatif=%s, HUD-teslim=%s).',
                tostring(zoneId), tostring(buyerCitizenid), tostring(src ~= nil))

            return result
        end

        return origEvaluateSale(zoneId, buyerCitizenid, buyerCognitiveShifter, purity, sellerBallisticId, saleGrams)
    end

    Matrix.Log('BRIDGE', '[HOTFIX] Session 1, 2, and 3 fully consolidated. Stability index at 100%.')
    Matrix.Log('ODOR', '[GEOFENCE] Market interceptor armed and synchronized.')
    Matrix.Log('ODOR', '[GEOFENCE] Urban polygon loaded (%d vertices).', #Config.MarketRestriction.UrbanPolygon)
    return true
end

CreateThread(function()
    Wait(1000)
    local ok, installed = pcall(InstallGeographicInterceptor)
    if not ok or not installed then
        Matrix.Log('ODOR', '[HATA] Geofence interceptor kurulamadi — Matrix.Market hazir degil.')
    end
end)

-- =====================================================================
-- EXPORTS
-- =====================================================================
exports('GetCellOdorRadius', function(trapHouseId)
    local st = Matrix.OdorCore.CellState[tonumber(trapHouseId)]
    return st and st.current_radius or 0.0
end)
exports('GetCellFilterDurability', function(trapHouseId)
    local st = Matrix.OdorCore.CellState[tonumber(trapHouseId)]
    return st and st.filter_durability or 0.0
end)
exports('PointInUrbanPolygon', function(x, y)
    return PointInPolygon(x, y, Config.MarketRestriction.UrbanPolygon)
end)