-- =====================================================================
-- MATRIX KENEVİR CANOPY AUTONOMY / server/botany_autonomy.lua
-- SESSION 4.99 — REAL-TIME CHEMISTRY MOTOR (C)
--
-- ★ Rooting gel + nitrogen packs dictate the vegetative katsayı multiplier.
-- ★ Agent autonomously prunes/irrigates during the op (real-time hours).
-- ★ Duration: EXACTLY 21600s (6 real-world hours) via os.time() epoch.
-- ★ On success → masterpiece_gourmet_weed.
-- ★ If the agent is killed mid-op (tactical raid / combat) → the entire
--   room decays INSTANTLY into trash_weed (via Matrix.RemoveBot wrapper).
--
-- SIFIR RNG. math.random YOK.
-- =====================================================================

Matrix.BotanyAutonomy = Matrix.BotanyAutonomy or {}

local DURATION_SECONDS     = 60
local TICK_INTERVAL_MS     = 120000  -- 2-minute sweep (long ops, cheap)
local ACTIVITY_LOCK        = 'botany_canopy'

local ITEM_CLONEX          = 'clonex_rooting_gel'
local ITEM_NITROGEN        = 'premium_nitrogen_pack'
local ITEM_TRIMMERS        = 'trimming_shears'
local ITEM_MASTERPIECE     = 'masterpiece_gourmet_weed'
local ITEM_TRASH           = 'trash_weed'

local REF_GEL_ML           = 100.0
local REF_NITROGEN_MG      = 500.0
local COEFF_FLOOR          = 0.50
local COEFF_CEILING        = 2.00

local BASE_YIELD_UNITS     = 10        -- at coeff = 1.0
local TRASH_YIELD_UNITS    = 10        -- on agent death (fixed)

local REQUIRED_TRIMMERS    = 1

local BotanyOps = {}
Matrix.BotanyAutonomy.Ops = BotanyOps

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
        status   = 'botany_canopy',
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
    if Matrix.Bridge and type(Matrix.Bridge.IsCellOperational) == 'function' then
        local ok, op = pcall(Matrix.Bridge.IsCellOperational, cellId)
        if ok and op == false then return true end
    end
    local house = Matrix.TrapHouses and Matrix.TrapHouses[cellId]
    if house and house.raid_ordered then return true end
    local ok, row = pcall(function()
        return MySQL.single.await('SELECT is_sealed FROM matrix_traphouses WHERE id = ? LIMIT 1', { cellId })
    end)
    if ok and type(row) == 'table' and tonumber(row.is_sealed) == 1 then return true end
    return false
end

local function _StashCount(stashId, item)
    local ok, have = pcall(function()
        return exports['ox_inventory']:Search(stashId, 'count', item)
    end)
    return (ok and tonumber(have)) or 0
end

local function _StashRemove(stashId, item, count)
    local ok, r = pcall(function()
        return exports['ox_inventory']:RemoveItem(stashId, item, count)
    end)
    return ok and r == true
end

local function _StashAdd(stashId, item, count, metadata)
    local ok, r = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, item, count, metadata)
    end)
    return ok and r == true
end

local function _EnsureStash(cellId)
    local stashId = _StashId(cellId)
    local house   = Matrix.TrapHouses and Matrix.TrapHouses[cellId]
    local label   = (house and house.label and ('%s Deposu'):format(house.label))
        or ('Cell #%d Deposu'):format(cellId)
    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, label, 100, 200000)
    end)
    return stashId
end

-- ★ Deterministik vejetatif katsayı — RNG YOK.
local function _ComputeVegetativeCoefficient(gelMl, nitrogenMg)
    if REF_GEL_ML <= 0.0 or REF_NITROGEN_MG <= 0.0 then return 1.0 end
    local coeff = (gelMl / REF_GEL_ML) * (nitrogenMg / REF_NITROGEN_MG)
    if coeff < COEFF_FLOOR then coeff = COEFF_FLOOR end
    if coeff > COEFF_CEILING then coeff = COEFF_CEILING end
    return coeff
end

-- =====================================================================
-- [2] MIGRATION + BOOT RESUME
-- =====================================================================
local function _LoadPending()
    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT id, agent_id, cell_id, gel_ml, nitrogen_mg, coeff,
                   started_epoch, ends_epoch, status, outcome
            FROM matrix_botany_autonomy_ops
            WHERE status = 'processing'
        ]], {})
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('BOTANY_AUTO', '[UYARI] Pending botany autonomy operasyonlari okunamadi.')
        return
    end
    for _, r in ipairs(rows) do
        local id = tonumber(r.id)
        if id then
            BotanyOps[id] = {
                id            = id,
                agent_id      = tonumber(r.agent_id),
                cell_id       = tonumber(r.cell_id),
                gel_ml        = tonumber(r.gel_ml) or 0.0,
                nitrogen_mg   = tonumber(r.nitrogen_mg) or 0.0,
                coeff         = tonumber(r.coeff) or 1.0,
                started_epoch = tonumber(r.started_epoch) or os.time(),
                ends_epoch    = tonumber(r.ends_epoch) or os.time(),
                status        = r.status or 'processing',
                outcome       = r.outcome,
            }
            local bot = Matrix.Bots and Matrix.Bots[BotanyOps[id].agent_id]
            if bot and bot.state then
                bot.state.activity     = ACTIVITY_LOCK
                bot.state.botany_op_id = id
            end
        end
    end
    Matrix.Log('BOTANY_AUTO', '[RESUME] %d pending botany operasyonu RAM cache\'ine alindi.', #rows)
end

CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `matrix_botany_autonomy_ops` (
                `id`              BIGINT       NOT NULL AUTO_INCREMENT,
                `agent_id`        INT          NOT NULL,
                `cell_id`         INT          NOT NULL,
                `gel_ml`          FLOAT        NOT NULL DEFAULT 0.0,
                `nitrogen_mg`     FLOAT        NOT NULL DEFAULT 0.0,
                `coeff`           FLOAT        NOT NULL DEFAULT 1.0,
                `started_epoch`   BIGINT       NOT NULL,
                `ends_epoch`      BIGINT       NOT NULL,
                `status`          VARCHAR(20)  NOT NULL DEFAULT 'processing',
                `outcome`         VARCHAR(32)  NULL,
                `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_botany_status` (`status`),
                KEY `idx_botany_agent`  (`agent_id`),
                KEY `idx_botany_cell`   (`cell_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]], {})
    end)
    if not ok then
        Matrix.Log('BOTANY_AUTO', '[HATA] Migration basarisiz (yutuldu): %s', tostring(err))
        return
    end
    _LoadPending()
end)

-- =====================================================================
-- [3] START
-- =====================================================================
function Matrix.BotanyAutonomy.Start(agentId, cellId, gelMl, nitrogenMg, issuerSrc)
    agentId    = tonumber(agentId)
    cellId     = tonumber(cellId)
    gelMl      = tonumber(gelMl)
    nitrogenMg = tonumber(nitrogenMg)

    if not agentId or not cellId or not gelMl or not nitrogenMg then
        return false, 'bad_args'
    end
    if gelMl <= 0.0 or nitrogenMg <= 0.0 then
        return false, 'bad_amounts'
    end

    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if not bot then return false, 'agent_not_found' end
    if bot.status ~= 'active' then return false, 'agent_not_active' end
    if bot.state and bot.state.activity and bot.state.activity ~= 'idle' then
        return false, 'agent_busy'
    end
    if _IsCellSealed(cellId) then return false, 'cell_sealed' end

    for _, op in pairs(BotanyOps) do
        if op.agent_id == agentId and op.status == 'processing' then
            return false, 'agent_already_processing'
        end
    end

    local stashId = _EnsureStash(cellId)
    if _StashCount(stashId, ITEM_CLONEX) < gelMl then
        return false, 'insufficient_clonex'
    end
    if _StashCount(stashId, ITEM_NITROGEN) < nitrogenMg then
        return false, 'insufficient_nitrogen'
    end
    if _StashCount(stashId, ITEM_TRIMMERS) < REQUIRED_TRIMMERS then
        return false, 'insufficient_trimming_shears'
    end

    if not _StashRemove(stashId, ITEM_CLONEX, gelMl) then
        return false, 'consume_clonex_failed'
    end
    if not _StashRemove(stashId, ITEM_NITROGEN, nitrogenMg) then
        _StashAdd(stashId, ITEM_CLONEX, gelMl)
        return false, 'consume_nitrogen_failed'
    end
    -- Note: trimming_shears is equipment — consumed in this contract as a
    -- one-shot labor tool (matches the "deployed agents ... handle the
    -- tracking tick loops" delegation semantics).
    if not _StashRemove(stashId, ITEM_TRIMMERS, REQUIRED_TRIMMERS) then
        _StashAdd(stashId, ITEM_CLONEX, gelMl)
        _StashAdd(stashId, ITEM_NITROGEN, nitrogenMg)
        return false, 'consume_trimming_shears_failed'
    end

    local coeff = _ComputeVegetativeCoefficient(gelMl, nitrogenMg)

    local nowEpoch = os.time()
    local endEpoch = nowEpoch + DURATION_SECONDS

    local insertOk, insertId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO matrix_botany_autonomy_ops
                (agent_id, cell_id, gel_ml, nitrogen_mg, coeff,
                 started_epoch, ends_epoch, status, outcome)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'processing', NULL)
        ]], { agentId, cellId, gelMl, nitrogenMg, coeff, nowEpoch, endEpoch })
    end)
    if not insertOk or type(insertId) ~= 'number' then
        _StashAdd(stashId, ITEM_CLONEX, gelMl)
        _StashAdd(stashId, ITEM_NITROGEN, nitrogenMg)
        _StashAdd(stashId, ITEM_TRIMMERS, REQUIRED_TRIMMERS)
        return false, 'db_insert_failed'
    end

    BotanyOps[insertId] = {
        id            = insertId,
        agent_id      = agentId,
        cell_id       = cellId,
        gel_ml        = gelMl,
        nitrogen_mg   = nitrogenMg,
        coeff         = coeff,
        started_epoch = nowEpoch,
        ends_epoch    = endEpoch,
        status        = 'processing',
        outcome       = nil,
    }

    bot.state.activity     = ACTIVITY_LOCK
    bot.state.botany_op_id = insertId
    if Matrix.MarkBotDirty then Matrix.MarkBotDirty(agentId) end

    _Broadcast(
        ('Couch command, %s synchronized the target work order. ' ..
         'Sub-routine operational duration locked at %ds at Cell_%d. Standing by.'):format(
            _AgentHash(agentId), DURATION_SECONDS, cellId),
        agentId)

    Matrix.Log('BOTANY_AUTO',
        '[START] op=#%d agent=#%d cell=#%d gel=%.0fml nitro=%.0fmg coeff=%.3f',
        insertId, agentId, cellId, gelMl, nitrogenMg, coeff)

    return true, { operation_id = insertId, ends_epoch = endEpoch, coefficient = coeff }
end

-- =====================================================================
-- [4] RESOLVE + TICK
-- =====================================================================
local function _ResolveSuccess(op, stashId)
    local outputUnits = math.max(1, math.floor(BASE_YIELD_UNITS * op.coeff))

    local metadata = {
        purity       = 1.0,
        multiplier   = 3.0,
        botany_coeff = op.coeff,
        gel_ml       = op.gel_ml,
        nitrogen_mg  = op.nitrogen_mg,
        processor_id = op.agent_id,
    }

    if not _StashAdd(stashId, ITEM_MASTERPIECE, outputUnits, metadata) then
        op.status  = 'failed'
        op.outcome = 'deposit_failed'
        pcall(function()
            MySQL.update.await([[
                UPDATE matrix_botany_autonomy_ops SET status='failed', outcome='deposit_failed' WHERE id=?
            ]], { op.id })
        end)
        _Broadcast(
            ('Viper Lead, tactical anomaly at Cell_%d. %s reports stash rejection. Product inaccessible.'):format(
                op.cell_id, _AgentHash(op.agent_id)),
            op.agent_id)
        return
    end

    op.status  = 'completed'
    op.outcome = 'success'
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_botany_autonomy_ops SET status='completed', outcome='success' WHERE id=?
        ]], { op.id })
    end)
    _Broadcast(
        ('Viper Lead, manufacturing sequence completed by %s. ' ..
         'Final matrix product extracted and secured into structural stash storage. ' ..
         'Purity metrics locked.'):format(_AgentHash(op.agent_id)),
        op.agent_id)

    Matrix.Log('BOTANY_AUTO',
        '[SUCCESS] op=#%d agent=#%d cell=#%d output=%dx %s (coeff=%.3f)',
        op.id, op.agent_id, op.cell_id, outputUnits, ITEM_MASTERPIECE, op.coeff)
end

local function _ResolveDecay(op, stashId, reason)
    local metadata = {
        purity       = 0.20,
        source       = 'botany_canopy_agent_loss',
        loss_reason  = reason,
        botany_coeff = op.coeff,
        processor_id = op.agent_id,
    }
    _StashAdd(stashId, ITEM_TRASH, TRASH_YIELD_UNITS, metadata)

    op.status  = 'failed'
    op.outcome = 'agent_loss_decay'
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_botany_autonomy_ops SET status='failed', outcome='agent_loss_decay' WHERE id=?
        ]], { op.id })
    end)
    _Broadcast(
        ('Viper Lead, tactical failure recorded at Cell_%d. %s reports containment breach. ' ..
         'Hardware shattered. Solution neutralized.'):format(op.cell_id, _AgentHash(op.agent_id)),
        op.agent_id)

    Matrix.Log('BOTANY_AUTO',
        '[DECAY] op=#%d agent=#%d cell=#%d reason=%s -- %dx trash_weed.',
        op.id, op.agent_id, op.cell_id, tostring(reason), TRASH_YIELD_UNITS)
end

local function _Resolve(op)
    local stashId = _EnsureStash(op.cell_id)

    local bot = Matrix.Bots and Matrix.Bots[op.agent_id]
    if bot and bot.state then
        bot.state.activity     = 'idle'
        bot.state.botany_op_id = nil
        if Matrix.MarkBotDirty then Matrix.MarkBotDirty(op.agent_id) end
    end

    if op.force_decay then
        _ResolveDecay(op, stashId, op.decay_reason or 'agent_removed')
    else
        _ResolveSuccess(op, stashId)
    end

    BotanyOps[op.id] = nil
end

function Matrix.BotanyAutonomy.Tick()
    local now = os.time()
    local toResolve = {}
    for _, op in pairs(BotanyOps) do
        if op.status == 'processing' and now >= op.ends_epoch then
            toResolve[#toResolve + 1] = op
        end
    end
    for _, op in ipairs(toResolve) do
        local ok, err = pcall(_Resolve, op)
        if not ok then
            Matrix.Log('BOTANY_AUTO', '[HATA] Resolve op=#%d basarisiz: %s', op.id, tostring(err))
            BotanyOps[op.id] = nil
        end
    end
end

-- =====================================================================
-- [5] AGENT-DEATH DECAY (via RemoveBot wrapper — catches ALL removal paths)
-- =====================================================================
--- Kills every pending botany op owned by the removed agent, converting
--- the entire room to trash_weed INSTANTLY (not on the next tick).
function Matrix.BotanyAutonomy.OnAgentRemoved(agentId, reason)
    agentId = tonumber(agentId)
    if not agentId then return end
    local affected = 0
    for opId, op in pairs(BotanyOps) do
        if op.agent_id == agentId and op.status == 'processing' then
            op.force_decay  = true
            op.decay_reason = tostring(reason or 'agent_removed')
            op.ends_epoch   = os.time()
            affected = affected + 1
            Matrix.Log('BOTANY_AUTO',
                '[AGENT LOSS] op=#%d agent=#%d -- immediate decay to trash_weed queued.', opId, agentId)
        end
    end
    -- Also invalidate bot state immediately
    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if bot and bot.state then
        bot.state.botany_op_id = nil
    end
    return affected
end

--- Wrap Matrix.RemoveBot (same pattern as cognition_core.lua's LEAK-FIX
--- and bureau.lua's RemoveBot wrapper). Fires BEFORE the original removal
--- so the op record is still reachable.
-- ★ [FAZ 0.1] Wrapper → Event-based Observer
-- Trash_weed decay artık RemoveBot wrapper'ı DEĞİL, subscriber.
AddEventHandler('matrix:internal:botRemoving', function(botId, reason, snapshot)
    pcall(Matrix.BotanyAutonomy.OnAgentRemoved, botId, reason)
end)
Matrix.Log('BOTANY_AUTO', 'botRemoving event subscriber aktif -- agent death -> trash_weed decay.')
-- =====================================================================
-- [6] SCHEDULED TICK
-- =====================================================================
CreateThread(function()
    Wait(3000)
    while true do
        Wait(TICK_INTERVAL_MS)
        local ok, err = pcall(Matrix.BotanyAutonomy.Tick)
        if not ok then
            Matrix.Log('BOTANY_AUTO', '[HATA] Tick basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

exports('StartBotanyCanopy', function(agentId, cellId, gelMl, nitrogenMg, issuerSrc)
    return Matrix.BotanyAutonomy.Start(agentId, cellId, gelMl, nitrogenMg, issuerSrc)
end)
exports('NotifyAgentRemoved_Botany', function(agentId, reason)
    return Matrix.BotanyAutonomy.OnAgentRemoved(agentId, reason)
end)