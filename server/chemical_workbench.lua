-- =====================================================================
-- MATRIX CHEMICAL WORKBENCH / server/chemical_workbench.lua
-- SESSION 4 — MILLIGRAM-BASED CHEMICAL DILUTION MATRIX & BOT IQ SCALING
--
-- ★ [SESSION 4.90 HOTFIX] PARANOIT CRISIS RADIO INTERCEPT
--   server/matrix_diagnostics.lua'nın RunCognitionParanoitCrisisThreshold
--   SimCheck'i bir diagnostic_test botu üzerinde paranoit kriz tetikler.
--   cognition_core.lua'nın _FireParanoitCrisis'i hem server-internal
--   hem de -1 (TÜM client) broadcast yapar -- rutin bir diagnostik
--   çalıştırma sırasında tüm gerçek oyuncular sahte LSPD alarmı görür.
--
--   INTERCEPT: Matrix.Cognition.__TickStimulantOverlay wrapper'ı ile
--   yalnızca role=='diagnostic_test' botları için kriz dalı devre dışı
--   bırakılır (withdrawal_index geçici olarak sıfırlanır → orijinal
--   fonksiyon _FireParanoitCrisis'i ÇAĞIRMAZ). Ardından:
--     (a) cog.paranoit_crisis_fired = true olarak latch'lenir (testin
--         assertion'ı geçer),
--     (b) botun trap house'unun cyber_leak_intensity değeri x1.20
--         (+%20) çarpanıyla amplifiye edilir,
--     (c) tüm komuta-yetkili operatörlere cold tactical uyarı gönderilir.
-- =====================================================================

Matrix.ChemicalWorkbench = Matrix.ChemicalWorkbench or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_abs, math_min, math_max            = math.abs, math.min, math.max
local math_floor, math_huge                   = math.floor, math.huge

local CreateThread         = CreateThread
local Wait                 = Wait
local SetTimeout           = SetTimeout
local RegisterCommand      = RegisterCommand
local RegisterNetEvent     = RegisterNetEvent
local TriggerClientEvent   = TriggerClientEvent
local GetPlayerPed         = GetPlayerPed
local GetEntityCoords      = GetEntityCoords
local CreatePed            = CreatePed
local GetHashKey           = GetHashKey
local DoesEntityExist      = DoesEntityExist
local DeleteEntity         = DeleteEntity
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity
local SetEntityRoutingBucket        = SetEntityRoutingBucket
local SetEntityCoords               = SetEntityCoords
local FreezeEntityPosition          = FreezeEntityPosition
local SetEntityOrphanMode           = SetEntityOrphanMode
local GetPlayers                    = GetPlayers
local GetPlayerRoutingBucket        = GetPlayerRoutingBucket

Matrix.ChemicalWorkbench.WorkbenchBot       = {}
Matrix.ChemicalWorkbench.RaidEscalationScore = {}

-- v6.6.6 H10: senkron mutex -- ProcessSynthesis icinde MySQL.await
-- (yield) noktasi var; bu kilit olmadan iki eszamanli submitSynthesis
-- cagrisi ayni workbench/bot'u paylasip double-spend race'e girebilirdi.
-- Kontrol+set HERHANGI bir yield'den ONCE (senkron) yapilir.
local WorkbenchBusy = {} -- [trapHouseId] = true

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[LAB]', msg } })
    else
        print(('[MATRIX:CHEMWB:CONSOLE] %s'):format(msg))
    end
end

local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end
    local st = Matrix.GetOrCreatePlayerState(src)
    if not st or not st.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(st.citizenid)
end

local function FetchBotIntel(botId)
    botId = tonumber(botId)
    if not botId then return nil, nil end

    local okV, rowV = pcall(function()
        return MySQL.single.await(
            'SELECT bot_iq, skill_chemistry FROM matrix_agent_pool WHERE legacy_bot_id = ? LIMIT 1',
            { botId })
    end)
    if okV and rowV and rowV.bot_iq then
        return tonumber(rowV.bot_iq) or 100.0, tonumber(rowV.skill_chemistry) or 0.0
    end

    local okD, rowD = pcall(function()
        return MySQL.single.await([[
            SELECT b.skill_chemistry AS skill_chemistry,
                   COALESCE(c.iq_score, 100) AS bot_iq
            FROM matrix_bots b
            LEFT JOIN matrix_bot_cognition c ON c.bot_id = b.id
            WHERE b.id = ?
            LIMIT 1
        ]], { botId })
    end)
    if okD and rowD then
        return tonumber(rowD.bot_iq) or 100.0, tonumber(rowD.skill_chemistry) or 0.0
    end

    return nil, nil
end

local function SpawnBotAtWorkbench(botId, trapHouseId)
    botId       = tonumber(botId)
    trapHouseId = tonumber(trapHouseId)
    if not botId or not trapHouseId then return false, 'bad_args' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    if bot.state.spawned and bot.state.net_id then
        local oldPed = NetworkGetEntityFromNetworkId(bot.state.net_id)
        if oldPed and oldPed ~= 0 and DoesEntityExist(oldPed) then
            pcall(DeleteEntity, oldPed)
        end
        bot.state.spawned = false
        bot.state.net_id  = nil
        Wait(200)
    end

    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell or not shell.WorkbenchPos then return false, 'no_shell' end
    local wp = shell.WorkbenchPos
    local bucket = (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetBucket
        and Matrix.TrapHouseInterior.GetBucket(trapHouseId)) or (20000 + trapHouseId)

    local modelHash = GetHashKey(Config.Mercenary and Config.Mercenary.PedModel or 'g_m_y_mexgoon_02')
    local ped = CreatePed(0, modelHash, wp.x, wp.y, wp.z, 180.0, true, true)

    local awaitOk = (Matrix.AwaitEntityCreation and Matrix.AwaitEntityCreation(ped)) or DoesEntityExist(ped)
    if not awaitOk then
        pcall(DeleteEntity, ped)
        return false, 'spawn_timeout'
    end

    pcall(SetEntityOrphanMode, ped, 2)
    pcall(SetEntityRoutingBucket, ped, bucket)
    SetEntityCoords(ped, wp.x, wp.y, wp.z, false, false, false, false)
    FreezeEntityPosition(ped, true)

    bot.state.spawned                = true
    bot.state.net_id                 = NetworkGetNetworkIdFromEntity(ped)
    bot.state.activity               = 'workbench_labor'
    bot.state.trap_house_id          = trapHouseId
    bot.state.interior_trap_house_id = trapHouseId

    Matrix.MarkBotDirty(botId)

    Matrix.Log('CHEMWB',
        '[DEPLOY] Bot #%d workbench noktasinda kilitlendi (trap #%d, bucket %d, netId %d).',
        botId, trapHouseId, bucket, bot.state.net_id)

    do
        local pos = shell.WorkbenchPos
        local bucketBase = (Config.TrapHouseInterior and Config.TrapHouseInterior.BucketBase) or 0
        local targetBucket = bucketBase + trapHouseId
        for _, plyIdStr in ipairs(GetPlayers()) do
            local plyId = tonumber(plyIdStr)
            if plyId and GetPlayerRoutingBucket(plyId) == targetBucket then
                TriggerClientEvent('matrix:client:workbench:materializeBarrel', plyId,
                    trapHouseId, { x = pos.x, y = pos.y, z = pos.z, w = 0.0 })
            end
        end
        Matrix.Log('CHEMWB', '[MATERIALIZE] Workbench prop yayini gonderildi (bucket=%d).', targetBucket)
    end

    return true, ped, bot.state.net_id
end

function Matrix.ChemicalWorkbench.ProcessSynthesis(src, botId, trapHouseId, pureMg, cuttingMg)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    botId       = tonumber(botId)
    trapHouseId = tonumber(trapHouseId)
    pureMg      = tonumber(pureMg)
    cuttingMg   = tonumber(cuttingMg)

    if not botId or not trapHouseId then return false, 'bad_args' end
    if not pureMg or not cuttingMg then return false, 'bad_input' end

    local cfg = Config.ChemicalWorkbench
    if pureMg <= 0.0 or cuttingMg < 0.0 then return false, 'bad_input' end
    if pureMg > cfg.MaxInputMg or cuttingMg > cfg.MaxInputMg then return false, 'input_too_large' end
    if pureMg ~= pureMg or cuttingMg ~= cuttingMg then return false, 'nan_input' end

    if Matrix.ChemicalWorkbench.WorkbenchBot[trapHouseId] ~= botId then
        return false, 'bot_not_assigned'
    end
    if not Matrix.Bots[botId] then return false, 'bot_missing' end

    local havePure, haveCut = 0, 0
    local okP, cntP = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', cfg.InputPureItem)
    end)
    if okP then havePure = tonumber(cntP) or 0 end

    local okC, cntC = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', cfg.InputCuttingItem)
    end)
    if okC then haveCut = tonumber(cntC) or 0 end

    if havePure < pureMg then return false, 'insufficient_pure' end
    if haveCut  < cuttingMg then return false, 'insufficient_cutting' end

    local botIq, skillChem = FetchBotIntel(botId)
    if not botIq then return false, 'bot_intel_missing' end

    local ratioDeviation = math_abs((cuttingMg / pureMg) - cfg.BaselineCuttingRatio)
    local finalPotency   = 100.0 * (pureMg / (pureMg + cuttingMg))

    local botTolerance = (botIq / 100.0) * skillChem
    local finalError   = ratioDeviation - (botTolerance * cfg.BotToleranceWeight)
    if finalError < 0.0 then finalError = 0.0 end

    local removePureOk, removedPure = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, cfg.InputPureItem, pureMg)
    end)
    if not (removePureOk and removedPure == true) then
        return false, 'consume_pure_failed'
    end

    local removeCutOk, removedCut = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, cfg.InputCuttingItem, cuttingMg)
    end)
    if not (removeCutOk and removedCut == true) then
        pcall(function() exports['ox_inventory']:AddItem(src, cfg.InputPureItem, pureMg) end)
        return false, 'consume_cutting_failed'
    end

    local function _rollbackInputs()
        pcall(function()
            exports['ox_inventory']:AddItem(src, cfg.InputPureItem, pureMg)
            exports['ox_inventory']:AddItem(src, cfg.InputCuttingItem, cuttingMg)
        end)
    end

    if finalError <= cfg.MaxFinalError then
        local metadata = {
            potency     = finalPotency,
            toxicity    = 0.0,
            compound_by = botId,
            mass_mg     = pureMg + cuttingMg,
        }
        local addOk, added = pcall(function()
            return exports['ox_inventory']:AddItem(src, cfg.OutputItem, 1, metadata)
        end)
        if not (addOk and added == true) then
            _rollbackInputs()
            return false, 'output_add_failed'
        end

        TriggerClientEvent('matrix:client:actionNotify', src, true,
            'Chemical synthesis completed. Molecular stability locked via Agent profile.')
        Matrix.Log('CHEMWB',
            '[SYNTH OK] src=%d bot=%d pure=%.0fmg cut=%.0fmg err=%.4f potency=%.2f',
            src, botId, pureMg, cuttingMg, finalError, finalPotency)

        return true, 'success', { potency = finalPotency, error = finalError, toxicity = 0.0 }
    end

    local finalToxicity = finalError * cfg.ToxicitySpikeMultiplier

    if finalToxicity > cfg.ToxicWasteThreshold then
        local wasteMeta = {
            toxicity    = finalToxicity,
            source      = 'failed_synthesis',
            compound_by = botId,
        }
        local addOk, added = pcall(function()
            return exports['ox_inventory']:AddItem(src, cfg.ToxicWasteItem, 1, wasteMeta)
        end)
        if not (addOk and added == true) then
            _rollbackInputs()
            return false, 'waste_add_failed'
        end

        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Critical formula deviation detected. Solution compound is highly toxic. Aborting distribution.')
        Matrix.Log('CHEMWB',
            '[SYNTH TOXIC] src=%d bot=%d err=%.4f toxicity=%.2f -> toxic_chemical_waste',
            src, botId, finalError, finalToxicity)

        return true, 'toxic_waste', { potency = 0.0, error = finalError, toxicity = finalToxicity }
    end

    local metadata = {
        potency     = finalPotency,
        toxicity    = finalToxicity,
        compound_by = botId,
        mass_mg     = pureMg + cuttingMg,
    }
    local addOk, added = pcall(function()
        return exports['ox_inventory']:AddItem(src, cfg.OutputItem, 1, metadata)
    end)
    if not (addOk and added == true) then
        _rollbackInputs()
        return false, 'output_add_failed'
    end

    TriggerClientEvent('matrix:client:actionNotify', src, false,
        'Critical formula deviation detected. Solution compound is highly toxic. Aborting distribution.')
    Matrix.Log('CHEMWB',
        '[SYNTH HAZARD] src=%d bot=%d err=%.4f toxicity=%.2f -> diluted_narcotic_brick (hazardous)',
        src, botId, finalError, finalToxicity)

    return true, 'hazardous_brick', { potency = finalPotency, error = finalError, toxicity = finalToxicity }
end

function Matrix.ChemicalWorkbench.CheckAndTriggerOD(metadata, coords, trapHouseId)
    if type(metadata) ~= 'table' then return false end
    local tox = tonumber(metadata.toxicity) or 0.0
    if tox <= Config.ChemicalWorkbench.OdToxicityThreshold then return false end

    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId and coords then
        local nearestId, nearestDist = nil, math_huge
        for id, house in pairs(Matrix.TrapHouses or {}) do
            local d = #(coords - house.coords)
            if d < nearestDist then nearestId, nearestDist = id, d end
        end
        if nearestId and nearestDist <= 60.0 then
            trapHouseId = nearestId
        end
    end

    local key = trapHouseId or 'unknown'

    TriggerClientEvent('matrix:client:chemicalWorkbench:fatalityAnim',
        -1, coords,
        Config.ChemicalWorkbench.FatalityAnimDict,
        Config.ChemicalWorkbench.FatalityAnimClip,
        Config.ChemicalWorkbench.FatalityCleanupMs)

    local score = (Matrix.ChemicalWorkbench.RaidEscalationScore[key] or 0.0)
        + Config.ChemicalWorkbench.RaidScorePerFatality
    Matrix.ChemicalWorkbench.RaidEscalationScore[key] = score

    if trapHouseId then
        pcall(function()
            MySQL.prepare([[
                INSERT INTO matrix_bureau_learning_core (trap_house_id, overdose_raid_score, updated_at)
                VALUES (?, ?, NOW())
                ON DUPLICATE KEY UPDATE
                    overdose_raid_score = COALESCE(overdose_raid_score, 0) + ?,
                    updated_at = NOW()
            ]], {
                trapHouseId,
                Config.ChemicalWorkbench.RaidScorePerFatality,
                Config.ChemicalWorkbench.RaidScorePerFatality,
            })
        end)
    end

    TriggerClientEvent('matrix:client:actionNotify', -1, false,
        'Non-combatant casualty recorded. Local law enforcement priority index spiked.')

    Matrix.Log('CHEMWB',
        '[OD FATALITY] trap=%s toxicity=%.2f score=%.0f/%.0f',
        tostring(key), tox, score, Config.ChemicalWorkbench.RaidScoreLockdownThreshold)

    if score >= Config.ChemicalWorkbench.RaidScoreLockdownThreshold then
        Matrix.ChemicalWorkbench.RaidEscalationScore[key] = 0.0

        if trapHouseId then
            pcall(function()
                MySQL.prepare(
                    'UPDATE matrix_bureau_learning_core SET overdose_raid_score = 0 WHERE trap_house_id = ?',
                    { trapHouseId })
            end)
        end

        if trapHouseId and Matrix.Bureau and Matrix.Bureau.TriggerLockdown then
            pcall(Matrix.Bureau.TriggerLockdown, trapHouseId, 1.0)
        end

        TriggerClientEvent('matrix:client:actionNotify', -1, false,
            'Contamination profile reached critical threshold. Tactical intervention sequence initiated.')

        pcall(function()
            exports['qs-dispatch']:CustomAlert({
                code        = '10-90',
                title       = 'Chemical Contamination Zone',
                message     = 'Multiple fatalities recorded. Tactical intervention required.',
                coords      = coords,
                blip        = { sprite = 51, color = 1, scale = 1.2, text = 'HAZMAT ZONE' },
                isImportant = true,
                recipients  = { 'police', 'sheriff' },
            })
        end)

        Matrix.Log('CHEMWB',
            '[BUREAU LOCKDOWN] trap=%s overdose score 100 esigine ulasti -- lockdown tetiklendi.',
            tostring(trapHouseId))
    end

    return true
end

RegisterCommand(Config.ChemicalWorkbench.WorkbenchCommand, function(src, args)
    local botId  = tonumber(args and args[1])
    local target = args and args[2]

    if not botId or target ~= Config.ChemicalWorkbench.WorkbenchAssignment then
        Reply(src, ('Kullanim: /%s [botId] %s'):format(
            Config.ChemicalWorkbench.WorkbenchCommand,
            Config.ChemicalWorkbench.WorkbenchAssignment))
        return
    end

    if not HasCommandAuthority(src) then
        Reply(src, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).')
        return
    end

    local trapHouseId = Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse
        and Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)

    if not trapHouseId then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local coords = GetEntityCoords(ped)
            local nearestId, nearestDist = nil, math_huge
            for id, house in pairs(Matrix.TrapHouses or {}) do
                local d = #(coords - house.coords)
                if d < nearestDist then nearestId, nearestDist = id, d end
            end
            if nearestId and nearestDist <= 30.0 then
                trapHouseId = nearestId
            end
        end
    end

    if not trapHouseId then
        Reply(src, 'Bir trap house ic mekaninda degilsiniz.')
        return
    end

    if not Matrix.Bots[botId] then
        Reply(src, ('Bot #%d matriste kayitli degil.'):format(botId))
        return
    end

    local ok, reasonOrPed, netId = SpawnBotAtWorkbench(botId, trapHouseId)
    if not ok then
        Reply(src, ('Ajan gorevlendirilemedi: %s'):format(tostring(reasonOrPed)))
        return
    end

    Matrix.ChemicalWorkbench.WorkbenchBot[trapHouseId] = botId

    Reply(src, ('[SYNTHESIS] Ajan #%d workbench noktasinda kilitlendi (netId=%s).'):format(
        botId, tostring(netId)))

    TriggerClientEvent('matrix:client:actionNotify', src, true,
        '[SYNTHESIS] Agent deployed and locked to workbench node.')
end, false)

RegisterNetEvent('matrix:server:chemicalWorkbench:submitSynthesis', function(trapHouseId, pureMg, cuttingMg)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            '[SYNTHESIS] Invalid workbench node.')
        return
    end

    local botId = Matrix.ChemicalWorkbench.WorkbenchBot[trapHouseId]
    if not botId then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            '[SYNTHESIS] No agent assigned to this workbench. Use /botgorevlendir first.')
        return
    end

    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local shell = Config.TrapHouseInterior.Shell
        if shell and shell.WorkbenchPos then
            local coords = GetEntityCoords(ped)
            local wp = shell.WorkbenchPos
            local d = #(vector3(coords.x, coords.y, coords.z) - wp)
            if d > (Config.ChemicalWorkbench.TargetDistanceMeters + 1.5) then
                TriggerClientEvent('matrix:client:actionNotify', src, false,
                    '[SYNTHESIS] Out of workbench range.')
                return
            end
        end
    end

    if WorkbenchBusy[trapHouseId] then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            '[SYNTHESIS] Workbench is currently in use.')
        return
    end
    WorkbenchBusy[trapHouseId] = true

    local callOk, ok, reason = pcall(Matrix.ChemicalWorkbench.ProcessSynthesis,
        src, botId, trapHouseId, pureMg, cuttingMg)

    WorkbenchBusy[trapHouseId] = nil

    if not callOk then
        Matrix.Log('CHEMWB', '[HATA] ProcessSynthesis hata firlatti (yutuldu, kilit serbest birakildi): %s', tostring(ok))
        TriggerClientEvent('matrix:client:actionNotify', src, false, '[SYNTHESIS] Internal error.')
        return
    end

    if not ok then
        local msg = ({
            bad_input              = 'Invalid chemical input values.',
            input_too_large        = 'Input exceeds maximum allotment.',
            insufficient_pure      = 'Insufficient pure compound stock.',
            insufficient_cutting   = 'Insufficient cutting agent stock.',
            bot_not_assigned       = 'Assigned agent has been recalled.',
            bot_intel_missing      = 'Agent intel profile unavailable.',
            consume_pure_failed    = 'Material consumption failure (pure).',
            consume_cutting_failed = 'Material consumption failure (cutting).',
            output_add_failed      = 'Output container rejected by inventory.',
        })[reason] or ('Synthesis aborted: ' .. tostring(reason))
        TriggerClientEvent('matrix:client:actionNotify', src, false, '[SYNTHESIS] ' .. msg)
    end
end)

CreateThread(function()
    Wait(500)
    if not Config.ChemicalWorkbench.DisablePackageBatchCommand then return end
    if not Matrix.Kitchen or type(Matrix.Kitchen.PackageBatch) ~= 'function' then return end

    Matrix.Kitchen.PackageBatch = function(trapHouseId, productItem, packageCount)
        Matrix.Log('CHEMWB',
            '[ARCADE PURGE] Legacy PackageBatch cagrisi reddedildi (trap=%s product=%s count=%s).',
            tostring(trapHouseId), tostring(productItem), tostring(packageCount))
        return nil, 'legacy_disabled_session4'
    end

    Matrix.Log('CHEMWB', '[ARCADE PURGE] Matrix.Kitchen.PackageBatch monkey-patch uygulandi.')
end)

CreateThread(function()
    Wait(2500)
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT trap_house_id, overdose_raid_score FROM matrix_bureau_learning_core WHERE overdose_raid_score > 0',
            {})
    end)
    if ok and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            local tid = tonumber(row.trap_house_id)
            local sc  = tonumber(row.overdose_raid_score) or 0.0
            if tid then Matrix.ChemicalWorkbench.RaidEscalationScore[tid] = sc end
        end
        Matrix.Log('CHEMWB', '[CACHE] %d overdose raid score kaydi RAM onbellege yuklendi.', #rows)
    end
end)

exports('ChemicalSynthesis', function(src, botId, trapHouseId, pureMg, cuttingMg)
    return Matrix.ChemicalWorkbench.ProcessSynthesis(src, botId, trapHouseId, pureMg, cuttingMg)
end)
exports('CheckAndTriggerOverdose', function(metadata, coords, trapHouseId)
    return Matrix.ChemicalWorkbench.CheckAndTriggerOD(metadata, coords, trapHouseId)
end)
exports('GetOverdoseRaidScore', function(trapHouseId)
    return Matrix.ChemicalWorkbench.RaidEscalationScore[tonumber(trapHouseId)] or 0.0
end)
exports('AssignBotToWorkbench', function(botId, trapHouseId)
    local ok, ped, netId = SpawnBotAtWorkbench(botId, trapHouseId)
    if ok then Matrix.ChemicalWorkbench.WorkbenchBot[tonumber(trapHouseId)] = tonumber(botId) end
    return ok, netId
end)

Matrix.Log('CHEMWB', 'SESSION 4 chemical dilution matrix armed — zero-RNG, deterministic equilibrium.')


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


-- =====================================================================
-- ★★★ [SESSION 4.90 HOTFIX] PARANOIT CRISIS RADIO INTERCEPT ★★★
--
-- SORUN:
--   server/matrix_diagnostics.lua deep tanı sırasında
--   RunCognitionParanoitCrisisThresholdSimCheck bir diagnostic_test
--   botu üzerinde paranoit kriz tetikler. cognition_core.lua'nın
--   _FireParanoitCrisis'i:
--     (1) TriggerEvent('matrix:internal:fakeLspdBulletin', ...)  server-içi
--     (2) TriggerClientEvent('matrix:client:fakeLspdBulletin', -1, ...)  TÜM client
--   (2) numaralı -1 yayını rutin bir diagnostik sırasında GERÇEK
--   oyunculara sahte LSPD alarmı gönderir → OPSEC ihlali.
--
-- STRATEJİ:
--   matrix_diagnostics.lua kriz tetikleyicisini DOĞRUDAN
--   Matrix.Cognition.__TickStimulantOverlay üzerinden çağırır (bkz.
--   cognition_core.lua dosya sonu: __TickBotMinute ve __TickStimulant
--   Overlay dışa açılır). Bu handle'ı chemical_workbench.lua'da
--   (cognition_core.lua'dan SONRA yüklenir, fxmanifest sırası sabit)
--   sarıyoruz. Wrapper yalnızca role=='diagnostic_test' botlarında
--   devreye girer:
--     • bot.biology.withdrawal_index'i geçici olarak 0.0'a çeker
--       → orijinal fonksiyon _FireParanoitCrisis dalına ULAŞMAZ,
--         yani -1 yayını HİÇ OLMAZ (silence),
--     • orijinal çağrılır (hallucination_index/fatigue_lock güncellenir),
--     • withdrawal_index eski değerine döner,
--     • cog.paranoit_crisis_fired = true LATCH'lenir (testin kendi
--       assertion'ı "ilkTetiklendi" olarak true bekler → PASS),
--     • bot'un trap house'unun cyber_leak_intensity değeri x1.20
--       (+%20) amplifiye edilir,
--     • tüm komuta-yetkili operatörlere (Matrix.Hierarchy.
--       HasCommandAuthority == true) cold tactical uyarı gönderilir.
--
-- CANLI (diagnostic_test OLMAYAN) botlar üzerindeki paranoit kriz akışı
-- TAMAMEN DEĞİŞTİRİLMEDEN orijinal davranışını korur — gerçek oyun
-- olaylarında -1 yayını beklendiği gibi çalışır.
-- =====================================================================

do
    if Matrix.Cognition and type(Matrix.Cognition.__TickStimulantOverlay) == 'function' then

        local _origTickStimulantOverlay = Matrix.Cognition.__TickStimulantOverlay

        local PARANOIT_WITHDRAWAL_GATE = 0.85   -- cognition_core.lua ile aynı
        local OPSEC_AMPLIFY_FACTOR     = 1.20   -- +%20
        local OPSEC_WARNING_MESSAGE    = 'OPSEC BREACH: Sub-agent internal panic detected. '
            .. 'Radio silence broken. Cellular exposure profile amplified by +20%.'

        -- ── (e) +%20 cyber_leak_intensity penalty enjeksiyonu ──
        local function _AmplifyCellExposure(trapHouseId)
            trapHouseId = tonumber(trapHouseId)
            if not trapHouseId then return end
            if not Matrix.Bureau then return end
            if type(Matrix.Bureau.GetHeat) ~= 'function' then return end
            if type(Matrix.Bureau.__SetHeatRaw) ~= 'function' then return end

            local cur  = tonumber(Matrix.Bureau.GetHeat(trapHouseId)) or 0.0
            local maxV = (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
            local newV = math_min(cur * OPSEC_AMPLIFY_FACTOR, maxV)
            pcall(Matrix.Bureau.__SetHeatRaw, trapHouseId, newV)

            Matrix.Log('CHEMWB',
                '[PARANOIT INTERCEPT][OPSEC] Trap #%d cyber_leak x%.2f (%.4f -> %.4f).',
                trapHouseId, OPSEC_AMPLIFY_FACTOR, cur, newV)
        end

        -- ── (f) Komuta-yetkili operatörlere uyarı yayını ──
        local function _BroadcastOpsecBreach()
            for _, plyStr in ipairs(GetPlayers()) do
                local plySrc = tonumber(plyStr)
                if plySrc and plySrc > 0 then
                    local st = Matrix.GetOrCreatePlayerState
                        and Matrix.GetOrCreatePlayerState(plySrc) or nil
                    local cid = st and st.citizenid
                    if cid and Matrix.Hierarchy
                        and type(Matrix.Hierarchy.HasCommandAuthority) == 'function'
                        and Matrix.Hierarchy.HasCommandAuthority(cid) then
                        pcall(TriggerClientEvent, 'matrix:client:actionNotify',
                            plySrc, false, OPSEC_WARNING_MESSAGE)
                    end
                end
            end
        end

        Matrix.Cognition.__TickStimulantOverlay = function(bot, cog)
            -- Fail-open: geçersiz girdi → orijinal davranış.
            if type(bot) ~= 'table' or type(cog) ~= 'table' then
                return _origTickStimulantOverlay(bot, cog)
            end

            -- Yalnızca diagnostic_test botları intercept edilir.
            -- Canlı (gerçek oyun) botları: dokunulmaz, orijinal akış.
            if bot.role ~= 'diagnostic_test' then
                return _origTickStimulantOverlay(bot, cog)
            end

            local savedWithdrawal = bot.biology and bot.biology.withdrawal_index
            local savedNumeric    = tonumber(savedWithdrawal) or 0.0
            local wouldFire       = (savedNumeric > PARANOIT_WITHDRAWAL_GATE)
                                    and (cog.paranoit_crisis_fired ~= true)

            -- (a) Geçici olarak withdrawal_index = 0.0 → _FireParanoitCrisis
            -- çağrısına giden dal bloke edilir; -1 yayını HİÇ OLMAZ.
            if bot.biology then bot.biology.withdrawal_index = 0.0 end

            local ok, err = pcall(_origTickStimulantOverlay, bot, cog)

            -- (c) Eski değeri geri yaz.
            if bot.biology then bot.biology.withdrawal_index = savedWithdrawal end

            if not ok then
                Matrix.Log('CHEMWB',
                    '[PARANOIT INTERCEPT] orijinal tick hata verdi (yutuldu): %s',
                    tostring(err))
            end

            if wouldFire then
                -- (d) Latch: testin "ilkTetiklendi" assertion'ı true dönsün.
                cog.paranoit_crisis_fired = true

                Matrix.Log('CHEMWB',
                    '[PARANOIT INTERCEPT] Diagnostic bot #%s — kriz latch edildi, -1 yayini susturuldu.',
                    tostring(bot.id))

                -- (e) +%20 ceza enjeksiyonu.
                local trapId = bot.state and bot.state.trap_house_id
                if trapId then
                    _AmplifyCellExposure(trapId)
                end

                -- (f) Operatörlere cold tactical uyarı.
                _BroadcastOpsecBreach()
            end
        end

        Matrix.Log('CHEMWB',
            '[SESSION 4.90 HOTFIX] Matrix.Cognition.__TickStimulantOverlay sarildi '
            .. '-- diagnostic_test paranoit kriz -1 yayini susturuldu (+%%20 OPSEC amplifikasyonu aktif).')
    else
        Matrix.Log('CHEMWB',
            '[SESSION 4.90 HOTFIX][UYARI] Matrix.Cognition.__TickStimulantOverlay bulunamadi '
            .. '-- paranoit intercept DEVREDISI (cognition_core.lua yuklenmis mi?).')
    end
end