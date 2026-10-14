-- =====================================================================
-- ★★★ MATRIX CHAOS ENGINE — HARDCORE — WORLD STATE FUZZER ★★★
-- server/matrix_chaos_hardcore_world.lua
--
-- Modül: chaos_world_state_fuzzer [HARDCORE]
-- KAPSAM: playtest hotfix'lerinin (blip stabilizasyon, broker ground
-- placement) REGRESYONA UĞRAMADIĞINI statik kaynak taramasıyla + fiziksel
-- dispatch pipeline'ının garbage koordinat karşısında fail-closed
-- davrandığını runtime fixture ile doğrular. World-config (cell tower,
-- gang hood, phantom doctor, vendor pool) koordinat/alan sağlamlığını
-- denetler.
--
-- ★ Config.Chaos.HardcoreEnabled = false ise bu dosya HİÇBİR ŞEY
-- register ETMEZ (dosya seviyesinde erken çıkış). Modül fonksiyonu
-- içinde AYRICA aynı guard tekrar edilir (ikinci savunma hattı).
-- =====================================================================

if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

Matrix = Matrix or {}
Matrix.Chaos = Matrix.Chaos or {}

local HARDCORE_TAG = '[HARDCORE]'

-- ---------------------------------------------------------------------
-- YARDIMCI: dosya kaynağını oku (LoadResourceFile), bulunamazsa nil.
-- ---------------------------------------------------------------------
local function _ReadFile(relPath)
    local ok, src = pcall(LoadResourceFile, GetCurrentResourceName(), relPath)
    if ok and type(src) == 'string' then return src end
    return nil
end

Matrix.Chaos.RegisterModule('chaos_world_state_fuzzer',
    HARDCORE_TAG .. ' World State Fuzzer — blip/ground-placement regresyon + koordinat sanity',
    function()
        -- ★ İKİNCİ SAVUNMA HATTI: fail-closed.
        if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_world_state_fuzzer', 'server/matrix_chaos_hardcore_world.lua')

        -- ═══════════════════════════════════════════════════════════
        -- A1: client/trap_house_client.lua — blip fix regresyonu
        -- ═══════════════════════════════════════════════════════════
        do
            local src = _ReadFile('client/trap_house_client.lua')
            if not src then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A1: client/trap_house_client.lua okunamadi', {
                    file   = 'client/trap_house_client.lua',
                    impact = 'Blip regresyon taramasi yapilamadi.',
                })
            else
                local hasShortRangeFalse = src:find('SetBlipAsShortRange(blip, false)', 1, true) ~= nil
                local hasBlipDisplay4    = src:find('SetBlipDisplay(blip, 4)', 1, true) ~= nil

                if not hasShortRangeFalse or not hasBlipDisplay4 then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A1 REGRESYON: trap house blip kalicilik fix kayip', {
                        file   = 'client/trap_house_client.lua',
                        attack = 'Statik kaynak taramasi (string.find)',
                        impact = ('SetBlipAsShortRange(blip, false): %s | SetBlipDisplay(blip, 4): %s'):format(
                            hasShortRangeFalse and 'VAR' or 'YOK',
                            hasBlipDisplay4 and 'VAR' or 'YOK'),
                        fix    = 'Fix 2 (blip stabilizasyon) yeniden uygulanmali.',
                    })
                else
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A1 temiz: blip kalicilik fix mevcut', {})
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- A2: client/matrix_session1_client.lua — ground placement regresyonu
        -- ═══════════════════════════════════════════════════════════
        do
            local src = _ReadFile('client/matrix_session1_client.lua')
            if not src then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A2: client/matrix_session1_client.lua okunamadi', {
                    file   = 'client/matrix_session1_client.lua',
                    impact = 'Broker/Counselor ground-placement regresyon taramasi yapilamadi.',
                })
            else
                local required = {
                    'GetGroundZFor_3dCoord',
                    'HasCollisionLoadedAroundEntity',
                    'PlaceObjectOnGroundProperly',
                    'SetEntityCoords',
                }
                local missing = {}
                for _, sig in ipairs(required) do
                    if not src:find(sig, 1, true) then
                        missing[#missing + 1] = sig
                    end
                end

                if #missing > 0 then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A2 REGRESYON: broker/counselor ground-placement fix kayip', {
                        file   = 'client/matrix_session1_client.lua',
                        attack = 'Statik kaynak taramasi (string.find)',
                        impact = ('Eksik imzalar: %s'):format(table.concat(missing, ', ')),
                        fix    = 'Fix 3 (ground placement) yeniden uygulanmali.',
                    })
                else
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A2 temiz: ground-placement fix mevcut', {})
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- A3: BeginPhysicalDispatch — absurd Z ile fail-closed testi
        --
        -- NOT: gorev tanimi "bot.state.last_coords" alanini test etmeyi
        -- istiyordu, ancak grep ile dogrulandi -- bot.state hicbir zaman
        -- last_coords alani TASIMAZ (server/main.lua:298-308,
        -- Matrix.CreateBotRecord). last_coords SADECE Matrix.Dispatches
        -- [botId] uzerinde var (aktif dispatch entry'si), bot.state'te
        -- degil, ve BeginPhysicalDispatch bu alani hic OKUMAZ. Bu yuzden
        -- absurd Z, fonksiyonun GERCEKTEN dogruladigi parametre olan
        -- origin/destination'a dogrudan verilir (_SafeVec kontrolu
        -- burayi kapsiyor).
        -- ═══════════════════════════════════════════════════════════
        do
            if not Matrix.BeginPhysicalDispatch then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A3: Matrix.BeginPhysicalDispatch tanimli degil', {
                    file = 'server/main.lua',
                })
            else
                local botId
                for id in pairs(Matrix.Chaos.Fixture.ActiveBots) do botId = id; break end

                if not botId then
                    Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A3: fixture bot yok, test atlandi', {})
                else
                    local bot = Matrix.Bots[botId]
                    local absurdOrigin = vector3(0.0, 0.0, 9999.0)
                    local dest         = vector3(0.0, 0.0, 9999.0)

                    local callOk, dispatchOk, reason = pcall(
                        Matrix.BeginPhysicalDispatch,
                        botId, absurdOrigin, dest, nil, 'foot', 0.0, nil, 1.0)

                    if not callOk then
                        Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A3 CRASH: BeginPhysicalDispatch absurd Z ile hata firlatti', {
                            file   = 'server/main.lua',
                            attack = 'origin/destination = vector3(0,0,9999)',
                            impact = tostring(dispatchOk),
                            fix    = 'BeginPhysicalDispatch icinde pcall/guard eksik.',
                        })
                    elseif type(dispatchOk) ~= 'boolean' then
                        -- ★ KIRMIZI ÇİZGİ: nil -> true yorumlanabilir belirsizlik YASAK
                        Matrix.Chaos.Report('CRITICAL', HARDCORE_TAG .. ' A3 FAIL-OPEN: BeginPhysicalDispatch bool olmayan durum dondurdu', {
                            file   = 'server/main.lua',
                            attack = 'origin/destination = vector3(0,0,9999)',
                            impact = ('donen deger tipi: %s (nil ise cagiran taraf yanlislikla basarili sanabilir)'):format(type(dispatchOk)),
                            fix    = 'Her kod yolunda acikca true/false dondur.',
                        })
                    elseif dispatchOk == true then
                        -- ★ DUZELTME: absurd Z (harita disi koordinat) ile
                        -- spawn KABUL EDILMEMELI -- bu REGRESYONDUR, "temiz"
                        -- degil. bot.state (net_id/spawned) evidence olarak
                        -- rapora eklenir.
                        Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A3 REGRESYON: harita disi koordinat kabul edildi', {
                            file   = 'server/main.lua',
                            attack = 'origin/destination = vector3(0,0,9999)',
                            impact = 'BeginPhysicalDispatch, harita disi (Z=9999) koordinati reddetmeden spawn etti.',
                            fix    = 'origin/destination icin makul Z bounds kontrolu ekle (fail-closed).',
                            evidence = ('spawned=%s net_id=%s'):format(
                                tostring(bot and bot.state and bot.state.spawned),
                                tostring(bot and bot.state and bot.state.net_id)),
                        })
                        -- Temizlik: bu test-dispatch fixture teardown'dan bagimsiz,
                        -- modul sonunda kalinti kalmasin. Matrix.RemoveBot DEGIL --
                        -- o fixture bot kaydini TAMAMEN siler (Teardown zaten
                        -- yapacak); burada sadece spawn edilen ped'i geri cekmek
                        -- yeterli ve dogru olan (Matrix.DespawnBot, main.lua:701).
                        pcall(Matrix.DespawnBot, botId)
                        Matrix.Dispatches[botId] = nil
                    else
                        -- false -- fail-closed, beklenen/kabul edilen sonuc.
                        Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A3 temiz: absurd Z fail-closed reddedildi', {
                            evidence = ('reason=%s'):format(tostring(reason)),
                        })
                        -- ★ DUZELTME 3: her iki yolda da partial-state
                        -- leak olmasin -- false yolunda normalde zaten nil
                        -- olmali (BeginPhysicalDispatch bu noktaya kadar
                        -- Matrix.Dispatches'a hic yazmaz), ama garanti icin.
                        Matrix.Dispatches[botId] = nil
                    end
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- Ortak Z/NaN sanity yardımcı (A4/A5 için)
        -- ═══════════════════════════════════════════════════════════
        local function _IsBadZ(z, minZ, maxZ)
            if type(z) ~= 'number' then return true end
            if z ~= z then return true end -- NaN
            if z < minZ or z > maxZ then return true end
            return false
        end

        -- ═══════════════════════════════════════════════════════════
        -- A4: Config.Bureau.CellTowers koordinat sanity
        -- ═══════════════════════════════════════════════════════════
        do
            local towers = Config.Bureau and Config.Bureau.CellTowers
            if type(towers) ~= 'table' then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A4: Config.Bureau.CellTowers tanimli degil', {})
            else
                local failCount = 0
                for _, t in ipairs(towers) do
                    if type(t.coords) ~= 'vector3' or _IsBadZ(t.coords.z, -200, 1200) then
                        failCount = failCount + 1
                        Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A4 FAIL: cell tower Z bounds ihlali', {
                            file   = 'shared/config.lua',
                            attack = 'Config.Bureau.CellTowers statik sanity',
                            impact = ('tower id=%s coords=%s'):format(tostring(t.id), tostring(t.coords)),
                            fix    = 'Koordinati -200..1200 Z araligina cek.',
                        })
                    end
                end
                if failCount == 0 then
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A4 temiz: tum cell tower Z degerleri makul', {})
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- A5: Config.GangHoods.Hoods koordinat sanity
        -- ═══════════════════════════════════════════════════════════
        do
            local hoods = Config.GangHoods and Config.GangHoods.Hoods
            if type(hoods) ~= 'table' then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A5: Config.GangHoods.Hoods tanimli degil', {})
            else
                local failCount = 0
                for _, h in ipairs(hoods) do
                    if type(h.coords) ~= 'vector3' or _IsBadZ(h.coords.z, -200, 1200) then
                        failCount = failCount + 1
                        Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A5 FAIL: gang hood Z bounds ihlali', {
                            file   = 'shared/config.lua',
                            attack = 'Config.GangHoods.Hoods statik sanity',
                            impact = ('hood id=%s label=%s coords=%s'):format(
                                tostring(h.id), tostring(h.label), tostring(h.coords)),
                            fix    = 'Koordinati -200..1200 Z araligina cek.',
                        })
                    end
                end
                if failCount == 0 then
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A5 temiz: tum gang hood Z degerleri makul', {})
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- A6: Config.PhantomDoctor.Coords (dogrudan vector3 dizisi)
        -- ═══════════════════════════════════════════════════════════
        do
            local coordsList = Config.PhantomDoctor and Config.PhantomDoctor.Coords
            if type(coordsList) ~= 'table' then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A6: Config.PhantomDoctor.Coords tanimli degil', {})
            else
                local failCount = 0
                for idx, c in ipairs(coordsList) do
                    if type(c) ~= 'vector3' or _IsBadZ(c.z, -200, 1200) then
                        failCount = failCount + 1
                        Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' A6 FAIL: Phantom Doctor koordinat Z bounds ihlali', {
                            file   = 'shared/config.lua',
                            attack = 'Config.PhantomDoctor.Coords statik sanity',
                            impact = ('index=%d coords=%s'):format(idx, tostring(c)),
                            fix    = 'Koordinati -200..1200 Z araligina cek.',
                        })
                    end
                end
                if failCount == 0 then
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A6 temiz: tum Phantom Doctor koordinatlari makul', {})
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- A7: Config.VendorPool sanity (SpawnCount>0, PedModel string)
        -- ═══════════════════════════════════════════════════════════
        do
            local vp = Config.VendorPool
            if type(vp) ~= 'table' then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A7: Config.VendorPool tanimli degil', {})
            else
                local problems = {}
                if type(vp.SpawnCount) ~= 'number' or vp.SpawnCount <= 0 then
                    problems[#problems + 1] = ('SpawnCount gecersiz: %s'):format(tostring(vp.SpawnCount))
                end
                if type(vp.PedModel) ~= 'string' or vp.PedModel == '' then
                    problems[#problems + 1] = ('PedModel gecersiz: %s'):format(tostring(vp.PedModel))
                end

                if #problems > 0 then
                    Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' A7 FAIL: VendorPool config sanity ihlali', {
                        file   = 'shared/config.lua',
                        attack = 'Config.VendorPool statik sanity',
                        impact = table.concat(problems, ' | '),
                        fix    = 'Config.VendorPool.SpawnCount/PedModel degerlerini duzelt.',
                    })
                else
                    Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' A7 temiz: VendorPool config sanity gecerli', {})
                end
            end
        end
    end)

Matrix.Chaos.Modules['chaos_world_state_fuzzer'].fixture_opts = { traps = 1, bots = 2, dispatches = 0, fleet = 0 }
