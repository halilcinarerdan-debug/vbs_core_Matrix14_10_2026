print('[MATRIX:PROP_PLACEMENT] *** FILE LOADED ***')

Matrix = Matrix or {}
Matrix.PropPlacement = Matrix.PropPlacement or {}

-- =====================================================================
-- SABİTLER
-- =====================================================================
local PHANTOM_ALPHA          = 180
local PLACE_MIN_DIST         = 0.6
local PLACE_MAX_DIST         = 4.0
local PLACE_STEP_DIST        = 0.15
local PLACE_DEFAULT_DIST     = 1.8
local PLACE_MIN_HEIGHT       = -2.0
local PLACE_MAX_HEIGHT       = 2.0
local PLACE_STEP_HEIGHT      = 0.005
local PLACE_STEP_HEIGHT_FAST = 0.020
local ROT_SLOW_DEG           = 2.0
local ROT_FAST_DEG           = 10.0
local PLACE_ROTATE_TICK_MS   = 60

local PLACE_MODELS = {
    chemical_workbench = 'prop_table_03b',
    botany_cabinet     = 'bkr_prop_weed_01_small_01a',
}
local PLACE_LABELS = {
    chemical_workbench = 'Chemical Workbench',
    botany_cabinet     = 'Botany Cabinet',
}
local PROXIMITY_RANGE = 1.8

-- ★ NUI tabanlı yardım metni — flicker + overlap YAPISAL OLARAK imkansız
local PLACEMENT_HELP = table.concat({
    '<< / >>  : Dondur  (Shift = Hizli)',
    'Q        : 180 Derece Cevir',
    'Fare Tekerlegi : Yatay Mesafe',
    'Yukari / Asagi : Yukseklik  (Shift = Hizli)',
    '[E] Onayla       [BACKSPACE] Iptal',
}, '\n')

-- =====================================================================
-- STATE
-- =====================================================================
local placementActive   = false
local previewObj        = nil
local previewKind       = nil
local currentHeading    = 0.0
local currentDistance   = PLACE_DEFAULT_DIST
local currentHeight     = 0.0

local trackedProps      = {}
local registeredTargets = {}

-- =====================================================================
-- UTILITY
-- =====================================================================
local function Notify(msg, kind)
    if lib and lib.notify then
        lib.notify({ title = '[PLACEMENT]', description = tostring(msg), type = kind or 'inform', duration = 4000 })
    end
end

local function ShowHelp()
    if lib and lib.showTextUI then
        lib.showTextUI(PLACEMENT_HELP, {
            position = 'left-center',
            icon     = 'fa-solid fa-cube',
        })
    end
end

local function HideHelp()
    if lib and lib.hideTextUI then
        lib.hideTextUI()
    end
end

local function LoadModelSync(name)
    local hash = joaat(name)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 5000 do Wait(50); t = t + 50 end
    return HasModelLoaded(hash) and hash or nil
end

local function DestroyPreview()
    if previewObj and previewObj ~= 0 and DoesEntityExist(previewObj) then
        DeleteObject(previewObj)
    end
    previewObj = nil
end

local function ComputePlacementCoords()
    local ped = PlayerPedId()
    local pc  = GetEntityCoords(ped)
    local h   = GetEntityHeading(ped)
    local rad = math.rad(h)
    local fx  = -math.sin(rad)
    local fy  =  math.cos(rad)
    return vector3(pc.x + fx * currentDistance, pc.y + fy * currentDistance, pc.z + currentHeight)
end

-- =====================================================================
-- PLACEMENT MODE
-- =====================================================================
local function StartPlacement(kind)
    if type(kind) == 'table' then kind = kind[1] end
    if type(kind) ~= 'string' or not PLACE_MODELS[kind] then
        Notify('Gecersiz kit tipi.', 'error')
        return
    end
    if placementActive then
        Notify('Zaten aktif bir oturum var.', 'error')
        return
    end

    local hash = LoadModelSync(PLACE_MODELS[kind])
    if not hash then
        Notify('Model yuklenemedi: ' .. PLACE_MODELS[kind], 'error')
        return
    end

    placementActive = true
    previewKind     = kind
    currentHeading  = GetEntityHeading(PlayerPedId())
    currentDistance = PLACE_DEFAULT_DIST
    currentHeight   = 0.0

    local pc = ComputePlacementCoords()
    previewObj = CreateObject(hash, pc.x, pc.y, pc.z, false, false, false)
    if not previewObj or previewObj == 0 then
        placementActive = false
        previewKind = nil
        SetModelAsNoLongerNeeded(hash)
        Notify('Onizleme olusturulamadi.', 'error')
        return
    end

    SetEntityHeading(previewObj, currentHeading)
    SetEntityAlpha(previewObj, PHANTOM_ALPHA, false)
    SetEntityCollision(previewObj, false, true)
    FreezeEntityPosition(previewObj, true)
    SetEntityInvincible(previewObj, true)
    SetModelAsNoLongerNeeded(hash)

    ShowHelp()
    Notify(('%s yerlestirme modu.'):format(PLACE_LABELS[kind] or kind))
end

local function ConfirmPlacement()
    HideHelp()
    if not placementActive or not previewObj or previewObj == 0 then return end
    if not DoesEntityExist(previewObj) then
        placementActive = false
        previewKind = nil
        return
    end

    local coords  = GetEntityCoords(previewObj)
    local heading = GetEntityHeading(previewObj)
    local kind    = previewKind

    DestroyPreview()
    placementActive = false
    previewKind = nil

    TriggerServerEvent('matrix:server:propRegistry:deploy', kind, coords.x, coords.y, coords.z, heading)
    Notify('Yerlestirme gonderildi.', 'inform')
end

local function CancelPlacement(reason)
    HideHelp()
    if not placementActive then return end
    DestroyPreview()
    placementActive = false
    previewKind = nil
    Notify('Iptal: ' .. tostring(reason or 'kullanici'), 'inform')
end

-- =====================================================================
-- PLACEMENT INPUT LOOP
-- =====================================================================
CreateThread(function()
    local lastTick = 0
    while true do
        if placementActive and previewObj and previewObj ~= 0 and DoesEntityExist(previewObj) then

            DisableControlAction(0, 24,  true); DisableControlAction(0, 25,  true)
            DisableControlAction(0, 47,  true); DisableControlAction(0, 58,  true)
            DisableControlAction(0, 140, true); DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true); DisableControlAction(0, 143, true)
            DisableControlAction(0, 38,  true); DisableControlAction(0, 177, true)
            DisableControlAction(0, 172, true); DisableControlAction(0, 173, true)
            DisableControlAction(0, 174, true); DisableControlAction(0, 175, true)
            DisableControlAction(0, 44,  true)

            -- Anlık girdiler
            if IsDisabledControlJustPressed(0, 44) then
                currentHeading = (currentHeading + 180.0) % 360.0
            end
            if IsDisabledControlJustPressed(0, 14) then
                currentDistance = math.min(PLACE_MAX_DIST, currentDistance + PLACE_STEP_DIST)
            end
            if IsDisabledControlJustPressed(0, 15) then
                currentDistance = math.max(PLACE_MIN_DIST, currentDistance - PLACE_STEP_DIST)
            end
            if IsDisabledControlJustPressed(0, 38)  then ConfirmPlacement() end
            if IsDisabledControlJustPressed(0, 177) then CancelPlacement('backspace') end

            -- Tick-based yavaş hareket
            local now = GetGameTimer()
            if (now - lastTick) >= PLACE_ROTATE_TICK_MS then
                lastTick = now

                local fast    = IsDisabledControlPressed(0, 21)
                local rotStep = fast and ROT_FAST_DEG or ROT_SLOW_DEG
                local hStep   = fast and PLACE_STEP_HEIGHT_FAST or PLACE_STEP_HEIGHT

                if IsDisabledControlPressed(0, 174) then
                    currentHeading = (currentHeading - rotStep) % 360.0
                end
                if IsDisabledControlPressed(0, 175) then
                    currentHeading = (currentHeading + rotStep) % 360.0
                end
                if IsDisabledControlPressed(0, 172) then
                    currentHeight = math.min(PLACE_MAX_HEIGHT, currentHeight + hStep)
                end
                if IsDisabledControlPressed(0, 173) then
                    currentHeight = math.max(PLACE_MIN_HEIGHT, currentHeight - hStep)
                end
            end

            -- Phantom güncelle (her frame)
            local coords = ComputePlacementCoords()
            SetEntityCoordsNoOffset(previewObj, coords.x, coords.y, coords.z, false, false, false)
            SetEntityHeading(previewObj, currentHeading)

            Wait(0)
        else
            lastTick = 0
            Wait(200)
        end
    end
end)

-- =====================================================================
-- OX_TARGET — propId bazlı, addSphereZone
-- =====================================================================
local function _RegisterOxTarget(tracked)
    local propId = tonumber(tracked.id)
    if not propId then return false end
    if registeredTargets[propId] then return true end
    if not exports.ox_target then return false end

    local kind        = tracked.kind
    local trapHouseId = tracked.trap_house_id
    local coords

    if tracked.local_entity and tracked.local_entity ~= 0 and DoesEntityExist(tracked.local_entity) then
        coords = GetEntityCoords(tracked.local_entity)
    elseif tracked.x and tracked.y and tracked.z then
        coords = vector3(tracked.x, tracked.y, tracked.z)
    else
        return false
    end

    local options = {
        {
            name     = ('matrix_prop_%d'):format(propId),
            icon     = (kind == 'chemical_workbench') and 'fa-solid fa-flask-vial' or 'fa-solid fa-seedling',
            label    = (kind == 'chemical_workbench') and 'Chemical Synthesis' or 'Botany Environment',
            distance = PROXIMITY_RANGE,
            onSelect = function()
                TriggerServerEvent('matrix:server:propRegistry:interact', propId)
            end,
        },
        {
            name     = ('matrix_prop_%d_remove'):format(propId),
            icon     = 'fa-solid fa-screwdriver',
            label    = 'Sok ve Kiti Geri Al',
            distance = PROXIMITY_RANGE,
            onSelect = function()
                local confirmed = lib.alertDialog({
                    header   = 'PROPU SOK',
                    content  = ('%s sokulecek ve kit envanterinize iade edilecek. Onayliyor musunuz?'):format(
                        PLACE_LABELS[kind] or kind),
                    centered = true,
                    cancel   = true,
                })
                if confirmed ~= 'confirm' then return end
                TriggerServerEvent('matrix:server:propRegistry:remove', propId)
            end,
        },
    }

    local ok, zoneId = pcall(function()
        return exports.ox_target:addSphereZone({
            coords  = coords,
            radius  = PROXIMITY_RANGE,
            debug   = false,
            options = options,
        })
    end)

    if ok and zoneId then
        registeredTargets[propId] = zoneId
        tracked.zone_id = zoneId
        print(('[MATRIX:PROP_PLACEMENT] Sphere zone OK: id=%d zoneId=%s'):format(propId, tostring(zoneId)))
        return true
    end
    print(('[MATRIX:PROP_PLACEMENT] [HATA] Sphere zone fail: id=%d err=%s'):format(propId, tostring(zoneId)))
    return false
end

-- =====================================================================
-- DESPAWN
-- =====================================================================
local function _DespawnLocalByPropId(propId)
    propId = tonumber(propId)
    if not propId then return end
    local p = trackedProps[propId]
    if not p then return end

    if p.zone_id then
        pcall(function() exports.ox_target:removeZone(p.zone_id) end)
    end
    if p.local_entity and p.local_entity ~= 0 and DoesEntityExist(p.local_entity) then
        DeleteObject(p.local_entity)
    end
    registeredTargets[propId] = nil
    trackedProps[propId] = nil
    print(('[MATRIX:PROP_PLACEMENT] Despawned: id=%d'):format(propId))
end

-- =====================================================================
-- SPAWN — fizik kayması yok, atomik sıra
-- =====================================================================
local function _SpawnLocalProp(prop)
    if type(prop) ~= 'table' then return end
    local propId = tonumber(prop.id)
    if not propId then return end

    local kind = prop.kind
    if not PLACE_MODELS[kind] then return end

    _DespawnLocalByPropId(propId)

    local hash = joaat(PLACE_MODELS[kind])
    if not IsModelValid(hash) then return end
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 5000 do Wait(50); t = t + 50 end
    if not HasModelLoaded(hash) then
        print(('[MATRIX:PROP_PLACEMENT] [HATA] Model yuklenemedi: %s'):format(PLACE_MODELS[kind]))
        return
    end

    local obj = CreateObject(hash, prop.x, prop.y, prop.z, false, false, false)
    if not obj or obj == 0 then
        SetModelAsNoLongerNeeded(hash)
        print('[MATRIX:PROP_PLACEMENT] [HATA] CreateObject basarisiz.')
        return
    end

    -- ★ ATOMİK SIRA — CreateObject'dan HEMEN sonra, Wait YOK
    SetEntityCollision(obj, false, true)
    SetEntityNoCollisionEntity(obj, PlayerPedId(), true)
    FreezeEntityPosition(obj, true)
    SetEntityInvincible(obj, true)
    SetEntityCoordsNoOffset(obj, prop.x, prop.y, prop.z, false, false, false)
    SetEntityHeading(obj, prop.heading or 0.0)
    SetEntityAlpha(obj, 255, false)
    SetModelAsNoLongerNeeded(hash)

    local tracked = {
        id            = propId,
        trap_house_id = prop.trap_house_id,
        kind          = kind,
        local_entity  = obj,
        x             = prop.x,
        y             = prop.y,
        z             = prop.z,
    }
    trackedProps[propId] = tracked

    print(('[MATRIX:PROP_PLACEMENT] LOCAL spawn: id=%d kind=%s @ (%.2f,%.2f,%.2f)'):format(
        propId, kind, prop.x, prop.y, prop.z))

    CreateThread(function()
        for _ = 1, 10 do
            if DoesEntityExist(obj) then
                local success = _RegisterOxTarget(tracked)
                if success then
                    print(('[MATRIX:PROP_PLACEMENT] ox_target registered: id=%d'):format(propId))
                    return
                end
            end
            Wait(300)
        end
        print(('[MATRIX:PROP_PLACEMENT] [HATA] ox_target register fail: id=%d'):format(propId))
    end)
end

-- =====================================================================
-- EVENT HANDLERS
-- =====================================================================
RegisterNetEvent('matrix:client:propRegistry:spawned', function(prop)
    if type(prop) ~= 'table' then return end
    _SpawnLocalProp(prop)
end)

RegisterNetEvent('matrix:client:propRegistry:despawned', function(propId)
    _DespawnLocalByPropId(propId)
end)

RegisterNetEvent('matrix:client:propRegistry:syncAll', function(props)
    if type(props) ~= 'table' then return end

    for propId, p in pairs(trackedProps) do
        if p.zone_id then
            pcall(function() exports.ox_target:removeZone(p.zone_id) end)
        end
        if p.local_entity and p.local_entity ~= 0 and DoesEntityExist(p.local_entity) then
            DeleteObject(p.local_entity)
        end
        registeredTargets[propId] = nil
    end
    trackedProps = {}

    for _, prop in ipairs(props) do
        if type(prop) == 'table' and prop.kind and prop.id then
            _SpawnLocalProp(prop)
        end
    end
end)

RegisterNetEvent('matrix:client:propRegistry:openChemWB', function(propId, trapHouseId)
    propId = tonumber(propId); trapHouseId = tonumber(trapHouseId)
    if not propId then return end

    local prop = trackedProps[propId]
    if not prop then
        if not trapHouseId then
            print('[MATRIX:PROP_PLACEMENT] openChemWB: prop ve trapHouseId yok')
            return
        end
        prop = { id = propId, trap_house_id = trapHouseId }
    end

    local input = lib.inputDialog('Chemical Synthesis Matrix', {
        { type = 'number', label = 'Pure Compound (mg)', required = true, min = 1, max = 100000, default = 1000 },
        { type = 'number', label = 'Cutting Agent (mg)', required = true, min = 0, max = 100000, default = 300 },
    })
    if not input then return end

    local pureMg    = tonumber(input[1])
    local cuttingMg = tonumber(input[2])
    if not pureMg or not cuttingMg then return end

    local done = lib.progressBar({
        duration = 5000, label = 'Chemical synthesis calisiyor...',
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim    = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
    })
    if not done then return end

    TriggerServerEvent('matrix:server:chemicalWorkbench:submitSynthesis',
        prop.trap_house_id, pureMg, cuttingMg)
end)

-- =====================================================================
-- SYNC TRIGGERS
-- =====================================================================
AddEventHandler('qbx_core:client:onPlayerLoaded', function()
    CreateThread(function() Wait(3000); TriggerServerEvent('matrix:server:propRegistry:requestSync') end)
end)
AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    CreateThread(function() Wait(3000); TriggerServerEvent('matrix:server:propRegistry:requestSync') end)
end)
AddEventHandler('matrix:client:trapHouseInterior:teleportIn', function()
    CreateThread(function() Wait(1500); TriggerServerEvent('matrix:server:propRegistry:requestSync') end)
end)

-- =====================================================================
-- EXPORT — ox_inventory args normalize
-- =====================================================================
exports('StartPropPlacement', function(a, b)
    local function _findKind(t, depth)
        depth = depth or 0
        if depth > 4 then return nil end
        if type(t) == 'string' then
            if t == 'chemical_workbench' or t == 'botany_cabinet' then return t end
            return nil
        end
        if type(t) ~= 'table' then return nil end
        if type(t[1]) == 'string' and (t[1] == 'chemical_workbench' or t[1] == 'botany_cabinet') then return t[1] end
        if type(t.kind) == 'string' and (t.kind == 'chemical_workbench' or t.kind == 'botany_cabinet') then return t.kind end
        if type(t.args) == 'table' and type(t.args[1]) == 'string' and (t.args[1] == 'chemical_workbench' or t.args[1] == 'botany_cabinet') then return t.args[1] end
        if t.name == 'chemical_workbench_kit' then return 'chemical_workbench' end
        if t.name == 'botany_cabinet_kit'     then return 'botany_cabinet'     end
        for _, v in pairs(t) do
            local found = _findKind(v, depth + 1)
            if found then return found end
        end
        return nil
    end

    local kind = _findKind(b) or _findKind(a)
    if not kind then print('[MATRIX:PROP_PLACEMENT] kind bulunamadi.'); return end
    StartPlacement(kind)
end)

-- =====================================================================
-- COLLISION HEARTBEAT
-- =====================================================================
CreateThread(function()
    while true do
        Wait(1000)
        for propId, p in pairs(trackedProps) do
            if p.local_entity and p.local_entity ~= 0 and DoesEntityExist(p.local_entity) then
                SetEntityCollision(p.local_entity, false, true)
            end
        end
    end
end)

-- =====================================================================
-- CLEANUP
-- =====================================================================
AddEventHandler('onClientResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    HideHelp()
    DestroyPreview()
    for propId, p in pairs(trackedProps) do
        if p.zone_id then
            pcall(function() exports.ox_target:removeZone(p.zone_id) end)
        end
        if p.local_entity and p.local_entity ~= 0 and DoesEntityExist(p.local_entity) then
            DeleteObject(p.local_entity)
        end
    end
    trackedProps = {}
    registeredTargets = {}
end)

print('[MATRIX:PROP_PLACEMENT] [BOOT] v6 armed. NUI textUI + slow-rot + no-physics-drift.')