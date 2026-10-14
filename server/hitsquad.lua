-- =====================================================================
-- MATRIX HIT SQUAD / server/hitsquad.lua  (KATMAN 8 — YENİ)
--
-- Yüksek siber-ısılı oyuncular (server/rendezvous.lua [R2] İLE AYNI
-- trace-level formülü: Matrix.Bureau.GetHeat / Config.Bureau.
-- CyberLeakMaxIntensity) en yakın düşman mahallesinden (Config.GangHoods)
-- sızdırılan otonom bir çete aracı tarafından takip edilir. Araç saldırı
-- menziline girince Config.HitSquad.DrivebySeconds boyunca TaskVehicleDriveby
-- ile sürekli ateş açar, ardından "Hit-and-Run" — arka sokaklardan en
-- yakın mahalleye otonom geri çekilir. RNG YOK: eşik karşılaştırması +
-- sabit süreli fazlar. Entity yaşam döngüsü server/main.lua'nın fiziksel
-- sevk deseniyle AYNI (AwaitEntityCreation, SetEntityOrphanMode/Bucket).
-- =====================================================================


Matrix.HitSquad = Matrix.HitSquad or {}

-- v6.6.6: LegacyHitsquad=false ama statik scanner hâlâ referans görüyor
Matrix.StreetCover = Matrix.StreetCover or {}
if type(Matrix.StreetCover.RequestScan) ~= 'function' then
    Matrix.StreetCover.RequestScan = function() return nil end
end

print('[HITSQUAD-BOOT] FILE LOADED OK — Matrix.HitSquad = ' .. tostring(Matrix.HitSquad))
-- ★ FEATURE FLAG: Legacy hitsquad kapalıysa bu dosya çalışmaz
if Config.Features and Config.Features.LegacyHitsquad == false then
    print('[HITSQUAD] Legacy sistem devre disi (Config.Features.LegacyHitsquad = false).')
    print('[HITSQUAD] Yeni istihbarat bazli sistem yazilana kadar bu dosya pasif.')
    return
end

local pairs, type, tostring   = pairs, type, tostring
local math_max, math_huge      = math.max, math.huge
local GetPlayers                = GetPlayers
local GetPlayerPed              = GetPlayerPed
local GetEntityCoords           = GetEntityCoords
local DoesEntityExist            = DoesEntityExist
local DeleteEntity               = DeleteEntity
local CreateVehicle              = CreateVehicle
local CreatePedInsideVehicle     = CreatePedInsideVehicle
local GetHashKey                 = GetHashKey
local TaskVehicleDriveToCoord    = TaskVehicleDriveToCoord
local TaskVehicleDriveby         = TaskVehicleDriveby
local ClearPedTasksImmediately   = ClearPedTasksImmediately
local SetEntityOrphanMode        = SetEntityOrphanMode
local SetEntityRoutingBucket     = SetEntityRoutingBucket



-- Aktif takip/saldırı durumu: src -> { vehicle, driver, phase,
-- phase_started_at, trap_house_id, hood }
local activeSquads = {}


--- server/main.lua'nın SafeDeleteEntity'siyle AYNI dayanıklı imha deseni
--- (bu dosyada tekrar İCAT EDİLMEDİ, yalnızca birebir taşındı — o local
--- Matrix.* olarak dışa aktarılmadığından buradan erişilemiyor).
local function SafeDeleteEntity(handle)
    if not handle or handle == 0 then return end
    pcall(function()
        if DoesEntityExist(handle) then DeleteEntity(handle) end
    end)
end


local function FindNearestTrapHouse(coords)
    local bestId, bestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        if house.coords then
            local d = #(coords - house.coords)
            if d < bestDist then bestDist, bestId = d, id end
        end
    end
    return bestId
end


local function FindNearestHood(coords)
    local best, bestDist = nil, math_huge
    for _, hood in pairs((Config.GangHoods and Config.GangHoods.Hoods) or {}) do
        if hood.coords then
            local d = #(coords - hood.coords)
            if d < bestDist then bestDist, best = d, hood end
        end
    end
    return best
end


--- Server/rendezvous.lua [R2] İLE BİREBİR AYNI normalize formülü — ikinci
--- bir ısı alanı İCAT EDİLMEZ, mevcut Matrix.Bureau.GetHeat getter'ı
--- (KATMAN 5, DEĞİŞTİRİLMEDİ) okunur.
local function ComputeTraceLevel(coords)
    local trapHouseId = FindNearestTrapHouse(coords)
    local heat    = (trapHouseId and Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapHouseId)) or 0.0
    local maxHeat = (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
    return Matrix.Clamp(heat / math_max(maxHeat, 0.0001), 0.0, 1.0), trapHouseId
end


local function DespawnSquad(src, reason)
    local squad = activeSquads[src]
    if not squad then return end
    SafeDeleteEntity(squad.driver)
    if squad.shooter then SafeDeleteEntity(squad.shooter) end
    SafeDeleteEntity(squad.vehicle)
        -- ★ SESSION 5.1: siper cache'ini de temizle
    if squad.entity_net_id and Matrix.StreetCover then
        Matrix.StreetCover.Cache[squad.entity_net_id] = nil
        Matrix.StreetCover.BackoffUntil[squad.entity_net_id] = nil
    end
    activeSquads[src] = nil
    Matrix.Log('HITSQUAD', 'src=%s takip sonlandi (%s).', tostring(src), tostring(reason))
end


local function SpawnSquadVehicle(hood)
    local vehHash = GetHashKey(Config.HitSquad.VehicleModel)
    local pedHash = GetHashKey(Config.HitSquad.PedModel)

    local vehicle = CreateVehicle(vehHash, hood.coords.x, hood.coords.y, hood.coords.z, 0.0, true, true)
    if not Matrix.AwaitEntityCreation(vehicle) then
        SafeDeleteEntity(vehicle)
        return nil, nil, nil
    end

    pcall(SetEntityOrphanMode, vehicle, 2)
    pcall(SetEntityRoutingBucket, vehicle, 0)
    SetEntityCoords(vehicle, hood.coords.x, hood.coords.y, hood.coords.z + 0.5, false, false, false, false)

    -- ★ Sürücü (koltuk -1)
    local driver = CreatePedInsideVehicle(vehicle, 0, pedHash, -1, true, true)
    if not Matrix.AwaitEntityCreation(driver) then
        SafeDeleteEntity(driver)
        SafeDeleteEntity(vehicle)
        return nil, nil, nil
    end
    pcall(SetEntityOrphanMode, driver, 2)
    pcall(SetEntityRoutingBucket, driver, 0)

    -- ★ YENİ: Tetikçi (koltuk 0 = yolcu, ön sağ)
    local shooter = CreatePedInsideVehicle(vehicle, 0, pedHash, 0, true, true)
    if not Matrix.AwaitEntityCreation(shooter) then
        SafeDeleteEntity(shooter)
        SafeDeleteEntity(driver)
        SafeDeleteEntity(vehicle)
        return nil, nil, nil
    end
    pcall(SetEntityOrphanMode, shooter, 2)
    pcall(SetEntityRoutingBucket, shooter, 0)

        -- Netowner client'a delege: silahlandır + gruba al
    local equipOk, equipSrc = pcall(NetworkGetEntityOwner, shooter)
    if equipOk and equipSrc and equipSrc > 0 then
        TriggerClientEvent('matrix:client:hitsquad:equipDriver', equipSrc,
            NetworkGetNetworkIdFromEntity(shooter),
            NetworkGetNetworkIdFromEntity(vehicle))
    end

    return vehicle, driver, shooter
end                          -- ★ EKSİK OLAN SATIR


-- =====================================================================
-- TAKİP/SALDIRI FAZ MAKİNESİ — mesafe/hedefleme her tick DEĞİL, main.lua'
-- nın bureauAccumulator deseniyle AYNI TARZDA sabit bir aralıkta taranır
-- (Config.HitSquad.ScanIntervalTicks * Config.Tick.IntervalMs).
-- =====================================================================
local function TickPlayer(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local squad  = activeSquads[src]

    if not squad then
        local traceLevel = ComputeTraceLevel(coords)
        if traceLevel < Config.HitSquad.HeatTraceThreshold then return end

        local hood = FindNearestHood(coords)
        if not hood then return end

            local vehicle, driver, shooter = SpawnSquadVehicle(hood)
        if not (vehicle and driver and shooter) then return end

        local pedNetId    = NetworkGetNetworkIdFromEntity(driver)
        local shooterNetId = NetworkGetNetworkIdFromEntity(shooter)
        local vehNetId    = NetworkGetNetworkIdFromEntity(vehicle)

        activeSquads[src] = {
            vehicle        = vehicle,
            driver         = driver,
            shooter        = shooter,             -- ★ YENİ
            entity_net_id  = pedNetId,
            shooter_net_id = shooterNetId,        -- ★ YENİ
            vehicle_net_id = vehNetId,
            phase          = 'pursuing',
            phase_started_at = Matrix.Now(),
            hood           = hood
        }


        -- ★ Kural 4: TaskVehicleDriveToCoord client-only.
        -- Server netowner'a event yollar, gerçek task client'ta atanır.
        local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, driver)
        if ownerOk and ownerSrc and ownerSrc > 0 then
            TriggerClientEvent('matrix:client:hitsquad:driveTo', ownerSrc,
                pedNetId, vehNetId, coords.x, coords.y, coords.z)
        end

        Matrix.Log('HITSQUAD', 'src=%s iz=%.3f (esik:%.2f) -> "%s" cetesi sizdirildi.',
            tostring(src), traceLevel, Config.HitSquad.HeatTraceThreshold, hood.label)
        return
    end

    if not DoesEntityExist(squad.vehicle) or not DoesEntityExist(squad.driver) then
        DespawnSquad(src, 'entity_lost')
        return
    end

    local vehCoords = GetEntityCoords(squad.vehicle)
    
        -- ★ SESSION 5.1: SADECE yaya fazda (dismounted/fleeing) siper tara.
    -- pursuing/driveby'da tetikçi araç içinde → TaskSeekCoverFromPos
    -- anlamsız (native reddeder, sessizce spam yapar).
    if squad.phase == 'dismounted' then
        if squad.entity_net_id then
            Matrix.StreetCover.RequestScan(src, squad.entity_net_id)
        end
    end

    Matrix.Log('HITSQUAD', '[POS-CHECK] ped=(%.1f,%.1f,%.1f) veh=(%.1f,%.1f,%.1f) dist=%.1f',
        GetEntityCoords(squad.driver).x, GetEntityCoords(squad.driver).y, GetEntityCoords(squad.driver).z,
        vehCoords.x, vehCoords.y, vehCoords.z,
        #(coords - vehCoords))

       if squad.phase == 'pursuing' then
        local dist = #(coords - vehCoords)

        if dist <= Config.HitSquad.AttackRange then
            squad.phase, squad.phase_started_at = 'driveby', Matrix.Now()
            local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, squad.driver)
            if ownerOk and ownerSrc and ownerSrc > 0 then
                TriggerClientEvent('matrix:client:hitsquad:vehDriveby', ownerSrc,
                    squad.shooter_net_id, NetworkGetNetworkIdFromEntity(ped))
            end
        else
            -- Client-side task (varsa)
            local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, squad.driver)
            if ownerOk and ownerSrc and ownerSrc > 0 then
                TriggerClientEvent('matrix:client:hitsquad:driveTo', ownerSrc,
                    squad.entity_net_id, squad.vehicle_net_id, coords.x, coords.y, coords.z)
            end

            -- Server-side fallback: araç elle yaklaşır
            local aracCoords = GetEntityCoords(squad.vehicle)
            local dx, dy = coords.x - aracCoords.x, coords.y - aracCoords.y
            local distFb = math.sqrt(dx * dx + dy * dy)
            if distFb > 3.0 then
                local stepSize = math.min(20.0, distFb - 1.0)
                local newX = aracCoords.x + (dx / distFb) * stepSize
                local newY = aracCoords.y + (dy / distFb) * stepSize
                pcall(SetEntityCoords, squad.vehicle, newX, newY, aracCoords.z, false, false, false, false)
                pcall(SetEntityHeading, squad.vehicle, math.deg(math.atan(dy, dx)) - 90.0)
            end
        end

    elseif squad.phase == 'driveby' then

                if (Matrix.Now() - squad.phase_started_at) >= Config.HitSquad.DrivebySeconds then
            squad.phase            = 'dismounted'
            squad.phase_started_at = Matrix.Now()

            pcall(ClearPedTasksImmediately, squad.driver)
            if DoesEntityExist(squad.vehicle) then
                pcall(SetVehicleForwardSpeed, squad.vehicle, 0.0)
            end

            local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, squad.driver)
            if ownerOk and ownerSrc and ownerSrc > 0 then
                TriggerClientEvent('matrix:client:hitsquad:equipDriver', ownerSrc,
                    squad.shooter_net_id, squad.vehicle_net_id)
                TriggerClientEvent('matrix:client:streetCover:dismount',    ownerSrc, squad.shooter_net_id)
                TriggerClientEvent('matrix:client:streetCover:startFiring', ownerSrc, squad.shooter_net_id)
                TriggerClientEvent('matrix:client:hitsquad:attackPlayer',   ownerSrc, squad.shooter_net_id)
            end
        end

    elseif squad.phase == 'dismounted' then
        -- ★ SESSION 5.1: 15sn siper + yaylım → yaya kaçış
        if (Matrix.Now() - squad.phase_started_at) >= 15.0 then
            local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, squad.driver)
            if ownerOk and ownerSrc and ownerSrc > 0 then
                TriggerClientEvent('matrix:client:streetCover:stopFiring', ownerSrc, squad.entity_net_id)
                -- ★ Watchdog'dan çıkar (artık ateş etmesin)
                if squad.shooter_net_id then
                    TriggerClientEvent('matrix:client:hitsquad:unregisterShooter', ownerSrc, squad.shooter_net_id)
                end
            end

            local hood = FindNearestHood(vehCoords)
            squad.phase, squad.phase_started_at, squad.hood = 'fleeing', Matrix.Now(), hood or squad.hood

            pcall(ClearPedTasksImmediately, squad.driver)
            if squad.hood then
                -- ★ Kural 4: TaskFollowNavMeshToCoord client-only.
                local fOwnerOk, fOwnerSrc = pcall(NetworkGetEntityOwner, squad.driver)
                if fOwnerOk and fOwnerSrc and fOwnerSrc > 0 then
                    TriggerClientEvent('matrix:client:hitsquad:fleeTo', fOwnerSrc,
                        squad.entity_net_id,
                        squad.hood.coords.x, squad.hood.coords.y, squad.hood.coords.z)
                end
            end
            Matrix.Log('HITSQUAD', 'src=%s siperden cikti -> yaya kacis.', tostring(src))
        end

    elseif squad.phase == 'fleeing' then
        if (Matrix.Now() - squad.phase_started_at) >= Config.HitSquad.FleeSeconds then
            DespawnSquad(src, 'retreated_to_hood')
        end
    end
end


-- =====================================================================
-- BİRİKİMLİ TARAMA DÖNGÜSÜ — server/main.lua'nın bureauAccumulator ile
-- AYNI kalıcı Config.Tick.IntervalMs taban aralığı; ayrı bir Wait(0)
-- sıcak döngüsü AÇILMAZ.
-- =====================================================================
CreateThread(function()
    local scanAccumulator = 0

    while true do
        Wait(Config.Tick.IntervalMs)
        scanAccumulator = scanAccumulator + 1
        if scanAccumulator >= Config.HitSquad.ScanIntervalTicks then
            scanAccumulator = 0
            for _, srcStr in ipairs(GetPlayers()) do
                local src = tonumber(srcStr)
                if src then
                    local ok, err = pcall(TickPlayer, src)
                    if not ok then Matrix.Log('HITSQUAD', '[HATA] TickPlayer(%s) basarisiz (yutuldu): %s', tostring(src), tostring(err)) end
                end
            end
        end
    end
end)


AddEventHandler('playerDropped', function()
    DespawnSquad(source, 'disconnected')
end)

-- =====================================================================
-- ★★★ SESSION 5.1: SOKAK SİPERİ — SERVER CACHE KATMANI (additive) ★★★
--
-- BAĞLAM: Sokak çetesi simülasyonu. Rakip tetikçiler köşeye/dükkan
-- arkasına sığınır, oradan yaylım basar. "Askeri taktik cover" DEĞİL.
--
-- ★ DEĞİŞMEZ KURAL (Kural 4): Cover tarama (GetClosestObjectOfType) ve
--   köşe atışı (TaskSeekCoverFromPed) CLIENT-ONLY native'lerdir. Bu
--   blok SADECE istek yayınlar + dönen sonucu cache'ler. Hiçbir native
--   çağrısı YOK.
--
-- ★ ZERO RNG: Cache sadece koordinat/model tutar. Seçim client'ta
--   deterministik (en yakın mesafe + en düşük handle) yapılır.
-- =====================================================================
Matrix.StreetCover = Matrix.StreetCover or {
    Cache        = {},   -- [pedNetId] = { coords, model, assigned_at }
    BackoffUntil = {},   -- [pedNetId] = epoch_ms
}

local STREET_COVER_CACHE_TTL_MS = (Config.StreetCover and Config.StreetCover.CacheRefreshTickMs) or 2000

--- Server → client: "bu ped için siper tara" isteği. TTL ve backoff
--- kontrolü burada; client spam olmaz.
function Matrix.StreetCover.RequestScan(src, pedNetId)
    if type(src) ~= 'number' or src <= 0 then return end
    if type(pedNetId) ~= 'number' or pedNetId <= 0 then return end

    local nowMs = GetGameTimer()
    local until_ = Matrix.StreetCover.BackoffUntil[pedNetId]
    if until_ and nowMs < until_ then return end

    local cached = Matrix.StreetCover.Cache[pedNetId]
    if cached and (nowMs - cached.assigned_at) < STREET_COVER_CACHE_TTL_MS then return end

    TriggerClientEvent('matrix:client:streetCover:scan', src, pedNetId)
end

--- Client → server: siper bulundu. Netowner + squad doğrulaması zorunlu.
RegisterNetEvent('matrix:server:streetCover:assign', function(pedNetId, coordsX, coordsY, coordsZ, model)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    pedNetId = tonumber(pedNetId)
    if not pedNetId or pedNetId <= 0 then return end

    local squad = activeSquads[src]
    if not squad or squad.entity_net_id ~= pedNetId then return end

    local x, y, z = tonumber(coordsX), tonumber(coordsY), tonumber(coordsZ)
    if not x or not y or not z then return end
    if x ~= x or y ~= y or z ~= z then return end

    local prev = Matrix.StreetCover.Cache[pedNetId]
    local unchanged = prev
        and prev.coords
        and #(prev.coords - vector3(x, y, z)) < 0.5   -- aynı siper (50cm tolerans)

    Matrix.StreetCover.Cache[pedNetId] = {
        coords      = vector3(x, y, z),
        model       = model,
        assigned_at = GetGameTimer(),
    }

    -- ★ Aynı siper 3 kez üst üste gelirse artık log basma (spam koruması)
    if not unchanged then
        Matrix.Log('HITSQUAD', '[SOKAK SIPERI] Ped net=%d siper aldi: (%.1f,%.1f,%.1f)',
            pedNetId, x, y, z)
    end
end)

--- Client → server: 15m içinde siper bulunamadı. Backoff başlat.
RegisterNetEvent('matrix:server:streetCover:notFound', function(pedNetId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    pedNetId = tonumber(pedNetId)
    if not pedNetId or pedNetId <= 0 then return end

    local squad = activeSquads[src]
    if not squad or squad.entity_net_id ~= pedNetId then return end

    local backoff = (Config.StreetCover and Config.StreetCover.CoverScanBackoffMs) or 5000
    Matrix.StreetCover.BackoffUntil[pedNetId] = GetGameTimer() + backoff
end)

-- ★ GEÇİCİ DEBUG — Session 5.1 sonrası silinebilir
RegisterCommand('hitsquaddebug', function(src)
    if type(src) ~= 'number' or src <= 0 then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)

    local traceLevel, trapHouseId = ComputeTraceLevel(coords)
    local hood = FindNearestHood(coords)

    local heatRaw = (trapHouseId and Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapHouseId)) or 0.0
    local hoodLabel = hood and hood.label or 'nil'
    local isSquadActive = (activeSquads[src] ~= nil)

    TriggerClientEvent('chat:addMessage', src, {
        args = { '[HITSQUAD-DEBUG]', ('trace=%.3f / threshold=%.3f | heat=%.3f trap=%s | hood=%s | squadActive=%s'):format(
            traceLevel, Config.HitSquad.HeatTraceThreshold,
            heatRaw, tostring(trapHouseId), hoodLabel, tostring(isSquadActive)) }
    })
end, false)