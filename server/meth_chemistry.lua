-- =====================================================================
-- MATRIX METH P2P AMINATION / server/meth_chemistry.lua
-- SESSION 4.99 — REAL-TIME CHEMISTRY MOTOR (B)
--
-- ★ Methylamine : Phenylacetone — strict 1:1 molar synthesis.
-- ★ purity_drop = abs(methylamine_mg - phenylacetone_mg)
-- ★ toxicity    = purity_drop * TOXICITY_BASE * (1.0 - skill_chemistry)
-- ★ If toxicity > 65.0 → output flips to toxic_chemical_waste AND
--   triggers a gas-leak window on the cell: any operative entering
--   requires a gas_mask_filter (swap is enforced).
-- ★ Duration: EXACTLY 7200s (2 real-world hours) via os.time() epoch.
-- ★ Output: meth_crystal_shards (or toxic_chemical_waste).
--
-- SIFIR RNG: math.random YOK.
-- =====================================================================

Matrix.MethChem = Matrix.MethChem or {}
Matrix.ChemGasLeaks = Matrix.ChemGasLeaks or {}  -- [cellId] = expires_epoch

local METH_DURATION_SECONDS = 45
local TICK_INTERVAL_MS      = 60000
local ACTIVITY_LOCK         = 'meth_processing'

local ITEM_METHYLAMINE      = 'methylamine_barrel'
local ITEM_P2P              = 'phenylacetone_liq'
local ITEM_OUTPUT_CRYSTAL   = 'meth_crystal_shards'
local ITEM_OUTPUT_TOXIC     = 'toxic_chemical_waste'
local ITEM_GAS_FILTER       = 'gas_mask_filter'

local TOXICITY_BASE         = 200.0
local TOXICITY_THRESHOLD    = 65.0
local LEAK_WINDOW_SECONDS   = 300   -- 5 real-world minutes
local YIELD_COEFFICIENT     = 0.72
local MIN_OUTPUT_UNITS      = 1
local OUTPUT_UNIT_PER_MG    = 0.001

local MethOps = {}
Matrix.MethChem.Ops = MethOps

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
        status   = 'meth_chem',
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

local function _GetAgentChemistrySkill(agentId)
    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if not bot or not bot.psychology then return 0.0 end
    local skill = tonumber(bot.psychology.skill_chemistry) or 0.0
    if skill < 0.0 then skill = 0.0 end
    if skill > 1.0 then skill = 1.0 end
    return skill
end

-- =====================================================================
-- [2] MIGRATION + BOOT RESUME
-- =====================================================================
local function _LoadPending()
    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT id, agent_id, cell_id, methylamine_mg, phenylacetone_mg,
                   purity_drop, toxicity, skill_chemistry,
                   started_epoch, ends_epoch, status, outcome
            FROM matrix_meth_operations
            WHERE status = 'processing'
        ]], {})
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('METH', '[UYARI] Pending meth operasyonlari okunamadi.')
        return
    end
    for _, r in ipairs(rows) do
        local id = tonumber(r.id)
        if id then
            MethOps[id] = {
                id               = id,
                agent_id         = tonumber(r.agent_id),
                cell_id          = tonumber(r.cell_id),
                methylamine_mg   = tonumber(r.methylamine_mg) or 0.0,
                phenylacetone_mg = tonumber(r.phenylacetone_mg) or 0.0,
                purity_drop      = tonumber(r.purity_drop) or 0.0,
                toxicity         = tonumber(r.toxicity) or 0.0,
                skill_chemistry  = tonumber(r.skill_chemistry) or 0.0,
                started_epoch    = tonumber(r.started_epoch) or os.time(),
                ends_epoch       = tonumber(r.ends_epoch) or os.time(),
                status           = r.status or 'processing',
                outcome          = r.outcome,
            }
            local bot = Matrix.Bots and Matrix.Bots[MethOps[id].agent_id]
            if bot and bot.state then
                bot.state.activity   = ACTIVITY_LOCK
                bot.state.meth_op_id = id
            end
        end
    end
    Matrix.Log('METH', '[RESUME] %d pending meth operasyonu RAM cache\'ine alindi.', #rows)
end

CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `matrix_meth_operations` (
                `id`                BIGINT       NOT NULL AUTO_INCREMENT,
                `agent_id`          INT          NOT NULL,
                `cell_id`           INT          NOT NULL,
                `methylamine_mg`    FLOAT        NOT NULL DEFAULT 0.0,
                `phenylacetone_mg`  FLOAT        NOT NULL DEFAULT 0.0,
                `purity_drop`       FLOAT        NOT NULL DEFAULT 0.0,
                `toxicity`          FLOAT        NOT NULL DEFAULT 0.0,
                `skill_chemistry`   FLOAT        NOT NULL DEFAULT 0.0,
                `started_epoch`     BIGINT       NOT NULL,
                `ends_epoch`        BIGINT       NOT NULL,
                `status`            VARCHAR(20)  NOT NULL DEFAULT 'processing',
                `outcome`           VARCHAR(32)  NULL,
                `created_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_meth_status` (`status`),
                KEY `idx_meth_agent`  (`agent_id`),
                KEY `idx_meth_cell`   (`cell_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]], {})
    end)
    if not ok then
        Matrix.Log('METH', '[HATA] Migration basarisiz (yutuldu): %s', tostring(err))
        return
    end
    _LoadPending()
end)

-- =====================================================================
-- [3] START
-- =====================================================================
function Matrix.MethChem.Start(agentId, cellId, methylamineMg, p2pMg, issuerSrc)
    agentId       = tonumber(agentId)
    cellId        = tonumber(cellId)
    methylamineMg = tonumber(methylamineMg)
    p2pMg         = tonumber(p2pMg)

    if not agentId or not cellId or not methylamineMg or not p2pMg then
        return false, 'bad_args'
    end
    if methylamineMg <= 0.0 or p2pMg <= 0.0 then
        return false, 'bad_amounts'
    end

    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if not bot then return false, 'agent_not_found' end
    if bot.status ~= 'active' then return false, 'agent_not_active' end
    if bot.state and bot.state.activity and bot.state.activity ~= 'idle' then
        return false, 'agent_busy'
    end
    if _IsCellSealed(cellId) then return false, 'cell_sealed' end

    for _, op in pairs(MethOps) do
        if op.agent_id == agentId and op.status == 'processing' then
            return false, 'agent_already_processing'
        end
    end

    local stashId = _EnsureStash(cellId)
    if _StashCount(stashId, ITEM_METHYLAMINE) < methylamineMg then
        return false, 'insufficient_methylamine'
    end
    if _StashCount(stashId, ITEM_P2P) < p2pMg then
        return false, 'insufficient_p2p'
    end

    if not _StashRemove(stashId, ITEM_METHYLAMINE, methylamineMg) then
        return false, 'consume_methylamine_failed'
    end
    if not _StashRemove(stashId, ITEM_P2P, p2pMg) then
        _StashAdd(stashId, ITEM_METHYLAMINE, methylamineMg)
        return false, 'consume_p2p_failed'
    end

    local skill      = _GetAgentChemistrySkill(agentId)
    local purityDrop = math.abs(methylamineMg - p2pMg) / math.max(methylamineMg, 1.0)
    local toxicity   = purityDrop * TOXICITY_BASE * (1.0 - skill)
    if toxicity < 0.0 then toxicity = 0.0 end

    local nowEpoch = os.time()
    local endEpoch = nowEpoch + METH_DURATION_SECONDS

    local insertOk, insertId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO matrix_meth_operations
                (agent_id, cell_id, methylamine_mg, phenylacetone_mg,
                 purity_drop, toxicity, skill_chemistry,
                 started_epoch, ends_epoch, status, outcome)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'processing', NULL)
        ]], { agentId, cellId, methylamineMg, p2pMg, purityDrop, toxicity, skill, nowEpoch, endEpoch })
    end)
    if not insertOk or type(insertId) ~= 'number' then
        _StashAdd(stashId, ITEM_METHYLAMINE, methylamineMg)
        _StashAdd(stashId, ITEM_P2P, p2pMg)
        return false, 'db_insert_failed'
    end

    MethOps[insertId] = {
        id               = insertId,
        agent_id         = agentId,
        cell_id          = cellId,
        methylamine_mg   = methylamineMg,
        phenylacetone_mg = p2pMg,
        purity_drop      = purityDrop,
        toxicity         = toxicity,
        skill_chemistry  = skill,
        started_epoch    = nowEpoch,
        ends_epoch       = endEpoch,
        status           = 'processing',
        outcome          = nil,
    }

    bot.state.activity   = ACTIVITY_LOCK
    bot.state.meth_op_id = insertId
    if Matrix.MarkBotDirty then Matrix.MarkBotDirty(agentId) end

    _Broadcast(
        ('Couch command, %s synchronized the target work order. ' ..
         'Sub-routine operational duration locked at %ds at Cell_%d. Standing by.'):format(
            _AgentHash(agentId), METH_DURATION_SECONDS, cellId),
        agentId)

    Matrix.Log('METH',
        '[START] op=#%d agent=#%d cell=#%d methylamine=%.0fmg p2p=%.0fmg drop=%.4f tox=%.2f skill=%.2f',
        insertId, agentId, cellId, methylamineMg, p2pMg, purityDrop, toxicity, skill)

    return true, { operation_id = insertId, ends_epoch = endEpoch, toxicity = toxicity }
end

-- =====================================================================
-- [4] GAS-LEAK / ENTRY GUARD (public helper for other modules)
-- =====================================================================
function Matrix.MethChem.IsGasLeakActive(cellId)
    cellId = tonumber(cellId)
    if not cellId then return false end
    local until_ = Matrix.ChemGasLeaks[cellId]
    if not until_ then return false end
    if os.time() >= until_ then
        Matrix.ChemGasLeaks[cellId] = nil
        return false
    end
    return true
end

--- Any cell-entry handler (trap_house_interior.lua, workbench.lua,
--- chemical_workbench.lua, etc.) SHOULD call this before allowing an
--- operative into a cell that is under an active meth-leak.
--- @return boolean, string|nil  (ok, reason)
function Matrix.MethChem.CheckEntryRequirements(src, cellId)
    if not Matrix.MethChem.IsGasLeakActive(cellId) then return true end
    local ok, count = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', ITEM_GAS_FILTER)
    end)
    if not ok or (tonumber(count) or 0) < 1 then
        return false, 'gas_mask_filter_required'
    end
    return true
end

-- =====================================================================
-- [5] RESOLVE + TICK
-- =====================================================================
local function _Resolve(op)
    local agentId = op.agent_id
    local cellId  = op.cell_id
    local stashId = _EnsureStash(cellId)

    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if bot and bot.state then
        bot.state.activity   = 'idle'
        bot.state.meth_op_id = nil
        if Matrix.MarkBotDirty then Matrix.MarkBotDirty(agentId) end
    end

    local isToxic = op.toxicity > TOXICITY_THRESHOLD

    if isToxic then
        -- Trigger a gas leak window on the cell
        Matrix.ChemGasLeaks[cellId] = os.time() + LEAK_WINDOW_SECONDS

        -- Deposit toxic_chemical_waste (small amount — a hazardous byproduct)
        local wasteUnits = math.max(MIN_OUTPUT_UNITS, math.floor(op.methylamine_mg * OUTPUT_UNIT_PER_MG * 0.20))
        local wasteMeta = {
            toxicity     = op.toxicity,
            source       = 'meth_p2p_amination_failure',
            processor_id = agentId,
        }
        _StashAdd(stashId, ITEM_OUTPUT_TOXIC, wasteUnits, wasteMeta)

        op.status  = 'failed'
        op.outcome = 'toxic_waste'
        pcall(function()
            MySQL.update.await([[
                UPDATE matrix_meth_operations SET status='failed', outcome='toxic_waste' WHERE id=?
            ]], { op.id })
        end)

        _Broadcast(
            ('Viper Lead, tactical failure recorded at Cell_%d. %s reports containment breach. ' ..
             'Hardware shattered. Solution neutralized.'):format(cellId, _AgentHash(agentId)),
            agentId)

        Matrix.Log('METH',
            '[TOXIC] op=#%d agent=#%d cell=#%d tox=%.2f skill=%.2f -- GAS LEAK ACTIVE %ds.',
            op.id, agentId, cellId, op.toxicity, op.skill_chemistry, LEAK_WINDOW_SECONDS)
    else
        -- Success: deposit meth_crystal_shards
        local outputMg    = op.methylamine_mg * YIELD_COEFFICIENT
        local outputUnits = math.max(MIN_OUTPUT_UNITS, math.floor(outputMg * OUTPUT_UNIT_PER_MG))
        local purity      = math.max(0.30, 1.0 - (op.purity_drop * 0.5))

        local metadata = {
            purity       = purity,
            toxicity     = op.toxicity,
            mass_mg      = outputMg,
            processor_id = agentId,
            skill_chem   = op.skill_chemistry,
        }

        if not _StashAdd(stashId, ITEM_OUTPUT_CRYSTAL, outputUnits, metadata) then
            op.status  = 'failed'
            op.outcome = 'deposit_failed'
            pcall(function()
                MySQL.update.await([[
                    UPDATE matrix_meth_operations SET status='failed', outcome='deposit_failed' WHERE id=?
                ]], { op.id })
            end)
            _Broadcast(
                ('Viper Lead, tactical anomaly at Cell_%d. %s reports stash rejection. Product inaccessible.'):format(
                    cellId, _AgentHash(agentId)),
                agentId)
            MethOps[op.id] = nil
            return
        end

        op.status  = 'completed'
        op.outcome = 'success'
        pcall(function()
            MySQL.update.await([[
                UPDATE matrix_meth_operations SET status='completed', outcome='success' WHERE id=?
            ]], { op.id })
        end)

        _Broadcast(
            ('Viper Lead, manufacturing sequence completed by %s. ' ..
             'Final matrix product extracted and secured into structural stash storage. ' ..
             'Purity metrics locked.'):format(_AgentHash(agentId)),
            agentId)

        Matrix.Log('METH',
            '[SUCCESS] op=#%d agent=#%d cell=#%d output=%dx %s purity=%.3f tox=%.2f',
            op.id, agentId, cellId, outputUnits, ITEM_OUTPUT_CRYSTAL, purity, op.toxicity)
    end

    MethOps[op.id] = nil
end

function Matrix.MethChem.Tick()
    local now = os.time()
    local toResolve = {}
    for _, op in pairs(MethOps) do
        if op.status == 'processing' and now >= op.ends_epoch then
            toResolve[#toResolve + 1] = op
        end
    end
    for _, op in ipairs(toResolve) do
        local ok, err = pcall(_Resolve, op)
        if not ok then
            Matrix.Log('METH', '[HATA] Resolve op=#%d basarisiz: %s', op.id, tostring(err))
            MethOps[op.id] = nil
        end
    end
end

-- =====================================================================
-- [6] CANCEL
-- =====================================================================
function Matrix.MethChem.CancelForAgent(agentId, reason)
    agentId = tonumber(agentId)
    if not agentId then return 0 end
    local n = 0
    for opId, op in pairs(MethOps) do
        if op.agent_id == agentId and op.status == 'processing' then
            -- Cancel forces toxic output (bot can't stabilize without agent)
            op.toxicity   = TOXICITY_THRESHOLD + 1.0
            op.ends_epoch = os.time()
            n = n + 1
            Matrix.Log('METH', '[CANCEL] op=#%d agent=#%d reason=%s -- forced toxic waste.',
                opId, agentId, tostring(reason))
        end
    end
    return n
end

-- =====================================================================
-- [7] SCHEDULED TICK
-- =====================================================================
CreateThread(function()
    Wait(3000)
    while true do
        Wait(TICK_INTERVAL_MS)
        local ok, err = pcall(Matrix.MethChem.Tick)
        if not ok then
            Matrix.Log('METH', '[HATA] Tick basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

exports('StartMethAmination', function(agentId, cellId, methylamineMg, p2pMg, issuerSrc)
    return Matrix.MethChem.Start(agentId, cellId, methylamineMg, p2pMg, issuerSrc)
end)
exports('CancelMethForAgent', function(agentId, reason)
    return Matrix.MethChem.CancelForAgent(agentId, reason)
end)
exports('IsGasLeakActive', function(cellId)
    return Matrix.MethChem.IsGasLeakActive(cellId)
end)
exports('CheckCellEntryGasFilter', function(src, cellId)
    return Matrix.MethChem.CheckEntryRequirements(src, cellId)
end)