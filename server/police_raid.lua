-- =====================================================================
-- MATRIX POLICE RAID / server/police_raid.lua
-- Steel Beasts tarzı fiziksel SWAT baskını
-- =====================================================================

Matrix.PoliceRaid = Matrix.PoliceRaid or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local CreateThread              = CreateThread
local Wait                      = Wait
local GetEntityCoords           = GetEntityCoords
local GetHashKey                = GetHashKey
local CreateVehicle             = CreateVehicle
local CreatePedInsideVehicle    = CreatePedInsideVehicle
local TaskLeaveVehicle          = TaskLeaveVehicle
local TaskEnterVehicle          = TaskEnterVehicle
local TaskCombatPed             = TaskCombatPed
local GiveWeaponToPed           = GiveWeaponToPed
local DoesEntityExist           = DoesEntityExist
local DeleteEntity              = DeleteEntity
local SetEntityOrphanMode       = SetEntityOrphanMode
local SetEntityRoutingBucket    = SetEntityRoutingBucket
local SetEntityCoords           = SetEntityCoords
local SetEntityHeading          = SetEntityHeading
local ClearPedTasksImmediately  = ClearPedTasksImmediately
local GetPlayerPed              = GetPlayerPed
local GetPlayers                = GetPlayers

-- ★ [SORUN 1 FIX] Client delegation — server'da SetPedAccuracy vb. no-op olduğu
-- için ped configure'ı NetOwner client'a delege edilir.
local function ConfigurePedOnOwner(ped, config)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    local netId = NetworkGetNetworkIdFromEntity(ped)
    if not netId or netId == 0 then return end
    -- Tüm client'lara broadcast: NetOwner kendi tarafında uygular.
    -- (NetOwner olmayan client'lar handler içinde no-op yapar.)
    TriggerClientEvent('matrix:client:policeRaid:configurePed', -1, netId, config)
end

local ActiveRaids = {}

local RAID_PHASE = {
    APPROACH = 'approach',
    BREACH   = 'breach',
    ENGAGE   = 'engage',
    WITHDRAW = 'withdraw',
}

local function SafeDeleteEntity(handle)
    if not handle or handle == 0 then return end
    pcall(function()
        if DoesEntityExist(handle) then DeleteEntity(handle) end
    end)
end

local function SpawnRaidVehicle(spawnCoords, pedCount, targetBucket)
    targetBucket = tonumber(targetBucket) or 0
    local cfg = Config.PoliceRaid
    local vehHash = GetHashKey(cfg.VehicleModel)
    local pedHash = GetHashKey(cfg.PedModel)

    -- ★ [ONEsync RETRY FIX] Yeni boot'ta CreateVehicle 0 donebilir.
    -- 3 deneme, 500ms aralikla.
    local vehicle = 0
    for attempt = 1, 3 do
        vehicle = CreateVehicle(vehHash, spawnCoords.x, spawnCoords.y, spawnCoords.z, 0.0, true, true)
        if vehicle and vehicle ~= 0 then
            if attempt > 1 then
                Matrix.Log('POLICE_RAID',
                    '[RETRY] CreateVehicle attempt=%d OK handle=%d', attempt, vehicle)
            end
            break
        end
        Wait(500)
    end

    -- ★ [ONEsync FIX] Server-side DoesEntityExist yeni networked araçlar için
    -- gecikmeli/hatalı döner. Sadece handle != 0 kontrolü yeterli.
    if not vehicle or vehicle == 0 then
        SafeDeleteEntity(vehicle)
        return nil, nil, {}
    end
    Wait(300)   -- ★ Spawn otursun diye kısa bekleme (OneSync server-side sync)
    pcall(SetEntityOrphanMode, vehicle, 2)
    pcall(SetEntityRoutingBucket, vehicle, targetBucket)  -- ★ FAZ 2.8: hedef oyuncu bucket'i
    SetEntityCoords(vehicle, spawnCoords.x, spawnCoords.y, spawnCoords.z, false, false, false, false)

    local driver = CreatePedInsideVehicle(vehicle, 4, pedHash, -1, true, true)
    if not driver or driver == 0 then
        SafeDeleteEntity(driver); SafeDeleteEntity(vehicle)
        return nil, nil, {}
    end
    pcall(SetEntityOrphanMode, driver, 2)
    pcall(SetEntityRoutingBucket, driver, targetBucket)   -- ★ FAZ 2.8
    GiveWeaponToPed(driver, GetHashKey(cfg.Weapon), 250, false, true)

    -- ★ [SORUN 1 FIX] Configure client'a delege
    ConfigurePedOnOwner(driver, {
        accuracy          = cfg.PedAccuracy,
        flee_attributes   = 0,
        combat_attributes = 46,
        combat_ability    = 2,
        combat_range      = 2,
        blocking_events   = true,
    })

    local passengers = {}
    for seat = 0, pedCount - 2 do
        local ped = CreatePedInsideVehicle(vehicle, 4, pedHash, seat, true, true)
        if ped and ped ~= 0 then
            pcall(SetEntityOrphanMode, ped, 2)
            pcall(SetEntityRoutingBucket, ped, targetBucket)  -- ★ FAZ 2.8
            GiveWeaponToPed(ped, GetHashKey(cfg.Weapon), 250, false, true)

            -- ★ [SORUN 1 FIX] Configure client'a delege
            ConfigurePedOnOwner(ped, {
                accuracy          = cfg.PedAccuracy,
                flee_attributes   = 0,
                combat_attributes = 46,
                combat_ability    = 2,
                combat_range      = 2,
                blocking_events   = true,
            })
            passengers[#passengers + 1] = ped
        end
    end

    return vehicle, driver, passengers
end

local function StartRaid(trapHouseId, squadSize, breachMethod, escapeWindow)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    -- ★ [NO-PLAYER GUARD] Aktif oyuncu yoksa raid BAŞLATILMAZ.
    -- Server-side CreateVehicle oyuncu yokken 0 döner (OneSync entity
    -- stream edilemez) → 3 deneme başarısız → log spam.
    local playerCount = 0
    for _, plySrc in ipairs(GetPlayers()) do
        if tonumber(plySrc) and tonumber(plySrc) > 0 then
            playerCount = playerCount + 1
        end
    end
    if playerCount == 0 then
        Matrix.Log('POLICE_RAID',
            '[RED] Trap #%d: Raid ertelendi — aktif oyuncu yok (entity stream edilemez).',
            trapHouseId)
        return
    end
    if ActiveRaids[trapHouseId] then
        Matrix.Log('POLICE_RAID', '[ATLANDI] Trap #%d icin zaten aktif raid var.', trapHouseId)
        return
    end

    local house = Matrix.TrapHouses[trapHouseId]
    if not house or not house.coords then
        Matrix.Log('POLICE_RAID', '[HATA] Trap #%d bulunamadi.', trapHouseId)
        return
    end

    -- ★ [AKILLI SPAWN — KARMA ÇÖZÜM]
    -- Hedef HER ZAMAN trap house (rol yapma korunur).
    -- Spawn noktası oyuncuya göre uyarlanır + Z oyuncudan alınır.
    local playerPed = nil
    local playerCoords = nil
    for _, plySrc in ipairs(GetPlayers()) do
        local plyId = tonumber(plySrc)
        local ped = plyId and GetPlayerPed(plyId) or 0
        if ped and ped ~= 0 then
            playerPed = ped
            playerCoords = GetEntityCoords(ped)
            break
        end
    end

    local baseAngle
    if playerCoords then
        local dx = playerCoords.x - house.coords.x
        local dy = playerCoords.y - house.coords.y
        local distToPlayer = math.sqrt(dx*dx + dy*dy)
        if distToPlayer > 5.0 then
            baseAngle = math.deg(math.atan(dy, dx))
        else
            baseAngle = (trapHouseId * 137) % 360
        end
    else
        baseAngle = (trapHouseId * 137) % 360
    end

    local spawnDistance = 25.0
    local spawnAngleRad = math.rad(baseAngle)
    local spawnX = house.coords.x + math.cos(spawnAngleRad) * spawnDistance
    local spawnY = house.coords.y + math.sin(spawnAngleRad) * spawnDistance

    -- ★ [Z FIX] Z HER ZAMAN trap house'un DÜNYA Z'sinden alınır.
    -- Oyuncu interior'dayken (-99 Z) spawn olursa van yer altına gider.
    local spawnZ = house.coords.z + 0.5

    Matrix.Log('POLICE_RAID',
        '[SPAWN] Trap #%d: van (%.1f,%.1f,%.1f) spawn (aci=%.0f°)',
        trapHouseId, spawnX, spawnY, spawnZ, baseAngle)

    if not spawnZ then
        spawnZ = house.coords.z + 0.5  -- fallback
    end

    -- ★ FAZ 2.8: Hedef oyuncunun bucket'ını oku
    -- Oyuncu interior'daysa (bucket > 0), polis de o bucket'a spawn olmalı.
    local targetBucket = 0
    for _, plySrc in ipairs(GetPlayers()) do
        local plyId = tonumber(plySrc)
        if plyId and plyId > 0 then
            local b = GetPlayerRoutingBucket(plyId)
            if b and b > 0 then
                targetBucket = b
                break
            end
        end
    end

    if targetBucket > 0 then
        Matrix.Log('POLICE_RAID',
            '[INTERIOR TESPIT] Oyuncu bucket=%d icinde — polis o bucket\'a spawn edilecek.',
            targetBucket)
    end

    local vehicle, driver, passengers = SpawnRaidVehicle(
        vector3(spawnX, spawnY, spawnZ),
        squadSize or 3,
        targetBucket
    )

    if not vehicle then
        Matrix.Log('POLICE_RAID', '[HATA] Trap #%d icin arac spawn edilemedi.', trapHouseId)
        return
    end

    ActiveRaids[trapHouseId] = {
        trap_house_id    = trapHouseId,
        bucket           = targetBucket or 0,   -- ★ FAZ 2.8
        phase            = RAID_PHASE.APPROACH,
        phase_started_at = Matrix.Now(),
        vehicle          = vehicle,
        driver           = driver,
        passengers       = passengers,
        target_coords    = house.coords,
        escape_window    = escapeWindow or 30,
        breach_method    = breachMethod or 'ram',
        squad_size       = squadSize or 3,
        engaged          = false,
    }

    Matrix.Log('POLICE_RAID',
        '[START] Trap #%d, %d polis, breach=%s, pencere=%ds',
        trapHouseId, squadSize or 3, breachMethod or 'ram', escapeWindow or 30)

    TriggerClientEvent('matrix:client:policeRaid:started', -1)
end

-- ★ FAZ 2.8: Raid bucket senkronizasyonu — ayrı helper (parse güvenli)
local function SyncRaidBucket(trapHouseId, raid)
    local currentBucket = 0
    for _, plySrc in ipairs(GetPlayers()) do
        local plyId = tonumber(plySrc)
        if plyId and plyId > 0 then
            local b = GetPlayerRoutingBucket(plyId)
            if b and b > 0 then
                currentBucket = b
                break
            end
        end
    end

    if currentBucket ~= (raid.bucket or 0) then
        local oldBucket = raid.bucket or 0
        raid.bucket = currentBucket

        if DoesEntityExist(raid.vehicle) then
            pcall(SetEntityRoutingBucket, raid.vehicle, currentBucket)
        end
        if raid.driver and DoesEntityExist(raid.driver) then
            pcall(SetEntityRoutingBucket, raid.driver, currentBucket)
        end
        for _, ped in ipairs(raid.passengers) do
            if DoesEntityExist(ped) then
                pcall(SetEntityRoutingBucket, ped, currentBucket)
            end
        end

        Matrix.Log('POLICE_RAID',
            '[BREACH-BUCKET] Trap #%d: polisler bucket %d -> %d tasindi.',
            trapHouseId, oldBucket, currentBucket)
    end
end

local function ProcessRaid(trapHouseId, raid)
    local now = Matrix.Now()
    local elapsed = now - raid.phase_started_at

    -- ★ FAZ 2.8: Dinamik bucket takibi (her tick)
    SyncRaidBucket(trapHouseId, raid)

    if not DoesEntityExist(raid.vehicle) then
        Matrix.Log('POLICE_RAID', '[KAYIP] Trap #%d araci yok oldu, iptal.', trapHouseId)
        return true
    end

    if raid.phase == RAID_PHASE.APPROACH then
        local nearestPed = nil
        for _, plySrc in ipairs(GetPlayers()) do
            local p = GetPlayerPed(tonumber(plySrc))
            if p and p ~= 0 then nearestPed = p break end
        end
        if nearestPed then
            local targetCoords = GetEntityCoords(nearestPed)
            -- ★ INTERIOR Z FIX: Oyuncu interior bucket'taysa Z -99 olabilir.
            -- Dünya Z'sine sabitle (trap house coords'u referans).
            if targetCoords.z < -50.0 then
                targetCoords = vector3(targetCoords.x, targetCoords.y, raid.target_coords.z or 30.0)
            end
            raid.target_coords = targetCoords
        end

        local vCoords = GetEntityCoords(raid.vehicle)
        local dist = #(vCoords - raid.target_coords)

        if dist <= Config.PoliceRaid.ArrivalRadius then
            raid.phase = RAID_PHASE.BREACH
            raid.phase_started_at = now
            Matrix.Log('POLICE_RAID', '[VARDI] Trap #%d: Van kapiya dayandi.', trapHouseId)
        elseif elapsed > 15 then
            Matrix.Log('POLICE_RAID', '[ZAMAN ASIMI] Trap #%d: Van 15s icinde varamadi.', trapHouseId)
            return true
        else
            local vehNetId = NetworkGetNetworkIdFromEntity(raid.vehicle)
            if vehNetId and vehNetId ~= 0 then
                TriggerClientEvent('matrix:client:policeRaid:approachTarget', -1,
                    vehNetId,
                    raid.target_coords.x,
                    raid.target_coords.y,
                    raid.target_coords.z,
                    Config.PoliceRaid.ApproachSpeed)
            end
        end

    elseif raid.phase == RAID_PHASE.BREACH then
        if elapsed >= (Config.PoliceRaid.BreachDelayMs / 1000) then
            pcall(ClearPedTasksImmediately, raid.driver)
            for _, ped in ipairs(raid.passengers) do
                pcall(TaskLeaveVehicle, ped, raid.vehicle, 4160)
            end

            CreateThread(function()
                Wait(2500)

                local vCoords = GetEntityCoords(raid.vehicle)
                local groundZ = vCoords.z
                for _, plySrc in ipairs(GetPlayers()) do
                    local plyId = tonumber(plySrc)
                    local plyPed = plyId and GetPlayerPed(plyId) or 0
                    if plyPed and plyPed ~= 0 then
                        groundZ = GetEntityCoords(plyPed).z
                        break
                    end
                end

                local count = #raid.passengers
                for i, ped in ipairs(raid.passengers) do
                    if DoesEntityExist(ped) then
                        local angle = (360.0 / count) * (i - 1)
                        local rad = math.rad(angle)
                        local px = vCoords.x + math.cos(rad) * 3.5
                        local py = vCoords.y + math.sin(rad) * 3.5
                        pcall(SetEntityCoords, ped, px, py, groundZ, false, false, false, false)

                        local dx = raid.target_coords.x - px
                        local dy = raid.target_coords.y - py
                        pcall(SetEntityHeading, ped, math.deg(math.atan(dy, dx)) - 90.0)
                    end
                end
                Matrix.Log('POLICE_RAID', '[MEVZI] Trap #%d: %d polis cevre emniyetini aldi.',
                    trapHouseId, count)
            end)

            raid.phase = RAID_PHASE.ENGAGE
            raid.phase_started_at = now
            Matrix.Log('POLICE_RAID', '[MEVZI] Trap #%d: Polisler konuslandi, %ds beklenecek.',
                trapHouseId, raid.escape_window)
        end

    elseif raid.phase == RAID_PHASE.ENGAGE then
        if not raid.engaged then
            for _, src in ipairs(GetPlayers()) do
                local plyPed = GetPlayerPed(tonumber(src))
                if plyPed and plyPed ~= 0 then
                    local d = #(GetEntityCoords(plyPed) - raid.target_coords)
                    if d < 40.0 then
                        for _, ped in ipairs(raid.passengers) do
                            if DoesEntityExist(ped) then
                                pcall(TaskCombatPed, ped, plyPed, 0, 16)
                            end
                        end
                        raid.engaged = true
                        Matrix.Log('POLICE_RAID', '[CATISMA] Trap #%d: Polisler hedefe kilitlendi.', trapHouseId)
                        break
                    end
                end
            end
        end

        if elapsed >= raid.escape_window then
            raid.phase = RAID_PHASE.WITHDRAW
            raid.phase_started_at = now
            for _, ped in ipairs(raid.passengers) do
                if DoesEntityExist(ped) then
                    pcall(TaskEnterVehicle, ped, raid.vehicle, 8000, -2, 1.0, 1, 0)
                end
            end
            Matrix.Log('POLICE_RAID', '[CEKILME] Trap #%d: Mudahale tamamlandi, ekip cekiliyor.', trapHouseId)
        end

    elseif raid.phase == RAID_PHASE.WITHDRAW then
        if elapsed >= 8 then
            Matrix.Log('POLICE_RAID', '[BITTI] Trap #%d: Ekip bolgeden ayrildi.', trapHouseId)
            return true
        end
    end

    return false
end

local function CleanupRaid(trapHouseId, raid)
    SafeDeleteEntity(raid.driver)
    for _, ped in ipairs(raid.passengers) do
        SafeDeleteEntity(ped)
    end
    SafeDeleteEntity(raid.vehicle)
    ActiveRaids[trapHouseId] = nil
    TriggerClientEvent('matrix:client:policeRaid:ended', -1)
    Matrix.Log('POLICE_RAID', '[TEMIZLIK] Trap #%d: Tum entityler silindi.', trapHouseId)
end

CreateThread(function()
    Wait(3000)
    while true do
        Wait(500)
        local toRemove = {}
        for trapHouseId, raid in pairs(ActiveRaids) do
            local ok, doneOrErr = pcall(ProcessRaid, trapHouseId, raid)
            if not ok then
                Matrix.Log('POLICE_RAID', '[HATA] Trap #%d tick hatasi: %s', trapHouseId, tostring(doneOrErr))
                toRemove[#toRemove + 1] = trapHouseId
            elseif doneOrErr then
                toRemove[#toRemove + 1] = trapHouseId
            end
        end
        for _, trapHouseId in ipairs(toRemove) do
            local raid = ActiveRaids[trapHouseId]
            if raid then CleanupRaid(trapHouseId, raid) end
        end
    end
end)

AddEventHandler('matrix:internal:raidIssued', function(trapHouseId, escapeWindow, breachMethod, squadSize)
    -- ★ [DIAGNOSTIC ISOLATION] Diagnostics çalışırken gerçek raid başlatılmaz.
    if Matrix.Diagnostics and Matrix.Diagnostics.IsRunning then
        return
    end
    StartRaid(trapHouseId, squadSize, breachMethod, escapeWindow)
end)

RegisterCommand('police_raid_test', function(src, args)
    local trapHouseId = tonumber(args[1]) or 1
    local house = Matrix.TrapHouses[trapHouseId]
    if not house or not house.coords then
        Matrix.Log('POLICE_RAID', '[HATA] Trap #%d bulunamadi.', trapHouseId)
        return
    end

    -- ★ [INTERIOR GUARD] Oyuncu herhangi bir trap house interior'ındaysa
    -- raid BAŞLATILMAZ. Aksi halde van yer altında (-99 Z) spawn olur.
    if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse then
        for _, plySrc in ipairs(GetPlayers()) do
            local plyId = tonumber(plySrc)
            if plyId and Matrix.TrapHouseInterior.GetPlayerTrapHouse(plyId) then
                Matrix.Log('POLICE_RAID',
                    '[RED] src=%d interior icinde — raid baslatilmadi (yuzeyde degil).',
                    plyId)
                return
            end
        end
    end
    if house.raid_ordered then
        house.raid_ordered = false
        Matrix.Log('POLICE_RAID', '[TEST] Trap #%d raid_ordered sifirlandi.', trapHouseId)
    end
    StartRaid(trapHouseId, Config.Bureau.RaidBaseSquadSize, 'ram', 30)
end, false)

Matrix.Log('POLICE_RAID', '[BOOT] Steel Beasts tarzi SWAT baskini armed.')