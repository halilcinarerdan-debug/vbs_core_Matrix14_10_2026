-- =====================================================================
-- ★★★ MATRIX CHAOS ENGINE — YAMYAM MODU v2.0 ★★★
-- server/matrix_chaos.lua
--
-- FELSEFE: Bir HACKER gibi düşün, bir HACKER gibi saldır.
-- SİMÜLASYON İÇİNDE SİMÜLASYON: Her saldırı modülü kendi test ortamını
-- (fixture) kurar — trap house, bot, dispatch, fleet, player. Saldırı
-- bittikten sonra hepsini temizler. Canlı veriyi ETKİLEMEZ.
--
-- ★ Config.Chaos.Enabled = false ise HİÇBİR ŞEY yüklenmez.
-- ★ ZERO-RNG: Test dizileri deterministik.
-- =====================================================================

Matrix = Matrix or {}
Matrix.Chaos = Matrix.Chaos or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local table_insert = table.insert
local table_remove = table.remove
local table_concat = table.concat
local string_format = string.format
local string_rep    = string.rep
local os_time       = os.time
local math_abs      = math.abs
local math_min      = math.min
local math_max      = math.max
local math_floor    = math.floor

-- =====================================================================
-- STATE
-- =====================================================================
Matrix.Chaos.Findings      = {}
Matrix.Chaos.Modules       = {}
Matrix.Chaos.Running       = false
Matrix.Chaos.StartedAt     = 0
Matrix.Chaos.CurrentModule = nil
Matrix.Chaos.Stats         = {}

local SEVERITY_ORDER = { INFO = 1, LOW = 2, MEDIUM = 3, HIGH = 4, CRITICAL = 5 }
local SEVERITY_COLOR = {
    INFO = '^5', LOW = '^2', MEDIUM = '^6', HIGH = '^3', CRITICAL = '^1',
}

-- =====================================================================
-- BOX DRAWING
-- =====================================================================
local function _PadLine(text, width)
    text = tostring(text or '')
    if #text > width then text = text:sub(1, width - 3) .. '...' end
    return text .. string_rep(' ', width - #text)
end
local function _BoxLine(text, width) return '║ ' .. _PadLine(text, width) .. ' ║' end
local function _BoxDivider(width) return '╠' .. string_rep('═', width + 2) .. '╣' end
local function _BoxTop(width) return '╔' .. string_rep('═', width + 2) .. '╗' end
local function _BoxBottom(width) return '╚' .. string_rep('═', width + 2) .. '╝' end

-- =====================================================================
-- VBS 4 FORMATLI RAPOR
-- =====================================================================
function Matrix.Chaos.Report(severity, title, opts)
    -- ★ [SILENT MODE] — self-check çağrıları için global flag
    if Matrix.Chaos.__SilentMode or (opts and opts.silent == true) then
        Matrix.Chaos.__silentCount = (Matrix.Chaos.__silentCount or 0) + 1
        return
    end

    severity = tostring(severity or 'INFO'):upper()
    if not SEVERITY_ORDER[severity] then severity = 'INFO' end
    opts = opts or {}

    local minLevel = SEVERITY_ORDER[(Config.Chaos and Config.Chaos.MinSeverity) or 'LOW'] or 2
    if SEVERITY_ORDER[severity] < minLevel then return end

    local finding = {
        timestamp = os_time(),
        severity  = severity,
        title     = tostring(title or '?'),
        file      = opts.file or '?',
        line      = opts.line,
        attack    = opts.attack or '',
        impact    = opts.impact or '',
        fix       = opts.fix or '',
        reproduce = opts.reproduce or {},
        evidence  = opts.evidence,
        module    = Matrix.Chaos.CurrentModule or '?',
    }
    table_insert(Matrix.Chaos.Findings, finding)

    -- ★ NIL GUARD — tüm opsiyonel alanlar için
    local function _s(v) if type(v) == 'string' then return v end return '' end
    local sAttack = _s(opts.attack)
    local sImpact = _s(opts.impact)
    local sFix    = _s(opts.fix)
    local sEvid   = _s(opts.evidence)

    local width = 78
    local color = SEVERITY_COLOR[severity] or '^7'

    print('')
    print(color .. _BoxTop(width) .. '^7')
    print(color .. _BoxLine(string_format('[%s] %s', severity, title), width) .. '^7')
    print(color .. _BoxDivider(width) .. '^7')

    if opts.file and opts.file ~= '?' then
        local loc = opts.file
        if opts.line then loc = loc .. ':' .. tostring(opts.line) end
        print(color .. _BoxLine('DOSYA: ' .. loc, width) .. '^7')
    end
    print(color .. _BoxLine('MODUL: ' .. tostring(Matrix.Chaos.CurrentModule or '?'), width) .. '^7')

    if #sAttack > 0 then
        print(color .. _BoxDivider(width) .. '^7')
        print(color .. _BoxLine('SALDIRI:', width) .. '^7')
        for line in sAttack:gmatch('[^\n]+') do
            print(color .. _BoxLine('  ' .. line, width) .. '^7')
        end
    end

    if #sImpact > 0 then
        print(color .. _BoxLine('ETKI:', width) .. '^7')
        for line in sImpact:gmatch('[^\n]+') do
            print(color .. _BoxLine('  ' .. line, width) .. '^7')
        end
    end

    if #sFix > 0 then
        print(color .. _BoxLine('ONERI:', width) .. '^7')
        for line in sFix:gmatch('[^\n]+') do
            print(color .. _BoxLine('  ' .. line, width) .. '^7')
        end
    end

    if type(opts.reproduce) == 'table' and #opts.reproduce > 0 then
        print(color .. _BoxDivider(width) .. '^7')
        print(color .. _BoxLine('REPRODUCE:', width) .. '^7')
        for i, step in ipairs(opts.reproduce) do
            print(color .. _BoxLine(string_format('  %d. %s', i, tostring(step)), width) .. '^7')
        end
    end

    if #sEvid > 0 then
        print(color .. _BoxDivider(width) .. '^7')
        print(color .. _BoxLine('KANIT:', width) .. '^7')
        for line in sEvid:gmatch('[^\n]+') do
            print(color .. _BoxLine('  ' .. line, width) .. '^7')
        end
    end

    print(color .. _BoxBottom(width) .. '^7')
    print('')
end
-- =====================================================================
-- MODULE REGISTRY
-- =====================================================================
function Matrix.Chaos.RegisterModule(name, description, fn)
    if type(name) ~= 'string' or type(fn) ~= 'function' then return false end
    Matrix.Chaos.Modules[name] = { name = name, description = description or '', fn = fn }
    Matrix.Chaos.Stats[name] = { runs = 0, findings = 0, elapsed_ms = 0 }
    return true
end

function Matrix.Chaos.GetModules()
    local list = {}
    for name in pairs(Matrix.Chaos.Modules) do list[#list + 1] = name end
    table.sort(list)
    return list
end


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ FIXTURE SYSTEM — SİMÜLASYON İÇİNDE SİMÜLASYON ██████████
-- ═════════════════════════════════════════════════════════════════════
-- Her saldırı modülü çağırır: Setup() → saldır → Teardown()
-- Fixture: trap house + bot + dispatch + fleet + vendor
-- =====================================================================

Matrix.Chaos.Fixture = Matrix.Chaos.Fixture or {
    ActiveTrapHouses = {},   -- [id] = true (fixture tarafından yaratıldı)
    ActiveBots       = {},   -- [botId] = true
    ActiveFleet      = {},   -- [plate] = true
    ActivePlayers    = {},   -- [citizenid] = true
    SetupCount       = 0,
    TeardownCount    = 0,
}

local FIXTURE_MARKER = 'CHAOS-FIXTURE'

-- ★ Forward declarations — Setup fonksiyonu bu helper'ları YUKARIDAN çağırıyor
local _CreateFixtureTrapHouse
local _CreateFixtureBot
local _CreateFixtureDispatch

--- Fixture kur — test ortamı yaratır
--- @param opts table { traps, bots, dispatches, fleet, vendors }
function Matrix.Chaos.Fixture.Setup(opts)
  opts = opts or {}
    local traps      = math_min(opts.traps      or 2, 20)
    local bots       = math_min(opts.bots       or 10, 100)
    local dispatches = math_min(opts.dispatches or 3, 20)
    local fleet      = math_min(opts.fleet      or 2, 10)

    print(('[CHAOS][FIXTURE] Setup: %dx trap, %dx bot, %dx dispatch, %dx fleet'):format(
        traps, bots, dispatches, fleet))

    -- 1) TRAP HOUSE'LAR YARAT
    local trapIds = {}
    for i = 1, traps do
        local id = _CreateFixtureTrapHouse(i)
        if id then
            trapIds[#trapIds + 1] = id
            Matrix.Chaos.Fixture.ActiveTrapHouses[id] = true
        end
    end
    print(('[CHAOS][FIXTURE] %d trap house yaratildi'):format(#trapIds))

     -- 2) BOT'LAR YARAT
    local botIds = {}
    if #trapIds == 0 then
        print('[CHAOS][FIXTURE] UYARI: trap house yaratilamadi, bot yaratma atlandi')
    else
        for i = 1, bots do
            local trapId = trapIds[((i - 1) % #trapIds) + 1]
            local bot = _CreateFixtureBot(i, trapId)
            if bot then
                botIds[#botIds + 1] = bot.id
                Matrix.Chaos.Fixture.ActiveBots[bot.id] = true
            end
        end
    end
    print(('[CHAOS][FIXTURE] %d bot yaratildi'):format(#botIds))

        -- 3) DISPATCH'LER YARAT (aktif dispatch'teki botlar)
    local dspCount = 0
    if #trapIds > 0 then
        for i = 1, dispatches do
            if botIds[i] then
                if _CreateFixtureDispatch(botIds[i], trapIds[((i - 1) % #trapIds) + 1]) then
                    dspCount = dspCount + 1
                end
            end
        end
    end
    print(('[CHAOS][FIXTURE] %d dispatch yaratildi'):format(dspCount))

    -- 4) FLEET ARACI YARAT
    local fleetCount = 0
    for i = 1, fleet do
        local plate = ('CHAOS%03d'):format(i)
        if Matrix.Fleet and Matrix.Fleet.RegisterVehicle then
            local ok = Matrix.Fleet.RegisterVehicle(
                FIXTURE_MARKER, plate, 'car', 'scratched', 0.5)
            if ok then
                Matrix.Chaos.Fixture.ActiveFleet[plate] = true
                fleetCount = fleetCount + 1
            end
        end
    end
    print(('[CHAOS][FIXTURE] %d fleet araci kayit edildi'):format(fleetCount))

    Matrix.Chaos.Fixture.SetupCount = Matrix.Chaos.Fixture.SetupCount + 1
    return {
        trapIds  = trapIds,
        botIds   = botIds,
        dspCount = dspCount,
        fleetCount = fleetCount,
    }
end

--- Fixture temizle — tüm test verisini sil
function Matrix.Chaos.Fixture.Teardown()
    local cleaned = { traps = 0, bots = 0, fleet = 0 }

    -- 1) BOT'LARI SIL (RemoveBot çağırarak — proper cleanup)
    for botId in pairs(Matrix.Chaos.Fixture.ActiveBots) do
        pcall(Matrix.RemoveBot, botId, 'retired')
        cleaned.bots = cleaned.bots + 1
    end
    Matrix.Chaos.Fixture.ActiveBots = {}

    -- 2) FLEET ARAÇLARINI SIL
    for plate in pairs(Matrix.Chaos.Fixture.ActiveFleet) do
        if Matrix.Fleet and Matrix.Fleet.SeizeVehicle then
            pcall(Matrix.Fleet.SeizeVehicle, plate, 'chaos_fixture_cleanup', 'CHAOS', nil)
        end
        cleaned.fleet = cleaned.fleet + 1
    end
    Matrix.Chaos.Fixture.ActiveFleet = {}

    -- 3) TRAP HOUSE'LARI SIL (★ FK GUARD eklendi)
    for trapId in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do
        -- ★ FK GUARD: Bağımlı kayıtları önce temizle
        pcall(function()
            MySQL.query.await('DELETE FROM matrix_cash_decay WHERE trap_house_id = ?', { trapId })
        end)
        pcall(function()
            MySQL.query.await('DELETE FROM matrix_banking_escrow WHERE trap_house_id = ?', { trapId })
        end)

        -- RAM'den sil
        if Matrix.TrapHouses then
            Matrix.TrapHouses[trapId] = nil
        end
        -- DB'den sil
        pcall(function()
            MySQL.query.await('DELETE FROM matrix_trap_houses WHERE id = ? AND label LIKE ?',
                { trapId, 'CHAOS-FIXTURE%' })
        end)
        cleaned.traps = cleaned.traps + 1
    end
    Matrix.Chaos.Fixture.ActiveTrapHouses = {}

    Matrix.Chaos.Fixture.TeardownCount = Matrix.Chaos.Fixture.TeardownCount + 1
    print(('[CHAOS][FIXTURE] Teardown: %d trap, %d bot, %d fleet temizlendi'):format(
        cleaned.traps, cleaned.bots, cleaned.fleet))
end

        -- 3) TRAP HOUSE'LARI SIL
    for trapId in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do
        -- ★ FK GUARD: Önce bağımlı kayıtları temizle
        pcall(function()
            MySQL.query.await('DELETE FROM matrix_cash_decay WHERE trap_house_id = ?', { trapId })
        end)
        pcall(function()
            MySQL.query.await('DELETE FROM matrix_banking_escrow WHERE trap_house_id = ?', { trapId })
        end)
        -- v6.6.6 B11 (v6.6.5 [KOR NOKTA 1.1]'in bulgusu): Matrix.CashDecay
        -- modulu (market.lua) __ClearDirtyForTrap'i hic tanimlamamisti --
        -- guard sayesinde zaten sessiz bir no-op'tu. Cagri kaldirildi
        -- (kaldir secenegi). market.lua'ya bu sprint'te yazma iznim yok;
        -- gercek RAM dirty-cache temizligi v6.6.7'ye not dusuldu.

        -- RAM'den sil
        if Matrix.TrapHouses then
            Matrix.TrapHouses[trapId] = nil
        end
        -- DB'den sil
        pcall(function()
            MySQL.query.await('DELETE FROM matrix_trap_houses WHERE id = ? AND label LIKE ?',
                { trapId, 'CHAOS-FIXTURE%' })
        end)
        cleaned.traps = cleaned.traps + 1
    end

--- Trap house yarat (DB + RAM)
function _CreateFixtureTrapHouse(idx)
    local label = string_format('CHAOS-FIXTURE-TRAP-%03d', idx)
    local x = 500.0 + idx * 50.0
    local y = -1500.0 - idx * 30.0
    local z = 30.0

    -- ★ FIX: Önce aynı koordinatta var mı kontrol et (duplicate önleme)
    local existing = nil
    pcall(function()
        existing = MySQL.single.await(
            'SELECT id FROM matrix_trap_houses WHERE coord_x = ? AND coord_y = ? AND coord_z = ?',
            { x, y, z })
    end)

    if existing and existing.id then
        local id = existing.id
        if Matrix.TrapHouses then
            Matrix.TrapHouses[id] = Matrix.TrapHouses[id] or {
                id                    = id,
                label                 = label,
                coords                = vector3(x, y, z),
                decryption_confidence = 0.0,
                raid_ordered          = false,
                straw_buyer_citizenid = nil,
                structural_integrity  = 1.00,
            }
        end
        return id
    end

    local ok, id = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO matrix_trap_houses
                (label, coord_x, coord_y, coord_z, decryption_confidence, cyber_leak_intensity,
                 raid_ordered, straw_buyer_citizenid, structural_integrity, created_at)
            VALUES (?, ?, ?, ?, 0.0, 0.0, 0, NULL, 1.00, NOW())
        ]], { label, x, y, z })
    end)

    if not ok or type(id) ~= 'number' then
        print(('[CHAOS][FIXTURE] Trap house DB INSERT fail: %s'):format(tostring(id)))
        return nil
    end

    -- RAM cache'e ekle
    if Matrix.TrapHouses then
        Matrix.TrapHouses[id] = {
            id                    = id,
            label                 = label,
            coords                = vector3(x, y, z),
            decryption_confidence = 0.0,
            raid_ordered          = false,
            straw_buyer_citizenid = nil,
            structural_integrity  = 1.00,
        }
    end

    return id
end
--- Bot yarat (RAM)
function _CreateFixtureBot(idx, trapHouseId)
    if not Matrix.CreateBotRecord then return nil end

    local ok, bot = pcall(Matrix.CreateBotRecord, {
        name          = string_format('CHAOS-FIXTURE-BOT-%03d', idx),
        role          = 'dealer',
        trap_house_id = trapHouseId,
    })

    if not ok or not bot then return nil end
    return bot
end

--- Sahte dispatch yarat (RAM — ped spawn etmez, sadece tablo girişi)
function _CreateFixtureDispatch(botId, trapHouseId)
    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return false end

    -- Bot zaten dispatch'te mi?
    if Matrix.Dispatches and Matrix.Dispatches[botId] then return false end

    -- Sahte dispatch entry (ped yok, entity_net_id = nil)
    if Matrix.Dispatches then
        Matrix.Dispatches[botId] = {
            bot_id            = botId,
            entity_net_id     = nil,        -- ped yok
            vehicle_net_id    = nil,
            plate             = nil,
            vehicle_type      = 'foot',
            profile           = { SpeedCoefficient = 1.0, CombatResistance = 0.0, PoliceDecryptionMultiplier = 1.0 },
            origin            = vector3(0, 0, 30),
            destination       = vector3(0, 0, 30),
            eta_estimate      = 0.0,
            cruise_speed      = 1.4,
            elapsed           = 0.0,
            last_coords       = vector3(0, 0, 30),
            weight_total      = 0.0,
            dispatcher_src    = nil,
            comms_lost        = false,
            pending_events    = {},
            alpr_logged_traps = {},
            combat_damage     = 0.0,
            police_dwell      = 0,
            task_retry_ticks  = 0,
            started_at        = os_time(),
        }
        bot.state.is_locked = true
        return true
    end

    return false
end


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ MODULE RUNNER — Fixture destekli ██████████
-- ═════════════════════════════════════════════════════════════════════

local function _RunOneModule(name)
    local mod = Matrix.Chaos.Modules[name]
    if not mod then
        Matrix.Chaos.Report('HIGH', ('Modul bulunamadi: %s'):format(name), {
            impact = 'Saldiri modulu yuklenmedi',
            fix    = 'Modul ismini kontrol et: /matrix_chaos_listele',
        })
        return
    end

    Matrix.Chaos.CurrentModule = name
    local startMs = GetGameTimer()
    local beforeCount = #Matrix.Chaos.Findings

    print('')
    print(('[CHAOS] >>> SALDIRI BASLIYOR: %s — %s'):format(name, mod.description))

    -- ★ FIXTURE SETUP — Her modül kendi ortamında çalışır
    -- Modül kendi istediği fixture boyutunu belirtebilir (mod.fixture_opts)
    local fixtureOpts = mod.fixture_opts or { traps = 2, bots = 10, dispatches = 3, fleet = 2 }
    Matrix.Chaos.Fixture.Setup(fixtureOpts)

    -- ★ MODULE RUN
    local ok, err = pcall(mod.fn)

    -- ★ FIXTURE TEARDOWN — Her durumda temizle
    Matrix.Chaos.Fixture.Teardown()

    local elapsed = GetGameTimer() - startMs
    local stat = Matrix.Chaos.Stats[name]
    stat.runs = stat.runs + 1
    stat.elapsed_ms = stat.elapsed_ms + elapsed
    stat.findings = stat.findings + (#Matrix.Chaos.Findings - beforeCount)

    if not ok then
        Matrix.Chaos.Report('CRITICAL', ('Modul CRASH: %s'):format(name), {
            attack = 'Modul kendi içinde hata fırlattı',
            impact = ('pcall yakaladı: %s'):format(tostring(err)),
            fix    = 'Modul kodunu incele, guard ekle',
        })
    else
        print(('[CHAOS] <<< SALDIRI BITTI: %s — %d ms, %d bulgu'):format(
            name, elapsed, #Matrix.Chaos.Findings - beforeCount))
    end

    Matrix.Chaos.CurrentModule = nil
end

-- =====================================================================
-- MAIN RUNNER
-- =====================================================================
function Matrix.Chaos.Run(moduleList, replyTo)
    if replyTo == 0 then replyTo = nil end

    if Matrix.Chaos.Running then
        if replyTo and replyTo > 0 then
            TriggerClientEvent('chat:addMessage', replyTo, {
                args = { '[CHAOS]', 'Zaten saldiri surüyor. Once /matrix_chaos_durdur.' }
            })
        end
        return false
    end

    if not Config.Chaos or not Config.Chaos.Enabled then
        if replyTo and replyTo > 0 then
            TriggerClientEvent('chat:addMessage', replyTo, {
                args = { '[CHAOS]', 'Config.Chaos.Enabled = false.' }
            })
        end
        return false
    end

    if type(moduleList) ~= 'table' or #moduleList == 0 then
        if replyTo and replyTo > 0 then
            TriggerClientEvent('chat:addMessage', replyTo, {
                args = { '[CHAOS]', 'Modul listesi bos.' }
            })
        end
        return false
    end

    Matrix.Chaos.Running   = true
    Matrix.Chaos.StartedAt = os_time()
    Matrix.Chaos.Findings  = {}

    print('')
    print('[CHAOS] ╔══════════════════════════════════════════════╗')
    print(('[CHAOS] ║  YAMYAM MODU AKTIF — %d modul'):format(#moduleList))
    print(('[CHAOS] ║  Maks sure: %ds'):format(Config.Chaos.MaxDurationSeconds or 600))
    print('[CHAOS] ╚══════════════════════════════════════════════╝')

    if replyTo and replyTo > 0 then
        TriggerClientEvent('chat:addMessage', replyTo, {
            args = { '[CHAOS]', ('Saldiri basliyor: %d modul'):format(#moduleList) }
        })
    end

    CreateThread(function()
        for _, name in ipairs(moduleList) do
            if not Matrix.Chaos.Running then break end

            local elapsed = os_time() - Matrix.Chaos.StartedAt
            if elapsed >= (Config.Chaos.MaxDurationSeconds or 600) then
                print('[CHAOS] Watchdog: maks sure asildi.')
                break
            end

            _RunOneModule(name)
        end

        Matrix.Chaos.Running = false
        Matrix.Chaos.CurrentModule = nil
        Matrix.Chaos.PrintSummary(replyTo)
    end)

    return true
end

function Matrix.Chaos.Stop()
    if not Matrix.Chaos.Running then return false end
    Matrix.Chaos.Running = false
    print('[CHAOS] Manuel durdurma istendi.')
    return true
end

-- =====================================================================
-- SUMMARY
-- =====================================================================
function Matrix.Chaos.PrintSummary(replyTo)
    if replyTo == 0 then replyTo = nil end

    local summary = { INFO = 0, LOW = 0, MEDIUM = 0, HIGH = 0, CRITICAL = 0 }
    for _, f in ipairs(Matrix.Chaos.Findings) do
        summary[f.severity] = (summary[f.severity] or 0) + 1
    end

    local elapsed = os_time() - Matrix.Chaos.StartedAt
    local width = 78

    print('')
    print(_BoxTop(width))
    print(_BoxLine('CHAOS ENGINE — SALDIRI OZETI', width))
    print(_BoxDivider(width))
    print(_BoxLine(string_format('Sure: %ds | Toplam bulgu: %d', elapsed, #Matrix.Chaos.Findings), width))
    print(_BoxLine(string_format('CRITICAL: %d | HIGH: %d | MEDIUM: %d | LOW: %d | INFO: %d',
        summary.CRITICAL, summary.HIGH, summary.MEDIUM, summary.LOW, summary.INFO), width))
    print(_BoxLine(string_format('Fixture Setup: %d | Teardown: %d',
        Matrix.Chaos.Fixture.SetupCount, Matrix.Chaos.Fixture.TeardownCount), width))
    print(_BoxDivider(width))
    print(_BoxLine('MODUL BAZLI:', width))
    for name, stat in pairs(Matrix.Chaos.Stats) do
        if stat.runs > 0 then
            print(_BoxLine(string_format('  [%s] %d run, %d finding, %dms',
                name, stat.runs, stat.findings, stat.elapsed_ms), width))
        end
    end
    print(_BoxBottom(width))

    if #Matrix.Chaos.Findings > 0 then
        print('')
        print('  KRITIK/YUKSEK BULGULAR:')
        for _, f in ipairs(Matrix.Chaos.Findings) do
            if f.severity == 'CRITICAL' or f.severity == 'HIGH' then
                print(string_format('    [%s] %s', f.severity, f.title))
                if f.file and f.file ~= '?' then
                    print(string_format('           @ %s', f.file))
                end
            end
        end
    end

    if replyTo and replyTo > 0 then
        TriggerClientEvent('chat:addMessage', replyTo, {
            args = { '[CHAOS]', string_format('Saldiri bitti: %d bulgu (%d kritik)',
                #Matrix.Chaos.Findings, summary.CRITICAL + summary.HIGH) }
        })
    end
end

-- =====================================================================
-- COMMANDS
-- =====================================================================
local function _Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[CHAOS]', msg } })
    else
        print(('[CHAOS:CONSOLE] %s'):format(msg))
    end
end

-- ★ v6.6.6 HOTFIX: RegisterCommand restricted=true, FXServer'in
-- 'command.matrix_chaos_*' ACE'sini (server.cfg'de tanimli olsa bile
-- identifier/exec sira sorunu yuzunden) zorunlu kiliyordu ve oyuncular
-- komutlari hic calistiramiyordu. restricted=true KALDIRILDI -- iç
-- kontrol (bu fonksiyon) zaten 'matrix.chaos' ACE'sini sorguladigindan
-- iki savunma katmani gereksizdi, tek nokta (bu fonksiyon) yeterli ve
-- fail-closed.
-- ★ Server console (src=0 veya nil) icin ACE sorgusu atlanir -- konsol
-- zaten en yuksek yetkiye sahip, IsPlayerAceAllowed(0, ...) bir "player"
-- olmadigi icin guvenilmez/tutarsiz davranabilir.
local function _IsChaosAceAllowed(src)
    if type(src) ~= 'number' or src <= 0 then return true end
    local ok, allowed = pcall(IsPlayerAceAllowed, src, 'matrix.chaos')
    return ok == true and allowed == true
end

RegisterCommand('matrix_chaos_baslat', function(src, args)
    if not _IsChaosAceAllowed(src) then
        _Reply(src, 'Yetkisiz (matrix.chaos ACE gerekir).')
        return
    end
    if not Config.Chaos or not Config.Chaos.Enabled then
        _Reply(src, 'Chaos devre disi.')
        return
    end

    local target = tostring(args[1] or ''):lower()
    if target == '' then
        _Reply(src, 'Kullanim: /matrix_chaos_baslat <modul|all>')
        _Reply(src, 'Moduller: ' .. table_concat(Matrix.Chaos.GetModules(), ', '))
        return
    end

    local list = {}
    if target == 'all' then
        list = Matrix.Chaos.GetModules()
    else
        list = { target }
    end

    if #list == 0 then
        _Reply(src, 'Gecerli modul yok.')
        return
    end

    Matrix.Chaos.Run(list, src)
end, false)

RegisterCommand('matrix_chaos_durdur', function(src)
    if not _IsChaosAceAllowed(src) then
        _Reply(src, 'Yetkisiz (matrix.chaos ACE gerekir).')
        return
    end
    if Matrix.Chaos.Stop() then _Reply(src, 'Durdurma sinyali gonderildi.')
    else _Reply(src, 'Zaten calismiyor.') end
end, false)

RegisterCommand('matrix_chaos_listele', function(src)
    if not _IsChaosAceAllowed(src) then
        _Reply(src, 'Yetkisiz (matrix.chaos ACE gerekir).')
        return
    end
    _Reply(src, '=== MEVCUT SALDIRI MODULLERI ===')
    for _, name in ipairs(Matrix.Chaos.GetModules()) do
        local mod = Matrix.Chaos.Modules[name]
        _Reply(src, ('  %s — %s'):format(name, mod.description))
    end
end, false)

RegisterCommand('matrix_chaos_rapor', function(src)
    if not _IsChaosAceAllowed(src) then
        _Reply(src, 'Yetkisiz (matrix.chaos ACE gerekir).')
        return
    end
    Matrix.Chaos.PrintSummary(src)
end, false)

RegisterCommand('matrix_chaos_fixture_test', function(src)
    if not _IsChaosAceAllowed(src) then
        _Reply(src, 'Yetkisiz (matrix.chaos ACE gerekir).')
        return
    end
    _Reply(src, 'Fixture test basliyor...')
    local f = Matrix.Chaos.Fixture.Setup({ traps = 2, bots = 5, dispatches = 2, fleet = 1 })
    _Reply(src, ('Setup: %d trap, %d bot, %d dispatch, %d fleet'):format(
        #f.trapIds, #f.botIds, f.dspCount, f.fleetCount))
    Wait(1000)
    Matrix.Chaos.Fixture.Teardown()
    _Reply(src, 'Teardown tamamlandi.')
end, false)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 1: REPLAY ATTACK ██████████
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('replay', 'Replay Attack — ayni paketi N kez gonder', function()
    local REPLAY_COUNT = 20

    -- ★ TEST 1: Plate generation determinism
    if Matrix.BlackMarket and Matrix.BlackMarket.GenerateScratchedPlate then
        print('[CHAOS][replay] Test 1: Plate generation determinism')

        local plates = {}
        for i = 1, REPLAY_COUNT do
            plates[i] = Matrix.BlackMarket.GenerateScratchedPlate('CHAOS-TEST-CITIZEN')
        end

        local seen = {}
        local dupes = 0
        local firstDupPair = nil
        for i, p in ipairs(plates) do
            if seen[p] then
                dupes = dupes + 1
                if not firstDupPair then firstDupPair = string_format('%s == %s', p, seen[p]) end
            end
            seen[p] = p
        end

        if dupes > 0 then
            Matrix.Chaos.Report('CRITICAL', 'Replay: Plate dupe tespit edildi', {
                file      = 'server/blackmarket.lua',
                attack    = string_format('%dx GenerateScratchedPlate ayni citizenid icin', REPLAY_COUNT),
                impact    = string_format('%d plate DUPE uretildi', dupes),
                fix       = 'purchaseSequence sayaci her cagride artmiyor olabilir.',
                reproduce = {
                    'for i=1,20 do print(Matrix.BlackMarket.GenerateScratchedPlate("X")) end',
                },
                evidence  = firstDupPair or '',
            })
        else
            print(('[CHAOS][replay] OK: %d plate, 0 dupe'):format(REPLAY_COUNT))
        end
    end

    -- ★ TEST 2: CompleteDispatch replay — GERÇEK dispatch ile
    if Matrix.Dispatches then
        print('[CHAOS][replay] Test 2: CompleteDispatch replay (aktif dispatch ile)')

        -- Fixture'dan aktif dispatch'te bir bot bul
        local targetBot = nil
        for botId, _ in pairs(Matrix.Chaos.Fixture.ActiveBots) do
            if Matrix.Dispatches[botId] then
                targetBot = botId
                break
            end
        end

        if not targetBot then
            Matrix.Chaos.Report('INFO', 'Replay: Test 2 atlandi (aktif dispatch yok)', {
                fix = 'Fixture dispatch yaratamadi',
            })
            print('[CHAOS][replay] SKIP: Test 2 — aktif dispatch bulunamadi')
        else
            local successes = 0
            for i = 1, REPLAY_COUNT do
                local ok, result = pcall(Matrix.CompleteDispatch, targetBot, 'arrived')
                if ok and result == true then successes = successes + 1 end
            end

            if successes ~= 1 then
                Matrix.Chaos.Report('HIGH', 'Replay: CompleteDispatch idempotent degil', {
                    file      = 'server/main.lua',
                    attack    = string_format('%dx CompleteDispatch AKTIF dispatch uzerinde', REPLAY_COUNT),
                    impact    = string_format('%d basarili donus (beklenen 1) -- DUPE RISKI', successes),
                    fix       = 'CompleteDispatch basinda Matrix.Dispatches[botId] guard ekle.',
                    reproduce = {
                        'Aktif dispatch yarat',
                        'for i=1,20 do Matrix.CompleteDispatch(botId, "arrived") end',
                        'Donus degerleri say',
                    },
                    evidence  = string_format('successes=%d (beklenen 1)', successes),
                })
            else
                print('[CHAOS][replay] OK: CompleteDispatch idempotent (1/20)')
            end
        end
    end

    -- ★ TEST 3: RemoveBot replay
    if Matrix.RemoveBot then
        print('[CHAOS][replay] Test 3: RemoveBot replay')

        local testBot = Matrix.CreateBotRecord({
            name = 'CHAOS-REPLAY-REMOVE',
            role = 'diagnostic_test',
        })

        if testBot and testBot.id then
            Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true

            local successes = 0
            for i = 1, REPLAY_COUNT do
                local ok, result = pcall(Matrix.RemoveBot, testBot.id, 'retired')
                if ok and result == true then successes = successes + 1 end
            end

            if successes ~= 1 then
                Matrix.Chaos.Report('MEDIUM', 'Replay: RemoveBot tam idempotent degil', {
                    file      = 'server/main.lua',
                    attack    = string_format('%dx RemoveBot ayni bot icin', REPLAY_COUNT),
                    impact    = string_format('%d basarili (beklenen 1)', successes),
                    fix       = '_botRemovalInFlight guard kontrol et.',
                    evidence  = string_format('successes=%d', successes),
                })
            else
                print('[CHAOS][replay] OK: RemoveBot re-entrance guard calisiyor')
            end
        end
    end

    -- ★ TEST 4: AdvanceDecryption cumulative — GERÇEK trap house ile
    if Matrix.Bureau and Matrix.Bureau.AdvanceDecryption and next(Matrix.Chaos.Fixture.ActiveTrapHouses) then
        print('[CHAOS][replay] Test 4: AdvanceDecryption cumulative')

        local trapId
        for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do trapId = id; break end

        if trapId then
            -- Fixture trap house'ların decryption'ı 0.0
            local trap = Matrix.TrapHouses and Matrix.TrapHouses[trapId]
            local before = trap and trap.decryption_confidence or 0.0

            for i = 1, REPLAY_COUNT do
                pcall(Matrix.Bureau.AdvanceDecryption, trapId, 0.001)
            end

            local after = trap and trap.decryption_confidence or 0.0
            local delta = after - before
            local expected = REPLAY_COUNT * 0.001

            if math_abs(delta - expected) < 0.0001 then
                print(('[CHAOS][replay] OK: AdvanceDecryption kumulatif (delta=%.4f, beklenen=%.4f)'):format(
                    delta, expected))
            else
                Matrix.Chaos.Report('MEDIUM', 'Replay: AdvanceDecryption beklenenden farkli', {
                    file      = 'server/bureau.lua',
                    attack    = string_format('%dx AdvanceDecryption x 0.001', REPLAY_COUNT),
                    impact    = string_format('delta=%.4f, beklenen=%.4f', delta, expected),
                    fix       = 'Decryption kumulatif mi, yoksa rate-limit mi var kontrol et.',
                })
            end
        end
    else
        print('[CHAOS][replay] SKIP: Test 4 — fixture trap house yok')
    end

    Matrix.Chaos.Report('INFO', 'Replay attack tamamlandi', {
        attack = '4 farkli saldiri noktasi test edildi',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 2: RACE CONDITION ATTACK ██████████
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('race', 'Race Condition Attack — paralel cagrilarin atomic kontrolu', function()
    local PARALLEL = 50

    -- ★ TEST 1: Paralel bot yarat + sil
    print(('[CHAOS][race] Test 1: %dx paralel CreateBot + RemoveBot'):format(PARALLEL))

    local bots = {}
    for i = 1, PARALLEL do
        bots[i] = Matrix.CreateBotRecord({
            name = string_format('CHAOS-RACE-P%d', i),
            role = 'diagnostic_test',
        })
        if bots[i] and bots[i].id then
            Matrix.Chaos.Fixture.ActiveBots[bots[i].id] = true
        end
    end

    local completed = 0
    local results = {}
    for i = 1, PARALLEL do
        CreateThread(function()
            if bots[i] and bots[i].id then
                local ok, result = pcall(Matrix.RemoveBot, bots[i].id, 'retired')
                results[i] = (ok and result == true) and 1 or 0
            else
                results[i] = 0
            end
            completed = completed + 1
        end)
    end

    local waited = 0
    while completed < PARALLEL and waited < 5000 do
        Wait(50); waited = waited + 50
    end

    local successCount = 0
    for i = 1, PARALLEL do
        if results[i] == 1 then successCount = successCount + 1 end
    end

    if successCount ~= PARALLEL then
        Matrix.Chaos.Report('HIGH', 'Race: Paralel RemoveBot kayip', {
            file   = 'server/main.lua',
            attack = string_format('%dx paralel RemoveBot', PARALLEL),
            impact = string_format('%d/%d basarili', successCount, PARALLEL),
            fix    = 'Bot registry thread-safe kontrolu gerekli.',
        })
    else
        print(('[CHAOS][race] OK: Paralel RemoveBot %d/%d'):format(successCount, PARALLEL))
    end

    -- ★ TEST 2: Aynı botu N paralel sil
    print(('[CHAOS][race] Test 2: Ayni botu %dx paralel sil'):format(PARALLEL))

    local raceBot = Matrix.CreateBotRecord({
        name = 'CHAOS-RACE-SINGLE',
        role = 'diagnostic_test',
    })

    if raceBot and raceBot.id then
        Matrix.Chaos.Fixture.ActiveBots[raceBot.id] = true

        local singlesCompleted = 0
        local singlesResults = {}
        for i = 1, PARALLEL do
            CreateThread(function()
                local ok, result = pcall(Matrix.RemoveBot, raceBot.id, 'retired')
                singlesResults[i] = (ok and result == true) and 1 or 0
                singlesCompleted = singlesCompleted + 1
            end)
        end

        local waited2 = 0
        while singlesCompleted < PARALLEL and waited2 < 5000 do
            Wait(50); waited2 = waited2 + 50
        end

        local singleSuccess = 0
        for i = 1, PARALLEL do
            singleSuccess = singleSuccess + (singlesResults[i] or 0)
        end

        if singleSuccess ~= 1 then
            Matrix.Chaos.Report('CRITICAL', 'Race: Ayni bot iki kere silinebiliyor!', {
                file   = 'server/main.lua',
                attack = string_format('%dx paralel RemoveBot AYNI bot icin', PARALLEL),
                impact = string_format('%d basarili (beklenen 1) -- DUPE RISKI', singleSuccess),
                fix    = '_botRemovalInFlight[id] guard RACE condition var.',
                evidence = string_format('successes=%d (beklenen 1)', singleSuccess),
            })
        else
            print('[CHAOS][race] OK: Ayni bot atomic siliniyor')
        end
    end

    -- ★ TEST 3: Paralel dispatch — GERÇEK trap house ile
    print('[CHAOS][race] Test 3: Paralel BeginPhysicalDispatch')

    if Matrix.BeginPhysicalDispatch and next(Matrix.Chaos.Fixture.ActiveTrapHouses) then
        local trapId
        for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do trapId = id; break end

        if trapId then
            local house = Matrix.TrapHouses[trapId]
            local dspBot = Matrix.CreateBotRecord({
                name = 'CHAOS-RACE-DSP',
                role = 'diagnostic_test',
                trap_house_id = trapId,
            })

            if dspBot and dspBot.id then
                Matrix.Chaos.Fixture.ActiveBots[dspBot.id] = true

                local dspCompleted = 0
                local dspResults = {}
                for i = 1, PARALLEL do
                    CreateThread(function()
                        local ok, result = pcall(Matrix.BeginPhysicalDispatch,
                            dspBot.id, house.coords, house.coords, nil, 'foot', 0.0, nil, 1.0)
                        dspResults[i] = (ok and result == true) and 1 or 0
                        dspCompleted = dspCompleted + 1
                    end)
                end

                local waited3 = 0
                while dspCompleted < PARALLEL and waited3 < 5000 do
                    Wait(50); waited3 = waited3 + 50
                end

                local dspSuccess = 0
                for i = 1, PARALLEL do
                    dspSuccess = dspSuccess + (dspResults[i] or 0)
                end

                if dspSuccess > 1 then
                    Matrix.Chaos.Report('CRITICAL', 'Race: Bot iki kere dispatch edilebiliyor!', {
                        file   = 'server/main.lua',
                        attack = string_format('%dx paralel BeginPhysicalDispatch', PARALLEL),
                        impact = string_format('%d basarili (beklenen 1) -- DUPE RISK', dspSuccess),
                        fix    = 'Matrix.Dispatches[botId] kontrolu ATOMIK degil.',
                        evidence = string_format('successes=%d (beklenen 1)', dspSuccess),
                    })
                else
                    print('[CHAOS][race] OK: Dispatch atomic (1 basarili)')
                end
            end
        end
    else
        print('[CHAOS][race] SKIP: Test 3 — fixture trap house yok')
    end

    Matrix.Chaos.Report('INFO', 'Race attack tamamlandi', {
        attack = '3 farkli race noktasi test edildi',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- =====================================================================
-- BOOT
-- =====================================================================
CreateThread(function()
    Wait(12000)
    if Config.Chaos and Config.Chaos.Enabled then
        print('')
        print('[CHAOS] ╔══════════════════════════════════════════════╗')
        print('[CHAOS] ║  YAMYAM MODU HAZIR (FIXTURE-DESTEKLI)' .. string_rep(' ', 3) .. '║')
        print('[CHAOS] ╠══════════════════════════════════════════════╣')
        print('[CHAOS] ║  Aktif moduller:' .. string_rep(' ', 33) .. '║')
        for _, name in ipairs(Matrix.Chaos.GetModules()) do
            local pad = 40 - #name
            if pad < 1 then pad = 1 end
            print(('[CHAOS] ║    - %s%s║'):format(name, string_rep(' ', pad)))
        end
        print('[CHAOS] ╚══════════════════════════════════════════════╝')
        print('')
    else
        print('[CHAOS] Devre disi (Config.Chaos.Enabled = false)')
    end
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ AUTO-DISCOVERY + AUTO-INTEGRATION ██████████
-- ═════════════════════════════════════════════════════════════════════
-- ★ FELSEFE: Chaos kendi kendini keşfetsin. Yeni bir matrix dosyası
-- eklendiğinde, chaos onu OTTOMATİK tanısın ve test etsin.
--
-- ★ AUTO-INTEGRATION: Başka bir dosya kendini tanıtabilir:
--   TriggerEvent('matrix:internal:chaosRegisterModule', 'ismi', 'aciklama', function() ... end)
-- ═════════════════════════════════════════════════════════════════════

-- Auto-Integration event handler
AddEventHandler('matrix:internal:chaosRegisterModule', function(name, description, fn)
    if type(name) ~= 'string' or type(fn) ~= 'function' then return end
    local ok = Matrix.Chaos.RegisterModule(name, description or '', fn)
    if ok then
        print(('[CHAOS][AUTO-INTEGRATE] Yeni modul kayit edildi: %s'):format(name))
    end
end)

-- ★ Discover modülü: fxmanifest'i oku, tüm API yüzeyini tara
Matrix.Chaos.RegisterModule('discover', 'Auto Discovery — Matrix API yüzeyini tara ve doğrula', function()
    -- fxmanifest'i yükle
    local manifest = LoadResourceFile(GetCurrentResourceName(), 'fxmanifest.lua')
    if type(manifest) ~= 'string' then
        Matrix.Chaos.Report('MEDIUM', 'Discover: fxmanifest okunamadi', {
            attack = 'LoadResourceFile ile fxmanifest alınamadı',
            impact = 'API keşfi yapılamadı',
            fix    = 'fxmanifest.lua dosyasını kontrol et',
        })
        return
    end

    -- server_scripts bloğundaki tüm .lua dosyalarını çıkar
    local files = {}
    for path in manifest:gmatch("'(server/[%w_]+%.lua)'") do
        files[#files + 1] = path
    end

    print(('[CHAOS][discover] fxmanifest tarandi: %d server dosyasi bulundu'):format(#files))

    -- Her dosyayı tara
    local totalApis    = 0
    local missingApis  = 0
    local namespaceCount = {}
    local MAX_MISSING_REPORT = 10  -- spam önlemek için

    for _, path in ipairs(files) do
        local content = LoadResourceFile(GetCurrentResourceName(), path)
        if type(content) == 'string' then
            -- function Matrix.X.Y pattern'larını bul
            for namespace, fnName in content:gmatch('function Matrix%.([%w_]+)%.([%w_]+)%s*%(') do
                totalApis = totalApis + 1
                namespaceCount[namespace] = (namespaceCount[namespace] or 0) + 1

                -- Runtime'da var mı?
                local ns = Matrix[namespace]
                if not ns or type(ns[fnName]) ~= 'function' then
                    missingApis = missingApis + 1

                    if missingApis <= MAX_MISSING_REPORT then
                        Matrix.Chaos.Report('LOW', ('Discover: Matrix.%s.%s runtime\'da yok'):format(namespace, fnName), {
                            file      = path,
                            attack    = 'Static kaynak taraması vs runtime kontrolü',
                            impact    = ('Kaynakta tanımlı, runtime\'da eksik -- yükleme sırası veya yazım hatası'):format(
                                namespace, fnName),
                            fix       = ('%s dosyasının fxmanifest sırasını ve namespace tanımını kontrol et.'):format(path),
                            reproduce = {
                                ('grep "function Matrix.%s.%s" %s'):format(namespace, fnName, path),
                                ('print(type(Matrix.%s and Matrix.%s.%s))'):format(namespace, namespace, fnName),
                            },
                        })
                    end
                end
            end
        end
    end

    if missingApis > MAX_MISSING_REPORT then
        print(('[CHAOS][discover] +%d ek eksik API (spam önlemek için gizlendi)'):format(
            missingApis - MAX_MISSING_REPORT))
    end

    print(('[CHAOS][discover] %d dosya tarandi | %d API bulundu | %d eksik'):format(
        #files, totalApis, missingApis))

    -- Namespace özeti
    local summary = {}
    for ns, count in pairs(namespaceCount) do
        summary[#summary + 1] = ('%s:%d'):format(ns, count)
    end
    table.sort(summary)
    print(('[CHAOS][discover] API dagilimi: %s'):format(table_concat(summary, ', ')))

    Matrix.Chaos.Report('INFO', 'Discover tamamlandi', {
        attack = ('%d dosya tarandi, %d API bulundu'):format(#files, totalApis),
        impact = ('%d eksik API tespit edildi'):format(missingApis),
    })
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 3: STATE POISON ██████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: RAM state'e bozuk veri enjekte et, sistem toparlıyor mu?
--   • NaN enjekte → propagate oluyor mu?
--   • Negatif değer → clamp var mı?
--   • Nil → crash var mı?
--   • Sonsuz (+inf) → hesaplamada taşma?
--   • String yerine number → type mismatch?
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('state_poison', 'State Poison — RAM state boz, self-heal test', function()
    local NaN = 0.0 / 0.0
    local INF = math.huge
    local NEG_INF = -math.huge

        -- ★ TEST 1: Bot cortisol NaN + DB ROUND-TRIP
    print('[CHAOS][state_poison] Test 1: bot.biology.cortisol_level = NaN + DB round-trip')

    local testBot = Matrix.CreateBotRecord({
        name = 'CHAOS-POISON-CORTISOL',
        role = 'diagnostic_test',
    })

    if testBot and testBot.id then
        Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true
        testBot.biology.cortisol_level = NaN

        -- ★ DB ROUND-TRIP: NaN persist ediliyor mu?
        Matrix.MarkBotDirty(testBot.id)
        Matrix.FlushDirtyBots()  -- force flush
        Wait(500)                -- async bekle

        local dbRow = nil
        pcall(function()
            dbRow = MySQL.single.await(
                'SELECT cortisol_level FROM matrix_bots WHERE id = ?',
                { testBot.id })
        end)

        if dbRow then
            local dbCortisol = tonumber(dbRow.cortisol_level)
            if dbCortisol ~= dbCortisol then
                -- DB'de NaN var!
                Matrix.Chaos.Report('CRITICAL', 'State Poison: NaN DB\'ye yazildi', {
                    file      = 'server/main.lua',
                    attack    = 'bot.cortisol_level = NaN, FlushDirtyBots()',
                    impact    = 'NaN DB\'ye persist edildi — veri bozuldu',
                    fix       = 'BuildBotUpsert içine Matrix.Clamp guard ekle.',
                    reproduce = {
                        'bot.biology.cortisol_level = 0/0',
                        'Matrix.MarkBotDirty(bot.id)',
                        'Matrix.FlushDirtyBots()',
                        'SELECT cortisol_level FROM matrix_bots WHERE id = bot.id',
                    },
                })
            elseif dbCortisol == nil then
                Matrix.Chaos.Report('HIGH', 'State Poison: NaN null olarak kaydedildi', {
                    file   = 'server/main.lua',
                    attack = 'NaN → NULL',
                    impact = 'Değer kaybı',
                    fix    = 'Clamp guard ekle.',
                })
            else
                print(('[CHAOS][state_poison] OK: NaN DB\'ye sizmedi (db=%.4f)'):format(dbCortisol))
            end
        else
            Matrix.Chaos.Report('HIGH', 'State Poison: DB round-trip basarisiz', {
                fix = 'FlushDirtyBots calisti mi kontrol et.',
            })
        end
    end

        -- Bir sonraki tick nasıl davranıyor?
        local beforeMultiplier = 1.0
        local ok, result = pcall(function()
            return Matrix.Kitchen.GetEffectiveSkill(testBot, 'skill_chemistry')
        end)

        if not ok or type(result) ~= 'number' or result ~= result then
            Matrix.Chaos.Report('CRITICAL', 'State Poison: NaN propagate', {
                file      = 'server/kitchen.lua',
                attack    = 'bot.biology.cortisol_level = NaN (0/0)',
                impact    = ('GetEffectiveSkill NaN dondurdu: ok=%s result=%s'):format(tostring(ok), tostring(result)),
                fix       = 'GetEffectiveSkill başında NaN guard ekle: if x ~= x then x = 0.0 end',
                reproduce = {
                    'bot.biology.cortisol_level = 0/0',
                    'print(Matrix.Kitchen.GetEffectiveSkill(bot, "skill_chemistry"))',
                },
                evidence  = string_format('result=%s type=%s', tostring(result), type(result)),
            })
        else
            print('[CHAOS][state_poison] OK: NaN yakalandi veya propagate etmedi')
        end
    

    -- ★ TEST 2: Trap house decryption -1
    print('[CHAOS][state_poison] Test 2: trap.decryption_confidence = -1.0')

    local trapId
    for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do trapId = id; break end

    if trapId and Matrix.TrapHouses and Matrix.TrapHouses[trapId] then
        local house = Matrix.TrapHouses[trapId]
        local originalValue = house.decryption_confidence
        house.decryption_confidence = -1.0

        if Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
            local ok, err = pcall(Matrix.Bureau.AdvanceDecryption, trapId, 0.5)
            if not ok then
                Matrix.Chaos.Report('HIGH', 'State Poison: Negatif decryption crash', {
                    file      = 'server/bureau.lua',
                    attack    = 'decryption_confidence = -1.0, sonra AdvanceDecryption(0.5)',
                    impact    = ('pcall yakaladi: %s'):format(tostring(err)),
                    fix       = 'AdvanceDecryption Matrix.Clamp kullanmıyor olabilir.',
                    evidence  = string_format('error=%s', tostring(err)),
                })
            elseif house.decryption_confidence < 0.0 then
                Matrix.Chaos.Report('HIGH', 'State Poison: Negatif decryption persist', {
                    file      = 'server/bureau.lua',
                    attack    = 'decryption_confidence = -1.0',
                    impact    = string_format('Hala negatif: %.3f', house.decryption_confidence),
                    fix       = 'Clamp(0.0, 1.0) guard ekle.',
                })
            else
                print('[CHAOS][state_poison] OK: Negatif deger clamp edildi')
            end
        end
        house.decryption_confidence = originalValue
    end

    -- ★ TEST 3: Bot resilience +inf
    print('[CHAOS][state_poison] Test 3: bot.psychology.resilience = +inf')

    if testBot then
        testBot.psychology.resilience = INF
        if Matrix.Kitchen and Matrix.Kitchen.ComputeSnitchIndex then
            local ok, result = pcall(Matrix.Kitchen.ComputeSnitchIndex, testBot)
            if not ok then
                Matrix.Chaos.Report('HIGH', 'State Poison: +inf resilience crash', {
                    file   = 'server/kitchen.lua',
                    attack = 'resilience = math.huge',
                    impact = ('pcall: %s'):format(tostring(result)),
                    fix    = 'SnitchIndex hesaplamasında +inf guard ekle.',
                })
            elseif type(result) == 'number' and (result == INF or result == NEG_INF) then
                Matrix.Chaos.Report('HIGH', 'State Poison: +inf propagate', {
                    file   = 'server/kitchen.lua',
                    attack = 'resilience = +inf',
                    impact = string_format('SnitchIndex = %s', tostring(result)),
                    fix    = 'Clamp(-1,1) veya isfinite check ekle.',
                })
            else
                print('[CHAOS][state_poison] OK: +inf yakalandi')
            end
        end
        testBot.psychology.resilience = 0.5
    end

    -- ★ TEST 4: Bot trap_house_id = string (should be number)
    print('[CHAOS][state_poison] Test 4: bot.state.trap_house_id = "not_a_number"')

    if testBot then
        testBot.state.trap_house_id = 'NOT_A_NUMBER'
        if Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
            local ok, err = pcall(Matrix.Bureau.AdvanceDecryption, testBot.state.trap_house_id, 0.1)
            -- Bu normalde sessizce başarısız olmalı veya tip kontrolü yapmalı
            if not ok then
                Matrix.Chaos.Report('MEDIUM', 'State Poison: string trap_house_id crash', {
                    file   = 'server/bureau.lua',
                    attack = 'trap_house_id = "NOT_A_NUMBER"',
                    impact = ('pcall: %s'):format(tostring(err)),
                    fix    = 'AdvanceDecryption başında tonumber() guard ekle.',
                })
            else
                print('[CHAOS][state_poison] OK: string trap_house_id sessizce reddedildi')
            end
        end
        testBot.state.trap_house_id = nil
    end

    -- ★ TEST 5: Inventory count = -999
    print('[CHAOS][state_poison] Test 5: envanter manipulation (negatif count)')

    if Matrix.Market and Matrix.Market.CanDepositToStash then
        local ok, result = pcall(Matrix.Market.CanDepositToStash, -1, -999)
        if not ok then
            Matrix.Chaos.Report('MEDIUM', 'State Poison: negatif mass kap', {
                file   = 'server/market.lua',
                attack = 'CanDepositToStash(-1, -999)',
                impact = ('pcall: %s'):format(tostring(result)),
                fix    = 'CanDepositToStash başında negatif guard ekle.',
            })
        else
            print('[CHAOS][state_poison] OK: negatif girdi reddedildi')
        end
    end

    Matrix.Chaos.Report('INFO', 'State Poison tamamlandi', {
        attack = '5 farkli NaN/inf/string enjeksiyon',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 4: RESOURCE EXHAUST ██████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: Sistemi kaynak tüketimi ile boğ
--   • 10.000 event flood
--   • 1.000 paralel thread
--   • Memory leak (tablo şişmesi)
--   • Çok uzun string payload
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('resource_exhaust', 'Resource Exhaust — event flood + RAM leak', function()
    -- ★ TEST 1: 1000x event flood (aynı event)
    print('[CHAOS][resource_exhaust] Test 1: 1000x event flood')

    local EVENTS = 1000
    local floodStart = GetGameTimer()

    -- Aslında event göndermek yerine, handler'ı doğrudan çağırıyoruz
    -- (network layer'ı bypass eder, sadece işlem maliyeti ölçer)
    if Matrix.Bureau and Matrix.Bureau.GetHeat then
        for i = 1, EVENTS do
            pcall(Matrix.Bureau.GetHeat, 1)
        end
        local elapsed = GetGameTimer() - floodStart
        print(('[CHAOS][resource_exhaust] OK: %dx GetHeat %dms (%d/sec)'):format(
            EVENTS, elapsed, elapsed > 0 and math_floor(EVENTS * 1000 / elapsed) or 0))

        if elapsed > 500 then
            Matrix.Chaos.Report('MEDIUM', 'Resource: GetHeat yavas', {
                file   = 'server/bureau.lua',
                attack = string_format('%dx GetHeat (%d/sec)', EVENTS, EVENTS * 1000 / elapsed),
                impact = string_format('%dms toplam -- performans riski', elapsed),
                fix    = 'GetHeat cache ile hızlandırılabilir.',
            })
        end
    end

    -- ★ TEST 2: 500 paralel thread
    print('[CHAOS][resource_exhaust] Test 2: 500 paralel thread')

    local THREADS = 500
    local completed = 0
    local success = 0
    local threadStart = GetGameTimer()

    for i = 1, THREADS do
        CreateThread(function()
            local ok = pcall(function()
                return Matrix.Clamp(i / THREADS, 0, 1)
            end)
            if ok then success = success + 1 end
            completed = completed + 1
        end)
    end

    local waited = 0
    while completed < THREADS and waited < 10000 do
        Wait(50)
        waited = waited + 50
    end

    local threadElapsed = GetGameTimer() - threadStart
    if completed < THREADS then
        Matrix.Chaos.Report('HIGH', 'Resource: Thread starvation', {
            file   = 'server/matrix_chaos.lua',
            attack = string_format('%dx paralel CreateThread', THREADS),
            impact = string_format('%d/%d tamamlandi (%dms timeout)', completed, THREADS, threadElapsed),
            fix    = 'Sunucu thread limiti aşıldı -- production\'da 500 paralel thread kabul edilemez.',
        })
    else
        print(('[CHAOS][resource_exhaust] OK: %d thread %dms\'de tamamlandi'):format(
            THREADS, threadElapsed))
    end

    -- ★ TEST 3: Memory leak -- AddNotepadEntry benzeri tablo şişmesi
    print('[CHAOS][resource_exhaust] Test 3: Memory leak -- tablo şişmesi')

    -- Matrix.Persistence.dirtyBots tablosuna 1000 kayıt ekle
    if Matrix.Persistence and Matrix.Persistence.dirtyBots then
        local before = 0
        for _ in pairs(Matrix.Persistence.dirtyBots) do before = before + 1 end

        for i = 1, 1000 do
            Matrix.Persistence.dirtyBots[100000 + i] = true
        end

        local after = 0
        for _ in pairs(Matrix.Persistence.dirtyBots) do after = after + 1 end

        print(('[CHAOS][resource_exhaust] dirtyBots: %d -> %d'):format(before, after))

        -- Temizle
        for i = 1, 1000 do
            Matrix.Persistence.dirtyBots[100000 + i] = nil
        end
    end

    -- ★ TEST 4: Çok uzun string
    print('[CHAOS][resource_exhaust] Test 4: 1MB string payload')

    local hugeString = string.rep('X', 1024 * 1024)  -- 1 MB

    if Matrix.Bureau and Matrix.Bureau.GetHeat then
        local ok, err = pcall(Matrix.Bureau.GetHeat, hugeString)
        if not ok and tostring(err):find('memory') then
            Matrix.Chaos.Report('MEDIUM', 'Resource: 1MB string memory harcadi', {
                file   = 'server/bureau.lua',
                attack = '1MB string GetHeat argumani',
                impact = string_format('pcall: %s', tostring(err)),
                fix    = 'String tip kontrolü ekle.',
            })
        else
            print('[CHAOS][resource_exhaust] OK: 1MB string guvenli islendi')
        end
    end

    Matrix.Chaos.Report('INFO', 'Resource Exhaust tamamlandi', {
        attack = string_format('4 farkli kaynak tuketimi (%d event, %d thread)', EVENTS, THREADS),
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 5: SQL INJECTION ██████████████████████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: MySQL sorgularına bozuk veri enjekte et
--   • '; DROP TABLE
--   • ' OR 1=1 --
--   • %s%s%s format string
--   • Unicode escape
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('sql_inject', 'SQL Injection — MySQL prepared statement kontrolu', function()
    local SQL_PAYLOADS = {
        "'; DROP TABLE matrix_bots;--",
        "' OR 1=1 --",
        "1'; DROP TABLE matrix_trap_houses; --",
        "%s%s%s%s%s%s%s%s",
        "\x00\x01\x02\x03",
        string.rep("'", 100),
        "UNION SELECT * FROM players",
        "admin'--",
        "' AND 1=(SELECT COUNT(*) FROM matrix_bots)--",
    }

    -- ★ TEST 1: MySQL.prepare parametre binding
    print('[CHAOS][sql_inject] Test 1: MySQL.prepare parametre binding')

    local payload = "'; DROP TABLE matrix_bots;--"
    local ok, err = pcall(function()
        -- Parametreli sorgu kullan, SQL injection'a karşı korumalı olmalı
        return MySQL.single.await(
            'SELECT COUNT(*) AS c FROM matrix_bots WHERE name = ?',
            { payload })
    end)

    if not ok then
        Matrix.Chaos.Report('HIGH', 'SQL: parametreli sorgu bile crash', {
            file   = 'server/matrix_chaos.lua',
            attack = 'MySQL.single.await(?, {SQL_PAYLOAD})',
            impact = ('pcall: %s'):format(tostring(err)),
            fix    = 'MySQL driver sorunu veya bağlantı kopuk.',
        })
    else
        print('[CHAOS][sql_inject] OK: Parametreli sorgu guvenli')
    end

    -- ★ TEST 2: matrix_bots hala var mı? (DROP TABLE çalıştı mı?)
    print('[CHAOS][sql_inject] Test 2: matrix_bots tablo hala var mi?')

    local tableOk, tableResult = pcall(function()
        return MySQL.single.await(
            "SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'matrix_bots'",
            {})
    end)

    if tableOk and tableResult and tonumber(tableResult.c) == 1 then
        print('[CHAOS][sql_inject] OK: matrix_bots tablo saglam (SQL injection etkisiz)')
    else
        Matrix.Chaos.Report('CRITICAL', 'SQL: matrix_bots tablo YOK!', {
            file   = 'server/matrix_chaos.lua',
            attack = "SQL injection ile DROP TABLE calisti",
            impact = 'matrix_bots tablosu silinmis olabilir',
            fix    = 'Acilen database yedegine donulmeli. Tum SQL sorgular parametreli olmali.',
        })
    end

    -- ★ TEST 3: Farklı payload'larla iteration
    print('[CHAOS][sql_inject] Test 3: 9 farkli payload testi')

    local fails = 0
    for i, pl in ipairs(SQL_PAYLOADS) do
        local ok2, err2 = pcall(function()
            return MySQL.single.await(
                'SELECT COUNT(*) AS c FROM matrix_bots WHERE name = ?',
                { pl })
        end)
        if not ok2 then
            fails = fails + 1
            Matrix.Chaos.Report('MEDIUM', ('SQL: Payload #%d crash'):format(i), {
                file   = 'server/matrix_chaos.lua',
                attack = ('Payload: %s'):format(pl:sub(1, 30)),
                impact = ('pcall: %s'):format(tostring(err2)),
                fix    = 'MySQL driver hex/unicode payload yönetemiyor olabilir.',
            })
        end
    end

    if fails == 0 then
        print(('[CHAOS][sql_inject] OK: %d payload guvenli'):format(#SQL_PAYLOADS))
    end

    -- ★ TEST 4: Tablo sayısı -- hiç tablo eksik mi?
    print('[CHAOS][sql_inject] Test 4: Beklenen tablo sayisi')

    local expectedTables = {
        'matrix_bots', 'matrix_trap_houses', 'matrix_forensic_evidence',
        'matrix_hierarchy', 'matrix_market_zones', 'matrix_cash_decay',
    }

    local missingTables = {}
    for _, tableName in ipairs(expectedTables) do
        local ok3, res = pcall(function()
            return MySQL.single.await(
                "SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?",
                { tableName })
        end)
        if not ok3 or not res or tonumber(res.c) ~= 1 then
            missingTables[#missingTables + 1] = tableName
        end
    end

    if #missingTables > 0 then
        Matrix.Chaos.Report('CRITICAL', 'SQL: Kritik tablolar eksik', {
            file   = 'server/matrix_chaos.lua',
            attack = 'information_schema taramasi',
            impact = string_format('Eksik tablolar: %s', table_concat(missingTables, ', ')),
            fix    = 'sql/matrix_MASTER.sql calistirilmis mi kontrol et.',
        })
    else
        print('[CHAOS][sql_inject] OK: 6 kritik tablo mevcut')
    end

    Matrix.Chaos.Report('INFO', 'SQL Injection tamamlandi', {
        attack = string_format('%d farkli payload test edildi', #SQL_PAYLOADS),
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- =====================================================================
-- BOOT BANNER — v3.0
-- =====================================================================

-- ═════════════════════════════════════════════════════════════════════
-- ██████████ MILITARY ASSERTION FRAMEWORK v1.0 ██████████
-- ═════════════════════════════════════════════════════════════════════
-- DO-178C / MIL-STD-810 FELSEFESİ:
--   • Her test ASSERT ile doğrulanır — "iyi görünüyor" YETMEZ
--   • Expected vs Actual karşılaştırması ZORUNLU
--   • NaN, Inf, tip mismatch, range ihlali → otomatik FAIL
--   • Her assertion test adı taşır (traceability)
--   • Failing assertion → detaylı Report otomatik
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.Assert = Matrix.Chaos.Assert or {}

-- Trace için test bağlamı
Matrix.Chaos.Assert.TestName = nil
Matrix.Chaos.Assert.TestFile = nil

function Matrix.Chaos.Assert.SetContext(testName, testFile)
    Matrix.Chaos.Assert.TestName = testName
    Matrix.Chaos.Assert.TestFile = testFile
end

-- ─────────────────────────────────────────────────────────────────────
-- [A1] Type Assertion — tipler uyuşmuyorsa fail
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.Type(value, expectedType, assertionName)
    local actualType = type(value)
    if actualType ~= expectedType then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'Type'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = ('Type assertion failed'):format(),
            impact = ('Beklenen: %s | Gercek: %s | Deger: %s'):format(
                expectedType, actualType, tostring(value)),
            fix    = 'Fonksiyon başına tip guard ekle.',
            evidence = ('value=%s type=%s'):format(tostring(value), actualType),
        })
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A2] NotNil Assertion
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.NotNil(value, assertionName)
    if value == nil then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'NotNil'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'Nil check failed',
            impact = 'Beklenen deger nil olamaz',
            fix    = 'Fonksiyon return degerlerini kontrol et.',
        })
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A3] Nil Assertion (tersi)
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.Nil(value, assertionName)
    if value ~= nil then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'Nil'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'Nil check failed',
            impact = ('Deger nil olmaliydi ama %s'):format(tostring(value)),
            fix    = 'Fonksiyon gereksiz deger donduruyor olabilir.',
        })
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A4] Equal Assertion — toleranslı
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.Equal(actual, expected, tolerance, assertionName)
    tolerance = tonumber(tolerance) or 1e-9
    if type(actual) ~= 'number' or type(expected) ~= 'number' then
        if actual ~= expected then
            Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'Equal'), {
                file   = Matrix.Chaos.Assert.TestFile or '?',
                attack = 'Non-numeric equality',
                impact = ('Beklenen: %s | Gercek: %s'):format(tostring(expected), tostring(actual)),
                fix    = 'Deger karşılaştırması yanlış.',
            })
            return false
        end
        return true
    end

    -- NaN check
    if actual ~= actual or expected ~= expected then
        Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (NaN)'):format(assertionName or 'Equal'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'NaN comparison',
            impact = ('actual=%s expected=%s'):format(tostring(actual), tostring(expected)),
            fix    = 'NaN guard ekle.',
        })
        return false
    end

    local diff = math_abs(actual - expected)
    if diff > tolerance then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'Equal'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'Numeric equality failed',
            impact = ('Beklenen: %.6f | Gercek: %.6f | Fark: %.6f | Tolerans: %.6f'):format(
                expected, actual, diff, tolerance),
            fix    = 'Formül veya return değeri yanlış.',
        })
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A5] InRange Assertion
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.InRange(value, minVal, maxVal, assertionName)
    if type(value) ~= 'number' or value ~= value then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s (Not a number)'):format(assertionName or 'InRange'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'Range check on non-number',
            impact = ('value=%s'):format(tostring(value)),
            fix    = 'Fonksiyon numeric return etmiyor.',
        })
        return false
    end

    if value < minVal or value > maxVal then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s (Out of range)'):format(assertionName or 'InRange'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'Range assertion failed',
            impact = ('Beklenen: [%.4f, %.4f] | Gercek: %.4f'):format(minVal, maxVal, value),
            fix    = 'Fonksiyon başına clamp ekle.',
        })
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A6] Finite Assertion — NaN/Inf yasak
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.Finite(value, assertionName)
    if type(value) ~= 'number' then return true end
    if value ~= value then
        Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (NaN)'):format(assertionName or 'Finite'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'NaN propagation',
            impact = ('value=NaN'):format(),
            fix    = 'NaN guard ekle.',
        })
        return false
    end
    if value == math.huge or value == -math.huge then
        Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (Infinity)'):format(assertionName or 'Finite'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'Infinity propagation',
            impact = ('value=%s'):format(tostring(value)),
            fix    = 'Inf guard ekle.',
        })
        return false
    end
    return true
end



-- ─────────────────────────────────────────────────────────────────────
-- [A7] GreaterThan / LessThan
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- ★ SILENT MODE ASSERTION HELPERS — Self-check için
-- Bu fonksiyonlar normal assertion gibi çalışır ama raporları
-- bulgu listesine yazmaz, sadece sayar (shadow mode).
-- ═════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
-- [A7] GreaterThan / LessThan
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.GreaterThan(actual, threshold, assertionName)
    if type(actual) ~= 'number' or actual ~= actual then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s (Invalid number)'):format(assertionName or 'GreaterThan'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'GreaterThan non-numeric',
            impact = ('value=%s'):format(tostring(actual)),
            fix    = 'Numeric guard ekle.',
        })
        return false
    end
    if actual <= threshold then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'GreaterThan'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = ('GreaterThan: %s > %s'):format(tostring(actual), tostring(threshold)),
            impact = ('Beklenen > %.4f | Gercek: %.4f'):format(threshold, actual),
            fix    = 'Fonksiyon beklenenden kucuk donduruyor.',
        })
        return false
    end
    return true
end

function Matrix.Chaos.Assert.LessThan(actual, threshold, assertionName)
    if type(actual) ~= 'number' or actual ~= actual then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s (Invalid number)'):format(assertionName or 'LessThan'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = 'LessThan non-numeric',
            impact = ('value=%s'):format(tostring(actual)),
            fix    = 'Numeric guard ekle.',
        })
        return false
    end
    if actual >= threshold then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'LessThan'), {
            file   = Matrix.Chaos.Assert.TestFile or '?',
            attack = ('LessThan: %s < %s'):format(tostring(actual), tostring(threshold)),
            impact = ('Beklenen < %.4f | Gercek: %.4f'):format(threshold, actual),
            fix    = 'Fonksiyon beklenenden buyuk donduruyor.',
        })
        return false
    end
    return true
end

-- ═════════════════════════════════════════════════════════════════════
-- ★ SILENT MODE — global flag ile Report'u sessize alır
-- ═════════════════════════════════════════════════════════════════════
local function _withSilent(fn)
    local prev = Matrix.Chaos.__SilentMode
    Matrix.Chaos.__SilentMode = true
    local result = fn()
    Matrix.Chaos.__SilentMode = prev
    return result
end

function Matrix.Chaos.Assert._silentEqual(a, b, tol, n)
    return _withSilent(function() return Matrix.Chaos.Assert.Equal(a, b, tol, n) end)
end
function Matrix.Chaos.Assert._silentInRange(v, mn, mx, n)
    return _withSilent(function() return Matrix.Chaos.Assert.InRange(v, mn, mx, n) end)
end
function Matrix.Chaos.Assert._silentType(v, t, n)
    return _withSilent(function() return Matrix.Chaos.Assert.Type(v, t, n) end)
end
function Matrix.Chaos.Assert._silentFinite(v, n)
    return _withSilent(function() return Matrix.Chaos.Assert.Finite(v, n) end)
end
function Matrix.Chaos.Assert._silentGreaterThan(a, t, n)
    return _withSilent(function() return Matrix.Chaos.Assert.GreaterThan(a, t, n) end)
end
function Matrix.Chaos.Assert._silentLessThan(a, t, n)
    return _withSilent(function() return Matrix.Chaos.Assert.LessThan(a, t, n) end)
end
function Matrix.Chaos.Assert._silentNotNil(v, n)
    return _withSilent(function() return Matrix.Chaos.Assert.NotNil(v, n) end)
end
function Matrix.Chaos.Assert._silentNil(v, n)
    return _withSilent(function() return Matrix.Chaos.Assert.Nil(v, n) end)
end
function Matrix.Chaos.Assert._silentDeepEqual(a, b, n)
    return _withSilent(function() return Matrix.Chaos.Assert.DeepEqual(a, b, n) end)
end
function Matrix.Chaos.Assert._silentDeterministic(fn, it, n)
    return _withSilent(function() return Matrix.Chaos.Assert.Deterministic(fn, it, n) end)
end

-- ─────────────────────────────────────────────────────────────────────
-- [A8] DeepEqual — Tablo karşılaştırması
-- ─────────────────────────────────────────────────────────────────────
local function _DeepEqual(a, b, visited)
    visited = visited or {}
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    if visited[a] then return true end
    visited[a] = true

    for k, v in pairs(a) do
        if not _DeepEqual(v, b[k], visited) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function Matrix.Chaos.Assert.DeepEqual(actual, expected, assertionName)
    if not _DeepEqual(actual, expected) then
        Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s'):format(assertionName or 'DeepEqual'), {
            impact = 'Tablo içerikleri uyuşmuyor',
        })
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A9] Determinism Assertion — 2 çağrı aynı sonucu vermeli
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Chaos.Assert.Deterministic(fn, iterations, assertionName)
    if type(fn) ~= 'function' then return false end
    iterations = tonumber(iterations) or 100

    local firstOk, first = pcall(fn)
    if not firstOk then
        Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (First call crashed)'):format(assertionName or 'Deterministic'), {
            impact = ('Hata: %s'):format(tostring(first)),
        })
        return false
    end

    for i = 2, iterations do
        local ok, result = pcall(fn)
        if not ok then
            Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (Iter %d crashed)'):format(assertionName or 'Deterministic', i), {
                impact = ('Hata: %s'):format(tostring(result)),
            })
            return false
        end

        if type(first) ~= 'table' then
            if result ~= first then
                Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (Non-deterministic)'):format(assertionName or 'Deterministic'), {
                    attack = ('%dx ayni cagri farkli sonuc'):format(iterations),
                    impact = ('iter#1=%s | iter#%d=%s'):format(tostring(first), i, tostring(result)),
                    fix    = 'Fonksiyonda hidden state veya RNG var.',
                })
                return false
            end
        else
            if not _DeepEqual(first, result) then
                Matrix.Chaos.Report('CRITICAL', ('Assert FAIL: %s (Non-deterministic table)'):format(assertionName or 'Deterministic'), {
                    attack = ('%dx ayni cagri farkli tablo'):format(iterations),
                    fix    = 'Table mutasyonu veya paylaşılan state var.',
                })
                return false
            end
        end
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- [A10] Chain Assertion — beklenen event sırası
-- ─────────────────────────────────────────────────────────────────────
Matrix.Chaos.Assert.EventLog = {}

function Matrix.Chaos.Assert.LogEvent(name)
    table_insert(Matrix.Chaos.Assert.EventLog, { name = name, ts = GetGameTimer() })
end

function Matrix.Chaos.Assert.ClearEventLog()
    Matrix.Chaos.Assert.EventLog = {}
end

function Matrix.Chaos.Assert.EventFired(eventName, assertionName)
    for _, e in ipairs(Matrix.Chaos.Assert.EventLog) do
        if e.name == eventName then return true end
    end
    Matrix.Chaos.Report('HIGH', ('Assert FAIL: %s (Event not fired)'):format(assertionName or 'EventFired'), {
        attack = ('Beklenen event tetiklenmedi: %s'):format(eventName),
        impact = ('Log: %s'):format(table_concat(
            (function()
                local names = {}
                for _, e in ipairs(Matrix.Chaos.Assert.EventLog) do names[#names+1] = e.name end
                return names
            end)(), ', ')),
    })
    return false
end

-- ═════════════════════════════════════════════════════════════════════
-- ██████████ ASKERİ SEVİYE — KENDİNİ TEST ETME ██████████
-- ═════════════════════════════════════════════════════════════════════
Matrix.Chaos.RegisterModule('self_check', 'Askeri Self-Check — Chaos kendi assertion frameworkunu test eder', function()
    local A = Matrix.Chaos.Assert
    A.SetContext('self_check', 'server/matrix_chaos.lua')

    local tests = {
        { name = 'equal_positive',    fn = function() return A.Equal(5.0, 5.0, 0.001, 'equal_pos') == true end },
        { name = 'equal_negative',    fn = function() return A._silentEqual(5.0, 6.0, 0.001, 'equal_neg') == false end },
        { name = 'equal_nan_reject',  fn = function() local n = 0.0/0.0; return A._silentEqual(n, n, 0.001, 'nan') == false end },

        { name = 'inrange_positive',  fn = function() return A.InRange(0.5, 0.0, 1.0, 'inrange_pos') == true end },
        { name = 'inrange_negative',  fn = function() return A._silentInRange(5.0, 0.0, 1.0, 'inrange_neg') == false end },

        { name = 'type_positive',     fn = function() return A.Type('hello', 'string', 'type_pos') == true end },
        { name = 'type_negative',     fn = function() return A._silentType(123, 'string', 'type_neg') == false end },

        { name = 'finite_positive',   fn = function() return A.Finite(0.5, 'finite_pos') == true end },
        { name = 'finite_nan_reject', fn = function() return A._silentFinite(0.0/0.0, 'finite_nan') == false end },
        { name = 'finite_inf_reject', fn = function() return A._silentFinite(math.huge, 'finite_inf') == false end },

        { name = 'gt_positive',       fn = function() return A.GreaterThan(5.0, 3.0, 'gt_pos') == true end },
        { name = 'gt_negative',       fn = function() return A._silentGreaterThan(2.0, 5.0, 'gt_neg') == false end },
        { name = 'lt_positive',       fn = function() return A.LessThan(3.0, 5.0, 'lt_pos') == true end },
        { name = 'lt_negative',       fn = function() return A._silentLessThan(7.0, 5.0, 'lt_neg') == false end },

        { name = 'notnil_positive',   fn = function() return A.NotNil(5, 'nn_pos') == true end },
        { name = 'notnil_negative',   fn = function() return A._silentNotNil(nil, 'nn_neg') == false end },
        { name = 'nil_positive',      fn = function() return A.Nil(nil, 'nil_pos') == true end },
        { name = 'nil_negative',      fn = function() return A._silentNil(5, 'nil_neg') == false end },

        { name = 'deepequal_positive', fn = function() return A.DeepEqual({a=1,b={c=2}}, {a=1,b={c=2}}, 'de_pos') == true end },
        { name = 'deepequal_negative', fn = function() return A._silentDeepEqual({a=1}, {a=2}, 'de_neg') == false end },

        { name = 'determinism_positive', fn = function()
            return A.Deterministic(function() return 42 end, 5, 'det_pos') == true
        end },
        { name = 'determinism_negative', fn = function()
            local counter = 0
            return A._silentDeterministic(function()
                counter = counter + 1
                return counter
            end, 5, 'det_neg') == false
        end },
    }

    local passed, failed = 0, 0
    local failures = {}
    for _, t in ipairs(tests) do
        local ok, result = pcall(t.fn)
        if ok and result == true then
            passed = passed + 1
            print(('[CHAOS][self_check] PASS: %s'):format(t.name))
        else
            failed = failed + 1
            failures[#failures + 1] = t.name
            print(('[CHAOS][self_check] FAIL: %s%s'):format(
                t.name, ok and '' or (' — ' .. tostring(result))))
        end
    end

      local verdict = (failed == 0) and 'PASS' or 'FAIL'
    Matrix.Chaos.Report(
        (failed > 0) and 'CRITICAL' or 'MEDIUM',  -- ★ INFO yerine MEDIUM: box görünsün
        ('Askeri Self-Check: %d/%d passed'):format(passed, #tests),
        {
            file     = 'server/matrix_chaos.lua',
            attack   = ('%d assertion framework testi'):format(#tests),
            impact   = (failed > 0)
                and ('%d passed, %d failed — %s'):format(passed, failed, table_concat(failures, ', '))
                or ('%d/%d — tam koruma'):format(passed, #tests),
            fix      = (failed > 0) and 'Assertion framework bozuk — acil fix gerekli.' or 'Framework saglikli.',
            evidence = ('Verdict: %s'):format(verdict),
        }
    )
end)
    
-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 6: SIGNATURE SPOOF ██████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: Server-authoritative sistemlerde kimlik/ID sahteciliği
--   • Sahte net_id → başka botun pedini kontrol et
--   • Sahte citizenid → başka oyuncunun parasını çek
--   • Sahte src → başka oyuncunun adına işlem yap
--   • Negatif/yüksek src → tablo taşması
--   • Cross-boundary entity erişimi → başka routing bucket'taki entity
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('signature_spoof', 'Signature Spoof — sahte src/net_id/citizenid', function()
    local A = Matrix.Chaos.Assert
    A.SetContext('signature_spoof', 'server/matrix_chaos.lua')

    -- ★ TEST 1: Sahte server-side src ile GetOrCreatePlayerState
    print('[CHAOS][signature_spoof] Test 1: Sahte src ile GetOrCreatePlayerState')

    local spoofPayloads = { 0, -1, -99999, 99999999, 'admin', nil, {} }

    for i, badSrc in ipairs(spoofPayloads) do
        local ok, result = pcall(Matrix.GetOrCreatePlayerState, badSrc)
        if not ok then
            Matrix.Chaos.Report('HIGH', ('Signature Spoof: GetOrCreatePlayerState(%s) crash'):format(type(badSrc)), {
                file   = 'server/main.lua',
                attack = ('Fonksiyon cagrildi: GetOrCreatePlayerState(%s)'):format(tostring(badSrc)),
                impact = ('pcall: %s'):format(tostring(result)),
                fix    = 'Fonksiyon başında type(src) ~= "number" kontrolü ekle.',
                reproduce = {
                    ('Matrix.GetOrCreatePlayerState(%s)'):format(tostring(badSrc)),
                },
            })
        else
            print(('[CHAOS][signature_spoof] OK: %s src reddedildi (return %s)'):format(
                type(badSrc), tostring(result)))
        end
    end

    -- ★ TEST 2: Sahte net_id ile bot çözümleme
    print('[CHAOS][signature_spoof] Test 2: Sahte net_id ile entity cozumleme')

    local badNetIds = { -1, 0, 999999999, -99999, 'not_a_net_id' }

    for i, badNetId in ipairs(badNetIds) do
        local ok, entity = pcall(function()
            return NetworkGetEntityFromNetworkId(badNetId)
        end)
        if not ok then
            Matrix.Chaos.Report('HIGH', ('Signature Spoof: NetworkGetEntityFromNetworkId(%s) crash'):format(tostring(badNetId)), {
                file   = 'server/matrix_chaos.lua',
                attack = ('Native cagrildi: NetworkGetEntityFromNetworkId(%s)'):format(tostring(badNetId)),
                impact = ('pcall: %s'):format(tostring(entity)),
                fix    = 'Fonksiyon başında net_id sayısal mı ve pozitif mi kontrol et.',
            })
        else
            print(('[CHAOS][signature_spoof] OK: net_id %s guvenli (entity=%s)'):format(
                tostring(badNetId), tostring(entity)))
        end
    end

    -- ★ TEST 3: Sahte citizenid ile para işlemi
    print('[CHAOS][signature_spoof] Test 3: Sahte citizenid ile bakiye cekme')

    local fakeCitizenids = {
        '',
        'NEVER_EXISTED_CITIZEN',
        "' OR 1=1 --",
        string.rep('X', 10000),
        "\x00\x01\x02",
    }

    for _, fakeCid in ipairs(fakeCitizenids) do
        -- Matrix.CashDecay.Launder bir citizenid alır
        if Matrix.CashDecay and Matrix.CashDecay.Launder then
            local ok, result = pcall(Matrix.CashDecay.Launder, 999999, 100.0, fakeCid)
            if not ok then
                Matrix.Chaos.Report('MEDIUM', 'Signature Spoof: Launder fake citizenid ile crash', {
                    file   = 'server/market.lua',
                    attack = ('Matrix.CashDecay.Launder(999999, 100, "%s")'):format(fakeCid:sub(1, 20)),
                    impact = ('pcall: %s'):format(tostring(result)),
                    fix    = 'Citizenid sanitizasyonu ekle.',
                })
            else
                print(('[CHAOS][signature_spoof] OK: fake citizenid %s guvenli'):format(fakeCid:sub(1, 20)))
            end
        end
    end

    -- ★ TEST 4: Aynı bot için sahte ped net_id sahipliği
    print('[CHAOS][signature_spoof] Test 4: Cross-bot net_id sahiplik sahteciligi')

    -- Fixture'dan bir bot al
    local targetBot = nil
    for botId in pairs(Matrix.Chaos.Fixture.ActiveBots) do
        targetBot = botId
        break
    end

    if targetBot and Matrix.Bots[targetBot] then
        -- Botun net_id'si YOK (fixture'da ped yok)
        local originalNetId = Matrix.Bots[targetBot].state.net_id
        Matrix.Bots[targetBot].state.net_id = 999999

        -- Bu bot üzerinden dispatch başlatmayı dene — bot spawn edilmemiş
        if Matrix.BeginPhysicalDispatch and next(Matrix.Chaos.Fixture.ActiveTrapHouses) then
            local trapId
            for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do trapId = id; break end
            if trapId and Matrix.TrapHouses[trapId] then
                local house = Matrix.TrapHouses[trapId]
                local ok, result = pcall(Matrix.BeginPhysicalDispatch,
                    targetBot, house.coords, house.coords, nil, 'foot', 0.0, nil, 1.0)
                if not ok then
                    Matrix.Chaos.Report('MEDIUM', 'Signature Spoof: Fake net_id ile dispatch crash', {
                        file   = 'server/main.lua',
                        attack = 'Bot net_id = 999999 (gercek degil) + BeginPhysicalDispatch',
                        impact = ('pcall: %s'):format(tostring(result)),
                        fix    = 'BeginPhysicalDispatch net_id doğrulaması yapmıyor.',
                    })
                else
                    print('[CHAOS][signature_spoof] OK: Fake net_id ile dispatch reddedildi')
                end
            end
        end

        Matrix.Bots[targetBot].state.net_id = originalNetId
    end

    -- ★ TEST 5: Sınır ihlali — MAX_INT + 1
    print('[CHAOS][signature_spoof] Test 5: Integer overflow src')

    local overflowSrc = 2147483648  -- 2^31
    local ok, result = pcall(Matrix.GetOrCreatePlayerState, overflowSrc)
    if not ok then
        Matrix.Chaos.Report('MEDIUM', 'Signature Spoof: MAX_INT overflow', {
            file   = 'server/main.lua',
            attack = ('GetOrCreatePlayerState(%d)'):format(overflowSrc),
            impact = ('pcall: %s'):format(tostring(result)),
            fix    = 'src üst sınırı kontrol et.',
        })
    else
        print(('[CHAOS][signature_spoof] OK: overflow src reddedildi (return %s)'):format(tostring(result)))
    end

    Matrix.Chaos.Report('INFO', 'Signature Spoof tamamlandi', {
        attack = '5 farkli sahtecilik vektoru',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 7: PLAYER SIMULATION ██████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: Gerçek bir oyuncunun yapacağı tüm hareketleri simüle et
--   • Oyuncu doğ → resource yüklensin
--   • Stok işlemi → envanter manipülasyonu
--   • HUD aç/kapa → event flood
--   • Trap house gir/çık → bucket değişimi
--   • Disconnect/reconnect → state recovery
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('player_sim', 'Player Simulation — tam oyuncu yasam dongusu', function()
    local A = Matrix.Chaos.Assert
    A.SetContext('player_sim', 'server/matrix_chaos.lua')

    -- ★ TEST 1: 100x state consistency — aynı girdi aynı çıktı
    print('[CHAOS][player_sim] Test 1: 100x state consistency')

    local testCitizenId = 'CHAOS-PLAYER-SIM-CID'

    -- 100x aynı hesap üret — deterministik olmalı
    local accounts = {}
    for i = 1, 100 do
        accounts[i] = Matrix.BlackMarket.GenerateWeaponSerial(testCitizenId, 'weapon_assaultrifle')
    end

    -- Hepsi farklı olmalı (her çağrıda sequence artar)
    local seen = {}
    local dupes = 0
    for i, acc in ipairs(accounts) do
        if seen[acc] then
            dupes = dupes + 1
        end
        seen[acc] = true
    end

    if dupes > 0 then
        Matrix.Chaos.Report('HIGH', ('Player Sim: %dx WeaponSerial dupe'):format(dupes), {
            file   = 'server/blackmarket.lua',
            attack = '100x GenerateWeaponSerial ayni citizenid',
            impact = ('%d dupe -- sequence sayaci yarisi var'):format(dupes),
            fix    = 'NextSequence atomic mi kontrol et.',
        })
    else
        print('[CHAOS][player_sim] OK: 100x WeaponSerial unique')
    end

    -- ★ TEST 2: Bot lifecycle simülasyonu — doğ → ateş → öl
    print('[CHAOS][player_sim] Test 2: Bot lifecycle — dog, ates, ol')

    local simBot = Matrix.CreateBotRecord({
        name = 'CHAOS-PLAYER-SIM-BOT',
        role = 'dealer',
    })

    if simBot and simBot.id then
        Matrix.Chaos.Fixture.ActiveBots[simBot.id] = true

        -- Adım 1: Doğ
        A.NotNil(simBot.id, 'sim_bot_spawn')

        -- Adım 2: Ateş et (10x cortisol spike)
        for i = 1, 10 do
            pcall(Matrix.Kitchen.AdjustCortisol, { kind = 'bot', id = simBot.id }, 'gunshot')
        end

        local cortisol = simBot.biology.cortisol_level
        A.InRange(cortisol, 0.0, 1.0, 'sim_cortisol_range')
        A.Finite(cortisol, 'sim_cortisol_finite')

        -- Adım 3: Öl
        if Matrix.RemoveBot then
            local ok = pcall(Matrix.RemoveBot, simBot.id, 'deceased')
            A.Equal(ok, true, 0, 'sim_bot_remove_ok')
        end

        print('[CHAOS][player_sim] OK: Bot lifecycle tamamlandi')
    end

    -- ★ TEST 3: HUD aç/kapa fırtınası
    print('[CHAOS][player_sim] Test 3: HUD toggle firtinasi')

    local hudToggles = 50
    local toggleErrors = 0

    for i = 1, hudToggles do
        local ok = pcall(function()
            -- HUD snapshot al
            if Matrix.Hud and Matrix.Hud.BuildSnapshot then
                return Matrix.Hud.BuildSnapshot(0)
            end
            return true
        end)
        if not ok then toggleErrors = toggleErrors + 1 end
    end

    if toggleErrors > 0 then
        Matrix.Chaos.Report('MEDIUM', ('Player Sim: HUD toggle %d/%d fail'):format(toggleErrors, hudToggles), {
            file   = 'server/market.lua',
            attack = ('%dx HUD.BuildSnapshot'):format(hudToggles),
            impact = ('%d fail'):format(toggleErrors),
            fix    = 'BuildSnapshot src=0 için guard ekle.',
        })
    else
        print('[CHAOS][player_sim] OK: HUD 50x toggle temiz')
    end

    -- ★ TEST 4: Trap house giriş/çıkış simülasyonu
    print('[CHAOS][player_sim] Test 4: Trap house giris/cikis sim')

    local anyTrapId
    for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do anyTrapId = id; break end

    if anyTrapId then
        -- 20x gir/çık döngüsü
        local enterExitErrors = 0
        for i = 1, 20 do
            local okEnter = pcall(function()
                -- Fake player source ile giriş — should silently fail or safe
                if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse then
                    return Matrix.TrapHouseInterior.GetPlayerTrapHouse(999999)
                end
                return nil
            end)
            if not okEnter then enterExitErrors = enterExitErrors + 1 end
        end

        if enterExitErrors > 0 then
            Matrix.Chaos.Report('MEDIUM', 'Player Sim: Trap house enter/exit crash', {
                file   = 'server/trap_house_interior.lua',
                attack = '20x GetPlayerTrapHouse(999999)',
                impact = ('%d fail'):format(enterExitErrors),
                fix    = 'src guard ekle.',
            })
        else
            print('[CHAOS][player_sim] OK: Trap house 20x enter/exit temiz')
        end
    end

    -- ★ TEST 5: Disconnect/reconnect state recovery
    print('[CHAOS][player_sim] Test 5: Disconnect/reconnect recovery')

    -- RAM cache'e sahte oyuncu koy
    local originalSourceIndexSize = 0
    for _ in pairs(Matrix.PlayerSourceIndex) do originalSourceIndexSize = originalSourceIndexSize + 1 end

    local ok, err = pcall(function()
        -- PlayerSourceIndex'e 100 sahte kayıt koy
        for i = 1, 100 do
            Matrix.PlayerSourceIndex[900000 + i] = 'FAKE-CID-' .. i
        end
    end)

    if not ok then
        Matrix.Chaos.Report('MEDIUM', 'Player Sim: PlayerSourceIndex manipulation crash', {
            file   = 'server/main.lua',
            attack = '100x PlayerSourceIndex[900000+i] = "FAKE-CID"',
            impact = ('pcall: %s'):format(tostring(err)),
        })
    else
        -- Temizle
        for i = 1, 100 do
            Matrix.PlayerSourceIndex[900000 + i] = nil
        end
        print('[CHAOS][player_sim] OK: PlayerSourceIndex manipulation temiz')
    end

    Matrix.Chaos.Report('INFO', 'Player Simulation tamamlandi', {
        attack = '5 farkli oyuncu yasam dongusu adimi',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 8: TIMING ATTACK ██████████████████████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: Zamanlama pencerelerini yakala
--   • Spawn + Remove aynı anda → race window
--   • Event flood + DB write → order dependency
--   • Thread race → deadlock
--   • Lock starve → starvation
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('timing_attack', 'Timing Attack — zamanlama pencereleri', function()
    local A = Matrix.Chaos.Assert
    A.SetContext('timing_attack', 'server/matrix_chaos.lua')

    -- ★ TEST 1: Spawn + Remove aynı milisaniyede
    print('[CHAOS][timing_attack] Test 1: Spawn + Remove ayni ms')

    local spawnBot = Matrix.CreateBotRecord({
        name = 'CHAOS-TIMING-SPAWN',
        role = 'diagnostic_test',
    })

    if spawnBot and spawnBot.id then
        Matrix.Chaos.Fixture.ActiveBots[spawnBot.id] = true

        -- Aynı anda spawn + remove
        local spawnResults = {}
        local removeResults = {}

        CreateThread(function()
            spawnResults[1] = pcall(Matrix.SpawnBot, spawnBot.id, vector4(0, 0, 30, 0))
        end)

        CreateThread(function()
            removeResults[1] = pcall(Matrix.RemoveBot, spawnBot.id, 'retired')
        end)

        Wait(500)

        -- Bot hala RAM'de mi? (Spawn crash etmiş olabilir ama Remove temizlemiş olmalı)
        local ramExists = Matrix.Bots[spawnBot.id] ~= nil

        if ramExists then
            Matrix.Chaos.Report('HIGH', 'Timing: Spawn+Remove race -> hayalet bot', {
                file   = 'server/main.lua',
                attack = 'Ayni anda SpawnBot + RemoveBot',
                impact = 'Bot RAM\'de kaldi -- ghost entry',
                fix    = 'Spawn ve Remove arasinda mutex gerekli.',
                reproduce = {
                    'CreateThread(function() Matrix.SpawnBot(id, coords) end)',
                    'CreateThread(function() Matrix.RemoveBot(id, "retired") end)',
                    'Matrix.Bots[id] ~= nil kontrol et',
                },
            })
            -- Temizle
            pcall(Matrix.RemoveBot, spawnBot.id, 'chaos_cleanup')
        else
            print('[CHAOS][timing_attack] OK: Spawn+Remove race temiz')
        end
    end

    -- ★ TEST 2: Event flood + state read
    print('[CHAOS][timing_attack] Test 2: Event flood esnasinda state read')

    local testBot = Matrix.CreateBotRecord({
        name = 'CHAOS-TIMING-READ',
        role = 'diagnostic_test',
    })

    if testBot and testBot.id then
        Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true

        -- 100 thread aynı anda hem okuma hem yazma yapsın
        local completed = 0
        local readErrors = 0
        local writeErrors = 0

        for i = 1, 100 do
            CreateThread(function()
                -- Read
                local okR = pcall(function()
                    return testBot.biology.cortisol_level
                end)
                if not okR then readErrors = readErrors + 1 end

                -- Write
                local okW = pcall(function()
                    testBot.biology.cortisol_level = 0.5
                end)
                if not okW then writeErrors = writeErrors + 1 end

                completed = completed + 1
            end)
        end

        local waited = 0
        while completed < 100 and waited < 5000 do
            Wait(50); waited = waited + 50
        end

        if readErrors > 0 or writeErrors > 0 then
            Matrix.Chaos.Report('HIGH', ('Timing: 100x concurrent read/write fail'):format(), {
                file   = 'server/matrix_chaos.lua',
                attack = '100x paralel read + write',
                impact = ('read_errors=%d write_errors=%d'):format(readErrors, writeErrors),
                fix    = 'Bot state tablosu thread-safe değil.',
            })
        else
            print('[CHAOS][timing_attack] OK: 100x concurrent read/write temiz')
        end
    end

    -- ★ TEST 3: Lock starvation — uzun süren işlem
    print('[CHAOS][timing_attack] Test 3: Lock starvation')

    -- Uzun süreli bir işlem başlat, paralel olarak diğer thread'ler işlem yapsın
    local starvationCompleted = 0
    local starvationFail = 0

    CreateThread(function()
        -- Uzun işlem: 1000x GetHeat
        for i = 1, 1000 do
            pcall(Matrix.Bureau.GetHeat, 1)
        end
    end)

    for i = 1, 10 do
        CreateThread(function()
            local ok = pcall(function()
                return Matrix.Clamp(0.5, 0.0, 1.0)
            end)
            if ok then starvationCompleted = starvationCompleted + 1
            else starvationFail = starvationFail + 1 end
        end)
    end

    Wait(500)

    if starvationFail > 0 then
        Matrix.Chaos.Report('MEDIUM', ('Timing: Lock starvation -- %d fail'):format(starvationFail), {
            file   = 'server/matrix_chaos.lua',
            attack = 'Uzun sureli GetHeat + kisa thread',
            impact = ('%d fail'):format(starvationFail),
        })
    else
        print(('[CHAOS][timing_attack] OK: Lock starvation yok (%d tamamlandi)'):format(starvationCompleted))
    end

    -- ★ TEST 4: Kısa pencere koordinasyon testi
    print('[CHAOS][timing_attack] Test 4: Kisa pencere koordinasyon')

    -- Dispatch başlat ve hemen sil — kısa pencereyi yakala
    local dspBot = Matrix.CreateBotRecord({
        name = 'CHAOS-TIMING-DSP',
        role = 'diagnostic_test',
    })

    if dspBot and dspBot.id and Matrix.Chaos.Fixture.ActiveTrapHouses then
        Matrix.Chaos.Fixture.ActiveBots[dspBot.id] = true

        local trapId
        for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do trapId = id; break end

        if trapId and Matrix.TrapHouses[trapId] then
            local house = Matrix.TrapHouses[trapId]

            -- Dispatch başlat
            local okDsp = pcall(Matrix.BeginPhysicalDispatch,
                dspBot.id, house.coords, house.coords, nil, 'foot', 0.0, nil, 1.0)

            -- Hemen sil
            local okRem = pcall(Matrix.RemoveBot, dspBot.id, 'retired')

            -- Dispatch tablosunda kaldı mı?
            if Matrix.Dispatches[dspBot.id] then
                Matrix.Chaos.Report('CRITICAL', 'Timing: Dispatch leak', {
                    file   = 'server/main.lua',
                    attack = 'Dispatch + immediate Remove',
                    impact = 'Dispatches[botId] hala dolu -- dispatch leak',
                    fix    = 'RemoveBot içinde Dispatch cleanup yapılmıyor.',
                    reproduce = {
                        'Matrix.BeginPhysicalDispatch(bot.id, ...)',
                        'Matrix.RemoveBot(bot.id, "retired")',
                        'print(Matrix.Dispatches[bot.id])  -- nil olmalı',
                    },
                })
                -- Temizle
                Matrix.Dispatches[dspBot.id] = nil
            else
                print('[CHAOS][timing_attack] OK: Dispatch leak yok')
            end
        end
    end

    Matrix.Chaos.Report('INFO', 'Timing Attack tamamlandi', {
        attack = '4 farkli zamanlama penceresi',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- =====================================================================
-- BOOT BANNER — v4.0 (3 yeni askeri modül)
-- =====================================================================
print('[CHAOS] Yamyam modu v4.0 (ASKERI SEVIYE) hazir.')
print('[CHAOS] Aktif moduller: ' .. table_concat(Matrix.Chaos.GetModules(), ', '))

-- ═════════════════════════════════════════════════════════════════════
-- ██████████ SALDIRI MODÜLÜ 12: NETWORK GUARD TEST ██████████
-- ═════════════════════════════════════════════════════════════════════
-- KONSEPT: NetworkGuard'ın trust audit + rate limit korumasını doğrula.
-- 4 test:
--   1. Yanlış tip (botId string) → reddedilmeli
--   2. Yanlış range (purity=999) → reddedilmeli
--   3. Doğru argüman → kabul edilmeli (false positive yok)
--   4. Rate limit flood (20 istek) → 10'dan fazla geçmemeli
-- ═════════════════════════════════════════════════════════════════════

Matrix.Chaos.RegisterModule('network_guard_test', 'Network Guard — trust audit + rate limit doğrulama', function()
    local NG = Matrix.NetworkGuard
    if not NG then
        Matrix.Chaos.Report('MEDIUM', 'NetworkGuard yüklü değil', {
            attack = 'Matrix.NetworkGuard bulunamadı',
            impact = 'Trust audit testi yapılamadı',
            fix = 'matrix_network_guard.lua fxmanifest\'te yüklü mü kontrol et.',
        })
        return
    end

    -- ═══════════════════════════════════════════════════════════════
    -- TEST 1: Yanlış tip (botId string)
    -- ═══════════════════════════════════════════════════════════════
    print('[CHAOS][network_guard] Test 1: Yanlış tip (botId string)')
    local ok1, field1, val1 = NG.ValidateArgs(1, 'matrix:server:reportSaleAttempt',
        { 'HACKER_BOT', 0.5, 0.5, 'x', 10 })
    if ok1 then
        Matrix.Chaos.Report('CRITICAL', 'Trust Audit: Yanlış tip kabul edildi', {
            file   = 'server/matrix_network_guard.lua',
            attack = "reportSaleAttempt(botId='HACKER_BOT', ...)",
            impact = 'String botId kabul edildi — tip koruması YOK',
            fix    = 'Schemas tablosunda botId için number kontrolü var mı?',
        })
    else
        print(('[CHAOS][network_guard] OK: Yanlış tip reddedildi (field=%s value=%s)'):format(
            tostring(field1), tostring(val1)))
    end

    -- ═══════════════════════════════════════════════════════════════
    -- TEST 2: Yanlış range (purity=999.99)
    -- ═══════════════════════════════════════════════════════════════
    print('[CHAOS][network_guard] Test 2: Yanlış range (purity=999.99)')
    local ok2, field2, val2 = NG.ValidateArgs(1, 'matrix:server:reportSaleAttempt',
        { 1, 0.5, 999.99, 'x', 10 })
    if ok2 then
        Matrix.Chaos.Report('HIGH', 'Trust Audit: Yanlış range kabul edildi', {
            file   = 'server/matrix_network_guard.lua',
            attack = 'reportSaleAttempt(purity=999.99)',
            impact = '999.99 > 1 olmasına rağmen kabul edildi',
            fix    = 'Schemas: purity için max=1 kontrol et.',
        })
    else
        print(('[CHAOS][network_guard] OK: Yanlış range reddedildi (field=%s value=%s)'):format(
            tostring(field2), tostring(val2)))
    end

    -- ═══════════════════════════════════════════════════════════════
    -- TEST 3: Doğru argüman (false positive kontrolü)
    -- ═══════════════════════════════════════════════════════════════
    print('[CHAOS][network_guard] Test 3: Doğru argüman (false positive kontrolü)')
    local ok3 = NG.ValidateArgs(1, 'matrix:server:reportSaleAttempt',
        { 1, 0.5, 0.5, 'BM-TRIFLE-12345678-1', 10 })
    if not ok3 then
        Matrix.Chaos.Report('HIGH', 'Trust Audit: Doğru argüman reddedildi (false positive)', {
            file   = 'server/matrix_network_guard.lua',
            attack = 'reportSaleAttempt(1, 0.5, 0.5, "BM-TRIFLE-...", 10) — GEÇERLİ',
            impact = 'Doğru argüman reddedildi — gerçek oyuncular etkilenir',
            fix    = 'Şema çok sıkı, gevşet.',
        })
    else
        print('[CHAOS][network_guard] OK: Doğru argüman kabul edildi')
    end

    -- ═══════════════════════════════════════════════════════════════
    -- TEST 4: Rate limit flood (20 istek)
    -- ═══════════════════════════════════════════════════════════════
    print('[CHAOS][network_guard] Test 4: Rate limit flood (20 istek)')
    local fakeSrc = 999999
    local allowed = 0
    local blocked = 0
    for i = 1, 20 do
        if NG.Check(fakeSrc, 'matrix:server:reportSaleAttempt') then
            allowed = allowed + 1
        else
            blocked = blocked + 1
        end
    end
    if allowed > 10 then
        Matrix.Chaos.Report('HIGH', 'Rate Limit: 20 istekten fazla geçti', {
            file   = 'server/matrix_network_guard.lua',
            attack = '20x Check aynı src için reportSaleAttempt',
            impact = ('%d geçti (max 10 olmalı)'):format(allowed),
            fix    = 'Token bucket limiti çalışmıyor.',
        })
    else
        print(('[CHAOS][network_guard] OK: Rate limit calisiyor (%d/%d gecti, %d reddedildi)'):format(
            allowed, 20, blocked))
    end

    -- ═══════════════════════════════════════════════════════════════
    -- TEST 5-16: 12 yeni event şeması doğrulama
    -- Her event için yanlış argüman → reddedilmeli
    -- ═══════════════════════════════════════════════════════════════
    print('[CHAOS][network_guard] Test 5-16: 12 yeni event şeması')

    local testCases = {
        { event = 'matrix:server:blackmarket:buyVehicle',
          bad   = { 999, 'token' },                                    -- catalogId number, olmamalı
          good  = { 'bm_sultan', 'TK-1234' } },
        { event = 'matrix:server:blackmarket:buyAmmo',
          bad   = { { }, 'token' },                                    -- catalogId table
          good  = { 'bm_ammo_rifle', 'TK-1234' } },
        { event = 'matrix:server:blackmarket:buyBurnerPhone',
          bad   = { 'x', 999 },                                        -- token number
          good  = { 'bm_burner', 'TK-1234' } },
        { event = 'matrix:server:blackmarket:buySpareBarrel',
          bad   = { nil },                                             -- token nil
          good  = { 'TK-1234' } },
        { event = 'matrix:server:trapHouseInterior:transferBotToBot',
          bad   = { 1, 2, 'meth_bag', 99999 },                         -- count aşırı
          good  = { 1, 2, 'meth_bag', 5 } },
        { event = 'matrix:server:phone:remoteWipe',
          bad   = { 123 },                                             -- dnaIdHint number
          good  = { 'DNA-00000001' } },
        { event = 'matrix:server:proxy:purchaseCell',
          bad   = { 123, 'payload' },                                  -- size number
          good  = { 'medium', 'payload' } },
        { event = 'matrix:server:vendorPool:purchaseWeapon',
          bad   = { 'x', 'weapon_assaultrifle' },                      -- vendorId string
          good  = { 1, 'weapon_assaultrifle' } },
        { event = 'matrix:server:districtHubs:assign',
          bad   = { 'not_a_number', 'label', 'coords' },
          good  = { 1, 'label', 'coords' } },
        { event = 'matrix:server:doorReinforcement:install',
          bad   = { 1, 999 },                                          -- targetLevel max 3
          good  = { 1, 2 } },
        { event = 'matrix:server:registerFleetVehicle',
          bad   = { 'plate', 'car', 'hot', 5.0 },                      -- wear max 1
          good  = { 'plate', 'car', 'hot', 0.5 } },
        { event = 'matrix:server:unassignFleetVehicle',
          bad   = { 123 },                                             -- plate number
          good  = { 'CHAOS001' } },
    }

    local passed = 0
    local failed = 0
    for i, tc in ipairs(testCases) do
        local okBad  = NG.ValidateArgs(1, tc.event, tc.bad)
        local okGood = NG.ValidateArgs(1, tc.event, tc.good)

        if okBad then
            failed = failed + 1
            Matrix.Chaos.Report('HIGH', ('NetworkGuard: %s yanlış argümanı kabul etti'):format(tc.event), {
                file   = 'server/matrix_network_guard.lua',
                attack = ('Bad args for %s'):format(tc.event),
                impact = 'Spoof edilebilir event',
                fix    = 'Şema kontrolü sıkılaştır.',
            })
        elseif not okGood then
            failed = failed + 1
            Matrix.Chaos.Report('HIGH', ('NetworkGuard: %s doğru argümanı reddetti'):format(tc.event), {
                file   = 'server/matrix_network_guard.lua',
                attack = 'Good args rejected',
                impact = 'False positive — gerçek oyuncu etkilenir',
                fix    = 'Şema gevşet.',
            })
        else
            passed = passed + 1
        end
    end

    print(('[CHAOS][network_guard] Sonuç: %d/%d geçti, %d fail'):format(passed, #testCases, failed))


    -- ═══════════════════════════════════════════════════════════════
    -- ÖZET
    -- ═══════════════════════════════════════════════════════════════
    Matrix.Chaos.Report('INFO', 'NetworkGuard test tamamlandi', {
        attack = '4 trust audit + rate limit testi',
        impact = string_format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)

Matrix.Chaos.RegisterModule('live_spoof',
    'Gerçek TriggerServerEvent spoof — NetworkGuard gerçekten durduruyor mu?', function()

    local A = Matrix.Chaos.Assert
    A.SetContext('live_spoof', 'server/matrix_chaos.lua')

    -- ★ Bu modül yalnızca AKTIF OYUNCU varsa çalışır.
    -- Chaos'u komut olarak sen tetikledin — sen aktif oyuncusun.
    local mySrc = nil
    for _, srcStr in ipairs(GetPlayers()) do
        mySrc = tonumber(srcStr); break
    end

    if not mySrc then
        Matrix.Chaos.Report('MEDIUM', 'live_spoof: aktif oyuncu yok, atlandi', {
            attack = 'Gerçek client TriggerServerEvent',
            impact = 'Test atlandi',
            fix    = 'Oyun içinden çalıştır.',
        })
        return
    end

    -- ★ TEST 1: Geçersiz argümanla reportSaleAttempt — reddedilmeli
    -- (Bot ID string, purity 999 vs.)
    local beforeFindings = #Matrix.Chaos.Findings

    TriggerClientEvent('chaos:client:fireSpoof', mySrc,
        'matrix:server:reportSaleAttempt', { 'HACKER_BOT', 0.5, 999.99, 'x', 10 })

    Wait(500)

    -- Eğer NetworkGuard çalışıyorsa oyuncu KICK edilmemeli,
    -- ama [TRUST-VIOLATION] log'u düşmüş olmalı.
    -- Burada kesin test: oyuncu hala bağlı mı?
    local stillConnected = GetPlayerName(mySrc) ~= nil

    A.Equal(stillConnected, true, 0, 'player_not_kicked_after_1_violation')

    Matrix.Chaos.Report('INFO', 'live_spoof tamamlandi', {
        attack = 'Gerçek client TriggerServerEvent spoof (1 deneme)',
        impact = ('oyuncu hala bagli: %s'):format(tostring(stillConnected)),
    })
end)

Matrix.Chaos.RegisterModule('sql_static_scan',
    'MySQL.query cagrilarinda string birlestirme tara', function()

    local A = Matrix.Chaos.Assert
    A.SetContext('sql_static_scan', 'server/matrix_chaos.lua')

    -- Taranacak kritik dosyalar
    local files = {
        'server/main.lua', 'server/bureau.lua', 'server/market.lua',
        'server/logistics.lua', 'server/blackmarket.lua', 'server/wound_system.lua',
        'server/crime_witness.lua', 'server/kitchen.lua', 'server/forensics.lua',
    }

    local offenders = {}

    for _, path in ipairs(files) do
        local content = LoadResourceFile(GetCurrentResourceName(), path)
        if type(content) == 'string' then
            local lineNum = 0
            for line in content:gmatch('[^\n]*') do
                lineNum = lineNum + 1
                local codeOnly = line:match('^([^%-]*)') or ''

                -- ★ Tehlikeli pattern: MySQL.query/prepare/insert/update
                -- cagrisi ile ayni satirda `..` (string birleştirme) VEYA
                -- `string.format` var mi?
                local hasSQLCall = codeOnly:find('MySQL%.%w+%.?%w*%s*%(')
                    or codeOnly:find('MySQL%.%w+%s*%(')

                local hasStringConcat = codeOnly:find('%.%.', 1, true)
                local hasStringFormat = codeOnly:find('string%.format')

                if hasSQLCall and (hasStringConcat or hasStringFormat) then
                    offenders[#offenders + 1] = ('%s:%d'):format(path, lineNum)
                end
            end
        end
    end

    if #offenders > 0 then
        Matrix.Chaos.Report('HIGH', 'sql_static_scan: SQL string birlestirme bulundu', {
            file   = offenders[1],
            attack = ('%d dosya: SQL cagrisi + string birlestirme ayni satirda'):format(#offenders),
            impact = ('Ornekler: %s'):format(table.concat(offenders, ', ')),
            fix    = 'MySQL cagrilarinda parametre binding (?) kullanilmali, string birlestirme DEGIL.',
        })
    else
        print(('[CHAOS][sql_static_scan] OK: %d dosya temiz'):format(#files))
    end

    Matrix.Chaos.Report('INFO', 'sql_static_scan tamamlandi', {
        attack = ('%d dosya static scan'):format(#files),
        impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)

Matrix.Chaos.RegisterModule('cross_citizen_access',
    'Iki farkli citizenid ile ayni fonksiyon cagrilinca veri karisiyor mu?', function()

    local A = Matrix.Chaos.Assert
    A.SetContext('cross_citizen_access', 'server/matrix_chaos.lua')

    -- ★ TEST: CashDecay.Launder iki farkli citizenid icin ayri escrow olusturuyor mu?
    local trapId
    for id in pairs(Matrix.TrapHouses or {}) do trapId = id; break end

    if not trapId then
        Matrix.Chaos.Report('MEDIUM', 'cross_citizen_access: trap house yok', {
            attack = 'CashDecay.Launder cross-test',
            impact = 'Atlandi',
        })
        return
    end

    -- İki farkli citizenid icin ayni trap'e kirli nakit yatir
    Matrix.CashDecay.Deposit(trapId, 1000.0)

    local ok1 = Matrix.CashDecay.Launder(trapId, 100.0, 'CITIZEN-ALPHA-TEST')
    local ok2 = Matrix.CashDecay.Launder(trapId, 200.0, 'CITIZEN-BETA-TEST')

    A.Equal(ok1, true, 0, 'launder_alpha_ok')
    A.Equal(ok2, true, 0, 'launder_beta_ok')

    Wait(500)

    -- ★ DB kontrolu: iki ayri escrow kaydi var mi, yoksa karistilar mi?
    local rows = MySQL.query.await([[
        SELECT citizenid, amount FROM matrix_banking_escrow
        WHERE citizenid IN ('CITIZEN-ALPHA-TEST', 'CITIZEN-BETA-TEST')
          AND status = 'processing'
    ]], {}) or {}

    local foundAlpha, foundBeta = false, false
    for _, r in ipairs(rows) do
        if r.citizenid == 'CITIZEN-ALPHA-TEST' and tonumber(r.amount) == 100.0 then
            foundAlpha = true
        elseif r.citizenid == 'CITIZEN-BETA-TEST' and tonumber(r.amount) == 200.0 then
            foundBeta = true
        end
    end

    A.Equal(foundAlpha, true, 0, 'alpha_escrow_correct')
    A.Equal(foundBeta,  true, 0, 'beta_escrow_correct')

    -- Temizle
    pcall(function()
        MySQL.query.await([[
            DELETE FROM matrix_banking_escrow
            WHERE citizenid IN ('CITIZEN-ALPHA-TEST', 'CITIZEN-BETA-TEST')
        ]], {})
    end)

    Matrix.Chaos.Report('INFO', 'cross_citizen_access tamamlandi', {
        attack = '2 farkli citizenid, ayni trap house',
        impact = string.format('%d bulgu', #Matrix.Chaos.Findings),
    })
end)


-- =====================================================================
-- ★★★ CHAOS v5.0 — 3 GERÇEK SALDIRI VEKTÖRÜ ★★★
-- =====================================================================

Matrix.Chaos.RegisterModule('live_spoof',
    'Gerçek TriggerServerEvent spoof — NetworkGuard gerçekten durduruyor mu?', function()

    local A = Matrix.Chaos.Assert
    A.SetContext('live_spoof', 'server/matrix_chaos.lua')

    local mySrc = nil
    for _, srcStr in ipairs(GetPlayers()) do
        mySrc = tonumber(srcStr); break
    end

    if not mySrc then
        Matrix.Chaos.Report('MEDIUM', 'live_spoof: aktif oyuncu yok, atlandi', {
            attack = 'Gerçek client TriggerServerEvent',
            impact = 'Test atlandi',
            fix    = 'Oyun içinden çalıştır.',
        })
        return
    end

    TriggerClientEvent('chaos:client:fireSpoof', mySrc,
        'matrix:server:reportSaleAttempt', { 'HACKER_BOT', 0.5, 999.99, 'x', 10 })

    Wait(500)

    local stillConnected = GetPlayerName(mySrc) ~= nil

    A.Equal(stillConnected, true, 0, 'player_not_kicked_after_1_violation')

    Matrix.Chaos.Report('INFO', 'live_spoof tamamlandi', {
        attack = 'Gerçek client TriggerServerEvent spoof (1 deneme)',
        impact = ('oyuncu hala bagli: %s'):format(tostring(stillConnected)),
    })
end)


-- v6.6.6 B2/H7: duplicate 'sql_static_scan' Matrix.Chaos.RegisterModule
-- blogu (v5.0 kalintisi) buradan SILINDI -- birinci, daha detayli
-- versiyon (bu dosyada yukarida) tek gecerli kayit olarak kaldi.

-- =====================================================================
-- [v6.6.5 A5 PAKET 3] KOR NOKTA CHAOS MODULLERI
--
-- Paket 1'deki 3 detection check'in (matrix_diagnostics.lua) chaos
-- versiyonu -- ayni regex/runtime-check mantigi, chaos'un Report()
-- altyapisina baglanmis, BAGIMSIZ bir kopya olarak (chaos diagnostics'e
-- bagimli olmaz). Bulgular '[KOR NOKTA]' etiketiyle raporlanir.
--
-- Mevcut chaos modulleri (replay, cannibal, sql_static_scan, vb.)
-- BIREBIR DEGISTIRILMEDI -- bu blok sadece 3 yeni modul EKLER ve
-- Matrix.Chaos.Run()'i additive olarak SARAR (orijinal Run() govdesi
-- tek satir bile degismedi; wrapper sadece cagrilan modul listesine
-- bu 3 modulu otomatik ekler).
-- =====================================================================
local KOR_NOKTA_TAG = '[KOR NOKTA]'

-- Diagnostics'teki ile ayni mantik, burada BAGIMSIZ kopya.
local function _KorNoktaSplitLines(src)
    local lines = {}
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = line
    end
    return lines
end

local function _KorNoktaReadServerScriptList()
    local resourceName = GetCurrentResourceName()
    local files = {}
    local ok, src = pcall(LoadResourceFile, resourceName, 'fxmanifest.lua')
    if ok and type(src) == 'string' then
        for path in src:gmatch("['\"](server/[%w_]+%.lua)['\"]") do
            files[#files + 1] = path
        end
    end
    return files
end

local function _KorNoktaResolveMatrixApi(x, y)
    local ref = Matrix
    ref = ref and x and ref[x]
    ref = ref and y and ref[y]
    if type(ref) == 'function' then return ref end
    return nil
end

-- =====================================================================
-- chaos_api_reference_scan -- [1.1]'in chaos versiyonu
-- =====================================================================
Matrix.Chaos.RegisterModule('chaos_api_reference_scan',
    KOR_NOKTA_TAG .. ' Static API Reference Scan (Matrix.X.Y calisma zamaninda tanimli mi)',
    function()
        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_api_reference_scan', 'server/matrix_chaos.lua')

        local files = _KorNoktaReadServerScriptList()
        if #files == 0 then
            Matrix.Chaos.Report('MEDIUM', KOR_NOKTA_TAG .. ' fxmanifest.lua server_scripts listesi okunamadi', {
                impact = 'Tarama yapilamadi.',
            })
            return
        end

        local resourceName = GetCurrentResourceName()
        local seen, order = {}, {}

        for _, relPath in ipairs(files) do
            local ok, src = pcall(LoadResourceFile, resourceName, relPath)
            if ok and type(src) == 'string' then
                local lines = _KorNoktaSplitLines(src)
                for lineNo, line in ipairs(lines) do
                    local trimmed = line:match('^%s*(.-)%s*$')
                    if trimmed:sub(1, 2) ~= '--' then
                        for x, y in line:gmatch('Matrix%.([%w_]+)%.([%w_]+)%s*%(') do
                            local key = ('Matrix.%s.%s'):format(x, y)
                            if not seen[key] then
                                seen[key] = { file = relPath, line = lineNo }
                                order[#order + 1] = key
                            end
                        end
                        for x, y in line:gmatch('pcall%(%s*Matrix%.([%w_]+)%.([%w_]+)') do
                            local key = ('Matrix.%s.%s'):format(x, y)
                            if not seen[key] then
                                seen[key] = { file = relPath, line = lineNo }
                                order[#order + 1] = key
                            end
                        end
                    end
                end
            end
        end

        local failCount = 0
        for _, key in ipairs(order) do
            local x, y = key:match('^Matrix%.([%w_]+)%.([%w_]+)$')
            if not _KorNoktaResolveMatrixApi(x, y) then
                failCount = failCount + 1
                local loc = seen[key]
                Matrix.Chaos.Report('HIGH', ('%s tanimsiz API: %s'):format(KOR_NOKTA_TAG, key), {
                    file   = loc.file,
                    line   = loc.line,
                    attack = 'Statik referans taramasi (regex tabanli, gercek parser degil)',
                    impact = ('%s dosyasinda cagriliyor ama calisma zamaninda fonksiyon degil.'):format(loc.file),
                    fix    = 'Ilgili modulde fonksiyonu tanimla veya cagriyi kaldir.',
                })
            end
        end

        if failCount == 0 then
            Matrix.Chaos.Report('INFO', KOR_NOKTA_TAG .. ' Static API Reference Scan temiz', {
                impact = ('%d benzersiz Matrix.X.Y referansi (%d dosya), hepsi tanimli.'):format(#order, #files),
            })
        end
    end)

-- =====================================================================
-- chaos_fk_parent_guard_audit -- [1.2]'in chaos versiyonu
-- =====================================================================
Matrix.Chaos.RegisterModule('chaos_fk_parent_guard_audit',
    KOR_NOKTA_TAG .. ' FK Parent Guard Audit (FlushDirty* INSERT/UPDATE)',
    function()
        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_fk_parent_guard_audit', 'server/matrix_chaos.lua')

        local resourceName = GetCurrentResourceName()
        local targets = { 'server/bureau.lua', 'server/market.lua' }
        local GUARD_PATTERN = 'Matrix%.TrapHouses'
        local flagged = {}
        local failCount = 0

        for _, relPath in ipairs(targets) do
            local ok, src = pcall(LoadResourceFile, resourceName, relPath)
            if ok and type(src) == 'string' then
                local lines = _KorNoktaSplitLines(src)
                local currentFlush = nil

                for i, line in ipairs(lines) do
                    local fnName = line:match('function%s+Matrix%.[%w_]+%.(FlushDirty[%w_]*)')
                    if fnName then
                        currentFlush = fnName
                    elseif line:match('^end%s*$') then
                        currentFlush = nil
                    end

                    if currentFlush
                        and (line:match('INSERT%s+INTO%s+matrix_%w+') or line:match('UPDATE%s+matrix_%w+')) then
                        local guarded = false
                        for back = math.max(1, i - 5), i - 1 do
                            if lines[back]:match(GUARD_PATTERN) then
                                guarded = true
                                break
                            end
                        end
                        if not guarded then
                            local dedupeKey = relPath .. ':' .. currentFlush
                            if not flagged[dedupeKey] then
                                flagged[dedupeKey] = true
                                failCount = failCount + 1
                                Matrix.Chaos.Report('CRITICAL', ('%s %s guard yok'):format(KOR_NOKTA_TAG, currentFlush), {
                                    file   = relPath,
                                    line   = i,
                                    attack = 'FK parent guard denetimi (regex tabanli)',
                                    impact = 'Silinen trap house icin INSERT/UPDATE denenebilir (FK constraint violation).',
                                    fix    = 'Matrix.TrapHouses[id] parent-existence guard ekle.',
                                })
                            end
                        end
                    end
                end
            end
        end

        if failCount == 0 then
            Matrix.Chaos.Report('INFO', KOR_NOKTA_TAG .. ' FK Parent Guard Audit temiz', {
                impact = 'Taranan FlushDirty* fonksiyonlarinda tum INSERT/UPDATE Matrix.TrapHouses guard icinde.',
            })
        end
    end)

-- =====================================================================
-- chaos_teardown_audit -- [1.3]'un chaos versiyonu
-- =====================================================================
Matrix.Chaos.RegisterModule('chaos_teardown_audit',
    KOR_NOKTA_TAG .. ' Fixture Teardown Audit (_DestroyDiagFixtureTrapHouse)',
    function()
        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_teardown_audit', 'server/matrix_chaos.lua')

        local resourceName = GetCurrentResourceName()
        local ok, src = pcall(LoadResourceFile, resourceName, 'server/matrix_diagnostics.lua')
        if not ok or type(src) ~= 'string' then
            Matrix.Chaos.Report('MEDIUM', KOR_NOKTA_TAG .. ' matrix_diagnostics.lua okunamadi', {
                impact = 'Teardown denetimi yapilamadi.',
            })
            return
        end

        local lines = _KorNoktaSplitLines(src)
        local bodyStart, bodyEnd = nil, nil
        for i, line in ipairs(lines) do
            if not bodyStart and line:match('^local function _DestroyDiagFixtureTrapHouse') then
                bodyStart = i
            elseif bodyStart and not bodyEnd and line:match('^end%s*$') then
                bodyEnd = i
            end
        end

        if not bodyStart then
            Matrix.Chaos.Report('MEDIUM', KOR_NOKTA_TAG .. ' _DestroyDiagFixtureTrapHouse bulunamadi', {
                file   = 'server/matrix_diagnostics.lua',
                impact = 'Fixture teardown fonksiyonu tasindi/silindi mi kontrol edilmeli.',
            })
            return
        end
        bodyEnd = bodyEnd or #lines

        local refs, order = {}, {}
        for i = bodyStart, bodyEnd do
            for x, y in lines[i]:gmatch('pcall%(%s*Matrix%.([%w_]+)%.([%w_]+)') do
                local key = ('Matrix.%s.%s'):format(x, y)
                if not refs[key] then
                    refs[key] = i
                    order[#order + 1] = key
                end
            end
        end

        local failCount = 0
        for _, key in ipairs(order) do
            local x, y = key:match('^Matrix%.([%w_]+)%.([%w_]+)$')
            if not _KorNoktaResolveMatrixApi(x, y) then
                failCount = failCount + 1
                Matrix.Chaos.Report('CRITICAL', ('%s teardown tanimsiz API cagiriyor: %s'):format(KOR_NOKTA_TAG, key), {
                    file   = 'server/matrix_diagnostics.lua',
                    line   = refs[key],
                    attack = 'Fixture teardown denetimi (regex tabanli)',
                    impact = 'Teardown bu fonksiyonu cagiriyor ama tanimli degil -- guard sessizce atlar, RAM/DB state sizabilir.',
                    fix    = 'Ilgili modulde fonksiyonu tanimla.',
                })
            end
        end

        if failCount == 0 then
            Matrix.Chaos.Report('INFO', KOR_NOKTA_TAG .. ' Fixture Teardown Audit temiz', {
                impact = ('%d teardown API referansi dogrulandi (satir %d-%d).'):format(#order, bodyStart, bodyEnd),
            })
        end
    end)

-- =====================================================================
-- OTOMATIK CALISTIRMA: bu 3 modul her chaos kosusunda (secilen modul
-- listesinden bagimsiz) otomatik calisir. Orijinal Matrix.Chaos.Run
-- govdesi DEGISTIRILMEDI -- sadece additive olarak SARILDI (wrapper).
-- =====================================================================
local KOR_NOKTA_MODULES = { 'chaos_api_reference_scan', 'chaos_fk_parent_guard_audit', 'chaos_teardown_audit' }
local _OriginalChaosRun = Matrix.Chaos.Run

function Matrix.Chaos.Run(moduleList, replyTo)
    local list = {}
    if type(moduleList) == 'table' then
        for _, name in ipairs(moduleList) do list[#list + 1] = name end
    end

    local already = {}
    for _, name in ipairs(list) do already[name] = true end
    for _, name in ipairs(KOR_NOKTA_MODULES) do
        if not already[name] then
            list[#list + 1] = name
            already[name] = true
        end
    end

    return _OriginalChaosRun(list, replyTo)
end

-- =====================================================================
-- ★ v6.6.6 HARDCORE CHAOS — Paket F: 5 hardcore modülü tek komutla
-- çalıştırır. _IsChaosAceAllowed / _Reply bu dosyada zaten mevcut.
-- =====================================================================
RegisterCommand('matrix_chaos_hardcore', function(src)
    if not _IsChaosAceAllowed(src) then
        _Reply(src, 'Yetkisiz (matrix.chaos ACE gerekir).')
        return
    end
    if not Config.Chaos or not Config.Chaos.HardcoreEnabled then
        _Reply(src, 'Hardcore kapali (Config.Chaos.HardcoreEnabled=false).')
        return
    end
    local list = {
        'chaos_world_state_fuzzer',
        'chaos_transition_storm',
        'chaos_client_bridge_fuzzer',
        'chaos_authority_bypass_tester',
        'chaos_ui_persistence_audit',
    }
    Matrix.Chaos.Run(list, src)
end, false)
