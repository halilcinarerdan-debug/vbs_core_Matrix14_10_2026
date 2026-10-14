-- =====================================================================
-- MATRIX OYUNCU TELEMETRISI / server/player_telemetry.lua
--
-- ADDITIVE. Mevcut hicbir dosya/fonksiyon imzasi degistirilmedi; yalnizca
-- var olan net-event'lere (matrix:server:reportSaleAttempt,
-- matrix:server:reportPlayerWounded, matrix:server:reportWeaponShotFired,
-- playerDropped) AddEventHandler ile EK dinleyiciler baglanir.
--
-- citizenid bazli RAM tablosu: aggression_index, escape_pattern,
-- spend_rate, death_frequency, trade_balance, active_hours (7x24 matris,
-- gun*24+saat indeksli), preferred_zone. 15sn'de bir "write-behind"
-- thread'i kirli (dirty) kayitlari matrix_player_telemetry tablosuna
-- MySQL.transaction.await ile (server/market.lua FlushDirtyMarketZones
-- ile AYNI desen) toplu yazar.
--
-- KATI ANAYASA: math.random YOK. Tum skor guncellemeleri deterministik
-- bir EMA (ustel hareketli ortalama) ile yapilir -- ayni girdi dizisi
-- HER ZAMAN ayni sonucu uretir.
--
-- Profil siniflandirmasi (deterministik, RNG yok):
--   aggression_index > 0.70 ve escape_pattern < 0.30  -> 'aggressive'
--   aggression_index < 0.30 ve escape_pattern > 0.70  -> 'cautious'
--   trade_balance > 0.70                              -> 'economist'
--   aksi halde                                        -> 'roleplay'
-- =====================================================================

Matrix.PlayerTelemetry = Matrix.PlayerTelemetry or {}

-- =====================================================================
-- [FAZ 0.2 FIX] Migration — tablo yoksa oluştur (idempotent)
-- =====================================================================
CreateThread(function()
    Wait(500)
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `matrix_player_telemetry` (
                `citizenid`        VARCHAR(50) NOT NULL,
                `active_hours`     TEXT        NULL
                    COMMENT 'CSV: 168 değer (7gün x 24saat)',
                `preferred_zone`   INT         NULL,
                `aggression_index` FLOAT       NOT NULL DEFAULT 0.0,
                `escape_pattern`   FLOAT       NOT NULL DEFAULT 0.5,
                `spend_rate`       FLOAT       NOT NULL DEFAULT 0.0,
                `death_frequency`  FLOAT       NOT NULL DEFAULT 0.0,
                `trade_balance`    FLOAT       NOT NULL DEFAULT 0.0,
                `updated_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`),
                KEY `idx_matrix_player_telemetry_preferred_zone` (`preferred_zone`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if ok then
        Matrix.Log('TELEMETRY', '[MIGRATION] matrix_player_telemetry tablosu hazir.')
    else
        Matrix.Log('TELEMETRY', '[HATA] Migration basarisiz: %s', tostring(err))
    end
end)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_min, math_max                      = math.min, math.max
local os_date                                  = os.date
local CreateThread                             = CreateThread
local Wait                                     = Wait
local RegisterCommand                          = RegisterCommand
local TriggerClientEvent                       = TriggerClientEvent

local EMA_ALPHA = 0.15

local Telemetry      = {} -- [citizenid] = record
local DirtyTelemetry  = {} -- [citizenid] = true

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[TELEMETRI]', msg } })
    else
        print(('[MATRIX:TELEMETRY:CONSOLE] %s'):format(msg))
    end
end

local function Ema(old, sample)
    old = tonumber(old) or 0.0
    sample = Matrix.Clamp(tonumber(sample) or 0.0, 0.0, 1.0)
    return Matrix.Clamp(old + ((sample - old) * EMA_ALPHA), 0.0, 1.0)
end

local function NewActiveHoursMatrix()
    local t = {}
    for i = 0, 167 do t[i] = 0 end
    return t
end

local function GetOrCreateTelemetry(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local rec = Telemetry[citizenid]
    if rec then return rec end

    rec = {
        citizenid        = citizenid,
        aggression_index = 0.0,
        escape_pattern   = 0.5,
        spend_rate       = 0.0,
        death_frequency  = 0.0,
        trade_balance    = 0.0,
        active_hours     = NewActiveHoursMatrix(),
        preferred_zone   = nil,
        zone_visits      = {}, -- RAM-only yardimci; preferred_zone bundan turetilir
    }
    Telemetry[citizenid] = rec
    return rec
end

--- Sunucu saatine gore (gun-of-week*24 + saat) 7x24 aktivite matrisinin
--- ilgili hucresini +1 arttirir. Deterministik: os.date sunucu duvar
--- saatini okur, RNG yok.
local function TouchActiveHours(rec)
    local d = os_date('*t')
    local idx = ((d.wday - 1) * 24) + d.hour
    rec.active_hours[idx] = (rec.active_hours[idx] or 0) + 1
end

local function TouchPreferredZone(rec, zoneId)
    if not zoneId then return end
    rec.zone_visits[zoneId] = (rec.zone_visits[zoneId] or 0) + 1
    local bestZone, bestCount
    for zId, count in pairs(rec.zone_visits) do
        if not bestCount or count > bestCount then
            bestZone, bestCount = zId, count
        end
    end
    rec.preferred_zone = bestZone
end

local function ComputeProfile(rec)
    if not rec then return 'roleplay' end
    if rec.aggression_index > 0.70 and rec.escape_pattern < 0.30 then
        return 'aggressive'
    elseif rec.aggression_index < 0.30 and rec.escape_pattern > 0.70 then
        return 'cautious'
    elseif rec.trade_balance > 0.70 then
        return 'economist'
    end
    return 'roleplay'
end

Matrix.PlayerTelemetry.ComputeProfile = ComputeProfile

function Matrix.PlayerTelemetry.GetProfile(citizenid)
    return ComputeProfile(Telemetry[citizenid])
end

function Matrix.PlayerTelemetry.GetRecord(citizenid)
    return Telemetry[citizenid]
end

--- Aktif dispatch/bot AI kancalari icin: bir src'nin (oyuncunun) o anki
--- profilini dogrudan cozer. Kaydi yoksa notr 'roleplay' doner (yeni
--- oyuncular icin agresif-tepki kancasi hatali tetiklenmez).
function Matrix.PlayerTelemetry.GetProfileForSource(src)
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return 'roleplay' end
    return ComputeProfile(Telemetry[citizenid])
end

-- =====================================================================
-- KANCALAR (AddEventHandler -- mevcut RegisterNetEvent kayitlarina EK,
-- imza/davranis DEGISTIRILMEDI)
-- =====================================================================

AddEventHandler('matrix:server:reportSaleAttempt', function(botId, buyerCognitiveShifter, purity, sellerBallisticId, saleGrams)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return end

    local rec = GetOrCreateTelemetry(citizenid)
    if not rec then return end

    TouchActiveHours(rec)

    local grams = tonumber(saleGrams) or 0.0
    rec.trade_balance = Ema(rec.trade_balance, grams / 50.0)
    rec.spend_rate    = Ema(rec.spend_rate, grams / 100.0)

    botId = tonumber(botId)
    local bot = botId and Matrix.Bots and Matrix.Bots[botId]
    if bot and bot.state and bot.state.coords and Matrix.Market and Matrix.Market.FindNearestZone then
        local okZone, zoneId = pcall(Matrix.Market.FindNearestZone, bot.state.coords)
        if okZone and zoneId then
            TouchPreferredZone(rec, zoneId)
        end
    end

    DirtyTelemetry[citizenid] = true
end)

-- ★ matrix:server:reportPlayerWounded icin ZERO-TRUST guard bu event'in
-- ANA sahibi olan server/wound_system.lua'da uygulanir (spoofed rapor
-- orada DropPlayer ile ANINDA kesilir). Burada AYRICA -- handler kayit
-- SIRASINA bagli KALMADAN -- ayni dogrulayiciyi (Matrix.Wounds.
-- ValidateWoundReport) TEKRAR cagiriyoruz ki sahte bir rapor, iki
-- handler HANGI SIRAYLA calisirsa calissin, telemetriye ASLA sizmasin.
AddEventHandler('matrix:server:reportPlayerWounded', function(attackerServerId, attackerWeaponHash)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    if Matrix.Wounds and Matrix.Wounds.ValidateWoundReport then
        local okReport = Matrix.Wounds.ValidateWoundReport(src, attackerServerId, attackerWeaponHash)
        if not okReport then return end
    end

    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return end

    local rec = GetOrCreateTelemetry(citizenid)
    if not rec then return end

    TouchActiveHours(rec)
    rec.death_frequency = Ema(rec.death_frequency, 1.0)
    rec.escape_pattern   = Ema(rec.escape_pattern, 0.0)

    DirtyTelemetry[citizenid] = true
end)

AddEventHandler('matrix:server:reportWeaponShotFired', function(weaponItemName, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return end

    local rec = GetOrCreateTelemetry(citizenid)
    if not rec then return end

    TouchActiveHours(rec)
    rec.aggression_index = Ema(rec.aggression_index, 1.0)
    rec.escape_pattern    = Ema(rec.escape_pattern, math_max(rec.escape_pattern - 0.05, 0.0))

    DirtyTelemetry[citizenid] = true
end)

AddEventHandler('playerDropped', function()
    local src = source
    local citizenid = Matrix.PlayerSourceIndex and Matrix.PlayerSourceIndex[src]
    if citizenid and Telemetry[citizenid] then
        DirtyTelemetry[citizenid] = true
    end
end)

-- =====================================================================
-- WRITE-BEHIND: 15sn'de bir kirli kayitlari toplu flush eder
-- (server/market.lua FlushDirtyMarketZones ile AYNI transaction deseni).
-- =====================================================================
local function EncodeActiveHours(activeHours)
    local parts = {}
    for i = 0, 167 do
        parts[#parts + 1] = tostring(activeHours[i] or 0)
    end
    return table.concat(parts, ',')
end

local function FlushDirtyTelemetry()
    local pending = {}
    for citizenid in pairs(DirtyTelemetry) do
        pending[#pending + 1] = citizenid
    end
    if #pending == 0 then return end

    local queries = {}
    for _, citizenid in ipairs(pending) do
        local rec = Telemetry[citizenid]
        if rec then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_player_telemetry
                        (citizenid, active_hours, preferred_zone, aggression_index,
                         escape_pattern, spend_rate, death_frequency, trade_balance, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        active_hours     = VALUES(active_hours),
                        preferred_zone   = VALUES(preferred_zone),
                        aggression_index = VALUES(aggression_index),
                        escape_pattern   = VALUES(escape_pattern),
                        spend_rate       = VALUES(spend_rate),
                        death_frequency  = VALUES(death_frequency),
                        trade_balance    = VALUES(trade_balance),
                        updated_at       = NOW()
                ]],
                values = {
                    citizenid, EncodeActiveHours(rec.active_hours), rec.preferred_zone,
                    rec.aggression_index, rec.escape_pattern, rec.spend_rate,
                    rec.death_frequency, rec.trade_balance
                }
            }
        end
    end

    if #queries == 0 then
        for _, citizenid in ipairs(pending) do DirtyTelemetry[citizenid] = nil end
        return
    end

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, citizenid in ipairs(pending) do DirtyTelemetry[citizenid] = nil end
    else
        Matrix.Log('TELEMETRY',
            '[HATA][KRITIK] FlushDirtyTelemetry transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end

CreateThread(function()
    while true do
        Wait(15000)
        local ok, err = pcall(FlushDirtyTelemetry)
        if not ok then
            Matrix.Log('TELEMETRY', '[HATA] FlushDirtyTelemetry hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

-- =====================================================================
-- /matrix_telemetrydurum [citizenid] -- operatör komutu
-- (server/main.lua botkilitac/operatiftasfiye ile AYNI yetki deseni:
-- Matrix.Hierarchy.HasCommandAuthority)
-- =====================================================================
RegisterCommand('matrix_telemetrydurum', function(src, args)
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end

    local citizenid = args[1]
    if not citizenid or citizenid == '' then
        local st = Matrix.GetOrCreatePlayerState(src)
        citizenid = st and st.citizenid
    end
    if not citizenid then
        Reply(src, 'Kullanim: /matrix_telemetrydurum [citizenid]'); return
    end

    local rec = Telemetry[citizenid]
    if not rec then
        Reply(src, ('%s icin telemetri kaydi yok.'):format(citizenid)); return
    end

    local profile = ComputeProfile(rec)
    Reply(src, ('[%s] agresyon=%.3f kacis-orunutusu=%.3f harcama-orani=%.3f olum-sikligi=%.3f ticaret-dengesi=%.3f tercih-bolge=%s | PROFIL=%s'):format(
        citizenid, rec.aggression_index, rec.escape_pattern, rec.spend_rate,
        rec.death_frequency, rec.trade_balance, tostring(rec.preferred_zone or '-'), profile))
end, false)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('GetTelemetryProfile', function(citizenid) return Matrix.PlayerTelemetry.GetProfile(citizenid) end)
exports('GetTelemetryRecord',  function(citizenid) return Matrix.PlayerTelemetry.GetRecord(citizenid) end)
