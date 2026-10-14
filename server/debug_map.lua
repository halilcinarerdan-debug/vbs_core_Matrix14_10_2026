-- =====================================================================
-- ★★★ ADMIN DEBUG MAP -- CANLI BOT/HUB/TRAP HOUSE HARİTASI ★★★
-- YENİ dosya. Sadece OKUMA amaçlı: hiçbir oyun/ekonomi kuralına dokunmaz,
-- yalnızca Matrix.TrapHouses / Matrix.Dispatches / Matrix.DistrictHubs
-- verisini periyodik olarak abone admin(ler)e serialize edip yollar.
--
-- YETKI: FiveM native ACE ('command.matrix_admin'). Bu resource'ta zaten
-- var olan Matrix.Hierarchy.HasCommandAuthority deseni KASITLI olarak
-- kullanılmaz -- kullanıcı bu özelliğin Hierarchy'den bağımsız, saf ACE
-- tabanlı olmasını istedi. FAIL-CLOSED: IsPlayerAceAllowed her ne
-- sebeple olursa olsun doğru döndürmezse (nil/false) erişim REDDEDİLİR.
--
-- ZERO-RESMON: yeni bir 'while true do ... Wait(...) end' thread'i AÇILMAZ.
-- server/main.lua'daki MEVCUT 1-saniyelik ana tick thread'ine (Config.Tick
-- .IntervalMs = 1000ms) Matrix.DebugMap.Tick() olarak iğnelenir; abone
-- yoksa (next(MapSubscribers) == nil) gövde SIFIR maliyetle atlanır.
-- =====================================================================

Matrix.DebugMap = Matrix.DebugMap or {}

local MapSubscribers = {}

local BROADCAST_INTERVAL_MS = 2000
local ticksSinceBroadcast   = 0

local function IsAdminAllowed(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local ok, allowed = pcall(IsPlayerAceAllowed, src, 'command.matrix_admin')
    return ok == true and allowed == true
end

-- =====================================================================
-- ISI BUCKET'I -- Sıfır Çiğ Sayı Standardı: ham float ASLA client'a gitmez.
-- =====================================================================
local function HeatLabel(trapHouseId)
    local heat = (Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapHouseId)) or 0.0
    local maxIntensity = (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
    if type(maxIntensity) ~= 'number' or maxIntensity <= 0.0 then maxIntensity = 5.0 end

    local ratio = heat / maxIntensity
    if ratio ~= ratio then ratio = 0.0 end -- NaN guard
    if ratio < 0.0 then ratio = 0.0 end

    if ratio < 0.25 then
        return 'SIBER-ISI: SOGUK'
    elseif ratio < 0.5 then
        return 'SIBER-ISI: ILIK'
    elseif ratio < 0.75 then
        return 'SIBER-ISI: SICAK'
    else
        return 'SIBER-ISI: KRITIK'
    end
end

-- =====================================================================
-- PAYLOAD DERLEME
-- =====================================================================
function Matrix.DebugMap.CompilePayload()
    local payload = { trap_houses = {}, dispatches = {}, hubs = {} }

    for id, house in pairs(Matrix.TrapHouses or {}) do
        payload.trap_houses[#payload.trap_houses + 1] = {
            id         = id,
            coords     = house.coords,
            locked     = (Matrix.Bureau and Matrix.Bureau.IsLockedDown and Matrix.Bureau.IsLockedDown(id)) == true,
            heat_label = HeatLabel(id)
        }
    end

    for botId, dispatch in pairs(Matrix.Dispatches or {}) do
        local isVehicle = dispatch.vehicle_type ~= nil

        if dispatch.comms_lost then
            payload.dispatches[#payload.dispatches + 1] = {
                bot_id      = botId,
                coords      = dispatch.last_known_coords or dispatch.last_coords,
                comms_lost  = true,
                is_vehicle  = isVehicle
            }
        else
            -- [FK-5 STYLE] STATEBAG INVALID-ENTITY FIX ile aynı 4-katmanlı
            -- savunma (server/wound_system.lua ApplyBotRegionalDamage'in
            -- statebag yazımıyla aynı desen) -- InvokeNative crash'i
            -- yapısal olarak imkansız kılınır.
            local liveCoords = dispatch.last_coords
            if type(dispatch.entity_net_id) == 'number' and dispatch.entity_net_id ~= 0 then
                local okEntity, freshCoords = pcall(function()
                    local pedEntity = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
                    if not pedEntity or pedEntity == 0 then return nil end
                    if not DoesEntityExist(pedEntity) then return nil end
                    if not NetworkGetEntityIsNetworked(pedEntity) then return nil end

                    local freshNetId = NetworkGetNetworkIdFromEntity(pedEntity)
                    if type(freshNetId) ~= 'number' or freshNetId == 0 or freshNetId ~= dispatch.entity_net_id then
                        return nil
                    end

                    local c = GetEntityCoords(pedEntity)
                    return vector3(c.x, c.y, c.z)
                end)
                if okEntity and freshCoords then
                    liveCoords = freshCoords
                end
            end

            payload.dispatches[#payload.dispatches + 1] = {
                bot_id     = botId,
                coords     = liveCoords,
                comms_lost = false,
                is_vehicle = isVehicle
            }
        end
    end

    if Matrix.DistrictHubs and Matrix.DistrictHubs.GetAll then
        for id, hub in pairs(Matrix.DistrictHubs.GetAll()) do
            payload.hubs[#payload.hubs + 1] = {
                id     = id,
                coords = hub.coords,
                locked = hub.locked == true
            }
        end
    end

    return payload
end

-- =====================================================================
-- TICK -- server/main.lua'nın MEVCUT 1-saniyelik ana tick thread'inden
-- her turda çağrılır (yeni thread YOK). ~2000ms'de bir yayınlar.
-- =====================================================================
function Matrix.DebugMap.Tick()
    if not next(MapSubscribers) then return end

    ticksSinceBroadcast = ticksSinceBroadcast + (Config.Tick and Config.Tick.IntervalMs or 1000)
    if ticksSinceBroadcast < BROADCAST_INTERVAL_MS then return end
    ticksSinceBroadcast = 0

    local ok, payload = pcall(Matrix.DebugMap.CompilePayload)
    if not ok then
        Matrix.Log('DEBUG_MAP', '[HATA] CompilePayload basarisiz (yutuldu): %s', tostring(payload))
        return
    end

    for src in pairs(MapSubscribers) do
        if GetPlayerName(src) then
            TriggerClientEvent('matrix:client:syncDebugMapPayload', src, payload)
        else
            MapSubscribers[src] = nil
        end
    end
end

-- =====================================================================
-- NET EVENTS
-- =====================================================================
RegisterNetEvent('matrix:server:toggleDebugMap', function(wantsOn)
    local src = source
    if not IsAdminAllowed(src) then return end

    if wantsOn then
        MapSubscribers[src] = true
        Matrix.Log('DEBUG_MAP', '[ADMIN] src=%d canli harita aboneligi ACIK.', src)
    else
        MapSubscribers[src] = nil
        Matrix.Log('DEBUG_MAP', '[ADMIN] src=%d canli harita aboneligi KAPALI.', src)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    MapSubscribers[src] = nil
end)
