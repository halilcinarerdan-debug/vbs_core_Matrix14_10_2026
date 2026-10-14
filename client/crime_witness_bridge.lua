-- =====================================================================
-- MATRIX CRIME WITNESS BRIDGE / client/crime_witness_bridge.lua
-- FAZ 2.1 — Cinayet tespit KLIENT köprüsü
--
-- ★ NEDEN: gameEventTriggered CEventNetworkEntityDamage KLIENT'ta
--   tetiklenir. Server-side CEventNetworkEntityDamage ULAŞMAZ.
--   Bu bridge, client'ın GÖRDÜĞÜ olum event'lerini server'a iletir.
--
-- ★ DEDUPE: Ayni olum birden fazla client tarafindan raporlanabilir
--   (attacker'in client'i + victim'in client'i + tanik client'lar).
--   Server-side dedupe (crime_witness.lua) bunu yutar.
--   Ayrica burada kisa bir yerel cooldown var (aynı client spam yapmasın).
--
-- ★ SERVER-AUTHORITATIVE: Bu dosya SADECE net_id raporlar. Victim/killer
--   KIMLIGI server'da PedRegistry + GetPlayerPed ile cozulur. Client'a
--   HICBIR ZAMAN "victim_kind=bot" veya "victim_id=95" DEMIYORUZ.
--   RedEngine bu bridge'i spoof etse bile yalnizca "bir ped oldu"
--   diyebilir; kimligi server cozer.
--
-- ★ 0 RNG. math.random YOK.
-- =====================================================================

local REPORT_COOLDOWN_MS = 250   -- ayni victim:attacker icin yerel spam koruma
local _lastReport = {}           -- [key] = GetGameTimer()

AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then return end

    local victimPed   = args[1]
    local attackerPed = args[2]
    -- args[3] = weapon hash (kullanilmiyor simdilik)
    -- args[4] = isFatal (kullanilmiyor — victimDied daha guvenilir)
    local victimDied  = args[5]

    if type(victimPed) ~= 'number' or victimPed == 0 then return end
    if victimDied ~= true then return end

    -- ★ Network ID cozumlemesi — victim ped bir networked entity olmali
    local victimNetId = 0
    pcall(function()
        if NetworkGetEntityIsNetworked(victimPed) then
            victimNetId = NetworkGetNetworkIdFromEntity(victimPed)
        end
    end)
    if not victimNetId or victimNetId == 0 then return end

    local attackerNetId = 0
    if type(attackerPed) == 'number' and attackerPed ~= 0 and attackerPed ~= victimPed then
        pcall(function()
            if NetworkGetEntityIsNetworked(attackerPed) then
                attackerNetId = NetworkGetNetworkIdFromEntity(attackerPed)
            end
        end)
    end

    -- ★ Yerel spam koruma
    local key = victimNetId .. ':' .. attackerNetId
    local now = GetGameTimer()
    if _lastReport[key] and (now - _lastReport[key]) < REPORT_COOLDOWN_MS then
        return
    end
    _lastReport[key] = now

    TriggerServerEvent('matrix:server:reportKill', victimNetId, attackerNetId, true)
end)

-- Kaynak durdugunda temizlik
AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    _lastReport = {}
end)

print('[CRIME_WITNESS_BRIDGE] Client damage bridge armed (gameEventTriggered -> server).')