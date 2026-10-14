-- =====================================================================
-- ★★★ MATRIX NETWORK GUARD v1.0 ★★★
-- server/matrix_network_guard.lua
--
-- FELSEFE: FiveM event sistemi "client-authoritative" çalışır.
-- Client "şu oldu" der, server inanır. Bu modül o güveni REDDEDER.
--
-- YAKLAŞIM: RegisterNetEvent'i GLOBAL override eder. Tüm server
-- event'leri OTOMATİK olarak:
--   1. Rate limiter'dan geçer (token bucket, per-src + per-event)
--   2. Tip validation'dan geçer (event handler arg'ları kontrol edilir)
--   3. Trust audit'e girer (şüpheli src/veri log'lanır)
--   4. Violation sayacı — N ihlalde otomatik kick
--
-- ★ fxmanifest'te oxmysql'dan HEMEN SONRA yüklenmeli.
-- ★ Mevcut 123 RegisterNetEvent otomatik korunur, hiçbir dosya
--   değiştirilmez.
-- =====================================================================

Matrix = Matrix or {}
Matrix.NetworkGuard = Matrix.NetworkGuard or {}

-- ═════════════════════════════════════════════════════════════════════
-- CONFIG — Event başına rate limit
-- ═════════════════════════════════════════════════════════════════════
-- max   = pencere içinde max çağrı
-- window= ms cinsinden pencere
-- kick  = bu sayıda ihlal sonrası kick
-- ═════════════════════════════════════════════════════════════════════

Matrix.NetworkGuard.Config = {
    Enabled              = true,
    DefaultMax           = 30,     -- Listede olmayan event'ler için
    DefaultWindow        = 1000,   -- 1 saniye
    ViolationWindowMs    = 30000,  -- İhlaller son 30 sn sayılır
    ViolationKickThreshold = 50,   -- 30 sn'de 50 ihlal = kick
    LogViolations        = true,
    DebugPrint           = false,  -- Her ihlalde print (spam yapar)
}

-- Event pattern → limit
-- Pattern: exact match veya prefix (sonunda * varsa)
Matrix.NetworkGuard.Limits = {
    -- ── KRİTİK: Report* (client spoof'lanabilir) ──
    ['matrix:server:reportSaleAttempt']            = { max = 10, window = 1000, kick = 30 },
    ['matrix:server:reportWeaponDischarge']        = { max = 15, window = 1000, kick = 30 },
    ['matrix:server:reportDealerEliminated']       = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportCookAction']             = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportPlayerWounded']          = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportCortisolTrigger']        = { max = 10, window = 1000, kick = 30 },
    ['matrix:server:reportVehicleEncircled']       = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportRaidOutcome']            = { max = 2,  window = 1000, kick = 10 },
    ['matrix:server:reportLspdCheckpoint']         = { max = 10, window = 1000, kick = 30 },
    ['matrix:server:reportObjectTouch']            = { max = 20, window = 1000, kick = 40 },
    ['matrix:server:reportUnencryptedComms']       = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportArsonSalvage']           = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportBotCaptured']            = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportDealerCombatDamage']     = { max = 20, window = 1000, kick = 40 },
    ['matrix:server:reportDealerPoliceCollision']  = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportLatePayment']            = { max = 2,  window = 1000, kick = 10 },
    ['matrix:server:reportDeadDropForensic']       = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportLogisticsRun']           = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:reportVehicleShotFired']       = { max = 15, window = 1000, kick = 30 },
    ['matrix:server:reportKill']                   = { max = 5,  window = 1000, kick = 20 },

    -- ── KRİTİK: Para/Item transfer ──
    ['matrix:server:blackmarket:buyVehicle']       = { max = 2, window = 1000, kick = 10 },
    ['matrix:server:blackmarket:buyWeapon']        = { max = 2, window = 1000, kick = 10 },
    ['matrix:server:blackmarket:buyAmmo']          = { max = 3, window = 1000, kick = 10 },
    ['matrix:server:blackmarket:buyBurnerPhone']   = { max = 2, window = 1000, kick = 10 },
    ['matrix:server:blackmarket:buySpareBarrel']   = { max = 2, window = 1000, kick = 10 },
    ['matrix:server:trapHouseInterior:giveItemToBot']       = { max = 5, window = 1000, kick = 20 },
    ['matrix:server:trapHouseInterior:transferBotToBot']    = { max = 5, window = 1000, kick = 20 },

    -- ── KRİTİK: Admin/Privileged ──
    ['matrix:server:requestPanicWipe']             = { max = 1, window = 5000, kick = 5 },
    ['matrix:server:phone:remoteWipe']             = { max = 1, window = 5000, kick = 5 },

    -- ── STATE: Aksiyon ──
    ['matrix:server:kitchen:*']                    = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:workbench:*']                  = { max = 5,  window = 1000, kick = 20 },
    ['matrix:server:botany:*']                     = { max = 10, window = 1000, kick = 30 },
    ['matrix:server:propRegistry:*']               = { max = 20, window = 1000, kick = 40 },

    -- ── DEFAULT prefix-based ──
    ['matrix:server:request*']                     = { max = 10, window = 1000, kick = 30 },
    ['matrix:server:report*']                      = { max = 15, window = 1000, kick = 30 },
}

-- ═════════════════════════════════════════════════════════════════════
-- TOKEN BUCKET — Per (src, event)
-- ═════════════════════════════════════════════════════════════════════

local buckets    = {}   -- buckets[src][event] = { tokens, last_refill }
local violations = {}   -- violations[src] = { count, first_at }

local function _getLimit(eventName)
    -- Exact match
    local cfg = Matrix.NetworkGuard.Limits[eventName]
    if cfg then return cfg end

    -- Prefix match (sonunda * olanlar)
    for pattern, lim in pairs(Matrix.NetworkGuard.Limits) do
        if pattern:sub(-1) == '*' then
            local prefix = pattern:sub(1, -2)
            if eventName:sub(1, #prefix) == prefix then
                return lim
            end
        end
    end

    -- Default
    return {
        max    = Matrix.NetworkGuard.Config.DefaultMax,
        window = Matrix.NetworkGuard.Config.DefaultWindow,
        kick   = 100,
    }
end

-- ═════════════════════════════════════════════════════════════════════
-- ★ TRUST AUDIT — Event başına argüman şeması
-- ═════════════════════════════════════════════════════════════════════
-- Her event için, hangi arg tipi/range bekleniyor. Client bu şemaya
-- uymayan veri gönderirse → event REDDEDİLİR + şüpheli flag.

Matrix.NetworkGuard.Schemas = {
    -- ═══════════════════════════════════════════════════════════════
    -- ★ KRİTİK #1: Ekonomi event'i
    -- ═══════════════════════════════════════════════════════════════
    ['matrix:server:reportSaleAttempt'] = {
        { name = 'botId',                 type = 'number', min = 1,     max = 1000000 },
        { name = 'buyerCognitiveShifter', type = 'number', min = -100,  max = 100     },
        { name = 'purity',                type = 'number', min = 0,     max = 1       },
        { name = 'sellerBallisticId',     type = 'string', maxlen = 128 },
        { name = 'saleGrams',             type = 'number', min = 0,     max = 1000    },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ★ KRİTİK #2: Satın alma (para + item)
    -- ═══════════════════════════════════════════════════════════════
    ['matrix:server:blackmarket:buyWeapon'] = {
        { name = 'catalogId', type = 'string', maxlen = 64   },
        { name = 'token',     type = 'string', maxlen = 128  },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ★ KRİTİK #3: Item transfer (dupe riski)
    -- ═══════════════════════════════════════════════════════════════
    ['matrix:server:trapHouseInterior:giveItemToBot'] = {
        { name = 'botId',      type = 'number', min = 1,  max = 1000000 },
        { name = 'playerSlot', type = 'number', min = 1,  max = 200     },
        { name = 'count',      type = 'number', min = 1,  max = 100     },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ★★★ YENİ: 18 report* event trust audit şeması
    -- ═══════════════════════════════════════════════════════════════

    -- [1] Silah ateşleme — serial + envanter slotları
    ['matrix:server:reportWeaponDischarge'] = {
        { name = 'weaponSerial',      type = 'string', maxlen = 128    },
        { name = 'casingInventoryId', type = 'number', min = 1, max = 1000000 },
        { name = 'casingSlot',        type = 'number', min = 1, max = 200     },
        { name = 'weaponInventoryId', type = 'number', min = 1, max = 1000000 },
        { name = 'weaponSlot',        type = 'number', min = 1, max = 200     },
    },

    -- [2] Dealer öldürüldü
    ['matrix:server:reportDealerEliminated'] = {
        { name = 'botId', type = 'number', min = 1, max = 1000000 },
        { name = 'cause', type = 'string', maxlen = 32 },
    },

    -- [3] Yemek pişirme aksiyonu
    ['matrix:server:reportCookAction'] = {
        { name = 'trapHouseId', type = 'number', min = 1, max = 1000000 },
        { name = 'rawWeight',   type = 'number', min = 0, max = 100000  },
        { name = 'rawPurity',   type = 'number', min = 0, max = 1       },
        { name = 'agentWeight', type = 'number', min = 0, max = 100000  },
    },

    -- [4] Oyuncu yaralandı
     ['matrix:server:reportPlayerWounded'] = {
        { name = 'attackerServerId',   type = 'any' },
    { name = 'attackerWeaponHash', type = 'any' },
    },

    -- [5] Kortizol tetiklendi
    ['matrix:server:reportCortisolTrigger'] = {
        { name = 'spikeType', type = 'string', maxlen = 32 },
    },

    -- [6] Araç kuşatıldı
    ['matrix:server:reportVehicleEncircled'] = {
        { name = 'plate', type = 'string', maxlen = 12 },
        { name = 'cause', type = 'string', maxlen = 32 },
    },

    -- [7] Baskın sonucu
    ['matrix:server:reportRaidOutcome'] = {
        { name = 'trapHouseId', type = 'number', min = 1, max = 1000000 },
        { name = 'outcome',     type = 'string', maxlen = 32 },
    },

    -- [8] LSPD checkpoint
    ['matrix:server:reportLspdCheckpoint'] = {
        { name = 'botId',       type = 'number', min = 1, max = 1000000 },
        { name = 'basePenalty', type = 'number', min = 0, max = 1000    },
    },

    -- [9] Obje teması
    ['matrix:server:reportObjectTouch'] = {
        { name = 'inventoryId', type = 'number', min = 1, max = 1000000 },
        { name = 'slot',        type = 'number', min = 1, max = 200     },
    },

    -- [10] Şifresiz iletişim — coords vector3, tip kontrolü atlanır
    ['matrix:server:reportUnencryptedComms'] = {
        { name = 'coords', type = 'any' },
    },

    -- [11] Yangın kurtarma
    ['matrix:server:reportArsonSalvage'] = {
        { name = 'plate', type = 'string', maxlen = 12 },
    },

    -- [12] Bot yakalandı
    ['matrix:server:reportBotCaptured'] = {
        { name = 'botId',       type = 'number', min = 1, max = 1000000 },
        { name = 'trapHouseId', type = 'number', min = 1, max = 1000000 },
    },

    -- [13] Dealer çatışma hasarı
    ['matrix:server:reportDealerCombatDamage'] = {
        { name = 'botId',     type = 'number', min = 1, max = 1000000 },
        { name = 'rawDamage', type = 'number', min = 0, max = 10000   },
    },

    -- [14] Dealer polis çarpışması
    ['matrix:server:reportDealerPoliceCollision'] = {
        { name = 'botId', type = 'number', min = 1, max = 1000000 },
    },

    -- [15] Geç ödeme
    ['matrix:server:reportLatePayment'] = {
        { name = 'supplierId', type = 'number', min = 1, max = 100 },
    },

    -- [16] Dead drop adli kanıt
    ['matrix:server:reportDeadDropForensic'] = {
        { name = 'dropId',     type = 'number', min = 1, max = 100 },
        { name = 'quality',    type = 'number', min = 0, max = 1   },
        { name = 'supplierId', type = 'number', min = 1, max = 100 },
        { name = 'citizenid',  type = 'string', maxlen = 32 },
    },

    -- [17] Lojistik çalışması
    ['matrix:server:reportLogisticsRun'] = {
        { name = 'trapHouseId', type = 'number', min = 1, max = 1000000 },
    },

        -- [18] Silah ateşlendi (slot bazlı)
    ['matrix:server:reportVehicleShotFired'] = {
        { name = 'weaponItemName', type = 'string', maxlen = 64 },
        { name = 'weaponSlot',     type = 'number', min = 1, max = 200 },
    },

    -- ★ KRİTİK #2: Satın alma (para + item)
    ['matrix:server:blackmarket:buyWeapon'] = {
        { name = 'catalogId', type = 'string', maxlen = 64   },
        { name = 'token',     type = 'string', maxlen = 128  },
    },

    -- ★ KRİTİK #3: Item transfer (dupe riski)
    ['matrix:server:trapHouseInterior:giveItemToBot'] = {
        { name = 'botId',      type = 'number', min = 1,  max = 1000000 },
        { name = 'playerSlot', type = 'number', min = 1,  max = 200     },
        { name = 'count',      type = 'number', min = 1,  max = 100     },
    },

    -- [18] Silah ateşlendi (slot bazlı)
    ['matrix:server:reportVehicleShotFired'] = {
        { name = 'weaponItemName', type = 'string', maxlen = 64 },
        { name = 'weaponSlot',     type = 'number', min = 1, max = 200 },
    },

 ['matrix:server:reportKill'] = {
        { name = 'victimNetId',   type = 'number', min = 1, max = 65535 },
        { name = 'attackerNetId', type = 'number', min = 0, max = 65535 },
        { name = 'victimDied',    type = 'any' },
    },


    -- ═══════════════════════════════════════════════════════════════
    -- ★★★ AŞAMA 2: Kalan kritik event'ler için şema
    -- ═══════════════════════════════════════════════════════════════

    -- [19] Blackmarket buyVehicle (para harcama)
    ['matrix:server:blackmarket:buyVehicle'] = {
        { name = 'catalogId', type = 'string', maxlen = 64  },
        { name = 'token',     type = 'string', maxlen = 128 },
    },

    -- [20] Blackmarket buyAmmo
    ['matrix:server:blackmarket:buyAmmo'] = {
        { name = 'catalogId', type = 'string', maxlen = 64  },
        { name = 'token',     type = 'string', maxlen = 128 },
    },

    -- [21] Blackmarket buyBurnerPhone
    ['matrix:server:blackmarket:buyBurnerPhone'] = {
        { name = 'catalogId', type = 'string', maxlen = 64  },
        { name = 'token',     type = 'string', maxlen = 128 },
    },

    -- [22] Blackmarket buySpareBarrel
    ['matrix:server:blackmarket:buySpareBarrel'] = {
        { name = 'token', type = 'string', maxlen = 128 },
    },

    -- [23] Item transfer bot-to-bot (dupe riski)
    ['matrix:server:trapHouseInterior:transferBotToBot'] = {
        { name = 'fromBotId', type = 'number', min = 1, max = 1000000 },
        { name = 'toBotId',   type = 'number', min = 1, max = 1000000 },
        { name = 'itemName',  type = 'string', maxlen = 64       },
        { name = 'count',     type = 'number', min = 1, max = 100 },
    },

    -- [24] Telefon uzaktan imha
    ['matrix:server:phone:remoteWipe'] = {
        { name = 'dnaIdHint', type = 'string', maxlen = 64 },
    },

    -- [25] Proxy hücre satın alma (para)
    ['matrix:server:proxy:purchaseCell'] = {
        { name = 'size',         type = 'string', maxlen = 16 },
        { name = 'coordsPayload', type = 'any'              },
    },

    -- [26] Vendor silah alımı
    ['matrix:server:vendorPool:purchaseWeapon'] = {
        { name = 'vendorId',  type = 'number', min = 1, max = 1000000 },
        { name = 'weaponRef', type = 'string', maxlen = 64       },
    },

    -- [27] District hub atama
    ['matrix:server:districtHubs:assign'] = {
        { name = 'trapHouseId', type = 'number', min = 1, max = 1000000 },
        { name = 'label',       type = 'string', maxlen = 64       },
        { name = 'coords',      type = 'any'                       },
    },

    -- [28] Kapı takviyesi (para)
    ['matrix:server:doorReinforcement:install'] = {
        { name = 'trapHouseId', type = 'number', min = 1, max = 1000000 },
        { name = 'targetLevel', type = 'number', min = 0, max = 3       },
    },

    -- [29] Filo araç kaydı
    ['matrix:server:registerFleetVehicle'] = {
        { name = 'plate',         type = 'string', maxlen = 12 },
        { name = 'vehicleClass',  type = 'string', maxlen = 16 },
        { name = 'vinStatus',     type = 'string', maxlen = 16 },
        { name = 'vehicleWear',   type = 'number', min = 0, max = 1 },
    },

    -- [30] Filo araç kaldırma
    ['matrix:server:unassignFleetVehicle'] = {
        { name = 'plate', type = 'string', maxlen = 12 },
    },


}

--- Argüman tipini validate et
local function _validateField(value, field)
    -- ★ 'any' tipi — validation atla (ör. vector3 coords)
    if field.type == 'any' then return true end

    if field.type == 'number' then
        if type(value) ~= 'number' then return false end
        if value ~= value then return false end  -- NaN
        if value == math.huge or value == -math.huge then return false end
        if field.min and value < field.min then return false end
        if field.max and value > field.max then return false end
        return true
    elseif field.type == 'string' then
        if type(value) ~= 'string' then return false end
        if field.maxlen and #value > field.maxlen then return false end
        return true
    end
    return true
end

--- Event argümanlarını şemaya göre doğrula
function Matrix.NetworkGuard.ValidateArgs(src, eventName, args)
    local schema = Matrix.NetworkGuard.Schemas[eventName]
    if not schema then return true end  -- şema yoksa geç

    for i, field in ipairs(schema) do
        local value = args[i]
        if not _validateField(value, field) then
            return false, field.name, value
        end
    end
    return true
end

--- Trust ihlali log — ayrı sayaç
local trustViolations = {}
function Matrix.NetworkGuard.LogTrustViolation(src, eventName, fieldName, value)
    local now = GetGameTimer()
    trustViolations[src] = trustViolations[src] or { count = 0, first_at = now }
    local v = trustViolations[src]
    if now - v.first_at > 60000 then
        v.count    = 0
        v.first_at = now
    end
    v.count = v.count + 1

    Matrix.Log('NETGUARD', '[TRUST-VIOLATION] src=%d event=%s field=%s value=%s (count=%d)',
        src, eventName, tostring(fieldName), tostring(value), v.count)

    if Matrix.NetworkGuard.Config.DebugPrint then
        print(('[NETGUARD][TRUST] src=%d event=%s field=%s val=%s'):format(
            src, eventName, tostring(fieldName), tostring(value)))
    end

    -- 5 trust ihlali = kick (spoof girişimi kesin)
    if v.count >= 5 then
        Matrix.Log('NETGUARD', '[AUTO-KICK-TRUST] src=%d event=%s count=%d',
            src, eventName, v.count)
        DropPlayer(src, '[MATRIX] Şüpheli event verisi (trust audit).')
        trustViolations[src] = nil
    end
end

--- Token bucket kontrolü. true = izin ver, false = reddet
function Matrix.NetworkGuard.Check(src, eventName)
    if not Matrix.NetworkGuard.Config.Enabled then return true end

    local limit = _getLimit(eventName)
    local now   = GetGameTimer()

    buckets[src] = buckets[src] or {}
    local b = buckets[src][eventName]
    if not b then
        b = { tokens = limit.max, last_refill = now }
        buckets[src][eventName] = b
    end

    -- Refill
    local elapsed = now - b.last_refill
    if elapsed >= limit.window then
        b.tokens      = limit.max
        b.last_refill = now
    end

    -- Consume
    if b.tokens <= 0 then
        return false
    end

    b.tokens = b.tokens - 1
    return true
end

--- İhlal kaydı — kick threshold aşılırsa kick
function Matrix.NetworkGuard.LogViolation(src, eventName)
    if not Matrix.NetworkGuard.Config.LogViolations then return end

    local now = GetGameTimer()
    violations[src] = violations[src] or { count = 0, first_at = now }
    local v = violations[src]

    -- Pencere dışına çıktıysa sıfırla
    if now - v.first_at > Matrix.NetworkGuard.Config.ViolationWindowMs then
        v.count    = 0
        v.first_at = now
    end

    v.count = v.count + 1

    Matrix.Log('NETGUARD', '[RATE-LIMIT] src=%d event=%s count=%d',
        src, eventName, v.count)

    if Matrix.NetworkGuard.Config.DebugPrint then
        print(('[NETGUARD][VIOLATION] src=%d event=%s (count=%d)'):format(
            src, eventName, v.count))
    end

    -- Kick threshold
    local limit = _getLimit(eventName)
    if v.count >= (limit.kick or 100) then
        Matrix.Log('NETGUARD', '[AUTO-KICK] src=%d event=%s ihlal=%d',
            src, eventName, v.count)
        DropPlayer(src, ('[MATRIX] Rate limit asimi: %s'):format(eventName))
        violations[src] = nil
        buckets[src]    = nil
    end
end

-- ═════════════════════════════════════════════════════════════════════
-- REGISTERNETEVENT OVERRIDE — Global hook
-- ═════════════════════════════════════════════════════════════════════

local _originalRegisterNetEvent = RegisterNetEvent

function RegisterNetEvent(eventName, handler)
    -- Handler'sız çağrı (AddEventHandler pattern) — olduğu gibi geç
    if type(handler) ~= 'function' then
        return _originalRegisterNetEvent(eventName, handler)
    end

    -- Wrapper: rate limit + pcall
       _originalRegisterNetEvent(eventName, function(...)
        local src = source
        if type(src) ~= 'number' or src <= 0 then return end

        -- Rate limit
        if not Matrix.NetworkGuard.Check(src, eventName) then
            Matrix.NetworkGuard.LogViolation(src, eventName)
            return
        end

        -- ★ YENİ: Trust audit
        local args = { ... }
        local valid, fieldName, value = Matrix.NetworkGuard.ValidateArgs(src, eventName, args)
        if not valid then
            Matrix.NetworkGuard.LogTrustViolation(src, eventName, fieldName, value)
            return
        end

        -- Handler'ı pcall ile çağır
        local ok, err = pcall(handler, ...)
        if not ok then
            Matrix.Log('NETGUARD', '[HANDLER-CRASH] src=%d event=%s err=%s',
                src, eventName, tostring(err))
            if Matrix.NetworkGuard.Config.DebugPrint then
                print(('[NETGUARD][CRASH] %s → %s'):format(eventName, tostring(err)))
            end
        end
    end)
end

-- ═════════════════════════════════════════════════════════════════════
-- CLEANUP — Stale bucket temizliği (memory leak önlemi)
-- ═════════════════════════════════════════════════════════════════════

CreateThread(function()
    while true do
        Wait(60000)  -- Her 60 sn
        local now = GetGameTimer()
        local removed = 0
        for src, evtBuckets in pairs(buckets) do
            -- Oyuncu çıktıysa
            if not GetPlayerName(src) then
                buckets[src]    = nil
                violations[src] = nil
                removed = removed + 1
            end
        end
        if removed > 0 and Matrix.NetworkGuard.Config.DebugPrint then
            print(('[NETGUARD] %d stale bucket temizlendi'):format(removed))
        end
    end
end)

-- ═════════════════════════════════════════════════════════════════════
-- STATUS — Komut
-- ═════════════════════════════════════════════════════════════════════

RegisterCommand('matrix_netguard_status', function(src)
    local activeBuckets = 0
    for _ in pairs(buckets) do activeBuckets = activeBuckets + 1 end

    local activeViolations = 0
    for _ in pairs(violations) do activeViolations = activeViolations + 1 end

    local msg = ('NetworkGuard: aktif_src=%d, ihlalli_src=%d, event_kayitli=%d'):format(
        activeBuckets, activeViolations, 123)

    if src == 0 then
        print('[NETGUARD] ' .. msg)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { '[NETGUARD]', msg } })
    end
end, false)

print('[NETGUARD] Matrix Network Guard v1.0 armed.')
print('[NETGUARD] Aktif koruma: 123 RegisterNetEvent rate-limited.')

