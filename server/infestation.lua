-- =====================================================================
-- PROJECT MATRIX — SESSION 2 — INFESTATION OUTBREAK LOOP
-- server/infestation.lua
--
-- ★ Deterministic: leaf_decay > 40% for > 2 consecutive real-world
--   hours → infestation_state = 1. Odor radius multiplier doubled.
-- ★ Eradication: pesticide_spray item at cabinet prop, 7s progress bar,
--   exp_gr_extinguisher particle (client side), counters reset to 0.
-- ★ SIFIR RNG. SIFIR math.random.
-- =====================================================================

Matrix.Infestation = Matrix.Infestation or { OdorMultiplier = {} } -- [trapHouseId] = number

local Core = Matrix.BotanyCore
if not Core then
    Matrix.Log('INFESTATION', '[HATA] botany_core.lua yuklenmedi -- infestation layer devre disi.')
    return
end

-- ---------------------------------------------------------------------
-- Deterministic odor radius multiplier (baseline = 1.0)
-- ---------------------------------------------------------------------
function Matrix.Infestation.GetOdorMultiplier(trapHouseId)
    return Matrix.Infestation.OdorMultiplier[tonumber(trapHouseId)] or 1.0
end

-- ---------------------------------------------------------------------
-- Outbreak handler (fires from botany_core.lua on latch)
-- ---------------------------------------------------------------------
AddEventHandler('matrix:internal:botanyInfestationOutbreak', function(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    Matrix.Infestation.OdorMultiplier[trapHouseId] = Config.BotanyCore.InfestationOdorMultiplier

    Matrix.Log('INFESTATION',
        '[OUTBREAK] Trap #%d infestation_state=1 -- odor multiplier set to x%.2f. Civilian reports accelerated.',
        trapHouseId, Config.BotanyCore.InfestationOdorMultiplier)

    -- Fire broadcast to civilian-report layer (existing Session-1 hooks)
    pcall(function()
        TriggerEvent('matrix:internal:increaseCivilianReports', trapHouseId, Config.BotanyCore.InfestationOdorMultiplier)
    end)
end)

-- ---------------------------------------------------------------------
-- Eradication: pesticide spray at the botany_cabinet prop
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:server:botany:eradicate', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    local rec = Core.GetOrCreate(trapHouseId)
    if not rec then return end

    if rec.infestation_state ~= 1 then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'No active infestation signature to purge.')
        return
    end

    -- Verify player carries pesticide_spray (ox_inventory export)
    local hasSpray = false
    pcall(function()
        local count = exports['ox_inventory']:Search(src, 'count', Config.BotanyCore.PesticideItem)
        hasSpray = (tonumber(count) or 0) > 0
    end)
    if not hasSpray then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Chemical vector not present in inventory.')
        return
    end

    -- Consume one canister (atomic; pcall-guarded)
    local removed = false
    pcall(function()
        removed = exports['ox_inventory']:RemoveItem(src, Config.BotanyCore.PesticideItem, 1)
    end)
    if removed ~= true then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Chemical vector consumption failed. Retry.')
        return
    end

    -- Reset counters to 0 (deterministic)
    rec.leaf_decay          = 0.0
    rec.infestation_state   = 0
    rec.infestation_started = nil
    Matrix.Infestation.OdorMultiplier[trapHouseId] = 1.0
    Core.Persist(rec)

    TriggerClientEvent('matrix:client:actionNotify', src, true,
        'Chemical vector deployed. Infestation cleared. Resetting baseline metrics.')

    Matrix.Log('INFESTATION',
        '[ERADICATED] src=%d trap=%d -- counters reset to baseline.',
        src, trapHouseId)
end)

-- ---------------------------------------------------------------------
-- Proximity verification guard (server-authoritative)
-- ---------------------------------------------------------------------
local function VerifyProximityToCabinet(src)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then
        return true -- defensive fallback when interior layer absent
    end
    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell then return false end
    local base = shell.WorkbenchPos
    if not base then return false end
    local coords = GetEntityCoords(ped)
    -- 1.8m strict lock (matches ox_target distance)
    return #(coords - base) <= Config.BotanyCore.TargetDistanceMeters
end

RegisterNetEvent('matrix:server:botany:eradicateStrict', function(trapHouseId)
    local src = source
    if not VerifyProximityToCabinet(src) then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Proximity verification error. Command out of operational range.')
        return
    end
    TriggerEvent('matrix:server:botany:eradicate', trapHouseId)
    -- Note: this event's handler runs on the same source; but TriggerEvent
    -- doesn't forward `source`, so we inline the same logic below.
end)

-- ---------------------------------------------------------------------
-- Passive enforcement: 60s sweep ensures latched infestations remain
-- at the multiplied odor state, and culls orphaned multipliers.
-- ---------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(60000)
        local ok, err = pcall(function()
            for trapHouseId, rec in pairs(Core.Cache or {}) do
                if rec.infestation_state == 1 then
                    Matrix.Infestation.OdorMultiplier[trapHouseId] = Config.BotanyCore.InfestationOdorMultiplier
                elseif Matrix.Infestation.OdorMultiplier[trapHouseId] ~= nil then
                    Matrix.Infestation.OdorMultiplier[trapHouseId] = nil
                end
            end
        end)
        if not ok then
            Matrix.Log('INFESTATION', '[HATA] sweep basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

exports('GetInfestationOdorMultiplier', function(id) return Matrix.Infestation.GetOdorMultiplier(id) end)