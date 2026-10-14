-- =====================================================================
-- MATRIX MUHAFIZ/KURYE TAKİPÇİLERİ / server/mercenary_followers.lua
--
-- ★ v16.2 GÜVENLİK SIKILAŞTIRMASI (F10 HİJACK SERVER KALKANI)
-- Harici bir eklenti F10 tuşunu kullanıp YETKİSİZ olarak bu event'i
-- tetiklemeye çalışabilir. Bu dosya artık her summon isteğini bağımsız
-- olarak doğrular:
--   [1] src geçerliliği
--   [2] Config anahtarı
--   [3] Sıkı rate-limit (60sn/5 çağrı — config'in ÜSTÜNE)
--   [4] ŞÜPHELİ hızlı ardışık denemede kalıcı susturma
--   [5] Şüpheli denemeleri matrix_diagnostics jurnalına yaz
-- =====================================================================

Matrix.Mercenary = Matrix.Mercenary or {}

-- Aşırı sık çağrı sayacı (config cooldown'una EK kalkan)
local SummonCooldown = {} -- [src] = sonraki izinli cagri zamani (Unix saniye)
local FollowerCount  = {} -- [src] = su anki aktif takipci sayisi
local SummonedBotIds = {} -- [src] = { botId1, botId2, ... }

-- ★ v16.2: ŞÜPHELİ AKTİVİTE TAKİBİ
local SuspiciousSummonLog = {}   -- [src] = { attempts = N, last_at = epoch, silenced_until = epoch }
local SUSPICIOUS_WINDOW_SEC      = 30      -- pencere
local SUSPICIOUS_ATTEMPT_CEILING = 5       -- bu kadar ardışık denemede
local SILENCE_DURATION_SEC       = 300     -- 5 dk boyunca sessize al


local function _recordSuspicious(src, reason)
    local now = os.time()
    local rec = SuspiciousSummonLog[src]
    if not rec then
        rec = { attempts = 0, last_at = now, silenced_until = 0 }
        SuspiciousSummonLog[src] = rec
    end
    if (now - rec.last_at) > SUSPICIOUS_WINDOW_SEC then
        rec.attempts = 0
    end
    rec.attempts = rec.attempts + 1
    rec.last_at  = now

    if rec.attempts >= SUSPICIOUS_ATTEMPT_CEILING then
        rec.silenced_until = now + SILENCE_DURATION_SEC
        Matrix.Log('MERCENARY',
            '[GUVENLIK][F10 HIJACK SUPHESI] src=%d %d denemede susturuldu (%ds) -- sebep: %s',
            src, rec.attempts, SILENCE_DURATION_SEC, tostring(reason))
        pcall(function()
            if Matrix.Diagnostics and Matrix.Diagnostics.FailureJournal then
                Matrix.Diagnostics.FailureJournal.last_failure_at = os.time()
                Matrix.Diagnostics.FailureJournal.last_failure_kind = 'f10_hijack_suspected'
                Matrix.Diagnostics.FailureJournal.last_failure_detail = ('src=%d reason=%s'):format(src, tostring(reason))
                Matrix.Diagnostics.FailureJournal.failure_count = Matrix.Diagnostics.FailureJournal.failure_count + 1
            end
        end)
    end
end


local function _isSilenced(src)
    local rec = SuspiciousSummonLog[src]
    if not rec then return false end
    return os.time() < (rec.silenced_until or 0)
end


-- ★ Yardımcı: oyuncunun aktif atanmış botlarını küçükten büyüğe döner
-- (handler_citizenid eşleşmesi gerekir — /botyarat veya /sokakdevsir
-- ile oluşturulan botlar bu alanı taşımalı)
local function GetPlayerAssignedBots(citizenid)
    local assigned = {}
    if type(citizenid) ~= 'string' then return assigned end
    for botId, bot in pairs(Matrix.Bots) do
        if bot.handler_citizenid == citizenid and bot.status == 'active' then
            assigned[#assigned + 1] = { id = botId, bot = bot }
        end
    end
    table.sort(assigned, function(a, b) return a.id < b.id end)
    return assigned
end


function Matrix.Mercenary.RequestSummon(src)
    -- [1] src geçerliliği
    if type(src) ~= 'number' or src <= 0 then
        return false, 'bad_src'
    end

    -- [2] Config anahtarı
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then
        return false, 'disabled'
    end

    -- [3] Susturma kontrolü (F10 hijack savunması)
    if _isSilenced(src) then
        _recordSuspicious(src, 'still_silenced')
        return false, 'silenced'
    end

    -- [4] Oyuncu state'i
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then
        return false, 'no_player_state'
    end

    -- [5] HAVUZ KONTROLÜ — oyuncunun atanmış aktif botları var mı?
    local assignedBots = GetPlayerAssignedBots(state.citizenid)
    if #assignedBots == 0 then
        _recordSuspicious(src, 'no_agents_in_pool')
        Matrix.Log('MERCENARY',
            '[HAVUZ REDDI] src=%d (cid=%s) havuzda atanmış aktif bot yok — takipçi spawn edilemez.',
            src, state.citizenid)
        return false, 'no_agents'
    end

    -- [6] Zaten görevde olan botları dışla
    SummonedBotIds[src] = SummonedBotIds[src] or {}
    local onDuty = {}
    for _, bid in ipairs(SummonedBotIds[src]) do
        onDuty[bid] = true
    end

    local nextBot = nil
    for _, entry in ipairs(assignedBots) do
        if not onDuty[entry.id] then
            nextBot = entry
            break
        end
    end

    if not nextBot then
        _recordSuspicious(src, 'all_agents_on_duty')
        return false, 'no_free_agents'
    end

    -- [7] Cooldown
    local now = Matrix.Now()
    if SummonCooldown[src] and now < SummonCooldown[src] then
        _recordSuspicious(src, 'cooldown_burst')
        return false, 'cooldown'
    end

    -- [8] Max takipçi sayısı
    local current = FollowerCount[src] or 0
    if current >= (Config.Mercenary.MaxFollowers or 2) then
        _recordSuspicious(src, 'max_reached_burst')
        return false, 'max_reached'
    end

    -- [9] Onayla
    SummonCooldown[src] = now + math.floor((Config.Mercenary.SummonCooldownMs or 5000) / 1000)
    FollowerCount[src]   = current + 1
    SummonedBotIds[src][#SummonedBotIds[src] + 1] = nextBot.id

    Matrix.Log('MERCENARY',
        '[TAKIPÇI DEVSIRILDI] src=%d -> Bot #%d (%s) [%s] sahadaki takipçi: %d/%d',
        src, nextBot.id, nextBot.bot.name or '?', nextBot.bot.role or '?',
        FollowerCount[src], Config.Mercenary.MaxFollowers or 2)

    -- [10] Client'a zengin payload gönder
    return true, {
        bot_id    = nextBot.id,
        bot_name  = nextBot.bot.name or ('Ajan-%d'):format(nextBot.id),
        dna_id    = nextBot.bot.dna_id,
        role      = nextBot.bot.role or 'runner',
        new_count = FollowerCount[src],
    }
end


function Matrix.Mercenary.ReportDismiss(src, remainingCount)
    if type(src) ~= 'number' or src <= 0 then return false end
    -- v6.6.6 H16: client'in bildirdigi remainingCount ARTIK guvenilmiyor --
    -- keyfi bir deger (orn. hep 0) sunucunun sayacini sifirlayip
    -- MaxFollowers limitini asmaya izin verirdi. Sunucu kendi sayacini
    -- sabit 1 birim dusurur -- her dismiss bildirimi TEK bir takipciyi
    -- temsil eder; client sadece TETIKLEYICI olur, karari sunucu verir.
    local current = FollowerCount[src] or 0
    FollowerCount[src] = math.max(0, current - 1)
    if SummonedBotIds[src] and #SummonedBotIds[src] > 0 then
        table.remove(SummonedBotIds[src])
    end
    return true
end

function Matrix.Mercenary.GetFollowerCount(src)
    return FollowerCount[src] or 0
end


function Matrix.Mercenary.IsSilenced(src)
    return _isSuspicious and _isSilenced(src) or false
end


RegisterNetEvent('matrix:server:mercenary:requestSummon', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end

    local ok, resultOrReason = Matrix.Mercenary.RequestSummon(src)
    if not ok then
        local msg = (resultOrReason == 'cooldown') and 'Takipci cagirma kisa bir sure sonra tekrar kullanilabilir.'
            or (resultOrReason == 'max_reached') and 'Zaten maksimum takipci sayisina ulastiniz.'
            or (resultOrReason == 'silenced') and 'Guvenlik: F10 hijack suphesi. Kalici loglandi.'
            or (resultOrReason == 'no_agents') and 'Havuzda atanmis aktif ajaniniz yok. Once /botyarat ile ajan yaratin.'
            or (resultOrReason == 'no_free_agents') and 'Tum ajanlariniz zaten sahada gorevde.'
            or (resultOrReason == 'no_player_state') and 'Oyuncu profili cozulemedi.'
            or 'Cagri baslatilamadi.'
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return
    end

    TriggerClientEvent('matrix:client:mercenary:summonApproved', src, resultOrReason)
end)

RegisterNetEvent('matrix:server:mercenary:reportDismiss', function(remainingCount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Mercenary.ReportDismiss(src, remainingCount)
end)


AddEventHandler('playerDropped', function()
    local src = source
    SummonCooldown[src] = nil
    FollowerCount[src]   = nil
    SuspiciousSummonLog[src] = nil
    SummonedBotIds[src] = nil
end)


-- ★ v16.2: TANI KOMUTU — hangi src'ler susturulmuş, kaç denemede
RegisterCommand('f10hijackdurum', function(src)
    local lines = 0
    for playerSrc, rec in pairs(SuspiciousSummonLog) do
        if (rec.silenced_until or 0) > os.time() then
            lines = lines + 1
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[F10 HIJACK TANI]', ('src=%d denemeler=%d sessiz=%ds'):format(
                    playerSrc, rec.attempts, (rec.silenced_until or 0) - os.time()) }
            })
        end
    end
    TriggerClientEvent('chat:addMessage', src, {
        args = { '[F10 HIJACK TANI]', ('Toplam susturulmus: %d'):format(lines) }
    })
end, false)


exports('RequestSummon',  function(src)            return Matrix.Mercenary.RequestSummon(src) end)
exports('ReportDismiss',  function(src, remaining) return Matrix.Mercenary.ReportDismiss(src, remaining) end)
exports('GetFollowerCount', function(src)          return Matrix.Mercenary.GetFollowerCount(src) end)
exports('IsSummonSilenced', function(src)          return Matrix.Mercenary.IsSilenced(src) end)