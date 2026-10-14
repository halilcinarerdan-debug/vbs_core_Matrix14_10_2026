-- =====================================================================
-- MATRIX RECRUITMENT / recruitment.lua
-- Batch UPDATE, async insert, sıfır await ticker.
-- PHASE 5: COERCION MATRIX + REF-1 (Cognitive Recruitment Coercion Loop)
-- =====================================================================


Matrix.Recruitment = Matrix.Recruitment or {}
Matrix.Candidates  = Matrix.Candidates  or {}
Matrix.Sessions    = Matrix.Sessions    or {}
Matrix.Coercions   = Matrix.Coercions   or {} -- PHASE 5 in-flight coercion sessions


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table               = tonumber, table
local math_max, math_floor          = math.max, math.floor
local os_time                       = os.time


local nextCandidateId = 1
local nextSessionId   = 1
local nextCoercionId  = 1


local BIO_FIELDS = {
    'fear_factor', 'resilience', 'snitch_tendency',
    'economic_pressure', 'cognitive_shifter', 'skill_chemistry'
}


-- =====================================================================
-- PHASE 5 CONFIG ACCESSORS (defansif; Config tam olmasa bile çalışır)
-- =====================================================================
local function CoercionCfg()
    local r = (Config and Config.Recruitment) or {}
    local c = r.Coercion or {}
    return {
        MinConditionsMet            = c.MinConditionsMet            or 2,
        AddictionBondThreshold      = c.AddictionBondThreshold      or 80.0,
        MinDistinctLowPurityBatches = c.MinDistinctLowPurityBatches or 3,
        LowPurityCeiling            = c.LowPurityCeiling            or 0.60,
        DurationMs                  = c.DurationMs                  or 60000,
        ProximityAbortDistance      = c.ProximityAbortDistance      or 3.0,
        CyberLeakSpikeOnAbort       = c.CyberLeakSpikeOnAbort       or 0.15,
        FreezeDurationMs            = c.FreezeDurationMs            or 30000
    }
end


-- =====================================================================
-- ASCII SES DALGASI
-- =====================================================================
local function BuildAsciiWaveform(intensity)
    intensity = Matrix.Clamp(tonumber(intensity) or 0.0, 0.0, 1.0)
    local width = (Config.Recruitment and Config.Recruitment.WaveformWidth) or 24
    local filled = math_floor((intensity * width) + 0.5)
    return '[' .. ('|'):rep(filled) .. ('.'):rep(width - filled) .. ']'
end


-- =====================================================================
-- SORGU ÖZNESİ ÇÖZÜMLEMESİ
-- =====================================================================
local function ResolveInterrogationSubject(kind, id)
    if kind == 'bot' then
        local bot = Matrix.Bots and Matrix.Bots[id]
        if not bot then return nil end
        return { kind = 'bot', id = id, name = bot.name, psychology = bot.psychology, ref_key = bot.dna_id }
    end

    local candidate = Matrix.Candidates[id]
    if not candidate then return nil end
    return { kind = 'candidate', id = id, name = candidate.name, psychology = candidate.psychology, ref_key = candidate.citizenid }
end


-- =====================================================================
-- TRAIT DERIVATION (DEĞİŞTİRİLMEDİ)
-- =====================================================================
local function DeriveTraitsFromCustomer(stats)
    if type(stats) ~= 'table' then stats = {} end
    return {
        fear_factor       = Matrix.Clamp((stats.police_encounters_nearby or 0) * 0.10, 0.0, 1.0),
        resilience        = Matrix.Clamp(0.30 + ((stats.completed_deals or 0) * 0.02), 0.0, 1.0),
        snitch_tendency   = Matrix.Clamp((stats.times_reported or 0) * 0.15, 0.0, 1.0),
        economic_pressure = Matrix.Clamp((stats.failed_payments or 0) * 0.12, 0.0, 1.0),
        cognitive_shifter = Matrix.Clamp(0.20 + ((stats.completed_deals or 0) * 0.015), 0.0, 1.0),
        skill_chemistry   = Matrix.Clamp((stats.chemistry_hints or 0) * 0.10, 0.0, 1.0)
    }
end


-- =====================================================================
-- SCAN CUSTOMER POOL (DEĞİŞTİRİLMEDİ)
-- =====================================================================
function Matrix.Recruitment.ScanCustomerPool()
    local rows = MySQL.query.await(
        'SELECT * FROM matrix_customer_pool WHERE promoted_to_candidate = 0 LIMIT 200',
        {}
    ) or {}
    if #rows == 0 then return 0 end

    local momentum  = Matrix.Bureau and Matrix.Bureau.GetPropagandaMomentum and Matrix.Bureau.GetPropagandaMomentum() or 0.0
    local threshold = (Config.Recruitment.BaseEligibilityThreshold) / (1.0 + momentum)

    local promotedCids = {}
    local promotedCount = 0

    for _, row in ipairs(rows) do
        local traits = DeriveTraitsFromCustomer(row)
        local score  = traits.resilience + traits.cognitive_shifter + (1.0 - traits.snitch_tendency)

        if momentum > Config.Recruitment.StreetWhisperMomentumThreshold and (row.times_reported or 0) > 0 then
            Matrix.Log('RECRUITMENT', '[SOKAK KULAKLARI] "%s" hakkında fısıltılar var: %d kez ihbar geçmiş.',
                row.name or row.citizenid, row.times_reported)
        end

        if score >= threshold then
            local cid = nextCandidateId
            nextCandidateId = cid + 1

            Matrix.Candidates[cid] = {
                id            = cid,
                citizenid     = row.citizenid,
                name          = row.name or ('Aday-%d'):format(cid),
                psychology    = traits,
                addiction_level = tonumber(row.addiction_level) or 0.0,
                revealed_fields = {}
            }
            promotedCids[#promotedCids + 1] = row.citizenid
            promotedCount = promotedCount + 1
            Matrix.Log('RECRUITMENT', 'Aday #%d havuzdan çekildi (skor %.2f / eşik %.2f)',
                cid, score, threshold)
        end
    end

    if #promotedCids > 0 then
        local placeholders = {}
        for i = 1, #promotedCids do placeholders[i] = '?' end
        local q = ('UPDATE matrix_customer_pool SET promoted_to_candidate = 1 WHERE citizenid IN (%s)')
                  :format(table.concat(placeholders, ','))
        MySQL.prepare(q, promotedCids)
    end

    return promotedCount
end


-- =====================================================================
-- ============================================================
-- ★ PHASE 5 / REF-1: COERCION MATRIX
-- ============================================================
-- Üç 0-RNG kriminolojik koşuldan en az İKİSİ sağlanmadan hiçbir NPC
-- dönüştürülemez. Her koşul DB veya RAM üzerinden deterministik
-- olarak doğrulanır. RNG yoktur.
--   (A) BIOCHEMICAL BONDING : addiction_level >= 80.0
--   (B) ADLI KOZ (Forensic) : dna_id, matrix_forensic_evidence'ta
--                             sanitized=0 ile eşleşiyor
--   (C) FINANCIAL DEPENDENCY: >= 3 farklı düşük-purity batch satın alma
-- =====================================================================

-- (A) Biyokimyasal bağ
-- targetData: { addiction_level = number }
local function CheckBiochemicalBonding(targetData)
    local cfg = CoercionCfg()
    local addiction = tonumber(targetData and targetData.addiction_level) or 0.0
    local met = addiction >= cfg.AddictionBondThreshold
    return met, { addiction = addiction, threshold = cfg.AddictionBondThreshold }
end

-- (B) Adli koz (forensic leverage)
-- dna_id varsa ve matrix_forensic_evidence'ta sanitize edilmemiş link varsa true.
local function CheckForensicLeverage(dnaId)
    if type(dnaId) ~= 'string' or dnaId == '' then
        return false, { reason = 'no_dna_id' }
    end
    local row = MySQL.single.await([[
        SELECT id AS evidence_id, crime_scene_ref
        FROM matrix_forensic_evidence
        WHERE dna_id = ? AND sanitized = 0
        LIMIT 1
    ]], { dnaId })
    if not row then return false, { reason = 'no_unsanitized_link', dna_id = dnaId } end
    return true, { evidence_id = row.evidence_id, crime_scene_ref = row.crime_scene_ref, dna_id = dnaId }
end

-- (C) Finansal bağımlılık (debt lock)
local function CheckFinancialDependency(citizenid)
    local cfg = CoercionCfg()
    if type(citizenid) ~= 'string' or citizenid == '' then
        return false, { reason = 'no_citizenid' }
    end
    local row = MySQL.single.await([[
        SELECT COUNT(DISTINCT batch_id) AS distinct_batches
        FROM matrix_sales_ledger
        WHERE buyer_citizenid = ? AND purity <= ?
    ]], { citizenid, cfg.LowPurityCeiling })
    local batches = (row and (row.distinct_batches or row['distinct_batches'])) or 0
    local met = tonumber(batches) >= cfg.MinDistinctLowPurityBatches
    return met, { distinct_batches = tonumber(batches) or 0, min_required = cfg.MinDistinctLowPurityBatches }
end

-- Tüm koşulları değerlendirir, hangi koşulların sağlandığını ve sayısını döner.
function Matrix.Recruitment.EvaluateCoercionConditions(targetData)
    if type(targetData) ~= 'table' then return nil end
    local cfg = CoercionCfg()

    local bioMet, bioMeta       = CheckBiochemicalBonding(targetData)
    local dnaId                 = targetData.dna_id
    local forensicMet, foreMeta = CheckForensicLeverage(dnaId)
    local citizenid             = targetData.citizenid
    local financeMet, finMeta   = CheckFinancialDependency(citizenid)

    local metCount = (bioMet and 1 or 0) + (forensicMet and 1 or 0) + (financeMet and 1 or 0)
    return {
        met_count           = metCount,
        required            = cfg.MinConditionsMet,
        eligible            = metCount >= cfg.MinConditionsMet,
        biochemical_bonding = bioMet,
        forensic_leverage   = forensicMet,
        financial_dependency= financeMet,
        meta                = { biochemical = bioMeta, forensic = foreMeta, financial = finMeta }
    }
end

exports('EvaluateCoercionConditions', function(targetData) return Matrix.Recruitment.EvaluateCoercionConditions(targetData) end)


-- =====================================================================
-- COERCION BEGIN (server-authoritative)
-- ---------------------------------------------------------------------
-- clientSource : oyuncu source
-- targetNetId  : hedef ped'in net id'si
-- targetData   : { name, addiction_level, dna_id, citizenid }
--   -> Client tarafı bu veriyi entity state / server-side stub üzerinden
--      toplar; burada KANDİT doğrulanır.
-- =====================================================================
local function BroadcastChat(src, tag, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { tag, msg } })
    else
        print(('[MATRIX:RECRUITMENT:CONSOLE] %s %s'):format(tag, msg))
    end
end

local function AbortCoercion(coercionId, reason, src)
    local c = Matrix.Coercions[coercionId]
    if not c then return end
    Matrix.Coercions[coercionId] = nil

    local cfg = CoercionCfg()

    -- Proximity abort -> hedef freeze
    -- v6.6.6 B12 (v6.6.5 [KOR NOKTA 1.1]'in bulgusu): Matrix.CyberLeak
    -- modulu hic olusturulmamisti VE _G.MatrixSpikeCyberLeak fallback'i
    -- de hic tanimli degildi -- cyber_leak_intensity spike mekanigi HER
    -- ZAMAN sessiz bir no-op'tu. Iki dal da kaldirildi (kaldir secenegi).
    -- Duzgun bir implementasyon (Matrix.Bureau.SetHeat ile hangi trap
    -- house'un spikelenecegini bulmak) coercion kaydinin bir trapHouseId
    -- tasimasini gerektirir -- kapsam disi, v6.6.7'ye not dusuldu.
    if reason == 'proximity' or reason == 'cancelled' then
        -- Hedefi freeze et
        if c.target_net_id then
            TriggerClientEvent('matrix:client:freezeEntity', -1, c.target_net_id, cfg.FreezeDurationMs)
        end
    end

    BroadcastChat(src or c.source, '[COERCION]', ('Süreç iptal edildi: %s'):format(reason))
    Matrix.Log('RECRUITMENT', '[COERCION] #%d iptal: %s (src=%s)', coercionId, reason, tostring(c.source))
end

function Matrix.Recruitment.BeginCoercion(clientSource, targetNetId, targetData)
    if type(clientSource) ~= 'number' or clientSource <= 0 then return nil, 'bad_source' end
    if type(targetNetId) ~= 'number' then return nil, 'bad_target' end
    if type(targetData) ~= 'table' then return nil, 'bad_data' end

    local eval = Matrix.Recruitment.EvaluateCoercionConditions(targetData)
    if not eval then return nil, 'eval_failed' end

    if not eval.eligible then
        BroadcastChat(clientSource, '[COERCION]',
            ('REDDEDİLDİ — %d/3 koşul sağlandı (min %d). Bio:%s Adli:%s Fin:%s'):format(
                eval.met_count, eval.required,
                tostring(eval.biochemical_bonding),
                tostring(eval.forensic_leverage),
                tostring(eval.financial_dependency)
            ))
        Matrix.Log('RECRUITMENT', '[COERCION] REDDEDİLDİ src=%d (met=%d)', clientSource, eval.met_count)
        return nil, 'rejected'
    end

    local cid = nextCoercionId
    nextCoercionId = cid + 1

    Matrix.Coercions[cid] = {
        id            = cid,
        source        = clientSource,
        target_net_id = targetNetId,
        target_data   = targetData,
        started_at    = os_time(),
        eval          = eval,
        completed     = false
    }

    local cfg = CoercionCfg()

    -- Client'a progress bar başlatma komutu (server-authoritative süre ve proximity izleme)
    TriggerClientEvent('matrix:client:beginCoercionProgress', clientSource, {
        coercion_id       = cid,
        target_net_id    = targetNetId,
        duration_ms      = cfg.DurationMs,
        abort_distance   = cfg.ProximityAbortDistance,
        title            = 'AJAN PSIKOLOJIK COERCION SURECI...'
    })

    BroadcastChat(clientSource, '[COERCION]',
        ('Süreç başlatıldı. Süre: %ds | Adli:%s Fin:%s Bio:%s'):format(
            math_floor(cfg.DurationMs / 1000),
            tostring(eval.forensic_leverage),
            tostring(eval.financial_dependency),
            tostring(eval.biochemical_bonding)
        ))

    Matrix.Log('RECRUITMENT', '[COERCION] #%d başlatıldı (src=%d, target=%d, met=%d)',
        cid, clientSource, targetNetId, eval.met_count)

    return cid
end


-- =====================================================================
-- COERCION TAMAMLANDI (client progress bar bittiğinde çağrılır)
-- =====================================================================
RegisterNetEvent('matrix:server:coercionCompleted', function(coercionId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    coercionId = tonumber(coercionId)
    if not coercionId then return end

    local c = Matrix.Coercions[coercionId]
    if not c or c.source ~= src then return end

    local cfg = CoercionCfg()

    -- Sunucu-yetkili sure dogrulamasi: BeginCoercion'da kaydedilen
    -- started_at'tan bu yana gecen GERCEK sure cfg.DurationMs'i
    -- karsilamiyorsa client 60sn bekleme suresini atlamis demektir.
    local elapsedMs = (os_time() - c.started_at) * 1000
    if elapsedMs < cfg.DurationMs then
        Matrix.Log('RECRUITMENT', '[YETKI RED] #%d src=%d erken tamamlama denemesi (gecen=%dms, gerekli=%dms).',
            coercionId, src, elapsedMs, cfg.DurationMs)
        AbortCoercion(coercionId, 'premature_completion', src)
        return
    end

    -- Sunucu-yetkili yakinlik dogrulamasi: hedefe mesafe yeniden olculur;
    -- client'in bildirdigi mesafeye guvenilmez.
    local targetPed = c.target_net_id and NetworkGetEntityFromNetworkId(c.target_net_id)
    local playerPed = GetPlayerPed(src)
    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed)
        or not playerPed or playerPed == 0 then
        Matrix.Log('RECRUITMENT', '[YETKI RED] #%d src=%d hedef/oyuncu ped cozulemedi.', coercionId, src)
        AbortCoercion(coercionId, 'proximity', src)
        return
    end

    local dist = #(GetEntityCoords(playerPed) - GetEntityCoords(targetPed))
    if dist > cfg.ProximityAbortDistance then
        Matrix.Log('RECRUITMENT', '[YETKI RED] #%d src=%d yakinlik ihlali (mesafe=%.2fm, limit=%.2fm).',
            coercionId, src, dist, cfg.ProximityAbortDistance)
        AbortCoercion(coercionId, 'proximity', src)
        return
    end

    Matrix.Coercions[coercionId] = nil

    local data = c.target_data or {}

    -- Yeni bir aday kaydı üret: coercion tamamlandı → psychology coercion-türevli
    local cid = nextCandidateId
    nextCandidateId = cid + 1

    local traits
    if Matrix.Cognition and Matrix.Cognition.DeriveCoercedPsychology then
        traits = Matrix.Cognition.DeriveCoercedPsychology(data)
    else
        -- Deterministik fallback (RNG yok)
        local addiction = tonumber(data.addiction_level) or 0.0
        local forensic  = c.eval.forensic_leverage and 1 or 0
        local finance   = c.eval.financial_dependency and 1 or 0
        traits = {
            fear_factor       = Matrix.Clamp(0.40 + forensic * 0.30 + (addiction / 100.0) * 0.20, 0.0, 1.0),
            resilience        = Matrix.Clamp(0.70 - forensic * 0.25 - finance * 0.15, 0.0, 1.0),
            snitch_tendency   = Matrix.Clamp(0.10 + (1.0 - forensic) * 0.35, 0.0, 1.0),
            economic_pressure = Matrix.Clamp(0.20 + finance * 0.55, 0.0, 1.0),
            cognitive_shifter = Matrix.Clamp(0.30 + forensic * 0.20, 0.0, 1.0),
            skill_chemistry   = Matrix.Clamp(0.15 + finance * 0.10, 0.0, 1.0)
        }
    end

    -- v6.6.6 H19: handler_citizenid coercion basariyla tamamlanir tamamlanmaz
    -- atanir -- coercion'i yapan oyuncu (src) bu ajanin handler'i olur.
    -- Bu olmadan bot.handler_citizenid hep nil kalir ve hangi handler'in
    -- hangi bota bagli oldugu asla belli olmazdi (orn. bureau.lua'nin
    -- _IsRaidDispatcher kontrolu bu alana bagimlidir).
    local handlerState = Matrix.GetOrCreatePlayerState(src)

    Matrix.Candidates[cid] = {
        id                = cid,
        citizenid         = data.citizenid or ('coerced_%d'):format(cid),
        handler_citizenid = handlerState and handlerState.citizenid,
        name              = data.name or ('Ajan-%d'):format(cid),
        psychology        = traits,
        addiction_level   = tonumber(data.addiction_level) or 0.0,
        revealed_fields   = {},
        coerced           = true
    }

    -- Otomatik bot devşirme (tam baskı sonrası)
    local bot = Matrix.Recruitment.Promote(Matrix.Candidates[cid])
    BroadcastChat(src, '[COERCION]',
        ('Süreç tamamlandı. Ajan devşirildi -> Bot #%d (Res:%.2f Snitch:%.2f)'):format(
            bot.id, bot.psychology.resilience, bot.psychology.snitch_tendency))

    Matrix.Log('RECRUITMENT', '[COERCION] #%d tamamlandı → Bot #%d', coercionId, bot.id)
end)


-- =====================================================================
-- COERCION IPTAL (proximity ihlali / cancel)
-- =====================================================================
RegisterNetEvent('matrix:server:coercionAborted', function(coercionId, reason)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    coercionId = tonumber(coercionId)
    if not coercionId then return end

    local c = Matrix.Coercions[coercionId]
    if not c or c.source ~= src then return end

    reason = (type(reason) == 'string' and reason) or 'cancelled'
    AbortCoercion(coercionId, reason, src)
end)


-- =====================================================================
-- HEdef veri toplama NET handler'ı
-- Client, hedef ped'in birincil bilgilerini server'a iletir.
-- Server, DB doğrulamasını yapar ve BeginCoercion'ı çalıştırır.
-- =====================================================================
RegisterNetEvent('matrix:server:requestCoercion', function(targetNetId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    targetNetId = tonumber(targetNetId)
    if not targetNetId then return end

    -- Client'tan gelen state bilgisi + citizenid stub'ını çek
    -- Client tarafı BeginCoercion'a hazır data sağlar
    TriggerClientEvent('matrix:client:gatherCoercionData', src, targetNetId)
end)

RegisterNetEvent('matrix:server:coercionDataReady', function(targetNetId, targetData)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    targetNetId = tonumber(targetNetId)
    if not targetNetId or type(targetData) ~= 'table' then return end

    Matrix.Recruitment.BeginCoercion(src, targetNetId, targetData)
end)


-- =====================================================================
-- ESKİ DAVRANIŞ YASAĞI: /npcrecruit kaldırıldı
-- ---------------------------------------------------------------------
-- Anlık devşirme artık YASAKTIR. Komut bilinçli olarak kayıtlı DEĞİLDİR.
-- (Yanlışlıkla mod/resource tarafından çağrılırsa net bir red mesajı verilir.)
-- =====================================================================
RegisterCommand('npcrecruit', function(src)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[COERCION]', 'Bu komut kaldırıldı. Faz 5 itibariyle devşirme yalnızca biyokimyasal/adli/finansal coercion süreci ile mümkündür.' }
        })
    else
        print('[MATRIX:RECRUITMENT:CONSOLE] /npcrecruit devre dışı.')
    end
end, false)


-- =====================================================================
-- INTERROGATION (DEĞİŞTİRİLMEDİ)
-- =====================================================================
function Matrix.Recruitment.BeginInterrogation(subjectRef, interrogatorSource)
    local kind, id
    if type(subjectRef) == 'table' then
        kind, id = subjectRef.kind, tonumber(subjectRef.id)
    else
        kind, id = 'candidate', tonumber(subjectRef)
    end
    if not id then return nil end

    local subject = ResolveInterrogationSubject(kind, id)
    if not subject then return nil end

    local sid = nextSessionId
    nextSessionId = sid + 1

    Matrix.Sessions[sid] = {
        id                  = sid,
        subject_kind        = subject.kind,
        subject_id          = subject.id,
        interrogator_source = interrogatorSource,
        cumulative_pressure = 0.0,
        lies_told           = 0,
        confessions         = 0,
        revealed            = {}
    }

    Matrix.Log('RECRUITMENT', 'Sorgu #%d başlatıldı -> %s #%s (%s)', sid, subject.kind, tostring(subject.id), subject.name)
    return sid
end


local function NextUnrevealedField(session)
    for _, field in ipairs(BIO_FIELDS) do
        if not session.revealed[field] then return field end
    end
    return nil
end


function Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
    sessionId = tonumber(sessionId)
    if not sessionId then return nil end
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end

    local subject = ResolveInterrogationSubject(session.subject_kind, session.subject_id)
    if not subject then return nil end
    local psychology = subject.psychology

    pressureAmount = tonumber(pressureAmount) or 0.0
    if pressureAmount ~= pressureAmount or pressureAmount < 0.0 then pressureAmount = 0.0 end
    if pressureAmount > 100.0 then pressureAmount = 100.0 end

    session.cumulative_pressure = session.cumulative_pressure + pressureAmount

    local panic = Matrix.Clamp(
        (session.cumulative_pressure * psychology.fear_factor)
            - (psychology.resilience * Config.Recruitment.ResilienceDamping),
        0.0, 1.0
    )
    local waveform = BuildAsciiWaveform(panic)

    local field = NextUnrevealedField(session)
    if not field then
        Matrix.Log('RECRUITMENT', 'Sorgu #%d tükendi. Panik: %s', sessionId, waveform)
        return { panic_index = panic, outcome = 'exhausted', waveform = waveform }
    end

    if panic >= Config.Recruitment.ConfessionThreshold then
        session.revealed[field] = psychology[field]
        session.confessions = session.confessions + 1
        Matrix.Log('RECRUITMENT', '[İTİRAF] Sorgu #%d -> %s = %.2f | Panik: %s',
            sessionId, field, psychology[field], waveform)
        return { panic_index = panic, outcome = 'confession', field = field, value = psychology[field], waveform = waveform }
    elseif panic >= Config.Recruitment.LieThreshold then
        local trueValue = psychology[field]
        local fakeValue = Matrix.Clamp(trueValue + ((trueValue >= 0.5) and -0.4 or 0.4), 0.0, 1.0)
        session.lies_told = session.lies_told + 1

        local deviation = Matrix.Clamp(panic - (Config.Recruitment.LieWaveformDeviationPerLie * session.lies_told), 0.0, 1.0)
        local deviationWave = BuildAsciiWaveform(deviation)

        Matrix.Log('RECRUITMENT', '[YALAN TESPİTİ] Sorgu #%d -> %s alanında sapma tespit edildi.\n  SES  : %s\n  SAPMA: %s',
            sessionId, field, waveform, deviationWave)
        return { panic_index = panic, outcome = 'lie', field = field, value = fakeValue, waveform = waveform, deviation_waveform = deviationWave }
    else
        Matrix.Log('RECRUITMENT', '[SESSİZLİK] Sorgu #%d -> Aday baskıya direniyor. Panik: %s', sessionId, waveform)
        return { panic_index = panic, outcome = 'silence', waveform = waveform }
    end
end


function Matrix.Recruitment.Promote(candidate)
    local bot = Matrix.CreateBotRecord({
        name              = candidate.name,
        role              = 'dealer',
        handler_citizenid = candidate.handler_citizenid,
        fear_factor       = candidate.psychology.fear_factor,
        resilience        = candidate.psychology.resilience,
        snitch_tendency   = candidate.psychology.snitch_tendency,
        economic_pressure = candidate.psychology.economic_pressure,
        cognitive_shifter = candidate.psychology.cognitive_shifter,
        skill_chemistry   = candidate.psychology.skill_chemistry,
        addiction_level   = candidate.addiction_level
    })

    Matrix.Log('RECRUITMENT', 'Aday #%d bot matrisine eklendi -> Bot #%d', candidate.id, bot.id)
    return bot
end


function Matrix.Recruitment.RecruitStreetNpc(npcLabel, trapHouseId, loyaltyBase)
    npcLabel = (type(npcLabel) == 'string' and npcLabel ~= '') and npcLabel or 'Sokak Ajani'
    trapHouseId = tonumber(trapHouseId)

    local momentum = (Matrix.Bureau and Matrix.Bureau.GetPropagandaMomentum and Matrix.Bureau.GetPropagandaMomentum()) or 0.0
    local qualityFactor = Matrix.Clamp(
        1.0 + (momentum / Config.Recruitment.MomentumQualityDivisor),
        1.0, Config.Recruitment.MomentumQualityCeiling
    )

    local resilience     = Matrix.Clamp(Config.Recruitment.BaseCandidateResilience * qualityFactor, 0.0, 1.0)
    local snitchTendency = Matrix.Clamp(Config.Recruitment.BaseCandidateSnitchTendency / qualityFactor, 0.0, 1.0)

    local bot = Matrix.CreateBotRecord({
        name              = npcLabel,
        role              = 'dealer',
        fear_factor       = 0.5,
        resilience        = resilience,
        snitch_tendency   = snitchTendency,
        economic_pressure = 0.5,
        cognitive_shifter = 0.2,
        skill_chemistry   = 0.1,
        trap_house_id     = trapHouseId,
        loyalty_base      = loyaltyBase
    })

    Matrix.Log('RECRUITMENT',
        '[SOKAK DEVSIRME] "%s" -> Bot #%d (momentum=%.2f, kaliteFaktoru=%.3f, resilience=%.3f, snitch=%.3f, loyalty=%.2f, trap=%s)',
        npcLabel, bot.id, momentum, qualityFactor, resilience, snitchTendency, bot.psychology.loyalty_base, tostring(trapHouseId))

    return bot
end


function Matrix.Recruitment.EvaluateOutcome(sessionId)
    sessionId = tonumber(sessionId)
    if not sessionId then return nil end
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end

    local subject = ResolveInterrogationSubject(session.subject_kind, session.subject_id)
    if not subject then return nil end
    local psychology = subject.psychology

    local outcome
    if session.lies_told > Config.Recruitment.MaxToleratedLies then
        outcome = 'burned'
    elseif session.confessions >= Config.Recruitment.MinConfessionsToPromote
        and psychology.snitch_tendency <= Config.Recruitment.SafeSnitchTendencyCeiling
        and psychology.resilience >= Config.Recruitment.MinOperationalResilience then
        outcome = (subject.kind == 'candidate') and 'recruited' or 'released'
    else
        outcome = 'released'
    end

    MySQL.prepare([[
        INSERT INTO matrix_recruitment_sessions (
            candidate_citizenid, fear_factor, resilience, lies_told, confessions, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, NOW())
    ]], {
        subject.ref_key, psychology.fear_factor, psychology.resilience,
        session.lies_told, session.confessions, outcome
    })

    if outcome == 'recruited' and subject.kind == 'candidate' then
        Matrix.Recruitment.Promote(Matrix.Candidates[subject.id])
    end

    if subject.kind == 'candidate' then
        Matrix.Candidates[subject.id] = nil
    end
    Matrix.Sessions[sessionId] = nil

    Matrix.Log('RECRUITMENT', 'Sorgu #%d (%s #%s) sonuçlandı: %s', sessionId, subject.kind, tostring(subject.id), outcome)
    return outcome
end


-- =====================================================================
-- EVENT BRIDGE
-- =====================================================================
RegisterNetEvent('matrix:server:beginInterrogation', function(candidateId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    candidateId = tonumber(candidateId)
    if not candidateId then return end
    Matrix.Recruitment.BeginInterrogation(candidateId, src)
end)

RegisterNetEvent('matrix:server:applyInterrogationPressure', function(sessionId, pressureAmount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    sessionId = tonumber(sessionId)
    if not sessionId then return end
    Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
end)

RegisterNetEvent('matrix:server:evaluateInterrogation', function(sessionId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    sessionId = tonumber(sessionId)
    if not sessionId then return end
    Matrix.Recruitment.EvaluateOutcome(sessionId)
end)


-- =====================================================================
-- KOMUT: /sorgu
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[SORGU]', msg } })
    else
        print(('[MATRIX:RECRUITMENT:CONSOLE] %s'):format(msg))
    end
end


RegisterCommand('sorgu', function(src, args)
    local id = tonumber(args[1])
    local kind = (args[2] == 'bot') and 'bot' or 'candidate'

    if not id then
        Reply(src, 'Kullanim: /sorgu [id] [aday|bot]'); return
    end

    local sid = Matrix.Recruitment.BeginInterrogation({ kind = kind, id = id }, src)
    if not sid then
        Reply(src, ('%s #%d bulunamadı.'):format(kind, id)); return
    end

    local result = Matrix.Recruitment.ApplyPressure(sid, 25.0)
    if result then
        Reply(src, ('Sorgu #%d | Panik: %s | Sonuç: %s'):format(sid, result.waveform, result.outcome))
    end
end, false)


-- =====================================================================
-- /musterikaydet, /havuztara, /adaygoster, /baskiuygula, /sorgubitir
-- (AYNEN KORUNDU)
-- =====================================================================
RegisterCommand('musterikaydet', function(src, args)
    local citizenid = args[1]
    local name       = args[2] or citizenid
    if type(citizenid) ~= 'string' then
        Reply(src, 'Kullanim: /musterikaydet [citizenid] [isim] [polisEncounter] [tamamlananIs] [ihbar] [odemeBasarisiz] [kimyaIpucu] [bagimlilik]')
        return
    end

    MySQL.prepare([[
        INSERT INTO matrix_customer_pool (
            citizenid, name, police_encounters_nearby, completed_deals, times_reported,
            failed_payments, chemistry_hints, addiction_level, promoted_to_candidate, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NOW())
        ON DUPLICATE KEY UPDATE
            name = VALUES(name), police_encounters_nearby = VALUES(police_encounters_nearby),
            completed_deals = VALUES(completed_deals), times_reported = VALUES(times_reported),
            failed_payments = VALUES(failed_payments), chemistry_hints = VALUES(chemistry_hints),
            addiction_level = VALUES(addiction_level)
    ]], {
        citizenid, name,
        tonumber(args[3]) or 0, tonumber(args[4]) or 0, tonumber(args[5]) or 0,
        tonumber(args[6]) or 0, tonumber(args[7]) or 0, tonumber(args[8]) or 0.0
    })

    Reply(src, ('Müşteri havuzu satırı yazıldı: %s (%s)'):format(citizenid, name))
end, false)


RegisterCommand('havuztara', function(src)
    local count = Matrix.Recruitment.ScanCustomerPool()
    Reply(src, ('Havuz tarandı: %d aday terfi etti.'):format(count or 0))
end, false)


RegisterCommand('adaygoster', function(src, args)
    local id = tonumber(args[1])
    local candidate = id and Matrix.Candidates[id]
    if not candidate then Reply(src, 'Kullanim: /adaygoster [candidateId]'); return end

    local p = candidate.psychology
    Reply(src, ('Aday #%d %s | Fear:%.2f Res:%.2f Snitch:%.2f Econ:%.2f Cog:%.2f Chem:%.2f | Bağımlılık:%.1f'):format(
        id, candidate.name, p.fear_factor, p.resilience, p.snitch_tendency, p.economic_pressure,
        p.cognitive_shifter, p.skill_chemistry, candidate.addiction_level))
end, false)


RegisterCommand('baskiuygula', function(src, args)
    local sid = tonumber(args[1])
    local amount = tonumber(args[2])
    if not sid or not amount then Reply(src, 'Kullanim: /baskiuygula [sessionId] [miktar]'); return end

    local result = Matrix.Recruitment.ApplyPressure(sid, amount)
    if not result then Reply(src, 'Sorgu bulunamadı.'); return end

    Reply(src, ('Panik: %s (%.3f) | Sonuç: %s'):format(result.waveform, result.panic_index, result.outcome))
end, false)


RegisterCommand('sorgubitir', function(src, args)
    local sid = tonumber(args[1])
    if not sid then Reply(src, 'Kullanim: /sorgubitir [sessionId]'); return end

    local outcome = Matrix.Recruitment.EvaluateOutcome(sid)
    Reply(src, outcome and ('Sonuç: %s'):format(outcome) or 'Sorgu bulunamadı.')
end, false)


RegisterCommand('sokakdevsir', function(src, args)
    local trapHouseId = tonumber(args[1])
    local label = args[2] or 'Test-Ajan'
    local bot = Matrix.Recruitment.RecruitStreetNpc(label, trapHouseId, 1.0)
    Reply(src, ('"%s" devsirildi -> Bot #%d (loyalty_base=%.2f).'):format(label, bot.id, bot.psychology.loyalty_base))
end, false)


exports('RecruitStreetNpc', function(npcLabel, trapHouseId, loyaltyBase)
    return Matrix.Recruitment.RecruitStreetNpc(npcLabel, trapHouseId, loyaltyBase)
end)