-- =====================================================================
-- ★★★ MATRIX CHAOS ENGINE — HARDCORE — CLIENT BRIDGE FUZZER ★★★
-- server/matrix_chaos_hardcore_bridge.lua
--
-- Modül: chaos_client_bridge_fuzzer [HARDCORE]
-- KAPSAM: client'tan server'a gelen 7 net event'i (client tarafından
-- TriggerServerEvent ile tetiklenen, server'da RegisterNetEvent ile
-- kayıtlı köprüler) 12 bozuk payload ile fuzzlar. registerFleetVehicle/
-- unassignFleetVehicle KASITLI OLARAK LISTEDE YOK -- zaten network_guard
-- şemalarında kapsanıyor, tekrar test etmek duplicate olur.
--
-- ★ ÖN ADIM (ZORUNLU): her event, TriggerEvent ile çağrılmadan ÖNCE
-- LoadResourceFile + string.find ile kaynakta gerçekten RegisterNetEvent
-- ile kayıtlı olduğu doğrulanır. Bulunamayan event fuzz listesinden
-- çıkarılır ve MEDIUM olarak raporlanır (rule 5: var olmayan API'yi
-- çağırma).
--
-- ★ Config.Chaos.HardcoreEnabled = false ise bu dosya HİÇBİR ŞEY
-- register ETMEZ.
-- =====================================================================

if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

Matrix = Matrix or {}
Matrix.Chaos = Matrix.Chaos or {}

local HARDCORE_TAG = '[HARDCORE]'

local function _ReadFile(relPath)
    local ok, src = pcall(LoadResourceFile, GetCurrentResourceName(), relPath)
    if ok and type(src) == 'string' then return src end
    return nil
end

-- ★ 7 HEDEF EVENT — grep ile dogrulanmis, kaynak dosyasi ile birlikte.
local TARGET_EVENTS = {
    { name = 'matrix:server:trapHouseInterior:enter',            file = 'server/trap_house_interior.lua' },
    { name = 'matrix:server:trapHouseInterior:exit',              file = 'server/trap_house_interior.lua' },
    { name = 'matrix:server:trapHouseInterior:giveItemToBot',     file = 'server/trap_house_interior.lua' },
    { name = 'matrix:server:trapHouseInterior:transferBotToBot',  file = 'server/trap_house_interior.lua' },
    { name = 'matrix:server:reportRaidOutcome',                   file = 'server/bureau.lua' },
    { name = 'matrix:server:requestVettingDossier',               file = 'server/main.lua' },
    { name = 'matrix:server:coercionCompleted',                   file = 'server/recruitment.lua' },
}

Matrix.Chaos.RegisterModule('chaos_client_bridge_fuzzer',
    HARDCORE_TAG .. ' Client Bridge Fuzzer — 7 net event x 12 bozuk payload',
    function()
        -- ★ İKİNCİ SAVUNMA HATTI: fail-closed.
        if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_client_bridge_fuzzer', 'server/matrix_chaos_hardcore_bridge.lua')

        -- ═══════════════════════════════════════════════════════════
        -- ÖN ADIM: her event kaynakta gercekten kayitli mi?
        -- ═══════════════════════════════════════════════════════════
        local verifiedEvents = {}
        for _, ev in ipairs(TARGET_EVENTS) do
            local src = _ReadFile(ev.file)
            local pattern = ("RegisterNetEvent('%s'"):format(ev.name)
            if src and src:find(pattern, 1, true) then
                verifiedEvents[#verifiedEvents + 1] = ev
            else
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' event bulunamadi: ' .. ev.name, {
                    file   = ev.file,
                    impact = 'Fuzz listesinden cikarildi -- kaynakta RegisterNetEvent ile kayitli degil.',
                })
            end
        end

        if #verifiedEvents == 0 then
            Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' client_bridge_fuzzer: dogrulanmis event yok, test atlandi', {})
            return
        end

        -- ═══════════════════════════════════════════════════════════
        -- 12 BOZUK PAYLOAD
        -- ═══════════════════════════════════════════════════════════
        local big10kb = string.rep('A', 10 * 1024)
        local nested  = { a = { b = { c = { d = 1 } } } }
        local funcRef = function() return nil end

        local PAYLOADS = {
            { label = 'nil',                value = nil },
            { label = 'bos-tablo',          value = {} },
            { label = 'src=0',              value = { src = 0 } },
            { label = 'src=-1',             value = { src = -1 } },
            { label = "src='string'",       value = { src = 'string' } },
            { label = 'src=999999999',      value = { src = 999999999 } },
            { label = '10KB-string',        value = big10kb },
            { label = 'ic-ice-tablo',       value = nested },
            { label = 'fonksiyon-referansi',value = funcRef },
            { label = 'yanlis-tip(bool)',   value = true },
            { label = 'eksik-zorunlu-alan', value = { count = 5 } },
            { label = 'sql-meta-karakter',  value = "'; DROP TABLE matrix_bots; --" },
        }

        -- ═══════════════════════════════════════════════════════════
        -- HER PAYLOAD x HER EVENT — pcall icinde TriggerEvent.
        -- ═══════════════════════════════════════════════════════════
        local totalCalls  = 0
        local crashCount  = 0

        for _, ev in ipairs(verifiedEvents) do
            for _, p in ipairs(PAYLOADS) do
                totalCalls = totalCalls + 1
                local ok, err = pcall(TriggerEvent, ev.name, p.value)
                if not ok then
                    crashCount = crashCount + 1
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' FUZZ-REJECT eksik: ' .. ev.name, {
                        file   = ev.file,
                        attack = ('TriggerEvent(%s, <%s>)'):format(ev.name, p.label),
                        impact = tostring(err),
                        fix    = 'Handler basinda tip/nil guard ekle (pcall veya acik kontrol).',
                    })
                end
            end
        end

        Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' client_bridge_fuzzer ozet', {
            evidence = ('%d event x %d payload = %d cagri, %d crash'):format(
                #verifiedEvents, #PAYLOADS, totalCalls, crashCount),
        })
    end)

Matrix.Chaos.Modules['chaos_client_bridge_fuzzer'].fixture_opts = { traps = 1, bots = 1, dispatches = 0, fleet = 0 }
