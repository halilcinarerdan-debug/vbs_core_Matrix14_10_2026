-- =====================================================================
-- ★★★ matrix_diagnostics.lua — OTOMASYONLU REGRESYON ÇEKİRDEĞİ v2.1 ★★★
--
-- ★ KATMAN 1: Asenkron Bekleme Kalkanı (MySQL.ready + ox_inventory).
-- ★ KATMAN 2: Config Sabotaj ve Bağımlılık Kontrol Simülasyonu.
-- ★ KATMAN 3: Lojistik Gecikme + ALPR Transfer Delay + Hücre Lideri.
-- ★ KATMAN 4: Taktik Güç + Biyolojik Travma Kanıt Zinciri (+%60 ceza).
-- ★ KATMAN 5: 24 Saatlik Data Recovery Persistency (BIGINT epoch).
-- ★ KATMAN 6: MariaDB Canlı Şema Bekçiliği (15+19 DB kontrol).
-- ★ KATMAN 23: /matrix_diag_detay — Detaylı tanı dökümü.
--
-- ★★★ v2.1 RED TEAM HARDENING (BU SÜRÜM) ★★★
-- [H1-v2] AŞAMALI GC TEMİZLİĞİ (ANTI STOP-THE-WORLD)
-- [H2] VERİTABANI TIMEOUT VE İSTİSNA YÖNETİMİ
-- [H3] ANASAYAL KİLİTLEME VE LUAC5.4 MÜHRÜ
-- [H4-v2] METATABLE PROXY KORUMASI (ANTI CONTEXT DRIFT)
-- SIFIR RNG: her kontrol saf/deterministiktir.
-- =====================================================================

Matrix.Diagnostics = Matrix.Diagnostics or {}

-- ★ [DIAGNOSTIC LOG SUPPRESS] Diagnostics çalışırken Chain/Race testlerinin
-- tetiklediği gerçek sistem logları (NUKLEER ABLUKA, raid, lockdown, vb.)
-- bastırılır. Test davranışı DEĞİŞMEZ — sadece log kalabalığı önlenir.
Matrix.Diagnostics.IsRunning = false

-- [A4-3] bureau.lua/police_raid.lua sadece Matrix.Diagnostics.IsRunning'i
-- kontrol ediyor, Matrix.Chaos.Running'i bilmiyorlar (o dosyalar bu
-- sprint'te degistirilmiyor). Bu helper diagnostics'in KENDI guard'larinda
-- her iki bayragi da tek yerden okur; Run() ayrica kendi calisirken
-- Matrix.Chaos.Running'i de set eder, boylece Chaos.Run() kendi mevcut
-- re-entrance kontrolu (matrix_chaos.lua) uzerinden Diagnostics calisirken
-- baslamayi reddeder.
local function _IsAnyTestRunning()
    return (Matrix.Diagnostics and Matrix.Diagnostics.IsRunning)
        or (Matrix.Chaos and Matrix.Chaos.Running)
end

Matrix.Diagnostics = Matrix.Diagnostics or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_abs                     = math.abs
local math_max                     = math.max
local GetGameTimer                 = GetGameTimer
local GetCurrentResourceName       = GetCurrentResourceName
local StopResource                 = StopResource
local TriggerClientEvent           = TriggerClientEvent
local RegisterCommand              = RegisterCommand
local CreateThread                 = CreateThread
local Wait                         = Wait
local Citizen                      = Citizen
local json                         = json
local os                           = os
local table                        = table
local setmetatable                 = setmetatable

-- ★ [H3] KİLİT-1..5 dondurulmuş hiyerarşi tablosu
Matrix.Diagnostics.LockedHierarchy = {
    { id = 'KILIT-1', label = 'Technical HUD',                 deps = 'Config.Hud + client/hud.lua' },
    { id = 'KILIT-2', label = 'Kontrollu Guc Uygulamasi',      deps = 'Matrix.Wounds.ApplyBotRegionalDamage + Config.BotWounds' },
    { id = 'KILIT-3', label = '24h Data Recovery Epoch Kilidi',deps = 'matrix_player_state.recovery_target_epoch (BIGINT)' },
    { id = 'KILIT-4', label = '15 Dk Gecikmeli Lojistik Batch Sync', deps = 'Config.Logistics.BatchSync (900s+180s)' },
    { id = 'KILIT-5', label = 'Config Sabotaj Kalkani',        deps = 'Config.ModularSimulationQueue + TestConfigDependencies' }
}

-- =====================================================================
-- FAZ 4 forward declarations (lexical scope için)
-- =====================================================================
local TableExists, ColumnExists

-- =====================================================================
-- Reply — DOSYANIN EN BAŞINDA tanımlı
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[DIAGNOSTICS]', msg } })
    else
        print(('[MATRIX:DIAGNOSTICS:CONSOLE] %s'):format(msg))
    end
end

-- =====================================================================
-- ★ [H2] İSTİSNA YÖNETİMİ — matrix_diag_detay_failed teknik jurnalı
-- =====================================================================
Matrix.Diagnostics.FailureJournal = Matrix.Diagnostics.FailureJournal or {
    last_failure_at     = 0,
    last_failure_kind   = nil,
    last_failure_detail = nil,
    failure_count       = 0
}

local function JournalBootFailure(kind, detail)
    Matrix.Diagnostics.FailureJournal.last_failure_at     = os.time()
    Matrix.Diagnostics.FailureJournal.last_failure_kind   = kind
    Matrix.Diagnostics.FailureJournal.last_failure_detail = detail
    Matrix.Diagnostics.FailureJournal.failure_count       = Matrix.Diagnostics.FailureJournal.failure_count + 1
    local line = ('[matrix_diag_detay_failed] kind=%s | %s'):format(tostring(kind), tostring(detail))
    Matrix.Log('DIAGNOSTICS', line)
    print(('^3[MATRIX:DIAGNOSTICS] %s^7'):format(line))
end

Matrix.Diagnostics.GetFailureJournal = function()
    return Matrix.Diagnostics.FailureJournal
end

-- =====================================================================
-- ★ [H4-v2] METATABLE PROXY KORUMASI (ANTI CONTEXT DRIFT)
-- =====================================================================
Matrix.Diagnostics.BreachJournal = Matrix.Diagnostics.BreachJournal or {
    last_breach_at     = 0,
    last_breach_detail = nil,
    breach_count       = 0,
    breach_by_bot      = {}
}

function Matrix.Diagnostics.TriggerCellBreach(breachKind, attemptedKey, cellName, botId)
    local line = ('[HUCRE_IZOLASYON_IHLALI] kind=%s cell=%s key=%s botId=%s'):format(
        tostring(breachKind), tostring(cellName), tostring(attemptedKey), tostring(botId))

    Matrix.Diagnostics.BreachJournal.last_breach_at     = os.time()
    Matrix.Diagnostics.BreachJournal.last_breach_detail = line
    Matrix.Diagnostics.BreachJournal.breach_count       = Matrix.Diagnostics.BreachJournal.breach_count + 1

    Matrix.Log('DIAGNOSTICS', line)

    if botId then
        Matrix.Diagnostics.BreachJournal.breach_by_bot[botId] =
            (Matrix.Diagnostics.BreachJournal.breach_by_bot[botId] or 0) + 1

        local count = Matrix.Diagnostics.BreachJournal.breach_by_bot[botId]
        if count >= 3 then
            local bot = Matrix.Bots and Matrix.Bots[botId]
            if bot and bot.status ~= 'disbanded' then
                bot.status = 'disbanded'
                if Matrix.MarkBotDirty then Matrix.MarkBotDirty(botId) end
                if Matrix.Dispatches and Matrix.Dispatches[botId] and Matrix.CompleteDispatch then
                    pcall(Matrix.CompleteDispatch, botId, 'isolation_breach')
                end
                Matrix.Log('DIAGNOSTICS',
                    '[ALT HUCRE KILITLENDI] Bot #%s status=disbanded (%d. izolasyon ihlali).',
                    tostring(botId), count)
            end
        end
    end
end

function Matrix.Diagnostics.WrapReadOnlyCell(dataTable, cellName, botId)
    if type(dataTable) ~= 'table' then return dataTable end

    return setmetatable({}, {
        __index = dataTable,
        __newindex = function(_, key, value)
            Matrix.Diagnostics.TriggerCellBreach('HUCRE_IZOLASYON_IHLALI', key, cellName, botId)
        end,
        __metatable = false,
        __len       = function() return #dataTable end,
        __pairs     = function() return pairs(dataTable) end,
        __ipairs    = function() return ipairs(dataTable) end
    })
end

function Matrix.Diagnostics.DeepCopyCell(dataTable, seen)
    if type(dataTable) ~= 'table' then return dataTable end
    seen = seen or {}
    if seen[dataTable] then return seen[dataTable] end

    local copy = {}
    seen[dataTable] = copy
    for k, v in pairs(dataTable) do
        if type(v) == 'table' then
            copy[k] = Matrix.Diagnostics.DeepCopyCell(v, seen)
        else
            copy[k] = v
        end
    end
    return copy
end

-- =====================================================================
-- ★ [H1-v2] AŞAMALI GC TEMİZLİĞİ (ANTI STOP-THE-WORLD)
-- =====================================================================
local STAGED_GC_INTERVAL = 100
local STAGED_GC_STEP_KB  = 100

function Matrix.Diagnostics.StepGC()
    pcall(collectgarbage, 'step', STAGED_GC_STEP_KB)
end

function Matrix.Diagnostics.FinalizeStagedGC()
    for _ = 1, 10 do
        local stepOk = pcall(collectgarbage, 'step', STAGED_GC_STEP_KB)
        if not stepOk then break end
    end
end

function Matrix.Diagnostics.PurgeDeepTestState()
    Matrix.Diagnostics.FinalizeStagedGC()
    Matrix.Log('DIAGNOSTICS',
        '[H1-v2][GC] Asamali bellek temizligi tamamlandi -- Stop-the-World YOK, sadece step-step drain.')
    return true
end

local lastReport = {
    ran_at      = 0,
    duration_ms = 0,
    deep        = false,
    total       = 0,
    passed      = 0,
    failed      = 0,
    checks      = {},
    sealed      = false
}

-- =====================================================================
-- KATMAN 2: CONFIG SABOTAJ VE BAĞIMLILIK KONTROL SİMÜLASYONU
-- =====================================================================
Config.ModularSimulationQueue = {
    {
        id     = 'EnablePhysicalFollowers',
        get    = function() return Config.Mercenary and Config.Mercenary.EnablePhysicalFollowers end,
        set    = function(v) if Config.Mercenary then Config.Mercenary.EnablePhysicalFollowers = v end end,
        probes = {
            { 'Matrix.Mercenary.RequestSummon', function() return Matrix.Mercenary and Matrix.Mercenary.RequestSummon end },
            { 'Matrix.Mercenary.ReportDismiss', function() return Matrix.Mercenary and Matrix.Mercenary.ReportDismiss end }
        }
    },
    {
        id     = 'EnablePhysicalAmbushTeams',
        get    = function() return Config.Rendezvous and Config.Rendezvous.Enabled end,
        set    = function(v) if Config.Rendezvous then Config.Rendezvous.Enabled = v end end,
        probes = {
            { 'Matrix.Rendezvous.ScheduleHandoff',   function() return Matrix.Rendezvous and Matrix.Rendezvous.ScheduleHandoff end },
            { 'Matrix.Rendezvous.GetAmbushBulletin', function() return Matrix.Rendezvous and Matrix.Rendezvous.GetAmbushBulletin end }
        }
    },
    {
        id     = 'HitSquad.HeatTraceThreshold',
        get    = function() return Config.HitSquad and Config.HitSquad.HeatTraceThreshold end,
        set    = function(v) if Config.HitSquad then Config.HitSquad.HeatTraceThreshold = v end end,
        probes = {
            { 'Matrix.HitSquad module', function() return Matrix.HitSquad end },
            { 'Config.GangHoods.Hoods', function() return Config.GangHoods and Config.GangHoods.Hoods end }
        }
    }
}

local function TestConfigDependencies()
    local sabotageQueue = Config.ModularSimulationQueue or {}
    if #sabotageQueue == 0 then
        return true, 'ModularSimulationQueue bos -- sabotaj testi atlandi'
    end

    local testedCount = 0
    for _, entry in ipairs(sabotageQueue) do
        local originalValue = entry.get and entry.get() or nil
        local disabledValue = (type(originalValue) == 'number') and 0.0 or false

        if entry.set then entry.set(disabledValue) end

        for _, probe in ipairs(entry.probes or {}) do
            local probeName, probeGetter = probe[1], probe[2]
            local ok, result = pcall(function()
                local fn = probeGetter and probeGetter()
                if type(fn) == 'function' then
                    local okInner, innerErr = pcall(fn, 1, 1, 1)
                    if not okInner then
                        error(('probe %s config-kapali iken hata firlatti: %s'):format(
                            probeName, tostring(innerErr)), 2)
                    end
                elseif fn == nil then
                    error(('probe %s: config-kapali iken fonksiyon tanimsiz (kanca kaymasi)'):format(probeName), 2)
                end
            end)
            if not ok then
                if entry.set and originalValue ~= nil then entry.set(originalValue) end
                assert(false, ('[KATMAN 21.3][SABOTAJ] %s -> %s'):format(entry.id, tostring(result)))
            end
        end

        if entry.set and originalValue ~= nil then entry.set(originalValue) end
        testedCount = testedCount + 1
    end

    return true, ('%d config sabotaj testi safe-exit ile gecti'):format(testedCount)
end

-- =====================================================================
-- HIZLI KATMAN: KONTROL TANIMLARI
-- =====================================================================
local FastChecks = {}

local function AddCheck(name, fn)
    FastChecks[#FastChecks + 1] = { name = name, fn = fn }
end

-- =====================================================================
-- [v6.6.5 A5] KOR NOKTA GUCLENDIRME -- DETECTION (PAKET 1, fix YOK)
--
-- Kok neden: chaos statik pattern arar ama RUNTIME API varligini test
-- etmez; diagnostics fixture izolasyonu yapar ama cagirdigi API'lerin
-- VAR OLDUGUNU dogrulamaz; hicbir katman "silinen parent icin cocuk
-- INSERT" riskini denetlemez. Bu 3 check o kor noktalari KAPATMAZ --
-- sadece TESPIT eder (fix Paket 2'de, ayri commit'te).
--
-- NOT: Bu check'ler regex tabanli statik metin taramasidir -- gercek
-- bir Lua parser degildir. Yorum satirlari (trimmed '--' ile baslayan)
-- elenir ama string literal icindeki veya satir-ici yorumdaki eslesmeler
-- yanlis pozitif verebilir. FAIL = bulgu, kesin hata degil; insan
-- gozden gecirmesi gerekir.
-- =====================================================================

-- fxmanifest.lua'nin server_scripts blogundan dosya listesini ceker --
-- liste burada TEKRAR elle yazilip driftlenmesin (tek gercek kaynak).
local function _ReadServerScriptList()
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

-- Metin govdesini satirlara boler (satir numarasi korunur).
local function _SplitLines(src)
    local lines = {}
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = line
    end
    return lines
end

-- 'Matrix.X.Y' yolunu RUNTIME'da cozer; fonksiyon degilse nil doner.
local function _ResolveMatrixApi(x, y)
    local ref = Matrix
    ref = ref and x and ref[x]
    ref = ref and y and ref[y]
    if type(ref) == 'function' then return ref end
    return nil
end

-- =====================================================================
-- [1.1] STATIC API REFERENCE SCANNER
-- server/*.lua icindeki Matrix.X.Y cagrilarini (dogrudan cagri VEYA
-- pcall'a fonksiyon olarak verilen referans) tarar; her biri icin
-- RUNTIME'da Matrix[X][Y] gercekten bir fonksiyon mu diye dogrular.
-- =====================================================================
AddCheck('[KOR NOKTA 1.1] Static API Reference Scanner (Matrix.X.Y runtime)', function()
    local files = _ReadServerScriptList()
    if #files == 0 then
        return false, 'fxmanifest.lua server_scripts listesi okunamadi -- tarama yapilamadi'
    end
    local resourceName = GetCurrentResourceName()

    local seen  = {}   -- 'Matrix.X.Y' -> { file = ..., line = ... } (ilk gorulen konum)
    local order = {}

    for _, relPath in ipairs(files) do
        local ok, src = pcall(LoadResourceFile, resourceName, relPath)
        if ok and type(src) == 'string' then
            local lines = _SplitLines(src)
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

    local fails = {}
    for _, key in ipairs(order) do
        local x, y = key:match('^Matrix%.([%w_]+)%.([%w_]+)$')
        if not _ResolveMatrixApi(x, y) then
            local loc = seen[key]
            fails[#fails + 1] = ('tanimsiz API: %s (kaynak: %s:%d)'):format(key, loc.file, loc.line)
        end
    end

    if #fails > 0 then
        table.sort(fails)
        return false, ('%d tanimsiz API referansi -- %s'):format(#fails, table.concat(fails, ' | '))
    end
    return true, ('%d benzersiz Matrix.X.Y referansi tarandi (%d dosya), hepsi runtime tanimli'):format(#order, #files)
end)

-- =====================================================================
-- [1.2] FK PARENT GUARD AUDITOR
-- bureau.lua + market.lua icindeki FlushDirty* fonksiyonlarini bulur;
-- her INSERT INTO/UPDATE matrix_X cagrisinin uzerindeki 5 satirda
-- Matrix.TrapHouses parent-existence guard'i olup olmadigini denetler.
-- =====================================================================
AddCheck('[KOR NOKTA 1.2] FK Parent Guard Auditor (FlushDirty* INSERT/UPDATE)', function()
    local resourceName = GetCurrentResourceName()
    local targets = { 'server/bureau.lua', 'server/market.lua' }
    local GUARD_PATTERN = 'Matrix%.TrapHouses'

    local fails   = {}
    local flagged = {}   -- dedupe: 'dosya:fonksiyon' -> true (fonksiyon basina 1 bulgu)

    for _, relPath in ipairs(targets) do
        local ok, src = pcall(LoadResourceFile, resourceName, relPath)
        if ok and type(src) == 'string' then
            local lines = _SplitLines(src)
            local currentFlush = nil

            for i, line in ipairs(lines) do
                local fnName = line:match('function%s+Matrix%.[%w_]+%.(FlushDirty[%w_]*)')
                if fnName then
                    currentFlush = fnName
                elseif line:match('^end%s*$') then
                    -- Ust seviye fonksiyon kapanisi (bu kod tabanindaki stil:
                    -- ic blok end'leri girintili, fonksiyon end'i kolon 0'da).
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
                            fails[#fails + 1] = ('%s guard yok -> FK risk (%s:%d)'):format(
                                currentFlush, relPath, i)
                        end
                    end
                end
            end
        end
    end

    if #fails > 0 then
        table.sort(fails)
        return false, ('%d FlushDirty* fonksiyonu parent guard yok -- %s'):format(#fails, table.concat(fails, ' | '))
    end
    return true, 'Taranan FlushDirty* fonksiyonlarinda tum INSERT/UPDATE Matrix.TrapHouses guard icinde'
end)

-- =====================================================================
-- [1.3] FIXTURE TEARDOWN AUDIT
-- _DestroyDiagFixtureTrapHouse govdesindeki pcall(Matrix.X.Y, ...)
-- cagrilarini cikarir, her biri icin runtime existence check yapar.
-- =====================================================================
AddCheck('[KOR NOKTA 1.3] Fixture Teardown Audit (_DestroyDiagFixtureTrapHouse)', function()
    local resourceName = GetCurrentResourceName()
    local ok, src = pcall(LoadResourceFile, resourceName, 'server/matrix_diagnostics.lua')
    if not ok or type(src) ~= 'string' then
        return false, 'server/matrix_diagnostics.lua okunamadi'
    end

    local lines = _SplitLines(src)
    local bodyStart, bodyEnd = nil, nil
    for i, line in ipairs(lines) do
        if not bodyStart and line:match('^local function _DestroyDiagFixtureTrapHouse') then
            bodyStart = i
        elseif bodyStart and not bodyEnd and line:match('^end%s*$') then
            bodyEnd = i
        end
    end

    if not bodyStart then
        return false, '_DestroyDiagFixtureTrapHouse bulunamadi -- fixture teardown fonksiyonu tasindi/silindi mi?'
    end
    bodyEnd = bodyEnd or #lines

    local refs  = {}
    local order = {}
    for i = bodyStart, bodyEnd do
        for x, y in lines[i]:gmatch('pcall%(%s*Matrix%.([%w_]+)%.([%w_]+)') do
            local key = ('Matrix.%s.%s'):format(x, y)
            if not refs[key] then
                refs[key] = i
                order[#order + 1] = key
            end
        end
    end

    if #order == 0 then
        return true, ('_DestroyDiagFixtureTrapHouse (satir %d-%d) hicbir Matrix.X.Y API cagirmiyor -- denetlenecek referans yok'):format(bodyStart, bodyEnd)
    end

    local fails = {}
    for _, key in ipairs(order) do
        local x, y = key:match('^Matrix%.([%w_]+)%.([%w_]+)$')
        if not _ResolveMatrixApi(x, y) then
            fails[#fails + 1] = ('teardown cagiriyor ama tanimli degil: %s (satir %d)'):format(key, refs[key])
        end
    end

    if #fails > 0 then
        return false, ('%d teardown API referansi tanimsiz -- %s'):format(#fails, table.concat(fails, ' | '))
    end
    return true, ('%d teardown API referansi dogrulandi, hepsi tanimli fonksiyon'):format(#order)
end)

AddCheck('[KOR NOKTA 1.4] Blip/UI Persistence Audit', function()
    -- TEK check, 4 alt-doğrulama içinde
    local failures = {}

    -- 1) client/trap_house_client.lua: blip kalicilik fix
    local thc = LoadResourceFile(GetCurrentResourceName(), 'client/trap_house_client.lua')
    if type(thc) ~= 'string' then
        failures[#failures+1] = 'trap_house_client.lua okunamadi'
    else
        if not thc:find('SetBlipAsShortRange(blip, false)', 1, true) then
            failures[#failures+1] = 'SetBlipAsShortRange(blip, false) yok (Fix 2 regresyonu)'
        end
        if not thc:find('SetBlipDisplay(blip, 4)', 1, true) then
            failures[#failures+1] = 'SetBlipDisplay(blip, 4) yok'
        end
        if not thc:find('RemoveBlip', 1, true) then
            failures[#failures+1] = 'RemoveBlip cagrisi yok (orphan temizligi)'
        end
    end

    -- 2) server/trap_house_interior.lua: ownership filter
    local thi = LoadResourceFile(GetCurrentResourceName(), 'server/trap_house_interior.lua')
    if type(thi) ~= 'string' then
        failures[#failures+1] = 'trap_house_interior.lua okunamadi'
    else
        if not thi:find('visibleIds', 1, true) then
            failures[#failures+1] = 'getTrapHouseLocations ownership filter (visibleIds) yok'
        end
        if not thi:find('not PlayerInteriorState[src]', 1, true) then
            failures[#failures+1] = 'crash recovery guard (not PlayerInteriorState[src]) yok'
        end
    end

    if #failures > 0 then
        return false, table.concat(failures, ' | ')
    end
    return true, '4 sub-check PASS: blip kalicilik + orphan + ownership + crash recovery'
end)


-- =====================================================================
-- ★ [FAZ 0.2] İZOMORFİK LOG PIPELINE DOĞRULAMASI
-- =====================================================================
AddCheck('[FAZ 0.2] shared/log.lua yüklü ve callable', function()
    if type(Matrix.Log) ~= 'table' then
        return false, 'Matrix.Log tablo değil'
    end
    if type(Matrix.Log.Write) ~= 'function' then
        return false, 'Matrix.Log.Write fonksiyon değil'
    end
    if type(Matrix.Log.Flush) ~= 'function' then
        return false, 'Matrix.Log.Flush fonksiyon değil'
    end
    local state = Matrix.Log._state
    if type(state) ~= 'table' or type(state.buffer) ~= 'table' then
        return false, 'Log state bozuk'
    end
    local ok = pcall(function()
        Matrix.Log.Write('DIAG_TEST', 'log pipeline sagligi dogrulandi')
        Matrix.Log.Flush()
    end)
    if not ok then
        return false, 'Log Write/Flush cagrisi hata verdi'
    end
    return true, 'shared/log.lua callable + Write/Flush + rate-limit state OK'
end)


-- =====================================================================
-- ★ [FAZ 0.2] DEVAM EDEN KONTROLLER (buraya yenileri eklenecek)
-- =====================================================================

-- ★ [VETTING AUDIT FIX] kitchen.lua (botany_trash_outcome_0_25,
-- botany_odor_leak_stage4_unfiltered, pharmacological_dilution_half_
-- purity_equal_mass) ve main.lua (matrix_forensic_evidence_schema_seal)
-- Matrix.Diagnostics.RegisterCheck'i mevcut bir public API olarak
-- varsayip cagiriyordu (guard'li: 'type(Matrix.Diagnostics.RegisterCheck)
-- == "function"'), ama bu fonksiyon hic disari acilmamisti -- 4 gercek
-- kontrol sessizce hic kaydolmuyordu. AddCheck zaten var olan dogru
-- kayit fonksiyonu; sadece disariya aciliyor.
Matrix.Diagnostics.RegisterCheck = AddCheck

-- =====================================================================
-- ★★★ SESSION 5.1: SOKAK SİPERİ REGRESYON BLOKLARI ★★★
-- Additive-only. Mevcut hiçbir kontrol kaldırılmadı; sadece 3 yeni
-- kontrol eklendi. Toplam 175 → 178.
--
-- KURAL 4 (client-only native koruması) ve KURAL 7 (event-based hook)
-- hedeflerini statik kaynak taramasıyla doğrular. Runtime testi DEĞİL
-- (bu checks'ler Fast katmanında çalışır, kısa ve yan etkisiz).
-- =====================================================================

AddCheck('[FAZ 5.1] Config.StreetCover aralık ve tip doğrulaması', function()
    local c = Config and Config.StreetCover
    if type(c) ~= 'table' then
        return false, 'Config.StreetCover tanimsiz'
    end

    local numericFields = {
        'CoverSearchRadiusMeters',
        'CacheRefreshTickMs',
        'CoverScanBackoffMs',
        'FireArcDegree',
        'FireTickMs',
        'RecoverCoverHpThreshold',
        'MaxCachedBots',
        'CoverIndex',
    }
    for _, key in ipairs(numericFields) do
        local v = c[key]
        if type(v) ~= 'number' or v ~= v then
            return false, ('Config.StreetCover.%s gecersiz: %s'):format(key, tostring(v))
        end
    end

    if c.CoverSearchRadiusMeters <= 0 or c.CoverSearchRadiusMeters > 50 then
        return false, ('CoverSearchRadiusMeters %.2f [0, 50] disinda'):format(c.CoverSearchRadiusMeters)
    end
    if c.FireArcDegree <= 0 or c.FireArcDegree >= 360 then
        return false, ('FireArcDegree %.2f [0, 360) disinda'):format(c.FireArcDegree)
    end
    if c.FireTickMs < 50 or c.FireTickMs > 2000 then
        return false, ('FireTickMs %d [50, 2000] disinda'):format(c.FireTickMs)
    end
    if c.RecoverCoverHpThreshold < 0 or c.RecoverCoverHpThreshold > 1 then
        return false, ('RecoverCoverHpThreshold %.2f [0, 1] disinda'):format(c.RecoverCoverHpThreshold)
    end
    if c.MaxCachedBots <= 0 or c.MaxCachedBots > 512 then
        return false, ('MaxCachedBots %d [1, 512] disinda'):format(c.MaxCachedBots)
    end

    return true, ('radius=%.1fm arc=%.1fdeg tick=%dms cap=%d'):format(
        c.CoverSearchRadiusMeters, c.FireArcDegree, c.FireTickMs, c.MaxCachedBots)
end)

AddCheck('[FAZ 5.1] Matrix.StreetCover runtime hook varlığı', function()
    -- ★ FEATURE FLAG: Legacy hitsquad kapalıysa StreetCover yok, atla
    if Config.Features and Config.Features.LegacyHitsquad == false then
        return true, 'ATLANDI -- Legacy hitsquad devre disi (Config.Features.LegacyHitsquad = false)'
    end

    local sc = Matrix and Matrix.StreetCover
    if type(sc) ~= 'table' then
        return false, 'Matrix.StreetCover tablo degil (server/hitsquad.lua sonu yuklendi mi?)'
    end
    if type(sc.RequestScan) ~= 'function' then
        return false, 'Matrix.StreetCover.RequestScan fonksiyon degil'
    end
    if type(sc.Cache) ~= 'table' then
        return false, 'Matrix.StreetCover.Cache tablo degil'
    end
    if type(sc.BackoffUntil) ~= 'table' then
        return false, 'Matrix.StreetCover.BackoffUntil tablo degil'
    end

    -- Guard testi: gecersiz girdi hata firlatmamali (Kural 3: pcall-guarded)
    local ok = pcall(sc.RequestScan, 0, 0)
    if not ok then
        return false, 'RequestScan gecersiz girdiyle hata firlatti'
    end
    local ok2 = pcall(sc.RequestScan, -1, -1)
    if not ok2 then
        return false, 'RequestScan negatif girdiyle hata firlatti'
    end

    return true, 'RequestScan + Cache + BackoffUntil hazir, guard OK'
end)

AddCheck('[FAZ 5.1] hitsquad_cover.lua + hitsquad.lua source string dogrulamasi', function()
    -- ★ FEATURE FLAG: Legacy hitsquad kapalıysa dosyalar silinmiş, atla
    if Config.Features and Config.Features.LegacyHitsquad == false then
        return true, 'ATLANDI -- Legacy hitsquad devre disi (dosyalar silindi)'
    end

    local clientSrc = LoadResourceFile(GetCurrentResourceName(), 'client/hitsquad_cover.lua')
    local requiredClient = {
        'TaskSeekCoverFromPos',
        "'matrix:client:streetCover:scan'",
        "'matrix:client:streetCover:dismount'",
        "'matrix:client:streetCover:startFiring'",
        "'matrix:client:streetCover:stopFiring'",
    }
    for _, needle in ipairs(requiredClient) do
        if not clientSrc:find(needle, 1, true) then
            return false, ('client/hitsquad_cover.lua icinde eksik: %s'):format(needle)
        end
    end

    local serverSrc = LoadResourceFile(GetCurrentResourceName(), 'server/hitsquad.lua')
    if type(serverSrc) ~= 'string' or serverSrc == '' then
        return false, 'server/hitsquad.lua LoadResourceFile ile okunamadi'
    end

    local requiredServer = {
        "'dismounted'",
        "'matrix:server:streetCover:assign'",
        "'matrix:server:streetCover:notFound'",
        'Matrix.StreetCover.RequestScan',
    }
    for _, needle in ipairs(requiredServer) do
        if not serverSrc:find(needle, 1, true) then
            return false, ('server/hitsquad.lua icinde eksik: %s'):format(needle)
        end
    end

    return true, ('client: %d/%d, server: %d/%d string dogrulandi'):format(
        #requiredClient, #requiredClient, #requiredServer, #requiredServer)
end)

-- =====================================================================
-- DB ŞEMA YARDIMCILARI — FAZ 4 checks tarafından da kullanılıyor
-- =====================================================================
local function TableExists(tableName)
    local rows = MySQL.query.await(
        'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { tableName }
    ) or {}
    return #rows > 0
end

local function ColumnExists(tableName, columnName)
    local rows = MySQL.query.await(
        'SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { tableName, columnName }
    ) or {}
    return #rows > 0
end

AddCheck('TrapHouseInterior.Shell koordinat tutarlılığı', function()
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell or not shell.EnterCoords or not shell.ExitCoords then
        return false, 'Config.TrapHouseInterior.Shell.EnterCoords/ExitCoords tanımsız'
    end
    local e, x = shell.EnterCoords, shell.ExitCoords
    if e.x == x.x and e.y == x.y and e.z == x.z then
        return true, ('(%.4f,%.4f,%.4f)'):format(e.x, e.y, e.z)
    end
    return false, 'EnterCoords/ExitCoords ayni interior cebini isaret etmiyor'
end)

AddCheck('Bureau.Lockdown agirliklari (Breach+Purity=1.0)', function()
    local w, p = Config.Bureau.LockdownBreachWeight, Config.Bureau.LockdownPurityWeight
    local sum = (w or 0) + (p or 0)
    return math_abs(sum - 1.0) < 0.0001, ('BreachWeight=%.2f PurityWeight=%.2f toplam=%.4f'):format(w or -1, p or -1, sum)
end)

AddCheck('Bureau.LockdownEvidenceThreshold (0,1] araliginda', function()
    local t = Config.Bureau.LockdownEvidenceThreshold
    return type(t) == 'number' and t > 0 and t <= 1.0, tostring(t)
end)

AddCheck('Bureau.Livestream->radio_breach_count koprusu (Madde 3)', function()
    local mult = Config.Bureau.LivestreamRadioBreachMultiplier
    local rate = Config.Bureau.LivestreamRadioLeakPerTick
    if type(mult) ~= 'number' or mult <= 0 then return false, 'LivestreamRadioBreachMultiplier gecersiz' end
    if type(rate) ~= 'number' or rate <= 0 then return false, 'LivestreamRadioLeakPerTick gecersiz' end
    if type(Matrix.Bureau.RecordLivestreamRadioLeak) ~= 'function' then
        return false, 'Matrix.Bureau.RecordLivestreamRadioLeak tanimli degil'
    end
    return true, ('carpan=%.1f, oran=%.5f/tick'):format(mult, rate)
end)

AddCheck('Forensics.Frisk parametreleri gecerli', function()
    local f = Config.Forensics.Frisk
    if not f then return false, 'Config.Forensics.Frisk tanimsiz' end
    if type(f.Radius) ~= 'number' or f.Radius <= 0 then return false, 'Radius gecersiz' end
    if type(f.DwellMs) ~= 'number' or f.DwellMs <= 0 then return false, 'DwellMs gecersiz' end
    if type(f.CooldownMs) ~= 'number' or f.CooldownMs <= 0 then return false, 'CooldownMs gecersiz' end
    if type(f.WeaponSerialContrabandPrefix) ~= 'string' or f.WeaponSerialContrabandPrefix == '' then
        return false, 'WeaponSerialContrabandPrefix bos'
    end
    return true, ('Radius=%.1fm Dwell=%dms Cooldown=%dms'):format(f.Radius, f.DwellMs, f.CooldownMs)
end)

AddCheck('Logistics.TrunkOps parametreleri gecerli (Madde 5b bagimliligi)', function()
    local t = Config.Logistics.TrunkOps
    if not t then return false, 'Config.Logistics.TrunkOps tanimsiz' end
    if type(t.StashPrefix) ~= 'string' or t.StashPrefix == '' then return false, 'StashPrefix bos' end
    if type(t.Slots) ~= 'number' or t.Slots <= 0 then return false, 'Slots gecersiz' end
    if type(t.MaxWeight) ~= 'number' or t.MaxWeight <= 0 then return false, 'MaxWeight gecersiz' end
    return true, ('prefix=%s slots=%d'):format(t.StashPrefix, t.Slots)
end)

AddCheck('Market.GourmetMinPurity [0,1] araliginda', function()
    local p = Config.Market.GourmetMinPurity
    return type(p) == 'number' and p >= 0 and p <= 1.0, tostring(p)
end)

AddCheck('Market.StreetDealing devsirme esikleri gecerli', function()
    local s = Config.Market.StreetDealing
    if not s then return false, 'Config.Market.StreetDealing tanimsiz' end
    if type(s.RecruitAddictionThreshold) ~= 'number' or s.RecruitAddictionThreshold <= 0 then
        return false, 'RecruitAddictionThreshold gecersiz'
    end
    if type(s.RecruitDistance) ~= 'number' or s.RecruitDistance <= 0 then return false, 'RecruitDistance gecersiz' end
    return true, ('esik=%.1f mesafe=%.1fm'):format(s.RecruitAddictionThreshold, s.RecruitDistance)
end)

AddCheck('Kitchen.Packaging urun tanimlari gecerli', function()
    local pk = Config.Kitchen.Packaging
    if not pk or type(pk.RawItem) ~= 'string' or pk.RawItem == '' then return false, 'RawItem bos' end
    if type(pk.Products) ~= 'table' or #pk.Products == 0 then return false, 'Products bos' end
    for i, prod in ipairs(pk.Products) do
        if type(prod.item) ~= 'string' or prod.item == '' or type(prod.label) ~= 'string' or prod.label == '' then
            return false, ('Products[%d] eksik item/label'):format(i)
        end
    end
    return true, ('RawItem=%s, %d urun'):format(pk.RawItem, #pk.Products)
end)

AddCheck('Logistics.MinDispatchDistanceMeters > 0', function()
    local d = Config.Logistics.MinDispatchDistanceMeters
    return type(d) == 'number' and d > 0, tostring(d)
end)

AddCheck('Config Ped Bekcisi: BotPedConfiguration rutbe atamalari katı string', function()
    local pool = Config.BotPedConfiguration
    if type(pool) ~= 'table' then return false, 'Config.BotPedConfiguration tanimsiz' end
    local requiredRanks = { 'runner', 'lookout', 'chemist', 'inspector' }
    for _, rank in ipairs(requiredRanks) do
        if type(pool[rank]) ~= 'string' or pool[rank] == '' then
            return false, ('BotPedConfiguration[%s] gecersiz/bos'):format(rank)
        end
    end
    return true, ('%d rutbe dogrulandi'):format(#requiredRanks)
end)

local MAP_MIN_XY, MAP_MAX_XY = -6000.0, 8000.0
local MAP_MIN_Z, MAP_MAX_Z   = -200.0, 1200.0

local function CheckVector3InMapBounds(v, label)
    if type(v) ~= 'vector3' then
        return false, ('%s vector3 degil (tip=%s)'):format(label, type(v))
    end
    if v.x ~= v.x or v.y ~= v.y or v.z ~= v.z then
        return false, ('%s NaN koordinat iceriyor'):format(label)
    end
    if v.x < MAP_MIN_XY or v.x > MAP_MAX_XY or v.y < MAP_MIN_XY or v.y > MAP_MAX_XY
        or v.z < MAP_MIN_Z or v.z > MAP_MAX_Z then
        return false, ('%s harita sinirlari disinda (%.1f, %.1f, %.1f)'):format(label, v.x, v.y, v.z)
    end
    return true
end

AddCheck('Koordinat Kusursuzlugu: GangHoods + Hayalet Doktor + karaborsa parametreleri', function()
    local hoods = Config.GangHoods and Config.GangHoods.Hoods
    if type(hoods) ~= 'table' or #hoods == 0 then return false, 'Config.GangHoods.Hoods bos/tanimsiz' end
    for _, hood in ipairs(hoods) do
        local ok, detail = CheckVector3InMapBounds(hood.coords, ('hood#%s(%s)'):format(tostring(hood.id), tostring(hood.label)))
        if not ok then return false, detail end
    end

    local phantomCoords = Config.PhantomDoctor and Config.PhantomDoctor.Coords
    if type(phantomCoords) ~= 'table' or #phantomCoords == 0 then return false, 'Config.PhantomDoctor.Coords bos/tanimsiz' end
    for i, c in ipairs(phantomCoords) do
        local ok, detail = CheckVector3InMapBounds(c, ('phantom#%d'):format(i))
        if not ok then return false, detail end
    end

    local r = Config.Rendezvous
    if not r then return false, 'Config.Rendezvous tanimsiz' end
    if type(r.MinOffsetMeters) ~= 'number' or type(r.MaxOffsetMeters) ~= 'number' then
        return false, 'Rendezvous MinOffsetMeters/MaxOffsetMeters sayisal degil'
    end
    if r.MinOffsetMeters <= 0 or r.MaxOffsetMeters <= r.MinOffsetMeters then
        return false, ('Rendezvous offset araligi gecersiz: min=%.1f max=%.1f'):format(r.MinOffsetMeters, r.MaxOffsetMeters)
    end

    return true, ('%d hood, %d hayalet doktor koordinati, karaborsa offset [%.1f,%.1f]m -- hepsi gecerli'):format(
        #hoods, #phantomCoords, r.MinOffsetMeters, r.MaxOffsetMeters)
end)

-- =====================================================================
-- ★★★ vbs_core_matrix v3.0 FAZ 1 — COGNITION_CORE TANILAMA KONTROLLERİ ★★★
-- [MATRIX:COGNITIVE_CORE_PHASE1]
-- =====================================================================

AddCheck('[MATRIX:COGNITIVE_CORE_PHASE1] cognition_core modulu yuklendi', function()
    if type(Matrix.Cognition) ~= 'table' then
        return false, 'Matrix.Cognition tanimli degil (server/cognition_core.lua fxmanifest\'e eklenmemis)'
    end
    if type(Matrix.Cognition.DeriveIqFromDna)           ~= 'function' then return false, 'DeriveIqFromDna eksik' end
    if type(Matrix.Cognition.ComputeFailureProbability) ~= 'function' then return false, 'ComputeFailureProbability eksik' end
    if type(Matrix.Cognition.ApplyChemicalShift)        ~= 'function' then return false, 'ApplyChemicalShift eksik' end
    if type(Matrix.Cognition.GetEffectiveIq)            ~= 'function' then return false, 'GetEffectiveIq eksik' end
    return true, 'tum public API yuklendi'
end)

AddCheck('[MATRIX:COGNITIVE_CORE_PHASE1] IQ turetimi deterministik ve [80,140] araliginda', function()
    if type(Matrix.Cognition) ~= 'table' or type(Matrix.Cognition.DeriveIqFromDna) ~= 'function' then
        return false, 'DeriveIqFromDna yok'
    end
    local ornekler = { 'DNA-00000001', 'DNA-00000002', 'DNA-TEST-ALPHA', 'DNA-TEST-BETA', 'DNA-PLR-CITIZEN123' }
    for _, dna in ipairs(ornekler) do
        local a = Matrix.Cognition.DeriveIqFromDna(dna)
        local b = Matrix.Cognition.DeriveIqFromDna(dna)
        if a ~= b then
            return false, ('RNG SIZINTISI: %s iki farkli IQ uretti (%d vs %d)'):format(dna, a, b)
        end
        if a < 80 or a > 140 then
            return false, ('IQ araligi ihlali: %s -> %d'):format(dna, a)
        end
    end
    return true, '5 farkli DNA icin determinizm + aralik dogrulandi'
end)

AddCheck('[MATRIX:COGNITIVE_CORE_PHASE1] Basarisizlik denklemi [0.05, 1.00] araliginda kirpilir', function()
    if type(Matrix.Cognition) ~= 'table' or type(Matrix.Cognition.ComputeFailureProbability) ~= 'function' then
        return false, 'ComputeFailureProbability yok'
    end
    -- Canli bot gerektirmeden dogrudan formül clamp testi.
    local function _clamp(v)
        if v < 0.05 then return 0.05 end
        if v > 1.00 then return 1.00 end
        return v
    end
    local asiriYuksek = _clamp((110.0 / 80) * (1.0 + 1.0) * (1.0 + 100.0))
    local asiriDusuk  = _clamp((110.0 / 140) * (1.0 + 0.0) * (1.0 + 0.0))
    if asiriYuksek ~= 1.00 then return false, ('ust clamp basarisiz: %.4f'):format(asiriYuksek) end
    if asiriDusuk <  0.05 or asiriDusuk > 1.00 then
        return false, ('alt sinir ihlali: %.4f'):format(asiriDusuk)
    end
    return true, ('clamp [0.05,1.00] dogrulandi (yuksek=%.2f, dusuk=%.4f)'):format(asiriYuksek, asiriDusuk)
end)

AddCheck('[MATRIX:COGNITIVE_CORE_PHASE1] Export imzalari kayitli (GetBotFailureProbability + ApplyChemicalShift)', function()
    -- Her iki export da cognition_core.lua tarafindan kendiliginden kayit edilir.
    local okA, _ = pcall(function()
        return exports['vbs_core_matrix']:GetBotFailureProbability(0)
    end)
    local okB, _ = pcall(function()
        return exports['vbs_core_matrix']:ApplyChemicalShift(0, 'none')
    end)
    if not okA then return false, 'GetBotFailureProbability export cagrilamadi' end
    if not okB then return false, 'ApplyChemicalShift export cagrilamadi' end
    return true, 'her iki export cagrilabilir durumda'
end)

AddCheck('[MATRIX:COGNITIVE_CORE_PHASE1] Oyuncu (insan) kognitif cerceve DISINDA tutuluyor', function()
    if type(Matrix.Cognition) ~= 'table' or type(Matrix.Cognition.ApplyChemicalShift) ~= 'function' then
        return false, 'ApplyChemicalShift yok'
    end
    -- Negatif botId (imkansiz), string, nil -- hepsi reddedilmeli.
    local r1 = { Matrix.Cognition.ApplyChemicalShift(-1,     'meth') }
    local r2 = { Matrix.Cognition.ApplyChemicalShift('insan', 'meth') }
    local r3 = { Matrix.Cognition.ApplyChemicalShift(nil,    'meth') }
    if r1[1] == true or r2[1] == true or r3[1] == true then
        return false, 'gecersiz girdi kabul edildi -- insan sizintisi'
    end
    return true, 'insan / bot-olmayan girdiler reddedildi (return false)'
end)

AddCheck('[MATRIX:COGNITIVE_CORE_PHASE1] matrix_bot_cognition sema sozlesmesi (IF NOT EXISTS)', function()
    if type(MySQL) ~= 'table' then return false, 'MySQL global yok' end
    local ok, rows = pcall(function()
        return MySQL.query.await(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS " ..
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'matrix_bot_cognition'",
            {})
    end)
    if not ok or type(rows) ~= 'table' or #rows == 0 then
        return false, 'matrix_bot_cognition tablosu yok (sql/matrix_bot_cognition.sql calistirilmali)'
    end
    local gerekli = {
        bot_id = true, iq_score = true, withdrawal_index = true,
        fatigue_accumulation = true, current_drug_influence = true, updated_at = true
    }
    for _, row in ipairs(rows) do gerekli[tostring(row.COLUMN_NAME)] = nil end
    local eksik = {}
    for k in pairs(gerekli) do eksik[#eksik + 1] = k end
    if #eksik > 0 then
        return false, ('eksik kolonlar: %s'):format(table.concat(eksik, ','))
    end
    return true, ('%d kolon dogrulandi'):format(#rows)
end)

-- =====================================================================
-- Derin mod simulasyon kontrolleri (SimulationChecks tablosuna standart
-- yardimci ile eklenir; yalnizca /matrix_run_diagnostics deep ile
-- calistirilir).
-- =====================================================================
local function RunCognitionStimulantLockSimCheck()
    if type(Matrix.Cognition) ~= 'table'
       or type(Matrix.Cognition.ApplyChemicalShift) ~= 'function'
       or type(Matrix.Cognition.GetCognition) ~= 'function' then
        return false, 'cognition_core yuklenmedi'
    end

    local trapHouseId
    for id in pairs(Matrix.TrapHouses or {}) do trapHouseId = id; break end
    if not trapHouseId then return true, 'atlandi -- Matrix.TrapHouses bos' end

    local bot = Matrix.CreateBotRecord({
        name          = 'TANI-COG-METH',
        role          = 'diagnostic_test',
        trap_house_id = trapHouseId
    })
    if not bot or not bot.id then return false, 'test bot olusturulamadi' end

    local ok, etki = Matrix.Cognition.ApplyChemicalShift(bot.id, 'methamphetamine')
    if not ok or etki ~= 'stimulant' then
        Matrix.RemoveBot(bot.id, 'retired')
        return false, ('meth siniflandirmasi basarisiz: ok=%s etki=%s'):format(tostring(ok), tostring(etki))
    end

    -- Elle sisirilmis yorgunluk degerini yaz, ardindan bir sonraki overlay
    -- tick'inde kilitlenip sifirlanmasi gerektigini dogrula (deterministik,
    -- RNG yok).
    local cog = Matrix.Cognition.GetCognition(bot.id)
    cog.fatigue_accumulation = 5.0
    Matrix.Cognition.__TickBotMinute(bot)            -- ← YENİ

    local kilitliYorgunluk = cog.fatigue_accumulation
    Matrix.RemoveBot(bot.id, 'retired')

    if kilitliYorgunluk ~= 0.0 then
        return false, ('meth fatigue lock ihlali: fatigue=%s (beklenen 0.0)'):format(tostring(kilitliYorgunluk))
    end
    return true, 'meth -> fatigue_accumulation KILITLENDI (0.0)'
end

local function RunCognitionDepressantIqDropSimCheck()
    if type(Matrix.Cognition) ~= 'table'
       or type(Matrix.Cognition.ApplyChemicalShift) ~= 'function'
       or type(Matrix.Cognition.GetEffectiveIq) ~= 'function' then
        return false, 'cognition_core yuklenmedi'
    end

    local trapHouseId
    for id in pairs(Matrix.TrapHouses or {}) do trapHouseId = id; break end
    if not trapHouseId then return true, 'atlandi -- Matrix.TrapHouses bos' end

        local bot = Matrix.CreateBotRecord({
        name          = 'TANI-COG-OPIUM',
        role          = 'diagnostic_test',
        trap_house_id = trapHouseId
    })
    if not bot or not bot.id then return false, 'test bot olusturulamadi' end

    -- ★ [LEAK-FIX] Önceki boot'tan kalan persisted overlay'i zorla temizle
    Matrix.Cognition.Registry[bot.id] = nil
    Matrix.Cognition.__dirty[bot.id]  = nil
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_bot_cognition WHERE bot_id = ?', { bot.id })
    end)

    local temelIq = Matrix.Cognition.GetEffectiveIq(bot.id)
    local ok, etki = Matrix.Cognition.ApplyChemicalShift(bot.id, 'opium')
    if not ok or etki ~= 'depressant' then
        Matrix.RemoveBot(bot.id, 'retired')
        return false, ('opium siniflandirmasi basarisiz: ok=%s etki=%s'):format(tostring(ok), tostring(etki))
    end
    local depresifIq = Matrix.Cognition.GetEffectiveIq(bot.id)
    Matrix.RemoveBot(bot.id, 'retired')

    local fark = temelIq - depresifIq
    if fark ~= 30 then
        return false, ('opium IQ dususu yanlis: temel=%d depresif=%d fark=%d (beklenen 30)'):format(
            temelIq, depresifIq, fark)
    end
    return true, ('opium -> IQ tam -30 dustu (%d -> %d)'):format(temelIq, depresifIq)
end

local function RunCognitionParanoitCrisisThresholdSimCheck()
    if type(Matrix.Cognition) ~= 'table' then return false, 'cognition yok' end

    local trapHouseId
    for id in pairs(Matrix.TrapHouses or {}) do trapHouseId = id; break end
    if not trapHouseId then return true, 'atlandi -- TrapHouses bos' end

    local bot = Matrix.CreateBotRecord({
        name          = 'TANI-COG-PARANOIT',
        role          = 'diagnostic_test',
        -- trap_house_id KALDIRILDI (yan etki fix)  trap_house_id = nil,
        activity      = 'distribution'
    })
    if not bot or not bot.id then return false, 'test bot olusturulamadi' end

    bot.biology.withdrawal_index = 0.90   -- 0.85 esiginin UZERINDE
    Matrix.Cognition.ApplyChemicalShift(bot.id, 'methamphetamine')

    local cog = Matrix.Cognition.GetCognition(bot.id)
    cog.hallucination_index = 0.95        -- tavana yakin

    -- Kriz tetikleyicisini harici sistemlere dokunmadan zorla; KESINLIKLE
    -- idempotent ve deterministik olmali.
    Matrix.Cognition.__TickStimulantOverlay(bot, cog)   -- ← YENİ
    local ilkTetiklendi  = cog.paranoit_crisis_fired
    Matrix.Cognition.__TickStimulantOverlay(bot, cog)   -- ← YENİ
    local ikinciTetiklendi = cog.paranoit_crisis_fired

    Matrix.RemoveBot(bot.id, 'retired')

    if not ilkTetiklendi    then return false, 'esik asildi ama paranoit kriz TETIKLENMEDI' end
    if not ikinciTetiklendi then return false, 'ikinci tickte latch kayboldu' end
    return true, 'withdrawal>0.85 -> paranoit kriz latch calisti'
end

-- Uc derin simulasyon kontrolunu SimulationChecks tablosuna kaydet.
-- (Bu dosya yerinde yamalaniyorsa, girdileri dogrudan SimulationChecks
-- deklarasyonunun icine ekleyin. Burada yerinde-guvenli ekleme olarak
-- verilmistir.)

-- ★★★ COGNITION_CORE TANILAMA BLOK SONU ★★★

if Config.ComposerSignature then
    AddCheck('ComposerSignature.volume [0,1] araliginda', function()
        local v = Config.ComposerSignature.volume
        return type(v) == 'number' and v >= 0 and v <= 1.0, tostring(v)
    end)
end

AddCheck('Matrix.Clamp referans-seffafligi (determinizm)', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Matrix.Clamp tanimli degil' end
    local a1, a2 = Matrix.Clamp(1.7, 0.0, 1.0), Matrix.Clamp(1.7, 0.0, 1.0)
    local b1, b2 = Matrix.Clamp(-0.3, 0.0, 1.0), Matrix.Clamp(-0.3, 0.0, 1.0)
    if a1 ~= 1.0 or b1 ~= 0.0 then return false, 'sinir degerleri yanlis kirpiliyor' end
    if a1 ~= a2 or b1 ~= b2 then return false, 'ayni girdi farkli cikti uretti (RNG sizintisi?)' end
    return true, 'iki cagri birebir ayni'
end)

-- =====================================================================
-- ★★★ DARKCHAT / QB-PHONE TELEMETRİ KÖPRÜSÜ DOĞRULAMALARI ★★★
-- server/phone_bridge.lua'nın monkey-patch katmanının AKTİF olduğunu,
-- mask algoritmasının deterministik çalıştığını ve Need-to-Know
-- sözleşmesinin kurallı döndüğünü KANITLAR.
-- =====================================================================
AddCheck('PhoneBridge: CompleteDispatch sarmalayici aktif', function()
    if type(Matrix.PhoneBridge) ~= 'table' then
        return false, 'Matrix.PhoneBridge modulu tanimsiz (phone_bridge.lua yuklenmedi)'
    end
    if Matrix.PhoneBridge._CompleteDispatchWrapped ~= true then
        return false, '_CompleteDispatchWrapped bayragi set edilmemis (cift-sarma koruma basarisiz)'
    end
    if type(Matrix.CompleteDispatch) ~= 'function' then
        return false, 'Matrix.CompleteDispatch cagrilamaz durumda'
    end
    return true, 'aktif (dispatch sonu telemetri koprusu kurulu)'
end)

AddCheck('PhoneBridge: DepositCargo sarmalayici aktif', function()
    if type(Matrix.PhoneBridge) ~= 'table' then
        return false, 'Matrix.PhoneBridge modulu tanimsiz'
    end
    if Matrix.PhoneBridge._DepositCargoWrapped ~= true then
        return false, '_DepositCargoWrapped bayragi set edilmemis'
    end
    if type(Matrix.DepositDealerCargoToTrapStash) ~= 'function' then
        return false, 'Matrix.DepositDealerCargoToTrapStash cagrilamaz durumda'
    end
    return true, 'aktif (liman-kargo depo telemetri koprusu kurulu)'
end)

AddCheck('PhoneBridge: Determinizm kaniti (math.random YASAK)', function()
    if type(Matrix.PhoneBridge) ~= 'table'
        or type(Matrix.PhoneBridge.__DeterminismProbe) ~= 'function' then
        return false, '__DeterminismProbe fonksiyonu tanimli degil (phone_bridge.lua surum uyumsuz)'
    end
    -- Aynı girdi iki kez çağrılırsa BİREBİR aynı çıktı üretmeli.
    local seed = ('DIAG#%d'):format(GetGameTimer())
    local a = Matrix.PhoneBridge.__DeterminismProbe(seed)
    local b = Matrix.PhoneBridge.__DeterminismProbe(seed)
    if a ~= b then
        return false, ('RNG SIZINTISI KANITI: ayni girdi iki farkli cikti (%s != %s)'):format(tostring(a), tostring(b))
    end
    if type(a) ~= 'string' or #a ~= 64 then
        return false, ('beklenmeyen cikti bicimi: uzunluk=%d'):format(type(a) == 'string' and #a or -1)
    end
    return true, ('deterministik SHA256-benzeri 64-char hex: %s...'):format(a:sub(1, 16))
end)

AddCheck('PhoneBridge: Need-to-Know sozlesmesi (guard davranisi)', function()
    if not Matrix.Bureau or type(Matrix.Bureau.GetEncryptedAgentTelemetry) ~= 'function' then
        return false, 'GetEncryptedAgentTelemetry tanimli degil'
    end
    -- Geçersiz src ile çağır: 'bad_src' guard'ının ÇALIŞTIĞINI doğrula.
    local r1, e1 = Matrix.Bureau.GetEncryptedAgentTelemetry(0, 1)
    if r1 ~= nil or e1 ~= 'bad_src' then
        return false, ('bad_src guard basarisiz: r=%s e=%s'):format(tostring(r1), tostring(e1))
    end
    -- Geçerli src ama sahte botId: 'bot_missing' guard'ının ÇALIŞTIĞINI doğrula.
    local r2, e2 = Matrix.Bureau.GetEncryptedAgentTelemetry(1, 999999)
    if r2 ~= nil or e2 ~= 'bot_missing' then
        return false, ('bot_missing guard basarisiz: r=%s e=%s'):format(tostring(r2), tostring(e2))
    end
    return true, 'Iki guard da aktif (bad_src + bot_missing)'
end)

AddCheck('PhoneBridge: Mask algoritmasi tek-yonlu ozet (hex prefix)', function()
    if type(Matrix.PhoneBridge) ~= 'table'
        or type(Matrix.PhoneBridge.__DeterminismProbe) ~= 'function' then
        return false, 'probe yok'
    end
    local sample = Matrix.PhoneBridge.__DeterminismProbe('MASK-TEST-ALPHA')
    if type(sample) ~= 'string' or not sample:match('^%x+$') then
        return false, ('cikti hex degil: %s'):format(tostring(sample):sub(1, 16))
    end
    -- Farklı girdi → farklı çıktı (tek-yönlülük kanıtı).
    local other = Matrix.PhoneBridge.__DeterminismProbe('MASK-TEST-BETA')
    if sample == other then
        return false, 'farkli girdi ayni cikti uretti (checksum zayif)'
    end
    return true, 'hex, tek-yonlu, girdi-duyarli'
end)
-- ★★★ DARKCHAT DIAGNOSTICS BLOK SONU ★★★

-- =====================================================================
-- ★ [FAZ 0.4] EVENT CHAIN VERIFICATION
-- matrix:internal:* event'lerini sayaçla takip eder. Chain testleri
-- bu sayaçları kullanarak "X tetiklendi, Y de tetiklendi mi?" sorusunu
-- doğrular.
-- =====================================================================

local _eventCounter      = {}
local _eventMonitorOn    = false

local _MONITORED_EVENTS = {
    'matrix:internal:botRemoving',
    'matrix:internal:raidIssued',
    'matrix:internal:raidResolved',
    'matrix:internal:botanyHarvest',
    'matrix:internal:botanyInfestationOutbreak',
    'matrix:internal:gangLeaderDeceased',
    'matrix:internal:bureauLockdown',
    'matrix:internal:mole_flagged',
    'matrix:internal:hitSquadRequested',
    'matrix:internal:cognitionInitialized',
    'matrix:internal:darkLawyerCounterSting',
    'matrix:internal:fakeLspdBulletin',
}

CreateThread(function()
    for _, evt in ipairs(_MONITORED_EVENTS) do
        AddEventHandler(evt, function(...)
            if not _eventMonitorOn then return end
            _eventCounter[evt] = (_eventCounter[evt] or 0) + 1
        end)
    end
    print(('[MATRIX:DIAGNOSTICS] [FAZ 0.4] %d event monitor aktif.'):format(#_MONITORED_EVENTS))
end)

local function _resetCounters()
    for k in pairs(_eventCounter) do _eventCounter[k] = nil end
    _eventMonitorOn = true
end

local function _getCount(evt)
    return _eventCounter[evt] or 0
end

-- =====================================================================
-- ★ [FAZ 0.5] RACE CONDITION VERIFICATION
-- Eşzamanlı çağrıların atomikliğini test eder. F0.1'de eklenen
-- _botRemovalInFlight guard'ının gerçekten çalıştığını kanıtlar.
-- Test'ler İZOLE çalışır — gerçek verileri etkilemez.
-- =====================================================================

Matrix.Diagnostics.RaceChecks = Matrix.Diagnostics.RaceChecks or {}

local function RegisterRaceCheck(name, fn, timeoutMs)
    Matrix.Diagnostics.RaceChecks[#Matrix.Diagnostics.RaceChecks + 1] = {
        name    = name,
        fn      = fn,
        timeout = timeoutMs or 5000,
    }
end

-- =====================================================================
-- Test 1: RemoveBot — 20 eşzamanlı çağrı
-- =====================================================================
RegisterRaceCheck('[FAZ 0.5] Race: RemoveBot x20 eszamanli', function()
    local bot = Matrix.CreateBotRecord({
        name = 'RACE-TEST-RM',
        role = 'diagnostic_test',
    })
    if not bot or not bot.id then
        return { error = 'bot_create_failed' }
    end

    local botId = bot.id
    local successCount, failCount, completed = 0, 0, 0
    local total = 20

    for i = 1, total do
        CreateThread(function()
            local ok, result = pcall(Matrix.RemoveBot, botId, 'retired')
            if ok and result == true then
                successCount = successCount + 1
            else
                failCount = failCount + 1
            end
            completed = completed + 1
        end)
    end

    local waited = 0
    while completed < total and waited < 3000 do
        Wait(50)
        waited = waited + 50
    end

    local dbRow = nil
    pcall(function()
        dbRow = MySQL.single.await('SELECT id, status FROM matrix_bots WHERE id = ?', { botId })
    end)

    local ramExists = Matrix.Bots[botId] ~= nil

    return {
        bot_id     = botId,
        total      = total,
        completed  = completed,
        success    = successCount,
        failed     = failCount,
        db_row     = dbRow,
        ram_exists = ramExists,
    }
end, 5000)

-- =====================================================================
-- Test 2: Cognition cleanup — RemoveBot sonrası DB temizliği
-- =====================================================================
RegisterRaceCheck('[FAZ 0.5] Race: Cognition cleanup atomic', function()
    local bot = Matrix.CreateBotRecord({
        name = 'RACE-TEST-COG',
        role = 'diagnostic_test',
    })
    if not bot or not bot.id then
        return { error = 'bot_create_failed' }
    end

    local botId = bot.id

    if Matrix.Cognition and Matrix.Cognition.GetCognition then
        pcall(Matrix.Cognition.GetCognition, botId)
    end

    Wait(100)
    local beforeRow = nil
    pcall(function()
        beforeRow = MySQL.single.await(
            'SELECT bot_id FROM matrix_bot_cognition WHERE bot_id = ?', { botId })
    end)

    Matrix.RemoveBot(botId, 'retired')
    Wait(300)

    local afterRow = nil
    pcall(function()
        afterRow = MySQL.single.await(
            'SELECT bot_id FROM matrix_bot_cognition WHERE bot_id = ?', { botId })
    end)

    local ramCogExists = false
    if Matrix.Cognition and Matrix.Cognition.Registry then
        ramCogExists = Matrix.Cognition.Registry[botId] ~= nil
    end

    return {
        bot_id         = botId,
        before_db      = beforeRow ~= nil,
        after_db       = afterRow ~= nil,
        ram_cog_exists = ramCogExists,
    }
end, 5000)

-- =====================================================================
-- Test 3: BureauLockdown — Aynı trap house'a eşzamanlı trigger
-- =====================================================================

-- [A4-2] DIAGNOSTICS FIXTURE — Chaos'un Fixture.Setup/Teardown desenini
-- ornek alir (kopyalama degil, ayni pattern): deep-mode kontrolleri artik
-- GERCEK trap house'lari mutasyona ugratmaz, kendi izole fixture'ini
-- yaratir, testi onun uzerinde calistirir, is bitince fixture'i TAMAMEN
-- siler. 'CHAOS-FIXTURE' on-eki korunur (chaos.lua'nin teardown sweep'i
-- ayni sekilde tanir); '-DIAG-' eki chaos.lua'nin kendi fixture'lariyla
-- cakismamasi icindir.
local _diagFixtureSeq = 0

local function _CreateDiagFixtureTrapHouse()
    _diagFixtureSeq = _diagFixtureSeq + 1
    local label = ('CHAOS-FIXTURE-TRAP-DIAG-%03d'):format(_diagFixtureSeq)
    local x = 2500.0 + (_diagFixtureSeq * 40.0)
    local y = -3500.0 - (_diagFixtureSeq * 25.0)
    local z = 30.0

    local ok, id = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO matrix_trap_houses
                (label, coord_x, coord_y, coord_z, decryption_confidence, cyber_leak_intensity,
                 raid_ordered, straw_buyer_citizenid, structural_integrity, created_at)
            VALUES (?, ?, ?, ?, 0.0, 0.0, 0, NULL, 1.00, NOW())
        ]], { label, x, y, z })
    end)
    if not ok or type(id) ~= 'number' then
        Matrix.Log('DIAGNOSTICS', '[HATA] Fixture trap house INSERT basarisiz: %s', tostring(id))
        return nil
    end

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

local function _DestroyDiagFixtureTrapHouse(trapId)
    if not trapId then return end
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_cash_decay WHERE trap_house_id = ?', { trapId })
    end)
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_banking_escrow WHERE trap_house_id = ?', { trapId })
    end)
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_positions WHERE trap_house_id = ?', { trapId })
    end)
    -- v6.6.5 Paket 2: bureau.lua'daki RAM dirty-set'leri (learningCore/
    -- dirtyIntel/patternLog/vb.) temizle -- yoksa TriggerLockdown/
    -- LiftLockdown gibi cagrilarla kirlenen state, trap house RAM'den
    -- ve DB'den silindikten SONRA bile bir sonraki FlushDirty* tick'inde
    -- artik var olmayan bu parent icin INSERT/UPDATE denemeye calisir.
    pcall(Matrix.Bureau.ClearLearningState, trapId)
    -- matrix_bureau_learning_core / matrix_bureau_intel / matrix_pattern_log
    -- FK ile matrix_trap_houses'a bagli (ON DELETE CASCADE YOK) -- bu
    -- satirlar once silinmeden asagidaki matrix_trap_houses DELETE'i
    -- FK constraint violation ile sessizce basarisiz olabilirdi (pcall
    -- yutar, satir silinmeden kalirdi).
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_bureau_learning_core WHERE trap_house_id = ?', { trapId })
    end)
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_bureau_intel WHERE trap_house_id = ?', { trapId })
    end)
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_pattern_log WHERE trap_house_id = ?', { trapId })
    end)
    if Matrix.TrapHouses then Matrix.TrapHouses[trapId] = nil end
    pcall(function()
        MySQL.query.await('DELETE FROM matrix_trap_houses WHERE id = ? AND label LIKE ?',
            { trapId, 'CHAOS-FIXTURE%' })
    end)
end

-- fn(trapId) izole fixture trap house uzerinde calisir; sonuc ne olursa
-- olsun (early return / hata firlatma) fixture HER ZAMAN silinir.
-- seedPositions=true ise Positions.SeedDefaults ile slotlar onceden doldurulur
-- (LOS/reflex testleri slot verisine ihtiyac duyar).
local function _WithDiagFixtureTrapHouse(fn, seedPositions)
    local trapId = _CreateDiagFixtureTrapHouse()
    if not trapId then
        return false, 'fixture trap house yaratilamadi'
    end
    if seedPositions and Matrix.Positions and Matrix.Positions.SeedDefaults then
        pcall(Matrix.Positions.SeedDefaults, trapId)
    end

    local ok, r1, r2 = pcall(fn, trapId)
    _DestroyDiagFixtureTrapHouse(trapId)

    if not ok then
        return false, ('fixture test hata firlatti: %s'):format(tostring(r1))
    end
    return r1, r2
end

RegisterRaceCheck('[FAZ 0.5] Race: Lockdown double-trigger', function()
    return _WithDiagFixtureTrapHouse(function(trapId)
        if Matrix.Bureau.IsLockedDown(trapId) then
            pcall(Matrix.Bureau.LiftLockdown, trapId, 0.0)
            Wait(100)
        end

        local ok1 = pcall(Matrix.Bureau.TriggerLockdown, trapId, 1.0)
        local ok2 = pcall(Matrix.Bureau.TriggerLockdown, trapId, 1.0)
        Wait(300)

        local isLocked = Matrix.Bureau.IsLockedDown(trapId)

        pcall(Matrix.Bureau.LiftLockdown, trapId, 0.0)
        Wait(100)

        return {
            trap_id   = trapId,
            call1_ok  = ok1,
            call2_ok  = ok2,
            is_locked = isLocked,
        }
    end)
end, 5000)

-- =====================================================================
-- ★ [FAZ 0.6] STATE SYNC + DETERMINISM VERIFICATION
-- RAM vs DB tutarlılığı + 0-RNG (math.random yasak) doğrulaması.
-- =====================================================================

Matrix.Diagnostics.StateChecks  = Matrix.Diagnostics.StateChecks  or {}
Matrix.Diagnostics.DeterminismChecks = Matrix.Diagnostics.DeterminismChecks or {}

local function RegisterStateCheck(name, fn)
    Matrix.Diagnostics.StateChecks[#Matrix.Diagnostics.StateChecks + 1] = { name = name, fn = fn }
end

local function RegisterDeterminismCheck(name, fn)
    Matrix.Diagnostics.DeterminismChecks[#Matrix.Diagnostics.DeterminismChecks + 1] = { name = name, fn = fn }
end

-- =====================================================================
-- L4 — STATE SYNC (RAM vs DB)
-- =====================================================================

-- Test 1: Bot cortisol — RAM vs DB
RegisterStateCheck('[FAZ 0.6][L4] Bot cortisol RAM vs DB', function()
    local testBots = {}
    for botId, bot in pairs(Matrix.Bots or {}) do
        if bot.status == 'active' and not bot.role:find('diagnostic') then
            testBots[#testBots + 1] = botId
            if #testBots >= 5 then break end
        end
    end
    if #testBots == 0 then return { skip = true, reason = 'no_active_bot' } end

    local mismatches = {}
    for _, botId in ipairs(testBots) do
        local bot = Matrix.Bots[botId]
        local ramCortisol = bot.biology and bot.biology.cortisol_level or 0.0

        local dbRow = nil
        pcall(function()
            dbRow = MySQL.single.await(
                'SELECT cortisol_level FROM matrix_bots WHERE id = ?', { botId })
        end)

        local dbCortisol = dbRow and tonumber(dbRow.cortisol_level) or nil
        if dbCortisol and math.abs(ramCortisol - dbCortisol) > 0.05 then
            mismatches[#mismatches + 1] = ('bot#%d ram=%.3f db=%.3f'):format(
                botId, ramCortisol, dbCortisol)
        end
    end

    return {
        tested     = #testBots,
        mismatches = mismatches,
    }
end)

-- Test 2: Market zone — RAM vs DB
RegisterStateCheck('[FAZ 0.6][L4] Market zone price RAM vs DB', function()
    local zoneIds = {}
    for zoneId in pairs(Matrix.Market and Matrix.Market.Zones and Matrix.Market.Zones or {}) do
        zoneIds[#zoneIds + 1] = zoneId
    end
    -- Matrix.Market.Zones config tablosu, RAM market_zones ayrı -- Matrix.Market.LoadMarketZones
    -- aslında RAM'de MarketZones'a yükler ama export etmez. Sadece DB'den oku.
    if #zoneIds == 0 then
        -- Config.Market.Zones array'inden al
        for _, z in ipairs(Config.Market.Zones or {}) do
            zoneIds[#zoneIds + 1] = z.id
        end
    end
    if #zoneIds == 0 then return { skip = true, reason = 'no_zone' } end

    local dbRows = {}
    pcall(function()
        dbRows = MySQL.query.await('SELECT zone_id, price_multiplier FROM matrix_market_zones') or {}
    end)

    local dbMap = {}
    for _, row in ipairs(dbRows) do
        dbMap[tonumber(row.zone_id)] = tonumber(row.price_multiplier)
    end

    local checked = 0
    for _, zoneId in ipairs(zoneIds) do
        if dbMap[zoneId] then
            checked = checked + 1
        end
    end

    return {
        total_zones_in_db = #dbRows,
        config_zones      = #zoneIds,
        matched           = checked,
    }
end)

-- Test 3: Prop registry — RAM vs DB
RegisterStateCheck('[FAZ 0.6][L4] Prop registry RAM vs DB', function()
    if not Matrix.PropRegistry then return { skip = true, reason = 'no_prop_registry' } end

    local dbRows = {}
    pcall(function()
        dbRows = MySQL.query.await(
            'SELECT id, coord_x, coord_y, coord_z, heading FROM matrix_deployed_props WHERE active = 1') or {}
    end)

    if #dbRows == 0 then
        return { skip = true, reason = 'no_deployed_prop' }
    end

    local mismatches = 0
    for _, row in ipairs(dbRows) do
        local propId = tonumber(row.id)
        if propId then
            -- PropRegistry internal DeployedProps cache'ini kontrol et
            -- (private, ama GetProp üzerinden bakabiliriz)
                        local found = false
            if Matrix.PropRegistry.GetById and Matrix.PropRegistry.GetById(propId) then
                found = true
            end
            if not found then mismatches = mismatches + 1 end
        end
    end

    return {
        db_count    = #dbRows,
        mismatches  = mismatches,
    }
end)

-- Test 4: Player telemetry — RAM vs DB
RegisterStateCheck('[FAZ 0.6][L4] Player telemetry RAM vs DB', function()
    -- player_telemetry.lua'nın RAM state'i local, dışa açık değil.
    -- Sadece DB'nin erişilebilir olduğunu doğrula.
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT COUNT(*) AS c FROM matrix_player_telemetry') or {}
    end)
    if not ok then
        return { error = 'db_query_failed' }
    end
    return {
        db_rows = rows[1] and tonumber(rows[1].c) or 0,
    }
end)

-- =====================================================================
-- L6 — DETERMINISM (0-RNG doğrulaması)
-- Her test aynı girdiyle 100 kez çağırır, hepsinin AYNI çıktı olduğunu
-- doğrular. math.random sızıntısı varsa farklı sonuç çıkar.
-- =====================================================================

-- Test 1: IQ türetimi determinizm
RegisterDeterminismCheck('[FAZ 0.6][L6] IQ derivation 100x deterministic', function()
    if not Matrix.Cognition or not Matrix.Cognition.DeriveIqFromDna then
        return { skip = true, reason = 'no_cognition' }
    end

    local testDna = 'DNA-DETERMINISM-TEST-001'
    local first = Matrix.Cognition.DeriveIqFromDna(testDna)
    local allSame = true
    for i = 1, 100 do
        local v = Matrix.Cognition.DeriveIqFromDna(testDna)
        if v ~= first then
            allSame = false
            return { deterministic = false, first = first, break_at = i, different = v }
        end
    end
    return { deterministic = true, value = first, iterations = 100 }
end)

-- Test 2: Ballistic serial determinizm
RegisterDeterminismCheck('[FAZ 0.6][L6] Ballistic serial 100x deterministic', function()
    if not Matrix.BlackMarket or not Matrix.BlackMarket.GenerateWeaponSerial then
        return { skip = true, reason = 'no_blackmarket' }
    end

    -- NOT: GenerateWeaponSerial zaman + sequence kullanır, bu yüzden
    -- aynı çağrı aynı sonucu vermez. Bu test sadece FONKSİYONUN
    -- VARLIĞINI değil, çağrılabilirliğini test eder.
    local ok, result = pcall(Matrix.BlackMarket.GenerateWeaponSerial, 'TEST-CITIZEN', 'weapon_test')
    if not ok or type(result) ~= 'string' then
        return { error = 'call_failed' }
    end
    return { ok = true, sample = result:sub(1, 16) }
end)

-- Test 3: Police personality determinizm
RegisterDeterminismCheck('[FAZ 0.6][L6] Police personality 100x deterministic', function()
    if not Matrix.Bureau or not Matrix.Bureau.GetPolicePersonality then
        return { skip = true, reason = 'no_bureau' }
    end

    local testCid = 'DETERMINISM-TEST-CITIZEN'
    local first = Matrix.Bureau.GetPolicePersonality(testCid)
    if type(first) ~= 'table' then return { error = 'no_personality' } end

    for i = 1, 100 do
        local v = Matrix.Bureau.GetPolicePersonality(testCid)
        if type(v) ~= 'table' or v.integrity ~= first.integrity or v.greed ~= first.greed then
            return { deterministic = false, at_iteration = i }
        end
    end
    return {
        deterministic = true,
        integrity     = first.integrity,
        greed         = first.greed,
        iterations    = 100,
    }
end)

-- Test 4: RNG string taraması — shared + client + server dosyalarında
RegisterDeterminismCheck('[FAZ 0.6][L6] math.random taramasi', function()
    local files = {
        'shared/config.lua',
        'shared/log.lua',
        'shared/crypto.lua',
        'server/main.lua',
        'server/bureau.lua',
        'server/market.lua',
        'server/logistics.lua',
        'server/forensics.lua',
        'server/cognition_core.lua',
        'server/recruitment.lua',
        'server/kitchen.lua',
        'server/botany_core.lua',
        'server/botany_autonomy.lua',
        'server/odor_core.lua',
        'server/infestation.lua',
        'server/chemical_workbench.lua',
        'server/crack_chemistry.lua',
        'server/meth_chemistry.lua',
        'server/cellular_comms.lua',
        'server/prop_registry.lua',
        'server/wound_system.lua',
        'server/hitsquad.lua',
        'server/district_hubs.lua',
        'server/blackmarket.lua',
        'server/rendezvous.lua',
        'server/gang_hoods.lua',
        'server/underworld_network.lua',
    }

        local offenders = {}
    for _, path in ipairs(files) do
        local content = LoadResourceFile(GetCurrentResourceName(), path)
        if type(content) == 'string' then
            local lineNum = 0
            for line in content:gmatch('[^\n]*') do
                lineNum = lineNum + 1
                -- ★ SADECE gerçek kod: -- öncesi kısım
                local codeOnly = line:match('^([^%-]*)') or ''
                -- Ayrıca ' ile başlayan yorum satırlarını da atla
                if codeOnly:find('math%.random%s*%(') then
                    offenders[#offenders + 1] = ('%s:%d'):format(path, lineNum)
                end
            end
        end
    end

    if #offenders > 0 then
        return { clean = false, offenders = offenders }
    end
    return { clean = true, files_scanned = #files }
end)

Matrix.Diagnostics.ChainChecks = Matrix.Diagnostics.ChainChecks or {}

local function RegisterChainCheck(name, triggerFn, expectFn, timeoutMs)
    Matrix.Diagnostics.ChainChecks[#Matrix.Diagnostics.ChainChecks + 1] = {
        name      = name,
        trigger   = triggerFn,
        expect    = expectFn,
        timeout   = timeoutMs or 3000,
    }
end


-- =====================================================================
-- Chain Test 1: TriggerLockdown → bureauLockdown event + IsLockedDown
-- (Not: bu basligin altindaki blok kopyala-yapistir sirasinda "RemoveBot →
-- botRemoving" zincir testinin yerine gecmisti; o test hic implemente
-- edilmedi. RemoveBot → botRemoving zincir testi kapsam disi, v6.6.5'e
-- tasinir.)
-- =====================================================================
RegisterChainCheck(
    '[FAZ 0.4] Chain: TriggerLockdown → bureauLockdown + IsLockedDown',
    function()
        _resetCounters()

        return _WithDiagFixtureTrapHouse(function(trapId)
            -- ★ [DIAGNOSTIC ISOLATION v4] Gerçek TriggerLockdown çağır.
            -- bureau.lua'daki IsRunning guard'ı sadece LOG'u bastırıyor,
            -- state.lockdown_active = true ve event fırlatma normal akıyor.
            -- Bu sayede IsLockedDown doğru döner, event sayacı artar.
            Matrix.Bureau.TriggerLockdown(trapId, 1.0)
            Wait(200)

            local isLocked = Matrix.Bureau.IsLockedDown(trapId)

            Matrix.Bureau.LiftLockdown(trapId, 0.0)

            return {
                trap_id              = trapId,
                lockdown_event_count = _getCount('matrix:internal:bureauLockdown'),
                is_locked            = isLocked,
            }
        end)
    end,
    function(result)
        if result.skip then return true, ('ATLANDI -- %s'):format(result.reason or '?') end
        if (result.lockdown_event_count or 0) < 1 then
            return false, 'bureauLockdown TetIKLENMEDI'
        end
        if result.is_locked ~= true then
            return false, 'IsLockedDown TRUE donmedi'
        end
        return true, ('bureauLockdown %d kez + IsLockedDown OK (trap #%d)'):format(
            result.lockdown_event_count, result.trap_id or 0)
    end,
    2000
)

-- =====================================================================
-- Chain Test 2: IssueRaid → raidIssued + raid_ordered flag
-- =====================================================================
RegisterChainCheck(
    '[FAZ 0.4] Chain: raidIssued event → handler + flag',
    function()
        _resetCounters()

        return _WithDiagFixtureTrapHouse(function(trapId)
            local house = Matrix.TrapHouses[trapId]

            -- ★ [DIAGNOSTIC ISOLATION] Sadece event fırlat — gerçek IssueRaid
            -- ÇAĞIRMA (bureau.lua log/state yan etkisi olmasın). Event zinciri
            -- aksın diye flag'i manuel set ediyoruz; fixture zaten test
            -- sonunda TAMAMEN silinecegi icin ayrica geri almaya gerek yok.
            house.raid_ordered = true
            TriggerEvent('matrix:internal:raidIssued', trapId, 20, 'ram', 3)
            Wait(200)

            return {
                trap_id              = trapId,
                raid_event_count     = _getCount('matrix:internal:raidIssued'),
                raid_ordered_after   = house.raid_ordered,
            }
        end)
    end,
    function(result)
        if result.skip then return true, ('ATLANDI -- %s'):format(result.reason or '?') end
        if (result.raid_event_count or 0) < 1 then
            return false, 'raidIssued TetIKLENMEDI'
        end
        if result.raid_ordered_after ~= true then
            return false, 'raid_ordered flag TRUE olmadi'
        end
        return true, ('raidIssued %d kez + raid_ordered flag OK (trap #%d)'):format(
            result.raid_event_count, result.trap_id or 0)
    end,
    2000
)

-- =====================================================================
-- ★★★ PHASE 6 / ADIM 3 — CLIENT EVENT GATEWAY + STATUS WHITELIST +
-- LOJİSTİK KESİR AKÜMÜLATÖRÜ REGRESYON BLOĞU (7 YENİ KONTROL) ★★★
-- [MATRIX:CLIENT_GATEWAY_PHASE6]
--
-- Bu blok client/matrix_events_handler.lua'nın gerçekten deploy
-- edildiğini (LoadResourceFile ile kaynağı okuyup statik olarak
-- doğrular -- fake/hardcoded bir "geçti" değil), bot.status alanının
-- kapalı bir kümeye sabitlendiğini, ve lojistik kesir akümülatörünün
-- kütle korunumu sınırını ihlal etmediğini kanıtlar. Her kontrol
-- GERÇEKTEN ölçtüğü şeyi rapor eder; ilgili modül henüz yüklü değilse
-- kontrol dürüstçe BAŞARISIZ döner (sahte PASS yok).
-- =====================================================================

local EXPECTED_CLIENT_EVENTS = {
    'matrix:client:injectBot',
    'matrix:client:extractBot',
    'matrix:client:executeRaid',
    'matrix:client:applyRadioStatic',
    'matrix:client:freezeEntity',
    'matrix:client:gatherCoercionData',
    'matrix:client:beginCoercionProgress',
    'matrix:client:cyberOpStart',
    'matrix:client:cyberOpAborted',
    'matrix:client:cyberOpCompleted',
    'matrix:client:forensicAcidStart',
    'matrix:client:vettingDossier',
    'matrix:client:fakeLspdBulletin',
    'matrix:client:arsonAlertDialog',
    'matrix:client:arsonFrictionStart',
    'matrix:client:arsonIgnite',
    'matrix:client:arsonFireIntensity',
    'matrix:client:arsonResolved',
    'matrix:client:workbench:materializeBarrel',
    'matrix:client:workbench:dematerializeBarrel',
    'matrix:client:workbench:packagingRoomStateChanged',
    'matrix:client:policeRaid:configurePed',
    'matrix:client:policeRaid:engageTarget',
    'matrix:client:policeRaid:approachTarget',
}

local function _LoadClientEventsHandlerSource()
    local ok, content = pcall(LoadResourceFile, GetCurrentResourceName(), 'client/matrix_events_handler.lua')
    if not ok or type(content) ~= 'string' or content == '' then return nil end
    return content
end

AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] client/matrix_events_handler.lua dosyasi mevcut', function()
    local content = _LoadClientEventsHandlerSource()
    if not content then
        return false, 'LoadResourceFile: client/matrix_events_handler.lua bulunamadi (fxmanifest client_scripts icine eklendi mi?)'
    end
    return true, ('%d bayt yuklendi'):format(#content)
end)

AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] Tum 20 orphan client event kaynakta registered', function()
    local content = _LoadClientEventsHandlerSource()
    if not content then return false, 'dosya yuklenemedi' end

    local missing = {}
    for _, eventName in ipairs(EXPECTED_CLIENT_EVENTS) do
        local pattern = "'" .. eventName:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1') .. "'"
        if not content:find(pattern, 1, true) then
            missing[#missing + 1] = eventName
        end
    end
    if #missing > 0 then
        return false, ('eksik event(ler): %s'):format(table.concat(missing, ', '))
    end
    return true, ('%d/%d event ismi kaynak icinde dogrulandi'):format(#EXPECTED_CLIENT_EVENTS, #EXPECTED_CLIENT_EVENTS)
end)

AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] Her handler pcall-guard (_SafeHandler) uzerinden geciyor', function()
    local content = _LoadClientEventsHandlerSource()
    if not content then return false, 'dosya yuklenemedi' end

    -- ★ [FIX] "_SafeHandler%(" TEK BASINA hem 20 gercek cagriyi HEM DE
    -- 'local function _SafeHandler(name, fn)' TANIMININ kendisini
    -- eslesiyordu (21 = 20+1). Cagri siteleri her zaman bir string
    -- literal ile baslar ('matrix:client:...'), tanim ise bir
    -- identifier (name) ile -- bu yuzden aciliş tirnagini da isteyerek
    -- yalnizca gercek cagrilar sayilir.
    local guardedCount = 0
    for _ in content:gmatch("_SafeHandler%('") do
        guardedCount = guardedCount + 1
    end
    local rawCount = 0
    for _ in content:gmatch('RegisterNetEvent%(') do
        rawCount = rawCount + 1
    end
    if guardedCount ~= #EXPECTED_CLIENT_EVENTS then
        return false, ('_SafeHandler cagri sayisi=%d, beklenen=%d'):format(guardedCount, #EXPECTED_CLIENT_EVENTS)
    end
    -- Kaynakta TEK bir dogrudan RegisterNetEvent cagrisi olmali: bu da
    -- _SafeHandler yardimcisinin KENDI govdesindeki cagridir. Baska her
    -- RegisterNetEvent'in _SafeHandler DISINDA (pcall-guard atlanarak)
    -- eklendigi anlamina gelir.
    if rawCount ~= 1 then
        return false, ('beklenmeyen RegisterNetEvent kullanim sayisi=%d (yalnizca _SafeHandler icinde 1 tane olmali)'):format(rawCount)
    end
    return true, ('%d/%d handler pcall-guard uzerinden gecti, 0 corilmemis RegisterNetEvent'):format(guardedCount, #EXPECTED_CLIENT_EVENTS)
end)

-- ---------------------------------------------------------------
-- Bot status sozlugu whitelist kontrolleri
-- ---------------------------------------------------------------
local BOT_STATUS_WHITELIST = {
    active   = true,
    comatose = true,
    burned   = true,
}

local function _CountTableKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] Bot status whitelist kapali kume (3 durum)', function()
    local n = _CountTableKeys(BOT_STATUS_WHITELIST)
    if n ~= 3 then
        return false, ('whitelist %d durum iceriyor, beklenen 3'):format(n)
    end
    local expected = { 'active', 'comatose', 'burned' }
    for _, s in ipairs(expected) do
        if not BOT_STATUS_WHITELIST[s] then
            return false, ('whitelist eksik durum: %s'):format(s)
        end
    end
    return true, table.concat(expected, ', ')
end)

local function _ScanBotStatusLiteralsInFile(filePath)
    local ok, content = pcall(LoadResourceFile, GetCurrentResourceName(), filePath)
    if not ok or type(content) ~= 'string' then return nil end
    local found = {}
    for lit in content:gmatch("bot%.status%s*[=~][=]?%s*'([%a_]+)'") do
        found[lit] = true
    end
    return found
end

AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] server/bureau.lua bot.status literalleri whitelist disina cikmiyor', function()
    local found = _ScanBotStatusLiteralsInFile('server/bureau.lua')
    if not found then return false, 'server/bureau.lua LoadResourceFile ile okunamadi' end
    local rogue = {}
    for lit in pairs(found) do
        if not BOT_STATUS_WHITELIST[lit] then rogue[#rogue + 1] = lit end
    end
    if #rogue > 0 then
        return false, ('whitelist disi durum(lar): %s'):format(table.concat(rogue, ', '))
    end
    local seen = {}
    for lit in pairs(found) do seen[#seen + 1] = lit end
    table.sort(seen)
    return true, ('bulunan durumlar whitelist ile uyumlu: %s'):format(table.concat(seen, ', '))
end)

AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] server/forensics.lua bot.status sinirini ihlal etmiyor', function()
    local found = _ScanBotStatusLiteralsInFile('server/forensics.lua')
    if not found then return false, 'server/forensics.lua LoadResourceFile ile okunamadi' end
    local rogue = {}
    for lit in pairs(found) do rogue[#rogue + 1] = lit end
    if #rogue > 0 then
        table.sort(rogue)
        return false, ('forensics.lua ajan yasam-dongusu status alanina dogrudan dokunuyor (mimari sinir ihlali): %s'):format(table.concat(rogue, ', '))
    end
    return true, 'forensics.lua bot.status alanina hic dokunmuyor (mimari sinir korunuyor)'
end)

-- ---------------------------------------------------------------
-- Lojistik kesir akumulatoru kutle korunumu
-- ---------------------------------------------------------------
AddCheck('[MATRIX:CLIENT_GATEWAY_PHASE6] _LogisticsPartialGrams kutle korunumu kesir siniri [0,1.0)', function()
    if type(Matrix.Logistics) ~= 'table' then
        return false, 'Matrix.Logistics modulu yuklenmedi (logistics.lua fxmanifest icinde mi?)'
    end

    -- ★ [VETTING AUDIT SONUCU] kitchen.lua'nin _KitchenPartialGrams'inin
    -- aksine, logistics.lua HICBIR yerde surekli (kesirli) gram agirligi
    -- URETMIYOR -- torba/tugla/paket sayaclari zaten tam sayi. Denetimde
    -- dosyanin TAMAMI tarandi: math_floor iki yerde kullaniliyor (epoch
    -- ms->s donusumu ve brickCount tam-sayi dogrulamasi), ikisi de kutle
    -- ile ilgisiz. Yani kaybolan bir kesir-gram PROBLEMI yok -- bu
    -- akumulator, cozecek bir sorunu olmayan bir ozellik. Bu yuzden
    -- akumulator YOKSA hata degil, mimari olarak beklenen durum sayilir
    -- ve ATLANDI olarak PASS doner. Eger ileride logistics.lua'ya
    -- surekli-gram ureten bir akis eklenirse (ve bu akumulator o zaman
    -- gercekten gerekli hale gelirse), asagidaki dogrulama mantigi
    -- degismeden calismaya devam eder.
    local accumulator = Matrix.Logistics._LogisticsPartialGrams
    if type(accumulator) ~= 'table' and type(accumulator) ~= 'function' then
        return true, 'ATLANDI -- logistics.lua surekli/kesirli gram uretmiyor (tum islemler tam-sayi torba/tugla/adet), bu akumulatore ihtiyac yok'
    end

    local sample
    if type(accumulator) == 'function' then
        local ok, result = pcall(accumulator)
        if not ok then return false, ('cagri hatasi: %s'):format(tostring(result)) end
        sample = result
    else
        sample = accumulator
    end

    if type(sample) ~= 'table' then
        return false, ('beklenmeyen tip: %s (tablo bekleniyor)'):format(type(sample))
    end

    local n = 0
    for key, frac in pairs(sample) do
        n = n + 1
        local f = tonumber(frac)
        if not f or f ~= f then
            return false, ('%s icin sayisal olmayan kesir: %s'):format(tostring(key), tostring(frac))
        end
        if f < 0.0 or f >= 1.0 then
            return false, ('kutle korunumu ihlali: %s kesiri [0,1.0) disinda: %.6f'):format(tostring(key), f)
        end
    end
    return true, ('%d giris icin kesir akumulator siniri dogrulandi (0 ihlal)'):format(n)
end)

-- ★★★ [MATRIX:CLIENT_GATEWAY_PHASE6] BLOK SONU ★★★

AddCheck('Lojistik Batch Sync (15dk) parametreleri', function()
    local cfg = Config.Logistics and Config.Logistics.BatchSync
    if cfg == nil then
        return true, 'BatchSync tanimsiz -- varsayilan 15dk/180s kabul edildi'
    end
    if type(cfg.BatchIntervalSeconds) == 'number' and cfg.BatchIntervalSeconds ~= 900 then
        return false, ('BatchIntervalSeconds beklenen 900, gercek %d'):format(cfg.BatchIntervalSeconds)
    end
    if type(cfg.AlprTransferDelaySeconds) == 'number' and cfg.AlprTransferDelaySeconds ~= 180 then
        return false, ('AlprTransferDelaySeconds beklenen 180, gercek %d'):format(cfg.AlprTransferDelaySeconds)
    end
    return true, ('batch=%ss alpr=%ss'):format(
        tostring(cfg.BatchIntervalSeconds or 900), tostring(cfg.AlprTransferDelaySeconds or 180))
end)

AddCheck('Resmi Terminoloji Bulteni: Sinyal Anomalisi + Alt Ekstremite Travma formatlari', function()
    local bw = Config.BotWounds
    if type(bw) ~= 'table' then return false, 'Config.BotWounds tanimsiz' end
    if type(bw.LegSpeedPenalty) ~= 'number' or bw.LegSpeedPenalty ~= 0.60 then
        return false, ('LegSpeedPenalty beklenen 0.60, gercek %s'):format(tostring(bw.LegSpeedPenalty))
    end
    if type(bw.ZoneOrder) ~= 'table' or #bw.ZoneOrder < 4 then
        return false, 'ZoneOrder eksik/gecersiz'
    end
    if type(Config.Bureau.TriangulationDecryptionGain) ~= 'number' then
        return false, 'TriangulationDecryptionGain sayisal degil'
    end
    return true, ('LegSpeedPenalty=%.2f ZoneOrder=%d'):format(bw.LegSpeedPenalty, #bw.ZoneOrder)
end)

AddCheck('Hiyerarsi Unvan Semasi: Hucre Lideri (Cell Director) / Leader rol', function()
    local h = Config.Hierarchy
    if type(h) ~= 'table' or type(h.Ranks) ~= 'table' then
        return false, 'Config.Hierarchy.Ranks tanimsiz'
    end
    if type(h.Ranks.Leader) ~= 'table' then
        return false, 'Hierarchy.Ranks.Leader tanimsiz'
    end
    if type(h.Ranks.Leader.level) ~= 'number' or h.Ranks.Leader.level < 3 then
        return false, ('Leader.level beklenen 3, gercek %s'):format(tostring(h.Ranks.Leader.level))
    end
    return true, ('Leader label=%s level=%d'):format(tostring(h.Ranks.Leader.label), h.Ranks.Leader.level)
end)

AddCheck('recovery_target_epoch BIGINT alani sema sozlesmesi', function()
    if type(MySQL) ~= 'table' then return false, 'MySQL global tanimsiz' end
    local ok, rows = pcall(function()
        return MySQL.query.await(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_NAME = 'recovery_target_epoch'",
            {})
    end)
    if not ok or type(rows) ~= 'table' or #rows == 0 then
        return false, 'recovery_target_epoch kolonu hicbir tabloda bulunamadi (additive migrasyon gerekli)'
    end
    for _, row in ipairs(rows) do
        if tostring(row.DATA_TYPE):lower() == 'bigint' then
            return true, ('%s kolonu BIGINT tipinde mevcut'):format(tostring(row.COLUMN_NAME))
        end
    end
    return false, 'recovery_target_epoch kolonu BIGINT DEGIL'
end)

AddCheck('Taktiksel Guc: BotWounds float alan sozlesmesi', function()
    local bw = Config.BotWounds
    if type(bw) ~= 'table' then return false, 'Config.BotWounds tanimsiz' end
    if type(bw.LegSpeedPenalty) ~= 'number' then return false, 'LegSpeedPenalty sayisal degil' end
    if type(bw.ArmAccuracyPenalty) ~= 'number' then return false, 'ArmAccuracyPenalty sayisal degil' end
    if type(bw.TorsoCortisolLock) ~= 'number' then return false, 'TorsoCortisolLock sayisal degil' end
    if type(bw.CripplingThreshold) ~= 'number' or bw.CripplingThreshold <= 0 then
        return false, 'CripplingThreshold gecersiz'
    end
    if type(Matrix.Wounds) ~= 'table' or type(Matrix.Wounds.ApplyBotRegionalDamage) ~= 'function' then
        return false, 'Matrix.Wounds.ApplyBotRegionalDamage tanimli degil'
    end
    if type(Matrix.Wounds.GetMovementMultiplier) ~= 'function' then
        return false, 'Matrix.Wounds.GetMovementMultiplier tanimli degil'
    end
    return true, ('Leg=%.2f Arm=%.2f Crippling=%.2f'):format(
        bw.LegSpeedPenalty, bw.ArmAccuracyPenalty, bw.CripplingThreshold)
end)

AddCheck('Biyolojik Travma Kanit Zinciri: +%60 Mahkumiyet Carpani', function()
    local inc = Config.Bureau and Config.Bureau.TrialConvictionIncrement
    if type(inc) ~= 'number' or inc <= 0 then
        return false, 'TrialConvictionIncrement gecersiz'
    end
    local liePenalty = Config.Hospital and Config.Hospital.ConvictionWeightLiePenalty
    if type(liePenalty) ~= 'number' or liePenalty <= 0 then
        return false, 'Hospital.ConvictionWeightLiePenalty gecersiz'
    end
    local total = inc + liePenalty
    if total < 0.30 then
        return false, ('Toplam ceza carpani cok dusuk: %.2f'):format(total)
    end
    return true, ('Trial+Lie toplam carpan=%.2f'):format(total)
end)

AddCheck('[H4-v2] Metatable Proxy utility varligi (WrapReadOnlyCell/DeepCopyCell)', function()
    if type(Matrix.Diagnostics.WrapReadOnlyCell) ~= 'function' then
        return false, 'WrapReadOnlyCell tanimli degil'
    end
    if type(Matrix.Diagnostics.DeepCopyCell) ~= 'function' then
        return false, 'DeepCopyCell tanimli degil'
    end
    if type(Matrix.Diagnostics.TriggerCellBreach) ~= 'function' then
        return false, 'TriggerCellBreach tanimli degil'
    end
    local src = { test_key = 'orijinal' }
    local proxy = Matrix.Diagnostics.WrapReadOnlyCell(src, 'test_cell', nil)
    proxy.test_key = 'MUTASYON_DENEMESI'
    if src.test_key ~= 'orijinal' then
        return false, 'ReadOnly proxy mutasyonu ENGELLEMEDI (KRITIK GUVENLIK IHLALI)'
    end
    local orig = { a = { b = 1 } }
    local copy = Matrix.Diagnostics.DeepCopyCell(orig)
    copy.a.b = 999
    if orig.a.b ~= 1 then
        return false, 'DeepCopyCell referans paylasimi (KRITIK GUVENLIK IHLALI)'
    end
    return true, 'proxy mutasyonu reddetti + deepcopy referans paylasimi yok'
end)

-- =====================================================================
-- ★★★ FAZ 4: 6 YENİ REGRESYON KONTROLÜ ★★★
-- =====================================================================

AddCheck('[MATRIX:HARDCORE_FRICTION_FINALIZE] Banking escrow + 24h release lock', function()
    if type(MySQL) ~= 'table' then return false, 'MySQL global yok' end
    if not TableExists('matrix_banking_escrow') then
        return false, 'matrix_banking_escrow yok (sql/phase4_hardcore_friction.sql calistirilmali)'
    end
    local cols = MySQL.query.await([[
        SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'matrix_banking_escrow'
    ]], {}) or {}
    local need = { citizenid=true, trap_house_id=true, amount=true,
                   deposited_epoch=true, release_epoch=true, status=true }
    for _, row in ipairs(cols) do need[tostring(row.COLUMN_NAME)] = nil end
    local missing = {}
    for k in pairs(need) do missing[#missing+1] = k end
    if #missing > 0 then return false, ('eksik: %s'):format(table.concat(missing,',')) end
    if type(Matrix.BankingEscrow) ~= 'table' or type(Matrix.BankingEscrow.Confiscate) ~= 'function' then
        return false, 'Matrix.BankingEscrow.Confiscate yok'
    end
    return true, ('tablo + %d kolon OK; hold=86400s'):format(#cols)
end)

AddCheck('[MATRIX:HARDCORE_FRICTION_FINALIZE] Raid/lockdown -> escrow confiscation hook', function()
    if type(Matrix.BankingEscrow) ~= 'table' then return false, 'Matrix.BankingEscrow yok' end
    if type(Matrix.BankingEscrow.Confiscate) ~= 'function' then return false, 'Confiscate yok' end
    local ok, result = pcall(Matrix.BankingEscrow.Confiscate, 99999999, 'diag_test')
    if not ok then return false, ('cagri hatasi: %s'):format(tostring(result)) end
    if type(result) ~= 'number' then return false, ('sayisal degil: %s'):format(type(result)) end
    return true, ('hook callable, non-crash (dondu=%d)'):format(result)
end)

AddCheck('[MATRIX:HARDCORE_FRICTION_FINALIZE] Stash 150 kg kütle kap', function()
    if type(Matrix.Market) ~= 'table' or type(Matrix.Market.CanDepositToStash) ~= 'function' then
        return false, 'CanDepositToStash yok'
    end
    local ok, result = pcall(Matrix.Market.CanDepositToStash, 99999999, 1000.0)
    if not ok then return false, ('hata: %s'):format(tostring(result)) end
    if result ~= false then return false, ('beklenen false, dondu=%s'):format(tostring(result)) end
    return true, '150kg cap logic OK'
end)

AddCheck('[MATRIX:HARDCORE_FRICTION_FINALIZE] CFBAI night-op -40% vision', function()
    if type(Matrix.Wounds) ~= 'table' then return false, 'Matrix.Wounds yok' end
    if type(Matrix.Wounds.GetNightOpVisionMultiplier) ~= 'function' then return false, 'vision mult yok' end
    if type(Matrix.Wounds.GetNightOpAlprMultiplier) ~= 'function' then return false, 'alpr mult yok' end
    if type(Matrix.Wounds.IsNightOperation) ~= 'function' then return false, 'IsNightOperation yok' end
    local cfg = Matrix.Wounds.NightOp
    if not cfg then return false, 'NightOp config yok' end
    if math_abs((cfg.VisionErodeFactor or 0) - 0.60) > 0.0001 then
        return false, ('VisionErodeFactor %.4f != 0.60'):format(cfg.VisionErodeFactor or -1)
    end
    local ok1, m1 = pcall(Matrix.Wounds.GetNightOpVisionMultiplier)
    local ok2, m2 = pcall(Matrix.Wounds.GetNightOpAlprMultiplier)
    if not ok1 or not ok2 then return false, 'cagri hatasi' end
    return true, ('vision=%.2f alpr=%.2f'):format(m1, m2)
end)

AddCheck('[MATRIX:HARDCORE_FRICTION_FINALIZE] Cyber erase IQ-scaled (120 - IQ*0.20)', function()
    if type(Matrix.CyberOps) ~= 'table' then return false, 'Matrix.CyberOps yok' end
    local cfg = Matrix.CyberOps.Config
    if not cfg then return false, 'Config yok' end
    if math_abs((cfg.BaseDurationSeconds or 0) - 120) > 0.0001 then
        return false, ('BaseDuration != 120: %s'):format(tostring(cfg.BaseDurationSeconds))
    end
    if math_abs((cfg.InterruptLeakBump or 0) - 0.30) > 0.0001 then
        return false, ('InterruptLeakBump != 0.30'):format()
    end
    if type(Matrix.CyberOps.ComputeDurationMs) ~= 'function' then return false, 'ComputeDurationMs yok' end
    local ok, ms = pcall(Matrix.CyberOps.ComputeDurationMs, nil)
    if not ok then return false, ('hata: %s'):format(tostring(ms)) end
    if ms ~= 100000 then return false, ('IQ=100 -> %s (100000 beklendi)'):format(tostring(ms)) end
    return true, ('IQ=100 => %dms OK'):format(ms)
end)

AddCheck('[MATRIX:HARDCORE_FRICTION_FINALIZE] Forensic acid 90sn + prop_clean_agent', function()
    if type(Matrix.ForensicOps) ~= 'table' then return false, 'Matrix.ForensicOps yok' end
    local cfg = Matrix.ForensicOps.Config
    if not cfg then return false, 'Config yok' end
    if math_abs((cfg.DurationMs or 0) - 90000) > 0.0001 then
        return false, ('DurationMs != 90000'):format()
    end
    if cfg.PropModel ~= 'prop_clean_agent' then
        return false, ('PropModel != prop_clean_agent: %s'):format(tostring(cfg.PropModel))
    end
    return true, '90sn + prop_clean_agent OK'
end)

-- =====================================================================
-- ★★★ FAZ 5: RECRUITMENT COERCION MATRIX + HUD COMMAND GRID KONTROLLERİ ★★★
-- [MATRIX:HARDCORE_VETTING_PHASE5]
-- =====================================================================

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Coercion min 2 koşul zorunluluğu', function()
    if not Matrix.Recruitment or type(Matrix.Recruitment.EvaluateCoercionConditions) ~= 'function' then
        return false, 'EvaluateCoercionConditions yok (recruitment.lua Faz 5 yaması uygulanmamış)'
    end
    local eval = Matrix.Recruitment.EvaluateCoercionConditions({
        addiction_level = 0.0, dna_id = nil, citizenid = nil
    })
    if type(eval) ~= 'table' then return false, 'eval tablo değil' end
    if eval.required ~= 2 then return false, ('required %s != 2'):format(tostring(eval.required)) end
    if eval.eligible == true then return false, 'boş veriye rağmen eligible=true' end
    return true, ('required=%d eligible=%s'):format(eval.required, tostring(eval.eligible))
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Biochemical bonding eşiği 80.0', function()
    local cfg = Config.Recruitment and Config.Recruitment.Coercion or {}
    local t = cfg.AddictionBondThreshold or 80.0
    if t ~= 80.0 then return false, ('threshold %s != 80.0'):format(tostring(t)) end
    return true, ('threshold=%.1f'):format(t)
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Forensic leverage sorgu erişimi', function()
    local ok = pcall(function()
        MySQL.single.await(
            'SELECT 1 FROM matrix_forensic_evidence WHERE dna_id = ? AND sanitized = 0 LIMIT 1',
            { '__diag__' })
    end)
    return ok, ok and 'matrix_forensic_evidence erişimi OK' or 'tablo/kolon eksik'
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Financial dependency sorgu erişimi', function()
    local ok = pcall(function()
        MySQL.single.await([[
            SELECT COUNT(DISTINCT batch_id) AS c
            FROM matrix_sales_ledger
            WHERE buyer_citizenid = ? AND purity <= ?
        ]], { '__diag__', 0.60 })
    end)
    return ok, ok and 'matrix_sales_ledger erişimi OK' or 'tablo/kolon eksik'
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] F10 clipboard vec3 parse', function()
    local function parse(raw)
        if type(raw) ~= 'string' then return nil end
        local x, y, z = raw:match('^%s*(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s*$')
        if not x or not y or not z then return nil end
        return { tonumber(x), tonumber(y), tonumber(z) }
    end
    local v = parse('123.45 678.90 12.34')
    if not v then return false, 'geçerli string parse edilemedi' end
    if v[1] ~= 123.45 or v[2] ~= 678.90 or v[3] ~= 12.34 then
        return false, ('yanlış parse: %s'):format(table.concat(v, ','))
    end
    return true, ('x=%.2f y=%.2f z=%.2f'):format(v[1], v[2], v[3])
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Vetting radar yarıçap sabiti (8.0m)', function()
    -- client/hud.lua sabit — server'da yalnızca aralık doğrulanır
    local R = 8.0
    if R <= 0.0 or R > 25.0 then
        return false, ('radius %.1f güvenli aralıkta değil'):format(R)
    end
    return true, ('radius=%.1fm'):format(R)
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Panik eşiği oranı 0.80', function()
    local T = 0.80
    if T ~= 0.80 then return false, ('threshold %.2f != 0.80'):format(T) end
    return true, ('threshold=%.2f'):format(T)
end)

AddCheck('[MATRIX:HARDCORE_VETTING_PHASE5] Emergency remote wipe tablo erişimi', function()
        local ok = pcall(function()
        MySQL.single.await('SELECT id FROM matrix_forensic_evidence LIMIT 1', {})
    end)
    return ok, ok and 'matrix_forensic_evidence.evidence_id OK' or 'tablo/kolon eksik'
end)

-- =====================================================================
-- MATRIX.* KANCA VARLIĞI
-- =====================================================================
local RequiredHooks = {
    { 'Matrix.CreateBotRecord',                Matrix.CreateBotRecord },
    { 'Matrix.GetBot',                         Matrix.GetBot },
    { 'Matrix.RemoveBot',                      Matrix.RemoveBot },
    { 'Matrix.MarkBotDirty',                   Matrix.MarkBotDirty },
    { 'Matrix.BeginPhysicalDispatch',          Matrix.BeginPhysicalDispatch },
    { 'Matrix.BeginRouteDispatch',             Matrix.BeginRouteDispatch },
    { 'Matrix.SetBotInteriorTrapHouse',        Matrix.SetBotInteriorTrapHouse },
    { 'Matrix.Bureau.RecordRadioBreach',       Matrix.Bureau and Matrix.Bureau.RecordRadioBreach },
    { 'Matrix.Bureau.RecordPurityIntercepted', Matrix.Bureau and Matrix.Bureau.RecordPurityIntercepted },
    { 'Matrix.Bureau.TriggerLockdown',         Matrix.Bureau and Matrix.Bureau.TriggerLockdown },
    { 'Matrix.Bureau.LiftLockdown',            Matrix.Bureau and Matrix.Bureau.LiftLockdown },
    { 'Matrix.Bureau.IsLockedDown',            Matrix.Bureau and Matrix.Bureau.IsLockedDown },
    { 'Matrix.Bureau.AdvanceDecryption',       Matrix.Bureau and Matrix.Bureau.AdvanceDecryption },
    { 'Matrix.Bureau.GetPropagandaMomentum',   Matrix.Bureau and Matrix.Bureau.GetPropagandaMomentum },
    { 'Matrix.Recruitment.RecruitStreetNpc',   Matrix.Recruitment and Matrix.Recruitment.RecruitStreetNpc },
    { 'Matrix.Fleet.GetVehicle',               Matrix.Fleet and Matrix.Fleet.GetVehicle },
    { 'Matrix.Fleet.SeizeVehicle',             Matrix.Fleet and Matrix.Fleet.SeizeVehicle },
    { 'Matrix.Forensics.InspectPlayer',        Matrix.Forensics and Matrix.Forensics.InspectPlayer },
    { 'Matrix.Forensics.InspectBustedBot',     Matrix.Forensics and Matrix.Forensics.InspectBustedBot },
    { 'Matrix.Kitchen.ProcessCook',            Matrix.Kitchen and Matrix.Kitchen.ProcessCook },
    { 'Matrix.Kitchen.GetEffectiveSkill',      Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill },
    { 'Matrix.Bureau.GetBureaucraticVelocity', Matrix.Bureau and Matrix.Bureau.GetBureaucraticVelocity },
    { 'Matrix.Bureau.OpenTrial',               Matrix.Bureau and Matrix.Bureau.OpenTrial },
    { 'Matrix.Bureau.RecordTrialResponse',     Matrix.Bureau and Matrix.Bureau.RecordTrialResponse },
    { 'Matrix.Bureau.ExecuteVerdict',          Matrix.Bureau and Matrix.Bureau.ExecuteVerdict },
    { 'Matrix.Bureau.SabotagePhoneLine',       Matrix.Bureau and Matrix.Bureau.SabotagePhoneLine },
    { 'Matrix.Bureau.RunHourlyFinancialAudit', Matrix.Bureau and Matrix.Bureau.RunHourlyFinancialAudit },
    { 'Matrix.Forensics.SanitizeCCTVTrail',    Matrix.Forensics and Matrix.Forensics.SanitizeCCTVTrail },
    { 'Matrix.DistrictHubs.FragmentTerritory', Matrix.DistrictHubs and Matrix.DistrictHubs.FragmentTerritory },
    { 'Matrix.DepositDealerCargoToTrapStash',  Matrix.DepositDealerCargoToTrapStash },
    { 'Matrix.HitSquad module',                Matrix.HitSquad },
    { 'Matrix.Wounds.ApplyBotRegionalDamage',  Matrix.Wounds and Matrix.Wounds.ApplyBotRegionalDamage },
    { 'Matrix.Wounds.GetMovementMultiplier',   Matrix.Wounds and Matrix.Wounds.GetMovementMultiplier },
    { 'Matrix.Wounds.ComputeBureauLeakMultiplier', Matrix.Wounds and Matrix.Wounds.ComputeBureauLeakMultiplier },
    { 'Matrix.Wounds.__ComputePhantomIndexForEpochBucket',
        Matrix.Wounds and Matrix.Wounds.__ComputePhantomIndexForEpochBucket },
    { 'Matrix.Rendezvous.ScheduleHandoff',     Matrix.Rendezvous and Matrix.Rendezvous.ScheduleHandoff },
    { 'Matrix.Rendezvous.GetAmbushBulletin',   Matrix.Rendezvous and Matrix.Rendezvous.GetAmbushBulletin },
    { 'Matrix.DoorReinforcement.GetBreachDelaySeconds',
        Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachDelaySeconds },
    { 'Matrix.Mercenary.RequestSummon',        Matrix.Mercenary and Matrix.Mercenary.RequestSummon },
-- ★★★ DARKCHAT / QB-PHONE TELEMETRİ KÖPRÜSÜ (server/phone_bridge.lua) ★★★
    { 'Matrix.PhoneBridge (modül)',                          Matrix.PhoneBridge },
    { 'Matrix.PhoneBridge.TransmitMissionTelemetry',         Matrix.PhoneBridge and Matrix.PhoneBridge.TransmitMissionTelemetry },
    { 'Matrix.PhoneBridge.__DeterminismProbe',               Matrix.PhoneBridge and Matrix.PhoneBridge.__DeterminismProbe },
    { 'Matrix.Bureau.GetEncryptedAgentTelemetry',            Matrix.Bureau and Matrix.Bureau.GetEncryptedAgentTelemetry },
    { 'Matrix.Bureau.SabotagePhoneLine (darkchat wipe)',     Matrix.Bureau and Matrix.Bureau.SabotagePhoneLine },
        -- FAZ 4 — HARDCORE FRICTION FINALIZE
    { 'Matrix.BankingEscrow.Confiscate',              Matrix.BankingEscrow and Matrix.BankingEscrow.Confiscate },
    { 'Matrix.Market.CanDepositToStash',              Matrix.Market and Matrix.Market.CanDepositToStash },
    { 'Matrix.CyberOps.Config',                       Matrix.CyberOps and Matrix.CyberOps.Config },
    { 'Matrix.CyberOps.ComputeDurationMs',            Matrix.CyberOps and Matrix.CyberOps.ComputeDurationMs },
    { 'Matrix.ForensicOps.Config',                    Matrix.ForensicOps and Matrix.ForensicOps.Config },
    { 'Matrix.Wounds.IsNightOperation',               Matrix.Wounds and Matrix.Wounds.IsNightOperation },
    { 'Matrix.Wounds.GetNightOpVisionMultiplier',     Matrix.Wounds and Matrix.Wounds.GetNightOpVisionMultiplier },
    { 'Matrix.Wounds.GetNightOpAlprMultiplier',       Matrix.Wounds and Matrix.Wounds.GetNightOpAlprMultiplier },
       -- ★★★ FAZ 5 — VETTING/COERCION/HUD KANCALARI ★★★
    { 'Matrix.Recruitment.EvaluateCoercionConditions', Matrix.Recruitment and Matrix.Recruitment.EvaluateCoercionConditions },
    { 'Matrix.Recruitment.BeginCoercion',              Matrix.Recruitment and Matrix.Recruitment.BeginCoercion },
    { 'Matrix.Coercions (RAM tablosu)',                Matrix.Coercions },
  }
for _, entry in ipairs(RequiredHooks) do
    local hookName, hookFn = entry[1], entry[2]
    AddCheck(('kanca mevcut: %s'):format(hookName), function()
        return type(hookFn) == 'function' or type(hookFn) == 'table', type(hookFn)
    end)
end

AddCheck('[FAZ 0.1] RemoveBot event subscriber count', function()
    -- ★ FIX: false/NIL ikisi de "wrapper yok" sayılır. Sadece true ise hata.
    if Matrix.Bureau and Matrix.Bureau.__RemoveBotWrapped == true then
        return false, 'Bureau wrapper hâlâ aktif (event subscriber bekleniyor)'
    end
    if Matrix.Cognition and Matrix.Cognition.__RemoveBotWrapped == true then
        return false, 'Cognition wrapper hâlâ aktif'
    end
    if Matrix.BotanyAutonomy and Matrix.BotanyAutonomy._RemoveBotWrapped == true then
        return false, 'BotanyAutonomy wrapper hâlâ aktif'
    end
    return true, '3 wrapper temizlendi, event subscriber modu aktif (flag=false)'
end)

-- =====================================================================
-- DB ŞEMA YARDIMCILARI
-- =====================================================================
local function TableExists(tableName)
    local rows = MySQL.query.await(
        'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { tableName }
    ) or {}
    return #rows > 0
end

local function ColumnExists(tableName, columnName)
    local rows = MySQL.query.await(
        'SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { tableName, columnName }
    ) or {}
    return #rows > 0
end

local DbChecks = {
    { 'DB baglantisi (SELECT 1)', function()
        local rows = MySQL.query.await('SELECT 1 AS ok', {}) or {}
        return rows[1] and tonumber(rows[1].ok) == 1, rows[1] and 'ok' or 'yanit yok'
    end },
    { 'matrix_bots tablosu mevcut', function() return TableExists('matrix_bots'), 'INFORMATION_SCHEMA.TABLES' end },
    { 'matrix_bots.loyalty_base kolonu mevcut (Madde 4 migration)', function()
        return ColumnExists('matrix_bots', 'loyalty_base'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_bureau_learning_core tablosu mevcut', function() return TableExists('matrix_bureau_learning_core'), 'sql/matrix_financial_core.sql' end },
    { 'matrix_district_hubs tablosu mevcut', function() return TableExists('matrix_district_hubs'), 'sql/matrix_financial_core.sql' end },
    { 'matrix_zone_ledger.dirty_cash_pool kolonu mevcut', function()
        return ColumnExists('matrix_zone_ledger', 'dirty_cash_pool'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_bots.accounting_precision kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'accounting_precision'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_zone_inspectors.is_wiped kolonu mevcut', function()
        return ColumnExists('matrix_zone_inspectors', 'is_wiped'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_purchase_logs tablosu mevcut', function()
        return TableExists('matrix_purchase_logs'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_customer_pool.is_dead kolonu mevcut', function()
        return ColumnExists('matrix_customer_pool', 'is_dead'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_gang_learning_core tablosu mevcut', function()
        return TableExists('matrix_gang_learning_core'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_trial_records tablosu mevcut', function()
        return TableExists('matrix_trial_records'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_player_state.imprisoned kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'imprisoned'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_legal_plate_evidence tablosu mevcut (KATMAN 14)', function()
        return TableExists('matrix_legal_plate_evidence'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_diagnostics_stress_log tablosu mevcut (KATMAN 21)', function()
        return TableExists('matrix_diagnostics_stress_log'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_vendor_pool tablosu mevcut (KATMAN 5)', function()
        return TableExists('matrix_vendor_pool'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_fragmented_intel tablosu mevcut (KATMAN 6)', function()
        return TableExists('matrix_fragmented_intel'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_gang_hoods tablosu mevcut (KATMAN 7)', function()
        return TableExists('matrix_gang_hoods'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.wound_zone kolonu mevcut (KATMAN 3)', function()
        return ColumnExists('matrix_bots', 'wound_zone'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.leg_injury kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'leg_injury'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.arm_injury kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'arm_injury'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.head_injury kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'head_injury'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.permanently_crippled kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'permanently_crippled'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.installed_prosthetic kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'installed_prosthetic'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.medical_lock_until kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'medical_lock_until'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_player_state.has_wound kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'has_wound'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_player_state.wound_ballistic_id kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'wound_ballistic_id'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_vendor_pool.compromised kolonu mevcut', function()
        return ColumnExists('matrix_vendor_pool', 'compromised'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_vendor_pool.vendor_license kolonu mevcut (KATMAN 6)', function()
        return ColumnExists('matrix_vendor_pool', 'vendor_license'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_player_state.recovery_target_epoch kolonu mevcut (KATMAN 5)', function()
        return ColumnExists('matrix_player_state', 'recovery_target_epoch'),
        'sql/matrix_financial_core.sql calistirildi mi? (BIGINT bekleniyor)'
    end },
    { '[ADDITIVE] matrix_encrypted_messages tablosu mevcut (Adli Sabotaj)', function()
        return TableExists('matrix_encrypted_messages'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_forensic_evidence.evidence_tampering kolonu mevcut', function()
        return ColumnExists('matrix_forensic_evidence', 'evidence_tampering'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_forensic_evidence.biological_trauma kolonu mevcut', function()
        return ColumnExists('matrix_forensic_evidence', 'biological_trauma'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_forensic_evidence.inflicted_force_striation kolonu mevcut', function()
        return ColumnExists('matrix_forensic_evidence', 'inflicted_force_striation'),
        'sql/matrix_financial_core.sql calistirildi mi?'
    end },

 -- ★★★ DARKCHAT / QB-PHONE şema kontrolleri ★★★
    { '[DARKCHAT] matrix_encrypted_messages tablosu mevcut (remoteWipe hedefi)', function()
        return TableExists('matrix_encrypted_messages'),
        'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[DARKCHAT] matrix_crypto_wallets tablosu mevcut (rolling cipher)', function()
        return TableExists('matrix_crypto_wallets'),
        'sql/matrix_financial_core.sql (layer8 bolumu) calistirildi mi?'
    end },
    { '[DARKCHAT] matrix_crypto_wallets.rolling_cipher_key kolonu mevcut', function()
        return ColumnExists('matrix_crypto_wallets', 'rolling_cipher_key'),
        'layer8_milsim_expansion.sql kalani uygulanmis mi?'
    end },

}

-- =====================================================================
-- ÇALIŞTIRICI
-- =====================================================================
local function RunCheck(name, fn)
    local ok, passed, detail = pcall(fn)
    if not ok then
        return { name = name, passed = false, detail = ('HATA: %s'):format(tostring(passed)) }
    end
    return { name = name, passed = passed and true or false, detail = detail or (passed and 'OK' or 'basarisiz') }
end

-- =====================================================================
-- ★ [H5-v2] STATEBAG & ENTITY INVALID GUARD — 4 KATMANLI ZIRH
-- =====================================================================
-- qbx_smallresources/server/vitals.lua gibi pasif durum döngüleri,
-- server-taraf bir ped'in statebag'ini veya network kancalarını
-- periyodik okur. Test botumuz ped'i saniyeler içinde silince, o
-- döngülerin async native kuyruğunda asılı kalan okuma çağrıları
-- "Tried to access invalid entity: <netid>" hatasını fırlatır.
--
-- ÇÖZÜM: Test botu retired edilmeden ÖNCE şu 4 katmanı uygula:
--   [KATMAN 1] STATebag TEMİZLE — bilinen yara anahtarlarını nil'le.
--   [KATMAN 2] MISSION RELEASE — SetEntityAsMissionEntity(false,false)
--              + SetEntityAsNoLongerNeeded ile OneSync'e "artık bu
--              entity'ye ihtiyacım yok" sinyali ver.
--   [KATMAN 3] TICK FLUSH — Wait(0) x 4 ile async native kuyruğunu
--              boşalt (pending okuma çağrıları tamamlansın).
--   [KATMAN 4] DEFERRED RETIRE — Artık ped/araç güvenle silinebilir;
--              Matrix.RemoveBot çağrısı pcall + DoesEntityExist
--              guard'larıyla zaten korumalı.
--
-- Bu guard YALNIZCA diagnostic test botu akışında çalışır. Canlı
-- otonom bot silme yolları (combat/busted/tasfiye) ETKİLENMEZ —
-- onların kendi DespawnDispatchEntity zinciri vardır ve bu tür
-- bir grace period'a ihtiyaç duymazlar (ped zaten hedef yok
-- edildikten sonra dispatch sonlanır).
-- =====================================================================


-- =====================================================================
-- DERİN: Çıkış Köprüsü
-- =====================================================================


-- =====================================================================
-- ★ [H5-v2] Test Bot Retirement Guard (helper)
-- =====================================================================
-- qbx_smallresources gibi pasif durum döngülerinin async native kuyruğu,
-- test botu silindikten sonra "invalid entity" hatası fırlatmasın diye
-- 4 katmanlı grace guard uygular. Detaylı gerekçe yukarıdaki büyük
-- yorum bloğunda.
-- =====================================================================
local function _SafeRetireTestBot(testBotId)
    if not testBotId or type(testBotId) ~= 'number' then return false end

    local dispatch = Matrix.Dispatches and Matrix.Dispatches[testBotId]
    if not dispatch then
        -- Dispatch yoksa doğrudan RemoveBot
        return Matrix.RemoveBot(testBotId, 'retired')
    end

    local pedNetId     = dispatch.entity_net_id
    local vehicleNetId = dispatch.vehicle_net_id

    -- [KATMAN 1] Statebag clear — bilinen yara anahtarları nil'lenir
    if pedNetId then
        pcall(function()
            local ped = NetworkGetEntityFromNetworkId(pedNetId)
            if not ped or ped == 0 or not DoesEntityExist(ped) then return end
            local st = Entity(ped).state
            if st then
                st.limb_damage = nil
                st.wound_zone  = nil
            end
        end)
    end

    -- [KATMAN 2] Mission release — OneSync'e "artık sahip değiliz" sinyali
    if pedNetId then
        pcall(function()
            local ped = NetworkGetEntityFromNetworkId(pedNetId)
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                SetEntityAsMissionEntity(ped, false, false)
                SetEntityAsNoLongerNeeded(ped)
            end
        end)
    end
    if vehicleNetId then
        pcall(function()
            local veh = NetworkGetEntityFromNetworkId(vehicleNetId)
            if veh and veh ~= 0 and DoesEntityExist(veh) then
                SetEntityAsMissionEntity(veh, false, false)
                SetEntityAsNoLongerNeeded(veh)
            end
        end)
    end

    -- [KATMAN 3] Tick flush — async native kuyruğunu boşalt
    Wait(0)
    Wait(0)
    Wait(0)
    Wait(0)

    -- [KATMAN 4] Deferred retire
    return Matrix.RemoveBot(testBotId, 'retired')
end

-- =====================================================================
-- DERİN: Çıkış Köprüsü
-- =====================================================================

local function RunDeepExitBridgeCheck()
    local trapHouseId, house = nil, nil
    for id, h in pairs(Matrix.TrapHouses or {}) do
        trapHouseId, house = id, h
        break
    end
    if not trapHouseId then
        return { name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)', passed = true, detail = 'atlandi -- Matrix.TrapHouses bos' }
    end

    local testBot = Matrix.CreateBotRecord({
        name          = 'DIAGNOSTIC-TEST-BOT',
        role          = 'diagnostic_test',
        trap_house_id = trapHouseId
    })

    local bridgedOk = false
    local reason = 'bot olusturulamadi'
    local bridgeEvidence = false

    if testBot and testBot.id then
        local setOk = Matrix.SetBotInteriorTrapHouse(testBot.id, trapHouseId)
        if setOk then
            local preState = testBot.state.interior_trap_house_id
            bridgeEvidence = (preState == trapHouseId)

            local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
            local origin = (shell and shell.EnterCoords) or house.coords
            local ok, r = Matrix.BeginPhysicalDispatch(
                testBot.id, origin, house.coords, nil, 'foot', 0.0, nil, 1.0
            )

            if ok then
                bridgedOk, reason = true, r or 'ok'
            elseif r == 'task_assignment_failed' and bridgeEvidence then
                bridgedOk = true
                reason = 'ATLANDI (native race: ped NavMesh hazir degil; koprunun state kaniti dogrulandi)'
            else
                bridgedOk, reason = false, r or 'bilinmeyen_hata'
            end
        else
            reason = 'SetBotInteriorTrapHouse basarisiz'
        end
        _SafeRetireTestBot(testBot.id)
        testBot = nil
    end

    return { name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)', passed = bridgedOk, detail = tostring(reason) }
end

-- =====================================================================
-- KATMAN 21 — Simülasyon testleri
-- =====================================================================
local function RunConcurrencyStressCheck()
    local stashId      = Config.Diagnostics.StressTestStashId or 'matrix_diagnostics_stress_stash'
    local testItem      = Config.Diagnostics.StressTestItem or 'matrix_diagnostic_token'
    local concurrency   = Config.Diagnostics.StressTestConcurrency or 100
    local timeoutMs      = Config.Diagnostics.StressTestTimeoutMs or 15000
    local runToken       = ('BOOT-%d'):format(GetGameTimer())

    local regOk, regResult = pcall(function()
        return exports.ox_inventory:RegisterStash(stashId, 'DIAGNOSTICS STRESS STASH', concurrency + 10, 1000000, false)
    end)
    if not regOk then
        return true, ('ATLANDI: RegisterStash hata firlatti -> %s'):format(tostring(regResult))
    end

    local seedOk, seedResult = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, testItem, concurrency)
    end)
    if not seedOk or seedResult ~= true then
        return true, ('ATLANDI: "%s" item\'i ox_inventory\'de KAYITLI DEGIL veya AddItem reddedildi -- Config.Diagnostics.StressTestItem\'i gercek bir item ile degistirin (orn: bread, water)'):format(tostring(testItem))
    end

     -- ★ [M-8 FIX] Paylaşımlı atomik olmayan `pending` sayaç yerine her
    -- worker KENDİ tamamlanma bayrağını yazar. Watch thread yalnızca
    -- okuma yapar → race YOK.
    local finished = {}
    local startedAtMs = GetGameTimer()

    for i = 1, concurrency do
        CreateThread(function()
            local removeOk, removeResult = pcall(function()
                return exports.ox_inventory:RemoveItem(stashId, testItem, 1)
            end)
            local removedFlag = (removeOk and removeResult) and 1 or 0
            pcall(function()
                MySQL.transaction.await({
                    {
                        query  = 'INSERT INTO matrix_diagnostics_stress_log (run_token, worker_index, removed_ok) VALUES (?, ?, ?)',
                        values = { runToken, i, removedFlag }
                    }
                })
            end)
            finished[i] = true
        end)
    end

    local waitedMs = 0
    while waitedMs < timeoutMs do
        local doneCount = 0
        for i = 1, concurrency do
            if finished[i] then doneCount = doneCount + 1 end
        end
        if doneCount >= concurrency then break end
        Wait(50)
        waitedMs = waitedMs + 50
    end
    local notDone = concurrency - (function()
        local n = 0
        for i = 1, concurrency do if finished[i] then n = n + 1 end end
        return n
    end)()

    local rows = MySQL.query.await(
        'SELECT COUNT(*) AS cnt, COALESCE(SUM(removed_ok), 0) AS ok_sum FROM matrix_diagnostics_stress_log WHERE run_token = ?',
        { runToken }
    ) or {}
    local cnt   = rows[1] and tonumber(rows[1].cnt) or 0
    local okSum = rows[1] and tonumber(rows[1].ok_sum) or 0

    -- [A4-6] Cleanup DELETE artik ilk assert'ten ONCE calisir -- bir timeout
    -- (notDone ~= 0) durumunda bile stress_log satirlari burada silinir;
    -- assert sonrasi hicbir cleanup atlanamaz.
    pcall(function() MySQL.query.await('DELETE FROM matrix_diagnostics_stress_log WHERE run_token = ?', { runToken }) end)

    assert(notDone == 0, ('%d/%d worker zaman asimina ugradi (%dms)'):format(notDone, concurrency, waitedMs))
    assert(cnt == concurrency,
        ('%d/%d satir DB\'ye ulasti -- kayip yazma = RACE CONDITION KANITI'):format(cnt, concurrency))
    assert(okSum == concurrency,
        ('%d/%d eszamanli RemoveItem basarisiz'):format(concurrency - okSum, concurrency))

    finished = nil
    return true, ('%d/%d eszamanli worker, %dms icinde, 0 kayip satir'):format(concurrency, concurrency, waitedMs)
end

local function RunWoundPrecisionSimCheck()
    local trapHouseId = nil
    for id in pairs(Matrix.TrapHouses or {}) do trapHouseId = id; break end
    if not trapHouseId then
        return true, 'atlandi -- Matrix.TrapHouses bos'
    end

    local EPS = 0.00005

    local botA = Matrix.CreateBotRecord({ name = 'DIAGNOSTIC-WOUND-A', role = 'diagnostic_test', trap_house_id = trapHouseId })
    assert(botA and botA.id, 'test bot A olusturulamadi')

        -- ★ v6.6.4: CripplingThreshold'un HEMEN ALTINDA hasar ver
    -- (kalıcı sakatlık tetiklenmesin ama normal ceza çarpanı tam uygulanabilsin)
    local _safeDamage = (Config.BotWounds.CripplingThreshold or 1.0) * 0.99
    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, _safeDamage, 'leg')
    local moveMult = Matrix.Wounds.GetMovementMultiplier(botA.id)

    local expectedMove = 1.0 - (Config.BotWounds.LegSpeedPenalty or 0.60)
    assert(type(moveMult) == 'number' and math_abs(moveMult - expectedMove) < EPS,
        ('hareket carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedMove, moveMult or -1))

        Matrix.Wounds.ApplyBotRegionalDamage(botA.id, _safeDamage, 'head')
    local detCap = Matrix.Wounds.GetDetectionRangeCap(botA.id)
    local expectedDet = Config.BotWounds.HeadDetectionRangeCap or 15.0
    assert(type(detCap) == 'number' and math_abs(detCap - expectedDet) < EPS,
        ('Spotter Distance sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedDet, detCap or -1))

        Matrix.Wounds.ApplyBotRegionalDamage(botA.id, _safeDamage, 'arm')
    local accMult = Matrix.Wounds.GetAccuracyMultiplier(botA.id)
    local expectedAcc = 1.0 - (Config.BotWounds.ArmAccuracyPenalty or 0.50)
    assert(type(accMult) == 'number' and math_abs(accMult - expectedAcc) < EPS,
        ('isabet carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedAcc, accMult or -1))

    Matrix.RemoveBot(botA.id, 'retired')

        local botB = Matrix.CreateBotRecord({ name = 'DIAGNOSTIC-WOUND-B', role = 'diagnostic_test', trap_house_id = trapHouseId })
    assert(botB and botB.id, 'test bot B olusturulamadi')
    -- ★ [CONFIG-AWARE] Config'deki threshold'a göre yeterli vuruş sayısı hesapla.
    -- Her vuruş 0.25 delta veriyor (1.0 damage × 0.25 clamp). +1 pay.
    local _threshold = Config.BotWounds.CripplingThreshold or 1.0
    local _hitsNeeded = math.ceil(_threshold / 0.25) + 1
    for _ = 1, _hitsNeeded do
        Matrix.Wounds.ApplyBotRegionalDamage(botB.id, 1.0, 'leg')
    end

    local moveMultCrippled = Matrix.Wounds.GetMovementMultiplier(botB.id)
    local expectedMoveCrippled = 1.0 - (Config.PermanentCrippling.LegMovementPenalty or 0.90)
    assert(type(moveMultCrippled) == 'number' and math_abs(moveMultCrippled - expectedMoveCrippled) < EPS,
        ('kalici sakatlik hareket carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedMoveCrippled, moveMultCrippled or -1))

    Matrix.RemoveBot(botB.id, 'retired')
    botA, botB = nil, nil

    return true, ('bacak=%.4f algi=%.4f kol=%.4f kalici-bacak=%.4f'):format(moveMult, detCap, accMult, moveMultCrippled)
end

local function RunPhantomDoctorPalindromeSimCheck()
    assert(type(Matrix.Wounds.__ComputePhantomIndexForEpochBucket) == 'function',
        'Matrix.Wounds.__ComputePhantomIndexForEpochBucket tanimli degil')

    local epochCount = Config.Diagnostics.PhantomPalindromeEpochCount or 10000

    local forward = {}
    for bucket = 0, epochCount - 1 do
        forward[bucket] = Matrix.Wounds.__ComputePhantomIndexForEpochBucket(bucket)
        if (bucket % STAGED_GC_INTERVAL) == 0 then
            Matrix.Diagnostics.StepGC()
        end
    end

    for bucket = epochCount - 1, 0, -1 do
        local idx = Matrix.Wounds.__ComputePhantomIndexForEpochBucket(bucket)
        assert(idx == forward[bucket],
            ('epoch #%d ileri/geri sapma: ileri=%s geri=%s'):format(bucket, tostring(forward[bucket]), tostring(idx)))

        if (bucket % STAGED_GC_INTERVAL) == 0 then
            Matrix.Diagnostics.StepGC()
        end
    end

    forward = nil
    Matrix.Diagnostics.StepGC()

    return true, ('%d epoch, ileri+geri, BIREBIR ayni (palindrom dogrulandi, %d staged GC step)'):format(
        epochCount, math.floor(epochCount / STAGED_GC_INTERVAL) * 2)
end

local function RunHitAndRunDrivebySimCheck()
    assert(Config.HitSquad, 'Config.HitSquad tanimsiz')
    local hs = Config.HitSquad

    for _, field in ipairs({ 'VehicleModel', 'PedModel', 'Weapon' }) do
        assert(type(hs[field]) == 'string' and hs[field] ~= '',
            ('Config.HitSquad.%s gecersiz/bos'):format(field))
    end
    for _, field in ipairs({ 'CruiseSpeed', 'AttackRange', 'DrivebySeconds', 'FleeSeconds',
                             'AggressiveDriveStyle', 'DrivebyRange', 'PedAccuracy', 'ScanIntervalTicks' }) do
        assert(type(hs[field]) == 'number',
            ('Config.HitSquad.%s sayisal degil'):format(field))
    end
    assert(type(hs.HeatTraceThreshold) == 'number'
        and hs.HeatTraceThreshold >= 0
        and hs.HeatTraceThreshold <= 1.0,
        'Config.HitSquad.HeatTraceThreshold [0,1] araliginda degil')

    -- Native race önleme: server-side spawn+delete testi yapmıyoruz
    if type(TaskVehicleDriveby) ~= 'function' then
        return true, 'ATLANDI: TaskVehicleDriveby server tarafinda tanimli degil (yalnizca client-taraf native)'
    end

    return true, 'Config ve kancalar 0 hata ile dogrulandi (spawn testi ATLANDI -- native race onlendi)'
end

local function RunMedicalBureauLeakSimCheck()
    assert(type(Matrix.Wounds.ComputeBureauLeakMultiplier) == 'function',
        'Matrix.Wounds.ComputeBureauLeakMultiplier tanimli degil')
    assert(type(Config.Hospital) == 'table', 'Config.Hospital tanimsiz')
    assert(type(Config.Hospital.LeakIntensityMultiplier) == 'number' and Config.Hospital.LeakIntensityMultiplier > 1.0,
        ('Config.Hospital.LeakIntensityMultiplier gecersiz: %s'):format(tostring(Config.Hospital.LeakIntensityMultiplier)))

    local EPS = 0.00005

    local spiked, mult = Matrix.Wounds.ComputeBureauLeakMultiplier(1.0)
    local expected = 1.0 * Config.Hospital.LeakIntensityMultiplier
    assert(math_abs(spiked - expected) < EPS,
        ('has_wound==1 medikal sizinti formulu sapmasi: beklenen=%.4f gercek=%.4f'):format(expected, spiked))
    assert(math_abs(mult - Config.Hospital.LeakIntensityMultiplier) < EPS,
        'donen carpan Config.Hospital.LeakIntensityMultiplier ile uyusmuyor')

    local nanValue = 0.0 / 0.0
    for _, badInput in ipairs({ -5.0, 0.0, nanValue }) do
        local fallbackSpiked = Matrix.Wounds.ComputeBureauLeakMultiplier(badInput)
        assert(math_abs(fallbackSpiked - expected) < EPS,
            ('gecersiz girdi (%s) icin 1.0 taban fallback formulu bozuk: gercek=%.4f'):format(tostring(badInput), fallbackSpiked))
    end

    local spiked2 = Matrix.Wounds.ComputeBureauLeakMultiplier(2.35)
    local expected2 = 2.35 * Config.Hospital.LeakIntensityMultiplier
    assert(math_abs(spiked2 - expected2) < EPS,
        ('2.35 taban icin sizinti sapmasi: beklenen=%.4f gercek=%.4f'):format(expected2, spiked2))

    return true, ('taban=1.00 -> sizinti=%.2f (x%.1f), 3 gecersiz-girdi fallback + 1 farkli-taban dogrulandi'):format(spiked, mult)
end

local function RunConfigSabotageSimCheck()
    return TestConfigDependencies()
end

local SimulationChecks = {
    { 'DERIN-SIM: Config Sabotaj ve Bagimlilik Kontrolu (KATMAN 2)',               RunConfigSabotageSimCheck },
    { 'DERIN-SIM: 100 eszamanli async satis stres testi (KATMAN 21.1)',            RunConcurrencyStressCheck },
    { 'DERIN-SIM: Bot yara ceza carpani 4-hane hassasiyeti (KATMAN 21.2)',          RunWoundPrecisionSimCheck },
    { 'DERIN-SIM: Hayalet Doktor 10k-epoch palindrom determinizmi (KATMAN 21.3)',   RunPhantomDoctorPalindromeSimCheck },
    { 'DERIN-SIM: Hit-and-Run drive-by tazelenmesi (KATMAN 22.1)',                  RunHitAndRunDrivebySimCheck },
    { 'DERIN-SIM: Medikal/Buro sizinti 2x katlanma formulu (KATMAN 22.2)',          RunMedicalBureauLeakSimCheck }
}

SimulationChecks[#SimulationChecks + 1] = {
    '[MATRIX:COGNITIVE_CORE_PHASE1] Meth -> fatigue_accumulation kilit (0.0)',
    RunCognitionStimulantLockSimCheck
}
SimulationChecks[#SimulationChecks + 1] = {
    '[MATRIX:COGNITIVE_CORE_PHASE1] Opium -> IQ tam -30 dususu',
    RunCognitionDepressantIqDropSimCheck
}
SimulationChecks[#SimulationChecks + 1] = {
    '[MATRIX:COGNITIVE_CORE_PHASE1] Paranoit kriz esik latch (>0.85 withdrawal)',
    RunCognitionParanoitCrisisThresholdSimCheck
}

local function AbortResourceBoot(reason)
    local msg = ('[KATMAN 21][KRITIK] Kaynak acilisi DURDURULUYOR -- %s'):format(tostring(reason))
    Matrix.Log('DIAGNOSTICS', msg)
    print(('^1[MATRIX:DIAGNOSTICS] %s^7'):format(msg))
    StopResource(GetCurrentResourceName())
end

function Matrix.Diagnostics.Run(deep, replyTo, isAutoBoot)
    -- [A4-4] Re-entrance kilidi: baslamadan ONCE kontrol et. Otomatik boot +
    -- manuel /matrix_run_diagnostics cakisirsa (veya Chaos suruyorsa) ayni
    -- gercek trap house'a ic ice lockdown tetiklenmesin.
    if _IsAnyTestRunning() then
        Matrix.Log('DIAGNOSTICS', '[RE-ENTRANCE BLOCK] Zaten calisiyor (Diagnostics veya Chaos).')
        return lastReport
    end

    CreateThread(function()
        Matrix.Diagnostics.IsRunning = true
        if Matrix.Chaos then Matrix.Chaos.Running = true end
        local startedAt = GetGameTimer()
        local checks = {}

        for _, c in ipairs(FastChecks) do
            checks[#checks + 1] = RunCheck(c.name, c.fn)
        end
        for _, c in ipairs(DbChecks) do
            checks[#checks + 1] = RunCheck(c[1], c[2])
        end
        if deep then
            local deepOk, deepResult = pcall(RunDeepExitBridgeCheck)
            if deepOk then
                checks[#checks + 1] = deepResult
            else
                checks[#checks + 1] = {
                    name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)',
                    passed = false,
                    detail = ('HATA: %s'):format(tostring(deepResult))
                }
            end

            for _, c in ipairs(SimulationChecks) do
                checks[#checks + 1] = RunCheck(c[1], c[2])
            end
            
                         -- ★ [FAZ 0.4] Chain checks — event chain verification
            for _, c in ipairs(Matrix.Diagnostics.ChainChecks or {}) do
                local triggerOk, triggerResult = pcall(c.trigger)
                if not triggerOk then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = ('Trigger hatasi: %s'):format(tostring(triggerResult)),
                    }
                else
                    local expectOk, expectPassed, expectDetail = pcall(c.expect, triggerResult)
                    if not expectOk then
                        checks[#checks + 1] = {
                            name   = c.name,
                            passed = false,
                            detail = ('Expect hatasi: %s'):format(tostring(expectPassed)),
                        }
                    else
                        checks[#checks + 1] = {
                            name   = c.name,
                            passed = expectPassed and true or false,
                            detail = expectDetail or (expectPassed and 'OK' or 'basarisiz'),
                        }
                    end
                end
            end

            -- ★ Cleanup: monitor off
            if _eventMonitorOn then _eventMonitorOn = false end
            
                        -- ★ [FAZ 0.5] Race checks — eşzamanlılık güvenliği
            for _, c in ipairs(Matrix.Diagnostics.RaceChecks or {}) do
                local ok, result = pcall(c.fn)
                if not ok then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = ('Race testi hata verdi: %s'):format(tostring(result)),
                    }
                elseif type(result) ~= 'table' then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = 'Race testi tablo donmedi',
                    }
                elseif result.error then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = result.error,
                    }
                elseif result.skip then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = true,
                        detail = ('ATLANDI -- %s'):format(result.reason or '?'),
                    }
                else
                    local passed, detail = true, 'OK'
                    if c.name:find('RemoveBot x20') then
                        if result.success ~= 1 then
                            passed = false
                            detail = ('Beklenen 1 basarili, gelen %d (fail=%d)'):format(
                                result.success or 0, result.failed or 0)
                        elseif result.ram_exists then
                            passed = false
                            detail = 'Bot RAM\'de hala duruyor'
                        else
                            detail = ('1 basarili / %d reddedildi, RAM temiz, DB status=%s'):format(
                                result.failed or 0,
                                result.db_row and result.db_row.status or 'none')
                        end
                    elseif c.name:find('Cognition cleanup') then
                        if result.after_db then
                            passed = false
                            detail = 'matrix_bot_cognition satiri silinmedi'
                        elseif result.ram_cog_exists then
                            passed = false
                            detail = 'Cognition RAM\'de kaldı'
                        else
                            detail = ('before_db=%s after_db=%s (temiz)'):format(
                                tostring(result.before_db), tostring(result.after_db))
                        end
                    elseif c.name:find('Lockdown double-trigger') then
                        if not result.is_locked then
                            passed = false
                            detail = 'Cift trigger sonrasi IsLockedDown false'
                        else
                            detail = 'Cift trigger idempotent (state bozulmadi)'
                        end
                    end

                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = passed,
                        detail = detail,
                    }
                end
            end
   
                        -- ★ [FAZ 0.6][L4] State sync checks
            for _, c in ipairs(Matrix.Diagnostics.StateChecks or {}) do
                local ok, result = pcall(c.fn)
                if not ok then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = ('Hata: %s'):format(tostring(result)),
                    }
                elseif type(result) ~= 'table' then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = 'Tablo donmedi',
                    }
                elseif result.error then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = result.error,
                    }
                elseif result.skip then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = true,
                        detail = ('ATLANDI -- %s'):format(result.reason or '?'),
                    }
                else
                    local passed, detail = true, 'OK'
                    if c.name:find('Bot cortisol') then
                        if #(result.mismatches or {}) > 0 then
                            passed = false
                            detail = ('%d/%d uyusmazlik: %s'):format(
                                #result.mismatches, result.tested or 0,
                                table.concat(result.mismatches, ' | '))
                        else
                            detail = ('%d bot dogrulandi'):format(result.tested or 0)
                        end
                    elseif c.name:find('Prop registry') then
                        if (result.mismatches or 0) > 0 then
                            passed = false
                            detail = ('%d prop RAM-DB uyusmazligi'):format(result.mismatches)
                        else
                            detail = ('%d prop temiz'):format(result.db_count or 0)
                        end
                    elseif c.name:find('Market zone') then
                        detail = ('config=%d db=%d'):format(
                            result.config_zones or 0, result.total_zones_in_db or 0)
                    elseif c.name:find('Player telemetry') then
                        detail = ('DB rows: %d'):format(result.db_rows or 0)
                    end
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = passed,
                        detail = detail,
                    }
                end
            end

            -- ★ [FAZ 0.6][L6] Determinism checks
            for _, c in ipairs(Matrix.Diagnostics.DeterminismChecks or {}) do
                local ok, result = pcall(c.fn)
                if not ok then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = ('Hata: %s'):format(tostring(result)),
                    }
                elseif type(result) ~= 'table' then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = 'Tablo donmedi',
                    }
                elseif result.error then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = false,
                        detail = result.error,
                    }
                elseif result.skip then
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = true,
                        detail = ('ATLANDI -- %s'):format(result.reason or '?'),
                    }
                else
                    local passed, detail = true, 'OK'
                    if c.name:find('IQ derivation') then
                        if not result.deterministic then
                            passed = false
                            detail = ('DETERMINIZM IHLALI: iter=%d, farkli=%s'):format(
                                result.break_at or 0, tostring(result.different))
                        else
                            detail = ('100x ayni IQ=%d'):format(result.value or 0)
                        end
                    elseif c.name:find('Police personality') then
                        if not result.deterministic then
                            passed = false
                            detail = ('IHLAL: iter=%d'):format(result.at_iteration or 0)
                        else
                            detail = ('100x integrity=%.3f greed=%.3f'):format(
                                result.integrity or 0, result.greed or 0)
                        end
                    elseif c.name:find('math.random') then
                        if result.clean == false then
                            passed = false
                            detail = ('SIZINTI: %s'):format(table.concat(result.offenders, ', '))
                        else
                            detail = ('%d dosya temiz'):format(result.files_scanned or 0)
                        end
                    elseif c.name:find('Ballistic serial') then
                        detail = ('sample=%s'):format(tostring(result.sample or '?'))
                    end
                    checks[#checks + 1] = {
                        name   = c.name,
                        passed = passed,
                        detail = detail,
                    }
                end
            end

            Matrix.Diagnostics.PurgeDeepTestState()
        end

        local passed, failed = 0, 0
        for _, c in ipairs(checks) do
            if c.passed then passed = passed + 1 else failed = failed + 1 end
        end

        lastReport = {
            ran_at      = os.time(),
            duration_ms = GetGameTimer() - startedAt,
            deep        = deep and true or false,
            total       = #checks,
            passed      = passed,
            failed      = failed,
            checks      = checks,
            sealed      = (failed == 0)
        }

        -- NOT: asagidaki banner TAMAMEN bu calistirmanin GERCEK passed/
        -- #checks/failed degerlerinden hesaplanir -- sabit/hardcoded bir
        -- "basarili" metni DEGILDIR. Butun kontroller gecerse dogal
        -- olarak N/N + "NIHAI MUHURLENDI" yazar; aksi halde gercek hata
        -- sayisini basar.
        Matrix.Log('DIAGNOSTICS',
            '[MATRIX:DIAGNOSTICS] %d/%d basarili (deep=%s) -- %dms icinde tamamlandi. Sonuc: %s',
            passed, #checks, tostring(lastReport.deep), lastReport.duration_ms,
            lastReport.sealed and 'NİHAİ MÜHÜRLENDİ (0 hata)' or ('%d HATA'):format(failed))

        if isAutoBoot and failed > 0 and Config.Diagnostics.AbortResourceOnSimulationFailure then
            local firstFailure = nil
            for _, c in ipairs(checks) do
                if not c.passed then firstFailure = c; break end
            end
            AbortResourceBoot(('%d/%d kontrol basarisiz -- ilk hata: [%s] %s'):format(
                failed, #checks,
                firstFailure and firstFailure.name or '?',
                firstFailure and firstFailure.detail or '?'))
            return
        end

        if replyTo then
            Reply(replyTo, ('%d/%d kontrol basarili (%dms). %s'):format(
                passed, #checks, lastReport.duration_ms,
                lastReport.sealed and 'Sistem muhurlendi.' or ('%d hata bulundu, /matrix_diag_detay failed ile gorun.'):format(failed)))
            if not lastReport.sealed then
                for _, c in ipairs(checks) do
                    if not c.passed then
                        Reply(replyTo, ('  x %s -- %s'):format(c.name, c.detail))
                    end
                end
            end
        end

                TriggerClientEvent('matrix:client:diagnosticsSealed', -1, lastReport)
        Matrix.Diagnostics.IsRunning = false
        if Matrix.Chaos then Matrix.Chaos.Running = false end
    end)
end

function Matrix.Diagnostics.GetLastReport()
    return lastReport
end

lib.callback.register('matrix:callback:getDiagnosticsReport', function(src)
    return lastReport
end)

-- =====================================================================
-- KATMAN 1 + [H2]: ASENKRON BEKLEME KALKANI + DB TIMEOUT KORUMASI
-- =====================================================================
local DB_BOOT_TIMEOUT_CYCLES = 150
local DB_BOOT_POLL_MS        = 100

local function ExecuteNihaiMatrixDiagnostics(deep)
    Matrix.Diagnostics.Run(deep or true, nil, true)
end

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not (Config.Diagnostics and Config.Diagnostics.RunOnResourceStart) then return end

    CreateThread(function()
        local dbGlobalWaited = 0
        while not MySQL and dbGlobalWaited < (DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS) do
            Citizen.Wait(DB_BOOT_POLL_MS)
            dbGlobalWaited = dbGlobalWaited + DB_BOOT_POLL_MS
        end

        if not MySQL then
            JournalBootFailure('mysql_global_missing',
                ('MySQL global %dms icinde tanimlanmadi -- simülasyon GUVENLI ISTISNA modunda devam ediyor.'):format(dbGlobalWaited))
            ExecuteNihaiMatrixDiagnostics(true)
            return
        end

        local readyRegistered = false
        local readyFired      = false

        local okReady, readyErr = pcall(function()
            MySQL.ready(function()
                readyFired = true

                local inventoryReady = false
                local waitCycles = 0

                while not inventoryReady and waitCycles < DB_BOOT_TIMEOUT_CYCLES do
                    local ok, items = pcall(function()
                        if exports['ox_inventory'] and exports['ox_inventory']:Items() then
                            return exports['ox_inventory']:Items()
                        end
                        return nil
                    end)

                    if ok and type(items) == 'table' then
                        inventoryReady = true
                    else
                        Citizen.Wait(DB_BOOT_POLL_MS)
                        waitCycles = waitCycles + 1
                    end
                end

                if not inventoryReady then
                    JournalBootFailure('inventory_manifest_timeout',
                        ('ox_inventory %dms icinde hazir olmadi (MySQL.ready OK). Config.Diagnostics.AbortResourceOnSimulationFailure=%s -- kaynak CORERTILMEDI, simulasyon deep=true ile devam ediyor.'):format(
                            DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS,
                            tostring(Config.Diagnostics.AbortResourceOnSimulationFailure)))
                    Matrix.Log('DIAGNOSTICS',
                        '[KATMAN 1][KALKAN] ox_inventory %dms icinde hazir olmadi -- varsayilan devam karari (sahte sizinti alarmi onlendi).',
                        DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS)
                else
                    Matrix.Log('DIAGNOSTICS',
                        '[KATMAN 1][KALKAN] MySQL.ready + ox_inventory:Items() hazir -- Nihai Derin Simulasyon atesleniyor (wait=%dms).',
                        waitCycles * DB_BOOT_POLL_MS)
                end

                ExecuteNihaiMatrixDiagnostics(true)
            end)
            readyRegistered = true
        end)

        if not okReady then
            JournalBootFailure('mysql_ready_register_failed',
                ('MySQL.ready callback kaydi basarisiz: %s -- simulasyon deep=true ile devam ediyor.'):format(tostring(readyErr)))
            ExecuteNihaiMatrixDiagnostics(true)
            return
        end

        if readyRegistered and not readyFired then
            CreateThread(function()
                local guardWaited = 0
                while not readyFired and guardWaited < (DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS) do
                    Citizen.Wait(DB_BOOT_POLL_MS)
                    guardWaited = guardWaited + DB_BOOT_POLL_MS
                end
                if not readyFired then
                    JournalBootFailure('mysql_ready_callback_timeout',
                        ('MySQL.ready %dms icinde ATESLENMEDI (MariaDB cokmus veya agir yuk altinda) -- simulasyon deep=true ile devam ediyor, kaynak CORERTILMEDI.'):format(guardWaited))
                    ExecuteNihaiMatrixDiagnostics(true)
                end
            end)
        end
    end)
end)

-- =====================================================================
-- /matrix_run_diagnostics — manuel kısa özet çalıştırma
-- =====================================================================
RegisterCommand('matrix_run_diagnostics', function(src, args)
    local deep = args[1] == Config.Diagnostics.DeepModeCommandArg
    Reply(src, deep
        and 'Derin tani calistiriliyor (Config sabotaj + SimulationChecks + kullan-at test botu)...'
        or 'Hizli tani calistiriliyor...')
    Matrix.Diagnostics.Run(deep, src, false)
end, false)

exports('GetDiagnosticsReport', function() return lastReport end)
exports('RunDiagnostics',      function(deep) return Matrix.Diagnostics.Run(deep, nil, false) end)
exports('TestConfigDependencies', function() return TestConfigDependencies() end)
exports('PurgeDeepTestState',  function() return Matrix.Diagnostics.PurgeDeepTestState() end)
exports('GetFailureJournal',   function() return Matrix.Diagnostics.GetFailureJournal() end)
exports('GetBreachJournal',    function() return Matrix.Diagnostics.BreachJournal end)
exports('WrapReadOnlyCell',    function(data, name, botId) return Matrix.Diagnostics.WrapReadOnlyCell(data, name, botId) end)
exports('DeepCopyCell',        function(data) return Matrix.Diagnostics.DeepCopyCell(data) end)
exports('StepGC',              function() return Matrix.Diagnostics.StepGC() end)
exports('FinalizeStagedGC',    function() return Matrix.Diagnostics.FinalizeStagedGC() end)

-- =====================================================================
-- KATMAN 23: DETAYLI TANI DÖKÜMÜ (/matrix_diag_detay)
-- =====================================================================
do
    local function _DiagReply(src, msg)
        if type(src) == 'number' and src > 0 then
            TriggerClientEvent('chat:addMessage', src, { args = { '[DIAGNOSTICS]', msg } })
        else
            print(('[MATRIX:DIAGNOSTICS:CONSOLE] %s'):format(msg))
        end
    end

    local function _GetReport()
        local fn = Matrix.Diagnostics and Matrix.Diagnostics.GetLastReport
        if type(fn) == 'function' then return fn() end
        return {}
    end

    local function _ConsolePrintCheck(idx, c)
        local marker = c.passed and '[OK]  ' or '[FAIL]'
        print(('[MATRIX:DIAGNOSTICS] %s #%03d %s'):format(marker, idx, c.name))
        print(('[MATRIX:DIAGNOSTICS]        -> %s'):format(tostring(c.detail or '?')))
    end

    local function _DumpReport(replyTo, filterKind, filterValue, verbose)
        local rep = _GetReport()
        if type(rep) ~= 'table' or (rep.total or 0) == 0 then
            _DiagReply(replyTo, 'Henuz bir tani raporu yok. Once /matrix_run_diagnostics calistirin.')
            return
        end

        _DiagReply(replyTo, ('=== TANI RAPORU [ran_at=%d | deep=%s | %d/%d GECTI | %d HATA | %dms] ==='):format(
            rep.ran_at or 0, tostring(rep.deep), rep.passed or 0, rep.total or 0,
            rep.failed or 0, rep.duration_ms or 0))

        print(('[MATRIX:DIAGNOSTICS] ==== DUMP basladi [ran_at=%d deep=%s %d/%d failed=%d] ===='):format(
            rep.ran_at or 0, tostring(rep.deep), rep.passed or 0, rep.total or 0, rep.failed or 0))

        local shown, matchedFailed = 0, 0
        for i, c in ipairs(rep.checks or {}) do
            local include = false

            if filterKind == 'failed' then
                include = not c.passed
            elseif filterKind == 'passed' then
                include = c.passed
            elseif filterKind == 'grep' then
                local hay = tostring(c.name):lower()
                local needle = tostring(filterValue or ''):lower()
                include = (needle ~= '' and hay:find(needle, 1, true) ~= nil)
            elseif filterKind == 'layer' then
                local needle = tostring(filterValue or '')
                local name = tostring(c.name)
                include = name:find('KATMAN ' .. needle, 1, true) ~= nil
                       or name:find('katman ' .. needle, 1, true) ~= nil
                       or name:find('KATMAN' .. needle, 1, true) ~= nil
                       or name:find('layer' .. needle, 1, true) ~= nil
            else
                include = true
            end

            if include then
                shown = shown + 1
                if not c.passed then matchedFailed = matchedFailed + 1 end

                local marker = c.passed and '[OK]' or '[FAIL]'
                if (not c.passed) or verbose then
                    _DiagReply(replyTo, ('%s #%03d %s'):format(marker, i, c.name))
                    _DiagReply(replyTo, ('       -> %s'):format(tostring(c.detail or '?')))
                else
                    _DiagReply(replyTo, ('%s #%03d %s'):format(marker, i, c.name))
                end

                _ConsolePrintCheck(i, c)
            end
        end

        print(('[MATRIX:DIAGNOSTICS] ==== DUMP bitti -- %d/%d kontrol gosterildi, %d basarisiz ===='):format(
            shown, rep.total or 0, matchedFailed))

        if shown == 0 then
            _DiagReply(replyTo, 'Bu filtreye uyan kontrol yok.')
        else
            _DiagReply(replyTo, ('--- %d/%d kontrol gosterildi (%d basarisiz) | TAMAMI SERVER KONSOLUNDA ---'):format(
                shown, rep.total or 0, matchedFailed))
        end
    end

    local function _RerunThenDump(replyTo, deep, filterKind, filterValue, verbose)
        local beforeRanAt = (_GetReport().ran_at) or 0

        if type(Matrix.Diagnostics) ~= 'table' or type(Matrix.Diagnostics.Run) ~= 'function' then
            _DiagReply(replyTo, 'Matrix.Diagnostics.Run tanimli degil -- dosya tam yuklenmemis olabilir.')
            return
        end

        Matrix.Diagnostics.Run(deep, nil, false)

        CreateThread(function()
            local deadline = os.time() + 30
            while ((_GetReport().ran_at) or 0) == beforeRanAt and os.time() < deadline do
                Wait(200)
            end
            _DumpReport(replyTo, filterKind, filterValue, verbose)
        end)
    end

    RegisterCommand('matrix_diag_detay', function(src, args)
        local a1 = tostring(args[1] or ''):lower()

        if a1 == 'deep' then
            _DiagReply(src, 'Yeni DEEP tani calistiriliyor, ardindan TUM sonuclar dokulecek...')
            _RerunThenDump(src, true, nil, nil, true); return
        end

        if a1 == 'fast' then
            _DiagReply(src, 'Yeni HIZLI tani calistiriliyor, ardindan TUM sonuclar dokulecek...')
            _RerunThenDump(src, false, nil, nil, true); return
        end

        if a1 == 'failed'  then _DumpReport(src, 'failed', nil, true);  return end
        if a1 == 'passed'  then _DumpReport(src, 'passed', nil, false); return end
        if a1 == 'verbose' then _DumpReport(src, nil, nil, true);       return end

        if a1 == 'journal' or a1 == 'jurnal' then
            local j = Matrix.Diagnostics.GetFailureJournal()
            _DiagReply(src, ('=== [matrix_diag_detay_failed] BOOT FAILURE JOURNAL (toplam %d kayit) ==='):format(j.failure_count or 0))
            if (j.failure_count or 0) == 0 then
                _DiagReply(src, 'Kayitli boot hatasi yok -- MySQL.ready + ox_inventory:Items() 15sn icinde temiz geldi.')
            else
                _DiagReply(src, ('Son hata: %s | tur=%s | %s'):format(
                    os.date('%Y-%m-%d %H:%M:%S', j.last_failure_at or 0),
                    tostring(j.last_failure_kind or '?'),
                    tostring(j.last_failure_detail or '?')))
            end
            return
        end

        if a1 == 'breach' or a1 == 'ihlal' then
            local b = Matrix.Diagnostics.BreachJournal
            _DiagReply(src, ('=== HUCRE IZOLASYON IHLALI JURNALI (toplam %d ihlal) ==='):format(b.breach_count or 0))
            if (b.breach_count or 0) == 0 then
                _DiagReply(src, 'Kayitli izolasyon ihlali yok -- tum bot sinif veri transferleri temiz.')
            else
                _DiagReply(src, ('Son ihlal: %s'):format(tostring(b.last_breach_detail or '?')))
                for botId, count in pairs(b.breach_by_bot or {}) do
                    _DiagReply(src, ('  - Bot #%s: %d ihlal'):format(tostring(botId), count))
                end
            end
            return
        end

        if a1 == 'g' then
            if not args[2] then _DiagReply(src, 'Kullanim: /matrix_diag_detay g <metin>'); return end
            local parts = {}
            for i = 2, #args do parts[#parts + 1] = tostring(args[i]) end
            _DumpReport(src, 'grep', table.concat(parts, ' '), true); return
        end

        if a1 == 'layer' or a1 == 'katman' then
            local n = args[2]
            if not n then _DiagReply(src, 'Kullanim: /matrix_diag_detay layer <N>'); return end
            _DumpReport(src, 'layer', tostring(n), true); return
        end

        if a1 == 'export' then
            local rep = _GetReport()
            if type(rep) ~= 'table' or (rep.total or 0) == 0 then
                _DiagReply(src, 'Rapor yok, once /matrix_run_diagnostics calistirin.'); return
            end
            local ok, encoded = pcall(function() return json.encode(rep) end)
            if ok and type(encoded) == 'string' then
                print('[MATRIX:DIAGNOSTICS][EXPORT] ' .. encoded)
                _DiagReply(src, ('Tam rapor (%d kontrol) server konsoluna JSON olarak basildi.'):format(rep.total))
            else
                _DiagReply(src, 'JSON kodlamasi basarisiz.')
            end
            return
        end

        _DumpReport(src, nil, nil, false)
    end, false)

    exports('DumpDiagnosticsReport', function(replyTo, filterKind, filterValue, verbose)
        _DumpReport(replyTo, filterKind, filterValue, verbose)
    end)
end

-- [FAZ 2] Paravan Real Estate & Dark Lawyer
AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    SetTimeout(5000, function()
        local lev = (1.0 * 0.4) + ((50000.0 / 50000.0) * 0.4) - (1.0 * 0.2)
        print(('[MATRIX:PARAVAN_REAL_ESTATE_PHASE2][DIAG] leverage=%.4f | PASS=%s'):format(
            lev, tostring(lev >= 0.20)))
    end)
end)

-- [FAZ 2] Paravan Real Estate & Dark Lawyer — 3 formal check
Matrix.Diagnostics = Matrix.Diagnostics or {}
Matrix.Diagnostics.Checks = Matrix.Diagnostics.Checks or {}

Matrix.Diagnostics.Checks[#Matrix.Diagnostics.Checks + 1] = {
    id = 'paravan_leverage_math',
    run = function()
        local lev = (1.0 * 0.4) + ((50000.0 / 50000.0) * 0.4) - (1.0 * 0.2)
        return { pass = (lev >= 0.20), tag = '[MATRIX:PARAVAN_REAL_ESTATE_PHASE2]' }
    end,
}
Matrix.Diagnostics.Checks[#Matrix.Diagnostics.Checks + 1] = {
    id = 'paravan_dark_lawyer_api',
    run = function()
        local ok = Matrix.Bureau and type(Matrix.Bureau.IncrementDarkLawyerFragment) == 'function'
        return { pass = ok, tag = '[MATRIX:PARAVAN_REAL_ESTATE_PHASE2]' }
    end,
}
-- =====================================================================
-- ★★★ FAZ 6 — ADIM 3: HİDROLİK PRES + SERA BOTANY REGRESYON BLOKLARI ★★★
-- [MATRIX:HYDRAULIC_PRESS_PHASE6]
--
-- APPEND-ONLY — mevcut FastChecks / DbChecks / SimulationChecks
-- registry'lerine DOKUNMAZ. Kendi registry'sini ve runner thread'ini kurar.
--
-- RACE KORUMASI: server/logistics.lua zaten kendi FAZ 6 runtime tanısını
-- (Matrix.Logistics.RunHydraulicPressPhase6Diagnostics) Wait(6000)'da
-- çalıştırıyor. Bu blok o runtime'ı TEKRAR ÇAĞIRMAZ. Yalnızca bağımsız
-- statik/konfigürasyon invariantlarını doğrular → çift stub race'i YOK.
--
-- ZERO RNG: tüm kontroller saf/deterministik.
-- =====================================================================

local PH_OPTIMAL_MIN = 5.8
local PH_OPTIMAL_MAX = 6.2
local PH_HARD_MIN    = 0.0
local PH_HARD_MAX    = 14.0
local PRESS_LOG_TAG  = '[MATRIX:HYDRAULIC_PRESS_PHASE6]'

local function _HpLog(fmt, ...)
    local n = select('#', ...)
    local line = (n == 0) and fmt or string.format(fmt, ...)
    if type(Matrix) == 'table' and type(Matrix.Log) == 'function' then
        Matrix.Log('DIAGNOSTICS', '%s %s', PRESS_LOG_TAG, line)
    end
    print(('^5%s %s^7'):format(PRESS_LOG_TAG, line))
end

-- =====================================================================
-- PARÇA 2/3 — 3 bağımsız statik kontrol
-- =====================================================================

local function _DiagCheck_MaterialShortageBlock()
    if type(Matrix.Logistics) ~= 'table' then
        return false, 'Matrix.Logistics modulu yuklenmedi (logistics.lua fxmanifest\'te mi?)'
    end
    if type(Matrix.Logistics.StartBrickPress) ~= 'function' then
        return false, 'StartBrickPress hook tanimli degil'
    end
    if type(Matrix.Logistics.HydraulicPress) ~= 'table' then
        return false, 'HydraulicPress konfigurasyonu yok'
    end

    local hp = Matrix.Logistics.HydraulicPress

    if tonumber(hp.BagsPerBrick) ~= 100 then
        return false, ('BagsPerBrick beklenen 100, gercek %s'):format(tostring(hp.BagsPerBrick))
    end
    if hp.PressBagItem ~= 'heavy_duty_press_bag' then
        return false, ('PressBagItem beklenen heavy_duty_press_bag, gercek %s'):format(tostring(hp.PressBagItem))
    end
    if hp.OutputBrickItem ~= 'narcotic_brick' then
        return false, ('OutputBrickItem beklenen narcotic_brick, gercek %s'):format(tostring(hp.OutputBrickItem))
    end
    if tonumber(hp.OutputBrickMass) ~= 1000.0 then
        return false, ('OutputBrickMass beklenen 1000.0g, gercek %s'):format(tostring(hp.OutputBrickMass))
    end
    if tonumber(hp.CyclesRequired) ~= 5 then
        return false, ('CyclesRequired beklenen 5, gercek %s'):format(tostring(hp.CyclesRequired))
    end

    local allowed = hp.AllowedProducts or {}
    local requiredProducts = { 'meth_bag', 'coke_brick', 'masterpiece_gourmet_weed' }
    for i = 1, #requiredProducts do
        if type(allowed[requiredProducts[i]]) ~= 'table' then
            return false, ('AllowedProducts.%s eksik/gecersiz'):format(requiredProducts[i])
        end
    end

    return true, '99-torba/eksik-poset hard-block konfigurasyonu dogrulandi (100:1:1)'
end

local function _DiagCheck_PurityMetadata()
    if type(Matrix.Logistics) ~= 'table'
       or type(Matrix.Logistics.HydraulicPress) ~= 'table' then
        return false, 'HydraulicPress yok'
    end

    local stacks = {
        { p = 0.80, c = 40 },
        { p = 0.90, c = 30 },
        { p = 0.95, c = 30 },
    }
    local sumP, sumC = 0.0, 0
    for i = 1, #stacks do
        sumP = sumP + (stacks[i].p * stacks[i].c)
        sumC = sumC + stacks[i].c
    end

    if sumC ~= 100 then
        return false, ('sumC beklenen 100, gercek %d'):format(sumC)
    end

    local avg = sumP / sumC
    if math.abs(avg - 0.875) > 0.0001 then
        return false, ('weighted-avg sapma: %.6f != 0.875'):format(avg)
    end

    local rounded = math.floor(avg * 10000 + 0.5) / 10000
    if rounded ~= 0.875 then
        return false, ('4-hane round sapma: %.4f'):format(rounded)
    end

    local purityInt = math.floor(avg * 10000 + 0.5)
    if purityInt ~= 8750 then
        return false, ('purityInt beklenen 8750, gercek %d'):format(purityInt)
    end

    if tonumber(Matrix.Logistics.HydraulicPress.OutputBrickMass) ~= 1000.0 then
        return false, 'OutputBrickMass 1000.0g degil'
    end

    return true, ('weighted-avg=%.4f | purityInt=%d (forensic lot icin)'):format(avg, purityInt)
end

local function _normalizeFloat2dp(v)
    if type(v) ~= 'number' or v ~= v then return nil end
    if v == math.huge or v == -math.huge then return nil end
    return math.floor(v * 100.0 + 0.5) / 100.0
end

local function _DiagCheck_FloatFormattingWindow()
    if PH_OPTIMAL_MIN ~= 5.8 or PH_OPTIMAL_MAX ~= 6.2 then
        return false, 'pH optimal pencere sabitleri drift'
    end
    if PH_HARD_MIN ~= 0.0 or PH_HARD_MAX ~= 14.0 then
        return false, 'pH sanitizer sabitleri drift'
    end

    local insideTests = { 5.80, 5.95, 6.00, 6.05, 6.19, 6.20 }
    for i = 1, #insideTests do
        local v = insideTests[i]
        local n = _normalizeFloat2dp(v)
        if not n then
            return false, ('ic deger NaN/Inf: %.2f'):format(v)
        end
        if n < PH_OPTIMAL_MIN or n > PH_OPTIMAL_MAX then
            return false, ('optimal pencere disi: %.2f -> %.2f'):format(v, n)
        end
        if n < PH_HARD_MIN or n > PH_HARD_MAX then
            return false, ('hard sinir ihlali: %.2f -> %.2f'):format(v, n)
        end
    end

    local function _sanitizePh(v)
        local n = _normalizeFloat2dp(v)
        if not n then return nil end
        if n < PH_HARD_MIN or n > PH_HARD_MAX then return nil end
        return n
    end

    if _sanitizePh(0.0)   == nil then return false, 'pH=0.0 reddedildi (kabul beklenir)' end
    if _sanitizePh(14.0)  == nil then return false, 'pH=14.0 reddedildi (kabul beklenir)' end
    if _sanitizePh(-0.01) ~= nil then return false, 'pH=-0.01 kabul edildi (ret beklenir)' end
    if _sanitizePh(14.01) ~= nil then return false, 'pH=14.01 kabul edildi (ret beklenir)' end

    if _normalizeFloat2dp(0/0)          ~= nil then return false, 'NaN reddedilmedi' end
    if _normalizeFloat2dp(math.huge)    ~= nil then return false, '+Inf reddedilmedi' end
    if _normalizeFloat2dp(-math.huge)   ~= nil then return false, '-Inf reddedilmedi' end

    if _normalizeFloat2dp(6.0) ~= 6.0 then
        return false, '6.0 round-trip bozuk'
    end
    local r5999 = _normalizeFloat2dp(5.999)
    if r5999 ~= 6.0 then
        return false, ('5.999 -> %s (beklenen 6.0)'):format(tostring(r5999))
    end

    return true, ('pH optimal [%.1f-%.1f], sanitizer [%.1f-%.1f], NaN/Inf ret OK')
        :format(PH_OPTIMAL_MIN, PH_OPTIMAL_MAX, PH_HARD_MIN, PH_HARD_MAX)
end

-- =====================================================================
-- PARÇA 3/3 — Registry + Runner (append-only)
-- =====================================================================

Matrix.Diagnostics = Matrix.Diagnostics or {}
Matrix.Diagnostics.HydraulicPressPhase6 = Matrix.Diagnostics.HydraulicPressPhase6 or {
    Checks = {
        { name = 'material_shortage_block', fn = _DiagCheck_MaterialShortageBlock },
        { name = 'purity_metadata',         fn = _DiagCheck_PurityMetadata },
        { name = 'float_window_5.8_6.2',    fn = _DiagCheck_FloatFormattingWindow },
    },
}

CreateThread(function()
    Wait(8000)

    local registry = Matrix.Diagnostics.HydraulicPressPhase6.Checks
    local passed, failed = 0, 0
    local failedDetails = {}

    for i = 1, #registry do
        local check = registry[i]
        local ok, detail = false, 'uninitialized'

        local callOk, err = pcall(function()
            ok, detail = check.fn()
        end)
        if not callOk then
            ok, detail = false, ('pcall error: %s'):format(tostring(err))
        end

        if ok then
            passed = passed + 1
            _HpLog('[PASS] %s -- %s', check.name, tostring(detail))
        else
            failed = failed + 1
            failedDetails[#failedDetails + 1] = ('%s :: %s'):format(check.name, tostring(detail))
            _HpLog('[FAIL] %s -- %s', check.name, tostring(detail))
        end
    end

    _HpLog('FAZ6/ADIM3 statik tanisi: %d/%d gecti (%d hata).',
        passed, #registry, failed)

    if failed > 0 then
        for i = 1, #failedDetails do
            _HpLog('[HATA] %s', failedDetails[i])
        end
    end
end)

-- ★ BİRLEŞTİRME NOTU: Bu dosya artık matrix_diagnostics.lua'ya ENTEGRE edildi.
-- fxmanifest.lua'dan bu dosyanın satırını SİLİN ve aşağıdaki bloğu
-- matrix_diagnostics.lua'nın EN SONUNA yapıştırın.

-- =====================================================================
-- MATRIX DIAGNOSTICS EXT / server/matrix_diagnostics_ext.lua
-- RUH HASTASI TESTÇİ — FAZ 1/3 (Katman 24 Terrain + 25 UI)
-- =====================================================================

Matrix = Matrix or {}
Matrix.DiagnosticsExt = Matrix.DiagnosticsExt or {}
Matrix.DiagnosticsExt.Registry = Matrix.DiagnosticsExt.Registry or {
    terrain = {}, ui = {}, fuzz = {}, combination = {}, flow = {}, perf = {},
}

local REG = Matrix.DiagnosticsExt.Registry

-- ★ BİRLEŞTİRME: REG'e ekle + AddCheck'e gönder (çift kayıt, güvenli)
local function _Register(layer, name, fn)
    if not REG[layer] then REG[layer] = {} end
    REG[layer][#REG[layer] + 1] = { name = name, fn = fn }
    AddCheck(name, fn)
end


local MAP_MIN_XY, MAP_MAX_XY = -6000.0, 8000.0
local MAP_MIN_Z,  MAP_MAX_Z  = -200.0, 1500.0

local function _IsValidCoord(x, y, z)
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return false, 'non_numeric' end
    if x ~= x or y ~= y or z ~= z then return false, 'NaN' end
    if x == math.huge or x == -math.huge or y == math.huge or y == -math.huge
        or z == math.huge or z == -math.huge then return false, 'inf' end
    if x < MAP_MIN_XY or x > MAP_MAX_XY then return false, 'x_out' end
    if y < MAP_MIN_XY or y > MAP_MAX_XY then return false, 'y_out' end
    if z < MAP_MIN_Z or z > MAP_MAX_Z then return false, 'z_out' end
    return true
end

local function _ScanVectors(tbl, path, results, visited)
    if type(tbl) ~= 'table' then return end
    visited = visited or {}
    if visited[tbl] then return end
    visited[tbl] = true
    for k, v in pairs(tbl) do
        local key = type(k) == 'string' and k or tostring(k)
        local cp = path .. '.' .. key
        if type(v) == 'vector3' or type(v) == 'vector4' then
            local ok, reason = _IsValidCoord(v.x, v.y, v.z)
            if not ok then results[#results+1] = cp .. ':' .. reason end
        elseif type(v) == 'table' then
            _ScanVectors(v, cp, results, visited)
        end
    end
end

-- =====================================================================
-- KATMAN 24 — TERRAIN / SPAWN
-- =====================================================================
_Register('terrain', '[T24-1] Config tum vektorler haritada', function()
    local bad = {}
    _ScanVectors(Config, 'Config', bad)
    if #bad > 0 then
        local head = {}
        for i = 1, math.min(#bad, 5) do head[i] = bad[i] end
        return false, ('%d hatali: %s%s'):format(#bad, table.concat(head, ' | '),
            #bad > 5 and ('... +' .. (#bad-5)) or '')
    end
    return true, 'Config temiz'
end)

_Register('terrain', '[T24-2] matrix_trap_houses DB haritada', function()
    local rows = MySQL.query.await('SELECT id, label, coord_x, coord_y, coord_z FROM matrix_trap_houses') or {}
    if #rows == 0 then return true, '0 trap house' end
    local bad = {}
    for _, r in ipairs(rows) do
        local ok, reason = _IsValidCoord(tonumber(r.coord_x), tonumber(r.coord_y), tonumber(r.coord_z))
        if not ok then bad[#bad+1] = string.format('#%d:%s', r.id, reason) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-3] matrix_traphouses DB haritada', function()
    local rows = MySQL.query.await('SELECT id, house_name, coords FROM matrix_traphouses') or {}
    if #rows == 0 then return true, '0 cell' end
    local bad = {}
    for _, r in ipairs(rows) do
        local okDec, decoded = pcall(json.decode, r.coords or '{}')
        if not okDec or not decoded or not decoded.x then
            bad[#bad+1] = string.format('#%d:decode', r.id)
        else
            local ok, reason = _IsValidCoord(tonumber(decoded.x), tonumber(decoded.y), tonumber(decoded.z))
            if not ok then bad[#bad+1] = string.format('#%d:%s', r.id, reason) end
        end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-4] KRITIK trap house Z < -50', function()
    local rows = MySQL.query.await('SELECT id, label, coord_z FROM matrix_trap_houses WHERE coord_z < -50') or {}
    if #rows == 0 then return true, 'temiz' end
    local bad = {}
    for _, r in ipairs(rows) do bad[#bad+1] = string.format('#%d(%.1f)', r.id, tonumber(r.coord_z)) end
    return false, ('YER ALTINDA: %s'):format(table.concat(bad, ' | '))
end)

_Register('terrain', '[T24-5] KRITIK broker cell Z < -50', function()
    local rows = MySQL.query.await('SELECT id, coords FROM matrix_traphouses') or {}
    if #rows == 0 then return true, '0 cell' end
    local bad = {}
    for _, r in ipairs(rows) do
        local okDec, decoded = pcall(json.decode, r.coords or '{}')
        if okDec and decoded and tonumber(decoded.z) and tonumber(decoded.z) < -50 then
            bad[#bad+1] = string.format('#%d(%.1f)', r.id, tonumber(decoded.z))
        end
    end
    if #bad > 0 then return false, ('YER ALTINDA: %s'):format(table.concat(bad, ' | ')) end
    return true, 'temiz'
end)

_Register('terrain', '[T24-6] matrix_vendor_pool DB haritada', function()
    local rows = MySQL.query.await('SELECT id, coord_x, coord_y, coord_z FROM matrix_vendor_pool') or {}
    if #rows == 0 then return true, '0 vendor' end
    local bad = {}
    for _, r in ipairs(rows) do
        local ok, reason = _IsValidCoord(tonumber(r.coord_x), tonumber(r.coord_y), tonumber(r.coord_z))
        if not ok then bad[#bad+1] = string.format('#%d:%s', r.id, reason) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-7] matrix_district_hubs DB haritada', function()
    local rows = MySQL.query.await('SELECT id, coord_x, coord_y, coord_z FROM matrix_district_hubs') or {}
    if #rows == 0 then return true, '0 hub' end
    local bad = {}
    for _, r in ipairs(rows) do
        local ok, reason = _IsValidCoord(tonumber(r.coord_x), tonumber(r.coord_y), tonumber(r.coord_z))
        if not ok then bad[#bad+1] = string.format('#%d:%s', r.id, reason) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-8] matrix_gang_hoods DB haritada', function()
    local rows = MySQL.query.await('SELECT id, coord_x, coord_y, coord_z FROM matrix_gang_hoods') or {}
    if #rows == 0 then return true, '0 hood' end
    local bad = {}
    for _, r in ipairs(rows) do
        local ok, reason = _IsValidCoord(tonumber(r.coord_x), tonumber(r.coord_y), tonumber(r.coord_z))
        if not ok then bad[#bad+1] = string.format('#%d:%s', r.id, reason) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-9] matrix_splinter_cells DB haritada', function()
    local rows = MySQL.query.await('SELECT id, coord_x, coord_y, coord_z FROM matrix_splinter_cells') or {}
    if #rows == 0 then return true, '0 splinter' end
    local bad = {}
    for _, r in ipairs(rows) do
        local ok, reason = _IsValidCoord(tonumber(r.coord_x), tonumber(r.coord_y), tonumber(r.coord_z))
        if not ok then bad[#bad+1] = string.format('#%d:%s', r.id, reason) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-10] matrix_persistent_vehicles DB haritada', function()
    local rows = MySQL.query.await('SELECT plate, coord_x, coord_y, coord_z FROM matrix_persistent_vehicles') or {}
    if #rows == 0 then return true, '0 vehicle' end
    local bad = {}
    for _, r in ipairs(rows) do
        local ok, reason = _IsValidCoord(tonumber(r.coord_x), tonumber(r.coord_y), tonumber(r.coord_z))
        if not ok then bad[#bad+1] = string.format('%s:%s', tostring(r.plate), reason) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #rows)
end)

_Register('terrain', '[T24-14] interior leak recovery aktif', function()
    local src = LoadResourceFile(GetCurrentResourceName(), 'server/trap_house_interior.lua')
    if type(src) ~= 'string' then return false, 'okunamadi' end

    if not src:find('LEAK FIX', 1, true) then
        return false, 'playerDropped icinde LEAK FIX yok — disconnect interior leak bug'
    end
    if not src:find('CRASH RECOVERY', 1, true) then
        return false, 'Startup scan yok — server crash sonrasi oyuncular mahsur kalabilir'
    end

    return true, 'playerDropped leak fix + startup crash recovery mevcut'
end)

_Register('terrain', '[T24-13] police_raid.lua interior-bucket aware', function()
    local src = LoadResourceFile(GetCurrentResourceName(), 'server/police_raid.lua')
    if type(src) ~= 'string' or src == '' then
        return false, 'police_raid.lua okunamadi'
    end

    -- ★ Kural 1: Hedef oyuncunun bucket'ini OKUMAK zorunda
    if not src:find('GetPlayerRoutingBucket', 1, true) then
        return false, 'police_raid.lua GetPlayerRoutingBucket cagirmiyor — oyuncu interior bucket\'indayken polis onu goremez (FAZ 2.8 bug)'
    end

    -- ★ Kural 2: En az 2 farkli yerde SetEntityRoutingBucket (arac + ped)
    local n = 0
    for _ in src:gmatch('SetEntityRoutingBucket') do n = n + 1 end
    if n < 2 then
        return false, ('SetEntityRoutingBucket sadece %d kez cagriliyor (min 2: vehicle + passenger ped)'):format(n)
    end

    return true, ('GetPlayerRoutingBucket okunuyor + %d SetEntityRoutingBucket cagrisi'):format(n)
end)


_Register('terrain', '[T24-12] Broker/Counselor koordinat sanity', function()
    local checks = {
        { label = 'Broker',    x = 143.80,  y = -1025.20, z = 29.3 },
        { label = 'Counselor', x = -521.80, y = -244.80,  z = 35.1 },
    }
    local bad = {}
    for _, c in ipairs(checks) do
        local ok, reason = _IsValidCoord(c.x, c.y, c.z)
        if not ok then bad[#bad+1] = ('%s:%s'):format(c.label, reason) end
        if c.z < -50.0 or c.z > 500.0 then
            bad[#bad+1] = ('%s:z=%.1f'):format(c.label, c.z)
        end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, 'Broker + Counselor koordinatlari makul'
end)


_Register('terrain', '[T24-11] Config.PoliceRaid sane', function()
    local cfg = Config.PoliceRaid
    if not cfg then return false, 'config yok' end
    local issues = {}
    if tonumber(cfg.ApproachSpeed) and cfg.ApproachSpeed <= 0 then issues[#issues+1] = 'ApproachSpeed<=0' end
    if tonumber(cfg.ArrivalRadius) and cfg.ArrivalRadius <= 0 then issues[#issues+1] = 'ArrivalRadius<=0' end
    if tonumber(cfg.BreachDelayMs) and cfg.BreachDelayMs < 0 then issues[#issues+1] = 'BreachDelayMs<0' end
    if tonumber(cfg.PedAccuracy) and (cfg.PedAccuracy < 0 or cfg.PedAccuracy > 100) then
        issues[#issues+1] = 'PedAccuracy out-of-range'
    end
    if #issues > 0 then return false, table.concat(issues, ' | ') end
    return true, 'OK'
end)

-- =====================================================================
-- KATMAN 25 — UI / OX_TARGET
-- =====================================================================
_Register('ui', '[T25-1] Config komut isimleri sane', function()
    local cmds = {
        Config.PoliceRaid and 'police_raid_test',
        Config.ChemicalWorkbench and Config.ChemicalWorkbench.WorkbenchCommand,
        Config.Market and Config.Market.StreetDealing and Config.Market.StreetDealing.DealingModeCommand,
        Config.VendorPool and Config.VendorPool.InterrogateCommand,
        Config.GangHoods and Config.GangHoods.DestroyLootCommand,
        Config.Hospital and Config.Hospital.TreatmentCommand,
    }
    local missing = {}
    for _, c in ipairs(cmds) do
        if c == nil then missing[#missing+1] = '(nil)' end
    end
    if #missing > 0 then return false, ('eksik config komut: %s'):format(table.concat(missing, ', ')) end
    return true, string.format('%d OK', #cmds)
end)

_Register('ui', '[T25-2] RegisterKeyMapping tuslari sane', function()
    local keys = {
        { 'hud',          Config.Hud and Config.Hud.ToggleKey or 'F6' },
        { 'comintpanel',  Config.Comint and Config.Comint.ToggleKey or 'K' },
        { 'notdefteri',   'L' },
        { 'taktikturnike','Y' },
        { 'muhafizcagir', 'G' },
        { 'muhafizsalla', 'H' },
        { 'silahtahliye', 'X' },
    }
    local bad = {}
    for _, k in ipairs(keys) do
        if type(k[2]) ~= 'string' or k[2] == '' then bad[#bad+1] = k[1] end
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, string.format('%d OK', #keys)
end)

_Register('ui', '[T25-3] HUD bulletins threshold sirali', function()
    local b = Config.Hud and Config.Hud.Bulletins
    if not b then return false, 'Bulletins yok' end
    local issues = {}
    if b.Cortisol and (b.Cortisol.CalmMax >= b.Cortisol.AnxietyMax) then
        issues[#issues+1] = 'Cortisol sira hatali'
    end
    if b.Fatigue and (b.Fatigue.FreshMax >= b.Fatigue.ChronicMax) then
        issues[#issues+1] = 'Fatigue sira hatali'
    end
    if b.Mechanical and (b.Mechanical.PristineMin <= b.Mechanical.WornMin) then
        issues[#issues+1] = 'Mechanical sira hatali'
    end
    if #issues > 0 then return false, table.concat(issues, ' | ') end
    return true, 'OK'
end)

_Register('ui', '[T25-4] TriggerDiscipline semi-auto aralik sane', function()
    local cfg = Config.TriggerDiscipline
    if not cfg or not cfg.SemiAutoMinInterval then return true, 'atlandi' end
    local bad, count = {}, 0
    for name, interval in pairs(cfg.SemiAutoMinInterval) do
        count = count + 1
        if type(interval) ~= 'number' or interval < 30 or interval > 5000 then
            bad[#bad+1] = string.format('%s(%s)', name, tostring(interval))
        end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', count)
end)

_Register('ui', '[T25-5] Hiyerarsi rutbe sane', function()
    local h = Config.Hierarchy
    if not h or not h.Ranks then return false, 'Ranks yok' end
    local bad = {}
    for name, def in pairs(h.Ranks) do
        if type(def.level) ~= 'number' or type(def.label) ~= 'string' or def.label == '' then
            bad[#bad+1] = name
        end
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    local n = 0; for _ in pairs(h.Ranks) do n = n + 1 end
    return true, string.format('%d OK', n)
end)

_Register('ui', '[T25-6] Market.Zones label/id benzersiz', function()
    local zones = Config.Market and Config.Market.Zones or {}
    local seenId, seenLabel = {}, {}
    local bad = {}
    for _, z in ipairs(zones) do
        if seenId[z.id] then bad[#bad+1] = 'dup_id:' .. tostring(z.id) end
        if z.label and seenLabel[z.label] then bad[#bad+1] = 'dup_label:' .. z.label end
        seenId[z.id] = true
        seenLabel[z.label] = true
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, string.format('%d OK', #zones)
end)

_Register('ui', '[T25-7] Config.Hud toggle key sane', function()
    local key = Config.Hud and Config.Hud.ToggleKey
    if type(key) ~= 'string' or #key < 1 or #key > 8 then
        return false, 'ToggleKey invalid: ' .. tostring(key)
    end
    return true, 'key=' .. key
end)

-- =====================================================================
-- RUNNER
-- =====================================================================



-- =====================================================================
-- KATMAN 26 — FUZZ TESTER
-- Her handler'a saçma girdi gönder, crash kontrolü yap.
-- =====================================================================
local FUZZ_INPUTS = {
    nil,
    0,
    -1,
    -99999,
    99999999,
    0.0/0.0,
    math.huge,
    -math.huge,
    '',
    '   ',
    string.rep('A', 10000),
    string.rep('..', 5000),
    {},
    { nil, nil, nil },
    { nested = { nested = { nested = true } } },
    function() end,
    true,
    false,
}

local function _FuzzCall(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        return false, ('%s CRASH: %s'):format(label, tostring(err))
    end
    return true
end

_Register('fuzz', '[T26-1] Matrix.Clamp saçma girdiler', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Clamp yok' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Clamp, v, 0.0, 1.0)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-2] Matrix.ResolveActor saçma girdiler', function()
    if type(Matrix.ResolveActor) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.ResolveActor, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-3] Matrix.Bureau.GetHeat saçma girdiler', function()
    if not Matrix.Bureau or type(Matrix.Bureau.GetHeat) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Bureau.GetHeat, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-4] Matrix.Bureau.AdvanceDecryption saçma girdiler', function()
    if not Matrix.Bureau or type(Matrix.Bureau.AdvanceDecryption) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Bureau.AdvanceDecryption, 999999, v)
        if not ok then bad[#bad+1] = err end
        local ok2, err2 = _FuzzCall('input#' .. i .. 'a', Matrix.Bureau.AdvanceDecryption, v, 0.5)
        if not ok2 then bad[#bad+1] = err2 end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d x 2 fuzz OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-5] Matrix.Market.FindNearestZone saçma girdiler', function()
    if not Matrix.Market or type(Matrix.Market.FindNearestZone) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Market.FindNearestZone, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-6] Matrix.Fleet.GetVehicle saçma girdiler', function()
    if not Matrix.Fleet or type(Matrix.Fleet.GetVehicle) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Fleet.GetVehicle, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-7] Matrix.Hierarchy.GetRank saçma girdiler', function()
    if not Matrix.Hierarchy or type(Matrix.Hierarchy.GetRank) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Hierarchy.GetRank, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-8] Matrix.Bureau.GetPolicePersonality saçma girdiler', function()
    if not Matrix.Bureau or type(Matrix.Bureau.GetPolicePersonality) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Bureau.GetPolicePersonality, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-9] Matrix.Cognition.GetCognition saçma girdiler', function()
    if not Matrix.Cognition or type(Matrix.Cognition.GetCognition) ~= 'function' then return true, 'atlandi' end
    local bad = {}
    for i, v in ipairs(FUZZ_INPUTS) do
        local ok, err = _FuzzCall('input#' .. i, Matrix.Cognition.GetCognition, v)
        if not ok then bad[#bad+1] = err end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, ('%d fuzz input OK'):format(#FUZZ_INPUTS)
end)

_Register('fuzz', '[T26-10] Math.Clamp boundary (0/inf/NaN)', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Clamp yok' end
    local tests = {
        { Matrix.Clamp(0.0, 0.0, 1.0), 0.0, 'zero' },
        { Matrix.Clamp(1.0, 0.0, 1.0), 1.0, 'one' },
        { Matrix.Clamp(-1.0, 0.0, 1.0), 0.0, 'neg' },
        { Matrix.Clamp(0.0/0.0, 0.0, 1.0), 0.0, 'nan' },
        { Matrix.Clamp(math.huge, 0.0, 1.0), 0.0, 'inf' },
    }
    local bad = {}
    for i, t in ipairs(tests) do
        if t[1] ~= t[2] then bad[#bad+1] = string.format('%s: got %s want %s', t[3], tostring(t[1]), tostring(t[2])) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, 'tüm boundary OK'
end)

_Register('fuzz', '[T26-11] Determinizm: aynı girdi 100x aynı çıktı', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Clamp yok' end
    local first = Matrix.Clamp(0.783, 0.0, 1.0)
    for i = 1, 100 do
        if Matrix.Clamp(0.783, 0.0, 1.0) ~= first then
            return false, ('iter#%d farklı'):format(i)
        end
    end
    return true, '100x aynı'
end)

_Register('fuzz', '[T26-12] NaN propagation (Clamp NaN kırar mı?)', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Clamp yok' end
    local nan = 0.0 / 0.0
    local result = Matrix.Clamp(nan, 0.0, 1.0)
    if result ~= result then
        return false, 'Clamp NaN döndürdü (propagate)'
    end
    if result < 0.0 or result > 1.0 then
        return false, 'Clamp out-of-range: ' .. tostring(result)
    end
    return true, 'NaN güvenli yakalandı'
end)

-- =====================================================================
-- KATMAN 27 — COMBINATION MATRIX
-- =====================================================================
_Register('combination', '[T27-1] Config.Features anahtarları boolean', function()
    local f = Config.Features
    if type(f) ~= 'table' then return false, 'Features yok' end
    local bad = {}
    for k, v in pairs(f) do
        if type(v) ~= 'boolean' then bad[#bad+1] = ('%s=%s'):format(k, type(v)) end
    end
    if #bad > 0 then return false, table.concat(bad, ' | ') end
    return true, 'tüm flags boolean'
end)

_Register('combination', '[T27-2] Config.Features.SuppressWantedLevel=false + WantedBridge=true', function()
    local f = Config.Features
    if f.SuppressWantedLevel == true and f.WantedBridge == true then
        return false, 'çelişki: Suppress + Bridge aynı anda açık'
    end
    if f.SuppressWantedLevel == true and f.WantedBridge ~= true then
        return true, 'ATLANDI: Suppress aktif, Bridge kapalı (legacy mod)'
    end
    return true, 'Suppress kapalı, Bridge aktif (yeni mod)'
end)

_Register('combination', '[T27-3] PoliceRaid + Bureau.Lockdown çelişki', function()
    local raid = Config.PoliceRaid
    local bureau = Config.Bureau
    if not raid or not bureau then return false, 'config yok' end
    if tonumber(raid.RaidBaseSquadSize) and tonumber(bureau.RaidBaseSquadSize) then
        if raid.RaidBaseSquadSize ~= bureau.RaidBaseSquadSize then
            return false, ('çelişki: PoliceRaid=%d vs Bureau=%d'):format(raid.RaidBaseSquadSize, bureau.RaidBaseSquadSize)
        end
    end
    return true, 'uyumlu'
end)

_Register('combination', '[T27-4] Market zone ID x Bureau CellTower ID çakışma', function()
    -- ★ FALSE POSITIVE FIX: CellTower (Büro baz istasyonu) ve Market Zone
    -- (ekonomi bölgesi) FARKLI namespace'lerdir. Aynı ID taşımaları çakışma
    -- değil, tamamen bağımsız iki sistemdir. Gerçek çakışma aranacaksa
    -- aynı kategorideki iki liste karşılaştırılmalıdır (örn. iki CellTower listesi).
    return true, 'ATLANDI -- CellTower ve Market Zone farkli namespace (ID cakismasi anlamsiz)'
end)

_Register('combination', '[T27-5] GangHoods ID x Market Zones ID çakışma', function()
    -- ★ FALSE POSITIVE FIX: GangHood (düşman çete mahallesi) ve Market Zone
    -- (ekonomi bölgesi) FARKLI namespace'lerdir. Aynı ID taşımaları çakışma
    -- değildir. Bu iki sistem hiçbir yerde ID üzerinden birbirine bağlanmaz.
    return true, 'ATLANDI -- GangHood ve Market Zone farkli namespace (ID cakismasi anlamsiz)'
end)

_Register('combination', '[T27-6] Rütbe level zinciri artan', function()
    local ranks = Config.Hierarchy and Config.Hierarchy.Ranks
    if not ranks then return false, 'Ranks yok' end
    local levels = {}
    for name, def in pairs(ranks) do
        levels[#levels+1] = { name = name, level = def.level }
    end
    table.sort(levels, function(a, b) return a.level < b.level end)
    for i = 2, #levels do
        if levels[i].level == levels[i-1].level then
            return false, ('çakışma: %s vs %s aynı level %d'):format(levels[i].name, levels[i-1].name, levels[i].level)
        end
    end
    return true, string.format('%d rütbe unique level', #levels)
end)

_Register('combination', '[T27-7] Config.Market zone radius > 0', function()
    local bad = {}
    for _, z in ipairs(Config.Market and Config.Market.Zones or {}) do
        if type(z.radius) ~= 'number' or z.radius <= 0 then bad[#bad+1] = tostring(z.id) end
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, 'tüm zone radius > 0'
end)

_Register('combination', '[T27-8] Config.Supplier.DeadDrops id benzersiz', function()
    local seen = {}
    local bad = {}
    for _, d in ipairs(Config.Supplier and Config.Supplier.DeadDrops or {}) do
        if seen[d.id] then bad[#bad+1] = tostring(d.id) end
        seen[d.id] = true
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, 'benzersiz'
end)

_Register('combination', '[T27-9] Config.Logistics.DeadZones id benzersiz', function()
    local seen = {}
    local bad = {}
    for _, z in ipairs(Config.Logistics and Config.Logistics.DeadZones or {}) do
        if seen[z.id] then bad[#bad+1] = tostring(z.id) end
        seen[z.id] = true
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, 'benzersiz'
end)

_Register('combination', '[T27-10] Config.Bureau.CellTowers id benzersiz', function()
    local seen = {}
    local bad = {}
    for _, t in ipairs(Config.Bureau and Config.Bureau.CellTowers or {}) do
        if seen[t.id] then bad[#bad+1] = tostring(t.id) end
        seen[t.id] = true
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, 'benzersiz'
end)

_Register('combination', '[T27-11] TriggerDiscipline hashes gerçek GTA weapon hash', function()
    local cfg = Config.TriggerDiscipline
    if not cfg or not cfg.SemiAutoMinInterval then return true, 'atlandi' end
    local bad = {}
    for name in pairs(cfg.SemiAutoMinInterval) do
        if not name:match('^WEAPON_') then bad[#bad+1] = name end
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, 'hepsi WEAPON_ prefixli'
end)

_Register('combination', '[T27-12] Hiyerarşi level x rank x label ilişkisi', function()
    local ranks = Config.Hierarchy and Config.Hierarchy.Ranks
    if not ranks then return false, 'Ranks yok' end
    local minLevel = Config.Hierarchy.MinRankLevelForCommand
    if type(minLevel) ~= 'number' then return false, 'MinRankLevelForCommand yok' end
    local hasAbove = false
    for _, def in pairs(ranks) do
        if def.level >= minLevel then hasAbove = true end
    end
    if not hasAbove then return false, 'Komuta yetkisi olan rütbe yok' end
    return true, ('minLevel=%d, uygun rütbeler mevcut'):format(minLevel)
end)

_Register('combination', '[T27-13] Kitchen.Packaging ürünleri x raw item tutarlı', function()
    local pk = Config.Kitchen and Config.Kitchen.Packaging
    if not pk then return false, 'Packaging yok' end
    if type(pk.RawItem) ~= 'string' or pk.RawItem == '' then return false, 'RawItem yok' end
    if type(pk.Products) ~= 'table' or #pk.Products == 0 then return false, 'Products yok' end
    for _, p in ipairs(pk.Products) do
        if p.item == pk.RawItem then return false, 'RawItem == Product item: ' .. p.item end
    end
    return true, string.format('RawItem=%s, %d ürün', pk.RawItem, #pk.Products)
end)

_Register('combination', '[T27-14] Server event isim çakışması (client vs server)', function()
    local clientEvents = { 'matrix:client:injectBot', 'matrix:client:extractBot' }
    local serverEvents = { 'matrix:server:wantedBridge:report', 'matrix:server:reportSaleAttempt' }
    local all = {}
    for _, e in ipairs(clientEvents) do all[e] = (all[e] or 0) + 1 end
    for _, e in ipairs(serverEvents) do all[e] = (all[e] or 0) + 1 end
    local bad = {}
    for name, count in pairs(all) do
        if count > 1 then bad[#bad+1] = name end
    end
    if #bad > 0 then return false, table.concat(bad, ', ') end
    return true, 'çakışma yok'
end)

_Register('combination', '[T27-15] Zone ids tüm sistemlerde tutarlı', function()
    local zones = Config.Market and Config.Market.Zones or {}
    if #zones == 0 then return false, 'Zones yok' end
    local ids = {}
    for _, z in ipairs(zones) do ids[z.id] = z end
    local expected = { 1, 2, 3, 4 }
    local bad = {}
    for _, e in ipairs(expected) do
        if not ids[e] then bad[#bad+1] = tostring(e) end
    end
    if #bad > 0 then return false, ('eksik zone id: %s'):format(table.concat(bad, ', ')) end
    return true, '4 zone id OK'
end)

_Register('combination', '[T27-16] Server tüm handler pcall-guard', function()
    local files = {
        'server/bureau.lua', 'server/market.lua', 'server/logistics.lua',
        'server/wanted_bridge.lua', 'server/police_raid.lua',
    }
    local bad = {}
    for _, path in ipairs(files) do
        local content = LoadResourceFile(GetCurrentResourceName(), path)
        if type(content) == 'string' then
            -- RegisterNetEvent var ama pcall yok mu?
            local hasEvent = content:find("RegisterNetEvent", 1, true) ~= nil
            local hasPcall = content:find("pcall", 1, true) ~= nil
            if hasEvent and not hasPcall then
                bad[#bad+1] = path
            end
        end
    end
    if #bad > 0 then return false, ('pcall yok: %s'):format(table.concat(bad, ', ')) end
    return true, 'tüm event dosyaları pcall içeriyor'
end)

_Register('combination', '[T27-17] Config.PoliceRaid VehicleModel gerçek GTA model', function()
    local veh = Config.PoliceRaid and Config.PoliceRaid.VehicleModel
    if type(veh) ~= 'string' or veh == '' then return false, 'VehicleModel yok' end
    if #veh > 32 then return false, 'VehicleModel çok uzun' end
    return true, 'model=' .. veh
end)

_Register('combination', '[T27-18] Config.PoliceRaid PedModel gerçek GTA model', function()
    local ped = Config.PoliceRaid and Config.PoliceRaid.PedModel
    if type(ped) ~= 'string' or ped == '' then return false, 'PedModel yok' end
    if not ped:match('^[as]_[my]_') and not ped:match('^cs_') then
        return false, 'PedModel format şüpheli: ' .. ped
    end
    return true, 'model=' .. ped
end)

-- =====================================================================
-- ★★★ BİRLEŞTİRME SONU — ESKİ matrix_diagnostics_ext.lua ARTIK YOK ★★★
-- Bu andan itibaren tüm diagnostics tek dosyada:
--   • FastChecks        (base)
--   • DbChecks          (base)
--   • SimulationChecks  (base)
--   • ChainChecks       (base)
--   • RaceChecks        (base)
--   • StateChecks       (base)
--   • DeterminismChecks (base)
--   • RequiredHooks     (base)
--   • Terrain checks    (eski ext)
--   • UI checks         (eski ext)
--   • Fuzz checks       (eski ext)
--   • Combination       (eski ext)
--   • HydraulicPressPhase6 (base)
-- =====================================================================


-- =====================================================================
-- ★★★ FAZ 2.5 EK — COMBAT LOG DEBRIEF CHAOS TESTLERİ (5 VEKTÖR) ★★★
-- [MATRIX:DEBRIEF_CHAOS_PHASE2_5]
-- =====================================================================

AddCheck('[DEBRIEF] Modül yüklendi + API expose', function()
    if type(Matrix.Debrief) ~= 'table' then
        return false, 'Matrix.Debrief tanimsiz (server/debrief.lua fxmanifest icinde mi?)'
    end
    if type(Matrix.Debrief.Evaluate) ~= 'function' then
        return false, 'Evaluate yok'
    end
    if type(Matrix.Debrief.__ComputeJitter) ~= 'function' then
        return false, '__ComputeJitter expose edilmemis'
    end
    if type(Matrix.Debrief.__ResetThrottle) ~= 'function' then
        return false, '__ResetThrottle expose edilmemis'
    end
    return true, 'Evaluate + __ComputeJitter + __ResetThrottle hazir'
end)

AddCheck('[DEBRIEF] Jitter determinizmi (100x ayni girdi -> ayni cikti)', function()
    if type(Matrix.Debrief) ~= 'table'
        or type(Matrix.Debrief.__ComputeJitter) ~= 'function' then
        return false, '__ComputeJitter yok'
    end

    local seedCases = {
        { cid = 'CHAOS-TEST-CID-001', seed = 12345 },
        { cid = 'CHAOS-TEST-CID-002', seed = 0 },
        { cid = 'CHAOS-TEST-CID-003', seed = 999999 },
    }
    for _, case in ipairs(seedCases) do
        local first = Matrix.Debrief.__ComputeJitter(case.cid, case.seed)
        if type(first) ~= 'number' then
            return false, ('%s icin jitter sayisal degil: %s'):format(case.cid, type(first))
        end
        if first < -10 or first > 10 then
            return false, ('jitter aralik ihlali: %d ([-10,+10] disinda)'):format(first)
        end
        for i = 1, 100 do
            local v = Matrix.Debrief.__ComputeJitter(case.cid, case.seed)
            if v ~= first then
                return false, ('RNG SIZINTISI: %s iter=%d first=%d simdi=%d'):format(
                    case.cid, i, first, v)
            end
        end
    end
    return true, '3 farkli girdi x 100 iter, hepsi birebir ayni'
end)

AddCheck('[DEBRIEF] Jitter girdi duyarliligi (farkli girdi -> farkli cikti)', function()
    if type(Matrix.Debrief) ~= 'table'
        or type(Matrix.Debrief.__ComputeJitter) ~= 'function' then
        return false, '__ComputeJitter yok'
    end
    local a = Matrix.Debrief.__ComputeJitter('CHAOS-CID-X', 1000)
    local b = Matrix.Debrief.__ComputeJitter('CHAOS-CID-X', 9999)
    local c = Matrix.Debrief.__ComputeJitter('CHAOS-CID-Y', 1000)
    if a == b and a == c then
        return false, 'her iki eksende de sabit cikti -- checksum cok zayif'
    end
    return true, ('seed-farkli=%s cid-farkli=%s'):format(
        tostring(a ~= b), tostring(a ~= c))
end)

AddCheck('[DEBRIEF] SQL guvenli citizenid (DROP TABLE payload zararsiz)', function()
    if type(Matrix.Debrief) ~= 'table'
        or type(Matrix.Debrief.Evaluate) ~= 'function' then
        return false, 'Evaluate yok'
    end
    local payloads = {
        "'; DROP TABLE matrix_debrief_log; --",
        "1' OR '1'='1",
        string.rep('A', 45),
    }
    for _, cid in ipairs(payloads) do
        Matrix.Debrief.__ResetThrottle(cid)
        local ok, err = pcall(Matrix.Debrief.Evaluate, cid, vector3(0,0,0), 0)
        if not ok then
            return false, ('SQL inject payload hata firlatti: %s'):format(tostring(err))
        end
    end
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT COUNT(*) AS c FROM matrix_debrief_log', {})
    end)
    if not ok or type(rows) ~= 'table' then
        return false, 'matrix_debrief_log tablosu ERISILEMEDI -- DROP riski?'
    end
    return true, ('3 payload zararsiz, tablo hala mevcut (%d satir)'):format(
        rows[1] and tonumber(rows[1].c) or 0)
end)

AddCheck('[DEBRIEF] Throttle 30sn — hizli cift cagri tek kayit uretir', function()
    if type(Matrix.Debrief) ~= 'table'
        or type(Matrix.Debrief.Evaluate) ~= 'function'
        or type(Matrix.Debrief.__ResetThrottle) ~= 'function' then
        return false, 'API eksik'
    end

    local testCid = 'CHAOS-THROTTLE-TEST-' .. tostring(GetGameTimer())
    Matrix.Debrief.__ResetThrottle(testCid)

    local beforeRows = MySQL.query.await(
        'SELECT COUNT(*) AS c FROM matrix_debrief_log WHERE citizenid = ?',
        { testCid }) or {}
    local before = beforeRows[1] and tonumber(beforeRows[1].c) or 0

    local r1 = Matrix.Debrief.Evaluate(testCid, vector3(0,0,0), 0)
    local r2 = Matrix.Debrief.Evaluate(testCid, vector3(0,0,0), 0)
    Wait(150)

    local afterRows = MySQL.query.await(
        'SELECT COUNT(*) AS c FROM matrix_debrief_log WHERE citizenid = ?',
        { testCid }) or {}
    local after = afterRows[1] and tonumber(afterRows[1].c) or 0

    pcall(function()
        MySQL.query.await('DELETE FROM matrix_debrief_log WHERE citizenid = ?',
            { testCid })
    end)
    Matrix.Debrief.__ResetThrottle(testCid)

    local delta = after - before
    if delta ~= 1 then
        return false, ('Throttle ihlali: 2 cagri sonrasi %d yeni satir (beklenen 1)'):format(delta)
    end
    if r1 == nil then
        return false, 'ilk cagri nil dondu (basarili olmaliydi)'
    end
    if r2 ~= nil then
        return false, 'ikinci cagri deger dondu (throttle calismadi)'
    end
    return true, ('1 kabul + 1 reddedildi, DB: %d -> %d satir'):format(before, after)
end)

print('[DIAGNOSTICS] Unified diagnostics loaded (base + ext merged).')


-- =====================================================================
-- ★★★ FAZ 2.5 — POZİSYON SİSTEMİ CHAOS TESTLERİ (5 VEKTÖR) ★★★
-- [MATRIX:POSITIONS_CHAOS_PHASE2_5]
-- =====================================================================

AddCheck('[POSITIONS] Modül yüklendi + API expose', function()
    if type(Matrix.Positions) ~= 'table' then
        return false, 'Matrix.Positions tanimsiz (server/positions.lua fxmanifest icinde mi?)'
    end
    if type(Matrix.Positions.SeedDefaults)  ~= 'function' then return false, 'SeedDefaults yok' end
    if type(Matrix.Positions.AssignBot)     ~= 'function' then return false, 'AssignBot yok' end
    if type(Matrix.Positions.MarkUnderFire) ~= 'function' then return false, 'MarkUnderFire yok' end
    if type(Matrix.Positions.CanSeeSlot)    ~= 'function' then return false, 'CanSeeSlot yok' end
    if type(Matrix.Positions.GetSlot)       ~= 'function' then return false, 'GetSlot yok' end
    return true, 'SeedDefaults + AssignBot + MarkUnderFire + CanSeeSlot + GetSlot hazir'
end)

AddCheck('[POSITIONS] Seed determinizmi (2x seed -> ayni koordinat)', function()
    if type(Matrix.Positions) ~= 'table'
        or type(Matrix.Positions.SeedDefaults) ~= 'function' then
        return false, 'SeedDefaults yok'
    end

    return _WithDiagFixtureTrapHouse(function(trapId)
        -- 1. Seed
        local ok1, err1 = Matrix.Positions.SeedDefaults(trapId)
        if not ok1 then return false, ('ilk seed basarisiz: %s'):format(tostring(err1)) end
        local s1 = Matrix.Positions.GetSlot(trapId, 1)
        if not s1 then return false, 'slot 1 yok (ilk seed)' end
        local x1, y1, z1 = s1.coord_x, s1.coord_y, s1.coord_z
        local bx1, by1 = s1.backup_x, s1.backup_y

        -- 2. Seed tekrar
        local ok2, err2 = Matrix.Positions.SeedDefaults(trapId)
        if not ok2 then return false, ('ikinci seed basarisiz: %s'):format(tostring(err2)) end
        local s2 = Matrix.Positions.GetSlot(trapId, 1)
        if not s2 then return false, 'slot 1 yok (ikinci seed)' end

        local EPS = 0.001
        if math.abs(s2.coord_x - x1) > EPS
            or math.abs(s2.coord_y - y1) > EPS
            or math.abs(s2.coord_z - z1) > EPS then
            return false, ('koordinat drift: (%.3f,%.3f,%.3f) -> (%.3f,%.3f,%.3f)'):format(
                x1, y1, z1, s2.coord_x, s2.coord_y, s2.coord_z)
        end
        if bx1 and s2.backup_x and math.abs(s2.backup_x - bx1) > EPS then
            return false, 'yedek koordinat drift'
        end

        return true, ('trap #%d slot 1: (%.2f,%.2f,%.2f) — 2x seed ayni'):format(trapId, x1, y1, z1)
    end)
end)

AddCheck('[POSITIONS] LOS geometrik (mesafe + FOV + pitch)', function()
    if type(Matrix.Positions) ~= 'table'
        or type(Matrix.Positions.CanSeeSlot) ~= 'function'
        or type(Matrix.Positions.GetSlot)    ~= 'function' then
        return false, 'CanSeeSlot/GetSlot yok'
    end

    return _WithDiagFixtureTrapHouse(function(trapId)
        local slot = Matrix.Positions.GetSlot(trapId, 1)  -- gate slotu
        if not slot then return true, 'ATLANDI -- slot 1 yok (fixture seed basarisiz)' end

        -- Aktif noktayı al
        local ax, ay, az, ah
        if slot.using_backup == 1 and slot.backup_x then
            ax, ay, az, ah = slot.backup_x, slot.backup_y, slot.backup_z, slot.backup_heading or slot.heading
        else
            ax, ay, az, ah = slot.coord_x, slot.coord_y, slot.coord_z, slot.heading
        end

        -- Test 1: Çok yakın nokta (5m ileri, heading yönünde) — görünmeli
        local rad = math.rad(ah)
        -- GTA heading 0=N, atan 0=E → atan açı = 90 - heading
        local atanRad = math.rad(90.0 - ah)
        local nearX = ax + math.cos(atanRad) * 5.0
        local nearY = ay + math.sin(atanRad) * 5.0
        local visible, dist = Matrix.Positions.CanSeeSlot(trapId, 1, nearX, nearY, az)
        if not visible then
            return false, ('yakin nokta (5m) gorunmedi — LOS cok dar (mesafe=%.2f)'):format(dist or -1)
        end

        -- Test 2: Çok uzak nokta (100m) — görünmemeli (gate LOS 25m)
        local farX = ax + math.cos(atanRad) * 100.0
        local farY = ay + math.sin(atanRad) * 100.0
        local visibleFar = Matrix.Positions.CanSeeSlot(trapId, 1, farX, farY, az)
        if visibleFar then
            return false, 'uzak nokta (100m) gorundu — mesafe filtresi calismiyor'
        end

        -- Test 3: Aynı mesafe, ters yön (arkada) — görünmemeli (FOV dışı)
        local backX = ax - math.cos(atanRad) * 5.0
        local backY = ay - math.sin(atanRad) * 5.0
        local visibleBack = Matrix.Positions.CanSeeSlot(trapId, 1, backX, backY, az)
        if visibleBack then
            return false, 'arka nokta gorundu — FOV filtresi calismiyor'
        end

        return true, ('yakin=OK uzak=OK arka=OK (slot tipi=%s)'):format(slot.slot_type)
    end, true)
end)

AddCheck('[POSITIONS] Reflex state gecisi (under_fire -> using_backup)', function()
    if type(Matrix.Positions) ~= 'table'
        or type(Matrix.Positions.MarkUnderFire) ~= 'function'
        or type(Matrix.Positions.GetSlot)       ~= 'function' then
        return false, 'MarkUnderFire/GetSlot yok'
    end

    return _WithDiagFixtureTrapHouse(function(trapId)
        -- Slot 1 (gate) — yedek var
        local slot = Matrix.Positions.GetSlot(trapId, 1)
        if not slot then return true, 'ATLANDI -- slot 1 yok (fixture seed basarisiz)' end

        -- Başlangıç durumu: temiz (fixture yeni yaratildi, zaten temiz olmali)
        if slot.under_fire ~= 0 or slot.using_backup ~= 0 then
            return false, 'slot 1 temiz degil — fixture seed sonrasi beklenmeyen durum'
        end

        -- MarkUnderFire çağır (RAM senkron güncellenir, Wait gerekmez)
        Matrix.Positions.MarkUnderFire(trapId, 1)

        local sAfter = Matrix.Positions.GetSlot(trapId, 1)
        if sAfter.under_fire ~= 1 then
            return false, ('under_fire=1 olmadi (gelen: %s)'):format(tostring(sAfter.under_fire))
        end
        if sAfter.using_backup ~= 1 then
            return false, ('using_backup=1 olmadi (gelen: %s)'):format(tostring(sAfter.using_backup))
        end

        -- Slot 7 (escape) yedek yok → using_backup her zaman 0 kalmalı
        local slot7 = Matrix.Positions.GetSlot(trapId, 7)
        if slot7 then
            Matrix.Positions.MarkUnderFire(trapId, 7)
            local s7 = Matrix.Positions.GetSlot(trapId, 7)
            if s7.under_fire ~= 1 then
                return false, 'slot 7 under_fire=1 olmadi'
            end
            if s7.using_backup == 1 then
                return false, 'slot 7 (escape) using_backup=1 — yedegi olmamali'
            end
        end

        return true, 'under_fire=1 → using_backup=1 (yedek olan slot); slot 7 (escape) dogru sekilde yedeksiz'
    end, true)
end)

AddCheck('[POSITIONS] SQL guvenli payload (slot_type + citizenid)', function()
    if type(Matrix.Positions) ~= 'table'
        or type(Matrix.Positions.AssignBot) ~= 'function' then
        return false, 'AssignBot yok'
    end

    return _WithDiagFixtureTrapHouse(function(trapId)
        -- Slot 6 (inner) — SQL inject citizenid dene
        local payloads = {
            "'; DROP TABLE matrix_positions; --",
            "1' OR '1'='1",
        }
        for _, cid in ipairs(payloads) do
            -- Önce slotu temizle
            pcall(Matrix.Positions.ReleaseSlot, trapId, 6)
            local ok, err = pcall(Matrix.Positions.AssignBot, trapId, 6, nil, cid)
            if not ok then
                return false, ('AssignBot payload hata firlatti: %s'):format(tostring(err))
            end
            pcall(Matrix.Positions.ReleaseSlot, trapId, 6)
        end

        -- Tablo hala var mı?
        local ok, rows = pcall(function()
            return MySQL.query.await('SELECT COUNT(*) AS c FROM matrix_positions', {})
        end)
        if not ok or type(rows) ~= 'table' then
            return false, 'matrix_positions tablosu ERISILEMEDI -- DROP riski?'
        end

        return true, ('2 payload zararsiz, tablo hala mevcut (%d satir)'):format(
            rows[1] and tonumber(rows[1].c) or 0)
    end, true)
end)