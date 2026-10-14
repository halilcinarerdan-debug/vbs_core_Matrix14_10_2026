-- =====================================================================
-- ★★★ MATRIX CHAOS ENGINE — HARDCORE — TRANSITION STORM ★★★
-- server/matrix_chaos_hardcore_transition.lua
--
-- Modül: chaos_transition_storm [HARDCORE]
-- KAPSAM: trap house interior giriş/çıkış event'lerini (ve komşu
-- disconnect-race/stash-run yollarını) SAHTE src (0/nil, chaos'un
-- kendi gerçek src'si yok) ile spam/bozuk-parametre saldırısına tabi
-- tutar. Amaç: crash YOK, sızıntı YOK -- her yol fail-closed erken
-- return ile kapanmalı.
--
-- ★ ÖNEMLİ: SetPlayerRoutingBucket gerçek bir player src gerektirir;
-- chaos'un öyle bir src'si yok. Bu yüzden testler runtime-DIŞI API
-- (MarkBotForStashRun) + EVENT (TriggerEvent) seviyesinde yürütülür,
-- gerçek bir oyuncu bucket'ını asla değiştirmez -- handler'lar zaten
-- source<=0 için erken return ettiğinden bucket'a hiç ulaşılmaz.
--
-- ★ Config.Chaos.HardcoreEnabled = false ise bu dosya HİÇBİR ŞEY
-- register ETMEZ.
-- =====================================================================

if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

Matrix = Matrix or {}
Matrix.Chaos = Matrix.Chaos or {}

local HARDCORE_TAG = '[HARDCORE]'

Matrix.Chaos.RegisterModule('chaos_transition_storm',
    HARDCORE_TAG .. ' Transition Storm — trap house giris/cikis event fuzzing (sahte src)',
    function()
        -- ★ İKİNCİ SAVUNMA HATTI: fail-closed.
        if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_transition_storm', 'server/matrix_chaos_hardcore_transition.lua')

        local trapId
        for id in pairs(Matrix.Chaos.Fixture.ActiveTrapHouses) do trapId = id; break end

        if not trapId then
            Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' transition_storm: fixture trap house yok, test atlandi', {})
            return
        end

        local maxIter = Config.Chaos.TransitionStormMaxIterations or 100

        -- ═══════════════════════════════════════════════════════════
        -- SENARYO 1: 100x enter spam (source ambient/0/nil -- erken
        -- return bekleniyor, crash YOK, bulgu YOK).
        -- ═══════════════════════════════════════════════════════════
        do
            local crashed = false
            for i = 1, maxIter do
                local ok = pcall(TriggerEvent, 'matrix:server:trapHouseInterior:enter', trapId)
                if not ok then crashed = true; break end
            end
            if crashed then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' SENARYO 1 CRASH: enter spam (100x) hata firlatti', {
                    file   = 'server/trap_house_interior.lua',
                    attack = ('TriggerEvent enter(%s) x%d'):format(tostring(trapId), maxIter),
                    impact = 'Handler crash -- kaynak taskeninde beklenmeyen kesinti.',
                    fix    = 'source guard (type(src)~=\'number\' or src<=0) eksik/hatali olabilir.',
                })
            else
                Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' SENARYO 1 temiz: enter spam crash yok', {
                    evidence = ('%d tekrar'):format(maxIter),
                })
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- SENARYO 2: bozuk trap_id (nil, string, -1, 1e15) -- fail-closed,
        -- crash YOK.
        -- ═══════════════════════════════════════════════════════════
        do
            local crashed = {}
            for _, bad in ipairs({ 'string', -1, 1e15 }) do
                local ok = pcall(TriggerEvent, 'matrix:server:trapHouseInterior:enter', bad)
                if not ok then crashed[#crashed + 1] = tostring(bad) end
            end
            -- nil ayrı çağrılır (ipairs nil'i atlar)
            local okNil = pcall(TriggerEvent, 'matrix:server:trapHouseInterior:enter', nil)
            if not okNil then crashed[#crashed + 1] = 'nil' end

            if #crashed > 0 then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' SENARYO 2 CRASH: bozuk trap_id ile hata firladi', {
                    file   = 'server/trap_house_interior.lua',
                    attack = 'TriggerEvent enter(nil/\'string\'/-1/1e15)',
                    impact = ('Crash veren degerler: %s'):format(table.concat(crashed, ', ')),
                    fix    = 'tonumber(trapHouseId) sonrasi Matrix.TrapHouses[trapHouseId] guard eksik olabilir.',
                })
            else
                Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' SENARYO 2 temiz: bozuk trap_id fail-closed, crash yok', {})
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- SENARYO 3: 100x exit spam -- PlayerInteriorState[src] nil
        -- oldugu icin erken return bekleniyor.
        -- ═══════════════════════════════════════════════════════════
        do
            local crashed = false
            for i = 1, maxIter do
                local ok = pcall(TriggerEvent, 'matrix:server:trapHouseInterior:exit')
                if not ok then crashed = true; break end
            end
            if crashed then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' SENARYO 3 CRASH: exit spam (100x) hata firlatti', {
                    file   = 'server/trap_house_interior.lua',
                    attack = ('TriggerEvent exit() x%d'):format(maxIter),
                    impact = 'Handler crash.',
                    fix    = 'PlayerInteriorState[src] nil guard eksik/hatali olabilir.',
                })
            else
                Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' SENARYO 3 temiz: exit spam crash yok', {
                    evidence = ('%d tekrar'):format(maxIter),
                })
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- SENARYO 4 KALDIRILDI (v6.6.6 hotfix): 'playerDropped' GLOBAL
        -- bir FXServer event'i -- bu resource disindaki 3. parti
        -- resource'larin (pma-voice, xt-prison, monitor vb.) handler'larini
        -- da tetikliyordu; onlar gercek bir player disconnect'i bekleyip
        -- source yerine sahte bir string alinca kendi ic format()
        -- cagrilarinda crash ediyordu. Sahte playerDropped tetiklemek
        -- kendi kod tabanimizin disina tasan, guvenli olmayan bir yan
        -- etki -- bu yuzden tamamen kaldirildi. Diger senaryolar (1,2,3,
        -- 5,6) SADECE kendi matrix:server:trapHouseInterior:* event'lerimizi
        -- cagirdigindan guvenli ve DEGISTIRILMEDI.
        -- ═══════════════════════════════════════════════════════════

        -- ═══════════════════════════════════════════════════════════
        -- SENARYO 5: ayni trap'e iki kez ust uste enter (source=0/nil,
        -- her ikisi de fail-closed erken return etmeli).
        -- ═══════════════════════════════════════════════════════════
        do
            local ok1 = pcall(TriggerEvent, 'matrix:server:trapHouseInterior:enter', trapId)
            local ok2 = pcall(TriggerEvent, 'matrix:server:trapHouseInterior:enter', trapId)

            if not ok1 or not ok2 then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' SENARYO 5 CRASH: double-enter ayni trap ile hata firladi', {
                    file   = 'server/trap_house_interior.lua',
                    attack = 'TriggerEvent enter(trapId) x2 ust uste',
                    impact = ('1. cagri ok=%s, 2. cagri ok=%s'):format(tostring(ok1), tostring(ok2)),
                    fix    = 'Idempotent olmayan state yazimi olabilir.',
                })
            else
                Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' SENARYO 5 temiz: double-enter crash yok', {})
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- SENARYO 6: MarkBotForStashRun bozuk parametrelerle --
        -- return false bekleniyor, crash YOK.
        -- ═══════════════════════════════════════════════════════════
        do
            if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.MarkBotForStashRun) then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' SENARYO 6: Matrix.TrapHouseInterior.MarkBotForStashRun tanimli degil', {
                    file = 'server/trap_house_interior.lua',
                })
            else
                local cases = {
                    { nil,    trapId },
                    { 12345,  nil },
                    { 'x',    'y' },
                }
                local failures = {}

                for _, args in ipairs(cases) do
                    local callOk, result = pcall(Matrix.TrapHouseInterior.MarkBotForStashRun, args[1], args[2])
                    if not callOk then
                        failures[#failures + 1] = ('CRASH(%s,%s): %s'):format(
                            tostring(args[1]), tostring(args[2]), tostring(result))
                    elseif result ~= false then
                        -- ★ KIRMIZI ÇİZGİ: nil/true YASAK, acikca false bekleniyor.
                        failures[#failures + 1] = ('FAIL-OPEN(%s,%s): donen=%s'):format(
                            tostring(args[1]), tostring(args[2]), tostring(result))
                    end
                end

                if #failures > 0 then
                    Matrix.Chaos.Report('CRITICAL', HARDCORE_TAG .. ' SENARYO 6 FAIL: MarkBotForStashRun bozuk parametrede guvensiz', {
                        file   = 'server/trap_house_interior.lua',
                        attack = 'MarkBotForStashRun(nil,trapId) / (botId,nil) / (\'x\',\'y\')',
                        impact = table.concat(failures, ' | '),
                        fix    = 'tonumber() sonrasi acikca return false ekle, nil donme.',
                    })
                else
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' SENARYO 6 temiz: MarkBotForStashRun bozuk parametrede fail-closed', {})
                end
            end
        end
    end)

Matrix.Chaos.Modules['chaos_transition_storm'].fixture_opts = { traps = 3, bots = 0, dispatches = 0, fleet = 0 }
