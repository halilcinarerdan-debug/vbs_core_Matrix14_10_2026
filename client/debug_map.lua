-- =====================================================================
-- ★★★ ADMIN DEBUG MAP -- CLIENT ★★★
-- YENİ dosya. Sadece görselleştirme -- hiçbir yetki kontrolü burada
-- GÜVENİLMEZ (client input asla trusted değildir); gerçek ACE kontrolü
-- server/debug_map.lua'da yapılır. Bu dosya sadece kendi lokal
-- 'DebugMapActive' toggle durumunu tutar ve gelen payload'u render eder.
-- =====================================================================

local DebugMapActive   = false
local RuntimeDebugBlips = {}

local function ClearRuntimeDebugBlips()
    for _, blip in pairs(RuntimeDebugBlips) do
        pcall(RemoveBlip, blip)
    end
    RuntimeDebugBlips = {}
end

local function GetOrCreateBlip(key, coords)
    local blip = RuntimeDebugBlips[key]
    if blip and DoesBlipExist(blip) then
        SetBlipCoords(blip, coords.x, coords.y, coords.z)
        return blip
    end

    blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    RuntimeDebugBlips[key] = blip
    return blip
end

local function SetBlipLabel(blip, text)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(blip)
end

local function RenderTrapHouses(trapHouses)
    for _, house in ipairs(trapHouses or {}) do
        if house.coords then
            local key  = 'trap_' .. tostring(house.id)
            local blip = GetOrCreateBlip(key, house.coords)

            SetBlipSprite(blip, 40)
            SetBlipColour(blip, house.locked and 1 or 5)
            SetBlipAsShortRange(blip, true)
            SetBlipLabel(blip, ('TRAP #%s [%s]'):format(tostring(house.id), tostring(house.heat_label or '?')))
        end
    end
end

local function RenderDispatches(dispatches)
    for _, dispatch in ipairs(dispatches or {}) do
        if dispatch.coords then
            local key  = 'bot_' .. tostring(dispatch.bot_id)
            local blip = GetOrCreateBlip(key, dispatch.coords)

            local sprite = dispatch.is_vehicle and 225 or 126
            SetBlipSprite(blip, sprite)

            if dispatch.comms_lost then
                SetBlipColour(blip, 39)
                SetBlipAsShortRange(blip, true)
                SetBlipLabel(blip, ('BOT #%s [LKP] RADAR SIGNAL LOST'):format(tostring(dispatch.bot_id)))
            else
                SetBlipColour(blip, 2)
                SetBlipAsShortRange(blip, true)
                SetBlipLabel(blip, ('BOT #%s'):format(tostring(dispatch.bot_id)))
            end
        end
    end
end

local function RenderHubs(hubs)
    for _, hub in ipairs(hubs or {}) do
        if hub.coords then
            local key  = 'hub_' .. tostring(hub.id)
            local blip = GetOrCreateBlip(key, hub.coords)

            SetBlipSprite(blip, 478)
            SetBlipColour(blip, hub.locked and 39 or 3)
            SetBlipAsShortRange(blip, true)
            SetBlipLabel(blip, ('HUB #%s%s'):format(tostring(hub.id), hub.locked and ' [KILITLI]' or ''))
        end
    end
end

RegisterCommand('matrix_debug_map', function()
    local wantsOn = not DebugMapActive
    TriggerServerEvent('matrix:server:toggleDebugMap', wantsOn)
    DebugMapActive = wantsOn

    if not DebugMapActive then
        ClearRuntimeDebugBlips()
    end
end, false)

RegisterNetEvent('matrix:client:syncDebugMapPayload', function(payload)
    if not DebugMapActive then return end
    if type(payload) ~= 'table' then return end

    RenderTrapHouses(payload.trap_houses)
    RenderDispatches(payload.dispatches)
    RenderHubs(payload.hubs)
end)

AddEventHandler('onClientResourceStop', function(resName)
    if GetCurrentResourceName() == resName then
        ClearRuntimeDebugBlips()
    end
end)
