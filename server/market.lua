-- =====================================================================
-- MATRIX MARKET / server/market.lua  (KATMAN 6 — MÜHÜRLÜ SÜRÜM)
--
-- ★ KATMAN 5 v1 SERTLEŞTİRME (korunuyor):
--   [M1] FormatCortisolThreshold / FormatFatigueThreshold artık
--        `tonumber() or 0.0` yeterli değil — NaN ve ±inf değerler
--        KARŞILAŞTIRMA MATRİSİNE SOKULMADAN önce açıkça filtrelenir.
--        (Lua'da NaN tüm karşılaştırmalarda false döner; inf ise sessizce
--        "else" dalına düşerdi. Her iki davranış da deterministik ama
--        AÇIKÇA ifade edilmesi gerekir — çökme yok, ama "hangi metin çıkar"
--        belirsizliği de ortadan kalktı.)
--   [M2] BuildSnapshot artık tüm sayısal alanları (cortisol, fatigue,
--        heat, decryption_confidence) HUD'a push etmeden ÖNCE
--        Matrix.Clamp'ten geçirir. Master ticker'ın ürettiği hiçbir
--        NaN/inf, client DrawText katmanına ulaşamaz.
--   [M3] PushSnapshots içindeki TriggerClientEvent yalnızca pcall BAŞARILI
--        ise çağrılır (mevcut davranış), ekstra olarak snapshot tipi
--        kontrol edilir.
--
-- ★ KATMAN 5 ULTIMATE (korunuyor):
--   [U4] SIGINT — Bölge Denetleyicileri (Inspectors), [U5] COMINT, [U6]
--        Bölgesel Mali Rapor, [U8] ACİL TAHLİYE bülteni. Hiçbiri DEĞİŞMEDİ.
--
-- ★ KATMAN 6 (bu sürüm — yeni): [K6] BuildSnapshot'a iki YENİ guard'lı
--   satır bloğu eklendi:
--     - Matrix.Rendezvous.GetAmbushBulletin(src)      (server/rendezvous.lua)
--     - Matrix.DoorReinforcement.GetBreachCountdownText(src) (server/door_reinforcement.lua)
--   Her ikisi de bu dosyanın HİÇBİR MEVCUT formülüne dokunmaz; modüller
--   yüklü değilse guard'lar nil döner ve blok HİÇ eklenmez (davranış
--   ESKİSİYLE BİREBİR AYNI kalır). Format: Sıfır Sayı Standardı —
--   yalnızca hazır metin + danger bayrağı, çiğ sayı YOK.
-- =====================================================================


Matrix.Hierarchy    = Matrix.Hierarchy    or {}
Matrix.Market        = Matrix.Market        or {}
Matrix.RadioSilence  = Matrix.RadioSilence  or {}
Matrix.CashDecay     = Matrix.CashDecay     or {}
Matrix.Undercover    = Matrix.Undercover    or {}
Matrix.Inspector     = Matrix.Inspector     or {}
Matrix.Comint        = Matrix.Comint        or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local math_max, math_min, math_huge = math.max, math.min, math.huge
local math_floor                    = math.floor


local CreateThread       = CreateThread
local Wait                = Wait
local RegisterCommand     = RegisterCommand
local RegisterNetEvent    = RegisterNetEvent
local TriggerClientEvent  = TriggerClientEvent


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[MARKET]', msg } })
    else
        print(('[MATRIX:MARKET:CONSOLE] %s'):format(msg))
    end
end


-- =====================================================================
-- 1) CO-OP KARTEL HİYERARŞİSİ
-- =====================================================================
local HierarchyRanks = {}   -- citizenid -> { rank, assigned_by }


function Matrix.Hierarchy.LoadHierarchy()
    local callOk = pcall(function()
        MySQL.query('SELECT citizenid, rank, assigned_by FROM matrix_hierarchy', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.citizenid and Config.Hierarchy.Ranks[row.rank] then
                            HierarchyRanks[row.citizenid] = { rank = row.rank, assigned_by = row.assigned_by }
                        end
                    end
                    Matrix.Log('MARKET', '%d co-op rutbe atamasi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_hierarchy sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


CreateThread(function()
    Matrix.Hierarchy.LoadHierarchy()
end)


function Matrix.Hierarchy.GetRank(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    local rec = HierarchyRanks[citizenid]
    return rec and rec.rank or nil
end


function Matrix.Hierarchy.HasCommandAuthority(citizenid)
    local rank = Matrix.Hierarchy.GetRank(citizenid)
    if not rank then return false end
    local rankCfg = Config.Hierarchy.Ranks[rank]
    if not rankCfg then return false end
    return rankCfg.level >= Config.Hierarchy.MinRankLevelForCommand
end


function Matrix.Hierarchy.SetRank(citizenid, rank, assignedBy)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'bad_citizenid' end
    if not Config.Hierarchy.Ranks[rank] then return false, 'bad_rank' end

    -- ★ v6.6.4-A2d: Yetki kapısı (fail-closed).
    -- Bootstrap: assignedBy 'console' / nil / '' → izinli (ilk Leader'ı
    -- console veya DB seed atar). Aksi halde atayan LEADER olmalı.
    -- Bu kapı olmadan herhangi bir oyuncu `/rutbeata <kendisi> Leader`
    -- ile tüm Hierarchy kilitlerini atlayabiliyordu.
    if assignedBy ~= nil and assignedBy ~= '' and assignedBy ~= 'console' then
        local assigner = HierarchyRanks[assignedBy]
        if not assigner or assigner.rank ~= 'Leader' then
            Matrix.Log('MARKET',
                '[YETKI RED] %s -> %s atamasi reddedildi (atayan Leader degil: %s).',
                tostring(assignedBy), tostring(citizenid), tostring(rank))
            return false, 'insufficient_authority'
        end
    end


    HierarchyRanks[citizenid] = { rank = rank, assigned_by = assignedBy }


    MySQL.prepare([[
        INSERT INTO matrix_hierarchy (citizenid, rank, assigned_by, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE rank = VALUES(rank), assigned_by = VALUES(assigned_by), updated_at = NOW()
    ]], { citizenid, rank, assignedBy })


    Matrix.Log('MARKET', 'Rutbe atandi: %s -> %s (atayan: %s)', citizenid, rank, tostring(assignedBy))
    return true
end


local function ResolveTargetCitizenidWithRetry(targetSrc)
    for attempt = 1, 3 do
        local state = Matrix.GetOrCreatePlayerState(targetSrc)
        if state and state.citizenid then return state.citizenid end
        if attempt < 3 then Wait(300) end
    end
    return nil
end


RegisterCommand('rutbeata', function(src, args)
    -- ★ v6.6.4-A2d: fail-closed. Konsol (src=0) serbest; oyuncu yetkili olmali.
    -- BOOTSTRAP: ilk Leader bu komutla ATANAMAZ (kendi kendini Leader yapma
    -- acigi kapatildi). Ilk Leader'i DB seed ile atayin:
    --   INSERT INTO matrix_hierarchy (citizenid, rank, assigned_by, created_at, updated_at)
    --   VALUES ('senin_citizenid', 'Leader', 'console', NOW(), NOW());
    if type(src) == 'number' and src > 0 then
        local _s = Matrix.GetOrCreatePlayerState(src)
        if not _s or not _s.citizenid then
            Reply(src, 'Oyuncu cozulemedi.'); return
        end
        if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then
            Reply(src, 'Yetkisiz.'); return
        end
        if not Matrix.Hierarchy.HasCommandAuthority(_s.citizenid) then
            Reply(src, 'Bu atamayi yapmak icin yetkiniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end

    local targetSrc = tonumber(args[1])
    local rank = args[2]
    if not targetSrc or not rank then
        Reply(src, 'Kullanim: /rutbeata [targetSrc] [Leader|Logistics_Officer|Chemist]'); return
    end


    local targetCitizenid = ResolveTargetCitizenidWithRetry(targetSrc)
    if not targetCitizenid then
        Reply(src, 'Hedef oyuncu bulunamadi (3 deneme sonrasi da cozulemedi; oyuncu hala yukleniyor olabilir, birkac saniye sonra tekrar deneyin).'); return
    end


    local assignerState = Matrix.GetOrCreatePlayerState(src)
    -- Konsol çağrısı için 'console' sentinel; oyuncu için gerçek citizenid.
    -- assignerState nil ise fail-closed: 'console' YERINE nil gönderip
    -- SetRank'ın fail-open dalına DÜŞMEYİZ.
    local assignerCitizenid
    if type(src) == 'number' and src > 0 then
        assignerCitizenid = assignerState and assignerState.citizenid or nil
        if not assignerCitizenid then
            Reply(src, 'Atayan kimlik cozulemedi.'); return
        end
    else
        assignerCitizenid = 'console'
    end

    local ok, reason = Matrix.Hierarchy.SetRank(targetCitizenid, rank, assignerCitizenid)
    if ok then
        Reply(src, ('%s rutbesi %s olarak ayarlandi.'):format(targetCitizenid, rank))
    elseif reason == 'bad_rank' then
        Reply(src, 'Gecersiz rutbe: Leader, Logistics_Officer veya Chemist olmali.')
    elseif reason == 'insufficient_authority' then
        Reply(src, 'Bu rutbeyi atamak icin Leader yetkisi gerekir (self-promotion yasak).')
    else
        Reply(src, ('Rutbe atamasi basarisiz: %s'):format(tostring(reason)))
    end
end, false)

RegisterCommand('rutbemgoster', function(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local rank = Matrix.Hierarchy.GetRank(state.citizenid)
    if not rank then
        Reply(src, 'Hiyerarside kayitli degilsiniz (komuta yetkiniz yok).')
    else
        Reply(src, ('Rutbeniz: %s (%s) | Komuta yetkisi: %s'):format(
            rank, Config.Hierarchy.Ranks[rank].label, tostring(Matrix.Hierarchy.HasCommandAuthority(state.citizenid))))
    end
end, false)


-- =====================================================================
-- 2) BÖLGESEL MADDE PİYASASI & GURME MÜŞTERİ REAKSİYONU
-- =====================================================================
local MarketZones      = {}
local dirtyMarketZones = {}


function Matrix.Market.LoadMarketZones()
    local callOk = pcall(function()
        MySQL.query('SELECT * FROM matrix_market_zones', {}, function(rows)
            pcall(function()
                local loaded = {}
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        loaded[row.zone_id] = true
                        MarketZones[row.zone_id] = {
                            zone_id          = row.zone_id,
                            price_multiplier = tonumber(row.price_multiplier) or Config.Market.PriceMultiplierDefault,
                            rejected_streak  = tonumber(row.rejected_streak) or 0
                        }
                    end
                end
                for _, zoneCfg in ipairs(Config.Market.Zones) do
                    if not loaded[zoneCfg.id] then
                        MarketZones[zoneCfg.id] = {
                            zone_id          = zoneCfg.id,
                            price_multiplier = Config.Market.PriceMultiplierDefault,
                            rejected_streak  = 0
                        }
                        dirtyMarketZones[zoneCfg.id] = true
                    end
                end
                Matrix.Log('MARKET', '%d bolgesel piyasa kaydi yuklendi.', type(rows) == 'table' and #rows or 0)
            end)
        end)
    end)
    if not callOk then
        for _, zoneCfg in ipairs(Config.Market.Zones) do
            MarketZones[zoneCfg.id] = MarketZones[zoneCfg.id] or {
                zone_id = zoneCfg.id, price_multiplier = Config.Market.PriceMultiplierDefault, rejected_streak = 0
            }
        end
        Matrix.Log('MARKET', '[HATA] matrix_market_zones sorgu cagrisi reddedildi; RAM varsayilanlariyla devam ediliyor.')
    end
end


CreateThread(function()
    Matrix.Market.LoadMarketZones()
end)


local function GetOrCreateZoneRecord(zoneId)
    local rec = MarketZones[zoneId]
    if not rec then
        rec = { zone_id = zoneId, price_multiplier = Config.Market.PriceMultiplierDefault, rejected_streak = 0 }
        MarketZones[zoneId] = rec
    end
    return rec
end


function Matrix.Market.FindNearestZone(coords)
    if not coords then return nil end
    local nearestId, nearestDist = nil, math_huge
    for _, zoneCfg in ipairs(Config.Market.Zones) do
        local d = #(coords - zoneCfg.coords)
        if d < nearestDist then nearestId, nearestDist = zoneCfg.id, d end
    end
    return nearestId
end


-- ★ KATMAN 5 ULTIMATE [U6]: `saleGrams` opsiyonel 5. parametredir (geriye
-- dönük uyumlu — eski çağıranlar bu argümanı hiç geçmez, nil kalır ve
-- ledger'a hiçbir şey yazılmaz, davranış BİREBİR ESKİSİYLE AYNIDIR).
function Matrix.Market.EvaluateSale(zoneId, buyerCitizenid, buyerCognitiveShifter, purity, sellerBallisticId, saleGrams)
    zoneId = tonumber(zoneId)
    if not zoneId then return nil end

    -- ★ [M-2 FIX] Client-supplied saleGrams sunucu tarafında katı clamp:
    saleGrams = math.min(math.max(tonumber(saleGrams) or 0, 0), 1000)

    local zone = GetOrCreateZoneRecord(zoneId)
    buyerCognitiveShifter = Matrix.Clamp(tonumber(buyerCognitiveShifter) or 0.0, 0.0, 1.0)
    purity                = Matrix.Clamp(tonumber(purity) or 0.0, 0.0, 1.0)


    local isGourmet = buyerCognitiveShifter > Config.Market.GourmetCognitiveShifterThreshold
    local rejected   = isGourmet and (purity < Config.Market.GourmetMinPurity)


    if rejected then
        zone.rejected_streak = zone.rejected_streak + 1


        local decayRate = Config.Market.RejectionPriceDecayRate * Config.Market.DemandElasticity
        zone.price_multiplier = Config.Market.PriceMultiplierFloor
            + ((zone.price_multiplier - Config.Market.PriceMultiplierFloor) * math.exp(-decayRate))
        zone.price_multiplier = Matrix.Clamp(
            zone.price_multiplier, Config.Market.PriceMultiplierFloor, Config.Market.PriceMultiplierCeiling)
        dirtyMarketZones[zoneId] = true


        -- ★ [U6] "Newton fiyat çöküş sönümlenmesi" bölgesel mali defterde
        -- de sayaçlanır (Bölgesel Mali Rapor'un "Fiyat-Cokme" sütunu).
        Matrix.Market.RecordPriceCrash(zoneId)


        Matrix.Log('MARKET',
            '[PAZAR ANOMALİSİ: KALİTESİZ ARZ REDDEDİLDİ] Bölge #%d | Saflık:%.3f | Ardarda-Red:%d | Yeni-Çarpan:x%.3f',
            zoneId, purity, zone.rejected_streak, zone.price_multiplier)
    elseif zone.rejected_streak ~= 0 then
        zone.rejected_streak = 0
        dirtyMarketZones[zoneId] = true
    end


    local isUndercover = Matrix.Undercover.IsUndercoverAgent(buyerCitizenid)
    if isUndercover and type(sellerBallisticId) == 'string' and sellerBallisticId ~= '' then
        Matrix.Forensics.ForceSeal(sellerBallisticId)
        Matrix.Log('MARKET', '[UNDERCOVER TESLİMAT] %s -> gizli ajan tespit edildi, balistik #%s zorla mühürlendi.',
            tostring(buyerCitizenid), sellerBallisticId)
    end


    -- ★ [U6]: yalnızca reddedilmemiş VE geçerli bir gram miktarı verilmiş
    -- satışlar brüt ciro/net kâra işlenir.
    if not rejected and not isUndercover then
        local grams = tonumber(saleGrams)
        if grams and grams > 0 then
            Matrix.Market.RecordZoneRevenue(zoneId, grams, zone.price_multiplier)
        end
    end


    return {
        rejected         = rejected,
        is_gourmet       = isGourmet,
        price_multiplier = zone.price_multiplier,
        is_undercover    = isUndercover
    }
end


-- ★ CRITICAL FIX: toplu MySQL.transaction.await; RAM bayraklari SADECE
-- basari sonrasi temizlenir (bkz. server/logistics.lua FlushDirtyFleet ile
-- AYNI desen).
local function FlushDirtyMarketZones()
    local pendingZones = {}
    for zoneId in pairs(dirtyMarketZones) do
        pendingZones[#pendingZones + 1] = zoneId
    end
    if #pendingZones == 0 then return end


    local queries = {}
    for _, zoneId in ipairs(pendingZones) do
        local zone = MarketZones[zoneId]
        if zone then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_market_zones (zone_id, price_multiplier, rejected_streak, updated_at)
                    VALUES (?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        price_multiplier = VALUES(price_multiplier),
                        rejected_streak  = VALUES(rejected_streak),
                        updated_at       = NOW()
                ]],
                values = { zoneId, zone.price_multiplier, zone.rejected_streak }
            }
        end
    end


    if #queries == 0 then
        for _, zoneId in ipairs(pendingZones) do dirtyMarketZones[zoneId] = nil end
        return
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, zoneId in ipairs(pendingZones) do dirtyMarketZones[zoneId] = nil end
    else
        Matrix.Log('MARKET',
            '[HATA][KRITIK] FlushDirtyMarketZones transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


RegisterNetEvent('matrix:server:reportSaleAttempt', function(botId, buyerCognitiveShifter, purity, sellerBallisticId, saleGrams)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    local bot = botId and Matrix.Bots[botId]
    if not bot or not bot.state.coords then return end


    local zoneId = Matrix.Market.FindNearestZone(bot.state.coords)
    if not zoneId then return end


    local state = Matrix.GetOrCreatePlayerState(src)
    Matrix.Market.EvaluateSale(zoneId, state and state.citizenid, buyerCognitiveShifter, purity, sellerBallisticId, saleGrams)
end)


RegisterCommand('piyasasifirla', function(src, args)
    local zoneId = tonumber(args[1])
    if not zoneId then Reply(src, 'Kullanim: /piyasasifirla [zoneId]'); return end


    local zone = GetOrCreateZoneRecord(zoneId)
    zone.price_multiplier = Config.Market.PriceMultiplierDefault
    zone.rejected_streak  = 0
    dirtyMarketZones[zoneId] = true


    Reply(src, ('Bolge #%d fiyat carpani varsayilana (x%.2f) sifirlandi.'):format(zoneId, Config.Market.PriceMultiplierDefault))
end, false)


RegisterCommand('piyasasorgu', function(src, args)
    local zoneId = tonumber(args[1])
    if zoneId then
        local zone = MarketZones[zoneId]
        if not zone then Reply(src, 'Bu bolge icin kayit yok.'); return end
        Reply(src, ('Bolge #%d | Fiyat-Carpani:x%.3f | Ardarda-Red:%d'):format(
            zoneId, zone.price_multiplier, zone.rejected_streak))
        return
    end


    for _, zoneCfg in ipairs(Config.Market.Zones) do
        local zone = MarketZones[zoneCfg.id]
        if zone then
            Reply(src, ('#%d %s | Fiyat-Carpani:x%.3f | Ardarda-Red:%d'):format(
                zoneCfg.id, zoneCfg.label, zone.price_multiplier, zone.rejected_streak))
        end
    end
end, false)


-- =====================================================================
-- 3) TELSİZ SESSİZLİĞİ MODU
-- =====================================================================
local SilenceExpiry = {}
-- ★ KATMAN 7 [T3]: sessizlik ihlali (BreakForRedirect) sayacı, citizenid
-- başına ardışık kırılma sayısını tutar — geometrik ceza büyümesi buradan
-- beslenir. /sessizlik yeniden başlatıldığında (Start, aşağıda) sıfırlanır.
local SilenceBreakCount = {}


function Matrix.RadioSilence.Start(citizenid, minutes)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    minutes = Matrix.Clamp(tonumber(minutes) or 5.0, 1.0, Config.RadioSilence.MaxDurationMinutes)
    SilenceExpiry[citizenid] = Matrix.Now() + math.floor(minutes * 60.0)
    -- ★ [T3] Temiz sayfa: yeni bir sessizlik penceresi, önceki ihlallerin
    -- geometrik cezasını miras almaz.
    SilenceBreakCount[citizenid] = nil
    return true, minutes
end


function Matrix.RadioSilence.IsActive(citizenid)
    if type(citizenid) ~= 'string' then return false end
    local expiresAt = SilenceExpiry[citizenid]
    if not expiresAt then return false end
    if Matrix.Now() >= expiresAt then
        SilenceExpiry[citizenid] = nil
        return false
    end
    return true
end


function Matrix.RadioSilence.IsActiveForSource(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local state = Matrix.GetOrCreatePlayerState(src)
    return state ~= nil and Matrix.RadioSilence.IsActive(state.citizenid)
end


-- =====================================================================
-- ★ KATMAN 7 [T3]: SESSİZLİK ALTINDA YENİ SEVK/ROTA GUARD'I
-- server/logistics.lua Matrix.Logistics.DispatchDealer VE
-- Matrix.Logistics.DispatchAmmoRun tarafından, fiziksel sevk hiç
-- başlamadan ÖNCE çağrılır: dispatcher /sessizlik altındaysa lojistik/
-- kurye botlarına YENİ bir rota/komut fırlatılması siber koruma amacıyla
-- TAMAMEN engellenir (dönüş: false, 'radio_silence_active'). Zaten
-- YOLDA olan (aktif dispatch) bir botu telsizden yeniden yönlendirmek
-- BU GUARD'IN KAPSAMI DIŞINDADIR — bkz. BreakForRedirect (aşağıda),
-- server/main.lua Matrix.TriggerPanicEvacuation'dan çağrılır.
-- =====================================================================
function Matrix.RadioSilence.GuardBotDispatch(dispatcherSrc)
    if type(dispatcherSrc) ~= 'number' or dispatcherSrc <= 0 then return true end
    local state = Matrix.GetOrCreatePlayerState(dispatcherSrc)
    if not state or not state.citizenid then return true end
    if Matrix.RadioSilence.IsActive(state.citizenid) then
        return false, 'radio_silence_active'
    end
    return true
end


-- =====================================================================
-- ★ KATMAN 7 [T3]: SESSİZLİK İHLALİ — YOLDAKİ BOTA TELSİZ MÜDAHALESİ
-- dispatcher /sessizlik altındayken, zaten aktif bir dispatch'te olan bir
-- bota (örn. Acil Tahliye ile) telsizden bilinçli olarak müdahale
-- edildiğinde çağrılır. Engellemez — yalnızca bir bedel uygular:
--   1) o dispatch'in orijinal dispatcher'ına (dispatch.dispatcher_src)
--      Matrix.Radio.ApplyStatic ile artan şiddette statik parazit,
--   2) botun trap house'unun Büro decryption_confidence katsayısına
--      (Matrix.Bureau.AdvanceDecryption) artan büyüklükte bir sıçrama.
-- Her ikisi de SilenceBreakCount[citizenid]'e göre Config.RadioSilence.
-- BreakGeometricFactor ÜSSEL katsayısıyla büyür — art arda ihlaller
-- katlanarak pahalılaşır (Zero RNG: tamamen deterministik).
-- =====================================================================
function Matrix.RadioSilence.BreakForRedirect(citizenid, botId, trapHouseId)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0.0, 0.0 end

    local n = (SilenceBreakCount[citizenid] or 0) + 1
    SilenceBreakCount[citizenid] = n
    local geometricStep = Config.RadioSilence.BreakGeometricFactor ^ (n - 1)

    local staticIntensity = Matrix.Clamp(Config.RadioSilence.BreakBaseStatic * geometricStep, 0.0, 1.0)
    local decryptionSpike = Config.RadioSilence.BreakBaseDecryptionGain * geometricStep

    local dispatch  = (botId and Matrix.Dispatches) and Matrix.Dispatches[botId] or nil
    local targetSrc = dispatch and dispatch.dispatcher_src
    if targetSrc and Matrix.Radio and Matrix.Radio.ApplyStatic then
        Matrix.Radio.ApplyStatic(targetSrc, staticIntensity, 'sessizlik_bozuldu')
    end

    local resolvedTrapId = trapHouseId
    if not resolvedTrapId and botId and Matrix.Bots[botId] then
        resolvedTrapId = Matrix.Bots[botId].state.trap_house_id
    end
    if resolvedTrapId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        Matrix.Bureau.AdvanceDecryption(resolvedTrapId, decryptionSpike)
    end

    Matrix.Log('MARKET',
        '[SESSIZLIK BOZULDU] %s -> Bot #%s icin telsiz mudahalesi (#%d. ardisik kirilma). Statik:%.2f Desifre-Sicramasi:+%.4f',
        citizenid, tostring(botId), n, staticIntensity, decryptionSpike)

    return staticIntensity, decryptionSpike
end


RegisterCommand('sessizlik', function(src, args)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local ok, minutes = Matrix.RadioSilence.Start(state.citizenid, tonumber(args[1]))
    if ok then
        Reply(src, ('Telsiz sessizligi %d dakika aktif. Bu sure boyunca canli yayin siber heatmap artisi durur.'):format(minutes))
    else
        Reply(src, 'Sessizlik baslatilamadi.')
    end
end, false)


-- =====================================================================
-- 4) KİRLENEN NAKİT SÖNÜMLENMESİ
-- =====================================================================
local CashByTrapHouse = {}
local dirtyCash        = {}


function Matrix.CashDecay.LoadCashDecay()
    local callOk = pcall(function()
        MySQL.query('SELECT trap_house_id, dirty_amount FROM matrix_cash_decay', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.trap_house_id then
                            CashByTrapHouse[row.trap_house_id] = {
                                dirty_amount = tonumber(row.dirty_amount) or 0.0,
                                deposited_at = Matrix.Now()
                            }
                        end
                    end
                    Matrix.Log('MARKET', '%d kirli nakit kaydi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_cash_decay sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


CreateThread(function()
    Matrix.CashDecay.LoadCashDecay()
end)


function Matrix.CashDecay.Deposit(trapHouseId, amount)
    trapHouseId = tonumber(trapHouseId)
    amount      = tonumber(amount) or 0.0
    if not trapHouseId or amount <= 0.0 then return false end


    local rec = CashByTrapHouse[trapHouseId]
    if not rec then
        rec = { dirty_amount = 0.0, deposited_at = Matrix.Now() }
        CashByTrapHouse[trapHouseId] = rec
    end
    rec.dirty_amount = rec.dirty_amount + amount
    dirtyCash[trapHouseId] = true


    Matrix.Log('MARKET', 'Trap house #%d kirli nakit yatirimi: +%.1f (toplam:%.1f)', trapHouseId, amount, rec.dirty_amount)
    return true
end


local ESCROW_HOLD_SECONDS = 24 * 60 * 60

function Matrix.CashDecay.Launder(trapHouseId, amount, citizenid)
    trapHouseId = tonumber(trapHouseId)
    amount      = tonumber(amount) or 0.0
    citizenid   = (type(citizenid) == 'string' and citizenid ~= '') and citizenid or 'UNKNOWN'

    if Matrix.Bureau and Matrix.Bureau.IsLockedDown and trapHouseId and Matrix.Bureau.IsLockedDown(trapHouseId) then
        return false, 'bureau_lockdown'
    end

        local rec = trapHouseId and CashByTrapHouse[trapHouseId]
    if not rec or amount <= 0.0 then return false, 'invalid_amount' end
    -- ★ v6.6.4-A2d: Yıkanan miktar eldeki kirli nakdi AŞAMAZ.
    -- Aksi halde escrow satırı gerçek bakiyeden büyük açılır ve
    -- 24 saat sonra sıfırdan para ödenir.
    if amount > rec.dirty_amount then
        return false, 'insufficient_dirty_funds'
    end

    rec.dirty_amount = math_max(rec.dirty_amount - amount, 0.0)
    if rec.dirty_amount <= 0.0 then
        rec.deposited_at = Matrix.Now()
    end
    dirtyCash[trapHouseId] = true

    local nowEpoch     = os.time()
    local releaseEpoch = nowEpoch + ESCROW_HOLD_SECONDS

    MySQL.insert([[
        INSERT INTO matrix_banking_escrow
            (citizenid, trap_house_id, amount, deposited_epoch, release_epoch, status)
        VALUES (?, ?, ?, ?, ?, 'processing')
    ]], { citizenid, trapHouseId, amount, nowEpoch, releaseEpoch },
    function(insertId)
        if insertId then
            Matrix.Log('MARKET',
                '[ESCROW OLUSTURULDU] id=%d | %s | $%.0f | release=%d (%ds sonra)',
                insertId, citizenid, amount, releaseEpoch, ESCROW_HOLD_SECONDS)
        end
    end)

    Matrix.Log('MARKET',
        'Trap house #%d nakit aklandi: -%.1f (kalan:%.1f) -- 24 SAATLIK ESCROW BEKLEMEDE.',
        trapHouseId, amount, rec.dirty_amount)
    return true
end


function Matrix.CashDecay.Tick()
    local now = Matrix.Now()
    for trapHouseId, rec in pairs(CashByTrapHouse) do
        if rec.dirty_amount > 0.0 and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId] then
            local ageDays    = math_max((now - rec.deposited_at) / 86400.0, 0.0)
            local traceLevel = Matrix.Clamp(1.0 - (0.5 ^ (ageDays / Config.CashDecay.TraceHalfLifeRealDays)), 0.0, 1.0)


            local raidGain = Config.Bureau.PatternAnalysisGain * traceLevel
                * (Config.CashDecay.RaidRiskMultiplierAtMaxTrace - 1.0)
            if raidGain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, raidGain)
            end
        end
    end
end


CreateThread(function()
    while true do
        Wait(Config.CashDecay.TickIntervalMs)
        local ok, err = pcall(Matrix.CashDecay.Tick)
        if not ok then
            Matrix.Log('MARKET', '[HATA] CashDecay.Tick hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)


-- ★ CRITICAL FIX: toplu MySQL.transaction.await; RAM bayraklari SADECE
-- basari sonrasi temizlenir.
local function FlushDirtyCash()
    local pendingHouses = {}
    for trapHouseId in pairs(dirtyCash) do
        pendingHouses[#pendingHouses + 1] = trapHouseId
    end
    if #pendingHouses == 0 then return end


    local queries = {}
    for _, trapHouseId in ipairs(pendingHouses) do
        local rec = CashByTrapHouse[trapHouseId]
        if rec then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_cash_decay (trap_house_id, dirty_amount, deposited_at, updated_at)
                    VALUES (?, ?, FROM_UNIXTIME(?), NOW())
                    ON DUPLICATE KEY UPDATE
                        dirty_amount = VALUES(dirty_amount),
                        deposited_at = VALUES(deposited_at),
                        updated_at   = NOW()
                ]],
                values = { trapHouseId, rec.dirty_amount, rec.deposited_at }
            }
        end
    end


    if #queries == 0 then
        for _, trapHouseId in ipairs(pendingHouses) do dirtyCash[trapHouseId] = nil end
        return
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, trapHouseId in ipairs(pendingHouses) do dirtyCash[trapHouseId] = nil end
    else
        Matrix.Log('MARKET',
            '[HATA][KRITIK] FlushDirtyCash transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


RegisterCommand('nakityatir', function(src, args)
    -- ★ v6.6.4-A2d: fail-closed yetki + mesafe + miktar kapıları
    if type(src) == 'number' and src > 0 then
        if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then
            Reply(src, 'Yetkisiz.'); return
        end
        local _s = Matrix.GetOrCreatePlayerState(src)
        if not _s or not _s.citizenid
            or not Matrix.Hierarchy.HasCommandAuthority(_s.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end

    local trapHouseId = tonumber(args[1])
    local amount = tonumber(args[2])
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then
        Reply(src, 'Kullanim: /nakityatir [trapHouseId] [miktar]'); return
    end

    -- Pozitif, makul miktar, NaN/Inf guard
    if not amount or amount ~= amount or amount <= 0.0
        or amount == math.huge or amount == -math.huge
        or amount > 1.0e9 then
        Reply(src, 'Gecersiz miktar.'); return
    end

    -- Mesafe kontrolü: oyuncu trap house deposuna 15m icinde olmali
    if type(src) == 'number' and src > 0 then
        local _ped = GetPlayerPed(src)
        if _ped and _ped ~= 0 then
            local _pc = GetEntityCoords(_ped)
            local _hc = Matrix.TrapHouses[trapHouseId].coords
            if _hc then
                local _dist = #(vector3(_pc.x, _pc.y, _pc.z) - _hc)
                if _dist > (Config.Logistics.TrapHouseArrivalStashRadius or 15.0) then
                    Reply(src, ('Trap #%d deposuna cok uzaksiniz (%.1fm).'):format(trapHouseId, _dist))
                    return
                end
            end
        end
    end

    local _ok = Matrix.CashDecay.Deposit(trapHouseId, amount)
    if not _ok then
        Reply(src, 'Yatirim basarisiz (gecersiz trap house veya miktar).'); return
    end
    local _rec = CashByTrapHouse[trapHouseId]
    Reply(src, ('Trap #%d kirli nakit: %.1f'):format(trapHouseId, _rec and _rec.dirty_amount or 0.0))
end, false)

RegisterCommand('nakitakla', function(src, args)
    local trapHouseId = tonumber(args[1])
    local amount      = tonumber(args[2])
    if not trapHouseId or not amount then
        Reply(src, 'Kullanim: /nakitakla [trapHouseId] [miktar]'); return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = (state and state.citizenid) or 'UNKNOWN'

    local ok, reason = Matrix.CashDecay.Launder(trapHouseId, amount, citizenid)
    if ok then
        local remaining = CashByTrapHouse[trapHouseId] and CashByTrapHouse[trapHouseId].dirty_amount or 0.0
        Reply(src, ('[ESCROW] $%.0f 24 saatlik escrow kilidine alindi. Kalan kirli nakit: %.1f'):format(
            amount, remaining))
        Reply(src, 'Federal raid veya Büro lockdown esnasinda %100 el konulur.')
    else
        Reply(src, ('Aklama basarisiz: %s'):format(tostring(reason)))
    end
end, false)

RegisterCommand('nakitdurum', function(src, args)
    local trapHouseId = tonumber(args[1])
    local rec = trapHouseId and CashByTrapHouse[trapHouseId]
    if not rec then Reply(src, 'Kullanim: /nakitdurum [trapHouseId]'); return end


    local ageDays = math_max((Matrix.Now() - rec.deposited_at) / 86400.0, 0.0)
    local traceLevel = Matrix.Clamp(1.0 - (0.5 ^ (ageDays / Config.CashDecay.TraceHalfLifeRealDays)), 0.0, 1.0)
    Reply(src, ('Trap #%d | Kirli-Nakit:%.1f | Yas:%.2f gun | Iz-Seviyesi:%.3f'):format(
        trapHouseId, rec.dirty_amount, ageDays, traceLevel))
end, false)


-- =====================================================================
-- 5) UNDERCOVER AJAN YOĞUNLAŞMASI
-- =====================================================================
local UndercoverFlags = {}


function Matrix.Undercover.IsUndercoverAgent(citizenid)
    return type(citizenid) == 'string' and UndercoverFlags[citizenid] == true
end


function Matrix.Undercover.Tick()
    local momentum = Matrix.Bureau.GetPropagandaMomentum()
    if momentum < Config.Undercover.InfiltrationMomentumThreshold then return end


    local rows = MySQL.query.await(
        'SELECT citizenid, times_reported, completed_deals FROM matrix_customer_pool WHERE promoted_to_candidate = 0', {}
    ) or {}


    for _, row in ipairs(rows) do
        if row.citizenid and not UndercoverFlags[row.citizenid] then
            local suspicion = Matrix.Clamp(
                ((row.times_reported or 0) * Config.Undercover.SuspicionReportWeight)
                    + ((row.completed_deals or 0) * Config.Undercover.SuspicionDealWeight),
                0.0, 1.0
            )
            if suspicion >= Config.Undercover.SuspicionThreshold then
                UndercoverFlags[row.citizenid] = true
                Matrix.Log('MARKET', '[UNDERCOVER ŞÜPHESİ] %s gizli ajan olarak isaretlendi (supheydi:%.2f, momentum:%.2f)',
                    row.citizenid, suspicion, momentum)
            end
        end
    end
end


CreateThread(function()
    while true do
        Wait(Config.Undercover.ScanIntervalSeconds * 1000)
        local ok, err = pcall(Matrix.Undercover.Tick)
        if not ok then
            Matrix.Log('MARKET', '[HATA] Undercover.Tick hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)


RegisterCommand('gizliajandurum', function(src)
    local count = 0
    for citizenid in pairs(UndercoverFlags) do
        count = count + 1
        Reply(src, ('- %s'):format(citizenid))
    end
    Reply(src, ('--- Toplam %d isaretli gizli ajan | Propaganda-Momentum:%.2f (esik:%.2f) ---'):format(
        count, Matrix.Bureau.GetPropagandaMomentum(), Config.Undercover.InfiltrationMomentumThreshold))
end, false)


-- =====================================================================
-- 6) TAKTİK HUD ANLIK GÖRÜNTÜ  (★ M1+M2 SERTLEŞTİRME + ★ U5 COMINT EKİ
--    + ★ K6 RENDEZVOUS/TAHKİMAT EKİ, bkz. dosya başı notu)
-- =====================================================================
Matrix.Hud = Matrix.Hud or {}
local HudViewers = {}   -- src -> true
local _HudSnapshotHash = {}
local function _HashHudSnapshot(snapshot)
    if type(snapshot) ~= 'table' then return '' end
    local parts = {}
    for i = 1, #snapshot do
        local line = snapshot[i]
        if type(line) == 'table' and type(line.text) == 'string' then
            parts[#parts + 1] = line.text
            parts[#parts + 1] = line.header and 'H' or line.danger and 'D' or '-'
        end
    end
    return table.concat(parts, '|')
end

RegisterNetEvent('matrix:server:hudToggled', function(active)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if active then
        HudViewers[src] = true
    else
        HudViewers[src] = nil
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    HudViewers[src] = nil
    _HudSnapshotHash[src] = nil
end)

-- ★ [M1] NaN/inf/type filtresi + sabit metin eşlemesi. Aynı girdi → aynı
-- çıktı. Çağrıldığında MASTER TICKER THREAD'İNİ ASLA DONDURMAZ.
local function FormatCortisolThreshold(value)
    local v = tonumber(value)
    if not v or v ~= v or v == math_huge or v == -math_huge then
        v = 0.0
    end
    if v < 0.20 then
        return '[NABIZ: SOĞUKKANLI SUBAY]'
    elseif v <= 0.60 then
        return '[NABIZ: ANKSİYETE BAŞLANGICI — TETİKTE]'
    else
        return '[NABIZ: AKUT PANİK ATAK KRİZİ — ELLERİN TİTRİYOR]'
    end
end


local function FormatFatigueThreshold(value)
    local v = tonumber(value)
    if not v or v ~= v or v == math_huge or v == -math_huge then
        v = 0.0
    end
    if v < 0.30 then
        return '[KONDİSYON: DİNÇ]'
    elseif v <= 0.80 then
        return '[KONDİSYON: KRONİK BİTKİNLİK]'
    else
        return '[KONDİSYON: NÖRON HASARI SINIRI — BEYİN SAKATLIĞI RİSKİ]'
    end
end


local function FindNearestTrapHouseCoordsForHud(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId
end


-- ★ [U5] Telsiz sessizliği geri sayımını "Kalan MM:SS Dk" biçimine çevirir.
-- SilenceExpiry (bölüm 3, yukarıda) AYNI dosya chunk'ında bir üst-değer
-- olduğundan doğrudan erişilebilir. Çiğ saniye HİÇBİR ZAMAN ekrana basılmaz.
local function FormatSilenceCountdownText(citizenid)
    if not citizenid or not Matrix.RadioSilence.IsActive(citizenid) then return nil end
    local expiresAt = SilenceExpiry[citizenid]
    if not expiresAt then return nil end
    local remaining = math_max(expiresAt - Matrix.Now(), 0)
    local mm = math_floor(remaining / 60)
    local ss = remaining % 60
    return ('[SESSIZLIK SURESI: Kalan %02d:%02d Dk]'):format(mm, ss)
end


-- ★ [U5] Aktif telefon görüşmesi durumunu bültene çevirir. İkinci dönüş
-- değeri (danger) true ise client/hud.lua bu satırı KIRMIZI çizer.
-- Matrix.Comint (bölüm 8, aşağıda) bu dosyanın İÇİNDE tanımlı olduğundan
-- (ayrı bir dosya değil) ileri-referans sorunu yoktur — bu fonksiyon
-- yalnızca ÇAĞRILDIĞINDA (HUD push anında, tüm dosya zaten yüklenmiş
-- durumdayken) Matrix.Comint.GetCallState'i okur.
local function FormatComintCallStatus(src)
    local call = Matrix.Comint.GetCallState and Matrix.Comint.GetCallState(src)
    if not call then return nil, false end


    if call.is_burner then
        return '[BAGLANTI: GUVENLI ACIK HAT — IMEI MASKELEME AKTIF]', false
    end


    local elapsed = math_max(Matrix.Now() - (call.started_at or Matrix.Now()), 0)
    if elapsed > Config.Comint.NormalCallTriangulationSeconds then
        return '[BURO RADARI: SINYAL UCGENLEME BASLADI — TELEFONU KAPATIN!]', true
    end


    return nil, false
end


-- ★ [M2] Tüm sayısal değerler Clamp'ten geçer; hiçbir NaN/inf HUD'a
-- ulaşmaz. Saf okuma, mutasyon yok.

function Matrix.Hud.BuildSnapshot(src)
    -- ★ [CHAOS-FIX] src=0 / nil için guard
    if type(src) ~= 'number' or src <= 0 then return nil end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid


    local rank      = citizenid and Matrix.Hierarchy.GetRank(citizenid)
    local authority = (citizenid and Matrix.Hierarchy.HasCommandAuthority(citizenid)) or false
    local silent    = (citizenid and Matrix.RadioSilence.IsActive(citizenid)) or false


    local ped    = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local trapId = coords and FindNearestTrapHouseCoordsForHud(coords)
    local house  = trapId and Matrix.TrapHouses[trapId]


    local heatRaw = (trapId and Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapId)) or 0.0
    local heat    = Matrix.Clamp(heatRaw, 0.0, Config.Bureau.CyberLeakMaxIntensity)


    local decryption = house and Matrix.Clamp(house.decryption_confidence or 0.0, 0.0, 1.0) or 0.0


    local cortisol = Matrix.Clamp((state and state.biology and state.biology.cortisol_level) or 0.0, 0.0, 1.0)
    local fatigue  = Matrix.Clamp((state and state.biology and state.biology.fatigue_level) or 0.0, 0.0, 1.0)


    local botCount = 0
    for _ in pairs(Matrix.Bots or {}) do botCount = botCount + 1 end
    local dispatchCount = 0
    for _ in pairs(Matrix.Dispatches or {}) do dispatchCount = dispatchCount + 1 end


    local snapshot = {
        { text = '[KARTEL BUROSU]', header = true },
        { text = ('RUTBE:%s  KOMUTA-YETKISI:%s'):format(rank or 'YOK', tostring(authority)) },
        { text = '[SIBER RADAR]', header = true },
        { text = house
            and ('BOLGE:#%d DESIFRE:%.2f SIZINTI:%.2f SESSIZLIK:%s'):format(trapId, decryption, heat, tostring(silent))
            or 'BOLGE: BILINMIYOR' },
        { text = '[BIYOLOJIK PROFIL]', header = true },
        { text = FormatCortisolThreshold(cortisol) },
        { text = FormatFatigueThreshold(fatigue) },
        { text = '[SAHA OPERASYONU]', header = true },
        { text = ('AKTIF-BOT:%d  SEVKIYAT:%d'):format(botCount, dispatchCount) }
    }


    -- ★ KATMAN 5 ULTIMATE [U8]: ACİL TAHLİYE bülteni — YALNIZCA bu oyuncunun
    -- kendi tetiklediği bir panik tahliyesi (bkz. server/main.lua Matrix.
    -- TriggerPanicEvacuation / /panikiptal) aktifken görünür; başka
    -- oyuncuların HUD'unda hiç basılmaz (dispatch.panic_dispatcher_src ==
    -- src kontrolü). Aynı anda birden fazla bot panikte olabileceğinden her
    -- biri kendi satırını alır. Sabit metin: çiğ mesafe/süre YOK (Sıfır Sayı
    -- Standardı), her zaman kırmızı (danger=true) basılır.
    local panicLines = {}
    for panicBotId, dispatch in pairs(Matrix.Dispatches or {}) do
        if dispatch.panic_evacuation and dispatch.panic_dispatcher_src == src then
            panicLines[#panicLines + 1] = {
                text   = ('[DURUM: ACIL TAHLIYE — SANA DOGRU GELIYOR] (Bot #%d)'):format(panicBotId),
                danger = true
            }
        end
    end
    if #panicLines > 0 then
        snapshot[#snapshot + 1] = { text = '[ACIL DURUM]', header = true }
        for i = 1, #panicLines do
            snapshot[#snapshot + 1] = panicLines[i]
        end
    end


    -- ★ KATMAN 6 [K6]: Rendezvous pusu uyarısı + Kapı Sürgü Tahkimatı geri
    -- sayımı. server/rendezvous.lua / server/door_reinforcement.lua yüklü
    -- DEĞİLSE getter'lar nil döner ve bu blok HİÇ eklenmez — davranış
    -- ESKİSİYLE (Katman 5 Ultimate) BİREBİR AYNI kalır. Sıfır Sayı
    -- Standardı: yalnızca hazır askeri metin + danger bayrağı taşınır.
    local k6Lines = {}
    if Matrix.Rendezvous and Matrix.Rendezvous.GetAmbushBulletin then
        local text, danger = Matrix.Rendezvous.GetAmbushBulletin(src)
        if text then k6Lines[#k6Lines + 1] = { text = text, danger = danger } end
    end
    if Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachCountdownText then
        local text, danger = Matrix.DoorReinforcement.GetBreachCountdownText(src)
        if text then k6Lines[#k6Lines + 1] = { text = text, danger = danger } end
    end
    -- ★ [T4] BURO KILIDI bulteni -- AYNI hook-if-present deseni. K/F6
    -- panelinin ikisi de ayni BuildSnapshot'i paylastigi icin (bkz. dosya
    -- ustundeki comintpanel/hud RegisterCommand notu, client/hud.lua)
    -- bu satir tek basina her iki tus icin de kirmizi bulteni basar.
    if Matrix.Bureau and Matrix.Bureau.GetLockdownBulletin then
        local text, danger = Matrix.Bureau.GetLockdownBulletin(trapId)
        if text then k6Lines[#k6Lines + 1] = { text = text, danger = danger } end
    end
    if #k6Lines > 0 then
        snapshot[#snapshot + 1] = { text = '[GUVENLIK DURUMU]', header = true }
        for i = 1, #k6Lines do
            snapshot[#snapshot + 1] = k6Lines[i]
        end
    end


    -- ★ [U5] COMINT bloğu — her zaman en az bir satır ("kayıt yok" dahil),
    -- çiğ sayı YASAK standardı (bkz. shared/config.lua Katman 5 EVRİM notu)
    -- burada da geçerli: yalnızca edebi/askeri bültenler basılır.
    snapshot[#snapshot + 1] = { text = '[COMINT ISTIHBARAT PROFILI]', header = true }


    local addedComintLine = false
    local silenceLine = silent and FormatSilenceCountdownText(citizenid) or nil
    if silenceLine then
        snapshot[#snapshot + 1] = { text = silenceLine }
        addedComintLine = true
    end


    local callLine, callDanger = FormatComintCallStatus(src)
    if callLine then
        snapshot[#snapshot + 1] = { text = callLine, danger = callDanger }
        addedComintLine = true
    end


    if not addedComintLine then
        snapshot[#snapshot + 1] = { text = 'HAT DURUMU: TEMIZ / AKTIF GORUSME YOK' }
    end


    return snapshot
end


function Matrix.Hud.PushSnapshots()
    for src in pairs(HudViewers) do
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then
            HudViewers[src] = nil
            _HudSnapshotHash[src] = nil
        else
            local ok, snapshot = pcall(Matrix.Hud.BuildSnapshot, src)
            if ok and type(snapshot) == 'table' then
                local hash = _HashHudSnapshot(snapshot)
                if _HudSnapshotHash[src] ~= hash then
                    _HudSnapshotHash[src] = hash
                    TriggerClientEvent('matrix:client:hudSnapshot', src, snapshot)
                end
            end
        end
    end
end

-- =====================================================================
-- 7) ★ KATMAN 5 ULTIMATE [U4]: BÖLGE DENETLEYİCİLERİ (INSPECTORS) & SIGINT
-- KÖSTEBEK TARAMASI
--
-- 'Inspector', bot hiyerarşisinde 'dealer'/'runner' rolünün ÜSTÜNDE
-- çalışan yeni bir rol (bkz. Config.Inspector.PromotableRoles). Bir
-- oyuncu F10 menüsünden kıdemli bir kuryeyi bir bölgeye Inspector olarak
-- atadığında (/denetleyiciata), o bölgedeki (en yakın market zone'u
-- kendisiyle aynı olan trap house'lara bağlı) TÜM alt kuryeler periyodik
-- olarak taranır. RNG YOK: tetikleme SAF bir eşik karşılaştırmasıdır
-- (bot.psychology.snitch_tendency >= Config.Inspector.MoleSnitchThreshold).
-- =====================================================================
local ZoneInspectors = {}  -- zoneId -> botId
local MoleFlags      = {}  -- botId -> { flagged_at, snitch_tendency }


function Matrix.Inspector.LoadZoneInspectors()
    local callOk = pcall(function()
        MySQL.query('SELECT zone_id, bot_id FROM matrix_zone_inspectors', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.zone_id and row.bot_id then
                            ZoneInspectors[row.zone_id] = row.bot_id
                        end
                    end
                    Matrix.Log('MARKET', '%d bolge denetleyicisi atamasi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_zone_inspectors sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


function Matrix.Inspector.LoadMoleFlags()
    local callOk = pcall(function()
        MySQL.query('SELECT bot_id, snitch_tendency, flagged_at FROM matrix_mole_flags', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.bot_id then
                            MoleFlags[row.bot_id] = {
                                flagged_at      = Matrix.Now(),
                                snitch_tendency = tonumber(row.snitch_tendency) or 0.0
                            }
                        end
                    end
                    Matrix.Log('MARKET', '%d kalici kostebek bulteni yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_mole_flags sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


CreateThread(function()
    Matrix.Inspector.LoadZoneInspectors()
    Matrix.Inspector.LoadMoleFlags()
end)


function Matrix.Inspector.AssignInspector(zoneId, botId, assignerCitizenid)
    zoneId = tonumber(zoneId)
    botId  = tonumber(botId)
    if not zoneId or not botId then return false, 'bad_args' end


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if not Config.Inspector.PromotableRoles[bot.role] then return false, 'not_promotable' end


    local zoneExists = false
    for _, z in ipairs(Config.Market.Zones) do
        if z.id == zoneId then zoneExists = true; break end
    end
    if not zoneExists then return false, 'bad_zone' end


    bot.role = 'Inspector'
    Matrix.MarkBotDirty(botId)
    ZoneInspectors[zoneId] = botId


    MySQL.prepare([[
        INSERT INTO matrix_zone_inspectors (zone_id, bot_id, assigned_by_citizenid, assigned_at)
        VALUES (?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE bot_id = VALUES(bot_id), assigned_by_citizenid = VALUES(assigned_by_citizenid), assigned_at = NOW()
    ]], { zoneId, botId, assignerCitizenid })


    Matrix.Log('MARKET', '[DENETLEYICI ATANDI] Bot #%d -> Bolge #%d (atayan: %s)', botId, zoneId, tostring(assignerCitizenid))
    return true
end


--- Bir trap house'un hangi market zone'una ait sayılacağını (en yakın
--- zone) döner — bot<->zone eşlemesi bu üzerinden kurulur, ayrı bir
--- "trap house -> zone" tablosu YOKTUR (mevcut FindNearestZone deseniyle
--- tutarlı, bkz. bölüm 2).
function Matrix.Inspector.GetZoneForTrapHouse(trapHouseId)
    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if not house or not house.coords then return nil end
    return Matrix.Market.FindNearestZone(house.coords)
end


function Matrix.Inspector.IsMoleFlagged(botId)
    return MoleFlags[botId] ~= nil
end


function Matrix.Inspector.ClearMoleFlag(botId)
    if MoleFlags[botId] then
        MoleFlags[botId] = nil
        MySQL.prepare('DELETE FROM matrix_mole_flags WHERE bot_id = ?', { botId })
        return true
    end
    return false
end


-- ★ [KATMAN 4] Kostebek tespit edilir edilmez, F10/HUD panelini acik tutan
-- TUM izleyicilere (HudViewers -- Matrix.Hud.PushSnapshots ile AYNI
-- izleyici kumesi) ANLIK/asenkron bir istihbarat bulteni firlatilir. Ayri
-- bir CreateThread icinde calisir ki ScanForMoles'in kendi dongusunu
-- (ve dolayisiyla Config.Inspector.ScanIntervalSeconds periyodunu) ASLA
-- geciktirmesin veya bir hata durumunda onu COKERTMESIN.
local function BroadcastMoleBulletin(botId, zoneId, inspectorBotId, snitchTendency)
    CreateThread(function()
        local text = ('[KRITIK ANOMALI: HUCRE ICI KOSTEBEK TESPIT EDILDI] Bot #%d (Bolge #%d, Denetleyici Bot #%d) snitch_tendency=%.3f'):format(
            botId, zoneId, inspectorBotId, snitchTendency)
        for src in pairs(HudViewers) do
            pcall(function()
                TriggerClientEvent('chat:addMessage', src, { args = { '[F10 ISTIHBARAT BULTENI]', text } })
            end)
        end
    end)
end


-- ★ Köstebek tarama: her Inspector, kendi bölgesindeki alt kuryeleri
-- snitch_tendency eşiğine göre SAF/deterministik olarak tarar. RNG YOK —
-- aynı psychology.snitch_tendency değeri HER ZAMAN aynı sonucu üretir.
function Matrix.Inspector.ScanForMoles()
    for zoneId, inspectorBotId in pairs(ZoneInspectors) do
        local inspector = Matrix.Bots[inspectorBotId]
        if inspector and inspector.role == 'Inspector' then
            for botId, bot in pairs(Matrix.Bots) do
                if botId ~= inspectorBotId and Config.Inspector.PromotableRoles[bot.role]
                    and bot.state.trap_house_id and not MoleFlags[botId] then
                    local botZone = Matrix.Inspector.GetZoneForTrapHouse(bot.state.trap_house_id)
                    if botZone == zoneId and bot.psychology.snitch_tendency >= Config.Inspector.MoleSnitchThreshold then
                        MoleFlags[botId] = { flagged_at = Matrix.Now(), snitch_tendency = bot.psychology.snitch_tendency }
                        MySQL.prepare([[
                            INSERT INTO matrix_mole_flags (bot_id, snitch_tendency, flagged_at)
                            VALUES (?, ?, NOW())
                            ON DUPLICATE KEY UPDATE snitch_tendency = VALUES(snitch_tendency), flagged_at = NOW()
                        ]], { botId, bot.psychology.snitch_tendency })
                        Matrix.Log('MARKET',
                            '[SIGINT ANOMALISI: KOSTEBEK/MUHBIR DOGRULANDI] Bot #%d (Bolge #%d, Denetleyici Bot #%d) snitch_tendency=%.3f',
                            botId, zoneId, inspectorBotId, bot.psychology.snitch_tendency)
                        BroadcastMoleBulletin(botId, zoneId, inspectorBotId, bot.psychology.snitch_tendency)
                        -- ★ [YERALTI AGI KATMAN 6] Guard'li tek-satirlik gozlemci --
                        -- server/underworld_network.lua'nin Sting mekanigi (yuklu ise)
                        -- bu koestebek isaretini en yakin Satici contact'ina compromised
                        -- olarak yansitir. Modul yuklu degilse davranis birebir eskisiyle
                        -- AYNIDIR (TriggerEvent dinleyicisiz sessizce no-op'tur).
                        local hookOk, hookErr = pcall(function() TriggerEvent('matrix:internal:mole_flagged', botId) end)
                        if not hookOk then
                            Matrix.Log('MARKET', '[HATA] mole_flagged hook basarisiz (yutuldu): %s', tostring(hookErr))
                        end
                    end
                end
            end
        else
            -- Denetleyici bot artik yok (tasfiye edildi) veya rolu degisti -
            -- atama kendini iyilestirir (self-healing), DB'de stale kalir
            -- ama bir sonraki /denetleyiciata onu ezip yeniler.
            ZoneInspectors[zoneId] = nil
        end
    end
end


CreateThread(function()
    while true do
        -- ★ [GLOBAL CONVAR] Devriye frekansi Matrix.Bureau.GetBureaucraticVelocity
        -- (server/bureau.lua, 'matrix_bureau_intensity' ConVar'i) ile CANLI
        -- olceklenir -- yuklu degilse (savunmacı geri dusus) davranis BIREBIR
        -- ESKISI GIBIDIR (carpan=1.0).
        local velocity = (Matrix.Bureau and Matrix.Bureau.GetBureaucraticVelocity and Matrix.Bureau.GetBureaucraticVelocity()) or 1.0
        if type(velocity) ~= 'number' or velocity <= 0.0 then velocity = 1.0 end
        Wait((Config.Inspector.ScanIntervalSeconds / velocity) * 1000)
        local ok, err = pcall(Matrix.Inspector.ScanForMoles)
        if not ok then Matrix.Log('MARKET', '[HATA] Inspector.ScanForMoles basarisiz (yutuldu): %s', tostring(err)) end
    end
end)


RegisterCommand('denetleyiciata', function(src, args)
    local zoneId = tonumber(args[1])
    local botId  = tonumber(args[2])
    if not zoneId or not botId then Reply(src, 'Kullanim: /denetleyiciata [zoneId] [botId]'); return end


    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid or not Matrix.Hierarchy.HasCommandAuthority(state.citizenid) then
        Reply(src, 'Bu atamayi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local ok, reason = Matrix.Inspector.AssignInspector(zoneId, botId, state.citizenid)
    if ok then
        Reply(src, ('Bot #%d, Bolge #%d denetleyicisi olarak atandi. SIGINT kostebek taramasi baslatildi.'):format(botId, zoneId))
    elseif reason == 'not_promotable' then
        Reply(src, 'Bu bot terfi ettirilebilir bir rolde degil (dealer/runner olmali).')
    elseif reason == 'bad_zone' then
        Reply(src, 'Gecersiz bolge ID.')
    else
        Reply(src, ('Atama basarisiz: %s'):format(tostring(reason)))
    end
end, false)


RegisterCommand('denetleyicidurum', function(src)
    local count = 0
    for zoneId, botId in pairs(ZoneInspectors) do
        count = count + 1
        local zoneLabel = tostring(zoneId)
        for _, z in ipairs(Config.Market.Zones) do
            if z.id == zoneId then zoneLabel = z.label; break end
        end
        Reply(src, ('Bolge #%d (%s) -> Denetleyici Bot #%d'):format(zoneId, zoneLabel, botId))
    end
    Reply(src, ('--- Toplam %d aktif denetleyici | %d isaretli kostebek ---'):format(count, (function()
        local n = 0
        for _ in pairs(MoleFlags) do n = n + 1 end
        return n
    end)()))
end, false)


-- =====================================================================
-- 8) ★ KATMAN 5 ULTIMATE [U5]: COMINT — TELSİZ / TELEFON İLETİŞİM PROFİLİ
--
-- CallState src (sayısal oyuncu ID) ile anahtarlanır — citizenid İLE
-- DEĞİL. Sebep: main.lua'nın playerDropped handler'ı Matrix.
-- PlayerSourceIndex[src]'i KENDİ handler'ında nil'ler; birden fazla
-- dosyanın AddEventHandler('playerDropped', ...) kayıtları arasındaki
-- çalışma SIRASI garanti değildir (main.lua önce çalışırsa citizenid
-- burada zaten kaybolmuş olurdu). src anahtarı bu sıralama tehlikesini
-- YAPISAL olarak ortadan kaldırır.
-- =====================================================================
local CallState = {} -- src -> { started_at, is_burner }


RegisterNetEvent('matrix:server:reportPhoneCallState', function(active, isBurner)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if active then
        CallState[src] = { started_at = Matrix.Now(), is_burner = isBurner and true or false }
    else
        CallState[src] = nil
    end
end)


AddEventHandler('playerDropped', function()
    CallState[source] = nil
end)


--- Herhangi bir telefon kaynağının (qb-phone, lb-phone, vb. — bu şema
--- HANGİ telefon kaynağının kurulu olduğunu bilmez) çağrı başlangıcı/
--- bitişinde bu export'u çağırması beklenir:
---   exports['matrix-layer5-ultimate']:ReportPhoneCallState(src, true, isBurnerPhone)
---   exports['matrix-layer5-ultimate']:ReportPhoneCallState(src, false)
--- Net event alternatifi client'tan da tetiklenebilir (bkz. yukarı).
function Matrix.Comint.GetCallState(src)
    return CallState[src]
end


function Matrix.Comint.ReportCallState(src, active, isBurner)
    if type(src) ~= 'number' or src <= 0 then return false end
    if active then
        CallState[src] = { started_at = Matrix.Now(), is_burner = isBurner and true or false }
    else
        CallState[src] = nil
    end
    return true
end


exports('ReportPhoneCallState', function(src, active, isBurner)
    return Matrix.Comint.ReportCallState(src, active, isBurner)
end)


-- Entegrasyon/test amaçlı manuel debug komutu — gerçek üretimde bu
-- durumu telefon kaynağının kendisi export/event ile bildirmelidir.
RegisterCommand('comintcagritest', function(src, args)
    local active = tostring(args[1]) == '1'
    local burner = tostring(args[2]) == '1'
    Matrix.Comint.ReportCallState(src, active, burner)
    Reply(src, active
        and ('Test gorusmesi baslatildi (Acik-Hat:%s).'):format(tostring(burner))
        or 'Test gorusmesi sonlandirildi.')
end, false)


-- =====================================================================
-- 9) ★ KATMAN 5 ULTIMATE [U6]: BÖLGESEL MALİ RAPOR (Karaborsa Ekonomisi)
--
-- Bölge başına yuvarlanan (rolling) bilanço: RAM'de tek bir toplam kayıt
-- tutulur (satış-başı ayrı satır DEĞİL — mevcut "dirty-flag" mimarisiyle
-- tutarlı, bkz. MarketZones/CashByTrapHouse) ve periyodik olarak
-- matrix_zone_ledger'a upsert edilir.
-- =====================================================================
local ZoneLedger      = {} -- zoneId -> { sale_count, total_grams, gross_revenue, net_profit, price_crash_count }
local dirtyZoneLedger = {}


function Matrix.Market.LoadZoneLedger()
    local callOk = pcall(function()
        MySQL.query('SELECT * FROM matrix_zone_ledger', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.zone_id then
                            ZoneLedger[row.zone_id] = {
                                sale_count        = tonumber(row.sale_count) or 0,
                                total_grams       = tonumber(row.total_grams) or 0.0,
                                gross_revenue     = tonumber(row.gross_revenue) or 0.0,
                                net_profit        = tonumber(row.net_profit) or 0.0,
                                price_crash_count = tonumber(row.price_crash_count) or 0
                            }
                        end
                    end
                    Matrix.Log('MARKET', '%d bolgesel mali defter kaydi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('MARKET', '[HATA] matrix_zone_ledger sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


CreateThread(function()
    Matrix.Market.LoadZoneLedger()
end)


local function GetOrCreateLedger(zoneId)
    local ledger = ZoneLedger[zoneId]
    if not ledger then
        ledger = { sale_count = 0, total_grams = 0.0, gross_revenue = 0.0, net_profit = 0.0, price_crash_count = 0 }
        ZoneLedger[zoneId] = ledger
    end
    return ledger
end


function Matrix.Market.RecordZoneRevenue(zoneId, grams, priceMultiplier)
    zoneId = tonumber(zoneId)
    grams  = tonumber(grams)
    if not zoneId or not grams or grams <= 0.0 then return false end


    local gross  = grams * Config.Market.StreetBasePricePerGram * (tonumber(priceMultiplier) or 1.0)
    local cost   = grams * Config.Market.EstimatedCostBasisPerGram
    local profit = gross - cost


    local ledger = GetOrCreateLedger(zoneId)
    ledger.sale_count    = ledger.sale_count + 1
    ledger.total_grams   = ledger.total_grams + grams
    ledger.gross_revenue = ledger.gross_revenue + gross
    ledger.net_profit    = ledger.net_profit + profit
    dirtyZoneLedger[zoneId] = true
    return true
end


function Matrix.Market.RecordPriceCrash(zoneId)
    zoneId = tonumber(zoneId)
    if not zoneId then return false end
    local ledger = GetOrCreateLedger(zoneId)
    ledger.price_crash_count = ledger.price_crash_count + 1
    dirtyZoneLedger[zoneId] = true
    return true
end


-- ★ CRITICAL FIX: toplu MySQL.transaction.await; RAM bayraklari SADECE
-- basari sonrasi temizlenir.
local function FlushDirtyZoneLedger()
    local pendingZones = {}
    for zoneId in pairs(dirtyZoneLedger) do
        pendingZones[#pendingZones + 1] = zoneId
    end
    if #pendingZones == 0 then return end


    local queries = {}
    for _, zoneId in ipairs(pendingZones) do
        local ledger = ZoneLedger[zoneId]
        if ledger then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_zone_ledger
                        (zone_id, sale_count, total_grams, gross_revenue, net_profit, price_crash_count, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        sale_count        = VALUES(sale_count),
                        total_grams       = VALUES(total_grams),
                        gross_revenue     = VALUES(gross_revenue),
                        net_profit        = VALUES(net_profit),
                        price_crash_count = VALUES(price_crash_count),
                        updated_at        = NOW()
                ]],
                values = { zoneId, ledger.sale_count, ledger.total_grams, ledger.gross_revenue, ledger.net_profit, ledger.price_crash_count }
            }
        end
    end


    if #queries == 0 then
        for _, zoneId in ipairs(pendingZones) do dirtyZoneLedger[zoneId] = nil end
        return
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, zoneId in ipairs(pendingZones) do dirtyZoneLedger[zoneId] = nil end
    else
        Matrix.Log('MARKET',
            '[HATA][KRITIK] FlushDirtyZoneLedger transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


lib.callback.register('matrix:callback:getRegionalFinancialReport', function(src)
    local lines = { '=== BOLGESEL MALI RAPOR (KARABORSA EKONOMISI) ===' }


    for _, zoneCfg in ipairs(Config.Market.Zones) do
        local ledger = ZoneLedger[zoneCfg.id]
        if ledger and ledger.sale_count > 0 then
            lines[#lines + 1] = ('#%d %s | Satis:%d | Gram:%.1f | Brut-Ciro:$%.0f | Net-Kar:$%.0f | Fiyat-Cokme:%d'):format(
                zoneCfg.id, zoneCfg.label, ledger.sale_count, ledger.total_grams,
                ledger.gross_revenue, ledger.net_profit, ledger.price_crash_count)
        else
            lines[#lines + 1] = ('#%d %s | Veri yok (henuz kayitli satis yok)'):format(zoneCfg.id, zoneCfg.label)
        end
    end


    return lines
end)


RegisterCommand('bolgeselrapor', function(src)
    for _, zoneCfg in ipairs(Config.Market.Zones) do
        local ledger = ZoneLedger[zoneCfg.id]
        if ledger and ledger.sale_count > 0 then
            Reply(src, ('#%d %s | Satis:%d | Gram:%.1f | Brut-Ciro:$%.0f | Net-Kar:$%.0f | Fiyat-Cokme:%d'):format(
                zoneCfg.id, zoneCfg.label, ledger.sale_count, ledger.total_grams,
                ledger.gross_revenue, ledger.net_profit, ledger.price_crash_count))
        else
            Reply(src, ('#%d %s | Veri yok'):format(zoneCfg.id, zoneCfg.label))
        end
    end
end, false)


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: SOKAKTA CANLI NPC "KEŞ" SATIŞ DÖNGÜSÜ ★★★
-- Gerçek oyuncular (K panel / Config.Market.StreetDealing.DealingModeCommand)
-- VE 'street_dealing' aktivitesindeki dealer botları AYNI sunucu-otoriteli
-- çözümleyiciyi (ResolveStreetSale) paylaşır. Matrix.Market.EvaluateSale
-- (yukarıda, [U6]) HİÇ DEĞİŞTİRİLMEDİ -- bu, TAMAMEN AYRI bir ekonomi
-- hattıdır: sokaktaki ambient "keş" NPC'ler matrix_customer_pool'daki
-- GERÇEK oyuncu kimlikli müşterilerle KARIŞTIRILMAZ (bkz. shared/config.lua
-- [F2-2] notu), bu yüzden kendi bağımsız fiyat/red mantığını taşır.
--
-- SIFIR RNG:
--   - Ret eşiği Config.Market.GourmetMinPurity'nin (MEVCUT, DEĞİŞTİRİLMEDİ)
--     KOŞULSUZ tekrar kullanımıdır (gurme-şartı YOK -- her keş bu eşiğin
--     altını reddeder).
--   - Satış tutarı = Min + (Max-Min)*saflık (doğrusal, deterministik).
--   - Bağımlılık birikimi sabit bir artışla (StreetAddictionGainPerSale)
--     ilerler; eşik geçildiğinde devşirme AYNI momentum köprüsünü
--     (server/recruitment.lua Matrix.Recruitment.RecruitStreetNpc) kullanır.
--
-- 0 RESMON: bot tarafı, main.lua'nın master ticker'ından BAĞIMSIZ, kendi
-- Config.Market.StreetDealing.NpcApproachIntervalMs (25sn) aralıklı
-- thread'inde çalışır -- Wait(0) YOK. Oyuncu tarafı tamamen client'ın
-- (client/hud.lua) kendi NpcScanIntervalMs döngüsünün tetiklediği net
-- event'lere tepki verir; bu dosyada sürekli-döngü bir tarama YOKTUR.
-- =====================================================================
Matrix.Market.StreetDealing = Matrix.Market.StreetDealing or {}


local DealingActivePlayers = {}   -- citizenid -> true (yalnizca gercek oyuncular)
local StreetAddiction      = {}   -- 'p:CID' veya 'b:botId' -> birikmis bagimlilik
local BotStreetCash        = {}   -- botId -> henuz eve donmemis riskli nakit


local function StreetDealerKey(kind, id)
    return (kind == 'bot') and ('b:' .. tostring(id)) or ('p:' .. tostring(id))
end


local function AddStreetAddiction(key)
    local level = (StreetAddiction[key] or 0.0) + Config.Market.StreetDealing.StreetAddictionGainPerSale
    StreetAddiction[key] = level
    return level
end


-- Saf fonksiyon (yan etkisi yalnizca dusuk saflikta Buro'ya bir "anlik
-- ihbar" -- mevcut AdvanceDecryption motoruna KUCUK/SABIT bir kazanc
-- eklenir, yeni bir ihbar tablosu ICAT EDILMEZ).
local function ResolveStreetSale(purity, trapHouseId)
    purity = Matrix.Clamp(tonumber(purity) or 0.0, 0.0, 1.0)
    local accepted = purity >= Config.Market.GourmetMinPurity


    if not accepted then
        if trapHouseId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
            Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Bureau.PatternAnalysisGain)
        end
        return false, 0.0
    end


    local cash = Config.Market.StreetDealing.MinSaleCash
        + ((Config.Market.StreetDealing.MaxSaleCash - Config.Market.StreetDealing.MinSaleCash) * purity)
    return true, cash
end


local function IsStreetProduct(itemName)
    for _, product in ipairs(Config.Kitchen.Packaging.Products) do
        if product.item == itemName then return true end
    end
    return false
end


-- ★ Bota kalici atanmis riskli nakdin trap house'a KİLİTLENMESİ.
-- server/main.lua Matrix.CompleteDispatch'in 'arrived' dalindan cagrilir
-- (bkz. main.lua dosya basi FAZ 2 notu). Mevcut Matrix.CashDecay.Deposit
-- (yukarida, DEGISTIRILMEDI) yeniden kullanilir -- YENI bir ekonomi hatti
-- ICAT EDILMEZ.
function Matrix.Market.FlushBotStreetCash(botId, trapHouseId)
    botId = tonumber(botId)
    local amount = botId and BotStreetCash[botId]
    if not amount or amount <= 0.0 then return false end


    BotStreetCash[botId] = nil
    local ok = Matrix.CashDecay.Deposit(trapHouseId, amount)
    if ok then
        Matrix.Log('MARKET', '[SOKAK NAKDI KILITLENDI] Bot #%d: $%.0f -> Trap #%s kirli nakit kasasi.',
            botId, amount, tostring(trapHouseId))
    end
    return ok
end


-- ★ Yakalanan bir botun uzerindeki, henuz eve donup kasaya kilitlenmemis
-- riskli nakdi musadere edilir. server/main.lua'nin 'busted' dalindan cagrilir.
function Matrix.Market.SeizeBotStreetCash(botId)
    botId = tonumber(botId)
    local amount = botId and BotStreetCash[botId]
    if not amount or amount <= 0.0 then return false end


    BotStreetCash[botId] = nil
    Matrix.Log('MARKET', '[SOKAK NAKDI MUSADERE EDILDI] Bot #%d: $%.0f el konuldu.', botId, amount)
    return true
end


-- =====================================================================
-- OYUNCU TARAFI: dealing-mode toggle + satis cozumleme
-- =====================================================================
local function ToggleStreetDealing(src)
    if type(src) ~= 'number' or src <= 0 then return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


    local newState = not DealingActivePlayers[citizenid]
    DealingActivePlayers[citizenid] = newState or nil


    TriggerClientEvent('matrix:client:streetDealing:modeChanged', src, newState)
    Reply(src, newState and 'Sokak satis modu AKTIF -- yakinlardaki musteriler yaklasmaya baslayacak.'
                        or 'Sokak satis modu KAPATILDI.')
    Matrix.Log('MARKET', '[SOKAK SATIS MODU] %s -> %s', citizenid, tostring(newState))
end


-- ★ RegisterNetEvent, hem client'tan gelen ağ event'lerini (K panel) HEM DE
-- aynı kaynaktan RegisterCommand'ın doğrudan çağrısını (bkz. aşağıdaki
-- Config.Market.StreetDealing.DealingModeCommand komutu) tek bir ortak
-- fonksiyonda (ToggleStreetDealing) birleştirir -- mantık İKİ YERDE
-- TEKRARLANMAZ.
RegisterNetEvent('matrix:server:streetDealing:toggle', function()
    ToggleStreetDealing(source)
end)


RegisterCommand(Config.Market.StreetDealing.DealingModeCommand, function(src)
    ToggleStreetDealing(src)
end, false)


-- ★ Client bir slot NUMARASI ILETMEZ -- sunucu, ResolveBotStreetSale ILE
-- AYNI deterministik secim ilkesiyle (en dusuk slot numarali paketlenmis
-- urun) oyuncunun KENDI envanterini kendisi tarar. Bu, client'in "hangi
-- slotta ne var" iddiasina GUVENMEDEN tamamen sunucu-otoriteli kalir.
RegisterNetEvent('matrix:server:streetDealing:attemptSale', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid or not DealingActivePlayers[citizenid] then return end


    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(src) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then
        TriggerClientEvent('matrix:client:streetDealing:saleResult', src, false, nil, false)
        return
    end


    local slot, item
    for s, it in pairs(inv.items) do
        if type(it) == 'table' and type(it.name) == 'string' and IsStreetProduct(it.name) then
            if not slot or s < slot then slot, item = s, it end
        end
    end
    if not slot then
        TriggerClientEvent('matrix:client:streetDealing:saleResult', src, false, nil, false)
        return
    end


    local purity = (item.metadata and tonumber(item.metadata.purity)) or 0.0
    local ped    = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local trapHouseId = coords and FindNearestTrapHouseCoordsForHud(coords)


    local accepted, cash = ResolveStreetSale(purity, trapHouseId)
    if not accepted then
        TriggerClientEvent('matrix:client:streetDealing:saleResult', src, false, nil, false)
        Matrix.Log('MARKET', '[SOKAK SATISI REDDEDILDI] %s: %s saflik=%.3f (esik altinda, Buro anlik ihbar edildi)',
            citizenid, item.name, purity)
        return
    end


    -- ★ CRITICAL FIX: pcall'in GERCEK basari boolean'ini (2. donus degeri)
    -- kontrol etmeden nakit verilirse, torba oyuncunun cebinden hic
    -- eksilmeden nakit tekrar tekrar alinabilir (sinirsiz nakit dupe'u).
    -- Eksilme basarisiz olursa nakit verme islemi ANINDA 'return' ile kesilir.
    local removeOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, item.name, 1, item.metadata, slot)
    end)
    if not (removeOk and removed == true) then
        TriggerClientEvent('matrix:client:streetDealing:saleResult', src, false, nil, false)
        Matrix.Log('MARKET',
            '[KRITIK] attemptSale: %s icin %s envanterden cikarilamadi -- nakit VERILMEDI.',
            citizenid, tostring(item.name))
        return
    end


    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if ok and player then
        pcall(function() player.Functions.AddMoney('cash', cash, 'street-dealing-sale') end)
    end


    local level    = AddStreetAddiction(StreetDealerKey('player', citizenid))
    local eligible = level >= Config.Market.StreetDealing.RecruitAddictionThreshold

      -- [SESSION 4] Street overdose escalation hook (player path)
    local _toxA = (item.metadata and tonumber(item.metadata.toxicity)) or 0.0
    if _toxA > (Config.ChemicalWorkbench and Config.ChemicalWorkbench.OdToxicityThreshold or 45.0)
        and Matrix.ChemicalWorkbench and Matrix.ChemicalWorkbench.CheckAndTriggerOD then
        SetTimeout(0, function()
            Matrix.ChemicalWorkbench.CheckAndTriggerOD(item.metadata, coords, trapHouseId)
        end)
    end
    -- [SESSION 4] END hook
    TriggerClientEvent('matrix:client:streetDealing:saleResult', src, true, cash, eligible)

    Matrix.Log('MARKET', '[SOKAK SATISI] %s: %s saflik=%.3f -> $%.0f (bagimlilik=%.1f, devsirmeyeHazir=%s)',
        citizenid, item.name, purity, cash, level, tostring(eligible))
end)


-- ★ Client, bir "keş" NPC'sinin devşirme mesafesine (RecruitDistance)
-- girdiğini VE bağımlılık eşiğinin zaten aşıldığını gördüğünde tetikler.
-- Sunucu NPC'nin son bilinen konumunu (npcCoords -- kozmetik, ambient bir
-- ped'in konumu, server-authoritative bir varlık DEĞİL) kendi oyuncu
-- konumuyla karşılaştırarak BAĞIMSIZ doğrular.
RegisterNetEvent('matrix:server:streetDealing:recruit', function(npcCoords, npcLabel)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return end


    local key = StreetDealerKey('player', citizenid)
    if (StreetAddiction[key] or 0.0) < Config.Market.StreetDealing.RecruitAddictionThreshold then
        Reply(src, 'Bu bolgede henuz devsirmeye hazir bir keş yok.'); return
    end


    local ped    = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    if not coords or not npcCoords or #(coords - npcCoords) > Config.Market.StreetDealing.RecruitDistance then
        Reply(src, 'Devsirmek icin keşe yeterince yakin degilsiniz.'); return
    end


    local trapHouseId = FindNearestTrapHouseCoordsForHud(coords)
    -- ★ [MADDE 4] loyalty_base=1.0: Ox_Target "Kadroya Kat" tetigiyle
    -- gelen tek gercek devsirme yolu -- bkz. server/recruitment.lua
    -- RecruitStreetNpc yorumu.
    local bot = Matrix.Recruitment.RecruitStreetNpc(npcLabel, trapHouseId, 1.0)
    StreetAddiction[key] = 0.0


    Reply(src, ('"%s" devsirildi -> Bot #%d (loyalty_base=%.2f).'):format(tostring(npcLabel or 'Sokak Ajani'), bot.id, bot.psychology.loyalty_base))
end)


-- =====================================================================
-- BOT TARAFI: 'street_dealing' aktivitesindeki dealer botlari icin
-- headless (ped/gorsel YOK -- diger bot aktiviteleriyle AYNI istatistiksel
-- model, bkz. server/workbench.lua Paketleme Odasi yorumu) periyodik satis.
-- =====================================================================
local function ResolveBotStreetSale(botId, bot)
    local inventoryId = ('dealer_%d'):format(botId)
    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(inventoryId) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return end


    -- Deterministik secim: en dusuk slot numarali paketlenmis urun.
    local chosenSlot, chosenItem
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' and IsStreetProduct(item.name) then
            if not chosenSlot or slot < chosenSlot then
                chosenSlot, chosenItem = slot, item
            end
        end
    end
    if not chosenSlot then return end


    local purity = (chosenItem.metadata and tonumber(chosenItem.metadata.purity)) or 0.0
    local trapHouseId = bot.state.trap_house_id
    local accepted, cash = ResolveStreetSale(purity, trapHouseId)


    if not accepted then
        Matrix.Log('MARKET', '[SOKAK SATISI REDDEDILDI] Bot #%d: %s saflik=%.3f (esik altinda, Buro anlik ihbar edildi)',
            botId, chosenItem.name, purity)
        return
    end


    -- ★ CRITICAL FIX: RemoveItem'in GERCEK basari boolean'i kontrol edilmeden
    -- BotStreetCash sisirilirse, bot envanterinden urun hic eksilmeden
    -- sinirsiz nakit birikimi mumkun olurdu. Basarisiz olursa 'return' ile
    -- ANINDA kesilir.
    local removeOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(inventoryId, chosenItem.name, 1, chosenItem.metadata, chosenSlot)
    end)
    if not (removeOk and removed == true) then
        Matrix.Log('MARKET',
            '[KRITIK] ResolveBotStreetSale: Bot #%d icin %s envanterden cikarilamadi -- nakit BIRIKTIRILMEDI.',
            botId, tostring(chosenItem.name))
        return
    end


    BotStreetCash[botId] = (BotStreetCash[botId] or 0.0) + cash
    local level = AddStreetAddiction(StreetDealerKey('bot', botId))
   
        -- [SESSION 4] Street overdose escalation hook (bot path)
    local _toxB = (chosenItem.metadata and tonumber(chosenItem.metadata.toxicity)) or 0.0
    if _toxB > (Config.ChemicalWorkbench and Config.ChemicalWorkbench.OdToxicityThreshold or 45.0)
        and Matrix.ChemicalWorkbench and Matrix.ChemicalWorkbench.CheckAndTriggerOD then
        local botCoords = bot.state and bot.state.coords
        SetTimeout(0, function()
            Matrix.ChemicalWorkbench.CheckAndTriggerOD(chosenItem.metadata, botCoords, trapHouseId)
        end)
    end
    -- [SESSION 4] END hook

    Matrix.Log('MARKET', '[SOKAK SATISI] Bot #%d: %s saflik=%.3f -> $%.0f (biriken riskli nakit=%.0f, bagimlilik=%.1f, devsirmeyeHazir=%s)',
        botId, chosenItem.name, purity, cash, BotStreetCash[botId], level,
        tostring(level >= Config.Market.StreetDealing.RecruitAddictionThreshold))
end


CreateThread(function()
    while true do
        Wait(Config.Market.StreetDealing.NpcApproachIntervalMs)
        for botId, bot in pairs(Matrix.Bots or {}) do
            if bot.role == 'dealer' and bot.state.activity == 'street_dealing' then
                local ok, err = pcall(ResolveBotStreetSale, botId, bot)
                if not ok then
                    Matrix.Log('MARKET', '[HATA] Bot #%d sokak satisi hata verdi (yutuldu): %s', botId, tostring(err))
                end
            end
        end
    end
end)


-- ★ F10 "Sokak Satisina Cikar/Geri Cek" (client/hud.lua botAksiyonlari)
-- bu fonksiyonu cagirir -- workbench.lua'nin TogglePackagingRoom ILE AYNI
-- yetki/aktivite-degistirme deseni.
function Matrix.Market.StreetDealing.SetBotDealing(src, botId, active)
    botId = tonumber(botId)
    local bot = botId and Matrix.Bots[botId]
    if not bot or bot.role ~= 'dealer' then return false, 'bad_bot_id' end
    if not Matrix.Hierarchy.HasCommandAuthority((Matrix.GetOrCreatePlayerState(src) or {}).citizenid or '') then
        return false, 'no_authority'
    end


    if active then
        bot.state.activity = 'street_dealing'
    elseif bot.state.activity == 'street_dealing' then
        bot.state.activity = 'idle'
    end


    Matrix.Log('MARKET', '[SOKAK SATISI] Bot #%d aktivite -> %s (tetikleyen:%s)', botId, bot.state.activity, tostring(src))
    return true, bot.state.activity
end


RegisterCommand('botsokaga', function(src, args)
    local botId = tonumber(args[1])
    local active = args[2] ~= 'geri'
    if not botId then Reply(src, 'Kullanim: /botsokaga [botId] [geri]'); return end


    local ok, reasonOrActivity = Matrix.Market.StreetDealing.SetBotDealing(src, botId, active)
    if ok then
        Reply(src, ('Bot #%d aktivite: %s'):format(botId, reasonOrActivity))
    else
        Reply(src, reasonOrActivity == 'no_authority'
            and 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'
            or 'Gecersiz bot ID veya dealer degil.')
    end
end, false)


-- ★ F10 "Canli Kes Satis Sayaclari" paneli (getRegionalFinancialReport ILE
-- AYNI desen: duz metin satirlari).
lib.callback.register('matrix:callback:getStreetDealingReport', function(src)
    local lines = { '=== CANLI KES SATIS SAYAÇLARI ===' }


    local activeCount = 0
    for _ in pairs(DealingActivePlayers) do activeCount = activeCount + 1 end
    lines[#lines + 1] = ('Aktif sokak saticisi (oyuncu): %d'):format(activeCount)


    local anyBot = false
    for botId, bot in pairs(Matrix.Bots or {}) do
        if bot.role == 'dealer' and bot.state.activity == 'street_dealing' then
            anyBot = true
            local key = StreetDealerKey('bot', botId)
            local level = StreetAddiction[key] or 0.0
            lines[#lines + 1] = ('Bot #%d (%s) | Biriken-Riskli-Nakit:$%.0f | Bagimlilik:%.1f/%.0f | Devsirmeye-Hazir:%s'):format(
                botId, bot.name, BotStreetCash[botId] or 0.0, level,
                Config.Market.StreetDealing.RecruitAddictionThreshold,
                tostring(level >= Config.Market.StreetDealing.RecruitAddictionThreshold))
        end
    end
    if not anyBot then
        lines[#lines + 1] = 'Sokakta aktif satis yapan bot yok.'
    end


    return lines
end)


RegisterCommand('sokaksatisrapor', function(src)
    local report = {}
    local activeCount = 0
    for _ in pairs(DealingActivePlayers) do activeCount = activeCount + 1 end
    Reply(src, ('Aktif sokak saticisi (oyuncu): %d'):format(activeCount))
    for botId, bot in pairs(Matrix.Bots or {}) do
        if bot.role == 'dealer' and bot.state.activity == 'street_dealing' then
            local level = StreetAddiction[StreetDealerKey('bot', botId)] or 0.0
            Reply(src, ('Bot #%d (%s) | Riskli-Nakit:$%.0f | Bagimlilik:%.1f/%.0f'):format(
                botId, bot.name, BotStreetCash[botId] or 0.0, level, Config.Market.StreetDealing.RecruitAddictionThreshold))
        end
    end
end, false)


-- =====================================================================
-- DIRTY-SET FLUSH THREAD
-- =====================================================================
CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyMarketZones()
        FlushDirtyCash()
        FlushDirtyZoneLedger()
    end
end)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('GetRank',              function(cid) return Matrix.Hierarchy.GetRank(cid) end)
exports('HasCommandAuthority',  function(cid) return Matrix.Hierarchy.HasCommandAuthority(cid) end)
exports('SetRank',              function(cid, rank, by) return Matrix.Hierarchy.SetRank(cid, rank, by) end)


exports('EvaluateSale',         function(zoneId, cid, cog, purity, ballisticId, saleGrams)
    return Matrix.Market.EvaluateSale(zoneId, cid, cog, purity, ballisticId, saleGrams)
end)
exports('FindNearestMarketZone',function(coords) return Matrix.Market.FindNearestZone(coords) end)


exports('StartRadioSilence',    function(cid, minutes) return Matrix.RadioSilence.Start(cid, minutes) end)
exports('IsRadioSilent',        function(cid) return Matrix.RadioSilence.IsActive(cid) end)
exports('GuardBotDispatch',     function(src) return Matrix.RadioSilence.GuardBotDispatch(src) end)
exports('BreakRadioSilenceForRedirect', function(cid, botId, trapHouseId)
    return Matrix.RadioSilence.BreakForRedirect(cid, botId, trapHouseId)
end)


exports('DepositDirtyCash',     function(trapHouseId, amount) return Matrix.CashDecay.Deposit(trapHouseId, amount) end)
exports('LaunderDirtyCash',     function(trapHouseId, amount) return Matrix.CashDecay.Launder(trapHouseId, amount) end)


exports('IsUndercoverAgent',    function(cid) return Matrix.Undercover.IsUndercoverAgent(cid) end)


exports('AssignInspector',      function(zoneId, botId, assignerCid) return Matrix.Inspector.AssignInspector(zoneId, botId, assignerCid) end)
exports('IsMoleFlagged',        function(botId) return Matrix.Inspector.IsMoleFlagged(botId) end)
exports('ClearMoleFlag',        function(botId) return Matrix.Inspector.ClearMoleFlag(botId) end)


exports('RecordZoneRevenue',    function(zoneId, grams, priceMultiplier) return Matrix.Market.RecordZoneRevenue(zoneId, grams, priceMultiplier) end)


exports('FlushBotStreetCash',   function(botId, trapHouseId) return Matrix.Market.FlushBotStreetCash(botId, trapHouseId) end)
exports('SeizeBotStreetCash',   function(botId) return Matrix.Market.SeizeBotStreetCash(botId) end)
exports('SetBotStreetDealing',  function(src, botId, active) return Matrix.Market.StreetDealing.SetBotDealing(src, botId, active) end)

-- =====================================================================
-- ★★★ FAZ 4 — ESCROW + MASS CAP + PROGRESSIVE SABOTAJ ★★★
-- [MATRIX:HARDCORE_FRICTION_FINALIZE]
-- =====================================================================

Matrix.BankingEscrow = Matrix.BankingEscrow or {}

CreateThread(function()
    while true do
        Wait(60000)
        local nowEpoch = os.time()
        local matured = MySQL.query.await([[
            SELECT id, citizenid, amount FROM matrix_banking_escrow
            WHERE status = 'processing' AND release_epoch <= ?
            LIMIT 200
        ]], { nowEpoch }) or {}

        for _, row in ipairs(matured) do
            local cas = MySQL.update.await([[
                UPDATE matrix_banking_escrow
                SET status = 'released'
                WHERE id = ? AND status = 'processing'
            ]], { row.id })

            if type(cas) == 'number' and cas > 0 then
                local targetPlayer = nil
                local playersOk, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
                if playersOk and type(players) == 'table' then
                    for _, p in pairs(players) do
                        if p and p.PlayerData and p.PlayerData.citizenid == row.citizenid then
                            targetPlayer = p; break
                        end
                    end
                end

                if targetPlayer then
                    pcall(function()
                        targetPlayer.Functions.AddMoney('bank', row.amount, 'escrow-release')
                    end)
                else
                    pcall(function()
                        MySQL.update.await(
                            "UPDATE players SET money = JSON_SET(money, '$.bank', COALESCE(JSON_EXTRACT(money, '$.bank'), 0) + ?) WHERE citizenid = ?",
                            { row.amount, row.citizenid })
                    end)
                end

                Matrix.Log('MARKET',
                    '[ESCROW SERBEST] id=%d %s $%.0f banka hesabina aktarildi (24h doldu).',
                    row.id, row.citizenid, row.amount)
            end
        end
    end
end)

function Matrix.BankingEscrow.Confiscate(trapHouseId, reason)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return 0 end
    local ok, affected = pcall(function()
        return MySQL.update.await([[
            UPDATE matrix_banking_escrow
            SET status = 'confiscated', confiscated_by = ?
            WHERE trap_house_id = ? AND status = 'processing'
        ]], { reason or 'federal_seizure', trapHouseId })
    end)
    if ok and type(affected) == 'number' and affected > 0 then
        Matrix.Log('MARKET',
            '[IRS/MASAK EL KOYMA] Trap #%d: %d processing escrow kaydi FEDERAL olarak muhurlendi (sebep: %s).',
            trapHouseId, affected, tostring(reason))
        return affected
    end
    return 0
end

AddEventHandler('matrix:internal:raidIssued', function(trapHouseId)
    pcall(Matrix.BankingEscrow.Confiscate, trapHouseId, 'federal_raid')
end)

AddEventHandler('matrix:internal:bureauLockdown', function(trapHouseId, active)
    if active then
        pcall(Matrix.BankingEscrow.Confiscate, trapHouseId, 'bureau_lockdown')
    end
end)

local STASH_MASS_CAP_KG = 150.0

CreateThread(function()
    Wait(6000)
    local count = 0
    for trapHouseId, house in pairs(Matrix.TrapHouses or {}) do
        local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
        local label   = ((house.label or ('Trap #' .. trapHouseId)) .. ' Deposu')
        pcall(function()
            exports['ox_inventory']:RegisterStash(stashId, label, 100, STASH_MASS_CAP_KG * 1000)
        end)
        count = count + 1
    end
    Matrix.Log('MARKET', '[FAZ 4][KUTLE KAP] %d trap stash %.0f kg ile muhurlendi.', count, STASH_MASS_CAP_KG)
end)

function Matrix.Market.CanDepositToStash(trapHouseId, newItemWeight)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return false, 'bad_trap' end
    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(stashId) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then
        return false, 'stash_unavailable'
    end
    local current = 0.0
    for _, item in pairs(inv.items) do
        if type(item) == 'table' then
            current = current + ((tonumber(item.weight) or 0.0) * (tonumber(item.count) or 0.0))
        end
    end
    if (current + (tonumber(newItemWeight) or 0.0)) > (STASH_MASS_CAP_KG * 1000) then
        return false, 'mass_cap_exceeded'
    end
    return true, current
end

local WEEKLY_DEGRADE_INTERVAL_S = 7 * 24 * 3600

local function _GetWeeklyDegradeEpoch()
    local ok, row = pcall(function()
        return MySQL.single.await(
            "SELECT value FROM matrix_kv WHERE key_name = 'weekly_degradation_epoch' LIMIT 1")
    end)
    if not ok then return 0 end
    if row and row.value then
        local v = tonumber(row.value)
        if v and v == v then return v end
    end
    return 0
end

local function _SetWeeklyDegradeEpoch(epoch)
    pcall(function()
        MySQL.prepare([[
            INSERT INTO matrix_kv (key_name, value, updated_at)
            VALUES ('weekly_degradation_epoch', ?, NOW())
            ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = NOW()
        ]], { tostring(epoch) })
    end)
end

local function _RunWeeklyDegradation()
    local affectedPurity, affectedWear = 0, 0
    for trapHouseId in pairs(Matrix.TrapHouses or {}) do
        local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
        local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(stashId) end)
        if invOk and type(inv) == 'table' and type(inv.items) == 'table' then
            for slot, item in pairs(inv.items) do
                if type(item) == 'table' and type(item.name) == 'string' then
                    local meta = item.metadata or {}
                    if type(meta.purity) == 'number' then
                        local newPurity = math.max(meta.purity - 0.05, 0.0)
                        pcall(function()
                            local merged = {}
                            for k, v in pairs(meta) do merged[k] = v end
                            merged.purity = newPurity
                            exports['ox_inventory']:SetMetadata(stashId, slot, merged)
                        end)
                        affectedPurity = affectedPurity + 1
                    end
                    if item.name:sub(1, 7) == 'weapon_' then
                        local wear    = tonumber(meta.wear_level) or 0.0
                        local newWear = math.min(wear + 0.08, 1.0)
                        pcall(function()
                            local merged = {}
                            for k, v in pairs(meta) do merged[k] = v end
                            merged.wear_level = newWear
                            exports['ox_inventory']:SetMetadata(stashId, slot, merged)
                        end)
                        affectedWear = affectedWear + 1
                    end
                end
            end
        end
    end
    Matrix.Log('MARKET',
        '[FAZ 4][HAFTALIK BOZULMA] %d urun safligi -0.05, %d silah wear_level +0.08.',
        affectedPurity, affectedWear)
end

CreateThread(function()
    Wait(10000)
    local last = _GetWeeklyDegradeEpoch()
    local now  = os.time()
    if (now - last) >= WEEKLY_DEGRADE_INTERVAL_S then
        _RunWeeklyDegradation()
        _SetWeeklyDegradeEpoch(now)
        last = now
    end
    while true do
        Wait(60 * 60 * 1000)
        local cur = os.time()
        if (cur - last) >= WEEKLY_DEGRADE_INTERVAL_S then
            _RunWeeklyDegradation()
            _SetWeeklyDegradeEpoch(cur)
            last = cur
        end
    end
end)

Matrix.CyberOps = Matrix.CyberOps or { BySrc = {}, ByTarget = {} }

Matrix.CyberOps.Config = {
    BaseDurationSeconds = 120,
    IqScaleSeconds      = 0.20,
    MinDurationSeconds  = 30,
    MaxDurationSeconds  = 120,
    MaxActorRadiusM     = 3.0,
    StepIntervalMs      = 5000,
    CertaintyDropStep   = 0.20,
    InterruptLeakBump   = 0.30,
    ImmobilizeFlags     = true,
}

Matrix.ForensicOps = Matrix.ForensicOps or { BySrc = {}, ByTarget = {} }

Matrix.ForensicOps.Config = {
    DurationMs          = 90000,
    MaxActorRadiusM     = 3.0,
    StepIntervalMs      = 5000,
    CertaintyDropStep   = 0.20,
    InterruptLeakBump   = 0.30,
    AnimationDict       = 'amb@world_human_maid_clean@',
    AnimationClip       = 'base',
    PropModel           = 'prop_clean_agent',
}

local function _ResolveActingIq(botId)
    if botId and Matrix.Cognition and type(Matrix.Cognition.GetEffectiveIq) == 'function' then
        local ok, iq = pcall(Matrix.Cognition.GetEffectiveIq, botId)
        if ok and type(iq) == 'number' and iq == iq then return iq end
    end
    return 100
end

local function _ComputeCyberDurationMs(botId)
    local cfg = Matrix.CyberOps.Config
    local iq  = _ResolveActingIq(botId)
    local s   = cfg.BaseDurationSeconds - (iq * cfg.IqScaleSeconds)
    if s < cfg.MinDurationSeconds then s = cfg.MinDurationSeconds end
    if s > cfg.MaxDurationSeconds then s = cfg.MaxDurationSeconds end
    return math.floor(s * 1000)
end
Matrix.CyberOps.ComputeDurationMs = _ComputeCyberDurationMs

local function _VerifyAtRouter(src)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then
        return true
    end
    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return false end
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    local routerPos = shell and shell.RouterPos
    if not routerPos then return true end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    local radius = (Config.Forensics and Config.Forensics.RouterSanitization
                        and Config.Forensics.RouterSanitization.Radius) or 2.0
    return #(coords - routerPos) <= radius
end

local function _BumpCyberLeak(trapHouseId, delta)
    if not (Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.__SetHeatRaw) then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    local current = Matrix.Bureau.GetHeat(trapHouseId) or 0.0
    local maxV    = (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
    local next_   = math.min(current + (tonumber(delta) or 0.0), maxV)
    Matrix.Bureau.__SetHeatRaw(trapHouseId, next_)
end

local function _FindNearestTrapHouseId(coords)
    local nearestId, nearestDist = nil, math.huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId
end

local function _AbortCyberOp(src, reason)
    local session = Matrix.CyberOps.BySrc[src]
    if not session then return end
    Matrix.CyberOps.BySrc[src] = nil
    if session.target_key then
        Matrix.CyberOps.ByTarget[session.target_key] = nil
    end
    if session.trap_house_id then
        _BumpCyberLeak(session.trap_house_id, Matrix.CyberOps.Config.InterruptLeakBump)
        Matrix.Log('MARKET',
            '[SIBER OP IPTAL] src=%d trap=%d sebep=%s -- +%.2f cyber_leak, LSPD sorgusu tetiklendi.',
            src, session.trap_house_id, tostring(reason), Matrix.CyberOps.Config.InterruptLeakBump)
    end
    TriggerClientEvent('matrix:client:cyberOpAborted', src, reason)
end

local function _CompleteCyberOp(src)
    local session = Matrix.CyberOps.BySrc[src]
    if not session then return end
    Matrix.CyberOps.BySrc[src] = nil
    if session.target_key then
        Matrix.CyberOps.ByTarget[session.target_key] = nil
    end
    Matrix.Log('MARKET',
        '[SIBER OP TAMAM] src=%d tur=%s -- %d adim, kanit scrub tamamlandi.',
        src, tostring(session.op_type), session.steps_done or 0)
    TriggerClientEvent('matrix:client:cyberOpCompleted', src, session.op_type)
end

local function _StepCyberScrub(session)
    if not session.dna_id then return end
    local drop = Matrix.CyberOps.Config.CertaintyDropStep
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_cctv_logs
            SET cctv_certainty = GREATEST(0.0, cctv_certainty - ?)
            WHERE dna_id = ? AND created_at >= (NOW() - INTERVAL 30 MINUTE)
        ]], { drop, session.dna_id })
    end)
    pcall(function()
        MySQL.update.await([[
            DELETE FROM matrix_cctv_logs
            WHERE dna_id = ? AND cctv_certainty <= 0.0
        ]], { session.dna_id })
    end)
end

local function _StepForensicScrub(session)
    local drop = Matrix.ForensicOps.Config.CertaintyDropStep
    if not session.evidence_id then return end
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_forensic_evidence
            SET match_certainty = GREATEST(0.0, match_certainty - ?)
            WHERE id = ?
        ]], { drop, session.evidence_id })
    end)
    pcall(function()
        MySQL.update.await([[
            UPDATE matrix_forensic_evidence
            SET scrubbed = 1
            WHERE id = ? AND match_certainty <= 0.0
        ]], { session.evidence_id })
    end)
    pcall(function()
        MySQL.update.await(
            'DELETE FROM matrix_forensic_evidence WHERE id = ? AND scrubbed = 1',
            { session.evidence_id })
    end)
end

CreateThread(function()
    while true do
        Wait(500)
        local now = GetGameTimer()
        for src, session in pairs(Matrix.CyberOps.BySrc) do
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 then
                Matrix.CyberOps.BySrc[src] = nil
            else
                local coords = GetEntityCoords(ped)
                if not session.actor_coords then session.actor_coords = coords end
                if #(coords - session.actor_coords) > Matrix.CyberOps.Config.MaxActorRadiusM then
                    _AbortCyberOp(src, 'distance_broken')
                elseif now >= session.end_ts then
                    _CompleteCyberOp(src)
                elseif now >= session.next_step_ts then
                    session.next_step_ts = now + Matrix.CyberOps.Config.StepIntervalMs
                    session.steps_done   = (session.steps_done or 0) + 1
                    if session.op_type == 'cctv' then
                        _StepCyberScrub(session)
                    elseif session.op_type == 'forensic' then
                        _StepForensicScrub(session)
                    end
                end
            end
        end
    end
end)

RegisterCommand('kameralogutemizle', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    if not _VerifyAtRouter(src) then
        Reply(src, 'Router kutusunun yaninda degilsiniz.'); return
    end
    if Matrix.CyberOps.BySrc[src] then
        Reply(src, 'Zaten aktif bir siber operasyonunuz var.'); return
    end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid or not state.dna_id then
        Reply(src, 'Profil cozulemedi.'); return
    end
    local botId = tonumber(args[1])
    local durationMs = _ComputeCyberDurationMs(botId)
    local ped = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local trapHouseId = coords and _FindNearestTrapHouseId(coords)
    local session = {
        src           = src,
        citizenid     = state.citizenid,
        dna_id        = state.dna_id,
        op_type       = 'cctv',
        target_key    = 'cctv:' .. state.dna_id,
        trap_house_id = trapHouseId,
        started_ts    = GetGameTimer(),
        end_ts        = GetGameTimer() + durationMs,
        next_step_ts  = GetGameTimer() + Matrix.CyberOps.Config.StepIntervalMs,
        steps_done    = 0,
        actor_coords  = coords,
    }
    Matrix.CyberOps.BySrc[src] = session
    Matrix.CyberOps.ByTarget[session.target_key] = true
    TriggerClientEvent('matrix:client:cyberOpStart', src,
        'cyber_erase', durationMs, Matrix.CyberOps.Config.MaxActorRadiusM)
    Reply(src, ('[SIBER OP] Kamera veri temizligi baslatildi (%dms). Hareket etmeyin.'):format(durationMs))
end, false)

RegisterCommand('delilkarart', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    local evidenceId = tonumber(args[1])
    if not evidenceId then Reply(src, 'Kullanim: /delilkarart [evidenceId]'); return end
    if Matrix.CyberOps.BySrc[src] then
        Reply(src, 'Zaten aktif bir operasyonunuz var.'); return
    end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then Reply(src, 'Profil cozulemedi.'); return end
    local row = MySQL.single.await(
        'SELECT id, match_certainty FROM matrix_forensic_evidence WHERE id = ?',
        { evidenceId })
    if not row then Reply(src, 'Bu ID ile kayitli bir adli kanit yok.'); return end
    local ped = GetPlayerPed(src)
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local trapHouseId = coords and _FindNearestTrapHouseId(coords)
    local cfg = Matrix.ForensicOps.Config
    local session = {
        src           = src,
        citizenid     = state.citizenid,
        evidence_id   = evidenceId,
        op_type       = 'forensic',
        target_key    = 'forensic:' .. tostring(evidenceId),
        trap_house_id = trapHouseId,
        started_ts    = GetGameTimer(),
        end_ts        = GetGameTimer() + cfg.DurationMs,
        next_step_ts  = GetGameTimer() + cfg.StepIntervalMs,
        steps_done    = 0,
        actor_coords  = coords,
    }
    Matrix.CyberOps.BySrc[src] = session
    Matrix.CyberOps.ByTarget[session.target_key] = true
    TriggerClientEvent('matrix:client:forensicAcidStart', src,
        evidenceId, cfg.DurationMs, cfg.MaxActorRadiusM,
        cfg.AnimationDict, cfg.AnimationClip, cfg.PropModel)
    Reply(src, ('[ADLI ASIT] Delil #%d icin 90sn kimyasal eritme baslatildi.'):format(evidenceId))
end, false)

RegisterNetEvent('matrix:server:cyberOpInterrupted', function(opType, reason)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if Matrix.CyberOps.BySrc[src] then
        _AbortCyberOp(src, type(reason) == 'string' and reason or 'client_interrupt')
    end
end)

RegisterCommand('escrowdurum', function(src)
    local rows = MySQL.query.await([[
        SELECT status, COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total
        FROM matrix_banking_escrow
        GROUP BY status
    ]], {}) or {}
    if #rows == 0 then Reply(src, 'Escrow kaydi yok.'); return end
    for _, r in ipairs(rows) do
        Reply(src, ('[ESCROW] %s: %d kayit | $%.0f toplam'):format(
            tostring(r.status), tonumber(r.n) or 0, tonumber(r.total) or 0))
    end
end, false)

exports('ConfiscateEscrow', function(trapHouseId, reason)
    return Matrix.BankingEscrow.Confiscate(trapHouseId, reason)
end)
exports('CanDepositToStash', function(trapHouseId, weight)
    return Matrix.Market.CanDepositToStash(trapHouseId, weight)
end)
exports('GetStashMassCapKg', function() return STASH_MASS_CAP_KG end)