-- =====================================================================
-- server/cognition_core.lua
-- vbs_core_matrix v3.0 — PHASE 1
-- COGNITIVE MATRIX & BIOCHEMICAL SHIFT GRID
--
-- ★ 0-RNG (no math.random anywhere)
-- ★ Strict determinism (same bot.dna_id => same IQ every boot)
-- ★ Immutable forensic base IQ (unalterable; runtime penalties are
--   additive overlays that rebuild on restart from persisted state)
-- ★ Humans/players are EXPLICITLY SKIPPED from this fatigue framework
--   (every public entry-point resolves ONLY via Matrix.Bots[botId]).
-- ★ Zero master-ticker cost: dedicated low-frequency thread, O(N)/min.
-- =====================================================================

Matrix = Matrix or {}
Matrix.Cognition = Matrix.Cognition or {}
Matrix.Cognition.Registry = Matrix.Cognition.Registry or {}   -- [botId] = cognition cell
Matrix.Cognition.__dirty  = Matrix.Cognition.__dirty  or {}   -- [botId] = true

local pairs, ipairs, type, tostring, tonumber, next = pairs, ipairs, type, tostring, tonumber, next
local math_floor, math_max, math_min, math_abs = math.floor, math.max, math.min, math.abs
local math_huge        = math.huge
local string_format    = string.format
local string_byte      = string.byte
local string_sub       = string.sub
local string_rep       = string.rep
local table_concat     = table.concat
local os_time          = os.time
local CreateThread, Wait = CreateThread, Wait

-- =====================================================================
-- SECTION 1 — DETERMINISTIC 64-CHAR HEX DIGEST (SHA-256 SHAPED, 0-RNG)
-- =====================================================================
-- If a global `sha256` helper is exposed by an external lib, we use it.
-- Otherwise we fall back to an 8-lane FNV-1a 32-bit cascade that emits
-- the exact same 64-hex-char shape, with the exact same determinism
-- guarantees. No math.random, no os.clock, no external entropy.
-- =====================================================================
local sha256_hex
if type(sha256) == 'table' and type(sha256.hex) == 'function' then
    sha256_hex = function(s) return sha256.hex(s) end
else
    local function _fnv1a32(input, seed)
        local h = seed % 4294967296
        for i = 1, #input do
            h = (h ~ input:byte(i)) % 4294967296
            -- FNV-1a 32-bit prime = 16777619
            h = (h * 16777619) % 4294967296
        end
        return h
    end

    sha256_hex = function(s)
        s = tostring(s or '')
        local lanes = {}
        for k = 0, 7 do
            -- Golden-ratio offset seeds (deterministic, zero RNG).
            local seed = (2166136261 + k * 2654435761) % 4294967296
            lanes[#lanes + 1] = string_format('%08x', _fnv1a32(s, seed))
        end
        return table_concat(lanes)   -- exactly 64 lowercase hex chars
    end
end

-- =====================================================================
-- SECTION 2 — IMMUTABLE IQ DERIVATION FROM bot.dna_id
-- =====================================================================
local IQ_MIN, IQ_MAX = 80, 140
local HEX_CHAR_MIN, HEX_CHAR_MAX = 48, 102     -- ASCII '0' .. 'f'
local BYTE_SUM_MIN = HEX_CHAR_MIN * 8          -- 384
local BYTE_SUM_MAX = HEX_CHAR_MAX * 8          -- 816
local BYTE_SUM_RANGE = BYTE_SUM_MAX - BYTE_SUM_MIN

--- Deterministic IQ derivation: sha256("COGNITION#"..dna_id),
--- first 8 chars, byte-sum, linear-normalize into [80, 140].
--- This is the ONLY writer of base_iq_score. Nothing else may assign it.
function Matrix.Cognition.DeriveIqFromDna(dnaId)
    local seed    = sha256_hex('COGNITION#' .. tostring(dnaId or ''))
    local first8  = string_sub(seed, 1, 8)
    local byteSum = 0
    for i = 1, #first8 do
        byteSum = byteSum + string_byte(first8, i)
    end
    -- Guard against pathological inputs (never expected in practice).
    if byteSum < BYTE_SUM_MIN then byteSum = BYTE_SUM_MIN end
    if byteSum > BYTE_SUM_MAX then byteSum = BYTE_SUM_MAX end

    local normalized = (byteSum - BYTE_SUM_MIN) / BYTE_SUM_RANGE
    local iq = math_floor(IQ_MIN + normalized * (IQ_MAX - IQ_MIN))
    if iq < IQ_MIN then iq = IQ_MIN end
    if iq > IQ_MAX then iq = IQ_MAX end
    return iq
end

-- =====================================================================
-- SECTION 3 — COGNITION CELL LIFECYCLE
-- =====================================================================
-- A cognition cell is created lazily on first access. It mirrors the
-- bot's dna_id-derived base IQ, tracks fatigue_accumulation and the
-- biochemical overlay. It NEVER touches players: only Matrix.Bots.
-- =====================================================================
local STIMULANT_DRUGS = {
    methamphetamine = true,
    meth            = true,
    stimulant       = true,
    amphetamine     = true,
    cocaine         = true
}
local DEPRESSANT_DRUGS = {
    opium     = true,
    heroin    = true,
    depressant= true,
    fentanyl  = true,
    morphine  = true
}

local function _ClassifyDrug(drugType)
    if type(drugType) ~= 'string' then return 'none' end
    local d = drugType:lower()
    if STIMULANT_DRUGS[d]  then return 'stimulant'  end
    if DEPRESSANT_DRUGS[d] then return 'depressant' end
    return 'none'
end

local function _NewCognitionCell(bot)
    local baseIq = Matrix.Cognition.DeriveIqFromDna(bot.dna_id)
    return {
        bot_id                 = bot.id,
        base_iq_score          = baseIq,      -- IMMUTABLE
        iq_penalty             = 0,           -- runtime overlay (depressant -30)
        withdrawal_index       = 0.0,         -- mirror of bot.biology.withdrawal_index
        fatigue_accumulation   = 0.0,
        consecutive_cycles     = 0,
        current_drug_influence = 'none',
        hallucination_index    = 0.0,
        fatigue_lock           = false,       -- stimulant lock
        cortisol_lock          = false,       -- depressant lock
        paranoit_crisis_fired  = false,
        updated_at             = os_time()
    }
end

--- Lazy-initializer. Idempotent. Never touches players.
local function GetOrCreateCognition(bot)
    if type(bot) ~= 'table' or type(bot.id) ~= 'number' then return nil end
    local cog = Matrix.Cognition.Registry[bot.id]
    if cog then return cog end

    cog = _NewCognitionCell(bot)
    Matrix.Cognition.Registry[bot.id] = cog
    Matrix.Cognition.__dirty[bot.id]  = true

    -- Rehydrate the drug-state overlay from the persisted column if the
    -- DB already had a value. Deterministic: same persisted state yields
    -- the exact same runtime overlay after every restart.
    pcall(function()
        local rows = MySQL.query.await(
            'SELECT current_drug_influence FROM matrix_bot_cognition WHERE bot_id = ?',
            { bot.id }
        )
        local persisted = rows and rows[1] and rows[1].current_drug_influence
        if persisted and persisted ~= 'none' then
            Matrix.Cognition.__ApplyOverlay(cog, persisted)
        end
    end)

    -- External modules may attach listeners (e.g. diagnostics, HUD).
    pcall(function()
        TriggerEvent('matrix:internal:cognitionInitialized', bot.id, cog)
    end)

    return cog
end
Matrix.Cognition.GetOrCreate = GetOrCreateCognition

--- Public read accessor (safe for external modules / HUD).
function Matrix.Cognition.GetCognition(botId)
    local bot = Matrix.Bots and Matrix.Bots[tonumber(botId)]
    if not bot then return nil end
    return GetOrCreateCognition(bot)
end

-- =====================================================================
-- SECTION 4 — EFFECTIVE IQ + FAILURE EQUATION (0-RNG)
-- =====================================================================
--- Effective (operational) IQ: base minus the runtime depressant penalty.
function Matrix.Cognition.GetEffectiveIq(botId)
    local bot = Matrix.Bots and Matrix.Bots[tonumber(botId)]
    if not bot then return nil end
    local cog = GetOrCreateCognition(bot)
    if not cog then return nil end
    local iq = cog.base_iq_score - cog.iq_penalty
    if iq < 1 then iq = 1 end   -- never negative / never zero denominator
    return iq
end

--- Failure probability per cycle. Exact 0-RNG formula from the spec:
---   failure_probability = (110 / bot_iq) * (1.0 + withdrawal_index)
---                                          * (1.0 + fatigue_accumulation)
--- Clamped to [0.05, 1.00].
function Matrix.Cognition.ComputeFailureProbability(botId)
    botId = tonumber(botId)
    if not botId then return nil end
    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return nil end

    local cog = GetOrCreateCognition(bot)
    if not cog then return nil end

    local iq = cog.base_iq_score - cog.iq_penalty
    if iq < 1 then iq = 1 end

    -- Mirror latest biological withdrawal (source of truth is bot.biology).
    local withdrawal = tonumber(bot.biology and bot.biology.withdrawal_index) or 0.0
    cog.withdrawal_index = withdrawal

    local fatigue = tonumber(cog.fatigue_accumulation) or 0.0

    local probability = (110.0 / iq) * (1.0 + withdrawal) * (1.0 + fatigue)

    -- Hard clamp [0.05, 1.00].
    if probability < 0.05 then probability = 0.05 end
    if probability > 1.00 then probability = 1.00 end
    if probability ~= probability then probability = 1.00 end  -- NaN guard
    return probability
end

-- =====================================================================
-- SECTION 5 — STIMULANT BEHAVIOURAL OVERLAY ("The Overdrive Cycle")
-- =====================================================================
local PARANOIT_WITHDRAWAL_THRESHOLD = 0.85
local PARANOIT_DECRYPTION_SPIKE     = 0.20
local HALLUCINATION_PER_TICK        = 0.05    -- per minute per dispatched tick

local function _FireParanoitCrisis(bot, cog)
    local trapId = bot.state and bot.state.trap_house_id
    if not trapId then return end

    -- 1) Fake LSPD ambush bulletin to F10 Baron Terminal.
    pcall(function()
        TriggerEvent('matrix:internal:fakeLspdBulletin', {
            bot_id        = bot.id,
            trap_house_id = trapId,
            kind          = 'lspd_ambush',
            coords        = bot.state and bot.state.coords or nil,
            confidence    = 0.85,
            source        = 'cognition_core'
        })
    end)
    pcall(function()
        TriggerClientEvent('matrix:client:fakeLspdBulletin', -1,
            bot.id, trapId, bot.state and bot.state.coords or nil)
    end)

    -- 2) Break local RadioSilence loops.
    if Matrix.RadioSilence
       and type(Matrix.RadioSilence.BreakForRedirect) == 'function'
       and bot.handler_citizenid then
        pcall(Matrix.RadioSilence.BreakForRedirect,
            bot.handler_citizenid, bot.id, trapId)
    end

    -- 3) +0.20 decryption confidence spike to the parent trap house.
    if Matrix.Bureau and type(Matrix.Bureau.AdvanceDecryption) == 'function' then
        pcall(Matrix.Bureau.AdvanceDecryption, trapId, PARANOIT_DECRYPTION_SPIKE)
    end

    Matrix.Log('COGNITION',
        '[PARANOIT KRIZ] Bot #%d (trap #%d) sahte LSPD pusu bulteni yayinladi, ' ..
        'RadioSilence kirildi, +%.2f decrypt conf.',
        bot.id, trapId, PARANOIT_DECRYPTION_SPIKE)
end

local function _TickStimulantOverlay(bot, cog)
    -- Fatigue lock: stimulant forces fatigue_accumulation to hard-zero.
    cog.fatigue_lock        = true
    cog.fatigue_accumulation= 0.0

    -- Counter-blowback: hallucination index grows per operational task tick.
    local isWorking = bot.state
        and bot.state.activity
        and bot.state.activity ~= 'idle'
    if not isWorking then return end

    cog.hallucination_index = math_min(1.0, cog.hallucination_index + HALLUCINATION_PER_TICK)

    local withdrawal = tonumber(bot.biology and bot.biology.withdrawal_index) or 0.0
    if withdrawal > PARANOIT_WITHDRAWAL_THRESHOLD
       and not cog.paranoit_crisis_fired then
        cog.paranoit_crisis_fired = true
        _FireParanoitCrisis(bot, cog)
    end
end

-- =====================================================================
-- SECTION 6 — DEPRESSANT BEHAVIOURAL OVERLAY ("The Cognitive Decay")
-- =====================================================================
local DEPRESSANT_IQ_PENALTY        = 30
local DEPRESSANT_MISROUTE_THRESHOLD= 0.60   -- effective failure probability

local function _DropOneCargoItem(botId)
    local invId = ('dealer_%d'):format(botId)
    local ok, inv = pcall(function()
        return exports['ox_inventory']:GetInventory(invId)
    end)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then
        return false
    end
    for slot, item in pairs(inv.items) do
        if type(item) == 'table'
           and type(item.name) == 'string'
           and (tonumber(item.count) or 0) > 0 then
            local removeOk, removed = pcall(function()
                return exports['ox_inventory']:RemoveItem(
                    invId, item.name, 1, item.metadata, slot)
            end)
            if removeOk and removed == true then
                return true
            end
        end
    end
    return false
end

local function _TickDepressantOverlay(bot, cog)
    -- Cortisol lock: depressant forces physiological cortisol at 0.0.
    cog.cortisol_lock = true
    if bot.biology then
        bot.biology.cortisol_level = 0.0
    end

    -- Cognitive cost: -30 flat IQ penalty (idempotent; overlay rebuilds
    -- from current_drug_influence on every restart, so this never stacks).
    cog.iq_penalty = DEPRESSANT_IQ_PENALTY

    -- Misinterpreted /timeemir routing — deterministic threshold trigger.
    local dispatch = Matrix.Dispatches and Matrix.Dispatches[bot.id]
    if not dispatch then return end

    local prob = Matrix.Cognition.ComputeFailureProbability(bot.id) or 0.0
    if prob < DEPRESSANT_MISROUTE_THRESHOLD then return end

    -- 0-RNG decision split: alternate comms loss and cargo mass drop
    -- using a deterministic integer derived from (bot_id + elapsed).
    local elapsedSec = math_floor(tonumber(dispatch.elapsed) or 0)
    local decision   = (bot.id + elapsedSec) % 2

    if decision == 0 then
        if not dispatch.comms_lost then
            dispatch.comms_lost = true
            Matrix.Log('COGNITION',
                '[TIMEEMIR SAPMASI] Bot #%d (depresan, prob=%.2f) rota komutunu yanlis yorumladi -- comms_lost=true (dead-zone).',
                bot.id, prob)
        end
    else
        local dropped = _DropOneCargoItem(bot.id)
        if dropped then
            Matrix.Log('COGNITION',
                '[TIMEEMIR SAPMASI] Bot #%d (depresan, prob=%.2f) kargo kutlesini dusurdu (1 birim).',
                bot.id, prob)
        end
    end
end

-- =====================================================================
-- SECTION 7 — PUBLIC APPLY CHEMICAL SHIFT
-- =====================================================================
local function __ApplyOverlay(cog, influence)
    if influence == 'stimulant' then
        cog.cortisol_lock          = false
        cog.fatigue_lock           = true
        cog.fatigue_accumulation   = 0.0
        cog.iq_penalty             = 0
        cog.paranoit_crisis_fired  = cog.paranoit_crisis_fired or false
    elseif influence == 'depressant' then
        cog.fatigue_lock           = false
        cog.cortisol_lock          = true
        cog.iq_penalty             = DEPRESSANT_IQ_PENALTY
    else
        -- Clear: physiological overlays removed; hallucination index is
        -- history-preserving and decays naturally by resetting per session.
        cog.fatigue_lock           = false
        cog.cortisol_lock          = false
        cog.iq_penalty             = 0
        cog.hallucination_index    = 0.0
        cog.paranoit_crisis_fired  = false
    end
end
Matrix.Cognition.__ApplyOverlay = __ApplyOverlay

--- Public API: ApplyChemicalShift(botId, drugType).
--- Players/humans are REJECTED silently (return false, 'not_a_bot').
function Matrix.Cognition.ApplyChemicalShift(botId, drugType)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end
    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return false, 'not_a_bot' end

    local influence = _ClassifyDrug(drugType)
    local cog       = GetOrCreateCognition(bot)
    if not cog then return false, 'cognition_unavailable' end

    cog.current_drug_influence = influence
    cog.updated_at             = os_time()

    __ApplyOverlay(cog, influence)

    Matrix.Cognition.__dirty[botId] = true

    Matrix.Log('COGNITION',
        '[BIOCHEMICAL SHIFT] Bot #%d (%s) -> %s (IQ efektif=%d, fatigue_lock=%s, cortisol_lock=%s)',
        botId, tostring(drugType), influence,
        cog.base_iq_score - cog.iq_penalty,
        tostring(cog.fatigue_lock), tostring(cog.cortisol_lock))

    return true, influence
end

-- =====================================================================
-- SECTION 8 — PER-MINUTE COGNITIVE TICK (0-RESMON, O(N) / minute)
-- =====================================================================
local CONSECUTIVE_CYCLE_THRESHOLD = 10     -- "at least 10 minutes"
local FATIGUE_STEP                = 0.15   -- hard step per overdue cycle

local function _TickBotMinute(bot)
    if type(bot) ~= 'table' or bot.status ~= 'active' then return end
    local cog = GetOrCreateCognition(bot)
    if not cog then return end

    -- Mirror the biological withdrawal (source of truth is bot.biology).
    cog.withdrawal_index = tonumber(bot.biology and bot.biology.withdrawal_index) or 0.0

    local activity = (bot.state and bot.state.activity) or 'idle'
    local isIdle   = (activity == 'idle')

    -- -----------------------------------------------------------------
    -- 1) WORK EXHAUSTION TICKER
    -- -----------------------------------------------------------------
    if isIdle then
        cog.consecutive_cycles = 0
    else
        cog.consecutive_cycles = cog.consecutive_cycles + 1
        if cog.consecutive_cycles >= CONSECUTIVE_CYCLE_THRESHOLD
           and not cog.fatigue_lock then
            cog.fatigue_accumulation = cog.fatigue_accumulation + FATIGUE_STEP
        end
    end

    -- -----------------------------------------------------------------
    -- 2) BIOCHEMICAL OVERLAYS
    -- -----------------------------------------------------------------
    if cog.current_drug_influence == 'stimulant' then
        _TickStimulantOverlay(bot, cog)
    elseif cog.current_drug_influence == 'depressant' then
        _TickDepressantOverlay(bot, cog)
    end

    cog.updated_at = os_time()
    Matrix.Cognition.__dirty[bot.id] = true
end

-- =====================================================================
-- SECTION 9 — PERSISTENCE (batched, pcall-guarded)
-- =====================================================================
local function _FlushCognitionDirty()
    local dirty = Matrix.Cognition.__dirty
    if not next(dirty) then return 0 end

    local flushed = 0
    for botId in pairs(dirty) do
        local cog = Matrix.Cognition.Registry[botId]
        if not cog then
            dirty[botId] = nil
        else
            local ok = pcall(function()
                MySQL.query.await([[
                    INSERT INTO matrix_bot_cognition
                        (bot_id, iq_score, withdrawal_index,
                         fatigue_accumulation, current_drug_influence, updated_at)
                    VALUES (?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        iq_score               = VALUES(iq_score),
                        withdrawal_index       = VALUES(withdrawal_index),
                        fatigue_accumulation   = VALUES(fatigue_accumulation),
                        current_drug_influence = VALUES(current_drug_influence),
                        updated_at             = NOW()
                ]], {
                    botId,
                    cog.base_iq_score,            -- immutable base persisted as canonical
                    cog.withdrawal_index,
                    cog.fatigue_accumulation,
                    cog.current_drug_influence
                })
            end)
            if ok then
                dirty[botId] = nil
                flushed = flushed + 1
            end
        end
    end
    return flushed
end

-- =====================================================================
-- SECTION 10 — RUNTIME HOOKS
-- =====================================================================

-- 10.1 — Pull cognition cells back in when main.lua loads bots at boot.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    -- Defer one tick: main.lua's LoadBotsFromDatabase runs on the same boot.
    CreateThread(function()
        Wait(200)
        for botId, bot in pairs(Matrix.Bots or {}) do
            GetOrCreateCognition(bot)
        end
    end)
end)

-- 10.2 — Purge cells when a bot is removed (mirrors main.lua YAMA 4).
AddEventHandler('matrix:internal:botRemoved', function(botId)
    if type(botId) ~= 'number' then return end
    Matrix.Cognition.Registry[botId] = nil
    Matrix.Cognition.__dirty[botId]  = nil
end)

-- 10.3 — Dedicated low-frequency driver. NOTHING in the master ticker
-- is touched; this thread waits 60s between sweeps and iterates only
-- the bot registry. O(N)/minute — negligible.
CreateThread(function()
    Wait(15000)   -- offset from boot to avoid startup concurrency
    while true do
        Wait(60000)
        local ok, err = pcall(function()
            for _, bot in pairs(Matrix.Bots or {}) do
                _TickBotMinute(bot)
            end
        end)
        if not ok then
            Matrix.Log('COGNITION', '[HATA] per-minute cognition tick basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

-- 10.4 — Persistence sweep (piggybacks nothing; standalone 30s thread).
CreateThread(function()
    Wait(20000)
    while true do
        Wait(30000)
        local ok, err = pcall(_FlushCognitionDirty)
        if not ok then
            Matrix.Log('COGNITION', '[HATA] cognition flush basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

-- 10.5 — Graceful shutdown persist.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    pcall(_FlushCognitionDirty)
end)

-- =====================================================================
-- SECTION 11 — PUBLIC EXPORTS (self-registering, no main.lua patch needed)
-- =====================================================================
exports('GetBotFailureProbability', function(botId)
    return Matrix.Cognition.ComputeFailureProbability(botId)
end)

exports('ApplyChemicalShift', function(botId, drugType)
    return Matrix.Cognition.ApplyChemicalShift(botId, drugType)
end)

exports('GetBotEffectiveIq', function(botId)
    return Matrix.Cognition.GetEffectiveIq(botId)
end)

exports('GetCognitionCell', function(botId)
    return Matrix.Cognition.GetCognition(botId)
end)

-- =====================================================================
-- SECTION 12 — DEBUG COMMANDS (restricted to same group as matrixdebug)
-- =====================================================================
local function _Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[COGNITION]', msg } })
    else
        print(('[MATRIX:COGNITION:CONSOLE] %s'):format(msg))
    end
end

-- Fail-closed yetki kapisi: player_telemetry.lua / debug_map.lua'daki
-- Matrix.Hierarchy.HasCommandAuthority deseniyle ayni. Herkes bir botun
-- biyokimyasal durumunu okuyup/degistiremesin.
local function _HasCommandAuthority(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return false end
    local st = Matrix.GetOrCreatePlayerState(src)
    if not st or not st.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(st.citizenid)
end

RegisterCommand('iqdurum', function(src, args)
    if not _HasCommandAuthority(src) then
        Matrix.Log('COGNITION', '[YETKI RED] /iqdurum: src=%s yetkisiz erisim denemesi.', tostring(src))
        _Reply(src, 'Yetkisiz.')
        return
    end
    local botId = tonumber(args[1])
    local bot = botId and Matrix.Bots[botId]
    if not bot then _Reply(src, 'Kullanim: /iqdurum [botId]'); return end
    local cog  = Matrix.Cognition.GetCognition(botId)
    local iq   = Matrix.Cognition.GetEffectiveIq(botId) or -1
    local prob = Matrix.Cognition.ComputeFailureProbability(botId) or -1
    _Reply(src, ('Bot #%d | BaseIQ=%d EffIQ=%d | Penalti=%d | FailProb=%.4f | FatigueAcc=%.3f | Withdrawal=%.3f | Drug=%s | Halluc=%.3f'):format(
        botId, cog.base_iq_score, iq, cog.iq_penalty, prob,
        cog.fatigue_accumulation, cog.withdrawal_index,
        cog.current_drug_influence, cog.hallucination_index))
end, false)

RegisterCommand('kimyasal', function(src, args)
    if not _HasCommandAuthority(src) then
        Matrix.Log('COGNITION', '[YETKI RED] /kimyasal: src=%s yetkisiz erisim denemesi.', tostring(src))
        _Reply(src, 'Yetkisiz.')
        return
    end
    local botId   = tonumber(args[1])
    local drug    = args[2]
    if not botId or not drug then
        _Reply(src, 'Kullanim: /kimyasal [botId] [meth|opium|heroin|none]'); return
    end
    local ok, influence = Matrix.Cognition.ApplyChemicalShift(botId, drug)
    if ok then
        _Reply(src, ('Bot #%d kimyasal etkisi: %s'):format(botId, influence))
    else
        _Reply(src, ('Uygulanamadi: %s'):format(tostring(influence)))
    end
end, false)

RegisterCommand('iqsifirla', function(src, args)
    if not _HasCommandAuthority(src) then
        Matrix.Log('COGNITION', '[YETKI RED] /iqsifirla: src=%s yetkisiz erisim denemesi.', tostring(src))
        _Reply(src, 'Yetkisiz.')
        return
    end
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then
        _Reply(src, 'Kullanim: /iqsifirla [botId]'); return
    end
    Matrix.Cognition.ApplyChemicalShift(botId, 'none')
    local cog = Matrix.Cognition.Registry[botId]
    if cog then
        cog.fatigue_accumulation = 0.0
        cog.consecutive_cycles   = 0
        cog.hallucination_index  = 0.0
        cog.paranoit_crisis_fired= false
        Matrix.Cognition.__dirty[botId] = true
    end
    _Reply(src, ('Bot #%d kognitif durum sifirlandi.'):format(botId))
end, false)

Matrix.Log('COGNITION', 'cognition_core.lua PHASE 1 yuklendi -- 0-RNG, strict determinism.')

Matrix.Log('COGNITION', 'cognition_core.lua PHASE 1 yuklendi -- 0-RNG, strict determinism.')

-- ★★★ BURADAN AŞAĞISI YENİ — İKİ SATIR EKLENECEK ★★★
-- Ic ticker'lari tani paketine ac. Bunlar public gameplay sozlesmesinin
-- parcasi DEGILDIR ve yalnizca matrix_diagnostics.lua'dan cagrilir.
Matrix.Cognition.__TickBotMinute        = _TickBotMinute
Matrix.Cognition.__TickStimulantOverlay = _TickStimulantOverlay
-- =====================================================================
-- ★★★ KÖK-NEDEN DÜZELTMESİ — COGNITION LEAK WRAPPER ★★★
-- [MATRIX:COGNITIVE_CORE_PHASE1][LEAK-FIX]
--
-- SORUN: Matrix.RemoveBot (main.lua) botu RAM'den silip DB'de
-- status='retired' yazıyor, ama matrix_bot_cognition satırını
-- SILMIYOR ve 'matrix:internal:botRemoved' event'ini TETIKLEMIYOR.
-- Sonuc: bir bot retired edildikten sonra AYNI bot ID'si (NextBotId
-- her boot 1'e resetlenir) yeni bir bot icin kullanildiginda,
-- GetOrCreateCognition'in DB rehydration'i ESKI drug overlay'i
-- geri yukluyor -- temiz bir bot 'depressant'/'stimulant' olarak
-- basliyor ve determinizm testleri bu yuzden sasiyor.
--
-- COZUM: Matrix.RemoveBot'u sar; bot silinmeden ONCE hem RAM
-- registry'sini hem de matrix_bot_cognition DB satirini temizle.
-- Bu, server/main.lua'ya DOKUNMADAN yapilir (ayni CashDecay.Launder
-- wrapper deseniyle).
-- =====================================================================

-- ★ [FAZ 0.1] Wrapper → Event-based Observer
-- Cognition DB temizliği artık RemoveBot wrapper'ı DEĞİL, subscriber.
AddEventHandler('matrix:internal:botRemoving', function(botId, reason, snapshot)
    botId = tonumber(botId)
    if not botId then return end

    Matrix.Cognition.Registry[botId] = nil
    Matrix.Cognition.__dirty[botId]  = nil

    pcall(function()
        MySQL.prepare('DELETE FROM matrix_bot_cognition WHERE bot_id = ?', { botId })
    end)
end)

-- =====================================================================
-- ★ KİŞİLİK + UZMANLIK SİSTEMİ (Personality + Specialty)
-- Deterministik üretim: dna_id'den türetilir, 0 RNG.
-- Aynı dna_id = aynı kişilik, HER ZAMAN.
-- =====================================================================

local SPECIALTY_LIST = {
    'marksman',    -- Uzun menzil isabet +%30
    'driver',      -- Araç kontrolü +%20
    'sneak',       -- Tespit mesafesi -%40
    'chemist',     -- Kimya hızı +%30
    'medic',       -- Yara sarma +%40
    'lockpicker',  -- Kilit açma +%50
    'talker',      -- İkna +%25
    'scout',       -- Görüş menzili +%30
}

local TEMPERAMENT_LIST = {
    'calm',        -- Soğukkanlı
    'nervous',     -- Gergin
    'hot-headed',  -- Fevri
    'cold',        -- Duygusuz
}

--- dna_id + salt → 0..1 arası deterministik sayı
local function _DeriveFloat(dnaId, salt)
    local seed = sha256_hex('PERSONALITY#' .. tostring(dnaId) .. '#' .. tostring(salt))
    local first4 = string_sub(seed, 1, 4)  -- İlk 4 hex char
    local num = tonumber(first4, 16) or 0  -- 0..65535
    return num / 65535.0
end

--- dna_id + salt → 1..N arası deterministik index
local function _DeriveIndex(dnaId, salt, maxN)
    local seed = sha256_hex('INDEX#' .. tostring(dnaId) .. '#' .. tostring(salt))
    local first4 = string_sub(seed, 1, 4)
    local num = tonumber(first4, 16) or 0
    return (num % maxN) + 1
end

--- Kişilik üret (4 boyut + temperament)
function Matrix.Cognition.GeneratePersonalityFromDna(dnaId)
    if type(dnaId) ~= 'string' or dnaId == '' then return nil end

    local tIdx = _DeriveIndex(dnaId, 'temperament', #TEMPERAMENT_LIST)

    return {
        patience   = _DeriveFloat(dnaId, 'patience'),    -- 0 sabırsız, 1 sabırlı
        aggression = _DeriveFloat(dnaId, 'aggression'),  -- 0 pasif, 1 agresif
        caution    = _DeriveFloat(dnaId, 'caution'),     -- 0 cesur, 1 temkinli
        loyalty    = _DeriveFloat(dnaId, 'loyalty'),     -- 0 hain, 1 sadık
        temperament = TEMPERAMENT_LIST[tIdx],
    }
end

--- Uzmanlık üret (1 ana + 1 yedek, farklı olacak)
function Matrix.Cognition.GenerateSpecialtyFromDna(dnaId)
    if type(dnaId) ~= 'string' or dnaId == '' then return nil end

    local pIdx = _DeriveIndex(dnaId, 'specialty_primary', #SPECIALTY_LIST)
    local primary = SPECIALTY_LIST[pIdx]

    -- İkincil: farklı olsun
    local sIdx = _DeriveIndex(dnaId, 'specialty_secondary', #SPECIALTY_LIST - 1)
    if sIdx >= pIdx then sIdx = sIdx + 1 end
    local secondary = SPECIALTY_LIST[sIdx]

    return {
        primary   = primary,
        bonus     = 0.30,      -- Ana uzmanlık: +%30
        secondary = secondary,
        bonus2    = 0.10,      -- Yedek uzmanlık: +%10
    }
end

-- v6.6.6 B13 (v6.6.5 [KOR NOKTA 1.1]'in bulgusu): recruitment.lua
-- Matrix.Cognition.DeriveCoercedPsychology'i cagiriyordu ama bu fonksiyon
-- hic tanimli degildi (guard'lanmis oldugu icin sessizce kendi
-- deterministik fallback'ine dusuyordu). Burada AYNI GeneratePersonalityFromDna
-- desenini (0 RNG, _DeriveFloat hash-tabanli) kullanan gercek bir
-- implementasyon tanimlanir -- baski (coercion) altinda devsirilen
-- ajanlar dogal recruitment'a gore daha korkak/daha ihbarci baslar;
-- addiction_level bu egilimi guclendirir.
function Matrix.Cognition.DeriveCoercedPsychology(data)
    if type(data) ~= 'table' then return nil end
    local seed = (type(data.dna_id) == 'string' and data.dna_id ~= '' and data.dna_id)
        or (type(data.citizenid) == 'string' and data.citizenid ~= '' and data.citizenid)
        or 'UNKNOWN-COERCED'
    local addictionFrac = Matrix.Clamp(tonumber(data.addiction_level) or 0.0, 0.0, 100.0) / 100.0

    return {
        fear_factor       = Matrix.Clamp(0.40 + _DeriveFloat(seed, 'coerced_fear') * 0.30 + addictionFrac * 0.20, 0.0, 1.0),
        resilience        = Matrix.Clamp(0.70 * _DeriveFloat(seed, 'coerced_resilience'), 0.0, 1.0),
        snitch_tendency   = Matrix.Clamp(0.10 + _DeriveFloat(seed, 'coerced_snitch') * 0.35, 0.0, 1.0),
        economic_pressure = Matrix.Clamp(0.20 + _DeriveFloat(seed, 'coerced_economic') * 0.55 + addictionFrac * 0.25, 0.0, 1.0),
        cognitive_shifter = Matrix.Clamp(0.30 + _DeriveFloat(seed, 'coerced_shifter') * 0.20, 0.0, 1.0),
        skill_chemistry   = Matrix.Clamp(0.15 + _DeriveFloat(seed, 'coerced_chemistry') * 0.10, 0.0, 1.0)
    }
end

-- Not: sha256_hex ve string_sub, dosyanın en başında tanımlı (Section 1).

-- =====================================================================
-- ★ [LEAK-FIX] DEVAM
-- =====================================================================

Matrix.Log('COGNITION', '[LEAK-FIX] botRemoving event subscriber aktif — cognition DB + RAM cleanup hooked.')
