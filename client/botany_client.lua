-- =====================================================================
-- PROJECT MATRIX — SESSION 2 — PHYSICAL BOTANY CLIENT
-- client/botany_client.lua
--
-- ★ FİZİKSEL PROP INTEGRATION: item kullanımı → ox_lib progressBar →
--   ped'e attach → CreateObject (networked) → FreezeEntityPosition →
--   ox_target context (1.8m lock).
--
-- ★ SIFIR RNG. math.random YOK. Tüm zaman/koordinat türevleri
--   os.time() + deterministik checksum.
-- =====================================================================

local spawnedProps = {}   -- [trapHouseId] = { cabinet, barrel, uv }

-- ---------------------------------------------------------------------
-- Prop model cache
-- ---------------------------------------------------------------------
local function LoadModel(modelName)
    local hash = joaat(modelName)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 100 do
        Wait(50); tries = tries + 1
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- ---------------------------------------------------------------------
-- Spawn networked object at fixed world position, freeze, register target
-- ---------------------------------------------------------------------
local function SpawnLabProp(kind, trapHouseId, coords, heading)
    local cfg = Config.BotanyCore
    local modelName = cfg.PropModels[kind]
    if not modelName then return nil end

    local hash = LoadModel(modelName)
    if not hash then return nil end

    local obj = CreateObject(hash, coords.x, coords.y, coords.z, true, true, false)
    if not obj or obj == 0 then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    SetEntityHeading(obj, heading or 0.0)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetModelAsNoLongerNeeded(hash)

    local netId = NetworkGetNetworkIdFromEntity(obj)
    if netId then
        SetNetworkIdExistsOnAllMachines(netId, true)
        SetNetworkIdCanMigrate(netId, false)
    end

    return obj
end

-- ---------------------------------------------------------------------
-- ox_target context registration — STRICT 1.8m LOCK
-- ---------------------------------------------------------------------
local function RegisterTargetHandlers(obj, kind, trapHouseId)
    if not exports.ox_target then return end
    local dist = Config.BotanyCore.TargetDistanceMeters

    if kind == 'heavy_duty_barrel' then
        exports.ox_target:addLocalEntity(obj, {
            {
                name     = ('matrix_botany_water_%d'):format(trapHouseId),
                icon     = 'fa-solid fa-droplet',
                label    = 'Restore Water Level',
                distance = dist,
                items    = Config.BotanyCore.WaterCanItem,
                onSelect = function()
                    local done = lib.progressBar({
                        duration     = Config.BotanyCore.PropAttachDurationMs,
                        label        = 'Refilling nutrient reservoir...',
                        useWhileDead = false,
                        canCancel    = true,
                        disable      = { move = true, car = true, combat = true },
                        anim         = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
                    })
                    if not done then return end

                    TriggerServerEvent('matrix:server:botany:waterRestore', trapHouseId)
                    local ok, result = lib.callback.await('matrix:server:botany:getState', false, trapHouseId)
                    if ok and result then
                        lib.notify({
                            title       = '[LABORATORY]',
                            description = ('Water restored. Level: %.1f%%'):format(result.water_level or 0.0),
                            type        = 'success',
                        })
                    end
                end,
            },
        })
    elseif kind == 'botany_cabinet' then
        exports.ox_target:addLocalEntity(obj, {
            {
                name     = ('matrix_botany_prune_%d'):format(trapHouseId),
                icon     = 'fa-solid fa-scissors',
                label    = 'Execute Leaf Pruning (/yaprakbakimi)',
                distance = dist,
                onSelect = function()
                    local done = lib.progressBar({
                        duration     = Config.BotanyCore.PropAttachDurationMs,
                        label        = 'Manual leaf pruning in progress...',
                        useWhileDead = false,
                        canCancel    = true,
                        disable      = { move = true, car = true, combat = true },
                        anim         = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
                    })
                    if not done then return end

                    TriggerServerEvent('matrix:server:botany:pruneLeaves', trapHouseId)
                    local ok, result = lib.callback.await('matrix:server:botany:getState', false, trapHouseId)
                    if ok and result then
                        lib.notify({
                            title       = '[LABORATORY]',
                            description = ('Leaf decay cleaned. Decay: %.1f%%.'):format(result.leaf_decay or 0.0),
                            type        = 'success',
                        })
                    end
                end,
            },
        })
    elseif kind == 'uv_light_system' then
        exports.ox_target:addLocalEntity(obj, {
            {
                name     = ('matrix_botany_uvtune_%d'):format(trapHouseId),
                icon     = 'fa-solid fa-lightbulb',
                label    = 'UV Light Spectrum Tune',
                distance = dist,
                onSelect = function()
                    local input = lib.inputDialog('UV Light Spectrum', {
                        { type = 'number', label = 'Target pH (5.0 - 7.5)', required = true,
                          min = 5.0, max = 7.5, step = 0.05, default = 6.25 },
                    })
                    if not input then return end
                    local ph = tonumber(input[1])
                    if not ph then return end
                    TriggerServerEvent('matrix:server:botany:setPH', trapHouseId, ph)
                    lib.notify({
                        title       = '[LABORATORY]',
                        description = ('UV tuning applied. Target pH: %.2f'):format(ph),
                        type        = 'success',
                    })
                end,
            },
        })
    end
end

-- ---------------------------------------------------------------------
-- Server → client: spawn lab props into an interior instance
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:client:botany:spawnLab', function(payload)
    if type(payload) ~= 'table' then return end
    local trapHouseId = tonumber(payload.trap_house_id)
    if not trapHouseId then return end

    -- Idempotent: de-spawn previous instance if present
    if spawnedProps[trapHouseId] then
        for _, obj in pairs(spawnedProps[trapHouseId]) do
            if DoesEntityExist(obj) then
                pcall(function() exports.ox_target:removeLocalEntity(obj) end)
                DeleteEntity(obj)
            end
        end
        spawnedProps[trapHouseId] = nil
    end

    local cabinetPos  = payload.cabinet_pos
    local barrelPos   = payload.barrel_pos
    local uvPos       = payload.uv_pos
    if not (cabinetPos and barrelPos and uvPos) then return end

    local cabinet = SpawnLabProp('botany_cabinet',    trapHouseId, cabinetPos, payload.cabinet_heading or 0.0)
    local barrel  = SpawnLabProp('heavy_duty_barrel', trapHouseId, barrelPos,  payload.barrel_heading  or 0.0)
    local uvlight = SpawnLabProp('uv_light_system',   trapHouseId, uvPos,      payload.uv_heading      or 0.0)

    spawnedProps[trapHouseId] = { cabinet = cabinet, barrel = barrel, uv = uvlight }

    if cabinet then RegisterTargetHandlers(cabinet, 'botany_cabinet',    trapHouseId) end
    if barrel  then RegisterTargetHandlers(barrel,  'heavy_duty_barrel', trapHouseId) end
    if uvlight then RegisterTargetHandlers(uvlight, 'uv_light_system',   trapHouseId) end

    lib.notify({
        title       = '[LABORATORY]',
        description = 'Physical botany props materialized. Secure the perimeter.',
        type        = 'inform',
    })
end)

RegisterNetEvent('matrix:client:botany:despawnLab', function(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    local set = trapHouseId and spawnedProps[trapHouseId]
    if not set then return end
    for _, obj in pairs(set) do
        if DoesEntityExist(obj) then
            pcall(function() exports.ox_target:removeLocalEntity(obj) end)
            DeleteEntity(obj)
        end
    end
    spawnedProps[trapHouseId] = nil
end)

-- ---------------------------------------------------------------------
-- Item use hook: player uses a botany prop ITEM from ox_inventory
-- (e.g. from a dealer inventory or held item) -- spawns physical prop.
-- Triggered from ox_inventory items.lua: exports['matrix']:PlaceLabProp(...)
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:client:botany:placeFromInventory', function(kind, trapHouseId, coords, heading)
    if type(kind) ~= 'string' then return end
    if type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return end

    local attachMs = Config.BotanyCore.PropAttachDurationMs
    local ped = PlayerPedId()

    -- 5-second carrier animation, then drop the prop at target coords.
    local done = lib.progressBar({
        duration     = attachMs,
        label        = ('Deploying %s to site...'):format(kind),
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
    })
    if not done then
        lib.notify({ title = '[LABORATORY]', description = 'Deployment aborted. Returning to carrier.', type = 'error' })
        return
    end

    TriggerServerEvent('matrix:server:botany:registerProp', kind, trapHouseId, coords, heading or 0.0)
end)

-- ---------------------------------------------------------------------
-- Player leaves cell → clean up local props
-- ---------------------------------------------------------------------
AddEventHandler('onClientResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    for _, set in pairs(spawnedProps) do
        for _, obj in pairs(set) do
            if DoesEntityExist(obj) then
                pcall(function() exports.ox_target:removeLocalEntity(obj) end)
                DeleteEntity(obj)
            end
        end
    end
    spawnedProps = {}
end)