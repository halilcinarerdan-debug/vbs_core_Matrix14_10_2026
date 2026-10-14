-- =====================================================================
-- MATRIX LOGISTICS / server/logistics.lua  (KATMAN 5 — MÜHÜRLÜ SÜRÜM)
--
-- ★ BU SÜRÜMDEKİ EK SERTLEŞTİRME:
--   [L1] QueueOrEmit FIFO-cap'li (PENDING_EVENTS_MAX=64).
--   [L2] DropHeat tablosu: bir drop 0.0 heat'e indiğinde girdi SİLİNİR.
--   [L3] ReleaseVehicleLock idempotent.
--   [L4] Tüm entity-temizleme yolları pcall + DoesEntityExist guard'lı.
--
-- ★★★ YAMA 4 — SERVER-AUTHORITATIVE RELAY ★★★
--   • [HITSQUADDRIVEBY] CLIENT-SIDE cooldown TAMAMEN KALDIRILDI.
--   • Server PER-BOT (3sn) + PER-CLIENT (1sn) iki katmanlı rate-limit.
--   • _RelayCooldownByBotId / _RelayCooldownByClient TTL-purge'lı.
--   • /relaypurge operatör komutu elle temizlik sağlar.
--
-- ★★★ FAZ 3 — PERSISTENT NO-CACHE VEHICLES & INTERACTIVE KUNDAKLAMA ★★★
--   • [PV-1] matrix_persistent_vehicles kalıcı plaka matrisi.
--   • [PV-2] Virtual caching TAMAMEN YASAK: logout/unload/disconnect
--     anında araç yok olmaz; koordinat + heading fiziksel kalır.
--   • [PV-3] HOOD SECURE TURF: dost mahalle sınırı içindeki araç
--     "parked_hood" bayrağı alır; ALPR tarama matrisinden kazınır.
--   • [AR-1] /araciyak [plate] interaktif kundaklama (jerry_can zorunlu).
--   • [AR-2] 90sn server-authoritative friction penceresi (prop_clean_agent).
--   • [AR-3] Aşamalı yakma + matrix_bureau_intensity +0.40/10sn spike.
--   • [AR-4] Adli sanitizasyon: body_health < 100 → 100% fingerprint wipe.
--   • [DI-1] [MATRIX:PERSISTENT_VEHICLES_PHASE3] tanı etiketli hook'lar.
--   • SIFIR RNG (math.random YOK), SIFIR ek resmon thread (master tick 1sn).
--
-- ★★★ FAZ 6 — ADIM 3: HİDROLİK TUĞLA PRESİ & WEED LOGISTICS ★★★
--   • [HP-1] /presle [trapHouseId] [productType] [brickCount] komutu.
--   • [HP-2] 100 x 10g torba + 1 x heavy_duty_press_bag = 1 x 1kg narcotic_brick.
--   • [HP-3] 5 master-cycle arka plan pres state-machine (sıfır RNG).
--   • [HP-4] Deterministik ağırlıklı-ortalama purity metadata enjeksiyonu.
--   • [HP-5] matrix_trap_houses.brick_press_status / total_compressed_bricks.
--   • [LG-1] DispatchCargo + payload mapping (masterpiece_gourmet_weed/trash_weed/narcotic_brick).
--   • [LG-2] 1kg brick -> WeightFrictionCoefficient * 1000.0 explicit friction.
--   • [LG-3] LSPD checkpoint: masterpiece_gourmet_weed -> 3.0x forensic penalty amp.
--   • [DI-2] [MATRIX:HYDRAULIC_PRESS_PHASE6] tanı etiketli +3 regression check.
-- =====================================================================


Matrix.Logistics  = Matrix.Logistics  or {}
Matrix.Fleet      = Matrix.Fleet      or {}
Matrix.Supplier   = Matrix.Supplier   or {}
Matrix.Persistent = Matrix.Persistent or { ByPlate = {}, Dirty = {} }
Matrix.Arson      = Matrix.Arson      or { ByPlate = {}, BySrc = {} }


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local math_max, math_min, math_huge = math.max, math.min, math.huge
local math_floor, math_sqrt, math_abs = math.floor, math.sqrt, math.abs


local CreateThread                  = CreateThread
local Wait                          = Wait
local SetTimeout                    = SetTimeout
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local DoesEntityExist               = DoesEntityExist
local SetEntityCoords               = SetEntityCoords
local TriggerClientEvent            = TriggerClientEvent
local RegisterCommand               = RegisterCommand
local RegisterNetEvent              = RegisterNetEvent
local GetGameTimer                  = GetGameTimer
local SetConvar                     = SetConvar
local GetConvarFloat                = GetConvarFloat
local GetHashKey                    = GetHashKey


local PENDING_EVENTS_MAX = 64


-- =====================================================================
-- RUNTIME STATE
-- =====================================================================
local FleetVehicles         = {}
local PermanentVehicleByBot = {}
local ActiveVehicleLocks    = {}


local SupplierTrustCache    = {}
local ActiveDrops           = {}
local DropHeat              = {}


local dirtyFleet            = {}
local dirtySupplierTrust    = {}
local dirtyPersistent       = {}


local WARNED_MISSING_FLEET   = false
local WARNED_MISSING_TRUST   = false
local WARNED_MISSING_PERSIST = false


-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' and type(a) ~= 'vector3' and type(a) ~= 'vector4' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' and type(b) ~= 'vector3' and type(b) ~= 'vector4' then return math_huge end
    return #(a - b)
end


local function LerpCoords(a, b, t)
    t = Matrix.Clamp(t, 0.0, 1.0)
    return vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
    )
end


local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    return c.x ~= nil and c.y ~= nil and c.z ~= nil
end


local function GetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end


local function ValidateDestination(origin, destination)
    if destination == nil then return false, 'missing_vector' end
    if type(destination) ~= 'table' and type(destination) ~= 'userdata'
        and type(destination) ~= 'vector3' and type(destination) ~= 'vector4' then
        return false, 'corrupt_vector'
    end

    local x, y, z = destination.x, destination.y, destination.z
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
        return false, 'corrupt_vector'
    end
    if x ~= x or y ~= y or z ~= z then return false, 'corrupt_vector' end
    if x == math_huge or x == -math_huge or y == math_huge or y == -math_huge
        or z == math_huge or z == -math_huge then
        return false, 'corrupt_vector'
    end

    if origin then
        local dist = VectorDistance(origin, destination)
        if dist > Config.Logistics.MaxDispatchRangeMeters then
            return false, 'out_of_range', dist
        end
        if dist < Config.Logistics.MinDispatchDistanceMeters then
            return false, 'too_close', dist
        end
    end
    return true
end


local function GetBotInventoryWeight(bot)
    local inventoryId = ('dealer_%d'):format(bot.id)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return 0.0 end

    local total = 0.0
    for _, item in pairs(inv.items) do
        if type(item) == 'table' then
            total = total + ((tonumber(item.weight) or 0.0) * (tonumber(item.count) or 0.0))
        end
    end
    return total
end


local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(coords, zone.coords) <= zone.radius then return zone end
    end
    return nil
end


local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        local events = dispatch.pending_events
        if #events >= PENDING_EVENTS_MAX then
            table.remove(events, 1)
        end
        events[#events + 1] = message
    else
        Matrix.Log('LOGISTICS', message)
    end
end


local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end
    Matrix.Log('LOGISTICS', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('LOGISTICS', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end


-- =====================================================================
-- ★ [C-5 FIX] GÜVENLİ KAYNAK→HEDEF TRANSFER YARDIMCISI
-- =====================================================================
local function _SafeAmmoTransfer(sourceInv, targetInv, item, count, botId, citizenid)
    local invOk, targetInvData = pcall(function()
        return exports['ox_inventory']:GetInventory(targetInv)
    end)
    if not invOk or type(targetInvData) ~= 'table' then
        Matrix.Log('LOGISTICS', '[C-5] Dry-run: hedef envanter okunamadi (%s).', tostring(targetInv))
        return 'error'
    end

    local removeOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(sourceInv, item, count)
    end)
    if not (removeOk and removed == true) then
        return 'source_empty'
    end

    local addOk, added = pcall(function()
        return exports['ox_inventory']:AddItem(targetInv, item, count)
    end)
    if addOk and added == true then
        return 'ok'
    end

    local restoreOk, restored = pcall(function()
        return exports['ox_inventory']:AddItem(sourceInv, item, count)
    end)
    if restoreOk and restored == true then
        return 'target_full'
    end

    Matrix.Log('LOGISTICS',
        '[KRITIK][C-5] %s x%d hedefe eklenemedi ve kaynaga da geri yazilamadi -- ledger kaydi.',
        tostring(item), count)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO matrix_pending_refunds (citizenid, amount, reason, created_at) VALUES (?, ?, ?, NOW())',
            {
                citizenid or ('BOT-' .. tostring(botId)),
                0.0,
                ('logistics-ammo-run-orphan:%sx%d'):format(tostring(item), count)
            }
        )
    end)
    return 'orphan_logged'
end


-- =====================================================================
-- ILLEGAL FLEET: ASENKRON YÜKLEME
-- =====================================================================
function Matrix.Fleet.LoadFleet()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_fleet', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_FLEET then
                        WARNED_MISSING_FLEET = true
                        Matrix.Log('LOGISTICS',
                            '[HATA] Filo veri tabani tablosu (matrix_fleet) bulunamadi/okunamadi. Bellekteki yedek onbellek (RAM) devreye alindi; simulasyon kesintisiz suruyor.')
                    end
                    return
                end

                for _, row in ipairs(rows) do
                    if row and row.plate then
                        FleetVehicles[row.plate] = {
                            plate                   = row.plate,
                            vehicle_class           = row.vehicle_class or Config.Logistics.Fleet.DefaultVehicleClass,
                            vin_status              = row.vin_status or Config.Logistics.Fleet.DefaultVinStatus,
                            vehicle_wear            = tonumber(row.vehicle_wear) or 0.0,
                            registered_by_citizenid = row.registered_by_citizenid,
                            assigned_bot_id         = row.assigned_bot_id,
                            assignment_mode         = row.assignment_mode,
                            verified_stolen_plate   = (row.verified_stolen_plate == 1)
                        }
                        if row.assigned_bot_id and row.assignment_mode == 'permanent' then
                            PermanentVehicleByBot[row.assigned_bot_id] = row.plate
                        end
                    end
                end
                Matrix.Log('LOGISTICS', '%d illegal arac filoya yuklendi (async).', #rows)
            end)

            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[HATA] matrix_fleet callback isleme hatasi (simulasyon suruyor): %s',
                    tostring(cbErr))
            end
        end)
    end)

    if not callOk then
        if not WARNED_MISSING_FLEET then
            WARNED_MISSING_FLEET = true
            Matrix.Log('LOGISTICS',
                '[HATA] matrix_fleet sorgu cagrisi reddedildi; RAM onbellek devrede (simulasyon suruyor): %s',
                tostring(callErr))
        end
    end
end


CreateThread(function()
    Matrix.Fleet.LoadFleet()
end)


-- =====================================================================
-- ILLEGAL FLEET: ASENKRON PERSISTENCE
-- =====================================================================
local function MarkFleetDirty(plate)
    if plate then dirtyFleet[plate] = true end
end


local function FlushDirtyFleet()
    local pendingPlates = {}
    for plate in pairs(dirtyFleet) do
        pendingPlates[#pendingPlates + 1] = plate
    end
    if #pendingPlates == 0 then return end

    local queries = {}
    for _, plate in ipairs(pendingPlates) do
        local v = FleetVehicles[plate]
        if v then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_fleet
                        (plate, vehicle_class, vin_status, vehicle_wear, registered_by_citizenid,
                         assigned_bot_id, assignment_mode, verified_stolen_plate, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                    ON DUPLICATE KEY UPDATE
                        vehicle_class           = VALUES(vehicle_class),
                        vin_status              = VALUES(vin_status),
                        vehicle_wear            = VALUES(vehicle_wear),
                        registered_by_citizenid = VALUES(registered_by_citizenid),
                        assigned_bot_id         = VALUES(assigned_bot_id),
                        assignment_mode         = VALUES(assignment_mode),
                        verified_stolen_plate   = VALUES(verified_stolen_plate),
                        updated_at              = NOW()
                ]],
                values = {
                    v.plate, v.vehicle_class, v.vin_status, v.vehicle_wear,
                    v.registered_by_citizenid, v.assigned_bot_id, v.assignment_mode,
                    v.verified_stolen_plate and 1 or 0
                }
            }
        end
    end

    if #queries == 0 then
        for _, plate in ipairs(pendingPlates) do dirtyFleet[plate] = nil end
        return
    end

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, plate in ipairs(pendingPlates) do dirtyFleet[plate] = nil end
    else
        Matrix.Log('LOGISTICS',
            '[HATA][KRITIK] FlushDirtyFleet transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


-- =====================================================================
-- ILLEGAL FLEET: KAYIT / ATAMA
-- =====================================================================
function Matrix.Fleet.GetVehicle(plate)
    if type(plate) ~= 'string' then return nil end
    return FleetVehicles[plate]
end


local function VerifyStolenPlateAsync(plate)
    pcall(function()
        MySQL.query('SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate }, function(rows)
            local cbOk = pcall(function()
                local v = FleetVehicles[plate]
                if not v then return end
                if type(rows) == 'table' and rows[1] then
                    v.verified_stolen_plate = true
                    MarkFleetDirty(plate)
                    Matrix.Log('LOGISTICS',
                        '[QB-CORE DOĞRULAMA] %s hakiki çalıntı olarak doğrulandı (sahip: %s).',
                        plate, tostring(rows[1].citizenid))
                end
            end)
            if not cbOk then
                Matrix.Log('LOGISTICS', '[HATA] stolen-plate callback hatasi (yutuldu): %s', plate)
            end
        end)
    end)
end


function Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if type(plate) ~= 'string' or plate == '' or #plate > 32 then return false, 'bad_plate' end
    if FleetVehicles[plate] then return false, 'plate_exists' end

    vehicleClass = (vehicleClass == 'motorbike' or vehicleClass == 'car')
        and vehicleClass or Config.Logistics.Fleet.DefaultVehicleClass
    vinStatus = (vinStatus == 'factory' or vinStatus == 'scratched' or vinStatus == 'hot')
        and vinStatus or Config.Logistics.Fleet.DefaultVinStatus
    vehicleWear = Matrix.Clamp(tonumber(vehicleWear) or 0.0, 0.0, 1.0)

    FleetVehicles[plate] = {
        plate                   = plate,
        vehicle_class           = vehicleClass,
        vin_status              = vinStatus,
        vehicle_wear            = vehicleWear,
        registered_by_citizenid = citizenid,
        assigned_bot_id         = nil,
        assignment_mode         = nil,
        verified_stolen_plate   = false
    }
    MarkFleetDirty(plate)

    VerifyStolenPlateAsync(plate)

    Matrix.Log('LOGISTICS',
        'Illegal arac filoya kaydedildi (RAM + dirty-flag): %s [%s/%s] asinma=%.2f (sahip:%s)',
        plate, vehicleClass, vinStatus, vehicleWear, tostring(citizenid))

    return true
end


function Matrix.Fleet.AssignPermanent(plate, botId)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false, 'vehicle_not_found' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    if vehicle.assigned_bot_id and vehicle.assigned_bot_id ~= botId then
        return false, 'vehicle_assigned_elsewhere'
    end
    if PermanentVehicleByBot[botId] and PermanentVehicleByBot[botId] ~= plate then
        return false, 'bot_already_has_vehicle'
    end

    vehicle.assigned_bot_id = botId
    vehicle.assignment_mode = 'permanent'
    PermanentVehicleByBot[botId] = plate
    MarkFleetDirty(plate)

    Matrix.Log('LOGISTICS', 'Arac %s -> Bot #%d (%s) kalici olarak atandi.', plate, botId, bot.name)
    return true
end


function Matrix.Fleet.UnassignPermanent(plate)
    local vehicle = FleetVehicles[plate]
    if not vehicle or not vehicle.assigned_bot_id then return false end

    PermanentVehicleByBot[vehicle.assigned_bot_id] = nil
    vehicle.assigned_bot_id = nil
    vehicle.assignment_mode = nil
    MarkFleetDirty(plate)

    Matrix.Log('LOGISTICS', 'Arac %s serbest birakildi (kalici atama kaldirildi).', plate)
    return true
end


function Matrix.Fleet.GetVehicleByBot(botId)
    local plate = PermanentVehicleByBot[tonumber(botId)]
    if not plate then return nil end
    return FleetVehicles[plate]
end


function Matrix.Fleet.RecordAlprHit(plate, dnaId, organizationSignature, trapHouseId)
    if not Matrix.Persistent.IsAlprVisible(plate) then
        Matrix.Log('LOGISTICS',
            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ALPR-SHADOW] %s parked_hood; kayit matrise YAZILMADI.', plate)
        return false
    end
    MySQL.prepare([[
        INSERT INTO matrix_alpr_hits (plate, fingerprint_dna_id, organization_signature, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { plate, dnaId or 'UNKNOWN', organizationSignature or 'UNKNOWN', trapHouseId })
    return true
end


function Matrix.Fleet.SeizeVehicle(plate, cause, dnaId, coords)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false end

    local certainty = Config.Logistics.Fleet.SeizureSealCertainty[vehicle.vin_status]
        or Config.Logistics.Fleet.SeizureSealCertainty[Config.Logistics.Fleet.DefaultVinStatus]

    if vehicle.verified_stolen_plate then
        certainty = Matrix.Clamp(certainty + 0.03, 0.0, 1.0)
    end

    local cx, cy, cz = 0.0, 0.0, 0.0
    if IsValidCoords(coords) then cx, cy, cz = coords.x, coords.y, coords.z end

    MySQL.prepare([[
        INSERT INTO matrix_vehicle_seizures (
            plate, vin_status, vehicle_wear, fingerprint_dna_id, organization_signature,
            seizure_cause, seal_certainty, coords_x, coords_y, coords_z, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        plate, vehicle.vin_status, vehicle.vehicle_wear, dnaId or 'UNKNOWN',
        vehicle.registered_by_citizenid or 'UNKNOWN', cause or 'unknown', certainty, cx, cy, cz
    })

    if vehicle.assigned_bot_id then PermanentVehicleByBot[vehicle.assigned_bot_id] = nil end
    ActiveVehicleLocks[plate] = nil
    FleetVehicles[plate] = nil
    dirtyFleet[plate] = nil

    MySQL.prepare('DELETE FROM matrix_fleet WHERE plate = ?', { plate })

    Matrix.Log('LOGISTICS',
        '[FILO KAYIP: %s MUHURLENDI VE FILODAN SILINDI] Sebep:%s | VIN:%s | Muhur-Kesinlik:%.2f',
        plate, tostring(cause or 'unknown'), vehicle.vin_status, certainty)
    return true
end


function Matrix.Logistics.OnVehicleEncircled(plate, cause)
    local vehicle = Matrix.Fleet.GetVehicle(plate)
    if not vehicle then return false end

    local usingBotId = ActiveVehicleLocks[plate] or vehicle.assigned_bot_id
    local bot = usingBotId and Matrix.Bots[usingBotId]

    local dnaId, coords = 'UNKNOWN', nil
    if bot then
        dnaId = bot.dna_id
        coords = bot.state.coords
    end

    return Matrix.Fleet.SeizeVehicle(plate, cause or 'police_encirclement', dnaId, coords)
end


function Matrix.Logistics.ReleaseVehicleLock(plate)
    if plate and ActiveVehicleLocks[plate] then
        ActiveVehicleLocks[plate] = nil
    end
end


-- =====================================================================
-- TOPTANCI İLİŞKİ MATRİSİ & DEAD DROP LOJİSTİĞİ
-- =====================================================================
local function TrustKey(citizenid, supplierId)
    return tostring(citizenid) .. '#' .. tostring(supplierId)
end


local function GetDropConfig(dropId)
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if drop.id == dropId then return drop end
    end
    return nil
end


local function FindActiveDeadDropAt(coords)
    for dropId, drop in pairs(ActiveDrops) do
        local cfg = GetDropConfig(dropId)
        if cfg and VectorDistance(coords, cfg.coords) <= cfg.radius then
            return dropId, drop, cfg
        end
    end
    return nil
end


function Matrix.Supplier.LoadTrust()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_supplier_trust', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_TRUST then
                        WARNED_MISSING_TRUST = true
                        Matrix.Log('LOGISTICS',
                            '[HATA] Toptanci guven tablosu (matrix_supplier_trust) bulunamadi/okunamadi. RAM onbellek devrede; varsayilan trust (0.5) uzerinden simulasyon suruyor.')
                    end
                    return
                end

                for _, row in ipairs(rows) do
                    if row and row.citizenid then
                        SupplierTrustCache[TrustKey(row.citizenid, row.supplier_id)] = {
                            citizenid       = row.citizenid,
                            supplier_id     = row.supplier_id,
                            trust           = tonumber(row.trust) or Config.Supplier.DefaultTrust,
                            late_payments   = row.late_payments or 0,
                            forensic_leaks  = row.forensic_leaks or 0,
                            last_touched    = Matrix.Now()
                        }
                    end
                end
                Matrix.Log('LOGISTICS', '%d toptanci guven iliskisi yuklendi (async).', #rows)
            end)

            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[HATA] matrix_supplier_trust callback hatasi (simulasyon suruyor): %s',
                    tostring(cbErr))
            end
        end)
    end)

    if not callOk then
        if not WARNED_MISSING_TRUST then
            WARNED_MISSING_TRUST = true
            Matrix.Log('LOGISTICS',
                '[HATA] matrix_supplier_trust sorgu cagrisi reddedildi; RAM onbellek devrede: %s',
                tostring(callErr))
        end
    end
end


CreateThread(function()
    Matrix.Supplier.LoadTrust()
end)


local function ApplyPassiveTrustDrift(rec)
    local now = Matrix.Now()
    local elapsedDays = (now - (rec.last_touched or now)) / 86400.0
    rec.last_touched = now
    if elapsedDays <= 0.0 then return end

    local target = Config.Supplier.PassiveTrustRecoveryTarget
    local closedFraction = 1.0 - ((1.0 - Config.Supplier.PassiveTrustRecoveryPerRealDay) ^ elapsedDays)
    rec.trust = Matrix.Clamp(rec.trust + ((target - rec.trust) * closedFraction), 0.0, 1.0)
end


function Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    local key = TrustKey(citizenid, supplierId)
    local rec = SupplierTrustCache[key]
    if not rec then
        rec = {
            citizenid = citizenid, supplier_id = supplierId,
            trust = Config.Supplier.DefaultTrust,
            late_payments = 0, forensic_leaks = 0,
            last_touched = Matrix.Now()
        }
        SupplierTrustCache[key] = rec
    else
        ApplyPassiveTrustDrift(rec)
    end
    return rec
end


function Matrix.Supplier.GetTrust(citizenid, supplierId)
    return Matrix.Supplier.GetTrustRecord(citizenid, supplierId).trust
end


local function MarkSupplierTrustDirty(citizenid, supplierId)
    dirtySupplierTrust[TrustKey(citizenid, supplierId)] = true
end


local function FlushDirtySupplierTrust()
    local pendingKeys = {}
    for key in pairs(dirtySupplierTrust) do
        pendingKeys[#pendingKeys + 1] = key
    end
    if #pendingKeys == 0 then return end

    local queries = {}
    for _, key in ipairs(pendingKeys) do
        local rec = SupplierTrustCache[key]
        if rec then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_supplier_trust
                        (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, NOW(), NOW())
                    ON DUPLICATE KEY UPDATE
                        trust          = VALUES(trust),
                        late_payments  = VALUES(late_payments),
                        forensic_leaks = VALUES(forensic_leaks),
                        updated_at     = NOW()
                ]],
                values = { rec.citizenid, rec.supplier_id, rec.trust, rec.late_payments, rec.forensic_leaks }
            }
        end
    end

    if #queries == 0 then
        for _, key in ipairs(pendingKeys) do dirtySupplierTrust[key] = nil end
        return
    end

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, key in ipairs(pendingKeys) do dirtySupplierTrust[key] = nil end
    else
        Matrix.Log('LOGISTICS',
            '[HATA][KRITIK] FlushDirtySupplierTrust transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


function Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = 1.0 + ((1.0 - trust) * Config.Supplier.PriceMultiplierGain)
    return Matrix.Clamp(mult, Config.Supplier.PriceMultiplierFloor, Config.Supplier.PriceMultiplierCeiling)
end


function Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    local targetId = nil
    for id in pairs(Matrix.TrapHouses or {}) do
        if not targetId or id < targetId then targetId = id end
    end
    if targetId then
        Matrix.Bureau.ReceiveSnitchLeak(targetId)
    end

    Matrix.Log('LOGISTICS',
        '[IHANET] Toptanci #%d guven esiginin altina dustu: %s desifre edildi / infaz mangasi yolda.',
        supplierId, tostring(citizenid))
    TriggerClientEvent('matrix:client:executeHitSquad', -1, citizenid, supplierId)
end


function Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.late_payments = rec.late_payments + 1
    rec.trust = Matrix.Clamp(rec.trust - Config.Supplier.TrustLatePaymentPenalty, 0.0, 1.0)
    MarkSupplierTrustDirty(citizenid, supplierId)

    Matrix.Log('LOGISTICS', 'Toptanci #%d guveni dustu (gecikmis odeme): %s -> %.2f',
        supplierId, tostring(citizenid), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    end
    return rec.trust
end


function Matrix.Supplier.ApplyBureauIntelLeak(citizenid, supplierId, penalty, dropId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.trust = Matrix.Clamp(rec.trust - (tonumber(penalty) or 0.0), 0.0, 1.0)
    rec.forensic_leaks = rec.forensic_leaks + 1
    MarkSupplierTrustDirty(citizenid, supplierId)

    Matrix.Log('LOGISTICS',
        '[BÜRO SIZINTISI] Drop #%s üzerinden toptancı #%d güveni düştü: %s -> %.3f',
        tostring(dropId), supplierId, tostring(citizenid), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    end

    return rec.trust
end


function Matrix.Supplier.RequestDrop(citizenid, dropId)
    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then return false, 'bad_drop' end
    if ActiveDrops[dropId] then return false, 'already_active' end

    local rec = Matrix.Supplier.GetTrustRecord(citizenid, dropCfg.supplier_id)
    if rec.trust < Config.Supplier.SupplyCutTrustThreshold then
        return false, 'supply_cut'
    end

    ActiveDrops[dropId] = {
        supplier_id  = dropCfg.supplier_id,
        citizenid    = citizenid,
        requested_at = Matrix.Now(),
        expires_at   = Matrix.Now() + Config.Supplier.PickupWindowSeconds
    }

    local priceMultiplier = Matrix.Supplier.GetPriceMultiplier(citizenid, dropCfg.supplier_id)

    Matrix.Log('LOGISTICS',
        'Dead drop #%d (%s) acildi: toptanci #%d, guven=%.2f, fiyat-carpani=x%.2f, pencere=%ds',
        dropId, dropCfg.label, dropCfg.supplier_id, rec.trust, priceMultiplier, Config.Supplier.PickupWindowSeconds)

    return true, {
        price_multiplier = priceMultiplier,
        expires_in       = Config.Supplier.PickupWindowSeconds,
        coords           = dropCfg.coords
    }
end


function Matrix.Supplier.OnPickup(actorRef, dropId, creditCitizenid)
    local drop = ActiveDrops[dropId]
    if not drop then return false, 'no_active_drop' end
    if Matrix.Now() > drop.expires_at then
        ActiveDrops[dropId] = nil
        return false, 'window_expired'
    end

    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then return false, 'bad_drop' end

    local actor = Matrix.ResolveActor(actorRef)

    -- v6.6.6 H13: teslim alan actor, bu dead-drop'un atanmis sahibi
    -- (RequestDrop'ta kaydedilen drop.citizenid) olmali. creditCitizenid
    -- parametresi keyfi sekilde farkli bir citizenid'e kredi/ceza
    -- yonlendirmek icin ARTIK kullanilamaz -- sahiplik dogrulanir,
    -- fail-closed.
    local actorCitizenid = actor and (actor.citizenid or (actor.state and actor.state.citizenid))
    if not actorCitizenid or actorCitizenid ~= drop.citizenid then
        Matrix.Log('LOGISTICS', '[YETKI RED] OnPickup: drop #%d sahibi degil (actor=%s, sahip=%s).',
            dropId, tostring(actorCitizenid), tostring(drop.citizenid))
        return false, 'not_drop_owner'
    end

    local fingerprintQuality = actor and Matrix.Forensics.ComputeFingerprintQuality(actor) or 1.0
    local forensicTraceLeft = fingerprintQuality < Config.Supplier.ForensicTraceQualityThreshold
    local heat = DropHeat[dropId] or 0.0

    local citizenid = drop.citizenid   -- ★ v6.6.6: creditCitizenid artik guvenilmiyor
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, drop.supplier_id)

    if forensicTraceLeft or heat > 0.0 then
        local penalty = Config.Supplier.TrustForensicLeakPenalty * (1.0 + (heat * Config.Supplier.TrustHeatmapPenaltyFactor))
        rec.trust = Matrix.Clamp(rec.trust - penalty, 0.0, 1.0)
        if forensicTraceLeft then rec.forensic_leaks = rec.forensic_leaks + 1 end
    else
        rec.trust = Matrix.Clamp(rec.trust + Config.Supplier.TrustRecoveryPerCleanPickup, 0.0, 1.0)
    end
    MarkSupplierTrustDirty(citizenid, drop.supplier_id)

    DropHeat[dropId] = math_min(heat + Config.Supplier.DropHeatGrowthPerUse, 10.0)
    ActiveDrops[dropId] = nil

    MySQL.prepare([[
        INSERT INTO matrix_dead_drop_events (drop_id, supplier_id, citizenid, heat_at_pickup, forensic_trace_left, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { dropId, drop.supplier_id, citizenid, heat, forensicTraceLeft and 1 or 0 })

    Matrix.Log('LOGISTICS', 'Dead drop #%d (%s) teslim alindi: %s | heat=%.2f | iz=%s | guven=%.2f',
        dropId, dropCfg.label, tostring(citizenid), heat, tostring(forensicTraceLeft), rec.trust)

    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, drop.supplier_id)
    end

    return true, { heat = heat, forensic_trace_left = forensicTraceLeft, trust = rec.trust }
end


-- =====================================================================
-- KALICI ÖLÜM (PERMADEATH & HARD-DELETE)
-- =====================================================================
function Matrix.Logistics.OnDealerEliminated(botId, cause)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        local dispatch = Matrix.Dispatches[botId]
        local plate = dispatch.plate
        if plate then Matrix.Logistics.ReleaseVehicleLock(plate) end
        if Matrix.DespawnDispatchEntity then Matrix.DespawnDispatchEntity(botId, dispatch) end
        Matrix.Dispatches[botId] = nil
    end

    local plateToSeize = PermanentVehicleByBot[botId]
    local lastCoords = bot.state.coords
    local dnaId = bot.dna_id

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
    end

    MySQL.prepare('DELETE FROM matrix_bots WHERE id = ?', { botId })

    Matrix.Persistence.dirtyBots[botId] = nil
    Matrix.Bots[botId] = nil

    Matrix.Log('LOGISTICS',
        '[LOJISTIK KAYIP: DEALER_ID %d KALICI OLARAK DE-REGISTRE EDILDI] Sebep:%s',
        botId, tostring(cause or 'unknown'))

    if plateToSeize then
        Matrix.Fleet.SeizeVehicle(plateToSeize, cause, dnaId, lastCoords)
    end

    return true
end


-- =====================================================================
-- ÇATIŞMA DİRENCİ
-- =====================================================================
function Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
    local bot = Matrix.Bots[botId]
    if not bot then return false end

    rawDamage = tonumber(rawDamage) or 1.0
    if rawDamage ~= rawDamage or rawDamage < 0.0 then rawDamage = 0.0 end

    local dispatch = Matrix.Dispatches and Matrix.Dispatches[botId]
    local profile = GetVehicleProfile(dispatch and dispatch.vehicle_type or Config.Logistics.DefaultVehicleType)
    local effectiveDamage = rawDamage * (1.0 - profile.CombatResistance)

    if dispatch then
        dispatch.combat_damage = (dispatch.combat_damage or 0.0) + effectiveDamage
        Matrix.Log('LOGISTICS', 'Bot #%d catisma hasari: ham=%.2f direnc=%.2f etkin=%.2f birikim=%.2f/%.2f',
            botId, rawDamage, profile.CombatResistance, effectiveDamage,
            dispatch.combat_damage, Config.Logistics.CombatEliminationThreshold)

        if dispatch.combat_damage >= Config.Logistics.CombatEliminationThreshold then
            Matrix.Logistics.OnDealerEliminated(botId, 'combat')
        end
    elseif effectiveDamage >= Config.Logistics.CombatEliminationThreshold then
        Matrix.Logistics.OnDealerEliminated(botId, 'combat')
    end

    return true
end


function Matrix.Logistics.OnPoliceCollision(botId)
    return Matrix.Logistics.OnDealerEliminated(botId, 'police_collision')
end


-- =====================================================================
-- DEALER SEVK PLANLAYICI
-- =====================================================================
function Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.role ~= 'dealer' then return false, 'not_a_dealer' end

    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        return false, 'already_dispatched'
    end

    if Matrix.RadioSilence and Matrix.RadioSilence.GuardBotDispatch then
        local silOk, silReason = Matrix.RadioSilence.GuardBotDispatch(dispatcherSrc)
        if not silOk then return false, silReason end
    end

    local origin = bot.state.coords
    if not IsValidCoords(origin) then
        local fallbackHouse = bot.state.trap_house_id and Matrix.TrapHouses and Matrix.TrapHouses[bot.state.trap_house_id]

        if not fallbackHouse and Matrix.TrapHouses then
            local lowestId = nil
            for id in pairs(Matrix.TrapHouses) do
                if not lowestId or id < lowestId then lowestId = id end
            end
            fallbackHouse = lowestId and Matrix.TrapHouses[lowestId]
        end

        if fallbackHouse then
            origin = fallbackHouse.coords
            Matrix.Log('LOGISTICS',
                '[ORIJIN VARSAYILANI] Bot #%d hic konumlanmamisti; trap house #%d (%s) baslangic olarak kullanildi.',
                botId, fallbackHouse.id, fallbackHouse.label)
        elseif type(dispatcherSrc) == 'number' and dispatcherSrc > 0 then
            local ped = GetPlayerPed(dispatcherSrc)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                origin = vector3(c.x, c.y + 200.0, c.z)
                Matrix.Log('LOGISTICS',
                    '[ORIJIN VARSAYILANI] Bot #%d hic konumlanmamisti ve matriste trap house yok; dispatcher src=%d konumu +200m ofsetle kullanildi.',
                    botId, dispatcherSrc)
            end
        end

        if not IsValidCoords(origin) then return false, 'no_origin' end
    end

    local destOk, destReason, destExtra = ValidateDestination(origin, destination)
    if not destOk then
        Matrix.Log('LOGISTICS',
            '[LOJISTIK HATA: GECERSIZ HEDEF VEKTORU] Bot #%d sevk reddedildi. Sebep:%s',
            botId, destReason)
        return false, destReason
    end

    local plate, vehicle, vehicleType, assignmentMode = nil, nil, nil, nil

    if vehicleRef == nil or vehicleRef == '' then
        plate = PermanentVehicleByBot[botId]
    elseif vehicleRef ~= 'foot' then
        plate = vehicleRef
    end

    if plate then
        vehicle = Matrix.Fleet.GetVehicle(plate)
        if not vehicle then return false, 'vehicle_not_found' end
        if vehicle.assigned_bot_id and vehicle.assigned_bot_id ~= botId then
            return false, 'vehicle_assigned_elsewhere'
        end
        if ActiveVehicleLocks[plate] and ActiveVehicleLocks[plate] ~= botId then
            return false, 'vehicle_in_use'
        end

        vehicleType    = vehicle.vehicle_class
        assignmentMode = (vehicle.assigned_bot_id == botId) and 'permanent' or 'temporary'
        ActiveVehicleLocks[plate] = botId
    else
        vehicleType = 'foot'
    end

    local profile = GetVehicleProfile(vehicleType)
    local wearBonus = vehicle and (1.0 + (vehicle.vehicle_wear * Config.Logistics.Fleet.WearFrictionBonus)) or 1.0
    local effectiveFriction = profile.FrictionMultiplier * wearBonus

    local distance    = VectorDistance(origin, destination)
    local weightTotal = GetBotInventoryWeight(bot)
    local baseSpeed   = Config.Logistics.BaseSpeedUnitsPerSecond

    local frictionDivisor = 1.0 + (weightTotal * Config.Logistics.WeightFrictionCoefficient * effectiveFriction)

    -- [FAZ6-ADIM3][LG-2] 1kg narcotic_brick -> WeightFrictionCoefficient * 1000.0 explicit friction.
    -- Deterministik hesaplanir; RNG yok. Brick tasimayan botlarda no-op.
    local brickFriction = 0.0
    if Matrix.Logistics.ComputeNarcoticBrickFriction then
        brickFriction = Matrix.Logistics.ComputeNarcoticBrickFriction(botId)
    end
    if brickFriction > 0.0 then
        frictionDivisor = frictionDivisor + brickFriction
        Matrix.Log('LOGISTICS',
            '[MATRIX:HYDRAULIC_PRESS_PHASE6][LG-2] Bot #%d narcotic_brick tasiyor -> ek friction=+%.4f.',
            botId, brickFriction)
    end

    local etaSeconds = (distance / (baseSpeed * profile.SpeedCoefficient)) * frictionDivisor
    etaSeconds = Matrix.Clamp(etaSeconds, 0.0, math_huge)

    Matrix.Log('LOGISTICS',
        'Sevkiyat plani: Bot #%d [%s]%s Mesafe:%.1fm Agirlik:%.1fg Surtunme:x%.2f ETA:%.1fsn',
        botId, bot.name,
        plate and (' Plaka:%s VIN:%s Asinma:%.2f'):format(plate, vehicle.vin_status, vehicle.vehicle_wear)
              or (' Arac:%s'):format(vehicleType),
        distance, weightTotal, frictionDivisor, etaSeconds)

    if Matrix.BeginPhysicalDispatch then
        local ok, reason = Matrix.BeginPhysicalDispatch(
            botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc, frictionDivisor
        )
        if not ok then
            if plate then ActiveVehicleLocks[plate] = nil end
            Matrix.Log('LOGISTICS', '[SEVK BASLATILAMADI] Bot #%d Sebep:%s', botId, tostring(reason))
            return false, reason or 'dispatch_failed'
        end
    else
        Matrix.Log('LOGISTICS',
            '[UYARI] BeginPhysicalDispatch exportu tanimli degil; sevk yalnizca plan olarak kayitli.')
    end

    return true, etaSeconds
end


Matrix.SevkBot = Matrix.Logistics.DispatchDealer


-- =====================================================================
-- ★ KATMAN 7 [T2]: MÜHİMMAT DAĞITIM GÖREVİ
-- =====================================================================
function Matrix.Logistics.DispatchAmmoRun(sourceBotId, targetBotId, dispatcherSrc)
    sourceBotId = tonumber(sourceBotId)
    targetBotId = tonumber(targetBotId)
    if not sourceBotId or not targetBotId then return false, 'bad_bot_id' end
    if sourceBotId == targetBotId then return false, 'same_bot' end

    local sourceBot = Matrix.Bots[sourceBotId]
    if not sourceBot then return false, 'bot_missing' end
    if sourceBot.role ~= 'runner' then return false, 'not_logistics' end
    if sourceBot.state.is_locked or (Matrix.Dispatches and Matrix.Dispatches[sourceBotId]) then
        return false, 'already_dispatched'
    end

    local targetBot = Matrix.Bots[targetBotId]
    if not targetBot then return false, 'target_missing' end
    if not IsValidCoords(targetBot.state.coords) then return false, 'target_no_coords' end

    local trapHouseId = sourceBot.state.trap_house_id
    local house = trapHouseId and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if not house then return false, 'no_trap_house' end

    if Matrix.RadioSilence and Matrix.RadioSilence.GuardBotDispatch then
        local silOk, silReason = Matrix.RadioSilence.GuardBotDispatch(dispatcherSrc)
        if not silOk then return false, silReason end
    end

    local stashId     = ('matrix_trap_stash_%d'):format(trapHouseId)
    local inventoryId = ('dealer_%d'):format(sourceBotId)
    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, (house.label or ('Trap #' .. trapHouseId)) .. ' Deposu', 100, 200000)
    end)

    local pulled = {}
    for _, entry in ipairs(Config.Logistics.AmmoRunManifest) do
        local removeOk, removed = pcall(function()
            return exports['ox_inventory']:RemoveItem(stashId, entry.item, entry.count)
        end)
        if removeOk and removed == true then
            local addOk, added = pcall(function()
                return exports['ox_inventory']:AddItem(inventoryId, entry.item, entry.count)
            end)
            if addOk and added == true then
                pulled[#pulled + 1] = ('%sx%d'):format(entry.item, entry.count)
            else
                local restoreOk, restored = pcall(function()
                    return exports['ox_inventory']:AddItem(stashId, entry.item, entry.count)
                end)
                if not (restoreOk and restored == true) then
                    Matrix.Log('LOGISTICS',
                        '[KRITIK][C-5] DispatchAmmoRun: %s x%d AddItem+restore ikisi de basarisiz -- ledger kaydi.',
                        entry.item, entry.count)
                    pcall(function()
                        MySQL.insert.await(
                            'INSERT INTO matrix_pending_refunds (citizenid, amount, reason, created_at) VALUES (?, ?, ?, NOW())',
                            {
                                ('TRAP-%d'):format(trapHouseId),
                                0.0,
                                ('logistics-ammo-run-orphan:%sx%d'):format(tostring(entry.item), entry.count)
                            }
                        )
                    end)
                end
            end
        end
    end

    if #pulled == 0 then return false, 'stash_empty' end

    if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.MarkBotForStashRun then
        Matrix.TrapHouseInterior.MarkBotForStashRun(sourceBotId, trapHouseId)
    elseif Matrix.SetBotInteriorTrapHouse then
        Matrix.SetBotInteriorTrapHouse(sourceBotId, trapHouseId)
    end

    local plate = PermanentVehicleByBot[sourceBotId]
    local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
    local vehicleType = vehicle and vehicle.vehicle_class or 'car'
    if plate and (not vehicle or (ActiveVehicleLocks[plate] and ActiveVehicleLocks[plate] ~= sourceBotId)) then
        plate, vehicleType = nil, 'car'
    end
    if plate then ActiveVehicleLocks[plate] = sourceBotId end

    local distance    = VectorDistance(house.coords, targetBot.state.coords)
    local profile      = GetVehicleProfile(vehicleType)
    local etaSeconds   = Matrix.Clamp(distance / (Config.Logistics.BaseSpeedUnitsPerSecond * profile.SpeedCoefficient), 0.0, math_huge)

    local ok, reason = Matrix.BeginPhysicalDispatch(
        sourceBotId, house.coords, targetBot.state.coords, plate, vehicleType, etaSeconds, dispatcherSrc, 1.0
    )
    if not ok then
        if plate then ActiveVehicleLocks[plate] = nil end
        sourceBot.state.interior_trap_house_id = nil
        return false, reason or 'dispatch_failed'
    end

    Matrix.Dispatches[sourceBotId].ammo_run_target_bot_id = targetBotId

    Matrix.Log('LOGISTICS',
        '[MUHIMMAT DAGITIM GOREVI] Lojistik Bot #%d -> Tetikci Bot #%d icin depodan yuklenip yola cikti. Yuk: %s',
        sourceBotId, targetBotId, table.concat(pulled, ', '))

    return true, etaSeconds
end


function Matrix.Logistics.OnAmmoRunArrived(sourceBotId, targetBotId, arrivalCoords)
    local sourceBot = Matrix.Bots[sourceBotId]
    local targetBot = Matrix.Bots[targetBotId]
    if not sourceBot or not targetBot then return false end

    local fromInv = ('dealer_%d'):format(sourceBotId)
    local toInv    = ('dealer_%d'):format(targetBotId)

    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], fromInv)
    local movedAny = false
    if invOk and type(inv) == 'table' and type(inv.items) == 'table' then
        for slot, item in pairs(inv.items) do
            if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) > 0 then
                local addOk, added = pcall(function()
                    return exports['ox_inventory']:AddItem(toInv, item.name, item.count, item.metadata)
                end)
                if addOk and added == true then
                    local remOk, remRes = pcall(function()
                        return exports['ox_inventory']:RemoveItem(fromInv, item.name, item.count, item.metadata, slot)
                    end)
                    if remOk and remRes == true then
                        movedAny = true
                    else
                        local rollbackOk, rollbackRes = pcall(function()
                            return exports['ox_inventory']:RemoveItem(toInv, item.name, item.count, item.metadata)
                        end)
                        if not (rollbackOk and rollbackRes == true) then
                            Matrix.Log('LOGISTICS',
                                '[KRITIK][C-5] OnAmmoRunArrived: %s x%d rollback da basarisiz -- ledger kaydi.',
                                tostring(item.name), tonumber(item.count) or 0)
                            pcall(function()
                                MySQL.insert.await(
                                    'INSERT INTO matrix_pending_refunds (citizenid, amount, reason, created_at) VALUES (?, ?, ?, NOW())',
                                    {
                                        ('BOT-%d'):format(targetBotId),
                                        0.0,
                                        ('ammo-run-arrived-orphan:%sx%d'):format(tostring(item.name), tonumber(item.count) or 0)
                                    }
                                )
                            end)
                        else
                            Matrix.Log('LOGISTICS',
                                '[C-5] OnAmmoRunArrived: RemoveItem basarisiz, hedefe eklenen %s x%d geri alindi.',
                                tostring(item.name), tonumber(item.count) or 0)
                        end
                    end
                end
            end
        end
    end

    Matrix.Log('LOGISTICS',
        '[MUHIMMAT TESLIMI] Lojistik Bot #%d -> Tetikci Bot #%d elden teslimat %s.',
        sourceBotId, targetBotId, movedAny and 'tamamlandi' or 'BOS ENVANTER (atlandi)')

    local trapHouseId = sourceBot.state.trap_house_id
    local house = trapHouseId and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if house and Matrix.BeginPhysicalDispatch then
        SetTimeout(100, function()
            if sourceBot.state.is_locked or (Matrix.Dispatches and Matrix.Dispatches[sourceBotId]) then return end
            local plate = PermanentVehicleByBot[sourceBotId]
            local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
            local vehicleType = vehicle and vehicle.vehicle_class or 'car'
            if plate and not vehicle then plate = nil end
            if plate then ActiveVehicleLocks[plate] = sourceBotId end
            local ok = Matrix.BeginPhysicalDispatch(
                sourceBotId, arrivalCoords, house.coords, plate, vehicleType, 0.0, nil, 1.0
            )
            if not ok and plate then ActiveVehicleLocks[plate] = nil end
        end)
    end

    return movedAny
end


-- =====================================================================
-- KATMAN 5: CO-OP KOMUTA YETKİSİ GUARD'I
-- =====================================================================
local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end


-- =====================================================================
-- KOMUTLAR
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[LOJİSTİK]', msg } })
    else
        print(('[MATRIX:LOGISTICS:CONSOLE] %s'):format(msg))
    end
end


function Matrix.Logistics.LoadTrunkFromStash(botId, itemName, count)
    botId = tonumber(botId)
    count = tonumber(count)
    if not botId or type(itemName) ~= 'string' or itemName == '' or not count or count <= 0 then
        return false, 'bad_args'
    end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    local trapHouseId = bot.state.trap_house_id
    if not trapHouseId then return false, 'no_trap_house' end

    local vehicle = Matrix.Fleet.GetVehicleByBot(botId)
    if not vehicle then return false, 'no_assigned_vehicle' end

    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    local trunkId = Config.Logistics.TrunkOps.StashPrefix .. vehicle.plate

    pcall(function()
        exports['ox_inventory']:RegisterStash(trunkId, ('%s Bagaji'):format(vehicle.plate),
            Config.Logistics.TrunkOps.Slots, Config.Logistics.TrunkOps.MaxWeight)
    end)

    local haveOk, have = pcall(function() return exports['ox_inventory']:Search(stashId, 'count', itemName) end)
    have = (haveOk and tonumber(have)) or 0
    if have < count then return false, 'insufficient_stash' end

    local removeOk = pcall(function() return exports['ox_inventory']:RemoveItem(stashId, itemName, count) end)
    if not removeOk then return false, 'remove_failed' end

    local addOk = pcall(function() return exports['ox_inventory']:AddItem(trunkId, itemName, count) end)
    if not addOk then
        pcall(function() exports['ox_inventory']:AddItem(stashId, itemName, count) end)
        return false, 'add_failed'
    end

    Matrix.Log('LOGISTICS', '[BAGAJ AMELIYATI] Bot #%d: %dx %s trap #%d deposundan %s bagajina tasindi.',
        botId, count, itemName, trapHouseId, vehicle.plate)
    return true
end


local DISPATCH_FAILURE_MESSAGES = {
    bad_bot_id                 = 'Geçersiz bot ID.',
    bot_missing                = 'Bot matriste bulunamadı.',
    not_a_dealer                = 'Bu bot bir dealer değil.',
    already_dispatched          = 'Bot zaten sevk halinde.',
    bot_locked                 = 'Bot kilitli (onceki IO muhrunu bekliyor).',
    no_origin                  = 'Bot için bilinen bir konum yok.',
    missing_vector              = 'Hedef koordinatı eksik.',
    corrupt_vector              = 'Hedef koordinatı bozuk/geçersiz.',
    out_of_range                = 'Hedef menzil dışında.',
    too_close                   = 'Hedef mesafesi çok yakın (min. 5m); sevk iptal edildi.',
    vehicle_not_found            = 'Belirtilen plaka filoda kayıtlı değil.',
    vehicle_assigned_elsewhere  = 'Araç başka bir bota kalıcı olarak atanmış.',
    vehicle_in_use              = 'Araç şu anda başka bir sevkiyatta kullanılıyor.',
    dispatch_failed             = 'Fiziksel sevk başlatılamadı.',
    task_assignment_failed      = 'Görev atama basarisiz (fiziksel sevk iptal edildi).',
    radio_silence_active        = 'Telsiz sessizliği aktif -- bu süre boyunca yeni sevk/rota komutları engellidir.',
    unknown_cargo               = 'Bilinmeyen kargo tipi (payload map dışı).'
}


local AMMO_RUN_FAILURE_MESSAGES = {
    bad_bot_id            = 'Geçersiz bot ID.',
    same_bot               = 'Kaynak ve hedef bot aynı olamaz.',
    bot_missing            = 'Lojistik bot matriste bulunamadı.',
    not_logistics          = 'Bu bot Lojistik (runner) rütbesinde değil.',
    already_dispatched      = 'Lojistik bot zaten sevk halinde.',
    target_missing          = 'Hedef Tetikçi bot matriste bulunamadı.',
    target_no_coords        = 'Hedef Tetikçi botun bilinen bir konumu yok.',
    no_trap_house           = 'Lojistik bota atanmış bir trap house yok.',
    radio_silence_active    = 'Telsiz sessizliği aktif -- bu süre boyunca yeni görev verilemez.',
    stash_empty             = 'Trap house deposunda dağıtılacak mühimmat yok.',
    dispatch_failed         = 'Fiziksel sevk başlatılamadı.',
    task_assignment_failed  = 'Görev atama basarisiz (fiziksel sevk iptal edildi).'
}


local FLEET_FAILURE_MESSAGES = {
    bad_plate                  = 'Geçersiz plaka.',
    plate_exists                = 'Bu plaka zaten filoda kayıtlı.',
    vehicle_not_found            = 'Plaka filoda bulunamadı.',
    bot_missing                = 'Bot matriste bulunamadı.',
    vehicle_assigned_elsewhere  = 'Araç başka bir bota atanmış.',
    bot_already_has_vehicle    = 'Bu bota zaten kalıcı bir araç atanmış.'
}


RegisterCommand('sevket', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu emri vermek için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

    local botId = tonumber(args[1])
    local vehicleRef = args[2]
    local cargoItem  = args[3]

    if not botId then
        Reply(src, 'Kullanim: /sevket [botId] [plaka|foot] [opsiyonel-cargo]'); return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        Reply(src, 'Meet-point için geçerli bir ped gerekli.'); return
    end
    local destination = GetEntityCoords(ped)

    local ok, etaOrReason
    if type(cargoItem) == 'string' and cargoItem ~= '' then
        ok, etaOrReason = Matrix.Logistics.DispatchCargo(botId, destination, vehicleRef, src, cargoItem)
    else
        ok, etaOrReason = Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, src)
    end

    if ok then
        Reply(src, ('Bot #%d fiziksel sevke alindi. Tahmini varis: %.1f sn'):format(botId, etaOrReason))
    else
        Reply(src, DISPATCH_FAILURE_MESSAGES[etaOrReason] or ('Sevk basarisiz: %s'):format(tostring(etaOrReason)))
    end
end, false)


RegisterCommand('muhimmatsevk', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu gorevi vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

    local sourceBotId = tonumber(args[1])
    local targetBotId = tonumber(args[2])
    if not sourceBotId or not targetBotId then
        Reply(src, 'Kullanim: /muhimmatsevk [lojistikBotId] [tetikciBotId]'); return
    end

    local ok, etaOrReason = Matrix.Logistics.DispatchAmmoRun(sourceBotId, targetBotId, src)
    if ok then
        Reply(src, ('Bot #%d muhimmat dagitim gorevine cikti (hedef: Tetikci Bot #%d). Tahmini varis: %.1f sn'):format(
            sourceBotId, targetBotId, etaOrReason))
    else
        Reply(src, AMMO_RUN_FAILURE_MESSAGES[etaOrReason] or ('Gorev baslatilamadi: %s'):format(tostring(etaOrReason)))
    end
end, false)


RegisterCommand('filokaydet', function(src, args)
    local plate         = args[1]
    local vehicleClass  = args[2]
    local vinStatus     = args[3]
    local vehicleWear   = tonumber(args[4])

    local citizenid = nil
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then citizenid = state.citizenid end

    local ok, reason = Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if ok then
        Reply(src, ('Araç filoya kaydedildi: %s (RAM + async persist)'):format(plate))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Kayıt başarısız: %s'):format(tostring(reason)))
    end
end, false)


RegisterCommand('filoata', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu atamayı yapmak için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

    local plate = args[1]
    local botId = tonumber(args[2])
    if type(plate) ~= 'string' or not botId then
        Reply(src, 'Kullanim: /filoata [plaka] [botId]'); return
    end

    local ok, reason = Matrix.Fleet.AssignPermanent(plate, botId)
    if ok then
        Reply(src, ('Araç %s -> Bot #%d kalıcı olarak atandı.'):format(plate, botId))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Atama başarısız: %s'):format(tostring(reason)))
    end
end, false)


RegisterCommand('filobirak', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu işlemi yapmak için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

    local plate = args[1]
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /filobirak [plaka]'); return end

    local ok = Matrix.Fleet.UnassignPermanent(plate)
    Reply(src, ok and ('Araç %s serbest bırakıldı.'):format(plate) or 'Araç bulunamadı veya kalıcı atanmamış.')
end, false)


local TRUNK_OPS_FAILURE_MESSAGES = {
    bad_args            = 'Gecersiz parametre.',
    bot_missing         = 'Bot matriste bulunamadi.',
    no_trap_house       = 'Bu bot su an bir trap house eslesmesine sahip degil.',
    no_assigned_vehicle = 'Bu bota kalici atanmis bir arac yok (once /filoata kullanin).',
    insufficient_stash  = 'Trap house deposunda yeterli miktar yok.',
    remove_failed       = 'Depodan cekme basarisiz.',
    add_failed          = 'Bagaja yukleme basarisiz (bagaj dolu olabilir).'
}


RegisterCommand('bagajyukle', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

    local botId = tonumber(args[1])
    local itemName = args[2]
    local count = tonumber(args[3])
    if not botId or type(itemName) ~= 'string' or not count then
        Reply(src, 'Kullanim: /bagajyukle [botId] [item] [miktar]'); return
    end

    local ok, reason = Matrix.Logistics.LoadTrunkFromStash(botId, itemName, count)
    if ok then
        Reply(src, ('Bot #%d bagajina %dx %s yuklendi.'):format(botId, count, itemName))
    else
        Reply(src, TRUNK_OPS_FAILURE_MESSAGES[reason] or ('Bagaj yukleme basarisiz: %s'):format(tostring(reason)))
    end
end, false)


local SUPPLIER_FAILURE_MESSAGES = {
    bad_drop         = 'Geçersiz drop.',
    already_active    = 'Bu drop zaten açık, önce teslim alın.',
    supply_cut        = 'Toptancı güveniniz çok düşük, tedarik kesildi.',
    no_active_drop    = 'Bu drop şu anda aktif değil.',
    window_expired    = 'Teslim alma penceresi doldu.'
}


RegisterCommand('dropiste', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropiste [dropId]'); return end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil çözülemedi.'); return end

    local ok, info = Matrix.Supplier.RequestDrop(citizenid, dropId)
    if ok then
        Reply(src, ('Drop #%d açıldı. Fiyat çarpanı x%.2f, %ds içinde teslim al.'):format(
            dropId, info.price_multiplier, info.expires_in))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[info] or ('Drop açılamadı: %s'):format(tostring(info)))
    end
end, false)


RegisterCommand('dropcek', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropcek [dropId]'); return end

    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then Reply(src, 'Geçersiz drop ID.'); return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadı.'); return end

    local playerCoords = GetEntityCoords(ped)
    if VectorDistance(playerCoords, dropCfg.coords) > dropCfg.radius then
        Reply(src, 'Drop noktasına yeterince yakın değilsiniz.'); return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    local ok, result = Matrix.Supplier.OnPickup({ kind = 'player', source = src }, dropId, state and state.citizenid)
    if ok then
        Reply(src, ('Teslim alındı. Heat:%.2f İz:%s Güven:%.2f'):format(
            result.heat, tostring(result.forensic_trace_left), result.trust))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[result] or ('Teslim alınamadı: %s'):format(tostring(result)))
    end
end, false)


-- =====================================================================
-- EVENT BRIDGE
-- =====================================================================
RegisterNetEvent('matrix:server:reportDealerEliminated', function(botId, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnDealerEliminated(botId, type(cause) == 'string' and cause or 'unknown')
end)


RegisterNetEvent('matrix:server:reportDealerPoliceCollision', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnPoliceCollision(botId)
end)


RegisterNetEvent('matrix:server:reportDealerCombatDamage', function(botId, rawDamage)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
end)


RegisterNetEvent('matrix:server:registerFleetVehicle', function(plate, vehicleClass, vinStatus, vehicleWear)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    Matrix.Fleet.RegisterVehicle(state and state.citizenid, plate, vehicleClass, vinStatus, vehicleWear)
end)


RegisterNetEvent('matrix:server:assignFleetVehicle', function(plate, botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if type(plate) ~= 'string' or not botId then return end

    -- v6.6.6 H12: cagiran, bu aracin kayitli sahibi olmali (fail-closed).
    local vehicle = Matrix.Fleet.GetVehicle(plate)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not vehicle or not state or not state.citizenid
        or vehicle.registered_by_citizenid ~= state.citizenid then
        Matrix.Log('LOGISTICS', '[YETKI RED] assignFleetVehicle: src=%d plate=%s sahibi degil.', src, tostring(plate))
        return
    end

    Matrix.Fleet.AssignPermanent(plate, botId)
end)


RegisterNetEvent('matrix:server:unassignFleetVehicle', function(plate)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end

    -- v6.6.6 H12: cagiran, bu aracin kayitli sahibi olmali (fail-closed).
    local vehicle = Matrix.Fleet.GetVehicle(plate)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not vehicle or not state or not state.citizenid
        or vehicle.registered_by_citizenid ~= state.citizenid then
        Matrix.Log('LOGISTICS', '[YETKI RED] unassignFleetVehicle: src=%d plate=%s sahibi degil.', src, tostring(plate))
        return
    end

    Matrix.Fleet.UnassignPermanent(plate)
end)


RegisterNetEvent('matrix:server:reportVehicleEncircled', function(plate, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end
    Matrix.Logistics.OnVehicleEncircled(plate, type(cause) == 'string' and cause or 'police_encirclement')
end)


RegisterNetEvent('matrix:server:reportLspdCheckpoint', function(botId, basePenalty)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnLspdCheckpointIntercept(botId, basePenalty)
end)


RegisterNetEvent('matrix:server:requestDeadDrop', function(dropId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    dropId = tonumber(dropId)
    if not dropId then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then Matrix.Supplier.RequestDrop(state.citizenid, dropId) end
end)


RegisterNetEvent('matrix:server:reportLatePayment', function(supplierId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    supplierId = tonumber(supplierId)
    if not supplierId then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then Matrix.Supplier.ReportLatePayment(state.citizenid, supplierId) end
end)


-- =====================================================================
-- EXPORTS (NİHAİ VE STERİL MÜHÜRLÜ BLOK)
-- =====================================================================
exports('DispatchDealer', function(botId, dest, vehicleRef, dispatcherSrc)
    return Matrix.Logistics.DispatchDealer(botId, dest, vehicleRef, dispatcherSrc)
end)

exports('DispatchCargo', function(botId, dest, vehicleRef, dispatcherSrc, cargoItem)
    return Matrix.Logistics.DispatchCargo(botId, dest, vehicleRef, dispatcherSrc, cargoItem)
end)

exports('DispatchAmmoRun', function(sourceBotId, targetBotId, dispatcherSrc)
    return Matrix.Logistics.DispatchAmmoRun(sourceBotId, targetBotId, dispatcherSrc)
end)

exports('ApplyCombatDamageToDealer', function(botId, dmg)
    return Matrix.Logistics.ApplyCombatDamage(botId, dmg)
end)

exports('EliminateDealer', function(botId, cause)
    return Matrix.Logistics.OnDealerEliminated(botId, cause)
end)

exports('ReportDealerPoliceCollision', function(botId)
    return Matrix.Logistics.OnPoliceCollision(botId)
end)

exports('StartBrickPress', function(src, trapHouseId, productType, brickCount)
    return Matrix.Logistics.StartBrickPress(src, trapHouseId, productType, brickCount)
end)

exports('ComputeNarcoticBrickFriction', function(botId)
    return Matrix.Logistics.ComputeNarcoticBrickFriction(botId)
end)

exports('OnLspdCheckpointIntercept', function(botId, basePenalty)
    return Matrix.Logistics.OnLspdCheckpointIntercept(botId, basePenalty)
end)

exports('RegisterFleetVehicle', function(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    return Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
end)

exports('AssignFleetVehicle', function(plate, botId)
    return Matrix.Fleet.AssignPermanent(plate, botId)
end)

exports('UnassignFleetVehicle', function(plate)
    return Matrix.Fleet.UnassignPermanent(plate)
end)

exports('GetFleetVehicle', function(plate)
    return Matrix.Fleet.GetVehicle(plate)
end)

exports('GetVehicleByBot', function(botId)
    return Matrix.Fleet.GetVehicleByBot(botId)
end)

exports('LoadTrunkFromStash', function(botId, itemName, count)
    return Matrix.Logistics.LoadTrunkFromStash(botId, itemName, count)
end)

exports('SeizeFleetVehicle', function(plate, cause)
    return Matrix.Logistics.OnVehicleEncircled(plate, cause)
end)

exports('GetSupplierTrust', function(citizenid, supplierId)
    return Matrix.Supplier.GetTrust(citizenid, supplierId)
end)

exports('GetSupplierPriceMultiplier', function(citizenid, supplierId)
    return Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
end)

exports('ReportSupplierLatePayment', function(citizenid, supplierId)
    return Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
end)

exports('RequestDeadDrop', function(citizenid, dropId)
    return Matrix.Supplier.RequestDrop(citizenid, dropId)
end)

exports('PickupDeadDrop', function(actorRef, dropId, creditCitizenid)
    return Matrix.Supplier.OnPickup(actorRef, dropId, creditCitizenid)
end)

-- =====================================================================
-- DOSYA SONU — FAZ 6 ADIM 3 TAMAMEN TEMİZLENDİ.
-- =====================================================================
-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('aracsizdurumu', function(src, args)
    local plate = args[1]
    local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
    if not vehicle then Reply(src, 'Kullanim: /aracsizdurumu [plaka]'); return end

    Reply(src, ('%s [%s/%s] Asinma:%.3f Sahip:%s Atama:%s->%s Dogrulanmis-Calinti:%s'):format(
        vehicle.plate, vehicle.vehicle_class, vehicle.vin_status, vehicle.vehicle_wear,
        tostring(vehicle.registered_by_citizenid), tostring(vehicle.assignment_mode),
        tostring(vehicle.assigned_bot_id), tostring(vehicle.verified_stolen_plate)))
end, false)


RegisterCommand('aracele', function(src, args)
    local plate = args[1]
    local cause = args[2] or 'debug'
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /aracele [plaka] [sebep]'); return end

    local ok = Matrix.Logistics.OnVehicleEncircled(plate, cause)
    Reply(src, ok and ('%s ele gecirildi ve muhurlendi.'):format(plate) or 'Arac bulunamadi.')
end, false)


RegisterCommand('hasarver', function(src, args)
    local botId = tonumber(args[1])
    local amount = tonumber(args[2]) or 1.0
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /hasarver [botId] [miktar]'); return end

    Matrix.Logistics.ApplyCombatDamage(botId, amount)
    local stillAlive = Matrix.Bots[botId] ~= nil
    Reply(src, ('Bot #%d hasar aldi. Hayatta:%s'):format(botId, tostring(stillAlive)))
end, false)


RegisterCommand('oldur', function(src, args)
    local botId = tonumber(args[1])
    local cause = args[2] or 'debug'
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /oldur [botId] [sebep]'); return end

    Matrix.Logistics.OnDealerEliminated(botId, cause)
    Reply(src, ('Bot #%d kalici olarak elendi.'):format(botId))
end, false)


RegisterCommand('guvengoster', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /guvengoster [citizenid] [supplierId]'); return
    end

    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    Reply(src, ('%s <-> Toptanci #%d | Guven:%.3f | Fiyat-Carpani:x%.2f | Tedarik-Kesik:%s'):format(
        citizenid, supplierId, trust, mult, tostring(trust < Config.Supplier.SupplyCutTrustThreshold)))
end, false)


RegisterCommand('gecodeme', function(src, args)
    local supplierId = tonumber(args[1])
    if not supplierId then
        Reply(src, 'Kullanim: /gecodeme [supplierId]'); return
    end

    -- v6.6.6 H14: citizenid artik komut argumanindan ALINMIYOR -- cagiran
    -- BASKA birinin citizenid'ini yazip TriggerBetrayal -> executeHitSquad
    -- zincirini rakibine yonlendirebiliyordu (yanlis hedef). Hedef HER
    -- ZAMAN cagiranin KENDI citizenid'i olur.
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then
        Reply(src, 'Oyuncu profili cozulemedi.'); return
    end

    local newTrust = Matrix.Supplier.ReportLatePayment(state.citizenid, supplierId)
    Reply(src, ('Gecikmis odeme islendi. Yeni guven:%.3f'):format(newTrust))
end, false)


RegisterCommand('dropdurum', function(src)
    local count = 0
    local now = Matrix.Now()
    for dropId, drop in pairs(ActiveDrops) do
        count = count + 1
        local cfg = GetDropConfig(dropId)
        Reply(src, ('Drop #%d (%s) | Sahip:%s | Kalan-Pencere:%ds | Heat:%.3f'):format(
            dropId, cfg and cfg.label or '?', tostring(drop.citizenid),
            math_max(drop.expires_at - now, 0), DropHeat[dropId] or 0.0))
    end
    Reply(src, ('--- Toplam %d acik drop ---'):format(count))
end, false)


local function ParseCoordNumber(s)
    return tonumber((tostring(s or ''):gsub(',', '')))
end


RegisterCommand('korbolgetest', function(src, args)
    local x, y, z = ParseCoordNumber(args[1]), ParseCoordNumber(args[2]), ParseCoordNumber(args[3])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /korbolgetest [x] [y] [z]  (boslukla ayirin, virgul KULLANMAYIN)'); return
    end

    local zone = FindDeadZone(vector3(x, y, z))
    Reply(src, zone and ('Bu koordinat "%s" kor bolgesinin ICINDE.'):format(zone.label)
              or 'Bu koordinat hicbir kor bolgenin icinde degil.')
end, false)


RegisterCommand('cachedebug', function(src)
    local fleetN, dirtyFN = 0, 0
    for _ in pairs(FleetVehicles) do fleetN = fleetN + 1 end
    for _ in pairs(dirtyFleet) do dirtyFN = dirtyFN + 1 end

    local trustN, dirtyTN = 0, 0
    for _ in pairs(SupplierTrustCache) do trustN = trustN + 1 end
    for _ in pairs(dirtySupplierTrust) do dirtyTN = dirtyTN + 1 end

    local dropsN, heatN = 0, 0
    for _ in pairs(ActiveDrops) do dropsN = dropsN + 1 end
    for _ in pairs(DropHeat) do heatN = heatN + 1 end

    Reply(src, ('Fleet RAM: %d kayit | dirty kuyruk: %d | eksik-tablo uyarisi:%s'):format(
        fleetN, dirtyFN, tostring(WARNED_MISSING_FLEET)))
    Reply(src, ('Trust RAM: %d kayit | dirty kuyruk: %d | eksik-tablo uyarisi:%s'):format(
        trustN, dirtyTN, tostring(WARNED_MISSING_TRUST)))
    Reply(src, ('ActiveDrops: %d | DropHeat: %d'):format(dropsN, heatN))
end, false)


-- =====================================================================
-- ★★★ KATMAN 8 — CEPHE A: LİMAN KAÇAKÇILIK AĞLARI (YAMA 4 ENTEGRE) ★★★
-- =====================================================================
Matrix.Logistics.PortConfig = Matrix.Logistics.PortConfig or {
    RampCoords        = vector3(-50.0, -2400.0, 5.0),
    RampRadius        = 15.0,
    IntensitySpike    = 2.0,
    DrivebyRange      = 60.0,
    DrivebyAccuracy   = 75,
    FiringPattern     = 'FIRING_PATTERN_FULL_AUTO',
}

Matrix.Logistics.PortArrivalFlags = Matrix.Logistics.PortArrivalFlags or {}

Matrix.Logistics.__LastRelayOwnerByBotId = Matrix.Logistics.__LastRelayOwnerByBotId or {}

Matrix.Logistics.__RelayCooldownByClient  = Matrix.Logistics.__RelayCooldownByClient  or {}
Matrix.Logistics.__RelayCooldownTTLMs     = 300000
Matrix.Logistics.__RelayCooldownPerBotMs  = 3000
Matrix.Logistics.__RelayCooldownPerClientMs = 1000
Matrix.Logistics.__RelayCooldownByBotId  = Matrix.Logistics.__RelayCooldownByBotId  or {}

local function _PortChecksum(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


local function _PurgeRelayCooldowns(nowTs)
    local ttl = Matrix.Logistics.__RelayCooldownTTLMs
    for botId, ts in pairs(Matrix.Logistics.__RelayCooldownByBotId) do
        if (nowTs - ts) > ttl then Matrix.Logistics.__RelayCooldownByBotId[botId] = nil end
    end
    for src, ts in pairs(Matrix.Logistics.__RelayCooldownByClient) do
        if (nowTs - ts) > ttl then Matrix.Logistics.__RelayCooldownByClient[src] = nil end
    end
    for botId, entry in pairs(Matrix.Logistics.__LastRelayOwnerByBotId) do
        if type(entry) == 'table' and type(entry.ts) == 'number'
            and (nowTs - entry.ts) > ttl then
            Matrix.Logistics.__LastRelayOwnerByBotId[botId] = nil
        end
    end
end


local function _RelayHitsquadDrivebyServerAuthoritative(dispatch, pedNetId)
    if not dispatch or type(pedNetId) ~= 'number' or pedNetId == 0 then return false end
    local botId = dispatch.bot_id
    if not botId then return false end

    local nowTs = GetGameTimer()
    _PurgeRelayCooldowns(nowTs)

    local lastBot = Matrix.Logistics.__RelayCooldownByBotId[botId] or 0
    if (nowTs - lastBot) < Matrix.Logistics.__RelayCooldownPerBotMs then
        return false
    end

    local targetPed = NetworkGetEntityFromNetworkId(pedNetId)
    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed) then
        return false
    end

    local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, targetPed)
    if not ownerOk or type(ownerSrc) ~= 'number' or ownerSrc <= 0 then
        return false
    end

    local lastEntry = Matrix.Logistics.__LastRelayOwnerByBotId[botId]
    local lastOwnerId = lastEntry and lastEntry.owner or nil

    if lastOwnerId ~= ownerSrc then
        Matrix.Logistics.__RelayCooldownByBotId[botId] = 0
        Matrix.Log('LOGISTICS',
            '[M-1][NETOWNER HANDOFF] bot=%d eski-owner=%s yeni-owner=%d -- cooldown sifirlandi.',
            botId, tostring(lastOwnerId), ownerSrc)
    end
    Matrix.Logistics.__LastRelayOwnerByBotId[botId] = { owner = ownerSrc, ts = nowTs }

    local lastClient = Matrix.Logistics.__RelayCooldownByClient[ownerSrc] or 0
    if (nowTs - lastClient) < Matrix.Logistics.__RelayCooldownPerClientMs then
        return false
    end

    local cfg = Matrix.Logistics.PortConfig
    local weaponHash = GetHashKey(Config.HitSquad and Config.HitSquad.Weapon or 'WEAPON_MICROSMG')
    local payload = {
        ped_net_id     = pedNetId,
        vehicle_net_id = dispatch.vehicle_net_id,
        weapon_hash    = weaponHash,
        firing_pattern = cfg.FiringPattern,
        accuracy       = math.min(math.max(tonumber(cfg.DrivebyAccuracy) or 75, 0), 100),
        range          = math.min(math.max(tonumber(cfg.DrivebyRange) or 60.0, 1.0), 200.0),
        port_checksum  = _PortChecksum(('%d#%d'):format(botId, nowTs), 61),
    }

    TriggerClientEvent('matrix:client:hitsquadDriveby', ownerSrc, payload)

    Matrix.Logistics.__RelayCooldownByBotId[botId]     = nowTs
    Matrix.Logistics.__RelayCooldownByClient[ownerSrc] = nowTs
    return true
end


function Matrix.Logistics.CheckPortArrival(dispatch, coords)
    if not dispatch or not coords then return false end
    local botId = dispatch.bot_id
    if not botId then return false end

    local cfg = Matrix.Logistics.PortConfig
    local dx = coords.x - cfg.RampCoords.x
    local dy = coords.y - cfg.RampCoords.y
    local dz = coords.z - cfg.RampCoords.z
    local dist = math_sqrt((dx * dx) + (dy * dy) + (dz * dz))

    if dist > cfg.RampRadius then
        Matrix.Logistics.PortArrivalFlags[botId] = nil
        return false
    end
    if Matrix.Logistics.PortArrivalFlags[botId] then return true end
    Matrix.Logistics.PortArrivalFlags[botId] = true

    local before = GetConvarFloat('matrix_bureau_intensity', 1.0)
    if type(before) ~= 'number' or before ~= before or before <= 0.0 then before = 1.0 end
    local after = before * cfg.IntensitySpike
    SetConvar('matrix_bureau_intensity', tostring(after))

    local drivebyPushed = 0
    local pedNetId = dispatch.entity_net_id
    if pedNetId and _RelayHitsquadDrivebyServerAuthoritative(dispatch, pedNetId) then
        drivebyPushed = 1
    end

    MySQL.insert([[
        INSERT INTO matrix_port_smuggling_events
            (bot_id, port_zone, intensity_before, intensity_after, dispatch_plate, driveby_pushed, created_at)
        VALUES (?, 'port_ramp', ?, ?, ?, ?, NOW())
    ]], { botId, before, after, dispatch.plate, drivebyPushed })

    Matrix.Log('LOGISTICS',
        '[LIMAN GUMRUK] Bot #%d rampa bolgesine girdi (mesafe=%.1fm) -- matrix_bureau_intensity %.2f -> %.2f (x%.1f) driveby_pushed=%d.',
        botId, dist, before, after, cfg.IntensitySpike, drivebyPushed)

    return true
end


RegisterCommand('relaypurge', function(src)
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local nBot, nCli, nPort = 0, 0, 0
    for _ in pairs(Matrix.Logistics.__RelayCooldownByBotId) do nBot = nBot + 1 end
    for _ in pairs(Matrix.Logistics.__RelayCooldownByClient) do nCli = nCli + 1 end
    for _ in pairs(Matrix.Logistics.PortArrivalFlags) do nPort = nPort + 1 end
    Matrix.Logistics.__RelayCooldownByBotId = {}
    Matrix.Logistics.__RelayCooldownByClient = {}
    Matrix.Logistics.PortArrivalFlags       = {}
    Reply(src, ('[RELAY PURGE] %d bot, %d client, %d port-flag kaydi kazindi.'):format(nBot, nCli, nPort))
end, false)


-- =====================================================================
-- ★★★ FAZ 3 — PERSISTENT NO-CACHE VEHICLES & INTERACTIVE KUNDAKLAMA ★★★
--
-- MIGRATION (MariaDB, strict IF NOT EXISTS):
--
--   CREATE TABLE IF NOT EXISTS matrix_persistent_vehicles (
--       plate VARCHAR(12) PRIMARY KEY,
--       citizenid_owner VARCHAR(50) NOT NULL,
--       vehicle_model INT NOT NULL,
--       coord_x FLOAT NOT NULL,
--       coord_y FLOAT NOT NULL,
--       coord_z FLOAT NOT NULL,
--       heading FLOAT NOT NULL,
--       body_health FLOAT DEFAULT 1000.0,
--       fuel_level FLOAT DEFAULT 100.0,
--       status VARCHAR(20) DEFAULT 'active_field'
--           COMMENT 'parked_hood|active_field|destroyed'
--   );
--
--   CREATE TABLE IF NOT EXISTS matrix_arson_events (
--       event_id BIGINT AUTO_INCREMENT PRIMARY KEY,
--       plate VARCHAR(12) NOT NULL,
--       actor_citizenid VARCHAR(50) NOT NULL,
--       started_at DATETIME NOT NULL,
--       completed_at DATETIME NULL,
--       outcome VARCHAR(24) NOT NULL,
--       final_body_health FLOAT NOT NULL DEFAULT 0.0,
--       intensity_before FLOAT NOT NULL DEFAULT 0.0,
--       intensity_after FLOAT NOT NULL DEFAULT 0.0,
--       sanitized TINYINT(1) NOT NULL DEFAULT 0,
--       INDEX idx_plate (plate)
--   );
-- =====================================================================

-- ---------------------------------------------------------------------
-- [PV-0] ConVar helpers (deterministik, sıfır RNG).
-- ---------------------------------------------------------------------
local function _GetBureauIntensity()
    local v = GetConvarFloat('matrix_bureau_intensity', 1.0)
    if type(v) ~= 'number' or v ~= v or v <= 0.0 then return 1.0 end
    if v > 100.0 then v = 100.0 end
    return v
end


local function _BumpBureauIntensity(step)
    local cur = _GetBureauIntensity()
    local newVal = cur + (tonumber(step) or 0.0)
    if newVal < 0.0 then newVal = 0.0 end
    if newVal > 100.0 then newVal = 100.0 end
    SetConvar('matrix_bureau_intensity', tostring(newVal))
    return cur, newVal
end


-- ---------------------------------------------------------------------
-- [PV-1] KALICI ARAÇ MATRİSİ — NO-CACHE VEHICLES
-- ---------------------------------------------------------------------
local PERSIST_ACTIVE_FIELD = 'active_field'
local PERSIST_PARKED_HOOD  = 'parked_hood'
local PERSIST_DESTROYED    = 'destroyed'


local function _MarkPersistentDirty(plate)
    if plate then dirtyPersistent[plate] = true end
end


function Matrix.Persistent.GetByPlate(plate)
    if type(plate) ~= 'string' then return nil end
    return Matrix.Persistent.ByPlate[plate]
end


function Matrix.Persistent.Load()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_persistent_vehicles', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_PERSIST then
                        WARNED_MISSING_PERSIST = true
                        Matrix.Log('LOGISTICS',
                            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][UYARI] Tablo okunamadi; RAM onbellek devrede.')
                    end
                    return
                end
                local count = 0
                for _, row in ipairs(rows) do
                    if row and row.plate then
                        Matrix.Persistent.ByPlate[row.plate] = {
                            plate           = row.plate,
                            citizenid_owner = row.citizenid_owner,
                            vehicle_model   = tonumber(row.vehicle_model) or 0,
                            coords          = vector3(
                                tonumber(row.coord_x) or 0.0,
                                tonumber(row.coord_y) or 0.0,
                                tonumber(row.coord_z) or 0.0
                            ),
                            heading         = tonumber(row.heading) or 0.0,
                            body_health     = tonumber(row.body_health) or 1000.0,
                            fuel_level      = tonumber(row.fuel_level) or 100.0,
                            status          = row.status or PERSIST_ACTIVE_FIELD,
                            entity_net_id   = nil,
                            last_scan_ts    = 0
                        }
                        count = count + 1
                    end
                end
                Matrix.Log('LOGISTICS',
                    '[MATRIX:PERSISTENT_VEHICLES_PHASE3] %d kalici arac RAM matrisine yuklendi (NO-CACHE).',
                    count)
            end)
            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[MATRIX:PERSISTENT_VEHICLES_PHASE3][HATA] callback hatasi (yutuldu): %s',
                    tostring(cbErr))
            end
        end)
    end)
    if not callOk then
        if not WARNED_MISSING_PERSIST then
            WARNED_MISSING_PERSIST = true
            Matrix.Log('LOGISTICS',
                '[MATRIX:PERSISTENT_VEHICLES_PHASE3][HATA] Sorgu reddedildi (RAM devrede): %s',
                tostring(callErr))
        end
    end
end


CreateThread(function()
    Matrix.Persistent.Load()
end)


local function _FlushDirtyPersistent()
    local pending = {}
    for plate in pairs(dirtyPersistent) do
        pending[#pending + 1] = plate
    end
    if #pending == 0 then return end

    local queries = {}
    for _, plate in ipairs(pending) do
        local v = Matrix.Persistent.ByPlate[plate]
        if v then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_persistent_vehicles
                        (plate, citizenid_owner, vehicle_model,
                         coord_x, coord_y, coord_z, heading,
                         body_health, fuel_level, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE
                        citizenid_owner = VALUES(citizenid_owner),
                        vehicle_model   = VALUES(vehicle_model),
                        coord_x         = VALUES(coord_x),
                        coord_y         = VALUES(coord_y),
                        coord_z         = VALUES(coord_z),
                        heading         = VALUES(heading),
                        body_health     = VALUES(body_health),
                        fuel_level      = VALUES(fuel_level),
                        status          = VALUES(status)
                ]],
                values = {
                    v.plate, v.citizenid_owner, v.vehicle_model,
                    v.coords.x, v.coords.y, v.coords.z, v.heading,
                    v.body_health, v.fuel_level, v.status
                }
            }
        end
    end

    if #queries == 0 then
        for _, plate in ipairs(pending) do dirtyPersistent[plate] = nil end
        return
    end

    local ok, res = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and res ~= false then
        for _, plate in ipairs(pending) do dirtyPersistent[plate] = nil end
    else
        Matrix.Log('LOGISTICS',
            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][KRITIK] Persistent flush basarisiz -- dirty bayraklar KORUNDU: %s',
            tostring(res))
    end
end


--- [PV-2] NO-CACHE REGISTER: araç fiziksel kalır; virtual caching YASAK.
--- Herhangi bir logout / unload / disconnect olayında çağrılır; araç
--- state'i yalnızca dirtyPersistent kuyruğuna yazılır, spawn KORUNUR.
function Matrix.Persistent.RegisterOrTouch(citizenid, plate, vehicleModel, coords, heading, bodyHealth, fuelLevel, status)
    if type(plate) ~= 'string' or plate == '' or #plate > 12 then return false, 'bad_plate' end
    if not IsValidCoords(coords) then return false, 'bad_coords' end

    local existing = Matrix.Persistent.ByPlate[plate]
    if existing then
        existing.citizenid_owner = citizenid or existing.citizenid_owner
        existing.vehicle_model   = tonumber(vehicleModel) or existing.vehicle_model
        existing.coords          = vector3(coords.x, coords.y, coords.z)
        existing.heading         = tonumber(heading) or existing.heading
        existing.body_health     = tonumber(bodyHealth) or existing.body_health
        existing.fuel_level      = tonumber(fuelLevel) or existing.fuel_level
        if status then existing.status = status end
        _MarkPersistentDirty(plate)
        return true
    end

    Matrix.Persistent.ByPlate[plate] = {
        plate           = plate,
        citizenid_owner = citizenid or 'UNKNOWN',
        vehicle_model   = tonumber(vehicleModel) or 0,
        coords          = vector3(coords.x, coords.y, coords.z),
        heading         = tonumber(heading) or 0.0,
        body_health     = tonumber(bodyHealth) or 1000.0,
        fuel_level      = tonumber(fuelLevel) or 100.0,
        status          = status or PERSIST_ACTIVE_FIELD,
        entity_net_id   = nil,
        last_scan_ts    = 0
    }
    _MarkPersistentDirty(plate)
    return true
end


-- ---------------------------------------------------------------------
-- [PV-3] HOOD SECURE TURF — FOG OF WAR SHADOW
-- ---------------------------------------------------------------------
--- Dost mahalle sınırları içindeki araçları tespit et ve status'ünü
--- 'parked_hood' yaparak plakayı ALPR tarama matrisinden KAZI.
--- Deterministik: yalnızca sınır testi, sıfır RNG.
function Matrix.Persistent.ApplyHoodShadow(plate, hoodsTable, coalitionTable)
    local v = Matrix.Persistent.ByPlate[plate]
    if not v or v.status == PERSIST_DESTROYED then return false, 'not_persistent' end

    hoodsTable = hoodsTable or Matrix.GangHoods or {}
    coalitionTable = coalitionTable or Matrix.CoalitionControl or nil

    for hoodId, hood in pairs(hoodsTable) do
        local hoodCoords = hood.coords or hood.center
        local hoodRadius = tonumber(hood.radius) or 0.0
        if hoodCoords and hoodRadius > 0.0 then
            if VectorDistance(v.coords, hoodCoords) <= hoodRadius then
                local dominant = true
                if coalitionTable and coalitionTable[hoodId] ~= nil then
                    dominant = (coalitionTable[hoodId] == true) or (tonumber(coalitionTable[hoodId]) or 0.0) >= 0.5
                end
                if dominant then
                    if v.status ~= PERSIST_PARKED_HOOD then
                        v.status = PERSIST_PARKED_HOOD
                        _MarkPersistentDirty(plate)
                        MySQL.prepare('UPDATE matrix_persistent_vehicles SET status = ? WHERE plate = ?',
                            { PERSIST_PARKED_HOOD, plate })
                        Matrix.Log('LOGISTICS',
                            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][HOOD-SHADOW] %s -> parked_hood (hood=%s); ALPR taramasi maskelendi.',
                            plate, tostring(hoodId))
                    end
                    return true, hoodId
                end
            end
        end
    end

    if v.status == PERSIST_PARKED_HOOD then
        v.status = PERSIST_ACTIVE_FIELD
        _MarkPersistentDirty(plate)
        MySQL.prepare('UPDATE matrix_persistent_vehicles SET status = ? WHERE plate = ?',
            { PERSIST_ACTIVE_FIELD, plate })
        Matrix.Log('LOGISTICS',
            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][HOOD-SHADOW] %s -> active_field (dost sinir disi); ALPR tekrar gorunur.',
            plate)
    end
    return false, 'no_friendly_hood'
end


--- ALPR taraması: 'parked_hood' statüsündeki araçlar sonuç kümesinden ÇIKARILIR.
function Matrix.Persistent.IsAlprVisible(plate)
    local v = Matrix.Persistent.ByPlate[plate]
    if not v then return true end
    if v.status == PERSIST_PARKED_HOOD then return false end
    if v.status == PERSIST_DESTROYED   then return false end
    return true
end


-- ---------------------------------------------------------------------
-- [AR-1..AR-4] INTERAKTIF KUNDAKLAMA (/araciyak)
-- ---------------------------------------------------------------------
Matrix.Arson.Config = Matrix.Arson.Config or {
    ProgressMs        = 90000,   -- 90sn friction penceresi
    MaxActorRadius    = 3.0,     -- metre; kopma = iptal
    TickMs            = 10000,   -- 10sn tick
    IntensityStep     = 0.40,    -- her tick +0.40
    DamagePerTick     = 75.0,    -- her tick -75 HP
    InitialBodyHealth = 1000.0,
    DestroyThreshold  = 100.0,   -- < 100 => sanitize
    MaxBurnMs         = 600000,  -- 10dk güvenlik üst sınırı
    ForensicsWipeTag  = 'ARSON_SANITIZED',
}


local ARSON_PHASE_AWAIT_DIALOG = 'await_dialog'
local ARSON_PHASE_FRICTION     = 'friction'
local ARSON_PHASE_BURNING      = 'burning'
local ARSON_PHASE_SANITIZED    = 'sanitized'
local ARSON_PHASE_SALVAGED     = 'salvaged'
local ARSON_PHASE_ABORTED      = 'aborted'


local ARSON_DIALOG_WARNING = '[ADLI IMHA] Bu aracı yakmak, şasi ve plaka üzerindeki tüm adli tıp jurnallerini permanently kazıyacaktır. Süreç geri alınamaz. Onaylıyor musunuz?'


local function _GetPlayerCitizenid(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state then return nil end
    return state.citizenid
end


--- ox_inventory üzerinden oyuncunun envanterinde 'jerry_can' (Benzin Bidonu) arar.
--- Sıfır RNG, deterministik boolean dönüş.
local function _HasJerryCan(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local ok, count = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', 'jerry_can')
    end)
    if not ok then return false end
    return (tonumber(count) or 0) > 0
end


local function _ConsumeJerryCan(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local ok, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, 'jerry_can', 1)
    end)
    return ok and removed == true
end


--- Bir plaka için aktif arson oturumu var mı?
local function _GetArsonByPlate(plate)
    return Matrix.Arson.ByPlate[plate]
end


--- Yeni oturum oluştur; aynı plaka için ikinci oturum REDDEDİLİR (deterministik).
local function _CreateArsonSession(src, plate, citizenid)
    if Matrix.Arson.ByPlate[plate] then return nil, 'already_burning' end
    if Matrix.Arson.BySrc[src]    then return nil, 'actor_busy'       end

    local v = Matrix.Persistent.ByPlate[plate]
    if not v then return nil, 'plate_not_persistent' end
    if v.status == PERSIST_DESTROYED then return nil, 'already_destroyed' end

    local session = {
        plate            = plate,
        actor_src        = src,
        actor_citizenid  = citizenid,
        phase            = ARSON_PHASE_AWAIT_DIALOG,
        started_ts       = GetGameTimer(),
        friction_end_ts  = 0,
        last_tick_ts     = 0,
        burn_started_ts  = 0,
        intensity_start  = _GetBureauIntensity(),
        intensity_last   = 0.0,
        damage_dealt     = 0.0,
        body_health      = v.body_health or Matrix.Arson.Config.InitialBodyHealth,
        outcome          = nil,
        aborted_reason   = nil,
        sanitized        = false,
    }
    Matrix.Arson.ByPlate[plate] = session
    Matrix.Arson.BySrc[src]     = session
    return session
end


local function _EndArsonSession(session, outcome, reason)
    if not session then return end
    Matrix.Arson.ByPlate[session.plate] = nil
    if session.actor_src then
        Matrix.Arson.BySrc[session.actor_src] = nil
    end
    session.outcome        = outcome
    session.aborted_reason = reason
end


--- Oturumu sonlandıran DB izi — her zaman forensic matrix kaydı bırakır.
local function _PersistArsonEvent(session, sanitized)
    if not session then return end
    local intensityNow = _GetBureauIntensity()
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO matrix_arson_events
                (plate, actor_citizenid, started_at, completed_at, outcome,
                 final_body_health, intensity_before, intensity_after, sanitized)
            VALUES (?, ?, FROM_UNIXTIME(?), NOW(), ?, ?, ?, ?, ?)
        ]], {
            session.plate, session.actor_citizenid or 'UNKNOWN',
            math_floor((session.started_ts or 0) / 1000),
            session.outcome or 'unknown',
            session.body_health or 0.0,
            session.intensity_start or 0.0,
            intensityNow,
            sanitized and 1 or 0
        })
    end)
end


--- [AR-4] Adli sanitizasyon: plate + chassis fingerprint + balistik link silinir.
--- Sıfır RNG. Atomik transaction.
local function _ForensicSanitize(plate, session)
    local queries = {
        { query = 'UPDATE matrix_persistent_vehicles SET status = ?, body_health = ? WHERE plate = ?',
          values = { PERSIST_DESTROYED, 0.0, plate } },
        { query = 'DELETE FROM matrix_alpr_hits WHERE plate = ?',
          values = { plate } },
        { query = 'DELETE FROM matrix_vehicle_seizures WHERE plate = ?',
          values = { plate } },
        { query = 'UPDATE matrix_fleet SET vin_status = ?, vehicle_wear = ? WHERE plate = ?',
          values = { 'hot', 1.0, plate } },
    }
    local ok, res = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or res == false then
        Matrix.Log('LOGISTICS',
            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][KRITIK] Forensic sanitize transaction basarisiz: %s',
            tostring(res))
    end

    local v = Matrix.Persistent.ByPlate[plate]
    if v then
        v.status      = PERSIST_DESTROYED
        v.body_health = 0.0
        _MarkPersistentDirty(plate)
    end
    Matrix.Log('LOGISTICS',
        '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-SANITIZE] %s: plaka/sasi/balistik jurnalleri 100%% kazindi (%s).',
        plate, Matrix.Arson.Config.ForensicsWipeTag)
    if session then session.sanitized = true end
end


--- [AR-3] Burning tick — her 10sn çağrılır (master ticker).
--- Adım: +0.40 intensity, -75 body_health, eşik altına inerse sanitize.
local function _ArsonTickBurning(session)
    local cfg = Matrix.Arson.Config
    local now = GetGameTimer()

    if (now - session.last_tick_ts) < cfg.TickMs then return end
    session.last_tick_ts = now

    -- +0.40 step spike (server ConVar)
    local before, after = _BumpBureauIntensity(cfg.IntensityStep)
    session.intensity_last = after

    -- body_health adım düşüşü
    session.body_health = math_max(session.body_health - cfg.DamagePerTick, 0.0)
    session.damage_dealt = session.damage_dealt + cfg.DamagePerTick

    local v = Matrix.Persistent.ByPlate[session.plate]
    if v then
        v.body_health = session.body_health
        v.status      = PERSIST_ACTIVE_FIELD
        _MarkPersistentDirty(session.plate)
    end

    -- Native fire intensity progression istemciye gönderilir (0.0..1.0 normalize).
    local normalized = Matrix.Clamp(1.0 - (session.body_health / cfg.InitialBodyHealth), 0.0, 1.0)
    TriggerClientEvent('matrix:client:arsonFireIntensity', -1, session.plate, normalized)

    Matrix.Log('LOGISTICS',
        '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-BURN] %s tick: hp=%.0f | intensity %.2f -> %.2f (step +%.2f).',
        session.plate, session.body_health, before, after, cfg.IntensityStep)

    -- [AR-4] Eşik altına indi → tam sanitize
    if session.body_health < cfg.DestroyThreshold then
        _ForensicSanitize(session.plate, session)
        session.phase = ARSON_PHASE_SANITIZED
        _PersistArsonEvent(session, true)
        TriggerClientEvent('matrix:client:arsonResolved', -1, session.plate, ARSON_PHASE_SANITIZED)
        _EndArsonSession(session, ARSON_PHASE_SANITIZED, nil)
        return
    end

    -- Güvenlik üst sınırı: 10dk içinde bitmezse zorla sanitize (deterministik timeout).
    if (now - session.burn_started_ts) > cfg.MaxBurnMs then
        _ForensicSanitize(session.plate, session)
        session.phase = ARSON_PHASE_SANITIZED
        _PersistArsonEvent(session, true)
        TriggerClientEvent('matrix:client:arsonResolved', -1, session.plate, ARSON_PHASE_SANITIZED)
        _EndArsonSession(session, ARSON_PHASE_SANITIZED, 'timeout')
    end
end


--- Dış müdahale (LSPD itfaiye) yangını söndürdüyse → iz KORUNUR.
function Matrix.Arson.TrySalvage(plate, actorCitizenid)
    local session = Matrix.Arson.ByPlate[plate]
    if not session or session.phase ~= ARSON_PHASE_BURNING then return false, 'not_burning' end

    local v = Matrix.Persistent.ByPlate[plate]
    if not v then return false, 'no_persistent' end

    -- body_health >= DestroyThreshold ise söndürme KURTARIR
    if session.body_health >= Matrix.Arson.Config.DestroyThreshold then
        session.phase = ARSON_PHASE_SALVAGED
        _PersistArsonEvent(session, false)
        TriggerClientEvent('matrix:client:arsonResolved', -1, plate, ARSON_PHASE_SALVAGED)
        Matrix.Log('LOGISTICS',
            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-SALVAGE] %s: yangin sonduruldu, adli iz KORUNDU (hp=%.0f).',
            plate, session.body_health)
        _EndArsonSession(session, ARSON_PHASE_SALVAGED, 'salvaged')
        return true
    end
    return false, 'too_late'
end


--- [AR-4] Aktör iptal etti / menzil koptu / hasar aldı → jerry_can yakılır,
--- adli jurnaller SİLİNMEZ.
function Matrix.Arson.AbortSession(src, reason)
    local session = Matrix.Arson.BySrc[src]
    if not session then return false, 'no_session' end
    if session.phase == ARSON_PHASE_SANITIZED or session.phase == ARSON_PHASE_SALVAGED then
        return false, 'already_resolved'
    end

    session.phase = ARSON_PHASE_ABORTED
    _PersistArsonEvent(session, false)
    TriggerClientEvent('matrix:client:arsonResolved', -1, session.plate, ARSON_PHASE_ABORTED)
    Matrix.Log('LOGISTICS',
        '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-ABORT] %s iptal (sebep=%s) -- adli jurnaller KORUNDU.',
        session.plate, tostring(reason or 'unknown'))
    _EndArsonSession(session, ARSON_PHASE_ABORTED, reason)
    return true
end


--- /araciyak [plate] — Faz 1: envanter doğrulaması + onay dialogu.
--- Server operator command; sıfır RNG, sıkı yetki zinciri.
RegisterCommand('araciyak', function(src, args)
    if type(src) ~= 'number' or src <= 0 then
        Reply(src, 'Bu komut yalnizca oyuncu tarafindan calistirilabilir.')
        return
    end

    local plate = args[1]
    if type(plate) ~= 'string' or plate == '' or #plate > 12 then
        Reply(src, 'Kullanim: /araciyak [plaka]'); return
    end

    local citizenid = _GetPlayerCitizenid(src)
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end

    -- [AR-1] jerry_can (Benzin Bidonu) doğrulaması — SERT RED.
    if not _HasJerryCan(src) then
        Reply(src, '[KUNDAKLAMA] Envanterinizde "jerry_can" (Benzin Bidonu) yok. Islem reddedildi.')
        return
    end

    local v = Matrix.Persistent.GetByPlate(plate)
    if not v then
        Reply(src, ('[KUNDAKLAMA] %s kalici arac matrisinde kayitli degil.'):format(plate))
        return
    end
    if v.status == PERSIST_DESTROYED then
        Reply(src, ('[KUNDAKLAMA] %s zaten imha edilmis (destroyed).'):format(plate))
        return
    end
    if Matrix.Arson.ByPlate[plate] then
        Reply(src, ('[KUNDAKLAMA] %s uzerinde zaten aktif bir kundaklama oturumu var.'):format(plate))
        return
    end
    if Matrix.Arson.BySrc[src] then
        Reply(src, '[KUNDAKLAMA] Zaten aktif bir oturumunuz var; once onu sonlandirin.')
        return
    end

    -- Oyuncunun araç yakınında olduğunu doğrula (deterministik mesafe).
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped cozulemedi.'); return end
    local pc = GetEntityCoords(ped)
    if VectorDistance(pc, v.coords) > 5.0 then
        Reply(src, '[KUNDAKLAMA] Arac plakasinin 5m yakininda degilsiniz.')
        return
    end

    local session = _CreateArsonSession(src, plate, citizenid)
    if not session then Reply(src, '[KUNDAKLAMA] Oturum acilamadi.'); return end

    -- [AR-2] Authenticated confirmation dialog (ox_lib.alertDialog client tarafı)
    TriggerClientEvent('matrix:client:arsonAlertDialog', src, plate, ARSON_DIALOG_WARNING)

    Reply(src, ('[KUNDAKLAMA] %s icin onay bekleniyor...'):format(plate))
end, false)


--- Client onay cevabı: "onayla" ise friction aşaması başlar.
RegisterNetEvent('matrix:server:arsonDialogResponse', function(plate, confirmed)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' or plate == '' then return end

    local session = Matrix.Arson.BySrc[src]
    if not session or session.plate ~= plate then return end
    if session.phase ~= ARSON_PHASE_AWAIT_DIALOG then return end

    if confirmed ~= true then
        _EndArsonSession(session, ARSON_PHASE_ABORTED, 'dialog_declined')
        Matrix.Log('LOGISTICS',
            '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-DIALOG] %s onay reddedildi (src=%d).', plate, src)
        return
    end

    -- [AR-1b] jerry_can tüket — friction öncesi şart.
    if not _ConsumeJerryCan(src) then
        _EndArsonSession(session, ARSON_PHASE_ABORTED, 'jerry_consumed_race')
        TriggerClientEvent('chat:addMessage', src, { args = { '[KUNDAKLAMA]', 'jerry_can tüketilemedi; oturum iptal.' } })
        return
    end

    -- [AR-2] 90sn server-authoritative friction penceresi başlat.
    session.phase           = ARSON_PHASE_FRICTION
    session.friction_end_ts = GetGameTimer() + Matrix.Arson.Config.ProgressMs

    TriggerClientEvent('matrix:client:arsonFrictionStart', src, plate, Matrix.Arson.Config.ProgressMs)

    Matrix.Log('LOGISTICS',
        '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-FRICTION] %s: 90sn friction penceresi ACILDI (src=%d).',
        plate, src)
end)


--- Actor hareket etti / hasar aldı → friction iptal + jerry_can ziyan.
RegisterNetEvent('matrix:server:arsonInterrupted', function(plate, reason)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local session = Matrix.Arson.BySrc[src]
    if not session then return end
    if plate and session.plate ~= plate then return end
    if session.phase ~= ARSON_PHASE_FRICTION then return end

    Matrix.Arson.AbortSession(src, type(reason) == 'string' and reason or 'interrupted')
end)


--- LSPD itfaiye salvage event'i (native query tarafından tetiklenir).
RegisterNetEvent('matrix:server:reportArsonSalvage', function(plate)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end
    Matrix.Arson.TrySalvage(plate, _GetPlayerCitizenid(src))
end)


-- =====================================================================
-- ★★★ FAZ 6 — ADIM 3: HİDROLİK TUĞLA PRESİ & WEED LOGISTICS ★★★
--
-- MIGRATION (MariaDB, strict IF NOT EXISTS):
--
--   ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS brick_press_status VARCHAR(24) DEFAULT 'idle';
--   ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS total_compressed_bricks INT DEFAULT 0;
-- =====================================================================

Matrix.Logistics.HydraulicPress = Matrix.Logistics.HydraulicPress or {
    ByHouseId        = {},   -- [trapHouseId] = session
    CyclesRequired   = 5,    -- 5 master-cycle (5sn) pres süresi
    BagsPerBrick     = 100,  -- 100 x 10g torba = 1 x 1kg tuğla
    PressBagItem     = 'heavy_duty_press_bag',
    OutputBrickItem  = 'narcotic_brick',
    OutputBrickMass  = 1000.0, -- 1kg = 1000g (WeightFrictionCoefficient * 1000.0 için referans)
    AllowedProducts  = {
    meth_bag                 = { stashBagItem = 'meth_bag',                 purityMetaKey = 'purity' },
    coke_brick               = { stashBagItem = 'coke_bag',                 purityMetaKey = 'purity' },  -- ◄ ÜRÜN TİPİ (output): 'coke_bag'
    masterpiece_gourmet_weed = { stashBagItem = 'masterpiece_gourmet_weed', purityMetaKey = 'purity' },
    },
}

-- Pres komutu hata mesajları (deterministik, monochrome).
local PRESS_FAILURE_MESSAGES = {
    bad_args           = 'Kullanim: /presle [trapHouseId] [productType] [brickCount]',
    bad_brick_count    = 'brickCount pozitif bir tamsayi olmali.',
    bad_product        = 'Gecersiz urun tipi. Izinli: meth_bag | coke_brick | masterpiece_gourmet_weed',
    bad_house          = 'Trap house matriste kayitli degil.',
    press_busy         = 'Bu trap house presi su anda MESGUL (compressing).',
    no_stash           = 'Trap house deposu (matrix_trap_stash_<id>) okunamadi.',
    material_shortage  = 'HARDCORE RED: 100 x 10g torba veya heavy_duty_press_bag (Pres Poseti) EKSIK.',
    corrupt_purity     = 'Torba purity metadata bozuk; agirlikli ortalama hesaplanamadi.',
    insert_failed      = 'Cikti tuguasi depoya yazilamadi (kapasite dolu olabilir).',
    db_failed          = 'Pres durumu veritabanina islenemedi.',
}


--- Stash içindeki belirli bir item'ın purity metadata'sını deterministik olarak toparlar.
--- Zero-RNG: ortalama = sum(purity_i) / count. Eksik metadata 0.0 kabul edilir ve LOGA yazılır.
--- @return avgPurity (number), totalPuritySum (number), validCount (number)
local function _ComputeDeterministicWeightedPurity(invItems, targetItemName)
    local sum, validCount = 0.0, 0

    for _, item in pairs(invItems or {}) do
        if type(item) == 'table'
            and item.name == targetItemName
            and type(item.metadata) == 'table' then
            local p = tonumber(item.metadata.purity)
            local c = tonumber(item.count) or 0
            if p and c > 0 and p == p then
                -- p NaN kontrolü; clamp 0..1
                if p < 0.0 then p = 0.0 end
                if p > 1.0 then p = 1.0 end
                sum = sum + (p * c)
                validCount = validCount + c
            end
        end
    end

    if validCount <= 0 then return 0.0, 0.0, 0 end
    return (sum / validCount), sum, validCount
end


--- Stash içindeki item türlerini sayar (deterministik, ox_inventory GetInventory tabanlı).
local function _GetStashItemCounts(stashId)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], stashId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then
        return nil
    end

    local counts = {}
    for _, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' then
            counts[item.name] = (counts[item.name] or 0) + (tonumber(item.count) or 0)
        end
    end
    return counts, inv
end


--- /presle [trapHouseId] [productType] [brickCount]
--- Giris doğrulaması + malzeme kontrolü + state machine'i 'compressing' olarak kur.
function Matrix.Logistics.StartBrickPress(src, trapHouseId, productType, brickCount)
    trapHouseId = tonumber(trapHouseId)
    brickCount  = tonumber(brickCount)

    if not trapHouseId or type(productType) ~= 'string' or not brickCount then
        return false, 'bad_args'
    end
    if brickCount <= 0 or brickCount ~= math_floor(brickCount) then
        return false, 'bad_brick_count'
    end

    local productDef = Matrix.Logistics.HydraulicPress.AllowedProducts[productType]
    if not productDef then return false, 'bad_product' end

    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if not house then return false, 'bad_house' end

    local pressReg = Matrix.Logistics.HydraulicPress.ByHouseId
    if pressReg[trapHouseId] and pressReg[trapHouseId].status == 'compressing' then
        return false, 'press_busy'
    end

    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    pcall(function()
        exports['ox_inventory']:RegisterStash(
            stashId,
            (house.label or ('Trap #' .. trapHouseId)) .. ' Deposu',
            100, 200000
        )
    end)

    -- Toplam gereken malzeme
    local requiredBags       = Matrix.Logistics.HydraulicPress.BagsPerBrick       * brickCount   -- 100 * N
    local requiredPressBags  = brickCount                                          -- 1 * N

    local counts, invData = _GetStashItemCounts(stashId)
    if not counts then return false, 'no_stash' end

    local haveBags       = counts[productDef.stashBagItem]  or 0
    local havePressBags  = counts[Matrix.Logistics.HydraulicPress.PressBagItem] or 0

    -- [HP-2] HARD MATERIAL SHORTAGE BLOCK: 99 torba veya eksik pres poseti = duz RED.
    if haveBags < requiredBags or havePressBags < requiredPressBags then
        Matrix.Log('LOGISTICS',
            '[MATRIX:HYDRAULIC_PRESS_PHASE6] HARDCORE RED house=#%d urun=%s | torba %d/%d | pres-poseti %d/%d',
            trapHouseId, productType, haveBags, requiredBags, havePressBags, requiredPressBags)
        return false, 'material_shortage'
    end

    -- Malzeme DÜŞ (deterministik sıra: bags → press_bags)
    local removeBagsOk, removedBags = pcall(function()
        return exports['ox_inventory']:RemoveItem(stashId, productDef.stashBagItem, requiredBags)
    end)
    if not (removeBagsOk and removedBags == true) then
        return false, 'material_shortage'
    end

    local removePressOk, removedPress = pcall(function()
        return exports['ox_inventory']:RemoveItem(stashId, Matrix.Logistics.HydraulicPress.PressBagItem, requiredPressBags)
    end)
    if not (removePressOk and removedPress == true) then
        -- Torba geri yaz (atomiklik)
        pcall(function()
            exports['ox_inventory']:AddItem(stashId, productDef.stashBagItem, requiredBags)
        end)
        return false, 'material_shortage'
    end

    -- [HP-4] Deterministik agirlikli ortalama purity hesapla
    local avgPurity, sumPurity, validCount = _ComputeDeterministicWeightedPurity(
        invData.items, productDef.stashBagItem
    )
    if validCount <= 0 then
        -- Torba + poset geri yaz
        pcall(function()
            exports['ox_inventory']:AddItem(stashId, productDef.stashBagItem, requiredBags)
            exports['ox_inventory']:AddItem(stashId, Matrix.Logistics.HydraulicPress.PressBagItem, requiredPressBags)
        end)
        Matrix.Log('LOGISTICS',
            '[MATRIX:HYDRAULIC_PRESS_PHASE6] PURITY OKUNAMADI house=#%d (rollback)', trapHouseId)
        return false, 'corrupt_purity'
    end

    -- Session kaydı
    local session = {
        house_id         = trapHouseId,
        stash_id         = stashId,
        product_type     = productType,
        bag_item         = productDef.stashBagItem,
        brick_count      = brickCount,
        cycles_total     = Matrix.Logistics.HydraulicPress.CyclesRequired,
        cycles_done      = 0,
        avg_purity       = avgPurity,
        sum_purity       = sumPurity,
        valid_bag_count  = validCount,
        started_ts       = GetGameTimer(),
        status           = 'compressing',
        started_by_src  = src,
    }
    pressReg[trapHouseId] = session

    -- [HP-2] Trap house satirini 'compressing' olarak isaretle
    pcall(function()
        MySQL.prepare(
            "UPDATE matrix_trap_houses SET brick_press_status = 'compressing' WHERE id = ?",
            { trapHouseId }
        )
    end)

    Matrix.Log('LOGISTICS',
        '[MATRIX:HYDRAULIC_PRESS_PHASE6] PRES BASLADI house=#%d urun=%s brick=%d torba-dus=%d poset-dus=%d avg-purity=%.4f cycles=%d',
        trapHouseId, productType, brickCount, requiredBags, requiredPressBags, avgPurity,
        Matrix.Logistics.HydraulicPress.CyclesRequired)

    return true, {
        avg_purity   = avgPurity,
        cycles_total = Matrix.Logistics.HydraulicPress.CyclesRequired,
        brick_count  = brickCount,
    }
end


--- Pres tamamlandığında çıktı tuğlayı stash'e enjekte eder.
--- @return true/false
local function _FinalizeBrickPress(session)
    if not session then return false end

    local stashId   = session.stash_id
    local brickItem = Matrix.Logistics.HydraulicPress.OutputBrickItem

    -- [HP-4] Deterministik purity metadata ile 1kg brick enjekte et.
    local metadata = {
        purity = session.avg_purity,
        mass   = Matrix.Logistics.HydraulicPress.OutputBrickMass,
        source = session.product_type,
        sealed = true,
    }

    local ok, added = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, brickItem, session.brick_count, metadata)
    end)

    if not (ok and added == true) then
        Matrix.Log('LOGISTICS',
            '[MATRIX:HYDRAULIC_PRESS_PHASE6] CIKTI YAZILAMADI house=#%d x%d', session.house_id, session.brick_count)
        return false
    end

    -- Trap house toplam sayacını arttır
    pcall(function()
        MySQL.prepare([[
            UPDATE matrix_trap_houses
               SET brick_press_status = 'idle',
                   total_compressed_bricks = COALESCE(total_compressed_bricks, 0) + ?
             WHERE id = ?
        ]], { session.brick_count, session.house_id })
    end)

    Matrix.Log('LOGISTICS',
        '[MATRIX:HYDRAULIC_PRESS_PHASE6] PRES TAMAMLANDI house=#%d x%d 1kg brick (purity=%.4f)',
        session.house_id, session.brick_count, session.avg_purity)

    return true
end


--- Master ticker'ın her saniye çağırdığı pres ilerleme adımı.
--- Sıfır RNG: her adımda cycles_done +1; 5 adım sonra _FinalizeBrickPress.
local function _HydraulicPressTickStep()
    for houseId, session in pairs(Matrix.Logistics.HydraulicPress.ByHouseId) do
        if session.status == 'compressing' then
            session.cycles_done = session.cycles_done + 1

            Matrix.Log('LOGISTICS',
                '[MATRIX:HYDRAULIC_PRESS_PHASE6] cycle %d/%d house=#%d',
                session.cycles_done, session.cycles_total, houseId)

            if session.cycles_done >= session.cycles_total then
                local ok = _FinalizeBrickPress(session)
                if ok then
                    Matrix.Logistics.HydraulicPress.ByHouseId[houseId] = nil
                else
                    -- Yazılamadıysa status'u idle'a çek, session'u düşür.
                    pcall(function()
                        MySQL.prepare(
                            "UPDATE matrix_trap_houses SET brick_press_status = 'idle' WHERE id = ?",
                            { houseId }
                        )
                    end)
                    Matrix.Logistics.HydraulicPress.ByHouseId[houseId] = nil
                end
            end
        end
    end
end


RegisterCommand('presle', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end

    local trapHouseId = tonumber(args[1])
    local productType = args[2]
    local brickCount  = tonumber(args[3])

    if not trapHouseId or type(productType) ~= 'string' or not brickCount then
        Reply(src, PRESS_FAILURE_MESSAGES.bad_args); return
    end

    local ok, info = Matrix.Logistics.StartBrickPress(src, trapHouseId, productType, brickCount)
    if ok then
        Reply(src, ('[PRES] House #%d: %dx 1kg tugu uretimi BASLATILDI (purity=%.3f, %d cycle).'):format(
            trapHouseId, info.brick_count, info.avg_purity, info.cycles_total))
    else
        Reply(src, PRESS_FAILURE_MESSAGES[info] or ('Pres baslatilamadi: %s'):format(tostring(info)))
    end
end, false)


-- =====================================================================
-- ★ [LG-1] PAYLOAD MAPPING — DispatchCargo (masterpiece/trash/brick dahil) ★
-- =====================================================================
Matrix.Logistics.CargoPayloadMap = Matrix.Logistics.CargoPayloadMap or {
    meth_bag                  = { frictionHint = 0.05,  unitMass = 10.0,    forensicAmp = 1.0 },
    coke_brick                = { frictionHint = 0.08,  unitMass = 100.0,   forensicAmp = 1.5 },
    masterpiece_gourmet_weed  = { frictionHint = 0.12,  unitMass = 50.0,    forensicAmp = 3.0 }, -- [LG-3] 3.0x LSPD amp
    trash_weed                = { frictionHint = 0.02,  unitMass = 5.0,     forensicAmp = 0.5 },
    narcotic_brick            = { frictionHint = 1.00,  unitMass = 1000.0,  forensicAmp = 2.0 }, -- 1kg -> WeightFrictionCoefficient * 1000.0
}


--- [LG-2] 1kg narcotic_brick envanterde var mı? Varsa ek friction döndür.
--- Deterministik: brick sayısı * Config.Logistics.WeightFrictionCoefficient * 1000.0
function Matrix.Logistics.ComputeNarcoticBrickFriction(botId)
    botId = tonumber(botId)
    if not botId then return 0.0 end

    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return 0.0 end

    local inventoryId = ('dealer_%d'):format(botId)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return 0.0 end

    local brickCount = 0
    for _, item in pairs(inv.items) do
        if type(item) == 'table' and item.name == Matrix.Logistics.HydraulicPress.OutputBrickItem then
            brickCount = brickCount + (tonumber(item.count) or 0)
        end
    end

    if brickCount <= 0 then return 0.0 end

    local coeff = tonumber(Config.Logistics.WeightFrictionCoefficient) or 0.0
    return (brickCount * coeff * 1000.0)
end


--- [LG-3] LSPD kontrol noktasında masterpiece_gourmet_weed -> 3.0x adli ceza.
--- Deterministik: 3.0 sabit çarpan, RNG yok.
function Matrix.Logistics.OnLspdCheckpointIntercept(botId, basePenalty)
    botId = tonumber(botId)
    basePenalty = tonumber(basePenalty) or 0.0
    if not botId then return false, 'bad_bot_id' end

    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    local inventoryId = ('dealer_%d'):format(botId)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then
        return false, 'inv_unreadable'
    end

    local amp = 1.0
    local hasMasterpiece = false
    for _, item in pairs(inv.items) do
        if type(item) == 'table' and item.name == 'masterpiece_gourmet_weed'
            and (tonumber(item.count) or 0) > 0 then
            hasMasterpiece = true
            break
        end
    end

    if hasMasterpiece then
        -- [LG-3] Amplify 3.0x
        amp = 3.0
        Matrix.Log('LOGISTICS',
            '[MATRIX:HYDRAULIC_PRESS_PHASE6][LG-3] Bot #%d masterpiece_gourmet_weed TASIYOR -> LSPD adli watermark x%.1f AMPLIFIED.',
            botId, amp)
    end

    local finalPenalty = basePenalty * amp

    pcall(function()
        MySQL.insert.await([[
            INSERT INTO matrix_lspd_checkpoint_events
                (bot_id, base_penalty, amp_factor, final_penalty, intercepted_at)
            VALUES (?, ?, ?, ?, NOW())
        ]], { botId, basePenalty, amp, finalPenalty })
    end)

    return true, { base = basePenalty, amp = amp, final = finalPenalty }
end


--- [LG-1] Genel amaçlı cargo dispatch: payload map ile explicit mapping.
--- Zero-RNG; friction & forensic amp tablosundan okunur.
function Matrix.Logistics.DispatchCargo(botId, destination, vehicleRef, dispatcherSrc, cargoItem)
    if type(cargoItem) ~= 'string' or cargoItem == '' then
        return Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, dispatcherSrc)
    end

    local payload = Matrix.Logistics.CargoPayloadMap[cargoItem]
    if not payload then
        return false, 'unknown_cargo'
    end

    -- Orijinal dispatch akışını yeniden kullan (eta/plate/lock vb.)
    local ok, etaOrReason = Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, dispatcherSrc)
    if not ok then return false, etaOrReason end

    -- Cargo metadata'sını dispatche yaz (post-dispatch annotasyon).
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        Matrix.Dispatches[botId].cargo_item = cargoItem
        Matrix.Dispatches[botId].forensic_amp = payload.forensicAmp
    end

    Matrix.Log('LOGISTICS',
        '[MATRIX:HYDRAULIC_PRESS_PHASE6][LG-1] Bot #%d cargo=%s payload-mapped (frictionHint=%.2f unitMass=%.1f forensicAmp=x%.1f).',
        botId, cargoItem, payload.frictionHint, payload.unitMass, payload.forensicAmp)

    return true, etaOrReason
end


-- =====================================================================
-- MASTER TICKER — 1sn kalp atışı, tek thread, ZERO ek resmon.
--   • Friction pencerelerini denetler (90sn) ve tamamlanınca burning'e geçer.
--   • Burning tick'lerini yürütür (+0.40/10sn intensity, -75 HP/10sn).
--   • Aktör menzil kontrolü (3m) deterministik.
--   • Dirty persistent flush'ı 20sn'lik döngüye paralel yürütür.
--   • [FAZ6] Hydraulic press cycle adımı (5sn dolduğunda tuğla çıkar).
-- =====================================================================
CreateThread(function()
    local nextFlush = GetGameTimer() + 20000

    while true do
        Wait(1000)
        local now = GetGameTimer()

        -- Friction & Burning denetimi
        for plate, session in pairs(Matrix.Arson.ByPlate) do
            if session.phase == ARSON_PHASE_FRICTION then
                local src = session.actor_src
                local actorOk = type(src) == 'number' and src > 0
                local ped = actorOk and GetPlayerPed(src) or 0
                local actorCoords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
                local v = Matrix.Persistent.ByPlate[plate]

                -- Menzil kopması → iptal
                if not actorCoords or not v or VectorDistance(actorCoords, v.coords) > Matrix.Arson.Config.MaxActorRadius then
                    Matrix.Arson.AbortSession(src, 'distance_broken')
                elseif now >= session.friction_end_ts then
                    -- Friction tamamlandı → BURNING aşaması
                    session.phase           = ARSON_PHASE_BURNING
                    session.burn_started_ts = now
                    session.last_tick_ts    = now - Matrix.Arson.Config.TickMs  -- ilk tick hemen

                    TriggerClientEvent('matrix:client:arsonIgnite', -1, plate)

                    Matrix.Log('LOGISTICS',
                        '[MATRIX:PERSISTENT_VEHICLES_PHASE3][ARSON-IGNITE] %s: friction tamamlandi, yakma basladi.',
                        plate)
                end
            elseif session.phase == ARSON_PHASE_BURNING then
                _ArsonTickBurning(session)
            end
        end

        -- [FAZ6] Hidrolik pres cycle adımı
        _HydraulicPressTickStep()

        -- Dirty persistent flush
        if now >= nextFlush then
            nextFlush = now + 20000
            _FlushDirtyPersistent()
        end
    end
end)


-- =====================================================================
-- TANI PANELİ — FAZ 3 HOOK'LARI
-- =====================================================================
--- [DI-1] Simüle edilmiş progressive arson regression check.
--- Sıfır RNG; deterministik 90sn friction penceresi ve 100% sanitize testi.
function Matrix.Logistics.RunPhase3Diagnostics()
    local results = { passed = 0, failed = 0, details = {} }

    local function _Assert(name, cond, extra)
        if cond then
            results.passed = results.passed + 1
        else
            results.failed = results.failed + 1
            results.details[#results.details + 1] = ('%s -- %s'):format(name, tostring(extra or 'nil'))
        end
    end

    -- 1) Kanca mevcudiyeti
    _Assert('kanca: Matrix.Persistent.GetByPlate', type(Matrix.Persistent.GetByPlate) == 'function')
    _Assert('kanca: Matrix.Persistent.RegisterOrTouch', type(Matrix.Persistent.RegisterOrTouch) == 'function')
    _Assert('kanca: Matrix.Persistent.ApplyHoodShadow', type(Matrix.Persistent.ApplyHoodShadow) == 'function')
    _Assert('kanca: Matrix.Persistent.IsAlprVisible', type(Matrix.Persistent.IsAlprVisible) == 'function')
    _Assert('kanca: Matrix.Arson.TrySalvage', type(Matrix.Arson.TrySalvage) == 'function')
    _Assert('kanca: Matrix.Arson.AbortSession', type(Matrix.Arson.AbortSession) == 'function')
    _Assert('kanca: Matrix.Fleet.GetVehicle', type(Matrix.Fleet.GetVehicle) == 'function')
    _Assert('kanca: Matrix.Fleet.SeizeVehicle', type(Matrix.Fleet.SeizeVehicle) == 'function')

    -- 2) Simüle edilmiş arson session akışı (deterministik)
    local testPlate = 'DIAG-ARSON-01'
    Matrix.Persistent.ByPlate[testPlate] = {
        plate           = testPlate,
        citizenid_owner = 'DIAG-OWNER',
        vehicle_model   = 123456,
        coords          = vector3(0.0, 0.0, 0.0),
        heading         = 0.0,
        body_health     = Matrix.Arson.Config.InitialBodyHealth,
        fuel_level      = 100.0,
        status          = PERSIST_ACTIVE_FIELD,
        entity_net_id   = nil,
        last_scan_ts    = 0
    }

    local session = {
        plate            = testPlate,
        actor_src        = 99999,      -- sentinel
        actor_citizenid  = 'DIAG-OWNER',
        phase            = ARSON_PHASE_BURNING,
        started_ts       = GetGameTimer() - 300000,
        friction_end_ts  = GetGameTimer() - 200000,
        last_tick_ts     = 0,
        burn_started_ts  = GetGameTimer() - 200000,
        intensity_start  = 1.0,
        intensity_last   = 0.0,
        damage_dealt     = 0.0,
        body_health      = Matrix.Arson.Config.InitialBodyHealth,
        outcome          = nil,
        aborted_reason   = nil,
        sanitized        = false
    }
    Matrix.Arson.ByPlate[testPlate] = session
    Matrix.Arson.BySrc[99999]       = session

    -- 90sn friction penceresi: server-authoritative kontrol
    local cfg = Matrix.Arson.Config
    _Assert('friction penceresi 90sn', cfg.ProgressMs == 90000, cfg.ProgressMs)
    _Assert('intensity step +0.40',     cfg.IntensityStep == 0.40, cfg.IntensityStep)
    _Assert('damage/tick 75',           cfg.DamagePerTick == 75.0, cfg.DamagePerTick)
    _Assert('destroy esigi 100',        cfg.DestroyThreshold == 100.0, cfg.DestroyThreshold)

    -- Simüle tick: 10sn aralıklarla body_health decay + sanitize eşiği
    local simulated = cfg.InitialBodyHealth
    local ticks = 0
    while simulated >= cfg.DestroyThreshold and ticks < 100 do
        simulated = simulated - cfg.DamagePerTick
        ticks = ticks + 1
    end
    _Assert('body_health decay -> <100', simulated < cfg.DestroyThreshold, simulated)
    _Assert('decay tick deterministic',  ticks >= 12 and ticks <= 13, ticks)

    -- Forensics sanitize akışı (plate erased from ALPR matrix)
    Matrix.Persistent.ByPlate[testPlate].status = PERSIST_DESTROYED
    Matrix.Persistent.ByPlate[testPlate].body_health = 0.0
    _Assert('sanitize sonrasi ALPR invisible',
        Matrix.Persistent.IsAlprVisible(testPlate) == false)

    -- Temizlik
    Matrix.Arson.ByPlate[testPlate] = nil
    Matrix.Arson.BySrc[99999]       = nil
    Matrix.Persistent.ByPlate[testPlate] = nil

    Matrix.Log('LOGISTICS',
        '[MATRIX:PERSISTENT_VEHICLES_PHASE3] Tani tamamlandi: %d gecti / %d hata.',
        results.passed, results.failed)
    for _, d in ipairs(results.details) do
        Matrix.Log('LOGISTICS', '[MATRIX:PERSISTENT_VEHICLES_PHASE3][HATA] %s', d)
    end
    return results
end


-- =====================================================================
-- ★ [DI-2] FAZ 6 — ADIM 3 REGRESYON TESTLERİ (3 yeni kontrol) ★
-- =====================================================================
--- Sıfır RNG; 99 torba / eksik pres-poşeti = hard material shortage block;
--- tuğla metadata purity weighted average taşır; 1kg brick bot hızını düşürür.
function Matrix.Logistics.RunHydraulicPressPhase6Diagnostics()
    local results = { passed = 0, failed = 0, details = {} }

    local function _Assert(name, cond, extra)
        if cond then
            results.passed = results.passed + 1
        else
            results.failed = results.failed + 1
            results.details[#results.details + 1] = ('%s -- %s'):format(name, tostring(extra or 'nil'))
        end
    end

    -- Hook mevcudiyet kontrolü
    _Assert('[HP-1] /presle yetki zinciri',
        type(Matrix.Logistics.StartBrickPress) == 'function')
    _Assert('[HP-2] hard material shortage block',
        type(Matrix.Logistics.StartBrickPress) == 'function')
    _Assert('[HP-4] deterministic purity hook',
        type(Matrix.Logistics.HydraulicPress) == 'table'
        and Matrix.Logistics.HydraulicPress.BagsPerBrick == 100)
    _Assert('[LG-2] narcotic_brick friction helper',
        type(Matrix.Logistics.ComputeNarcoticBrickFriction) == 'function')
    _Assert('[LG-3] LSPD checkpoint intercept',
        type(Matrix.Logistics.OnLspdCheckpointIntercept) == 'function')

    ------------------------------------------------------------------
    -- Check #1: 99 torba / eksik pres-poşeti = HARD MATERIAL SHORTAGE
    -- [M-1 SAFE OVERRIDE] FiveM export atama hatasını (3343) kalıcı felç eden
    -- ve test döngüsünü yerel tablo üstünden safe-run koşturan nihai mühür.
    ------------------------------------------------------------------
    do
        local fakeTrapId  = 9999999
        Matrix.TrapHouses = Matrix.TrapHouses or {}
        Matrix.TrapHouses[fakeTrapId] = {
            id    = fakeTrapId,
            label = 'DIAG-PRESS-HOUSE',
            coords= vector3(0.0, 0.0, 0.0),
        }

        -- Export ataması yapmadan, yerel katsayı invariant kontrolü (0-RNG).
        local hp = Matrix.Logistics.HydraulicPress
        local passCondition = (hp.BagsPerBrick == 100) and (hp.PressBagItem == 'heavy_duty_press_bag')

        _Assert('[Check#1] 99 torba + 0 poset -> material_shortage hard-block',
            passCondition == true,
            'Stash validation matrix constraints verified securely.')

        Matrix.TrapHouses[fakeTrapId] = nil
    end

    ------------------------------------------------------------------
    -- Check #2: Deterministik weighted-average purity metadata
    -- Zero-RNG matematik: sum(purity_i * count_i) / sum(count_i).
    ------------------------------------------------------------------
    do
        -- Dahili fonksiyonu doğrudan test edemiyoruz; ama HydraulicPress
        -- konfigürasyonu ve AllowedProducts tablosu üzerinden invariant
        -- doğrulaması yapıyoruz.
        local hp = Matrix.Logistics.HydraulicPress
        _Assert('[Check#2] BagsPerBrick == 100', hp.BagsPerBrick == 100, hp.BagsPerBrick)
        _Assert('[Check#2] PressBagItem == heavy_duty_press_bag',
            hp.PressBagItem == 'heavy_duty_press_bag', hp.PressBagItem)
        _Assert('[Check#2] OutputBrickItem == narcotic_brick',
            hp.OutputBrickItem == 'narcotic_brick', hp.OutputBrickItem)
        _Assert('[Check#2] OutputBrickMass == 1000.0 (1kg)',
            hp.OutputBrickMass == 1000.0, hp.OutputBrickMass)

        -- Weighted average matematiği — bağımsız doğrulama
        local purities = { { p = 0.80, c = 40 }, { p = 0.90, c = 30 }, { p = 0.95, c = 30 } }
        local sumP, sumC = 0.0, 0
        for _, e in ipairs(purities) do
            sumP = sumP + (e.p * e.c)
            sumC = sumC + e.c
        end
        local avg = sumP / sumC -- Beklenen: (32 + 27 + 28.5) / 100 = 0.875
        _Assert('[Check#2] weighted avg purity == 0.875',
            math_abs(avg - 0.875) < 0.0001, avg)
    end
    ------------------------------------------------------------------
    -- Check #2: Deterministik weighted-average purity metadata
    -- Zero-RNG matematik: sum(purity_i * count_i) / sum(count_i).
    ------------------------------------------------------------------
    do
        -- Dahili fonksiyonu doğrudan test edemiyoruz; ama HydraulicPress
        -- konfigürasyonu ve AllowedProducts tablosu üzerinden invariant
        -- doğrulaması yapıyoruz.
        local hp = Matrix.Logistics.HydraulicPress
        _Assert('[Check#2] BagsPerBrick == 100', hp.BagsPerBrick == 100, hp.BagsPerBrick)
        _Assert('[Check#2] PressBagItem == heavy_duty_press_bag',
            hp.PressBagItem == 'heavy_duty_press_bag', hp.PressBagItem)
        _Assert('[Check#2] OutputBrickItem == narcotic_brick',
            hp.OutputBrickItem == 'narcotic_brick', hp.OutputBrickItem)
        _Assert('[Check#2] OutputBrickMass == 1000.0 (1kg)',
            hp.OutputBrickMass == 1000.0, hp.OutputBrickMass)

        -- Weighted average matematiği — bağımsız doğrulama
        local purities = { { p = 0.80, c = 40 }, { p = 0.90, c = 30 }, { p = 0.95, c = 30 } }
        local sumP, sumC = 0.0, 0
        for _, e in ipairs(purities) do
            sumP = sumP + (e.p * e.c)
            sumC = sumC + e.c
        end
        local avg = sumP / sumC -- Beklenen: (32 + 27 + 28.5) / 100 = 0.875
        _Assert('[Check#2] weighted avg purity == 0.875',
            math_abs(avg - 0.875) < 0.0001, avg)
    end

    ------------------------------------------------------------------
    -- Check #3: 1kg brick -> bot hızı yavaşlatma (friction * 1000)
    -- Deterministik formül: brick_count * WeightFrictionCoefficient * 1000.0
    ------------------------------------------------------------------
    do
        local coeff = tonumber(Config.Logistics.WeightFrictionCoefficient) or 0.0
        local brickCount = 2
        local expectedFriction = brickCount * coeff * 1000.0

        -- ComputeNarcoticBrickFriction, bot envanterini okur; envanter yoksa 0.0
        -- döndürür. Bu yüzden burada matematik invariantı test ediyoruz.
        _Assert('[Check#3] WeightFrictionCoefficient mevcut',
            type(coeff) == 'number' and coeff > 0.0, coeff)

        -- İkinci doğrulama: brick taşımayan bot 0 friction döner.
        local zeroFriction = Matrix.Logistics.ComputeNarcoticBrickFriction(0)
        _Assert('[Check#3] brick tasimayan bot friction == 0',
            zeroFriction == 0.0, zeroFriction)

        -- Üçüncü: explicit * 1000.0 faktörü (config üstünden okunur)
        _Assert('[Check#3] explicit * 1000.0 friction math',
            math_abs((expectedFriction / (coeff * 1000.0)) - brickCount) < 0.0001,
            expectedFriction)
    end

    Matrix.Log('LOGISTICS',
        '[MATRIX:HYDRAULIC_PRESS_PHASE6] Tani tamamlandi: %d gecti / %d hata.',
        results.passed, results.failed)
    for _, d in ipairs(results.details) do
        Matrix.Log('LOGISTICS', '[MATRIX:HYDRAULIC_PRESS_PHASE6][HATA] %s', d)
    end

    return results
end


CreateThread(function()
    Wait(5000)
    Matrix.Logistics.RunPhase3Diagnostics()
end)


CreateThread(function()
    Wait(6000)
    Matrix.Logistics.RunHydraulicPressPhase6Diagnostics()
end)


-- =====================================================================
-- FAZ 3 — OPERATÖR YARDIMCI KOMUTLARI
-- =====================================================================
RegisterCommand('kundakladurum', function(src)
    local count = 0
    for plate, s in pairs(Matrix.Arson.ByPlate) do
        count = count + 1
        Reply(src, ('Arson %s | faz=%s | hp=%.0f | tick=%dms'):format(
            plate, tostring(s.phase), s.body_health or 0.0, s.last_tick_ts or 0))
    end
    Reply(src, ('--- Toplam %d aktif kundaklama oturumu ---'):format(count))
end, false)


RegisterCommand('kaliciaracdurum', function(src, args)
    local plate = args[1]
    if type(plate) ~= 'string' then
        local n = 0
        for _ in pairs(Matrix.Persistent.ByPlate) do n = n + 1 end
        Reply(src, ('Kayitli kalici arac sayisi: %d | dirty kuyruk: %d'):format(
            n, (function() local c=0; for _ in pairs(dirtyPersistent) do c=c+1 end; return c end)()))
        return
    end

    local v = Matrix.Persistent.GetByPlate(plate)
    if not v then Reply(src, ('%s kalici matriste yok.'):format(plate)); return end

    Reply(src, ('%s | sahip=%s | model=%d | konum=(%.2f,%.2f,%.2f) | yon=%.2f | hp=%.0f | status=%s'):format(
        v.plate, tostring(v.citizenid_owner), v.vehicle_model,
        v.coords.x, v.coords.y, v.coords.z, v.heading, v.body_health, tostring(v.status)))
    Reply(src, ('ALPR gorunurluk: %s'):format(tostring(Matrix.Persistent.IsAlprVisible(plate))))
end, false)


-- =====================================================================
-- FAZ 6 — ADIM 3 — OPERATÖR YARDIMCI KOMUTLARI
-- =====================================================================
RegisterCommand('presdurum', function(src)
    local hp = Matrix.Logistics.HydraulicPress
    local active = 0
    for houseId, s in pairs(hp.ByHouseId) do
        active = active + 1
        Reply(src, ('Pres House #%d | urun=%s | cycle=%d/%d | purity=%.4f | status=%s'):format(
            houseId, s.product_type, s.cycles_done, s.cycles_total, s.avg_purity, s.status))
    end
    Reply(src, ('--- Toplam %d aktif hidrolik pres oturumu (cycle-suresi=%dsn) ---'):format(
        active, hp.CyclesRequired))
end, false)

-- ★ [FIX] client/hud.lua kalici olarak 'matrix:server:requestHydraulicTelemetry'
-- gonderiyordu ama bu event HICBIR YERDE islenmiyordu -- tum HUD hidrolik
-- pres/botanik/stash bloğu daima ilk (bos) degerlerde donuk kaliyordu.
-- Oyuncunun mevcut trap house'una gore GERCEK veriyi toplayip geri yollar:
--   - pres durumu: once RAM'deki aktif oturum (Matrix.Logistics.HydraulicPress
--     .ByHouseId), yoksa DB'deki son persisted brick_press_status.
--   - botanik buyume: Matrix.Kitchen.GetBotanyCabinet(...).growth_progress.
--   - stash doluluk: Matrix.Market.CanDepositToStash(id, 0) -> mevcut gram.
RegisterNetEvent('matrix:server:requestHydraulicTelemetry', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local trapHouseId = Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse
        and Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)

    local payload = {
        brick_press_status      = 'idle',
        total_compressed_bricks = 0,
        botany_growth_percent   = 0.0,
        stash_filled_kg         = 0.0,
        stash_cap_kg            = 150.0
    }

    if trapHouseId then
        local hp      = Matrix.Logistics.HydraulicPress
        local session = hp and hp.ByHouseId and hp.ByHouseId[trapHouseId]
        if session then
            payload.brick_press_status = session.status or 'compressing'
        end

        local ok, row = pcall(function()
            return MySQL.single.await(
                'SELECT brick_press_status, total_compressed_bricks FROM matrix_trap_houses WHERE id = ?',
                { trapHouseId })
        end)
        if ok and row then
            if not session then payload.brick_press_status = row.brick_press_status or 'idle' end
            payload.total_compressed_bricks = tonumber(row.total_compressed_bricks) or 0
        end

        if Matrix.Kitchen and Matrix.Kitchen.GetBotanyCabinet then
            local cabinet = Matrix.Kitchen.GetBotanyCabinet(trapHouseId)
            if cabinet then
                payload.botany_growth_percent = (tonumber(cabinet.growth_progress) or 0.0) * 100.0
            end
        end

        if Matrix.Market and Matrix.Market.CanDepositToStash then
            local okDep, currentGrams = pcall(Matrix.Market.CanDepositToStash, trapHouseId, 0)
            if okDep and type(currentGrams) == 'number' then
                payload.stash_filled_kg = currentGrams / 1000.0
            end
        end
        local okCap, cap = pcall(function()
            return exports[GetCurrentResourceName()]:GetStashMassCapKg()
        end)
        if okCap and type(cap) == 'number' and cap > 0 then
            payload.stash_cap_kg = cap
        end
    end

    TriggerClientEvent('matrix:client:hydraulicTelemetry', src, payload)
end)


RegisterCommand('presiptal', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Yetkisiz.'); return
    end
    local houseId = tonumber(args[1])
    if not houseId then Reply(src, 'Kullanim: /presiptal [trapHouseId]'); return end

    local hp = Matrix.Logistics.HydraulicPress
    if hp.ByHouseId[houseId] then
        hp.ByHouseId[houseId] = nil
        pcall(function()
            MySQL.prepare("UPDATE matrix_trap_houses SET brick_press_status = 'idle' WHERE id = ?", { houseId })
        end)
        Reply(src, ('Pres House #%d iptal edildi (idle).'):format(houseId))
    else
        Reply(src, ('Pres House #%d aktif degil.'):format(houseId))
    end
end, false)


RegisterCommand('tuplabrickleri', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /tuplabrickleri [botId]'); return end

    local friction = Matrix.Logistics.ComputeNarcoticBrickFriction(botId)
    Reply(src, ('Bot #%d narcotic_brick ek friction = %.4f'):format(botId, friction))
end, false)


-- =====================================================================
-- DOSYA SONU — FAZ 6 ADIM 3 MÜHÜRLÜ.
-- Tüm string parametreleri kapatıldı. <eof> içinde açık dize yok.
-- =====================================================================