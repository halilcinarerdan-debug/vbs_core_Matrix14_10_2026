-- client/chaos_attacker.lua
-- Chaos modülü server'dan "chaos:client:fireSpoof" tetiklerse sahte
-- TriggerServerEvent yollar. NetworkGuard durdurmalı.

RegisterNetEvent('chaos:client:fireSpoof', function(eventName, args)
    if type(eventName) ~= 'string' or type(args) ~= 'table' then return end
    TriggerServerEvent(eventName, table.unpack(args))
end)

print('[CHAOS_ATTACKER] Client spoof channel armed.')