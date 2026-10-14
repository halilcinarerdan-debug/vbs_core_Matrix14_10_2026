-- =====================================================================
-- MATRIX PROP REGISTRY / server/prop_registry.lua
-- SESSION 4.99 — PHYSICAL ENTITY PLACEMENT & NO-COLLISION ENGINE
--
-- ★ MANDAT (Mission File):
--   - SIFIR RNG: math.random YASAK. Tüm pozisyon/heading girdileri
--     client'tan deterministik olarak gelir (kamera/oyuncu forward
--     vector'ünden türetilmiş); sunucu bunları yalnızca doğrular ve
--     sahneler. Hiçbir koordinat sunucu tarafında rastgele üretilmez.
--   - SINGLE SOURCE OF INTERIOR MARKER: Bu modül yüklendiği anda
--     Config.TrapHouseInterior.Shell.WorkbenchPos ve .PackagingPos
--     DEĞERLERİ NÖTRLENİR (nil). Böylece:
--         * client/trap_house_client.lua artık legacy statik E-prompt
--           GÖSTEREMEZ (workbench_pos/packaging_pos = nil -> hiçbir blok
--           girmiyor). İçeride KALAN tek statik tetik: Çıkış Kapısı.
--         * Tüm laboratuvar etkileşimi, oyuncunun kendi deploy ettiği
--           fiziksel prop'ların ox_target context'ine bağlanır.
--     NOT: Bu nötrleme BİLİNÇLİ bir davranıştır ve geri alınabilir
--     (Config.PropRegistry.PurgeLegacyStaticMarkers = false ile kapatılır).
--
--   - NO-COLLISION MANDATE: Prop'lar görsel olarak yüksek çözünürlükte
--     render edilir ancak FİZİKSEL ÇARPIŞMA SINIRI SIFIRDIR. Sunucu
--     tarafı entity collision'ı SET EDEMEZ (native yalnızca client'ta
--     mevcuttur) -- bu yüzden spawn sonrası TÜM bağlı client'lara
--     `matrix:client:propRegistry:spawned` broadcast edilir ve her bir
--     client KENDİ tarafında `SetEntityCollision(entity, false, true)`
--     uygular. 3sn'lik bir heartbeat, geç katılan client veya entity
--     re-stream olaylarında (routing bucket reload) tekrar uygular.
--
--   - ox_target context'i, prop'un 1.8m'lik STRICT PROXIMITY'sinde
--     client tarafında `addLocalEntity` ile bağlanır; sunucu asla
--     "target'ı kim açtı" tahmini yapmaz -- client `onSelect`
--     tetiklendiğinde hangi propId ile konuştuğunu BİLİR ve sunucuya
--     `matrix:server:propRegistry:interact` ile bildirir.
--
--   - REMOTELY DELEGATED SUPPLY PIPELINES: crack_chemistry.lua,
--     meth_chemistry.lua, botany_autonomy.lua hedeflerini bu modülün
--     GetProp(trapHouseId, kind) getter'ı üzerinden çeker (bkz. aşağıda
--     `getLabLayout` override'ı ve `Matrix.PropRegistry.GetWorkbenchPos`).
--
-- ★ DEPENDENCY SIRASI: fxmanifest.lua'da `server/trap_house_interior.lua`
--   VE `server/botany_core.lua` VE `server/chemical_workbench.lua`'DAN
--   SONRA yüklenmelidir (bu dosya o modüllerin callback'lerini yeniden
--   register eder).
--
-- ★ TEK-SEFERLİK KURULUM: ox_inventory items.lua'ya iki item ekleyin
--   (bu modül item TANIMLAMAZ, yalnızca referans eder — mevcut
--   meth_bag/burner_phone İLE AYNI disiplin):
--
--     ['chemical_workbench_kit'] = {
--         label = 'Kimyasal Tezgah Montaj Kutusu',
--         weight = 25000, stack = false, close = true,
--         description = 'Katlanmış endüstriyel kimyasal tezgah — sahada monte edilebilir.',
--         client = { export = 'vbs_core_matrix.StartPropPlacement', args = { 'chemical_workbench' } }
--     },
--     ['botany_cabinet_kit'] = {
--         label = 'Botanik Kabin Montaj Kutusu',
--         weight = 18000, stack = false, close = true,
--         description = 'Katlanmış modüler sera kabini — sahada monte edilebilir.',
--         client = { export = 'vbs_core_matrix.StartPropPlacement', args = { 'botany_cabinet' } }
--     },
-- =====================================================================

Matrix = Matrix or {}
Matrix.PropRegistry = Matrix.PropRegistry or {}

-- =====================================================================
-- SABİTLER
-- =====================================================================
local PROXIMITY_RANGE          = 1.8
local DEPLOY_RATE_LIMIT_MS     = 2500
local MIN_DEPLOY_DIST          = 0.3
local MAX_DEPLOY_DIST          = 5.0

local ALLOWED_KINDS = {
    chemical_workbench = {
        model = 'prop_table_03b',
        item  = 'chemical_workbench_kit',
        label = 'Chemical Synthesis (mg input)',
        icon  = 'fa-solid fa-flask-vial',
    },
    botany_cabinet = {
        model = 'bkr_prop_weed_01_small_01a',
        item  = 'botany_cabinet_kit',
        label = 'Botany Cabinet — Environment Control',
        icon  = 'fa-solid fa-seedling',
    },
}

-- ★ _SerializeProp — global tanım (boot restore + Deploy aynı fonksiyonu kullanır)
function _SerializeProp(prop)
    if type(prop) ~= 'table' then return {} end
    local c = prop.coords
    return {
        id            = prop.id,
        trap_house_id = prop.trap_house_id,
        kind          = prop.kind,
        x             = (c and c.x) or prop.x or 0.0,
        y             = (c and c.y) or prop.y or 0.0,
        z             = (c and c.z) or prop.z or 0.0,
        heading       = prop.heading or 0.0,
    }
end

-- State
local DeployedProps   = {}   -- [id] = prop
local DeployedByHouse = {}   -- [trapHouseId][kind] = propId
local LastDeployAt    = {}   -- [src] = ms (GetGameTimer)

-- Legacy fallback (Config nötrlemesinden önce kaydedilir)
Matrix.PropRegistry._LegacyFallback = Matrix.PropRegistry._LegacyFallback or {}

-- =====================================================================
-- UTILITY
-- =====================================================================
local function _IsValidCoord(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    if c.x == math.huge or c.x == -math.huge then return false end
    if c.y == math.huge or c.y == -math.huge then return false end
    if c.z == math.huge or c.z == -math.huge then return false end
    return true
end

local function _VectorDistance(a, b)
    if not a or not b then return math.huge end
    return #(a - b)
end

local function _GetTrapHouseIdForSource(src)
    if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse then
        local ok, tid = pcall(Matrix.TrapHouseInterior.GetPlayerTrapHouse, src)
        if ok then return tonumber(tid) end
    end
    return nil
end

local function _LoadModelHash(model)
    -- ★ SERVER-SIDE ONLY: IsModelValid / RequestModel / HasModelLoaded /
    -- SetModelAsNoLongerNeeded CLIENT-ONLY native'lerdir. Server tarafında
    -- yalnızca hash hesaplanır; model streaming'i OneSync üzerinden
    -- client'lar tarafından otomatik yapılır.
    if type(model) ~= 'string' or model == '' then return nil end
    return joaat(model)
end
-- =====================================================================
-- NÖTRLEME: SINGLE SOURCE OF INTERIOR MARKER MANDATE
-- =====================================================================
local function _PurgeLegacyStaticMarkers()
    local cfg  = Config and Config.PropRegistry
    local purge = (cfg and cfg.PurgeLegacyStaticMarkers)
    if purge == nil then purge = true end -- default: mandate uygulanır
    if not purge then
        Matrix.Log('PROP_REGISTRY', '[MANDATE] Legacy static marker purge DISABLED by config.')
        return
    end

    local shell = Config and Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell then return end

    Matrix.PropRegistry._LegacyFallback.WorkbenchPos = shell.WorkbenchPos
    Matrix.PropRegistry._LegacyFallback.PackagingPos = shell.PackagingPos
    Matrix.PropRegistry._LegacyFallback.RouterPos    = shell.RouterPos

    -- Yalnızca etkileşim tetikleyicileri nötrlenir; RouterPos (kamera veri
    -- temizliği için fiziksel yakınlık gerektiren bir nokta) KORUNUR --
    -- oyuncu oraya prop deploy etmiyor, sanal bir "router kutusu" olarak
    -- sabit kalıyor (mission brief yalnızca laboratuvar/üretim
    -- trigger'larını prop'a bağlamayı istiyor).
    shell.WorkbenchPos = nil
    shell.PackagingPos = nil

    Matrix.Log('PROP_REGISTRY',
        '[MANDATE] Legacy static markers purged. Yalnizca Cikis Kapisi ve Router kutusu statik kalir.')
end

CreateThread(function()
    Wait(500)
    _PurgeLegacyStaticMarkers()
end)

-- =====================================================================
-- MIGRATION
-- =====================================================================
CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `matrix_deployed_props` (
                `id`             INT          NOT NULL AUTO_INCREMENT,
                `trap_house_id`  INT          NOT NULL,
                `kind`           VARCHAR(32)  NOT NULL,
                `coord_x`        FLOAT        NOT NULL,
                `coord_y`        FLOAT        NOT NULL,
                `coord_z`        FLOAT        NOT NULL,
                `heading`        FLOAT        NOT NULL DEFAULT 0.0,
                `deployed_by`    VARCHAR(50)  NULL,
                `active`         TINYINT(1)   NOT NULL DEFAULT 1,
                `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_prop_house` (`trap_house_id`, `kind`, `active`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if not ok then
        Matrix.Log('PROP_REGISTRY', '[HATA] Migration basarisiz (yutuldu): %s', tostring(err))
        return
    end

    -- Boot restore
    local loadOk, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM matrix_deployed_props WHERE active = 1')
    end)
    if not loadOk or type(rows) ~= 'table' then
        Matrix.Log('PROP_REGISTRY', '[BOOT] Deployed prop tablosu okunamadi.')
        return
    end

    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        if id then
            local th = tonumber(row.trap_house_id)
            local prop = {
                id            = id,
                trap_house_id = th,
                kind          = row.kind,
                coords        = vector3(
                    tonumber(row.coord_x) or 0.0,
                    tonumber(row.coord_y) or 0.0,
                    tonumber(row.coord_z) or 0.0
                ),
                heading       = tonumber(row.heading) or 0.0,
                deployed_by   = row.deployed_by,
                entity        = nil,
                net_id        = nil,
            }
            DeployedProps[id] = prop
            DeployedByHouse[th] = DeployedByHouse[th] or {}
            DeployedByHouse[th][row.kind] = id
        end
    end
    Matrix.Log('PROP_REGISTRY', '[BOOT] %d deployed prop loaded from DB.', #rows)

    -- ★ BOOT RESTORE — server artık entity spawn etmiyor, sadece
    -- client'lara broadcast yolluyor (client kendi local prop'unu kurar).
    Wait(1000)
    for _, prop in pairs(DeployedProps) do
        TriggerClientEvent('matrix:client:propRegistry:spawned', -1, _SerializeProp(prop))
        Matrix.Log('PROP_REGISTRY',
            '[BOOT] Prop #%d (%s, trap #%d) client-local restore broadcast gonderildi.',
            prop.id, prop.kind, prop.trap_house_id)
    end
end)

-- =====================================================================
-- SPAWN HELPER — NO-COLLISION MANDATE
-- =====================================================================

-- =====================================================================
-- PUBLIC API
-- =====================================================================
function Matrix.PropRegistry.GetProp(trapHouseId, kind)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or type(kind) ~= 'string' then return nil end
    local byKind = DeployedByHouse[trapHouseId]
    if not byKind then return nil end
    local propId = byKind[kind]
    return propId and DeployedProps[propId] or nil
end

function Matrix.PropRegistry.GetWorkbenchPos(trapHouseId)
    local p = Matrix.PropRegistry.GetProp(trapHouseId, 'chemical_workbench')
    if p then return p.coords, p.heading end
    return nil
end

function Matrix.PropRegistry.GetCabinetPos(trapHouseId)
    local p = Matrix.PropRegistry.GetProp(trapHouseId, 'botany_cabinet')
    if p then return p.coords, p.heading end
    return nil
end

function Matrix.PropRegistry.GetAllForHouse(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    local out = {}
    if not trapHouseId then return out end
    local byKind = DeployedByHouse[trapHouseId]
    if not byKind then return out end
    for _, propId in pairs(byKind) do
        local p = DeployedProps[propId]
        if p then out[#out + 1] = _SerializeProp(p) end
    end
    return out
end

-- =====================================================================
-- DEPLOY / REMOVE
-- =====================================================================
local function _RemoveExistingForKind(trapHouseId, kind)
    local byKind = DeployedByHouse[trapHouseId]
    if not byKind then return end
    local propId = byKind[kind]
    if not propId then return end
    local prop = DeployedProps[propId]
    if not prop then return end

    -- Server'da entity YOK — sadece client'lara broadcast yolla
    TriggerClientEvent('matrix:client:propRegistry:despawned', -1, propId)

    -- DB soft-delete
    pcall(function()
        MySQL.prepare('UPDATE matrix_deployed_props SET active = 0 WHERE id = ?', { propId })
    end)

    DeployedProps[propId] = nil
    byKind[kind] = nil
    Matrix.Log('PROP_REGISTRY', '[REMOVE] Prop #%d (%s, trap #%d) silindi (client-local).',
        propId, kind, trapHouseId)
end

function Matrix.PropRegistry.Deploy(src, trapHouseId, kind, coords, heading)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    if not ALLOWED_KINDS[kind] then return false, 'bad_kind' end
    if not _IsValidCoord(coords) then return false, 'bad_coords' end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses or not Matrix.TrapHouses[trapHouseId] then
        return false, 'bad_trap_house'
    end

    heading = tonumber(heading) or 0.0
    if heading ~= heading or heading == math.huge or heading == -math.huge then
        heading = 0.0
    end
    heading = heading % 360.0

    -- Rate limit
    local now = GetGameTimer()
    local last = LastDeployAt[src] or 0
    if (now - last) < DEPLOY_RATE_LIMIT_MS then
        return false, 'rate_limited'
    end

    -- Kullanıcı içeride mi?
    local interiorId = _GetTrapHouseIdForSource(src)
    if interiorId ~= trapHouseId then
        return false, 'not_inside_trap_house'
    end

    -- Oyuncuya olan mesafe doğrulaması
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'no_ped' end
    local pCoords = GetEntityCoords(ped)
    local dist = _VectorDistance(vector3(pCoords.x, pCoords.y, pCoords.z), vector3(coords.x, coords.y, coords.z))
    if dist < MIN_DEPLOY_DIST or dist > MAX_DEPLOY_DIST then
        return false, 'distance_invalid'
    end

    -- Kit item tüket
    local kit = ALLOWED_KINDS[kind].item
    local invOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, kit, 1)
    end)
    if not invOk or removed ~= true then
        return false, 'kit_missing'
    end

    -- Aynı türde zaten bir prop varsa kaldır (idempotent upgrade)
    _RemoveExistingForKind(trapHouseId, kind)

    -- Persist
    local insertOk, insertId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO matrix_deployed_props
                (trap_house_id, kind, coord_x, coord_y, coord_z, heading, deployed_by, active)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1)
        ]], {
            trapHouseId, kind,
            coords.x, coords.y, coords.z, heading,
            ('src:%d'):format(src)
        })
    end)
    if not insertOk or type(insertId) ~= 'number' then
        -- Kit iadesi
        pcall(function() exports['ox_inventory']:AddItem(src, kit, 1) end)
        return false, 'db_insert_failed'
    end

    local prop = {
        id            = insertId,
        trap_house_id = trapHouseId,
        kind          = kind,
        coords        = vector3(coords.x, coords.y, coords.z),
        heading       = heading,
        deployed_by   = ('src:%d'):format(src),
        entity        = nil,
        net_id        = nil,
    }

    -- ★ SERVER ARTIK ENTITY SPAWN ETMİYOR.
    -- Her client kendi LOCAL (networked=false) kopyasını spawn eder.
    -- Bu sayede:
    --   1) SetEntityCollision her client tarafında garanti çalışır
    --   2) ox_target local entity'ye sorunsuz bağlanır
    --   3) OneSync owner gerektirmez

    DeployedProps[insertId] = prop
    DeployedByHouse[trapHouseId] = DeployedByHouse[trapHouseId] or {}
    DeployedByHouse[trapHouseId][kind] = insertId

    LastDeployAt[src] = now

    -- Broadcast — tüm client'lar local prop spawn eder
    TriggerClientEvent('matrix:client:propRegistry:spawned', -1, _SerializeProp(prop))

    -- Deploy edene ekran bildirimi
    TriggerClientEvent('matrix:client:actionNotify', src, true,
        ('%s basariyla sahaya yerlestirildi.'):format(ALLOWED_KINDS[kind].label))

     Matrix.Log('PROP_REGISTRY',
        '[DEPLOY] Prop #%d (%s, trap #%d) src=%d tarafindan konuldu @ (%.2f,%.2f,%.2f) h=%.1f',
        insertId, kind, trapHouseId, src, coords.x, coords.y, coords.z, heading)

    return true, insertId
end

-- =====================================================================
-- NET EVENTS
-- =====================================================================
RegisterNetEvent('matrix:server:propRegistry:deploy', function(kind, x, y, z, heading)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(kind) ~= 'string' or not ALLOWED_KINDS[kind] then return end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    heading = tonumber(heading)
    if not x or not y or not z then return end

    local tid = _GetTrapHouseIdForSource(src)
    if not tid then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Sadece bir trap house ic mekanindayken prop yerlestirebilirsiniz.')
        return
    end

    local ok, reason, _netId = Matrix.PropRegistry.Deploy(src, tid, kind, vector3(x, y, z), heading)
    if not ok then
        local MSG = {
            bad_src                  = 'Kaynak cozulemedi.',
            bad_kind                 = 'Gecersiz kit tipi.',
            bad_coords               = 'Konum gecersiz.',
            bad_trap_house           = 'Trap house bulunamadi.',
            not_inside_trap_house    = 'Su anda trap house ic mekaninda degilsiniz.',
            distance_invalid         = ('Yerlestirme mesafesi %.1f-%.1f m arasinda olmali.'):format(MIN_DEPLOY_DIST, MAX_DEPLOY_DIST),
            kit_missing              = 'Envanterinizde montaj kiti yok.',
            db_insert_failed         = 'Kayit olusturulamadi; kit iade edildi.',
            spawn_failed             = 'Sahne olusturulamadi; kit iade edildi.',
            rate_limited             = 'Cok hizli deniyorsunuz.',
        }
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            MSG[reason] or ('Yerlestirme basarisiz: ' .. tostring(reason)))
    end
end)

RegisterNetEvent('matrix:server:propRegistry:remove', function(propId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    propId = tonumber(propId)
    if not propId then return end

    local prop = DeployedProps[propId]
    if not prop then return end

    -- Yetki: prop'a en son deploy eden src veya bir Hierarchy komuta yetkilisi
    local allowed = false
    if prop.deployed_by == ('src:%d'):format(src) then
        allowed = true
    else
        local st = Matrix.GetOrCreatePlayerState(src)
        if st and st.citizenid and Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority
            and Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            allowed = true
        end
    end
    if not allowed then return end

    -- ★ Kit iadesi (prop türüne göre doğru kiti geri ver)
    local kindCfg = ALLOWED_KINDS[prop.kind]
    if kindCfg and kindCfg.item then
        pcall(function()
            exports['ox_inventory']:AddItem(src, kindCfg.item, 1)
        end)
        Matrix.Log('PROP_REGISTRY',
            '[REMOVE] Prop #%d (%s) sokuldu, kit iade edildi: %s (src=%d)',
            propId, prop.kind, kindCfg.item, src)
    end

    _RemoveExistingForKind(prop.trap_house_id, prop.kind)
end)

-- Sync: geç katılan client veya manuel talep
RegisterNetEvent('matrix:server:propRegistry:requestSync', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local interiorId = _GetTrapHouseIdForSource(src)
    local props = interiorId and Matrix.PropRegistry.GetAllForHouse(interiorId) or {}
    TriggerClientEvent('matrix:client:propRegistry:syncAll', src, props, interiorId)
end)

-- Interaction: client bir prop target'ına tıkladığında sunucuya bildirir
-- (kim, hangi propId) -- sunucu yakınlık doğrular.
RegisterNetEvent('matrix:server:propRegistry:interact', function(propId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    propId = tonumber(propId)
    if not propId then return end

    local prop = DeployedProps[propId]
    if not prop then return end

    -- Oyuncu hâlâ interior'da mı ve prop'a yakın mı?
    local interiorId = _GetTrapHouseIdForSource(src)
    if interiorId ~= prop.trap_house_id then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local pCoords = GetEntityCoords(ped)
    local dist = _VectorDistance(vector3(pCoords.x, pCoords.y, pCoords.z), prop.coords)
    -- 1.8m + tampon 1.5m (client-server latency)
    if dist > (PROXIMITY_RANGE + 1.5) then return end

    -- Uygun modüle yönlendir
    if prop.kind == 'chemical_workbench' then
        TriggerClientEvent('matrix:client:propRegistry:openChemWB', src, propId, prop.trap_house_id)
    elseif prop.kind == 'botany_cabinet' then
        TriggerClientEvent('matrix:client:propRegistry:openBotany', src, propId, prop.trap_house_id)
    end
end)

-- =====================================================================
-- ★ REMOTELY DELEGATED SUPPLY PIPELINES
-- =====================================================================

-- ★ 1) getLabLayout callback OVERRIDE
-- server/botany_core.lua'daki orijinal callback `shell.WorkbenchPos`'tan
-- deterministik ofset türetiyordu -- shell artık nil. Bu sürüm önce
-- deploy edilmiş gerçek prop'ları okur; prop yoksa legacy fallback'e
-- (bu modülün boot sırasında SAKLA DİĞİ orijinal WorkbenchPos) düşer.
-- Böylece hem mission mandate uygulanır (deploy edilmişse onu kullanır)
-- hem de prop yoksa script çökmez.
CreateThread(function()
    Wait(800)
    local ok, err = pcall(function()
        lib.callback.register('matrix:server:botany:getLabLayout', function(src, trapHouseId)
            if type(src) ~= 'number' or src <= 0 then return nil end
            trapHouseId = tonumber(trapHouseId)
            if not trapHouseId then return nil end

            local cabinet  = Matrix.PropRegistry.GetProp(trapHouseId, 'botany_cabinet')
            local workbench = Matrix.PropRegistry.GetProp(trapHouseId, 'chemical_workbench')
            local fb = Matrix.PropRegistry._LegacyFallback

            local baseX = (cabinet and cabinet.coords.x) or (fb.WorkbenchPos and fb.WorkbenchPos.x) or 0.0
            local baseY = (cabinet and cabinet.coords.y) or (fb.WorkbenchPos and fb.WorkbenchPos.y) or 0.0
            local baseZ = (cabinet and cabinet.coords.z) or (fb.WorkbenchPos and fb.WorkbenchPos.z) or 0.0

            return {
                cabinet_pos     = cabinet and cabinet.coords or vector3(baseX,         baseY,        baseZ),
                barrel_pos      = workbench and workbench.coords or vector3(baseX + 1.2, baseY,      baseZ),
                uv_pos          = vector3(baseX, baseY + 1.2, baseZ),
                cabinet_heading = cabinet and cabinet.heading or 0.0,
                barrel_heading  = workbench and workbench.heading or 90.0,
                uv_heading      = 180.0,
            }
        end)
    end)
    if not ok then
        Matrix.Log('PROP_REGISTRY', '[HATA] getLabLayout override basarisiz: %s', tostring(err))
    end
end)

-- ★ 2) Workbench prop materialize override
-- Orijinal chemical_workbench.lua, trap house bucket'ında prop_gun_barrel_01
-- spawn ediyordu. Mission mandate gereği statik prop YOK -- bu event
-- DÜŞÜRÜLÜR ve bunun yerine kullanıcı prop'unun ox_target context'i geçerli
-- olur. `matrix_events_handler.lua`'nın kendi legacy handler'ı hâlâ devrede
-- ama bizim isim-uzayımızda bu event artık no-op.
RegisterNetEvent('matrix:client:workbench:materializeBarrel', function()
    -- ★ No-op: mission mandate gereği statik tezgah prop'u YASAK.
    -- Uyarı bırakma, sessizce yut (client zaten trap house içine giriyor).
end)

-- ★ 3) public export'lar
exports('GetDeployedProp', function(trapHouseId, kind)
    return Matrix.PropRegistry.GetProp(trapHouseId, kind)
end)
exports('GetDeployedWorkbenchPos', function(trapHouseId)
    return Matrix.PropRegistry.GetWorkbenchPos(trapHouseId)
end)
exports('GetDeployedCabinetPos', function(trapHouseId)
    return Matrix.PropRegistry.GetCabinetPos(trapHouseId)
end)
exports('DeployProp', function(src, trapHouseId, kind, coords, heading)
    return Matrix.PropRegistry.Deploy(src, trapHouseId, kind, coords, heading)
end)

-- =====================================================================
-- OPERATÖR DEBUG KOMUTU
-- =====================================================================
RegisterCommand('matrix_props', function(src)
    local lines = { '=== DEPLOYED PROPS ===' }
    for id, prop in pairs(DeployedProps) do
        lines[#lines + 1] = ('#%d [%s] trap#%d @ (%.2f,%.2f,%.2f) h=%.1f net=%s'):format(
            id, prop.kind, prop.trap_house_id,
            prop.coords.x, prop.coords.y, prop.coords.z,
            prop.heading, tostring(prop.net_id))
    end
    if #lines == 1 then lines[#lines + 1] = '(bos)' end

    if type(src) == 'number' and src > 0 then
        for _, l in ipairs(lines) do
            TriggerClientEvent('chat:addMessage', src, { args = { '[PROP_REGISTRY]', l } })
        end
    else
        for _, l in ipairs(lines) do
            print(('[MATRIX:PROP_REGISTRY] %s'):format(l))
        end
    end
end, false)

-- ★ [FAZ 0.6] Public getters — diagnostic ve diğer modüller için
-- (RegisterCommand DIŞINDA tanımlanmalı; aksi halde komut çağrılmadıkça
--  bu fonksiyonlar HİÇ OLUŞMAZ, diagnostic testleri nil okur.)
function Matrix.PropRegistry.GetAllDeployedIds()
    local ids = {}
    for id in pairs(DeployedProps) do
        ids[#ids + 1] = id
    end
    return ids
end

function Matrix.PropRegistry.GetById(propId)
    return DeployedProps[tonumber(propId)]
end

RegisterCommand('matrix_prop_clear', function(src)
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            return
        end
    end
    local n = 0
    for _, prop in pairs(DeployedProps) do
        _RemoveExistingForKind(prop.trap_house_id, prop.kind)
        n = n + 1
    end
    Matrix.Log('PROP_REGISTRY', '[ADMIN] %d prop kaldirildi.', n)
end, false)

-- =====================================================================
-- CLEANUP
-- =====================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for _, prop in pairs(DeployedProps) do
        if prop.entity and prop.entity ~= 0 then
            pcall(function()
                if DoesEntityExist(prop.entity) then DeleteEntity(prop.entity) end
            end)
        end
    end
    DeployedProps = {}
    DeployedByHouse = {}
end)

Matrix.Log('PROP_REGISTRY',
    '[BOOT] Prop registry armed. Kinds=%d, proximity=%.1fm, mandate=NO-COLLISION+SINGLE-SOURCE.',
    (function() local n = 0 for _ in pairs(ALLOWED_KINDS) do n = n + 1 end return n end)(),
    PROXIMITY_RANGE)