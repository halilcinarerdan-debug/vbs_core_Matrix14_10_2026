-- =====================================================================
-- MATRIX TRIGGER DISCIPLINE v10 / client/trigger_discipline.lua
-- Sadece zamanlama filtresi — SetPedConfigFlag YOK
-- Muzzle flash + sfx + casing NORMAL çalışır
-- =====================================================================

if not Config.TriggerDiscipline or not Config.TriggerDiscipline.Enabled then
    return
end

local PlayerPedId              = PlayerPedId
local GetSelectedPedWeapon     = GetSelectedPedWeapon
local DisableControlAction     = DisableControlAction
local GetGameTimer             = GetGameTimer
local GetHashKey               = GetHashKey
local ShakeGameplayCam         = ShakeGameplayCam
local IsPedShooting            = IsPedShooting
local IsDisabledControlPressed = IsDisabledControlPressed

local SemiAutoIntervals = {}
for name, interval in pairs(Config.TriggerDiscipline.SemiAutoMinInterval) do
    SemiAutoIntervals[GetHashKey(name)] = interval
end

local PostFireSwayMs        = Config.TriggerDiscipline.PostFireSwayMs or 350
local PostFireSwayIntensity = Config.TriggerDiscipline.PostFireSwayIntensity or 0.13

local LastShotAt = {}
local SwayUntil  = {}

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local weaponHash = GetSelectedPedWeapon(ped)
        local interval = SemiAutoIntervals[weaponHash]

        if interval then
            Wait(0)

            local now      = GetGameTimer()
            local lastShot = LastShotAt[weaponHash] or 0
            local since    = now - lastShot
            local holding  = IsDisabledControlPressed(0, 24)

            -- ★ SPAM FİLTRESİ: son atıştan bu yana interval geçmediyse blok
            if holding and lastShot > 0 and since < interval then
                DisableControlAction(0, 24, true)
                DisableControlAction(0, 257, true)
            end

            -- ★ Ateş algılandı → son atış zamanı + sway penceresi
            if IsPedShooting(ped) then
                -- Interval içindeki tekrarları saymayalım (aynı ateş döngüsü)
                if lastShot == 0 or (now - lastShot) >= 30 then
                    LastShotAt[weaponHash] = now
                    SwayUntil[weaponHash]  = now + PostFireSwayMs
                end
            end

            -- ★ Atış sonrası sürekli sway (yumuşak azalır)
            local swayUntil = SwayUntil[weaponHash] or 0
            if now < swayUntil then
                local remaining = swayUntil - now
                local ratio = remaining / PostFireSwayMs
                ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', PostFireSwayIntensity * ratio)
            end
        else
            LastShotAt[weaponHash] = nil
            SwayUntil[weaponHash]  = nil
            Wait(200)
        end
    end
end)

RegisterCommand('triggerdebug', function()
    local ped = PlayerPedId()
    local hash = GetSelectedPedWeapon(ped)
    local interval = SemiAutoIntervals[hash]
    if not interval then
        print('[TRIGGER] Bu silah semi-auto listesinde degil')
        return
    end
    local now = GetGameTimer()
    local lastShot = LastShotAt[hash] or 0
    print(('[TRIGGER] hash=%d | interval=%dms | son-atistan=%dms'):format(
        hash, interval, lastShot > 0 and (now - lastShot) or -1))
end, false)

print('[TRIGGER_DISCIPLINE] v10 armed — spam filtresi only, flash+sfx NORMAL.')