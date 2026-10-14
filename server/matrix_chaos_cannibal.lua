-- =====================================================================
-- ★★★ CANNIBAL — ÇÖKERTİCİ KATMAN v1.0 ★★★
-- server/matrix_chaos_cannibal.lua
--
-- FELSEFE: Diğer chaos modülleri "davranış testi" yapar.
-- Bu modül "YIKIM TESTİ" yapar — sistemi KASITLI OLARAK kırmaya çalışır.
--
-- SONUÇ KATEGORİLERİ:
--   • SURVIVED → Sistem saldırıyı absorbe etti (iyi)
--   • DEFENDED → Sistem aktif savunma yaptı (en iyi)
--   • CORRUPTED→ Sessiz veri bozulması (tehlikeli!)
--   • CRASHED  → Sistem çöktü (bulgu)
--
-- ★ GÜVENLİK: Config.Chaos.AllowCannibal = true olmadan ÇALIŞMAZ.
-- =====================================================================

if not (Config.Chaos and Config.Chaos.Enabled and Config.Chaos.AllowCannibal) then
    print('[CHAOS][cannibal] Devre disi (Config.Chaos.AllowCannibal != true)')
    return
end

local math_huge   = math.huge
local string_rep  = string.rep
local table_concat = table.concat

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 1: METATABLE TRAP
-- Paylaşılan bir state tablosuna error-throwing metatable enjekte et.
-- Eğer okuyan kod pcall kullanmıyorsa → resource CRASH.
-- ═════════════════════════════════════════════════════════════════════
local function _attack_metatable_trap()
    print('[CHAOS][cannibal] Attack 1: Metatable Trap')

    local testBot = Matrix.CreateBotRecord({
        name = 'CANNIBAL-MT-TRAP',
        role = 'diagnostic_test',
    })
    if not testBot or not testBot.id then return end

    Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true

    -- ★ TRAP: her erişimde hata fırlatan metatable
    local trap = setmetatable({}, {
        __index    = function() error('CANNIBAL_MT_INDEX') end,
        __newindex = function() error('CANNIBAL_MT_NEWINDEX') end,
        __len      = function() error('CANNIBAL_MT_LEN') end,
        __call     = function() error('CANNIBAL_MT_CALL') end,
        __tostring = function() error('CANNIBAL_MT_TOSTRING') end,
    })

    -- Bot biology'yi trap ile değiştir
    local originalBiology = testBot.biology
    testBot.biology = trap

    -- Sistem bu botla çalışmaya çalışsın — hangi yol patlıyor?
    local attacks = {
        { name = 'GetEffectiveSkill', fn = function()
            return Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill
                and Matrix.Kitchen.GetEffectiveSkill(testBot, 'skill_chemistry')
        end },
        { name = 'AdjustCortisol', fn = function()
            return Matrix.Kitchen and Matrix.Kitchen.AdjustCortisol
                and Matrix.Kitchen.AdjustCortisol({ kind='bot', id=testBot.id }, 'gunshot')
        end },
        { name = 'ComputeSnitchIndex', fn = function()
            return Matrix.Kitchen and Matrix.Kitchen.ComputeSnitchIndex
                and Matrix.Kitchen.ComputeSnitchIndex(testBot)
        end },
        { name = 'MarkBotDirty', fn = function()
            return Matrix.MarkBotDirty and Matrix.MarkBotDirty(testBot.id)
        end },
    }

    for _, atk in ipairs(attacks) do
        local ok, err = pcall(atk.fn)
        if not ok then
            local errStr = tostring(err)
            if errStr:find('CANNIBAL_MT_') then
                -- Framework yakaladı ama metatable'a dokundu → defensive
                print(('[CHAOS][cannibal] DEFENDED: %s — %s'):format(atk.name, errStr))
            else
                Matrix.Chaos.Report('HIGH', ('Cannibal: %s metatable trap altinda patladi'):format(atk.name), {
                    file   = 'server/matrix_chaos_cannibal.lua',
                    attack = ('bot.biology = metatable(error-trap) → %s cagirildi'):format(atk.name),
                    impact = ('Fonksiyon yakaladi ama beklenen CANNIBAL_MT_ hata yok: %s'):format(errStr:sub(1,80)),
                    fix    = ('%s fonksiyonu biology field erisimini guard etmiyor.'):format(atk.name),
                    evidence = ('error=%s'):format(errStr),
                })
            end
        else
            print(('[CHAOS][cannibal] SURVIVED: %s'):format(atk.name))
        end
    end

    testBot.biology = originalBiology
end

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 2: SHARED STATE YANK
-- Operasyon sürerken paylaşılan state'i nil'le. Race window yakala.
-- ═════════════════════════════════════════════════════════════════════
local function _attack_shared_state_yank()
    print('[CHAOS][cannibal] Attack 2: Shared State Yank')

    local testBot = Matrix.CreateBotRecord({
        name = 'CANNIBAL-YANK',
        role = 'diagnostic_test',
    })
    if not testBot or not testBot.id then return end

    Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true
    local botId = testBot.id

    -- Thread 1: Uzun süren işlem başlat
    local opStarted = false
    local opDone = false
    local opError = nil

    CreateThread(function()
        opStarted = true
        local ok, err = pcall(function()
            for i = 1, 500 do
                Matrix.MarkBotDirty(botId)
                if i % 50 == 0 then Wait(0) end
            end
        end)
        if not ok then opError = tostring(err) end
        opDone = true
    end)

    -- Thread 2: İşlem sürerken state'i çek
    CreateThread(function()
        while not opStarted do Wait(0) end
        Wait(5)  -- operasyon başlasın, sonra çek
        Matrix.Bots[botId] = nil
    end)

    -- Bekle
    local waited = 0
    while not opDone and waited < 3000 do
        Wait(50); waited = waited + 50
    end

    if opError then
        Matrix.Chaos.Report('HIGH', 'Cannibal: Mid-op state yank crash', {
            file   = 'server/main.lua',
            attack = 'MarkBotDirty calisirken Matrix.Bots[id] = nil',
            impact = ('pcall: %s'):format(opError),
            fix    = 'MarkBotDirty başında Matrix.Bots[id] guard ekle.',
            evidence = ('error=%s'):format(opError),
        })
    elseif not opDone then
        Matrix.Chaos.Report('CRITICAL', 'Cannibal: State yank sonrasi thread hang', {
            file   = 'server/main.lua',
            attack = 'Mid-op state yank',
            impact = ('Thread 3000ms icinde donmedi'):format(),
            fix    = 'MarkBotDirty sonsuz donguye mi giriyor?',
        })
    else
        print('[CHAOS][cannibal] SURVIVED: State yank absorbed')
    end
end

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 3: RECURSIVE EVENT BOMB
-- Kendini tetikleyen event → stack overflow / infinite loop
-- ═════════════════════════════════════════════════════════════════════
local function _attack_recursive_event()
    print('[CHAOS][cannibal] Attack 3: Recursive Event Bomb')

    -- ═══════════════════════════════════════════════════════════════
    -- KISIM A: Direkt stack recursion (500 seviye)
    -- Sunucu stack'inin ne kadar derinlik kaldırdığını test eder.
    -- ═══════════════════════════════════════════════════════════════
    local STACK_DEPTH = 500
    local stackReached = 0

    local function _recurse(n)
        stackReached = stackReached + 1
        if n <= 1 then return end
        _recurse(n - 1)
    end

    local stackOk, stackErr = pcall(_recurse, STACK_DEPTH)

    if not stackOk then
        Matrix.Chaos.Report('HIGH', 'Cannibal: Stack recursion crash', {
            file   = 'server/matrix_chaos_cannibal.lua',
            attack = ('%dx direkt recursion'):format(STACK_DEPTH),
            impact = ('Stack depth=%d sonrasi pcall: %s'):format(stackReached, tostring(stackErr)),
            fix    = 'Lua stack limitini artir veya recursion guard ekle.',
        })
    else
        print(('[CHAOS][cannibal] SURVIVED: Stack recursion (depth=%d)'):format(stackReached))
    end

    -- ═══════════════════════════════════════════════════════════════
    -- KISIM B: Event self-trigger (scheduler queue testi)
    -- FiveM scheduler'ı event'i yield ile queue'lar — beklenen davranış.
    -- ═══════════════════════════════════════════════════════════════
    local EVENT_NAME = 'matrix:internal:cannibal:recursive'
    local eventFires = 0
    local MAX_EVENT_FIRES = 100
    local done = false

    AddEventHandler(EVENT_NAME, function()
        eventFires = eventFires + 1
        if eventFires >= MAX_EVENT_FIRES then
            done = true
            return
        end
        -- ★ Wait YOK — scheduler kendi korumasını uygular
        TriggerEvent(EVENT_NAME)
    end)

    local startMs = GetGameTimer()
    local triggerOk, triggerErr = pcall(function()
        TriggerEvent(EVENT_NAME)
    end)
    local elapsed = GetGameTimer() - startMs

    -- Scheduler queue'yu işlesin (max 2 saniye)
    local waitMs = 0
    while not done and waitMs < 2000 do
        Wait(50)
        waitMs = waitMs + 50
    end

    if not triggerOk then
        Matrix.Chaos.Report('HIGH', 'Cannibal: Event self-trigger crash', {
            file   = 'server/matrix_chaos_cannibal.lua',
            attack = 'TriggerEvent kendini tekrar tetikliyor',
            impact = ('pcall: %s'):format(tostring(triggerErr)),
            fix    = 'Event handler sonsuz recursion guard ekle.',
        })
    else
        print(('[CHAOS][cannibal] SURVIVED: Event self-trigger (fires=%d, %dms)'):format(
            eventFires, elapsed))
    end
end
-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 4: CIRCULAR REFERENCE
-- Kendine referans veren tablo — serialize edilirse sonsuz döngü
-- ═════════════════════════════════════════════════════════════════════
local function _attack_circular_reference()
    print('[CHAOS][cannibal] Attack 4: Circular Reference')

    local cyc = { name = 'CANNIBAL-CIRCULAR', data = {} }
    cyc.self = cyc
    cyc.data.parent = cyc
    cyc.data.sibling = cyc.data

    -- Bot biology'ye tak, sonra persistence'a zorla
    local testBot = Matrix.CreateBotRecord({
        name = 'CANNIBAL-CIRC',
        role = 'diagnostic_test',
    })
    if not testBot or not testBot.id then return end

    Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true
    testBot.__circular = cyc

    -- MarkBotDirty + Flush → persist sırasında serialization olur mu?
    local ok, err = pcall(function()
        Matrix.MarkBotDirty(testBot.id)
        if Matrix.FlushDirtyBots then
            Matrix.FlushDirtyBots()
        end
    end)

    if not ok then
        Matrix.Chaos.Report('HIGH', 'Cannibal: Circular reference crash', {
            file   = 'server/main.lua',
            attack = 'bot.__circular = self-referencing table + FlushDirtyBots',
            impact = ('pcall: %s'):format(tostring(err)),
            fix    = 'BuildBotUpsert sadece whitelisted alanlari serialize etsin.',
        })
    else
        print('[CHAOS][cannibal] SURVIVED: Circular ref')
    end
end

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 5: FORMAT STRING INJECTION
-- Eğer kod string.format(userInput, ...) yaparsa → error
-- ═════════════════════════════════════════════════════════════════════
local function _attack_format_string()
    print('[CHAOS][cannibal] Attack 5: Format String Injection')

    -- Yaygın format string payload'ları
    local payloads = {
        '%s', '%s%s%s%s%s', '%d%n%c', '%%n%%n%%n',
        ('%s'):rep(50),
    }

    -- Her biri bir citizenid/name/string argümanı olarak geçirilebilecek yerlere saldır
    local attackPoints = {
        { fn = 'GenerateScratchedPlate', call = function(p)
            return Matrix.BlackMarket and Matrix.BlackMarket.GenerateScratchedPlate
                and Matrix.BlackMarket.GenerateScratchedPlate(p)
        end },
        { fn = 'GenerateWeaponSerial', call = function(p)
            return Matrix.BlackMarket and Matrix.BlackMarket.GenerateWeaponSerial
                and Matrix.BlackMarket.GenerateWeaponSerial(p, 'weapon_pistol')
        end },
    }

    for _, pt in ipairs(attackPoints) do
        for i, payload in ipairs(payloads) do
            local ok, err = pcall(pt.call, payload)
            if not ok then
                local errStr = tostring(err)
                if errStr:find('format') or errStr:find('invalid option') then
                    Matrix.Chaos.Report('HIGH', ('Cannibal: Format string injection @ %s'):format(pt.fn), {
                        file   = 'server/blackmarket.lua',
                        attack = ('%s("%s")'):format(pt.fn, payload:sub(1, 30)),
                        impact = ('string.format injection — pcall: %s'):format(errStr:sub(1, 80)),
                        fix    = ('%s input\'u string.format\'e geciriyor. Sadece %s olarak kullan.'):format(pt.fn, '%s'),
                    })
                end
            end
        end
    end

    print('[CHAOS][cannibal] Format string attack tamamlandi')
end

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 6: DEEP NESTING OVERFLOW
-- 50.000 seviye nested tablo → iterasyon/serialize patlaması
-- ═════════════════════════════════════════════════════════════════════
local function _attack_deep_nesting()
    print('[CHAOS][cannibal] Attack 6: Deep Nesting')

    local deep = {}
    local cur = deep
    for i = 1, 50000 do
        cur.next = {}
        cur = cur.next
    end

    -- Bot'a tak, flush et
    local testBot = Matrix.CreateBotRecord({
        name = 'CANNIBAL-DEEP',
        role = 'diagnostic_test',
    })
    if not testBot or not testBot.id then return end

    Matrix.Chaos.Fixture.ActiveBots[testBot.id] = true
    testBot.__deep = deep

    local ok, err = pcall(function()
        Matrix.MarkBotDirty(testBot.id)
        if Matrix.FlushDirtyBots then Matrix.FlushDirtyBots() end
    end)

    if not ok then
        Matrix.Chaos.Report('MEDIUM', 'Cannibal: Deep nesting serialization crash', {
            file   = 'server/main.lua',
            attack = '50k-level nested table → FlushDirtyBots',
            impact = ('pcall: %s'):format(tostring(err)),
            fix    = 'Recursive serialize derinlik limiti ekle.',
        })
    else
        print('[CHAOS][cannibal] SURVIVED: Deep nesting')
    end
end

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 7: PLATE COLLISION RACE
-- İki thread aynı plakayı aynı anda register etsin → dupe?
-- ═════════════════════════════════════════════════════════════════════
local function _attack_plate_collision()
    print('[CHAOS][cannibal] Attack 7: Fleet Plate Collision Race')

    if not Matrix.Fleet or not Matrix.Fleet.RegisterVehicle then
        print('[CHAOS][cannibal] SKIP: Fleet API yok')
        return
    end

    local plate = 'CANNIBAL01'
    local results = { count = 0 }
    local success = 0
    local PARALLEL = 20

    for i = 1, PARALLEL do
        CreateThread(function()
            local ok, res = pcall(Matrix.Fleet.RegisterVehicle,
                'CANNIBAL-OWNER', plate, 'car', 'scratched', 0.5)
            if ok and res then success = success + 1 end
            results.count = results.count + 1
        end)
    end

    local waited = 0
    while results.count < PARALLEL and waited < 5000 do
        Wait(50); waited = waited + 50
    end

    if success ~= 1 then
        Matrix.Chaos.Report('HIGH', 'Cannibal: Fleet plate collision', {
            file   = 'server/logistics.lua',
            attack = ('%dx paralel RegisterVehicle("%s")'):format(PARALLEL, plate),
            impact = ('%d basarili (beklenen 1) -- DUPE'):format(success),
            fix    = 'RegisterVehicle plaka unique constraint ekle.',
            evidence = ('successes=%d'):format(success),
        })
    else
        print(('[CHAOS][cannibal] SURVIVED: Plate collision (1/%d)'):format(PARALLEL))
    end

    pcall(Matrix.Fleet.SeizeVehicle, plate, 'cannibal_cleanup', 'CANNIBAL', nil)
end

-- ═════════════════════════════════════════════════════════════════════
-- SALDIRI 8: REENTRANCY
-- Handler içinden aynı event'i tetikle — reentrancy guard var mı?
-- ═════════════════════════════════════════════════════════════════════
local function _attack_reentrancy()
    print('[CHAOS][cannibal] Attack 8: Reentrancy')

    -- ═══════════════════════════════════════════════════════════════
    -- Test: Handler içinden aynı event tekrar tetiklenebilir mi?
    -- Scheduler yield ile koruma sağlar — derin nested çağrı beklenmiyor.
    -- ═══════════════════════════════════════════════════════════════
    local EVENT = 'matrix:internal:cannibal:reenter'
    local depth, maxDepth = 0, 0
    local errors = 0
    local TOTAL_DEPTH = 50

    AddEventHandler(EVENT, function()
        depth = depth + 1
        if depth > maxDepth then maxDepth = depth end

        if depth < TOTAL_DEPTH then
            local ok = pcall(function() TriggerEvent(EVENT) end)
            if not ok then errors = errors + 1 end
        end
        depth = depth - 1
    end)

    local ok, err = pcall(function() TriggerEvent(EVENT) end)

    -- Scheduler queue'yu işlesin
    Wait(300)

    if not ok then
        Matrix.Chaos.Report('HIGH', 'Cannibal: Reentrancy crash', {
            file   = 'server/matrix_chaos_cannibal.lua',
            attack = ('Event kendi handler\'indan %dx tetiklendi'):format(TOTAL_DEPTH),
            impact = ('pcall: %s'):format(tostring(err)),
            fix    = 'Reentrancy guard ekle.',
        })
    elseif maxDepth <= 2 then
        -- Scheduler event'i yield ile queue'ladı — beklenen davranış
        print(('[CHAOS][cannibal] DEFENDED: Reentrancy scheduler (depth=%d/%d)'):format(
            maxDepth, TOTAL_DEPTH))
    else
        print(('[CHAOS][cannibal] SURVIVED: Reentrancy (max depth=%d)'):format(maxDepth))
    end
end
-- ═════════════════════════════════════════════════════════════════════
-- MODULE KAYIT
-- ═════════════════════════════════════════════════════════════════════
Matrix.Chaos.RegisterModule('cannibal', 'CANNIBAL — yikim testi (8 vektor)', function()
    local A = Matrix.Chaos.Assert
    A.SetContext('cannibal', 'server/matrix_chaos_cannibal.lua')

    print('')
    print('[CHAOS][cannibal] ╔════════════════════════════════════════╗')
    print('[CHAOS][cannibal] ║  YIKIM TESTI BASLIYOR — 8 VEKTOR     ║')
    print('[CHAOS][cannibal] ╚════════════════════════════════════════╝')

    _attack_metatable_trap()
    _attack_shared_state_yank()
    _attack_recursive_event()
    _attack_circular_reference()
    _attack_format_string()
    _attack_deep_nesting()
    _attack_plate_collision()
    _attack_reentrancy()

    Matrix.Chaos.Report('INFO', 'Cannibal tamamlandi', {
        attack = '8 yikim vektoru calistirildi',
        impact = 'Detaylar yukarida',
    })
end)

print('[CHAOS][cannibal] Yamyam v1.0 (YIKIM MODU) hazir.')