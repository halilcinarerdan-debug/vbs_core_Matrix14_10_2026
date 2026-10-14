print('[MATRIX:CRACK] ★ crack_chemistry.lua LOADED')
-- =====================================================================
-- MATRIX CRACK FREEBASE EXTRACTION / server/crack_chemistry.lua
-- SESSION 4.99 — REAL-TIME CHEMISTRY MOTOR (A)
--
-- ★ Cocaine : Sodium Bicarbonate — ideal 3:1 ratio (bicarb/cocaine=0.333)
-- ★ dev = abs((bicarbonate_mg / cocaine_mg) - IDEAL_BICARB_RATIO)
-- ★ HARD FAIL: dev > 0.15 AND bot_iq < 90 → glass_beaker SHATTERS,
--   100% of raw inputs destroyed, no product recovered.
-- ★ Duration: EXACTLY 3600s (1 real-world hour) via os.time() epoch.
-- ★ Output: crack_rock_lot (deposited into trap-house stash on success).
--
-- SIFIR RNG: math.random YOK. Tum kararlar esik karsilastirmasidir.
-- Tum IO pcall-guard'li; master ticker'i ASLA bloklamaz.
-- =====================================================================

Matrix.CrackChem = Matrix.CrackChem or {}

local IDEAL_BICARB_RATIO   = 0.333
local HARD_FAIL_DEV        = 0.15
local HARD_FAIL_IQ_CEILING = 90
local DURATION_SECONDS     = 30
local TICK_INTERVAL_MS     = 60000
local ACTIVITY_LOCK        = 'crack_processing'

local ITEM_COCAINE         = 'pure_cocaine_powder'
local ITEM_BICARB          = 'sodium_bicarbonate'
local ITEM_WATER           = 'distilled_water'
local ITEM_BEAKER          = 'glass_beaker'
local ITEM_OUTPUT          = 'crack_rock_lot'

local REQUIRED_WATER_ML    = 200
local REQUIRED_BEAKER      = 1
local YIELD_COEFFICIENT    = 0.85
local MIN_OUTPUT_UNITS     = 1
local OUTPUT_UNIT_PER_MG   = 0.001

local CrackOps = {}
Matrix.CrackChem.Ops = CrackOps

-- =====================================================================
-- [1] UTILITIES
-- =====================================================================
local function _AgentHash(agentId)
    return ('AGENT_%05d'):format(tonumber(agentId) or 0)
end

local function _StashId(cellId)
    return ('matrix_trap_stash_%d'):format(tonumber(cellId) or 0)
end

local function _HasCommandAuthority(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end

local function _Broadcast(text, agentId)
    local payload = {
        bot_id   = agentId or 0,
        bot_name = agentId and _AgentHash(agentId) or 'DARKCHAT // ENCRYPTED',
        status   = 'crack_chem',
        message  = text,
        epoch    = os.time(),
    }
    local list = GetPlayers()
    if type(list) ~= 'table' then return end
    for _, plyIdStr in ipairs(list) do
        local plySrc = tonumber(plyIdStr)
        if plySrc and _HasCommandAuthority(plySrc) then
            pcall(TriggerClientEvent, 'matrix:client:darkchat:telemetry', plySrc, payload)
        end
    end
end

local function _IsCellSealed(cellId)
    -- Session 1 proxy (matrix_traphouses) — is_sealed guard
    if Matrix.Bridge and type(Matrix.Bridge.IsCellOperational) == 'function' then
        local ok, op = pcall(Matrix.Bridge.IsCellOperational, cellId)
        if ok and op == false then return true end
    end
    -- Katman 2-8 (matrix_trap_houses) — raid_ordered guard
    local house = Matrix.TrapHouses and Matrix.TrapHouses[cellId]
    if house and house.raid_ordered then return true end
    -- Direct DB fallback (Session 1 proxy table)
    local ok, row = pcall(function()
        return MySQL.single.await(
            'SELECT is_sealed FROM matrix_traphouses WHERE id = ? LIMIT 1', { cellId })
    end)
    if ok and type(row) == 'table' and tonumber(row.is_sealed) == 1 then
        return true
    end
    return false
end

local function _StashCount(stashId, item)
    local ok, have = pcall(function()
        return exports['ox_inventory']:Search(stashId, 'count', item)
    end)
    if not ok then return 0 end
    return tonumber(have) or 0
end

local function _StashRemove(stashId, item, count)
    local ok, result = pcall(function()
        return exports['ox_inventory']:RemoveItem(stashId, item, count)
    end)
    return ok and result == true
end

local function _StashAdd(stashId, item, count, metadata)
    local ok, result = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, item, count, metadata)
    end)
    return ok and result == true
end

local function _EnsureStash(cellId)
    local stashId = _StashId(cellId)
    local house = Matrix.TrapHouses and Matrix.TrapHouses[cellId]
    local label = (house and house.label and ('%s Deposu'):format(house.label))
        or ('Cell #%d Deposu'):format(cellId)
    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, label, 100, 200000)
    end)
    return stashId
end

local function _GetAgentIq(agentId)
    if Matrix.Cognition and type(Matrix.Cognition.GetEffectiveIq) == 'function' then
        local ok, iq = pcall(Matrix.Cognition.GetEffectiveIq, agentId)
        if ok and type(iq) == 'number' and iq == iq then return iq end
    end
    return 100.0
end

-- =====================================================================
-- [2] MIGRATION + BOOT RESUME
-- =====================================================================
local function _LoadPending()
    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT id, agent_id, cell_id, cocaine_mg, bicarbonate_mg,
                   dev_value, agent_iq, started_epoch, ends_epoch, status, outcome
            FROM matrix_crack_operations
            WHERE status = 'processing'
        ]], {})
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('CRACK', '[UYARI] Pending crack operasyonlari okunamadi.')
        return
    end
    for _, r in ipairs(rows) do
        local id = tonumber(r.id)
        if id then
            CrackOps[id] = {
                id             = id,
                agent_id       = tonumber(r.agent_id),
                cell_id        = tonumber(r.cell_id),
                cocaine_mg     = tonumber(r.cocaine_mg) or 0.0,
                bicarbonate_mg = tonumber(r.bicarbonate_mg) or 0.0,
                dev_value      = tonumber(r.dev_value) or 0.0,
                agent_iq       = tonumber(r.agent_iq) or 100.0,
                started_epoch  = tonumber(r.started_epoch) or os.time(),
                ends_epoch     = tonumber(r.ends_epoch) or os.time(),
                status         = r.status or 'processing',
                outcome        = r.outcome,
            }
            local bot = Matrix.Bots and Matrix.Bots[CrackOps[id].agent_id]
            if bot and bot.state then
                bot.state.activity    = ACTIVITY_LOCK
                bot.state.crack_op_id = id
            end
        end
    end
    Matrix.Log('CRACK', '[RESUME] %d pending crack operasyonu RAM cache\'ine alindi.', #rows)
end

CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `matrix_crack_operations` (
                `id`              BIGINT       NOT NULL AUTO_INCREMENT,
                `agent_id`        INT          NOT NULL,
                `cell_id`         INT          NOT NULL,
                `cocaine_mg`      FLOAT        NOT NULL DEFAULT 0.0,
                `bicarbonate_mg`  FLOAT        NOT NULL DEFAULT 0.0,
                `dev_value`       FLOAT        NOT NULL DEFAULT 0.0,
                `agent_iq`        FLOAT        NOT NULL DEFAULT 100.0,
                `started_epoch`   BIGINT       NOT NULL,
                `ends_epoch`      BIGINT       NOT NULL,
                `status`          VARCHAR(20)  NOT NULL DEFAULT 'processing',
                `outcome`         VARCHAR(32)  NULL,
                `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_crack_status` (`status`),
                KEY `idx_crack_agent`  (`agent_id`),
                KEY `idx_crack_cell`   (`cell_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]], {})
    end)
    if not ok then
        Matrix.Log('CRACK', '[HATA] Migration basarisiz (yutuldu): %s', tostring(err))
        return
    end
    _LoadPending()
end)

-- =====================================================================
-- [3] START
-- =====================================================================
local function _ComputeDev(cocaineMg, bicarbMg)
    if cocaineMg <= 0.0 then return 999.0 end
    return math.abs((bicarbMg / cocaineMg) - IDEAL_BICARB_RATIO)
end

local function _WillHardFail(dev, agentIq)
    return dev > HARD_FAIL_DEV and agentIq < HARD_FAIL_IQ_CEILING
end

function Matrix.CrackChem.Start(agentId, cellId, cocaineMg, bicarbMg, issuerSrc)
    agentId   = tonumber(agentId)
    cellId    = tonumber(cellId)
    cocaineMg = tonumber(cocaineMg)
    bicarbMg  = tonumber(bicarbMg)

    if not agentId or not cellId or not cocaineMg or not bicarbMg then
        return false, 'bad_args'
    end
    if cocaineMg <= 0.0 or bicarbMg < 0.0 then
        return false, 'bad_amounts'
    end

    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if not bot then return false, 'agent_not_found' end
    if bot.status ~= 'active' then return false, 'agent_not_active' end
    if bot.state and bot.state.activity and bot.state.activity ~= 'idle' then
        return false, 'agent_busy'
    end
    if _IsCellSealed(cellId) then return false, 'cell_sealed' end

    for _, op in pairs(CrackOps) do
        if op.agent_id == agentId and op.status == 'processing' then
            return false, 'agent_already_processing'
        end
    end

    local stashId = _EnsureStash(cellId)
    if _StashCount(stashId, ITEM_COCAINE) < cocaineMg       then return false, 'insufficient_cocaine' end
    if _StashCount(stashId, ITEM_BICARB) < bicarbMg         then return false, 'insufficient_bicarbonate' end
    if _StashCount(stashId, ITEM_WATER) < REQUIRED_WATER_ML then return false, 'insufficient_water' end
    if _StashCount(stashId, ITEM_BEAKER) < REQUIRED_BEAKER  then return false, 'insufficient_beaker' end

    if not _StashRemove(stashId, ITEM_COCAINE, cocaineMg) then
        return false, 'consume_cocaine_failed'
    end
    if not _StashRemove(stashId, ITEM_BICARB, bicarbMg) then
        _StashAdd(stashId, ITEM_COCAINE, cocaineMg); return false, 'consume_bicarbonate_failed'
    end
    if not _StashRemove(stashId, ITEM_WATER, REQUIRED_WATER_ML) then
        _StashAdd(stashId, ITEM_COCAINE, cocaineMg)
        _StashAdd(stashId, ITEM_BICARB, bicarbMg); return false, 'consume_water_failed'
    end
    if not _StashRemove(stashId, ITEM_BEAKER, REQUIRED_BEAKER) then
        _StashAdd(stashId, ITEM_COCAINE, cocaineMg)
        _StashAdd(stashId, ITEM_BICARB, bicarbMg)
        _StashAdd(stashId, ITEM_WATER, REQUIRED_WATER_ML); return false, 'consume_beaker_failed'
    end

    local dev      = _ComputeDev(cocaineMg, bicarbMg)
    local agentIq  = _GetAgentIq(agentId)
    local willFail = _WillHardFail(dev, agentIq)

    local nowEpoch = os.time()
    local endEpoch = nowEpoch + DURATION_SECONDS

    local insertOk, insertId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO matrix_crack_operations
                (agent_id, cell_id, cocaine_mg, bicarbonate_mg,
                 dev_value, agent_iq, started_epoch, ends_epoch,
                 status, outcome)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'processing', NULL)
        ]], { agentId, cellId, cocaineMg, bicarbMg, dev, agentIq, nowEpoch, endEpoch })
    end)
    if not insertOk or type(insertId) ~= 'number' then
        _StashAdd(stashId, ITEM_COCAINE, cocaineMg)
        _StashAdd(stashId, ITEM_BICARB, bicarbMg)
        _StashAdd(stashId, ITEM_WATER, REQUIRED_WATER_ML)
        _StashAdd(stashId, ITEM_BEAKER, REQUIRED_BEAKER)
        return false, 'db_insert_failed'
    end

    CrackOps[insertId] = {
        id             = insertId,
        agent_id       = agentId,
        cell_id        = cellId,
        cocaine_mg     = cocaineMg,
        bicarbonate_mg = bicarbMg,
        dev_value      = dev,
        agent_iq       = agentIq,
        started_epoch  = nowEpoch,
        ends_epoch     = endEpoch,
        status         = 'processing',
        outcome        = nil,
        will_fail      = willFail,
    }

    bot.state.activity    = ACTIVITY_LOCK
    bot.state.crack_op_id = insertId
    if Matrix.MarkBotDirty then Matrix.MarkBotDirty(agentId) end

    _Broadcast(
        ('Couch command, %s synchronized the target work order. ' ..
         'Sub-routine operational duration locked at %ds at Cell_%d. Standing by.'):format(
            _AgentHash(agentId), DURATION_SECONDS, cellId),
        agentId)

    Matrix.Log('CRACK',
        '[START] op=#%d agent=#%d cell=#%d cocaine=%.0fmg bicarb=%.0fmg dev=%.4f iq=%.1f willFail=%s',
        insertId, agentId, cellId, cocaineMg, bicarbMg, dev, agentIq, tostring(willFail))

    return true, { operation_id = insertId, ends_epoch = endEpoch, will_fail = willFail }
end

-- =====================================================================
-- [4] RESOLVE + TICK
-- =====================================================================
local function _Resolve(op)
    local agentId  = op.agent_id
    local cellId   = op.cell_id
    local willFail = op.will_fail or _WillHardFail(op.dev_value, op.agent_iq)
    local stashId  = _EnsureStash(cellId)

    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if bot and bot.state then
        bot.state.activity    = 'idle'
        bot.state.crack_op_id = nil
        if Matrix.MarkBotDirty then Matrix.MarkBotDirty(agentId) end
    end

    if willFail then
        op.status  = 'failed'
        op.outcome = 'hardware_shattered'
        pcall(function()
            MySQL.update.await([[
                UPDATE matrix_crack_operations SET status='failed', outcome='hardware_shattered' WHERE id=?
            ]], { op.id })
        end)
        _Broadcast(
            ('Viper Lead, tactical failure recorded at Cell_%d. %s reports containment breach. ' ..
             'Hardware shattered. Solution neutralized.'):format(cellId, _AgentHash(agentId)),
            agentId)
        Matrix.Log('CRACK', '[FAIL] op=#%d agent=#%d cell=#%d dev=%.4f iq=%.1f (inputs destroyed)',
            op.id, agentId, cellId, op.dev_value, op.agent_iq)
    else
        local outputMg    = op.cocaine_mg * YIELD_COEFFICIENT
        local outputUnits = math.max(MIN_OUTPUT_UNITS, math.floor(outputMg * OUTPUT_UNIT_PER_MG))
        local purity      = math.max(0.30, 1.0 - (op.dev_value * 2.0))
        local metadata = {
            purity       = purity,
            mass_mg      = outputMg,
            processor_id = agentId,
            dev_value    = op.dev_value,
            agent_iq     = op.agent_iq,
        }

        if not _StashAdd(stashId, ITEM_OUTPUT, outputUnits, metadata) then
            op.status  = 'failed'
            op.outcome = 'deposit_failed'
            pcall(function()
                MySQL.update.await([[
                    UPDATE matrix_crack_operations SET status='failed', outcome='deposit_failed' WHERE id=?
                ]], { op.id })
            end)
            _Broadcast(
                ('Viper Lead, tactical anomaly at Cell_%d. %s reports stash rejection. Product inaccessible.'):format(
                    cellId, _AgentHash(agentId)),
                agentId)
            CrackOps[op.id] = nil
            return
        end

        op.status  = 'completed'
        op.outcome = 'success'
        pcall(function()
            MySQL.update.await([[
                UPDATE matrix_crack_operations SET status='completed', outcome='success' WHERE id=?
            ]], { op.id })
        end)
        _Broadcast(
            ('Viper Lead, manufacturing sequence completed by %s. ' ..
             'Final matrix product extracted and secured into structural stash storage. ' ..
             'Purity metrics locked.'):format(_AgentHash(agentId)),
            agentId)
        Matrix.Log('CRACK', '[SUCCESS] op=#%d agent=#%d cell=#%d output=%dx %s purity=%.3f',
            op.id, agentId, cellId, outputUnits, ITEM_OUTPUT, purity)
    end

    CrackOps[op.id] = nil
end

function Matrix.CrackChem.Tick()
    local now = os.time()
    local toResolve = {}
    for _, op in pairs(CrackOps) do
        if op.status == 'processing' and now >= op.ends_epoch then
            toResolve[#toResolve + 1] = op
        end
    end
    for _, op in ipairs(toResolve) do
        local ok, err = pcall(_Resolve, op)
        if not ok then
            Matrix.Log('CRACK', '[HATA] Resolve op=#%d basarisiz: %s', op.id, tostring(err))
            CrackOps[op.id] = nil
        end
    end
end

-- =====================================================================
-- [5] CANCEL (agent death / raid)
-- =====================================================================
function Matrix.CrackChem.CancelForAgent(agentId, reason)
    agentId = tonumber(agentId)
    if not agentId then return 0 end
    local n = 0
    for opId, op in pairs(CrackOps) do
        if op.agent_id == agentId and op.status == 'processing' then
            op.will_fail  = true        -- force failure path (inputs destroyed)
            op.ends_epoch = os.time()   -- immediate resolve on next tick
            n = n + 1
            Matrix.Log('CRACK', '[CANCEL] op=#%d agent=#%d reason=%s -- forced hard-fail.',
                opId, agentId, tostring(reason))
        end
    end
    return n
end

-- =====================================================================
-- [6] SCHEDULED TICK
-- =====================================================================
CreateThread(function()
    Wait(3000)
    while true do
        Wait(TICK_INTERVAL_MS)
        local ok, err = pcall(Matrix.CrackChem.Tick)
        if not ok then
            Matrix.Log('CRACK', '[HATA] Tick basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

exports('StartCrackFreebase', function(agentId, cellId, cocaineMg, bicarbMg, issuerSrc)
    return Matrix.CrackChem.Start(agentId, cellId, cocaineMg, bicarbMg, issuerSrc)
end)
exports('CancelCrackForAgent', function(agentId, reason)
    return Matrix.CrackChem.CancelForAgent(agentId, reason)
end)