-- =====================================================================
-- MATRIX CHEMICAL WORKBENCH — CLIENT / client/chemical_workbench_client.lua
-- SESSION 4 — ox_target sphere zone @ workbench koordinatı
--
-- ★ [SESSION 4.90 HOTFIX] INDOOR WORKBENCH PROP RENDER COMPLIANCE
--   SORUN: server/workbench.lua'nın materializeBarrel event'i mevcut
--   client tarafında prop_gun_barrel_01 ile spawn ediliyordu; iç mekan
--   routing bucket'ında prop render olmuyordu (spawn + freeze sırası
--   yanlış, ground grounding yok, ox_target bağlı değil).
--
--   FIX (bu dosya):
--     1) prop_table_03b zorunlu model (server'a paralel — prop_gun_barrel_01
--        ile eski handler'ı da matrix_events_handler.lua'da sweep eder).
--     2) CreateObjectNoOffset(hash, x, y, z, ...) — model origin'i TAM
--        verilen noktaya oturur (auto-offset YOK).
--     3) PlaceObjectOnGroundProperly(entity) — sunucudan gelen z
--        yeterince hassas olmasa da fizik motoruna zemin oturtma yetkisi
--        verilir (interior zeminine kusursuz hizalama).
--     4) FreezeEntityPosition(entity, true) — yerleştikten SONRA kilitlenir.
--     5) ox_target:addLocalEntity(entity, {... distance = 1.8 ...}) —
--        prop entity'sine DOĞRUDAN bağlı ox_target context (sphere zone
--        DEĞİL, strict 1.8m entity lock).
--
--   Legacy handler çakışma koruması: aynı event adı için
--   matrix_events_handler.lua'da bir ikinci handler daha kayıtlı
--   olabilir; bu handler sweep ile prop_gun_barrel_01 ve prop_table_03b
--   ikisini de siler, sonra kendi prop_table_03b'sini yerleştirir.
--   FIFO avantajı: fxmanifest sırasında bu dosya matrix_events_handler
--   .lua'dan SONRA yüklenir → bu handler event tetiklendiğinde İKİNCİ
--   çalışır, sweep legacy prop'u temizler.
-- =====================================================================

local workbenchZones = {} -- [trapHouseId] = zoneId (eski sphere-zone API'si)
local _workbenchProp = nil
local _workbenchPropTargetId = nil

local WORKBENCH_PROP_MODEL = 'prop_table_03b'
local WORKBENCH_PROP_RANGE = 1.8

-- =====================================================================
-- Yardımcılar
-- =====================================================================
local function _LoadModelSync(modelName)
    local hash = joaat(modelName)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- Belirtilen noktada çakışan workbench prop'larını (legacy
-- prop_gun_barrel_01 veya yeni prop_table_03b) siler.
local function _SweepNearbyWorkbenchProps(x, y, z, radius)
    radius = tonumber(radius) or 3.0
    local barrelHash = joaat('prop_gun_barrel_01')
    local tableHash  = joaat('prop_table_03b')
    local target = vector3(x, y, z)

    local pool = GetGamePool('CObject')
    for i = 1, #pool do
        local obj = pool[i]
        if DoesEntityExist(obj) then
            local c = GetEntityCoords(obj)
            if #(c - target) <= radius then
                local m = GetEntityModel(obj)
                if m == barrelHash or m == tableHash then
                    pcall(DeleteEntity, obj)
                end
            end
        end
    end
end

local function _TeardownWorkbenchProp()
    if _workbenchPropTargetId and exports.ox_target then
        pcall(function()
            exports.ox_target:removeLocalEntity(_workbenchPropTargetId)
        end)
        _workbenchPropTargetId = nil
    end
    if _workbenchProp and DoesEntityExist(_workbenchProp) then
        pcall(DeleteEntity, _workbenchProp)
    end
    _workbenchProp = nil
end

-- =====================================================================
-- Senthez Diyaloğu (eski API — değişmedi)
-- =====================================================================
local function OpenSynthesisDialog(trapHouseId)
    local input = lib.inputDialog('Chemical Synthesis Matrix', {
        {
            type        = 'number',
            label       = 'Pure Compound (mg)',
            description = 'Baseline: 1000mg ideal',
            required    = true,
            min         = 1,
            max         = (Config.ChemicalWorkbench and Config.ChemicalWorkbench.MaxInputMg) or 100000,
            default     = 1000,
        },
        {
            type        = 'number',
            label       = 'Cutting Agent (mg)',
            description = 'Ideal ratio: 0.30 (300mg per 1000mg pure)',
            required    = true,
            min         = 0,
            max         = (Config.ChemicalWorkbench and Config.ChemicalWorkbench.MaxInputMg) or 100000,
            default     = 300,
        },
    })
    if not input then return end

    local pureMg    = tonumber(input[1])
    local cuttingMg = tonumber(input[2])
    if not pureMg or not cuttingMg then return end

    local done = lib.progressBar({
        duration     = 5000,
        label        = 'Running synthesis matrix...',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
    })
    if not done then return end

    TriggerServerEvent('matrix:server:chemicalWorkbench:submitSynthesis',
        trapHouseId, pureMg, cuttingMg)
end

-- =====================================================================
-- Legacy sphere zone API (server event-driven) — değişmedi
-- =====================================================================
local function RegisterWorkbenchZone(trapHouseId, pos)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not pos then return end

    if workbenchZones[trapHouseId] and exports.ox_target then
        pcall(function() exports.ox_target:removeZone(workbenchZones[trapHouseId]) end)
        workbenchZones[trapHouseId] = nil
    end

    if not exports.ox_target then
        print('[CHEMWB:CLIENT] ox_target export bulunamadi')
        return
    end

    local coords = vector3(tonumber(pos.x) or 0.0, tonumber(pos.y) or 0.0, tonumber(pos.z) or 0.0)
    local radius = (Config.ChemicalWorkbench and Config.ChemicalWorkbench.TargetDistanceMeters) or 1.8

    local ok, zoneId = pcall(function()
        return exports.ox_target:addSphereZone({
            coords = coords,
            radius = radius,
            debug  = false,
            options = {
                {
                    name     = ('matrix_chemwb_%d'):format(trapHouseId),
                    icon     = 'fa-solid fa-flask-vial',
                    label    = 'Chemical Synthesis (mg input)',
                    distance = radius,
                    onSelect = function()
                        OpenSynthesisDialog(trapHouseId)
                    end,
                },
            },
        })
    end)

    if ok and zoneId then
        workbenchZones[trapHouseId] = zoneId
        print(('[CHEMWB:CLIENT] Sphere zone kaydedildi (trap=%d, radius=%.1f)'):format(trapHouseId, radius))
    else
        print(('[CHEMWB:CLIENT] addSphereZone basarisiz: %s'):format(tostring(zoneId)))
    end
end

local function UnregisterWorkbenchZone(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    local zoneId = trapHouseId and workbenchZones[trapHouseId]
    if zoneId and exports.ox_target then
        pcall(function() exports.ox_target:removeZone(zoneId) end)
    end
    workbenchZones[trapHouseId] = nil
end

-- =====================================================================
-- Server event handler: workbench materialize (LEGACY — sphere zone)
-- =====================================================================
-- ★ MANDATE: Statik workbench zone'ları kaldırıldı.
-- Eski sphere-zone sistemi yerine, oyuncunun prop_registry üzerinden
-- yerleştirdiği gerçek prop'un ox_target context'i kullanılır.
-- (bkz. server/prop_registry.lua + client/prop_placement.lua)
RegisterNetEvent('matrix:client:workbench:materializeBarrel', function() end)
RegisterNetEvent('matrix:client:workbench:dematerializeBarrel', function() end)
-- =====================================================================
-- ★ [SESSION 4.90 HOTFIX] INDOOR WORKBENCH PROP RENDER
--
-- Prop tabanlı materialize: prop_table_03b + CreateObjectNoOffset +
-- PlaceObjectOnGroundProperly + FreezeEntityPosition + ox_target:
-- addLocalEntity @ 1.8m. İdempotent: önce sweep, sonra spawn.
-- Event adı server/workbench.lua'nın gönderdiği İLE AYNIDIR
-- (matrix:client:workbench:materializeBarrel) — bu handler, FIFO
-- sırasında matrix_events_handler.lua'daki eski handler'dan SONRA
-- çalışır ve sweep ile eski prop'u temizler.
-- =====================================================================

local function _DeployWorkbenchTable(trapHouseId, x, y, z, heading)
    x       = tonumber(x) or 0.0
    y       = tonumber(y) or 0.0
    z       = tonumber(z) or 0.0
    heading = tonumber(heading) or 0.0

    -- Önce eski prop'u (ve varsa legacy barrel'i) sweep et.
    _SweepNearbyWorkbenchProps(x, y, z, 3.0)
    _TeardownWorkbenchProp()

    local hash = _LoadModelSync(WORKBENCH_PROP_MODEL)
    if not hash then
        print('[CHEMWB:CLIENT] prop_table_03b modeli yuklenemedi, workbench prop yerlesmedi.')
        return
    end

    -- CreateObjectNoOffset: model origin TAM (x,y,z) noktasına oturur.
    local obj = CreateObjectNoOffset(hash, x, y, z, true, true, false)
    if not obj or obj == 0 then
        SetModelAsNoLongerNeeded(hash)
        return
    end

    -- Fizik motoruna zemine oturtma yetkisi (interior z sıfırlamalarına karşı).
    PlaceObjectOnGroundProperly(obj)
    SetEntityHeading(obj, heading)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetModelAsNoLongerNeeded(hash)

    _workbenchProp = obj

    -- ox_target context'i DOĞRUDAN entity'ye bağla (strict 1.8m).
    if exports.ox_target then
        local trapId = tonumber(trapHouseId) or 0
        local ok = pcall(function()
            exports.ox_target:addLocalEntity(obj, {
                {
                    name     = ('matrix_chemwb_prop_%d'):format(trapId),
                    icon     = 'fa-solid fa-flask-vial',
                    label    = 'Chemical Synthesis (mg input)',
                    distance = WORKBENCH_PROP_RANGE,
                    onSelect = function()
                        OpenSynthesisDialog(trapId ~= 0 and trapId or 1)
                    end,
                },
            })
        end)
        if ok then
            _workbenchPropTargetId = obj
        end
    end

    print(('[CHEMWB:CLIENT] prop_table_03b yerlesdi: trap=%d @ (%.2f,%.2f,%.2f) heading=%.1f, ox_target @ %.1fm'):format(
        tonumber(trapHouseId) or 0, x, y, z, heading, WORKBENCH_PROP_RANGE))
end

-- ★ [SESSION 4.99 MANDATE] Legacy prop_table_03b spawn handler'ı SİLİNDİ.
-- Yukarıdaki MANDATE no-op handler'ı (üstte) tek yetkili kayıttır.
-- Oyuncu kendi chemical_workbench_kit'ini deploy eder; statik tezgah YOK.
-- =====================================================================
-- [§3] Fatality animation
-- =====================================================================
RegisterNetEvent('matrix:client:chemicalWorkbench:fatalityAnim', function(coords, animDict, animClip, cleanupMs)
    if type(coords) ~= 'vector3' and type(coords) ~= 'table' then return end
    if type(coords) ~= 'vector3' then
        coords = vector3(tonumber(coords.x) or 0.0, tonumber(coords.y) or 0.0, tonumber(coords.z) or 0.0)
    end

    animDict  = animDict or 'misscarsteal4@spliff@hs_reverse_spliff'
    animClip  = animClip or 'loop'
    cleanupMs = tonumber(cleanupMs) or 45000

    local pedModel = GetHashKey('a_m_y_skater_01')
    RequestModel(pedModel)
    local waited = 0
    while not HasModelLoaded(pedModel) and waited < 2000 do
        Wait(50); waited = waited + 50
    end
    if not HasModelLoaded(pedModel) then
        SetModelAsNoLongerNeeded(pedModel)
        return
    end

    local ped = CreatePed(4, pedModel,
        coords.x + 0.5, coords.y + 0.5, coords.z,
        0.0, false, true)
    SetModelAsNoLongerNeeded(pedModel)

    if not ped or ped == 0 then return end

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCanRagdoll(ped, false)

    ClearPedTasksImmediately(ped)

    if not HasAnimDictLoaded(animDict) then
        RequestAnimDict(animDict)
        local w = 0
        while not HasAnimDictLoaded(animDict) and w < 2000 do
            Wait(50); w = w + 50
        end
    end

    if HasAnimDictLoaded(animDict) then
        TaskPlayAnim(ped, animDict, animClip, 8.0, -8.0, -1, 1, 0.0, false, false, false)
    end

    SetEntityHealth(ped, 0)

    SetTimeout(cleanupMs, function()
        if DoesEntityExist(ped) then
            pcall(DeleteEntity, ped)
        end
    end)
end)

-- =====================================================================
-- Cleanup
-- =====================================================================
AddEventHandler('onClientResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    for trapHouseId in pairs(workbenchZones) do
        UnregisterWorkbenchZone(trapHouseId)
    end
    workbenchZones = {}
    _TeardownWorkbenchProp()
end)

print('[CHEMWB:CLIENT] Chemical workbench client armed.')


-- =====================================================================
-- [SESSION 4 FIX] Client callback: atanmış bot'un net_id'sini döner
-- =====================================================================
lib.callback.register('matrix:callback:chemworkbench:getAssignedBotNetId', function(src, trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return nil end
    local botId = Matrix.ChemicalWorkbench.WorkbenchBot[trapHouseId]
    if not botId then return nil end
    local bot = Matrix.Bots[botId]
    if not bot or not bot.state then return nil end
    return bot.state.net_id
end)