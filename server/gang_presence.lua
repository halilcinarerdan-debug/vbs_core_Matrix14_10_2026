-- =====================================================================
-- MATRIX GANG PRESENCE — SERVER
-- server/gang_presence.lua
--
-- Sokak çete ped'lerini spawn eder, netId'lerini client'lara bildirir.
-- Client tarafı davranışı (senaryo, anim) yönetir.
-- =====================================================================

if not Config.GangPresence or not Config.GangPresence.Enabled then
    print('[GANG_PRESENCE] Devre disi (Config.GangPresence.Enabled = false)')
    return
end

Matrix.GangPresence = Matrix.GangPresence or {}
Matrix.GangPresence.SpawnedPeds = {}
Matrix.GangPresence.ByHood = {}

local function _SpawnPedForHood(hoodKey, hoodCfg, index)
    local seed = (hoodCfg.hood_id * 1000) + index
    local angle = (seed * 37) % 360
    local radius = 15.0 + ((seed * 13) % math.floor(hoodCfg.spawn_radius - 15))
    local rad = math.rad(angle)
    local x = hoodCfg.coords.x + math.cos(rad) * radius
    local y = hoodCfg.coords.y + math.sin(rad) * radius
    local z = hoodCfg.coords.z

    local modelName = hoodCfg.ped_models[((seed - 1) % #hoodCfg.ped_models) + 1]
    local hash = joaat(modelName)

    local ped = CreatePed(0, hash, x, y, z, angle, true, true)
    if not ped or ped == 0 then return nil end

    local ticks = 0
    while not DoesEntityExist(ped) and ticks < 50 do
        Wait(10)
        ticks = ticks + 1
    end
    if not DoesEntityExist(ped) then
        pcall(DeleteEntity, ped)
        return nil
    end

    pcall(SetEntityOrphanMode, ped, 2)
    pcall(SetEntityRoutingBucket, ped, 0)

    local netId = NetworkGetNetworkIdFromEntity(ped)
    return netId, ped
end

function Matrix.GangPresence.SpawnAll()
    if not Config.GangPresence.SpawnOnBoot then return end

    local total = 0
    for hoodKey, hoodCfg in pairs(Config.GangPresence.Neighborhoods) do
        Matrix.GangPresence.ByHood[hoodKey] = {}

        for i = 1, hoodCfg.ped_count do
            local netId, ped = _SpawnPedForHood(hoodKey, hoodCfg, i)
            if netId and netId ~= 0 then
                Matrix.GangPresence.SpawnedPeds[netId] = {
                    hood     = hoodKey,
                    net_id   = netId,
                    entity   = ped,
                    coords   = hoodCfg.coords,
                    behavior = hoodCfg.behaviors[((i - 1) % #hoodCfg.behaviors) + 1],
                }
                Matrix.GangPresence.ByHood[hoodKey][#Matrix.GangPresence.ByHood[hoodKey] + 1] = netId
                total = total + 1
            end
        end
    end

    Matrix.Log('GANG_PRESENCE', '[SPAWN] %d sokak ped\'i 3 mahalleye yerlestirildi.', total)
end

local function _BuildClientPayload()
    local payload = {}
    for netId, info in pairs(Matrix.GangPresence.SpawnedPeds) do
        payload[netId] = {
            hood     = info.hood,
            behavior = info.behavior,
            coords   = {
                x = info.coords.x,
                y = info.coords.y,
                z = info.coords.z,
            },
        }
    end
    return payload
end

CreateThread(function()
    Wait(3000)
    Matrix.GangPresence.SpawnAll()

    -- Tum client'lara ped listesini yolla
    TriggerClientEvent('matrix:client:gangPresence:spawned', -1, _BuildClientPayload())
end)

-- Sonradan giren oyunculara da yolla
AddEventHandler('qbx_core:server:onPlayerLoaded', function(payload)
    local src = type(payload) == 'table' and payload.source or payload
    src = tonumber(src)
    if not src then return end

    CreateThread(function()
        Wait(2000)
        TriggerClientEvent('matrix:client:gangPresence:spawned', src, _BuildClientPayload())
    end)
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or not player.PlayerData then return end
    local src = tonumber(player.PlayerData.source)
    if not src then return end

    CreateThread(function()
        Wait(2000)
        TriggerClientEvent('matrix:client:gangPresence:spawned', src, _BuildClientPayload())
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    for _, info in pairs(Matrix.GangPresence.SpawnedPeds) do
        if info.entity and DoesEntityExist(info.entity) then
            pcall(DeleteEntity, info.entity)
        end
    end
    Matrix.GangPresence.SpawnedPeds = {}
    Matrix.GangPresence.ByHood = {}
end)

exports('GetGangPresencePeds', function() return Matrix.GangPresence.SpawnedPeds end)

Matrix.Log('GANG_PRESENCE', '[BOOT] Server tarafi armed (40 ped, 3 mahalle).')