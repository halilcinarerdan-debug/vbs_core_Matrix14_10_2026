-- =====================================================================
-- ★★★ MATRIX CHAOS ENGINE — HARDCORE — UI PERSISTENCE AUDIT ★★★
-- server/matrix_chaos_hardcore_ui.lua
--
-- Modül: chaos_ui_persistence_audit [HARDCORE]
-- KAPSAM: KOR NOKTA 1.4 (server/matrix_diagnostics.lua) ile AYNI 4
-- statik grep denetimini chaos tarafında da tekrarlar (belt and
-- suspenders — diagnostics FastChecks senkron/hafif kalmalı, chaos
-- tarafı ayrıntılı Report() ile ayrı ayrı raporlayabilir). Ayrıca
-- Config.Chaos.UIPersistence*/ClientBridgeFuzzEventCount sanity
-- kontrollerini yapar. Gerçek blip runtime'ı server-side manipüle
-- edilemez -- yalnızca client-side kaynak taraması + config sanity.
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

Matrix.Chaos.RegisterModule('chaos_ui_persistence_audit',
    HARDCORE_TAG .. ' UI Persistence Audit — blip kalicilik/ownership statik denetim + config sanity',
    function()
        -- ★ İKİNCİ SAVUNMA HATTI: fail-closed.
        if not Config.Chaos or not Config.Chaos.HardcoreEnabled then return end

        local A = Matrix.Chaos.Assert
        A.SetContext('chaos_ui_persistence_audit', 'server/matrix_chaos_hardcore_ui.lua')

        -- ═══════════════════════════════════════════════════════════
        -- 1) AYNI 4 STATIK GREP (KOR NOKTA 1.4 ile ayni) -- chaos
        -- versiyonu, her ihlal AYRI AYRI HIGH raporlanir (diagnostics
        -- tek bool dondururken burada detay/tekil bulgu istenir).
        -- ═══════════════════════════════════════════════════════════
        do
            local thc = _ReadFile('client/trap_house_client.lua')
            if not thc then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' client/trap_house_client.lua okunamadi', {
                    file = 'client/trap_house_client.lua',
                })
            else
                if not thc:find('SetBlipAsShortRange(blip, false)', 1, true) then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' SetBlipAsShortRange(blip, false) yok (Fix 2 regresyonu)', {
                        file = 'client/trap_house_client.lua',
                    })
                end
                if not thc:find('SetBlipDisplay(blip, 4)', 1, true) then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' SetBlipDisplay(blip, 4) yok', {
                        file = 'client/trap_house_client.lua',
                    })
                end
                if not thc:find('RemoveBlip', 1, true) then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' RemoveBlip cagrisi yok (orphan temizligi)', {
                        file = 'client/trap_house_client.lua',
                    })
                end
            end

            local thi = _ReadFile('server/trap_house_interior.lua')
            if not thi then
                Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' server/trap_house_interior.lua okunamadi', {
                    file = 'server/trap_house_interior.lua',
                })
            else
                if not thi:find('visibleIds', 1, true) then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' getTrapHouseLocations ownership filter (visibleIds) yok', {
                        file = 'server/trap_house_interior.lua',
                    })
                end
                if not thi:find('not PlayerInteriorState[src]', 1, true) then
                    Matrix.Chaos.Report('HIGH', HARDCORE_TAG .. ' crash recovery guard (not PlayerInteriorState[src]) yok', {
                        file = 'server/trap_house_interior.lua',
                    })
                end
            end
        end

        -- ═══════════════════════════════════════════════════════════
        -- 2-5) Config.Chaos.* sanity
        -- ═══════════════════════════════════════════════════════════
        do
            local v = Config.Chaos.UIPersistenceFlickerThreshold
            if type(v) ~= 'number' or v < 1 then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' Config.Chaos.UIPersistenceFlickerThreshold sanity ihlali', {
                    file   = 'shared/config.lua',
                    impact = ('deger: %s (beklenen: number >= 1)'):format(tostring(v)),
                })
            end
        end

        do
            local v = Config.Chaos.UIPersistenceMaxOrphanCount
            if type(v) ~= 'number' or v ~= 0 then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' Config.Chaos.UIPersistenceMaxOrphanCount sanity ihlali', {
                    file   = 'shared/config.lua',
                    impact = ('deger: %s (beklenen: number == 0)'):format(tostring(v)),
                })
            end
        end

        do
            local v = Config.Chaos.UIPersistenceScanIntervalMs
            if type(v) ~= 'number' or v < 100 or v > 10000 then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' Config.Chaos.UIPersistenceScanIntervalMs sanity ihlali', {
                    file   = 'shared/config.lua',
                    impact = ('deger: %s (beklenen: 100..10000)'):format(tostring(v)),
                })
            end
        end

        do
            local v = Config.Chaos.ClientBridgeFuzzEventCount
            if type(v) ~= 'number' or v ~= 7 then
                Matrix.Chaos.Report('MEDIUM', HARDCORE_TAG .. ' Config.Chaos.ClientBridgeFuzzEventCount sanity ihlali', {
                    file   = 'shared/config.lua',
                    impact = ('deger: %s (beklenen: number == 7, Paket C ile tutarli)'):format(tostring(v)),
                })
            end
        end

        Matrix.Chaos.Report('INFO', HARDCORE_TAG .. ' ui_persistence_audit tamamlandi', {})
    end)

Matrix.Chaos.Modules['chaos_ui_persistence_audit'].fixture_opts = { traps = 0, bots = 0 }
