-- =====================================================================
-- ★★★ MATRIX CHAOS ENGINE — HARDCORE — AUTHORITY BYPASS TESTER ★★★
-- server/matrix_chaos_hardcore_auth.lua
--
-- Modül: chaos_authority_bypass_tester [HARDCORE]
-- KAPSAM: MERKEZİ yetki API'si — Matrix.Hierarchy.GetRank (server/
-- market.lua:98) ve Matrix.Hierarchy.HasCommandAuthority (server/
-- market.lua:104) — 9 bozuk citizenid ile fuzzlanır. Yerel {src}
-- sarmalayıcıları (her dosyanın kendi yetki kontrol fonksiyonları)
-- HEDEF DEĞİL — sadece bu iki merkezi API.
--
-- ★ KIRMIZI ÇİZGİ: HasCommandAuthority hiçbir bozuk girdi için true
-- dönemez. Dönerse CRITICAL "AUTH-BYPASS".
--
-- ★ Config.Chaos.HardcoreEnabled = false ise bu dosya HİÇBİR ŞEY
-- register ETMEZ.
-- =====================================================================

if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

Matrix = Matrix or {}
Matrix.Chaos = Matrix.Chaos or {}

local HARDCORE_TAG = '[HARDCORE]'

Matrix.Chaos.RegisterModule('chaos_authority_bypass_tester',
    HARDCORE_TAG .. ' Authority Bypass Tester — Matrix.Hierarchy.GetRank/HasCommandAuthority fuzzing',
    function()
        -- ★ İKİNCİ SAVUNMA HATTI: fail-closed.
        if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_authority_bypass_tester', 'server/matrix_chaos_hardcore_auth.lua')

        if not (Matrix.Hierarchy and Matrix.Hierarchy.GetRank and Matrix.Hierarchy.HasCommandAuthority) then
            Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' authority_bypass_tester: Matrix.Hierarchy API eksik, test atlandi', {
                file = 'server/market.lua',
            })
            return
        end

        -- ═══════════════════════════════════════════════════════════
        -- 9 SENARYO (bozuk citizenid degerleri)
        -- ═══════════════════════════════════════════════════════════
        local SCENARIOS = {
            { label = 'nil',              value = nil },
            { label = 'bos-string',       value = '' },
            { label = "'fake-citizen'",   value = 'fake-citizen' },
            { label = '0',                value = 0 },
            { label = '-1',               value = -1 },
            { label = '1e15',             value = 1e15 },
            { label = 'bos-tablo',        value = {} },
            { label = 'fonksiyon-referansi', value = function() return nil end },
            { label = "sql-meta ('admin'; DROP TABLE --)", value = "admin'; DROP TABLE matrix_hierarchy; --" },
        }

        local bypassCount = 0
        local typeFailCount = 0

        for _, sc in ipairs(SCENARIOS) do
            -- --- Matrix.Hierarchy.GetRank ---
            local getOk, rankResult = pcall(Matrix.Hierarchy.GetRank, sc.value)
            if not getOk then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' GetRank CRASH: ' .. sc.label, {
                    file   = 'server/market.lua',
                    attack = ('Matrix.Hierarchy.GetRank(%s)'):format(sc.label),
                    impact = tostring(rankResult),
                    fix    = 'GetRank icinde tip guard eksik.',
                })
                typeFailCount = typeFailCount + 1
            elseif rankResult ~= nil then
                -- Bozuk girdi icin GECERLI bir rank ismi donmesi de bir
                -- sizinti isareti (fail-closed degil).
                Matrix.Chaos.Report('CRITICAL', HARDCORE_TAG .. ' GetRank AUTH-BYPASS: bozuk citizenid gecerli rank dondurdu', {
                    file   = 'server/market.lua',
                    attack = ('Matrix.Hierarchy.GetRank(%s)'):format(sc.label),
                    impact = ('donen rank: %s'):format(tostring(rankResult)),
                    fix    = 'GetRank her bozuk/taninmayan citizenid icin acikca nil dondurmeli.',
                })
                bypassCount = bypassCount + 1
            end

            -- --- Matrix.Hierarchy.HasCommandAuthority ---
            local hcaOk, hcaResult = pcall(Matrix.Hierarchy.HasCommandAuthority, sc.value)
            if not hcaOk then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' HasCommandAuthority CRASH: ' .. sc.label, {
                    file   = 'server/market.lua',
                    attack = ('Matrix.Hierarchy.HasCommandAuthority(%s)'):format(sc.label),
                    impact = tostring(hcaResult),
                    fix    = 'HasCommandAuthority icinde tip guard eksik.',
                })
                typeFailCount = typeFailCount + 1
            elseif hcaResult == true then
                -- ★ KIRMIZI ÇİZGİ IHLALI
                Matrix.Chaos.Report('CRITICAL', HARDCORE_TAG .. ' HasCommandAuthority AUTH-BYPASS: bozuk citizenid ile yetki verildi', {
                    file   = 'server/market.lua',
                    attack = ('Matrix.Hierarchy.HasCommandAuthority(%s)'):format(sc.label),
                    impact = 'true dondu -- fail-closed degil, komuta yetkisi bozuk girdiyle kazanildi.',
                    fix    = 'HasCommandAuthority, GetRank nil/gecersiz donerse KESINLIKLE false dondurmeli.',
                })
                bypassCount = bypassCount + 1
            elseif type(hcaResult) ~= 'boolean' then
                -- nil/diger -- "nil->true" belirsizligine acilan kapi.
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' HasCommandAuthority tip belirsizligi: ' .. sc.label, {
                    file   = 'server/market.lua',
                    attack = ('Matrix.Hierarchy.HasCommandAuthority(%s)'):format(sc.label),
                    impact = ('donen tip: %s (cagiran taraf yanlislikla true sanabilir)'):format(type(hcaResult)),
                    fix    = 'Her kod yolunda acikca true/false (boolean) dondur.',
                })
                typeFailCount = typeFailCount + 1
            end
        end

        if bypassCount == 0 and typeFailCount == 0 then
            Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' authority_bypass_tester temiz: 9 senaryo x 2 API (18 cagri), bypass/crash yok', {})
        else
            Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' authority_bypass_tester ozet', {
                evidence = ('18 cagri, %d bypass, %d tip/crash sorunu'):format(bypassCount, typeFailCount),
            })
        end
    end)

Matrix.Chaos.Modules['chaos_authority_bypass_tester'].fixture_opts = { traps = 0, bots = 0, dispatches = 0, fleet = 0 }
