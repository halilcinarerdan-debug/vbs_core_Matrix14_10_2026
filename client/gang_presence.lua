-- =====================================================================
-- MATRIX GANG PRESENCE — CLIENT
-- client/gang_presence.lua
-- =====================================================================

if not Config.GangPresence or not Config.GangPresence.Enabled then
    return
end

local TrackedPeds = {}
local LastApplied = {}
local PendingPeds = {}

local BEHAVIOR_REFRESH_MS = 45000
local PENDING_TIMEOUT_MS  = 120000

local function IsPedValid(ped)
    if not ped or ped == 0 then return false end
    return DoesEntityExist(ped)
end

local function ApplyBehavior(ped, behaviorName)
    if not IsPedValid(ped) then return false end
    if IsPedInAnyVehicle(ped, false) then return false end
    if IsPedDeadOrDying(ped, true) then return false end

    ClearPedTasks(ped)
    pcall(TaskStartScenarioInPlace, ped, behaviorName, 0, true)
    return true
end

local function TryStreamPed(netId, info)
    if info.coords then
        local playerCoords = GetEntityCoords(PlayerPedId())
        local dx = playerCoords.x - info.coords.x
        local dy = playerCoords.y - info.coords.y
        local dz = playerCoords.z - info.coords.z
        local distSq = dx*dx + dy*dy + dz*dz
        if distSq > 40000.0 then
            return false
        end
    end

    local ped = NetworkGetEntityFromNetworkId(netId)
    if not IsPedValid(ped) then return false end
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCanRagdoll(ped, false)

    TrackedPeds[netId] = {
        net_id   = netId,
        entity   = ped,
        behavior = info.behavior,
        hood     = info.hood,
    }
    if ApplyBehavior(ped, info.behavior) then
        LastApplied[netId] = GetGameTimer()
    end
    return true
end

RegisterNetEvent('matrix:client:gangPresence:spawned', function(spawnedPeds)
    if type(spawnedPeds) ~= 'table' then return end

    TrackedPeds = {}
    PendingPeds = {}

    local now = GetGameTimer()
    local tracked = 0
    local pending = 0

    for netId, info in pairs(spawnedPeds) do
        if type(netId) == 'number' and type(info) == 'table' then
            if TryStreamPed(netId, info) then
                tracked = tracked + 1
            else
                PendingPeds[netId] = {
                    info          = info,
                    tries         = 0,
                    first_seen_at = now,
                }
                pending = pending + 1
            end
        end
    end

    print(('[GANG_PRESENCE:CLIENT] %d sokak ped\'i takibe alindi (%d stream bekliyor).')
        :format(tracked, pending))
end)

CreateThread(function()
    while true do
        Wait(1500)

        if next(PendingPeds) == nil then
            Wait(3000)
        else
            local now = GetGameTimer()
            local resolved = {}

            for netId, entry in pairs(PendingPeds) do
                if (now - entry.first_seen_at) > PENDING_TIMEOUT_MS then
                    resolved[netId] = true
                else
                    entry.tries = entry.tries + 1
                    if TryStreamPed(netId, entry.info) then
                        resolved[netId] = true
                        print(('[GANG_PRESENCE:CLIENT] Ped stream oldu: netId=%d (%s)'):format(netId, entry.info.hood))
                    end
                end
            end

            for netId in pairs(resolved) do
                PendingPeds[netId] = nil
            end
        end
    end
end)

CreateThread(function()
    while true do
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local now = GetGameTimer()
        local anyClose = false

        for netId, info in pairs(TrackedPeds) do
            local ped = info.entity

            if not IsPedValid(ped) then
                TrackedPeds[netId] = nil
                LastApplied[netId] = nil
            else
                local pedCoords = GetEntityCoords(ped)
                local dist = #(pedCoords - playerCoords)

                if dist < 25.0 then
                    anyClose = true
                    local last = LastApplied[netId] or 0
                    if (now - last) > BEHAVIOR_REFRESH_MS then
                        if ApplyBehavior(ped, info.behavior) then
                            LastApplied[netId] = now
                        end
                    end
                end
            end
        end

        if anyClose then
            Wait(500)
        else
            Wait(2000)
        end
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    TrackedPeds = {}
    LastApplied = {}
    PendingPeds = {}
end)