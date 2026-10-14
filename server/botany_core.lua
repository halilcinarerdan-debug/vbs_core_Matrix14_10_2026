-- =====================================================================
-- PROJECT MATRIX — SESSION 2 — BOTANY CORE (SERVER)
-- server/botany_core.lua
--
-- ★ ADVANCED OFFLINE/ONLINE BOTANY MOTOR over legacy kitchen.lua.
-- ★ SIFIR RNG. math.random YOK. Tüm ilerleme `os.time()` mutlak
--   timestamp'lerden DOĞRUSAL olarak türetilir.
-- ★ Legacy Matrix.Kitchen.BotanyCycle (Session 1) KORUNUR -- bu motor
--   onunla PARALEL çalışır ve fiziksel prop/offline decay katmanını
--   üstlenir.
-- =====================================================================

Matrix.BotanyCore = Matrix.BotanyCore or {}
Matrix.BotanyCore.Cache = Matrix.BotanyCore.Cache or {} -- [trapHouseId] = row

-- ---------------------------------------------------------------------
-- MIGRATION: additive schema. IF NOT EXISTS (idempotent).
-- ---------------------------------------------------------------------
CreateThread(function()
    local migOk, migErr = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS matrix_botany_state (
                trap_house_id        INT PRIMARY KEY,
                growth_percent       FLOAT   NOT NULL DEFAULT 0.0,
                water_level          FLOAT   NOT NULL DEFAULT 100.0,
                leaf_decay           FLOAT   NOT NULL DEFAULT 0.0,
                ph_level             FLOAT   NOT NULL DEFAULT 6.25,
                infestation_state    TINYINT NOT NULL DEFAULT 0,
                infestation_started  BIGINT  NULL,
                last_cycle_time      BIGINT  NOT NULL,
                crop_generation      INT     NOT NULL DEFAULT 0,
                updated_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        ]], {})
    end)
    if not migOk then
        Matrix.Log('BOTANY', '[HATA] Migration basarisiz (yutuldu): %s', tostring(migErr))
        return
    end

    -- Warm cache
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM matrix_botany_state', {})
    end)
    if ok and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            Matrix.BotanyCore.Cache[row.trap_house_id] = {
                trap_house_id       = tonumber(row.trap_house_id),
                growth_percent      = tonumber(row.growth_percent) or 0.0,
                water_level         = tonumber(row.water_level)    or 100.0,
                leaf_decay          = tonumber(row.leaf_decay)     or 0.0,
                ph_level            = tonumber(row.ph_level)       or 6.25,
                infestation_state   = tonumber(row.infestation_state) or 0,
                infestation_started = tonumber(row.infestation_started),
                last_cycle_time     = tonumber(row.last_cycle_time) or os.time(),
                crop_generation     = tonumber(row.crop_generation) or 0,
            }
        end
    end
    Matrix.Log('BOTANY', '[MIGRATION] matrix_botany_state hazir (%d kayit).', #(rows or {}))
end)

-- ---------------------------------------------------------------------
-- Cache accessor -- idempotent, lazy-init with os.time() baseline
-- ---------------------------------------------------------------------
local function GetOrCreate(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return nil end
    local rec = Matrix.BotanyCore.Cache[trapHouseId]
    if rec then return rec end

    rec = {
        trap_house_id       = trapHouseId,
        growth_percent      = 0.0,
        water_level         = 100.0,
        leaf_decay          = 0.0,
        ph_level            = 6.25,
        infestation_state   = 0,
        infestation_started = nil,
        last_cycle_time     = os.time(),
        crop_generation     = 0,
    }
    Matrix.BotanyCore.Cache[trapHouseId] = rec

    pcall(function()
        MySQL.insert.await([[
            INSERT INTO matrix_botany_state
                (trap_house_id, growth_percent, water_level, leaf_decay, ph_level,
                 infestation_state, infestation_started, last_cycle_time, crop_generation)
            VALUES (?, 0.0, 100.0, 0.0, 6.25, 0, NULL, ?, 0)
            ON DUPLICATE KEY UPDATE trap_house_id = trap_house_id
        ]], { trapHouseId, rec.last_cycle_time })
    end)

    return rec
end
Matrix.BotanyCore.GetOrCreate = GetOrCreate

-- ---------------------------------------------------------------------
-- DETERMINISTIC TIMESTAMPED OFFLINE GROWTH
--
-- elapsed_hours = (os.time() - last_cycle_time) / 3600
--
--   growth_percent += BaseGrowthPercentPerHour * cell_coefficient * elapsed_hours
--   water_level    -= WaterDropPercentPerHour * elapsed_hours
--   leaf_decay     += (LeafDecayPerHourAtZeroWater  if water==0)
--                  or (LeafDecayPerHourBadPH        if pH out-of-band)
--                  or 0
--
-- ★ Exactly once per real-world hour boundary check; the tick thread
--   calls AdvanceState() which is itself idempotent (clamps and
--   persists only when a 60-second wall-clock bucket flips).
-- ---------------------------------------------------------------------
local CELL_COEFFICIENT = {
    small  = 1.0,
    medium = 1.35,
    large  = 1.75,
}

local function ResolveCellCoefficient(trapHouseId)
    -- Reuse existing Session-1 cell-size resolution if available; else 1.0
    local bridge = Matrix.Bridge
    if bridge and bridge.IsCellOperational then
        -- safe-read
        local cell = nil
        pcall(function() cell = bridge.CellVariants and bridge.CellVariants.small end)
        if cell then return CELL_COEFFICIENT.small or 1.0 end
    end
    -- Fallback: derive deterministically from trapHouseId
    local sum = 0
    local raw = ('CELL#%d'):format(trapHouseId)
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + 17))) % 0xFFFFFFF
    end
    local bucket = (sum % 3) + 1
    if bucket == 1 then return CELL_COEFFICIENT.small  end
    if bucket == 2 then return CELL_COEFFICIENT.medium end
    return CELL_COEFFICIENT.large
end

local function IsPHOutOfBand(ph)
    local cfg = Config.BotanyCore
    return (ph < cfg.OptimalPHMin) or (ph > cfg.OptimalPHMax)
end

function Matrix.BotanyCore.AdvanceState(trapHouseId)
    local rec = GetOrCreate(trapHouseId)
    if not rec then return nil end

    local cfg = Config.BotanyCore
    local now = os.time()
    local elapsedSeconds = now - (rec.last_cycle_time or now)
    if elapsedSeconds <= 0 then return rec end

    local elapsedHours = elapsedSeconds / 3600.0
    local coeff = ResolveCellCoefficient(trapHouseId)

    -- 1) Growth: linear, clamped to 100.
    if rec.growth_percent < 100.0 then
        rec.growth_percent = math.min(
            100.0,
            rec.growth_percent + (cfg.BaseGrowthPercentPerHour * coeff * elapsedHours)
        )
    end

    -- 2) Water: linear decay at exactly 4.16%/hour.
    rec.water_level = math.max(0.0, rec.water_level - (cfg.WaterDropPercentPerHour * elapsedHours))

    -- 3) Leaf decay: trigger on zero-water OR pH out-of-band.
    local decayRate = 0.0
    if rec.water_level <= 0.0 then
        decayRate = cfg.LeafDecayPerHourAtZeroWater
    elseif IsPHOutOfBand(rec.ph_level) then
        decayRate = cfg.LeafDecayPerHourBadPH
    end
    if decayRate > 0.0 then
        rec.leaf_decay = math.min(100.0, rec.leaf_decay + (decayRate * elapsedHours))
    end

    -- 4) Infestation latch: leaf_decay > threshold for consecutive hours.
    if rec.leaf_decay > cfg.InfestationLeafDecayThreshold then
        if not rec.infestation_started then
            rec.infestation_started = now
        elseif (now - rec.infestation_started) >= (cfg.InfestationConsecutiveHours * 3600.0) then
            if rec.infestation_state ~= 1 then
                rec.infestation_state = 1
                Matrix.Log('BOTANY',
                    '[BOTANY INFESTATION] Trap #%d outbreak latched (leaf_decay=%.1f%% for >=%.1fh).',
                    trapHouseId, rec.leaf_decay, cfg.InfestationConsecutiveHours)
                TriggerEvent('matrix:internal:botanyInfestationOutbreak', trapHouseId)
            end
        end
    else
        rec.infestation_started = nil
    end

    rec.last_cycle_time = now
    return rec
end

local function Persist(rec)
    if not rec then return end
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_botany_state
               SET growth_percent = ?, water_level = ?, leaf_decay = ?, ph_level = ?,
                   infestation_state = ?, infestation_started = ?, last_cycle_time = ?,
                   crop_generation = ?, updated_at = NOW()
             WHERE trap_house_id = ?
        ]], {
            rec.growth_percent, rec.water_level, rec.leaf_decay, rec.ph_level,
            rec.infestation_state, rec.infestation_started, rec.last_cycle_time,
            rec.crop_generation, rec.trap_house_id,
        })
    end)
end
Matrix.BotanyCore.Persist = Persist

-- ---------------------------------------------------------------------
-- HARVEST RESOLUTION
-- growth >= 100 AND leaf_decay > 30%  -> trash_weed
-- growth >= 100 AND leaf_decay <= 30% -> masterpiece_gourmet_weed
-- ---------------------------------------------------------------------
local function TryHarvest(rec)
    if not rec or rec.growth_percent < 100.0 then return nil end
    local cfg = Config.BotanyCore

    local output = (rec.leaf_decay > cfg.TrashLeafDecayThreshold)
        and 'trash_weed'
        or  'masterpiece_gourmet_weed'

    rec.crop_generation = (rec.crop_generation or 0) + 1
    rec.growth_percent  = 0.0
    rec.leaf_decay      = 0.0
    rec.water_level     = math.max(rec.water_level, 50.0) -- baseline reset

    Matrix.Log('BOTANY',
        '[HARVEST] Trap #%d -> %s (decay_at_harvest=%.1f%% gen=%d)',
        rec.trap_house_id, output, rec.leaf_decay, rec.crop_generation)

    return output
end

-- ---------------------------------------------------------------------
-- NET EVENTS: player-driven interactions
-- ---------------------------------------------------------------------
RegisterNetEvent('matrix:server:botany:waterRestore', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    local actualTrapHouseId = Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not actualTrapHouseId or actualTrapHouseId ~= trapHouseId then
        Matrix.Log('BOTANY', '[YETKI RED] waterRestore: src=%d bildirdigi trap=%s icinde degil (gercek=%s).',
            src, tostring(trapHouseId), tostring(actualTrapHouseId))
        return
    end
    local rec = GetOrCreate(trapHouseId)
    if not rec then return end

    rec.water_level = math.min(100.0, rec.water_level + Config.BotanyCore.WaterRestorePct)
    Persist(rec)

    Matrix.Log('BOTANY',
        '[WATER RESTORE] src=%d trap=%d -> water=%.1f%%',
        src, trapHouseId, rec.water_level)
end)

RegisterNetEvent('matrix:server:botany:pruneLeaves', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    local actualTrapHouseId = Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not actualTrapHouseId or actualTrapHouseId ~= trapHouseId then
        Matrix.Log('BOTANY', '[YETKI RED] pruneLeaves: src=%d bildirdigi trap=%s icinde degil (gercek=%s).',
            src, tostring(trapHouseId), tostring(actualTrapHouseId))
        return
    end
    local rec = GetOrCreate(trapHouseId)
    if not rec then return end

    rec.leaf_decay = math.max(0.0, rec.leaf_decay - Config.BotanyCore.PruneDecayDrop)
    Persist(rec)

    Matrix.Log('BOTANY',
        '[LEAF PRUNING] src=%d trap=%d -> leaf_decay=%.1f%%',
        src, trapHouseId, rec.leaf_decay)
end)

RegisterNetEvent('matrix:server:botany:setPH', function(trapHouseId, ph)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    local actualTrapHouseId = Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not actualTrapHouseId or actualTrapHouseId ~= trapHouseId then
        Matrix.Log('BOTANY', '[YETKI RED] setPH: src=%d bildirdigi trap=%s icinde degil (gercek=%s).',
            src, tostring(trapHouseId), tostring(actualTrapHouseId))
        return
    end
    ph = tonumber(ph)
    if not ph then return end
    local cfg = Config.BotanyCore
    ph = math.max(cfg.PHRangeMin, math.min(cfg.PHRangeMax, ph))

    local rec = GetOrCreate(trapHouseId)
    if not rec then return end

    rec.ph_level = ph
    Persist(rec)

    Matrix.Log('BOTANY',
        '[UV TUNE] src=%d trap=%d -> ph=%.2f',
        src, trapHouseId, ph)
end)

-- ---------------------------------------------------------------------
-- CALLBACK: state read for client HUD/progress-bar feedback
-- ---------------------------------------------------------------------
lib.callback.register('matrix:server:botany:getState', function(src, trapHouseId)
    if type(src) ~= 'number' or src <= 0 then return nil end
    local rec = GetOrCreate(trapHouseId)
    if not rec then return nil end
    return {
        trap_house_id     = rec.trap_house_id,
        growth_percent    = rec.growth_percent,
        water_level       = rec.water_level,
        leaf_decay        = rec.leaf_decay,
        ph_level          = rec.ph_level,
        infestation_state = rec.infestation_state,
    }
end)

-- ---------------------------------------------------------------------
-- CALLBACK: spawn physical props into a trap-house interior instance
-- (called by client when entering a cell; positions come from
--  Config.TrapHouseInterior.Shell -- already present)
-- ---------------------------------------------------------------------
lib.callback.register('matrix:server:botany:getLabLayout', function(src, trapHouseId)
    if type(src) ~= 'number' or src <= 0 then return nil end
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell then return nil end

    local base = shell.WorkbenchPos or vector3(0, 0, 0)
    -- Deterministic offset derivation from trapHouseId (no RNG).
    local sum = 0
    local raw = ('LAB#%d'):format(tonumber(trapHouseId) or 0)
    for i = 1, #raw do sum = (sum + raw:byte(i) * (i + 23)) % 0xFFFFFFF end
    local ox = ((sum % 200) - 100) / 100.0 * 1.5   -- [-1.5, +1.5]
    local oy = (((sum / 200) % 200) - 100) / 100.0 * 1.5

    return {
        cabinet_pos = vector3(base.x + ox,        base.y + oy,        base.z),
        barrel_pos  = vector3(base.x + ox + 1.2,  base.y + oy,        base.z),
        uv_pos      = vector3(base.x + ox,        base.y + oy + 1.2,  base.z),
        cabinet_heading = 0.0,
        barrel_heading  = 90.0,
        uv_heading      = 180.0,
    }
end)

-- ---------------------------------------------------------------------
-- TICK THREAD: 60s bucket. Guarded: AdvanceState is idempotent.
-- ---------------------------------------------------------------------
local lastBucket = -1
CreateThread(function()
    while true do
        Wait(30000)
        local bucket = math.floor(os.time() / 60)
        if bucket ~= lastBucket then
            lastBucket = bucket
            local ok, err = pcall(function()
                for trapHouseId, rec in pairs(Matrix.BotanyCore.Cache) do
                    Matrix.BotanyCore.AdvanceState(trapHouseId)
                    local harvest = TryHarvest(Matrix.BotanyCore.Cache[trapHouseId])
                    if harvest then
                        -- fire-and-forget notification to operator network
                        local okNet = pcall(function()
                            TriggerEvent('matrix:internal:botanyHarvest', trapHouseId, harvest)
                        end)
                        if not okNet then
                            Matrix.Log('BOTANY', '[HATA] harvest broadcast basarisiz (yutuldu).')
                        end
                    end
                    Persist(Matrix.BotanyCore.Cache[trapHouseId])
                end
            end)
            if not ok then
                Matrix.Log('BOTANY', '[HATA] tick basarisiz (yutuldu): %s', tostring(err))
            end
        end
    end
end)

-- ---------------------------------------------------------------------
-- EXPORTS
-- ---------------------------------------------------------------------
exports('BotanyGetState',       function(id)     return GetOrCreate(id) end)
exports('BotanyAdvanceState',   function(id)     return Matrix.BotanyCore.AdvanceState(id) end)
exports('BotanyForceHarvest',   function(id)
    local rec = GetOrCreate(id)
    if not rec then return nil end
    rec.growth_percent = 100.0
    local out = TryHarvest(rec)
    Persist(rec)
    return out
end)
exports('BotanyApplyPH',        function(id, ph) TriggerEvent('matrix:server:botany:setPH', id, ph) end)

-- =====================================================================
-- RESIDUAL JARGON -- all user-facing strings, paramilitary tone:
--   "Greenhouse environment stabilization failed. Crop integrity decaying."
--   "Parasite infestation detected. Odor signature breached safe thresholds."
--   "Chemical vector deployed. Infestation cleared. Resetting baseline metrics."
--   "Proximity verification error. Command out of operational range."
-- =====================================================================

AddEventHandler('matrix:internal:botanyInfestationOutbreak', function(trapHouseId)
    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if not house then return end
    for _, src in ipairs(GetPlayers()) do
        local pid = tonumber(src)
        if pid then
            TriggerClientEvent('matrix:client:actionNotify', pid, false,
                'Parasite infestation detected. Odor signature breached safe thresholds.')
        end
    end
end)

AddEventHandler('matrix:internal:botanyHarvest', function(trapHouseId, outputKind)
    local line
    if outputKind == 'trash_weed' then
        line = 'Greenhouse environment stabilization failed. Crop integrity decaying.'
    else
        line = 'Harvest secured. Crop signature authenticated. Moving to distribution.'
    end
    for _, src in ipairs(GetPlayers()) do
        local pid = tonumber(src)
        if pid then
            TriggerClientEvent('matrix:client:actionNotify', pid, outputKind ~= 'trash_weed', line)
        end
    end
end)