-- =====================================================================
-- MATRIX ENCRYPTED DARK CHAT REMOTE DELEGATION / server/cellular_comms.lua
-- SESSION 4.99 — MİLSİM TAKTİK İNTERFACE (Section 2)
--
-- ★ Eradicates phone script hooks — pure net interceptor.
-- ★ Parses cold clandestine work orders and routes them to the real-time
--   chemistry/botany engines (crack_chemistry.lua, meth_chemistry.lua,
--   botany_autonomy.lua).
-- ★ SIFIR RNG.
--
-- Net event: 'matrix:server:cellularComms:submitWorkOrder' (string)
-- =====================================================================

Matrix.CellularComms = Matrix.CellularComms or {}

-- =====================================================================
-- [1] COMMAND PATTERNS (Lua patterns — anchored, case-insensitive via
--     lowercase normalization; periods are optional to tolerate both
--     ". Cook freebase" and " Cook freebase")
-- =====================================================================
local PATTERNS = {
    {
        id    = 'crack',
        regex = '^%s*agent%s+(%d+)%s*,%s*lock%s+(%d+)%s*mg%s+cocaine%s+with%s+(%d+)%s*mg%s+bicarbonate%s+suspension%s+at%s+cell%s+(%d+)%s*%.?%s*cook%s+freebase%s*%.?%s*$',
    },
    {
        id    = 'meth',
        regex = '^%s*agent%s+(%d+)%s*,%s*extract%s+(%d+)%s*mg%s+methylamine%s+with%s+(%d+)%s*mg%s+p2p%s+compound%s+at%s+cell%s+(%d+)%s*%.?%s*flash%s+cook%s*%.?%s*$',
    },
    {
        id    = 'botany',
        regex = '^%s*agent%s+(%d+)%s*,%s*deploy%s+(%d+)%s*ml%s+clonex%s+gel%s+with%s+(%d+)%s*mg%s+nitrogen%s+pack%s+at%s+cell%s+(%d+)%s*%.?%s*clone%s+canopy%s*%.?%s*$',
    },
}

-- =====================================================================
-- [2] UTILITIES
-- =====================================================================
local function _AgentHash(agentId)
    return ('AGENT_%05d'):format(tonumber(agentId) or 0)
end

local function _HasCommandAuthority(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    -- v6.6.6 H17: fail-closed -- Matrix.Hierarchy henuz yuklenmemisse
    -- REDDET, asla acma (nil/eksik modul = yetkisiz demek).
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return false end
    local ok, state = pcall(Matrix.GetOrCreatePlayerState, src)
    if not ok or not state or not state.citizenid then return false end
    local authOk, hasAuth = pcall(Matrix.Hierarchy.HasCommandAuthority, state.citizenid)
    return authOk and hasAuth == true
end

local function _Broadcast(text, agentId)
    local payload = {
        bot_id   = agentId or 0,
        bot_name = agentId and _AgentHash(agentId) or 'DARKCHAT // ENCRYPTED',
        status   = 'cellular_comms',
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

local function _Reply(src, ok, text)
    if type(src) ~= 'number' or src <= 0 then return end
    if ok then
        pcall(TriggerClientEvent, 'matrix:client:actionNotify', src, true, text)
    else
        pcall(TriggerClientEvent, 'matrix:client:actionNotify', src, false, text)
    end
end

-- =====================================================================
-- [3] PARSER
-- =====================================================================
local function _Parse(orderText)
    local normalized = tostring(orderText or ''):lower()
    for _, entry in ipairs(PATTERNS) do
        local caps = { normalized:match(entry.regex) }
        if caps and caps[1] and caps[2] and caps[3] and caps[4] then
            return entry.id,
                tonumber(caps[1]),
                tonumber(caps[2]),
                tonumber(caps[3]),
                tonumber(caps[4])
        end
    end
    return nil
end

-- =====================================================================
-- [4] VALIDATION GUARD (is_sealed + agent alive + cell exists)
-- =====================================================================
local function _ValidateAgentAndCell(agentId, cellId)
    if not agentId or not cellId then
        return false, 'malformed_ids'
    end

    local bot = Matrix.Bots and Matrix.Bots[agentId]
    if not bot then return false, 'agent_not_found' end
    if bot.status ~= 'active' then return false, 'agent_not_active' end

    -- Cell exists in either registry
    local cellExists = (Matrix.TrapHouses and Matrix.TrapHouses[cellId] ~= nil)
    if not cellExists then
        -- Session-1 proxy fallback
        local ok, row = pcall(function()
            return MySQL.single.await('SELECT id FROM matrix_traphouses WHERE id = ? LIMIT 1', { cellId })
        end)
        if not ok or not row then return false, 'cell_not_found' end
    end

    return true
end

-- =====================================================================
-- [5] ROUTING
-- =====================================================================
local function _HandleCrack(agentId, a, b, cellId, src)
    if type(Matrix.CrackChem) ~= 'table' or type(Matrix.CrackChem.Start) ~= 'function' then
        return false, 'crack_engine_unavailable'
    end
    return Matrix.CrackChem.Start(agentId, cellId, a, b, src)
end

local function _HandleMeth(agentId, a, b, cellId, src)
    if type(Matrix.MethChem) ~= 'table' or type(Matrix.MethChem.Start) ~= 'function' then
        return false, 'meth_engine_unavailable'
    end
    return Matrix.MethChem.Start(agentId, cellId, a, b, src)
end

local function _HandleBotany(agentId, a, b, cellId, src)
    if type(Matrix.BotanyAutonomy) ~= 'table' or type(Matrix.BotanyAutonomy.Start) ~= 'function' then
        return false, 'botany_engine_unavailable'
    end
    return Matrix.BotanyAutonomy.Start(agentId, cellId, a, b, src)
end

local ROUTER = {
    crack  = _HandleCrack,
    meth   = _HandleMeth,
    botany = _HandleBotany,
}

-- =====================================================================
-- [6] NET EVENT — DARKCHAT WORK ORDER INGESTION
-- =====================================================================
RegisterNetEvent('matrix:server:cellularComms:submitWorkOrder', function(orderText)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(orderText) ~= 'string' then return end
    if #orderText > 512 then
        _Reply(src, false, 'DARKCHAT: work order exceeds 512 bytes -- rejected.')
        return
    end
    if not _HasCommandAuthority(src) then
        _Reply(src, false, 'DARKCHAT: insufficient command authority.')
        return
    end

    local kind, agentId, amountA, amountB, cellId = _Parse(orderText)
    if not kind then
        _Reply(src, false,
            'DARKCHAT: unrecognized work order format. ' ..
            'Accepted: "Agent N, lock Xmg cocaine with Ymg bicarbonate suspension at Cell C. Cook freebase." ' ..
            'or "...extract Xmg methylamine with Ymg P2P compound at Cell C. Flash cook." ' ..
            'or "...deploy Xml clonex gel with Ymg nitrogen pack at Cell C. Clone canopy."')
        Matrix.Log('COMMS', '[REJECT] src=%d pattern unmatched: %s', src, orderText:sub(1, 96))
        return
    end

    local ok, reason = _ValidateAgentAndCell(agentId, cellId)
    if not ok then
        _Reply(src, false, ('DARKCHAT: %s'):format(tostring(reason)))
        Matrix.Log('COMMS', '[REJECT] src=%d kind=%s reason=%s', src, kind, tostring(reason))
        return
    end

    local handler = ROUTER[kind]
    if not handler then
        _Reply(src, false, ('DARKCHAT: no handler for kind=%s'):format(tostring(kind)))
        return
    end

    local started, resultOrReason = handler(agentId, amountA, amountB, cellId, src)
    if started and type(resultOrReason) == 'table' then
        _Reply(src, true,
            ('DARKCHAT: work order accepted. Agent %s bound to Cell_%d. Duration locked.'):format(
                _AgentHash(agentId), cellId))
        Matrix.Log('COMMS',
            '[ACCEPT] src=%d kind=%s op_id=%s agent=#%d cell=#%d',
            src, kind, tostring(resultOrReason.operation_id or '?'), agentId, cellId)
    else
        _Reply(src, false,
            ('DARKCHAT: order rejected -- %s'):format(tostring(resultOrReason)))
        Matrix.Log('COMMS',
            '[REJECT] src=%d kind=%s reason=%s', src, kind, tostring(resultOrReason))
    end
end)

-- =====================================================================
-- [7] OPTIONAL TEST COMMAND (manual relay from chat, for ops/debug)
-- =====================================================================
RegisterCommand('darkchat', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    local text = table.concat(args or {}, ' ')
    if text == '' then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[DARKCHAT]', 'Kullanim: /darkchat Agent 1, lock 5000mg cocaine with 1500mg bicarbonate suspension at Cell 1. Cook freebase.' }
        })
        return
    end
    TriggerEvent('matrix:server:cellularComms:submitWorkOrder__invoke', src, text)
end, false)

-- Internal bridge so the /darkchat command can route through the net event
-- without needing a client round-trip (which would break for ops who
-- aren't online). This preserves a SINGLE canonical parser.
AddEventHandler('matrix:server:cellularComms:submitWorkOrder__invoke', function(src, orderText)
    if type(src) ~= 'number' or src <= 0 then return end
    if not _HasCommandAuthority(src) then
        _Reply(src, false, 'DARKCHAT: insufficient command authority.')
        Matrix.Log('COMMS', '[YETKI RED] /darkchat: src=%d yetkisiz erisim denemesi.', src)
        return
    end
    -- Reuse the same handler body via the event system
    local kind, agentId, amountA, amountB, cellId = _Parse(orderText)
    if not kind then
        _Reply(src, false, 'DARKCHAT: unrecognized work order format.')
        return
    end
    local ok, reason = _ValidateAgentAndCell(agentId, cellId)
    if not ok then
        _Reply(src, false, ('DARKCHAT: %s'):format(tostring(reason)))
        return
    end
    local handler = ROUTER[kind]
    if not handler then return end
    local started, resultOrReason = handler(agentId, amountA, amountB, cellId, src)
    if started then
        _Reply(src, true, ('DARKCHAT: work order accepted. Agent %s bound to Cell_%d.'):format(
            _AgentHash(agentId), cellId))
    else
        _Reply(src, false, ('DARKCHAT: %s'):format(tostring(resultOrReason)))
    end
end)

-- =====================================================================
-- [8] EXPORTS — programmatic entry point
-- =====================================================================
exports('SubmitCellularWorkOrder', function(src, orderText)
    if not _HasCommandAuthority(src) then
        Matrix.Log('COMMS', '[YETKI RED] SubmitCellularWorkOrder: src=%s yetkisiz erisim denemesi.', tostring(src))
        return false, 'insufficient_authority'
    end
    if type(orderText) ~= 'string' then return false, 'bad_order' end
    local kind, agentId, amountA, amountB, cellId = _Parse(orderText)
    if not kind then return false, 'unrecognized' end
    local ok, reason = _ValidateAgentAndCell(agentId, cellId)
    if not ok then return false, reason end
    local handler = ROUTER[kind]
    if not handler then return false, 'no_handler' end
    return handler(agentId, amountA, amountB, cellId, src)
end)