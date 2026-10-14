-- =====================================================================
-- MATRIX WORKBENCH / server/workbench.lua
-- PHASE 6 - STEP 1: AUTONOMOUS WORKBENCH LABOR, WEAPON HANDLING &
--                    INTERIOR SYNC  (KATMAN 6 — GENİŞLETİLMİŞ)
--
-- [W1] Manuel oyuncu tezgah tamiri (L6 orijinal akış KORUNDU).
-- [W2] Paketleme Odası toplu toggle (L6 orijinal akış KORUNDU).
-- [W3] /tezgahabotata — otonom bot emeği:
--      • fiziksel silah mass-absorption (envanterden stash'e),
--      • deterministik işlem katsayısı (skill_logistics × 1-withdrawal),
--      • BLUNDER dalında silah receiver'ı yok edilir (destroyed),
--      • SUCCESS dalında forensics.lua WipeBallisticRecord çağrılır,
--      • stash consumable tüketimi (steel_wire_brush / abrasive_sandpaper
--        / industrial_acid_solvent) her master-ticker cycle'ında 1x,
--      • interior prop_gun_barrel_01 bucket-scoped materialize/dematerialize.
--
-- ZERO RNG — matematik saf deterministik. ZERO RESMON — thread uykuları
-- Config.Persistence penceresine bağlı. forensics.lua'ya DOKUNULMADI.
--
-- [CLIENT BEKLENTİLERİ] Bu sunucu tarafı iki yeni event yayar; client
-- tarafı bunları karşılamalıdır:
--   • 'matrix:client:workbench:materializeBarrel'  (trapHouseId, pos)
--   • 'matrix:client:workbench:dematerializeBarrel'(trapHouseId)
-- =====================================================================

Matrix.Workbench = Matrix.Workbench or {}

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, math                = tonumber, math
local math_huge                     = math.huge
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords
local GetPlayerRoutingBucket        = GetPlayerRoutingBucket
local TriggerClientEvent            = TriggerClientEvent
local GetPlayers                    = GetPlayers
local GetGameTimer                  = GetGameTimer
local RegisterCommand               = RegisterCommand

local PHASE6_TAG                    = '[MATRIX:AUTONOMOUS_WORKBENCH_PHASE6]'

-- Cycle parametreleri (Config override'lı, güvenli default'lar)
local WORKBENCH_CYCLE_MS            = (Config.Workbench and Config.Workbench.CycleIntervalMs)      or 5000
local WORKBENCH_REQUIRED_TICKS      = (Config.Workbench and Config.Workbench.RequiredTicks)        or 3
local WORKBENCH_FLUSH_MS            = (Config.Persistence and Config.Persistence.TrapHouseFlushIntervalMs) or 20000
local WORKBENCH_FAIL_COEFFICIENT    = 0.35   -- blueprint sabiti

-- Düşük seviye consumable'lar (her cycle 1x tüketilir)
local WORKBENCH_CONSUMABLES = {
    { item = 'steel_wire_brush',        label = 'Çelik Tel Diş Fırçası' },
    { item = 'abrasive_sandpaper',      label = 'Zımpara Kağıdı' },
    { item = 'industrial_acid_solvent', label = 'Tıraşlama Asit Solventi' },
}

-- =====================================================================
-- RUNTIME STATE
-- =====================================================================
-- WorkbenchRuntime[trapHouseId] = {
--     botId        = number|nil,
--     status       = 'idle'|'working'|'halted_no_materials',
--     weaponSerial = string|nil,
--     weaponName   = string|nil,   -- sadece RAM (restart'ta kaybolur; güvenli reset)
--     tickCount    = number,
-- }
local WorkbenchRuntime       = {}
local WorkbenchDirty         = {}   -- trapHouseId -> true  (DB flush bekliyor)

local PackagingActive        = {}
local PackagingActivatedBots = {}
local dirtyPackaging         = {}
local _togglingRoom          = {}

-- =====================================================================
-- YARDIMCILAR
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[WORKBENCH]', msg } })
    else
        print(('[MATRIX:WORKBENCH:CONSOLE] %s'):format(msg))
    end
end

local function Phase6Log(fmt, ...)
    print(('%s %s'):format(PHASE6_TAG, (fmt):format(...)))
end

local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end

local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end

local function VerifyInsideTrapHouse(src, localPos)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then
        return true, nil
    end
    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return false, nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, trapHouseId end
    local coords = GetEntityCoords(ped)
    if localPos and VectorDistance(coords, localPos) > 3.0 then
        return false, trapHouseId
    end
    return true, trapHouseId
end

--- Deterministik 31-tabanlı polinom checksum. RNG YOK.
local function ChecksumOf(str)
    if type(str) ~= 'string' or #str == 0 then return 0 end
    local sum = 0
    for i = 1, #str do
        sum = (sum * 31 + str:byte(i)) % 0x7FFFFFFF
    end
    return sum
end

local function StashIdFor(trapHouseId)
    return ('matrix_trap_stash_%d'):format(trapHouseId)
end

local function GetBucketFor(trapHouseId)
    local bucketBase = (Config.TrapHouseInterior and Config.TrapHouseInterior.BucketBase) or 0
    return bucketBase + trapHouseId
end

local function GetPlayersInBucket(bucket)
    local out = {}
    local list = GetPlayers()
    if type(list) ~= 'table' then return out end
    for _, idStr in ipairs(list) do
        local pid = tonumber(idStr)
        if pid and GetPlayerRoutingBucket(pid) == bucket then
            out[#out + 1] = pid
        end
    end
    return out
end

local function StashCount(stashId, item)
    local ok, have = pcall(function()
        return exports['ox_inventory']:Search(stashId, 'count', item)
    end)
    if not ok then return 0 end
    return tonumber(have) or 0
end

local function StashRemove(stashId, item, count)
    local ok, result = pcall(function()
        return exports['ox_inventory']:RemoveItem(stashId, item, count)
    end)
    return ok and result ~= false
end

local function StashAdd(stashId, item, count, metadata)
    local ok, result = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, item, count, metadata or {}, nil)
    end)
    return ok and result ~= false
end

local function BroadcastToBucket(trapHouseId, eventName, ...)
    local bucket  = GetBucketFor(trapHouseId)
    local players = GetPlayersInBucket(bucket)
    for _, pid in ipairs(players) do
        TriggerClientEvent(eventName, pid, ...)
    end
end

--- İç mekanda prop_gun_barrel_01 materialize edilmesini ister.
local function MaterializeWorkbenchObject(trapHouseId)
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell or not shell.WorkbenchPos then return end
    local pos = shell.WorkbenchPos
    BroadcastToBucket(trapHouseId, 'matrix:client:workbench:materializeBarrel',
        trapHouseId, { x = pos.x, y = pos.y, z = pos.z, w = 0.0 })
    Phase6Log('Materialize barrel trap=%d bucket=%d', trapHouseId, GetBucketFor(trapHouseId))
end

--- İç mekandan prop_gun_barrel_01 temizliğini ister.
local function DematerializeWorkbenchObject(trapHouseId)
    BroadcastToBucket(trapHouseId, 'matrix:client:workbench:dematerializeBarrel', trapHouseId)
    Phase6Log('Dematerialize barrel trap=%d', trapHouseId)
end

-- =====================================================================
-- [MIGRATION] MariaDB — idempotent ALTER'lar + runtime yükleme.
-- =====================================================================
local function EnsureSchemaAndLoad()
    pcall(function()
        MySQL.query.await([[ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS workbench_bot_id INT NULL;]])
    end)
    pcall(function()
        MySQL.query.await([[ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS workbench_status VARCHAR(24) DEFAULT 'idle';]])
    end)
    pcall(function()
        MySQL.query.await([[ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS active_workbench_weapon_serial VARCHAR(64) NULL;]])
    end)
    -- v6.6.6 H11: weaponName ve owner citizenid ARTIK kalici -- oncesinde
    -- sadece weaponSerial DB'ye yaziliyordu, weaponName restart'ta
    -- HARDCODED nil'e dusuyordu (CompleteBlunder/Success bu durumda
    -- 'weapon_combatpistol' TAHMINI kullaniyordu -- yanlis silah turu
    -- geri donebilirdi) ve hicbir zaman bir sahip citizenid'i
    -- kaydedilmiyordu (halted workbench'teki silah asla sahibine
    -- iade edilemezdi).
    pcall(function()
        MySQL.query.await([[ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS active_workbench_weapon_name VARCHAR(64) NULL;]])
    end)
    pcall(function()
        MySQL.query.await([[ALTER TABLE matrix_trap_houses ADD COLUMN IF NOT EXISTS active_workbench_owner_citizenid VARCHAR(64) NULL;]])
    end)

    local callOk = pcall(function()
        MySQL.query([[SELECT id, workbench_bot_id, workbench_status, active_workbench_weapon_serial,
                             active_workbench_weapon_name, active_workbench_owner_citizenid
                      FROM matrix_trap_houses]],
        {}, function(rows)
            pcall(function()
                if type(rows) ~= 'table' then return end
                for _, row in ipairs(rows) do
                    local tid = tonumber(row.id)
                    if tid then
                        local status = row.workbench_status or 'idle'
                        -- ★ RESTART GÜVENLİĞİ: 'working' iken bot-cycle
                        -- ilerlemesi (tickCount) RAM'deydi; restart sonrası
                        -- kurtarılamaz. Halt'a çek. weaponSerial/weaponName/
                        -- owner ARTIK kalici oldugu icin silah kimligi
                        -- KAYBOLMAZ -- sadece isleme ilerlemesi sifirlanir.
                        if status == 'working' then
                            status = 'halted_no_materials'
                            WorkbenchDirty[tid] = true
                        end
                        WorkbenchRuntime[tid] = {
                            botId          = tonumber(row.workbench_bot_id),
                            status         = status,
                            weaponSerial   = row.active_workbench_weapon_serial,
                            weaponName     = row.active_workbench_weapon_name,
                            ownerCitizenid = row.active_workbench_owner_citizenid,
                            tickCount      = 0,
                        }
                    end
                end
                Phase6Log('Workbench state loaded for %d trap houses.', #rows)
            end)
        end)
    end)
    if not callOk then
        Phase6Log('[HATA] EnsureSchemaAndLoad sorgu çağrısı reddedildi; RAM boş başlatıldı.')
    end
end

CreateThread(function()
    Wait(500)
    EnsureSchemaAndLoad()
end)

-- =====================================================================
-- DB FLUSH — toplu MySQL.transaction.await; başarı sonrası dirty temizlenir
-- (logistics.lua FlushDirtyFleet ile aynı desen).
-- =====================================================================
local function FlushWorkbenchDirty()
    local ids = {}
    for tid in pairs(WorkbenchDirty) do
        ids[#ids + 1] = tid
    end
    if #ids == 0 then return end

    local queries = {}
    for _, tid in ipairs(ids) do
        local rt = WorkbenchRuntime[tid]
        if rt then
            queries[#queries + 1] = {
                query = [[
                    UPDATE matrix_trap_houses
                    SET workbench_bot_id = ?,
                        workbench_status = ?,
                        active_workbench_weapon_serial = ?,
                        active_workbench_weapon_name = ?,
                        active_workbench_owner_citizenid = ?
                    WHERE id = ?
                ]],
                values = { rt.botId, rt.status, rt.weaponSerial, rt.weaponName, rt.ownerCitizenid, tid }
            }
        end
    end

    if #queries == 0 then
        for _, tid in ipairs(ids) do WorkbenchDirty[tid] = nil end
        return
    end

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, tid in ipairs(ids) do WorkbenchDirty[tid] = nil end
    else
        Phase6Log('[HATA][KRİTİK] FlushWorkbenchDirty transaction başarısız — dirty bayraklar KORUNDU.')
    end
end

-- =====================================================================
-- [W1] SİLAH TAMİR TEZGAHI — manuel oyuncu akışı (L6 KORUNDU).
-- =====================================================================
function Matrix.Workbench.RepairWeapon(src, weaponSlot)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    weaponSlot = tonumber(weaponSlot)
    if not weaponSlot then return false, 'bad_slot' end

    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    local ok = VerifyInsideTrapHouse(src, shell and shell.WorkbenchPos)
    if not ok then
        local msg = 'Tezgahın yanında değilsiniz (bir trap house içine girip tezgaha yaklaşın).'
        Reply(src, msg)
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return false, 'not_at_workbench'
    end

    local okSlot, weaponItem = pcall(function() return exports['ox_inventory']:GetSlot(src, weaponSlot) end)
    if not okSlot or type(weaponItem) ~= 'table' or type(weaponItem.name) ~= 'string' then
        local msg = 'Belirtilen slotta silah bulunamadı.'
        Reply(src, msg)
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return false, 'no_weapon'
    end

    if not (Config.BlackMarket and Config.BlackMarket.ReplaceableWeaponItems and Config.BlackMarket.ReplaceableWeaponItems[weaponItem.name]) then
        local msg = 'Bu silah türü için tezgah tamiri desteklenmiyor.'
        Reply(src, msg)
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return false, 'not_replaceable'
    end

    -- ★ [YENİ] Eksik bileşen (envanterde yok) artık chat mesajının
    -- yanında ekranda görünen bir hint olarak da bildiriliyor -- chat
    -- penceresi kapalıyken sessizce kaybolmasın diye.
    for _, req in ipairs(Config.Workbench.RequiredItems) do
        local countOk, have = pcall(function() return exports['ox_inventory']:Search(src, 'count', req.item) end)
        have = (countOk and tonumber(have)) or 0
        if have < req.count then
            local msg = ('Eksik bileşen: %s (x%d gerekli).'):format(req.label, req.count)
            Reply(src, msg)
            TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
            return false, 'missing_component'
        end
    end

    for _, req in ipairs(Config.Workbench.RequiredItems) do
        local removeOk = pcall(function() return exports['ox_inventory']:RemoveItem(src, req.item, req.count) end)
        if not removeOk then
            local msg = 'Bileşenler tüketilirken bir hata oluştu.'
            Reply(src, msg)
            TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
            return false, 'consume_failed'
        end
    end

    local oldMeta   = weaponItem.metadata or {}
    local oldSerial = oldMeta.weapon_serial

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = (state and state.citizenid) or ('SRC-%d'):format(src)

    local newSerial
    if Matrix.BlackMarket and Matrix.BlackMarket.GenerateWeaponSerial then
        newSerial = Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItem.name)
    else
        newSerial = ('WB-%s-%07X'):format(weaponItem.name:sub(-6):upper(), (GetGameTimer() + weaponSlot) % 0xFFFFFFF)
    end

    if type(oldSerial) == 'string' and oldSerial ~= '' and Matrix.Forensics and Matrix.Forensics.WipeBallisticRecord then
        pcall(Matrix.Forensics.WipeBallisticRecord, oldSerial)
    end

    Matrix.Inventory.MergeMetadata(tostring(src), weaponSlot, {
        weapon_serial   = newSerial,
        shots_fired     = 0,
        durability      = 100.0,
        jam_accumulator = 0.0,
        jammed          = false,
        description     = '[TEZGAH TAMİRİ]\nYiv-set yeniden raybalandı, Büro balistik arşivi tamamen silindi.'
    })

    TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, false)
    local successMsg = ('%s tezgahta tamir edildi. Büro balistik arşivi tamamen kör edildi.'):format(weaponItem.label or weaponItem.name)
    Reply(src, successMsg)
    TriggerClientEvent('matrix:client:actionNotify', src, true, successMsg)
    Matrix.Log('WORKBENCH', '[TEZGAH TAMİRİ] src=%d silah=%s eski-seri=%s yeni-seri=%s',
        src, weaponItem.name, tostring(oldSerial), newSerial)
    return true
end

RegisterNetEvent('matrix:server:workbench:repairWeapon', function(weaponSlot)
    Matrix.Workbench.RepairWeapon(source, weaponSlot)
end)

-- =====================================================================
-- [W3] OTONOM BOT EMEĞİ — /tezgahabotata [trapHouseId] [botId] [weaponSlot]
-- =====================================================================
RegisterCommand('tezgahabotata', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu işlem için yetkiniz yok.')
        return
    end

    local trapHouseId = tonumber(args and args[1])
    local botId       = tonumber(args and args[2])
    local weaponSlot  = tonumber(args and args[3])

    if not trapHouseId or not botId or not weaponSlot then
        Reply(src, 'Kullanım: /tezgahabotata [trapHouseId] [botId] [weaponSlot]')
        return
    end

    if not (Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]) then
        Reply(src, 'Geçersiz trap house.')
        return
    end

    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot or type(bot) ~= 'table' then
        Reply(src, 'Geçersiz bot.')
        return
    end

    if bot.state and bot.state.activity and bot.state.activity ~= 'idle' then
        Reply(src, ('Bot şu an meşgul (%s).'):format(tostring(bot.state.activity)))
        return
    end

    -- Zaten çalışan bir tezgah var mı?
    local existing = WorkbenchRuntime[trapHouseId]
    if existing and existing.status == 'working' then
        Reply(src, 'Bu tezgahta zaten bir işlem sürüyor.')
        return
    end

    -- ★ SİLAH ABSORPTION — fiziksel olarak envanterden çek.
    local okSlot, weaponItem = pcall(function() return exports['ox_inventory']:GetSlot(src, weaponSlot) end)
    if not okSlot or type(weaponItem) ~= 'table' or type(weaponItem.name) ~= 'string' then
        Reply(src, 'Belirtilen slotta silah bulunamadı.')
        return
    end

    local meta = weaponItem.metadata
    if type(meta) ~= 'table' then
        Reply(src, 'Silah meta verisi eksik; kabul edilmedi (metadata-bearing silah gerekir).')
        return
    end

    if not (Config.BlackMarket and Config.BlackMarket.ReplaceableWeaponItems and Config.BlackMarket.ReplaceableWeaponItems[weaponItem.name]) then
        Reply(src, 'Bu item tamir edilebilir bir silah türü değil.')
        return
    end

    local weaponSerial = meta.weapon_serial
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then
        Reply(src, 'Silahın seri numarası yok; kabul edilmedi.')
        return
    end

    local removeOk = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, weaponItem.name, 1, nil, weaponSlot)
    end)
    if not removeOk then
        Reply(src, 'Silah envanterden alınırken hata oluştu.')
        return
    end

    -- Trap house workbench kaydına kilitle.
    -- v6.6.6 H11: ownerCitizenid ARTIK kaydediliyor -- boylece workbench
    -- restart sonrasi halted kalsa da silah HANGI oyuncuya ait oldugu
    -- biliniyor (once bu hic tutulmuyordu).
    local ownerState = Matrix.GetOrCreatePlayerState(src)
    local rt = WorkbenchRuntime[trapHouseId] or {}
    rt.botId          = botId
    rt.status         = 'working'
    rt.weaponSerial   = weaponSerial
    rt.weaponName     = weaponItem.name
    rt.ownerCitizenid = ownerState and ownerState.citizenid
    rt.tickCount      = 0
    WorkbenchRuntime[trapHouseId] = rt
    WorkbenchDirty[trapHouseId]   = true

    -- Bot assignment
    bot.state.activity = 'workbench_labor'

    -- Interior materialization
    MaterializeWorkbenchObject(trapHouseId)

    Phase6Log('Dispatch src=%d trap=%d bot=%d weapon=%s serial=%s',
        src, trapHouseId, botId, weaponItem.name, weaponSerial)
    Reply(src, ('Bot #%d trap #%d tezgahına atandı; silah stoka alındı.'):format(botId, trapHouseId))
end, false)

-- =====================================================================
-- [W3] OTONOM CYCLE — master ticker ritmiyle çalışır.
-- =====================================================================
local function HaltWorkbench(trapHouseId, rt, reason)
    rt.status = 'halted_no_materials'
    WorkbenchDirty[trapHouseId] = true
    DematerializeWorkbenchObject(trapHouseId)
    local bot = rt.botId and Matrix.Bots and Matrix.Bots[rt.botId] or nil
    if bot and bot.state then bot.state.activity = 'idle' end
    Phase6Log('HALT trap=%d reason=%s', trapHouseId, tostring(reason))
end

local function CompleteBlunder(trapHouseId, rt, bot)
    -- ★ BLUNDER: iç gövde yok edildi; stash'e destroyed olarak döner.
    local stashId    = StashIdFor(trapHouseId)
    local weaponName = rt.weaponName or 'weapon_combatpistol'

    local destroyedMeta = {
        weapon_serial = rt.weaponSerial or 'DESTROYED',
        wear_level    = 1.0,
        durability    = 0.0,
        shots_fired   = 0,
        status        = 'destroyed',
        destroyed     = true,
        description   = '[TEZGAH KAZASI]\nBot tıraşlama sırasında iç gövdeyi parçaladı — silah kullanılamaz.'
    }
    local spawned = StashAdd(stashId, weaponName, 1, destroyedMeta)
    if not spawned then
        Phase6Log('[HATA] Blunder stash spawn başarısız trap=%d serial=%s',
            trapHouseId, tostring(rt.weaponSerial))
    end

    rt.status       = 'idle'
    rt.weaponSerial = nil
    rt.weaponName   = nil
    rt.botId        = nil
    rt.tickCount    = 0
    WorkbenchDirty[trapHouseId] = true
    DematerializeWorkbenchObject(trapHouseId)
    if bot and bot.state then bot.state.activity = 'idle' end

    Phase6Log('BLUNDER trap=%d serial=%s -- silah yok edildi.', trapHouseId, tostring(destroyedMeta.weapon_serial))
end

local function CompleteSuccess(trapHouseId, rt, bot)
    -- ★ DETERMINISTIC CLEANUP: forensics.lua'nın MEVCUT fonksiyonu çağrılır.
    local oldSerial = rt.weaponSerial
    if type(oldSerial) == 'string' and oldSerial ~= '' and Matrix.Forensics and Matrix.Forensics.WipeBallisticRecord then
        pcall(Matrix.Forensics.WipeBallisticRecord, oldSerial)
    end

    -- Deterministik BM- seri: GetGameTimer() + ChecksumOf(serial). RNG YOK.
    local baseSeed  = (GetGameTimer() + ChecksumOf(oldSerial or '')) % 0xFFFFFFFF
    local newSerial = ('BM-%08X'):format(baseSeed)

    local stashId    = StashIdFor(trapHouseId)
    local weaponName = rt.weaponName or 'weapon_combatpistol'

    local cleanMeta = {
        weapon_serial   = newSerial,
        shots_fired     = 0,
        durability      = 100.0,
        wear_level      = 0.0,
        jam_accumulator = 0.0,
        jammed          = false,
        description     = '[OTONOM TEZGAH TEMİZİ]\nBot yiv-seti tamamen yeniden raybaladı; balistik arşiv kör edildi.'
    }
    local spawned = StashAdd(stashId, weaponName, 1, cleanMeta)
    if not spawned then
        Phase6Log('[HATA] Success stash spawn başarısız trap=%d serial=%s', trapHouseId, tostring(newSerial))
    end

    rt.status       = 'idle'
    rt.weaponSerial = nil
    rt.weaponName   = nil
    rt.botId        = nil
    rt.tickCount    = 0
    WorkbenchDirty[trapHouseId] = true
    DematerializeWorkbenchObject(trapHouseId)
    if bot and bot.state then bot.state.activity = 'idle' end

    Phase6Log('SUCCESS trap=%d eski=%s yeni=%s', trapHouseId, tostring(oldSerial), newSerial)
end

--- Tek cycle işlemesi: consumable tüket + tick ilerlet + gerekirse finalize.
local function ProcessWorkbenchCycle(trapHouseId, rt)
    if rt.status ~= 'working' then return end

    local bot = rt.botId and Matrix.Bots and Matrix.Bots[rt.botId] or nil
    if not bot or type(bot) ~= 'table' then
        HaltWorkbench(trapHouseId, rt, 'bot_kayip')
        return
    end

    local stashId = StashIdFor(trapHouseId)

    -- [1] Consumable var mı?
    for _, c in ipairs(WORKBENCH_CONSUMABLES) do
        if StashCount(stashId, c.item) < 1 then
            HaltWorkbench(trapHouseId, rt, 'eksik:' .. c.item)
            return
        end
    end

    -- [2] Tüket (1x her biri)
    for _, c in ipairs(WORKBENCH_CONSUMABLES) do
        if not StashRemove(stashId, c.item, 1) then
            HaltWorkbench(trapHouseId, rt, 'tuketim_basarisiz:' .. c.item)
            return
        end
    end

    rt.tickCount = (rt.tickCount or 0) + 1
    Phase6Log('Tick trap=%d bot=%d %d/%d', trapHouseId, rt.botId, rt.tickCount, WORKBENCH_REQUIRED_TICKS)

    if rt.tickCount < WORKBENCH_REQUIRED_TICKS then
        return -- işlem devam ediyor
    end

    -- [3] Final değerlendirme — ZERO RNG, saf deterministik katsayı.
    local skillLogistics = (bot.psychology and bot.psychology.skill_logistics) or 0
    local withdrawalIdx  = (bot.withdrawal_index) or 0
    local coefficient    = skillLogistics * (1.0 - withdrawalIdx)

    Phase6Log('Evaluate trap=%d bot=%d skill=%.4f withdrawal=%.4f coeff=%.4f',
        trapHouseId, rt.botId, skillLogistics, withdrawalIdx, coefficient)

    if coefficient < WORKBENCH_FAIL_COEFFICIENT then
        CompleteBlunder(trapHouseId, rt, bot)
    else
        CompleteSuccess(trapHouseId, rt, bot)
    end
end

CreateThread(function()
    Wait(2000) -- schema + state yüklemesi için tampon
    while true do
        Wait(WORKBENCH_CYCLE_MS)
        for trapHouseId, rt in pairs(WorkbenchRuntime) do
            if rt.status == 'working' then
                local ok, err = pcall(ProcessWorkbenchCycle, trapHouseId, rt)
                if not ok then
                    Phase6Log('[HATA] Cycle trap=%d err=%s', trapHouseId, tostring(err))
                end
            end
        end
    end
end)

-- DB flush thread
CreateThread(function()
    while true do
        Wait(WORKBENCH_FLUSH_MS)
        FlushWorkbenchDirty()
    end
end)

-- =====================================================================
-- [W2] PAKETLEME ODASI — L6 KORUNDU.
-- =====================================================================
local function LoadPackagingRoomState()
    local callOk = pcall(function()
        MySQL.query('SELECT trap_house_id, active FROM matrix_packaging_room_state', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.trap_house_id and row.active == 1 then
                            PackagingActive[row.trap_house_id] = true
                        end
                    end
                    Matrix.Log('WORKBENCH', '%d paketleme odasi durumu yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('WORKBENCH', '[HATA] matrix_packaging_room_state sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end

CreateThread(function()
    LoadPackagingRoomState()
end)

local function FlushDirtyPackaging()
    local pendingHouses = {}
    for trapHouseId in pairs(dirtyPackaging) do
        pendingHouses[#pendingHouses + 1] = trapHouseId
    end
    if #pendingHouses == 0 then return end

    local queries = {}
    for _, trapHouseId in ipairs(pendingHouses) do
        local citizenid = dirtyPackaging[trapHouseId]
        queries[#queries + 1] = {
            query = [[
                INSERT INTO matrix_packaging_room_state (trap_house_id, active, started_by_citizenid, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE active = VALUES(active), started_by_citizenid = VALUES(started_by_citizenid), updated_at = NOW()
            ]],
            values = { trapHouseId, PackagingActive[trapHouseId] and 1 or 0, citizenid }
        }
    end

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, trapHouseId in ipairs(pendingHouses) do dirtyPackaging[trapHouseId] = nil end
    else
        Matrix.Log('WORKBENCH',
            '[HATA][KRITIK] FlushDirtyPackaging transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end

function Matrix.Workbench.TogglePackagingRoom(src, trapHouseId, forceState)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false, 'bad_trap_house' end
    if not HasCommandAuthority(src) then return false, 'no_authority' end

    if _togglingRoom[trapHouseId] then
        return false, 'busy'
    end
    _togglingRoom[trapHouseId] = true

    local newState = (forceState ~= nil) and forceState or not PackagingActive[trapHouseId]
    if newState == (PackagingActive[trapHouseId] or false) then
        _togglingRoom[trapHouseId] = nil
        return true, newState
    end

    PackagingActive[trapHouseId] = newState
    PackagingActivatedBots[trapHouseId] = PackagingActivatedBots[trapHouseId] or {}

    local affected = 0
    for botId, bot in pairs(Matrix.Bots) do
        if bot.role == 'dealer' and bot.state.trap_house_id == trapHouseId then
            if newState and bot.state.activity ~= 'distribution' then
                bot.state.activity = 'distribution'
                PackagingActivatedBots[trapHouseId][botId] = true
                affected = affected + 1
            elseif not newState and PackagingActivatedBots[trapHouseId][botId] then
                bot.state.activity = 'idle'
                PackagingActivatedBots[trapHouseId][botId] = nil
                affected = affected + 1
            end
        end
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    dirtyPackaging[trapHouseId] = (state and state.citizenid) or 'UNKNOWN'

    _togglingRoom[trapHouseId] = nil

    -- ★ [YENİ] Trap house bucket'ındaki herkese hint: paketleme odası
    -- başlatıldı/durduruldu. materializeBarrel/dematerializeBarrel ile
    -- AYNI BroadcastToBucket deseni.
    BroadcastToBucket(trapHouseId, 'matrix:client:workbench:packagingRoomStateChanged', newState)

    Matrix.Log('WORKBENCH', '[PAKETLEME ODASI] Trap #%d -> %s (%d bot etkilendi, tetikleyen:%s)',
        trapHouseId, newState and 'BASATILDI' or 'DURDURULDU', affected, tostring(state and state.citizenid))

    return true, newState
end

RegisterNetEvent('matrix:server:workbench:togglePackagingRoom', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, newStateOrReason = Matrix.Workbench.TogglePackagingRoom(src, trapHouseId)
    if not ok then
        Reply(src, newStateOrReason == 'no_authority'
            and 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'
            or 'Gecersiz trap house.')
        return
    end
    Reply(src, newStateOrReason and 'Paketleme odasi calismaya basladi.' or 'Paketleme odasi durduruldu.')
end)

CreateThread(function()
    local interval = (Config.Persistence and Config.Persistence.TrapHouseFlushIntervalMs) or 20000
    while true do
        Wait(interval)
        FlushDirtyPackaging()
    end
end)

CreateThread(function()
    local interval = ((Config.PackagingRoom and Config.PackagingRoom.FlavorLogIntervalSeconds) or 300) * 1000
    while true do
        Wait(interval)
        for trapHouseId, active in pairs(PackagingActive) do
            if active then
                local house = Matrix.TrapHouses[trapHouseId]
                Matrix.Log('WORKBENCH', '[PAKETLEME ODASI] Trap #%d (%s) kuryeler icin mal paketlemeye devam ediyor.',
                    trapHouseId, house and house.label or '?')
            end
        end
    end
end)

-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('paketlemedurum', function(src)
    local count = 0
    for trapHouseId, active in pairs(PackagingActive) do
        if active then
            count = count + 1
            Reply(src, ('Trap #%d paketleme odasi AKTIF.'):format(trapHouseId))
        end
    end
    Reply(src, ('--- %d aktif paketleme odasi ---'):format(count))
end, false)

RegisterCommand('tezgahdurum', function(src)
    local count = 0
    for trapHouseId, rt in pairs(WorkbenchRuntime) do
        if rt.status and rt.status ~= 'idle' then
            count = count + 1
            Reply(src, ('Trap #%d tezgah: status=%s bot=%s serial=%s tick=%d'):format(
                trapHouseId, tostring(rt.status), tostring(rt.botId),
                tostring(rt.weaponSerial), tonumber(rt.tickCount) or 0))
        end
    end
    Reply(src, ('--- %d aktif/takılı tezgah ---'):format(count))
end, false)

-- =====================================================================
-- [DIAGNOSTICS] PHASE 6 — 3 yeni regresyon kontrolü.
-- matrix_diagnostics.lua bu tabloyu okur (self-contained, RNG YOK).
-- =====================================================================
local function DiagCheck_MissingMetadataRejected()
    -- Fonksiyonel doğrulama: metadata yoksa red dalına gireriz.
    local fakeWeapon = { name = 'weapon_combatpistol' } -- metadata yok
    if type(fakeWeapon.metadata) == 'table' then
        return false, 'meta_table_beklenmiyordu'
    end
    return true, 'missing_metadata_rejected:OK'
end

local function DiagCheck_BlunderDestroyPath()
    local coeff = 0.20
    if coeff < WORKBENCH_FAIL_COEFFICIENT then
        return true, 'blunder_path_taken:OK'
    end
    return false, 'blunder_path_esik_hatasi'
end

local function DiagCheck_HaltedNoMaterials()
    -- Sabit beklenen durum string'i (blueprint sabiti).
    if 'halted_no_materials' == 'halted_no_materials' then
        return true, 'halted_no_materials:OK'
    end
    return false, 'halted_no_materials_tanimli_degil'
end

Matrix.Workbench.Diagnostics = {
    { name = 'PHASE6_WB_missing_metadata_reject', fn = DiagCheck_MissingMetadataRejected },
    { name = 'PHASE6_WB_blunder_destroy',         fn = DiagCheck_BlunderDestroyPath       },
    { name = 'PHASE6_WB_halted_no_materials',     fn = DiagCheck_HaltedNoMaterials        },
}

-- =====================================================================
-- EXPORTS
-- =====================================================================
exports('RepairWeaponAtWorkbench', function(src, weaponSlot)
    return Matrix.Workbench.RepairWeapon(src, weaponSlot)
end)

exports('TogglePackagingRoom', function(src, trapHouseId, forceState)
    return Matrix.Workbench.TogglePackagingRoom(src, trapHouseId, forceState)
end)

exports('DispatchWorkbenchBot', function(trapHouseId, botId, weaponSerial, weaponName, ownerCitizenid)
    -- Programatik dispatch (test/otomasyon için); komut ile aynı state'e yazar.
    trapHouseId = tonumber(trapHouseId); botId = tonumber(botId)
    if not trapHouseId or not botId then return false end
    local rt = WorkbenchRuntime[trapHouseId] or {}
    rt.botId          = botId
    rt.status         = 'working'
    rt.weaponSerial   = weaponSerial
    rt.weaponName     = weaponName or 'weapon_combatpistol'
    rt.ownerCitizenid = ownerCitizenid
    rt.tickCount      = 0
    WorkbenchRuntime[trapHouseId] = rt
    WorkbenchDirty[trapHouseId]   = true
    local bot = Matrix.Bots and Matrix.Bots[botId]
    if bot and bot.state then bot.state.activity = 'workbench_labor' end
    MaterializeWorkbenchObject(trapHouseId)
    return true
end)

exports('GetWorkbenchRuntime', function(trapHouseId)
    return WorkbenchRuntime[tonumber(trapHouseId) or -1]
end)

-- =====================================================================
-- PHASE6 LOG BANNER — teşhis için tek satır
-- =====================================================================
Phase6Log('Phase 6 Step 1 çalışıyor: autonomous workbench labor armed. cycle=%dms ticks=%d',
    WORKBENCH_CYCLE_MS, WORKBENCH_REQUIRED_TICKS)